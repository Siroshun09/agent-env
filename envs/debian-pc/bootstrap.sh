#!/usr/bin/env bash
# Debian 13 (trixie) の実 PC をエージェント専用ホストに仕立てる。冪等なので何度実行してもよい。
# 初回起動時（agent-env-firstboot.service）と、管理者が手動で反映するとき（apply.sh）に実行される。
#
# OS パッケージ・ユーザー・更新設定に加え、エージェントのツール（Claude Code、OpenCode、mise）と
# その管理者用の設定まで扱う。agent ユーザーのホームに置くのは秘密情報と作業中のリポジトリだけで、ここでは扱わない。
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_USER=agent

log() { printf '\n==> %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }

log "apt リポジトリ（Debian 以外）"
export DEBIAN_FRONTEND=noninteractive
# HTTPS のリポジトリを読むには ca-certificates が先に要る
apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates
# 署名鍵はリポジトリに同梱する（取得時に fingerprint を確認済み。各 .sources のコメントを参照）
install -d -m 0755 /etc/apt/keyrings
install -m 0644 "${ENV_DIR}"/system/apt/keyrings/*.asc /etc/apt/keyrings/
install -m 0644 "${ENV_DIR}"/system/apt/sources/*.sources /etc/apt/sources.list.d/

log "apt パッケージ"
apt-get update -q
# コメント・空行を除いて packages.txt を読む
mapfile -t PKGS < <(sed -e 's/#.*//' -e '/^\s*$/d' "${ENV_DIR}/packages.txt")
apt-get install -y -q --no-install-recommends "${PKGS[@]}"

log "エージェント用ユーザー: ${AGENT_USER}"
if ! id "${AGENT_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${AGENT_USER}"
fi
# sudo は付与しない。root が必要なもの（apt パッケージやツールの導入）はこのリポジトリに書く。
# rootless podman 用の subuid/subgid は、uidmap が入っているので useradd が割り当てる。

log "OpenCode"
# shellcheck disable=SC1091 # 変数を定義するだけのファイル
source "${ENV_DIR}/tools.conf"
if [[ "$(/usr/local/bin/opencode --version 2>/dev/null || true)" != "opencode v${OPENCODE_VERSION}" ]]; then
  tmp="$(mktemp -d)"
  tarball="${tmp}/opencode.tgz"
  curl -fsSL -o "${tarball}" "https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${OPENCODE_VERSION}.tgz"
  actual="sha512-$(openssl dgst -sha512 -binary "${tarball}" | base64 -w0)"
  if [[ "${actual}" != "${OPENCODE_INTEGRITY}" ]]; then
    echo "OpenCode の SHA-512 が一致しません: ${actual}" >&2
    exit 1
  fi
  tar -xzf "${tarball}" -C "${tmp}" package/bin/opencode
  install -m 0755 "${tmp}/package/bin/opencode" /usr/local/bin/opencode
  rm -rf "${tmp}"
fi

log "エージェントのツールの管理者用設定"
# ユーザー・プロジェクトの設定より優先される。root 所有なので agent ユーザーは変更できない
install -d -m 0755 /etc/claude-code /etc/opencode
install -m 0644 "${ENV_DIR}/system/claude-code/managed-settings.json" /etc/claude-code/
install -m 0644 "${ENV_DIR}/system/opencode/opencode.jsonc" /etc/opencode/
install -m 0644 "${ENV_DIR}/system/profile.d/agent-env-mise.sh" /etc/profile.d/

log "NVIDIA ドライバー（NVIDIA の GPU がある場合だけ）"
# DKMS でビルドするオープン版のカーネルモジュールと、計算用（CUDA）のライブラリだけを入れる（画面表示用は入れない）。
# ドライバーのブランチは nvidia-driver-pinning-* で固定し、上げるときはここを書き換える
NVIDIA_PKGS=(linux-headers-amd64 nvidia-driver-pinning-620 nvidia-kernel-open-dkms nvidia-driver-cuda)
has_nvidia_gpu() {
  local d
  for d in /sys/bus/pci/devices/*; do
    [[ "$(cat "$d/vendor")" == 0x10de && "$(cat "$d/class")" == 0x03* ]] && return 0
  done
  return 1
}
if has_nvidia_gpu; then
  # Secure Boot が有効なら、モジュールの署名鍵の MOK 登録を申請する（インストール中に申請済みなら何もしない）
  # 失敗しても残りの設定は続ける（ドライバーは入り、署名鍵の登録が済めば読み込まれる）
  if ! "${ENV_DIR}/mok-enroll.sh"; then
    echo "警告: MOK の登録申請に失敗しました。次の bootstrap（apply.sh）で再試行します" >&2
  fi
  apt-get install -y -q --no-install-recommends "${NVIDIA_PKGS[@]}"
  if ! nvidia-smi >/dev/null 2>&1; then
    # 初回は nouveau の無効化（initramfs）と、MOK の承認のために再起動が要る
    echo "NVIDIA ドライバーを使うには再起動が必要です（sudo reboot）"
    echo "agent-env: NVIDIA ドライバー" >> /run/reboot-required.pkgs
    touch /run/reboot-required
  fi
else
  echo "NVIDIA の GPU が無いのでスキップします"
fi

log "Mac のブラウザから接続するためのサービス"
# エージェントの作業場所。Remote Control と OpenCode のセッションはここで始まる。
# agent ユーザーとして作る（root で agent のホーム以下を操作すると、agent が置いたシンボリックリンクを
# たどって別の場所の所有者や権限を変えてしまうため）
runuser -u "${AGENT_USER}" -- mkdir -p "/home/${AGENT_USER}/work"
# OpenCode サーバーのパスワード（初回だけ生成する。確認: sudo cat /etc/agent-env/opencode-server.env）
install -d -m 0755 /etc/agent-env
if [[ ! -s /etc/agent-env/opencode-server.env ]]; then
  (umask 077 && printf 'OPENCODE_PASSWORD=%s\n' "$(openssl rand -hex 16)" > /etc/agent-env/opencode-server.env)
fi
UNITS=(agent-env-claude-remote.service agent-env-claude-remote.path agent-env-opencode.service)
for u in "${UNITS[@]}"; do
  install -m 0644 "${ENV_DIR}/system/${u}" /etc/systemd/system/
done
systemctl enable agent-env-claude-remote.path agent-env-opencode.service
# systemd が動いている（コンテナでの検査ではない）なら、止まっていれば起動する。
# 動作中のサービスは再起動しない（作業中のセッションを切らないため）。ユニットの変更は次の再起動で反映される
if [[ -d /run/systemd/system ]]; then
  systemctl daemon-reload
  systemctl start --no-block agent-env-claude-remote.path agent-env-opencode.service
fi

log "Debian の自動セキュリティ更新"
# OS のパッチは unattended-upgrades で自動適用する。このリポジトリの変更は自動では反映しない（apply.sh で手動）
install -m 0644 "${ENV_DIR}/system/apt/52agent-env-unattended-upgrades" /etc/apt/apt.conf.d/

log "SSH ホスト鍵の fingerprint をコンソールのログイン画面に表示"
# 再インストールでホスト鍵が変わるので、初回接続時にこの表示と照合する
mkdir -p /etc/issue.d
for k in /etc/ssh/ssh_host_*_key.pub; do
  if [[ -f "$k" ]]; then ssh-keygen -lf "$k"; fi
done | sed 's/^/SSH host key: /' > /etc/issue.d/agent-env-ssh.issue

log "完了"

#!/usr/bin/env bash
# Debian 13 (trixie) の実 PC をエージェント専用ホストに仕立てる。冪等なので何度実行してもよい。
# 初回起動時（agent-env-firstboot.service）と毎日の更新（agent-env-update.service）から実行される。
# 手動実行: sudo /opt/agent-env/envs/debian-pc/bootstrap.sh
#
# 責務は PC 側（OS パッケージ・ユーザー・自動更新）まで。
# agent ユーザーのホーム以下（Claude Code、言語ツール、シェル設定、秘密情報）は別リポジトリで管理する。
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_USER="${AGENT_USER:-agent}"

log() { printf '\n==> %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }
# 初回セットアップ・毎日の更新・手動実行が同時に動かないようにする（update.sh と同じロック）
[[ -n "${AGENT_ENV_LOCKED:-}" ]] || exec env AGENT_ENV_LOCKED=1 flock /run/agent-env.lock "$0" "$@"

log "apt パッケージ"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# コメント・空行を除いて packages.txt を読む
mapfile -t PKGS < <(sed -e 's/#.*//' -e '/^\s*$/d' "${ENV_DIR}/packages.txt")
apt-get install -y -q --no-install-recommends "${PKGS[@]}"

log "エージェント用ユーザー: ${AGENT_USER}"
if ! id "${AGENT_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${AGENT_USER}"
fi
# sudo は付与しない。root が必要なもの（apt パッケージ等）はこのリポジトリに書く。

# rootless podman 用の subuid/subgid。uidmap があれば useradd が割り当てるが、
# uidmap より先にユーザーを作った場合などに備えて、無ければ既存範囲の後ろに追加する。
for f in /etc/subuid /etc/subgid; do
  touch "$f"
  if ! grep -q "^${AGENT_USER}:" "$f"; then
    start="$(awk -F: 'BEGIN { m = 100000 } { e = $2 + $3; if (e > m) m = e } END { print m }' "$f")"
    echo "${AGENT_USER}:${start}:65536" >> "$f"
  fi
done

log "自動更新"
# セキュリティ更新は unattended-upgrades、このリポジトリの変更は agent-env-update.timer（毎日）で反映する
install -m 0644 "${ENV_DIR}/system/apt/52agent-env-unattended-upgrades" /etc/apt/apt.conf.d/
if command -v systemctl >/dev/null 2>&1; then
  install -m 0644 "${ENV_DIR}/system/agent-env-update.service" "${ENV_DIR}/system/agent-env-update.timer" \
    /etc/systemd/system/
  if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable --now agent-env-update.timer
  else
    systemctl enable agent-env-update.timer # chroot 等、systemd が動いていない場合
  fi
fi

log "SSH ホスト鍵の fingerprint をコンソールのログイン画面に表示"
# 再インストールでホスト鍵が変わるので、初回接続時にこの表示と照合する
mkdir -p /etc/issue.d
for k in /etc/ssh/ssh_host_*_key.pub; do
  if [[ -f "$k" ]]; then ssh-keygen -lf "$k"; fi
done | sed 's/^/SSH host key: /' > /etc/issue.d/agent-env-ssh.issue

log "完了"

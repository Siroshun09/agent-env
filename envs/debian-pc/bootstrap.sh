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
# 作るファイルの権限を、呼び出し元の umask に左右されないようにする
umask 022
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
# エージェントへの指示。Claude Code は管理者用の CLAUDE.md として読み（ユーザーは除外できない）、
# OpenCode は opencode.jsonc の instructions で読む。毎回のリクエストに含まれるので短くし、
# ローカル LLM の呼び出し方の詳細は、必要なときにエージェントが読む別のファイルにする
install -m 0644 "${ENV_DIR}/system/agents/instructions.md" /etc/claude-code/CLAUDE.md
install -d -m 0755 /etc/agent-env
install -m 0644 "${ENV_DIR}/system/agents/local-llm.md" /etc/agent-env/local-llm.md
install -m 0644 "${ENV_DIR}/system/profile.d/agent-env-mise.sh" /etc/profile.d/
install -d -m 0755 /etc/mise
install -m 0644 "${ENV_DIR}/system/mise/config.toml" /etc/mise/config.toml
# グローバルの言語ツール（Java、Go、pnpm）を agent ユーザーとして入れる。
# 失敗しても残りの設定は続ける（次の bootstrap で再試行する）
if ! runuser -u "${AGENT_USER}" -- env -C "/home/${AGENT_USER}" HOME="/home/${AGENT_USER}" MISE_YES=1 mise install; then
  echo "警告: mise のツールのインストールに失敗しました。次の bootstrap（apply.sh）で再試行します" >&2
fi

log "GitHub のトークンの使い分け（持ち主ごとの fine-grained PAT）"
# git はリモートの URL の持ち主、gh は操作対象のリポジトリの持ち主で、トークンを選ぶ。
# トークン自体は agent ユーザーが agent-env-github-token set <owner> で保存する（リポジトリにも ISO にも入らない）
install -m 0755 "${ENV_DIR}/system/github/agent-env-github-token.sh" /usr/local/bin/agent-env-github-token
install -m 0755 "${ENV_DIR}/system/github/git-credential-agent-env.sh" /usr/local/bin/git-credential-agent-env
install -m 0755 "${ENV_DIR}/system/github/gh.sh" /usr/local/bin/gh
git config --system --replace-all credential.https://github.com.helper agent-env
git config --system credential.https://github.com.useHttpPath true
# SSH の URL は HTTPS に読み替える（SSH の鍵は置かないので、トークンを使える HTTPS に統一する）
git config --system --unset-all url.https://github.com/.insteadOf || true
git config --system --add url.https://github.com/.insteadOf git@github.com:
git config --system --add url.https://github.com/.insteadOf ssh://git@github.com/
# デフォルトブランチへの force push と削除を止める pre-push フックを、すべてのリポジトリに適用する。
# ほかのフックは、リポジトリ自身のフック（.git/hooks）を実行する。push-to-checkout と proc-receive は、
# フックがあるだけで git の動作が変わるので置かない
hooks=/etc/agent-env/git-hooks
rm -rf "${hooks}"
install -d -m 0755 "${hooks}"
install -m 0755 "${ENV_DIR}/system/github/git-hooks/pre-push" "${ENV_DIR}/system/github/git-hooks/run-repo-hook" "${hooks}/"
for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg \
  post-commit pre-rebase post-checkout post-merge post-rewrite reference-transaction pre-auto-gc post-index-change \
  sendemail-validate pre-receive update post-receive post-update; do
  ln -s run-repo-hook "${hooks}/${h}"
done
git config --system core.hooksPath "${hooks}"
# 以前の方式（gh auth login と gh auth setup-git）の認証情報を消す。残っていると、git のユーザー設定が
# 上の helper を無効にしたり、gh が古いトークンを使ったりする。ファイルの操作は agent ユーザーとして行う
agent_git() { runuser -u "${AGENT_USER}" -- env HOME="/home/${AGENT_USER}" git config --global "$@"; }
for section in credential.https://github.com credential.https://gist.github.com; do
  if agent_git --get-regexp "^${section//./\\.}\\." > /dev/null 2>&1; then
    agent_git --remove-section "${section}"
    log "  ${AGENT_USER} の git の設定から ${section} を削除しました"
  fi
done
if [ -e "/home/${AGENT_USER}/.config/gh/hosts.yml" ]; then
  runuser -u "${AGENT_USER}" -- rm -f "/home/${AGENT_USER}/.config/gh/hosts.yml"
  log "  ${AGENT_USER} の gh の認証情報（~/.config/gh/hosts.yml）を削除しました"
fi

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

log "ローカル LLM（llama.cpp）"
# 本体は GPU が無くても入れる（CPU でも動き、CI で検査できるため）。モデルとサーバーは NVIDIA の GPU がある場合だけ
llama_dir="/opt/llama.cpp/${LLAMA_CPP_VERSION}"
if [[ ! -x "${llama_dir}/llama-server" ]]; then
  tmp="$(mktemp -d)"
  tarball="${tmp}/llama.tar.gz"
  curl -fsSL -o "${tarball}" \
    "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_CPP_VERSION}/llama-${LLAMA_CPP_VERSION}-bin-ubuntu-cuda-13.5-x64.tar.gz"
  echo "${LLAMA_CPP_SHA256}  ${tarball}" | sha256sum -c --quiet -
  mkdir -p "${tmp}/x"
  tar -xzf "${tarball}" -C "${tmp}/x" --strip-components=1 --no-same-owner
  # 配布物のディレクトリは誰でも書き込める権限（777）なので、root 以外が書き換えられないようにする
  chmod -R go-w "${tmp}/x"
  chmod 0755 "${tmp}/x"
  install -d -m 0755 /opt/llama.cpp
  rm -rf "${llama_dir}"
  mv "${tmp}/x" "${llama_dir}"
  rm -rf "${tmp}"
fi
ln -sfn "${LLAMA_CPP_VERSION}" /opt/llama.cpp/current
# 古いバージョンを消す（動作中のサーバーは、再起動するまで古いファイルを使い続ける）
find /opt/llama.cpp -mindepth 1 -maxdepth 1 -type d ! -name "${LLAMA_CPP_VERSION}" -exec rm -rf {} +

if has_nvidia_gpu; then
  # 配布バイナリが使う CUDA ランタイム（ドライバーと同じ NVIDIA のリポジトリから）
  apt-get install -y -q --no-install-recommends cuda-cudart-13-5 libcublas-13-5
  if ! id llama >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /var/lib/llama --shell /usr/sbin/nologin llama
  fi
  # モデルの置き場所は root 所有にする（llama ユーザーは読むだけ。llama-server が乗っ取られても、
  # root が書き込む場所にシンボリックリンクを置けないように）
  install -d -m 0755 -o root -g root /var/lib/llama /var/lib/llama/models
  keep=()
  for entry in "${LLAMA_FILES[@]}"; do
    read -r name url sha256 <<< "${entry}"
    file="/var/lib/llama/models/${name}"
    if [[ ! -f "${file}" ]]; then
      # 数十 GB あるので、失敗して再試行したときは途中から再開する。止まった接続は 2 分で切る
      curl -fL --retry 5 --speed-limit 1024 --speed-time 120 -C - -o "${file}.part" "${url}" || {
        rc=$?
        # HTTP のエラー（途中のファイルが本来より大きいときの 416 など）は、途中のファイルを消してやり直す
        if [[ ${rc} -eq 22 ]]; then rm -f "${file}.part"; fi
        echo "モデル（${name}）のダウンロードに失敗しました（curl: ${rc}）" >&2
        exit 1
      }
      if ! echo "${sha256}  ${file}.part" | sha256sum -c --quiet -; then
        # 壊れた途中のファイルから再開し続けないように消す
        rm -f "${file}.part"
        echo "モデル（${name}）の SHA256 が一致しません" >&2
        exit 1
      fi
      chmod 0644 "${file}.part"
      mv "${file}.part" "${file}"
    fi
    keep+=(! -path "${file}")
  done
  # 使わなくなったモデルと、途中のファイルを消す
  find /var/lib/llama/models -maxdepth 1 \( -name '*.gguf' -o -name '*.gguf.part' \) "${keep[@]}" -delete

  # モデルの一覧（llama-server のルーターモードが読む）
  preset_changed=false
  if ! cmp -s "${ENV_DIR}/system/llama-models.ini" /etc/agent-env/llama-models.ini; then
    install -D -m 0644 "${ENV_DIR}/system/llama-models.ini" /etc/agent-env/llama-models.ini
    preset_changed=true
  fi
  # 以前の方式（モデル 1 つ）の設定を消す
  rm -f /etc/agent-env/llama-server.env
  install -m 0644 "${ENV_DIR}/system/agent-env-llama.service" /etc/systemd/system/
  systemctl enable agent-env-llama.service
  if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    # 作業中のセッションを持たないので、モデルや llama.cpp が変わったら再起動してよい
    # ドライバーを入れた直後（再起動前）は GPU を使えないので起動しない（起動時に自動で起動する）
    if ! nvidia-smi >/dev/null 2>&1; then
      echo "GPU を使えないので、llama-server は再起動後に起動します"
    elif [[ "${preset_changed}" == true || "$(readlink /proc/"$(systemctl show -p MainPID --value agent-env-llama)"/exe 2>/dev/null || true)" != "${llama_dir}/llama-server" ]]; then
      systemctl restart --no-block agent-env-llama.service
    fi
  fi
else
  echo "NVIDIA の GPU が無いので、モデルとサーバーは入れません"
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

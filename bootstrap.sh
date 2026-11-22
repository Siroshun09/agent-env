#!/usr/bin/env bash
# Debian 13 (trixie) をエージェント専用ホストに仕立てる。冪等なので何度実行してもよい。
# 使い方: sudo ./bootstrap.sh   （cloud-init からも同じものを呼ぶ）
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_USER="${AGENT_USER:-agent}"
AGENT_HOME="/home/${AGENT_USER}"
CLAUDE_VERSION="$(cat "${REPO_DIR}/config/claude-version")"

log() { printf '\n==> %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }

log "apt パッケージ"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# コメント・空行を除いて packages.txt を読む
mapfile -t PKGS < <(sed -e 's/#.*//' -e '/^\s*$/d' "${REPO_DIR}/config/packages.txt")
apt-get install -y -q --no-install-recommends "${PKGS[@]}"

log "エージェント用ユーザー: ${AGENT_USER}"
if ! id "${AGENT_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${AGENT_USER}"
fi
# sudo は付与しない。root が必要な変更は bootstrap 側（＝このリポジトリ）に書く。

log "ツールチェーン (mise)"
install -d -o "${AGENT_USER}" -g "${AGENT_USER}" "${AGENT_HOME}/.config" "${AGENT_HOME}/.config/mise"
install -m 0644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${REPO_DIR}/config/mise.toml" "${AGENT_HOME}/.config/mise/config.toml"
install -m 0644 -o "${AGENT_USER}" -g "${AGENT_USER}" \
  "${REPO_DIR}/config/bashrc.local" "${AGENT_HOME}/.bashrc.local"
grep -qxF '[ -f ~/.bashrc.local ] && . ~/.bashrc.local' "${AGENT_HOME}/.bashrc" ||
  echo '[ -f ~/.bashrc.local ] && . ~/.bashrc.local' >> "${AGENT_HOME}/.bashrc"
# 非対話シェル（エージェントからの実行）でもツールが見えるよう shims を PATH に入れる
for line in 'export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"' 'export DISABLE_AUTOUPDATER=1'; do
  grep -qxF "${line}" "${AGENT_HOME}/.profile" || echo "${line}" >> "${AGENT_HOME}/.profile"
done

# mise 本体は apt の公式リポジトリから入れると更新・削除が apt で管理できる
if ! command -v mise >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor --yes -o /etc/apt/keyrings/mise.gpg
  echo "deb [signed-by=/etc/apt/keyrings/mise.gpg arch=$(dpkg --print-architecture)] https://mise.jdx.dev/deb stable main" \
    > /etc/apt/sources.list.d/mise.list
  apt-get update -q
  apt-get install -y -q mise
fi
runuser -l "${AGENT_USER}" -c 'mise trust --all >/dev/null 2>&1 || true; mise install --yes'

log "Claude Code ${CLAUDE_VERSION}"
# 公式ネイティブインストーラでバージョン固定。自動更新は bashrc.local / .profile で無効化している。
if ! runuser -l "${AGENT_USER}" -c 'claude --version 2>/dev/null' | grep -qF "${CLAUDE_VERSION}"; then
  runuser -l "${AGENT_USER}" -c "curl -fsSL https://claude.ai/install.sh | bash -s ${CLAUDE_VERSION}"
fi

log "作業ディレクトリ"
install -d -o "${AGENT_USER}" -g "${AGENT_USER}" "${AGENT_HOME}/work"
# 秘密情報はリポジトリに含めない。ここに手で置くか、プロビジョナから注入する。
install -d -m 0700 -o "${AGENT_USER}" -g "${AGENT_USER}" "${AGENT_HOME}/.secrets"

log "完了"
runuser -l "${AGENT_USER}" -c 'mise ls --current; claude --version'

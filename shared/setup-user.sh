#!/usr/bin/env bash
# エージェント用ユーザーの環境を整える（OS 非依存・root 不要・冪等）。
# 前提: mise, curl, git が PATH にあること（各 envs/*/ が用意する）。
# 使い方: エージェント用ユーザーとして shared/setup-user.sh を実行する。
set -euo pipefail

SHARED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_VERSION="$(cat "${SHARED_DIR}/claude-version")"

log() { printf '\n==> %s\n' "$*"; }
ensure_line() { # ensure_line <file> <line>
  touch "$1"
  grep -qxF "$2" "$1" || printf '%s\n' "$2" >> "$1"
}

log "シェル設定"
install -d -m 0755 "${HOME}/.config/mise"
install -m 0644 "${SHARED_DIR}/mise.toml" "${HOME}/.config/mise/config.toml"
install -m 0644 "${SHARED_DIR}/shell/agentenv" "${HOME}/.agentenv"
install -m 0644 "${SHARED_DIR}/shell/agentrc" "${HOME}/.agentrc"
# login シェル（非対話を含む）は ~/.agentenv、対話シェルは ~/.agentrc を読む
for f in "${HOME}/.profile" "${HOME}/.zprofile"; do
  ensure_line "$f" '[ -f ~/.agentenv ] && . ~/.agentenv'
done
for f in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
  ensure_line "$f" '[ -f ~/.agentrc ] && . ~/.agentrc'
done

log "ツールチェーン (mise)"
mise trust --all >/dev/null 2>&1 || true
mise install --yes

log "Claude Code ${CLAUDE_VERSION}"
# 公式ネイティブインストーラでバージョン固定。自動更新は DISABLE_AUTOUPDATER で無効化。
if ! "${HOME}/.local/bin/claude" --version 2>/dev/null | grep -qF "${CLAUDE_VERSION}"; then
  curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}"
fi

log "作業ディレクトリ"
install -d -m 0755 "${HOME}/work"
# 秘密情報はリポジトリに含めない。ここに手で置くか、プロビジョナから注入する。
install -d -m 0700 "${HOME}/.secrets"

log "完了"
mise ls --current
"${HOME}/.local/bin/claude" --version

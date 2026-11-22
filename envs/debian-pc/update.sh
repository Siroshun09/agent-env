#!/usr/bin/env bash
# リポジトリを GitHub の最新に追従させ、bootstrap を再実行する（agent-env-update.service から実行）。
# リポジトリにマージされた変更が、翌日には PC に反映される。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRANCH="${AGENT_ENV_BRANCH:-main}"

[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }
cd "${REPO_ROOT}"
# ローカルで編集されていたら上書きせず失敗させる（journal とsystemctl --failed で分かる）
[[ -z "$(git status --porcelain)" ]] || { echo "${REPO_ROOT} に未コミットの変更があります" >&2; exit 1; }

git fetch --quiet origin "${BRANCH}"
if [[ "$(git rev-parse --abbrev-ref HEAD)" != "${BRANCH}" ]]; then
  git checkout --quiet -B "${BRANCH}" "origin/${BRANCH}"
fi
git merge --quiet --ff-only "origin/${BRANCH}"
echo "agent-env: ${BRANCH} @ $(git rev-parse --short HEAD)"

# 更新後のスクリプトで実行する
exec "${REPO_ROOT}/envs/debian-pc/bootstrap.sh"

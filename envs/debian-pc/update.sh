#!/usr/bin/env bash
# リポジトリを GitHub の最新に追従させ、bootstrap を再実行する（agent-env-update.service から実行）。
# リポジトリにマージされた変更が、翌日には PC に反映される。
# - 追従するのは AGENT_ENV_BRANCH（既定 main）だけ。別のブランチがチェックアウトされていたら切り替えずに停止する
# - bootstrap が失敗したら、更新前のコミットに戻して bootstrap をやり直し、失敗として終了する
# - bootstrap と同じロックを取り、初回セットアップや手動実行と同時には動かない
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/envs/debian-pc/bootstrap.sh"
BRANCH="${AGENT_ENV_BRANCH:-main}"
LOCK=/run/agent-env.lock

[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }
[[ -n "${AGENT_ENV_LOCKED:-}" ]] || exec env AGENT_ENV_LOCKED=1 flock "${LOCK}" "$0" "$@"

cd "${REPO_ROOT}"
# ローカルで編集されていたら上書きせず失敗させる（journal と systemctl --failed で分かる）
[[ -z "$(git status --porcelain)" ]] || { echo "${REPO_ROOT} に未コミットの変更があります" >&2; exit 1; }
current="$(git rev-parse --abbrev-ref HEAD)"
if [[ "${current}" != "${BRANCH}" ]]; then
  echo "${current} がチェックアウトされています（追従対象は ${BRANCH}）。自動では切り替えません。" >&2
  echo "切り替える場合: sudo git -C ${REPO_ROOT} switch ${BRANCH}（無ければ fetch 後に switch -c ${BRANCH} origin/${BRANCH}）" >&2
  exit 1
fi

prev="$(git rev-parse HEAD)"
git fetch --quiet origin "${BRANCH}"
git merge --quiet --ff-only "origin/${BRANCH}"
now="$(git rev-parse HEAD)"
echo "agent-env: ${BRANCH} ${prev:0:7} -> ${now:0:7}"

# 更新後のスクリプトで実行する
if ! "${BOOTSTRAP}"; then
  if [[ "${now}" != "${prev}" ]]; then
    echo "bootstrap が失敗したので ${prev:0:7} に戻します" >&2
    git reset --quiet --hard "${prev}"
    "${BOOTSTRAP}" || echo "戻したコミットでの bootstrap も失敗しました" >&2
  fi
  exit 1
fi

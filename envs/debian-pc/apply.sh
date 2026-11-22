#!/usr/bin/env bash
# GitHub の main の変更をこの PC に手動で反映する。自動では実行されない（タイマー等は無い）。
# 使い方: sudo /opt/agent-env/envs/debian-pc/apply.sh
#   1. GitHub から main を取得し、反映するコミット SHA と差分を表示する
#   2. 「yes」と入力して承認したときだけ、fast-forward して bootstrap を実行する
#      新しいコミットが無い場合も、承認すれば現在のコミットで bootstrap を再実行する（失敗後の再試行用）
# - 対話端末から実行されていなければ、何も変更せずに失敗する
# - root 専用。agent ユーザーには sudo が無いので実行できない
# - 反映前後のコミット SHA・bootstrap の出力・結果を /var/log/agent-env/apply.log に記録する
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/envs/debian-pc/bootstrap.sh"
BRANCH=main
LOG_DIR=/var/log/agent-env
LOG="${LOG_DIR}/apply.log"

die() { echo "NG: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "root で実行してください（sudo）"
[[ -t 0 ]] || die "対話端末から実行してください。非対話では承認できないので反映しません"

# 初回セットアップ（再試行待ちを含む）と同時に bootstrap を動かさない
if [[ -d /run/systemd/system ]]; then
  case "$(systemctl show -p ActiveState --value agent-env-firstboot.service)" in
    activating | active | deactivating | reloading)
      die "初回セットアップ（agent-env-firstboot）が実行中です。完了を待つか、sudo systemctl stop agent-env-firstboot で止めてから実行してください" ;;
  esac
fi

cd "${REPO_ROOT}"
[[ -z "$(git status --porcelain)" ]] || die "${REPO_ROOT} に未コミットの変更があります（git -C ${REPO_ROOT} status で確認）"
current="$(git symbolic-ref --quiet --short HEAD || echo "(detached HEAD)")"
[[ "${current}" == "${BRANCH}" ]] ||
  die "${current} がチェックアウトされています。反映するのは ${BRANCH} だけです（切り替える場合: sudo git -C ${REPO_ROOT} switch ${BRANCH}）"

git fetch --quiet origin "${BRANCH}"
prev="$(git rev-parse HEAD)"
next="$(git rev-parse "origin/${BRANCH}")"
git merge-base --is-ancestor "${prev}" "${next}" ||
  die "origin/${BRANCH}（${next}）が現在のコミット（${prev}）の後継ではありません（履歴の書き換え）。反映しません"

echo "リポジトリ: ${REPO_ROOT}（$(git remote get-url origin) ${BRANCH}）"
echo "現在:       ${prev}"
echo "反映:       ${next}"
if [[ "${prev}" == "${next}" ]]; then
  echo "新しいコミットはありません。承認すると現在のコミットで bootstrap を再実行します。"
else
  echo
  git --no-pager log --reverse --format='%h %ad %an  %s' --date=short "${prev}..${next}"
  echo
  git --no-pager diff --stat "${prev}" "${next}"
  echo
  git diff "${prev}" "${next}" # 端末ではページャで表示される
fi
echo
read -r -p "${next:0:12} を反映して bootstrap を root で実行します。よければ yes と入力: " answer || answer=""
[[ "${answer}" == yes ]] || { echo "中止しました（何も変更していません）"; exit 1; }

mkdir -p "${LOG_DIR}"
chmod 0700 "${LOG_DIR}"
log() { printf '%s %s\n' "$(date -Is)" "$*" >> "${LOG}"; }
log "START ${prev} -> ${next} (by ${SUDO_USER:-root})"
git merge --quiet --ff-only "${next}"

# 反映後のスクリプトで実行する
set +e
"${BOOTSTRAP}" 2>&1 | tee -a "${LOG}"
rc=${PIPESTATUS[0]}
set -e

if [[ ${rc} -eq 0 ]]; then
  log "OK ${next}"
  echo "OK: ${next} を反映しました（ログ: ${LOG}）"
  exit 0
fi
log "NG ${next} (bootstrap exit ${rc}, previous ${prev})"
cat >&2 <<MSG
NG: ${next} の bootstrap が失敗しました（終了コード ${rc}）。
  OS の設定は途中まで変更されている可能性があります（自動では元に戻しません）。
  リポジトリは ${next:0:12} のまま（反映前は ${prev:0:12}）。ログ: ${LOG}
  復旧: 原因を直したコミット（または revert）を main にマージしてから、もう一度 apply.sh を実行する。
        一時的な失敗（ネットワーク等）なら、そのまま apply.sh を再実行すればよい（bootstrap は冪等）。
MSG
exit 1

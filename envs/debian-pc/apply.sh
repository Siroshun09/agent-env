#!/usr/bin/env bash
# GitHub の main の変更をこの PC に手動で反映する。自動では実行されない（タイマー等は無い）。
# 使い方: sudo /opt/agent-env/envs/debian-pc/apply.sh
#   1. GitHub から main を取得し、反映するコミット SHA と差分を表示する
#   2. 「yes」と入力して承認したときだけ、fast-forward して bootstrap を実行する
#      新しいコミットが無い場合も、承認すれば現在のコミットで bootstrap を再実行する（失敗後の再試行用）
# root 専用（agent ユーザーには sudo が無い）。非対話では何も変更せずに失敗する。
# 反映前後のコミット SHA・bootstrap の出力・結果を /var/log/agent-env/apply.log に記録する。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP="${REPO_ROOT}/envs/debian-pc/bootstrap.sh"
LOG_DIR=/var/log/agent-env
LOG="${LOG_DIR}/apply.log"
LOCK=/run/agent-env-apply.lock
FIRSTBOOT_DONE=/var/lib/agent-env/firstboot.done

die() { echo "NG: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "root で実行してください（sudo）"
[[ -t 0 ]] || die "対話端末から実行してください。非対話では承認できないので反映しません"

# 初回セットアップが成功してから使う（失敗し続けている場合の復旧は README を参照）
[[ -e "${FIRSTBOOT_DONE}" ]] ||
  die "初回セットアップが完了していません（${FIRSTBOOT_DONE} がありません）。状況: journalctl -u agent-env-firstboot"

# 表示から反映・bootstrap 完了までを排他にする（別の端末の apply.sh が承認されていないコミットを実行しないように）
exec 9> "${LOCK}"
flock -n 9 || die "別の apply.sh が実行中です"

cd "${REPO_ROOT}"
[[ -z "$(git status --porcelain)" ]] || die "${REPO_ROOT} に未コミットの変更があります（git -C ${REPO_ROOT} status で確認）"

[[ "$(git symbolic-ref --quiet --short HEAD || true)" == main ]] || die "main ブランチ以外では反映できません（git -C ${REPO_ROOT} switch main）"

git fetch --quiet origin main
prev="$(git rev-parse HEAD)"
next="$(git rev-parse origin/main)"
git merge-base --is-ancestor "${prev}" "${next}" ||
  die "origin/main（${next}）が現在のコミット（${prev}）の後継ではありません。反映しません（main の履歴の書き換えか、main に無いコミットから作った ISO でインストールした）"

echo "リポジトリ: ${REPO_ROOT}（$(git remote get-url origin) main）"
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
[[ "$(git rev-parse HEAD)" == "${prev}" ]] || die "承認中に HEAD が変わりました。反映しません"
if ! git merge --quiet --ff-only "${next}" || [[ "$(git rev-parse HEAD)" != "${next}" ]]; then
  log "NG ${next} (git update failed)"
  die "${next} に更新できませんでした（bootstrap は実行していません）"
fi

# 反映後のスクリプトで実行する
set +e
"${BOOTSTRAP}" 9>&- 2>&1 | tee -a "${LOG}" # ロックは子プロセスに渡さない
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

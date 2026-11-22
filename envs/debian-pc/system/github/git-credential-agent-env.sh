#!/bin/sh
# git の credential helper。https://github.com/<owner>/... への接続に、<owner> のトークンを使う。
# bootstrap.sh が /usr/local/bin/git-credential-agent-env に配置し、/etc/gitconfig で
# credential.https://github.com.helper=agent-env と useHttpPath=true（<owner> を受け取るため）を設定する。
# トークンが無い持ち主では quit=1 を返し、後続の helper（以前に設定した gh auth git-credential など）と
# プロンプトを止める。別の持ち主のトークンや古い認証情報が使われないようにするため。
set -eu

[ "${1:-}" = get ] || exit 0 # store / erase は何もしない（トークンは agent-env-github-token で管理する）

protocol=""
host=""
path=""
while IFS= read -r line && [ -n "${line}" ]; do
  case "${line}" in
    protocol=*) protocol="${line#protocol=}" ;;
    host=*) host="${line#host=}" ;;
    path=*) path="${line#path=}" ;;
  esac
done

[ "${protocol}" = https ] && [ "${host}" = github.com ] || exit 0
owner="${path%%/*}"
if [ -z "${owner}" ] || ! token="$(agent-env-github-token get "${owner}" 2>/dev/null)"; then
  echo "agent-env: ${owner:-（不明）} の GitHub のトークンがありません。agent-env-github-token set ${owner:-<持ち主>} で保存してください" >&2
  echo quit=1
  exit 0
fi

printf 'username=x-access-token\npassword=%s\n' "${token}"

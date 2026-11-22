#!/bin/sh
# git の credential helper。https://github.com/<owner>/... への接続に、<owner> のトークンを使う。
# bootstrap.sh が /usr/local/bin/git-credential-agent-env に配置し、/etc/gitconfig で
# credential.https://github.com.helper=agent-env と useHttpPath=true（<owner> を受け取るため）を設定する。
# トークンが無い持ち主では何も返さない（git は次の helper か、プロンプトに進む）。
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
[ -n "${owner}" ] || exit 0
token="$(agent-env-github-token get "${owner}" 2>/dev/null)" || exit 0

printf 'username=x-access-token\npassword=%s\n' "${token}"

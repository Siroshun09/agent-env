#!/bin/sh
# gh のラッパー。操作対象のリポジトリの持ち主を判断し、その持ち主のトークン（agent-env-github-token）を
# GH_TOKEN に設定して /usr/bin/gh を実行する。bootstrap.sh が /usr/local/bin/gh に配置する。
# 持ち主は次の順に判断する。
#   1. -R / --repo の値
#   2. 環境変数 GH_REPO
#   3. gh repo <サブコマンド> <owner>/<repo> の引数、gh api の repos/<owner>/... のパス
#   4. 今いる git リポジトリの origin の URL
#   5. トークンが 1 つしか無ければ、その持ち主
# GH_TOKEN か GITHUB_TOKEN が設定済みの場合と、トークンが見つからない場合は、そのまま gh を実行する。
set -eu

real=/usr/bin/gh

if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  exec "${real}" "$@"
fi

# OWNER/REPO、HOST/OWNER/REPO、URL から github.com の持ち主を取り出す
owner_of() {
  r="$1"
  case "${r}" in
    https://github.com/*) r="${r#https://github.com/}" ;;
    git@github.com:*) r="${r#git@github.com:}" ;;
    ssh://git@github.com/*) r="${r#ssh://git@github.com/}" ;;
    github.com/*) r="${r#github.com/}" ;;
    *://* | *@*:*) return 1 ;; # github.com 以外
  esac
  case "${r}" in
    */*) printf '%s' "${r%%/*}" ;;
    *) return 1 ;;
  esac
}

owner=""

# 1. -R / --repo
want_repo=""
for a in "$@"; do
  if [ -n "${want_repo}" ]; then
    owner="$(owner_of "${a}")" || owner=""
    break
  fi
  case "${a}" in
    -R | --repo) want_repo=1 ;;
    --repo=*) owner="$(owner_of "${a#--repo=}")" || owner="" && break ;;
    -R?*) owner="$(owner_of "${a#-R}")" || owner="" && break ;;
    --) break ;;
  esac
done

# 2. GH_REPO
if [ -z "${owner}" ] && [ -n "${GH_REPO:-}" ]; then
  owner="$(owner_of "${GH_REPO}")" || owner=""
fi

# 3. gh repo <サブコマンド> <owner>/<repo>、gh api repos/<owner>/...
if [ -z "${owner}" ] && [ $# -ge 3 ] && [ "$1" = repo ]; then
  case "$3" in
    -*) ;;
    */*) owner="$(owner_of "$3")" || owner="" ;;
  esac
fi
if [ -z "${owner}" ] && [ $# -ge 2 ] && [ "$1" = api ]; then
  for a in "$@"; do
    case "${a}" in
      repos/*/* | /repos/*/*)
        a="${a#/}"
        a="${a#repos/}"
        owner="${a%%/*}"
        break
        ;;
    esac
  done
fi

# 4. 今いる git リポジトリの origin
if [ -z "${owner}" ]; then
  url="$(git remote get-url origin 2>/dev/null)" || url=""
  if [ -n "${url}" ]; then
    owner="$(owner_of "${url}")" || owner=""
  fi
fi

# 5. トークンが 1 つだけ
if [ -z "${owner}" ]; then
  owners="$(agent-env-github-token list 2>/dev/null)" || owners=""
  if [ -n "${owners}" ] && [ "$(printf '%s\n' "${owners}" | wc -l)" -eq 1 ]; then
    owner="${owners}"
  fi
fi

if [ -n "${owner}" ] && token="$(agent-env-github-token get "${owner}" 2>/dev/null)"; then
  GH_TOKEN="${token}"
  export GH_TOKEN
fi
exec "${real}" "$@"

#!/bin/sh
# gh のラッパー。操作対象のリポジトリの持ち主を判断し、その持ち主のトークン（agent-env-github-token）を
# GH_TOKEN に設定して /usr/bin/gh を実行する。bootstrap.sh が /usr/local/bin/gh に配置する。
# 持ち主は次の順に判断する（-R / --repo を指定した場合は、それだけで判断する）。
#   1. -R / --repo の値
#   2. 環境変数 GH_REPO
#   3. gh repo <サブコマンド> <owner>/<repo>、gh repo list <owner> の引数、gh api の repos/<owner>/... のパス
#      （gh api の {owner} のようなプレースホルダーは、次の 4 で解決する）
#   4. 今いる git リポジトリのリモート。gh repo set-default の設定があればそのリポジトリ、
#      無ければ gh と同じく upstream、github、origin の順
#   5. トークンが 1 つしか無ければ、その持ち主
# トークンが見つからない場合は、gh に保存済みの認証情報（以前の gh auth login など）も使わせない。
# 別の持ち主のトークンや古い認証情報が使われないようにするため。
# GH_TOKEN か GITHUB_TOKEN が設定済みの場合は、そのまま gh を実行する。
set -eu

real=/usr/bin/gh

if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  exec "${real}" "$@"
fi

# gh の認証情報を保存する操作は、この仕組みを迂回するので使わせない
case "${1:-} ${2:-}" in
  "auth login" | "auth setup-git" | "auth refresh" | "auth switch")
    echo "agent-env: gh auth ${2} は使えません。トークンは agent-env-github-token set <持ち主> で保存してください" >&2
    exit 1
    ;;
esac

# OWNER/REPO、github.com/OWNER/REPO、github.com の URL から持ち主を取り出す。それ以外は失敗
owner_of() {
  r="$1"
  case "${r}" in
    https://github.com/*) r="${r#https://github.com/}" ;;
    git@github.com:*) r="${r#git@github.com:}" ;;
    ssh://git@github.com/*) r="${r#ssh://git@github.com/}" ;;
    github.com/*) r="${r#github.com/}" ;;
    *://* | *@*:*) return 1 ;; # github.com 以外の URL
  esac
  case "${r}" in
    */*/*) return 1 ;; # github.com 以外のホスト（HOST/OWNER/REPO）
    ?*/?*) printf '%s' "${r%%/*}" ;;
    *) return 1 ;;
  esac
}

owner=""

# 1. -R / --repo（指定した場合は、ほかの方法で推測しない）
explicit=""
repo_arg=""
want_repo=""
for a in "$@"; do
  if [ -n "${want_repo}" ]; then
    explicit=1
    repo_arg="${a}"
    break
  fi
  case "${a}" in
    -R | --repo) want_repo=1 ;;
    --repo=*) explicit=1 && repo_arg="${a#--repo=}" && break ;;
    -R?*) explicit=1 && repo_arg="${a#-R}" && break ;;
    --) break ;;
  esac
done
if [ -n "${explicit}" ]; then
  owner="$(owner_of "${repo_arg}")" || owner=""
else
  # 2. GH_REPO
  if [ -n "${GH_REPO:-}" ]; then
    owner="$(owner_of "${GH_REPO}")" || owner=""
  fi

  # 3. gh repo <サブコマンド> <owner>/<repo>、gh repo list <owner>、gh api repos/<owner>/...
  if [ -z "${owner}" ] && [ $# -ge 3 ] && [ "$1" = repo ]; then
    case "$2 $3" in
      *" -"* | *"{"*) ;;
      "list "* | "ls "*) owner="$3" ;;
      *" "*/*) owner="$(owner_of "$3")" || owner="" ;;
    esac
  fi
  if [ -z "${owner}" ] && [ $# -ge 2 ] && [ "$1" = api ]; then
    for a in "$@"; do
      case "${a}" in
        repos/*/* | /repos/*/*)
          a="${a#/}"
          a="${a#repos/}"
          a="${a%%/*}"
          case "${a}" in
            *"{"*) ;; # {owner} などのプレースホルダー
            *) owner="${a}" ;;
          esac
          break
          ;;
      esac
    done
  fi

  # 4. 今いる git リポジトリのリモート
  if [ -z "${owner}" ] && git rev-parse --git-dir > /dev/null 2>&1; then
    # gh repo set-default は remote.<名前>.gh-resolved に base（そのリモート）か <owner>/<repo> を書く
    resolved="$(git config --get-regexp '^remote\..*\.gh-resolved$' 2>/dev/null | head -n 1)" || resolved=""
    if [ -n "${resolved}" ]; then
      key="${resolved%% *}"
      value="${resolved#* }"
      if [ "${value}" = base ]; then
        remote="${key#remote.}"
        remote="${remote%.gh-resolved}"
        url="$(git remote get-url "${remote}" 2>/dev/null)" || url=""
        owner="$(owner_of "${url}")" || owner=""
      else
        owner="$(owner_of "${value}")" || owner=""
      fi
    else
      for remote in upstream github origin; do
        url="$(git remote get-url "${remote}" 2>/dev/null)" || continue
        owner="$(owner_of "${url}")" || owner=""
        break
      done
    fi
  fi

  # 5. トークンが 1 つだけ
  if [ -z "${owner}" ]; then
    owners="$(agent-env-github-token list 2>/dev/null)" || owners=""
    case "${owners}" in
      '' | *"
"*) ;; # 無い、または複数
      *) owner="${owners}" ;;
    esac
  fi
fi

if [ -n "${owner}" ] && token="$(agent-env-github-token get "${owner}" 2>/dev/null)"; then
  GH_TOKEN="${token}"
  export GH_TOKEN
  exec "${real}" "$@"
fi

# トークンが無い: 保存済みの認証情報が無い、空の設定ディレクトリで実行する
echo "agent-env: ${owner:-操作対象の持ち主がわからないため、}${owner:+ の }GitHub のトークンを使いません。agent-env-github-token set <持ち主> で保存してください" >&2
noauth="${XDG_STATE_HOME:-${HOME}/.local/state}/agent-env/gh-noauth"
mkdir -p "${noauth}"
GH_CONFIG_DIR="${noauth}"
export GH_CONFIG_DIR
exec "${real}" "$@"

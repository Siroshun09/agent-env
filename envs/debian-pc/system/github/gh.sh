#!/bin/sh
# gh のラッパー。操作対象のリポジトリの持ち主を判断し、その持ち主のトークン（agent-env-github-token）を
# GH_TOKEN に設定して /usr/bin/gh を実行する。bootstrap.sh が /usr/local/bin/gh に配置する。
# 持ち主は次の順に判断する（-R / --repo を指定した場合は、それだけで判断する）。
#   1. -R / --repo の値
#   2. gh repo <サブコマンド> <owner>/<repo>、gh repo list <owner> の引数、gh api の repos/<owner>/... と
#      orgs/<owner>/... のパス（オプションとその値は飛ばす。{owner} のようなプレースホルダーは 4 以降で解決する）
#   3. 環境変数 GH_REPO
#   4. 今いる git リポジトリのリモート。gh repo set-default の設定があればそのリポジトリ、
#      無ければ gh と同じく upstream、github、origin、その他のリモートの順で、github.com を指す最初のもの
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

# 値を取るオプション（gh repo と gh api のもの）。引数の位置を数えるときに、その値を飛ばす
takes_value() {
  case "$1" in
    -L | --limit | -l | --language | --topic | --visibility | --json | -q | --jq | -t | --template | \
      -b | --branch | -u | --upstream-remote-name | --remote-name | --org | --source | --remote | \
      -d | --description | -h | --homepage | -g | --gitignore | --license | -p | --default-branch | \
      --add-topic | --remove-topic | -X | --method | -F | --field | -f | --raw-field | -H | --header | \
      --input | --cache | --preview | --hostname) return 0 ;;
  esac
  return 1
}

# $1 個のコマンド名を飛ばし、オプションとその値を除いた最初の引数を出力する。無ければ失敗
first_arg() {
  n="$1"
  shift
  shift "${n}"
  skip=""
  for a in "$@"; do
    if [ -n "${skip}" ]; then
      skip=""
      continue
    fi
    case "${a}" in
      --) return 1 ;; # gh repo clone の git に渡す引数など
      -*) takes_value "${a}" && skip=1 ;; # --limit=10 のような形は値を含むので飛ばさない
      *) printf '%s' "${a}" && return 0 ;;
    esac
  done
  return 1
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
  # 2. gh repo <サブコマンド> <owner>/<repo>、gh repo list <owner>、gh api repos/<owner>/... と orgs/<owner>/...
  if [ "${1:-}" = repo ] && [ $# -ge 3 ] && arg="$(first_arg 2 "$@")"; then
    case "$2 ${arg}" in
      *"{"*) ;;
      "list "* | "ls "*)
        case "${arg}" in
          *[!A-Za-z0-9-]*) ;;
          *) owner="${arg}" ;;
        esac
        ;;
      *) owner="$(owner_of "${arg}")" || owner="" ;;
    esac
  elif [ "${1:-}" = api ] && arg="$(first_arg 1 "$@")"; then
    arg="${arg#/}"
    case "${arg}" in
      repos/?*/* | orgs/?*)
        arg="${arg#*/}"
        arg="${arg%%/*}"
        case "${arg}" in
          *"{"*) ;; # {owner} などのプレースホルダー
          *) owner="${arg}" ;;
        esac
        ;;
    esac
  fi

  # 3. GH_REPO（明示的な操作対象が無い場合だけ）
  if [ -z "${owner}" ] && [ -n "${GH_REPO:-}" ]; then
    owner="$(owner_of "${GH_REPO}")" || owner=""
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
    fi
    if [ -z "${owner}" ]; then
      # shellcheck disable=SC2046 # リモート名は空白を含まない
      for remote in upstream github origin $(git remote 2>/dev/null); do
        url="$(git remote get-url "${remote}" 2>/dev/null)" || continue
        owner="$(owner_of "${url}")" && break
        owner=""
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

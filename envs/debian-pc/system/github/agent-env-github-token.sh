#!/bin/sh
# GitHub のトークン（fine-grained PAT）を、持ち主（ユーザーまたは org）ごとに保存・取得する。
# fine-grained PAT は 1 枚で 1 つの持ち主のリポジトリにしか使えないため、持ち主ごとに分けて置く。
# bootstrap.sh が /usr/local/bin/agent-env-github-token に配置する。git（git-credential-agent-env）と gh（ラッパー）が使う。
#
#   agent-env-github-token set <owner>     標準入力のトークンを保存する
#   agent-env-github-token get <owner>     トークンを出力する（無ければ終了コード 1）
#   agent-env-github-token list            トークンを保存済みの持ち主を一覧する
#   agent-env-github-token remove <owner>  トークンを削除する
set -eu

dir="${XDG_CONFIG_HOME:-${HOME}/.config}/agent-env/github-tokens"

usage() {
  sed -n 's/^#   //p' "$0" >&2
  exit 2
}

# 持ち主のトークンのファイル。GitHub の持ち主の名前は大文字・小文字を区別しないので小文字にそろえる
token_file() {
  case "$1" in
    '' | -* | *[!A-Za-z0-9-]*)
      echo "agent-env-github-token: 持ち主の名前が不正です: '$1'" >&2
      exit 2
      ;;
  esac
  printf '%s/%s' "${dir}" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
}

[ $# -ge 1 ] || usage
case "$1" in
  get)
    [ $# -eq 2 ] || usage
    file="$(token_file "$2")"
    [ -r "${file}" ] || exit 1
    token="$(tr -d '[:space:]' < "${file}")"
    [ -n "${token}" ] || exit 1
    printf '%s\n' "${token}"
    ;;
  set)
    [ $# -eq 2 ] || usage
    file="$(token_file "$2")"
    [ -t 0 ] && echo "$2 のトークンを貼り付け、Enter と Ctrl+D を押してください" >&2
    token="$(tr -d '[:space:]')"
    if [ -z "${token}" ]; then
      echo "agent-env-github-token: トークンが空です" >&2
      exit 1
    fi
    umask 077
    mkdir -p "${dir}"
    chmod 700 "${dir}"
    printf '%s\n' "${token}" > "${file}.tmp"
    mv -f "${file}.tmp" "${file}"
    echo "保存しました: ${file}" >&2
    ;;
  list)
    [ $# -eq 1 ] || usage
    [ -d "${dir}" ] || exit 0
    find "${dir}" -mindepth 1 -maxdepth 1 -type f ! -name '*.tmp' -printf '%f\n' | sort
    ;;
  remove)
    [ $# -eq 2 ] || usage
    rm -f "$(token_file "$2")"
    ;;
  *)
    usage
    ;;
esac

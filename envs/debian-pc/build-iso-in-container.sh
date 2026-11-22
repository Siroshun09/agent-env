#!/usr/bin/env bash
# build-iso.sh を使い捨ての Debian コンテナ内で実行し、macOS では続けて write-usb.sh で USB メモリに書き込む。
# ホストに xorriso などを入れずに済む。ランタイムは container（Apple 純正, macOS 26+）, docker, podman の順に探す。
#
# 使い方: envs/debian-pc/build-iso-in-container.sh [--ssh-key ~/.ssh/id_ed25519.pub] [--no-write]
#   --ssh-key   省略時は ~/.ssh/id_ed25519.pub, id_ecdsa.pub, id_rsa.pub の順に探す
#   --no-write  USB メモリに書き込まない
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ENV_DIR}/../.." && pwd)"

die() { echo "エラー: $*" >&2; exit 1; }

SSH_KEY=""
WRITE_USB=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --no-write) WRITE_USB=0; shift ;;
    *) die "不明な引数: $1" ;;
  esac
done
if [[ -z "${SSH_KEY}" ]]; then
  for k in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
    [[ -f "${HOME}/.ssh/${k}" ]] && { SSH_KEY="${HOME}/.ssh/${k}"; break; }
  done
  [[ -n "${SSH_KEY}" ]] || die "SSH 公開鍵が見つかりません。--ssh-key で指定してください"
fi
[[ -f "${SSH_KEY}" ]] || die "公開鍵が見つかりません: ${SSH_KEY}"
echo "SSH 公開鍵: ${SSH_KEY}"

RUNTIME=""
for r in container docker podman; do
  command -v "$r" >/dev/null 2>&1 && { RUNTIME="$r"; break; }
done
[[ -n "${RUNTIME}" ]] || die "container（Apple）, docker, podman のいずれかが必要です"
if [[ "${RUNTIME}" == container ]]; then
  container list >/dev/null 2>&1 || die "container system start を実行してから再度お試しください"
fi
echo "コンテナランタイム: ${RUNTIME}"

TTY=()
[[ -t 0 && -t 1 ]] && TTY=(-t)

# - 公開鍵はホストのファイルなので、中身を環境変数で渡してコンテナ内で書き出す
#   （ランタイム間の差を避けるため、マウントはディレクトリ1つだけにしている）
# - ISO のダウンロードキャッシュは out/cache（.gitignore 済み）に置き、次回以降も使い回す
# - GIT_OPTIONAL_LOCKS=0: git status がホストの .git/index を書き換えないようにする
# shellcheck disable=SC2016 # コンテナ内で展開させるため単一引用符で渡す
"${RUNTIME}" run --rm ${TTY[@]+"${TTY[@]}"} \
  -v "${REPO_ROOT}:/work" \
  -e XDG_CACHE_HOME=/work/out/cache \
  -e GIT_OPTIONAL_LOCKS=0 \
  -e SSH_KEY_CONTENT="$(cat "${SSH_KEY}")" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  docker.io/library/debian:trixie bash -euo pipefail -c '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git xorriso cpio gzip openssl >/dev/null
    git config --global --add safe.directory /work
    printf "%s\n" "${SSH_KEY_CONTENT}" > /tmp/ssh-key.pub
    # 終了時に生成物の所有者をホストのユーザーに戻す（Linux ホスト向け）
    trap "chown -R \"\${HOST_UID}:\${HOST_GID}\" /work/out 2>/dev/null || true" EXIT
    /work/envs/debian-pc/build-iso.sh --ssh-key /tmp/ssh-key.pub
  '

if [[ "${WRITE_USB}" -eq 1 && "$(uname -s)" == Darwin && -t 0 ]]; then
  echo
  "${ENV_DIR}/write-usb.sh"
fi

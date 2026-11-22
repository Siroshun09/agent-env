#!/usr/bin/env bash
# build-iso.sh を使い捨ての Debian コンテナ内で実行する。ホスト（macOS 等）には xorriso などを入れずに済む。
# 使うランタイム（見つかった順）: container（Apple 純正, macOS 26+）, docker, podman
#   AGENT_ENV_CONTAINER_RUNTIME で明示できる。
#
# 使い方: envs/debian-pc/build-iso-in-container.sh [build-iso.sh の引数...]
#   例: envs/debian-pc/build-iso-in-container.sh --ssh-key ~/.ssh/id_ed25519.pub
#   AGENT_ENV_CONTAINER_ARGS で run に引数を追加できる（プロキシ設定など）。
#
# ランタイム間の差を避けるため、使うのは --rm / -t / -e / -v <ディレクトリ>:<パス> だけにしている。
# （単一ファイルのマウントや名前付きボリュームは使わない）
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ENV_DIR}/../.." && pwd)"
IMAGE="docker.io/library/debian:trixie"

die() { echo "エラー: $*" >&2; exit 1; }

RUNTIME="${AGENT_ENV_CONTAINER_RUNTIME:-}"
if [[ -z "${RUNTIME}" ]]; then
  for r in container docker podman; do
    command -v "$r" >/dev/null 2>&1 && { RUNTIME="$r"; break; }
  done
fi
[[ -n "${RUNTIME}" ]] || die "container（Apple）, docker, podman のいずれかが必要です"
if [[ "${RUNTIME}" == container ]]; then
  container list >/dev/null 2>&1 || die "container system start を実行してから再度お試しください"
fi
echo "コンテナランタイム: ${RUNTIME}"

# --ssh-key はホストのファイルなので、中身を環境変数で渡してコンテナ内で書き出す
ARGS=()
SSH_KEY_CONTENT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key)
      [[ -f "$2" ]] || die "公開鍵が見つかりません: $2"
      SSH_KEY_CONTENT="$(cat "$2")"
      ARGS+=(--ssh-key /tmp/ssh-key.pub); shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

TTY=()
[[ -t 0 && -t 1 ]] && TTY=(-t)

# - ISO のダウンロードキャッシュは out/cache（.gitignore 済み）に置き、次回以降も使い回す
# - GIT_OPTIONAL_LOCKS=0: git status がホストの .git/index を書き換えないようにする
# shellcheck disable=SC2086
exec "${RUNTIME}" run --rm ${TTY[@]+"${TTY[@]}"} \
  -v "${REPO_ROOT}:/work" \
  -e XDG_CACHE_HOME=/work/out/cache \
  -e GIT_OPTIONAL_LOCKS=0 \
  -e SSH_KEY_CONTENT="${SSH_KEY_CONTENT}" \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  ${AGENT_ENV_CONTAINER_ARGS:-} \
  "${IMAGE}" bash -euo pipefail -c '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git xorriso cpio gzip >/dev/null
    git config --global --add safe.directory /work
    [ -z "${SSH_KEY_CONTENT}" ] || printf "%s\n" "${SSH_KEY_CONTENT}" > /tmp/ssh-key.pub
    # 終了時に生成物の所有者をホストのユーザーに戻す（Linux ホスト向け。macOS では不要）
    trap "chown -R \"\${HOST_UID}:\${HOST_GID}\" /work/out 2>/dev/null || true" EXIT
    /work/envs/debian-pc/build-iso.sh "$@"
  ' build-iso ${ARGS[@]+"${ARGS[@]}"}

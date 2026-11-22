#!/usr/bin/env bash
# build-iso.sh を使い捨ての Debian コンテナ内で実行する。ホスト（macOS 等）には xorriso などを入れずに済む。
# 必要なもの: docker または podman（Docker Desktop, OrbStack, Podman Desktop など）
#
# 使い方: envs/debian-pc/build-iso-in-container.sh [build-iso.sh の引数...]
#   例: envs/debian-pc/build-iso-in-container.sh --ssh-key ~/.ssh/id_ed25519.pub
#   AGENT_ENV_CONTAINER_ARGS 環境変数で docker run に引数を追加できる（プロキシ設定など）。
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ENV_DIR}/../.." && pwd)"
IMAGE="docker.io/library/debian:trixie"
# ダウンロードした Debian ISO をコンテナ間で使い回すためのボリューム
CACHE_VOLUME="agent-env-cache"

die() { echo "エラー: $*" >&2; exit 1; }

if command -v docker >/dev/null 2>&1; then RUNTIME=docker
elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
else die "docker か podman が必要です"; fi

# --ssh-key はホストのパスなので、コンテナ内から読めるようにマウントして差し替える
ARGS=()
MOUNTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ssh-key)
      [[ -f "$2" ]] || die "公開鍵が見つかりません: $2"
      MOUNTS+=(-v "$(cd "$(dirname "$2")" && pwd)/$(basename "$2"):/tmp/ssh-key.pub:ro")
      ARGS+=(--ssh-key /tmp/ssh-key.pub); shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

TTY=()
[[ -t 0 && -t 1 ]] && TTY=(-t)

# GIT_OPTIONAL_LOCKS=0: git status がホストの .git/index を root 所有で書き換えないようにする
# shellcheck disable=SC2086
exec "${RUNTIME}" run --rm ${TTY[@]+"${TTY[@]}"} \
  -v "${REPO_ROOT}:/work" \
  -v "${CACHE_VOLUME}:/root/.cache/agent-env" \
  ${MOUNTS[@]+"${MOUNTS[@]}"} \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" -e GIT_OPTIONAL_LOCKS=0 \
  ${AGENT_ENV_CONTAINER_ARGS:-} \
  "${IMAGE}" bash -euo pipefail -c '
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      ca-certificates curl git xorriso cpio gzip >/dev/null
    git config --global --add safe.directory /work
    # 終了時に生成物の所有者をホストのユーザーに戻す
    trap "chown -R \"\${HOST_UID}:\${HOST_GID}\" /work/out 2>/dev/null || true" EXIT
    /work/envs/debian-pc/build-iso.sh "$@"
  ' build-iso ${ARGS[@]+"${ARGS[@]}"}

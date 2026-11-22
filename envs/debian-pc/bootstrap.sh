#!/usr/bin/env bash
# Debian 13 (trixie) の実 PC をエージェント専用ホストに仕立てる。冪等なので何度実行してもよい。
# 使い方: sudo envs/debian-pc/bootstrap.sh   （preseed の late_command からも呼ぶ）
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ENV_DIR}/../.." && pwd)"
AGENT_USER="${AGENT_USER:-agent}"

log() { printf '\n==> %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "root で実行してください" >&2; exit 1; }

log "apt パッケージ"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
# コメント・空行を除いて packages.txt を読む
mapfile -t PKGS < <(sed -e 's/#.*//' -e '/^\s*$/d' "${ENV_DIR}/packages.txt")
apt-get install -y -q --no-install-recommends "${PKGS[@]}"

log "mise"
# apt の公式リポジトリから入れると更新・削除が apt で管理できる
if ! command -v mise >/dev/null 2>&1; then
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor --yes -o /etc/apt/keyrings/mise.gpg
  echo "deb [signed-by=/etc/apt/keyrings/mise.gpg arch=$(dpkg --print-architecture)] https://mise.jdx.dev/deb stable main" \
    > /etc/apt/sources.list.d/mise.list
  apt-get update -q
  apt-get install -y -q mise
fi

log "エージェント用ユーザー: ${AGENT_USER}"
if ! id "${AGENT_USER}" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "${AGENT_USER}"
fi
# sudo は付与しない。root が必要な変更はこのスクリプトに書く。

# rootless podman 用の subuid/subgid。uidmap があれば useradd が割り当てるが、
# uidmap より先にユーザーを作った場合などに備えて、無ければ既存範囲の後ろに追加する。
for f in /etc/subuid /etc/subgid; do
  touch "$f"
  if ! grep -q "^${AGENT_USER}:" "$f"; then
    start="$(awk -F: 'BEGIN { m = 100000 } { e = $2 + $3; if (e > m) m = e } END { print m }' "$f")"
    echo "${AGENT_USER}:${start}:65536" >> "$f"
  fi
done

log "自動更新"
# セキュリティ更新は unattended-upgrades、このリポジトリの変更は agent-env-update.timer（毎日）で反映する
install -m 0644 "${ENV_DIR}/system/apt/52agent-env-unattended-upgrades" /etc/apt/apt.conf.d/
if command -v systemctl >/dev/null 2>&1; then
  install -m 0644 "${ENV_DIR}/system/agent-env-update.service" "${ENV_DIR}/system/agent-env-update.timer" \
    /etc/systemd/system/
  if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable --now agent-env-update.timer
  else
    systemctl enable agent-env-update.timer # chroot 等、systemd が動いていない場合
  fi
fi

# ここから先は OS 非依存（エージェント用ユーザー権限）
runuser -l "${AGENT_USER}" -c "bash '${REPO_ROOT}/shared/setup-user.sh'"

#!/bin/sh
# Debian インストーラの partman/early_command から実行される（busybox sh）。
# インストール先ディスクを一覧から選ばせ、partman-auto/disk に設定する。
# 取り違え防止のため、ディスクが1台でも必ず確認する。インストールメディア自身は候補から外す。
set -eu
# shellcheck source=/dev/null
. /usr/share/debconf/confmodule

# インストールメディア（/cdrom をマウントしているデバイス）のディスク名
media_disk=""
media_part="$(awk '$2 == "/cdrom" { print $1 }' /proc/mounts | head -n 1)"
if [ -n "${media_part}" ] && [ -e "/sys/class/block/${media_part#/dev/}" ]; then
  media_disk="$(basename "$(readlink -f "/sys/class/block/${media_part#/dev/}/..")")"
  # パーティションでなくディスク自体をマウントしている場合
  [ "${media_disk}" = block ] && media_disk="${media_part#/dev/}"
fi

choices=""
for dev in $(list-devices disk); do
  name="${dev#/dev/}"
  [ "${name}" = "${media_disk}" ] && continue
  sectors="$(cat "/sys/class/block/${name}/size" 2>/dev/null || echo 0)"
  size_gb=$((sectors * 512 / 1000000000))
  model="$( { tr -s ' ,' ' ' < "/sys/class/block/${name}/device/model"; } 2>/dev/null || true)"
  choices="${choices}${choices:+, }${dev}  ${size_gb} GB  ${model}"
done
[ -n "${choices}" ] || { logger -t agent-env "インストール先のディスクが見つかりません"; exit 1; }

cat > /tmp/agent-env.templates <<EOF
Template: agent-env/disk
Type: select
Choices: ${choices}
Description: Install target disk (ALL DATA ON IT WILL BE ERASED)
 Select the disk to install Debian on. Every partition on the selected disk
 will be deleted. The installation media is not listed.
EOF
debconf-loadtemplate agent-env /tmp/agent-env.templates

db_fset agent-env/disk seen false
db_input critical agent-env/disk || true
db_go || exit 1
db_get agent-env/disk
disk="${RET%% *}"
logger -t agent-env "install target: ${disk}"
db_set partman-auto/disk "${disk}"

#!/bin/sh
# Debian インストーラの partman/early_command から実行される（busybox sh）。
# インストール先ディスクを一覧から選ばせ、確認（既定は No）を経て partman-auto/disk に設定する。
# 取り違え防止のため:
#   - ディスクが1台でも必ず選択と確認を求める
#   - 容量・モデルに加えて接続方式・シリアル番号・リムーバブル属性を表示する
#   - インストールメディア自身は候補から外す。特定できなければ候補に残り得るので中断する
set -eu
# shellcheck source=/dev/null
. /usr/share/debconf/confmodule

fail() {
  logger -t agent-env "$*"
  echo "agent-env: $*" >&2
  exit 1
}

# インストールメディア（/cdrom をマウントしているデバイス）のディスク名
media_part="$(awk '$2 == "/cdrom" { print $1 }' /proc/mounts | head -n 1)"
if [ -z "${media_part}" ] || [ ! -e "/sys/class/block/${media_part#/dev/}" ]; then
  fail "インストールメディアを特定できません（/cdrom のマウント元: ${media_part:-なし}）"
fi
if [ -e "/sys/class/block/${media_part#/dev/}/partition" ]; then
  media_disk="$(basename "$(readlink -f "/sys/class/block/${media_part#/dev/}/..")")"
else
  media_disk="${media_part#/dev/}" # パーティションでなくディスク自体をマウントしている場合
fi
[ -e "/sys/block/${media_disk}" ] || fail "インストールメディアのディスクを特定できません: ${media_disk}"
logger -t agent-env "install media: /dev/${media_disk}"

# udev のプロパティ（無ければ空）
prop() { udevadm info --query=property --name="$1" 2>/dev/null | sed -n "s/^$2=//p" | head -n 1; }
# 選択肢の区切り（カンマ）と余分な空白を除く
clean() { tr -s ' ,\t' ' ' | sed 's/^ //; s/ $//'; }

describe() {
  name="${1#/dev/}"
  sectors="$(cat "/sys/block/${name}/size" 2>/dev/null || echo 0)"
  size_gb=$((sectors * 512 / 1000000000))
  model="$(prop "$1" ID_MODEL)"
  [ -n "${model}" ] || model="$(cat "/sys/block/${name}/device/model" 2>/dev/null || true)"
  bus="$(prop "$1" ID_BUS)"
  case "$(readlink -f "/sys/block/${name}")" in
    */usb*) bus=usb ;;
    */nvme*) bus=nvme ;;
    */virtio*) bus="${bus:-virtio}" ;;
  esac
  serial="$(prop "$1" ID_SERIAL_SHORT)"
  [ -n "${serial}" ] || serial="$(cat "/sys/block/${name}/device/serial" 2>/dev/null || true)"
  wwn="$(prop "$1" ID_WWN)"
  removable=""
  [ "$(cat "/sys/block/${name}/removable" 2>/dev/null || echo 0)" = 1 ] && removable="REMOVABLE"
  printf '%s  %s GB  %s  %s  %s%s  %s' "$1" "${size_gb}" "${bus:-?}" "${model:-?}" \
    "${serial:+SN:}${serial:-SN:?}" "${wwn:+  WWN:${wwn}}" "${removable}" | clean
}

choices=""
for dev in $(list-devices disk); do
  [ "${dev#/dev/}" = "${media_disk}" ] && continue
  choices="${choices}${choices:+, }$(describe "${dev}")"
done
[ -n "${choices}" ] || fail "インストール先のディスクが見つかりません"

cat > /tmp/agent-env.templates <<EOF
Template: agent-env/disk
Type: select
Choices: ${choices}
Description: Install target disk (ALL DATA ON IT WILL BE ERASED)
 Select the disk to install Debian on. Every partition on the selected disk
 will be deleted. The installation media (/dev/${media_disk}) is not listed.
 .
 Format: device size bus model serial [WWN] [REMOVABLE]

Template: agent-env/confirm
Type: boolean
Default: false
Description: Really erase this disk?
 \${disk_desc}
 .
 ALL DATA ON THIS DISK WILL BE ERASED. Choose "No" to select another disk.
EOF
debconf-loadtemplate agent-env /tmp/agent-env.templates

# 確認で Yes を選ぶまで選択に戻る
while :; do
  db_fset agent-env/disk seen false
  db_input critical agent-env/disk || true
  db_go || exit 1
  db_get agent-env/disk
  disk_desc="${RET}"
  disk="${disk_desc%% *}"
  [ -b "${disk}" ] || fail "選択されたディスクが存在しません: ${disk}"

  db_set agent-env/confirm false
  db_fset agent-env/confirm seen false
  db_subst agent-env/confirm disk_desc "${disk_desc}"
  db_input critical agent-env/confirm || true
  db_go || exit 1
  db_get agent-env/confirm
  [ "${RET}" = true ] && break
done

logger -t agent-env "install target: ${disk_desc}"
db_set partman-auto/disk "${disk}"
# ブートローダーも同じディスクに入れる（default のままだと BIOS では別のディスクが選ばれ得る）
db_set grub-installer/bootdev "${disk}"
db_fset grub-installer/bootdev seen true

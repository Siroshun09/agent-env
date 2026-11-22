#!/usr/bin/env bash
# 生成した ISO を USB メモリに書き込む（macOS 専用。build-iso-in-container.sh の最後に自動で実行される）。
# 使い方: envs/debian-pc/write-usb.sh [out/agent-env-debian-pc.iso]
# 取り違え防止のため:
#   - 候補は外付けの物理ディスク（diskutil の external, physical）だけ。内蔵ディスクは表示しない
#   - 容量・名前・接続方式を表示し、書き込み先のディスク名（例: disk4）を入力させ、さらに「ERASE disk4」と入力させる
#   - 書き込み直前にディスクの情報を取り直し、一覧を表示したときと同じディスクであることを確認する
#   - 書き込み後に読み戻して ISO と一致することを確認する
# 書き込みには sudo（管理者パスワード）が必要。
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="${1:-${ENV_DIR}/../../out/agent-env-debian-pc.iso}"

die() { echo "エラー: $*" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || die "macOS 専用です"
[[ -f "${ISO}" ]] || die "ISO がありません: ${ISO}"
[[ -t 0 ]] || die "対話端末から実行してください"

iso_size="$(stat -f %z "${ISO}")"
(( iso_size > 0 )) || die "ISO が空です"

# diskutil info の値（plist から取り出す）
info() { diskutil info -plist "$1" | plutil -extract "$2" raw -o - - 2>/dev/null || true; }
# ディスクの識別情報（一覧表示時と書き込み直前で比較する）
identity() { printf '%s|%s|%s|%s' "$(info "$1" Internal)" "$(info "$1" TotalSize)" "$(info "$1" BusProtocol)" "$(info "$1" MediaName)"; }
external_disks() { diskutil list external physical | awk '/^\/dev\/disk[0-9]+/ { sub("/dev/", "", $1); print $1 }'; }

while :; do
  disks=()
  while IFS= read -r d; do
    [[ -n "$d" && "$(info "$d" Internal)" == false ]] && disks+=("$d")
  done < <(external_disks)
  if [[ ${#disks[@]} -gt 0 ]]; then break; fi
  read -r -p "外付けディスクが見つかりません。USB メモリを挿して Enter（中止は Ctrl-C）: " _ || exit 1
done

echo
echo "書き込み先の候補（外付けの物理ディスクのみ。書き込むとディスク全体が消去されます）:"
ids=()
for d in "${disks[@]}"; do
  ids+=("$(identity "$d")")
  size="$(info "$d" TotalSize)"
  printf '  %-8s %6s GB  %-6s %s\n' "$d" "$(( ${size:-0} / 1000000000 ))" \
    "$(info "$d" BusProtocol)" "$(info "$d" MediaName)"
done
echo "ISO: ${ISO} ($(( iso_size / 1000000 )) MB)"
echo
read -r -p "書き込み先のディスク名を入力（例: ${disks[0]}。空欄で中止）: " target || target=""
[[ -n "${target}" ]] || { echo "中止しました"; exit 1; }
want_id=""
for i in "${!disks[@]}"; do [[ "${disks[i]}" == "${target}" ]] && want_id="${ids[i]}"; done
[[ -n "${want_id}" ]] || die "${target} は候補にありません"
size="$(info "${target}" TotalSize)"
(( ${size:-0} >= iso_size )) || die "${target} の容量が ISO より小さいです"

echo
echo "書き込み先: ${target}  $(( size / 1000000000 )) GB  $(info "${target}" BusProtocol)  $(info "${target}" MediaName)"
read -r -p "このディスクの内容はすべて消去されます。よければ ERASE ${target} と入力: " answer || answer=""
[[ "${answer}" == "ERASE ${target}" ]] || { echo "中止しました（何も書き込んでいません）"; exit 1; }

diskutil unmountDisk "/dev/${target}"
# 一覧を表示してから抜き差しされていないか（同じ名前が別のディスクを指していないか）を書き込み直前に確認する
if ! external_disks | grep -x "${target}" > /dev/null || [[ "$(identity "${target}")" != "${want_id}" ]]; then
  die "${target} の情報が一覧を表示したときと変わりました（抜き差しされた可能性）。もう一度実行してください"
fi
echo "書き込んでいます（sudo のパスワードを求められます）"
# 書き込みは raw デバイス（rdisk）の方が速い。進捗は Ctrl-T で表示できる
sudo dd if="${ISO}" of="/dev/r${target}" bs=4m
sync

echo "書き込んだ内容を確認しています..."
diskutil unmountDisk "/dev/${target}" >/dev/null 2>&1 || true # 書き込み後に自動マウントされることがある
want="$(shasum -a 256 < "${ISO}" | cut -d' ' -f1)"
# raw デバイスはセクタ単位でしか読めないので 1 MiB 単位で読み、ISO のサイズに切り詰める
blocks=$(( (iso_size + 1048575) / 1048576 ))
got="$({ sudo dd if="/dev/r${target}" bs=1m count="${blocks}" 2>/dev/null || true; } |
  head -c "${iso_size}" | shasum -a 256 | cut -d' ' -f1)"
[[ "${want}" == "${got}" ]] || die "書き込んだ内容が ISO と一致しません。もう一度実行してください"

diskutil eject "/dev/${target}"
echo "完了: ${target} に書き込みました。USB メモリを抜いて PC に挿し、USB から起動してください。"

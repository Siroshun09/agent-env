#!/usr/bin/env bash
# 生成した ISO を USB メモリに書き込む（macOS 専用。build-iso-in-container.sh の最後に自動で実行される）。
# 使い方: envs/debian-pc/write-usb.sh [out/agent-env-debian-pc.iso]
# 取り違え防止のため:
#   - 候補は外付けの物理ディスク（diskutil の external, physical）だけ。内蔵ディスクは表示しない
#   - 容量・名前・接続方式を表示し、書き込み先のディスク名（例: disk4）を入力させる
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
for d in "${disks[@]}"; do
  size="$(info "$d" TotalSize)"
  printf '  %-8s %6s GB  %-6s %s\n' "$d" "$(( ${size:-0} / 1000000000 ))" \
    "$(info "$d" BusProtocol)" "$(info "$d" MediaName)"
done
echo "ISO: ${ISO} ($(( iso_size / 1000000 )) MB)"
echo
read -r -p "書き込み先のディスク名を入力（例: ${disks[0]}。空欄で中止）: " target || target=""
[[ -n "${target}" ]] || { echo "中止しました"; exit 1; }
found=0
for d in "${disks[@]}"; do [[ "$d" == "${target}" ]] && found=1; done
[[ ${found} -eq 1 ]] || die "${target} は候補にありません"
size="$(info "${target}" TotalSize)"
(( ${size:-0} >= iso_size )) || die "${target} の容量が ISO より小さいです"

echo "${target} を消去して書き込みます（sudo のパスワードを求められます）"
diskutil unmountDisk "/dev/${target}"
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

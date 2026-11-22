#!/usr/bin/env bash
# build-iso.sh で作った ISO の中身を検査する（CI・手元の両方で使う）。Linux / macOS で動く。
# 使い方: envs/debian-pc/verify-iso.sh [out/agent-env-debian-pc.iso]
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISO="${1:-${ENV_DIR}/../../out/agent-env-debian-pc.iso}"
[[ -f "${ISO}" ]] || { echo "ISO がありません: ${ISO}" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
fail() { echo "NG: $*" >&2; exit 1; }

xorriso -osirrox on -indev "${ISO}" \
  -extract /boot/grub/grub.cfg "${WORK}/grub.cfg" \
  -extract /isolinux/isolinux.cfg "${WORK}/isolinux.cfg" \
  -extract /install.amd/initrd.gz "${WORK}/initrd.gz" \
  -ls /agent-env 2>/dev/null > "${WORK}/files.txt"

for f in repo.bundle late-command.sh select-disk.sh build.env; do
  grep -q "'${f}'" "${WORK}/files.txt" || fail "/agent-env/${f} がありません"
done

# 起動メニュー: 自動インストールが既定で、どちらも自動では進まない
grep -q 'agent-env: Automated install' "${WORK}/grub.cfg" || fail "GRUB にエントリがありません"
grep -q '^set timeout=-1$' "${WORK}/grub.cfg" || fail "GRUB が無期限待機になっていません"
grep -qx 'timeout 0' "${WORK}/isolinux.cfg" || fail "isolinux が無期限待機になっていません"

# preseed: initrd に追加され、プレースホルダが埋まっている
gzip -dc "${WORK}/initrd.gz" 2>/dev/null > "${WORK}/initrd" || true
grep -aq 'partman/early_command string sh /cdrom/agent-env/select-disk.sh' "${WORK}/initrd" ||
  fail "preseed が initrd に入っていません"
grep -aq 'd-i passwd/user-password password [A-Za-z0-9]\{20\}$' "${WORK}/initrd" ||
  fail "パスワードが埋め込まれていません"
! grep -aq 'string @[A-Z_]*@\|password @[A-Z_]*@' "${WORK}/initrd" || fail "未置換のプレースホルダがあります"

echo "OK: ${ISO}"

#!/usr/bin/env bash
# 無人インストール用の Debian ISO を作る。root 不要。Linux / macOS で動く。
# 人間用ユーザー（owner、sudo あり）のパスワードはランダムに生成し、表示して out/ に保存する（ISO にはハッシュだけを入れる）。
# 公開鍵を登録し、SSH のパスワードログインは無効にする。インストール先ディスクはインストール時に選ぶ。
# ISO には HEAD のコミットを main として入れる。インストール後の apply.sh は GitHub の main からの
# fast-forward しか受け付けないので、本番用は GitHub の main と同じコミットから作ること。
#
# 使い方: envs/debian-pc/build-iso.sh --ssh-key ~/.ssh/id_ed25519.pub
# 必要なもの: git, curl, xorriso, cpio, gzip, openssl（passwd -6 対応のもの。macOS 標準の LibreSSL は不可）
#   macOS: brew install xorriso openssl（または build-iso-in-container.sh を使う）
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ENV_DIR}/../.." && pwd)"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-env"
OUT_DIR="${REPO_ROOT}/out"
OUT_ISO="${OUT_DIR}/agent-env-debian-pc.iso"
OUT_PASSWORD="${OUT_DIR}/agent-env-debian-pc.password"

die() { echo "エラー: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

[[ $# -eq 2 && "$1" == --ssh-key ]] || die "使い方: $0 --ssh-key <公開鍵>"
SSH_KEY="$2"
[[ -f "${SSH_KEY}" ]] || die "公開鍵が見つかりません: ${SSH_KEY}"
! grep -q "PRIVATE KEY" "${SSH_KEY}" || die "秘密鍵が指定されています。.pub を指定してください"
for cmd in git curl xorriso cpio gzip openssl; do
  command -v "${cmd}" >/dev/null || die "${cmd} が必要です"
done
openssl passwd -6 -salt agentenv x >/dev/null 2>&1 ||
  die "この openssl は passwd -6 に対応していません（macOS: brew install openssl で入る openssl を PATH の先頭に置く）"

# shellcheck source=/dev/null
. "${ENV_DIR}/iso.conf"

log "リポジトリの状態確認"
cd "${REPO_ROOT}"
[[ -z "$(git status --porcelain)" ]] || die "未コミットの変更があります。ISO には commit 済みの内容しか入りません"
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || die "shallow clone では作れません。git fetch --unshallow してください"
git log -1 --format='%h %s'

log "Debian ISO ${DEBIAN_ISO_VERSION}"
mkdir -p "${CACHE_DIR}"
BASE_ISO="${CACHE_DIR}/${DEBIAN_ISO_NAME}"
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
verify() { [[ "$(sha256 "${BASE_ISO}")" == "${DEBIAN_ISO_SHA256}" ]]; }
if ! { [[ -f "${BASE_ISO}" ]] && verify; }; then
  # 最新版は current/、古くなったら archive/ に移る
  for url in \
    "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/${DEBIAN_ISO_NAME}" \
    "https://cdimage.debian.org/cdimage/archive/${DEBIAN_ISO_VERSION}/amd64/iso-cd/${DEBIAN_ISO_NAME}"; do
    curl -fL --progress-bar -o "${BASE_ISO}.part" "${url}" && mv "${BASE_ISO}.part" "${BASE_ISO}" && break
  done
  [[ -f "${BASE_ISO}" ]] || die "ISO をダウンロードできませんでした"
  verify || { rm -f "${BASE_ISO}"; die "ISO の SHA256 が一致しません"; }
fi

log "パスワード生成"
# 記号を避けて入力しやすくする（英数字 20 文字 ≒ 119 bit）
# （tr | head だと SIGPIPE で pipefail に引っかかるので、有限の入力から切り出す）
PASSWORD="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c 1-20)"
[[ ${#PASSWORD} -eq 20 ]] || die "パスワードを生成できませんでした"
# ISO には SHA-512 crypt のハッシュだけを入れる（平文は out/ のファイルと画面表示のみ）
PASSWORD_HASH="$(printf '%s' "${PASSWORD}" | openssl passwd -6 -stdin)"
[[ "${PASSWORD_HASH}" =~ ^\$6\$[./A-Za-z0-9]+\$[./A-Za-z0-9]{86}$ ]] || die "パスワードのハッシュを生成できませんでした"

log "ISO の組み立て"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/initrd" "${WORK}/extra"

# preseed: プレースホルダを埋めて initrd に入れる（/preseed.cfg は自動で読まれる）
sed -e "s|@PASSWORD_HASH@|${PASSWORD_HASH}|g" \
  "${ENV_DIR}/preseed.cfg" > "${WORK}/initrd/preseed.cfg"
! grep -q '@[A-Z_]*@' "${WORK}/initrd/preseed.cfg" || die "preseed に未置換のプレースホルダがあります"

xorriso -osirrox on -indev "${BASE_ISO}" \
  -extract /install.amd/initrd.gz "${WORK}/initrd.gz" \
  -extract /boot/grub/grub.cfg "${WORK}/grub.cfg" \
  -extract /isolinux/isolinux.cfg "${WORK}/isolinux.cfg" 2>/dev/null
chmod u+w "${WORK}"/*.gz "${WORK}"/*.cfg
(cd "${WORK}/initrd" && echo preseed.cfg | cpio -H newc -o --quiet | gzip) >> "${WORK}/initrd.gz"

# 起動メニュー: 自動インストールを先頭・既定にする。
# ディスク全消去なので、USB を挿したままの再起動で再インストールされないよう自動選択（タイムアウト）はしない。
KERNEL_ARGS="auto=true priority=critical --- quiet"
# 既存の最初の menuentry の直前（テーマ設定の後）に差し込む
awk -v args="${KERNEL_ARGS}" '
  !done && /^menuentry/ {
    print "set default=0"
    print "set timeout=-1"
    print "menuentry \"agent-env: Automated install (ERASES DISK)\" {"
    print "    linux /install.amd/vmlinuz " args
    print "    initrd /install.amd/initrd.gz"
    print "}"
    done = 1
  }
  { print }' "${WORK}/grub.cfg" > "${WORK}/grub.cfg.new"
grep -q 'agent-env: Automated install' "${WORK}/grub.cfg.new" || die "grub.cfg の書き換えに失敗しました"
# isolinux（BIOS 起動）はこのエントリだけにする。timeout 0 は無期限待機
cat > "${WORK}/isolinux.cfg.new" <<EOF
default agentenv
prompt 0
timeout 0
ui vesamenu.c32
menu title agent-env
label agentenv
  menu label agent-env: Automated install (ERASES DISK)
  kernel /install.amd/vmlinuz
  append vga=788 initrd=/install.amd/initrd.gz ${KERNEL_ARGS}
EOF

# 安全確認: 後続の設定で上書きされず、自動では進まない（キー入力を待つ）こと
[[ "$(grep -E '^[[:space:]]*set timeout=' "${WORK}/grub.cfg.new" | tail -1)" == "set timeout=-1" ]] ||
  die "grub.cfg が無期限待機になっていません"

git bundle create "${WORK}/extra/repo.bundle" HEAD 2>/dev/null
cp "${ENV_DIR}/late-command.sh" "${ENV_DIR}/select-disk.sh" "${WORK}/extra/"
cp "${SSH_KEY}" "${WORK}/extra/authorized_keys"

mkdir -p "${OUT_DIR}"
rm -f "${OUT_ISO}" "${OUT_PASSWORD}"
(umask 077 && printf '%s\n' "${PASSWORD}" > "${OUT_PASSWORD}")
xorriso -indev "${BASE_ISO}" -outdev "${OUT_ISO}" \
  -map "${WORK}/initrd.gz" /install.amd/initrd.gz \
  -map "${WORK}/grub.cfg.new" /boot/grub/grub.cfg \
  -map "${WORK}/isolinux.cfg.new" /isolinux/isolinux.cfg \
  -map "${WORK}/extra" /agent-env \
  -boot_image any replay 2>/dev/null

log "完了: out/$(basename "${OUT_ISO}")"
echo "ユーザー:   owner"
echo "パスワード: ${PASSWORD}  （out/$(basename "${OUT_PASSWORD}") にも保存）"
echo
echo "USB メモリに書き込み（macOS: envs/debian-pc/write-usb.sh）、PC を USB から起動してメニューで Enter を押すとインストールが始まります。"
echo "インストール中に聞かれるのはインストール先ディスクの選択と確認だけです。"
echo "パスワードをパスワードマネージャーに保存したら、パスワードファイルは削除してください（ISO にはハッシュだけが入っています）。"

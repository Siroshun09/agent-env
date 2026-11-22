#!/usr/bin/env bash
# 無人インストール用の Debian ISO を作る。root 不要。Linux / macOS で動く。
# 人間用ユーザーのパスワードはランダムに生成し、表示して out/ に保存する。インストール先ディスクはインストール時に選ぶ。
# ISO と out/ にはパスワードが平文で入るので、共有しないこと（out/ は .gitignore 済み）。
#
# 使い方: envs/debian-pc/build-iso.sh [--user owner] [--ssh-key ~/.ssh/id_ed25519.pub]
#   --user     人間用ユーザー（sudo あり）の名前。既定は owner。admin など Debian の予約名は使えない。
#   --ssh-key  人間用ユーザーに登録する公開鍵。指定するとパスワードでの SSH ログインを無効化する。
# 必要なもの: git, curl, xorriso, cpio, gzip（macOS: brew install xorriso）
set -euo pipefail

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${ENV_DIR}/../.." && pwd)"
REPO_URL="https://github.com/Siroshun09/agent-env.git"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/agent-env"
OUT_DIR="${REPO_ROOT}/out"
OUT_ISO="${OUT_DIR}/agent-env-debian-pc.iso"
OUT_PASSWORD="${OUT_DIR}/agent-env-debian-pc.password"

die() { echo "エラー: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

HUMAN_USER="owner"
SSH_KEY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) HUMAN_USER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ "${HUMAN_USER}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "--user は小文字英数字とハイフンで指定してください"
[[ "${HUMAN_USER}" != agent ]] || die "--user に agent は使えません（エージェント用に予約）"
[[ -z "${SSH_KEY}" ]] || [[ -f "${SSH_KEY}" ]] || die "公開鍵が見つかりません: ${SSH_KEY}"
[[ -z "${SSH_KEY}" ]] || ! grep -q "PRIVATE KEY" "${SSH_KEY}" || die "秘密鍵が指定されています。.pub を指定してください"
for cmd in git curl xorriso cpio gzip; do
  command -v "${cmd}" >/dev/null || die "${cmd} が必要です"
done

# shellcheck source=iso.conf
. "${ENV_DIR}/iso.conf"

log "リポジトリの状態確認"
cd "${REPO_ROOT}"
[[ -z "$(git status --porcelain)" ]] || die "未コミットの変更があります。ISO には commit 済みの内容しか入りません"
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || die "shallow clone では作れません。git fetch --unshallow してください"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "${BRANCH}" != HEAD ]] || die "ブランチをチェックアウトしてください（detached HEAD）"
echo "${BRANCH} @ $(git rev-parse --short HEAD)"

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
PASSWORD="$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 20)"
[[ ${#PASSWORD} -eq 20 ]] || die "パスワードを生成できませんでした"

log "ISO の組み立て"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/initrd" "${WORK}/extra"

# preseed: プレースホルダを埋めて initrd に入れる（/preseed.cfg は自動で読まれる）
sed -e "s|@HUMAN_USER@|${HUMAN_USER}|g" -e "s|@PASSWORD@|${PASSWORD}|g" \
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

# 安全確認: どちらの起動メニューも自動では進まない（キー入力を待つ）こと
[[ "$(grep -E '^[[:space:]]*set timeout=' "${WORK}/grub.cfg.new" | tail -1)" == "set timeout=-1" ]] ||
  die "grub.cfg が無期限待機になっていません"
grep -qx 'timeout 0' "${WORK}/isolinux.cfg.new" || die "isolinux.cfg が無期限待機になっていません"

git bundle create "${WORK}/extra/repo.bundle" "${BRANCH}" 2>/dev/null
cp "${ENV_DIR}/late-command.sh" "${WORK}/extra/late-command.sh"
cat > "${WORK}/extra/build.env" <<EOF
HUMAN_USER='${HUMAN_USER}'
REPO_URL='${REPO_URL}'
REPO_BRANCH='${BRANCH}'
EOF
[[ -z "${SSH_KEY}" ]] || cp "${SSH_KEY}" "${WORK}/extra/authorized_keys"

mkdir -p "${OUT_DIR}"
rm -f "${OUT_ISO}" "${OUT_PASSWORD}"
(umask 077 && printf '%s\n' "${PASSWORD}" > "${OUT_PASSWORD}")
xorriso -indev "${BASE_ISO}" -outdev "${OUT_ISO}" \
  -map "${WORK}/initrd.gz" /install.amd/initrd.gz \
  -map "${WORK}/grub.cfg.new" /boot/grub/grub.cfg \
  -map "${WORK}/isolinux.cfg.new" /isolinux/isolinux.cfg \
  -map "${WORK}/extra" /agent-env \
  -boot_image any replay 2>/dev/null

log "完了: ${OUT_ISO}"
echo "ユーザー:   ${HUMAN_USER}"
echo "パスワード: ${PASSWORD}  （${OUT_PASSWORD} にも保存）"
echo
echo "USB メモリに書き込み、起動メニューで Enter を押すとインストールが始まります。"
echo "インストール中に聞かれるのはインストール先ディスクだけです。"
echo "パスワードをパスワードマネージャ等に保存したら、ISO とパスワードファイルは削除してください。"

#!/usr/bin/env bash
# 無人インストール用の Debian ISO を作る。root 不要。Linux / macOS で動く。
# 人間用ユーザーのパスワードはランダムに生成し、表示して out/ に保存する（ISO にはハッシュだけを入れる）。
# インストール先ディスクはインストール時に選ぶ。
#
# 使い方: envs/debian-pc/build-iso.sh (--ssh-key ~/.ssh/id_ed25519.pub | --no-ssh-key) [--user owner] [--allow-non-main]
#   --ssh-key         人間用ユーザーに登録する公開鍵。パスワードでの SSH ログインは無効になる。
#   --no-ssh-key      鍵を登録しない（SSH はパスワードでログインする）。どちらかの指定が必須。
#   --user            人間用ユーザー（sudo あり）の名前。既定は owner。root や admin などの予約名は使えない。
#   --allow-non-main  検証用。main 以外のブランチや、GitHub の main と一致しないコミットからも作れる。
#                     main 以外から作った PC では、インストール後の自動更新は停止する。
# 必要なもの: git, curl, xorriso, cpio, gzip, openssl（passwd -6 対応のもの。macOS 標準の LibreSSL は不可）
#   macOS: brew install xorriso openssl（または build-iso-in-container.sh を使う）
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
NO_SSH_KEY=0
ALLOW_NON_MAIN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) HUMAN_USER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --no-ssh-key) NO_SSH_KEY=1; shift ;;
    --allow-non-main) ALLOW_NON_MAIN=1; shift ;;
    *) die "不明な引数: $1" ;;
  esac
done
[[ "${HUMAN_USER}" =~ ^[a-z][a-z0-9-]{0,31}$ ]] || die "--user は小文字英数字とハイフンで指定してください"
# Debian のシステムアカウント・d-i の予約名・エージェント用ユーザー
case "${HUMAN_USER}" in
  root|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|backup|list|irc|gnats|nobody|\
  admin|adm|sudo|staff|users|operator|www-data|sshd|messagebus|avahi|polkitd|agent|systemd-*)
    die "--user に ${HUMAN_USER} は使えません（予約名）" ;;
esac
if [[ -n "${SSH_KEY}" ]]; then
  [[ -f "${SSH_KEY}" ]] || die "公開鍵が見つかりません: ${SSH_KEY}"
  ! grep -q "PRIVATE KEY" "${SSH_KEY}" || die "秘密鍵が指定されています。.pub を指定してください"
elif [[ "${NO_SSH_KEY}" -eq 0 ]]; then
  die "--ssh-key で公開鍵を指定してください（鍵なしで作る場合は --no-ssh-key）"
fi
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
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "${BRANCH}" != HEAD ]] || die "ブランチをチェックアウトしてください（detached HEAD）"
# ブランチ名はインストーラが読む build.env に書くので、シェルで特別な意味を持つ文字を許さない
[[ "${BRANCH}" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "ブランチ名に使えない文字が含まれています: ${BRANCH}"
# インストール後の自動更新は main を追従する。main 以外から作ると自動更新が止まるので明示を求める
[[ "${BRANCH}" == main || "${ALLOW_NON_MAIN}" -eq 1 ]] ||
  die "main 以外のブランチ（${BRANCH}）です。検証用に作る場合は --allow-non-main を付けてください"
# 本番用は GitHub の main と同じコミットであること（未 push のコミットを入れない）
if [[ "${ALLOW_NON_MAIN}" -eq 0 ]]; then
  remote_main="$(git ls-remote "${REPO_URL}" refs/heads/main | cut -f1)"
  [[ -n "${remote_main}" ]] || die "${REPO_URL} の main を取得できませんでした"
  [[ "$(git rev-parse HEAD)" == "${remote_main}" ]] ||
    die "HEAD が GitHub の main（${remote_main:0:7}）と一致しません。git pull するか、検証用なら --allow-non-main を付けてください"
fi
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
sed -e "s|@HUMAN_USER@|${HUMAN_USER}|g" -e "s|@PASSWORD_HASH@|${PASSWORD_HASH}|g" \
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
cp "${ENV_DIR}/late-command.sh" "${ENV_DIR}/select-disk.sh" "${WORK}/extra/"
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

log "完了: out/$(basename "${OUT_ISO}")"
echo "ユーザー:   ${HUMAN_USER}"
echo "パスワード: ${PASSWORD}  （out/$(basename "${OUT_PASSWORD}") にも保存）"
echo
echo "USB メモリに書き込み、起動メニューで Enter を押すとインストールが始まります。"
echo "インストール中に聞かれるのはインストール先ディスクの選択と確認だけです。"
echo "パスワードをパスワードマネージャ等に保存したら、パスワードファイルは削除してください（ISO にはハッシュだけが入っています）。"

#!/bin/sh
# Secure Boot が有効で NVIDIA GPU がある PC で、DKMS がカーネルモジュールに署名する鍵を作り、MOK への登録を申請する。
# 登録の承認は、次の再起動で表示される MokManager で人が行う（Secure Boot の仕様で自動化できない）。
# インストーラの late-command.sh（in-target）と bootstrap.sh の両方から実行される。冪等。
set -eu

KEY=/var/lib/dkms/mok.key # Debian の dkms が既定で使う鍵の場所
CERT=/var/lib/dkms/mok.pub
PASSWORD_FILE=/var/lib/agent-env/mok-password # ISO の作成時に生成したパスワード（無ければここで生成）

has_nvidia_gpu() {
  for d in /sys/bus/pci/devices/*; do
    [ "$(cat "$d/vendor")" = 0x10de ] || continue
    case "$(cat "$d/class")" in 0x03*) return 0 ;; esac
  done
  return 1
}

if ! has_nvidia_gpu; then echo "MOK: NVIDIA GPU が無いので何もしません"; exit 0; fi
if [ ! -d /sys/firmware/efi ]; then echo "MOK: UEFI で起動していないので何もしません"; exit 0; fi
if ! grep -qs efivarfs /proc/mounts; then
  # インストーラの chroot では未マウント。自分でマウントしたものは終了時に外す（chroot の後片付けを妨げないため）
  mount -t efivarfs efivarfs /sys/firmware/efi/efivars
  trap 'umount /sys/firmware/efi/efivars' EXIT
fi
if ! mokutil --sb-state 2>&1 | grep -q 'SecureBoot enabled'; then echo "MOK: Secure Boot が無効なので何もしません"; exit 0; fi

if [ ! -s "${KEY}" ] || [ ! -s "${CERT}" ]; then
  # 片方だけ残っている場合（作成中に中断した場合など）も作り直す
  mkdir -p /var/lib/dkms
  (umask 077 && openssl req -new -x509 -nodes -days 36500 -newkey rsa:2048 \
    -subj "/CN=agent-box DKMS module signing key/" -keyout "${KEY}" -outform DER -out "${CERT}" 2>/dev/null)
fi

fingerprint() { tr -d ': ' | tr 'A-F' 'a-f'; }
fpr="$(openssl x509 -inform DER -in "${CERT}" -noout -fingerprint -sha1 | sed 's/.*=//' | fingerprint)"
if mokutil --list-enrolled 2>/dev/null | sed -n 's/.*SHA1 Fingerprint: *//p' | fingerprint | grep -qx "${fpr}"; then
  echo "MOK: 登録済みです"
  exit 0
fi

if [ ! -s "${PASSWORD_FILE}" ]; then
  mkdir -p "$(dirname "${PASSWORD_FILE}")"
  # MokManager は US 配列で入力を受けるので、配列に依存しない数字だけにする
  (umask 077 && od -An -N8 -tu8 /dev/urandom | tr -d ' \n' | cut -c 1-8 > "${PASSWORD_FILE}")
fi
password="$(cat "${PASSWORD_FILE}")"
if ! mokutil --list-new 2>/dev/null | sed -n 's/.*SHA1 Fingerprint: *//p' | fingerprint | grep -qx "${fpr}"; then
  hash_file="$(mktemp)"
  mokutil --generate-hash="${password}" > "${hash_file}"
  mokutil --import "${CERT}" --hash-file "${hash_file}"
  rm -f "${hash_file}"
fi
echo "MOK: 登録を申請しました。次の再起動で MokManager が表示されたら、Enroll MOK → Continue → Yes を選び、パスワード ${password} を入力して Reboot を選んでください"

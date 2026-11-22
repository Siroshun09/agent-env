#!/bin/sh
# Debian インストーラの late_command から実行される（busybox sh）。
# 途中で失敗するとインストーラがエラーを表示して止まるので、未設定のまま完了扱いにならない。
set -eu

SRC=/cdrom/agent-env

# リポジトリ（ビルド時のコミット）を main として配置し、origin を GitHub に向ける
cp "${SRC}/repo.bundle" /target/tmp/agent-env.bundle
in-target git clone -q --no-checkout /tmp/agent-env.bundle /opt/agent-env
in-target git -C /opt/agent-env checkout -q -B main
in-target git -C /opt/agent-env remote set-url origin https://github.com/Siroshun09/agent-env.git
rm -f /target/tmp/agent-env.bundle

# 初回起動時に bootstrap を実行する
cp /target/opt/agent-env/envs/debian-pc/system/agent-env-firstboot.service /target/etc/systemd/system/
in-target systemctl enable agent-env-firstboot.service
[ -L /target/etc/systemd/system/multi-user.target.wants/agent-env-firstboot.service ]

# SSH: 公開鍵だけでログインさせる。root ではログインさせない
SSH_DIR=/target/home/owner/.ssh
mkdir -p "${SSH_DIR}"
cp "${SRC}/authorized_keys" "${SSH_DIR}/authorized_keys"
chmod 700 "${SSH_DIR}"
chmod 600 "${SSH_DIR}/authorized_keys"
in-target chown -R owner:owner /home/owner/.ssh
printf '%s\n' "PermitRootLogin no" "PasswordAuthentication no" "KbdInteractiveAuthentication no" \
  > /target/etc/ssh/sshd_config.d/agent-env.conf

#!/bin/sh
# Debian インストーラの late_command から実行される（busybox sh）。
# 途中で失敗するとインストーラがエラーを表示して止まるので、未設定のまま完了扱いにならない。
# build-iso.sh が ISO の /agent-env/ に build.env・repo.bundle と一緒に配置する。
set -eu

SRC=/cdrom/agent-env
# HUMAN_USER, REPO_URL, REPO_BRANCH
. "${SRC}/build.env"

# リポジトリ（ビルド時のコミット）を配置する
cp "${SRC}/repo.bundle" /target/tmp/agent-env.bundle
in-target git clone -q -b "${REPO_BRANCH}" /tmp/agent-env.bundle /opt/agent-env
in-target git -C /opt/agent-env remote set-url origin "${REPO_URL}"
rm -f /target/tmp/agent-env.bundle

# 初回起動時に bootstrap を実行する
cp /target/opt/agent-env/envs/debian-pc/agent-env-firstboot.service /target/etc/systemd/system/
in-target systemctl enable agent-env-firstboot.service
[ -L /target/etc/systemd/system/multi-user.target.wants/agent-env-firstboot.service ]

# SSH 公開鍵が同梱されていれば登録し、パスワードでの SSH ログインを無効化する
if [ -f "${SRC}/authorized_keys" ]; then
  SSH_DIR="/target/home/${HUMAN_USER}/.ssh"
  mkdir -p "${SSH_DIR}"
  cp "${SRC}/authorized_keys" "${SSH_DIR}/authorized_keys"
  chmod 700 "${SSH_DIR}"
  chmod 600 "${SSH_DIR}/authorized_keys"
  in-target chown -R "${HUMAN_USER}:${HUMAN_USER}" "/home/${HUMAN_USER}/.ssh"
  echo "PasswordAuthentication no" > /target/etc/ssh/sshd_config.d/agent-env.conf
fi

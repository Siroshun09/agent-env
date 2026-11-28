#!/bin/bash
# Mac で、ゲートウェイの画面をポート番号なしの URL（http://agent-box.localhost など）で開けるようにする。
# Mac の 127.0.0.1:80 と [::1]:80 への接続を、SSH が転送している 8700 番に振り替える（pf の rdr）。
# 80 番は root でないと待ち受けられないので、ssh は 8700 番のまま使う。
# 対象はループバック（lo0）だけなので、LAN などほかのマシンからは届かない。
# 規則は /etc/pf.conf を書き換えずに com.apple/agent-env のアンカーに読み込み、起動時に LaunchDaemon で読み込み直す。
#
# 使い方（Mac で実行）:
#   sudo ./mac-port80.sh               # 設定する（何度実行してもよい）
#   sudo ./mac-port80.sh --uninstall   # 元に戻す
set -euo pipefail

LABEL=io.github.siroshun09.agent-env.port80
ANCHOR=com.apple/agent-env
RULES=/etc/pf.anchors/agent-env
PLIST=/Library/LaunchDaemons/${LABEL}.plist
PORT=8700

if [[ "$(uname -s)" != Darwin ]]; then
  echo "Mac で実行してください" >&2
  exit 1
fi
if [[ "$(id -u)" -ne 0 ]]; then
  echo "sudo で実行してください" >&2
  exit 1
fi

if [[ "${1:-}" == --uninstall ]]; then
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  pfctl -a "$ANCHOR" -F all 2>/dev/null || true
  rm -f "$PLIST" "$RULES"
  echo "元に戻しました"
  exit 0
fi

cat >"$RULES" <<EOF
# agent-env（mac-port80.sh）: Mac 内の 80 番への接続を、SSH が転送している ${PORT} 番に振り替える
rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port 80 -> 127.0.0.1 port ${PORT}
rdr pass on lo0 inet6 proto tcp from any to ::1 port 80 -> ::1 port ${PORT}
EOF

# -E: pf を有効にする（macOS の既定では無効）
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/sbin/pfctl</string>
    <string>-E</string>
    <string>-a</string>
    <string>${ANCHOR}</string>
    <string>-f</string>
    <string>${RULES}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF
chmod 644 "$RULES" "$PLIST"

# 読み込み直して、今すぐ反映する
launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST"

# LaunchDaemon の pfctl が終わるのを待ってから確認する
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if pfctl -a "$ANCHOR" -s nat 2>/dev/null | grep -q "port ${PORT}"; then
    echo "設定しました: http://agent-box.localhost で開けます（ssh -N agent-box の実行中）"
    exit 0
  fi
  sleep 1
done
echo "pf の規則を読み込めませんでした（log show --last 5m --predicate 'process == \"pfctl\"' で確認してください）" >&2
exit 1

#!/bin/sh
# 外出先のブラウザから PC 内の画面を開けるように、tailscale serve で tailnet（自分の端末だけの VPN）に公開する。
# bootstrap.sh が /usr/local/sbin/agent-env-tailnet-serve に配置する。管理者が sudo tailscale up のあとに一度だけ実行する。
# 設定は Tailscale に保存されるので、PC を再起動しても残る。公開されるのは tailscale up の間だけ。
# やめるときは sudo tailscale serve reset
set -eu

[ "$(id -u)" -eq 0 ] || { echo "root で実行してください" >&2; exit 1; }

host="$(tailscale status --json | jq -r '.Self.DNSName // empty')"
host="${host%.}"
if [ -z "${host}" ]; then
  echo "Tailscale にログインしていません。先に sudo tailscale up を実行してください" >&2
  exit 1
fi

# ゲートウェイに、tailnet でのこの PC のホスト名を渡す（tailnet 名を含むので、リポジトリには置かない）
printf 'TAILNET_HOST=%s\n' "${host}" > /etc/agent-env/gateway.env
systemctl restart agent-env-gateway.service

# 画面ごとのポート（gateway/gateway.go の tailnetPorts と合わせる）を、すべてゲートウェイに中継する
for port in 443 8443 8444 8445 8446 8447; do
  tailscale serve --bg --https="${port}" http://127.0.0.1:8700
done
echo "https://${host}/ で開けます（tailscale up の間だけ）"

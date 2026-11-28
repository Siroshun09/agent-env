#!/usr/bin/env bash
# ローカル LLM に Codex（codex exec）経由で依頼し、最後の応答だけを表示する（claude -p のような使い方）。
# bootstrap.sh が /usr/local/bin/local-llm に配置する。
#   local-llm "質問"              cat file | local-llm "これを要約して"（標準入力は <stdin> として付く）
# 残りの引数は codex exec にそのまま渡す（例: -i 画像）。モデルは LOCAL_LLM_MODEL で変えられる。
# Codex の進行状況とログは表示せず、失敗したときだけ表示する。
# 標準入力が閉じないパイプ（端末でもない）だと codex exec が読み続けて止まるので、そのときは </dev/null を付ける。
set -euo pipefail

# サーバーが動いていないと codex exec は再試行を続けて止まらないので、先に確認する
if ! curl -sf --max-time 5 -o /dev/null http://127.0.0.1:8080/models; then
  echo "local-llm: ローカル LLM のサーバー（127.0.0.1:8080）に接続できません" >&2
  exit 1
fi

log="$(mktemp)"
trap 'rm -f "${log}"' EXIT
# 標準エラーが端末でないとき、codex exec は最後の応答だけを標準出力に書く
codex exec --skip-git-repo-check --ephemeral --color never \
  -c model_provider=llama-cpp -m "${LOCAL_LLM_MODEL:-qwen3.6-35b-a3b}" "$@" 2> "${log}" || {
  status=$?
  cat "${log}" >&2
  exit "${status}"
}

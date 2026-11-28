#!/usr/bin/env bash
# ローカル LLM（llama-server）に一度だけ依頼し、応答だけを表示する（claude -p のような使い方）。
# bootstrap.sh が /usr/local/bin/local-llm に配置する。
#   local-llm "指示" < file                     標準入力の内容を指示の後ろに付ける
#   local-llm -i image.png "指示" < /dev/null   画像を付ける（-i は繰り返せる）
#   local-llm -a "指示" < /dev/null             LLM 自身がファイルを読んだりコマンドを実行したりして調べる
# 既定では API（/v1/chat/completions）を直接呼ぶ。道具を渡さないので、扱うデータに紛れた指示に従っても、
# LLM は文章を返すことしかできない。
# -a では Codex（codex exec）を読み取り専用のサンドボックスで使う。今いるディレクトリなどを読めるが、
# ファイルの書き込みと通信はできない。Codex 自身のプロンプトとエージェントへの指示が付くぶん、文脈は減る。
# モデルは LOCAL_LLM_MODEL で変えられる。思考（reasoning）は llama-server の既定のまま（有効、上限なし）。
# 標準入力が閉じないパイプ（端末でもない）だと読み続けて止まるので、入力がないときは </dev/null を付ける。
set -euo pipefail

usage() {
  echo 'usage: local-llm [-a] [-i image]... "instruction" < input' >&2
  exit 2
}

model="${LOCAL_LLM_MODEL:-qwen3.6-35b-a3b}"
agent=false
images=()
while getopts ai: opt; do
  case "${opt}" in
    a) agent=true ;;
    i) images+=("${OPTARG}") ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || usage

# サーバーが動いていない PC（GPU が無いなど）では、すぐに失敗する
if ! curl -sf --max-time 5 -o /dev/null http://127.0.0.1:8080/models; then
  echo "local-llm: ローカル LLM のサーバー（127.0.0.1:8080）に接続できません" >&2
  exit 1
fi

if "${agent}"; then
  log="$(mktemp)"
  trap 'rm -f "${log}"' EXIT
  # 標準エラーが端末でないとき、codex exec は最後の応答だけを標準出力に書く。標準入力は <stdin> として付く。
  # 進行状況とログは、失敗したときだけ表示する
  codex exec --skip-git-repo-check --ephemeral --color never --sandbox read-only \
    -c model_provider=llama-cpp -m "${model}" "${images[@]/#/--image=}" "$1" 2> "${log}" || {
    status=$?
    cat "${log}" >&2
    exit "${status}"
  }
  exit 0
fi

# 入力と画像は、コマンドの引数の長さの上限を超えないように、ファイルで jq に渡す
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
if [[ -t 0 ]]; then : > "${tmp}/stdin"; else cat > "${tmp}/stdin"; fi
: > "${tmp}/images"
for image in "${images[@]}"; do
  type="${image##*.}"
  type="${type,,}"
  [[ "${type}" == jpg ]] && type=jpeg
  { printf 'data:image/%s;base64,' "${type}"; base64 -w0 "${image}"; } |
    jq -Rs '{type: "image_url", image_url: {url: .}}' >> "${tmp}/images"
done

jq -n --arg model "${model}" --arg prompt "$1" \
  --rawfile stdin "${tmp}/stdin" --slurpfile images "${tmp}/images" \
  '{model: $model, messages: [{role: "user", content: (
    [{type: "text", text: (if $stdin == "" then $prompt else "\($prompt)\n\n<stdin>\n\($stdin)</stdin>" end)}] + $images
  )}]}' > "${tmp}/request"

# モデルの読み込みと生成に時間がかかるので、待ち時間は長くする
curl -sS --fail-with-body --max-time 1800 http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' -d "@${tmp}/request" > "${tmp}/response" || {
  status=$?
  cat "${tmp}/response" >&2
  exit "${status}"
}
jq -r '.choices[0].message.content' "${tmp}/response"

<!-- agent-env が /etc/claude-code/CLAUDE.md に配置し、Claude Code と OpenCode の両方が読む。手で編集せずリポジトリ側を直すこと。 -->
# この PC のローカル LLM

この PC では llama.cpp の llama-server が `http://127.0.0.1:8080/v1`（OpenAI 互換、認証なし）で動いている。PC の外にデータを出さずに、費用をかけずに使える。適切な場面では積極的に使うこと。ただし、あなた自身がローカル LLM（`llama-cpp/...`）として動いている場合は、この節は無視してよい。

| モデル名（`"model"`） | 用途 |
|---|---|
| `qwen3.6-35b-a3b` | 文章の生成と画像の読み取り。コンテキストは 65536 トークン |
| `qwen3-embedding-0.6b` | 埋め込み（`/v1/embeddings`） |

## 使う場面

- **外に出したくないデータ:** ユーザーが外部に送りたくないと言ったデータ（個人情報、社外秘の資料など）は、自分では読まずにローカル LLM に処理させ、外に出してよい結果だけを受け取る。
- **大量のテキストの機械的な処理:** 多数のファイルやログの要約・分類・抽出など。自分で全部読むとコンテキストを大きく消費する作業は、ローカル LLM に下処理させて結果だけを読む。
- **意味での検索:** 多数の文書から、言葉が一致しなくても内容が近い箇所を探すときは、埋め込みを使う。
- **画像の下読み:** 大量のスクリーンショットや画像の文字起こし・分類。

次の場合は使わず、自分で行う。

- コードの設計・実装・レビューなど、品質や正確さが重要な作業（ローカル LLM はあなたより性能が低い）。
- 少量のテキスト（自分で読むほうが速くて正確）。

ローカル LLM の出力には誤りがあり得る。重要な判断の根拠にするときは原文で確認すること。

## 使い方

- まず `curl -sf http://127.0.0.1:8080/models` で動いているかを確認する。接続できなければ（GPU が無い PC など）、ローカル LLM を使わずに進める。
- モデルは初回の呼び出しで読み込むので、数十秒以上かかることがある。タイムアウトは長め（10 分程度）にする。生成も速くはないので、大量のリクエストを同時に送らず、順番に送る。
- 応答の本文は `.choices[0].message.content` にある（思考の過程は `reasoning_content` に分かれる）。

ファイルの内容を渡して処理させる例:

```bash
jq -n --rawfile text app.log '{model: "qwen3.6-35b-a3b", messages: [{role: "user", content: ("次のログからエラーの種類と件数を一覧にしてください。\n\n" + $text)}]}' \
  | curl -sf --max-time 600 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d @- \
  | jq -r '.choices[0].message.content'
```

画像を読ませる例:

```bash
jq -n --arg img "$(base64 -w0 screenshot.png)" '{model: "qwen3.6-35b-a3b", messages: [{role: "user", content: [{type: "text", text: "画像の文字をすべて書き起こしてください"}, {type: "image_url", image_url: {url: ("data:image/png;base64," + $img)}}]}]}' \
  | curl -sf --max-time 600 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d @- \
  | jq -r '.choices[0].message.content'
```

埋め込みの例（`input` には複数の文を配列で渡せる。検索する側の文には `Instruct: Given a search query, retrieve relevant passages that answer the query\nQuery: ` を前に付けると精度が上がる）:

```bash
jq -n '{model: "qwen3-embedding-0.6b", input: ["文 1", "文 2"]}' \
  | curl -sf --max-time 600 http://127.0.0.1:8080/v1/embeddings -H 'Content-Type: application/json' -d @- \
  | jq -c '.data[].embedding'
```

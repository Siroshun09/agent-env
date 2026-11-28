# Local LLM on this PC

llama.cpp's llama-server runs at `http://127.0.0.1:8080/v1` (OpenAI-compatible, no authentication).

| Model name (`"model"`) | Use |
|---|---|
| `qwen3.6-35b-a3b` | Text generation and image understanding. Context: 65536 tokens |
| `qwen3-embedding-0.6b` | Embeddings (`/v1/embeddings`) |

- It is less capable than you and can make mistakes. Check the source before relying on its output for important decisions.
- A model is loaded on its first call, which can take tens of seconds or more. Generation is not fast either, so send requests one at a time instead of many in parallel.

## Text: the `local-llm` command

`local-llm "<instruction>"` asks `qwen3.6-35b-a3b` and prints only the final answer (it runs `codex exec`; Codex's own output is shown only on failure). Standard input is attached to the prompt.

```bash
local-llm "List the error types in this log with their counts." < app.log
git diff | local-llm "Summarize what this diff changes, one line per file."
local-llm "Translate to English: こんにちは" < /dev/null
```

- Always redirect standard input (a file, a pipe, or `/dev/null`). Otherwise it can wait forever for input.
- If the server is not running (e.g. a PC without a GPU), it exits with an error right away. Proceed without the local LLM.
- The context is 65536 tokens including Codex's own prompt. Keep each input to about 40,000 tokens (roughly 100 KB of English or code, less for Japanese) and split larger inputs.

## Images, embeddings, and scripts: the API

Call `http://127.0.0.1:8080/v1` directly with a long timeout (about 10 minutes). The answer is in `.choices[0].message.content` (reasoning is returned separately in `reasoning_content`). `curl -sf http://127.0.0.1:8080/models` checks that it is running.

Read an image:

```bash
jq -n --arg img "$(base64 -w0 screenshot.png)" '{model: "qwen3.6-35b-a3b", messages: [{role: "user", content: [{type: "text", text: "Transcribe all text in this image."}, {type: "image_url", image_url: {url: ("data:image/png;base64," + $img)}}]}]}' \
  | curl -sf --max-time 600 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d @- \
  | jq -r '.choices[0].message.content'
```

Embeddings (`input` accepts an array of texts; prefix the search query, not the documents, with `Instruct: Given a search query, retrieve relevant passages that answer the query\nQuery: ` for better accuracy):

```bash
jq -n '{model: "qwen3-embedding-0.6b", input: ["text 1", "text 2"]}' \
  | curl -sf --max-time 600 http://127.0.0.1:8080/v1/embeddings -H 'Content-Type: application/json' -d @- \
  | jq -c '.data[].embedding'
```

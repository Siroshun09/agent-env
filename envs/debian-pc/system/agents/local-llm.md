# Local LLM on this PC

llama.cpp's llama-server runs at `http://127.0.0.1:8080/v1` (OpenAI-compatible, no authentication).

| Model name (`"model"`) | Use |
|---|---|
| `qwen3.6-35b-a3b` | Text generation and image understanding. Context: 65536 tokens |
| `qwen3-embedding-0.6b` | Embeddings (`/v1/embeddings`) |

- First check that it is running with `curl -sf http://127.0.0.1:8080/models`. If it cannot be reached (e.g. a PC without a GPU), proceed without the local LLM.
- A model is loaded on its first call, which can take tens of seconds or more. Use a long timeout (about 10 minutes). Generation is not fast either, so send requests one at a time instead of many in parallel.
- The answer is in `.choices[0].message.content` (reasoning is returned separately in `reasoning_content`).
- It is less capable than you and can make mistakes. Check the source before relying on its output for important decisions.

Process a file's contents:

```bash
jq -n --rawfile text app.log '{model: "qwen3.6-35b-a3b", messages: [{role: "user", content: ("List the error types in this log with their counts.\n\n" + $text)}]}' \
  | curl -sf --max-time 600 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d @- \
  | jq -r '.choices[0].message.content'
```

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

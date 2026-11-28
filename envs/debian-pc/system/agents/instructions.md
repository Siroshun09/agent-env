# Local LLM
A local LLM is available on this PC at `http://127.0.0.1:8080/v1` (OpenAI-compatible). Data stays on the machine and it costs nothing. Use it proactively in these cases (unless you are running as the local LLM yourself):
- Processing data the user does not want sent outside (do not read it yourself; take only the result)
- Summarizing, classifying, or extracting from many files or large logs; transcribing images
- Semantic search with embeddings

Do not use it for quality-critical work such as code design, implementation, or review, or for small amounts of text.

Call it with `local-llm "<instruction>" < <file>` (or `< /dev/null` when there is no input; `-i <image>` attaches an image); only the answer is printed. If it says the server cannot be reached, proceed without it. For embeddings, input size limits, and details, read `/etc/agent-env/local-llm.md`.

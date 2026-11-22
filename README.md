# agent-env

エージェント専用 PC を、いつでも作り直せる形でセットアップするためのリポジトリです。

## 対象範囲
このリポジトリでは、PC の OS からエージェントのツールまでを扱います。エージェントの作業中のデータと秘密情報だけは、リポジトリの外（PC 内）に置きます。

| このリポジトリ | リポジトリの外（PC 内だけ） |
|---|---|
| OS のインストールとパーティション | 秘密情報（Claude のログイン、ChatGPT のサインイン、GitHub のトークン） |
| ユーザーの分離（人間用の `owner` / エージェント用の `agent`） | エージェントが作業中のリポジトリ |
| パッケージと podman、OS の更新設定 | |
| エージェントのツール（Claude Code、OpenCode、mise、gh）と、その管理者用の設定 | |
| NVIDIA ドライバーとローカル LLM（llama.cpp とモデル） | |

`agent` には sudo 権限がありません。エージェントのツールに apt パッケージが必要な場合は、`envs/debian-pc/packages.txt` に追加してください。言語ツールは各プロジェクトの `mise.toml` で管理します。

## 方針
- PC は使い捨てにし、状態はリポジトリと外部に置きます。作り直すときは ISO から再インストールするだけです。
- 人間用ユーザーとエージェント用ユーザーを分け、エージェントには sudo 権限を与えません。
- エージェントのツールの設定のうち、エージェント自身に変えられたくないもの（OpenCode で使えるモデル提供元など）は、root 所有の管理者用の設定に置きます。管理者用の設定は、ユーザーやプロジェクトの設定より優先されます。
- 秘密情報はリポジトリに入れません。ISO にはパスワードのハッシュ、SSH 公開鍵、MOK の登録用のパスワード（インストール直後に 1 回だけ使う数字 8 桁）が入るため、CI でも ISO は公開しません。

## 構成
```
envs/debian-pc/                Debian 13 の実 PC
  build-iso-in-container.sh    ISO を作り、USB メモリに書き込む（通常はこれを実行する）
  build-iso.sh                 ISO を作る（コンテナ内で実行される）
  write-usb.sh                 ISO を USB メモリに書き込む（macOS 専用）
  preseed.cfg                  インストーラへの応答
  select-disk.sh               インストール先ディスクの選択画面
  late-command.sh              インストールの最後に、リポジトリと SSH を設定する
  mok-enroll.sh                Secure Boot 用に、NVIDIA ドライバーの署名鍵の登録（MOK）を申請する
  bootstrap.sh                 PC をセットアップする（冪等）
  apply.sh                     main の変更を、確認・承認したうえで PC に反映する
  packages.txt                 インストールするパッケージ
  tools.conf                   apt で入らないツール（OpenCode、llama.cpp）とローカル LLM のモデルのバージョンとハッシュ
  system/                      systemd ユニット、apt の設定とリポジトリ、エージェントのツールの管理者用の設定、GitHub のトークンの使い分けと git のフック
.github/workflows/             CI（静的検査、ISO のビルド、bootstrap と apply.sh のテスト）
```

## インストール
1. Mac で GitHub の `main` をチェックアウトし、USB メモリを挿して次を実行します。
   ```bash
   envs/debian-pc/build-iso-in-container.sh
   ```
   ISO の作成から USB メモリへの書き込みまでを行います。
   - ビルドはコンテナ内で行うため、Mac にツールを入れる必要はありません。Apple の `container`、`docker`、`podman` のいずれかが必要です（`container` の場合は、先に `container system start` を実行してください）。
   - 人間用ユーザー `owner` のパスワードはランダムに生成され、画面と `out/agent-env-debian-pc.password` に出力されます。パスワードマネージャーに保存したら、このファイルは削除してください。2 行目の MOK のパスワードは、インストール直後の再起動で 1 回だけ使います（手順 4）。
   - SSH 公開鍵（`~/.ssh/id_ed25519.pub` などを自動で探します。`--ssh-key` で指定も可能）が `owner` に登録されます。SSH のパスワードログインは無効です。
   - 書き込み先の候補には外付けディスクだけが表示されます。ディスク名（例: `disk4`）を入力し、確認のため `ERASE disk4` と入力すると書き込みが始まります。書き込み後は内容を検証し、USB メモリを取り出します。
   - ISO には現在のコミットが入ります。未コミットの変更がある場合や、現在のコミットが GitHub の `main` と異なる場合は中断します（`main` 以外から作った PC では、あとで `apply.sh` を使えなくなるため）。検証用に別のコミットから作る場合だけ `--allow-non-main` を付けます。
   - 書き込みだけをやり直す場合は `envs/debian-pc/write-usb.sh` を実行します。書き込みを省く場合は `--no-write` を付けます。
2. PC を USB メモリから起動し、メニューの `agent-env: Automated install (ERASES DISK)` を選んで Enter を押します。誤って再インストールしないよう、メニューは自動では進みません。
3. 一覧からインストール先のディスクを選び、確認画面で `Yes` を選びます（既定は `No`）。選んだディスクのデータはすべて消去されます。USB メモリ自体は一覧に表示されません。この後は自動で進みます。
   - パーティションは LVM で、`/` が 128GB（ローカル LLM のモデルを含む）、swap が 8GB、`/home`（エージェントの作業場所）が残りすべてです。ディスクが小さい場合は比率に応じて縮みます。
4. インストールが終わると再起動します。NVIDIA の GPU があり Secure Boot が有効な PC では、起動前に `Press any key to perform MOK management` と表示されるので、10 秒以内にキーを押します。青い MokManager の画面で `Enroll MOK` → `Continue` → `Yes` を選び、ISO の作成時に表示された MOK のパスワード（数字 8 桁。`out/agent-env-debian-pc.password` の 2 行目）を入力して `Reboot` を選びます。これは NVIDIA ドライバーの署名鍵を登録する手順で、Secure Boot の仕様上、PC の前での操作が必要です。
   - 10 秒以内にキーを押さなかった場合は、そのまま通常の起動に進みます。見逃した場合や、インストール中の申請に失敗した場合は、初回起動時の bootstrap が申請し直すので、次の再起動で同じ操作をしてください（`journalctl -u agent-env-firstboot` に案内が出ます）。
5. 初回起動時に bootstrap が自動で実行されます。失敗した場合は 60 秒ごとに再試行します。進み具合は `journalctl -fu agent-env-firstboot` で確認できます。
6. NVIDIA の GPU がある PC では、bootstrap の完了後に一度 `sudo reboot` します（ドライバーを読み込むため）。`nvidia-smi` で GPU が表示されれば完了です。
7. エージェントの認証をします（初回のみ）。手順は「エージェントの準備」を参照してください。

## エージェントの準備
初回セットアップが終わると、Claude Code（`claude`）、OpenCode（`opencode`）、mise、gh が入っています。認証情報はリポジトリにも ISO にも入らないので、最初に一度だけ手で設定します。

```bash
ssh -t agent-box sudo -iu agent
```

`agent` ユーザーで次を実行します。
- Claude Code: `cd ~/work && claude` を起動してログインします。表示された URL を Mac のブラウザで開いて認証します。続けて表示される `~/work` を信頼するかの確認で、信頼を選びます（Remote Control は、信頼済みのフォルダーでしか動きません）。
- OpenCode: `opencode` を起動し（ブラウザの Web UI からでも可）、`/connect` で OpenAI を選んで ChatGPT のプランでサインインします。管理者用の設定で、OpenAI とローカル LLM 以外のモデル提供元は使えないようにしています。
- GitHub: [fine-grained personal access token](https://github.com/settings/personal-access-tokens) を、リポジトリの持ち主（個人と各 org）ごとに 1 枚ずつ発行し、`agent-env-github-token set <持ち主>` で保存します（トークンを貼り付け、Enter と Ctrl+D）。fine-grained PAT は 1 枚で 1 つの持ち主のリポジトリにしか使えないためです。
  - トークンは対象のリポジトリに限定し、権限は Contents と Pull requests の Read and write だけにして、有効期限を付けてください。org のトークンは、org の設定で fine-grained PAT が許可されている必要があります（管理者の承認が必要な場合もあります）。`main` へのマージはブランチ保護で防ぎます。
  - git は接続先の URL（`https://github.com/<持ち主>/...`）、gh は操作対象のリポジトリ（`-R`、`gh repo clone <持ち主>/<名前>`、今いるリポジトリの `gh repo set-default` やリモートなど）から持ち主を判断し、そのトークンを使います。エージェントは使い分けを意識する必要はありません。
  - 持ち主のトークンが無い場合や、持ち主がわからない場合は、どのトークンも使いません（別の持ち主のトークンを誤って使わないため）。
  - SSH の URL（`git@github.com:...`、`ssh://git@github.com/...`）は、git が HTTPS に読み替えます。この PC には SSH の鍵を置かず、トークンで認証するためです。
  - `gh auth login` と `gh auth setup-git` は使えないようにしています。以前の方式で保存した gh の認証情報と git の設定は、bootstrap が削除します。
  - デフォルトブランチへの force push（fast-forward でない更新）と削除は、git の pre-push フックが止めます。GitHub Free の private リポジトリではブランチ保護も ruleset も使えないためです。すべてのリポジトリに `/etc/gitconfig` の `core.hooksPath` で適用し、リポジトリ自身のフック（`.git/hooks`）も続けて実行します。
    - 誤操作を防ぐためのもので、`git push --no-verify` や GitHub の API では迂回できます。確実に防ぐには、private リポジトリでもブランチ保護や ruleset を使える GitHub の有料プランが必要です。
    - リポジトリの設定で `core.hooksPath` を変えている場合（husky など）は、このフックは動きません。
  - 保存済みのトークンの一覧は `agent-env-github-token list`、削除は `agent-env-github-token remove <持ち主>` です。トークンは `~/.config/agent-env/github-tokens/` に保存されます（`agent` ユーザーだけが読めます）。

エージェントのツールの管理者用の設定（`envs/debian-pc/system/claude-code/`、`envs/debian-pc/system/opencode/`）は、bootstrap が `/etc/claude-code/` と `/etc/opencode/` に配置します。`agent` ユーザーの設定では上書きできません。

## Mac からの接続
PC は `agent-box.local` という名前で LAN 内に公開されます。`~/.ssh/config` に次を追加すると、`ssh agent-box` で接続できます。
```
Host agent-box
  HostName agent-box.local
  User owner
  # OpenCode の Web UI（PC 内の 127.0.0.1:4096）を Mac の localhost:4096 に転送する
  LocalForward 4096 127.0.0.1:4096
  # ローカル LLM のチャット画面（llama-server。NVIDIA の GPU がある場合だけ）
  LocalForward 8080 127.0.0.1:8080
```
再インストールすると SSH のホスト鍵が変わります。`ssh-keygen -R agent-box.local` で古い鍵を削除し、初回接続時に表示される fingerprint が、PC のログイン画面に表示される `SSH host key:` と一致することを確認してください。

### ブラウザからエージェントを使う
PC が起動すると、2 つのエージェントがサービスとして起動します。「エージェントの準備」が済んでいれば、PC にログインしなくてもブラウザから使えます。

| | 使い方 | 仕組み |
|---|---|---|
| Claude Code | ブラウザで [claude.ai/code](https://claude.ai/code) を開き、`agent-box` を選びます。Claude アプリからも使えます | Remote Control（`agent-env-claude-remote.service`）。PC から Anthropic へ外向きに接続するので、PC 側でポートは開けません |
| OpenCode | `ssh -N agent-box` を実行したまま、ブラウザで http://localhost:4096 を開きます。ユーザー名は `opencode`、パスワードは `ssh agent-box sudo cat /etc/agent-env/opencode-server.env` で確認します | `opencode serve`（`agent-env-opencode.service`）。PC 内（127.0.0.1）だけで待ち受け、SSH で転送します |

どちらのセッションも `agent` ユーザーの `~/work` で始まります。リポジトリの clone や worktree の作成はエージェントに任せます。

Claude Code の Remote Control は、Claude にログインすると自動で起動します（`agent-env-claude-remote.path`）。サービスの状態は `journalctl -u agent-env-claude-remote` と `journalctl -u agent-env-opencode` で確認できます。bootstrap は動作中のサービスを再起動しないので、ユニットの変更は PC の再起動か `sudo systemctl restart <ユニット名>` で反映してください。

## ローカル LLM
NVIDIA の GPU がある PC では、llama.cpp の `llama-server` がサービス（`agent-env-llama.service`、`llama` ユーザー）として動きます。PC 内（127.0.0.1:8080）だけで待ち受け、OpenAI 互換の API（`/v1`）とチャット画面を提供します。

- モデルは `tools.conf` の `LLAMA_FILES` で固定し、`system/llama-models.ini` で設定しています。初回の bootstrap でダウンロードするので、完了まで時間がかかります。

  | モデル名 | 用途 | モデル |
  |---|---|---|
  | `qwen3.6-35b-a3b` | 文章の生成と画像の読み取り | Qwen3.6 35B-A3B（4bit 量子化、約 22GB）と画像入力用の mmproj（約 0.9GB）。MoE のモデルで、VRAM（8GB）に収まらないエキスパートは `--fit` が自動でメインメモリ側に置きます |
  | `qwen3-embedding-0.6b` | 埋め込み（`/v1/embeddings`） | Qwen3-Embedding-0.6B（約 0.6GB）。CPU だけで動かします |

- llama-server はルーターモードで動き、リクエストの `"model"` で指定されたモデルを必要になった時点で読み込みます（同時に 2 つまで）。初回の呼び出しは読み込みの分だけ遅くなります。
- OpenCode からは、モデル `llama-cpp/qwen3.6-35b-a3b` として使えます（管理者用の設定で登録済み。画像も渡せます）。スクリプトなどからは `http://127.0.0.1:8080/v1` を直接呼び、`"model"` にモデル名を指定します。
- Mac からは、`ssh -N agent-box` を実行したまま http://localhost:8080 を開くとチャット画面を使えます。
- Claude Code と OpenCode には、ローカル LLM を使う場面を指示しています（`envs/debian-pc/system/agents/CLAUDE.md`）。外に出したくないデータの処理、大量のテキストの下処理、意味での検索などで使い、コードの設計や実装など品質が重要な作業には使いません。Claude Code は管理者用の CLAUDE.md（`/etc/claude-code/CLAUDE.md`）として、OpenCode は `instructions` として読みます。
  - この指示は毎回のリクエストに含まれるので短くしています。呼び出し方の詳細（`agents/local-llm.md`、PC では `/etc/agent-env/local-llm.md`）は、使うときにエージェントが読みます。
- モデルを追加・削除するときは、`tools.conf` の `LLAMA_FILES`、`system/llama-models.ini`、`envs/debian-pc/system/opencode/opencode.jsonc` を書き換えます。`tools.conf` から消したファイルは、次の bootstrap で消えます。モデルは / （128GB）に置くので、合計サイズに注意してください。
- llama.cpp は毎日リリースされるので、Renovate の更新 PR は週 1 回です。バージョンと SHA256（GitHub がリリースの添付ファイルごとに公開している値）を一緒に更新します。

## 更新
### Debian とツールの更新（自動）
セキュリティ更新などは `unattended-upgrades` が毎日自動で適用します。再起動が必要な場合は 04:30 に自動で再起動しますが、ログイン中のユーザーがいるときは再起動しません。その場合は `/run/reboot-required` が残るので、作業の区切りで `sudo reboot` してください。

Claude Code（公式 apt リポジトリの stable チャンネル）と mise の更新も、同じ仕組みで毎日自動で適用します。NVIDIA ドライバーは自動更新の対象外で、ブランチを `bootstrap.sh` の `nvidia-driver-pinning-*` で固定しています。カーネルが更新されたときは DKMS が同じ鍵でモジュールを作り直すので、MOK の登録はやり直す必要がありません。OpenCode のバージョンは `tools.conf` で固定していて、Renovate の更新 PR を `main` にマージしたあと、次の「このリポジトリの変更」の手順で反映します。

### このリポジトリの変更（手動）
`main` にマージしただけでは PC は変わりません。PC に反映するには、管理者が次を実行します。
```bash
ssh -t agent-box sudo /opt/agent-env/envs/debian-pc/apply.sh
```
反映するコミットの SHA、コミット一覧、差分が表示されます。内容を確認して `yes` と入力した場合だけ、そのコミットに更新して bootstrap を実行します。新しいコミットがない場合も、`yes` と入力すれば bootstrap を再実行できます。

次の場合は、何も変更せずに終了します。
- `yes` 以外を入力した
- 端末がない（`ssh` に `-t` を付けていない、cron から実行した など）
- 初回セットアップが完了していない
- 別の `apply.sh` が実行中である
- `/opt/agent-env` に未コミットの変更がある、または `main` 以外のブランチになっている
- PC のコミットが `main` の履歴に含まれていない

実行結果（反映前後の SHA、実行したユーザー、bootstrap の出力と結果）は `/var/log/agent-env/apply.log` に記録されます。履歴は `grep -E ' (START|OK|NG) ' /var/log/agent-env/apply.log` で確認できます。

bootstrap が失敗した場合、変更は自動では元に戻りません。PC は失敗したコミットのままになるので、修正（または revert）を `main` にマージしてから、もう一度 `apply.sh` を実行してください。ネットワーク障害などの一時的な失敗であれば、そのまま再実行すれば直ります。

`main` にはブランチ保護を設定し、CI の成功をマージの条件にしておいてください。

### 初回セットアップが失敗し続ける場合
原因の修正を `main` にマージしてから、次を実行します。
```bash
ssh -t agent-box 'sudo systemctl stop agent-env-firstboot && sudo git -C /opt/agent-env pull --ff-only origin main && sudo systemctl start agent-env-firstboot'
```

### Debian のバージョン
ベースにする Debian ISO のバージョンは `envs/debian-pc/iso.conf` で固定しています。新しいポイントリリースが出ると Renovate が更新の PR を作ります。この PR は自動ではマージされないので、ハッシュを [Debian の署名付き SHA256SUMS](https://www.debian.org/CD/verify) で確認してからマージしてください。

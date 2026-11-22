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

`agent` には sudo 権限がありません。エージェントのツールに apt パッケージが必要な場合は、`envs/debian-pc/packages.txt` に追加してください。言語ツールは各プロジェクトの `mise.toml` で管理します。

## 方針
- PC は使い捨てにし、状態はリポジトリと外部に置きます。作り直すときは ISO から再インストールするだけです。
- 人間用ユーザーとエージェント用ユーザーを分け、エージェントには sudo 権限を与えません。
- エージェントのツールの設定のうち、エージェント自身に変えられたくないもの（OpenCode で使えるモデル提供元など）は、root 所有の管理者用の設定に置きます。管理者用の設定は、ユーザーやプロジェクトの設定より優先されます。
- 秘密情報はリポジトリに入れません。ISO にはパスワードのハッシュと SSH 公開鍵が入るため、CI でも ISO は公開しません。

## 構成
```
envs/debian-pc/                Debian 13 の実 PC
  build-iso-in-container.sh    ISO を作り、USB メモリに書き込む（通常はこれを実行する）
  build-iso.sh                 ISO を作る（コンテナ内で実行される）
  write-usb.sh                 ISO を USB メモリに書き込む（macOS 専用）
  preseed.cfg                  インストーラへの応答
  select-disk.sh               インストール先ディスクの選択画面
  late-command.sh              インストールの最後に、リポジトリと SSH を設定する
  bootstrap.sh                 PC をセットアップする（冪等）
  apply.sh                     main の変更を、確認・承認したうえで PC に反映する
  packages.txt                 インストールするパッケージ
  tools.conf                   apt で入らないツール（OpenCode）のバージョンとハッシュ
  system/                      systemd ユニット、apt の設定とリポジトリ、エージェントのツールの管理者用の設定
.github/workflows/             CI（静的検査、ISO のビルド、bootstrap と apply.sh のテスト）
```

## インストール
1. Mac で GitHub の `main` をチェックアウトし、USB メモリを挿して次を実行します。
   ```bash
   envs/debian-pc/build-iso-in-container.sh
   ```
   ISO の作成から USB メモリへの書き込みまでを行います。
   - ビルドはコンテナ内で行うため、Mac にツールを入れる必要はありません。Apple の `container`、`docker`、`podman` のいずれかが必要です（`container` の場合は、先に `container system start` を実行してください）。
   - 人間用ユーザー `owner` のパスワードはランダムに生成され、画面と `out/agent-env-debian-pc.password` に出力されます。パスワードマネージャーに保存したら、このファイルは削除してください。
   - SSH 公開鍵（`~/.ssh/id_ed25519.pub` などを自動で探します。`--ssh-key` で指定も可能）が `owner` に登録されます。SSH のパスワードログインは無効です。
   - 書き込み先の候補には外付けディスクだけが表示されます。ディスク名（例: `disk4`）を入力し、確認のため `ERASE disk4` と入力すると書き込みが始まります。書き込み後は内容を検証し、USB メモリを取り出します。
   - ISO には現在のコミットが入ります。未コミットの変更がある場合や、現在のコミットが GitHub の `main` と異なる場合は中断します（`main` 以外から作った PC では、あとで `apply.sh` を使えなくなるため）。検証用に別のコミットから作る場合だけ `--allow-non-main` を付けます。
   - 書き込みだけをやり直す場合は `envs/debian-pc/write-usb.sh` を実行します。書き込みを省く場合は `--no-write` を付けます。
2. PC を USB メモリから起動し、メニューの `agent-env: Automated install (ERASES DISK)` を選んで Enter を押します。誤って再インストールしないよう、メニューは自動では進みません。
3. 一覧からインストール先のディスクを選び、確認画面で `Yes` を選びます（既定は `No`）。選んだディスクのデータはすべて消去されます。USB メモリ自体は一覧に表示されません。この後は自動で進みます。
4. 初回起動時に bootstrap が自動で実行されます。失敗した場合は 60 秒ごとに再試行します。進み具合は `journalctl -fu agent-env-firstboot` で確認できます。
5. エージェントの認証をします（初回のみ）。手順は「エージェントの準備」を参照してください。

## エージェントの準備
初回セットアップが終わると、Claude Code（`claude`）、OpenCode（`opencode`）、mise、gh が入っています。認証情報はリポジトリにも ISO にも入らないので、最初に一度だけ手で設定します。

```bash
ssh -t agent-box sudo -iu agent
```

`agent` ユーザーで次を実行します。
- Claude Code: `claude` を起動してログインします。表示された URL を Mac のブラウザで開いて認証します。
- OpenCode: `opencode` を起動し、`/connect` で OpenAI を選んで ChatGPT のプランでサインインします。管理者用の設定で、OpenAI 以外のモデル提供元は使えないようにしています。
- GitHub: [fine-grained personal access token](https://github.com/settings/personal-access-tokens) を発行し、`gh auth login --with-token` に標準入力で渡してから `gh auth setup-git` を実行します。トークンは対象のリポジトリに限定し、権限は Contents と Pull requests の Read and write だけにして、有効期限を付けてください。`main` へのマージはブランチ保護で防ぎます。

エージェントのツールの管理者用の設定（`envs/debian-pc/system/claude-code/`、`envs/debian-pc/system/opencode/`）は、bootstrap が `/etc/claude-code/` と `/etc/opencode/` に配置します。`agent` ユーザーの設定では上書きできません。

## Mac からの接続
PC は `agent-box.local` という名前で LAN 内に公開されます。`~/.ssh/config` に次を追加すると、`ssh agent-box` で接続できます。
```
Host agent-box
  HostName agent-box.local
  User owner
```
再インストールすると SSH のホスト鍵が変わります。`ssh-keygen -R agent-box.local` で古い鍵を削除し、初回接続時に表示される fingerprint が、PC のログイン画面に表示される `SSH host key:` と一致することを確認してください。

## 更新
### Debian とツールの更新（自動）
セキュリティ更新などは `unattended-upgrades` が毎日自動で適用します。再起動が必要な場合は 04:30 に自動で再起動しますが、ログイン中のユーザーがいるときは再起動しません。その場合は `/run/reboot-required` が残るので、作業の区切りで `sudo reboot` してください。

Claude Code（公式 apt リポジトリの stable チャンネル）と mise の更新も、同じ仕組みで毎日自動で適用します。OpenCode のバージョンは `tools.conf` で固定していて、Renovate の更新 PR を `main` にマージしたあと、次の「このリポジトリの変更」の手順で反映します。

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

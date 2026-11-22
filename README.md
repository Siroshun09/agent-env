# agent-env

エージェント専用 PC を、いつでも作り直せる形でセットアップするためのリポジトリです。

## 対象範囲
このリポジトリでは、root 権限が必要な PC 側の設定だけを扱います。エージェント自身の環境は、別のリポジトリで管理します。

| このリポジトリ | 別リポジトリ（agent 側） |
|---|---|
| OS のインストールとパーティション | Claude Code などのエージェント本体 |
| ユーザーの分離（人間用の `owner` / エージェント用の `agent`） | 言語ツール（mise など）とそのバージョン |
| 基本パッケージと podman | シェル設定、秘密情報の読み込み |
| OS の更新設定 | エージェントの作業データ |

`agent` には sudo 権限がありません。エージェントのツールに apt パッケージが必要な場合は、`envs/debian-pc/packages.txt` に追加してください。

## 方針
- PC は使い捨てにし、状態はリポジトリと外部に置きます。作り直すときは ISO から再インストールするだけです。
- 人間用ユーザーとエージェント用ユーザーを分け、エージェントには sudo 権限を与えません。
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
  system/                      systemd ユニットと apt の設定
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
   - ISO には現在のコミットが入ります。未コミットの変更がある場合は中断します。`main` 以外のコミットから作った PC には、あとで `apply.sh` で変更を反映できません。
   - 書き込みだけをやり直す場合は `envs/debian-pc/write-usb.sh` を実行します。書き込みを省く場合は `--no-write` を付けます。
2. PC を USB メモリから起動し、メニューの `agent-env: Automated install (ERASES DISK)` を選んで Enter を押します。誤って再インストールしないよう、メニューは自動では進みません。
3. 一覧からインストール先のディスクを選び、確認画面で `Yes` を選びます（既定は `No`）。選んだディスクのデータはすべて消去されます。USB メモリ自体は一覧に表示されません。この後は自動で進みます。
4. 初回起動時に bootstrap が自動で実行されます。失敗した場合は 60 秒ごとに再試行します。進み具合は `journalctl -fu agent-env-firstboot` で確認できます。
5. `sudo -iu agent` でエージェント用ユーザーに切り替え、agent 側のリポジトリでセットアップします。

## Mac からの接続
PC は `agent-box.local` という名前で LAN 内に公開されます。`~/.ssh/config` に次を追加すると、`ssh agent-box` で接続できます。
```
Host agent-box
  HostName agent-box.local
  User owner
```
再インストールすると SSH のホスト鍵が変わります。`ssh-keygen -R agent-box.local` で古い鍵を削除し、初回接続時に表示される fingerprint が、PC のログイン画面に表示される `SSH host key:` と一致することを確認してください。

## 更新
### Debian の更新（自動）
セキュリティ更新などは `unattended-upgrades` が毎日自動で適用します。再起動が必要な場合は 04:30 に自動で再起動しますが、ログイン中のユーザーがいるときは再起動しません。その場合は `/run/reboot-required` が残るので、作業の区切りで `sudo reboot` してください。

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
ベースにする Debian ISO のバージョンは `envs/debian-pc/iso.conf` で固定しています。

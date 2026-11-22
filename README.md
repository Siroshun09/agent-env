# agent-env

エージェント専用の作業環境を、再現可能かつ使い捨て可能な形でセットアップする。

## 方針
- **環境は使い捨て、状態はリポジトリと外部に置く。** 作り直しは「再インストール → bootstrap」の1手順。
- 人間用ユーザーとエージェント用ユーザー（`agent`、sudo なし）を分ける。root 権限が要る変更はこのリポジトリに書く。
- 言語ツールのバージョンは `shared/mise.toml` で固定し、全環境で揃える。Claude Code は最新版を使う。
- 秘密情報はリポジトリに入れない（`~/.secrets/env` に手で置く）。

## 構成
```
shared/                 OS 非依存。全環境で共通
  setup-user.sh         エージェント用ユーザーとして実行（root 不要・冪等）
  mise.toml             node / uv / gh のバージョン
  shell/agentenv        環境変数・秘密情報の読み込み（login シェル）
  shell/agentrc         対話シェル設定（bash / zsh）
envs/<name>/            OS・環境ごと。root 権限の処理とインストーラ
  debian-pc/            Debian 13 の実 PC
    build-iso.sh        無人インストール ISO を作る
    preseed.cfg         インストーラの応答（テンプレート）
    late-command.sh     インストール直後の処理（リポジトリ配置、初回起動の設定）
    bootstrap.sh        root 権限のセットアップ（初回起動時・毎日の更新で実行）
    update.sh           リポジトリを pull して bootstrap を再実行
    system/             systemd ユニット、apt 設定
out/                    生成物（.gitignore）
```

各 `envs/<name>/` の役割は次の3つ。
1. OS のパッケージと `mise` / `curl` / `git` を入れる
2. エージェント用ユーザーを作る
3. そのユーザーとして `shared/setup-user.sh` を実行する

新しい OS・環境（例: `envs/macos/`、`envs/podman/`）はこの形で追加する。

## 環境

### debian-pc
手作業は「ISO 作成 → USB 書き込み → 起動して Enter → インストール先ディスクの選択」と、最後の秘密情報の配置だけ。

1. Linux か macOS で ISO を作る（`git`, `curl`, `xorriso`, `cpio`, `gzip` が必要。macOS は `brew install xorriso`）。
   ```bash
   envs/debian-pc/build-iso.sh --ssh-key ~/.ssh/id_ed25519.pub
   ```
   - 人間用ユーザー（sudo あり、既定名 `owner`）のパスワードはランダムに生成され、表示と `out/agent-env-debian-pc.password` への保存が行われる。パスワードマネージャ等に保存したら、ISO とパスワードファイルは削除する。
   - `--user` で人間用ユーザーの名前を変えられる（`admin` は Debian の予約名で使えない）。
   - `--ssh-key` を指定すると人間用ユーザーに鍵が登録され、SSH のパスワードログインは無効になる。
   - ISO には commit 済みの内容が入る（未コミットの変更があると中断する）。
2. ISO を USB メモリに書き込む（書き込み先を取り違えないよう、リムーバブルドライブだけを表示するツールを推奨）。
3. PC を USB から起動し、メニュー先頭の `agent-env: Automated install (ERASES DISK)` で Enter を押す。
   - 誤って再インストールしないよう、メニューは自動では進まない。
4. インストール先ディスクを一覧から選ぶ（選んだディスクは全消去される）。以降は無人で進み、再起動する。
5. 初回起動時に `agent-env-firstboot.service` が bootstrap を実行する（失敗時は 60 秒ごとに再試行）。進捗は `journalctl -fu agent-env-firstboot`。
6. `sudo -iu agent` で入り、`~/.secrets/env` に API キー等を置く。

リポジトリは `/opt/agent-env` に配置される。

#### 運用（自動更新）
| 対象 | 仕組み | タイミング |
|---|---|---|
| Debian のセキュリティ更新・安定版更新、mise | `unattended-upgrades` | 毎日。再起動が必要なら 04:30 に自動再起動 |
| このリポジトリの変更（パッケージ・ツールのバージョン等） | `agent-env-update.timer` が `main` を pull して bootstrap を再実行 | 毎日 03:00 頃 |
| Claude Code | 自身の自動更新 ＋ 上記 bootstrap 内の `claude update` | 使用時・毎日 |

設定やツールのバージョンを変えるときは、このリポジトリに PR を出してマージするだけでよい。すぐ反映したい場合:
```bash
sudo systemctl start agent-env-update
```
状況確認は `journalctl -u agent-env-update` / `systemctl list-timers agent-env-update`。失敗は `systemctl --failed` に出る。
自動再起動を止めたい場合は `envs/debian-pc/system/apt/52agent-env-unattended-upgrades` の `Automatic-Reboot` を `false` にする。

Debian ISO のバージョンは `envs/debian-pc/iso.conf` で固定している。

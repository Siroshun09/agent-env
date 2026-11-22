# agent-env

エージェント専用の作業環境を、再現可能かつ使い捨て可能な形でセットアップする。

## 方針
- **環境は使い捨て、状態はリポジトリと外部に置く。** 作り直しは「再インストール → bootstrap」の1手順。
- 人間用ユーザーとエージェント用ユーザー（`agent`、sudo なし）を分ける。root 権限が要る変更はこのリポジトリに書く。
- ツールのバージョンは `shared/` で固定し、全環境で揃える。
- 秘密情報はリポジトリに入れない（`~/.secrets/env` に手で置く）。

## 構成
```
shared/                 OS 非依存。全環境で共通
  setup-user.sh         エージェント用ユーザーとして実行（root 不要・冪等）
  mise.toml             node / uv / gh のバージョン
  claude-version        Claude Code のバージョン（自動更新は無効化）
  shell/agentrc         対話シェル設定（bash / zsh）
envs/<name>/            OS・環境ごと。root 権限の処理とインストーラ
  debian-pc/            Debian 13 の実 PC
```

各 `envs/<name>/` の役割は次の3つ。
1. OS のパッケージと `mise` / `curl` / `git` を入れる
2. エージェント用ユーザーを作る
3. そのユーザーとして `shared/setup-user.sh` を実行する

新しい OS・環境（例: `envs/macos/`、`envs/podman/`）はこの形で追加する。

## 環境

### debian-pc
1. Debian 13 netinst を USB に書き込み、起動メニューで `envs/debian-pc/preseed.cfg` を指定する（ファイル冒頭のコメント参照）。ディスクは全消去される。
2. インストール中に `admin` のパスワードを入力する。インストール後、`late_command` が bootstrap を実行する。手動で入れた場合は:
   ```bash
   sudo git clone https://github.com/Siroshun09/agent-env.git /opt/agent-env && sudo /opt/agent-env/envs/debian-pc/bootstrap.sh
   ```
3. `sudo -iu agent` で入り、`~/.secrets/env` に API キー等を置く。

設定変更はリポジトリを編集して bootstrap を再実行する（冪等）。

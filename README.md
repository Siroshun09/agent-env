# agent-env

Debian 13 (trixie) をエージェント専用 PC として再現可能にセットアップする。

## 方針
- **OS は使い捨て、状態はリポジトリと外部に置く。** 作り直しは「再インストール → bootstrap」の1手順。
- `admin`（人間・sudo あり）と `agent`（エージェント・sudo なし）を分ける。root 権限が要る変更はこのリポジトリに書く。
- ツールのバージョンは `config/mise.toml` と `config/claude-version` に固定する。
- 秘密情報はリポジトリに入れない（`/home/agent/.secrets/env` に手で置く）。

## 使い方
1. Debian 13 netinst を USB に書き込み、起動メニューで `installer/preseed.cfg` を指定する（ファイル冒頭のコメント参照）。ディスクは全消去される。
2. インストール中に `admin` のパスワードを入力する。インストール後、`late_command` が `bootstrap.sh` を実行する。手動で入れた場合は:
   ```bash
   sudo git clone https://github.com/Siroshun09/agent-env.git /opt/agent-env && sudo /opt/agent-env/bootstrap.sh
   ```
3. `sudo -iu agent` で入り、`~/.secrets/env` に API キー等を置く。

設定変更はリポジトリを編集して `sudo /opt/agent-env/bootstrap.sh` を再実行する（冪等）。

## ファイル
| パス | 役割 |
|---|---|
| `bootstrap.sh` | 本体。apt・ユーザー・mise・Claude Code を設定 |
| `config/packages.txt` | apt パッケージ |
| `config/mise.toml` | node / uv / gh のバージョン |
| `config/claude-version` | Claude Code のバージョン（自動更新は無効化） |
| `config/bashrc.local` | agent ユーザーのシェル設定 |
| `installer/preseed.cfg` | Debian インストーラの無人応答 |

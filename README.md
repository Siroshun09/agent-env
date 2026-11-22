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
    build-iso.sh        無人インストール ISO を作る
    preseed.cfg         インストーラの応答（テンプレート）
    bootstrap.sh        root 権限のセットアップ（初回起動時に自動実行）
out/                    生成物（.gitignore）
```

各 `envs/<name>/` の役割は次の3つ。
1. OS のパッケージと `mise` / `curl` / `git` を入れる
2. エージェント用ユーザーを作る
3. そのユーザーとして `shared/setup-user.sh` を実行する

新しい OS・環境（例: `envs/macos/`、`envs/podman/`）はこの形で追加する。

## 環境

### debian-pc
手作業は「ISO 作成 → USB 書き込み → 起動して Enter」と、最後の秘密情報の配置だけ。

1. 任意の Linux マシンで ISO を作る（`git`, `curl`, `xorriso`, `cpio`, `openssl` が必要）。
   ```bash
   envs/debian-pc/build-iso.sh --disk /dev/nvme0n1 --ssh-key ~/.ssh/id_ed25519.pub
   ```
   - `admin` のパスワードを聞かれる。ハッシュだけが ISO に入る。
   - `--disk` はインストール先（全消去）。ディスクが複数ある PC では必ず指定する。
   - `--ssh-key` を指定すると admin に鍵が登録され、SSH のパスワードログインは無効になる。
   - ISO には commit 済みの内容が入る（未コミットの変更があると中断する）。
   - 生成物 `out/agent-env-debian-pc.iso` にはパスワードハッシュが入るので共有しない。
2. ISO を USB メモリに書き込む（書き込み先を取り違えないよう、リムーバブルドライブだけを表示するツールを推奨）。
3. PC を USB から起動し、メニュー先頭の `agent-env: Automated install (ERASES DISK)` で Enter を押す。以降は無人で進み、再起動する。
   - 誤って再インストールしないよう、メニューは自動では進まない。
4. 初回起動時に `agent-env-firstboot.service` が bootstrap を実行する（失敗時は 60 秒ごとに再試行）。進捗は `journalctl -fu agent-env-firstboot`。
5. `sudo -iu agent` で入り、`~/.secrets/env` に API キー等を置く。

リポジトリは `/opt/agent-env` に配置される。設定変更は `git pull` してから bootstrap を再実行する（冪等）。
```bash
sudo git -C /opt/agent-env pull && sudo /opt/agent-env/envs/debian-pc/bootstrap.sh
```

Debian ISO のバージョンは `envs/debian-pc/iso.conf` で固定している。

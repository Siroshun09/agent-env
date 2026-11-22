# agent-env

エージェント専用の作業環境を、再現可能かつ使い捨て可能な形でセットアップする。

## 責務
このリポジトリが管理するのは **PC 側（root 権限の領域）** まで。

| 管理する | 管理しない（agent 側の別リポジトリで管理） |
|---|---|
| OS インストール、パーティション | Claude Code などエージェント本体 |
| ユーザー分離（人間用 / `agent`） | 言語ツール（mise 等）とそのバージョン |
| 基本パッケージ、podman | シェル設定、秘密情報の読み込み |
| 自動更新（セキュリティパッチ、このリポジトリの反映） | エージェントの作業データ |

`agent` には sudo が無いので、エージェントのツールが前提とする OS パッケージ（apt）は `envs/<name>/packages.txt` に追加する。

## 方針
- **環境は使い捨て、状態はリポジトリと外部に置く。** 作り直しは「ISO で再インストール」の1手順。
- 人間用ユーザーとエージェント用ユーザー（`agent`、sudo なし）を分ける。
- 秘密情報はリポジトリに入れない。

## 構成
```
envs/<name>/            OS・環境ごと
  debian-pc/            Debian 13 の実 PC
    build-iso.sh        無人インストール ISO を作る
    build-iso-in-container.sh  上記を使い捨てコンテナ内で実行する
    verify-iso.sh       生成した ISO の中身を検査する
    preseed.cfg         インストーラの応答（テンプレート）
    select-disk.sh      インストール先ディスクの選択画面
    late-command.sh     インストール直後の処理（リポジトリ配置、初回起動の設定）
    bootstrap.sh        root 権限のセットアップ（初回起動時・毎日の更新で実行）
    update.sh           リポジトリを pull して bootstrap を再実行
    packages.txt        基本パッケージ
    system/             systemd ユニット、apt 設定
out/                    生成物（.gitignore）
.github/workflows/
  lint.yml              リポジトリ全体の静的検査（shellcheck、actionlint、zizmor）
  env-<name>.yml        環境ごとの検査（envs/<name>/ の変更時に実行）
```

CI はビルドが通ることの検査だけを行う。ISO にはパスワードのハッシュと SSH 公開鍵が入るため、成果物としては公開しない。

新しい OS・環境は `envs/<name>/` と、その検査用の `.github/workflows/env-<name>.yml` を追加する。

## 環境

### debian-pc
手作業は「ISO 作成 → USB 書き込み → 起動して Enter → インストール先ディスクの選択と確認」だけ。

1. ISO を作る。使い捨てのコンテナ内でビルドするので、ホストにツールを入れる必要はない。
   ```bash
   envs/debian-pc/build-iso-in-container.sh
   ```
   - コンテナランタイムは Apple の `container`（macOS 26+、事前に `container system start`）、`docker`、`podman` の順に自動で選ぶ。
   - コンテナを使わない場合は `envs/debian-pc/build-iso.sh` を直接実行する（`git`, `curl`, `xorriso`, `cpio`, `gzip`, `passwd -6` に対応した `openssl` が必要。macOS 標準の LibreSSL は不可）。
   - Debian ISO のダウンロードは `out/cache/` にキャッシュされる。
   - 人間用ユーザー（sudo あり、既定名 `owner`）のパスワードはランダムに生成され、表示と `out/agent-env-debian-pc.password` への保存が行われる。ISO にはハッシュ（SHA-512 crypt）だけが入る。パスワードマネージャ等に保存したら、パスワードファイルは削除する。
   - `--user` で人間用ユーザーの名前を変えられる（`admin` は Debian の予約名で使えない）。
   - SSH 公開鍵（既定は `~/.ssh/id_ed25519.pub` → `id_ecdsa.pub` → `id_rsa.pub` の順に自動検出、`--ssh-key` で指定可）が人間用ユーザーに登録され、SSH のパスワードログインは無効になる。鍵が無ければ中断する（鍵なしで作るなら `--no-ssh-key`）。
   - 本番用の ISO は、GitHub の `main` と同じコミットをチェックアウトしているときだけ作れる（インストール後の自動更新が `main` を追従するため）。検証用に別ブランチや未 push のコミットから作るには `--allow-non-main` が必要で、`main` 以外から作った PC の自動更新は停止する。
   - ISO には commit 済みの内容が入る（未コミットの変更があると中断する）。
2. ISO を USB メモリに書き込む（書き込み先を取り違えないよう、リムーバブルドライブだけを表示するツールを推奨）。
3. PC を USB から起動し、メニュー先頭の `agent-env: Automated install (ERASES DISK)` で Enter を押す。
   - 誤って再インストールしないよう、メニューは自動では進まない。
4. インストール先ディスクを一覧（容量・接続方式・モデル・シリアル番号）から選び、確認画面で `Yes` を選ぶ（既定は `No` で一覧に戻る。選んだディスクは全消去される）。インストールメディア自身は一覧に出ない。以降は無人で進み、再起動する。
5. 初回起動時に `agent-env-firstboot.service` が bootstrap を実行する（失敗時は 60 秒ごとに再試行）。進捗は `journalctl -fu agent-env-firstboot`。
6. `sudo -iu agent` で入り、agent 側の環境（別リポジトリ）をセットアップする。

リポジトリは `/opt/agent-env` に配置される。

#### Mac からの接続
ホスト名 `agent-box` を mDNS（avahi）で公開するので、同じ LAN の Mac から IP を調べずに接続できる。root ログインは無効。
```
# ~/.ssh/config
Host agent-box
  HostName agent-box.local
  User owner
```
```bash
ssh agent-box
```
- 再インストールするとホスト鍵が変わる。`ssh-keygen -R agent-box.local` で古い鍵を消し、初回接続時に表示される fingerprint を PC のコンソール（ログイン画面に `SSH host key:` として表示される）と照合する。
- エージェントとして作業するときは `ssh agent-box` 後に `sudo -iu agent`。

#### 運用（自動更新）
| 対象 | 仕組み | タイミング |
|---|---|---|
| Debian のセキュリティ更新・安定版更新 | `unattended-upgrades` | 毎日。再起動が必要なら 04:30 に自動再起動 |
| このリポジトリの変更（パッケージ・設定） | `agent-env-update.timer` が `main` を pull して bootstrap を再実行。bootstrap が失敗したら更新前のコミットに戻す | 毎日 03:00 頃（初回セットアップ完了後） |

パッケージや設定を変えるときは、このリポジトリに PR を出してマージするだけでよい。すぐ反映したい場合:
```bash
sudo systemctl start agent-env-update
```
`main` 以外がチェックアウトされているときは切り替えずに停止する。初回セットアップ・更新・手動の bootstrap はロックで排他され、同時には動かない。

`main` へのマージは root 権限でこの PC に適用されるので、`main` にはブランチ保護と必須チェックを設定しておく。

状況確認は `journalctl -u agent-env-update` / `systemctl list-timers agent-env-update`。失敗は `systemctl --failed` に出る。
自動再起動を止めたい場合は `envs/debian-pc/system/apt/52agent-env-unattended-upgrades` の `Automatic-Reboot` を `false` にする。

Debian ISO のバージョンは `envs/debian-pc/iso.conf` で固定している。

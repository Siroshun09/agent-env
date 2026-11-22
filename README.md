# agent-env

エージェント専用の作業環境を、再現可能かつ使い捨て可能な形でセットアップする。

## 責務
このリポジトリが管理するのは **PC 側（root 権限の領域）** まで。

| 管理する | 管理しない（agent 側の別リポジトリで管理） |
|---|---|
| OS インストール、パーティション | Claude Code などエージェント本体 |
| ユーザー分離（人間用 / `agent`） | 言語ツール（mise 等）とそのバージョン |
| 基本パッケージ、podman | シェル設定、秘密情報の読み込み |
| Debian のセキュリティ更新（自動）、このリポジトリの反映（手動） | エージェントの作業データ |

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
    bootstrap.sh        root 権限のセットアップ（初回起動時と apply.sh から実行。冪等）
    apply.sh            main の変更を確認・承認して手動で反映する
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
   - 本番用の ISO は、GitHub の `main` と同じコミットをチェックアウトしているときだけ作れる（インストール後に反映できるのは `main` だけのため）。検証用に別ブランチや未 push のコミットから作るには `--allow-non-main` が必要で、`main` 以外から作った PC では `apply.sh` による反映はできない。
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

#### 運用（更新と反映）
| 対象 | 仕組み | タイミング |
|---|---|---|
| Debian のセキュリティ更新・安定版更新 | `unattended-upgrades` | 自動（毎日）。再起動が必要なら 04:30 に自動再起動 |
| このリポジトリの変更（パッケージ・設定） | 管理者が `apply.sh` を実行して反映 | 手動のみ |

`main` へのマージだけでは PC は変わらない。PC への反映は、管理者が内容を確認して承認する最終ステップとして分けている。
```bash
ssh -t agent-box sudo /opt/agent-env/envs/debian-pc/apply.sh
```
1. GitHub から `main` を取得し、現在と反映先のコミット SHA、コミット一覧、差分を表示する。
2. `yes` と入力したときだけ fast-forward して bootstrap を root で実行する。それ以外の入力や、端末を伴わない実行（`ssh agent-box sudo ...` のように `-t` なし、cron 等）では何も変更せずに終了する。
3. 新しいコミットが無い場合も、承認すれば現在のコミットで bootstrap を再実行する。

- 反映できるのは `main` だけ。未コミットの変更がある場合や、`main` の履歴が書き換えられて fast-forward できない場合は中断する。
- 初回セットアップ（`agent-env-firstboot`）の実行中・再試行待ちの間は実行できない。
- root 専用。`agent` には sudo が無いので反映できない。
- 反映前後のコミット SHA、承認したユーザー、bootstrap の出力と結果を `/var/log/agent-env/apply.log` に記録する（`grep -E ' (START|OK|NG) ' /var/log/agent-env/apply.log` で履歴を確認できる）。

bootstrap が失敗した場合は失敗として終了し、自動では元に戻さない（OS 設定の完全なロールバックは保証できないため）。リポジトリは失敗したコミットのまま残るので、`git -C /opt/agent-env log -1` とログで原因を確認し、修正（または revert）を `main` にマージしてから再度 `apply.sh` を実行する。一時的な失敗なら、そのまま再実行すればよい（bootstrap は冪等）。

`main` にはブランチ保護と必須チェックを設定しておく。

自動再起動を止めたい場合は `envs/debian-pc/system/apt/52agent-env-unattended-upgrades` の `Automatic-Reboot` を `false` にする。

Debian ISO のバージョンは `envs/debian-pc/iso.conf` で固定している。

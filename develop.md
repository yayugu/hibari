## 基本方針
- iPhone に特化する。iPadもそれなりに対応
- 120Hzでタイムラインをスクロールできる
- アニメーションやハプティックフィードバックをリッチにする
- タイムラインなどパフォーマンスが重要な場所はUIKitで、設定などそうでもないところはSwiftUIで

## 開発

Xcode 27.1。
実機で動かす場合は `Config/Signing.local.xcconfig`（gitignore）に Team ID と Bundle ID prefix を書きます（`Config/Signing.xcconfig` 参照）。
Debug / Perf 構成は Bundle ID の末尾に `.debug` が付き（表示名は「Hibari β」）、リリース版とは別アプリとしてインストールされます。

```sh
# ビルドして実行（Xcode で hibari スキームを Run でも可）
xcodebuild -scheme hibari -destination 'platform=iOS Simulator,name=iPhone 17' build

# Test
python3 scripts/test_unit.py
python3 scripts/test_ui.py
# 一部だけ: python3 scripts/test_unit.py -only-testing:hibariTests/TimelineTabTests
# 端末や並列数を変える場合: python3 scripts/test_ui.py --destination 'platform=iOS Simulator,id=...' --workers 2

# パフォーマンステスト（Perf 構成。実機は DESTINATION='platform=iOS,name=<端末名>'）
#    計測が必要な場合のみ実行
#    先にテストデータ（misskey.io のタイムラインとメディア、perf/Fixtures.bundle、約300MB）を取得する
scripts/fetch_fixtures.py
scripts/perf.sh
```

- UI テストは極めて実行が遅いため開発のボトルネックになっている。追加した場合はcommit前に残す価値があるか再検討して、なかったら削ること
- Unit Testは数秒、UITestは1分以内に終了するようにすること。テスト変更後にそれ以上かかるようになってしまった場合は全体をみて取捨選択や効率化すること

### ローカル Misskey（本物のサーバー）

Mock server（`scripts/mock_misskey.py`。UI テスト用）では確かめられないこと（実際の API の挙動、投稿・リアクション・通知など）は、Docker で手元に立てた本物の Misskey で試すことができます。Docker（OrbStack など）が必要です。

```sh
scripts/local_misskey.py up        # 起動。初回はセットアップとテストデータの投入も（30秒ほど）
scripts/local_misskey.py down      # 停止（データは残る）
scripts/local_misskey.py reset     # データを全部消して作り直す
scripts/local_misskey.py approve   # シミュレータのアプリで開いたログインの画面を許可して、ログインを終える
scripts/local_misskey.py post      # 新着ノートを作る（引っ張って更新の確認。-n 3 / --image 2 / --as alice / --text ... / --channel 雑談）
scripts/local_misskey.py notify    # @hibari に通知を作る（ノートへのリアクション・リノート・返信・引用、メンション、フォロー。--as hibari_sub）
```

- サーバーは `http://localhost:3000`。設定は `scripts/local_misskey/`。Web UI も Mac のブラウザでそのまま開ける。ログは `docker compose -f scripts/local_misskey/compose.yml logs -f web`

シミュレータから接続する
1. アプリのログイン画面（2つめ以降はドロワーの「⋯」→「アカウントを追加」）でサーバーに `http://localhost:3000` を入れる（起動引数 `-HibariSignInServer http://localhost:3000` で初期値にもできる）
2. 確認のダイアログで「続ける」を押し、アプリの中に Misskey の許可の画面（`ASWebAuthenticationSession`）が開いたら、どちらかで許可する
   - `scripts/local_misskey.py approve` を実行する。@hibari として許可し、アプリにコールバックの URL を送る（画面が閉じてログインが終わる）。別のアカウントは `--as hibari_sub`
   - 開いた画面で Misskey にログイン（@hibari / `hibari`）して「許可」する。実機では Safari のログインが共有されるので、Safari でログイン済みなら許可だけになるが、シミュレータでは共有されない
- `down` / `up` ではデータもトークンも残るので、一度ログインすればそのまま使える。`reset` するとトークンも無効になり、アプリはログインし直しを求める

外部と隔離された Docker ネットワーク（127.0.0.1 のみ公開、federation: none）で動くため外部サーバーとは連合しない（URL プレビューは内部の http://news.hibari.test/... のみ取得可）

## リリース

App Store への提出は `scripts/release.py` で行う。

```sh
scripts/release.py status                 # ストアのバージョンとビルドの状態
scripts/release.py release 1.2            # バージョンを上げ、archive・アップロードし、処理を待って 1.2 にリリースノートとビルドを設定する
scripts/release.py submit 1.2             # 審査に提出する（release に --submit を付けても同じ）
```

- リリースノート（「このバージョンの新機能」）は `release-notes/<バージョン>/<ロケール>.txt`。ストアのローカライズ（いまは `ja` のみ）ごとに1つ必要で、足りなければアップロードの前に止まる
- リリースノートは利用者向けに書く。技術的な詳細は書かず、何がよくなったかを短い箇条書きにする。対象は前のリリースのタグからの変更（`git log v1.1..`）
- リリースのタグは `v1.2` の形（注釈付き）で、審査に出したビルドを作ったコミットに付ける。`submit` が付ける（push はしない）
- `release`（`bump` と `upload`）は、`release-notes/` 以外にコミットしていない変更があると止まる。ビルドが HEAD そのものになるように。バージョンを上げた `project.pbxproj` は `chore: bump version to 1.2 (3)` としてコミットする
- 途中で止まったら、残りの手順だけを実行し直す（`upload` / `prepare 1.2` / `submit 1.2`）。`release` をやり直すとビルド番号がもう一度上がる

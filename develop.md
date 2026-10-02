## 基本方針
- iPhoneのみに特化する
- 120Hzでタイムラインをスクロールできる
- アニメーションやハプティックフィードバックをリッチにする
- タイムラインなどパフォーマンスが重要な場所はUIKitで、設定などそうでもないところはSwiftUIで

## 開発

Xcode 27 / iOS 27 SDK が必要です。
実機で動かす場合は `Config/Signing.local.xcconfig`（gitignore）に Team ID と Bundle ID prefix を書きます（`Config/Signing.xcconfig` 参照）。
Debug / Perf 構成は Bundle ID の末尾に `.debug` が付き（表示名は「Hibari β」）、リリース版とは別アプリとしてインストールされます。

```sh
# 1. ビルドして実行（Xcode で hibari スキームを Run でも可）
xcodebuild -scheme hibari -destination 'platform=iOS Simulator,name=iPhone 17' build

# 2. 普段のテスト（unit test）
xcodebuild -scheme hibari -destination 'platform=iOS Simulator,name=iPhone 17' test

# 3. UI テスト（別スキーム）
python3 scripts/test_ui.py
# 端末や並列数を変える場合: python3 scripts/test_ui.py --destination 'platform=iOS Simulator,id=...' --workers 2

# 4. パフォーマンステスト（Perf 構成。実機は DESTINATION='platform=iOS,name=<端末名>'）
#    先にテストデータ（misskey.io のタイムラインとメディア、perf/Fixtures.bundle、約300MB）を取得する
scripts/fetch_fixtures.py
scripts/perf.sh
```

### テストの選び方

- **unit test にする:** 入力と期待結果を画面を起動せずに確かめられる処理。モデルの変換、API のリクエスト・レスポンス、投稿やリアクションの状態遷移、アカウント選択、レイアウト計算などを `hibariTests` で検証する。通信は `StubURLProtocol` などで差し替え、実サーバーや固定ポートには依存させない。
- **unit test にしない:** 実際のタップ・スワイプ、画面遷移、システム画面との受け渡し。アプリを操作しないと確認できない導線だけを `hibariUITests` で短く検証する。モデルや API の結果、状態の組み合わせを UI テストで繰り返し確認しない。
- UI テストを追加する前に、表示したい状態を unit test で再現できないか確認する。UI が必要なら、要素はアクセシビリティ ID で探し、時間待ちではなく状態を待つ。並列実行を前提に、テスト同士で同じ mock の可変状態を取り合わないようにする。
- UI テストは極めて実行が遅いため開発のボトルネックになっている。追加した場合はcommit前に残す価値があるか再検討して、なかったら削ること
- UI テストは `scripts/test_ui.py` から実行する。スクリプトが実行ごとに空きポートの mock を起動し、終了時に停止する。別 worktree ではビルド出力もそれぞれの `build/DerivedData` を使う。`--workers` は Xcode の並列ワーカー数の上限を指定する。

### 一覧の更新方針

- `TimelineSource.refreshPolicy` の標準は `.replace`。更新に成功したら最新の先頭1ページで一覧を置き換え、ページングをやり直す。プロフィールの全タブ、ブックマーク・いいね、検索結果、ハイライト、通知はこの方針。
- ホーム・ローカル・ソーシャル・グローバルの時系列TLだけ `.preserveHistory`。読み込み済みの履歴を残して新着と変更を取り込み、未取得の区間は gap として埋める。永続スナップショットもこの方針のTLだけに付ける。
- 更新方針と画面のメモリ保持は別。タブ移動や詳細画面から戻るだけでは一覧を作り直さない。アプリ内のノート削除・リノート解除は共通の削除通知で反映し、ブックマーク解除はブックマーク一覧からだけ行を除去する。

### ローカルの Misskey（本物のサーバー）

偽サーバー（`scripts/mock_misskey.py`。UI テスト用）では確かめられないこと（実際の API の挙動、投稿・リアクション・通知など）は、Docker で手元に立てた本物の Misskey で試します。Docker（OrbStack など）が必要です。

```sh
scripts/local_misskey.py up        # 起動。初回はセットアップとテストデータの投入も（30秒ほど）
scripts/local_misskey.py down      # 停止（データは残る）
scripts/local_misskey.py reset     # データを全部消して作り直す
scripts/local_misskey.py approve   # シミュレータのアプリで開いたログインの画面を許可して、ログインを終える
scripts/local_misskey.py post      # 新着ノートを作る（引っ張って更新の確認。-n 3 / --image 2 / --as alice / --text ...）
scripts/local_misskey.py notify    # @hibari に通知を作る（ノートへのリアクション・リノート・返信・引用、メンション、フォロー。--as hibari_sub）
```

- サーバーは `http://localhost:3000`（公式イメージの Misskey 2026.9.1。設定は `scripts/local_misskey/`）。Web UI も Mac のブラウザでそのまま開ける。ログは `docker compose -f scripts/local_misskey/compose.yml logs -f web`
- アカウント（パスワードはすべて `hibari`）
  - `@hibari`: アプリで使うメイン。@alice @bob @carol @hibari_sub をフォロー
  - `@hibari_sub`: アカウント切り替え用。@bob だけフォロー
  - `@alice` `@bob`（猫） `@carol`、`@dave`（誰にもフォローされていないので @hibari のホームTLには出ない）、`@newsbot`（bot）
  - `@admin`: 管理者（Web のコントロールパネル用）
- ノートの検索は、Misskey の標準では許されていないので、セットアップで標準のロールに許可している（`canSearchNotes`）。トレンドは最近の投稿のハッシュタグから作られるので、複数のアカウントで `post --as alice --text "#ねこ"` などとすると出る
- テストデータ（`scripts/local_misskey.py` の `seed()`）: ノート約100件。MFM、カスタム絵文字（通常・横長・アニメーション）、画像（1〜4枚、縦長・パノラマ、代替テキスト）、GIF、動画、センシティブ、CW、投票、リノート、引用、返信のスレッド、メンション、ハッシュタグ、長文、公開範囲（フォロワー・ホーム・ダイレクト）、リアクション。画像と動画は Misskey のコンテナの ffmpeg で生成するので何もダウンロードしない。日時はすべて投入した時刻（API で過去の日時は指定できない）

シミュレータから接続する
1. アプリのログイン画面（2つめ以降はドロワーの「⋯」→「アカウントを追加」）でサーバーに `http://localhost:3000` を入れる（起動引数 `-HibariSignInServer http://localhost:3000` で初期値にもできる）
2. 確認のダイアログで「続ける」を押し、アプリの中に Misskey の許可の画面（`ASWebAuthenticationSession`）が開いたら、どちらかで許可する
   - `scripts/local_misskey.py approve` を実行する。@hibari として許可し、アプリにコールバックの URL を送る（画面が閉じてログインが終わる）。別のアカウントは `--as hibari_sub`
   - 開いた画面で Misskey にログイン（@hibari / `hibari`）して「許可」する。実機では Safari のログインが共有されるので、Safari でログイン済みなら許可だけになるが、シミュレータでは共有されない
- `down` / `up` ではデータもトークンも残るので、一度ログインすればそのまま使える。`reset` するとトークンも無効になり、アプリはログインし直しを求める

外部との隔離（ほかのサーバーに影響しない・連合しない）
- Misskey・PostgreSQL・Redis は外への経路がない Docker ネットワーク（`internal: true`）にだけつながっている。Misskey はほかのホストに接続できず DNS も引けないので、連合の配送・リモートの取得・URL プレビューはすべて失敗する。外側のネットワークにもつながるのはポートを公開する nginx（`proxy`）だけで、Misskey への中継しかしない
- ポートは 127.0.0.1 にだけ公開し、サーバーの URL も `localhost` なので、LAN やインターネットからは届かず、ほかのサーバーから名指しもできない
- サーバー設定の連合も「なし」（`federation: none`）。WebFinger・ActivityPub のエンドポイントは 403 を返す
- そのため実機からは使えない。実機で使うには URL を Mac の LAN 上の名前にしてポートを LAN に開けることになり、そのぶん隔離が弱まる

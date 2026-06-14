# NostrGD

Godot 4.x で **Nostr プロトコル** を扱うための C# プラグイン + リファレンスクライアントです。

エディタプラグインとして有効化すると `NostrGD` シングルトンが自動登録され、
GDScript / C# の両方から Nostr の機能を利用できます。  
付属の `main.tscn` / `main.gd` は実際に動作するクライアントのリファレンス実装です。

---

## Features

### NostrGD SDK (addons/nostr_godot/)

| 機能 | 説明 |
|---|---|
| **リレー接続管理** | 複数リレーへの WebSocket 同時接続、自動再接続、メッセージキューイング |
| **秘密鍵管理** | 新規生成 / nsec・hex 形式インポート / ConfigFile 保存・読込 |
| **NIP-07 認証** | ブラウザ拡張 (Alby / nos2x 等) による認証 (HTTP ローカルサーバー) |
| **イベント送信** | Kind 0/1/4/6/7/9734 の全イベント作成・署名・ブロードキャスト |
| **イベント受信** | 全 kind のシグナルベース受信、タイムラインプール自動管理 |
| **タイムライン** | Kind 1 イベントを時刻順に最大 20 件保持、画像・URL・ハッシュタグ・YouTube 自動抽出、リポスト解決、100ms デバウンス更新 |
| **NWC (NIP-47)** | ウォレット接続・残高照会・送金・インボイス生成・照会 (ECDH/NIP-04 暗号化) |
| **Be​ch32 ユーティリティ** | npub/nsec/note1/nevent1/lnurl のエンコード・デコード |
| **Zap (NIP-57)** | Zap 要求イベント作成・送信、LNURL 解決 |

### リファレンスクライアント (main.gd / main.tscn)

| 機能 | 説明 |
|---|---|
| **サイドバーナビゲーション** | タイムライン / プロフィール / DM / 通知 / 設定 |
| **タイムライン表示** | プロフィール名・アバター・Zap ボタン・いいね・リポスト・返信・スタンプ |
| **画像インライン表示** | 投稿内の画像 URL を自動読み込み・表示 |
| **YouTube 埋め込み** | YouTube URL からサムネイル読み込み・クリックでブラウザ再生 |
| **ハッシュタグ表示** | `#tag` を抽出しクリック可能な検索リンクとして表示 |
| **リポスト埋め込み** | SDK が解決した元イベントをネスト表示 (画像・YouTube 含む) |
| **プロフィール編集** | 表示名・自己紹介・アバター・バナー・LUD16 設定 |
| **NWC 設定 UI** | 接続文字列入力・保存・クリア、⚡ボタンからの送金 |
| **ダークテーマ** | カスタム StyleBox によるダーク UI |

---

## Installation

### 1. プラグインのインストール

```bash
# addons/ ディレクトリがあることを確認
ls addons/

# nostr_godot をコピー
cp -r path/to/NostrGD/addons/nostr_godot your_project/addons/
```

### 2. プラグインの有効化

1. Godot エディタを開く
2. **プロジェクト → プロジェクト設定 → プラグイン** タブ
3. `NostrGD` の **Status** を `Enable` にする
4. 自動的に `NostrGD` シングルトンが登録される

### 3. NuGet 依存パッケージ

プロジェクトの `.csproj` に以下を追加してください (`GDNostr.csproj` 参照):

```xml
<ItemGroup>
  <PackageReference Include="NBitcoin" Version="10.0.6" />
  <PackageReference Include="NBitcoin.Secp256k1" Version="4.0.0" />
  <PackageReference Include="Nostr.Client" Version="2.1.0" />
  <PackageReference Include="Nostr.Sdk" Version="0.44.2" />
  <PackageReference Include="System.Memory" Version="4.6.3" />
</ItemGroup>
```

---

## Architecture

```
addons/nostr_godot/
├── NostrGDPlugin.cs              # EditorPlugin: シングルトン自動登録
├── NostrGDClient.cs              # コアクライアント: リレー管理・シグナル・ライフサイクル
├── NostrGDClient.Auth.cs         # NIP-07 ブラウザ拡張認証
├── NostrGDClient.Messaging.cs    # 鍵管理・イベント送受信・タイムライン・ユーティリティ
├── NostrGDClient.NWC.cs          # NIP-47 Nostr Wallet Connect
└── plugin.cfg                    # プラグイン設定

scripts/
├── nostr_utils.gd                # GDScript ユーティリティ (Be​ch32・LNURL・絵文字)

main.gd / main.tscn               # リファレンスクライアント
```

---

## Quick Start (GDScript)

```gdscript
# リレーに接続
NostrGD.ConnectToRelay("wss://relay.damus.io")
NostrGD.ConnectToRelay("wss://nos.lol")
NostrGD.ActivateRelayProcessing()

# シグナル接続
NostrGD.Connected.connect(func(url): print("Connected: ", url))
NostrGD.TimelineUpdated.connect(func(timeline): print("Events: ", timeline.size()))

# 秘密鍵でログイン (nsec または hex)
if NostrGD.Login(nsec_key):
    print("Logged in: ", NostrGD.GetPublicKeyNpub())

# テキストノート投稿
NostrGD.SendTextNote("Hello Nostr from Godot!")

# タイムライン取得
NostrGD.RequestTimeline("global_feed", 20)

# NIP-07 ブラウザ拡張認証
NostrGD.StartLocalAuthServer()
```

---

## API Reference

### Signals

```gdscript
NostrGD.Connected.connect(func(url: String):)                   # リレー接続完了
NostrGD.Disconnected.connect(func(url: String):)                # リレー切断
NostrGD.MessageReceived.connect(func(url, command, data):)      # 全メッセージ (生JSON)
NostrGD.EventReceived.connect(func(url, subId, eventDict):)     # 汎用イベント受信
NostrGD.NoticeReceived.connect(func(url, message):)             # NOTICE メッセージ
NostrGD.ExtensionAuthCompleted.connect(func():)                 # NIP-07 認証完了
NostrGD.TimelineUpdated.connect(func(timeline: Array):)         # Kind 1 タイムライン更新
NostrGD.ReactionReceived.connect(func(url, subId, eventDict):)  # Kind 7 リアクション
NostrGD.ZapReceiptReceived.connect(func(url, subId, eventDict):)# Kind 9735 Zap 受領書
NostrGD.NwcResponseReceived.connect(func(url, subId, eventDict):)# NWC 応答 (Kind 23194/23195)
NostrGD.WalletInfoReceived.connect(func(url, subId, eventDict):)# ウォレット情報受信
NostrGD.DirectMessageReceived.connect(func(url, subId, eventDict):)# Kind 4 DM
```

### Properties

| Property | Type | 説明 |
|---|---|---|
| `IsLoggedIn` | `bool` (read) | 秘密鍵ログイン済み |
| `IsNwcConfigured` | `bool` (read) | NWC 設定済み |
| `NwcWalletPubkey` | `String` (read) | NWC ウォレットの公開鍵 |

### リレー接続管理

| メソッド | 説明 |
|---|---|
| `ConnectToRelay(url: String)` | WebSocket 接続開始 |
| `ActivateRelayProcessing()` | `_Process` ポーリング開始 (接続後に必須) |
| `DisconnectFromRelay(url: String)` | 特定リレーから切断 |
| `GetConnectedRelayUrls() -> Array` | 接続中リレー一覧 |
| `ClearTimeline()` | タイムラインプールをクリア |
| `SaveRelayUrls(urls: Array)` | リレー URL を ConfigFile に保存 |
| `LoadRelayUrls() -> Array` | ConfigFile からリレー URL 読込 |

### 鍵管理

| メソッド | 説明 |
|---|---|
| `CreateNewKeyPair() -> String` | 新規鍵ペア生成、nsec を返す |
| `Login(key: String) -> bool` | nsec または hex でログイン |
| `LoginWithHexPrivateKey(hex: String) -> bool` | hex でログイン |
| `LoginWithExtension(pubkeyHex: String)` | 拡張機能ログイン状態設定 |
| `Logout()` | 秘密鍵をメモリから消去 |
| `GetPublicKeyHex() -> String` | 公開鍵 (hex) |
| `GetPublicKeyNpub() -> String` | 公開鍵 (npub) |
| `GetPrivateKeyHex() -> String` | 秘密鍵 (hex) |
| `GetPrivateKeyNsec() -> String` | 秘密鍵 (nsec) |
| `SavePrivateKey(key: String)` | 秘密鍵を ConfigFile に保存 |
| `LoadPrivateKey() -> String` | ConfigFile から秘密鍵読込 |
| `HasSavedPrivateKey() -> bool` | 保存済み秘密鍵の有無 |

### イベント送信

| メソッド | Kind | 説明 |
|---|---|---|
| `SendTextNote(content: String)` | 1 | テキストノート投稿 |
| `SendReply(content, eventId, pubkey)` | 1 | 返信 (e/p タグ付き) |
| `SendProfileMetaData(name, displayName, about, picture, banner, lud16)` | 0 | プロフィール更新 |
| `SendReaction(eventId, pubkey, emoji = "+")` | 7 | リアクション |
| `SendRepost(targetEventId)` | 6 | リポスト |
| `SendDirectMessage(content, targetPubkey)` | 4 | ダイレクトメッセージ |
| `SendZapRequest(eventId, pubkey, amountMsat, comment, relays)` | 9734 | Zap 要求ブロードキャスト |
| `CreateZapRequestEvent(eventId, pubkey, amountMsat, comment, relays) -> Dictionary` | 9734 | 署名済み Zap 要求イベントを生成 (送信なし) |

### イベント受信 / 購読

| メソッド | 説明 |
|---|---|
| `RequestTimeline(subId, limit = 20, targetUrl = "")` | Kind 1 タイムライン取得 |
| `RequestProfiles(subId, pubkeys: Array)` | Kind 0 プロフィール一括取得 |
| `RequestNotifications(subId, pubkey)` | 通知 (Kind 7/6/16/9735, #p) 取得 |
| `RequestDirectMessages(subId, pubkey)` | DM (Kind 4, #p) 取得 |
| `RequestZapReceipts(subId, eventIds: Array)` | Zap 受領書 (Kind 9735) 取得 |
| `RequestEventById(eventId, subId)` | 単一イベント取得 (埋め込み表示用) |
| `CloseSubscription(subId)` | 購読をクローズ |

### NWC (Nostr Wallet Connect / NIP-47)

| メソッド | 説明 |
|---|---|
| `ParseNWCConnectionString(connStr) -> NwcConnectionInfo` | 接続文字列をパース |
| `InitNWC(connStr) -> bool` | NWC 初期化 (接続 + ECDH 設定 + 購読開始) |
| `TryInitNWC() -> bool` | 保存済み接続文字列で初期化 |
| `SaveNwcConnectionString(connStr)` | 接続文字列を ConfigFile に保存 |
| `LoadNwcConnectionString() -> String` | ConfigFile から読込 |
| `ClearNwcConnectionString()` | NWC 設定をクリア |
| `SendNWCCommand(method, params, walletPubkey) -> bool` | 任意の NWC コマンド送信 |
| `NWCGetBalance(walletPubkey)` | 残高照会 |
| `NWCPayInvoice(invoice, walletPubkey) -> bool` | インボイス支払い |
| `NWCMakeInvoice(amountMsat, description, walletPubkey)` | インボイス生成 |
| `NWCGetInfo(walletPubkey)` | ウォレット情報取得 |
| `NWCLookupInvoice(paymentHash, walletPubkey)` | インボイス照会 |

接続文字列形式:
```
nostr+walletconnect://<wallet_pubkey>?relay=<relay_url>&secret=<secret>
```

### NIP-07 ブラウザ拡張認証

| メソッド | 説明 |
|---|---|
| `StartLocalAuthServer()` | HTTP サーバー起動 + ブラウザ表示 |
| `StopLocalAuthServer()` | HTTP サーバー停止 |

内部動作:
1. `http://localhost:8123/` で `window.nostr.getPublicKey()` を呼ぶ HTML を配信
2. 公開鍵を `GET /receive?pubkey=...` で受信
3. WebSocket (`/ws`) で署名要求 `SIGN_REQUEST` / 応答 `SIGN_RESPONSE` を交換
4. 成功時に `ExtensionAuthCompleted` 発行

### GDScript ユーティリティ (scripts/nostr_utils.gd)

| 関数 | 説明 |
|---|---|
| `decode_note1_id(uri) -> String` | `note1...` / `nevent1...` → hex event ID |
| `resolve_lnurl(profile) -> String` | `lud06` / `lud16` → LNURL URL |
| `lnurl_decode(lnurl) -> String` | `lnurl1...` → プレーン URL |
| `resolve_custom_emoji(content, tags) -> String` | `:emoji:` を NIP-30 タグから解決 |
| `has_lud(profile) -> bool` | Lightning アドレス有無確認 |

---

## Usage Examples

### タイムラインの表示

```gdscript
# 接続
NostrGD.Connected.connect(_on_connected)
NostrGD.TimelineUpdated.connect(_on_timeline_updated)

func _on_connected(url: String):
    # 初回タイムライン要求
    NostrGD.RequestTimeline("global_feed", 20, url)

func _on_timeline_updated(timeline: Array):
    for event in timeline:
        var pubkey = event["pubkey"]
        var content = event["content"]
        var images = event.get("media_images", [])
        var hashtags = event.get("media_hashtags", [])
        var youtube_ids = event.get("media_youtube_ids", [])
        print(pubkey.left(8) + ": " + content.left(50))
```

### NWC で送金

```gdscript
func _pay_invoice(invoice: String):
    if not NostrGD.IsNwcConfigured:
        print("NWC not configured")
        return
    if NostrGD.NWCPayInvoice(invoice, NostrGD.NwcWalletPubkey):
        print("Payment sent")

# 応答は NwcResponseReceived で受信
NostrGD.NwcResponseReceived.connect(_on_nwc_response)
func _on_nwc_response(_url, _subId, eventDict):
    var decrypted = eventDict.get("decrypted_content", "")
    if decrypted != "":
        print("NWC Response: ", decrypted)
```

### Zap 送信

```gdscript
func send_zap(event_id: String, author_pubkey: String, amount_sats: int):
    var relays = NostrGD.GetConnectedRelayUrls()
    NostrGD.SendZapRequest(event_id, author_pubkey, amount_sats * 1000, "", relays)
```

### プロフィール情報の利用

```gdscript
# プロフィール取得
NostrGD.RequestProfiles("profile_resolver", [pubkey])

# EventReceived で受信
func _on_nostr_event_received(sub_id: String, event: Dictionary):
    if sub_id == "profile_resolver":
        var profile = parse_json(event["content"])
        var name = profile.get("display_name", profile.get("name", "Unknown"))
        var picture = profile.get("picture", "")
        var lud16 = profile.get("lud16", "")
```

---

## リファレンスクライアント (main.gd) の主な実装パターン

| 処理 | 実装場所 |
|---|---|
| リレー接続・切断 | `_ready()` / `_on_connect_to_relay()` |
| タイムライン描画 | `_rebuild_timeline_item(event)` |
| 画像読み込み | `_load_and_display_image(url, parent)` |
| YouTube 埋め込み | `_render_youtube_embed(video_id, parent)` / `_load_youtube_thumbnail()` |
| プロフィール管理 | `_parse_profile_event()` / `_on_kind0_event_received()` |
| プロフィール編集 | `_on_save_profile()` |
| いいね (リアクション) | `_on_like_toggle(eventId, pubkey, btn)` |
| リポスト | `_on_repost_button(eventId)` |
| 返信 | `_on_reply_button(eventId, pubkey, name, content)` |
| Zap | `_on_zap(eventId, pubkey)` |
| NWC 設定 | NWC 設定ダイアログ |
| 秘密鍵管理 | 新規生成 / インポート UI |

---

## License

MIT License

Copyright (c) 2026 宵猫ルナ

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

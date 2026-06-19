# NostrGD

Godot 4.x で **Nostr プロトコル** を扱うための純 GDScript プラグイン + リファレンスクライアントです。

エディタプラグインとして有効化するか、`project.godot` の autoload に登録することで `NostrGD` シングルトンが利用可能になります。

---

## 特徴

### NostrGD SDK (addons/nostr_godot/)

| 機能 | 説明 |
|------|------|
| **リレー接続管理** | 複数リレーへの WebSocket 同時接続、自動再接続、メッセージキューイング、リレー権限制御 (r/w) |
| **秘密鍵管理** | 新規生成 / nsec・hex 形式インポート / ConfigFile 保存・読込 |
| **NIP-07 認証** | ブラウザ拡張 (Alby / nos2x 等) による認証 (HTTP ローカルサーバー / Web JavaScriptBridge) |
| **イベント送信** | Kind 0/1/4/6/7/9734 の全イベント作成・署名・ブロードキャスト、`SendCustomEvent` で任意 Kind |
| **イベント受信** | 全 kind のシグナルベース受信、タイムラインプール自動管理 (100件上限、400ms デバウンス) |
| **タイムライン** | Kind 1 イベントを時刻順に保持、画像・URL・ハッシュタグ・YouTube 自動抽出、リポスト解決、日本語フィルタ |
| **NWC (NIP-47)** | ウォレット接続・残高照会・送金・インボイス生成・照会 (ECDH/NIP-04 暗号化) |
| **純 GDScript 暗号** | BigInt ベース secp256k1/BIP340/ECDH/AES-256-CBC、GDExtension フォールバック対応 |
| **bech32 ユーティリティ** | npub/nsec のエンコード・デコード |
| **Zap (NIP-57)** | Zap 要求イベント作成・送信 |
| **ブックマーク** | ローカル JSON 保存 + kind 10003 でリレー同期 |

### リファレンスクライアント (main.gd / main.tscn)

| 機能 | 説明 |
|------|------|
| **サイドバーナビゲーション** | タイムライン / プロフィール / DM / 通知 / ブックマーク / 設定 |
| **タイムライン表示** | プロフィール名・アバター・Zap ボタン・いいね・リポスト・返信・ブックマーク |
| **画像インライン表示** | 投稿内の画像 URL を自動読み込み・表示 |
| **YouTube 埋め込み** | YouTube URL からサムネイル読み込み・クリックでブラウザ再生 |
| **ハッシュタグ表示** | `#tag` を抽出しクリック可能な検索リンクとして表示 |
| **リポスト埋め込み** | SDK が解決した元イベントをネスト表示 (画像・YouTube 含む) |
| **プロフィール編集** | 表示名・自己紹介・アバター・バナー・LUD16 設定 |
| **NWC 設定 UI** | 接続文字列入力・保存・クリア、⚡ボタンからの送金 |
| **通知タブ** | Zap・リアクション・リポスト・返信を一覧表示 |
| **ブックマークタブ** | 🔖ボタンで追加/削除、ローカル保存＋kind 10003 リレー同期 |
| **リレー設定** | TextEdit での一括編集、`url r w` 権限制御 |
| **ダークテーマ** | カスタム StyleBox によるダーク UI |

---

## インストール

### 1. addons のコピー

```bash
cp -r path/to/NostrGD/addons/nostr_godot your_project/addons/
```

### 2. シングルトンの登録

**方法 A: エディタプラグインとして有効化 (推奨)**

1. Godot エディタを開く
2. **プロジェクト → プロジェクト設定 → プラグイン** タブ
3. `NostrGD` の **Status** を `Enable` にする
4. `nostr_gd_plugin.gd` が `NostrGD` シングルトンを自動登録

**方法 B: project.godot に手動登録**

`project.godot` の `[autoload]` セクションに以下を追加:
```
NostrGD="*res://addons/nostr_godot/nostr_gd_client.gd"
```

### 3. GDExtension (オプション・高速化)

`addons/nostr_godot/gdextension/lib/` に `libnostr_crypto.so` が含まれています。
GDScript フォールバックでも動作するため必須ではありません。

---

## アーキテクチャ

```
addons/nostr_godot/
├── secp256k1.gd              # 純 GDScript 暗号 (BIP340, ECDH, AES-256-CBC, bech32)
├── nostr_gd_client.gd         # コアクライアント (リレー管理・鍵・イベント・NWC・タイムライン)
├── nostr_gd_plugin.gd         # EditorPlugin: シングルトン自動登録
├── plugin.cfg                 # プラグイン設定 (entry: nostr_gd_plugin.gd)
├── gdextension/               # GDExtension C++ libsecp256k1 (高速化)
│   ├── lib/libnostr_crypto.so
│   ├── src/nostr_crypto.cpp
│   └── nostr_crypto.gdextension
├── icon.png
└── icon.png.import

scripts/
└── nostr_utils.gd             # GDScript ユーティリティ (LUD16 解決, カスタム絵文字)

main.gd / main.tscn            # リファレンスクライアント
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
    print("Logged in: ", NostrGD.GetPublicKeyHex())

# テキストノート投稿
NostrGD.SendTextNote("Hello Nostr from Godot!")

# タイムライン取得
NostrGD.RequestTimeline("global_feed", 20)
```

---

## リレー権限フォーマット

リレー設定は TextEdit に 1行1リレーで記述します:

```
wss://relay.damus.io r w
wss://nos.lol r
wss://relay.example.com w
wss://historical-relay.com
```

- `r` = 読み取り (タイムライン・通知・DM の購読)
- `w` = 書き込み (イベント送信・Zap リレータグ)
- 省略時は `r w` 両方と解釈

---

## SDK リファレンス

詳細は [docs/sdk_reference.md](docs/sdk_reference.md) を参照してください。

---

## リファレンスクライアント (main.gd) の主な実装パターン

| 処理 | 実装場所 |
|------|----------|
| リレー接続・切断 | `_ready()` / `_on_connect_to_relay()` |
| タイムライン描画 | `_rebuild_timeline_item(event)` |
| 画像読み込み | `_load_and_display_image(url, parent)` |
| YouTube 埋め込み | `_render_youtube_embed(video_id, parent)` |
| プロフィール管理 | `_parse_profile_event()` |
| プロフィール編集 | `_on_save_profile()` |
| いいね | `_on_like_toggle(eventId, pubkey, btn)` |
| リポスト | `_on_repost_button(eventId)` |
| 返信 | `_on_reply_button(eventId, pubkey, name)` |
| Zap | `_on_zap(eventId, pubkey)` |
| ブックマーク | `_toggle_bookmark(eventId)` |
| NWC 設定 | NWC 設定ダイアログ |
| リレー設定 | TextEdit + 保存・再接続ボタン |

---

## 技術スタック

- **Godot 4.x** (.NET 不要 — 純 GDScript で動作)
- **暗号**: 独自 secp256k1.gd (BigInt + 手実装 BIP340/ECDH/AES-256-CBC)
- **GDExtension**: C++ libsecp256k1 による高速化 (フォールバック可能)
- **プラットフォーム**: Windows / Linux / macOS / Web (JavaScriptBridge)

---

## License

MIT License

Copyright (c) 2026 宵猫ルナ

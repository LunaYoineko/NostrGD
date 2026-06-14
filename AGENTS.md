# NostrGD — プロジェクトガイド（AI Agent 用）

## 概要

Godot 4.x 用 Nostr SDK（C# プラグイン）+ リファレンスクライアント。
エディタプラグインとして有効化すると `NostrGD` シングルトンが自動登録される。

## ディレクトリ構成

```
/
├── addons/nostr_godot/          # SDK 本体（C#）
│   ├── NostrGDPlugin.cs         # EditorPlugin: シングルトン登録
│   ├── NostrGDClient.cs         # コアクライアント（リレー管理・シグナル）
│   ├── NostrGDClient.Auth.cs    # NIP-07 ブラウザ拡張認証
│   ├── NostrGDClient.Messaging.cs # 鍵管理・イベント送受信・タイムライン
│   └── NostrGDClient.NWC.cs     # NIP-47 NWC
├── scripts/
│   └── nostr_utils.gd           # GDScript ユーティリティ
├── main.gd / main.tscn          # リファレンスクライアント
├── GDNostr.csproj               # .NET プロジェクト
└── AGENTS.md                    # 本ファイル
```

## ビルド・検証

```bash
dotnet build    # C# コンパイル（0 warnings 0 errors 必須）
```

GDScript は Godot エディタ上でしか検証できない。

## 技術スタック

- **Godot 4.x** (.NET 対応)
- **.NET 8.0**
- **Godot.NET.Sdk 4.6.3**
- 依存 NuGet: NBitcoin 10.0.6, NBitcoin.Secp256k1 4.0.0, Nostr.Client 2.1.0, Nostr.Sdk 0.44.2

## 命名規則・コード規約

- C#: ファイルスコープ名前空間・`private` 明示・`_camelCase` フィールド
- GDScript: `snake_case` 関数・変数、`PascalCase` クラス・ノード・enum
- コメントは原則付けない（コードで意図を表す）
- 公開 API の追加時は README.md も同時更新

## アーキテクチャ上の注意点

### イベント処理フロー

1. `NostrGDPlugin` が `NostrGDClient` をシングルトン `NostrGD` として登録
2. リレーからの全 EVENT は `HandleIncomingPacket` → `EventReceived` シグナル → GDScript
3. 同一フレーム内で `ProcessIncomingEventForTimeline` が実行され、同じ Dictionary に `media_*` フィールドを追加（ポストプロセス）
4. タイムラインイベントはプールに蓄積後 `TimelineUpdated` シグナルで GDScript に配信（100ms デバウンス）
5. `RequestEventById` の応答（embed_*）は `ProcessIncomingEventForTimeline` より先に GDScript に届く → embed 応答には `media_*` フィールドが**含まれない**

### SDK 側で抽出・UI は GDScript

- 画像URL・YouTube URL・nostr URI・ハッシュタグは `ProcessIncomingEventForTimeline`（C#）で抽出
- リポスト（Kind 6/16）はタイムラインプールから元イベントを検索して `repost_original_*` フィールドを埋め込む
- 画像読み込み・YouTube サムネイル表示・ハッシュタグ描画などは GDScript の `main.gd` で実装（UI 処理は SDK に移行しない）

### NWC (NIP-47)

- 接続文字列: `nostr+walletconnect://<pubkey>?relay=<url>&secret=<secret>`
- イベント署名は `secret` 鍵で行い、`event.pubkey` = secret 公開鍵
- NIP-04 共有鍵は ECDH の X 座標（32 bytes）を SHA256 せず直接 AES-256 鍵として使用
- kind 23195 応答は `RouteEventByKind` 内で `NwcDecryptContent` により復号、`decrypted_content` に格納
- `#p` フィルタ値は secret 公開鍵を使用

### Git

- リモート: `https://github.com/Luna1029-VRChat/NostrGD.git`
- ブランチ: `main`（追跡先: `main/main`）
- コミットは明示的に依頼された場合のみ行う

## リレー・認証

- リレーURLは動的配列 + ConfigFile 永続化
- デフォルトリレー不要（保存済みリレーがなければ何も接続しない）
- 未ログイン時でもリレー接続＋タイムライン読み取りは可能
- NWC 設定時は QR 表示せず直接送金、未設定時は既存の QR 表示フロー
- NWC リレーからの投稿はタイムラインに載せない
- リレー編集時にタイムラインリセット
- リアクション（kind 7）はタイムラインに載せない

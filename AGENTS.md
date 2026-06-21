# NostrGD — プロジェクトガイド（AI Agent 用）

## 概要

純 GDScript Nostr SDK（Godot 4.x）+ リファレンスクライアント。
`plugin.cfg` → `nostr_gd_plugin.gd` (EditorPlugin) が `NostrGD` シングルトンを自動登録する。
`project.godot` にも autoload 登録済み（エディタ起動前でも動作可）。

## ディレクトリ構成

```
/
├── addons/nostr_godot/          # SDK 本体（全 GDScript）
│   ├── secp256k1.gd             # 純 GDScript 暗号（BIP340, ECDH, AES-256-CBC, bech32）
│   ├── nostr_gd_client.gd       # コアクライアント（リレー管理・鍵・イベント・NWC・タイムライン）
│   ├── nostr_gd_plugin.gd       # EditorPlugin: プラグイン有効化時にシングルトン自動登録
│   └── plugin.cfg               # プラグイン設定（entry: nostr_gd_plugin.gd）
├── scripts/
│   └── nostr_utils.gd           # GDScript ユーティリティ
├── main.gd / main.tscn          # リファレンスクライアント
├── bench.gd                     # ベンチマークスクリプト（MainLoop、署名パフォーマンス計測用）
├── export_presets.cfg           # Web エクスポートプリセット
└── AGENTS.md                    # 本ファイル
```

## ビルド・検証

`dotnet build` 不要。GDScript は Godot エディタ上で検証する。

## 技術スタック

- **Godot 4.x**（.NET 不要 — 純 GDScript で動作）
- 暗号ライブラリ: 独自 `secp256k1.gd`（BigInt + 手実装 BIP340/ECDH/AES-CBC、BouncyCastle 非依存）
- アーキテクチャ: 1 Node (= `NostrGD`) に全 SDK 機能を集約（extends Node）

## 命名規則・コード規約

- GDScript: `_camelCase` プライベートメソッド・変数、`PascalCase` 公開 API（信号名・公開メソッド）
- `private` 相当の関数は `_` プレフィックス（GDScript にアクセス修飾子はない）
- コメントは原則付けない（コードで意図を表す）
- 公開 API の追加時は README.md も同時更新

## アーキテクチャ上の注意点

### イベント処理フロー

1. `nostr_gd_plugin.gd` (EditorPlugin) が `_enter_tree` 時に `add_autoload_singleton` で `NostrGD` を登録する
2. リレーからの全 EVENT は `_handle_incoming_packet` → `EventReceived` シグナル → GDScript UI
3. 同一フレーム内で `_process_incoming_event_for_timeline` が実行され、同じ Dictionary に `media_*` フィールドを追加（ポストプロセス）
4. タイムラインイベントはプールに蓄積後 `TimelineUpdated` シグナルで GDScript に配信（100ms デバウンス）
5. `RequestEventById` の応答（embed_*）は `_process_incoming_event_for_timeline` より先に GDScript に届く → embed 応答には `media_*` フィールドが**含まれない**

### SDK 側で抽出・UI は GDScript

- 画像URL・YouTube URL・nostr URI・ハッシュタグは `_process_incoming_event_for_timeline`（`nostr_gd_client.gd`）で抽出
- リポスト（Kind 6/16）はタイムラインプールから元イベントを検索して `repost_original_*` フィールドを埋め込む
- 画像読み込み・YouTube サムネイル表示・ハッシュタグ描画などは GDScript の `main.gd` で実装（UI 処理は SDK に移行しない）

### NWC (NIP-47)

- 接続文字列: `nostr+walletconnect://<pubkey>?relay=<url>&secret=<secret>`
- イベント署名は `secret` 鍵で行い、`event.pubkey` = secret 公開鍵
- NIP-04 共有鍵は ECDH の X 座標（32 bytes）を SHA256 せず直接 AES-256 鍵として使用（`secp256k1.gd` の `ecb` が返す値、libsecp256k1 のデフォルト ecdh ハッシュは使わず X 座標のみ）
- kind 23195 応答は `_route_event_by_kind` 内で `_nwc_decrypt_content` により復号、`decrypted_content` に格納
- `#p` フィルタ値は secret 公開鍵を使用

### Web エクスポート

- 純 GDScript → `.NET 不要`、Godot 標準 Web エクスポートがそのまま使える
- `nostr_gd_client.gd` は `OS.has_feature("web")` で分岐:
  - Desktop: `TCPServer` + raw HTTP/1.1 (localhost:8123) + ブラウザ自動起動（NIP-07 pubkey 取得）
  - Web: `JavaScriptBridge.eval()` 経由で直接 `window.nostr` を呼び出し
- NIP-07 署名フロー（Web のみ）:
  - `_sign_and_broadcast` が拡張ログイン ＋ Web を検出すると `_initiate_web_sign` を呼ぶ
  - JS 側で `window.nostr.signEvent()` → `_poll_web_sign` が結果をポーリング
  - 署名が届いたら `_broadcast_or_queue` ＋ `_process_event_for_timeline` を実行
- `export_presets.cfg` に Web プリセット設定済み
- `project.godot` に `[web]` セクション追加済み
- `DisplayServer.clipboard_set` は `_safe_clipboard_set` でラップし Web では `navigator.clipboard.writeText()` を使用
- `OS.shell_open()` は `_open_url()` でラップし Web では `window.open()` を使用
- **モバイル（<800px viewport）:**
  - サイドバー代わりに `_setup_mobile_bottom_nav()` で下部タブバー（アイコン6個）を生成
  - `_bottom_nav`: `PanelContainer`（背景 `#1c1e24`、角丸8px上部、anchor-bottom固定）
  - InputBar はタイムラインセクションのみ表示（`_switch_section`, `_set_ui_state` で制御）
  - `_update_bottom_nav_highlight()`: 現在のセクションのアイコンを `#66b3ff` に、他を `#808099` に
  - `_on_bottom_nav_pressed`: セクション切り替え、サイドバーが開いていれば閉じる
  - `_on_viewport_resized`: 800px 境界で mobile ↔ desktop 切替時に bottom_nav の生成/破棄

### 暗号（secp256k1.gd）

- 鍵生成: BIP340 準拠（`generate_keypair` → `generate_private_key` + `derive_pubkey`）
- 署名: BIP340 Schnorr（`sign_event` → SHA256(event_id) → `schnorr_sign`）
- **既知のバグと修正の歴史:**
  - `_jac_double` / `_jac_add` に無限遠点（z=0）のガードがなく、`1*G` で (0,0) を返していた → `_is_zero(z)` チェックを追加
  - `_reduce_p` / `_reduce_n` が繰り返し減算ループのみで、乗算結果（512-bit）を約 2^256 回の反復で減算しようとして事実上ハング → 乗算結果を反復的 secp256k1 reduction で処理するよう修正
  - AES ShiftRows が全行に left-1 / right-1 を適用していた（FIPS 197 では Row 0=不変, Row 1=left-1, Row 2=left-2, Row 3=left-3） → 正しいシフト量に修正。このバグにより標準 AES との相互運用が不可だった
  - NIP-04 AES 鍵が SHA256 で二重ハッシュされていた（GDExtension: SHA256(圧縮点), GDScript: SHA256(x)）。正しい鍵は生の X 座標（SHA256 無し、`@noble/curves` の `getSharedSecret` → `slice(1,33)` 相当） → `ecb` 関数から SHA256 を削除、GDExtension `ecdh` を `secp256k1_ecdh` → `secp256k1_ec_pubkey_tweak_mul` + 生 X 座標抽出に変更
- **パフォーマンス（2024時点は純GDScript BigInt）:**
  - `derive_pubkey`: ~20ms
  - `schnorr_sign`: ~1.0s（BIP340: `_scalar_mult` ×2-4回、`_mod_inv` ×1回）
  - `sign_event`: ~1.3s（`derive_pubkey` + `compute_event_id` + `schnorr_sign`）
  - 高速化には GDExtension (C++ libsecp256k1) への移行が必要（μs オーダーに短縮）
- ECDH: NIP-04 向け（`ecdh` → 共有 X 座標を直接返す、SHA256 は通さない）
- AES-256-CBC: 独自実装（S-box + 鍵拡張 + PKCS7 padding + IV ランダム生成、Godot Crypto クラス非依存）
- bech32: `npub_encode`/`npub_decode`/`nsec_encode`/`nsec_decode`（Bech32、NIP-19）
- 曲線定数: `_ensure_init` で初回アクセス時に静的初期化

### GDExtension ビルド

- `addons/nostr_godot/gdextension/build.sh -p <platform> -a <arch> [-t debug|release]` でクロスプラットフォームビルド
- 対応プラットフォーム: `linux`, `windows`, `macos`, `web`, `android`
- 対応アーキテクチャ: `x86_64`, `arm64`, `wasm32`
- 例: `./build.sh -p web -a wasm32`（Emscripten 必須、事前に `source ~/emsdk/emsdk_env.sh`）, `./build.sh -p windows -a x86_64`（MinGW 必須）
- 各プラットフォームのライブラリは `lib/` に配置され、`nostr_crypto.gdextension` が自動選択（18エントリ）
- `libsecp256k1/` と `godot-cpp/` は git 管理外（各自ビルド or 事前ビルド済みバイナリ）
- **既知の問題:**
  - godot-cpp の SCons は CC/CXX 環境変数を無視するため、クロスコンパイル時は SConstruct を一時的にパッチ（`env.Replace(CC=...)`）する。`build.sh` 内で自動的に行われる。
  - Windows/MinGW ビルド時は `-DSECP256K1_STATIC` が必要（`__declspec(dllimport)` 回避のため）。`build.sh` 内で自動的に追加される。
  - cmake の `CMAKE_AR` に相対パスで `emar` 等を渡すと `libsecp256k1/emar` に解決されるため、`$(which emar)` のフルパスを使用する。
- 2026年6月時点で以下のテンプレートをビルド・配置済み:
  - Linux x86_64 (debug + release)
  - Linux ARM64 (debug + release)
  - Windows x86_64 (debug + release)
  - Web Wasm32 (debug + release)
- macOS/Android は未ビルド（Android NDK 未設定、macOS ビルドは macOS ホストが必要）
- Web エクスポート時は `export_presets.cfg` の `variant/extensions_support=true` が必要（設定済み）
- フォールバック: GDExtension が利用できない環境では純 GDScript `secp256k1.gd` が自動的に使用される

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

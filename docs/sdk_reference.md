# NostrGD SDK Reference

The `NostrGD` singleton provides the full Nostr protocol implementation for Godot 4.x.
Access it directly from any GDScript after plugin activation.

The SDK also exposes `Secp256k1` (preloaded in `nostr_gd_client.gd`) for low-level crypto operations.

---

## Signals

| Signal | Arguments | Description |
|--------|-----------|-------------|
| `Connected` | `url: String` | Relay WebSocket connection established |
| `Disconnected` | `url: String` | Relay WebSocket disconnected |
| `MessageReceived` | `url: String, command: String, data: Array` | Raw relay message (JSON array) |
| `EventReceived` | `subscription_id: String, event_dict: Dictionary` | Any EVENT message from any subscription |
| `NoticeReceived` | `url: String, message: String` | NOTICE from relay |
| `ExtensionAuthCompleted` | — | NIP-07 browser extension auth succeeded |
| `TimelineUpdated` | `timeline_array: Array` | Kind 1 timeline pool updated (400ms debounced, filtered by JapaneseFilterEnabled) |
| `ReactionReceived` | `url: String, subscription_id: String, event_dict: Dictionary` | Kind 7 reaction received |
| `ZapReceiptReceived` | `url: String, subscription_id: String, event_dict: Dictionary` | Kind 9735 zap receipt received |
| `NwcResponseReceived` | `url: String, subscription_id: String, event_dict: Dictionary` | NWC response (kind 23194/23195) |
| `WalletInfoReceived` | `url: String, subscription_id: String, event_dict: Dictionary` | Wallet info response |
| `DirectMessageReceived` | `url: String, subscription_id: String, event_dict: Dictionary` | Kind 4 DM (decrypted_content populated for incoming) |

---

## Properties

| Property | Type | Description |
|----------|------|-------------|
| `IsLoggedIn` | `bool` | Whether a private key is loaded |
| `IsNwcConfigured` | `bool` | Whether NWC (NIP-47) is initialized |
| `NwcWalletPubkey` | `String` | Wallet pubkey from NWC connection string |
| `JapaneseFilterEnabled` | `bool` | When true, TimelineUpdated only emits Japanese-containing events |

---

## Relay Management

| Method | Description |
|--------|-------------|
| `ConnectToRelay(url: String)` | Open WebSocket connection to a relay |
| `ActivateRelayProcessing()` | Start `_process` polling (call after at least one connection) |
| `DisconnectFromRelay(url: String)` | Close connection to a specific relay |
| `GetConnectedRelayUrls() -> Array` | Return list of connected relay URLs |

---

## Key Management

| Method | Returns | Description |
|--------|---------|-------------|
| `CreateNewKeyPair()` | `String` (nsec) | Generate random keypair, auto-login, return nsec |
| `Login(key_input: String)` | `bool` | Login with nsec or hex private key |
| `LoginWithExtension(pubkey_hex: String)` | `void` | Set extension login state (no local key) |
| `Logout()` | `void` | Clear private key from memory |
| `GetPublicKeyHex()` | `String` | Return 64-char hex public key |
| `GetPrivateKeyHex()` | `String` | Return 64-char hex private key (empty for extension login) |
| `GetPrivateKeyNsec()` | `String` | Return nsec-encoded private key |
| `HasSavedPrivateKey()` | `bool` | Check if a key is saved in ConfigFile |
| `SavePrivateKey(key: String)` | `void` | Save private key to ConfigFile |
| `LoadPrivateKey()` | `String` | Load private key from ConfigFile |

---

## Config Persistence

| Method | Description |
|--------|-------------|
| `SaveRelayUrls(urls: Array)` | Save relay URL list to ConfigFile |
| `LoadRelayUrls()` | Load relay URL list from ConfigFile |
| `SavePrivateKey(key: String)` | Save private key to ConfigFile |
| `LoadPrivateKey()` | Load private key from ConfigFile |

---

## Japanese Filter

| Method | Returns | Description |
|--------|---------|-------------|
| `SetJapaneseFilterEnabled(enabled: bool)` | `void` | Toggle Japanese-only timeline filter |
| `IsJapaneseText(text: String)` | `bool` | Check if text contains Japanese characters (Hiragana, Katakana, Kanji) |

---

## Event Sending

| Method | Kind | Description |
|--------|------|-------------|
| `SendTextNote(content: String)` | 1 | Post a text note |
| `SendReply(content: String, reply_to_event_id: String, reply_to_pubkey: String)` | 1 | Reply to an event (adds `e` and `p` tags) |
| `SendProfileMetaData(name: String, display_name: String, about: String = "", picture: String = "", banner: String = "", lud16: String = "")` | 0 | Update profile metadata |
| `SendReaction(target_event_id: String, target_pubkey: String, emoji: String = "+")` | 7 | Send reaction (use `"-"` for unlike) |
| `SendRepost(target_event_id: String, quote: String = "")` | 6 | Repost (kind 6); non-empty quote = kind 6 with content |
| `SendDirectMessage(content: String, target_pubkey: String)` | 4 | Encrypted DM via NIP-04 |
| `SendCustomEvent(kind: int, content: String, tags: Array)` | any | Send arbitrary event kind with custom tags |
| `CreateZapRequestEvent(target_event_id: String, target_pubkey: String, amount_msat: int, comment: String = "", relay_urls: Array = [])` | 9734 | Create a signed zap request event (no broadcast) |
| `SendEvent(event_dict: Dictionary)` | any | Broadcast a pre-signed event dictionary |

---

## Subscriptions / Queries

| Method | Description |
|--------|-------------|
| `RequestTimeline(subscription_id: String, limit: int = 20, target_url: String = "")` | Subscribe to kind 1 events. Empty target_url = broadcast to all |
| `RequestNotifications(subscription_id: String, pubkey: String)` | Subscribe to kinds 7,6,16,9735 with `#p` filter (broadcast) |
| `RequestNotificationsForRelay(subscription_id: String, pubkey: String, target_url: String)` | Subscribe to kinds 1,7,6,16,9735 with `#p` filter (single relay) |
| `RequestDirectMessages(subscription_id: String, pubkey: String)` | Subscribe to kind 4 with `#p` + `authors` filter (broadcast) |
| `RequestDirectMessagesForRelay(subscription_id: String, pubkey: String, target_url: String)` | Subscribe to kind 4 (single relay) |
| `RequestProfiles(subscription_id: String, pubkeys: Array)` | Subscribe to kind 0 by authors (broadcast) |
| `RequestProfilesForRelay(subscription_id: String, pubkeys: Array, target_url: String)` | Subscribe to kind 0 by authors (single relay) |
| `RequestEventById(event_id: String, subscription_id: String)` | Fetch a single event by ID |
| `RequestZapReceipts(subscription_id: String, event_ids: Array)` | Subscribe to kind 9735 by `#e` filter |
| `RequestCustomEvents(subscription_id: String, kinds: Array, pubkey: String)` | Subscribe to arbitrary kinds with `#p` filter |
| `RequestUserEvents(subscription_id: String, kinds: Array, author: String)` | Subscribe to arbitrary kinds with `authors` filter |
| `CloseSubscription(subscription_id: String)` | Close a subscription (sends CLOSE) |
| `ClearTimeline()` | Clear the timeline pool and debounce timer |

---

## NWC (NIP-47 — Nostr Wallet Connect)

### Connection String Format
```
nostr+walletconnect://<wallet_pubkey>?relay=<relay_url>&secret=<secret>
```

### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `SaveNwcConnectionString(conn_str: String)` | `void` | Save connection string to ConfigFile |
| `LoadNwcConnectionString()` | `String` | Load connection string from ConfigFile |
| `ClearNwcConnectionString()` | `void` | Clear NWC configuration |
| `InitNWC(connection_string: String)` | `bool` | Initialize NWC (parse, derive keys, connect relay) |
| `TryInitNWC()` | `bool` | Initialize NWC from saved connection string |
| `SendNWCCommand(method: String, params: Dictionary, wallet_pubkey: String)` | `String` | Send an NWC command (kind 23194), returns event_id |
| `NWCGetBalance(wallet_pubkey: String)` | `void` | Request wallet balance |
| `NWCPayInvoice(invoice: String, wallet_pubkey: String)` | `bool` | Pay a BOLT11 invoice |
| `NWCMakeInvoice(amount_msat: int, description: String, wallet_pubkey: String)` | `void` | Create a lightning invoice |
| `NWCGetInfo(wallet_pubkey: String)` | `void` | Request wallet info |
| `NWCLookupInvoice(payment_hash: String, wallet_pubkey: String)` | `void` | Look up an invoice by payment hash |

**Note:** All NWC commands are fire-and-forget. Responses arrive via `NwcResponseReceived` signal with `decrypted_content` field set.

---

## NIP-07 (Browser Extension Auth)

| Method | Description |
|--------|-------------|
| `StartLocalAuthServer()` | Start HTTP server on `localhost:8123` + open browser. On Web, uses `JavaScriptBridge` |
| `StopLocalAuthServer()` | Stop the HTTP server |

Desktop flow: HTTP server serves an HTML page that calls `window.nostr.getPublicKey()`, then sends the pubkey back via a `/receive?pubkey=` GET request.

---

## Secp256k1 Crypto API

Access via the `Secp256k1` constant in `nostr_gd_client.gd`.

All methods are `static func`. Falls back to pure GDScript when GDExtension singleton `NostrCrypto` is not available.

| Method | Returns | Description |
|--------|---------|-------------|
| `bytes_from_hex(s: String)` | `PackedByteArray` | Convert hex string to bytes |
| `hex_from_bytes(arr: PackedByteArray)` | `String` | Convert bytes to hex string |
| `derive_pubkey(private_key_hex: String)` | `String` | Derive BIP340 X-only public key (32 bytes hex) |
| `schnorr_sign(private_key_hex: String, message: PackedByteArray)` | `PackedByteArray` | BIP340 Schnorr signature (64 bytes) |
| `schnorr_sign_raw(private_key: PackedByteArray, message: PackedByteArray)` | `PackedByteArray` | Same as schnorr_sign but accepts raw key bytes |
| `ecb(private_key_hex: String, pubkey_hex: String)` | `PackedByteArray` | ECDH shared secret — returns raw X coordinate (32 bytes, no SHA256) |
| `compute_event_id(event: Dictionary)` | `String` | Compute NIP-01 event ID (SHA256 of serialized event) |
| `sign_event(private_key_hex: String, event: Dictionary)` | `Dictionary` | Sign event (sets pubkey, id, sig fields) |
| `nip04_encrypt(private_key_hex: String, pubkey_hex: String, plaintext: String)` | `String` | NIP-04 encrypt: base64(ciphertext)?iv=base64(iv) |
| `nip04_decrypt(private_key_hex: String, pubkey_hex: String, payload: String)` | `String` | NIP-04 decrypt; returns `""` on invalid padding/UTF-8 |
| `npub_encode(pubkey_hex: String)` | `String` | bech32 encode npub |
| `npub_decode(npub: String)` | `String` | bech32 decode npub to hex |
| `nsec_encode(private_key_hex: String)` | `String` | bech32 encode nsec |
| `nsec_decode(nsec: String)` | `String` | bech32 decode nsec to hex |
| `nwc_try_decrypt(private_key_hex: String, pubkey_hex: String, payload: String)` | `String` | Try decryption with 3 key derivations (raw_x, SHA256(02\|x), SHA256(03\|x)) — useful for NWC compatibility |
| `bech32_encode(hrp: String, data: PackedByteArray)` | `String` | Generic bech32 encode |
| `bech32_decode(hrp: String, encoded: String)` | `PackedByteArray` | Generic bech32 decode |

---

## Event Processing Pipeline

1. Raw WebSocket packet → `_handle_incoming_packet` parses JSON
2. `EventReceived` signal emitted for every EVENT
3. `_route_event_by_kind` dispatches to kind-specific signals:
   - kind 4 → `DirectMessageReceived` (with `decrypted_content`)
   - kind 7 → `ReactionReceived`
   - kind 9735 → `ZapReceiptReceived`
   - kind 23194/23195 → `NwcResponseReceived` (with `decrypted_content`)
4. `_process_event_for_timeline` enriches kind 1 and kind 6/16 events with:
   - `media_images` — image URLs
   - `media_youtube` / `media_youtube_ids` — YouTube links
   - `media_hashtags` — `#tag` matches
   - `media_nostr_uris` — `nostr:` URIs
   - For reposts (kind 6/16): `repost_*` fields resolving original event from pool
5. Timeline pool emits `TimelineUpdated` after 400ms debounce

---

## Usage Pattern

```gdscript
# Get events from a custom subscription
NostrGD.EventReceived.connect(_on_event)

func _on_event(sub_id: String, ev: Dictionary):
    if sub_id == "my_sub":
        var content = ev.get("content", "")
        var kind = ev.get("kind", 0)
        # handle event...

# Broadcast to specific relays only
var read_relays = NostrGD.GetConnectedRelayUrls()
for url in read_relays:
    if _relay_can_read(url):
        NostrGD.RequestNotificationsForRelay("notif", pubkey, url)
```

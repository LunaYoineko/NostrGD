# NostrGD

A pure GDScript **Nostr protocol** plugin for Godot 4.x with a reference client.

Enable it as an EditorPlugin or register it in `project.godot` autoload, then use the `NostrGD` singleton from any GDScript.

---

## Features

### NostrGD SDK (addons/nostr_godot/)

| Feature | Description |
|---------|-------------|
| **Relay Management** | Multi-relay WebSocket connections, auto-reconnect, message queuing, per-relay read/write permissions |
| **Key Management** | Generate / import (nsec/hex) / persist via ConfigFile |
| **NIP-07 Auth** | Browser extension auth via local HTTP server or Web JavaScriptBridge |
| **Event Sending** | All standard kinds (0/1/4/6/7/9734) + arbitrary custom events via `SendCustomEvent` |
| **Event Receiving** | Signal-based dispatch for all kinds, automatic timeline pool (100 events, 400ms debounce) |
| **Timeline** | Kind 1 events sorted by time, auto-extraction of images/URLs/hashtags/YouTube, repost resolution, Japanese language filter |
| **NWC (NIP-47)** | Wallet connect, balance, pay invoice, create invoice, lookup invoice (ECDH/NIP-04 encrypted) |
| **Pure GDScript Crypto** | BigInt-based secp256k1/BIP340/ECDH/AES-256-CBC with optional GDExtension fallback |
| **bech32 Utilities** | npub/nsec encode/decode |
| **Zap (NIP-57)** | Zap request event creation and broadcast |
| **Bookmarks** | Local JSON storage + kind 10003 relay sync |

### Reference Client (main.gd / main.tscn)

| Feature | Description |
|---------|-------------|
| **Sidebar Navigation** | Timeline / Profile / DM / Notifications / Bookmarks / Settings |
| **Timeline Display** | Profile name, avatar, zap, like, repost, reply, bookmark buttons |
| **Inline Images** | Auto-load and display image URLs from posts |
| **YouTube Embeds** | Thumbnail loading with click-to-browse |
| **Hashtag Display** | `#tag` extraction with clickable links |
| **Repost Embedding** | SDK-resolved original event nested display |
| **Profile Editing** | Display name, bio, avatar, banner, LUD16 |
| **NWC UI** | Connection string input, save/clear, ⚡ payment button |
| **Notifications Tab** | Zap, reaction, repost, and reply event list |
| **Bookmarks Tab** | 🔖 toggle on timeline, local save + kind 10003 relay sync |
| **Relay Settings** | TextEdit-based multi-line editing with `url r w` permission format |
| **Dark Theme** | Custom StyleBox dark UI |

---

## Installation

### 1. Copy addons

```bash
cp -r path/to/NostrGD/addons/nostr_godot your_project/addons/
```

### 2. Register Singleton

**Method A: Enable as EditorPlugin (recommended)**

1. Open Godot Editor
2. **Project → Project Settings → Plugins** tab
3. Set `NostrGD` **Status** to `Enable`
4. `nostr_gd_plugin.gd` auto-registers the `NostrGD` singleton

**Method B: Manual autoload in project.godot**

Add to `[autoload]` section:
```
NostrGD="*res://addons/nostr_godot/nostr_gd_client.gd"
```

### 3. GDExtension (optional, for speed)

`libnostr_crypto.so` is included in `addons/nostr_godot/gdextension/lib/`.
The pure GDScript fallback works without it.

### Web Export

No additional setup required — the plugin fully supports HTML5 export via `JavaScriptBridge`.

---

## Architecture

```
addons/nostr_godot/
├── secp256k1.gd              # Pure GDScript crypto (BIP340, ECDH, AES-256-CBC, bech32)
├── nostr_gd_client.gd         # Core client (relay, keys, events, NWC, timeline)
├── nostr_gd_plugin.gd         # EditorPlugin: auto-register singleton
├── plugin.cfg                 # Plugin config (entry: nostr_gd_plugin.gd)
├── gdextension/               # GDExtension C++ libsecp256k1 (speed optimization)
│   ├── lib/libnostr_crypto.so
│   ├── src/nostr_crypto.cpp
│   └── nostr_crypto.gdextension
├── icon.png
└── icon.png.import

scripts/
└── nostr_utils.gd             # GDScript utilities (LUD16 resolution, custom emoji)

main.gd / main.tscn            # Reference client
```

---

## Quick Start (GDScript)

```gdscript
# Connect to relays
NostrGD.ConnectToRelay("wss://relay.damus.io")
NostrGD.ConnectToRelay("wss://nos.lol")
NostrGD.ActivateRelayProcessing()

# Connect signals
NostrGD.Connected.connect(func(url): print("Connected: ", url))
NostrGD.TimelineUpdated.connect(func(timeline): print("Events: ", timeline.size()))

# Login with nsec or hex
if NostrGD.Login(nsec_key):
    print("Logged in: ", NostrGD.GetPublicKeyHex())

# Post a text note
NostrGD.SendTextNote("Hello Nostr from Godot!")

# Request timeline
NostrGD.RequestTimeline("global_feed", 20)
```

---

## Relay Permission Format

Relay URLs are specified one per line in the settings TextEdit:

```
wss://relay.damus.io r w
wss://nos.lol r
wss://relay.example.com w
wss://historical-relay.com
```

- `r` = read (timeline, notifications, DM subscriptions)
- `w` = write (event broadcast, zap relay tags)
- Omitted = both `r w` assumed

---

## SDK Reference

See [docs/sdk_reference.md](docs/sdk_reference.md) for the complete API documentation.

---

## Tech Stack

- **Godot 4.x** (.NET not required — pure GDScript)
- **Crypto**: Custom `secp256k1.gd` (BigInt + hand-rolled BIP340/ECDH/AES-256-CBC)
- **GDExtension**: C++ libsecp256k1 for speed (falls back to GDScript)
- **Platform**: Windows / Linux / macOS / Web (WebSocket + JavaScriptBridge)

---

## License

MIT License

Copyright (c) 2026 Yonaka Luna

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net.WebSockets;
using System.Threading;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using Godot;
using Godot.Collections;
using NBitcoin.Secp256k1;
using Nostr.Sdk;

// ============================================================
// NostrGDClient - 鍵管理・Nostrメッセージ処理モジュール
//
// 秘密鍵の生成/インポート/ログアウト、Nostr イベントの
// 送信・受信処理、タイムライン管理、署名生成、
// Bech32 エンコード/デコードを担当する。
// ============================================================
public partial class NostrGDClient
{
    // ============================================================
    // 定数 - メディア検出用正規表現 / タイムライン制限
    // ============================================================

    private const int MaxTimelineItems = 20;

    // 画像URL (jpg/jpeg/png/gif/webp) を content から抽出
    private static readonly Regex ImageRegex = new Regex(
        @"(https?://\S+\.(?:jpg|jpeg|png|gif|webp)(?:\?\S+)?)",
        RegexOptions.IgnoreCase | RegexOptions.Compiled
    );

    // nostr: で始まるURI (プロフィールやイベントへの参照)
    private static readonly Regex NostrUriRegex = new Regex(
        @"(nostr:[a-z0-9]+)",
        RegexOptions.IgnoreCase | RegexOptions.Compiled
    );

    // YouTube動画URL (youtube.com/watch?v= / youtu.be/)
    private static readonly Regex YoutubeRegex = new Regex(
        @"(https?://(?:www\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([a-zA-Z0-9_-]+)\S*)",
        RegexOptions.IgnoreCase | RegexOptions.Compiled
    );

    // #hashtag を content から抽出
    private static readonly Regex HashtagRegex = new Regex(
        @"#(\w+)",
        RegexOptions.Compiled
    );

    // ============================================================
    // Public API - 鍵の生成・インポート
    // ============================================================

    /// <summary>
    /// 新しい鍵ペアをランダム生成し、nsec (Bech32) 形式の
    /// 秘密鍵文字列を返す。生成後は自動的にログイン状態になる。
    /// </summary>
    public string CreateNewKeyPair()
    {
        byte[] randomBytes = new byte[32];

        using (var rng = System.Security.Cryptography.RandomNumberGenerator.Create())
        {
            rng.GetBytes(randomBytes);
        }

        if (ECPrivKey.TryCreate(randomBytes, out var privKey))
        {
            _privateKey = privKey;
            _publicKey = _privateKey.CreateXOnlyPubKey();

            string hexPrivateKey = Convert.ToHexString(randomBytes).ToLower();
            GD.Print($"NostrGD: Generated new keypair. Pubkey: {GetPublicKeyHex()}");

            return EncodeHexToBech32("nsec", hexPrivateKey);
        }

        GD.PrintErr("NostrGD: Failed to generate a valid private key.");
        return string.Empty;
    }

    /// <summary>現在の秘密鍵を hex 形式で取得する。</summary>
    public string GetPrivateKeyHex()
    {
        if (_privateKey == null) return string.Empty;
        Span<byte> privBytes = stackalloc byte[32];
        _privateKey.WriteToSpan(privBytes);
        return Convert.ToHexString(privBytes).ToLower();
    }

    /// <summary>現在の秘密鍵を nsec (Bech32) 形式で取得する。</summary>
    public string GetPrivateKeyNsec()
    {
        if (_privateKey == null) return string.Empty;
        Span<byte> privBytes = stackalloc byte[32];
        _privateKey.WriteToSpan(privBytes);

        string hexPriv = Convert.ToHexString(privBytes).ToLower();
        return EncodeHexToBech32("nsec", hexPriv);
    }

    /// <summary>
    /// nsec (Bech32) または hex 形式の秘密鍵でログインする。
    /// 成功時に true、失敗時に false を返す。
    /// </summary>
    public bool Login(string keyInput)
    {
        string hexKey = keyInput.Trim();

        if (hexKey.StartsWith("nsec1"))
        {
            try
            {
                hexKey = DecodeBech32ToHex("nsec", hexKey);
            }
            catch (Exception ex)
            {
                GD.PrintErr($"NostrGD Bech32 Decode Error: {ex.Message}");
                return false;
            }
        }

        return LoginWithHexPrivateKey(hexKey);
    }

    /// <summary>16進数形式の秘密鍵でログインする。</summary>
    public bool LoginWithHexPrivateKey(string hexPrivateKey)
    {
        try
        {
            byte[] keyBytes = StringToByteArray(hexPrivateKey);

            if (ECPrivKey.TryCreate(keyBytes, out var privKey))
            {
                _privateKey = privKey;
                _publicKey = _privateKey.CreateXOnlyPubKey();

                GD.Print($"NostrGD: Logged in! Public Key (Hex): {GetPublicKeyHex()}");
                return true;
            }
        }
        catch (Exception ex)
        {
            GD.PrintErr($"NostrGD: Login Error: {ex.Message}");
        }

        GD.PrintErr("NostrGD: Invalid private key Hex.");
        return false;
    }

    // ============================================================
    // Public API - 拡張機能ログイン / ログアウト / 公開鍵取得
    // ============================================================

    /// <summary>
    /// ブラウザ拡張機能 (NIP-07) 経由でログインする。
    /// 秘密鍵は Godot 側には保存されず、署名は都度ブラウザ経由で行う。
    /// </summary>
    public void LoginWithExtension(string pubkeyHex)
    {
        _privateKey = null;
        _publicKey = null;
        _extensionPubkeyHex = pubkeyHex.ToLower();
        _isExtensionLogin = true;
        GD.Print($"NostrGD: Logged in via NIP-07 Extension! Pubkey: {_extensionPubkeyHex}");
    }

    /// <summary>ログアウトする（秘密鍵をメモリ上から消去）。</summary>
    public void Logout()
    {
        _privateKey = null;
        _publicKey = null;
        GD.Print("NostrGD: Logged out.");
    }

    // ============================================================
    // Public API - 鍵の保存/読み込み (ConfigFile)
    // ============================================================

    private const string ConfigPath = "user://nostr_config.cfg";

    /// <summary>秘密鍵を ConfigFile に保存する（次回起動時の自動ログイン用）。</summary>
    public void SavePrivateKey(string key)
    {
        var config = new ConfigFile();
        config.Load(ConfigPath);
        config.SetValue("auth", "private_key", key);
        config.Save(ConfigPath);
        GD.Print("NostrGD: Private key saved.");
    }

    /// <summary>ConfigFile から秘密鍵を読み込む。無ければ空文字を返す。</summary>
    public string LoadPrivateKey()
    {
        var config = new ConfigFile();
        Error err = config.Load(ConfigPath);
        if (err == Error.Ok)
        {
            return config.GetValue("auth", "private_key", "").AsString();
        }
        return string.Empty;
    }

    /// <summary>保存済みの秘密鍵が存在するか確認する。</summary>
    public bool HasSavedPrivateKey()
    {
        return !string.IsNullOrEmpty(LoadPrivateKey());
    }

    /// <summary>リレーURLリストを ConfigFile に保存する。</summary>
    public void SaveRelayUrls(Godot.Collections.Array urls)
    {
        var config = new ConfigFile();
        config.Load(ConfigPath);
        if (urls != null && urls.Count > 0)
        {
            for (int i = 0; i < urls.Count; i++)
                config.SetValue("relays", i.ToString(), urls[i].AsString());
        }
        config.Save(ConfigPath);
    }

    /// <summary>ConfigFile からリレーURLリストを読み込む。</summary>
    public Godot.Collections.Array LoadRelayUrls()
    {
        var result = new Godot.Collections.Array();
        var config = new ConfigFile();
        if (config.Load(ConfigPath) == Error.Ok && config.HasSection("relays"))
        {
            var keys = config.GetSectionKeys("relays");
            foreach (var key in keys)
            {
                string url = config.GetValue("relays", key, "").AsString();
                if (!string.IsNullOrEmpty(url))
                    result.Add(url);
            }
        }
        return result;
    }

    /// <summary>公開鍵を16進数で取得する。</summary>
    public string GetPublicKeyHex()
    {
        if (_isExtensionLogin) return _extensionPubkeyHex;
        if (_publicKey == null) return string.Empty;
        return Convert.ToHexString(_publicKey.ToBytes()).ToLower();
    }

    /// <summary>公開鍵を npub (Bech32) 形式で取得する。</summary>
    public string GetPublicKeyNpub()
    {
        string hexPub = GetPublicKeyHex();
        if (string.IsNullOrEmpty(hexPub)) return string.Empty;

        return EncodeHexToBech32("npub", hexPub);
    }

    // ============================================================
    // Public API - Nostr イベント送信
    // ============================================================

    /// <summary>Kind 0 のプロフィールメタデータをリレーに送信する。</summary>
    public void SendProfileMetaData(string name, string displayName, string about = "", string picture = "", string banner = "", string lud16 = "")
    {
        if (!IsLoggedIn) return;

        var profileContent = new Dictionary { { "name", name }, { "display_name", displayName }, { "about", about } };
        if (!string.IsNullOrEmpty(picture)) profileContent.Add("picture", picture);
        if (!string.IsNullOrEmpty(banner)) profileContent.Add("banner", banner);
        if (!string.IsNullOrEmpty(lud16)) profileContent.Add("lud16", lud16);
        var eventDict = new Dictionary
        {
            { "pubkey", GetPublicKeyHex() },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 0 },
            { "tags", new Godot.Collections.Array() },
            { "content", Json.Stringify(profileContent) }
        };

        string eventId = CalculateEventId(eventDict);
        eventDict.Add("id", eventId);
        eventDict.Add("sig", CreateSchnorrSignature(eventId));

        BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });

        GD.Print($"NostrGD: Sent Profile MetaData (Kind 0). ID: {eventId}");
    }

    /// <summary>
    /// Kind 1 のテキストノートをリレーに送信する。
    /// 秘密鍵でのログイン時はローカル署名、
    /// 拡張機能ログイン時はブラウザ経由でリモート署名を行う。
    /// </summary>
    public async void SendTextNote(string content)
    {
        if (!IsLoggedIn) return;

        var eventTags = new Godot.Collections.Array
        {
            new Godot.Collections.Array { "client", "NostrGD" }
        };
        var eventDict = new Dictionary
        {
            { "pubkey", GetPublicKeyHex() },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 1 },
            { "tags", eventTags },
            { "content", content }
        };

        string eventId = CalculateEventId(eventDict);
        eventDict.Add("id", eventId);

        if (_privateKey != null)
        {
            eventDict.Add("sig", CreateSchnorrSignature(eventId));
            BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });
            return;
        }

        if (_isExtensionLogin && _wsContext != null && _wsContext.WebSocket.State == WebSocketState.Open)
        {
            GD.Print("NostrGD: Requesting signature from browser extension...");
            _signatureTcs = new TaskCompletionSource<string>();

            var requestPayload = new Dictionary
            {
                { "type", "SIGN_REQUEST" },
                { "event", eventDict }
            };

            string requestJson = Json.Stringify(requestPayload);
            byte[] sendBuffer = System.Text.Encoding.UTF8.GetBytes(requestJson);
            await _wsContext.WebSocket.SendAsync(new ArraySegment<byte>(sendBuffer), WebSocketMessageType.Text, true, CancellationToken.None);

            var completedTask = await Task.WhenAny(_signatureTcs.Task, Task.Delay(30000));
            if (completedTask == _signatureTcs.Task)
            {
                string signature = await _signatureTcs.Task;
                if (!string.IsNullOrEmpty(signature))
                {
                    eventDict.Add("sig", signature);
                    BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });
                    GD.Print($"NostrGD: Post successful via browser signature! ID: {eventId}");
                    return;
                }
            }
            GD.PrintErr("NostrGD: Remote signing timeed out or rejected.");
        }
        else
        {
            GD.PrintErr("NostrGD: Browser connection lost. Please re-authenticate.");
        }
    }

    /// <summary>リポスト (Kind 6) を送信する。</summary>
    public void SendRepost(string targetEventId)
    {
        if (!IsLoggedIn) return;

        var tags = new Godot.Collections.Array
        {
            new Godot.Collections.Array { "e", targetEventId }
        };

        var eventDict = new Dictionary
        {
            { "pubkey", GetPublicKeyHex() },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 6 },
            { "tags", tags },
            { "content", "" }
        };

        string eid = CalculateEventId(eventDict);
        eventDict.Add("id", eid);
        eventDict.Add("sig", CreateSchnorrSignature(eid));

        BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });
        GD.Print($"NostrGD: Sent Repost (Kind 6). ID: {eid}");
    }

    /// <summary>返信 (Kind 1 + e/pタグ) を送信する。</summary>
    public void SendReply(string content, string replyToEventId, string replyToPubkey)
    {
        if (!IsLoggedIn) return;

        var tags = new Godot.Collections.Array
        {
            new Godot.Collections.Array { "e", replyToEventId },
            new Godot.Collections.Array { "p", replyToPubkey },
            new Godot.Collections.Array { "client", "NostrGD" }
        };

        var eventDict = new Dictionary
        {
            { "pubkey", GetPublicKeyHex() },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 1 },
            { "tags", tags },
            { "content", content }
        };

        string eid = CalculateEventId(eventDict);
        eventDict.Add("id", eid);
        eventDict.Add("sig", CreateSchnorrSignature(eid));

        BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });
        GD.Print($"NostrGD: Sent Reply (Kind 1). ID: {eid}");
    }

    /// <summary>Kind 4 ダイレクトメッセージ (NIP-04 暗号化なし、content = 平文) を送信する。</summary>
    public void SendDirectMessage(string content, string targetPubkey)
    {
        if (!IsLoggedIn) return;

        var tags = new Godot.Collections.Array
        {
            new Godot.Collections.Array { "p", targetPubkey }
        };

        var eventDict = new Dictionary
        {
            { "pubkey", GetPublicKeyHex() },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 4 },
            { "tags", tags },
            { "content", content }
        };

        string eid = CalculateEventId(eventDict);
        eventDict.Add("id", eid);
        eventDict.Add("sig", CreateSchnorrSignature(eid));

        BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });
        GD.Print($"NostrGD: Sent Direct Message (Kind 4). ID: {eid}");
    }

    /// <summary>指定公開鍵宛ての通知系イベント (Kind 7/6/16/9735) をリレーに要求する。</summary>
    public void RequestNotifications(string subscriptionId, string pubkey)
    {
        var authorsArray = new Godot.Collections.Array { pubkey };
        var filter = new Dictionary
        {
            { "kinds", new Godot.Collections.Array { 7, 6, 16, 9735 } },
            { "#p", authorsArray },
            { "limit", 30 }
        };
        var message = new Godot.Collections.Array { "REQ", subscriptionId, filter };
        BroadcastMessage(message);
        GD.Print($"NostrGD: Requested notifications for {pubkey}");
    }

    /// <summary>指定公開鍵宛ての DM (Kind 4) をリレーに要求する。</summary>
    public void RequestDirectMessages(string subscriptionId, string pubkey)
    {
        var filter = new Dictionary
        {
            { "kinds", new Godot.Collections.Array { 4 } },
            { "#p", new Godot.Collections.Array { pubkey } },
            { "limit", 50 }
        };
        var message = new Godot.Collections.Array { "REQ", subscriptionId, filter };
        BroadcastMessage(message);
        GD.Print($"NostrGD: Requested DMs for {pubkey}");
    }

    // ============================================================
    // Public API - リアクション (Kind 7)
    // ============================================================

    /// <summary>
    /// 指定イベントにリアクションを送信する (Kind 7)。
    /// 絵文字（または "+"/"-"）を content に設定する。
    /// </summary>
    public void SendReaction(string targetEventId, string targetPubkey, string emoji = "+")
    {
        if (!IsLoggedIn) return;

        var tags = new Godot.Collections.Array
        {
            new Godot.Collections.Array { "e", targetEventId },
            new Godot.Collections.Array { "p", targetPubkey }
        };

        var eventDict = new Dictionary
        {
            { "pubkey", GetPublicKeyHex() },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 7 },
            { "tags", tags },
            { "content", emoji }
        };

        string eventId = CalculateEventId(eventDict);
        eventDict.Add("id", eventId);
        eventDict.Add("sig", CreateSchnorrSignature(eventId));

        BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });
        GD.Print($"NostrGD: Sent Reaction (Kind 7). ID: {eventId}");
    }

    // ============================================================
    // Public API - Zap 要求 (Kind 9734)
    // ============================================================

    /// <summary>
    /// Zap 要求 (Kind 9734) を作成し、シグネチャまで済ませた
    /// Dictionary を返す。LNURL コールバックの nostr パラメータに
    /// このイベントの JSON を渡すために使用する。
    /// ブロードキャストは行わない。
    /// </summary>
    public Dictionary CreateZapRequestEvent(string targetEventId, string targetPubkey, long amountMsat, string comment = "", Array<string> relayUrls = null)
    {
        var tags = new Godot.Collections.Array
        {
            new Godot.Collections.Array { "p", targetPubkey },
            new Godot.Collections.Array { "amount", amountMsat.ToString() }
        };

        if (!string.IsNullOrEmpty(targetEventId))
        {
            tags.Add(new Godot.Collections.Array { "e", targetEventId });
        }

        if (relayUrls != null && relayUrls.Count > 0)
        {
            tags.Add(new Godot.Collections.Array { "relays" }.Duplicate());
            var relaysTag = tags[tags.Count - 1].AsGodotArray();
            foreach (var url in relayUrls)
            {
                relaysTag.Add(url);
            }
        }

        var eventDict = new Dictionary
        {
            { "pubkey", GetPublicKeyHex() },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 9734 },
            { "tags", tags },
            { "content", comment }
        };

        string eventId = CalculateEventId(eventDict);
        eventDict.Add("id", eventId);
        eventDict.Add("sig", CreateSchnorrSignature(eventId));

        GD.Print($"NostrGD: Created Zap Request (Kind 9734). ID: {eventId}");
        return eventDict;
    }

    /// <summary>
    /// Zap 要求 (Kind 9734) を作成し、リレーにブロードキャストする。
    /// LNURL フローの一部として使用する場合は CreateZapRequestEvent で
    /// JSON を取得してから callback に POST すること。
    /// </summary>
    public void SendZapRequest(string targetEventId, string targetPubkey, long amountMsat, string comment = "", Array<string> relayUrls = null)
    {
        var eventDict = CreateZapRequestEvent(targetEventId, targetPubkey, amountMsat, comment, relayUrls);
        BroadcastMessage(new Godot.Collections.Array { "EVENT", eventDict });
        GD.Print($"NostrGD: Broadcasted Zap Request (Kind 9734). ID: {eventDict["id"]}");
    }

    // ============================================================
    // Public API - Nostr クエリ
    // ============================================================

    /// <summary>指定公開鍵リストの Kind 0 プロフィールをリレーに要求する。</summary>
    public void RequestProfiles(string subscriptionId, Array<string> pubkeys)
    {
        var filter = new Dictionary { { "kinds", new Godot.Collections.Array { 0 } }, { "authors", pubkeys } };
        var message = new Godot.Collections.Array { "REQ", subscriptionId, filter };
        BroadcastMessage(message);
        GD.Print($"NostrGD: Requested profiles for {pubkeys.Count} users.");
    }

    /// <summary>Kind 1 テキストノートのタイムラインをリレーに要求する。</summary>
    public void RequestTimeline(string subscriptionId, int limit = 20, string targetUrl = "")
    {
        var filter = new Dictionary { { "kinds", new Godot.Collections.Array { 1 } }, { "limit", limit } };
        var message = new Godot.Collections.Array { "REQ", subscriptionId, filter };
        string jsonStr = Json.Stringify(message);

        foreach (var relay in _relays)
        {
            if (relay.IsConnected && (string.IsNullOrEmpty(targetUrl) || relay.Url == targetUrl))
            {
                relay.Socket.SendText(jsonStr);
                GD.Print($"NostrGD: Requested timeline with subscription ID: {subscriptionId}");
            }
        }
    }

    /// <summary>指定したイベントに対する Zap 受領書 (Kind 9735) をリレーに要求する。</summary>
    public void RequestZapReceipts(string subscriptionId, Array<string> eventIds)
    {
        var filter = new Dictionary { { "kinds", new Godot.Collections.Array { 9735 } }, { "#e", eventIds } };
        var message = new Godot.Collections.Array { "REQ", subscriptionId, filter };
        BroadcastMessage(message);
        GD.Print($"NostrGD: Requested zap receipts for {eventIds.Count} events.");
    }

    /// <summary>指定したイベントIDで単一イベントをリレーに要求する (埋め込み表示用)。</summary>
    public void RequestEventById(string eventId, string subscriptionId)
    {
        var filter = new Dictionary
        {
            { "ids", new Godot.Collections.Array { eventId } },
            { "limit", 1 }
        };
        var message = new Godot.Collections.Array { "REQ", subscriptionId, filter };
        BroadcastMessage(message);
        GD.Print($"NostrGD: Requested event {eventId} via {subscriptionId}");
    }

    /// <summary>指定サブスクリプションをクローズする。</summary>
    public void CloseSubscription(string subscriptionId)
    {
        var message = new Godot.Collections.Array { "CLOSE", subscriptionId };
        BroadcastMessage(message);
        GD.Print($"NostrGD: Closed subscription {subscriptionId}");
    }

    // ============================================================
    // Private - 受信パケット処理
    // ============================================================

    /// <summary>リレーから受信した1パケットをパースして振り分ける。</summary>
    private void HandleIncomingPacket(RelayConnection relay)
    {
        byte[] packet = relay.Socket.GetPacket();
        string jsonStr = System.Text.Encoding.UTF8.GetString(packet);

        var json = new Json();
        if (json.Parse(jsonStr) != Error.Ok)
        {
            GD.Print($"NostrGD: Invalid JSON: {jsonStr}");
            return;
        }

        if (json.Data.VariantType != Variant.Type.Array) return;
        Godot.Collections.Array parsedArray = (Godot.Collections.Array)json.Data;
        if (parsedArray.Count == 0) return;

        string command = parsedArray[0].AsString();
        EmitSignal(SignalName.MessageReceived, relay.Url, command, parsedArray);

        switch (command)
        {
            case "EVENT":
                if (parsedArray.Count >= 3)
                {
                    string subId = parsedArray[1].AsString();
                    Dictionary eventDict = parsedArray[2].AsGodotDictionary();

                    EmitSignal(SignalName.EventReceived, subId, eventDict);

                    ProcessIncomingEventForTimeline(eventDict);
                    RouteEventByKind(eventDict, relay.Url, subId);
                }
                break;
            case "NOTICE":
                if (parsedArray.Count >= 2)
                {
                    EmitSignal(SignalName.NoticeReceived, relay.Url, parsedArray[1].AsString());
                    GD.Print($"NostrGD: {parsedArray[1].AsString()}");
                }
                break;
            case "OK":
                GD.Print($"NostrGD: {jsonStr}");
                break;
        }
    }

    /// <summary>イベントの kind に応じて専用シグナルを発行する。</summary>
    private void RouteEventByKind(Dictionary eventDict, string url, string subscriptionId)
    {
        if (!eventDict.ContainsKey("kind")) return;
        int kind = eventDict["kind"].AsInt32();

        switch (kind)
        {
            case 4:
                EmitSignal(SignalName.DirectMessageReceived, url, subscriptionId, eventDict);
                break;
            case 7:
                EmitSignal(SignalName.ReactionReceived, url, subscriptionId, eventDict);
                break;
            case 9735:
                EmitSignal(SignalName.ZapReceiptReceived, url, subscriptionId, eventDict);
                break;
            case 23194:
                EmitSignal(SignalName.NwcResponseReceived, url, subscriptionId, eventDict);
                break;
            case 23195:
                GD.Print($"NostrGD/NWC: Received kind 23195 response from {eventDict["pubkey"]} via {url}");
                if (eventDict.ContainsKey("tags"))
                {
                    foreach (var tag in eventDict["tags"].AsGodotArray())
                    {
                        var t = tag.AsGodotArray();
                        if (t.Count >= 2)
                            GD.Print($"NostrGD/NWC:   tag {t[0]}: {t[1]}");
                    }
                }
                // 復号を試行
                if (NwcDecryptContent != null && eventDict.ContainsKey("content"))
                {
                    try
                    {
                        string decrypted = NwcDecryptContent(eventDict["content"].AsString(), eventDict["pubkey"].AsString());
                        eventDict["decrypted_content"] = decrypted;
                        GD.Print($"NostrGD/NWC: Decrypted content: {decrypted}");
                    }
                    catch (Exception ex)
                    {
                        GD.PrintErr($"NostrGD/NWC: Decryption failed: {ex.Message}");
                    }
                }
                EmitSignal(SignalName.NwcResponseReceived, url, subscriptionId, eventDict);
                break;
        }
    }

    // ============================================================
    // Private - タイムライン管理 (Kind 1 イベント)
    // ============================================================

    /// <summary>
    /// Kind 1 イベントをタイムラインプールに追加する。
    /// content 内の画像URL・nostr URI・YouTube URLを事前に抽出し、
    /// eventDict に media_* キーとして付与した上でプールに格納する。
    /// 追加後、100ms のデバウンスを経て UI 更新シグナルを発行する。
    /// </summary>
    private void ProcessIncomingEventForTimeline(Dictionary eventDict)
    {
        if (!eventDict.ContainsKey("kind")) return;
        int kind = eventDict["kind"].AsInt32();

        if (kind == 1)
        {
            string content = eventDict.ContainsKey("content") ? eventDict["content"].AsString() : "";

            var imageUrls = new Godot.Collections.Array<string>();
            foreach (Match match in ImageRegex.Matches(content))
            {
                imageUrls.Add(match.Value);
            }
            eventDict["media_images"] = imageUrls;

            var nostrUris = new Godot.Collections.Array<string>();
            foreach (Match match in NostrUriRegex.Matches(content))
            {
                nostrUris.Add(match.Value);
            }
            eventDict["media_nostr_uris"] = nostrUris;

            var youtubeUrls = new Godot.Collections.Array<string>();
            var youtubeIds = new Godot.Collections.Array<string>();
            foreach (Match match in YoutubeRegex.Matches(content))
            {
                youtubeUrls.Add(match.Value);
                if (match.Groups.Count >= 3)
                    youtubeIds.Add(match.Groups[2].Value);
            }
            eventDict["media_youtube"] = youtubeUrls;
            eventDict["media_youtube_ids"] = youtubeIds;

            var hashtags = new Godot.Collections.Array<string>();
            foreach (Match match in HashtagRegex.Matches(content))
            {
                hashtags.Add(match.Value);
            }
            eventDict["media_hashtags"] = hashtags;

            lock (_timelinePool)
            {
                _timelinePool.Add(eventDict);
                TrimTimelinePool();
            }

            TriggerTimelineUpdateWithDelay();
        }
        else if (kind == 6 || kind == 16)
        {
            eventDict["is_repost"] = true;
            string repostEventId = "";

            if (eventDict.ContainsKey("tags"))
            {
                var tags = eventDict["tags"].AsGodotArray();
                foreach (var tag in tags)
                {
                    var tagArr = tag.AsGodotArray();
                    if (tagArr.Count >= 2)
                    {
                        string key = tagArr[0].AsString();
                        if (key == "e")
                        {
                            repostEventId = tagArr[1].AsString();
                            eventDict["repost_event_id"] = repostEventId;
                        }
                        else if (key == "p")
                            eventDict["repost_pubkey"] = tagArr[1].AsString();
                    }
                }
            }

            // 元イベントをタイムラインプールから探して埋め込む
            if (!string.IsNullOrEmpty(repostEventId))
            {
                lock (_timelinePool)
                {
                    foreach (var ev in _timelinePool)
                    {
                        if (ev.ContainsKey("id") && ev["id"].AsString() == repostEventId)
                        {
                            eventDict["repost_original_content"] = ev.ContainsKey("content") ? ev["content"].AsString() : "";
                            eventDict["repost_original_pubkey"] = ev.ContainsKey("pubkey") ? ev["pubkey"].AsString() : "";
                            if (ev.ContainsKey("media_images"))
                                eventDict["repost_media_images"] = ev["media_images"];
                            if (ev.ContainsKey("media_youtube"))
                                eventDict["repost_media_youtube"] = ev["media_youtube"];
                            if (ev.ContainsKey("media_youtube_ids"))
                                eventDict["repost_media_youtube_ids"] = ev["media_youtube_ids"];
                            if (ev.ContainsKey("media_hashtags"))
                                eventDict["repost_media_hashtags"] = ev["media_hashtags"];
                            break;
                        }
                    }
                }
            }

            lock (_timelinePool)
            {
                _timelinePool.Add(eventDict);
                TrimTimelinePool();
            }

            TriggerTimelineUpdateWithDelay();
        }
    }

    /// <summary>
    /// タイムライン更新を100msデバウンスしてから発行する。
    /// 連続するイベントをまとめるため、前回の遅延が残っていれば
    /// キャンセルしてから再スケジュールする。
    /// </summary>
    private async void TriggerTimelineUpdateWithDelay()
    {
        _debounceCts?.Cancel();
        _debounceCts = new CancellationTokenSource();
        var token = _debounceCts.Token;

        try
        {
            await Task.Delay(100, token);
            await ToSignal(GetTree(), SceneTree.SignalName.ProcessFrame);

            if (!token.IsCancellationRequested)
            {
                BroadcastSortedTimeline();
            }
        }
        catch (TaskCanceledException)
        {
            // キャンセルされた場合はスルー
        }
    }

    /// <summary>タイムラインプールが最大件数を超えた場合、古いイベントを削除する。</summary>
    private void TrimTimelinePool()
    {
        while (_timelinePool.Count > MaxTimelineItems)
        {
            _timelinePool.Remove(_timelinePool.Last());
        }
    }

    /// <summary>タイムラインプールをソートして UI にブロードキャストする。</summary>
    private void BroadcastSortedTimeline()
    {
        var sortedGodotArray = new Godot.Collections.Array();

        lock (_timelinePool)
        {
            foreach (var ev in _timelinePool)
            {
                sortedGodotArray.Add(ev);
            }
        }

        EmitSignal(SignalName.TimelineUpdated, sortedGodotArray);
        GD.Print($"NostrGD: UI timeline refreshed with {sortedGodotArray.Count} items ordered by created_at.");
    }

    // ============================================================
    // Private - 暗号処理 (イベントID算出 / Schnorr署名)
    // ============================================================

    /// <summary>
    /// Nostr イベントの ID を計算する。
    /// シリアライズ仕様: [0, pubkey, created_at, kind, tags, content] を
    /// JSON 化し、SHA256 ハッシュを16進数で返す。
    /// </summary>
    private string CalculateEventId(Dictionary ev)
    {
        var serializeTarget = new Godot.Collections.Array
        {
            0,
            ev["pubkey"].AsString(),
            ev["created_at"].AsInt64(),
            ev["kind"].AsInt32(),
            ev["tags"].AsGodotArray(),
            ev["content"].AsString()
        };

        string jsonStr = Json.Stringify(serializeTarget);
        byte[] jsonBytes = System.Text.Encoding.UTF8.GetBytes(jsonStr);
        byte[] hashBytes = System.Security.Cryptography.SHA256.HashData(jsonBytes);

        return Convert.ToHexString(hashBytes).ToLower();
    }

    /// <summary>
    /// BIP340 Schnorr 署名を生成する (デフォルト秘密鍵使用)。
    /// 秘密鍵が存在しない場合 (拡張機能ログイン時) は呼び出さないこと。
    /// </summary>
    private string CreateSchnorrSignature(string eventIdHex)
    {
        return CreateSchnorrSignature(eventIdHex, _privateKey);
    }

    /// <summary>
    /// BIP340 Schnorr 署名を生成する (指定した秘密鍵使用)。
    /// </summary>
    private string CreateSchnorrSignature(string eventIdHex, ECPrivKey signingKey)
    {
        byte[] messageHash = StringToByteArray(eventIdHex);

        if (signingKey.TrySignBIP340(messageHash, null, out var signature))
        {
            return Convert.ToHexString(signature.ToBytes()).ToLower();
        }

        throw new Exception("Failed to generate Schnorr signature.");
    }

    // ============================================================
    // Private - Bech32 エンコード / デコード
    // ============================================================

    /// <summary>16進数文字列を Bech32 形式にエンコードする。</summary>
    private string EncodeHexToBech32(string hrp, string hex)
    {
        byte[] data = StringToByteArray(hex);
        byte[] converted = ConvertBits(data, 8, 5, true);

        byte[] checksum = Bech32CreateChecksum(hrp, converted);
        byte[] combined = new byte[converted.Length + checksum.Length];
        System.Array.Copy(converted, 0, combined, 0, converted.Length);
        System.Array.Copy(checksum, 0, combined, converted.Length, checksum.Length);

        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        sb.Append(hrp).Append("1");
        foreach (byte b in combined)
        {
            sb.Append(Bech32Chars[b]);
        }
        return sb.ToString();
    }

    /// <summary>Bech32 文字列を16進数にデコードする。</summary>
    private string DecodeBech32ToHex(string expectedHrp, string bech32Str)
    {
        int pos = bech32Str.LastIndexOf('1');
        if (pos < 1 || pos + 7 > bech32Str.Length) throw new Exception("Invalid Bech32 string");

        string hrp = bech32Str.Substring(0, pos);
        if (hrp != expectedHrp) throw new Exception("HRP mismatch");

        byte[] data = new byte[bech32Str.Length - pos - 1];
        for (int i = 0; i < data.Length; i++)
        {
            int c = Bech32Chars.IndexOf(bech32Str[pos + 1 + i]);
            if (c == -1) throw new Exception("Invalid character");
            data[i] = (byte)c;
        }

        if (!Bech32VerifyChecksum(hrp, data)) throw new Exception("Checksum verification failed");

        byte[] dataWithoutChecksum = new byte[data.Length - 6];
        System.Array.Copy(data, 0, dataWithoutChecksum, 0, dataWithoutChecksum.Length);

        byte[] converted = ConvertBits(dataWithoutChecksum, 5, 8, false);
        return Convert.ToHexString(converted).ToLower();
    }

    /// <summary>ビット列の基数変換 (8→5 / 5→8)。</summary>
    private byte[] ConvertBits(byte[] data, int fromBits, int toBits, bool pad)
    {
        int acc = 0;
        int bits = 0;
        System.Collections.Generic.List<byte> ret = new System.Collections.Generic.List<byte>();
        int maxv = (1 << toBits) - 1;
        int max_acc = (1 << (fromBits + toBits - 1)) -1;

        foreach (byte value in data)
        {
            acc = ((acc << fromBits) | value) & max_acc;
            bits += fromBits;
            while (bits >= toBits)
            {
                bits -= toBits;
                ret.Add((byte)((acc >> bits) & maxv));
            }
        }
        if (pad)
        {
            if (bits > 0) ret.Add((byte)((acc << (toBits - bits)) & maxv));
        }
        else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv) != 0)
        {
            throw new Exception("Invalid padding");
        }
        return ret.ToArray();
    }

    /// <summary>Bech32 チェックサム計算用の多項式剰余。</summary>
    private uint Bech32Polymod(byte[] values)
    {
        uint[] generator = { 0x3b6a57b2U, 0x26508e6dU, 0x1ea119faU, 0x3d4233ddU, 0x2a1462b3U };
        uint chk = 1;
        foreach (byte value in values)
        {
            uint top = chk >> 25;
            chk = ((chk & 0x1ffffff) << 5) ^ value;
            for (int i = 0; i < 5; ++i)
            {
                if (((top >> i) & 1) == 1) chk ^= generator[i];
            }
        }
        return chk;
    }

    /// <summary>HRP (Human Readable Part) をチェックサム計算用に展開する。</summary>
    private byte[] Bech32HrpExpand(string hrp)
    {
        byte[] ret = new byte[hrp.Length * 2 + 1];
        for (int i = 0; i < hrp.Length; i++)
        {
            ret[i] = (byte)(hrp[i] >> 5);
            ret[i + hrp.Length + 1] = (byte)(hrp[i] & 31);
        }
        ret[hrp.Length] = 0;
        return ret;
    }

    /// <summary>Bech32 チェックサムを検証する。</summary>
    private bool Bech32VerifyChecksum(string hrp, byte[] data)
    {
        byte[] exp = Bech32HrpExpand(hrp);
        byte[] combined = new byte[exp.Length + data.Length];
        System.Array.Copy(exp, 0, combined, 0, exp.Length);
        System.Array.Copy(data, 0, combined, exp.Length, data.Length);
        return Bech32Polymod(combined) == 1;
    }

    /// <summary>Bech32 チェックサムを生成する。</summary>
    private byte[] Bech32CreateChecksum(string hrp, byte[] data)
    {
        byte[] exp = Bech32HrpExpand(hrp);
        byte[] combined = new byte[exp.Length + data.Length + 6];
        System.Array.Copy(exp, 0, combined, 0, exp.Length);
        System.Array.Copy(data, 0, combined, exp.Length, data.Length);

        uint polymod = Bech32Polymod(combined) ^ 1;
        byte[] ret = new byte[6];
        for (int i = 0; i < 6; i++)
        {
            ret[i] = (byte)((polymod >> (5 * (5 - i))) & 31);
        }
        return ret;
    }

    // ============================================================
    // Public Utility API - GDScript の nostr_utils.gd 相当の機能
    // ============================================================

    /// <summary>note1.../nevent1... URI を 32バイトの hex event ID に変換する。</summary>
    public static string DecodeNoteId(string uri)
    {
        string s = uri.Trim().ToLowerInvariant();
        if (s.StartsWith("nostr:")) s = s.Substring(6);

        int sep = s.IndexOf('1');
        if (sep == -1) return "";

        string hrp = s.Substring(0, sep);
        string data = s.Substring(sep + 1);

        var values = new List<int>(data.Length);
        foreach (char c in data)
        {
            int idx = Bech32Chars.IndexOf(c);
            if (idx == -1) return "";
            values.Add(idx);
        }

        int checksumLen = 6;
        int len = values.Count - checksumLen;
        if (len <= 0) return "";

        var input = values.GetRange(0, len);

        var bytes = new List<byte>();
        int buffer = 0;
        int bits = 0;
        foreach (int v in input)
        {
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8)
            {
                bits -= 8;
                bytes.Add((byte)((buffer >> bits) & 0xFF));
                buffer &= (1 << bits) - 1;
            }
        }

        if ((hrp == "note" || hrp == "nevent") && bytes.Count >= 32)
        {
            var hex = new System.Text.StringBuilder(64);
            for (int i = 0; i < 32; i++)
                hex.Append(bytes[i].ToString("x2"));
            return hex.ToString();
        }
        return "";
    }

    /// <summary>プロフィールから LNURL エンドポイント URL を解決する。</summary>
    public static string ResolveLnurl(Dictionary profile)
    {
        if (profile.ContainsKey("lud06"))
        {
            string lud06 = profile["lud06"].AsString();
            if (lud06.StartsWith("lnurl"))
                return DecodeLnurl(lud06);
            return lud06;
        }

        if (profile.ContainsKey("lud16"))
        {
            string lud16 = profile["lud16"].AsString();
            var parts = lud16.Split('@');
            if (parts.Length == 2)
                return $"https://{parts[1]}/.well-known/lnurlp/{parts[0]}";
        }

        return "";
    }

    /// <summary>lnurl1... 文字列をデコードして URL に変換する。</summary>
    private static string DecodeLnurl(string lnurl)
    {
        string s = lnurl.Trim().ToLowerInvariant();
        int sep = s.IndexOf('1');
        if (sep == -1) return "";
        string data = s.Substring(sep + 1);

        var values = new List<int>(data.Length);
        foreach (char c in data)
        {
            int idx = Bech32Chars.IndexOf(c);
            if (idx == -1) return "";
            values.Add(idx);
        }

        var bytes = new List<byte>();
        int buffer = 0;
        int bits = 0;
        foreach (int v in values)
        {
            buffer = (buffer << 5) | v;
            bits += 5;
            if (bits >= 8)
            {
                bits -= 8;
                bytes.Add((byte)((buffer >> bits) & 0xFF));
                buffer &= (1 << bits) - 1;
            }
        }

        return System.Text.Encoding.UTF8.GetString(bytes.ToArray());
    }

    /// <summary>カスタム絵文字 (NIP-30) の画像URLを content と tags から解決する。</summary>
    public static string ResolveCustomEmoji(string content, Godot.Collections.Array tags)
    {
        string trimmed = content.Trim();
        if (!trimmed.StartsWith(":") || !trimmed.EndsWith(":"))
            return "";
        string emojiName = trimmed.TrimStart(':').TrimEnd(':');

        foreach (var tagObj in tags)
        {
            if (tagObj.Obj is Godot.Collections.Array tag && tag.Count >= 3
                && tag[0].AsString() == "emoji" && tag[1].AsString() == emojiName)
            {
                return tag[2].AsString();
            }
        }
        return "";
    }

    /// <summary>プロフィールが Lightning ウォレット (lud06/lud16) を持っているか確認する。</summary>
    public static bool HasLud(Dictionary profile)
    {
        return profile.ContainsKey("lud06") || profile.ContainsKey("lud16");
    }
}

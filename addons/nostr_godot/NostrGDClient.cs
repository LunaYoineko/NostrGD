using System;
using System.Data.Common;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Net;
using System.Threading.Tasks;
using Godot;
using Godot.Collections;
using NBitcoin.Secp256k1;
using Nostr.Sdk;
using Nostr.Client.Keys;
using System.Net.WebSockets;
using System.Threading;
using System.Collections.Generic;

// ============================================================
// NostrGDClient
// Godot 用 Nostr クライアント (Autoload Singleton)
// 
// 機能概要:
//   - リレー WebSocket 接続管理
//   - 秘密鍵の生成・インポート (nsec/hex)
//   - ブラウザ拡張機能 (NIP-07) による認証
//   - Nostr イベントの送信 (TextNote, Profile, Reaction, ZapRequest)
//   - リレーからのイベント受信・タイムライン管理
//   - リアクション (Kind 7) / Zap受領書 (Kind 9735) のルーティング
//   - Bech32 エンコード/デコード
//
// 本ファイルは partial class の核心部分です。
// 認証関連 -> NostrGDClient.Auth.cs
// 鍵・メッセージ関連 -> NostrGDClient.Messaging.cs
// に分割されています。
// ============================================================
public partial class NostrGDClient : Node
{
    // ============================================================
    // シグナル定義
    // ============================================================

    [Signal] public delegate void ConnectedEventHandler(string url);
    [Signal] public delegate void DisconnectedEventHandler(string url);
    [Signal] public delegate void MessageReceivedEventHandler(string url, string command, Godot.Collections.Array data);
    [Signal] public delegate void EventReceivedEventHandler(string url, string subscriptionId, Dictionary eventDict);
    [Signal] public delegate void NoticeReceivedEventHandler(string url, string message);
    [Signal] public delegate void ExtensionAuthCompletedEventHandler();
    [Signal] public delegate void TimelineUpdatedEventHandler(Godot.Collections.Array timelineArray);
    [Signal] public delegate void ReactionReceivedEventHandler(string url, string subscriptionId, Dictionary eventDict);
    [Signal] public delegate void ZapReceiptReceivedEventHandler(string url, string subscriptionId, Dictionary eventDict);
    [Signal] public delegate void NwcResponseReceivedEventHandler(string url, string subscriptionId, Dictionary eventDict);
    [Signal] public delegate void WalletInfoReceivedEventHandler(string url, string subscriptionId, Dictionary eventDict);
    [Signal] public delegate void DirectMessageReceivedEventHandler(string url, string subscriptionId, Dictionary eventDict);

    // ============================================================
    // 内部クラス
    // ============================================================

    /// <summary>リレー1接続分の情報を保持する。</summary>
    private class RelayConnection
    {
        public string Url { get; set; }
        public WebSocketPeer Socket { get; set; } = new WebSocketPeer();
        public bool IsConnected { get; set; } = false;
        public Godot.Collections.Array PendingMessages { get; set; } = new Godot.Collections.Array();
    }

    // ============================================================
    // 定数
    // ============================================================

    private const string Bech32Chars = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

    // ============================================================
    // フィールド
    // ============================================================

    // ----- リレー接続 -----
    private System.Collections.Generic.List<RelayConnection> _relays = new System.Collections.Generic.List<RelayConnection>();

    // ----- 鍵ペア -----
    private NBitcoin.Secp256k1.ECPrivKey _privateKey = null;
    private NBitcoin.Secp256k1.ECXOnlyPubKey _publicKey = null;

    // ----- ブラウザ拡張 (NIP-07) 認証 -----
    private HttpListener _localServer;
    private bool _isServerRunning = false;
    private HttpListenerWebSocketContext _wsContext = null;
    private bool _isExtensionLogin = false;
    private string _extensionPubkeyHex = "";
    private TaskCompletionSource<string> _signatureTcs = null;

    // ----- タイムライン (Kind 1 イベントをソート保持) -----
    private readonly SortedSet<Dictionary> _timelinePool = new SortedSet<Dictionary>(
        Comparer<Dictionary>.Create((a, b) =>
        {
            long timeA = a["created_at"].AsInt64();
            long timeB = b["created_at"].AsInt64();

            int compare = timeB.CompareTo(timeA);
            if (compare != 0) return compare;

            return string.Compare(a["id"].AsString(), b["id"].AsString());
        })
    );
    private CancellationTokenSource _debounceCts;

    // ============================================================
    // プロパティ
    // ============================================================

    /// <summary>秘密鍵でのログイン または 拡張機能ログイン 済みか。</summary>
    public bool IsLoggedIn => _privateKey != null || _isExtensionLogin;

    // ============================================================
    // Godot ライフサイクル
    // ============================================================

    public override void _Ready()
    {
        // リレー未接続時は _Process を停止
        SetProcess(false);
    }

    /// <summary>フレーム毎に全リレーの WebSocket をポーリングする。</summary>
    public override void _Process(double delta)
    {
        if (_relays.Count == 0) return;

        for (int i = _relays.Count - 1; i >= 0; i--)
        {
            var relay = _relays[i];
            relay.Socket.Poll();
            WebSocketPeer.State state = relay.Socket.GetReadyState();

            if (state == WebSocketPeer.State.Open)
            {
                if (!relay.IsConnected)
                {
                    relay.IsConnected = true;
                    EmitSignal(SignalName.Connected, relay.Url);
                    GD.Print($"NostrGD: Connected to relay: {relay.Url}");

                    // 接続後に保留中のメッセージを送信
                    foreach (var pendingMsg in relay.PendingMessages)
                    {
                        string pendingJson = Json.Stringify(pendingMsg.AsGodotArray());
                        relay.Socket.SendText(pendingJson);
                        GD.Print($"NostrGD: Sent pending message to {relay.Url}");
                    }
                    relay.PendingMessages.Clear();
                }

                int packetCount = 0;
                while (relay.Socket.GetAvailablePacketCount() > 0 && packetCount < 10)
                {
                    HandleIncomingPacket(relay);
                    packetCount++;
                }
            }
            else if (state == WebSocketPeer.State.Closed || state == WebSocketPeer.State.Connecting)
            {
                if (state == WebSocketPeer.State.Connecting) continue;

                if (relay.IsConnected)
                {
                    relay.IsConnected = false;
                    EmitSignal(SignalName.Disconnected, relay.Url);
                    GD.Print($"NostrGD: Disconnected from relay: {relay.Url}");
                }
            }
        }
    }

    // ============================================================
    // Public API - リレー接続管理
    // ============================================================

    /// <summary>指定URLのリレーへの接続を開始する。</summary>
    public void ConnectToRelay(string url)
    {
        if (_relays.Exists(r => r.Url == url)) return;

        var relay = new RelayConnection { Url = url };
        Error err = relay.Socket.ConnectToUrl(url);

        if (err == Error.Ok)
        {
            _relays.Add(relay);
            GD.Print($"NostrGD: Connecting to {url}...");
        }
        else
        {
            GD.Print($"NostrGD: Failed to initiate connection. Error: {err}");
        }
    }

    /// <summary>リレー処理（_Process によるポーリング）を開始する。</summary>
    public void ActivateRelayProcessing()
    {
        if (_relays.Count > 0)
        {
            SetProcess(true);
        }
    }

    /// <summary>タイムラインプールと debounce をリセットする。</summary>
    public void ClearTimeline()
    {
        lock (_timelinePool)
        {
            _timelinePool.Clear();
        }
        if (_debounceCts != null)
        {
            _debounceCts.Cancel();
            _debounceCts.Dispose();
            _debounceCts = null;
        }
        GD.Print("NostrGD: Timeline pool cleared.");
    }

    /// <summary>接続中の全リレーURLを Godot.Collections.Array として返す。</summary>
    public Godot.Collections.Array GetConnectedRelayUrls()
    {
        var result = new Godot.Collections.Array();
        foreach (var relay in _relays)
        {
            result.Add(relay.Url);
        }
        return result;
    }

    /// <summary>指定URLのリレーから切断する。全リレーが切断された場合は認証サーバーも停止する。</summary>
    public void DisconnectFromRelay(string url)
    {
        var relay = _relays.Find(r => r.Url == url);
        if (relay != null)
        {
            relay.Socket.Close();
            relay.IsConnected = false;
            EmitSignal(SignalName.Disconnected, relay.Url);
            _relays.Remove(relay);
            GD.Print($"NostrGD: Disconnected and removed {url}");
        }
        if (_relays.Count == 0) 
        {
            StopLocalAuthServer();
            _isExtensionLogin = false;
            SetProcess(false);
        }
    }

    // ============================================================
    // Private - ユーティリティ
    // ============================================================

    /// <summary>接続済み全リレーにメッセージをブロードキャストする。</summary>
    private void BroadcastMessage(Godot.Collections.Array message)
    {
        string jsonStr = Json.Stringify(message);
        foreach (var relay in _relays)
        {
            if (relay.IsConnected) relay.Socket.SendText(jsonStr);
        }
    }

    /// <summary>16進数文字列をバイト配列に変換する。</summary>
    private static byte[] StringToByteArray(string hex)
    {
        if (hex.Length % 2 != 0)
            throw new ArgumentException("Hex string must have an even length.");

        byte[] bytes = new byte[hex.Length / 2];
        for (int i = 0; i < bytes.Length; i++)
        {
            bytes[i] = byte.Parse(hex.Substring(i * 2, 2), NumberStyles.HexNumber);
        }
        return bytes;
    }
}

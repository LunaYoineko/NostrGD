using System;
using System.Linq;
using System.Text;
using Godot;
using Godot.Collections;
using NBitcoin.Secp256k1;

// ============================================================
// NostrGDClient - NWC (Nostr Wallet Connect / NIP-47) モジュール
//
// NWC を利用して Lightning ウォレットと通信する。
//
// 接続文字列形式:
//   nostr+walletconnect://<wallet_pubkey>?relay=<relay_url>&secret=<secret>
//
// フロー:
//   1. ユーザーが接続文字列を設定画面で登録（ConfigFile に保存）
//   2. InitNWC() でパース・暗号化デリゲート設定・リレー接続
//   3. SendNWCCommand() でウォレットに命令 (Kind 23194) を送信
//   4. 応答は NwcResponseReceived シグナルで受信 (Kind 23195)
// ============================================================
public partial class NostrGDClient
{
    // ============================================================
    // プロパティ
    // ============================================================

    /// <summary>NWC が設定済みかどうか。</summary>
    public bool IsNwcConfigured => !string.IsNullOrEmpty(_nwcConnectionString) && _nwcWalletPubkey != null;

    /// <summary>ウォレットの公開鍵。</summary>
    public string NwcWalletPubkey => _nwcWalletPubkey ?? "";

    private string _nwcConnectionString = "";
    private string _nwcWalletPubkey = null;
    private string _nwcRelayUrl = "";
    private ECPrivKey _nwcSecretKey = null;
    private string _nwcSecretPubkey = "";

    // ============================================================
    // デリゲート (暗号化/復号処理)
    // ============================================================

    /// <summary>NWC メッセージ暗号化用デリゲート。</summary>
    public Func<string, string, string> NwcEncryptContent { get; set; } = null;

    /// <summary>NWC メッセージ復号用デリゲート。</summary>
    public Func<string, string, string> NwcDecryptContent { get; set; } = null;

    // ============================================================
    // 内部クラス - NWC 接続情報
    // ============================================================

    /// <summary>NWC 接続文字列からパースした接続情報。</summary>
    public class NwcConnectionInfo
    {
        public string WalletPubkey { get; set; }
        public string RelayUrl { get; set; }
        public string Secret { get; set; }
    }

    // ============================================================
    // Public API - 接続文字列の永続化
    // ============================================================

    /// <summary>NWC 接続文字列を ConfigFile に保存する。</summary>
    public void SaveNwcConnectionString(string connectionString)
    {
        var config = new ConfigFile();
        config.Load(ConfigPath);
        config.SetValue("nwc", "connection_string", connectionString);
        config.Save(ConfigPath);
        _nwcConnectionString = connectionString;
        GD.Print("NostrGD/NWC: Connection string saved.");
    }

    /// <summary>ConfigFile から NWC 接続文字列を読み込む。</summary>
    public string LoadNwcConnectionString()
    {
        var config = new ConfigFile();
        Error err = config.Load(ConfigPath);
        if (err == Error.Ok)
        {
            var val = config.GetValue("nwc", "connection_string", "");
            if (val.AsString() != "")
            {
                _nwcConnectionString = val.AsString();
                return _nwcConnectionString;
            }
        }
        _nwcConnectionString = "";
        return "";
    }

    /// <summary>NWC 接続文字列を削除する。</summary>
    public void ClearNwcConnectionString()
    {
        _nwcConnectionString = "";
        _nwcWalletPubkey = null;
        _nwcRelayUrl = "";
        _nwcSecretKey = null;
        _nwcSecretPubkey = "";
        var config = new ConfigFile();
        config.Load(ConfigPath);
        config.SetValue("nwc", "connection_string", "");
        config.Save(ConfigPath);
        GD.Print("NostrGD/NWC: Connection string cleared.");
    }

    // ============================================================
    // Public API - NWC 初期化
    // ============================================================

    /// <summary>
    /// NWC 接続文字列をパースし、暗号化デリゲートを初期化して
    /// ウォレットリレーに接続する。
    /// </summary>
    public bool InitNWC(string connectionString)
    {
        var info = ParseNWCConnectionString(connectionString);
        if (info == null)
        {
            GD.PrintErr("NostrGD/NWC: Failed to parse connection string.");
            return false;
        }

        // 暗号化デリゲートを設定（事前チェック）
        if (!SetupNwcEncryption(info.Secret))
        {
            GD.PrintErr("NostrGD/NWC: Encryption setup failed.");
            return false;
        }

        _nwcWalletPubkey = info.WalletPubkey;
        _nwcRelayUrl = info.RelayUrl;
        _nwcConnectionString = connectionString;

        // ウォレットリレーに接続
        ConnectToRelay(info.RelayUrl);
        ActivateRelayProcessing();

        // ウォレットからの応答 (Kind 23195) を購読（保留 → 接続後に送信）
        // p タグには secret の公開鍵が入る（coinos 確認済み）
        var subFilter = new Dictionary
        {
            { "kinds", new Godot.Collections.Array { 23195 } },
            { "authors", new Godot.Collections.Array { info.WalletPubkey } },
            { "#p", new Godot.Collections.Array { _nwcSecretPubkey } }
        };
        var subMsg = new Godot.Collections.Array { "REQ", "nwc_resp", subFilter };
        foreach (var relay in _relays)
        {
            if (relay.Url == info.RelayUrl)
            {
                if (relay.IsConnected)
                {
                    relay.Socket.SendText(Json.Stringify(subMsg));
                    GD.Print($"NostrGD/NWC: Subscribed to kind 23195 from {info.WalletPubkey} on {info.RelayUrl}");
                }
                else
                {
                    relay.PendingMessages.Add(subMsg);
                    GD.Print($"NostrGD/NWC: Queued subscription to kind 23195 for {info.RelayUrl} (pending connect)");
                }
            }
        }

        GD.Print($"NostrGD/NWC: Initialized. Wallet pubkey: {info.WalletPubkey}, Relay: {info.RelayUrl}");
        return true;
    }

    /// <summary>
    /// 現在のログイン状態で NWC を再初期化する。
    /// 保存済みの接続文字列があれば自動的に設定する。
    /// </summary>
    public bool TryInitNWC()
    {
        string connStr = LoadNwcConnectionString();
        if (string.IsNullOrEmpty(connStr))
            return false;
        return InitNWC(connStr);
    }

    // ============================================================
    // Private - 暗号化設定
    // ============================================================

    private bool SetupNwcEncryption(string secret)
    {
        // NIP-47 + NWC Relay: コンテンツは NIP-04 (ECDH + AES-256-CBC) で暗号化
        // secret をクライアント秘密鍵、ウォレット公開鍵で ECDH して共有鍵を導出
        if (string.IsNullOrEmpty(secret))
        {
            GD.PrintErr("NostrGD/NWC: No secret in connection string.");
            return false;
        }

        // secret を hex デコードして ECPrivKey として扱う
        byte[] secretBytes;
        try
        {
            secretBytes = Convert.FromHexString(secret);
        }
        catch
        {
            GD.PrintErr("NostrGD/NWC: Secret is not valid hex.");
            return false;
        }

        var secretPrivKey = ECPrivKey.Create(secretBytes);
        _nwcSecretKey = secretPrivKey;
        var nwcPubKey = secretPrivKey.CreateXOnlyPubKey();
        _nwcSecretPubkey = Convert.ToHexString(nwcPubKey.ToBytes()).ToLower();
        GD.Print($"NostrGD/NWC: Secret decoded to {secretBytes.Length} bytes for ECDH. Derived pubkey: {_nwcSecretPubkey}");

        NwcEncryptContent = (plaintext, walletPubkey) =>
        {
            byte[] sharedKey = DeriveNwcSharedKey(secretPrivKey, walletPubkey);
            byte[] plainBytes = Encoding.UTF8.GetBytes(plaintext);
            var encrypted = Nostr.Client.Utils.NostrEncryption.EncryptBase64(plainBytes, sharedKey);
            return encrypted.Text + "?iv=" + encrypted.Iv;
        };

        NwcDecryptContent = (ciphertext, senderPubkey) =>
        {
            byte[] sharedKey = DeriveNwcSharedKey(secretPrivKey, senderPubkey);
            string text = ciphertext;
            string iv = "";
            int ivIdx = ciphertext.LastIndexOf("?iv=", StringComparison.Ordinal);
            if (ivIdx >= 0)
            {
                text = ciphertext.Substring(0, ivIdx);
                iv = ciphertext.Substring(ivIdx + 4);
            }
            var enc = new Nostr.Client.Utils.EncryptedBase64Data(text, iv);
            byte[] decrypted = Nostr.Client.Utils.NostrEncryption.DecryptBase64(enc, sharedKey);
            return Encoding.UTF8.GetString(decrypted);
        };

        GD.Print("NostrGD/NWC: NIP-04 (ECDH) encryption configured.");
        return true;
    }

    private static byte[] DeriveNwcSharedKey(ECPrivKey secretPrivKey, string hexPublicKey)
    {
        // NIP-04: ECDH(secret, walletPubkey) → 共有点の X 座標（32 bytes）をそのまま AES-256 鍵として使用。
        // SHA256 は行わない（libsecp256k1 のデフォルト動作を上書きして X 座標のみを使う）。
        byte[] pubBytes = Convert.FromHexString(hexPublicKey);
        ECPubKey pubKey;
        if (pubBytes.Length == 32)
        {
            byte[] compressed = new byte[33];
            Buffer.BlockCopy(pubBytes, 0, compressed, 1, 32);
            compressed[0] = 0x02;
            if (!ECPubKey.TryCreate(compressed, null, out _, out pubKey))
            {
                compressed[0] = 0x03;
                ECPubKey.TryCreate(compressed, null, out _, out pubKey);
            }
        }
        else
        {
            pubKey = ECPubKey.Create(pubBytes);
        }

        var sharedPubKey = pubKey.GetSharedPubkey(secretPrivKey);
        return sharedPubKey.ToXOnlyPubKey().ToBytes();
    }

    // ============================================================
    // Public API - NWC 接続文字列のパース
    // ============================================================

    /// <summary>
    /// NWC 接続文字列 (nostr+walletconnect://...) をパースする。
    /// 成功時は NwcConnectionInfo、失敗時は null を返す。
    /// </summary>
    public NwcConnectionInfo ParseNWCConnectionString(string connectionString)
    {
        try
        {
            var uri = new Uri(connectionString.Replace("nostr+walletconnect://", "https://"));
            string walletPubkey = uri.Host;
            string relayUrl = GetQueryParam(uri.Query, "relay");
            string secret = GetQueryParam(uri.Query, "secret");

            if (string.IsNullOrEmpty(walletPubkey) || string.IsNullOrEmpty(relayUrl))
            {
                GD.PrintErr("NostrGD/NWC: Invalid connection string - missing pubkey or relay.");
                return null;
            }

            return new NwcConnectionInfo
            {
                WalletPubkey = walletPubkey,
                RelayUrl = relayUrl,
                Secret = secret ?? ""
            };
        }
        catch (Exception ex)
        {
            GD.PrintErr($"NostrGD/NWC: Failed to parse connection string: {ex.Message}");
            return null;
        }
    }

    // ============================================================
    // Public API - NWC コマンド送信 (Kind 23194)
    // ============================================================

    /// <summary>
    /// NWC ウォレットにコマンドを送信する (Kind 23194)。
    /// NwcEncryptContent デリゲートが設定されている必要がある。
    /// NWC リレーが未接続の場合は保留キューに追加し、接続後に送信する。
    /// 成功時 true、失敗時 false を返す。
    /// </summary>
    public bool SendNWCCommand(string method, Dictionary parameters, string walletPubkey)
    {
        if (!IsLoggedIn)
        {
            GD.PrintErr("NostrGD/NWC: Not logged in.");
            return false;
        }

        if (NwcEncryptContent == null)
        {
            GD.PrintErr("NostrGD/NWC: NwcEncryptContent delegate is not set.");
            return false;
        }

        if (string.IsNullOrEmpty(_nwcRelayUrl))
        {
            GD.PrintErr("NostrGD/NWC: No NWC relay URL configured.");
            return false;
        }

        GD.Print($"NostrGD/NWC: Preparing command '{method}' for wallet {walletPubkey} via {_nwcRelayUrl}");

        // JSON-RPC ペイロード
        var payload = new Dictionary
        {
            { "method", method },
            { "params", parameters }
        };
        string jsonPayload = Json.Stringify(payload);
        GD.Print($"NostrGD/NWC: Payload: {jsonPayload}");

        // 暗号化
        string encrypted;
        try
        {
            encrypted = NwcEncryptContent(jsonPayload, walletPubkey);
            GD.Print($"NostrGD/NWC: Encrypted content length: {encrypted.Length}");
        }
        catch (Exception ex)
        {
            GD.PrintErr($"NostrGD/NWC: Encryption failed: {ex.Message}");
            return false;
        }

        // Kind 23194 イベントを作成（NWC secret 鍵で署名・pubkey 設定）
        var tags = new Godot.Collections.Array
        {
            new Godot.Collections.Array { "p", walletPubkey }
        };

        var eventDict = new Dictionary
        {
            { "pubkey", _nwcSecretPubkey },
            { "created_at", Mathf.FloorToInt(Time.GetUnixTimeFromSystem()) },
            { "kind", 23194 },
            { "tags", tags },
            { "content", encrypted }
        };

        string eventId = CalculateEventId(eventDict);
        eventDict.Add("id", eventId);
        eventDict.Add("sig", CreateSchnorrSignature(eventId, _nwcSecretKey));

        var message = new Godot.Collections.Array { "EVENT", eventDict };

        // NWC リレーのみに送信（未接続なら保留）
        foreach (var relay in _relays)
        {
            if (relay.Url == _nwcRelayUrl)
            {
                if (relay.IsConnected)
                {
                    string jsonMsg = Json.Stringify(message);
                    relay.Socket.SendText(jsonMsg);
                    GD.Print($"NostrGD/NWC: Sent command '{method}' (Kind 23194) to {_nwcRelayUrl}. ID: {eventId}");
                    GD.Print($"NostrGD/NWC: Message: {jsonMsg.Left(200)}...");
                }
                else
                {
                    relay.PendingMessages.Add(message);
                    GD.Print($"NostrGD/NWC: Queued command '{method}' for {_nwcRelayUrl} (pending connect). ID: {eventId}");
                }
                return true;
            }
        }

        GD.PrintErr($"NostrGD/NWC: NWC relay {_nwcRelayUrl} not found in relay list. Connected relays: {string.Join(", ", _relays.Select(r => r.Url))}");
        return false;
    }

    /// <summary>
    /// ウォレットの残高を取得する (get_balance)。
    /// 結果は NwcResponseReceived シグナルで受信する。
    /// </summary>
    public void NWCGetBalance(string walletPubkey)
    {
        SendNWCCommand("get_balance", new Dictionary(), walletPubkey);
    }

    /// <summary>
    /// インボイスを支払う (pay_invoice)。
    /// 結果は NwcResponseReceived シグナルで受信する。
    /// 成功時 true、失敗時 false を返す。
    /// </summary>
    public bool NWCPayInvoice(string invoice, string walletPubkey)
    {
        var parameters = new Dictionary { { "invoice", invoice } };
        return SendNWCCommand("pay_invoice", parameters, walletPubkey);
    }

    /// <summary>
    /// インボイスを作成する (make_invoice)。
    /// 結果は NwcResponseReceived シグナルで受信する。
    /// </summary>
    public void NWCMakeInvoice(long amountMsat, string description, string walletPubkey)
    {
        var parameters = new Dictionary
        {
            { "amount", amountMsat },
            { "description", description }
        };
        SendNWCCommand("make_invoice", parameters, walletPubkey);
    }

    /// <summary>
    /// ウォレット情報を取得する (get_info)。
    /// 結果は WalletInfoReceived シグナルで受信する。
    /// </summary>
    public void NWCGetInfo(string walletPubkey)
    {
        SendNWCCommand("get_info", new Dictionary(), walletPubkey);
    }

    /// <summary>
    /// インボイス情報を照会する (lookup_invoice)。
    /// 結果は NwcResponseReceived シグナルで受信する。
    /// </summary>
    public void NWCLookupInvoice(string paymentHash, string walletPubkey)
    {
        var parameters = new Dictionary { { "payment_hash", paymentHash } };
        SendNWCCommand("lookup_invoice", parameters, walletPubkey);
    }

    // ============================================================
    // Private - ユーティリティ
    // ============================================================

    private static string GetQueryParam(string queryString, string key)
    {
        if (string.IsNullOrEmpty(queryString)) return null;
        string q = queryString.TrimStart('?');
        foreach (var pair in q.Split('&'))
        {
            var parts = pair.Split('=');
            if (parts.Length == 2 && parts[0] == key)
            {
                return Uri.UnescapeDataString(parts[1]);
            }
        }
        return null;
    }
}

using System;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Godot;

// ============================================================
// NostrGDClient - ブラウザ拡張 (NIP-07) 認証モジュール
//
// ローカル HTTP サーバー (localhost:8123) を起動し、
// ブラウザ上の Nostr 拡張機能 (Alby / nos2x 等) と連携する。
//
// フロー:
//   1. StartLocalAuthServer() でサーバー起動 + ブラウザ自動オープン
//   2. ブラウザ側の JavaScript が window.nostr.getPublicKey() を呼び、
//      公開鍵を GET /receive 経由で Godot に送信
//   3. 以後、署名が必要なイベントは WebSocket (/ws) 経由で
//      ブラウザに署名要求を送り、結果を受け取る
// ============================================================
public partial class NostrGDClient
{
    // ============================================================
    // Public API - ブラウザ拡張 (NIP-07) 認証
    // ============================================================

    /// <summary>
    /// ローカル HTTP サーバーを起動し、ブラウザ経由で
    /// NIP-07 拡張機能の認証とリモート署名を受け付ける。
    /// </summary>
    public void StartLocalAuthServer()
    {
        if (_isServerRunning) return;

        _localServer = new HttpListener();
        _localServer.Prefixes.Add("http://localhost:8123/");
        _localServer.Start();
        _isServerRunning = true;

        GD.Print("NostrGD: Local auth server started at http://localhost:8123/");

        Task.Run(() => ListenForBrowserAuth());

        OS.ShellOpen("http://localhost:8123/");
    }

    /// <summary>ローカル HTTP サーバーを停止する。</summary>
    public void StopLocalAuthServer()
    {
        if (!_isServerRunning) return;
        _isServerRunning = false;
        _localServer?.Stop();
        _localServer?.Close();
        GD.Print("NostrGD: Local auth server stopped.");
    }

    // ============================================================
    // Private - 認証サーバー処理
    // ============================================================

    /// <summary>
    /// HttpListener でブラウザからのリクエストを待ち受ける非同期ループ。
    /// - GET  /  → 認証用 HTML ページを返す
    /// - GET  /receive?pubkey=... → 拡張機能から公開鍵を受信
    /// - WS   /ws → 署名要求/応答のための WebSocket 接続
    /// </summary>
    private async Task ListenForBrowserAuth()
    {
        while (_isServerRunning)
        {
            try
            {
                HttpListenerContext context = await _localServer.GetContextAsync();
                HttpListenerRequest request = context.Request;
                HttpListenerResponse response = context.Response;

                if (request.HttpMethod == "OPTIONS")
                {
                    response.AddHeader("Access-Control-Allow-Origin", "*");
                    response.AddHeader("Access-Control-Allow-Methods", "POST, GET, OPTIONS");
                    response.AddHeader("Access-Control-Allow-Headers", "Content-Type");
                    response.StatusCode = (int)HttpStatusCode.OK;
                    response.OutputStream.Close();
                    continue;
                }

                if (request.IsWebSocketRequest && request.Url.AbsolutePath == "/ws")
                {
                    _wsContext = await context.AcceptWebSocketAsync(subProtocol: null);
                    GD.Print("NostrGD: Browser WebSocket connected securely for remote signing!");

                    _ = Task.Run(() => ListenToBrowserWebSocket());
                    continue;
                }

                if (request.Url.AbsolutePath == "/")
                {
                    string html = GetAuthPageHtml();
                    byte[] buffer = System.Text.Encoding.UTF8.GetBytes(html);
                    response.ContentType = "text/html; charset=utf-8";
                    response.ContentLength64 = buffer.Length;
                    await response.OutputStream.WriteAsync(buffer, 0, buffer.Length);
                    response.OutputStream.Close();
                }
                else if (request.Url.AbsolutePath == "/receive")
                {
                    string pubkey = request.QueryString["pubkey"];

                    if (!string.IsNullOrEmpty(pubkey))
                    {
                        Callable.From(() =>
                        {
                            _extensionPubkeyHex = pubkey.ToLower();
                            _isExtensionLogin = true;
                            GD.Print($"NostrGD: Public key imported successfully via GET: {_extensionPubkeyHex}");
                            OnLocalAuthSuccess(pubkey);
                        }).CallDeferred();
                    }

                    response.AddHeader("Access-Control-Allow-Origin", "*");
                    byte[] buffer = System.Text.Encoding.UTF8.GetBytes("OK");
                    response.StatusCode = (int)HttpStatusCode.OK;
                    response.ContentLength64 = buffer.Length;
                    await response.OutputStream.WriteAsync(buffer, 0, buffer.Length);
                    response.OutputStream.Close();
                }
            }
            catch (Exception)
            {
                // メインスレッドではないため catch で握りつぶす
            }
        }
    }

    /// <summary>
    /// ブラウザ側の WebSocket から署名応答 (SIGN_RESPONSE) を
    /// 待ち受ける非同期ループ。
    /// </summary>
    private async Task ListenToBrowserWebSocket()
    {
        var buffer = new byte[1024 * 4];
        while (_wsContext != null && _wsContext.WebSocket.State == WebSocketState.Open)
        {
            try
            {
                var result = await _wsContext.WebSocket.ReceiveAsync(new ArraySegment<byte>(buffer), CancellationToken.None);
                if (result.MessageType == WebSocketMessageType.Text)
                {
                    string msg = System.Text.Encoding.UTF8.GetString(buffer, 0, result.Count);
                    using (JsonDocument doc = JsonDocument.Parse(msg))
                    {
                        string type = doc.RootElement.GetProperty("type").GetString();
                        if (type == "SIGN_RESPONSE")
                        {
                            string sig = doc.RootElement.GetProperty("sig").GetString();
                            _signatureTcs?.TrySetResult(sig);
                        }
                    }
                }
                else if (result.MessageType == WebSocketMessageType.Close)
                {
                    await _wsContext.WebSocket.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None);
                    _wsContext = null;
                    GD.Print("NostrGD: Browser signing line closed.");
                }
            }
            catch (Exception) { _wsContext = null; }
        }
    }

    // ============================================================
    // Private - 認証用 HTML ページ生成
    // ============================================================

    /// <summary>
    /// ブラウザに表示する NIP-07 連携ページの HTML。
    /// window.nostr.getPublicKey() で公開鍵を取得し、
    /// /receive 経由で Godot に送信した後、WebSocket で署名待機する。
    /// </summary>
    private string GetAuthPageHtml()
    {
        return @"
        <!DOCTYPE html>
        <html>
        <head><title>NostrGD Connect</title></head>
        <body style='font-family:sans-serif; text-align:center; padding-top:50px; background:#f0f2f5;'>
            <div style='max-width:500px; margin:0 auto; background:white; padding:30px; border-radius:10px; box-shadow:0 4px 6px rgba(0,0,0,0.1);'>
                <h2>NostrGD連携 (NIP-07)</h2>
                <p id='status'>Nostr拡張機能（Alby等）の承認を待っています...</p>
                <div id='log-box' style='text-align:left; background:#333; color:#fff; padding:10px; border-radius:5px; font-family:monospace; font-size:12px; margin-top:20px; max-height:150px; overflow-y:auto; display:none;'></div>
            </div>
            <script>
                let ws;
                const logBox = document.getElementById('log-box');
                
                function logToScreen(msg) {
                    logBox.style.display = 'block';
                    logBox.innerHTML += '<div>> ' + msg + '</div>';
                    logBox.scrollTop = logBox.scrollHeight;
                    console.log('[GodotAuth]', msg);
                }

                window.addEventListener('load', async () => {
                    if (!window.nostr) {
                        document.getElementById('status').innerText = 'AlbyなどのNostr拡張機能が見つかりません。';
                        return;
                    }
                    try {
                        // 1. 公開鍵を取得
                        const pubkey = await window.nostr.getPublicKey();
                        logToScreen('公開鍵を取得完了: ' + pubkey.substring(0, 8) + '...');
                        
                        // 2. 公開鍵をGETで送信
                        const response = await fetch('/receive?pubkey=' + encodeURIComponent(pubkey), {
                            method: 'GET',
                            mode: 'cors'
                        });

                        if (!response.ok) throw new Error('サーバーへのデータ同期に失敗しました。');
                        logToScreen('NostrGDへの登録成功。');

                        document.getElementById('status').innerText = 'NostrGDと連動中... このタブを開いたまま元のアプリに戻ってください！';

                        // 3. WebSocket接続を開始
                        ws = new WebSocket('ws://localhost:8123/ws');
                        
                        ws.onopen = () => {
                            logToScreen('WebSocketラインが確立しました。署名待機中...');
                        };

                        ws.onmessage = async (event) => {
                            logToScreen('NostrGDから署名要求を受信しました。');
                            try {
                                const data = JSON.parse(event.data);
                                
                                if (data.type === 'SIGN_REQUEST') {
                                    const rawEvent = data.event;
                                    
                                    // Albyが100%受け付ける形式へ完璧に型キャストする
                                    const eventToSign = {
                                        id: String(rawEvent.id),
                                        pubkey: String(rawEvent.pubkey),
                                        created_at: Number(rawEvent.created_at),
                                        kind: Number(rawEvent.kind),
                                        tags: Array.isArray(rawEvent.tags) ? rawEvent.tags : [],
                                        content: String(rawEvent.content)
                                    };

                                    logToScreen('拡張機能（Alby/nos2x）を呼び出します...');
                                    
                                    const signedEvent = await window.nostr.signEvent(eventToSign);
                                    logToScreen('署名が完了しました！');

                                    ws.send(JSON.stringify({
                                        type: 'SIGN_RESPONSE',
                                        sig: signedEvent.sig
                                    }));
                                    logToScreen('署名をNostrGDに送り返しました。');
                                }
                            } catch(err) {
                                logToScreen('エラー発生: ' + err.message);
                            }
                        };

                        ws.onclose = () => {
                            logToScreen('NostrGDとの接続が閉じられました。');
                        };

                    } catch (e) {
                        document.getElementById('status').innerText = 'エラーが発生しました: ' + e.message;
                        logToScreen('初期化失敗: ' + e.message);
                    }
                });
            </script>
        </body>
        </html>";
    }

    // ============================================================
    // Private - 認証成功時のコールバック
    // ============================================================

    /// <summary>ブラウザから公開鍵を受け取った後の内部処理。</summary>
    private void OnLocalAuthSuccess(string pubkeyHex)
    {
        LoginWithExtension(pubkeyHex);
        EmitSignal(SignalName.ExtensionAuthCompleted);
    }
}

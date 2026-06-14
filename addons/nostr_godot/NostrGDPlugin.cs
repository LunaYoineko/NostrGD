#if TOOLS
using Godot;

// ============================================================
// NostrGDPlugin
// Godot エディタプラグイン。プロジェクト設定で有効化すると
// NostrGDClient を自動ロードシングルトンとして登録する。
// ============================================================
[Tool]
public partial class NostrGDPlugin : EditorPlugin
{
    private const string AutoloadName = "NostrGD";
    private const string ClientScriptPath = "res://addons/nostr_godot/NostrGDClient.cs";

    public override void _EnterTree()
    {
        AddAutoloadSingleton(AutoloadName, ClientScriptPath);
        GD.Print($"NostrGD: Autoload '{AutoloadName}' has been registered.");
    }

    public override void _ExitTree()
    {
        RemoveAutoloadSingleton(AutoloadName);
        GD.Print($"NostrGD: Autoload '{AutoloadName}' has been removed.");
    }
}
#endif
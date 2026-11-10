// Diagnostic : valide l'accès en LECTURE SEULE à l'installation GTA V.
using CodeWalker.GameFiles;

internal static class Probe
{
    public static int Run(string[] args)
    {
        var folder = args[0];
        bool gen9 = args.Contains("--gen9");
        Console.Error.WriteLine($"Dossier : {folder}  gen9={gen9}");

        GTA5Keys.LoadFromPath(folder, gen9, null);
        Console.Error.WriteLine("Clés chargées OK.");

        var rpfman = new RpfManager();
        var errors = new List<string>();
        rpfman.Init(folder, gen9, s => { }, e => errors.Add(e));
        Console.Error.WriteLine($"RPF init OK : {rpfman.AllRpfs?.Count} archives, {rpfman.EntryDict?.Count} entrées, {errors.Count} erreurs.");
        foreach (var e in errors.Take(10)) Console.Error.WriteLine("  err: " + e);

        var byExt = new Dictionary<string, int>();
        var vehshare = new List<string>();
        var rels = new List<string>();
        var awcs = new List<string>();
        foreach (var kv in rpfman.EntryDict)
        {
            if (kv.Value is not RpfFileEntry fe) continue;
            var ext = Path.GetExtension(fe.Name).ToLowerInvariant();
            byExt.TryGetValue(ext, out int c); byExt[ext] = c + 1;
            var p = (fe.Path ?? fe.Name).ToLowerInvariant();
            if (p.Contains("vehshare")) vehshare.Add(p);
            if (ext == ".rel") rels.Add(p);
            if (ext == ".awc" && awcs.Count < 40) awcs.Add(p);
        }
        Console.Error.WriteLine("\n== Extensions (top 25) ==");
        foreach (var kv in byExt.OrderByDescending(k => k.Value).Take(25)) Console.Error.WriteLine($"  {kv.Key,-8} {kv.Value}");
        Console.Error.WriteLine("\n== vehshare ==");
        foreach (var p in vehshare.Take(30)) Console.Error.WriteLine("  " + p);
        Console.Error.WriteLine($"\n== .rel ({rels.Count}) ==");
        foreach (var p in rels.Where(r => r.Contains("game.dat") || r.Contains("sounds.dat") || r.Contains("151") || r.Contains("54")).Take(30)) Console.Error.WriteLine("  " + p);
        Console.Error.WriteLine("\n== .awc (echantillon) ==");
        foreach (var p in awcs) Console.Error.WriteLine("  " + p);
        return 0;
    }
}

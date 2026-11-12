// gta-extract — convertisseur headless des ressources GTA V (FiveM) vers le format XML CodeWalker.
//
// Usage :
//   gta-extract export <fichier|dossier> [...] -o <dossier_sortie> [-g <dossier GTA V>] [--legacy]
//       Convertit récursivement .yft .ydr .ydd .ytd .awc .rel en <nom>.<ext>.xml
//       + un sous-dossier <nom>/ contenant les textures .dds (ou les sons .wav).
//       -g : dossier de l'installation GTA V, nécessaire pour les .awc, qui sont
//            chiffrés avec une clé extraite de l'exécutable du jeu. À défaut de -g,
//            la variable GTAV_FOLDER puis ~/.fivem2roblox/gta-server.json sont lues.
//            L'édition est devinée (Enhanced/gen9 si GTA5_Enhanced.exe existe) ; --legacy force l'ancienne.
//   gta-extract xml2bin <fichier.yft.xml|.ydr.xml|.ytd.xml> -o <fichier_binaire>
//       Opération inverse (utile pour les tests).
//
// Sortie standard : un résumé JSON (une ligne par fichier) pour le pipeline Python.

using System.Text;
using System.Xml;
using CodeWalker.GameFiles;

internal static class Program
{
    static readonly string[] Extensions = { ".yft", ".ydr", ".ydd", ".ytd", ".awc", ".rel" };

    static int Main(string[] args)
    {
        if (args.Length < 1) return Usage();
        LoadStrings();
        try
        {
            switch (args[0].ToLowerInvariant())
            {
                case "export": return Export(args.Skip(1).ToArray());
                case "xml2bin": return Xml2Bin(args.Skip(1).ToArray());
                case "probe": return Probe.Run(args.Skip(1).ToArray());
                case "game-serve": return GameLib.Serve(args.Skip(1).ToArray());
                default: return Usage();
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("ERREUR: " + ex);
            return 2;
        }
    }

    static int Usage()
    {
        Console.Error.WriteLine("Usage: gta-extract export <fichier|dossier>... -o <sortie> [-g <dossier GTA V>] [--legacy]");
        Console.Error.WriteLine("       gta-extract xml2bin <fichier.xml> -o <fichier_binaire>");
        return 1;
    }

    // ------------------------------------------------------------------ clés du jeu
    //
    // Les .awc de GTA V sont chiffrés en entier (XXTEA) avec une clé qui ne vit que dans
    // l'exécutable du jeu : sans elle CodeWalker ne lit même pas l'en-tête. Les packs de
    // sons moddés étant des copies de ces conteneurs, ils sont chiffrés pareil. Les autres
    // formats (.yft, .ytd…) n'en ont pas besoin : la clé n'est chargée que si on la trouve.
    static bool keysLoaded;

    /// Dossier GTA V à utiliser : -g, sinon GTAV_FOLDER, sinon la config écrite par
    /// tools/gta-asset-server (gta_locate.py). Renvoie null si rien n'est connu.
    static string ResolveGtaFolder(string explicitFolder)
    {
        if (!string.IsNullOrWhiteSpace(explicitFolder)) return explicitFolder;
        var env = Environment.GetEnvironmentVariable("GTAV_FOLDER");
        if (!string.IsNullOrWhiteSpace(env)) return env;
        var cfg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                               ".fivem2roblox", "gta-server.json");
        if (!File.Exists(cfg)) return null;
        try
        {
            var node = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(cfg));
            var f = node?["game_folder"]?.GetValue<string>();
            return string.IsNullOrWhiteSpace(f) ? null : f;
        }
        catch { return null; }
    }

    static void LoadGameKeys(string folder, bool legacy)
    {
        if (keysLoaded || string.IsNullOrWhiteSpace(folder)) return;
        if (!Directory.Exists(folder)) throw new Exception("dossier GTA V introuvable : " + folder);
        var gen9 = !legacy && File.Exists(Path.Combine(folder, "GTA5_Enhanced.exe"));
        GTA5Keys.LoadFromPath(folder, gen9, null);
        keysLoaded = true;
        Console.Error.WriteLine($"gta-extract: clés lues dans {folder} ({(gen9 ? "Enhanced/gen9" : "Legacy")}).");
    }

    /// Un .awc en clair commence par « ADAT » (dans un sens ou dans l'autre). Tout le reste
    /// est chiffré : on le dit avant que CodeWalker ne parte en NullReferenceException.
    static void CheckAwcReadable(string file, byte[] data)
    {
        if (Path.GetExtension(file).ToLowerInvariant() != ".awc") return;
        if (data.Length >= 4)
        {
            var magic = BitConverter.ToUInt32(data, 0);
            if (magic == 0x54414441 || magic == 0x41444154) return;
        }
        if (GTA5Keys.PC_AWC_KEY != null) return;
        throw new Exception("AWC chiffré et clé absente : relancez avec -g <dossier GTA V> "
                          + "(ou définissez GTAV_FOLDER) pour l'extraire de l'exécutable du jeu");
    }

    // Les noms de shaders / paramètres sont stockés sous forme de hash Jenkins dans les
    // ressources binaires : on alimente l'index avec les chaînes connues pour que le XML
    // contienne "vehicle_paint1" plutôt que "hash_C3071C42".
    static readonly List<string> knownStrings = new();

    static void LoadStrings()
    {
        var dir = AppContext.BaseDirectory;
        foreach (var file in new[] { "strings.txt", "extra_strings.txt" })
        {
            var path = Path.Combine(dir, file);
            if (!File.Exists(path)) continue;
            foreach (var raw in File.ReadAllLines(path))
            {
                var s = raw.Trim();
                if (s.Length == 0 || s.StartsWith("//")) continue;
                JenkIndex.Ensure(s);
                JenkIndex.Ensure(s.ToLowerInvariant());
                if (!s.EndsWith(".sps")) JenkIndex.Ensure(s.ToLowerInvariant() + ".sps");
                knownStrings.Add(s.ToLowerInvariant());
            }
        }
        for (int i = 0; i < 100; i++) JenkIndex.Ensure(i.ToString("00"));
    }

    /// Les flux d'un AWC sont désignés par un hash Jenkins, et le nom en clair n'est stocké
    /// nulle part : il sort donc en « 0x1CEB5095 ». Une partie des conteneurs nomme ses flux
    /// « <nom du conteneur>_<rôle> » (par exemple « 4_cylinder_saloon_1_start »), alors on
    /// sème l'index avec cette combinaison avant de lire le fichier. Ce qui ne tombe pas
    /// juste reste un hash : l'en-tête XML donne la fréquence, la durée et les points de
    /// boucle, ce qui suffit à reconnaître un son à l'oreille.
    static void SeedAwcStreamNames(string awcPath)
    {
        var baseName = Path.GetFileNameWithoutExtension(awcPath).ToLowerInvariant();
        if (baseName.Length == 0) return;
        JenkIndex.Ensure(baseName);
        foreach (var s in knownStrings) JenkIndex.Ensure(baseName + "_" + s);
    }

    static (List<string> inputs, string output, string gta, bool legacy) ParseArgs(string[] args)
    {
        var inputs = new List<string>();
        string output = null, gta = null;
        var legacy = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "-o" && i + 1 < args.Length) { output = args[++i]; continue; }
            if (args[i] == "-g" && i + 1 < args.Length) { gta = args[++i]; continue; }
            if (args[i] == "--legacy") { legacy = true; continue; }
            if (args[i] == "--gen9") { legacy = false; continue; }
            inputs.Add(args[i]);
        }
        if (inputs.Count == 0 || output == null) throw new ArgumentException("arguments manquants (entrée et -o <sortie>)");
        return (inputs, output, gta, legacy);
    }

    static int Export(string[] args)
    {
        var (inputs, output, gta, legacy) = ParseArgs(args);
        Directory.CreateDirectory(output);
        LoadGameKeys(ResolveGtaFolder(gta), legacy);
        int ok = 0, failed = 0;
        foreach (var input in inputs)
        {
            var baseDir = Directory.Exists(input) ? Path.GetFullPath(input) : Path.GetDirectoryName(Path.GetFullPath(input));
            IEnumerable<string> files = Directory.Exists(input)
                ? Directory.EnumerateFiles(input, "*", SearchOption.AllDirectories)
                : new[] { input };
            foreach (var file in files)
            {
                var ext = Path.GetExtension(file).ToLowerInvariant();
                var rel = Path.GetRelativePath(baseDir, Path.GetFullPath(file));
                var outDir = Path.Combine(output, Path.GetDirectoryName(rel) ?? "");
                if (ext == ".rpf")
                {
                    // Addons solo (dlc.rpf) : on parcourt l'archive et ses RPF imbriqués.
                    var rpfOut = Path.Combine(outDir, Path.GetFileName(file) + "_extrait");
                    ExportRpf(file, rpfOut, ref ok, ref failed);
                    continue;
                }
                if (!Extensions.Contains(ext)) continue;
                Directory.CreateDirectory(outDir);
                try
                {
                    var data = File.ReadAllBytes(file);
                    CheckAwcReadable(file, data);
                    if (ext == ".awc") SeedAwcStreamNames(file);
                    var name = Path.GetFileName(file);
                    var entry = CreateFileEntry(name, file, ref data);
                    var xml = MetaXml.GetXml(entry, data, out string xmlName, outDir);
                    if (string.IsNullOrEmpty(xml)) throw new Exception("conversion XML vide (format non supporté ou fichier chiffré)");
                    var xmlPath = Path.Combine(outDir, name + ".xml");
                    File.WriteAllText(xmlPath, xml, new UTF8Encoding(false));
                    var assetDir = Path.Combine(outDir, entry.GetShortName());
                    Console.WriteLine(Json(("status", "ok"), ("input", file), ("xml", xmlPath),
                        ("assets", Directory.Exists(assetDir) ? assetDir : "")));
                    ok++;
                }
                catch (Exception ex)
                {
                    Console.WriteLine(Json(("status", "error"), ("input", file), ("error", ex.Message)));
                    failed++;
                }
            }
        }
        Console.Error.WriteLine($"gta-extract: {ok} fichier(s) converti(s), {failed} échec(s).");
        return failed > 0 && ok == 0 ? 3 : 0;
    }

    static readonly string[] RawCopyExtensions = { ".meta", ".xml", ".dat", ".lua", ".txt", ".ymt", ".gxt2" };

    static void ExportRpf(string path, string outRoot, ref int ok, ref int failed)
    {
        var rpf = new RpfFile(path, Path.GetFileName(path));
        var errors = new List<string>();
        rpf.ScanStructure(_ => { }, err => errors.Add(err));
        if (errors.Count > 0 || rpf.AllEntries == null)
        {
            Console.WriteLine(Json(("status", "error"), ("input", path),
                ("error", "RPF illisible (probablement chiffré NG/AES : ré-exportez-le avec OpenIV en dossier) " + string.Join(" | ", errors))));
            failed++;
            return;
        }
        var stack = new Stack<RpfFile>();
        stack.Push(rpf);
        while (stack.Count > 0)
        {
            var cur = stack.Pop();
            if (cur.Children != null) foreach (var c in cur.Children) stack.Push(c);
            if (cur.AllEntries == null) continue;
            foreach (var entry in cur.AllEntries)
            {
                if (entry is not RpfFileEntry fe) continue;
                var ext = Path.GetExtension(fe.Name).ToLowerInvariant();
                bool resource = Extensions.Contains(ext);
                if (!resource && !RawCopyExtensions.Contains(ext)) continue;
                var relPath = (fe.Path ?? fe.Name).Replace('\\', '/');
                var outDir = Path.Combine(outRoot, Path.GetDirectoryName(relPath) ?? "");
                Directory.CreateDirectory(outDir);
                try
                {
                    var data = fe.File.ExtractFile(fe);
                    if (data == null) throw new Exception(fe.File.LastError ?? "extraction impossible (entrée chiffrée ?)");
                    if (!resource)
                    {
                        File.WriteAllBytes(Path.Combine(outDir, fe.Name), data);
                        continue;
                    }
                    if (ext == ".awc") SeedAwcStreamNames(fe.Name);
                    var xml = MetaXml.GetXml(fe, data, out string _, outDir);
                    if (string.IsNullOrEmpty(xml)) throw new Exception("conversion XML vide");
                    var xmlPath = Path.Combine(outDir, fe.Name + ".xml");
                    File.WriteAllText(xmlPath, xml, new UTF8Encoding(false));
                    Console.WriteLine(Json(("status", "ok"), ("input", path + "!" + relPath), ("xml", xmlPath), ("assets", "")));
                    ok++;
                }
                catch (Exception ex)
                {
                    Console.WriteLine(Json(("status", "error"), ("input", path + "!" + relPath), ("error", ex.Message)));
                    failed++;
                }
            }
        }
    }

    static int Xml2Bin(string[] args)
    {
        var (inputs, output, _, _) = ParseArgs(args);
        var input = inputs[0];
        var xmlText = File.ReadAllText(input);
        var folder = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(input)) ?? "",
            Path.GetFileNameWithoutExtension(Path.GetFileNameWithoutExtension(input)));
        var doc = new XmlDocument();
        doc.LoadXml(xmlText);
        byte[] bin;
        var lower = input.ToLowerInvariant();
        if (lower.EndsWith(".yft.xml")) bin = XmlYft.GetYft(doc, folder).Save();
        else if (lower.EndsWith(".ydr.xml")) bin = XmlYdr.GetYdr(doc, folder).Save();
        else if (lower.EndsWith(".ytd.xml")) bin = XmlYtd.GetYtd(doc, folder).Save();
        else throw new ArgumentException("type non supporté pour xml2bin : " + input);
        File.WriteAllBytes(output, bin);
        Console.Error.WriteLine($"écrit {output} ({bin.Length} octets)");
        return 0;
    }

    // Équivalent de ExploreForm.CreateFileEntry (projet WinForms CodeWalker) : construit une
    // entrée RPF à partir d'un fichier disque et décompresse les ressources RSC7.
    static RpfFileEntry CreateFileEntry(string name, string path, ref byte[] data)
    {
        RpfFileEntry e;
        uint magic = data.Length > 4 ? BitConverter.ToUInt32(data, 0) : 0;
        if (magic == 0x37435352) // "RSC7"
        {
            e = RpfFile.CreateResourceFileEntry(ref data, 0);
            data = ResourceBuilder.Decompress(data);
        }
        else
        {
            var be = new RpfBinaryFileEntry();
            be.FileSize = (uint)data.Length;
            be.FileUncompressedSize = be.FileSize;
            e = be;
        }
        e.Name = name;
        e.NameLower = name.ToLowerInvariant();
        e.NameHash = JenkHash.GenHash(e.NameLower);
        e.ShortNameHash = JenkHash.GenHash(Path.GetFileNameWithoutExtension(e.NameLower));
        e.Path = path;
        return e;
    }

    static string Json(params (string k, string v)[] kv)
    {
        var sb = new StringBuilder("{");
        for (int i = 0; i < kv.Length; i++)
        {
            if (i > 0) sb.Append(',');
            sb.Append('"').Append(kv[i].k).Append("\":\"").Append(Esc(kv[i].v)).Append('"');
        }
        return sb.Append('}').ToString();
    }

    static string Esc(string s) => (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "");
}

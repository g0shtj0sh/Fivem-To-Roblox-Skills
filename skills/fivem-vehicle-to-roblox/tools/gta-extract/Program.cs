// gta-extract — convertisseur headless des ressources GTA V (FiveM) vers le format XML CodeWalker.
//
// Usage :
//   gta-extract export <fichier|dossier> [...] -o <dossier_sortie>
//       Convertit récursivement .yft .ydr .ydd .ytd .awc .rel en <nom>.<ext>.xml
//       + un sous-dossier <nom>/ contenant les textures .dds (ou les sons .wav).
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
        Console.Error.WriteLine("Usage: gta-extract export <fichier|dossier>... -o <sortie>");
        Console.Error.WriteLine("       gta-extract xml2bin <fichier.xml> -o <fichier_binaire>");
        return 1;
    }

    // Les noms de shaders / paramètres sont stockés sous forme de hash Jenkins dans les
    // ressources binaires : on alimente l'index avec les chaînes connues pour que le XML
    // contienne "vehicle_paint1" plutôt que "hash_C3071C42".
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
            }
        }
        for (int i = 0; i < 100; i++) JenkIndex.Ensure(i.ToString("00"));
    }

    static (List<string> inputs, string output) ParseArgs(string[] args)
    {
        var inputs = new List<string>();
        string output = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "-o" && i + 1 < args.Length) { output = args[++i]; continue; }
            inputs.Add(args[i]);
        }
        if (inputs.Count == 0 || output == null) throw new ArgumentException("arguments manquants (entrée et -o <sortie>)");
        return (inputs, output);
    }

    static int Export(string[] args)
    {
        var (inputs, output) = ParseArgs(args);
        Directory.CreateDirectory(output);
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
        var (inputs, output) = ParseArgs(args);
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

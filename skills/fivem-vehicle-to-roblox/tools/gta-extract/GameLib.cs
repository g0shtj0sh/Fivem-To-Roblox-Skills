// GameLib — accès en LECTURE SEULE à une installation GTA V pour y retrouver les
// ressources du jeu de base qu'un pack de véhicule réutilise sans les inclure :
//   • textures partagées (vehshare*.ytd, txdRelationships, vehicle_generic_*) ;
//   • son vanilla d'un véhicule (audioNameHash -> dat151 -> dat54 -> .awc -> .wav).
//
// Le scan initial des RPF coûte ~30 s : on ne le paie qu'une fois. Le mode
// « game-serve » garde le RpfManager en mémoire et répond à des commandes JSON
// (une par ligne) sur stdin/stdout.
//
//   gta-extract game-serve -g <dossier GTA> [--gen9]
//
// Commandes (JSON, une par ligne) :
//   {"id":1,"cmd":"status"}
//   {"id":2,"cmd":"find_textures","names":["..."],"hints":{"vehicle":"adder","txds":["..."]}}
//   {"id":3,"cmd":"extract_textures","names":["..."],"out":"<dir>","hints":{...}}
//   {"id":4,"cmd":"vehicle_audio","audioName":"ADDER","out":"<dir>"}
//   {"id":5,"cmd":"build_texture_index"}
//   {"id":6,"cmd":"quit"}
//
// Aucune écriture n'est faite dans le dossier du jeu.

using System.Text;
using System.Text.Json.Nodes;
using CodeWalker.GameFiles;
using CodeWalker.Utils;

internal sealed class GameLib
{
    readonly string folder;
    readonly bool gen9;
    RpfManager rpfman;

    // GameFileCache charge les .rel audio dans l'ordre réel des DLC
    // (dlclist.xml + « order » de chaque setup2.xml) : la version la plus
    // prioritaire d'une entrée écrase les précédentes, ce qu'un scan plat des
    // .rel ne fait pas. C'est indispensable pour les klaxons et les sirènes.
    GameFileCache cache;
    Dictionary<MetaHash, RelData> gameDict = new Dictionary<MetaHash, RelData>();
    Dictionary<MetaHash, RelData> soundsDict = new Dictionary<MetaHash, RelData>();
    public int DlcPacks, AudioRelFiles;

    // hash d'un « ContainerName » -> chemin de l'entrée .awc dans les RPF
    readonly Dictionary<uint, string> awcByContainer = new();

    // index complet « hash de texture -> entrées .ytd », construit à la demande
    Dictionary<uint, List<string>> texIndex;
    readonly List<string> vehicleYtds = new();
    readonly Dictionary<string, YtdFile> ytdCache = new();

    public GameLib(string folder, bool gen9) { this.folder = folder; this.gen9 = gen9; }

    // ------------------------------------------------------------------ init

    public void Init()
    {
        GTA5Keys.LoadFromPath(folder, gen9, null);
        var errs = new List<string>();

        // On ne charge que l'audio : archétypes, véhicules et peds coûtent cher
        // et ne servent pas ici.
        cache = new GameFileCache(256L * 1024 * 1024, 10.0, folder, gen9, "latest", false, "");
        cache.SelectedDlc = string.Empty;   // => GameFileCache prend le dernier DLC de dlclist.xml
        cache.EnableDlc = true;
        cache.LoadArchetypes = false;
        cache.LoadVehicles = false;
        cache.LoadPeds = false;
        cache.LoadAudio = true;
        cache.Init(_ => { }, e => errs.Add(e));

        rpfman = cache.RpfMan;
        gameDict = cache.AudioGameDict;
        soundsDict = cache.AudioSoundsDict;
        DlcPacks = cache.DlcActiveRpfs == null ? 0 : cache.DlcActiveRpfs.Count;
        AudioRelFiles = cache.AudioDatRelFiles == null ? 0 : cache.AudioDatRelFiles.Count;

        IndexAwcAndVehicleYtds();
    }

    /// Liste ordonnée des DLC telle que le jeu la voit (diagnostic).
    public JsonArray DlcOrder(int limit)
    {
        var a = new JsonArray();
        if (cache?.DlcSetupFiles == null) return a;
        foreach (var sf in cache.DlcSetupFiles)
        {
            if (a.Count >= limit) break;
            a.Add(new JsonObject
            {
                ["name"] = sf.deviceName,
                ["order"] = sf.order,
                ["minorOrder"] = sf.minorOrder,
            });
        }
        return a;
    }

    // Priorité d'un chemin, calquée sur l'ordre dans lequel le jeu charge ses
    // archives : base < update.rpf < DLC dans l'ordre de dlclist.xml. Sans ça,
    // une vieille version de resident/vehicles.awc peut gagner et les flux de
    // klaxon / sirène ne sont pas trouvés.
    Dictionary<string, int> dlcPriority;

    void BuildDlcPriority()
    {
        dlcPriority = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        if (cache?.DlcSetupFiles == null) return;
        int i = 0;
        foreach (var sf in cache.DlcSetupFiles)
        {
            var n = (sf.deviceName ?? "").ToLowerInvariant();
            if (n.Length == 0) continue;
            dlcPriority[n] = ++i;              // 1..N, dans l'ordre du jeu
            if (n.StartsWith("dlc_")) dlcPriority[n.Substring(4)] = i;
            if (n.StartsWith("dlc")) dlcPriority[n.Substring(3)] = i;
        }
    }

    int PathPriority(string path)
    {
        // path est en minuscules, séparateurs « / »
        var i = path.IndexOf("dlcpacks/", StringComparison.Ordinal);
        if (i >= 0)
        {
            var rest = path.Substring(i + 9);
            var j = rest.IndexOf('/');
            var name = j > 0 ? rest.Substring(0, j) : rest;
            int pr;
            if (dlcPriority != null && dlcPriority.TryGetValue(name, out pr)) return 1000 + pr;
            return 1000;                        // DLC inconnu de dlclist : juste au-dessus d'update
        }
        if (path.StartsWith("update", StringComparison.Ordinal)) return 500;
        return 0;                               // archives de base
    }

    void IndexAwcAndVehicleYtds()
    {
        BuildDlcPriority();
        var awcPri = new Dictionary<uint, int>();
        var ytds = new List<(int pri, string key)>();
        foreach (var kv in rpfman.EntryDict)
        {
            if (kv.Value is not RpfFileEntry fe) continue;
            var nl = fe.NameLower ?? fe.Name.ToLowerInvariant();
            var path = (fe.Path ?? fe.Name).ToLowerInvariant().Replace('\\', '/');
            if (nl.EndsWith(".awc")) { RegisterAwc(path, PathPriority(path), awcPri); continue; }
            if (nl.EndsWith(".ytd") && IsVehicleYtd(path)) ytds.Add((PathPriority(path), kv.Key));
        }
        // les dictionnaires les plus récents d'abord : même logique pour les textures
        ytds.Sort((x, y) => y.pri.CompareTo(x.pri));
        foreach (var t in ytds) vehicleYtds.Add(t.key);
    }

    static bool IsVehicleYtd(string path)
        => path.Contains("vehicles.rpf") || path.Contains("/vehicles/") || path.Contains("vehiclemods")
           || path.Contains("vehshare") || path.Contains("vehicles_")
           // tableaux de bord / compteurs : textures de cible de rendu (script_rt_dials_*)
           || path.Contains("script_txds");

    // Un ContainerName est le chemin du conteneur d'ondes relatif à x64/audio/,
    // sans extension (ex. « streamed_vehicles_granular/supercar_4_eur_v8 »).
    void RegisterAwc(string path, int pri, Dictionary<uint, int> awcPri)
    {
        var noExt = path.EndsWith(".awc") ? path.Substring(0, path.Length - 4) : path;
        var i = noExt.IndexOf("/audio/", StringComparison.Ordinal);
        if (i < 0) { RegisterVariant(Path.GetFileName(noExt), path, pri, awcPri); return; }
        var rel = noExt.Substring(i + 7);                 // « sfx/streamed_vehicles_granular.rpf/xxx »

        // Les AWC sont rangés dans des RPF imbriqués dont le nom reprend celui du
        // dossier logique : le ContainerName du dat54 ne contient PAS le « .rpf ».
        var parts = rel.Split('/');
        var clean = new List<string>();
        foreach (var seg in parts)
            clean.Add(seg.EndsWith(".rpf") ? seg.Substring(0, seg.Length - 4) : seg);
        var cleanRel = string.Join("/", clean);

        RegisterVariant(cleanRel, path, pri, awcPri);
        if (cleanRel.StartsWith("sfx/")) RegisterVariant(cleanRel.Substring(4), path, pri, awcPri);
        RegisterVariant(rel, path, pri, awcPri);
        if (rel.StartsWith("sfx/")) RegisterVariant(rel.Substring(4), path, pri, awcPri);
        RegisterVariant(Path.GetFileName(noExt), path, pri, awcPri);
    }

    void RegisterVariant(string v, string path, int pri, Dictionary<uint, int> awcPri)
    {
        if (string.IsNullOrEmpty(v)) return;
        var h = JenkHash.GenHash(v);
        if (h == 0) return;
        int old;
        if (awcPri.TryGetValue(h, out old) && old >= pri) return;   // on garde le plus prioritaire
        awcPri[h] = pri;
        awcByContainer[h] = path;
    }

    // ------------------------------------------------------------- textures

    static uint TexHash(string name) => JenkHash.GenHash(name.ToLowerInvariant());

    YtdFile LoadYtd(string entryKey)
    {
        if (ytdCache.TryGetValue(entryKey, out var c)) return c;
        YtdFile ytd = null;
        try
        {
            if (rpfman.EntryDict.TryGetValue(entryKey, out var e) && e is RpfFileEntry fe)
                ytd = rpfman.GetFile<YtdFile>(fe);
        }
        catch { /* dictionnaire illisible : ignoré */ }
        if (ytdCache.Count > 64) ytdCache.Clear();      // garde-fou mémoire
        ytdCache[entryKey] = ytd;
        return ytd;
    }

    // Ordre de recherche : d'abord les dictionnaires les plus probables (pas de scan complet).
    IEnumerable<string> CandidateYtds(JsonNode hints, string texName)
    {
        var seen = new HashSet<string>();
        var names = new List<string>();
        if (hints is JsonObject ho)
        {
            var arr = ho["txds"] as JsonArray;
            if (arr != null)
                foreach (var t in arr)
                    if (t != null) names.Add(t.GetValue<string>().ToLowerInvariant());
            var veh = ho["vehicle"]?.GetValue<string>();
            if (!string.IsNullOrEmpty(veh))
            {
                names.Add(veh.ToLowerInvariant());
                names.Add(veh.ToLowerInvariant() + "+hi");
            }
        }
        // « adder_sign_1 » -> essaie aussi « adder.ytd »
        var us = texName.IndexOf('_');
        if (us > 1) names.Add(texName.Substring(0, us).ToLowerInvariant());
        names.AddRange(new[] { "vehshare", "vehshare_truck", "vehshare_army", "vehshare_worn", "vehicles_generic" });

        foreach (var n in names)
            foreach (var key in vehicleYtds)
                if (Path.GetFileNameWithoutExtension(key).Equals(n, StringComparison.OrdinalIgnoreCase) && seen.Add(key))
                    yield return key;
    }

    public (string ytd, Texture tex) FindTexture(string name, JsonNode hints)
    {
        var h = TexHash(name);
        foreach (var key in CandidateYtds(hints, name))
        {
            var t = LoadYtd(key)?.TextureDict?.Lookup(h);
            if (t != null) return (key, t);
        }
        if (texIndex != null && texIndex.TryGetValue(h, out var list))
            foreach (var key in list)
            {
                var t = LoadYtd(key)?.TextureDict?.Lookup(h);
                if (t != null) return (key, t);
            }
        return (null, null);
    }

    public int IndexOk, IndexFailed, IndexEmpty;

    public int BuildTextureIndex(Action<int, int> progress)
    {
        var idx = new Dictionary<uint, List<string>>();
        int done = 0;
        IndexOk = IndexFailed = IndexEmpty = 0;
        foreach (var key in vehicleYtds)
        {
            YtdFile ytd = null;
            try
            {
                if (rpfman.EntryDict.TryGetValue(key, out var e) && e is RpfFileEntry fe)
                    ytd = rpfman.GetFile<YtdFile>(fe);
            }
            catch { IndexFailed++; }
            var items = ytd?.TextureDict?.Textures?.data_items;
            if (items == null || items.Length == 0) IndexEmpty++; else IndexOk++;
            if (items != null)
                foreach (var t in items)
                {
                    if (t == null || t.NameHash == 0) continue;
                    List<string> l;
                    if (!idx.TryGetValue(t.NameHash, out l)) idx[t.NameHash] = l = new List<string>();
                    if (l.Count < 8) l.Add(key);
                }
            if (++done % 200 == 0) progress(done, vehicleYtds.Count);
        }
        texIndex = idx;
        return idx.Count;
    }

    // ---------------------------------------------------------------- audio

    T Get<T>(Dictionary<MetaHash, RelData> d, MetaHash h) where T : RelData
    {
        RelData v;
        return d.TryGetValue(h, out v) ? v as T : null;
    }

    /// Cherche une entrée audio : d'abord les sons (dat54), puis les réglages (dat151).
    RelData Lookup(MetaHash h, out string dict)
    {
        RelData rd;
        if (soundsDict.TryGetValue(h, out rd) && rd != null) { dict = "dat54"; return rd; }
        if (gameDict.TryGetValue(h, out rd) && rd != null) { dict = "dat151"; return rd; }
        dict = null;
        return null;
    }

    /// Fichier .rel d'où vient l'entrée retenue : c'est lui qui a « gagné »
    /// l'arbitrage entre DLC.
    static string RelSource(RelData rd)
    {
        var rel = rd?.Rel;
        if (rel == null) return null;
        if (rel.RpfFileEntry != null && !string.IsNullOrEmpty(rel.RpfFileEntry.Path))
            return rel.RpfFileEntry.Path.Replace('\\', '/');
        return rel.Name;
    }

    sealed class Want
    {
        public string Role;
        public string Canon;          // nom attendu par f2r/audio.py
        public uint Slot;             // emplacement du Dat54SoundSet d'origine
        public MetaHash Container;
        public MetaHash File;
        public ChainNode Node;
    }

    // Noms de flux que f2r/audio.py sait exploiter directement.
    static readonly HashSet<string> KnownEngineStreams = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "engine_accel", "engine_decel", "engine_idle",
        "exhaust_accel", "exhaust_decel", "exhaust_idle",
    };

    /// Un maillon de la chaîne audio, pour le diagnostic comme pour l'extraction.
    sealed class ChainNode
    {
        public string Role, Canon, Dict, Type, Source;
        public uint Slot;
        public MetaHash Hash;
        public bool IsLeaf;
        public MetaHash Container, File;
        public string Wav;
        public double Seconds;
        public long Bytes;
        public string Awc, Status;
        public readonly List<ChainNode> Children = new List<ChainNode>();
        public readonly List<string> Props = new List<string>();

        public JsonObject ToJson(bool withProps)
        {
            var o = new JsonObject
            {
                ["role"] = Role,
                ["hash"] = Hash.ToString(),
                ["type"] = Type ?? "(absent des .rel)",
            };
            if (Dict != null) o["dict"] = Dict;
            if (Source != null) o["source"] = Source;
            if (IsLeaf)
            {
                o["container"] = Container.ToString();
                o["file"] = File.ToString();
                if (Awc != null) o["awc"] = Awc;
                if (Status != null) o["status"] = Status;
                if (Wav != null) { o["wav"] = Wav; o["seconds"] = Math.Round(Seconds, 2); o["bytes"] = Bytes; }
            }
            if (withProps && Props.Count > 0)
            {
                var pa = new JsonArray();
                foreach (var p in Props) pa.Add(p);
                o["props"] = pa;
            }
            if (Children.Count > 0)
            {
                var ca = new JsonArray();
                foreach (var c in Children) ca.Add(c.ToJson(withProps));
                o["children"] = ca;
            }
            return o;
        }
    }

    static readonly HashSet<string> SkipProps = new HashSet<string>
    {
        "NameHash", "ParentSound", "Name", "Category", "Unk", "Flags",
    };

    /// Descend l'arbre des sons jusqu'aux feuilles (ContainerName + FileName).
    /// Les types intermédiaires sont nombreux (multitrack, randomized, variable,
    /// switch, liste de hashes…) et n'ont pas d'interface commune : on suit donc
    /// par réflexion tous les tableaux de hashes, et tout champ de type MetaHash
    /// qui désigne lui-même un son connu.
    ChainNode Walk(MetaHash h, string role, HashSet<uint> seen, int depth, List<Want> leaves,
                   string canon = null, uint slot = 0)
    {
        var node = new ChainNode { Role = role, Canon = canon, Slot = slot, Hash = h };
        if (h.Hash == 0) { node.Type = "(vide)"; return node; }
        if (depth > 8 || leaves.Count > 256) { node.Type = "(coupé : trop profond)"; return node; }
        if (!seen.Add(h.Hash)) { node.Type = "(déjà vu)"; return node; }

        string dict;
        var rd = Lookup(h, out dict);
        if (rd == null) return node;
        node.Dict = dict;
        node.Type = rd.GetType().Name;
        node.Source = RelSource(rd);

        var t = rd.GetType();
        var arrays = new List<System.Reflection.PropertyInfo>();
        var hashes = new List<System.Reflection.PropertyInfo>();
        foreach (var pi in t.GetProperties())
        {
            if (SkipProps.Contains(pi.Name)) continue;
            if (pi.PropertyType == typeof(MetaHash[])) arrays.Add(pi);
            else if (pi.PropertyType == typeof(MetaHash)) hashes.Add(pi);
        }

        // Trace : tous les champs de hash non nuls, pour comprendre une structure
        // inconnue sans avoir à deviner.
        foreach (var pi in hashes)
        {
            MetaHash v;
            try { v = (MetaHash)pi.GetValue(rd); } catch { continue; }
            if (v.Hash != 0) node.Props.Add(pi.Name + " = " + v.ToString());
        }
        foreach (var pi in arrays)
        {
            MetaHash[] arr;
            try { arr = pi.GetValue(rd) as MetaHash[]; } catch { continue; }
            if (arr == null || arr.Length == 0) continue;
            var sb = new StringBuilder(pi.Name + "[" + arr.Length + "] =");
            for (int i = 0; i < arr.Length && i < 8; i++) sb.Append(' ').Append(arr[i].ToString());
            node.Props.Add(sb.ToString());
        }

        // Cas 1 : son granulaire (moteur) -> six canaux, chacun une feuille.
        var gran = rd as Dat54GranularSound;
        if (gran != null)
        {
            var chans = new[] { gran.Channel0, gran.Channel1, gran.Channel2,
                                gran.Channel3, gran.Channel4, gran.Channel5 };
            foreach (var c in chans)
            {
                if (c == null || c.ContainerName.Hash == 0 || c.FileName.Hash == 0) continue;
                var cn = c.FileName.ToString();
                node.Children.Add(Leaf(role, c.ContainerName, c.FileName, leaves,
                                       KnownEngineStreams.Contains(cn) ? cn : null, slot));
            }
            return node;
        }

        // Cas 2 : son simple -> feuille directe.
        var cnp = t.GetProperty("ContainerName");
        var fnp = t.GetProperty("FileName");
        if (cnp != null && fnp != null)
        {
            var cn = cnp.GetValue(rd);
            var fn = fnp.GetValue(rd);
            if (cn is MetaHash && fn is MetaHash
                && ((MetaHash)cn).Hash != 0 && ((MetaHash)fn).Hash != 0)
            {
                node.IsLeaf = true;
                node.Container = (MetaHash)cn;
                node.File = (MetaHash)fn;
                var fname = node.File.ToString();
                if (node.Canon == null && KnownEngineStreams.Contains(fname)) node.Canon = fname;
                leaves.Add(new Want
                {
                    Role = role, Canon = node.Canon, Slot = slot,
                    Container = node.Container, File = node.File, Node = node,
                });
                return node;
            }
        }

        // Cas 3 : ensemble nomme (Dat54SoundSet) -> chaque enfant porte un
        // ScriptName, seul libelle fiable pour distinguer les tonalites.
        var set = rd as Dat54SoundSet;
        if (set != null && set.SoundSets != null && set.SoundSets.Length > 0)
        {
            foreach (var it in set.SoundSets)
            {
                if (it == null || it.ChildSound.Hash == 0) continue;
                var label = SirenSlotLabel(it.ScriptName.Hash, it.ScriptName.ToString());
                node.Props.Add("SoundSet[" + label + "] -> " + it.ChildSound.ToString());
                // Chaque emplacement est resolu avec son propre jeu de « deja vu » :
                // plusieurs emplacements partagent souvent les memes sous-arbres, et
                // un ensemble partage masquerait les feuilles des emplacements suivants.
                node.Children.Add(Walk(it.ChildSound, role + "/" + label, new HashSet<uint>(),
                                       depth + 1, leaves, canon, it.ScriptName.Hash));
            }
            return node;
        }

        // Cas 4 : conteneur logique -> on descend.
        foreach (var pi in arrays)
        {
            MetaHash[] arr;
            try { arr = pi.GetValue(rd) as MetaHash[]; } catch { continue; }
            if (arr == null) continue;
            foreach (var ch in arr)
                if (ch.Hash != 0) node.Children.Add(Walk(ch, role, seen, depth + 1, leaves, canon, slot));
        }
        foreach (var pi in hashes)
        {
            MetaHash v;
            try { v = (MetaHash)pi.GetValue(rd); } catch { continue; }
            if (v.Hash == 0 || !soundsDict.ContainsKey(v)) continue;
            node.Children.Add(Walk(v, role + ":" + pi.Name, seen, depth + 1, leaves, canon, slot));
        }
        return node;
    }

    ChainNode Leaf(string role, MetaHash container, MetaHash file, List<Want> leaves,
                   string canon, uint slot)
    {
        var n = new ChainNode
        {
            Role = role, Canon = canon, Slot = slot, IsLeaf = true, Hash = file,
            Container = container, File = file, Type = "(flux AWC)",
        };
        leaves.Add(new Want
        {
            Role = role, Canon = canon, Slot = slot,
            Container = container, File = file, Node = n,
        });
        return n;
    }

    // ------------------------------------------------- extraction des feuilles

    /// Extrait les AWC nécessaires (un seul passage par AWC) puis renseigne
    /// chaque feuille avec son .wav et sa durée.
    void ResolveLeaves(List<Want> leaves, string outDir, JsonArray containers)
    {
        var dirs = new Dictionary<uint, string>();
        var errs = new Dictionary<uint, string>();
        foreach (var w in leaves)
        {
            if (dirs.ContainsKey(w.Container.Hash) || errs.ContainsKey(w.Container.Hash)) continue;
            var info = new JsonObject { ["container"] = w.Container.ToString() };
            string rel = null, err = null;
            try { rel = ExtractAwc(w.Container, outDir, info); }
            catch (Exception ex) { err = ex.Message; }
            if (rel != null) dirs[w.Container.Hash] = rel;
            else { errs[w.Container.Hash] = err ?? "introuvable"; info["error"] = err ?? "introuvable"; }
            if (containers != null) containers.Add(info);
        }
        foreach (var w in leaves)
        {
            var n = w.Node;
            string dir;
            if (!dirs.TryGetValue(w.Container.Hash, out dir))
            {
                n.Status = "awc_not_found";
                continue;
            }
            n.Awc = dir;
            var wav = FindWav(Path.Combine(outDir, dir), w.File);
            if (wav == null) { n.Status = "wav_not_found"; continue; }
            n.Status = "ok";
            n.Wav = Path.GetRelativePath(outDir, wav).Replace('\\', '/');
            n.Bytes = new FileInfo(wav).Length;
            n.Seconds = WavSeconds(wav);
        }
    }

    static string Tag(BinaryReader br)
    {
        var b = br.ReadBytes(4);
        return b.Length < 4 ? "" : Encoding.ASCII.GetString(b);
    }

    /// Durée d'un .wav PCM, lue dans son en-tête (aucun décodage).
    static double WavSeconds(string path)
    {
        try
        {
            using (var f = File.OpenRead(path))
            using (var br = new BinaryReader(f))
            {
                if (Tag(br) != "RIFF") return 0;
                br.ReadUInt32();
                if (Tag(br) != "WAVE") return 0;
                int rate = 0, bits = 0, chans = 0;
                while (f.Position + 8 <= f.Length)
                {
                    var id = Tag(br);
                    var len = br.ReadUInt32();
                    var body = f.Position;                 // début des données du chunk
                    var next = body + len + (len % 2);
                    if (id == "fmt ")
                    {
                        br.ReadUInt16();
                        chans = br.ReadUInt16();
                        rate = (int)br.ReadUInt32();
                        br.ReadUInt32();
                        br.ReadUInt16();
                        bits = br.ReadUInt16();
                    }
                    else if (id == "data")
                    {
                        if (rate <= 0 || bits <= 0 || chans <= 0) return 0;
                        return (double)len / (rate * chans * (bits / 8.0));
                    }
                    if (next <= body) break;           // chunk vide ou longueur absurde
                    f.Position = next;
                }
            }
        }
        catch { }
        return 0;
    }

    // ------------------------------------------------------ chaîne d'un véhicule

    static readonly string[] SirenKinds = { "wail", "yelp", "priority" };

    // Les sirenes d'un vehicule sont un Dat54SoundSet dont chaque entree porte un
    // « ScriptName ». Ces emplacements sont les MEMES pour tous les vehicules
    // d'urgence (verifie sur POLICE, POLICE2, SHERIFF, AMBULANCE, FIRETRUK et
    // POLIGNUS du DLC 2026) : seuls les sons enfants changent. Quatre de ces noms
    // ont pu etre retrouves par hash Jenkins, les autres sont identifies par leur
    // hash, stable d'un DLC a l'autre.
    static readonly Dictionary<uint, string> SirenSlotNames = new Dictionary<uint, string>
    {
        { 1043621919u, "Horn" },
        { 1689781374u, "Fast" },
        { 3303937151u, "Slow" },
        { 3410657623u, "Horn_Fast" },
        { 3642518543u, "Horn_Slow" },
        { 3911129148u, "Warning" },
        { 1305684053u, "Main" },        // porte la sirene propre au vehicule
        { 1410818973u, "Shared" },      // identique pour tous les vehicules
    };

    static string SirenSlotLabel(uint hash, string fallback)
    {
        string n;
        return SirenSlotNames.TryGetValue(hash, out n) ? n : fallback;
    }

    // Emplacement -> tonalite attendue par le runtime Roblox, par ordre de
    // preference. « Main » porte la sirene specifique du vehicule, « Slow » sert
    // de repli pour le wail, « Fast » donne le yelp et « Warning » le hi-lo.
    static readonly (uint slot, string kind)[] SirenSlotKinds =
    {
        (1305684053u, "wail"),
        (3303937151u, "wail"),
        (1689781374u, "yelp"),
        (3303937151u, "yelp"),
        (3911129148u, "priority"),
        (3410657623u, "priority"),
    };

    // Fenetres de duree plausibles par tonalite : le wail est une longue
    // montee-descente, le yelp et le hi-lo sont des boucles courtes.
    static bool PlausibleFor(string kind, double secs)
        => kind == "wail" ? secs >= 1.5 : (secs >= 0.15 && secs <= 2.5);

    /// Devine le type de sirène d'après les noms de flux et de conteneur.
    /// La plupart des flux de sirène n'ont pas de nom connu (hash seul) : on
    /// retombe alors sur la durée (voir ClassifySirens).
    static string SirenKindByName(ChainNode n)
    {
        var txt = (n.Role + " " + n.File.ToString() + " " + n.Container.ToString()).ToLowerInvariant();
        if (txt.Contains("wail")) return "wail";
        if (txt.Contains("yelp")) return "yelp";
        if (txt.Contains("priority") || txt.Contains("manual") || txt.Contains("hilo")
            || txt.Contains("phaser")) return "priority";
        return null;
    }

    /// Associe wail / yelp / priority aux flux de sirène trouvés.
    ///
    /// Les noms étant presque toujours des hashes inconnus, on se sert de la
    /// durée, qui distingue bien les trois dans GTA : le « wail » est une longue
    /// montée-descente (plusieurs secondes), le « yelp » et le « priority » sont
    /// des boucles courtes. Le plus long devient donc le wail, puis les deux
    /// suivants, du plus long au plus court, yelp puis priority.
    static Dictionary<ChainNode, string> ClassifySirens(List<ChainNode> sirens)
    {
        var kinds = new Dictionary<ChainNode, string>();
        var used = new HashSet<string>();
        var usedFiles = new HashSet<uint>();

        // 1) les rares flux réellement nommés
        foreach (var n in sirens)
        {
            var k = SirenKindByName(n);
            if (k != null && used.Add(k)) { kinds[n] = k; usedFiles.Add(n.File.Hash); }
        }

        // 2) par emplacement du SoundSet : c'est la source la plus sure, puisque
        //    c'est le jeu lui-meme qui range chaque son dans un emplacement nomme.
        foreach (var pref in SirenSlotKinds)
        {
            if (used.Contains(pref.kind)) continue;
            ChainNode best = null;
            foreach (var n in sirens)
            {
                if (n.Slot != pref.slot || kinds.ContainsKey(n)) continue;
                if (usedFiles.Contains(n.File.Hash)) continue;
                if (!PlausibleFor(pref.kind, n.Seconds)) continue;
                // wail : le plus long ; tonalites courtes : la plus courte
                if (best == null
                    || (pref.kind == "wail" ? n.Seconds > best.Seconds : n.Seconds < best.Seconds))
                    best = n;
            }
            if (best != null)
            {
                kinds[best] = pref.kind;
                used.Add(pref.kind);
                usedFiles.Add(best.File.Hash);
            }
        }

        // 3) ce qui reste, par durée décroissante, en évitant les doublons de flux
        var rest = new List<ChainNode>();
        var seenFile = new HashSet<uint>(usedFiles);
        foreach (var n in sirens)
        {
            if (kinds.ContainsKey(n)) { seenFile.Add(n.File.Hash); continue; }
            if (!seenFile.Add(n.File.Hash)) continue;
            rest.Add(n);
        }
        rest.Sort((x, y) => y.Seconds.CompareTo(x.Seconds));
        foreach (var n in rest)
        {
            string pick = null;
            foreach (var k in SirenKinds)
                if (!used.Contains(k)) { pick = k; break; }
            if (pick == null) break;
            if (!PlausibleFor(pick, n.Seconds))
            {
                // rien de plausible pour cette tonalite : la synthese s'en charge
                used.Add(pick);
                continue;
            }
            kinds[n] = pick;
            used.Add(pick);
        }
        return kinds;
    }

    sealed class VehChain
    {
        public Dat151CarAudioSettings Car;
        public string EngineKind = "none";     // granular | loops | none
        public List<ChainNode> Roots = new List<ChainNode>();
        public List<Want> Leaves = new List<Want>();
    }

    VehChain BuildChain(string audioName)
    {
        var nameHash = new MetaHash(JenkHash.GenHash(audioName.ToLowerInvariant()));
        var car = Get<Dat151CarAudioSettings>(gameDict, nameHash);
        if (car == null) return null;
        var vc = new VehChain { Car = car };

        var granular = Get<Dat151GranularEngineAudioSettings>(gameDict, car.GranularEngine);
        if (granular != null)
        {
            vc.EngineKind = "granular";
            vc.Roots.Add(Walk(granular.EngineAccel, "engine", new HashSet<uint>(), 0, vc.Leaves));
            vc.Roots.Add(Walk(granular.ExhaustAccel, "exhaust", new HashSet<uint>(), 0, vc.Leaves));
        }
        else
        {
            // Camions et vehicules anciens : pas de moteur granulaire, mais des
            // boucles bas / haut regime dans Dat151VehicleEngineAudioSettings.
            var eng = Get<Dat151VehicleEngineAudioSettings>(gameDict, car.Engine);
            if (eng != null)
            {
                vc.EngineKind = "loops";
                var map = new (MetaHash h, string role, string canon)[]
                {
                    (eng.HighEngineLoop, "engine", "engine_accel"),
                    (eng.RevsOffLoop, "engine", "engine_decel"),
                    (eng.LowEngineLoop, "engine", "engine_idle"),
                    (eng.HighExhaustLoop, "exhaust", "exhaust_accel"),
                    (eng.LowExhaustLoop, "exhaust", "exhaust_idle"),
                    (eng.IdleEngineSimpleLoop, "engine", "engine_idle"),
                    (eng.IdleExhaustSimpleLoop, "exhaust", "exhaust_idle"),
                };
                foreach (var m in map)
                    if (m.h.Hash != 0)
                        vc.Roots.Add(Walk(m.h, m.role, new HashSet<uint>(), 0, vc.Leaves, m.canon));
            }
        }
        vc.Roots.Add(Walk(car.HornSounds, "horn", new HashSet<uint>(), 0, vc.Leaves));
        vc.Roots.Add(Walk(car.SirenSounds, "siren", new HashSet<uint>(), 0, vc.Leaves));
        vc.Roots.Add(Walk(car.StartupRevs, "startup", new HashSet<uint>(), 0, vc.Leaves));
        return vc;
    }

    /// Diagnostic : chaîne complète d'un audioNameHash, avec la source .rel qui a
    /// gagné à chaque maillon. Si « out » est fourni, les .wav sont extraits et
    /// chaque feuille porte sa durée.
    public JsonObject AudioChain(string audioName, string outDir, bool withProps)
    {
        var res = new JsonObject { ["audioName"] = audioName };
        var vc = BuildChain(audioName);
        if (vc == null)
        {
            res["status"] = "not_found";
            res["error"] = "aucun Dat151CarAudioSettings nomme " + audioName;
            return res;
        }
        res["status"] = "ok";
        res["engineKind"] = vc.EngineKind;
        res["carAudioSettings"] = new JsonObject
        {
            ["source"] = RelSource(vc.Car),
            ["granularEngine"] = vc.Car.GranularEngine.ToString(),
            ["hornSounds"] = vc.Car.HornSounds.ToString(),
            ["sirenSounds"] = vc.Car.SirenSounds.ToString(),
            ["startupRevs"] = vc.Car.StartupRevs.ToString(),
        };
        if (!string.IsNullOrEmpty(outDir))
        {
            Directory.CreateDirectory(outDir);
            ResolveLeaves(vc.Leaves, outDir, null);
        }
        var roots = new JsonArray();
        foreach (var r in vc.Roots) roots.Add(r.ToJson(withProps));
        res["chain"] = roots;
        return res;
    }

    /// Extraction pour le pipeline : flux moteur, klaxon et sirènes classés.
    public JsonObject VehicleAudio(string audioName, string outDir)
    {
        var res = new JsonObject { ["audioName"] = audioName };
        var vc = BuildChain(audioName);
        if (vc == null)
        {
            res["status"] = "not_found";
            res["error"] = "aucun Dat151CarAudioSettings nomme " + audioName + " dans les .rel du jeu";
            return res;
        }
        res["status"] = "ok";
        res["granularEngine"] = vc.Car.GranularEngine.ToString();
        res["hornSounds"] = vc.Car.HornSounds.ToString();
        res["sirenSounds"] = vc.Car.SirenSounds.ToString();
        res["engineKind"] = vc.EngineKind;
        res["source"] = RelSource(vc.Car);

        var containers = new JsonArray();
        ResolveLeaves(vc.Leaves, outDir, containers);
        res["containers"] = containers;

        // Classement des sirènes : par nom quand il parle, sinon par ordre
        // d'apparition (wail, yelp, priority), ce que fait le jeu en pratique.
        var sirens = new List<ChainNode>();
        foreach (var w in vc.Leaves)
            if (w.Role.StartsWith("siren") && w.Node.Status == "ok" && w.Node.Seconds >= 0.15)
                sirens.Add(w.Node);
        var kinds = ClassifySirens(sirens);

        var streams = new JsonArray();
        foreach (var w in vc.Leaves)
        {
            var n = w.Node;
            var item = new JsonObject
            {
                ["role"] = w.Role,
                ["canon"] = w.Canon,
                ["slot"] = w.Slot == 0 ? null : SirenSlotLabel(w.Slot, w.Slot.ToString()),
                ["container"] = w.Container.ToString(),
                ["file"] = w.File.ToString(),
                ["status"] = n.Status ?? "unresolved",
            };
            string kind;
            if (kinds.TryGetValue(n, out kind)) item["sirenKind"] = kind;
            if (n.Awc != null) item["awcDir"] = n.Awc;
            if (n.Wav != null)
            {
                item["wav"] = n.Wav;
                item["bytes"] = n.Bytes;
                item["seconds"] = Math.Round(n.Seconds, 2);
            }
            streams.Add(item);
        }
        res["streams"] = streams;
        return res;
    }

    /// Extrait un AWC vers outDir/awc/<nom>/ et renvoie son chemin relatif.
    string ExtractAwc(MetaHash container, string outDir, JsonObject info)
    {
        string awcPath;
        if (!awcByContainer.TryGetValue(container.Hash, out awcPath)) return null;
        if (info != null) info["awc"] = awcPath;
        var key = awcPath.Replace('/', '\\');
        RpfEntry e;
        if (!rpfman.EntryDict.TryGetValue(key, out e) || !(e is RpfFileEntry fe))
            throw new Exception("entree RPF introuvable : " + awcPath);
        var relDir = Path.Combine("awc", Path.GetFileNameWithoutExtension(fe.Name));
        var dir = Path.Combine(outDir, relDir);
        if (!Directory.Exists(dir))
        {
            var data = fe.File.ExtractFile(fe);
            if (data == null) throw new Exception(fe.File.LastError ?? "extraction impossible");
            Directory.CreateDirectory(dir);
            string xmlName;
            var xml = MetaXml.GetXml(fe, data, out xmlName, dir);
            if (!string.IsNullOrEmpty(xml))
                File.WriteAllText(Path.Combine(dir, fe.Name + ".xml"), xml, new UTF8Encoding(false));
        }
        if (info != null)
        {
            int n = 0;
            foreach (var w in Directory.EnumerateFiles(dir, "*.wav", SearchOption.AllDirectories)) n++;
            info["wavs"] = n;
        }
        return relDir.Replace('\\', '/');
    }

    // Dans un AWC, l'identifiant d'un flux ne tient que sur 29 bits :
    // AwcStreamInfo.Read fait « Id = RawVal & 0x1FFFFFFF », les 3 bits hauts
    // servant au nombre de morceaux. Le hash FileName d'un dat54 est, lui, sur
    // 32 bits. Il faut donc le masquer avant toute comparaison — sans ça, tous
    // les flux dont le nom n'est pas connu (klaxons, sirènes) restent
    // introuvables alors que le bon AWC a été trouvé.
    const uint AwcIdMask = 0x1FFFFFFF;

    /// Retrouve le .wav d'un flux. CodeWalker nomme le fichier d'après la chaîne
    /// connue du hash (reconstruit en testant les 3 bits perdus), sinon
    /// « 0x » + l'identifiant masqué en hexadécimal.
    static string FindWav(string dir, MetaHash file)
    {
        if (!Directory.Exists(dir)) return null;
        var masked = file.Hash & AwcIdMask;
        var cands = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            file.ToString(),
            "0x" + masked.ToString("X8"),
            "0x" + masked.ToString("X"),
            "0x" + file.Hash.ToString("X8"),
            file.Hash.ToString(),
        };
        foreach (var f in Directory.EnumerateFiles(dir, "*.wav", SearchOption.AllDirectories))
            if (cands.Contains(Path.GetFileNameWithoutExtension(f)))
                return f;
        return null;
    }

    // ------------------------------------------------------------- serveur

    public static int Serve(string[] args)
    {
        string folder = null; bool gen9 = false;
        for (int i = 0; i < args.Length; i++)
        {
            if ((args[i] == "-g" || args[i] == "--game") && i + 1 < args.Length) folder = args[++i];
            else if (args[i] == "--gen9") gen9 = true;
        }
        if (folder == null) { Console.Error.WriteLine("game-serve : -g <dossier GTA> requis"); return 1; }

        var lib = new GameLib(folder, gen9);
        var t0 = DateTime.UtcNow;
        try { lib.Init(); }
        catch (Exception ex)
        {
            Emit(new JsonObject { ["event"] = "fatal", ["error"] = ex.Message });
            return 2;
        }
        Emit(new JsonObject
        {
            ["event"] = "ready",
            ["rpfs"] = lib.rpfman.AllRpfs == null ? 0 : lib.rpfman.AllRpfs.Count,
            ["entries"] = lib.rpfman.EntryDict == null ? 0 : lib.rpfman.EntryDict.Count,
            ["vehicleYtds"] = lib.vehicleYtds.Count,
            ["dat151Items"] = lib.gameDict.Count,
            ["dat54Sounds"] = lib.soundsDict.Count,
            ["awcContainers"] = lib.awcByContainer.Count,
            ["dlcPacks"] = lib.DlcPacks,
            ["audioRelFiles"] = lib.AudioRelFiles,
            ["initSeconds"] = Math.Round((DateTime.UtcNow - t0).TotalSeconds, 1),
        });

        string line;
        while ((line = Console.ReadLine()) != null)
        {
            if (line.Trim().Length == 0) continue;
            JsonObject req = null;
            try { req = JsonNode.Parse(line) as JsonObject; }
            catch (Exception ex) { Emit(new JsonObject { ["error"] = "json invalide: " + ex.Message }); continue; }
            if (req == null) continue;
            var id = req["id"] == null ? null : req["id"].DeepClone();
            JsonObject resp;
            try { resp = lib.Handle(req); }
            catch (Exception ex) { resp = new JsonObject { ["status"] = "error", ["error"] = ex.Message }; }
            if (resp == null) break;                     // quit
            if (id != null) resp["id"] = id;
            Emit(resp);
        }
        return 0;
    }

    JsonObject Handle(JsonObject req)
    {
        var cmdNode = req["cmd"];
        var cmd = cmdNode == null ? "" : cmdNode.GetValue<string>();
        switch (cmd)
        {
            case "quit": return null;

            case "status":
                return new JsonObject
                {
                    ["status"] = "ok",
                    ["entries"] = rpfman.EntryDict.Count,
                    ["vehicleYtds"] = vehicleYtds.Count,
                    ["textureIndex"] = texIndex == null ? 0 : texIndex.Count,
                };

            case "build_texture_index":
                {
                    var n = BuildTextureIndex((d, t) =>
                        Emit(new JsonObject { ["event"] = "index_progress", ["done"] = d, ["total"] = t }));
                    return new JsonObject
                    {
                        ["status"] = "ok", ["textures"] = n,
                        ["ytdOk"] = IndexOk, ["ytdEmpty"] = IndexEmpty, ["ytdFailed"] = IndexFailed,
                    };
                }

            case "find_textures":
            case "extract_textures":
                {
                    bool extract = cmd == "extract_textures";
                    var outNode = req["out"];
                    var outDir = outNode == null ? null : outNode.GetValue<string>();
                    if (extract && string.IsNullOrEmpty(outDir)) throw new Exception("'out' requis");
                    if (extract) Directory.CreateDirectory(outDir);
                    var found = new JsonObject();
                    var missing = new JsonArray();
                    var names = (req["names"] as JsonArray) ?? new JsonArray();
                    foreach (var n in names)
                    {
                        var name = n == null ? null : n.GetValue<string>();
                        if (string.IsNullOrWhiteSpace(name)) continue;
                        var r = FindTexture(name, req["hints"]);
                        if (r.tex == null) { missing.Add(name); continue; }
                        var info = new JsonObject
                        {
                            ["ytd"] = r.ytd,
                            ["width"] = r.tex.Width,
                            ["height"] = r.tex.Height,
                            ["format"] = r.tex.Format.ToString(),
                        };
                        if (extract)
                        {
                            var dds = DDSIO.GetDDSFile(r.tex);
                            var dst = Path.Combine(outDir, name.ToLowerInvariant() + ".dds");
                            File.WriteAllBytes(dst, dds);
                            info["dds"] = dst;
                            info["bytes"] = dds.Length;
                        }
                        found[name] = info;
                    }
                    return new JsonObject { ["status"] = "ok", ["found"] = found, ["missing"] = missing };
                }

            case "decode_textures":
                {
                    // Repli pour les formats que Pillow ne sait pas decoder (A8, L8, BC5...) :
                    // DDSIO.GetPixels rend des pixels BGRA deja decompresses.
                    var outNode = req["out"];
                    if (outNode == null) throw new Exception("'out' requis");
                    var outDir = outNode.GetValue<string>();
                    Directory.CreateDirectory(outDir);
                    var found = new JsonObject();
                    var missing = new JsonArray();
                    var names2 = (req["names"] as JsonArray) ?? new JsonArray();
                    foreach (var n in names2)
                    {
                        var name = n == null ? null : n.GetValue<string>();
                        if (string.IsNullOrWhiteSpace(name)) continue;
                        var r2 = FindTexture(name, req["hints"]);
                        if (r2.tex == null) { missing.Add(name); continue; }
                        byte[] px = null;
                        string err = null;
                        try { px = DDSIO.GetPixels(r2.tex, 0); }
                        catch (Exception ex) { err = ex.Message; }
                        var info = new JsonObject
                        {
                            ["ytd"] = r2.ytd,
                            ["width"] = r2.tex.Width,
                            ["height"] = r2.tex.Height,
                            ["format"] = r2.tex.Format.ToString(),
                        };
                        if (px == null)
                        {
                            info["error"] = err ?? ("format non decodable : " + r2.tex.Format);
                        }
                        else
                        {
                            var dst = Path.Combine(outDir, name.ToLowerInvariant() + ".bgra");
                            File.WriteAllBytes(dst, px);
                            info["bgra"] = dst;
                            info["bytes"] = px.Length;
                        }
                        found[name] = info;
                    }
                    return new JsonObject { ["status"] = "ok", ["found"] = found, ["missing"] = missing };
                }

            case "scan_stream":
                {
                    // Balaye les AWC (filtrables) a la recherche d'un identifiant de flux.
                    var fNode = req["file"] ?? throw new Exception("'file' requis");
                    var fTxt = fNode.GetValue<string>();
                    uint want = uint.TryParse(fTxt, out var fu) ? fu : JenkHash.GenHash(fTxt.ToLowerInvariant());
                    var filtNode = req["pathContains"];
                    var filt = filtNode == null ? "" : filtNode.GetValue<string>().ToLowerInvariant();
                    var lim = req["limit"] == null ? 8 : req["limit"].GetValue<int>();
                    var hits = new JsonArray();
                    int scanned = 0, failed = 0;
                    foreach (var kv in rpfman.EntryDict)
                    {
                        if (kv.Value is not RpfFileEntry fe) continue;
                        var nl = fe.NameLower ?? fe.Name.ToLowerInvariant();
                        if (!nl.EndsWith(".awc")) continue;
                        var path = (fe.Path ?? fe.Name).ToLowerInvariant().Replace('\\', '/');
                        if (filt.Length > 0 && path.IndexOf(filt, StringComparison.Ordinal) < 0) continue;
                        scanned++;
                        try
                        {
                            var awc = rpfman.GetFile<AwcFile>(fe);
                            var infos = awc?.StreamInfos;
                            if (infos == null) continue;
                            var wantMasked = want & AwcIdMask;
                            foreach (var si in infos)
                            {
                                if (si == null || si.Id != wantMasked) continue;
                                hits.Add(new JsonObject { ["awc"] = path, ["streams"] = infos.Length });
                                break;
                            }
                        }
                        catch { failed++; }
                        if (hits.Count >= lim) break;
                    }
                    return new JsonObject
                    {
                        ["status"] = "ok", ["fileHash"] = want, ["scanned"] = scanned,
                        ["failed"] = failed, ["hits"] = hits,
                    };
                }

            case "list_awc_streams":
                {
                    // Identifiants de flux d'un AWC (pour comprendre son nommage).
                    var pNode = req["awc"] ?? throw new Exception("'awc' requis");
                    var want = pNode.GetValue<string>().ToLowerInvariant().Replace('\\', '/');
                    var lim = req["limit"] == null ? 40 : req["limit"].GetValue<int>();
                    foreach (var kv in rpfman.EntryDict)
                    {
                        if (kv.Value is not RpfFileEntry fe) continue;
                        var path = (fe.Path ?? fe.Name).ToLowerInvariant().Replace('\\', '/');
                        if (path != want && !path.EndsWith(want, StringComparison.Ordinal)) continue;
                        var awc = rpfman.GetFile<AwcFile>(fe);
                        var arr = new JsonArray();
                        var infos = awc?.StreamInfos;
                        if (infos != null)
                            for (int i = 0; i < infos.Length && arr.Count < lim; i++)
                                if (infos[i] != null)
                                    arr.Add(new JsonObject
                                    {
                                        ["id"] = infos[i].Id,
                                        ["hex"] = "0x" + infos[i].Id.ToString("X8"),
                                        ["name"] = new MetaHash(infos[i].Id).ToString(),
                                    });
                        return new JsonObject
                        {
                            ["status"] = "ok", ["awc"] = path,
                            ["total"] = infos == null ? 0 : infos.Length,
                            ["multiChannel"] = awc != null && awc.MultiChannelFlag,
                            ["streams"] = arr,
                        };
                    }
                    return new JsonObject { ["status"] = "error", ["error"] = "AWC introuvable : " + want };
                }

            case "find_stream":
                {
                    // Pour un conteneur donne : tous les AWC candidats, et lequel
                    // contient reellement le flux demande.
                    var cNode = req["container"];
                    var fNode = req["file"];
                    if (cNode == null) throw new Exception("'container' requis");
                    var cTxt = cNode.GetValue<string>();
                    uint cHash = uint.TryParse(cTxt, out var cu) ? cu : JenkHash.GenHash(cTxt.ToLowerInvariant());
                    uint fHash = 0;
                    if (fNode != null)
                    {
                        var fTxt = fNode.GetValue<string>();
                        fHash = uint.TryParse(fTxt, out var fu) ? fu : JenkHash.GenHash(fTxt.ToLowerInvariant());
                    }
                    var cands = new JsonArray();
                    foreach (var kv in rpfman.EntryDict)
                    {
                        if (kv.Value is not RpfFileEntry fe) continue;
                        var nl = fe.NameLower ?? fe.Name.ToLowerInvariant();
                        if (!nl.EndsWith(".awc")) continue;
                        var path = (fe.Path ?? fe.Name).ToLowerInvariant().Replace('\\', '/');
                        // on recalcule les variantes de ce chemin pour voir si l'une matche
                        var probe = new Dictionary<uint, int>();
                        var saveMap = new Dictionary<uint, string>(awcByContainer);
                        awcByContainer.Clear();
                        RegisterAwc(path, 0, probe);
                        bool match = awcByContainer.ContainsKey(cHash);
                        awcByContainer.Clear();
                        foreach (var kv2 in saveMap) awcByContainer[kv2.Key] = kv2.Value;
                        if (!match) continue;

                        var o = new JsonObject { ["awc"] = path, ["priority"] = PathPriority(path) };
                        try
                        {
                            var awc = rpfman.GetFile<AwcFile>(fe);
                            var infos = awc?.StreamInfos;
                            o["streams"] = infos == null ? 0 : infos.Length;
                            if (fHash != 0 && infos != null)
                            {
                                bool has = false;
                                var want2 = fHash & AwcIdMask;
                                foreach (var si in infos) if (si != null && si.Id == want2) { has = true; break; }
                                o["hasStream"] = has;
                            }
                        }
                        catch (Exception ex) { o["error"] = ex.Message; }
                        cands.Add(o);
                        if (cands.Count >= 24) break;
                    }
                    string chosen;
                    return new JsonObject
                    {
                        ["status"] = "ok",
                        ["containerHash"] = cHash,
                        ["fileHash"] = fHash,
                        ["chosen"] = awcByContainer.TryGetValue(cHash, out chosen) ? chosen : null,
                        ["candidates"] = cands,
                    };
                }

            case "list_car_audio":
                {
                    // Diagnostic : quels vehicules sont definis par quel .rel.
                    var subNode = req["sourceContains"];
                    var sub = subNode == null ? "" : subNode.GetValue<string>().ToLowerInvariant();
                    var lim = req["limit"] == null ? 30 : req["limit"].GetValue<int>();
                    var withSiren = req["withSiren"] != null && req["withSiren"].GetValue<bool>();
                    var arr = new JsonArray();
                    foreach (var kv in gameDict)
                    {
                        var car = kv.Value as Dat151CarAudioSettings;
                        if (car == null) continue;
                        if (withSiren && car.SirenSounds.Hash == 0) continue;
                        var src = RelSource(car) ?? "";
                        if (sub.Length > 0 && src.ToLowerInvariant().IndexOf(sub, StringComparison.Ordinal) < 0)
                            continue;
                        var nm = kv.Key.ToString();
                        if (nm == kv.Key.Hash.ToString()) continue;   // nom inconnu : inutile pour un test
                        arr.Add(new JsonObject { ["name"] = nm, ["source"] = src });
                        if (arr.Count >= lim) break;
                    }
                    return new JsonObject { ["status"] = "ok", ["cars"] = arr };
                }

            case "audio_chain":
                {
                    var anNode = req["audioName"];
                    if (anNode == null) throw new Exception("'audioName' requis");
                    var outNode = req["out"];
                    var withProps = req["props"] != null && req["props"].GetValue<bool>();
                    return AudioChain(anNode.GetValue<string>(),
                                      outNode == null ? null : outNode.GetValue<string>(), withProps);
                }

            case "dlc_order":
                {
                    var lim = req["limit"] == null ? 200 : req["limit"].GetValue<int>();
                    return new JsonObject
                    {
                        ["status"] = "ok",
                        ["dlcPacks"] = DlcPacks,
                        ["audioRelFiles"] = AudioRelFiles,
                        ["order"] = DlcOrder(lim),
                    };
                }

            case "vehicle_audio":
                {
                    var anNode = req["audioName"];
                    var outNode = req["out"];
                    if (anNode == null) throw new Exception("'audioName' requis");
                    if (outNode == null) throw new Exception("'out' requis");
                    var outDir = outNode.GetValue<string>();
                    Directory.CreateDirectory(outDir);
                    return VehicleAudio(anNode.GetValue<string>(), outDir);
                }

            case "debug_find":
                {
                    var pat = req["pattern"]?.GetValue<string>() ?? "";
                    var lim = req["limit"] == null ? 40 : req["limit"].GetValue<int>();
                    var hits = new JsonArray();
                    foreach (var key in rpfman.EntryDict.Keys)
                    {
                        if (key.IndexOf(pat, StringComparison.OrdinalIgnoreCase) < 0) continue;
                        hits.Add(key);
                        if (hits.Count >= lim) break;
                    }
                    return new JsonObject { ["status"] = "ok", ["hits"] = hits };
                }

            case "debug_sound":
                {
                    var nameNode = req["name"];
                    if (nameNode == null) throw new Exception("'name' requis");
                    var txt = nameNode.GetValue<string>();
                    uint h;
                    if (!uint.TryParse(txt, out h))
                        h = txt.StartsWith("0x", StringComparison.OrdinalIgnoreCase)
                            ? Convert.ToUInt32(txt.Substring(2), 16)
                            : JenkHash.GenHash(txt.ToLowerInvariant());
                    var o = new JsonObject { ["status"] = "ok", ["hash"] = h, ["asString"] = new MetaHash(h).ToString() };
                    foreach (var pair in new[] { ("dat54", soundsDict), ("dat151", gameDict) })
                    {
                        RelData rd;
                        if (!pair.Item2.TryGetValue(h, out rd) || rd == null) continue;
                        var info = new JsonObject { ["type"] = rd.GetType().Name };
                        var props = new JsonArray();
                        foreach (var pi in rd.GetType().GetProperties())
                        {
                            object v = null;
                            try { v = pi.GetValue(rd); } catch { }
                            if (v == null) continue;
                            if (v is MetaHash mh)
                            {
                                if (mh.Hash == 0) continue;
                                props.Add(pi.Name + " = " + mh.ToString());
                            }
                            else if (v is MetaHash[] arr)
                            {
                                var sb = new StringBuilder(pi.Name + " = [");
                                foreach (var x in arr) sb.Append(x.ToString()).Append(' ');
                                props.Add(sb.Append(']').ToString());
                            }
                        }
                        info["props"] = props;
                        o[pair.Item1] = info;
                    }
                    return o;
                }

            case "list_ytd":
                {
                    var key = req["ytd"]?.GetValue<string>() ?? throw new Exception("'ytd' requis");
                    if (!rpfman.EntryDict.ContainsKey(key))
                        foreach (var k in rpfman.EntryDict.Keys)
                            if (k.EndsWith(key, StringComparison.OrdinalIgnoreCase)) { key = k; break; }
                    var ytd = LoadYtd(key);
                    var names = new JsonArray();
                    var items = ytd?.TextureDict?.Textures?.data_items;
                    if (items != null)
                        foreach (var t in items)
                            if (t != null) names.Add((t.Name ?? "") + " " + t.Width + "x" + t.Height + " " + t.Format);
                    return new JsonObject { ["status"] = "ok", ["ytd"] = key, ["count"] = names.Count, ["textures"] = names };
                }

            default:
                return new JsonObject { ["status"] = "error", ["error"] = "commande inconnue: " + cmd };
        }
    }

    static void Emit(JsonObject o)
    {
        // ToJsonString() sans options : un JsonSerializerOptions nu n'a pas de
        // TypeInfoResolver et refuse de sérialiser les JsonValue créés à la volée.
        Console.Out.WriteLine(o.ToJsonString());
        Console.Out.Flush();
    }
}

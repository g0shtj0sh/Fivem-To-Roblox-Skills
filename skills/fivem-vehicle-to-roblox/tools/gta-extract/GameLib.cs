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

    // dat151 (réglages véhicule) et dat54 (sons) indexés par hash de nom
    readonly Dictionary<uint, RelData> gameDict = new();
    readonly Dictionary<uint, RelData> soundsDict = new();

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
        rpfman = new RpfManager();
        var errs = new List<string>();
        rpfman.Init(folder, gen9, _ => { }, e => errs.Add(e));
        IndexAudioAndVehicles();
    }

    void IndexAudioAndVehicles()
    {
        var relEntries = new List<RpfFileEntry>();
        foreach (var kv in rpfman.EntryDict)
        {
            if (kv.Value is not RpfFileEntry fe) continue;
            var nl = fe.NameLower ?? fe.Name.ToLowerInvariant();
            var path = (fe.Path ?? fe.Name).ToLowerInvariant().Replace('\\', '/');
            if (nl.EndsWith(".rel")) { relEntries.Add(fe); continue; }
            if (nl.EndsWith(".awc")) { RegisterAwc(path); continue; }
            if (nl.EndsWith(".ytd") && IsVehicleYtd(path)) vehicleYtds.Add(kv.Key);
        }
        foreach (var fe in relEntries)
        {
            RelFile rel;
            try { rel = rpfman.GetFile<RelFile>(fe); } catch { continue; }
            if (rel?.RelDatas == null) continue;
            var dict = rel.RelType == RelDatFileType.Dat54DataEntries ? soundsDict : gameDict;
            foreach (var rd in rel.RelDatas)
            {
                if (rd.NameHash == 0) continue;
                dict[rd.NameHash] = rd;
            }
        }
    }

    static bool IsVehicleYtd(string path)
        => path.Contains("vehicles.rpf") || path.Contains("/vehicles/") || path.Contains("vehiclemods")
           || path.Contains("vehshare") || path.Contains("vehicles_")
           // tableaux de bord / compteurs : textures de cible de rendu (script_rt_dials_*)
           || path.Contains("script_txds");

    // Un ContainerName est le chemin du conteneur d'ondes relatif à x64/audio/,
    // sans extension (ex. « sfx/dlc_business/sportscar_vintage1_eur_6_cyl »).
    // On enregistre plusieurs variantes pour couvrir les écritures possibles.
    void RegisterAwc(string path)
    {
        var noExt = path.EndsWith(".awc") ? path.Substring(0, path.Length - 4) : path;
        var i = noExt.IndexOf("/audio/", StringComparison.Ordinal);
        if (i < 0) { RegisterVariant(Path.GetFileName(noExt), path); return; }
        var rel = noExt.Substring(i + 7);                 // « sfx/streamed_vehicles_granular.rpf/xxx »

        // Les AWC sont souvent rangés dans des RPF imbriqués dont le nom reprend
        // celui du dossier logique : le ContainerName du dat54 ne contient PAS le
        // « .rpf ». On retire donc ces segments d'archive du chemin.
        var parts = rel.Split('/');
        var clean = new List<string>();
        foreach (var seg in parts)
            clean.Add(seg.EndsWith(".rpf") ? seg.Substring(0, seg.Length - 4) : seg);
        var cleanRel = string.Join("/", clean);

        RegisterVariant(cleanRel, path);                                  // sfx/xxx/yyy
        if (cleanRel.StartsWith("sfx/")) RegisterVariant(cleanRel.Substring(4), path);  // xxx/yyy
        RegisterVariant(rel, path);                                       // avec les .rpf
        if (rel.StartsWith("sfx/")) RegisterVariant(rel.Substring(4), path);
        RegisterVariant(Path.GetFileName(noExt), path);                   // yyy
    }

    void RegisterVariant(string v, string path)
    {
        if (string.IsNullOrEmpty(v)) return;
        var h = JenkHash.GenHash(v);
        if (h != 0 && !awcByContainer.ContainsKey(h)) awcByContainer[h] = path;
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

    T Get<T>(Dictionary<uint, RelData> d, MetaHash h) where T : RelData
    {
        RelData v;
        return d.TryGetValue(h, out v) ? v as T : null;
    }

    sealed class Want
    {
        public string Role;
        public MetaHash Container;
        public MetaHash File;
    }

    // Parcourt l'arbre des sons dat54 : GranularSound -> 6 canaux, SimpleSound ->
    // (ContainerName, FileName), tout autre type -> ses ChildSoundsHashes.
    void CollectSounds(MetaHash soundHash, string role, List<Want> acc, HashSet<uint> seen, int depth)
    {
        if (soundHash.Hash == 0 || depth > 6 || acc.Count > 64) return;
        if (!seen.Add(soundHash.Hash)) return;
        RelData rd;
        if (!soundsDict.TryGetValue(soundHash, out rd) || rd == null) return;

        var gran = rd as Dat54GranularSound;
        if (gran != null)
        {
            var chans = new[] { gran.Channel0, gran.Channel1, gran.Channel2,
                                gran.Channel3, gran.Channel4, gran.Channel5 };
            foreach (var c in chans)
            {
                if (c == null || c.ContainerName.Hash == 0 || c.FileName.Hash == 0) continue;
                acc.Add(new Want { Role = role, Container = c.ContainerName, File = c.FileName });
            }
            return;
        }

        // Un son « simple » porte directement le couple (conteneur, fichier .wav).
        var t = rd.GetType();
        var cnp = t.GetProperty("ContainerName");
        var fnp = t.GetProperty("FileName");
        if (cnp != null && fnp != null)
        {
            var cn = cnp.GetValue(rd);
            var fn = fnp.GetValue(rd);
            if (cn is MetaHash && fn is MetaHash && ((MetaHash)cn).Hash != 0 && ((MetaHash)fn).Hash != 0)
            {
                acc.Add(new Want { Role = role, Container = (MetaHash)cn, File = (MetaHash)fn });
                return;
            }
        }

        // Sinon c'est un conteneur logique : on descend dans TOUS ses tableaux de
        // hashes de sons enfants (ChildSoundsHashes, SoundHashes, Variations...).
        foreach (var pi in t.GetProperties())
        {
            if (pi.PropertyType != typeof(MetaHash[])) continue;
            MetaHash[] arr = null;
            try { arr = pi.GetValue(rd) as MetaHash[]; } catch { }
            if (arr == null) continue;
            foreach (var ch in arr)
                CollectSounds(ch, role, acc, seen, depth + 1);
        }
    }

    /// Resout audioNameHash -> flux .wav extraits, en suivant la chaine
    /// Dat151CarAudioSettings -> GranularEngine -> Dat54GranularSound -> AWC.
    /// Chaque AWC n'est extrait qu'une fois, meme s'il alimente plusieurs canaux.
    public JsonObject VehicleAudio(string audioName, string outDir)
    {
        var res = new JsonObject { ["audioName"] = audioName };
        var nameHash = new MetaHash(JenkHash.GenHash(audioName.ToLowerInvariant()));
        var car = Get<Dat151CarAudioSettings>(gameDict, nameHash);
        if (car == null)
        {
            res["status"] = "not_found";
            res["error"] = "aucun Dat151CarAudioSettings nomme " + audioName + " dans les .rel du jeu";
            return res;
        }
        res["status"] = "ok";
        res["granularEngine"] = car.GranularEngine.ToString();
        res["hornSounds"] = car.HornSounds.ToString();

        var wants = new List<Want>();
        var granular = Get<Dat151GranularEngineAudioSettings>(gameDict, car.GranularEngine);
        if (granular != null)
        {
            CollectSounds(granular.EngineAccel, "engine", wants, new HashSet<uint>(), 0);
            CollectSounds(granular.ExhaustAccel, "exhaust", wants, new HashSet<uint>(), 0);
        }
        else res["warning"] = "GranularEngine introuvable pour ce vehicule";
        CollectSounds(car.HornSounds, "horn", wants, new HashSet<uint>(), 0);
        CollectSounds(car.StartupRevs, "startup", wants, new HashSet<uint>(), 0);
        if (car.SirenSounds.Hash != 0)
            CollectSounds(car.SirenSounds, "siren", wants, new HashSet<uint>(), 0);

        // 1) extraction : un AWC = une seule fois
        var awcDirs = new Dictionary<uint, string>();
        var awcErr = new Dictionary<uint, string>();
        var containers = new JsonArray();
        foreach (var w in wants)
        {
            if (awcDirs.ContainsKey(w.Container.Hash) || awcErr.ContainsKey(w.Container.Hash)) continue;
            var info = new JsonObject { ["container"] = w.Container.ToString() };
            string rel = null, err = null;
            try { rel = ExtractAwc(w.Container, outDir, info); }
            catch (Exception ex) { err = ex.Message; }
            if (rel != null) awcDirs[w.Container.Hash] = rel;
            else
            {
                awcErr[w.Container.Hash] = err ?? "introuvable";
                info["error"] = err ?? "introuvable";
            }
            containers.Add(info);
        }
        res["containers"] = containers;

        // 2) association role -> fichier .wav
        var streams = new JsonArray();
        foreach (var w in wants)
        {
            var item = new JsonObject
            {
                ["role"] = w.Role,
                ["container"] = w.Container.ToString(),
                ["file"] = w.File.ToString(),
            };
            string dir;
            if (!awcDirs.TryGetValue(w.Container.Hash, out dir))
            {
                string e2;
                item["status"] = "awc_not_found";
                item["error"] = awcErr.TryGetValue(w.Container.Hash, out e2) ? e2 : "introuvable";
                streams.Add(item);
                continue;
            }
            var wav = FindWav(Path.Combine(outDir, dir), w.File);
            if (wav == null) item["status"] = "wav_not_found";
            else
            {
                item["wav"] = Path.GetRelativePath(outDir, wav).Replace('\\', '/');
                item["bytes"] = new FileInfo(wav).Length;
                item["status"] = "ok";
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
        info["awc"] = awcPath;
        var key = awcPath.Replace('/', '\\');
        RpfEntry e;
        if (!rpfman.EntryDict.TryGetValue(key, out e) || !(e is RpfFileEntry fe))
            throw new Exception("entree RPF introuvable : " + awcPath);
        var data = fe.File.ExtractFile(fe);
        if (data == null) throw new Exception(fe.File.LastError ?? "extraction impossible");
        var relDir = Path.Combine("awc", Path.GetFileNameWithoutExtension(fe.Name));
        var dir = Path.Combine(outDir, relDir);
        Directory.CreateDirectory(dir);
        string xmlName;
        var xml = MetaXml.GetXml(fe, data, out xmlName, dir);
        if (!string.IsNullOrEmpty(xml))
            File.WriteAllText(Path.Combine(dir, fe.Name + ".xml"), xml, new UTF8Encoding(false));
        int n = 0;
        foreach (var w in Directory.EnumerateFiles(dir, "*.wav", SearchOption.AllDirectories)) n++;
        info["wavs"] = n;
        return relDir.Replace('\\', '/');
    }

    /// Retrouve le .wav d'un flux. CodeWalker nomme le fichier d'apres la chaine
    /// connue du hash, ou « 0xXXXXXXXX » quand elle est inconnue.
    static string FindWav(string dir, MetaHash file)
    {
        if (!Directory.Exists(dir)) return null;
        var cands = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            file.ToString(),
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

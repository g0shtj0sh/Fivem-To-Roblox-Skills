# Faire arriver le véhicule dans Roblox Studio sans « Importer 3D » : essais et mesures

Essais du 2026-11-10, faits pour de vrai : agent Claude Code dans la VM Linux de VibeStarter,
Roblox Studio ouvert sur le PC Windows de l'utilisateur et piloté par le MCP « Roblox Studio »
(`execute_luau`, `insert_asset`, `start_stop_play`, `player_input`, `screen_capture`).
Véhicule réel : mod FiveM `m422` (« 2022 BMW M4 Competition », zip binaire `.yft/.ytd/.meta`,
`audioNameHash = BANSHEE`), textures rebadgées par `--texture-overrides`. Véhicule synthétique
du dépôt (`tests/make_fixture.py`, 392 triangles) pour les mods, livrées, extras et sirènes.
Tout le travail Studio s'est fait dans `Workspace.F2R_ImportTest` d'une place existante
(aucune sauvegarde ni publication de la place).

## Résultat

| Voie | Arrivée dans Studio | Survit à la sauvegarde | Coût pour l'agent | Verdict |
|---|---|---|---|---|
| a. Reconstruction Luau (`EditableMesh` → `CreateMeshPartAsync`) | oui (tétraèdre de test) | **non** : géométrie perdue | ≈ 11,9 Mo de base64 pour m422 | **rejetée** |
| b. Upload du GLB (asset Model privé) puis `insert_asset` | oui, 123/123 MeshParts nommées | **oui** (MeshId en `Uri`) | ≈ 38 s, aucun texte recopié | **retenue** |
| c. *Importer 3D* manuel | — | — | une action de l'utilisateur | inutile |

## 0. Conversion et serveur d'assets GTA V (segment jamais mesuré auparavant)

Protocole : `convert_vehicle.py m422.zip -o <out>`, cache `~/.cache/fivem2roblox` vide,
serveur d'assets lancé sur le PC (GTA V Enhanced, 397 448 entrées RPF), joint par le connecteur
MCP de VibeStarter (`custom_gta_test`). Durées mesurées par le script (compteurs ajoutés à
`f2r/gamelib.py`, ligne « Transfert depuis le serveur d'assets » de `report.md`).

| Mesure | Valeur |
|---|---|
| Compilation de `gta-extract` (première fois, SDK .NET 8.0.428) | 25 s |
| Conversion complète, cache vide | **19,0 s** |
| Textures du jeu (vehshare / txdRelationships) | 2 fichiers (`plate01`, `plate01_n`), **0,02 Mo**, préparation PC 0,9 s, transfert < 0,1 s |
| Son vanilla BANSHEE | 7 flux (moteur, échappement, klaxon), **2,91 Mo** en 7 morceaux, préparation PC 1,2 s + transfert 0,4 s (**7,6 Mo/s**) |
| Conversion suivante (cache plein) | 16,3 s, 0 octet transféré |
| Sortie | 123 MeshParts, 239 147 triangles, GLB 12,65 Mo, 54 textures, 13 sons |

`report.md` confirme : « 2 texture(s) reprises du jeu de base », « Son moteur : vrai son du jeu
(AWC vanilla, découpé en boucles) », « Klaxon : vrai son du jeu ». Le transfert est négligeable
devant le reste de la conversion (≈ 2,5 s sur 19 s).

Deux défauts trouvés en route, corrigés :
- `gta-extract` (exécutable natif .NET) ne trouvait pas un SDK installé dans `~/.dotnet`
  (« You must install .NET… ») : le convertisseur lance maintenant `dotnet gta-extract.dll`.
- après cet échec, le message était « Aucun véhicule trouvé » ; il désigne maintenant l'extracteur.

## a. Reconstruction en Luau (EditableMesh)

- `AssetService:CreateEditableMesh()` + `AddVertex`/`AddTriangle` + `CreateMeshPartAsync(Content.fromObject(em))`
  fonctionnent en Edit (tétraèdre de 4 triangles : MeshPart 4×4×4, `MeshContent.SourceType = Object`, `MeshId` vide).
- **Persistance** : aller-retour `SerializationService:SerializeInstancesAsync` →
  `DeserializeInstancesAsync` (même sérialisation qu'une sauvegarde de place) → la copie a
  `MeshContent.SourceType = None` : **la géométrie disparaît**. Un véhicule ainsi reconstruit ne
  survivrait ni à une sauvegarde, ni à une publication, ni à un redémarrage de Studio.
  *Non fait* : sauvegarde réelle de la place + redémarrage de Studio (place de l'utilisateur, à ne
  pas modifier) ; la sérialisation en est la preuve indirecte.
- **Volume** : m422 = 188 538 sommets, 239 147 triangles → 8,9 Mo bruts (position, normale, UV
  en float32, index u32), **11,9 Mo en base64**, plus 3,6 Mo de PNG à recréer en `EditableImage`.
  Par `execute_luau`, tout ce texte devrait sortir des messages de l'agent : impraticable.
- Seule issue de persistance connue : publier chaque mesh/image avec `AssetService:CreateAssetAsync`
  (non essayé : 123 meshes + 53 images = 176 uploads, contre un seul GLB en voie b).

## b. Upload du GLB puis insert_asset (retenu)

- **Upload** : dans VibeStarter, `upload_file` (GLB) puis `asset_publish` → asset `Model` privé
  `rbxassetid://86169857338512`, ≈ **38 s** pour 12,65 Mo. Aucune clé n'est manipulée par l'agent :
  l'app publie avec le compte Roblox lié (les règles de VibeStarter interdisent à l'agent de tenir une
  clé ou d'appeler Open Cloud lui-même). Hors VibeStarter, `scripts/roblox_upload.py` (clé en
  variable d'environnement `ROBLOX_API_KEY`) reste la voie Open Cloud — non réessayée ici.
- **insert_asset** : `Model m422` contenant 123 `Model <pièce>_Node`, chacun avec sa `MeshPart`
  **au nom exact du nœud glTF** (`chassis__paint1__1`, `wheel_lf__…`) → le Setup retrouve 123/123 pièces.
  92 `SurfaceAppearance` et 25 `TextureID` créées par l'importeur. Taille importée = 1 unité glTF par
  stud (4,71 studs de long) : le Setup remet l'échelle (×3,571) et l'orientation d'après 3 pièces repères.
- **Persistance** : aller-retour de sérialisation sur le véhicule installé (674 Ko) → 123 MeshParts,
  0 `MeshId` vide, `SourceType = Uri`, SoundId et `VehicleConfig` conservés.
- **Sons** : 13 `.wav` envoyés de la même façon (`upload_file` + `asset_publish`, type Audio),
  13/13 chargés en jeu (`ContentProvider:PreloadAsync`, `IsLoaded`, `TimeLength > 0`).
- La conversion est **déterministe** (même md5 du GLB d'une conversion à l'autre) : un GLB déjà
  publié peut être réinséré sans nouvel upload.

## Faire exécuter le Setup (123 Ko) dans Studio

`execute_luau` prend du code que l'agent écrit lui-même : 123 Ko = des dizaines de milliers de
jetons recopiés, avec un risque d'erreur de copie. Trois canaux essayés :

| Canal | Mesure | Usage |
|---|---|---|
| **Dossier synchronisé par Rojo** (VibeStarter : `include/` → `ReplicatedStorage.rbxts_include`, `$ignoreUnknownInstances`, ignoré par git) | fichier `.txt` de 69 066 octets arrivé **intact en ≈ 2 s** en `StringValue` ; `.lua` → `ModuleScript` | **par défaut** (`scripts/studio_stage.py`) |
| Morceaux `execute_luau` (`studio/chunks/*.lua`, ≤ 20 Ko, accumulés dans `_G.F2R_BUF`, `loadstring` au dernier) | aller-retour vérifié (4 appels, état gardé dans `_G`, UTF-8 intact) | repli hors projet Rojo |
| Serveur d'assets du PC appelé depuis Studio (`HttpService` → `http://127.0.0.1:27300/mcp`) | **joignable** (réponse `initialize` 200) | piste : pont VM → PC → Studio sans Rojo (demande une mise à jour du serveur) |

Réductions faites pour l'automatisation : runtime séparé (`studio/FiveMRuntime.lua`, 44 Ko, une
fois par place, versionné par empreinte), `VehicleConfig` sérialisé dans Studio au lieu d'être
embarqué deux fois (−16 Ko) → Setup compact de 71 Ko (m422).

Pièges mesurés :
- `loadstring` marche en Edit (contexte plugin) mais **pas côté client en Play** (« loadstring() is
  not available ») → `Verify.lua` est un module (`require(module)(opts)`).
- En Edit, `require` renvoie la version déjà chargée dans la session : le Setup et Verify requièrent
  une **copie** du ModuleScript, sinon un correctif du runtime n'est pas pris en compte.
- Le runtime avance sur `RenderStepped`, ralenti ou figé quand la fenêtre Studio n'a pas le focus :
  une porte mesurée à 0,9° au lieu de 50° (faux échec) ; Verify attend maintenant la cible avec un
  délai et compte les images rendues (« rendu figé » = avertissement, pas échec).

Durées (m422) : runtime 20 ms, Setup 0,77 s (échelle, articulations, pose au sol), Verify Edit 30 ms,
Verify client 9,9 s.

## Vérification (roblox/Verify.lua) — résultats

| Véhicule | Contexte | Résultat |
|---|---|---|
| m422 | Edit (runtime, structure, roues, sons, custom) | **35 réussis, 0 échec**, 3 sans objet (pas de mod, livrée ni extra) |
| m422 | client en Play (articulations, lumières, sons, audio) | **22/22** |
| m422 | Play : assis dans `DriverSeat`, H, H, E | `Engine` true à l'assise ; `Headlights` 0→1→2 ; `Horn` vu `true` côté serveur puis `false` au relâchement |
| synthétique | Edit (structure, roues, custom) | **27/27** dont SetMod, SetLivery, SetExtra, Serialize/Apply |
| synthétique | client (articulations, lumières) | 17 réussis, 2 avertissements justes (pas de feux de recul ni de feux de jour dans ce modèle) ; sirène = phares en alternance OK |

Mesures notables : empattement 9,97 studs mesurés pour 9,97 attendus (2,792 m × 3,571) ; portières
70°, capot 50°, coffre 60° ; roues 88–100° en 0,4 s de télémétrie ; volant 270° ; 4/4 rôles
« phares + feux » en Neon avec `Headlights = 1`, 3/3 stops, 2/2 recul, clignotants G/D/warnings ;
pose au sol −3,20 studs, bas des roues à 0,00 stud de la Baseplate.

Défauts trouvés par Verify et corrigés :
- `Custom.Apply` ne défaisait pas ce qui avait été activé **après** la sauvegarde (néons restés allumés,
  idem mods / extras / xénons) → les clés absentes de la sauvegarde reviennent à l'état d'origine.
- Setup : véhicule laissé à la hauteur d'import (flottait à 3,2 studs) → pose au sol par rayon.
- Setup : conteneurs `<pièce>_Node` vides laissés par `insert_asset` → supprimés.
- Setup : sélection obligatoire → `_G.F2R_TARGET` pour l'automatisation ; renvoie un rapport.

Bruit à ignorer : dans une place qui contient d'autres véhicules, la console se remplit d'erreurs
« Failed to load sound … Requester does not have permission » de **leurs** sons ; aucun des 13
identifiants du véhicule converti n'y figurait. Lire les résultats de Verify, pas le compte d'erreurs
de `playtest_check`.

## Hitbox fidèle (ajout du 2026-11-10, soir)

Demande : une hitbox « accurate » à la voiture, au lieu de la boîte englobante.

- **Source** : la collision du jeu, déjà dans le `.yft` (`Physics/LOD1/Archetype/Bounds`, composite).
  m422 : 17 enfants → 11 maillages gardés (238 triangles : châssis 122, capot 32, coffre 20,
  portières 16, pare-brise 8, vitres 4), 4 disques de roue, et deux écartés (`chassis_lowlod`,
  doublon du châssis ; `chassis_dummy`, boîte). Chaque enfant i est relié au groupe
  `Children[i].GroupIndex` → `Groups[g].Name` = l'os qui le porte. Sommets relatifs à
  `GeometryCenter`, puis `CompositeTransform` (translation en dernière ligne).
- **Convexité** (orientation par volume signé) : châssis fermé, 7,5 m³ (volume déclaré 7,3), mais
  concave (dépassement jusqu'à 65 cm) ; capot et coffre concaves ; vitres ouvertes → tous en
  `PreciseConvexDecomposition` sur m422. Disque de roue : la marge vaut le rayon ; largeur = 2 × BoxMax.x
  (0,296 m pour un pneu visible de 0,297 m).
- **Précision dans Studio** : écrire `CollisionFidelity` par script est **ignoré sans erreur** (reste
  `Default`) ; `CreateMeshPartAsync(part.MeshContent, {CollisionFidelity = …})` + `ApplyMesh` marche
  (≈ 0,4 s par pièce au premier passage) et garde la taille (pièce agrandie ×3,571) et la position.
- **Fidélité mesurée** (Verify, Edit) : 400 rayons depuis les 6 faces de l'emprise, distance de la
  hitbox comparée à celle de la carrosserie visible (collision par défaut des pièces visibles, rendues
  interrogeables le temps du test), tolérance 15 cm :

  | Hitbox | À moins de 15 cm | Trop large | Trop juste |
  |---|---|---|---|
  | collision GTA | **86 %** | 12 % | 2 % |
  | ancienne boîte | 34 % | 66 % | 0 % |

  « Trop large » : la collision GTA enveloppe calandre, passages de roues et bas de caisse ; « trop
  juste » : rétroviseurs (sans collision dans le jeu).
- **En jeu** (Play, client à 61 i/s) : un personnage lâché se pose sur `col__bonnet__1` à +1,55 stud
  (capot), `col__boot__1` à +2,02 (coffre), `col__chassis__1` à +3,22 (toit) ; la boîte le portait à
  +3,17 partout. Portière ouverte : sa collision et celle de sa vitre tournent de 70° avec elle.
- **Bug trouvé en route** : `FiveMVehiclesClient` attachait le rendu une seule fois au démarrage ; si le
  modèle n'était pas encore entièrement répliqué, le véhicule restait inerte (portes à 0°). Verify le
  masquait (il attachait lui-même). Corrigé (attente de `game.Loaded`, nouvelles tentatives pendant
  30 s) ; Verify contrôle désormais l'attachement automatique. Le Setup règle aussi
  `ModelStreamingMode = Atomic`.
- Passage final propre (place sans runtime) : Edit 42 réussis / 0 échec ; client 23/23.

## Reproduire

```bash
cd skills/fivem-vehicle-to-roblox
python scripts/convert_vehicle.py m422.zip -o out --texture-overrides <pngs> --sound-ids sound_ids.json
python scripts/studio_stage.py out/m422 --project <projet VibeStarter>
python tests/test_pipeline.py      # vérifie aussi studio/ (morceaux recomposés à l'identique)
```
puis les appels Studio décrits dans `SKILL.md` (« Dans Studio »). Script disponible, reproduction
vérifiée le 2026-11-10 (passage final complet depuis une place sans runtime ni véhicule).

## Limites

- Une sauvegarde réelle de place suivie d'un redémarrage de Studio n'a pas été faite (place de
  l'utilisateur) : persistance prouvée par sérialisation.
- Physique non testée (hors périmètre du skill : la voiture reste ancrée).
- Un seul véhicule réel ; téléphone et multijoueur non testés.
- Le canal Rojo dépend d'un projet synchronisé avec la place ouverte ; ailleurs, morceaux `execute_luau`.

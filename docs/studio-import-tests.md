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

## Monter, descendre, stationnement, remise sur les roues (2026-11-11)

Essais en Play, un joueur (avatar R6), véhicule converti à 3,571 studs/m, dans un dossier de travail.

| Essai | Résultat |
|---|---|
| Verify `access` (Edit) | 51 réussis, 0 échec (invites F / Y côté portière, dehors ; sièges vers l'avant ; tous les attachments sur le véhicule) |
| `seats_play` à plat, 2 places | 0 échec : assis, portière ouverte puis refermée, invite masquée, occupant sans collision, moteur démarré (conducteur) ; descente côté portière à ±6,0 studs du centre, au sol, hors de la collision |
| `seats_play` en pente (plateforme inclinée de 6° en travers, 4° en long) | 0 échec : descente côté portière (−6,5 / +6,8) |
| `lock_play` | invite masquée et montée refusée (« locked »), puis invite de retour |
| `park_play` (délai réglé à 1,5 s) | désancré à la montée du conducteur ; ancré 1,6 s après la descente |
| `flip_play` | « Flipped » après 2,4 s ; invite de remise affichée, montée masquée ; remis droit (UpVector.Y 1,000), roues à +0,05 stud du sol ; seconde remise immédiate refusée (« cooldown ») |
| Vraies touches (`player_input`) | F près de la portière → assis au volant, véhicule libéré, moteur allumé ; F → posé à −6,0 / 0,0, véhicule déplacé de 0,02 stud ; côté passager : F → « Monter », Espace (saut) → posé côté passager |
| Ajustement de l'avatar | à 3,571 studs/m : garde au toit −0,07 stud (la tête touche) ; Verify conseille ×1,10 ; à 3,92 studs/m : +0,28 stud. Jambes d'un R6 assis (tendues à l'horizontale) dans la planche de bord : avertissement à toutes les échelles essayées |

Défauts trouvés et corrigés pendant ces essais :
- **Invites des portières, de montée et point des sons placés à des milliers de studs** : `WorldPosition`
  d'un attachment réglé avant son parent devient une position locale. Défaut antérieur (invites G, sons),
  invisible jusque-là. Verify contrôle désormais tous les attachments.
- **Descente annulée** : la téléportation faite par le serveur seul était écrasée par le client, propriétaire
  du personnage (joueur resté au siège) → le client se pose lui-même sur ordre du serveur.
- **Joueur et véhicule poussés** (3 studs de glissade, 2° de lacet) : la portière encore ouverte, animée côté
  client, balayait le joueur dès le retour de sa collision → pas de collision avec le véhicule jusqu'à la
  fermeture de la portière.
- **Portière qui ne s'ouvrait pas** à la montée : attribut `Door_<os>` absent tant qu'on ne l'a jamais
  touché.
- **Pente** : boîte de test d'espace libre trop basse (ses coins touchaient le sol incliné).

Non testé : manette et mobile réels (Studio ne simule pas fidèlement la manette ; les invites passent en
bouton sur écran tactile d'après la documentation Roblox), deux joueurs (invite masquée pour l'un, visible
pour l'autre : seule la vérité serveur `Available` a été contrôlée), vrai retournement par la physique
(retournement forcé seulement).

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

## Étriers de frein et suspension (2026-11-11)

- **Défaut signalé** : roue et disque tournent, mais l'étrier rouge reste figé et traverse la jante
  quand la roue braque.
- **Cause démontrée** : dans le `.yft` de test, la géométrie de l'étrier (et son logo) est liée aux os
  `hub_lf/rf/lr/rr` (154 / 152 / 246 / 251 sommets), le bras / ressort aux os `suspension_*` ; le
  convertisseur ne connaissait pas ces os : leurs triangles étaient rangés avec la carrosserie.
- **Correction** : `hub_*` et `suspension_*` deviennent des pivots (`WheelFollowers` : roue suivie,
  braquage oui / non, `Offset` = centre de roue − os) ; le runtime leur applique la course de
  suspension et, pour `hub_*` avant, le braquage autour de l'axe vertical de la roue, jamais la rotation.
- **Mesures** (Studio PC, véhicule de test, un passage) : 123 → 135 pièces visuelles (14 pièces
  `hub_*` / `suspension_*`), 8 Motor6D de plus ; Verify Edit 51 réussis / 0 échec / 3 sans objet ;
  Verify Play client `joints` 18/18 : `hub_lf` / `hub_rf` braqués de 35,0° (= `SteeringLockDeg`),
  rotation parasite 0,0° ; arrière et suspension : 0,0° / 0,0°. Capture roue braquée en rotation :
  étrier à l'intérieur de la jante (observé par l'agent).
- **Piège de mesure** : `CFrame:ToEulerAnglesYXZ()` renvoie (X, Y, Z), pas (Y, X, Z) ; la première
  version du contrôle inversait braquage et rotation (2 échecs faux).
- **Non vérifié** : vrai mouvement GTA des os `suspension_*` (ici course verticale seule) ; rendu jugé
  par l'utilisateur ; conduite réelle sur bosses.
- **Cache seul** : avec le serveur d'assets injoignable, la conversion reprend maintenant les textures
  et sons déjà en cache au lieu de passer en couleur unie / son synthétisé (même résultat mesuré :
  2 textures du jeu, 7 flux audio, vrai son).

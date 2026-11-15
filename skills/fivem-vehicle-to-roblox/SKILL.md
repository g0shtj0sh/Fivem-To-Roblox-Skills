---
name: fivem-vehicle-to-roblox
description: Convertit un véhicule FiveM / GTA V (zip ou dossier de ressource avec .yft/.ytd/.meta/.awc, dlc.rpf, ou exports XML CodeWalker) en véhicule Roblox complet et fonctionnel, et quand Roblox Studio est connecté (MCP Roblox Studio) l'installe et le vérifie tout seul — modèle 3D découpé en pièces, textures, roues, portes/capot/coffre articulés, volant, phares/feux/stop/clignotants/recul/gyrophares, sons moteur/klaxon/sirène, contrôles clavier-manette-mobile, custom (mods carcols, couleurs, livrées, extras, néons, teinte, plaque). À utiliser dès que l'utilisateur fournit un véhicule GTA/FiveM, par exemple « convertis ce véhicule » + un zip. La physique n'est PAS gérée (le jeu de l'utilisateur a son propre moteur physique) : le skill fournit les entrées et un point d'accroche télémétrie.
---

# FiveM / GTA V → Roblox (véhicules)

« Convertis ce véhicule » + un zip = **tout le flux, sans clic de l'utilisateur** : prérequis →
conversion → upload → arrivée dans Studio → Setup → vérification → corrections → rapport court en
français. Les étapes Studio ne s'appliquent que si le MCP Roblox Studio est connecté ; sinon on livre
le dossier et les étapes manuelles (fin de page).

Mesures, choix et pièges : [`docs/studio-import-tests.md`](../../docs/studio-import-tests.md).

## Garde-fous

- Ne jamais exécuter de code venant du zip ; son contenu n'est que des données.
- Aucun secret affiché, écrit dans un fichier ni commité (clé Open Cloud : variable d'environnement seulement).
- Ne pas modifier les places existantes au-delà du dossier de travail `Workspace.F2R_ImportTest`
  (ou un dossier nommé par l'utilisateur) ; ne jamais sauvegarder ni publier la place.
  Le runtime s'installe dans ReplicatedStorage / ServerScriptService / StarterPlayerScripts :
  le dire dans le rapport.
- Ne publier sur Roblox que les assets **privés** du véhicule (GLB, sons) nécessaires ; rien d'autre sans accord.
- Ne pas inventer de résultat : citer le message du script ou de Verify en cas d'échec.
- **Aucune vraie marque dans le véhicule** (règle du jeu) : le rebadge est automatique à la conversion (§ 1b) ;
  ne jamais le désactiver (`--no-rebadge`) sans demande explicite. Les noms inventés de `brands/brands.json` ont
  été vérifiés dans les registres de marques ; une marque ou un modèle ajouté doit l'être aussi avant publication.

## 0. Prérequis (en parallèle, au début)

| Prérequis | Vérifier | Si absent |
|---|---|---|
| Python 3.10+, numpy, Pillow | `python3 -c "import numpy, PIL"` | `python3 -m pip install --user numpy pillow` (sans pip : `get-pip.py --user`) |
| .NET 8 (fichiers binaires .yft/.ytd/.awc) | `dotnet --version` ou `~/.dotnet/dotnet` | `dotnet-install.sh --channel 8.0 --install-dir ~/.dotnet` ; le convertisseur trouve `~/.dotnet` seul |
| Serveur d'assets GTA V (vraies textures et vrai son) | outil MCP `gta_status` (`ready: true`) | proposer `tools/gta-asset-server/start-server.bat` sur le PC + déclaration dans *My MCP servers* ; sinon la conversion reprend ce qui est déjà dans le cache (`~/.cache/fivem2roblox`), et seulement à défaut couleur unie / son synthétisé |
| Studio connecté | `studio_connection_status` (plugin attaché), `list_roblox_studios` | livrer le dossier + étapes manuelles |
| Upload Roblox | VibeStarter : outils `upload_file` + `asset_publish` ; ailleurs : `ROBLOX_API_KEY` présent dans l'environnement (ne jamais l'afficher) | dernier recours : une seule action manuelle, *Importer 3D* (§ 4c) |

## 1. Convertir

```bash
cd skills/fivem-vehicle-to-roblox
python scripts/convert_vehicle.py "<zip>" -o "<sortie>" [--plate "TEXTE"] [--texture-overrides <dossier>]
```
Options : `--vehicle <nom>` (pack multi-véhicules), `--lod med` (> 300 000 triangles),
`--no-collision` (hitbox = simple boîte), `--wheel-collision` (cylindres de roues solides),
`--studs-per-meter`, `--texture-overrides <dossier>` (PNG/DDS de même nom qui remplacent les
textures du pack : retouches), `--brand`, `--model-name`, `--rebadge-spec` (§ 1b), `--sound-ids <json>`, `--retry-gamefiles`, `--no-game-server`.
**Sons moteur maison (pack Brolver)** : `--engine-pack <dossier|.rar>` (ou variable
d'environnement `F2R_ENGINE_PACK`) remplace le son du mod par un son du pack
`sounds/<categorie>/<son>/<son>_{moteur,echappement}_{acceleration,deceleration,ralenti}.wav`
+ `sounds/klaxon/*.wav`. Catégorie d'après la classe GTA **vérifiée** (§ 1c) (VC_SUPER→super, VC_SPORT→sport,
VC_SEDAN→berline, VC_SPORT_CLASSIC→classique, VC_OFF_ROAD→toutterrain, « monster » dans le nom→monster,
utilitaires→pickup…) ; le son est tiré du nom du modèle (stable d'une conversion à l'autre).
Moteur → couche `engine` (capot), échappement → couche `exhaust` (pots), découpés en boucles comme un son de mod. `--engine-sound
brolver_super_03` (ou une catégorie, ex. `muscle`) force le choix ; `--no-engine-pack` l'ignore.
Sans chemin, le pack est **téléchargé automatiquement** depuis la release GitHub `brolver-motor-sounds-v1` (une URL est aussi acceptée) ; le .rar est téléchargé et décompressé une seule fois (7-Zip, sinon `unrar`/`rar` du PATH) dans `%LOCALAPPDATA%/f2r/engine_pack` (`~/.cache/f2r/engine_pack` hors Windows).
Code 2 = binaires sans extracteur : installer .NET 8 (ci-dessus) et relancer ; sinon export XML
CodeWalker par l'utilisateur ; `dlc.rpf` chiffré → OpenIV.

Lire `<sortie>/<nom>/report.md` : « Hitbox : collision officielle du véhicule » (sinon boîte
englobante : le .yft n'avait pas de `Physics/Bounds`, le signaler), « texture(s) reprises du jeu de base », « vrai son du jeu »,
ligne « Transfert depuis le serveur d'assets » (fichiers, Mo, secondes). Une texture
`vehshare`/`vehicle_generic_*` manquante ou un son synthétisé = serveur d'assets injoignable.

## 1b. Marques : renommage et rebadge (automatique)

À chaque conversion, `f2r/brands.py` + `f2r/rebadge.py`, table `brands/brands.json` (102 marques, logos
PNG dans `brands/logos/`, galerie `brands/README.md`) :
- **Marque** : `vehicleMakeName` de vehicles.meta, sinon le nom de l'archive / des dossiers
  (« bmw_2022_bmw_m4_competition ») → marque du jeu (BMW → **Bavren**). `--brand` force la marque.
- **Modèle** : mots du nom de dossier ou de `gameName`, sans marque ni année ; table de la marque
  (`models`, `labels` : M4 → N4, AMG → MRG), mots génériques gardés (Competition, GT, Turbo…), désignation
  lettres+chiffres décalée d'une lettre (C63 → D63), nombre + 30 (911 → 941). Un mot qui ne se traduit pas
  (Mustang, Supra…) donne « ??? » et une étape manuelle du rapport : **choisir un nom** qui n'existe pas chez
  la marque d'origine, l'ajouter aux `models` de la marque dans `brands.json`, reconvertir (`--model-name` en dépannage).
- Le Roblox ne contient que les noms du jeu : `CONFIG.Make/Brand/ModelName/DisplayName`, attributs
  `Brand` et `ModelName` posés par le Setup. La marque réelle reste dans `vehicle_config.json` (local).
- **Logos 3D** : toute pièce dont la texture s'appelle *badge / logo / emblem* est découpée en îlots ; îlot
  uni (baguette) gardé ; îlot presque rond ou carré de 3 à 40 cm → pièce `<os>__emblem` (fond du médaillon
  d'origine + logo du jeu, suit son os : coffre, volant) ; le reste (lettrages « M4 », logo d'étrier) supprimé.
  Rapport : « Rebadge : N emblème(s)… ». Marque absente de la table : avertissement, emblèmes sans logo →
  ajouter la marque (ligne + logo, règles de la note « Marques de véhicules » du jeu) puis reconvertir.
- **Logos peints dans les textures** (cache-moyeu, flanc de pneu, écran, volant, plaque de phare) : non
  détectables automatiquement. Ouvrir les PNG de `textures/` (une planche contact suffit), relever les
  zones en pixels de la texture d'origine, écrire `brands/vehicles/<nom>.json` (exemple : `m422.json` ;
  opérations `fill_rect`, `fill_disc`, `fill_ring`, `fill_all`, `logo`), reconvertir : le fichier est lu
  automatiquement et la conversion suivante le refait seule. Pousser ce fichier avec le skill.
- **Lettrages modélisés** (lettres en relief dans la géométrie d'une pièce ordinaire, sans texture de badge :
  « ///M » du pommeau de vitesse et du repose-pied, « M4 » des appuie-tête de la m422) : ni le rebadge des
  badges ni les retouches de textures ne les voient, et un tri automatique ne les sépare pas des vis et des
  grilles (93 grappes sur la m422). Chaque conversion dessine donc `_rebadge/lettrages_modelises.png` (grappes
  de ≥ 5 îlots de 2 cm au plus, à 4 mm les uns des autres, numérotées) et `lettrages_modelises.json` (pièce,
  boîte en mètres). **Toujours regarder la planche** : chaque lettre ou logo lisible → copier sa boîte dans
  `brands/vehicles/<nom>.json`, clé `geometry` :
  `{"op": "remove_islands", "part": "<pièce>", "box": [[x0,y0,z0],[x1,y1,z1]], "why": "///M du pommeau"}`
  (marge de 2 mm ; un îlot n'est retiré que s'il est entièrement dans la boîte). Reconvertir : le rapport dit
  « Lettrage modélisé supprimé (…) : N triangle(s) », ou avertit si une boîte ne trouve plus rien.
- **Contrôle** : gros plans dans Studio (calandre, coffre, volant, roues, écran, **pommeau, appuie-tête,
  seuils**) avant de rendre la main.

## 1c. Classe du véhicule : vérifiée sur internet (obligatoire)

La `vehicleClass` du `vehicles.meta` d'un mod est souvent fausse (la m422, BMW M4 Competition, y est
`VC_MUSCLE`). Or elle choisit la **catégorie du son moteur** (pack Brolver) et le **rangement dans le menu
du jeu** (`VehicleConfig.Class`). Avant chaque conversion d'un nouveau véhicule :
1. Identifier le vrai modèle (nom du zip, `vehicleMakeName`/`gameName`, génération, année).
2. **Chercher sur internet** sa carrosserie et son segment (fiche constructeur, Wikipédia « Body style »),
   au moins une source, et choisir la classe d'après le **vrai véhicule**, pas d'après le mod :
   | Vrai véhicule | Classe | Son |
   |---|---|---|
   | coupé 2 portes, même version sportive (M4, C63 coupé, RC F) | `VC_COUPE` | coupe |
   | berline 4 portes, même version sportive (M3, M5, RS6 berline, E63) | `VC_SEDAN` | berline |
   | citadine / compacte (Golf, Clio, Mini) | `VC_COMPACT` | compact |
   | sportive pure, pensée comme telle (911, Supra, GT-R, Cayman, roadster) | `VC_SPORT` | sport |
   | supercar / hypercar (moteur central, > 600 ch : Huracán, F8, 720S) | `VC_SUPER` | super |
   | américaine V8 à propulsion (Mustang, Challenger, Camaro) | `VC_MUSCLE` | muscle |
   | ancienne (avant ~1980) | `VC_SPORT_CLASSIC` | classique |
   | SUV / 4x4 / pick-up / utilitaire | `VC_SUV` / `VC_OFF_ROAD` / `VC_VAN`… | suv / toutterrain / pickup |
   Règle de l'utilisateur (2026-11-15) : une version « performance » d'un coupé ou d'une berline reste un
   coupé ou une berline (la M4 Competition n'est ni une muscle ni une sport).
3. L'écrire dans `classes/vehicle_classes.json` (`class`, `mod_class`, `real_model`, `body`, `sources`,
   `checked`) et pousser ce fichier avec le skill : la conversion le lit seule (rapport : « Classe du
   véhicule : … (mod) remplacée par … »). `--vehicle-class VC_COUPE` (ou `coupe`) force en dépannage.
   Sans entrée, le rapport affiche « Classe du véhicule NON vérifiée » : ne pas livrer ainsi.

## 1d. Icônes de l'habitacle (automatique)

Les symboles des boutons (volant, portes, console, clim) sont dans la planche du shader `vehicle_dash_emissive`
(ex. `int_emis`, 512 px) et n'existent que dans son **alpha** ; sous le fond transparent le RVB est blanc. Sans
traitement, Roblox montre des rectangles blancs et des symboles flous (m422, 2026-11-15). La conversion
(`f2r/icon_atlas.py`) : fond -> plastique sombre de la planche, corps clair des symboles neutres -> gris clair
(couleurs gardées), agrandie ×4 (plafond 2048) avec des bords nets ; les pièces `dash_emissive` deviennent des
`decal` (transparentes) ; les pièces opaques qui échantillonnent la planche reçoivent `<nom>_opaque.png` (sans
trou, sinon `Part.Color` ou du blanc apparaît en mode Overlay). Rapport : « Planche d'icônes … agrandie à N px ».
Un véhicule déjà installé et retouché : ne pas le réinstaller, remplacer la ColorMap/TextureID de l'ancienne
planche par les deux nouvelles (decal : `AlphaMode.Transparency`), puis `sync_catalog`. Contrôle : gros plans
du volant, de la console et des portes.

## 2. Uploader le modèle et les sons (assets privés)

En parallèle :
- **GLB** `<nom>.glb` → `upload_file` puis `asset_publish` → `rbxassetid` de type Model.
- **Sons** : chaque `sounds/*.wav|ogg` → `upload_file` + `asset_publish` → écrire
  `sounds/sound_ids.json` = `{ "engine_on_1.wav": "rbxassetid://…", … }`.
  Hors VibeStarter : `python scripts/roblox_upload.py <sortie>/<nom>/sounds --user-id <id>` (clé en variable d'environnement).
- Relancer la conversion avec `--sound-ids <sortie>/<nom>/sounds/sound_ids.json` (cache : ~15 s) pour
  intégrer les SoundId au Setup. Le GLB est identique d'une conversion à l'autre (déterministe) :
  pas de nouvel upload.

## Hitbox fidèle (automatique)

Le `.yft` contient la **collision officielle du véhicule** (Physics/LOD1, `Bound` composite) :
carrosserie, capot, coffre, portières, vitres en maillages bas-poly (≈ 240 triangles), roues en
disques. Le convertisseur l'exporte dans le GLB (`col__<os>__<n>`, écarte `*_lowlod` / `*_dummy`) ;
le Setup en fait des pièces **invisibles, solides et interrogeables** dans `Collision/<os>/`,
**soudées à leur os** (une portière ouverte garde sa collision), règle leur précision
(`Hull` si le morceau est convexe, sinon `PreciseConvexDecomposition`, par `CreateMeshPartAsync` +
`ApplyMesh` : écrire `CollisionFidelity` par script est ignoré sans erreur), ajoute les roues en
cylindres (rayons et contacts ; solides avec `--wheel-collision`) et neutralise la boîte `Hitbox`
(gardée comme volume englobant, attribut `BoundsOnly`). Mesuré sur m422 : 86 % des rayons à moins de
15 cm de la carrosserie visible contre 34 % avec la boîte ; un joueur se pose sur le capot à +1,55 stud
au lieu de +3,17. Voir la hitbox : rendre `Collision` visible (Transparency 0,5) le temps d'une capture.

## 3. Préparer les scripts pour Studio (sans recopier 100 Ko de code)

La conversion écrit `<sortie>/<nom>/studio/` : `FiveMRuntime.lua` (runtime, une fois par place),
`<nom>_Setup.studio.lua` (Setup compact), `Verify.lua`, `ApplySoundIds.lua`, `chunks/` + `manifest.json`.

- **Projet Rojo synchronisé avec la place ouverte (VibeStarter)** : déposer les fichiers dans le dossier monté —
  ```bash
  python scripts/studio_stage.py <sortie>/<nom> --project <dossier du projet>
  ```
  → `ReplicatedStorage.rbxts_include.F2R_Transfer` (StringValue `FiveMRuntime`, `<nom>_Setup`,
  `ApplySoundIds`, `<nom>_sound_ids` ; ModuleScript `Verify`), visible dans Studio en ~2 s.
- **Sinon** : envoyer `studio/chunks/*.lua` dans l'ordre de `manifest.json`, un `execute_luau` par
  fichier, tel quel ; le dernier morceau de chaque étape exécute le script et renvoie son résultat.

## 4. Faire arriver le modèle dans Studio

a. ~~EditableMesh~~ : rejeté (géométrie perdue à la sauvegarde, ~12 Mo de texte pour un véhicule).
b. **Retenu** : `insert_asset` avec l'id du GLB, `parent = "Workspace.F2R_ImportTest"` (créer le
   dossier par `execute_luau` s'il manque), `position` libre (le Setup pose le véhicule au sol).
   Les MeshParts gardent le nom des nœuds glTF (dans des `Model <nom>_Node`, retirés par le Setup).
c. Dernier recours, sans upload possible : demander **une seule** action à l'utilisateur —
   « Dans Studio : Accueil › Importer 3D › `<sortie>/<nom>/<nom>.glb`, options par défaut, puis
   dis-moi quand c'est fait. » Le Setup retrouve ensuite le modèle tout seul (pièce `ProbePart`).

## 5. Runtime + Setup (execute_luau, Edit)

```lua
local T = game.ReplicatedStorage.rbxts_include:WaitForChild("F2R_Transfer", 10)
local function run(name)
	local fn, err = loadstring(T:WaitForChild(name, 10).Value, "=" .. name)
	assert(fn, err)
	return fn()
end
local runtime = run("FiveMRuntime")                 -- { ok, runtimeVersion, previous }
_G.F2R_TARGET = workspace.F2R_ImportTest.<nom>      -- le Model inséré
local setup = run("<nom>_Setup")                    -- { parts, joints, missingParts, missingSounds, groundedBy, warnings }
return { runtime = runtime, setup = setup }
```
`_G.F2R_NO_GROUND = true` avant le Setup garde la hauteur d'import. SoundId oubliés : `_G.F2R_TARGET = modèle ;
_G.F2R_SOUND_IDS = T.<nom>_sound_ids.Value ; run("ApplySoundIds")`.

## 6. Vérifier (roblox/Verify.lua)

`Verify.lua` renvoie une fonction `verify(opts) -> JSON` :
`{ pass, fail, warn, skip, results = { {group, name, status, detail} } }`.

**Edit** — `require(T.Verify:Clone())({ model = <modèle> })` : runtime installé ; pièces présentes et
nommées (`F2RExpectedParts`) ; véhicule droit, avant vers −Z ; échelle (empattement à 1 % près) ;
phares devant les feux ; pièces dans l'emprise ; posé au sol ; roues à leur place et du bon côté ;
hitbox (morceaux et roues présents, invisibles et solides, soudés à leur os, précision réglée, boîte
neutralisée, **fidélité par 400 rayons** depuis les 6 faces comparée à la carrosserie visible et à la
boîte : ≥ 80 % à moins de 15 cm) ;
SoundId renseignés ; SetColor / SetMod / SetLivery / SetExtra / SetNeon / SetPlate et
Serialize → Apply qui restaure l'état.

**Play, serveur** (`execute_luau` Server, un joueur) — `require(…Verify)({ model = …, checks = {…} })` :
`seats_play` (monter puis descendre à chaque place ; `seat = "<nom>"` pour une seule), `lock_play`,
`park_play`, `flip_play`, `void_play` (chute dans le vide rattrapée).
Corps adapté (client, joueur assis) : `checks = {"fit_play"}` — 0 point du corps hors habitacle, posé sur le siège, échelles lues. Refaire `seats_play` le véhicule posé sur une pente légère (plateforme inclinée
temporaire dans le dossier de travail).

**Play, client** (le runtime de rendu ne tourne que côté client ; `loadstring` y est interdit) :
1. `start_stop_play` (is_start = true).
2. `execute_luau` Client :
   `require(game.ReplicatedStorage.rbxts_include.F2R_Transfer.Verify)({ model = workspace.F2R_ImportTest:WaitForChild("<nom>"), checks = {"joints","lights","sounds","audio"} })`
   → rendu attaché **tout seul** par `FiveMVehiclesClient` (sinon : véhicule inerte en jeu),
   portes/capot/coffre à l'angle de `Hinges` via `Door_*`, roues et volant via la télémétrie,
   étriers (`hub_*`) qui braquent sans tourner, bras de suspension (`suspension_*`) fixes en rotation, chaque
   LightRole en Neon (ou sa lumière allumée) pour Headlights 1/2, Brake, Reverse, Indicator
   Left/Right/Hazard, Engine, Siren ; sons chargés ; moteur audible.
3. Conduite : `execute_luau` Server — asseoir le joueur (`seat:Sit(humanoid)` sur `Seats.DriverSeat`)
   et écouter l'attribut `Horn` ; `player_input` H puis E (maintenu 700 ms) ; `execute_luau` Server —
   attendre `Engine = true`, `Headlights = 1`, `Horn` vu `true` puis revenu `false`.
4. Moteur de conduite : joueur au volant (`VehicleAccess.Enter` côté serveur), puis `execute_luau` Client
   `require(…Verify)({ model = …, checks = {"drive_play"} })` (accélère, régime cohérent, s'arrête, reste
   droit). Mesures complètes (0-100, freinage, virages, bordure, côte, marche arrière) : piste
   `TestTrack.lua` créée en Play loin de la carte, banc `DriveBench.lua`, voir
   `references/roblox-integration.md` (« Essais de conduite ») ; essais longs en `task.spawn`.
5. `start_stop_play` (is_start = false). Toujours arrêter le Play avant de rendre la main ; un Play sans
   appel Studio pendant 3 min est arrêté par VibeStarter.

Lire les résultats de Verify, pas le nombre d'erreurs de console : une place qui contient d'autres
véhicules peut afficher des centaines de « Failed to load sound … » qui ne sont pas les nôtres.
Un statut `warn` « rendu figé » = Studio sans focus (RenderStepped arrêté) : relancer le groupe.

## 7. Corriger chaque échec

| Échec Verify | Cause habituelle | Correction |
|---|---|---|
| pièces manquantes / renommées | importeur différent | vérifier les noms (`F2RMissingParts`) ; réimporter le GLB (§ 4b) |
| empattement / avant vers −Z / roues côté | modèle en miroir, repères mal choisis | message « Recalage imprécis » du Setup ; corriger `pick_ref_parts` ou la conversion d'axes |
| porte à 0° (pas « rendu figé ») | Motor6D absent, pièce soudée à la racine | vérifier `Joints/` et le propriétaire (`Owner`) des pièces de la porte |
| rôle de lumière resté éteint | pièce sans `LightRole`, ID de lumière inconnu | `references/gta-format.md` (IDs de lumières) ; corriger `f2r/vehicle.py` |
| SoundId vides / sons non chargés | upload non fait ou refusé | § 2 ; `ApplySoundIds` |
| Serialize / Apply | état non restauré | `roblox/runtime/VehicleCustomization.lua` |
| hitbox : précision `Default` | `ApplyMesh` refusé (mesh non chargé, droits) | relancer le Setup ; vérifier que le GLB est un asset du propriétaire de la place |
| hitbox fidèle < 80 % | collision du mod grossière ou absente | lire « trop large / trop juste » ; mod sans `Physics` → boîte (signaler) |
| rendu non attaché par FiveMVehiclesClient | runtime d'avant le correctif du 2026-11-10 | réinstaller `FiveMRuntime` (nouvelle version) |
| étrier figé quand la roue braque | conversion d'avant le 2026-11-11 (os `hub_*` ignoré) | reconvertir et réinstaller (§ 4b à 6) |
| invites / sons « hors du véhicule » | Setup d'avant le 2026-11-11 (WorldPosition réglé avant le parent) | réinstaller le véhicule (§ 4b à 6) |
| descente : posé sur le toit | aucun espace libre des deux côtés (mur, autre véhicule) | normal ; sinon vérifier la pente et les pièces voisines |
| tête dans le toit (avertissement) | avatar trop grand pour l'échelle | reconvertir avec l'échelle conseillée par `seats_play` |

Après une correction du skill : reconvertir, réinstaller (supprimer le modèle, § 4b à 6) et revérifier.
Une modification du runtime se propage par `FiveMRuntime` (version = empreinte des sources).

## 8. Ranger et rendre compte

- `python scripts/studio_stage.py --clean --project <dossier>` (retire `F2R_Transfer`).
- Laisser le véhicule dans `Workspace.F2R_ImportTest`, Play arrêté, caméra rendue.
- **Rapport final court, en français** : ce qui marche (Verify : réussis / échecs / sans objet, test de
  conduite), avertissements (textures ou sons non repris du jeu, rôles sans pièce, licence et marques),
  ce qui reste à faire (calibrer la conduite sur des mesures FiveM, déplacer le modèle dans
  `ServerStorage`, sons manquants…). Joindre une capture du véhicule.

## Ce que l'utilisateur obtient dans Roblox

- `Model` avec `PrimaryPart = VehicleRoot` (ancré au départ), `Hitbox`, `Visual/` (MeshParts par
  propriétaire), `Joints/` (Motor6D : roues, portes, capot, coffre, volant, gyrophares), `Seats/`
  (`DriverSeat`…), `Liveries/`, `Neons/`, sons, lumières, `VehicleConfig` (ModuleScript), tag `FiveMVehicle`.
- `ReplicatedStorage.FiveMVehicles` : `VehicleInput` (contrôles), `VehicleRuntime` (rendu client),
  `VehicleCustomization` (API custom serveur), `VehiclePaints` (palette GTA), remotes ; `FiveMVehiclesServer` ;
  `FiveMVehiclesClient`. Un menu de custom du jeu (vMenu…) se branche par l'action `Custom` de `VehicleEvent`
  après `Custom.SetRemotePolicy` : `references/roblox-integration.md`, « Brancher un menu de custom ».
- Contrôles par défaut (GTA-like) : **F monter / descendre** (invite par siège, côté portière ; manette Y ;
  bouton à l'écran sur mobile), W/S/A/D, Espace frein à main (un passager qui saute descend aussi), E klaxon,
  H phares (off/codes/pleins), ←/→ clignotants, ↓ warnings, Q sirène, R tonalité, Z moteur, **Alt gauche maintenu + clic
  sur une portière / le capot / le coffre** pour l'ouvrir ou la fermer (`VehicleTarget`, comme ox_target sur FiveM ;
  invites « Ouvrir / fermer » gardées au tactile et à la manette),
  X remettre sur ses roues (manette : croix bas), Maj / Ctrl rapports (manette : croix haut / X).
- **Monter / descendre** (`VehicleAccess`, serveur) : distance, place libre et verrou (`Locked`) vérifiés,
  portière ouverte puis refermée, joueur assis sans marcher ; à la descente il est posé au sol à côté de **sa**
  portière, dans un espace libre (sinon l'autre côté, sinon le toit). Le client se pose lui-même : c'est lui
  qui possède la physique de son personnage. Les occupants ne heurtent pas la collision du véhicule
  (groupes `FiveMVehicle` / `FiveMVehicleOccupant`) jusqu'à la fermeture de la portière.
- **Stationnement** : sans conducteur et à l'arrêt depuis `ParkAnchorDelay` s (5), `VehicleRoot` est ancré
  (`Parked`) ; il est désancré et confié au conducteur quand celui-ci monte. **Remise sur les roues** :
  retourné ou sur le côté plus de 2 s et quasi immobile → `Flipped`, invite « Remettre sur ses roues »
  (F maintenu) ou X à bord ; délai `RecoverCooldown` (5 s). **Chute dans le vide** : remis à sa dernière
  position sûre avant que Roblox ne détruise ses pièces (occupants compris, `VoidRecoveries`).
- **Conduite** (`VehicleDynamics` + `VehicleDrive`, client du conducteur) : le véhicule roule dès qu'un joueur
  prend le volant (boîte, freins, ABS, frein à main, suspension par rayons, son et compte-tours) ;
  `UseBuiltinDrive = false` pour brancher un autre châssis. Mesures : `docs/drive-tests.md` du dépôt.
- **Compteur de vitesse** (`VehicleDashboard`, client du conducteur, automatique) : vitesse (km/h, ou mph
  avec l'attribut `SpeedUnit = "mph"`), rapport (« R », « N » moteur coupé, « D » boîte électrique) et barre de
  régime du ralenti au rupteur du véhicule, zone rouge sur les 10 derniers %. Tout se lit dans la
  configuration (rapports, régimes, vitesse de pointe) : aucun réglage par véhicule. `BuiltinSpeedometer =
  false` (sur `ReplicatedStorage.FiveMVehicles` ou le véhicule) pour le remplacer par un HUD du jeu, qui lit
  `VehicleDashboard.Read(model)` (mêmes grandeurs que les natives GTA : `references/roblox-integration.md`).
- **Corps adapté à l'habitacle** (`VehicleSeatFit`, automatique) : le convertisseur voxelise l'habitacle
  (`CONFIG.Cabin`, 4 cm, ≈ 7 Ko) ; à l'assise, le client de l'occupant mesure son corps et cherche le réglage
  qui le garde entièrement dedans — corps le plus grand, puis le plus large, puis siège le moins reculé, puis
  le plus bas — et le serveur l'applique (R15 : `BodyHeight/Width/Depth/HeadScale` ; R6 : `ScaleTo`), recale la
  soudure du siège (hauteur, recul) et masque les accessoires qui dépassent encore. Tout est rendu à la
  descente. `SeatFit = false` sur le modèle pour désactiver ; `--no-seat-fit` à la conversion. Habitacle
  ouvert (cabriolet) : pas d'adaptation. La posture assise reste celle de Roblox (tibias verticaux) : dans un
  coupé bas, le corps est fortement réduit (mesures : `docs/seat-fit-tests.md`).
- **Posture de conduite** (`VehiclePose`, chaque client, automatique) : comme GTA, la posture dépend du
  `layout` du véhicule (`CONFIG.Layout` ; `LAYOUT_LOW` : dossier incliné, jambes allongées) et le bassin est
  posé sur l'os du siège ; jambes vers le plancher devant le siège (grille d'habitacle), mains sur la jante du
  volant à 9 h 15 (elles suivent sa rotation jusqu'à ±100 °), mains sur les cuisses pour les passagers. Articulations
  `Motor6D` et `AnimationConstraint` ; R6 : angles fixes, non vérifié. `DrivingPose = false` pour la retirer.
  On ne s'assoit jamais en touchant un siège (`CanTouch = false`) : seulement par l'invite F ; à bord, les
  invites du véhicule sont masquées.
- **Vue intérieure façon GTA** (`VehicleCamera`, occupant local) : V (bouton « Vue » sur mobile) bascule, comme
  zoomer à fond ; caméra sur l'œil GTA du siège (`Seats[i].PovOffset` = `PovCameraOffset`), qui tourne avec le
  véhicule, bornée à ±110 ° de cap, +30 / −45 ° d'inclinaison, revient vers l'avant en roulant (1,5 s sans
  toucher à la vue), regarde derrière avec C / R3 ; seuls les avant-bras et les mains sont visibles, amincis sur l'écran de l'occupant. Bornes
  posées à l'œil (celles de GTA ne sont pas documentées). `PovCamera = false` pour garder la caméra de Roblox.
- **Traces de pneus, fumée et burn façon GTA** (`VehicleTyreFx`, chaque client ; `VehicleDynamics`) : par roue,
  trace noire au sol + fumée légère **ensemble**, dès que la roue glisse dans son propre repère au-delà du pic
  d'adhérence : patinage ou roue bloquée (burn, départ, frein à main) marquent seuls ; une glisse **de côté** ne marque
  que si la **voiture dérive** (angle entre le cap et la trajectoire de l'**essieu arrière** ≥ `DriftStart` 12°, plein à
  22° ; pas au centre de gravité, où la géométrie seule donne 5 à 14° à pleine butée) — braquer à fond dans un virage
  tenu ne laisse rien (correctif du 2026-11-15 : avant, les roues avant qui ripent en sous-virage marquaient). Trace =
  **ruban continu** par roue (Beams couchés qui se rejoignent point pour point, opacité lissée, fondu d'entrée et de
  sortie, segments alignés fusionnés), discrète (opacité 0,42 au plus) ; rien sur l'eau ; sols meubles : poussière et trace de la couleur du sol. **Burn** : W + S à l'arrêt, les
  roues motrices patinent sur place (régime tenu sous le rupteur, tache noire qui fonce) ; avec A / D, **donut** autour
  de l'avant ; relâcher S lance la voiture. Couleur de fumée : attribut `TyreSmokeColor`. Seuils posés à l'œil contre
  des vidéos GTA, non mesurés dans FiveM ; pas encore de pneu qui éclate après un long burn ni de crissement.
- **Retours de flamme façon GTA** (`VehicleBackfire`, chaque client, aucun réseau en plus) : jet de flamme + lumière
  orange à chaque os `exhaust*` du modèle, au lever de pied à haut régime (salve de 2 à 4), au passage de rapport sous
  les gaz et au rupteur (burn compris). Comme GTA, seulement avec un échappement amélioré (`Mod_Exhaust` > 0) sauf
  attribut `Backfire`. Son : attribut `BackfireSoundId` (aucun son fourni : le son de GTA appartient à Rockstar).
  Seuils et rendu posés à l'œil.
- **Taille de l'avatar** : à l'échelle réelle (3,571 studs/m) un avatar R6 assis touche souvent le pavillon.
  Verify (`seats_play`) mesure la garde au toit et donne l'échelle conseillée (`--studs-per-meter`).

## Sans Studio connecté (livraison manuelle)

Livrer `<sortie>/<nom>/` (sans `_work/`) zippé, avec :
1. *Importer 3D* → `<nom>.glb` ;
2. sélectionner le modèle importé → *Modèle › Exécuter un script* → `<nom>_Setup.lua` (version complète, runtime inclus) ;
3. le moteur de conduite est inclus ; pour un autre châssis : `references/roblox-integration.md`
   (« Interface d'adaptation »).
Résumer : pièces/triangles, mods, livrées, sons, avertissements.

## Références (à lire au besoin)

- `references/gta-format.md` — os, IDs de lumières, couches de peinture, shaders, metas, roues, mods, livrées.
- `references/roblox-integration.md` — hiérarchie produite, attributs, API Input/Runtime/Customization, branchement physique.
- `references/troubleshooting.md` — problèmes fréquents et corrections.
- `references/game-assets.md` — récupération des textures/sons du jeu de base.
- `tools/gta-asset-server/README.md` — serveur d'assets à lancer sur le PC.
- `docs/transport-tests.md` (canal VM → PC) et `docs/studio-import-tests.md` (arrivée dans Studio, Verify).

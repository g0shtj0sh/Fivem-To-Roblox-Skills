# Intégration Roblox

## Installation dans Studio

**Automatique** (agent + MCP Roblox Studio) : voir `SKILL.md` § 2 à 6 — upload du GLB et des sons
en assets privés, `insert_asset`, puis `studio/FiveMRuntime.lua` et `studio/<nom>_Setup.studio.lua`
par `execute_luau` (`_G.F2R_TARGET` = modèle), contrôle par `roblox/Verify.lua`. Le Setup pose le
véhicule au sol, retire les conteneurs `*_Node` de l'import et renvoie un rapport
(`parts`, `joints`, `missingParts`, `missingSounds`, `groundedBy`, `warnings`).

**Manuelle** :

1. **Avatar › Importer 3D** (ou Accueil › Importer 3D) → `<nom>.glb`. Options par défaut.
2. Sélectionner le modèle importé dans l'Explorateur.
3. **Modèle › Exécuter un script** → `<nom>_Setup.lua` (ou coller le fichier dans la barre de commande).
4. Vérifier la sortie : « « NOM » installé : … ». Les avertissements sont listés juste au-dessus.
5. Glisser le modèle dans `ServerStorage` pour le cloner en jeu (le tag `FiveMVehicle` suit les clones).

Le Setup est idempotent pour les modules runtime (il met à jour `ReplicatedStorage.FiveMVehicles`,
`ServerScriptService.FiveMVehiclesServer`, `StarterPlayerScripts.FiveMVehiclesClient`) mais refuse de
ré-installer un modèle déjà installé : ré-importer le `.glb` pour recommencer.

## Hiérarchie produite

```
<Nom> (Model, PrimaryPart = VehicleRoot, tag FiveMVehicle)
├─ VehicleRoot      Part 1×1×1 invisible à l'origine du véhicule, ANCRÉE (désancre-la pour ta physique)
│  ├─ Light_headlight_l (Attachment + SpotLight) … Light_indicator_rr …
│  └─ Sounds (Attachment) : engine_on_1..4 / engine_off_1..4, Idle, Start, Horn, IndicatorOn/Off, Siren_*
├─ Hitbox           boîte englobante ; solide seulement sans collision GTA (sinon BoundsOnly : ni collision ni rayons)
├─ Collision/<os>/  hitbox fidèle : col__<os>__<n> (MeshParts invisibles, CanCollide/CanQuery/CanTouch,
│                   précision Hull ou PreciseConvexDecomposition), Collision_wheel_* (cylindres) ;
│                   soudées à la racine ou au pivot de leur os (suivent portes, capot, coffre, roues)
├─ Visual/<propriétaire>/MeshParts   (Massless, CanCollide=false) + Mod_<Slot>_<n>/
├─ Joints/          Pivot_<os> + Motor6D <os> (roues, portes, capot, coffre, volant, gyrophares)
├─ Seats/           DriverSeat, Seat_seat_pside_f…
├─ Liveries/        SurfaceAppearance "1", "2"…
├─ Neons/           4 bandes Neon + PointLight (cachées)
└─ VehicleConfig    ModuleScript : toutes les données (roues, charnières, lumières, mods, handling…)
```

Repère : `VehicleRoot.CFrame.LookVector` = avant du véhicule, `UpVector` = haut.
`VehicleConfig.Wheels[os].Position` est en **mètres** dans le repère de la racine (× `StudsPerMeter`).

## Attributs du modèle (état répliqué)

| Attribut | Type | Rôle |
|---|---|---|
| `CollisionSource` | "gta"/"box" | origine de la hitbox (collision officielle du .yft, ou boîte englobante) |
| `Locked` | bool | verrouillé : invites « Conduire / Monter » masquées, montée refusée (descendre reste possible) |
| `ParkAnchorDelay` | s (5) | délai sans conducteur et à l'arrêt avant l'ancrage de `VehicleRoot` |
| `Parked` | bool | `VehicleRoot` ancré par le stationnement |
| `Flipped` | bool | retourné ou sur le côté depuis plus de 2 s, quasi immobile |
| `RecoverCooldown` | s (5) | délai entre deux remises sur les roues |
| `Engine` | bool | moteur allumé (auto au passage du conducteur, `AutoStartEngine`) |
| `Headlights` | 0/1/2 | éteint / codes / pleins phares |
| `Indicator` | "Off"/"Left"/"Right"/"Hazard" | clignotants |
| `Brake`, `Reverse` | bool | feux stop / recul |
| `Horn`, `Siren`, `SirenSound` | | klaxon, gyrophares, tonalité ("wail","yelp","priority","off") |
| `Rpm`, `Throttle`, `Steer`, `Gear` | number | télémétrie relayée aux autres joueurs (10 Hz) |
| `TyreFx` | entier | traces et fumée par roue (4 bits par roue, os triés par nom ; `VehicleTyreFx.Unpack`), relayé à 10 Hz |
| `TyreSmokeColor` | Color3 | couleur de la fumée de pneus (comme dans GTA ; défaut gris clair) |
| `TyreFx` = false | bool | sur le véhicule : coupe traces et fumée (l'attribut numérique ci-dessus est alors ignoré) |
| `Door_<os>` | 0..1 | ouverture porte / capot / coffre |
| `Mod_<Slot>`, `Color_<Couche>`, `Livery`, `Extra_<n>`, `WindowTint`, `Neon`, `NeonColor`, `XenonColor`, `PlateText`, `Perf_<Slot>` | | custom (voir API) |

## Touches

| Touche | Manette | Action |
|---|---|---|
| **F** | Y | monter (invite « Conduire » / « Monter » côté portière) ; à bord : descendre |
| F maintenu | Y maintenu | dehors, véhicule retourné : « Remettre sur ses roues » |
| X | croix bas | à bord, véhicule retourné : remettre sur ses roues |
| E | L3 | klaxon |
| G | — | ouvrir / fermer portière, capot, coffre (invite) |
| Z | — | couper / rallumer le moteur (il démarre à la montée du conducteur) |
| H | croix droite | phares : éteints / codes / pleins |
| ← / → / ↓ | — | clignotant gauche / droit / warnings |
| Q / R | croix gauche / — | sirène / tonalité |
| W A S D, Espace | gâchettes, stick, R1 | conduite, frein à main (lus par ton moteur via `VehicleInput.Controls`) |
| W + S (+ A / D) | gaz + frein (+ stick) | arrêté : **burn** (roues motrices qui patinent sur place) ; avec la direction : **donut** |
| Maj / Ctrl | croix haut / X | rapport + / − (`Input.Action`) |

Mobile : les invites s'affichent en bouton ; à bord, bouton « Descendre ».

## Hitbox : passages de roues creusés (`VehicleCollision.CarveWheelWells`)

La collision officielle GTA (`col__chassis__1`) est une coque presque convexe à fond plat **sous toute la
voiture, passages de roues compris** : sur le m422 elle descendait à −34 cm sous `VehicleRoot` au droit des
roues, la carrosserie visible à 0 / −2 cm. Ici la suspension est faite de rayons et les cylindres de roues
ne collisionnent pas en conduite : une roue qui montait sur une rampe ou un rondin faisait toucher l'obstacle
**à la coque, dans le passage de roue** — voiture posée « sur rien », roue en l'air, bloquée sans contact
visible. Le Setup (et `CarveWheelWells(model)` sur un véhicule déjà installé, idempotent) retire de chaque
pièce `col__*` qui les recoupe le volume que chaque roue balaie : un « stade » d'axe X entre détente et
compression maximales, du rayon de la roue braquée au maximum (roues directrices) + 3 cm, de la face
intérieure de la roue braquée jusqu'au-delà de l'aile. Soustraction `GeometryService:SubtractAsync` ; la
pièce creusée remplace l'ancienne (nom, réglages, attributs, groupe, soudure). `Verify` (groupe
`collision`) contrôle « passages de roues dégagés » sous le profil rond du pneu comprimé au maximum.

Mesuré sur le m422 (Play, PC Studio) : bosses alternées de 30 cm franchies sur 22 m (bloqué net avant) et de
50 cm jusqu'au contact du plancher, tremplin de 10° monté sur les seules roues (charge répartie, coque jamais en
contact). Les blocages restants sont ceux d'une sportive à ~15 cm de garde : pare-chocs contre une marche de
30 cm ou un rondin de Ø 24 cm, plancher sur une bosse de 50 cm. Reste non corrigé : le fond de la coque GTA est
2 à 3 cm sous le plancher visible au centre, 3 à 7 cm à l'arrière (diffuseur).

## Pièces mobiles : ce qui est monté dessus les suit

Le convertisseur répartit les triangles par os (`group_of`). Certains mods pondèrent sur un os du châssis
des pièces montées dans une portière ou le coffre : sur le m422, les feux arrière intérieurs (émissif, verre,
boîtier) et la lampe de plaque sont pondérés sur `taillight_l/r`, `misc_a`, `misc_b`, `misc_platelight`,
enfants du châssis, et restaient en l'air quand le coffre s'ouvrait. `VehicleBuilder._attach_to_hinged`
rattache un îlot (triangles connexes) d'une géométrie non peinte du châssis à une pièce de `ATTACH_PARTS`
(portières, coffre) quand les trois conditions sont réunies, mesurées sur la **peau extérieure peinte** :
75 % de ses sommets reposent (à 8 cm) sur la peau de cette pièce, il n'est pas enfoui dessous (profondeur
médiane ≤ 4 cm) et cette peau l'entoure (7 secteurs sur 12). Le rapport liste chaque rattachement
(« Rattachement : … »). **Le capot est exclu** : sa peau plonge à l'avant et entoure calandre, phares et
compartiment moteur (essai rejeté sur le m422 : calandre et optiques rattachées au capot). Test :
`tests/test_attach.py`. Sur le m422 : feux intérieurs, verres et lampe de plaque → coffre ; poignées →
portières ; rien d'autre.

## Compteur de vitesse (`VehicleDashboard`)

**Ce que fait GTA V** : aucun compteur dans le HUD du jeu de base. La vitesse se lit sur les cadrans du tableau
de bord intérieur, dont le modèle est désigné par `dashboardType` dans `vehicles.meta` (`VDT_*` ; le m422 :
`VDT_TRUCKDIGI`). La graduation appartient au modèle de cadran, pas au véhicule : un cadran plafonne (200 mph
d'après la communauté du modding), si bien que l'aiguille d'un véhicule de mod est souvent fausse. Les HUD des
serveurs FiveM affichent donc leur propre compteur, nourri par les natives : vitesse de l'entité (m/s ;
×3,6 = km/h, ×2,236936 = mph), régime normalisé (0,2 ralenti → 1,0 rupteur), rapport engagé (0 = marche
arrière), moteur, feux. Le convertisseur garde `dashboardType` (`CONFIG.DashboardType`) pour référence ; on
ne reproduit pas les cadrans 3D.

**Ce que fait le runtime** : le client du conducteur affiche un compteur simple, en bas au centre (hors du
stick et des boutons tactiles, dans la zone sûre `CoreUISafeInsets`), à l'échelle de l'écran (1 à 720 px de
haut, bornée 0,78–1,5 pour garder 12 px dessinés). Il se construit à partir du véhicule :

| Affiché | Source | Adapté au véhicule par |
|---|---|---|
| vitesse | `VehicleRoot`, vitesse le long de l'avant (comme `VehicleDrive`), lissée (1 − e^(−10·dt)) | — |
| rapport | `State.Gear` (télémétrie du moteur de conduite) | `Handling.Gears`, `Handling.Gearbox = "electric"` → « D » |
| barre de régime | `State.Rpm` entre `Audio.IdleRpm` et `Audio.MaxRpm` | régimes du véhicule ; zone rouge = 10 derniers % |

`VehicleDashboard.Read(model)` rend les mêmes valeurs à un HUD du jeu : `Speed`, `Unit`, `Gear`, `GearCount`,
`Rpm`, `Rpm01`, `RpmGta`, `Redline`, `TopSpeed` (vitesse au rupteur sur le dernier rapport,
`Handling.RedlineTopGearKmh`), `DialMax` (haut d'un cadran : pointe + 10 %, arrondi à 20), `Engine`,
`Headlights`, `Indicator`, `Brake`, `Reverse`, `DashboardType`. Désactiver le compteur intégré :
`BuiltinSpeedometer = false` (dossier `FiveMVehicles` pour tout le jeu, ou un véhicule).

## Feux (`VehicleLights.Rig`, état par `VehicleRuntime`)

Les optiques sont les maillages du shader GTA `vehicle_lightsemissive`, une pièce par feu (`LightRole`). GTA les
montre texturées éteintes et les fait briller (`emissiveMultiplier` 3) allumées. `VehicleLights.Rig(model)`
(appelé par le Setup, relançable sur un véhicule déjà installé) pose l'équipement ; le runtime le pilote.

| Élément | Ce qui est fait | Pourquoi (mesuré en Studio sur le m422, 2026-11-12) |
|---|---|---|
| Optique allumée | Neon de la couleur du feu, **`TextureID` retiré** (gardé dans `OffTexture`, remis à l'extinction) | un MeshPart Neon qui garde la texture GTA sombre reste presque éteint ; sans elle la signature lumineuse s'allume |
| Lumière d'un feu | `SpotLight` posé **hors de l'optique** (extrême de la pièce + 5–6 cm) et tourné vers l'extérieur ; les clignotants de côté éclairent de côté | les anciennes `PointLight` sans ombre, au centre de l'optique, éclairaient l'habitacle et le sol à travers la carrosserie |
| Phares | cône de 60°, portée 60, luminosité 3 (croisement) / 6 (route) ; **ombres seulement pour la voiture du joueur local** | posés au centre de l'optique avec ombres, ils étaient masqués par le boîtier : aucun faisceau au sol |
| Feux arrière | cône de 120°, portée 5 (position, 0,35) / 7 (stop, 1,2 ; 3ᵉ feu 0,6) ; recul 14 (1,2) | lueur rouge douce derrière, au lieu d'une flaque saturée de 4 `PointLight` de luminosité 3 |
| Plaques | textes `LightInfluence` 1 ; **lampe de plaque** au-dessus de la plaque arrière, vers le bas, allumée avec les feux | les plaques étaient pleinement lumineuses jour et nuit, l'avant compris |

`Verify` (groupe `lights`) contrôle aussi : cônes tournés vers l'extérieur, lampe de plaque arrière, optique allumée
sans texture. Non fait : halo (« corona ») des feux vus de loin, qui demanderait un `BloomEffect` réglé pour tout le
jeu ou un halo par `BillboardGui` ; tableau de bord émissif (`vehicle_dash_emissive`) éteint.

## Monter, descendre, stationnement (serveur)

```lua
local Access = require(game.ReplicatedStorage.FiveMVehicles.VehicleAccess)
Access.Enter(player, car, "DriverSeat")   -- true | false, "locked" / "occupied" / "too_far" / "flipped"…
Access.Exit(player)                       -- true, "door" | "other_side" | "roof"
Access.SetLocked(car, true)
Access.Recover(player, car)               -- true | false, "not_flipped" / "cooldown" / "too_far"
Access.PlaceOnGround(car, position, look) -- pose droit, roues sur la surface sous `position` (garage, essais)
Access.Teleport(car, pivot)               -- déplace le véhicule, même conduit (ancrage 0,25 s, physique rendue)
Access.MarkMoved(car, grace)              -- après un déplacement fait par ton propre code serveur
Access.RecoverFromVoid(car)               -- remet à la dernière position sûre (appelé tout seul)
```
**Déplacer un véhicule conduit depuis le serveur** : jamais un simple `PivotTo`. Le client propriétaire de
la physique renvoie son ancienne position et le contrôle de vraisemblance prend le saut pour une triche
(retour en arrière, `DriveViolations` +1). Utiliser `Access.Teleport` (ou `PlaceOnGround`), qui pose
l'attribut `TeleportGraceUntil` lu par tous les exemplaires du module (Actors, code lancé à part).

**Chute dans le vide** : toutes les 0,25 s, un véhicule non ancré dont la position prévue à 0,5 s passe sous
`Workspace.FallenPartsDestroyHeight + VoidMargin` (60 studs) est remis à sa dernière position sûre
(enregistrée toutes les 0,5 s quand il est droit, sol à moins de 3 m), occupants compris, avant que Roblox ne
détruise ses pièces. Attributs : `VoidMargin`, `VoidRecoveries` (compteur).
Chaque siège porte `Side` (-1 gauche, 1 droite) et `Door` (os de la portière), et son invite
`VehicleRoot/Enter_<siège>/EnterPrompt` (attributs `SeatName`, `Available`). Les pièces de collision du
véhicule sont dans le groupe `FiveMVehicle`, les occupants dans `FiveMVehicleOccupant` (non collisionnables
entre eux). Les cylindres de roues sont solides par défaut (le véhicule désancré repose dessus) ;
`--no-wheel-collision` les rend non solides pour un moteur à roues propres.

## Moteur de conduite intégré (VehicleDynamics + VehicleDrive)

Le véhicule roule tout seul : quand un joueur s'assoit au volant, `FiveMVehiclesClient` lance
`VehicleDrive.Start(car)` chez lui, le serveur lui confie la physique (`SetNetworkOwner`), puis la reprend à la
descente (`SetNetworkOwner(nil)`).

- **`VehicleDynamics`** (module pur, sans Instance) : moteur à régime normalisé 0,2 → 1, couple plat jusqu'à
  0,8 puis 60 % au rupteur, boîte (rapports d'origine du jeu, `DriveMaxFlatVelMs / rapport`, embrayage 0,1 → 1 au
  taux `ClutchChangeRate`, marche arrière, rupteur, `HARD_REV_LIMIT`, `FREEWHEEL_NO_GAS`, CVT, électrique),
  transmission `DriveFront/DriveRear`, pneus (courbe Max → Min, pic latéral `TractionCurveLateral × PeakFactor`,
  `TractionFront/Rear`, `LowSpeedTractionLossMult`), freins (`BrakeFront/Rear`, ABS selon les flags), frein à main
  arrière, suspension (`SuspensionForce`, amortissements, limites, `Raise`), anti-roulis, centre de roulis,
  traînée (`DragAccelCoeff`), déportance (`DownforceModifier`), braquage réduit avec la vitesse, contrôle en l'air
  et redressement doux. Tout en m/s² : la conduite ne dépend pas de la masse du modèle.
- **`VehicleDrive`** (client du conducteur) : un spherecast par roue (rayon = `Wheels[os].Radius`), une
  `VectorForce` et un `Torque` monde sur `VehicleRoot` (créés par le Setup : `DriveAttachment`, `DriveForce`,
  `DriveTorque`), forces × `AssemblyMass` × `StudsPerMeter`, gravité ramenée à `Handling.GravityMs2`, pas fixe
  `RunService:BindToSimulation` (repli `PreSimulation`), télémétrie `VehicleRuntime.SetTelemetry` à chaque pas.
- **Masse** : un lest `Ballast` (invisible, sans collision) porte toute la masse au centre de gravité
  (`Handling.CentreOfMassLocal` + base au-dessus des moyeux) ; la collision devient sans masse. La masse ne sert
  qu'aux chocs (`MassKg × 0,1`).
- **Roues de collision** : non solides pendant la conduite (suspension par rayons), solides sinon.
- **Serveur** : contrôle de vraisemblance (`VehicleAccess.CheckPlausibility`) : vitesse ≤ `RedlineTopGearKmh`
  × 1,35 + marge, pas de téléportation ; en cas d'écart, retour à la dernière position valide (attribut
  `DriveViolations`).

```lua
-- client du conducteur
local Drive = require(game.ReplicatedStorage.FiveMVehicles.VehicleDrive)
Drive.SetOverride({ Throttle = 1, Steer = 0 })  -- entrées imposées (tests, IA, cinématiques) ; nil = joueur
local a = Drive.Get()                           -- a.sim (P = paramètres, S = état), a.out (dernier pas)
print(a.out.speed, a.out.gear, a.out.rpm)       -- m/s, rapport (-1 = arrière), régime normalisé
local Dyn = require(game.ReplicatedStorage.FiveMVehicles.VehicleDynamics)
print(Dyn.PredictTopSpeed(a.sim) * 3.6)         -- vitesse de pointe théorique (km/h)
Dyn.reset(a.sim)                                -- état au repos (fait tout seul quand VehicleRoot est ancré)
```
Quand `VehicleRoot` est ancré (stationnement, `Access.Teleport`), `VehicleDrive` coupe les forces, annule les
vitesses chez le conducteur (une pièce ancrée garde sa vitesse et la reprendrait au désancrage) et remet la
simulation au repos (sinon les roues lancées en l'air relancent le véhicule).

### Essais de conduite (`TestTrack.lua`, `DriveBench.lua`)

Fournis dans `studio/` et déposés par `studio_stage.py`. Mesures et protocole : `docs/drive-tests.md` du dépôt.
```lua
-- serveur, en Play seulement (rien n'est enregistré)
local Track = require(T.TestTrack)
local t = Track.build(workspace.F2R_ImportTest)       -- plaque 2048 × 6144 studs loin de la carte
Track.place(car, t.lanes.straight, player)            -- voies : straight, curb (bordure 0,15 m), hill (15 %)
-- client du conducteur
local Bench = require(T.DriveBench)
Bench.setLine(car.PrimaryPart.CFrame)                  -- tenue de ligne
Bench.accel(45) ; Bench.brake(100) ; Bench.brake(60, { handbrake = true })
Bench.corner(40, 1, 5) ; Bench.curb(20, 150) ; Bench.hill(20) ; Bench.reverse(4)
```
Un appel `execute_luau` est coupé vers 14 s : lancer les essais longs en `task.spawn` et relever le résultat.
Un Play est une copie de la place : relancer le Play après une mise à jour d'un module.

### Réglages (`VehicleDynamics.Tuning`)

Les lois que le jeu ne publie pas sont des réglages. Les valeurs par défaut ont été **calées sur des mesures
FiveM réelles** (campagne `m422` : [`calibration/m422/README.md`](../../../calibration/m422/README.md)) ;
celles marquées **mesuré** ci-dessous en viennent. Pour un véhicule : table `DriveTuning` dans `VehicleConfig`
(mêmes noms), ou `Dyn.new(cfg, com, { KMu = 0.7 })`.

| Réglage | Défaut | Rôle |
|---|---|---|
| `KMu` | **1,0** | échelle de `TractionCurveMax/Min` en g — **mesuré sur les deux axes** : le champ du jeu *est* l'accélération en g (freinage roues bloquées 1,88 g, et pic latéral 1,898 g ± 0,003 au virage le plus fort, pour `fTractionCurveMax` = 1,90) |
| `PeakFactor` | **0,55** | pic latéral = `TractionCurveLateral × PeakFactor` — **rebalayé en Studio** (0,4 à 1,0, direction mesurée) : tient le virage 40 km/h établi de GTA à 2 % près (rayon, dérive de caisse, pneus à 9,5 / 8,3 ° contre 9,35 / 8,34). Un seul pic ne tient pas aussi le créneau (qui voudrait 0,4) : le pneu Roblox est linéaire jusqu'au pic. Dérive de pneu : vitesse latérale à l'essieu avant = `vLat − a·wz` (x à droite) |
| `LatVCap` | **1,25** | plafond de la force **latérale** : `|Fy| ≤ LatVCap × |vitesse latérale| × charge`. **Mesuré** sur 33 plateaux établis (22 cercles, dont 10 à rayon imposé pour séparer la vitesse du rayon) : sans lui le résidu latéral suit la vitesse (−0,84 de corrélation ; à rayon fixé, +25 % à 30 km/h et −17 % à 66), avec lui les corrélations tombent à −0,17 et +0,02 et l'écart de 0,137 à 0,083 g. Il explique le vieux conflit « un seul `PeakFactor` ne tient pas le créneau et le virage 40 » : avec lui, −3,8 % et −3,6 %. **Couplé à `PeakFactor`** : à 0,55 il est quasi inerte, il ne mord que si la courbe est plus raide (0,385 à 0,45) |
| `KappaPeak` | 0,12 | glissement longitudinal du pic |
| `Falloff` | 1,5 | largeur de la descente Max → Min |
| `FalloffKappa` | **0,1** | poids du glissement **longitudinal** dans cette descente — **mesuré** : une roue bloquée garde son pic ; dans GTA la chute est pilotée par la dérive. 1 = ancien comportement |
| `VStick`, `KStick`, `CStick` | **0,30 m/s** / **1600** / **60** | **frottement statique** : en dessous de `VStick`, le pneu devient un **ressort** sur le glissement accumulé (force ∝ déplacement, pas ∝ vitesse), ce qui tient le véhicule à l'arrêt. **Mesuré** : GTA ne bouge pas d'un millimètre en 2 s sur 17,1 % de pente, au point mort et sans pression de frein. Un amortisseur ne suffit pas — sa force s'annule avec la vitesse, donc il reste une vitesse de fluage (5,5 cm en 2 s, pire que sans rien) ; le ressort donne 0,1 cm |
| `SubSteps` | **16** | sous-pas internes. **Mesuré** : 8 ne suffisaient pas — la stabilité de l'intégration de ω demande `h < 2·KappaPeak·vRef·Iw/(r²·fmax)`, soit ≈ 43 sous-pas à 60 Hz avec `IwRel` = 0,03, et avec 8 le pas était **cinq fois** au-delà de la limite : la roue s'emballait au démarrage, masquée par l'écrêtage anti-dépassement. À 16 le résultat ne bouge plus (32 et 64 identiques) et le banc longitudinal est inchangé |
| `KSpring`, `KArb` | 1 | raideurs de suspension et d'anti-roulis (lois inconnues) |
| `RollCentreScale` | **0,25** | × hauteur des centres de roulis, là où `VehicleDrive` applique les forces latérales : c'est **elle** qui règle le roulis (bras de levier = centre de gravité − centre de roulis). Mesuré en Studio : 0,22 °/g à 1, 0,76 °/g à 0,25, 0,94 °/g à 0. Cible GTA **1,0 °/g**, linéaire de 0,83 à 1,84 g (1,014 / 1,030 / 1,002 °/g sur les trois essais). Sous 0,25 la roue arrière intérieure délestée patine et le virage serré perd sa motricité |
| `IwRel` | **0,03** | inertie de roue + transmission (`Iw = IwRel × r² / 4`) — **calé** : 0,25 interdisait de tenir à la fois le 0-100 et la vitesse de pointe |
| `KDrag` | **2,1** | multiplie le coefficient de traînée issu du chargement (`DragCoeff × 1e-4`), dont le facteur n'était qu'une hypothèse — **mesuré** sur le plateau de vitesse |
| `SlopeAssist` | **0** (mesuré 0,537) | poussée ajoutée en côte : `SlopeAssist × g × sin(pente)`, sous les gaz, via `ctx.slopeSin` (absent = plat, donc inactif). **Mesuré** sur 1046 images à plein gaz en 2ᵉ : `poussée = 0,400 g + 0,537 × g × sin(pente)`, écart 0,081 g contre 0,134 pour une poussée constante — à plat les 0,400 g sont exactement `fInitialDriveForce × rapport × g`. **Laissé à 0** : l'activer fait patiner la 1ʳᵉ en côte (la boîte pompe, la distance de lancement tombe de 34,6 à 26,1 m), parce que le moteur **sur-performe déjà le début du lancement** (GTA patine son embrayage 1,14 s au départ, le moteur embraye instantanément) : les deux sont à corriger ensemble |
| `FirstGearForce` | **1,5** | gain de poussée de la 1ʳᵉ **et de la marche arrière** (même rapport) — **mesuré** : 10,5 à 12,4 m/s² là où la loi donne 6,53 |
| `UpshiftRpm`, `UpshiftRpmFirst`, `DownshiftRpm`, `DownshiftRpmThrottle`, `DownshiftMargin` | **0,95** / **0,82** / 0,45 / **0,35** / 0,85 | boîte automatique — **mesuré** : la 1ʳᵉ passe nettement plus tôt que les autres ; 2→1 sous gaz à 0,35 (0,45 rétrogradait en plein virage serré), gaz relâchés à ≈ 0,41 |
| `EngineBrakeG` | **0,9** | frein moteur au rupteur, gaz relâchés — **calé** sur les 115 m de roue libre 110 → 30 km/h |
| `SteerSlideV0`, `SteerSlideK`, `SteerSlideMin` | **1,8 m/s** / **0,18** / **0,30** | le braquage obtenu tombe quand l'**arrière glisse** : `réduction = borne(1 − 0,18 × (|vLat + b·lacet| − 1,8), 0,30, 1)`, appliquée après le fondu en vitesse mais **avant** la butée. **Mesuré** sur 7972 images et 27 traces (cercles à consigne constante) ; écart quadratique moyen 0,066. Le prédicteur est la vitesse latérale de l'essieu **arrière** : seul candidat qui ne dépende pas de l'angle de roue (la dérive du pneu avant s'en déduit, donc elle serait circulaire). Vérifié sur 1200 images mesurées : virage 80 à 2,3 ° d'écart au lieu de 11,1 °, virage 40 et créneau inchangés |
| `SteerTau` | **0,08 s** | l'angle de roue rejoint sa cible par un **premier ordre**, il n'y saute pas. **Mesuré** sur 380 fronts de consigne à vitesse tenue, en simulation libre : écart sur l'angle de roue 5,31 ° sans retard, **1,31 ° avec** (tranches non contaminées par la glisse dure). Écartés : une butée de vitesse de braquage (la réponse normalisée ne dépend pas de l'amplitude) et un τ variable avec la vitesse (le gain ne survit pas à un ajustement en une passe). Ne pas confondre avec la colonne `steerAngle` de la télémétrie, qui est le volant et est **plus lente** que les roues |
| `LowSpeedFade` | 8 m/s | fin de la perte d'adhérence au démarrage |
| `SteerFade`, `SteerFadePower`, `SteerLockMeanPct`, `SteerMinPct`, `SteerPeakGain` | **15,0 m/s** / **2,72** / **0,875** / **0,1889** / **0** | braquage réduit avec la vitesse. **Loi mesurée** sur 20 plateaux à consigne constante de 15 à 105 km/h : `lock(v) = min(lock × 0,875, max(lock / (1 + (v/15)^2,72), lock × 0,1889))`. Le plafond 0,875 est la butée mécanique mesurée (30,625 ° pour 35 °, moyenne des deux roues, Ackermann 0,75) et `SteerMinPct` le braquage à 105 km/h : seuls `SteerFade` et `SteerFadePower` sont ajustés, RMS 0,78 °. L'ancien fondu linéaire braquait 2,3 fois trop à 105 km/h, `SteerPeakGain` étant actif dès 100 km/h alors que GTA descend **sous** l'angle du pic latéral. Le lacet de GTA est purement cinématique (`v × braquage / 2,811 m`, à 3,9 % près sur 20 plateaux) : si le braquage est juste, le lacet suit |
| `CounterSteer` | 0 | aide au contre-braquage |
| `AbsSlip`, `AbsRelease` | 0,18 / 0,35 | ABS |
| `HandbrakeGripRear` | **1,0** | adhérence latérale arrière au frein à main — **mesuré** : GTA bloque l'arrière sans lui faire perdre son adhérence latérale (0,1 °/s de lacet volant droit). Studio : reste droit (1,4–2 °/s) depuis un départ propre, mais 0,75 aussi ; entré en correction de cap, 36,5 °/s |
| `AirPitch`, `AirRoll` | **1,585** / **1,586** | couple de contrôle en l'air, rad/s² par unité. **MESURÉ** : 90,8 °/s² sur les deux axes, symétrie 96 à 98 % |
| `AirRateMax` | **1,066** | plafond de vitesse angulaire en vol, rad/s (61,1 °/s). **MESURÉ** : 9 vols sur 15 y butent. Écrêtage à sens unique — il n'annule jamais une rotation subie |
| `AirPitchFloor` | **−0,658** | assiette minimale en vol, rad (−37,7 °). **MESURÉ** : les 3 passes s'arrêtent à −37,4 / −37,6 / −38,2 °. La borne est **propre au piqué** : aucune borne de roulis sous 52 ° (6 passes, taux encore à ±63 °/s à l'atterrissage, libre jusqu'à 89,6 °) ni de cabrage sous 40 ° — elle n'est donc pas symétrique |
| `AirBoundTorque` | 12,4 | couple d'arrêt à la borne, rad/s². Ordre de grandeur seul (710 °/s², mesuré grossièrement sur 3 passes) |
| `GyrationSq` | 1,6 | m² : convertit les accélérations angulaires voulues (vol, redressement) en couples, × masse. **Faux dans Roblox (Studio, 2026-11-12)** : l'inertie réelle de l'assemblage vient du lest `Ballast` (boîte 0,35 m d'épaisseur) et vaut, rapportée à la masse, 1,098 m² en tangage, 1,394 en lacet, **0,319 en roulis** : le couple de vol sort ×1,43 en tangage et ×4,8 en roulis. Accepte un `Vector3` par axe (X, Y, Z) : `Vector3.new(1.098, 1.394, 0.319)` ramène le m422 à 88 °/s² sur les quatre sens. Voir `calibration/m422/README.md`, « Le contrôle en l'air vérifié dans Roblox » |
| `AirDamp` | **0** | amortissement angulaire en l'air. **MESURÉ NUL** : sans entrée le véhicule conserve sa rotation (+1,1 °/s²). Valait 1,5, posé au doigt |
| `RightingK`, `RightingSpeed` | 6 / 3 m/s | redressement doux |
| `SubSteps` | 8 | sous-pas internes |
| `DampVMax` | **1,0 m/s** | vitesse d'amortisseur plafonnée (clapets, souplesse du pneu) : sans elle une bordure de 15 cm à 20 km/h fait décoller l'avant. **Vérifié en Studio** avec `BumpK` 0 sur une marche de 0,149 m : +4,9 ° de cabrage à 20 km/h, +3,5 ° à 60 (GTA +3,45 / +2,2) — le cabrage *baisse* avec la vitesse ; 0,5 le fait moins bien |
| `BumpK` | **0** | butée au-delà de la course : à 400, une marche de 15 cm à 60 km/h renvoyait la caisse (−17,7 °, 3 images en l'air) ; GTA comprime au-delà de sa course nominale |
| `CurbBoost` | 0 | effet « curb boost » (désactivé) |

Dans le Setup : `COM_ABOVE_AXLE` (0,1 m, hauteur du centre de gravité au-dessus des moyeux), `MASS_SCALE` (0,1).

### Interface d'adaptation : brancher son propre châssis

Pour utiliser un autre moteur physique à la place de `VehicleDynamics` :

1. Mettre l'attribut `UseBuiltinDrive = false` sur le modèle (le client ne lance plus `VehicleDrive`, les
   cylindres de roues restent tels quels ; `--no-wheel-collision` à la conversion si ton châssis a ses roues).
2. Lire les entrées dans `VehicleInput.Controls` (`Throttle` 0..1, `Brake` 0..1, `Steer` -1..1, `Handbrake`) et
   `VehicleInput.Action` (`GearUp`, `GearDown`, `Horn`…) ; `cfg.Handling` contient tout `handling.meta` converti.
3. Alimenter le rendu à chaque pas, exactement comme `VehicleDrive` :

```lua
Runtime.SetTelemetry(car, {
	Rpm = rpm, Gear = gear, Throttle = c.Throttle, Brake = brakeLights, Reverse = inReverse,
	Speed = speedMs,                                  -- m/s, + = avant
	Steer = steer, WheelSteer = maxSteerRad,          -- angle des roues = -Steer × WheelSteer
	WheelSpin = { wheel_lf = omega, ... },            -- rad/s, + = avant
	Suspension = { wheel_lf = travel, ... },          -- m, + = vers le haut, relatif au repos
	TyreFx = { wheel_lf = 0..1, ... },                -- traces + fumée : VehicleTyreFx.Intensity(slip, slipV, grounded)
})
```
`TyreFx` vient du glissement de chaque roue (`slip` combiné, 1 = pic d'adhérence ; `slipV` en m/s au contact) ;
`FiveMVehiclesClient` en envoie le maximum de chaque 0,1 s au serveur, qui le pose dans l'attribut `TyreFx`.
Sans `SetTelemetry`, le rendu estime le régime et la rotation des roues depuis la vitesse de `VehicleRoot`.

## Données physiques exportées (`VehicleConfig.Handling` et `VehicleConfig.Physics`)

Tout le `handling.meta` du véhicule est exporté, pour qu'un moteur de conduite n'ait rien à relire :

- **Valeurs du fichier** sous des noms courts (`MassKg`, `DriveForce`, `TractionCurveMax`, …) et
  **toutes les valeurs brutes** dans `Handling.Raw` (noms GTA d'origine, rien n'est perdu).
- **Conversions faites par le jeu au chargement** (code du chargeur de FiveM et de l'éditeur de handling d'ikt) :
  `MaxFlatVelMs` (÷3,6), `DriveMaxFlatVelMs` (×1,2 : vitesse au rupteur pour un rapport de 1,0),
  `RedlineTopGearKmh` (rapport de dernière vitesse 0,9), `SteeringLockRad`, `TractionCurveLateralRad`,
  `SuspensionCompDampScaled` / `SuspensionReboundDampScaled` (×0,1), `DragAccelCoeff` (×10⁻⁴, hypothèse
  `a = k·v²`), répartitions avant/arrière stockées comme le jeu (`DriveFront/DriveRear`, `BrakeFront/BrakeRear`,
  `TractionFront/TractionRear`, `SuspensionFront/SuspensionRear`, `AntiRollFront/AntiRollRear` = 2b et 2(1−b) ;
  transmission : b < 0,1 → propulsion, b > 0,9 → traction), `ShiftTimeUpS/DownS` (0,9 / taux d'embrayage),
  `IdleRpm` 0,2 et `RedlineRpm` 1,0 (régime normalisé GTA).
- **Repère Roblox** : `CentreOfMassLocal` et `InertiaMultiplierLocal` (x droite, y haut, z arrière, en mètres).
- **Flags décodés** : `Handling.Flags.Model/Handling/Damage` et `Handling.CarHandling.AdvancedFlags`
  (`{Hex, Names}` ; bits non documentés : `bit_0x…`), `Handling.Gearbox` (`auto` / `manual` / `electric`),
  `Handling.GravityMs2` (9,8 ; 10,78 ou 11,76 avec les flags tout-terrain).
- **Sous-handling `CCarHandlingData`** : `Handling.CarHandling` (pincement, carrossage, chasse en valeurs
  brutes et en degrés, `EngineResistance`, `MaxDriveBiasTransfer`, `AdvancedData`…).
- **Physique du `.yft`** (`VehicleConfig.Physics`) : `FragMassKg`, `FragInertia` (repère local),
  amortissements de l'archétype, `ChildMassKg` (masse par os).
- **Charnières** : `VehicleConfig.Hinges[os]` prend l'axe et l'angle d'ouverture **réels** des limites
  articulaires du `.yft` (`Source = "yft"`, gère aussi les portes en élytre / ciseaux) ; sans limite,
  heuristique et angles par défaut (`Source = "defaut"`).

Les points encore disputés (pic de la courbe d'adhérence, sens du biais d'anti-roulis, échelle de
`fTractionCurveMax`) sont détaillés dans `reports/Physique véhicules GTA V Roblox.md` à la racine du dépôt.

## Custom (côté serveur)

```lua
local Custom = require(game.ReplicatedStorage.FiveMVehicles.VehicleCustomization)
print(Custom.GetOptions(car))                         -- slots de mods, livrées, extras, perfs
Custom.SetMod(car, "Spoiler", 2)                      -- 0 = d'origine
Custom.SetColor(car, "Primary", Color3.fromRGB(10, 10, 10))   -- Primary/Secondary/Pearlescent/Wheel/InteriorTrim/Dashboard
Custom.SetPaintMaterial(car, "Primary", Enum.Material.Metal, 0.1)
Custom.SetLivery(car, 1)                              -- 0 = sans
Custom.SetExtra(car, 1, false)
Custom.SetWindowTint(car, 0.7)                        -- 0 clair → 0.95 limo
Custom.SetNeon(car, true, Color3.fromRGB(255, 0, 200))
Custom.SetXenon(car, Color3.fromRGB(120, 170, 255))   -- nil = halogène
Custom.SetPlate(car, "ROBLOX")
Custom.SetPerformance(car, "Engine", 3)               -- lu par ton moteur via Custom.GetPerformance(car)
local save = Custom.Serialize(car)                     -- table -> DataStore
Custom.Apply(newCar, save)
```
Les portes / capot / coffre s'ouvrent via ProximityPrompt (touche G) ou
`car:SetAttribute("Door_door_dside_f", 1)` côté serveur.

## Limites Roblox prises en compte

- ≤ 20 000 triangles par MeshPart : découpage automatique à 19 000 (`--max-tris`).
- Textures ≤ 1024 px (Roblox réduit au-delà) : redimensionnées, puissances de 2.
- Une seule coordonnée UV par mesh : les pièces à livrée utilisent l'UV de la livrée.
- `SurfaceAppearance` ne se modifie pas en jeu : les livrées sont des SurfaceAppearance pré-créées que
  l'on échange ; la teinte de peinture texturée passe par `SurfaceAppearance.Color` (si dispo) sinon `Part.Color`.

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
| Maj / Ctrl | croix haut / X | rapport + / − (`Input.Action`) |

Mobile : les invites s'affichent en bouton ; à bord, bouton « Descendre ».

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
| `KMu` | **1,0** | échelle de `TractionCurveMax/Min` en g — **mesuré** : le champ du jeu *est* l'accélération en g |
| `PeakFactor` | **0,55** | pic latéral = `TractionCurveLateral × PeakFactor` — **rebalayé en Studio** (0,4 à 1,0, direction mesurée) : tient le virage 40 km/h établi de GTA à 2 % près (rayon, dérive de caisse, pneus à 9,5 / 8,3 ° contre 9,35 / 8,34). Un seul pic ne tient pas aussi le créneau (qui voudrait 0,4) : le pneu Roblox est linéaire jusqu'au pic. Dérive de pneu : vitesse latérale à l'essieu avant = `vLat − a·wz` (x à droite) |
| `KappaPeak` | 0,12 | glissement longitudinal du pic |
| `Falloff` | 1,5 | largeur de la descente Max → Min |
| `FalloffKappa` | **0,1** | poids du glissement **longitudinal** dans cette descente — **mesuré** : une roue bloquée garde son pic ; dans GTA la chute est pilotée par la dérive. 1 = ancien comportement |
| `KSpring`, `KArb` | 1 | raideurs de suspension et d'anti-roulis (lois inconnues) |
| `RollCentreScale` | **0,25** | × hauteur des centres de roulis, là où `VehicleDrive` applique les forces latérales : c'est **elle** qui règle le roulis (bras de levier = centre de gravité − centre de roulis). Mesuré en Studio : 0,22 °/g à 1, 0,76 °/g à 0,25, 0,94 °/g à 0 (GTA ≈ 1,0). Sous 0,25 la roue arrière intérieure délestée patine et le virage serré perd sa motricité |
| `IwRel` | **0,03** | inertie de roue + transmission (`Iw = IwRel × r² / 4`) — **calé** : 0,25 interdisait de tenir à la fois le 0-100 et la vitesse de pointe |
| `KDrag` | **2,1** | multiplie le coefficient de traînée issu du chargement (`DragCoeff × 1e-4`), dont le facteur n'était qu'une hypothèse — **mesuré** sur le plateau de vitesse |
| `FirstGearForce` | **1,5** | gain de poussée de la 1ʳᵉ **et de la marche arrière** (même rapport) — **mesuré** : 10,5 à 12,4 m/s² là où la loi donne 6,53 |
| `UpshiftRpm`, `UpshiftRpmFirst`, `DownshiftRpm`, `DownshiftRpmThrottle`, `DownshiftMargin` | **0,95** / **0,82** / 0,45 / **0,35** / 0,85 | boîte automatique — **mesuré** : la 1ʳᵉ passe nettement plus tôt que les autres ; 2→1 sous gaz à 0,35 (0,45 rétrogradait en plein virage serré), gaz relâchés à ≈ 0,41 |
| `EngineBrakeG` | **0,9** | frein moteur au rupteur, gaz relâchés — **calé** sur les 115 m de roue libre 110 → 30 km/h |
| `LowSpeedFade` | 8 m/s | fin de la perte d'adhérence au démarrage |
| `SteerFade`, `SteerFadePower`, `SteerLockMeanPct`, `SteerMinPct`, `SteerPeakGain` | **15,0 m/s** / **2,72** / **0,875** / **0,1889** / **0** | braquage réduit avec la vitesse. **Loi mesurée** sur 20 plateaux à consigne constante de 15 à 105 km/h : `lock(v) = min(lock × 0,875, max(lock / (1 + (v/15)^2,72), lock × 0,1889))`. Le plafond 0,875 est la butée mécanique mesurée (30,625 ° pour 35 °, moyenne des deux roues, Ackermann 0,75) et `SteerMinPct` le braquage à 105 km/h : seuls `SteerFade` et `SteerFadePower` sont ajustés, RMS 0,78 °. L'ancien fondu linéaire braquait 2,3 fois trop à 105 km/h, `SteerPeakGain` étant actif dès 100 km/h alors que GTA descend **sous** l'angle du pic latéral. Le lacet de GTA est purement cinématique (`v × braquage / 2,811 m`, à 3,9 % près sur 20 plateaux) : si le braquage est juste, le lacet suit |
| `CounterSteer` | 0 | aide au contre-braquage |
| `AbsSlip`, `AbsRelease` | 0,18 / 0,35 | ABS |
| `HandbrakeGripRear` | **1,0** | adhérence latérale arrière au frein à main — **mesuré** : GTA bloque l'arrière sans lui faire perdre son adhérence latérale (0,1 °/s de lacet volant droit). Studio : reste droit (1,4–2 °/s) depuis un départ propre, mais 0,75 aussi ; entré en correction de cap, 36,5 °/s |
| `AirPitch`, `AirRoll`, `AirDamp` | 4 / 3 / 1,5 | contrôle en l'air |
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
})
```
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

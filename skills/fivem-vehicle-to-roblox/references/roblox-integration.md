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
```
Chaque siège porte `Side` (-1 gauche, 1 droite) et `Door` (os de la portière), et son invite
`VehicleRoot/Enter_<siège>/EnterPrompt` (attributs `SeatName`, `Available`). Les pièces de collision du
véhicule sont dans le groupe `FiveMVehicle`, les occupants dans `FiveMVehicleOccupant` (non collisionnables
entre eux). Les cylindres de roues sont solides par défaut (le véhicule désancré repose dessus) ;
`--no-wheel-collision` les rend non solides pour un moteur à roues propres.

## Brancher ton moteur physique

```lua
-- LocalScript (client du conducteur), dans ton propre moteur
local RS = game:GetService("ReplicatedStorage")
local FiveM = RS:WaitForChild("FiveMVehicles")
local Input = require(FiveM.VehicleInput)
local Runtime = require(FiveM.VehicleRuntime)

game:GetService("RunService").Heartbeat:Connect(function(dt)
	if not Input.Enabled then return end          -- le joueur n'est pas au volant
	local c = Input.Controls                       -- Throttle 0..1, Brake 0..1, Steer -1..1, Handbrake
	local car = myCurrentCar                      -- le modèle conduit
	local cfg = require(car.VehicleConfig)        -- cfg.Handling (masse, rapports, freinage…), cfg.Wheels
	-- … ta physique ici …
	Runtime.SetTelemetry(car, {                    -- facultatif mais recommandé
		Rpm = rpm, Gear = gear, Throttle = c.Throttle, Speed = speedMs,
		WheelSpin = { wheel_lf = wLf, wheel_rf = wRf, wheel_lr = wLr, wheel_rr = wRr },   -- rad/s
		Suspension = { wheel_lf = compLf, ... },   -- mètres (+ = vers le haut)
		WheelSteer = math.rad(35),                 -- angle de braquage max réel (rad), optionnel
	})
end)

Input.Action.Event:Connect(function(name, value)  -- "GearUp", "GearDown", "Horn", "Headlights"...
	if name == "GearUp" then --[[...]] end
end)
```
Sans `SetTelemetry`, le rendu estime le régime et la rotation des roues depuis la vitesse de
`VehicleRoot` (`AssemblyLinearVelocity`) et `cfg.Handling` (rapports, vitesse max).

Les contrôles sont modifiables : `Input.Bindings.Horn = { Enum.KeyCode.E, Enum.KeyCode.ButtonL3 }`
(avant que le joueur monte), `Input.SteerSpeed`, `Input.Deadzone`.

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

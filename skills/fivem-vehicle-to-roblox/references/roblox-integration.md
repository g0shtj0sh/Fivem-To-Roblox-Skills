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
├─ Neons/           4 tubes invisibles calés sous la caisse + 2 SurfaceLight chacun (vers le bas, dehors et dessous)
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
| `Backfire` | bool | retours de flamme : true toujours, false jamais, absent = seulement avec un échappement amélioré (`Mod_Exhaust` > 0), comme GTA |
| `BackfireSoundId` | string | son d'une détonation (aussi sur `ReplicatedStorage.FiveMVehicles`) ; vide = flamme muette |
| `TyreSmokeColor` | Color3 | couleur de la fumée de pneus (comme dans GTA ; défaut gris clair) |
| `TyreFxEnabled` = false | bool | sur le véhicule : coupe traces et fumée (avant le 2026-11-16 : `TyreFx = false`, écrasé par l'attribut numérique dès qu'on conduisait) |
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
| **V** | — | vue suivante : poursuite proche → poursuite → capot → cockpit (`VehicleCamera`) |
| C | R3 | regarder derrière (toutes les vues) |
| clic droit + souris | stick droit | regarder autour (poursuite, capot) ; recentrage auto en roulant |
| **B** | — | rétroviseur virtuel en haut de l'écran (`VehicleMirror`) |

Mobile : les invites s'affichent en bouton ; à bord, bouton « Descendre ».

## Caméra façon Assetto Corsa (`VehicleCamera`) et rétroviseur (`VehicleMirror`)

Client de l'occupant. Quatre vues, cycle par **V** : `ChaseNear` (poursuite proche), `Chase` (poursuite), `Bonnet`
(capot), `Cockpit` (œil GTA du siège, l'ancienne « vue intérieure »). En montant : cockpit si le joueur était en
première personne, sinon la dernière vue extérieure (`DefaultView` au début).

**Poursuite** — comportement relevé sur DynaCam (chase cam CSP d'Assetto Corsa, kirbyguy22 ; licence : modification
sur permission → comportement réécrit, aucun code repris) et sa version « Imagined Visuals » :
- réglages en **mètres / degrés** (`Distance`, `Height`, `Pitch`), convertis par le `StudsPerMeter` du véhicule ;
  distance comptée depuis l'essieu arrière (centre des roues + ¼ d'empattement + 1,5 demi-empattement) ;
  `Height` = hauteur de la caméra au-dessus du centre des roues + 0,15 m (≈ centre de gravité), `Pitch` penche la vue ;
- suit la **direction de la vitesse** dès ~1 m/s (`VelocityFollow`), lissée (10/s), angle de glisse exagéré
  (`SlipExaggerate` : 0,32 rad max) ; en marche arrière (vitesse·capot < −0,25) pas d'orbite ;
- suit la pente (composante verticale lissée 4/s) ; `AccelFx` (recul à l'accélération / rapprochement au freinage,
  saturé, ∝ empattement), `BrakeDip` (plongée ≤ 7°), `RollFx` (≤ 3,4°, zone morte), `BumpFx` (ressort amorti sur
  l'à-coup vertical), `SpeedShake` (sigmoïde de la vitesse, centre `ShakeSpeed` m/s), `Impact` (secousse aux chocs) ;
- `FovDynamic` + `FovGain` : FOV vertical + gain × sin(atan(v/36)) ; la distance est corrigée pour garder la
  voiture à la même taille (« dolly zoom ») ;
- `Collide` : un obstacle entre le toit et la caméra la rapproche.
Presets (`Camera.ApplyPreset`) : **Calm** = Imagined Visuals (FOV 72 fixe, sans recul / plongée / roulis) ;
**Dynamic** = DynaCam (FOV 55 → ~80, tous les effets). Réglages d'origine fournis par l'utilisateur : *cinématique*
2,4 m / 1,15 m / 13° (`ChaseNear`), *jouable* 2,8 m / 1,25 m / 15° (`Chase`).

API : `Camera.SetSettings(partial)` (fusion profonde), `GetSettings()`, `ApplyPreset(name)`, `SetView`, `CycleView`,
`GetView`, `IsPov` (cockpit), `Changed(settings, view)`. Attributs du véhicule : `ChaseCamera = false` (caméra de Roblox
pivotant sur l'œil), `PovCamera = false` (pas de cockpit).

Mesures (Studio, m422, 2026-11-16) : en ligne droite caméra alignée (0°) ; en glisse de 53° la caméra est à 72° du
capot (suit la trajectoire + ~18°) ; Dynamic : FOV 55° à l'arrêt → 80° à 120 km/h. Cadrage ChaseNear comparé aux
vidéos de référence : voiture en bas au centre, ≈ 25 % de la largeur, horizon vers le tiers haut.

**Révision (2026-11-16, retour de l'utilisateur sur capture)** : les défauts sont calés en Studio sur les vidéos de
référence, en comparant une capture et une image de référence **à la même hauteur** (le FOV de Roblox est vertical)
et en mesurant une grandeur commune (`brolver-rp/scripts/camera-refs/compare.py`) : cockpit FOV 55 + œil avancé de
3 cm (volant ≈ 0,7 × la hauteur d'écran, comme la référence) ; poursuite proche 2,9 m / 1,15 m / 3° ; poursuite
3,2 m / 1,55 m / 10° ; **angle fixe** : la vue ne tourne que pendant un appui (clic droit, stick, doigt) et revient au
centre ; poursuite fixe derrière la voiture (`VelocityFollow = 0`, `SlipExaggerate = 0`). Tête : accélérations
dérivées d'une vitesse lissée puis lissées (6/s) ; seules les rotations lentes sont stabilisées (`Bandwidth` 2,5 Hz,
`RotationScale` 0,5) — stabilisée à toutes les fréquences, notre caisse qui vibre faisait danser l'habitacle
(17,5 °/s en ligne droite) ; regard dans le virage 0,04 / 6° max ; inclinaison latérale divisée par deux. Mesuré
(m422, ligne droite > 30 km/h) : rotation de l'image 6,8 °/s avec la tête contre 13,6 sans ; habitacle 3,9 °/s.

**Poursuite en drift (2026-11-16, retour de l'utilisateur avec vidéo)** : la poursuite suit la TRAJECTOIRE
(`VelocityFollow = 1`, défaut) : en drift la voiture tourne librement devant une caméra qui garde le sens de la route
(de profil à 90° de glisse, de face en toupie) — c'est ce que montrent les vidéos de référence ; collée au capot
(`VelocityFollow = 0`), « on a toujours la vue arrière ». La marche arrière n'est plus déduite du sens du mouvement
(une toupie recule aussi, et l'attribut `Reverse` passe alors à true) : on n'y entre qu'en reculant depuis moins de
1,5 m/s (`ReverseEnterSpeed`). Direction lissée par l'angle (`FollowRate` 6/s), jamais par mélange de vecteurs
(passage par zéro sur un demi-tour). Mesuré (m422) : caméra à 3–6° de la trajectoire en drift et en toupie jusqu'à
164° de glisse ; revient derrière la voiture à l'arrêt ; reste derrière le capot en vraie marche arrière.

**Deux poursuites (2026-11-16)** : `ChaseMode = "Dynamic"` (défaut, façon GTA V : derrière le capot avec retard,
3/s à pleine vitesse et ×0,25 à l'arrêt, 30 % de trajectoire en glisse ; regard libre qui reste en place et ne revient
qu'en roulant après `RecenterDelay` ; molette = zoom ×0,7–1,8 ; vue plus haute `Dynamic.ChaseNear/Chase` ; effets
doux `Dynamic.Fx`, FOV +6° à 108 km/h) ou `"Fixed"` (Assetto Corsa : garde la trajectoire, `FollowRate` 3/s, point
visé avancé le long de la vue). Capot et cockpit communs. Mesuré (m422) : dynamique 6–7° de retard en virage normal,
retour du regard en ~2 s en roulant ; fixe 0–8° de la trajectoire en drift. Cockpit : gains de tête séparés
(`Neck.Forward.Accel` 2,2 / `Brake` 0,5, `ForwardPitchAccel` 0,5) → 6,2 cm en arrière + 2,5° à l'accélération,
2,4 cm en avant + 1,8° au freinage ; FOV 60.

**Suspension vue par les autres joueurs (2026-11-16)** : seul le conducteur simule les roues (`VehicleDrive`) et sa
télémétrie (`Suspension`, `WheelSpin`…) reste sur son PC ; la caisse, elle, est répliquée par Roblox (avec le
retard et le lissage de la réplication — inévitable). Sans rien d'autre, chez un passager ou un piéton les roues
restaient figées au repos pendant que la caisse bougeait. `VehicleRuntime:_estimateSuspension` : chaque client qui
ne conduit pas sonde lui-même le sol sous chaque roue avec la géométrie du moteur de conduite (un spherecast par roue,
`Dyn.new(cfg).P.wheels`), lissé 25/s, pour les véhicules à moins de `SuspensionEstimateDistance` (200 studs) de sa
caméra. Mesuré (passager, voiture lâchée de 3 studs) : roues pendantes −18 cm en l'air, compression à l'impact,
retour au repos en ~0,4 s.

**Multijoueur (audit 2026-11-16, test à 2 joueurs + revue du code)** : débit limité par joueur et par action côté
serveur (télémétrie 15/s, bascules 8/s, vitres 4/s, siège 2/s) ; vitres : seulement les vraies vitres du modèle
(`Custom.WindowBones`), verrouillé = occupants seulement, `Serialize`/`Apply` ne gardent que les clés connues ;
télémétrie arrondie (régime /25, braquage /64) ; le conducteur envoie le braquage EFFECTIF (fraction de la butée
mécanique), pas la touche ; feux stop maintenus sur l'envoi ; à la sortie du conducteur `Rpm`, `Gear` effacés et
`Reverse` remis à faux ; braquage et régime lissés chez les autres ; clignotants et sirène sur le temps serveur ;
feux des véhicules lointains mis à jour 5 fois/s ; contrôle de rotation (> 20 rad/s pendant 0,5 s) et compteur
d'infractions par joueur (`F2R_DriveStrikes`, journalisé, sans sanction) ; vitesse permise selon Perf_/Tune_.
Clignotants : pièces `indicator` allumées en Neon entier (`Runtime.NeonFamilies`) — la zone des clignotants est
sombre dans le masque d'émission des feux de la m422, ils étaient invisibles ; extinction automatique après le
virage (volant > 35 % du côté du clignotant puis < 8 %). Nouveau : régulateur (`Y`, `Drive.ToggleCruise("cruise")`,
coupé par frein / frein à main / marche arrière, PI sur l'accélérateur) et limiteur (`U`, "limit"), signal
`Drive.CruiseChanged(mode, kmh, raison)`, champs `Cruise`/`CruiseSpeed`/`Blink` de `VehicleDashboard.Read` ; vitres
avant (`K`) ; `VehicleInput.Labels` (libellés pour un panneau des touches). Mesuré : régulateur 57–58 km/h pour
57,9 ; limiteur 55–56 km/h accélérateur à fond ; 200 envois de télémétrie en 1 s → 34 écritures du régime.

**Teintes de vitres et texture de verre (2026-11-18)** : la `SurfaceAppearance` des vitres doit être en
`AlphaMode.Overlay`. En `Transparency`, l'alpha de la texture décide seul : `Part.Transparency`, `Part.Color` et même
`SurfaceAppearance.Color` sont ignorés, donc les 7 teintes rendaient exactement pareil (mesuré en Play sur BavrenN4 :
transparence 0 + rouge vif = aucun changement). En Overlay, la texture se pose sur `Part.Color` et la transparence de
la pièce s'applique (teinte, vert, vitre baissée = 1). Le Setup pose Overlay ; `Custom.Refresh` et `setupVehicle`
(serveur) convertissent les véhicules installés avant. Transparences : Aucune 0.88, D'origine 0.45, Fumé clair 0.40,
Fumé foncé 0.25, Limousine 0.13, Noir intégral 0.04, Vert 0.40 (le matériau Glass éclaircit beaucoup : l'ancienne
plage 0.6 → 0.03 confondait Aucune / Fumé clair / D'origine).

**Vitres, plafonnier, plaque, klaxon (2026-11-16)** : la texture des vitres du mod (`vehicle_generic_glasswindows*` :
bordure noire, dégivrage) est mise en ligne à part (`glass/`, id lu avec les sons) et posée par le Setup en
SurfaceAppearance à transparence (attribut `GlassTexture`) ; une vitre qui casse (`WindowBroken_<os>`) lance des
éclats en particules sur chaque client (un émetteur par vitre, ≤ 30 éclats, détruit après 1,2 s, rien au-delà de
150 studs ; image `Runtime.GlassShardTexture` ou attribut `GlassShardTexture`). Plafonnier à l'os `interiorlight`
(portière ouverte, ou touche `I` → attribut `InteriorLight`), éclairage de plaque à l'os `platelight` avec les feux
(`Runtime.CabinLights`). Klaxon : `periodic_loop` (attaque retirée, fin choisie là où l'onde se raccorde, fondu
≤ 10 ms vers ce qui précède le départ) — l'ancien `_loopify` pompait le volume à chaque tour (mesuré sur 11 klaxons :
0,24–0,78 → 0,11–0,33).

**Cockpit : tête physique** (`Settings.Neck`, comportement relevé sur NeckFX / AC Head Physics de Jack Sankey &
Jordash, réécrit) : un ressort amorti par axe (`x'' = −2ζω·x' − ω²·x + a`, fréquence en Hz, amortissement 0..1).
Déplacements avant / côté / vertical poussés par les accélérations du véhicule **en g** (vertical passé en
passe-haut, `Recenter` s) ; rotations tangage / roulis / lacet : on retranche la rotation du véhicule (tête stable
dans le monde) puis le ressort ramène vers l'habitacle (`Tracking` = suivi des yeux : passe-haut sur la vitesse de
rotation, fréquence × 1,2, amortissement × 0,5) ; pivots (`ForwardPitchPivot`, `SideRollPivot`, `SideSighting`) ;
regard dans le virage = `SteerFollow` × angle du volant (verrou de braquage × `SteerRatio`), borné `SteerMax`,
lissé `Smoothing` s (conducteur local : direction de `VehicleDrive`, passager : attribut `Steer`) ; à-coup au
passage de rapport (`GearKick`) ; effets nuls sous `ThresholdKmh`, pleins à `FullKmh` ; garde-fous `Limits`.
Défauts = preset « NeckFX Imagined Visuals » fourni par l'utilisateur ; FOV cockpit 100 (conseil du pack), regarder
derrière 130° (par-dessus l'épaule, lissé). Mesuré (m422) : accélération → tête 2,8 cm en arrière et vue +2° ;
freinage → 4,6 cm en avant, −3,5° ; virage → 1,8 cm vers l'extérieur, roulis 5°, regard 20° dans le virage ; tout à
0 à l'arrêt.

**Rétroviseur** (`VehicleMirror`, **éteint par défaut**, touche **B**, bouton « Rétro » sur mobile) : rectangle en haut au centre (27 % de
la largeur, 4:1), `ViewportFrame` + `WorldModel` de **copies** (Roblox ne rend pas le monde deux fois) :
véhicules tagués derrière (≤ `Range` studs, `MaxPartsPerVehicle` plus grosses pièces, `BulkMoveTo` à chaque image),
décor (`GetPartBoundsInBox` derrière le véhicule, budget `MaxDecorParts`, `NewPerRefresh` par relevé),
**terrain relevé en dalles** (grille `TerrainCell` studs, hauteur et couleur de la matière : les routes en terrain
apparaissent), ciel / lumière de `Lighting`. Effet miroir : monde copié **et** caméra reflétés (x → −x, rotations
M·R·M), gauche et droite inversées comme un vrai rétro, objets non retournés.
Coût mesuré (Studio PC, ville en terrain + pièces) : 0,5 ms/image à l'arrêt, 0,9 ms en moyenne et 1,5 ms au pire
en roulant à 73 km/h (364 dalles, ~30 pièces de décor, 1 véhicule). Non mesuré sur téléphone.

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
	TyreFx = { wheel_lf = 0..1, ... },                -- traces + fumée : VehicleTyreFx.Intensity(roue, dérive)
})
```
`TyreFx` vient du glissement de chaque roue (`out.wheels[i]` : `slip` combiné, 1 = pic d'adhérence ; `slipLong` et
`slipLat` en m/s au contact) et de l'angle de dérive de la voiture (`VehicleTyreFx.DriftAngle(vBody, wBody, rearZ)`, ° à l'essieu arrière) : le patinage
ou le blocage marque seul, la glisse de côté seulement si la voiture dérive (`DriftStart` / `DriftFull`) ;
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

## Performances réelles et améliorations (`VehicleConfig.Performance`, attributs `Perf_*`)

La conversion cale le moteur et la boîte sur la fiche réelle du véhicule (`specs/vehicle_specs.json`,
SKILL.md § 1f) ; l'adhérence, la suspension, la direction et les freins restent ceux du mod.

| `VehicleConfig.Performance` | Contenu |
|---|---|
| `Vehicle`, `Specs`, `Sources` | vrai modèle, fiche complète et ses sources |
| `Target` | cibles du calage : `ZeroTo100S`, `VmaxKmh` (débridée), `LimiterKmh`, `Gears`, `ShiftTimeS` |
| `LimiterKmh` | vitesse bridée d'origine : limiteur électronique du moteur de conduite (absent = non bridé) |
| `Fitted`, `Result` | calage fait ; mesures au banc : 0-100, 0-200, vitesse bridée / débridée, passages |
| `Upgrades.Max` | aperçu tout amélioré (moteur 4, boîte 3, turbo, débridé) |
| `Mod` | valeurs du handling du mod remplacées (DriveForce, rapports, vitesse plate, traînée, embrayage, régimes du son) |

Améliorations : `Custom.SetPerformance(car, slot, niveau)` (serveur) borne le niveau et pose `Perf_<slot>`
(0 = d'origine, attribut retiré) ; `VehicleDrive` les relit à chaque changement, même en roulant
(`VehicleDynamics.SetUpgrades`). `Custom.PerformanceSlots(car)` donne le niveau maximal de chaque slot,
`Custom.GetPerformance(car)` les niveaux et pourcentages en cours. Sauvegardés par `Custom.Serialize`.

| Slot | Niveaux | Effet (`VehicleDynamics`) |
|---|---|---|
| `Engine` | 1-4 | DriveForce × (1 + 0,2 × statMods / 100) — DATAMINÉ (100 % → +20 %) |
| `Transmission` | 1-3 | +1 rapport dès le niveau 1, embrayage × max(1 + statMods / 100, `Tuning.TransmissionClutchMult` 1,5 / 2,25 / 3) |
| `Brakes` | 1-3 | BrakeForce × (1 + statMods / 100) **et** adhérence au freinage + `Tuning.BrakeGripPerLevel` (7 / 14 / 22 %) |
| `Suspension` | 1-4 | caisse abaissée de `Tuning.SuspensionLowerM` (1,5 / 3 / 4,5 / 6 cm, roues dessinées en conséquence, aussi chez les autres joueurs), raideur × (1 + 0,5 × statMods / 100), anti-roulis × (1 + 0,2 × niveau) |
| `Turbo` | 1 | + `Tuning.TurboGain` (10 %) de couple une fois chargé (`TurboSpool` 1,2 s) ; `out.turbo` pour un sifflement |
| `Unlimited` | 1 | débridage : lève `Performance.LimiterKmh` (proposé seulement si le véhicule est bridé) |
| `Armor` | 1-5 | aucun effet de conduite (comme GTA) |

Les pourcentages (`statMods`) viennent du carcols du véhicule (`VehicleConfig.StatMods`), à défaut
`VehicleDynamics.UpgradeDefaults` (Engine 25/50/75/100, Transmission 25/50/75, Brakes 20/40/60,
Suspension 20/40/60/80). Seule la loi du moteur est documentée par GTA ; les autres sont posées.

**Chaque niveau doit se sentir** (2026-11-16, mesuré sur le m422, piste `TestTrack` + `DriveBench`, PC Studio, une
mesure par niveau). Avant : freins ×2 = 100-0 en 20,5 → 20,4 m (le freinage plafonne à l'adhérence, pas à la force),
suspension +11 % = roulis 1,39 → 1,26°, transmission 1 ≈ 3. Après : **freins** 100-0 21,0 / 19,5 / 18,2 / 17,1 m ;
**suspension** caisse 0,488 / 0,472 / 0,457 / 0,427 m (niveaux 0/1/2/4), roulis à 60 km/h 1,39 / 1,18 / 1,02 / 0,77°,
centres des roues dessinées toujours à 0,328 m du sol ; **transmission** passage 0,147 / 0,095 / 0,067 / 0,051 s,
0-100 3,54 / 3,42 / 3,32 / 3,28 s ; **moteur 4** 0-100 3,52 → 2,72 s. Piège : dans ce moteur `P.raise` REMONTE la roue
dans la caisse (haut de course = rest + upper + raise) ; abaisser = augmenter `raise` (essai inverse : la caisse montait).

## Custom (côté serveur)

```lua
local Custom = require(game.ReplicatedStorage.FiveMVehicles.VehicleCustomization)
print(Custom.GetOptions(car))                         -- slots de mods, livrées, extras, perfs
Custom.SetMod(car, "Spoiler", 2)                      -- 0 = d'origine
Custom.SetColor(car, "Primary", Color3.fromRGB(10, 10, 10))   -- Primary/Secondary/Pearlescent/Wheel/InteriorTrim/Dashboard
Custom.SetPaintMaterial(car, "Primary", Enum.Material.Metal, 0.1)
Custom.SetLivery(car, 1)                              -- 0 = sans
Custom.SetExtra(car, 1, false)
Custom.SetWindowTint(car, 0.7)                        -- 0 clair → 0.95 noir (transparence = 0.88 × (1 − amount))
Custom.SetNeon(car, true, Color3.fromRGB(255, 0, 200))
Custom.SetXenon(car, Color3.fromRGB(120, 170, 255))   -- nil = halogène
Custom.SetPlate(car, "ROBLOX")                        -- plaque imposée par le jeu (voir « Plaques »)
Custom.SetPerformance(car, "Engine", 3)               -- appliqué en direct par le moteur de conduite (voir « Performances »)
local save = Custom.Serialize(car)                     -- table -> DataStore
Custom.Apply(newCar, save)
```

### Néons : règle (2026-11-18, décision de l'utilisateur)
Un néon de véhicule est une **vraie lumière Roblox**, comme dans GTA V : on ne voit pas les barres, on voit leur
lumière au sol. **Jamais** d'image, de `SurfaceGui`, de plaque dessinée ou d'« UI » pour la nappe (essai rejeté :
« ce n'est pas une UI »). Ce que fait le runtime (`VehicleCustomization.LayoutNeons`, une fois par véhicule, côté
serveur, attribut `Neons.Layout`) :
- tubes **mesurés** sur la géométrie : rayons tirés du dessous contre les pièces de collision `CanQuery` (roues
  exclues) ; latéral au bord du bas de caisse, long de l'avant de la roue avant à l'arrière de la roue arrière
  (`SideReach`) ; avant / arrière sous les boucliers ;
- tubes **invisibles** (`Transparency = 1`, `NeonLit` dit s'ils sont allumés) ;
- **une chaîne de `PointLight` à ombres par tube** (v7, 2026-11-18, retour « la lumière n'est pas diffusée de
  manière assez homogène » ; références : photos de kits LED réels et captures GTA Online) : une lumière tous les
  0,4 m (`LightSpacing`), rentrées de 0,3 m vers l'axe sous le bas de caisse (`SideLightInset`), 0,05 m à l'avant /
  l'arrière (`EndLightInset` : 0,3 éclaire l'intérieur des jantes avant, 0,14 la calandre par dedans) ; portées
  1,45 m (côtés) / 1,15 m (bouts) ; `Brightness` 7 ; 15 lumières sur BavrenN4. Les disques se recouvrent en une
  bande continue, la plus forte au ras de la caisse, dégradé doux sur ~0,5–1 m, dessous éclairé, roues sombres.
  **Ombres obligatoires** : sans elles jantes, passages de roue et habitacle se teintent (essayé). Coût des 15
  lumières à ombres non mesuré (PC Studio) ; téléphone non vérifié. Juger la voiture **posée sur ses roues** : un
  prototype qui flottait de 0,2 m donnait une nappe plus large et plus claire. Historique : v3–v6 en `SurfaceLight`
  (deux par tube, `Angle` 150) donnaient des rectangles aux bords durs et des taches séparées ;
- à éviter : une seule lumière inclinée vers l'extérieur (nappe seulement au bord, rien dessous : refusé, « trop sur
  les bords ») ; une seule lumière droite vers le bas (trop rasante, nappe cachée sous la caisse) ; `PointLight` sous
  la caisse **sans ombres** (teinte jantes, carrosserie et habitacle) ; `Angle` 120 (rectangles à bords nets).
**Vérifier une lumière** caméra posée depuis ~2 s : juste après un déplacement de caméra, le rendu des petites
lumières n'est pas à jour (une capture `frame` a montré une `SurfaceLight` « éteinte » à tort).
Les portes / capot / coffre s'ouvrent via ProximityPrompt (touche G) ou
`car:SetAttribute("Door_door_dside_f", 1)` côté serveur.

### Peintures GTA et finitions

`ReplicatedStorage.FiveMVehicles.VehiclePaints` (module **généré** par `scripts/f2r/gta_colors.py`, partagé
client / serveur) : les 160 peintures de véhicule GTA V par index carvariations (`Name` d'origine, `Label`
français, `Color`, `Group`, `Finish` par défaut). `Paints.Group("Classic" | "Matte" | "Metals" | "Chrome" |
"Utility" | "Worn" | "Alloy")` donne la liste d'un menu, `Paints.Nearest(color)` la peinture la plus proche.

```lua
Custom.SetPaint(car, "Primary", 28)              -- peinture n° 28 (Rouge Torino), finition par défaut (Metallic)
Custom.SetPaint(car, "Primary", 28, "Classic")   -- même teinte, vernis classique
Custom.SetCustomColor(car, "Primary", Color3.fromRGB(10, 200, 90))  -- hors palette (Paint_Primary effacé)
Custom.SetFactoryColors(car, 2)                  -- combinaison d'usine n° 2 (VehicleConfig.Colors.Variations)
Custom.LayersPresent(car)                        -- { Primary = true, ... } couches qui ont des pièces
```

Attributs posés (répliqués, sauvés par `Serialize`) : `Color_<couche>`, `Paint_<couche>` (index, absent pour
une couleur libre), `Finish_<couche>`, `FactoryColors`. Finitions (`Custom.FinishLooks`) : Classic, Metallic,
Pearl, Matte, Metal, Chrome, Worn → matériau + `Reflectance` des pièces peintes **sans** SurfaceAppearance (une
SurfaceAppearance impose son rendu : seule la couleur s'y applique). Les pièces visuelles sont `Massless` sans
collision : la finition ne change pas la conduite. Le nacré (`Pearlescent`) n'a de pièce que si le modèle en a.

## Plaques d'immatriculation (`VehiclePlates`)

Comme dans GTA V, le texte n'est pas dans la texture de la plaque : il est dessiné dans la **zone de texte
du shader GTA** (`LicensePlateFontExtents`), retrouvée à la conversion sur chaque plaque (`CONFIG.Plates.Zones` :
rectangle de la plaque, zone de texte `TextRect`, avant / arrière). Le Setup pose une surface invisible
`PlateSurfaceFront` / `PlateSurfaceRear` sur chaque plaque, avec une SurfaceGui `Plate` : fond (`Background`)
+ 8 cases de caractères centrées (`PlateText/C1..C8/Glyph`). `vehicles.meta` `plateType` est respecté
(avant + arrière, arrière seule, aucune).

- **Plaque unique** : à l'apparition, le serveur appelle `Plates.Register(car)` : la plaque est gardée si elle
  est libre, sinon une plaque est générée au format GTA (`Plates.Format = "##AAA###"`, ex. « 46EEK572 »).
  Les copies d'un même modèle reçoivent donc chacune leur plaque.
- **Styles** : `Plates.RegisterStyle(n, def)` puis `Plates.SetStyle(car, n)` (attribut `PlateStyle`).
  `def` : `Name`, `BackgroundColor`, `Background` (image de toute la plaque, `rbxassetid://…`), `TextColor`,
  `Font` (police Roblox), `Atlas` (planche de caractères : `{ Image, Chars, Columns, CellSize }`, prioritaire
  sur `Font`), `LetterFill`, `KeepOriginal` (garder la texture d'origine du mod). Style 1 par défaut : plaque
  neutre claire, texte bleu foncé, police standard à chasse fixe ; il recouvre la plaque d'origine du mod.
- **Recherche** : `Plates.Lookup("46EEK572")` → `{ Model, OwnerUserId, Text }` (ou `nil`).
- **Plaque imposée par le code du jeu** : `Plates.Assign(car, texte, { OwnerUserId = id })` ou
  `Custom.SetPlate(car, texte)` → `true, texte` ou `false, raison` (`invalid`, `taken`, `store`). Non filtrée :
  réservée aux textes choisis par le jeu.
- **Plaque personnalisée d'un joueur** : `Plates.RequestCustom(player, car, texte)` : nettoyage (A-Z, 0-9,
  espace), **refus** au-delà de 8 caractères (`too_long` : jamais coupé en silence, le joueur doit voir la
  plaque qu'il a demandée), **filtre de texte obligatoire** (`Plates.FilterText`, par défaut
  `TextService:FilterStringAsync` + `GetNonChatStringForBroadcastAsync`), unicité.
  Raisons de refus : `invalid`, `too_long`, `filtered`, `filter_error`, `taken`, `store`. À appeler depuis un
  RemoteEvent du jeu (menu de custom), jamais avec un texte non filtré.
  **Roblox ne filtre rien dans Studio** (mesuré le 2026-11-16 : « FUCK », « fuck you », un lien discord et un
  numéro de téléphone reviennent intacts) : en Studio une grossièreté est donc ACCEPTÉE (avertissement unique
  dans la sortie) ; le refus `filtered` ne s'observe qu'en serveur publié. Pour le tester, remplacer
  `Plates.FilterText` le temps de l'essai (c'est ce que fait Verify). Un jeu peut le remplacer par une règle
  plus stricte (liste maison + filtre Roblox), jamais plus permissive.
- **Véhicules installés avant les plaques à cases** (plaque = un simple `TextLabel` `PlateText`) : le runtime
  leur écrit le texte dans ce label (sinon les cases se superposaient à l'ancien texte : plaque illisible).
  Ils gardent la texture d'origine du mod (« San Andreas ») tant que leur Setup n'est pas refait.
- La plaque est libérée à la destruction du véhicule quel que soit le chemin d'attribution (`Register`,
  `Custom.SetPlate`, `Custom.Apply`). `Custom.Plates()` renvoie le registre utilisé par `Custom` (en Edit,
  une seule copie du module par exemplaire de `Custom`).
- **Persistance** (facultative) : `Plates.SetStore(Plates.DataStore("Plates_v1"))` réserve les plaques des
  véhicules possédés (`OwnerUserId`) dans un DataStore (une clé par plaque, réservation atomique). Sans
  stockage, les plaques valent pour la session du serveur. Un stockage maison doit fournir `Reserve(text, info)`,
  `Release(text)`, `Get(text)`.
- `Custom.Serialize` / `Apply` sauvegardent `PlateText` et `PlateStyle`. La lampe de plaque (rôle `plate`,
  allumée avec les phares) est posée par `VehicleLights.Rig` au-dessus de la plaque arrière.

### Plaques propres au jeu (images)

Le skill ne fournit qu'une plaque neutre. Un jeu qui a ses propres plaques les donne au runtime **depuis son
code serveur**, au démarrage (le runtime est installé dans la place : attendre `ReplicatedStorage.FiveMVehicles`) :

```lua
Plates.UseStyles({
    { Name = "Classique", Background = "rbxassetid://…", BackgroundColor = Color3.fromRGB(52, 61, 68),
      TextColor = Color3.fromRGB(27, 42, 74), TextRect = { 0.08, 0.371, 0.84, 0.4 }, Weight = 3 },
    -- …
}, { Random = true })
```

- Le fond (image ou couleur) est mis **dans la texture de la plaque du modèle** (MeshPart « plate » qui porte la
  surface : `TextureID`, sa SurfaceAppearance d'origine rangée dans `F2R_OriginalLook`, remise pour `KeepOriginal`) :
  ses UV couvrent toute l'image comme la plaque GTA d'origine. La surface `PlateSurface*` ne porte que les
  caractères, à 2,5 mm de la plaque (posé devant, le fond laissait voir la plaque d'origine et une épaisseur).
  Image fraîchement mise en ligne : `MeshPart.TextureID` peut échouer quelques minutes (« No asset content
  representation found ») alors qu'une ImageLabel l'affiche déjà ; vérifier le chargement avant de conclure.
- `Background` : image de **toute** la plaque, appliquée par ses UV ; préparer les images au rapport des plaques
  GTA (≈ 2:1) et en 1024 × 512 au plus (Roblox plafonne à 1024 px). `BackgroundColor` est dessinée derrière : elle
  se voit dans les coins arrondis transparents (prendre la couleur du bord de la plaque).
- `TextRect` : zone libre de CETTE image où écrire le numéro (fractions x, y, largeur, hauteur), mesurée sur
  l'image (bande unie entre titre et décor) ; sans `TextRect`, le texte reste dans la zone du shader GTA. La zone
  d'origine est gardée en attribut `ZoneRect` du cadre `PlateText` (retour possible à un style sans image).
- `Random = true` : chaque véhicule qui apparaît reçoit un style tiré au sort (pondéré par `Weight`, déterministe :
  même plaque → même style, donc des copies différentes), sauf si un style a été **choisi** (`Plates.SetStyle`,
  `Custom.SetPlateStyle` → attribut `PlateStyleChosen`, sauvegardé par `Custom.Serialize` et remis par `Apply`).
  Le serveur réapplique la config de chaque véhicule à son apparition : un `PlateStyle` présent ne veut pas dire
  « choisi ». Les véhicules déjà présents sont redessinés (et retirés au sort) à l'appel.
- Police : celle du style par défaut (RobotoMono Bold, chasse fixe). Une police proportionnelle dans les 8 cases
  donne des lettres de tailles inégales (chaque case est mise à l'échelle seule) : la garder à chasse fixe.
- Index des styles = position dans la liste (1..n) : c'est ce qui est sauvegardé (`PlateStyle`) ; n'insérer de
  nouveaux styles qu'à la fin.
- Contrôle : Verify (groupe custom) vérifie `SetPlateStyle` (fond, `PlateStyleChosen`) et que le texte suit le
  `TextRect` du style.

## Brancher un menu de custom (vMenu ou autre)

Le skill fournit le côté véhicule ; le menu (interface, navigation, qui y a accès) appartient au jeu.

1. **Côté serveur, le jeu pose sa règle d'autorisation** — sans elle, toute demande est refusée :
   ```lua
   local Custom = require(game.ReplicatedStorage.FiveMVehicles.VehicleCustomization)
   Custom.SetRemotePolicy(function(player, model, op)
   	return isAdmin(player) and estAssisDans(player, model) -- règle du jeu (admin, propriétaire, garage...)
   end)
   ```
   Le module est le même pour tous les scripts serveur : l'ordre de chargement ne compte pas.
2. **Côté client, le menu envoie** `FiveMVehicles.VehicleEvent:FireServer(model, "Custom", op, ...)` :

   | op | arguments | effet |
   |---|---|---|
   | `"Paint"` | couche, index de palette, finition ou nil | `SetPaint` |
   | `"Color"` | couche, `Color3` | `SetCustomColor` |
   | `"Factory"` | n | `SetFactoryColors` |
   | `"Mod"` | emplacement (`VehicleConfig.Mods`), index 0..n | `SetMod` (0 = d'origine) |
   | `"Perf"` | emplacement (`Engine`, `Brakes`, `Transmission`, `Suspension`, `Armor`, `Turbo`, `Unlimited`), niveau | `SetPerformance` |
   | `"Livery"` | n (0 = aucune) | `SetLivery` |
   | `"Extra"` | n, booléen | `SetExtra` (extra présent sur ce véhicule) |
   | `"Tint"` | n de `Custom.WindowTints` (1 = d'origine … 7 = vert) | `SetWindowTintPreset` |
   | `"Neon"` | `"Front"`/`"Back"`/`"Left"`/`"Right"`/`"All"`, booléen | `SetNeonSide` / `SetNeon` |
   | `"NeonColor"` | `Color3` | `SetNeonColor` |
   | `"InteriorColor"` | `Color3` ou rien (d'origine) | `SetInteriorLightColor` (attribut `InteriorLightColor`, sauvegardé) |
   | `"InteriorLight"` | booléen | plafonnier allumé / éteint |
   | `"Xenon"` | booléen, `Color3` ou nil (xénon de série) | `SetXenon` |
   | `"TyreSmoke"` | booléen, `Color3` ou nil | `SetTyreSmoke` (attribut `TyreSmokeColor`) |
   | `"Plate"` | texte (vide = plaque générée) | `VehiclePlates.RequestCustom` (filtré pour le joueur) |
   | `"PlateStyle"` | n de style | `SetPlateStyle` |
   | `"Window"` | os de vitre, booléen (descendue) | `SetWindowDown` |
   | `"Door"` | os de charnière, booléen (ouverte) | `Door_<os>` sans condition de portée (véhicule à distance) |
   | `"SmashWindows"` | — | `SmashWindows` (jusqu'à `Repair`) |
   | `"RemoveDoor"` | os de charnière, booléen (débris au sol) | `RemoveDoor` |
   | `"Repair"` | — | `Repair` : portières, vitres, remise sur les roues |
   | `"Flip"` | — | `Flip` : droit sur ses roues, sans condition |
   | `"Tune"` | `PowerMult` / `TorqueMult` (1..1024), `SpeedLimitKmh` (0 = aucun), `DriftTyres` (booléen) | `SetTune` → `VehicleDynamics.SetTune` |
   | `"Freeze"` | booléen | `SetFrozen` (ancré même conduit) |
   | `"Visible"` | booléen | `SetVisible` (attribut `Invisible` ; feux éteints côté client) |
   | `"Alarm"` | booléen | `SetAlarm` (détresse + klaxon, `AlarmDuration` s) |
   | `"Engine"` / `"EngineAlwaysOn"` | booléen | moteur ; `SetEngineAlwaysOn` (le serveur refuse de le couper) |
   | `"Lights"` | `"Auto"` / `"Off"` / `"On"` | `SetLights` (Auto : selon `Lighting.ClockTime`, une fois) |
   | `"Lock"` | booléen | `VehicleAccess.SetLocked` |
   | `"KickOut"` | — | `KickOccupants` |
   | `"HornTune"` | — | `PlayHornTune` |
   | `"Seat"` | — | `CycleSeat` : le joueur passe au siège libre suivant |
   | `"PaintFade"` | 0..1 | `SetPaintFade` : décoloration (couleur ternie, éclaircie, moins brillante ; attribut `PaintFade`, sauvegardé) ; refus `"absent"` sans pièce peinte |
   | `"EngineSound"` | nom d'un son du pack (`brolver_coupe_03`), `nil` = son d'origine | `SetEngineSound` : seulement un son de la **même catégorie** que le véhicule (raison `"other_category"` sinon), voir « Changer le son moteur en jeu » |

   Le serveur (`FiveMVehiclesServer`) limite le débit (8 par seconde, rafale 12, par joueur), appelle la règle
   (qui reçoit l'op : un jeu peut autoriser certaines ops hors du véhicule, p. ex. au propriétaire), puis
   `Custom.HandleRemote(model, op, a, b, c, player)` contrôle chaque argument (couche connue **et présente**,
   index entier, finition connue, couleur finie, extra / vitre / charnière / néon existant sur ce véhicule…).
   **Réponse** : `VehicleEvent:FireClient(player, "CustomResult", model, op, appliquée, raison)` — raison
   `"denied"` (règle du jeu), `"invalid"`, `"absent"` (le véhicule n'a pas cet élément), `"too_long"` /
   `"filtered"` / `"taken"` (plaque), `"always_on"`, `"empty"`, `"busy"`, `"no_free_seat"`… ; pour une plaque
   acceptée, la raison porte le texte posé. L'état se relit dans les attributs du modèle (`Paint_…`, `Mod_…`,
   `Perf_…`, `Neon_<côté>`, `Tune_…`, `WindowBroken_…`, `DoorRemoved_…`, `Frozen`, `Invisible`, `AlarmUntil`…).
   `Custom.RemoteOps` liste les ops du runtime installé ; `Custom.WindowTints`, `Custom.LightColors` (13 couleurs
   GTA des néons / xénons, libellés FR), `Custom.NeonSidesPresent`, `Custom.WindowBones`, `Custom.Seats`
   servent à construire les menus.
3. **Ce que le menu affiche** : il `require` `VehiclePaints` (listes et libellés) et lit
   `Custom.LayersPresent(model)` pour griser les couches absentes, `VehicleConfig.Colors.Variations` pour les
   combinaisons d'usine.

Correspondance avec vMenu (Options du véhicule › Couleurs) : Couleur principale / secondaire → `Primary` /
`Secondary`, groupes Chrome / Classique / Mat / Métallisé / Métaux / Utilitaires / Usées → `Paints.Group` avec
la finition Chrome / Classic / Matte / Metallic / Metal / Classic / Worn ; Nacré → couche `Pearlescent` ;
Jantes → `Wheel` (`Alloy` + `Classic`) ; Intérieur / Tableau de bord → `InteriorTrim` / `Dashboard` ; Couleur
personnalisée → op `"Color"` ; Combinaison d'usine → op `"Factory"`. Caméléon : pas de peinture dans la palette
(DLC), rien à brancher.

### Changer le son moteur en jeu (`EngineSoundBank`, op `"EngineSound"`, 2026-11-16)

Un véhicule converti porte un seul son du pack maison. Pour lui proposer les autres sons de **sa catégorie**
(coupé, sport, super… = catégorie du pack tirée de la classe GTA vérifiée, § 1c) :

1. `python scripts/engine_sound_bank.py build --category <cat> --out <dossier>` découpe chaque son de la catégorie
   avec la même chaîne que la conversion (34 boucles : moteur + échappement, enfoncé / relâché / ralenti, régimes
   mesurés). Déterministe : le son déjà porté par un véhicule donne les **mêmes fichiers** (empreinte vérifiée).
2. Publier les boucles (`upload_list.json`), écrire `<dossier>/sound_ids.json` (`"<son>/<fichier>.wav": "rbxassetid://…"`).
3. `python scripts/engine_sound_bank.py emit --out <dossier> --reuse <son>=<sortie du véhicule>/sounds/sound_ids.json
   [--merge EngineSoundBank.lua]` → `EngineSoundBank.lua`, à poser en ModuleScript
   `ReplicatedStorage.FiveMVehicles.EngineSoundBank` (l'installateur du runtime ne le touche pas). `--reuse` évite de
   republier le son déjà dans un véhicule.

Runtime : `Custom.EngineSounds(model)` → `{ Category, Default, Current, List = { {Name, Label} } }` (aussi dans
`GetOptions().EngineSounds`) ; l'op `"EngineSound"` pose l'attribut `EngineSound` (absent = d'origine, sauvegardé par
`Serialize`, remis à l'origine par `Apply` s'il manque). Catégorie = celle du son d'origine (`Audio.Source`
`awc:<son>_moteur_…`), sinon la classe. Chaque client crée alors les `Sound` de la banque (`Bank_<boucle>`, préchargés)
et refait ses couches ; klaxon et clignotants restent ceux du véhicule. Coût : 34 boucles publiées par son ; un
véhicule n'en joue que ~4 à la fois.

## Textures et brillance (2026-11-15)

- **Taille** : `--max-texture` (défaut **2048**). Mesuré par un GLB de test (rayures d'un pixel) importé
  par `upload_file` + `insert_asset` : une texture 2048 est stockée en 2048 × 2048 et rendue nette en
  qualité graphique 21 (période des rayures exacte à l'écran) ; une 4096 est ramenée à 2048. Une 2048
  coûte 4 × la mémoire d'une 1024 : seules les sources > 1024 (livrées 4096 surtout) en profitent.
- **Brillance** : la carte `SpecSampler` de GTA (R = intensité, G = brillance, B = Fresnel ; alpha plein)
  et `specularIntensityMult` / `specularFalloffMult` / `specMapIntMask` deviennent une
  `metallicRoughnessTexture` glTF (G = rugosité, B = métal) par `TextureStore.metal_rough()`.
  L'importeur de Roblox en tire **`RoughnessMap` + `MetalnessMap`** (vérifié : pixel 0,05/1 → 12 et 255,
  0,9/0 → 229 et 0). Conversion heuristique, réglable en tête de `f2r/textures.py` :
  rugosité = 1 − G × min(1, log2(1+falloff)/8) × √intensité ; défauts intensité 1 / falloff 100 ;
  métal = noms `chrome` / `alloy` ; chrome plafonné à 0,10. m422 : peinture 0,15, plastiques ≈ 0,94,
  jantes alu 0,25 métal. Carte uniforme → 4 × 4 px.
- **Limite** : l'importeur crée aussi une `MetalnessMap` noire (inutile, mémoire) sur les pièces non
  métalliques ; la vider (`sa.MetalnessMap = ""`) en Edit après l'import.
- **Juger le rendu en qualité graphique fixée (21)** : en `Automatic`, Studio peut afficher les textures
  réduites et sans relief (cause démontrée sur la m422, A/B/A). Les reflets demandent aussi
  `Lighting.EnvironmentSpecularScale` > 0 dans la place (réglage du jeu, pas du skill).
- **Peinture** : une pièce peinte qui garde une SurfaceAppearance ignore `Custom.SetFinish` (la
  rugosité de la SA décide) ; voir « Custom ».

## Limites Roblox prises en compte

- ≤ 20 000 triangles par MeshPart : découpage automatique à 19 000 (`--max-tris`).
- Textures ≤ 2048 px (`--max-texture`, défaut 2048) : Roblox garde 2048 et réduit 4096 à 2048 (mesuré le 2026-11-15, GLB importé, rendu net en qualité 21) ; redimensionnées, puissances de 2. Brillance GTA (`SpecSampler`) → `RoughnessMap`/`MetalnessMap` par la `metallicRoughnessTexture` du GLB (voir « Textures et brillance »).
- Une seule coordonnée UV par mesh : les pièces à livrée utilisent l'UV de la livrée.
- `SurfaceAppearance` ne se modifie pas en jeu : les livrées sont des SurfaceAppearance pré-créées que
  l'on échange ; la teinte de peinture texturée passe par `SurfaceAppearance.Color` (si dispo) sinon `Part.Color`.

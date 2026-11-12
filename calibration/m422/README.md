# Calibration `m422` — mesures FiveM face au moteur de conduite Roblox

Mesures prises **dans GTA V** (FiveM, FXServer b177, édition Enhanced/Gen9) sur le véhicule
`m422`, le même mod que celui converti par le skill et mesuré dans Roblox. But : disposer
de la référence réelle pour caler `VehicleDynamics.Dyn.Tuning`.

- Colonne **Roblox** : [`docs/drive-tests.md`](../../docs/drive-tests.md) (essais du 2026-11-11).
- Colonne **FiveM** : les traces de [`fivem/`](fivem/), produites par
  [`tools/fivem-telemetry`](../../tools/fivem-telemetry/).

Les essais FiveM reprennent ceux de `roblox/DriveBench.lua` : mêmes consignes, mêmes durées,
même tenue de ligne, même logique de départ (véhicule réparé, arrêté, moteur tournant).

## Protocole

**Véhicule.** `m422`, remis à neuf avant chaque essai (`SetVehicleFixed`, réservoir plein,
moteur tournant, vitesses annulées), puis laissé s'immobiliser avant la mesure. Le handling
**réellement chargé en jeu** est relevé au début de chaque essai et stocké dans la trace ;
il correspond exactement à ce que le skill a exporté :

| Champ | Valeur lue en jeu |
|---|---|
| `fMass` | 2200 kg |
| `nInitialDriveGears` | 6 |
| `fInitialDriveForce` | 0,20 |
| `fInitialDriveMaxFlatVel` | 135 |
| `fDriveBiasFront` | 0,50 |
| `fBrakeForce` | 0,60 |
| `fTractionCurveMax` / `Min` | 1,90 / 1,50 |
| `fSuspensionForce` | 1,40 |

**Piste.** Tablier de l'aéroport de Los Santos, départ `(-1201,0 ; -3044,0 ; 13,5)`, cap 90
(plein ouest) : **671 m de béton continu**, sans bordure ni obstacle, vérifiés **en
conduisant**. Météo au beau fixe, midi, trafic, piétons et niveau de recherche neutralisés.

**Entrées.** Imposées à chaque image par `SetControlNormal` (accélérateur 71, frein 72,
direction 59, frein à main 76). Les autres contrôles (sortie du véhicule, armes, klaxon) sont
désactivés pendant l'essai ; les contrôles de conduite, eux, ne doivent **pas** l'être
(`DisableControlAction` masque aussi la valeur injectée).

**Enregistrement.** Une ligne par image — **≈ 80 i/s mesurées** — et ~63 canaux : entrées,
vitesse et vitesse dans le repère véhicule, position, rotation, vitesses angulaires, régime,
rapport engagé et suivant, embrayage, `ThrottleOffset`, angle de volant, et **par roue**
vitesse, compression de suspension, braquage, longueur du vecteur de traction, puissance,
pression de frein, vitesse de rotation et matériau du sol.

**Répétition.** Chaque essai a été lancé **3 fois** (27 essais, 27 réussis). La dispersion
est donnée sous forme d'écart-type ; elle est partout très faible (σ ≤ 0,15 % sur les temps,
σ = 0 sur plusieurs mesures), ce qui veut dire que la physique GTA est **déterministe** à
cadence d'images donnée.

## Résultats

| Mesure | FiveM (moyenne de 3, σ) | Roblox | Écart | Réglages concernés |
|---|---|---|---|---|
| 0-60 km/h | **3,44 s** (σ 0,008) | 4,5 s | Roblox **+31 %** | `IwRel`, `DriveForce` |
| 0-100 km/h | **8,90 s** (σ 0,13) | 10,8 s | Roblox **+21 %** | `IwRel`, `KMu` |
| Vitesse de pointe | **118,9 km/h** (σ 0,41), plateau à 16,1 s, 4ᵉ rapport | 151,5 km/h | Roblox **+27 %** | `DriveMaxFlatVel` |
| Passage 1→2 | 39,9 km/h — régime **0,805** | 43 km/h | proche | `UpshiftRpm` |
| Passage 2→3 | 80,4 km/h — régime **0,956** | 76 km/h | proche | `UpshiftRpm` |
| Passage 3→4 | 110,3 km/h — régime **0,936** | 106 km/h | proche | `UpshiftRpm` |
| Durée d'un passage | **0,496 s** (σ 0,006, n = 9) | non mesuré | — | `ClutchChangeRate`, `ShiftLockout` |
| 100-0 au frein : distance | **20,6 m** (σ 0,03) | 33,3 m | Roblox **+62 %** | `BrakeForce`, `AbsSlip` |
| 100-0 au frein : temps | **1,57 s** (σ 0,02) | 2,38 s | | |
| 100-0 au frein : décélération | **1,81 g** (σ 0,02) | 1,19 g | Roblox **−34 %** | |
| 100-0 : lacet max | 0,23 °/s | 0,6 °/s | ok | tenue de cap |
| 60-0 frein à main : distance | **20,0 m** (σ 0,03) | 29,2 m | Roblox **+46 %** | `HandbrakeGripRear` |
| 60-0 frein à main : décélération | **0,71 g** (σ 0,001) | 0,51 g | | |
| 60-0 frein à main : **lacet max** | **0,13 °/s** (σ 0,06) | **69 °/s** | **énorme** | `HandbrakeGripRear` |
| Virage 40 km/h : accélération latérale | **1,83 g** (σ 0,03) | 1,07 g | Roblox **−41 %** | `KMu`, `PeakFactor` |
| Virage 40 km/h : **roulis** | **1,89 °** (σ 0,01) | 0,28 ° | Roblox **−85 %** | `KArb`, `KSpring` |
| Virage 40 km/h : dérive | 6,65 ° | 1,0 ° | | `PeakFactor` |
| Virage 40 km/h : rayon | **6,54 m** (σ 0,07) | non mesuré | — | `SteeringLock` |
| Virage 40 km/h : vitesse en sortie | 38,3 km/h | 39,9 km/h | ok | |
| Virage 80 km/h : accélération latérale | **2,24 g** (σ 0,001) | 2,04 g | proche | `KMu`, `Falloff` |
| Virage 80 km/h : **roulis** | **2,52 °** (σ 0,08) | 0,29 ° | Roblox **−88 %** | `KArb` |
| Virage 80 km/h : **dérive** | **53,9 °** (σ 2,7) | 9,5 ° | GTA **glisse** | `Falloff` |
| Virage 80 km/h : vitesse en sortie | **14,3 km/h** | 71 km/h | GTA perd tout | |
| Virage 80 km/h : rayon | 18,3 m | non mesuré | — | |
| Marche arrière, 4 s | **−48,8 km/h**, 41,4 m | −58,4 km/h, 34 m | Roblox **+20 %** | `ReverseHold` |
| Roue libre 110 → 30 km/h | **115,2 m** (σ 0,39) → ≈ **0,38 g** de décélération | non mesuré | — | `EngineBrakeG`, traînée |
| Créneau 60 km/h : lacet max | **31,2 °/s** (σ 0,33) | non mesuré | — | `SteerFade`, `SteerMinPct` |
| Créneau 60 km/h : roulis | **3,36 °** (σ 0,07) | non mesuré | — | `KArb` |
| Slalom 60 km/h : roulis | **3,48 °** (σ 0,33) | non mesuré | — | `KArb`, `KSpring` |
| Slalom 60 km/h : lacet max | 26,5 °/s | non mesuré | — | |
| Slalom 60 km/h : dérive | 1,22 ° | non mesuré | — | |

## Ce qu'on apprend du moteur GTA

**Les rapports.** Le régime de passage **n'est pas constant** : 0,805 en 1ʳᵉ, puis 0,956 et
0,936. Le moteur Roblox utilise une valeur unique (`UpshiftRpm` 0,93) ; la 1ʳᵉ passe donc
trop tard. Un passage dure **0,496 s**, pendant lesquelles `ThrottleOffset` tombe à 0 et
l'embrayage descend jusqu'à ≈ 0,29 : le couple est vraiment coupé, et on voit la
décélération passer de +1,12 g à −0,14 g le temps du passage. Seuls **4 rapports sur 6**
servent : la vitesse est plafonnée par `DriveMaxFlatVel`, pas par l'étagement.

**La vitesse de pointe.** 118,9 km/h pour `fInitialDriveMaxFlatVel = 135`, soit un facteur
de **0,88**. La conversion actuelle du skill retient 45 m/s (= 162 km/h) pour ce même champ,
d'où les 151,5 km/h mesurés dans Roblox. C'est l'écart le plus simple à corriger : le
rapport mesuré est 135 → 33,0 m/s, pas 135 → 45 m/s.

**Le freinage.** GTA s'arrête de 100 km/h en **20,6 m à 1,81 g**, là où Roblox met 33,3 m à
1,19 g. Pour `fBrakeForce = 0,6` cela donne ≈ **3,0 g par unité** de `BrakeForce`. Le cap
est tenu (0,23 °/s de lacet) : pas de tirage au freinage.

**Le frein à main.** C'est l'écart le plus spectaculaire. Dans GTA, frein à main serré à
60 km/h volant droit, le véhicule **reste droit** : 0,13 °/s de lacet, arrêt en 20,0 m à
0,71 g. Le moteur Roblox part en tête-à-queue à **69 °/s**. `HandbrakeGripRear` (0,75) est
donc très loin du compte : le frein à main de GTA bloque les roues arrière **sans** faire
perdre l'adhérence latérale en ligne droite.

**L'adhérence et le roulis.** À 40 km/h plein braquage, GTA tient **1,83 g** avec **1,89 °**
de roulis ; Roblox tient 1,07 g avec 0,28 °. En rapportant le roulis à la charge latérale,
GTA roule d'environ **1,0 °/g** et Roblox d'environ **0,26 °/g** : la caisse Roblox est
≈ 4 fois trop raide. Le relevé roulis/accélération latérale confirme la pente :

| Accélération latérale | Roulis GTA (virage 40) |
|---|---|
| 0,5 g | 0,83 ° |
| 1,0 g | 1,65 ° |
| 1,5 g | 1,72 ° |
| 2,0 g | 1,76 ° |

La courbe sature au-delà de 1 g — comportement de barre anti-roulis, pas de ressort pur.

**La perte d'adhérence.** À 80 km/h plein braquage, GTA atteint **53,9 ° de dérive** et sort
du virage à **14,3 km/h** : le véhicule part en glisse et la glisse le freine. Roblox reste
à 9,5 ° de dérive et sort à 71 km/h. La longueur du vecteur de traction le montre bien : au
régime stabilisé elle vaut ≈ 0,7, et elle monte à **4 à 5** quand le glissement de roue
dépasse 0,2 — la force n'est donc pas plafonnée par un simple pic, elle croît encore
largement au-delà.

**La traînée en roue libre.** 110 → 30 km/h en **115 m**, soit ≈ **0,38 g** de décélération
moyenne, rapport engagé. Le moteur Roblox n'applique que `EngineBrakeG = 0,08 g` : le
véhicule Roblox roule beaucoup trop loin en roue libre.

**La marche arrière.** −48,8 km/h en 4 s sur 41,4 m, contre −58,4 km/h sur 34 m dans
Roblox : confirme le point 5 de la liste « ce qui ne fait pas encore GTA ».

## Priorités de calage qui ressortent

1. `DriveMaxFlatVel` : facteur 0,88 sur `fInitialDriveMaxFlatVel`, pas 1/3 de la valeur.
2. `HandbrakeGripRear` : le frein à main GTA ne fait **pas** pivoter en ligne droite.
3. `BrakeForce` → ≈ 3,0 g par unité (1,81 g pour 0,6).
4. `KArb` / `KSpring` : viser ≈ 1,0 °/g de roulis, saturant au-delà de 1 g.
5. `KMu` : viser 1,83 g de tenue latérale à 40 km/h plein braquage.
6. `UpshiftRpm` : variable selon le rapport (0,805 en 1ʳᵉ, ≈ 0,95 ensuite), + 0,496 s de coupure.
7. `EngineBrakeG` : ≈ 0,38 g en roue libre, rapport engagé.
8. `IwRel` / `DriveForce` : 0-100 en 8,90 s.

## Limites de cette campagne

- **Longueur de piste : 671 m.** Suffisant pour tout ce qui précède — la vitesse de pointe
  a été atteinte (plateau à 16,1 s, 378 m) parce que le véhicule plafonne à 119 km/h. La
  roue libre part donc de 110 km/h et non de 150 comme prévu : il n'existe pas de vitesse
  plus élevée à atteindre sur ce véhicule.
- **Essais non faits : bordure et côte.** Ils demandent une marche de 15 cm et une pente de
  15 % repérées et validées ; le tablier de l'aéroport n'en a pas, et le repérage par
  téléportation s'est révélé non fiable (voir ci-dessous). Les lignes Roblox correspondantes
  (cabrage 7,6 ° à 20 km/h, 17,6 ° à 60 km/h, recul en côte) restent donc sans vis-à-vis.
- **Cadence d'images non pilotable.** Aucun convar de limitation n'est exposé par ce build
  (`game_maxFps`, `profile_maxFps`, `r_maxFps`, `cl_maxFps`… tous absents) : la comparaison
  30 / 60 i/s demandée n'a pas pu être faite. Les traces enregistrent en revanche la durée
  de **chaque** image (≈ 80 i/s, 11 à 29 ms), et la dispersion quasi nulle entre passes
  suggère que la physique ne dépend pas de la cadence sur cette plage — ce n'est pas une
  preuve pour 30 i/s.
- **Le repérage du terrain par téléportation ne se croit pas sur parole.** Sans collision
  chargée, `SetVehicleOnGroundProperly` ne fait rien : le véhicule garde l'assiette imposée
  et on lit une pente exactement nulle sur des kilomètres. Deux « pistes » de 2 km trouvées
  ainsi étaient du vide. Toute ligne droite a été validée en la conduisant.
- **Un seul véhicule, un seul conducteur, une seule session.** Ni propulsion, ni moto, ni
  véhicule lourd. Le `m422` est à 4 roues motrices (`DriveBiasFront` 0,5).
- Les traces contiennent **uniquement des mesures** : aucun fichier du jeu ni du mod.

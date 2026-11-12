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

**Bordure.** Il n'existe pas dans la carte de marche de 15 cm abordable de face avec de
l'élan : une bordure de rue est **parallèle** à la chaussée, on ne peut donc l'aborder qu'en
traversant la rue, soit 7 m d'élan — de quoi faire 20 km/h, pas 60. La marche a donc été
**construite** sur la ligne droite du tablier, à 74 m du départ : trois conteneurs
(`prop_container_01a`) enfoncés dans le béton de façon que leur face supérieure affleure à la
hauteur voulue, figés, alignés côte à côte — 7,9 m de large, 12,2 m de long. La marche
obtenue a été **relevée au rayon vertical avant toute mesure** : **+0,149 m**, dessus plat au
millimètre sur 12,2 m ([`fivem/bordure_profil_1.json`](fivem/bordure_profil_1.json)). Les
conteneurs ont été retirés après les essais et le tablier revérifié plat.

**Côte.** Richman Glen, route montante repérée au rayon vertical (profil en long relevé tous
les mètres sur 140 m), départ `(-1504,0 ; 259,4)`, cap 28,4. La pente **au point où le
véhicule s'immobilise** est relevée dans chaque trace : **16,5 %** (assiette 9,35 °), un peu
plus raide que les 15 % demandés — c'est la pente régulière la plus proche trouvée sur une
route goudronnée.

**Entrées.** Imposées à chaque image par `SetControlNormal` (accélérateur 71, frein 72,
direction 59, frein à main 76). Les autres contrôles (sortie du véhicule, armes, klaxon) sont
désactivés pendant l'essai ; les contrôles de conduite, eux, ne doivent **pas** l'être
(`DisableControlAction` masque aussi la valeur injectée).

**Enregistrement.** Une ligne par image — **≈ 80 i/s mesurées** — et ~63 canaux : entrées,
vitesse et vitesse dans le repère véhicule, position, rotation, vitesses angulaires, régime,
rapport engagé et suivant, embrayage, `ThrottleOffset`, angle de volant, et **par roue**
vitesse, compression de suspension, braquage, longueur du vecteur de traction, puissance,
pression de frein, vitesse de rotation et matériau du sol.

**Répétition.** Chaque essai a été lancé **3 fois** (36 essais, 36 réussis). La dispersion
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
| Bordure 0,15 m à 20 km/h : **cabrage** | **3,29 °** (σ 0,02) | 7,6 ° | Roblox **×2,3** | `BumpK`, `DampVMax` |
| Bordure 0,15 m à 20 km/h : roues au sol | **4 en permanence** | ≥ 2 | GTA ne décolle pas | `DampVMax` |
| Bordure 0,15 m à 20 km/h : vitesse perdue | **0,06 km/h** (σ 0,02) | 0,9 km/h | Roblox **×15** | `BumpK` |
| Bordure 0,15 m à 20 km/h : montée de caisse | **0,145 m** pour 0,149 m de marche | non mesuré | — | `KSpring` |
| Bordure 0,15 m à 60 km/h : **cabrage** | **+2,18 / −2,64 °** (σ 0,10) | 17,6 ° | Roblox **×8** | `BumpK`, `DampVMax` |
| Bordure 0,15 m à 60 km/h : temps en l'air | **0 image** | 0,15 s (9 images) | GTA reste collé | `DampVMax` |
| Bordure 0,15 m à 60 km/h : vitesse perdue | **0,03 km/h** | ≈ 0 | ok | |
| Bordure : vitesse de tangage max | 79,9 °/s à 20 km/h, **118,9 °/s** à 60 | non mesuré | — | `DampVMax` |
| Bordure : compression de suspension | 0,193 → **0,289** à 20 km/h ; 0,199 → **0,326** à 60 | non mesuré | — | `KSpring`, `BumpK` |
| Côte 16,5 % : frein à main 1,5 s | **5,9 cm** (σ 0,3) | 4,5 cm (à 15,0 %) | proche | `HandbrakeGripRear` |
| Côte 16,5 % : tout relâché 2 s | **0,0 cm** — recul **strictement nul** | 6,7 cm | Roblox **recule** | maintien à l'arrêt |
| Côte 16,5 % : plein gaz 4 s | **45,1 km/h** (σ 0,6), 32,5 m, 2ᵉ | 43 km/h | proche | `DriveForce` |
| Côte 16,5 % : coût de la pente | −22,2 km/h et −11,7 m face aux **67,3 km/h / 44,1 m** du plat | non mesuré | — | |

## Ce qu'on apprend du moteur GTA

**Les rapports.** Le régime de passage **n'est pas constant** : 0,805 en 1ʳᵉ, puis 0,956 et
0,936. Le moteur Roblox utilise une valeur unique (`UpshiftRpm` 0,93) ; la 1ʳᵉ passe donc
trop tard. Un passage dure **0,496 s**, pendant lesquelles `ThrottleOffset` tombe à 0 et
l'embrayage descend jusqu'à ≈ 0,29 : le couple est vraiment coupé, et on voit la
décélération passer de +1,12 g à −0,14 g le temps du passage. Seuls **4 rapports sur 6**
servent : la vitesse est plafonnée par `DriveMaxFlatVel`, pas par l'étagement.

**La vitesse de pointe — et une erreur de lecture de ma part, corrigée depuis.** 118,9 km/h
pour `fInitialDriveMaxFlatVel = 135`. J'en avais d'abord conclu que la conversion du skill
(135 → 45 m/s) était fausse. Elle est **juste** : les trois passages de rapports le prouvent,
le régime mesuré au passage vaut `v / (DriveMaxFlatVel / rapport)` à **±0,003 près** avec
`DriveMaxFlatVel = 1,2 × 135 / 3,6 = 45 m/s`. Les 118,9 km/h ne sont pas un plafond de boîte
mais un **plafond de traînée** : le véhicule plafonne en 4ᵉ à un régime de 0,806, bien avant
son rupteur, parce que la poussée (2,12 m/s²) y égale la traînée. C'est donc le coefficient de
traînée qu'il fallait corriger, pas la vitesse plate — voir « Calage appliqué » plus bas.

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

**La bordure.** GTA **avale** la marche de 15 cm. À 20 km/h : 3,29 ° de cabrage, quatre
roues toujours en contact, 0,06 km/h perdus ; la caisse monte de 0,145 m pour une marche de
0,149 m, donc la suspension n'absorbe que 4 mm et le châssis suit le terrain. À 60 km/h le
cabrage **diminue** (2,18 °) au lieu d'augmenter : le véhicule n'a plus le temps de suivre la
marche, c'est la suspension qui travaille (compression 0,199 → 0,326, contre 0,193 → 0,289 à
20 km/h) et la caisse ne monte plus que de 0,135 m. Les seules grandeurs qui croissent avec
la vitesse sont la **vitesse de tangage** (80 → 119 °/s) et le mouvement vertical
(0,33 → 0,47 m/s). Rien n'est perdu en vitesse : dans GTA, une bordure ne freine pas.

Le moteur Roblox fait l'inverse : 7,6 ° à 20 km/h, puis 17,6 ° et 0,15 s en l'air à 60 km/h,
avec 0,9 km/h perdus à 20 km/h. Le ressort est trop raide et la détente trop peu amortie : la
roue est renvoyée vers le haut au lieu d'être rattrapée. Le critère de réglage est simple —
le cabrage doit **baisser** quand la vitesse monte.

**La côte.** À 16,5 % de pente, moteur tournant, **le véhicule ne recule pas du tout** : 2 s
toutes commandes relâchées, déplacement strictement nul et vitesse minimale 0,0 km/h. GTA
applique un maintien à l'arrêt total. Les 5,9 cm de la phase frein à main sont la fin du
mouvement d'immobilisation, pas un glissement : cette phase précède la phase relâchée, qui
elle est à zéro. Roblox recule de 6,7 cm en 2 s — c'est peu, mais ce n'est pas zéro.

Au démarrage, plein gaz 4 s en côte : 45,1 km/h sur 32,5 m en 2ᵉ, contre **67,3 km/h sur
44,1 m** sur le plat. La pente coûte 22 km/h et 12 m en 4 s, soit à peu près ce qu'enlèverait
une composante de gravité de 0,16 g pendant 4 s (≈ 23 km/h) : en montée, GTA ne triche pas
sur la pente — seulement à l'arrêt.

**La marche arrière.** −48,8 km/h en 4 s sur 41,4 m, contre −58,4 km/h sur 34 m dans
Roblox : confirme le point 5 de la liste « ce qui ne fait pas encore GTA ».

## Priorités de calage qui ressortent

*(toutes appliquées sauf mention contraire — voir « Calage appliqué » plus bas)*

1. **La traînée**, pas la vitesse plate : `fInitialDriveMaxFlatVel` était bien converti, c'est
   le coefficient de traînée qui était 2,1 fois trop faible. Le plateau à 118,9 km/h est un
   équilibre poussée/traînée en 4ᵉ, pas un rupteur.
2. `HandbrakeGripRear` : le frein à main GTA ne fait **pas** pivoter en ligne droite.
3. `BrakeForce` → ≈ 3,0 g par unité (1,81 g pour 0,6).
4. `KArb` / `KSpring` : viser ≈ 1,0 °/g de roulis, saturant au-delà de 1 g. **Non appliqué** :
   la raideur de roulis effective ne vient pas de ces réglages (voir plus bas).
5. `KMu` : viser 1,83 g de tenue latérale à 40 km/h plein braquage.
6. `UpshiftRpm` : variable selon le rapport (0,805 en 1ʳᵉ, ≈ 0,95 ensuite), + 0,496 s de coupure.
7. `EngineBrakeG` : ≈ 0,38 g en roue libre, rapport engagé.
8. `IwRel` / `DriveForce` : 0-100 en 8,90 s.
9. `BumpK` / `DampVMax` : sur une marche de 15 cm, le cabrage doit **baisser** avec la vitesse
   (3,3 ° à 20 km/h, 2,2 ° à 60), sans décollage et sans perte de vitesse.
10. Maintien à l'arrêt en côte : recul **nul** à 16,5 % de pente, contre 6,7 cm dans Roblox.

## Calage appliqué au moteur Roblox

Les mesures ci-dessus ont été reportées dans
[`VehicleDynamics.lua`](../../skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua) :
chaque valeur porte en commentaire la mesure dont elle sort.

| Réglage | Avant | Après | D'où vient la valeur |
|---|---|---|---|
| `KMu` | 0,6 | **1,0** | 100-0 roues bloquées : 1,88 g de moyenne, 2,09–2,14 g de pic, pour `fTractionCurveMax` = 1,90. Le champ du jeu **est** une accélération en g. |
| `PeakFactor` | 0,5 | **0,25** | virage 40 km/h tenu à la limite : la dérive se stabilise à 4,6 ° pour 1,69 g (`fTractionCurveLateral` = 19 °) ; en virage 80 km/h l'adhérence latérale quasi établie décroît déjà entre 3 ° et 10 °. |
| `FalloffKappa` | *(n'existait pas)* | **0,1** | au freinage les roues se bloquent complètement (glissement −1,0) et l'adhérence reste à son pic : dans GTA la chute d'adhérence est pilotée par la **dérive**, pas par le blocage. |
| `KDrag` | *(facteur 1e-4 figé)* | **2,1** | plateau de vitesse : 118,9 km/h en 4ᵉ à régime 0,806 pour `fInitialDragCoeff` = 8,0. Le 1e-4 de la conversion de chargement n'était qu'une hypothèse. |
| `FirstGearForce` | *(n'existait pas)* | **1,5** | poussée mesurée en 1ʳᵉ : 10,5 à 12,4 m/s², là où `DriveForce × rapport × g` donne 6,53. Les 2ᵉ et 3ᵉ, elles, suivent la loi à 2 et 5 % près. Appliqué aussi à la marche arrière, qui emploie le même rapport. |
| `IwRel` | 0,25 | **0,03** | les 25 % d'inertie équivalente interdisaient de tenir ensemble le 0-100 et la vitesse de pointe. Seul réglage **ajusté par balayage** et non lu directement. |
| `UpshiftRpm` | 0,93 | **0,95** | passages 2→3 à 0,974 et 3→4 à 0,954. |
| `UpshiftRpmFirst` | *(n'existait pas)* | **0,82** | passage 1→2 à 0,821–0,827, soit 40,0 km/h : la 1ʳᵉ passe nettement plus tôt. |
| `EngineBrakeG` | 0,08 | **0,9** | roue libre 110 → 30 km/h en 115 m ; traînée retirée, le frein moteur vaut 2,7 à 3,0 m/s² (≈ 0,29 g) sur toute la plage. |
| `HandbrakeGripRear` | 0,75 | **1,0** | frein à main à 60 km/h volant droit : 0,1–0,2 °/s de lacet, 0,07 ° de dérive, alors que les roues arrière glissent (5,3 contre 9,2 m/s). |
| `DampVMax` | 1,0 | **0,5** | marche de 0,149 m : 3,29 ° de cabrage à 20 km/h, 2,18 ° à 60, quatre roues au sol, 0,06 km/h perdus. |
| rupteur en marche arrière | absent | **appliqué** | la marche arrière plafonne à −48,8 km/h, soit exactement `DriveMaxFlatVel / 3,333` = 48,6 km/h. |

### Vérification

`VehicleDynamics` est un module pur : il a été exécuté **hors Roblox**, avec
[lune](https://github.com/lune-org/lune), sur un banc **longitudinal** qui lui fournit des
contacts de roue à plat et intègre la vitesse. Ce banc est dans le dépôt —
[`tools/roblox-drive-rig/`](../../tools/roblox-drive-rig/) — et se relance d'une commande :

```bash
lune run tools/roblox-drive-rig/rig.luau report
```

Il reproduit d'abord fidèlement les
chiffres du banc Roblox réel de `docs/drive-tests.md` (0-60 en 4,48 s contre 4,5 ; pointe
153,1 contre 151,5 km/h ; passages à 43 / 76 / 106 km/h) : c'est ce qui le rend utilisable
pour juger le calage.

| Mesure | Avant | Après | GTA |
|---|---|---|---|
| 0-60 km/h | +30,3 % | **+0,8 %** | 3,44 s |
| 0-100 km/h | +21,0 % | **+13,1 %** | 8,90 s |
| Vitesse de pointe | +28,7 % | **+3,5 %** | 118,9 km/h |
| Plein gaz 4 s (vitesse) | −17,8 % | **−1,4 %** | 67,3 km/h |
| Plein gaz 4 s (distance) | −17,7 % | **+3,9 %** | 44,1 m |
| Passage 1→2 | +8,1 % | **−4,6 %** | 40,0 km/h |
| Passage 2→3 | −6,2 % | **−3,6 %** | 80,7 km/h |
| Passage 3→4 | −3,7 % | **−1,2 %** | 110,6 km/h |
| 100-0 distance | +76,8 % | **−0,5 %** | 20,6 m |
| 100-0 temps | +69,9 % | **−3,4 %** | 1,57 s |
| 100-0 décélération | −40,2 % | **+6,1 %** | 1,81 g |
| Roue libre 110 → 30 | +588,6 % | **−1,7 %** | 115,2 m |
| Marche arrière, vitesse | −26,1 % | **+4,5 %** | −48,8 km/h |
| Marche arrière, distance | −6,0 % | **+4,4 %** | 41,4 m |
| **Écart quadratique moyen** | **211 %** | **5,3 %** | |

### Ce que ce calage ne couvre pas

- **Le latéral, le roulis et la bordure ne sont pas vérifiés.** Un banc longitudinal ne peut
  pas les simuler : ils dépendent du solveur 3D de Roblox. `KMu`, `PeakFactor`, `FalloffKappa`,
  `HandbrakeGripRear` et `DampVMax` sont posés **d'après la mesure**, mais il faut relancer
  `roblox/DriveBench.lua` en Studio pour les confirmer.
- **Le roulis n'a pas été touché.** La mesure est claire (≈ 1,0 °/g dans GTA contre 0,26 °/g
  dans Roblox, saturant au-delà de 1 g), mais la formule de `Dyn` prédit déjà ≈ 0,93 °/g avec
  `KSpring` et `KArb` à 1 : la raideur de roulis effective ne vient donc pas de ces réglages,
  elle vient des contraintes de suspension du châssis (`VehicleDrive`). Baisser `KArb` à
  l'aveugle n'aurait rien prouvé. C'est le prochain chantier.
- **Il reste 13 % d'écart sur le 0-100.** La forme de la courbe de couple de GTA dans la zone
  médiane est plus pleine que celle du modèle (plat jusqu'à 0,8 puis 60 % au rupteur). La
  mesure le montre : la poussée effective monte avec le rapport (×1,00 en 2ᵉ, ×1,05 en 3ᵉ),
  ce que le modèle ne reproduit pas. Mesurer cette courbe demanderait un essai dédié, à
  rapport bloqué.
- **Un seul véhicule.** Tout vient du `m422`. `KMu = 1,0` et `KDrag = 2,1` deviennent les
  défauts de **tous** les véhicules convertis : à recouper sur un deuxième mod.

## Limites de cette campagne

- **Longueur de piste : 671 m.** Suffisant pour tout ce qui précède — la vitesse de pointe
  a été atteinte (plateau à 16,1 s, 378 m) parce que le véhicule plafonne à 119 km/h. La
  roue libre part donc de 110 km/h et non de 150 comme prévu : il n'existe pas de vitesse
  plus élevée à atteindre sur ce véhicule.
- **La bordure est construite, pas trouvée.** Aucune marche de la carte n'est abordable de
  face avec plus de 7 m d'élan (voir « Bordure » dans le protocole). La marche posée est plus
  propre qu'une bordure réelle — arête franche, dessus plat, perpendiculaire au millimètre —
  donc ces chiffres sont une borne **haute** du choc, pas une moyenne de ce qu'on rencontre
  en ville.
- **La côte fait 16,5 %, pas 15 %.** La ligne Roblox, elle, a été mesurée à 15,0 % (8,7 °).
  Les deux colonnes ne sont donc pas exactement au même point de pente ; les 1,5 point d'écart
  jouent sur le recul et sur le démarrage, pas sur la conclusion (recul nul contre 6,7 cm).
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

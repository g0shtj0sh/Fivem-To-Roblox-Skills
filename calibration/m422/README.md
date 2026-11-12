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
| Virage 80 km/h : **roulis** | **2,52 °** (σ 0,08) ⚠ | 0,29 ° | Roblox **−88 %** | `KArb` |
| Virage 80 km/h : **dérive** | **53,9 °** (σ 2,7) ⚠ | 9,5 ° | GTA **glisse** | `Falloff` |
| Virage 80 km/h : vitesse en sortie | **14,3 km/h** ⚠ | 71 km/h | GTA perd tout | |
| Virage 80 km/h : rayon | 18,3 m | non mesuré | — | |
| Marche arrière, 4 s | **−48,8 km/h**, 41,4 m | −58,4 km/h, 34 m | Roblox **+20 %** | `ReverseHold` |
| Roue libre 110 → 30 km/h | **115,2 m** (σ 0,39) → ≈ **0,38 g** de décélération | non mesuré | — | `EngineBrakeG`, traînée |
| Créneau 60 km/h : lacet max | **31,2 °/s** (σ 0,33) | non mesuré | — | `SteerFade`, `SteerMinPct` |
| Créneau 60 km/h : roulis | **3,36 °** (σ 0,07) ⚠ — en manœuvre seule **0,86 °** | non mesuré | — | `KArb` |
| Slalom 60 km/h : roulis | **3,48 °** (σ 0,33) ⚠ — en manœuvre seule **0,68 °** | non mesuré | — | `KArb`, `KSpring` |
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

> ⚠ **Valeurs faussées par le terrain, relevé du 2026-11-12.** Le créneau franchit en biais une arête du
> tablier ≈ 1,93 s après le braquage, le slalom à 8,4 s, le virage 80 à 1,28 s (durées **depuis le début de
> la manœuvre**) : les roulis de 3,36 ° et 3,48 ° sont ceux du franchissement, pas de la manœuvre (avant
> l'arête : 0,86 ° et 0,68 °), et tout le virage 80 au-delà de 1,28 s (dérive 53,9 °, sortie 14,3 km/h,
> roulis 2,52 °) suit ce choc. Les valeurs propres, calculées par le même code que le côté Roblox, sont dans
> « Vérification en 3D » plus bas et dans [`fivem-analyse.json`](fivem-analyse.json).
>
> **Où est cette arête, exactement** (localisée dans les traces, puis **relevée au rayon** le 2026-11-12).
> Ce n'est pas une marche en travers près du départ : c'est le **bord du tablier**, une arête
> **longitudinale** de ≈ +0,30 à +0,35 m. Le sol plat est à **z = 12,944** sur toute la longueur utile.
> Quatre profils en travers (`heightprobe`, cap 0, pas 0,25 m, ±30 m) donnent la largeur réelle, bord à
> ±5 cm près, en mètres par rapport à l'axe de départ (+ = nord) :
>
> | Avance | Bord sud | Bord nord | Largeur |
> |---|---|---|---|
> | 0 m | −14,50 | > +30 (plat au-delà du relevé) | ≥ 44,5 m |
> | 60 m | **−4,75** | +11,75 | 16,5 m |
> | 120 m | < −30 (plat au-delà du relevé) | **+9,00** | ≥ 39,0 m |
> | 180 m | −13,75 | +10,00 | 23,75 m |
>
> Le couloir garanti sur les quatre stations est donc **−4,75 m au sud à +9,00 m au nord** : les bords ne
> sont pas parallèles à l'axe, le nord se resserre vers l'avant et le sud a un pincement vers 60 m.
> Conséquences :
>
> - **Tous les essais en ligne droite sont intacts** — accel, frein, roue libre, frein à main, marche
>   arrière, bordure, côte ne s'écartent jamais de l'axe (l'accélération sur 380 m dérive de 2,2 m).
>   Le virage 40 non plus (écart de hauteur maximal 1,9 cm sur toute la trace) : son roulis de 1,89 ° est
>   propre.
> - Les essais qui dérivent latéralement franchissent l'arête nord chacun à leur distance : créneau à
>   80,3 m d'avance (t = 6,50 s absolu), virage 80 à 94,5 m (6,70 s), slalom à 178,5 m (12,23 s).
> - Le virage 80 à pleine butée quitte la bande **1,4 s après le braquage** : c'est tout ce que ce tablier
>   permet d'en mesurer. Pour aller plus loin il faudrait une surface plate de plus de 14 m de large.
> - D'où l'essai `steerfade` (ci-dessous), qui mesure la direction **en créneaux alternés** : le cap décrit
>   un triangle centré sur zéro, donc l'écart latéral reste de ±1,5 m et la mesure tient sur ce tablier.

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

J'en avais conclu une **saturation** au-delà de 1 g, comportement de barre anti-roulis. À revoir : ce
relevé mélange des points transitoires d'un seul essai. Les points en régime établi, eux, sont
**linéaires** — créneau 0,86 ° pour 0,83 g (1,03 °/g), virage 40 1,71 ° pour 1,69 g (1,01 °/g) — et c'est
aussi ce que trouve la vérification en Studio. Retenir **≈ 1,0 °/g linéaire** ; la saturation n'est pas
établie.

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
| `PeakFactor` | 0,5 | ~~0,25~~ → **0,5** (Studio) | virage 40 km/h tenu à la limite : la dérive se stabilise à 4,6 ° pour 1,69 g (`fTractionCurveLateral` = 19 °) ; en virage 80 km/h l'adhérence latérale quasi établie décroît déjà entre 3 ° et 10 °. |
| `FalloffKappa` | *(n'existait pas)* | **0,1** | au freinage les roues se bloquent complètement (glissement −1,0) et l'adhérence reste à son pic : dans GTA la chute d'adhérence est pilotée par la **dérive**, pas par le blocage. |
| `KDrag` | *(facteur 1e-4 figé)* | **2,1** | plateau de vitesse : 118,9 km/h en 4ᵉ à régime 0,806 pour `fInitialDragCoeff` = 8,0. Le 1e-4 de la conversion de chargement n'était qu'une hypothèse. |
| `FirstGearForce` | *(n'existait pas)* | **1,5** | poussée mesurée en 1ʳᵉ : 10,5 à 12,4 m/s², là où `DriveForce × rapport × g` donne 6,53. Les 2ᵉ et 3ᵉ, elles, suivent la loi à 2 et 5 % près. Appliqué aussi à la marche arrière, qui emploie le même rapport. |
| `IwRel` | 0,25 | **0,03** | les 25 % d'inertie équivalente interdisaient de tenir ensemble le 0-100 et la vitesse de pointe. Seul réglage **ajusté par balayage** et non lu directement. |
| `UpshiftRpm` | 0,93 | **0,95** | passages 2→3 à 0,974 et 3→4 à 0,954. |
| `UpshiftRpmFirst` | *(n'existait pas)* | **0,82** | passage 1→2 à 0,821–0,827, soit 40,0 km/h : la 1ʳᵉ passe nettement plus tôt. |
| `EngineBrakeG` | 0,08 | **0,9** | roue libre 110 → 30 km/h en 115 m ; traînée retirée, le frein moteur vaut 2,7 à 3,0 m/s² (≈ 0,29 g) sur toute la plage. |
| `HandbrakeGripRear` | 0,75 | **1,0** | frein à main à 60 km/h volant droit : 0,1–0,2 °/s de lacet, 0,07 ° de dérive, alors que les roues arrière glissent (5,3 contre 9,2 m/s). |
| `DampVMax` | 1,0 | ~~0,5~~ → **1,0** (Studio) | marche de 0,149 m : 3,29 ° de cabrage à 20 km/h, 2,18 ° à 60, quatre roues au sol, 0,06 km/h perdus. |
| rupteur en marche arrière | absent | **appliqué** | la marche arrière plafonne à −48,8 km/h, soit exactement `DriveMaxFlatVel / 3,333` = 48,6 km/h. |
| `BumpK` | 400 | **0** (Studio) | ajouté le 2026-11-12 après vérification en 3D : c'est la butée de fin de course, pas l'amortisseur, qui faisait cabrer et décoller sur la marche. Voir « Vérification en 3D ». |

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

- *(Vérifiés depuis en Studio, voir « Vérification en 3D » ci-dessous.)* **Le latéral, le roulis et la bordure ne sont pas vérifiés.** Un banc longitudinal ne peut
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

## Vérification en 3D (Studio, 2026-11-12)

Le latéral, le roulis, la marche et la côte demandent le solveur 3D de Roblox : ils ont été mesurés en
Studio, avec le protocole de [`docs/drive-tests.md`](../../docs/drive-tests.md) (`TestTrack.lua` serveur,
`DriveBench.lua` client du conducteur, même `m422` converti, un joueur, PC Studio, Play piloté par le MCP
Roblox Studio). Les deux colonnes sont calculées par **le même code**,
[`tools/drive-compare/analyze.luau`](../../tools/drive-compare/) : sous lune sur les traces FiveM, dans
Studio sur les traces Roblox (mêmes colonnes, mêmes fenêtres).

**Ce qui a changé dans le banc avant de mesurer.**

- La « bordure » de `TestTrack.lua` était une barre de 2 studs (0,56 m) : une bosse que les deux essieux
  franchissent, pas la **marche** de GTA. Elle est maintenant la marche des conteneurs : +0,149 m, dessus
  plat sur 12,2 m, à 74 m du départ. La côte passe de 15 % à **16,5 %** (pente au point d'arrêt mesurée :
  16,2 %), au même point de pente que GTA.
- `DriveBench` enregistre une ligne par image avec les colonnes de la télémétrie FiveM, et gagne le
  créneau (`stepsteer`) et le slalom (`slalom`) avec les lois de `tools/fivem-telemetry`.
- Les cibles GTA du créneau, du slalom et du virage 80 sont **corrigées** : voir l'encadré ⚠ sous
  « Résultats ». Le comparateur coupe les traces avant la marche du tablier.
- Les accélérations latérales de ce tableau viennent de `v × wz`, corrigé depuis : voir « Correction de
  l'instrument » plus bas. Les deux colonnes étant calculées de la même façon, leur comparaison tient,
  mais les valeurs du virage 80 et du slalom sont surévaluées de 8 à 11 %.

**Répétabilité.** Le moteur Roblox est déterministe sur ce banc : deux passes identiques donnent les mêmes
chiffres au centième (virage 40 : 1,76 g / 7,74 ° / 6,85 m deux fois ; marche à 20 km/h : 4,91 ° puis
4,98 °). Chaque chiffre Roblox ci-dessous vient d'une passe, sauf mention.

**Versions.** « Calage de la nuit » = runtime `d6df6a87f51c` (commit `d887f58`) ; « Après » = runtime
`ef7a5b4c4da2` (ce commit), valeurs **par défaut** du module, aucun réglage en direct.

| Essai | Mesure | GTA (3 passes) | Calage de la nuit | Après |
|---|---|---|---|---|
| Virage 40 km/h | pic latéral | 1,83 g | 1,77 g | 1,75 g |
| | latéral établi (2–4 s) | 1,69 g | 1,76 g | 1,72 g |
| | dérive de caisse établie | 4,4 ° | 7,7 ° | **5,4 °** |
| | rayon | 6,29 m | 6,85 m | **6,12 m** |
| | lacet max | 97,3 °/s | 91,7 °/s | 95,5 °/s |
| | roulis établi | 1,71 ° (1,01 °/g) | 0,39 ° (0,22 °/g) | 0,39 ° (0,22 °/g) |
| | sortie | 38,2 km/h | 39,2 km/h | 36,6 km/h |
| Virage 80 km/h (0–1,27 s) | pic latéral | 2,24 g | 1,88 g | 2,68 g |
| | dérive max dans la fenêtre | 8,2 ° (et croissante) | 1,2 ° | **7,0 °** |
| | lacet max | 60,7 °/s | 48,3 °/s | 69,8 °/s |
| | roulis max | 1,89 ° | 0,36 ° | 0,38 ° |
| Créneau 60 km/h, 0,5 (0–1,9 s) | lacet max | 29,3 °/s | — | 69,1 °/s |
| | latéral établi | 0,83 g | — | 1,88 g |
| | roulis établi | 0,86 ° (1,03 °/g) | — | 0,42 ° (0,22 °/g) |
| Slalom 60 km/h (0–8,3 s) | lacet max | 25,2 °/s | — | 66,0 °/s |
| | roulis max | 0,68 ° | — | 0,38 ° |
| Frein à main 60-0 | lacet max | 0,13 °/s | 0,8–1,0 °/s | **1,4 / 2,0 °/s** (2 passes) |
| | distance | 20,0 m (0,71 g) | 15,7 m (0,83 g) | 15,7 / 15,6 m (0,82 g) |
| 100-0 au frein | distance | 20,6 m (1,81 g) | 19,6 m (1,87 g) | 19,4 m (1,87 g) |
| Marche 0,149 m à 20 km/h | cabrage / plongée | +3,45 / −4,25 ° | **+9,6** / −3,9 ° | **+4,9 / −3,0 °** (2 passes) |
| | roues au sol min, images en l'air | 4, 0 | 2, 0 | **4, 0** |
| | vitesse perdue | 0,06 km/h | 3,0 km/h | 1,9–2,0 km/h |
| | montée de caisse | 0,145 m | 0,15 m | 0,15 m |
| Marche 0,149 m à 60 km/h | cabrage / plongée | +2,22 / −2,60 ° | +8,4 / **−17,7 °** | **+3,5 / −2,5 °** |
| | roues au sol min, images en l'air | 4, 0 | **0, 3** | **4, 0** |
| | vitesse perdue | 0,03 km/h | 8,7 km/h | 0,55 km/h |
| Côte 16,5 % | frein à main 1,5 s | 5,9 cm | 6,0 cm | 5,95 cm |
| | tout relâché 2 s | **0,0 cm** | 6,3 cm | **5,7 cm** |
| | plein gaz 4 s | 45,1 km/h, 32,5 m, 2ᵉ | 36,4 km/h, 32,7 m, 2ᵉ | 36,7 km/h, 32,8 m, 2ᵉ |

Cabrage et plongée sont relatifs à l'assiette de croisière (GTA roule à −0,16 ° à 20 km/h : le 3,29 ° du
résumé FiveM est la valeur brute, 3,45 ° la relative).

### Les quatre réglages posés d'après la mesure

| Réglage | Nuit | Verdict en 3D | Pourquoi |
|---|---|---|---|
| `PeakFactor` | 0,25 | **corrigé → 0,5** | La « dérive » de 4,4 ° du virage 40 est l'angle de la **caisse**. Sur un rayon de 6,3 m, la géométrie seule en donne ≈ 12,8 ° au centre de gravité ; les pneus arrière sont donc à ≈ 8 ° de dérive. Les traces donnent l'angle des roues avant (`w0str`, `w1str`) : au virage 40 établi, dérive du pneu avant ≈ 9 ° ; en entrée du virage 80, ≈ 10 °. C'est 19 ° × 0,5. En 3D : 0,25 → dérive 7,7 °, rayon 6,85 m, et le virage 80 ne décroche pas (1,2 °) ; 0,5 → 5,4 °, 6,12 m, 7,0 ° en 1,27 s (GTA 8,2 °). Balayage 0,25 / 0,4 / 0,45 / 0,5 / 0,55 / 0,6 / 0,75 : 0,5 est le meilleur au virage 40 ; au-delà, l'adhérence bascule (0,55 → sortie à 30 km/h). |
| `FalloffKappa` | 0,1 | **confirmé** | 100-0 en 19,4–19,6 m à 1,87 g (GTA 20,6 m, 1,81 g). À 1 : 20,6 m en 3D mais 22,9 m (+11 %) sur le banc longitudinal, qui freine moins fort que le 3D (pas de report de charge en tangage). Garder 0,1 tient le banc à 5,3 %. |
| `HandbrakeGripRear` | 1,0 | **confirmé, sans être la cause** | Départ propre sur la ligne : lacet 1,4 et 2,0 °/s, le véhicule reste droit (avant le calage : 69 °/s). Mais à 0,75 il reste droit aussi (1,35 °/s, `PeakFactor` 0,5) : sur le plat, ce n'est pas ce réglage qui faisait pivoter ; le tête-à-queue d'avant venait d'une autre cause, non isolée. Entré **pendant une correction de cap** (juste après le slalom), le frein à main part à 36,5 °/s : il amplifie un lacet présent. GTA n'a pas été mesuré dans ce cas. |
| `DampVMax` | 0,5 | **corrigé → 1,0, avec `BumpK` 400 → 0** | La cause du cabrage et du décollage n'était pas l'amortisseur mais la **butée de fin de course** : à 60 km/h la roue monte les 0,149 m en une image et dépasse les 0,10 m de course restante au repos ; `BumpK` 400 renvoyait la caisse (+8,4 / −17,7 °, 3 images en l'air). Grille à 60 km/h : `BumpK` 400 → +8,4 / −17,7 ° ; 100 → +5,1 / −7,3 ° ; 50 → +4,8 / −5,7 ° ; **0 → +3,8 / −3,3 °, 4 roues** (avec `DampVMax` 0,5). Puis `DampVMax` à `BumpK` 0 : 0,5 → +4,5 ° à 20 km/h et +3,8 ° à 60 ; **1,0 → +4,7 ° et +3,0 °** ; 0,25 → 24 images en l'air à 60. Seul 1,0 garde nettement la signature GTA (le cabrage **baisse** avec la vitesse). GTA comprime lui-même au-delà de sa course nominale (0,326 à 60 km/h). |

Le banc longitudinal, relancé après ces changements, reste à **5,3 %** : `PeakFactor`, `BumpK` et
`DampVMax` ne le touchent pas.

### `PeakFactor` : la dérive du pneu, calculée dans les traces

> **Section corrigée le 2026-11-12 (après-midi).** Ce qu'elle concluait — « le pneu de GTA n'est pas encore
> à son pic à 15 ° de dérive, donc `PeakFactor` vaut 0,8 à 1,0 » — était **faux**, à cause d'un signe. Les
> dérives justes sont dans « 2. La dérive des pneus de GTA, avec le bon signe » plus bas : **9,35 °** à
> l'avant au virage 40, et non 13,7 à 17,2 °. `PeakFactor` retenu : **0,55**.

**Ce qui était juste.** La correction de 0,25 à 0,5 tenait, et pour la bonne raison : les 4,4 ° qui avaient
servi à la poser étaient la dérive de la **caisse**. La dérive d'un pneu est l'écart entre le plan de la roue
et sa vitesse, il faut donc bien retirer le braquage de l'angle de la vitesse à l'essieu.

**L'erreur.** La vitesse latérale à l'essieu avant vaut `vLat − a · wz`, et non `vLat + a · wz` : dans la
télémétrie FiveM `vLat` est positif vers la **droite** et `wz` vers le haut, et ω × r impose ce signe. Le
mauvais signe gonflait la dérive avant de 9,5 ° à 33,6 °, ce qui faisait croire que le pneu travaillait
encore loin de son pic alors qu'il en est à 90 %.

**Pourquoi la « vérification des signes » n'en était pas une.** L'autre combinaison avait été écartée parce
qu'elle « donnerait 40 °, incompatible avec un rayon de 6,2 m » : c'était comparer un braquage **non signé**
à un angle de vitesse **signé**, donc mélanger deux conventions. Départager demandait une grandeur
extérieure au calcul, pas un argument de vraisemblance ; il y en a deux, données plus bas.

### Le roulis : la raideur ne vient pas des ressorts, mais du point d'application des forces latérales

Il n'y a pas de contrainte de suspension dans le châssis Roblox : les roues de collision ne sont pas
solides pendant la conduite, et `VehicleDrive` applique des forces calculées. La raideur de roulis
effective vient de **la hauteur à laquelle `VehicleDrive` applique les forces latérales des pneus** :
`lateralPoint` = contact + `RollCentreHeightFront/Rear` (0,3 / 0,4 m sur le m422). Le centre de gravité est
mesuré en Studio à 0,45 m au-dessus du contact : le bras de levier du roulis n'est donc que de **0,15 m à
l'avant et 0,05 m à l'arrière**.

- Calcul : raideur de roulis (ressorts + barres, `KSpring` = `KArb` = 1) = 263 m²/s² par radian. Avec le
  bras de 0,45 m → 0,96 °/g (c'est le ≈ 0,93 °/g de la formule). Avec les bras réels (moyenne pondérée
  0,10 m) → **0,22 °/g**.
- Mesuré en Studio : **0,22 °/g** (virage 40, créneau, virage 80). Avec `RollCentreScale` = 0 (forces au
  contact) : **0,94 °/g**, GTA ≈ 1,0 °/g. Cause démontrée par le calcul et la mesure.
- **Non adopté** : à 0, le virage 40 ne tient plus que 1,40 g établi (GTA 1,69 g, rayon 5,05 m, sortie
  30 km/h) et le créneau à 60 km/h part à **28 ° de roulis** sur 2 roues. Le seuil de levée de roue tombe à
  ≈ 1,7 g (voie 1,54 m / (2 × 0,45 m)) ; la trace GTA du virage 40 compte d'ailleurs par moments 2 à 3 roues au sol, sans
  perdre son adhérence. Le réglage `RollCentreScale` (défaut 1, comportement inchangé) est ajouté à
  `Dyn.Tuning` pour poursuivre.
- Prochaine étape suggérée : corriger d'abord la direction (ci-dessous), puis reprendre `RollCentreScale`
  entre 0 et 1, en surveillant l'adhérence établie du virage 40 et le roulis du créneau.

### Ce que la 3D révèle en plus (hors des quatre réglages)

1. **La direction braquait deux fois trop à vitesse — MESURÉE ET CORRIGÉE**, voir « La direction, à
   consigne constante » ci-dessous. Le constat de départ : au créneau (0,5 de braquage à 60 km/h), Roblox
   tenait 1,88 g et 69 °/s, GTA 0,83 g et 29 °/s ; au slalom 66 °/s contre 25.
2. **La côte recule encore** : 5,7 cm en 2 s relâché (GTA 0,0). Cause probable : le pneu ne produit une
   force que s'il glisse (glissement rapporté à `VMin` = 1 m/s), il n'a pas de frottement statique ; le
   maintien à l'arrêt (`hold` à 0,5 de frein) bloque les roues, mais la caisse glisse lentement sur ses
   pneus. Non corrigé.
3. **Le démarrage en côte est trop lent** : 36,7 km/h en 4 s contre 45,1 (même distance, 32,8 m contre
   32,5) ; Roblox accélère plus tôt et plafonne ensuite en 2ᵉ. Non expliqué.
4. **Le frein à main s'arrête trop court** : 15,6–15,7 m à 0,82 g (GTA 20,0 m, 0,71 g). Dans GTA les roues
   arrière glissent sans se bloquer (5,3 contre 9,2 m/s). Réglage probable : `HandBrakeForce` ou
   l'adhérence d'une roue bloquée. Non corrigé.

## La direction, à consigne constante

Les essais en virage ne suffisaient pas à caler la loi de braquage : ils mélangent le braquage, la
réponse du pneu et le terrain. L'essai [`steerfade`](../../tools/fivem-telemetry/README.md) impose une
consigne **constante**, en créneaux alternés pour rester sur la bande plate, et relève le plateau établi.
72 essais, de 15 à 105 km/h, consignes 0,25 à 1,00 — [`steerfade-analyse.json`](steerfade-analyse.json).

### Trois surprises

**Une consigne de 0,25 ne braque pas du tout.** 0,001 ° de roue et 0,00 °/s de lacet, à toutes les
vitesses. L'axe analogique de GTA a une **zone morte**, mesurée à **0,2501** sur trois vitesses
indépendantes (dispersion 4 × 10⁻³) : le braquage demandé est `(consigne − 0,25) / 0,75`. C'est une
propriété de l'entrée, pas du véhicule — un joueur au clavier demande toujours 1,00 — mais sans elle
toute la campagne aurait été fausse d'un facteur 3.

**Au-dessus de la zone morte, la réponse est strictement linéaire.** À 60 km/h, sept consignes de 0,26 à
0,80 donnent une droite de pente 20,1 °/unité passant par 0,2543. Mieux : la loi déduite de chaque
consigne concorde — six consignes différentes à 60 km/h donnent le même braquage à pleine demande à
**0,39 ° près**.

**Il y a une butée mécanique à 30,625 °** (moyenne des deux roues avant ; l'intérieure va à 35 °,
l'extérieure à 26,25 °, soit un rapport d'Ackermann de 0,75). À 15 et 30 km/h, les consignes 0,80 et 1,00
donnent toutes deux exactement cette valeur.

### La loi mesurée

Braquage de roue (moyenne avant) réellement obtenu à pleine demande :

| Vitesse | Loi brute | Obtenu | Consignes concordantes |
|---|---|---|---|
| 15 km/h | 49,78 ° | **30,62 °** (butée) | 3, écart max 0,10 ° |
| 30 km/h | 32,34 ° | **30,62 °** (butée) | 4, écart max 0,16 ° |
| 45 km/h | 21,20 ° | **21,20 °** | 1 |
| 60 km/h | 14,69 ° | **14,69 °** | 6, écart max 0,39 ° |
| 75 km/h | 10,81 ° | **10,81 °** | 1 |
| 90 km/h | 8,27 ° | **8,27 °** | 4, écart max 0,14 ° |
| 105 km/h | 6,61 ° | **6,61 °** | 1 |

### Le lacet de GTA est purement cinématique

C'est le résultat le plus utile pour la vérification en 3D. Sur **20 plateaux**, de 15 à 102 km/h et de
0,56 ° à 16,6 ° de braquage, le lacet vaut exactement `v × braquage / L` avec un **empattement effectif de
2,811 m** (écart-type 0,038, écart maximal 3,9 %). Le m422 ne quitte donc jamais le régime cinématique
dans cette plage : ni sous-virage, ni survirage, à 4 % près. Critère de vérification côté Roblox :

```
lacet (rad/s) = vitesse (m/s) × braquage (rad) / 2,811
```

Et la dérive de caisse reste faible (0,5 ° à 45 km/h et 0,5 de consigne ; 13,8 ° seulement à 15 km/h en
butée, où le rayon est minuscule). Autrement dit : **si le braquage est juste, le lacet suit.** C'est bien
ce que montrait la 3D en négatif — 69 °/s au lieu de 29 parce que la roue braquait 2,4 fois trop.

### Ce qui est appliqué

La loi du moteur **change de forme**. Elle descendait linéairement de `SteeringLock` jusqu'à un plancher
atteint à `SteerFade` ; elle suit maintenant la forme mesurée :

```
lock(v) = min( SteeringLock × SteerLockMeanPct,
               max( SteeringLock / (1 + (v / SteerFade) ^ SteerFadePower), SteeringLock × SteerMinPct ) )
```

| Réglage | Avant | Après | Origine |
|---|---|---|---|
| `SteerFade` | 28 m/s | **15,0 m/s** | ajusté — sens changé : vitesse où le braquage tombe de moitié |
| `SteerFadePower` | — | **2,72** | ajusté conjointement |
| `SteerLockMeanPct` | — | **0,875** | **mesuré** : butée 30,625 ° pour `fSteeringLock` 35 ° |
| `SteerMinPct` | 0,3 | **0,1889** | **mesuré** : 6,61 ° à 105 km/h |
| `SteerPeakGain` | 1,6 | **0** | contredit par la mesure |

Seuls deux paramètres sont ajustés : le plafond et le plancher sont des mesures directes. RMS **0,78 °**
contre 2,07 ° pour la forme linéaire.

`SteerPeakGain` imposait au braquage de rester au-dessus de 1,6 × l'angle de dérive du pic, soit 15,2 ° :
il était donc **actif dès 100 km/h** et causait l'essentiel de l'écart. GTA ne braque que 6,61 ° à
105 km/h, **sous** l'angle du pic latéral (9,5 ° pour `PeakFactor` 0,5) : le véhicule n'est pas censé
pouvoir atteindre son pic latéral à haute vitesse.

Écart au braquage mesuré, avant et après (lu dans le module, pas recalculé à la main) :

| Vitesse | GTA | Avant | Après |
|---|---|---|---|
| 15 km/h | 30,62 ° | 32,06 ° (+5 %) | 30,62 ° (0 %) |
| 30 km/h | 30,62 ° | 29,14 ° (−5 %) | 29,11 ° (−5 %) |
| 45 km/h | 21,20 ° | 26,31 ° (+24 %) | 21,75 ° (+3 %) |
| 60 km/h | 14,69 ° | 23,39 ° (+59 %) | 15,01 ° (+2 %) |
| 75 km/h | 10,81 ° | 20,61 ° (+91 %) | 10,16 ° (−6 %) |
| 90 km/h | 8,27 ° | 17,70 ° (+114 %) | 6,98 ° (−13 %) |
| 105 km/h | 6,61 ° | 15,20 ° (+130 %) | 6,61 ° (0 %) |

**Pourquoi changer la forme, et pas seulement les coefficients.** La forme linéaire ne peut pas être à la
fois plate sous 30 km/h et lente au-delà, et son résidu tombait **justement dans la bande 30–45 km/h où
vivent les essais de virage** — donc sur le virage 40 qui sert à balayer `PeakFactor`. Le braquage de roue
relevé dans les traces GTA, comparé aux deux formes à la même vitesse et à la même consigne effective :

| Essai | Consigne | GTA | Forme linéaire | Forme mesurée |
|---|---|---|---|---|
| Virage 40 (36,5 km/h) | 1,00 | 26,17 ° | 23,63 ° (**−9,7 %**) | 26,03 ° (**−0,5 %**) |
| Créneau (58,1 km/h) | 0,50 | 5,07 ° | 5,63 ° (+11 %) | 5,25 ° (+3,6 %) |
| Slalom (59,4 km/h) | 0,50 | 4,95 ° | 5,50 ° (+11 %) | 5,08 ° (+2,7 %) |

Garder la forme linéaire aurait livré un virage 40 sous-braqué de 10 %, avec le risque que le balayage de
`PeakFactor` compense ce défaut par de l'adhérence — exactement l'erreur qui avait figé `PeakFactor` à 0,5.
Ce qui reste : −13 % vers 90 km/h, loin des essais de virage, et −5 % à 30 km/h.

### Ce que la pleine butée ne permet pas de mesurer

À partir de 45 km/h, la pleine butée fait **tomber la vitesse** : plateau à 41 km/h pour 45 visés, 54 pour
60, 57 pour 75 et 58 pour 90. Le véhicule ne tient pas un régime établi, la mesure n'en est donc pas une
(ces points sont marqués `retenu: false` dans le JSON, avec le motif). Pire, à 90 km/h et 0,80 de consigne
le braquage **redescend** à 3,57 ° alors que le lacet bondit à 72,8 °/s : GTA réduit l'angle de roue quand
l'arrière glisse. **Cette réduction est maintenant mesurée et calée** : voir « La direction a deux étages »
plus bas. Elle ne demandait pas une piste plus large, mais un essai en **cercle**.
5. **Vitesse perdue sur la marche à 20 km/h** : 1,9–2,0 km/h (GTA 0,06). Une part vient sans doute du
   régulateur de vitesse du banc (entrée à 21 km/h pour 20 demandés) : à confirmer avec une chute
   image par image (Roblox 0,7 km/h par image, GTA 0,13).

### Limites de cette vérification

- PC Studio, un joueur, une session ; aucun téléphone. Un seul véhicule (4 roues motrices).
- Une passe par réglage, sauf mention : le moteur est déterministe sur ce banc, mais une passe ne
  couvre pas un départ différent (le frein à main le montre : 1,4 °/s sur la ligne, 36,5 °/s en
  correction de cap).
- La marche Roblox fait 11,2 m de large contre 7,9 m pour les conteneurs ; arête franche des deux côtés.
- Après 1,27 s, le virage 80 GTA n'est pas comparable (marche du tablier) : la glisse à 53,9 ° n'est
  ni confirmée ni infirmée.
- Reproduction : scripts disponibles (`TestTrack.lua`, `DriveBench.lua`, `tools/drive-compare/`) ;
  la séquence complète prend ≈ 6 min de Play.

## `PeakFactor` rebalayé en 3D (Studio, 2026-11-12, après-midi)

Même protocole que « Vérification en 3D » (PC Studio, un joueur, `m422` converti, piste `TestTrack`,
`DriveBench` côté client, analyseur commun). Runtime de départ `4ef18427ca1c` (direction mesurée,
commit `85203d1`) ; runtime final `2b8eef57da8e` (ce commit). Moteur déterministe : une passe par point,
le point PF 0,8 / virage 40 rejoué à l'identique.

### Ce qui a changé dans le banc

- **Zone morte de l'axe GTA** : `DriveBench` alimente le moteur avec la demande **effective**
  `sign(c) × max(0, (|c| − 0,25) / 0,75)` (`Bench.gtaAxis`) : créneau 0,50 → 1/3, slalom 0,5 sin → sinus
  écrêté (bande morte autour de chaque passage par zéro), virages 1,00 → 1,00. La colonne `str` garde la
  consigne brute, comme les traces FiveM (l'analyseur y cale le début des fenêtres) ; `strEff` donne la
  demande réelle et `steerDeg` le braquage de roue appliqué par `VehicleDynamics`.
- **Dérive des pneus et braquage de roue** dans l'analyseur commun (`opts.axleFront/axleRear` ; m422 :
  1,38 / 1,41 m) : `lune run tools/drive-compare/gta.luau calibration/m422/fivem 1.38 1.41`, sortie de
  référence [`fivem-analyse-pneus.json`](fivem-analyse-pneus.json). Sans ces arguments, la sortie
  [`fivem-analyse.json`](fivem-analyse.json) est inchangée (vérifié).

### 1. Le créneau avant tout réglage

`PeakFactor` 0,5, `RollCentreScale` 1, demande effective 1/3 : **29,7 °/s** de lacet (GTA 29,30),
braquage de roue **5,01 °** à 59,9 km/h (GTA 5,00 ° à 58,1 km/h dans la fenêtre 1,0–1,8 s). La loi
donne 5,02 ° à 59,9 km/h et 5,25 ° à 58,1 : l'écart au 5,25 ° prévu vient de la vitesse tenue par le banc,
pas de la direction. Rien d'autre en cause : on a pu continuer.

### 2. La dérive des pneus de GTA, avec le bon signe

| Essai (fenêtre établie) | Braquage de roue | Pneu avant | Pneu arrière | Latéral |
|---|---|---|---|---|
| Créneau (1,0–1,8 s) | 5,00 ° | **3,17 °** | **3,05 °** | 0,834 g |
| Virage 40 (2–4 s) | 25,90 ° | **9,35 °** | **8,34 °** | 1,690 g |
| Virage 80 (1,0–1,27 s, transitoire) | **8,27 °** | 11,55 ° | 11,62 ° | 1,844 g |

`a` = 1,38 m, `b` = 1,41 m (centre de gravité du m422 converti) ; 3 passes, σ ≤ 0,2 °. Deux lectures :
le pneu de GTA est plus raide au début (0,27 g/° à 3 °) qu'à 9 ° (0,18 g/°) — une courbe qui s'infléchit
tôt — et au virage 80 GTA **ne braque que 8,3 °** à 70 km/h, là où la loi à consigne constante donne
11,6 ° : c'est la réduction du braquage quand l'arrière glisse, **mesurée et calée depuis** (voir « La
direction a deux étages »). À l'époque de ce balayage elle manquait, et le virage 80 ne pouvait donc pas
servir à régler `PeakFactor` : Roblox y braquait 10,6–11,8 ° et ses pneus avant passaient le pic. Le moteur
y est maintenant à 2,3 ° d'écart au lieu de 11,1 °, donc le virage 80 redevient utilisable — à rejouer.

**Deux contrôles extérieurs au calcul.** La fermeture géométrique du modèle bicyclette ne peut pas
départager les deux signes : β, `b/R` et α_arrière sont liés algébriquement, et `|atan(b/R) − α_arrière|`
vaut 4,3 ° dans les deux cas, au signe de β près. Il faut une grandeur prise ailleurs. Deux l'ont fait.

- **La trajectoire monde**, reconstruite depuis `px`, `py` et `heading` seuls, sans aucune convention de
  repère local : `wz` est bien la vitesse de lacet vraie (−91,46 °/s contre −91,52 lus sur la dérivée du
  cap), et `atan(vLat/vFwd)` vaut bien la dérive de caisse mesurée sur la trajectoire (3,92 ° contre
  3,90 °), avec le signe qui confirme que `vLat` est positif vers la **droite** (3 passes, virage 40
  établi). Conséquence physique, elle aussi décisive : avec le bon signe les **deux** pneus ont leur
  vitesse du côté extérieur de leur plan de roue, donc produisent une force vers le centre du virage ;
  avec l'autre, le pneu arrière la pousserait **hors** du virage, ce qui ne peut pas tenir en régime
  établi.
- **Le point de fonctionnement du pneu.** Le modèle monte linéairement jusqu'au pic : la part du pic
  d'adhérence tenue doit donc égaler la part du pic de dérive atteinte. À `PeakFactor` 0,55 le pic est à
  19 × 0,55 = 10,45 °. GTA tient 1,690 g sur 1,90, soit **88,9 % du pic d'adhérence**, avec 9,47 ° de
  dérive, soit **90,6 % du pic de dérive** : 1,7 point d'écart. Avec l'autre signe la voiture serait à
  **3,2 fois** son pic de dérive, donc très au-delà du décrochage, tout en tenant 1,690 g. Ce contrôle
  confirme du même coup la valeur 0,55 par un chemin qui ne passe pas par le balayage.

### 3. Une cause parasite : la boîte rétrogradait en virage

Au virage 40, `PeakFactor` 0,7 et 0,8 s'effondraient (32 km/h, 1,39–1,42 g). Trace image par image : la
2ᵉ tient 36 km/h à 0,85 de gaz, puis la boîte rétrograde en 1ʳᵉ (`DownshiftRpm` 0,45, ≈ 34–36 km/h en 2ᵉ),
les gaz passent à 1, la boîte pompe 1↔2 et la vitesse chute. GTA reste en 2ᵉ (36,5 km/h, 0,79 de gaz).
Dans les traces GTA, 2→1 se fait **sous gaz à 0,348–0,353** (virage 80, 3 passes, 30,2–30,6 km/h) et **en
roue libre à 0,404–0,410** (34 km/h). D'où `DownshiftRpmThrottle` = 0,35 (sous gaz) ; `DownshiftRpm` 0,45
reste pour les gaz relâchés (à 0,35, la roue libre 110-30 du banc longitudinal passe de −1,7 % à +9,2 %).
Banc longitudinal après : **5,3 %**, inchangé. C'est aussi, très probablement, la cause du « au-delà de
0,55 l'adhérence bascule » du premier balayage (non rejoué avec l'ancienne direction).

### 4. Balayage

Virage 40 avec la boîte corrigée (`RollCentreScale` 1) :

| `PeakFactor` | Latéral établi | Rayon | Dérive caisse | Pneus av. / arr. | Vitesse établie |
|---|---|---|---|---|---|
| **GTA** | **1,690 g** | **6,288 m** | **4,44 °** | **9,35 / 8,34 °** | **36,5 km/h** |
| 0,5 (boîte 0,45) | 1,684 | 6,48 | 4,87 | 9,06 / 7,55 | 37,2 |
| **0,55** | **1,675** | **6,37** | **4,35** | **9,54 / 8,26** | **36,8** |
| 0,6 | 1,667 | 6,27 | 3,85 | 10,02 / 8,95 | 36,5 |
| 0,7 | 1,644 | 6,12 | 2,79 | 11,06 / 10,29 | 35,8 |
| 0,8 | 1,606 | 6,06 | 1,66 | 12,28 / 11,52 | 35,2 |

Autres essais, boîte d'origine (`DownshiftRpm` 0,45), `RollCentreScale` 1 :

| `PeakFactor` | Créneau : dérive caisse, pneus av./arr. | Virage 80 : latéral, rayon | Slalom : lacet max |
|---|---|---|---|
| **GTA** | **0,59 °, 3,17 / 3,05 °** | **1,844 g, 18,8 m** | **25,16 °/s** |
| 0,4 | 0,73 °, 3,26 / 3,23 ° | 1,197 g, 34,0 m | 28,1 |
| 0,45 | 1,13 °, 3,67 / 3,63 ° | 1,312 g, 30,1 m | 27,8 |
| 0,5 | 1,53 °, 4,08 / 4,04 ° | 1,465 g, 26,4 m | 27,4 |
| 0,6 | 2,32 °, 4,89 / 4,84 ° | 1,620 g, 22,9 m | 26,6 |
| 0,8 | 3,88 ° | 1,804 g, 19,2 m | 24,9 |
| 0,9 | 4,64 ° | 1,858 g, 18,1 m | 24,1 |
| 1,0 | 5,37 ° | 1,913 g, 17,0 m | 23,4 |

À 0,9 et 1,0, le virage 40 (boîte d'origine) donnait 1,91 g à 38 km/h, rayon 6,05 / 5,86 m :
vraisemblablement tenu en 1ʳᵉ (non relevé), donc non comparable.

**Retenu : `PeakFactor` 0,55.** C'est le seul point qui tient à la fois le rayon, la dérive de caisse,
les deux dérives de pneus et la vitesse du virage 40, à 2 % près. Pas besoin d'aller au-delà de 1,0 :
il fallait au contraire **rester sous 0,6**.

**Ce qu'aucune valeur ne tient** : le créneau voudrait 0,4 (pneus à 3,2 ° pour 0,83 g), le virage 40
0,55. Le pneu Roblox est linéaire jusqu'au pic puis décroît (`F = fmax × min(s, 1)`) ; celui de GTA
s'infléchit tôt. Un seul `PeakFactor` ne peut pas reproduire les deux pentes : il faudrait une courbe de
pneu à inflexion progressive. Le virage 80 voudrait 0,9, mais à l'époque de ce balayage il était faussé par
l'absence de réduction du braquage en glisse (§ 2) ; celle-ci étant désormais calée, ce point est à rejouer.

### 5. `RollCentreScale`

`PeakFactor` 0,55, boîte corrigée :

| `RollCentreScale` | Virage 40 : roulis, latéral, rayon, vitesse | Créneau : roulis, latéral | Virage 80 : roulis, latéral, rayon |
|---|---|---|---|
| **GTA** | **1,714 °, 1,690 g, 6,29 m, 36,5 km/h** | **0,859 °, 0,834 g** | **1,848 °, 1,844 g, 18,8 m** |
| 1 | 0,38 °, 1,675 g, 6,37 m, 36,8 | 0,20 °, 0,878 g | 0,39 °, 1,536 g, 24,6 m |
| 0,5 | 0,97 °, 1,659 g, 6,26 m, 36,3 | 0,52 °, 0,861 g | 1,00 °, 1,568 g, 26,6 m |
| **0,25** | **1,26 °, 1,650 g, 6,14 m, 35,9** | **0,67 °, 0,853 g** | **1,25 °, 1,625 g, 26,1 m** |
| 0,1 | 0,79 °, **0,889 g**, 5,01 m, **23,8** | 0,76 °, 0,848 g | 1,38 °, 0,627 g, 60,8 m |
| 0 | 1,11 °, **1,156 g**, 4,97 m, **27,0** | 0,82 °, 0,845 g | 3,52 °, 1,493 g, 19,6 m |

**Retenu : 0,25** (0,76 °/g ; GTA 1,01 °/g). C'est la valeur la plus basse qui tient. À 0,1 et 0, le virage 40
s'effondre. **Cause démontrée** par une trace roue par roue (RCS 0) : la roue **arrière intérieure** se
déleste et patine (vitesse de roue 77 puis 130 km/h pour 35 km/h de véhicule). Le régime, calculé sur la
moyenne des roues motrices, s'emballe, la boîte monte en 3ᵉ et le véhicule perd sa motricité. GTA roule par
moments sur 2 ou 3 roues au virage 40 sans rien perdre. Pour atteindre 1 °/g, il faut d'abord traiter ce
patinage (répartition du couple vers les roues chargées, régime pris sur la vitesse du véhicule ou sur
les roues au sol), puis redescendre ce réglage.

### 6. Avant / après, valeurs par défaut du module

« Avant » = runtime `4ef18427ca1c` (`PeakFactor` 0,5, `RollCentreScale` 1, rétrogradage à 0,45), banc avec
zone morte. « Après » = runtime `2b8eef57da8e` (`PeakFactor` 0,55, `RollCentreScale` 0,25,
`DownshiftRpmThrottle` 0,35), aucun réglage en direct (les chiffres retombent au centième sur ceux du
balayage).

| Essai | Mesure | GTA | Avant | Après |
|---|---|---|---|---|
| Virage 40 | latéral établi / pic | 1,690 / 1,829 g | 1,684 / 1,709 g | 1,650 / 1,711 g |
| | rayon | 6,288 m | 6,48 m | 6,14 m |
| | lacet max | 97,3 °/s | 91,5 °/s | 93,0 °/s |
| | roulis établi / max | 1,714 / 1,891 ° | 0,38 / 0,38 ° | **1,26 / 1,28 °** |
| | dérive de caisse établie | 4,44 ° | 4,87 ° | 4,02 ° |
| | pneus av. / arr. | 9,35 / 8,34 ° | 9,06 / 7,55 ° | 9,89 / 9,05 ° |
| | **braquage de roue appliqué** | 25,90 ° | 25,66 ° | **26,33 °** (35,9 km/h) |
| | vitesse en fin | 38,23 km/h | 37,2 km/h | 35,9 km/h |
| Virage 80 (0–1,27 s) | latéral établi / pic | **1,844 / 1,898 g** | 1,465 / 2,58 g ⚠ | 1,596 / 2,48 g ⚠ |
| | rayon | 18,82 m | 26,39 m | 26,59 m |
| | lacet max | 60,7 °/s | 66,8 °/s | 64,4 °/s |
| | roulis établi / max | 1,848 / 1,887 ° | 0,39 / 0,43 ° | **1,25 / 1,40 °** |
| | **braquage de roue appliqué** | 8,27 ° | 11,53 ° (max 11,82) | **10,56 °** (max 10,68, 73,5 km/h) |
| Créneau 60 (1/3) | latéral établi | 0,834 g | 0,879 g | 0,853 g |
| | rayon | 32,76 m | 32,14 m | 33,04 m |
| | lacet max | 29,30 °/s | 29,7 °/s | 28,9 °/s |
| | roulis établi | 0,859 ° | 0,20 ° | **0,67 °** |
| | dérive de caisse | 0,59 ° | 1,53 ° | 1,89 ° |
| | **braquage de roue appliqué** | 5,00 ° | 5,01 ° | **5,02 °** (59,9 km/h) |
| Slalom 60 (écrêté) | lacet max | 25,16 °/s | 27,4 °/s | 26,6 °/s |
| | roulis max | 0,675 ° | 0,15 ° | 0,49 ° |
| | pic latéral | **0,594 g** | 0,818 g ⚠ | 0,798 g ⚠ |
| | **braquage de roue max** | 4,95 ° | 4,94 ° | **4,93 °** |
| Frein à main 60-0 | distance, décélération | 20,0 m, 0,71 g | 15,7 m (matin) | **17,96 m, 0,77 g** |
| | lacet max | 0,13 °/s | 1,4–2,0 °/s (matin) | 1,03 °/s |
| Côte 16,5 % | plein gaz 4 s | 45,1 km/h, 32,5 m | 36,7 km/h, 32,8 m (matin) | 40,9 km/h, **22,9 m** |
| | tout relâché 2 s | 0,0 cm | 5,7 cm (matin) | 6,7 cm |

Le braquage GTA de ce tableau est la moyenne des deux roues avant dans la **fenêtre établie** de
l'analyseur (virage 40 : 2–4 s) ; le 26,17 ° cité ailleurs est pris sur une autre fenêtre.

Frein à main et côte : une passe chacun, observés sans cause isolée (`PeakFactor`, `RollCentreScale` et
le seuil de rétrogradage sous gaz ont changé ensemble). La côte arrive plus vite (40,9 km/h) mais sur
22,9 m au lieu de 32,8 : démarrage plus lent puis reprise. Ni amélioré ni dégradé franchement. À rejouer
séparément.

### 7. Ce qui reste

- ~~**Forme du pneu**~~ : **expliqué** le 2026-11-12, voir « La courbe du pneu ». Ce n'était pas la forme
  de la courbe mais un **plafond latéral proportionnel à la vitesse latérale** (`LatVCap`) ; avec lui, un
  `PeakFactor` unique tient le créneau à −3,8 % et le virage 40 à −3,6 %. `PeakFactor` à rebalayer en 3D
  avec le plafond actif (prédiction : 0,385 à 0,45).
- ~~**Réduction du braquage en glisse**~~ : **mesurée et calée** le 2026-11-12 après-midi, voir « La
  direction a deux étages ». Le virage 80 redevient utilisable au calage ; à rejouer en 3D.
- **Roulis à 0,76 °/g** au lieu de 1,0 : bloqué par le patinage de la roue intérieure délestée (§ 5).
- **Limites** : PC Studio, un joueur, une passe par point (moteur déterministe), un seul véhicule.
  Repro : scripts disponibles (`DriveBench.lua`, `TestTrack.lua`, `tools/drive-compare/`), ≈ 1 min de
  Play par point de balayage. Reproduction vérifiée pour la passe finale (valeurs par défaut = valeurs du
  balayage au centième).

## Correction de l'instrument : `v × wz` n'est pas l'accélération latérale en transitoire

Découvert le 2026-11-12 en vérifiant pourquoi la cible du virage 80 (2,026 g) dépassait
`fTractionCurveMax` (1,90 g) : **aucun réglage de pneu ne peut atteindre une cible qui dépasse
l'adhérence maximale du modèle.** La cible était fausse.

L'analyseur calculait l'accélération latérale par `|vFwd × wz|`, qui n'est la bonne valeur qu'en régime
**établi**. En repère tournant, `a = dv/dt + ω × v`, donc la composante latérale vaut :

```
a_lat = d(vLat)/dt − wz · vFwd
```

Le terme manquant n'est nul que si la dérive de caisse ne bouge plus. Contrôle contre l'accélération
dérivée du repère **monde** (`px`, `py`, `heading`, différence centrée), 3 passes par essai :

| Essai | `v × wz` | Formule complète | Vérité monde |
|---|---|---|---|
| Virage 40 (établi) | 1,69 g (**−0,2 à +0,6 %**) | 1,689 g (0,0 %) | 1,690 g |
| Créneau (établi) | 0,83 g (**−0,4 à −0,2 %**) | 0,834 g (−0,1 %) | 0,835 g |
| Virage 80 (transitoire) | 2,03 g (**+8,9 à +10,8 %**) | 1,846 g (+0,1 %) | 1,845 g |
| Slalom (transitoire) | 0,366 g (**+8,2 %**) | 0,338 g (+0,1 %) | 0,338 g |

Corrigé dans [`tools/drive-compare/analyze.luau`](../../tools/drive-compare/analyze.luau) (donc des deux
côtés : traces FiveM **et** traces `DriveBench`) et dans le résumé en jeu de
[`tools/fivem-telemetry`](../../tools/fivem-telemetry). Les traces enregistrées ne sont pas touchées :
elles contiennent les échantillons bruts, pas des grandeurs calculées.

### Ce que ça change

| Cible GTA | Avant | Après |
|---|---|---|
| Virage 80, latéral établi | 2,026 g | **1,844 g** (σ 0,003) |
| Virage 80, pic latéral | 2,244 g | **1,898 g** (σ 0,003) |
| Virage 80, roulis par g | 0,912 °/g | **1,002 °/g** |
| Slalom, pic latéral | 0,737 g | **0,594 g** (σ 0,001) |
| Virage 40, latéral établi | 1,694 g | 1,690 g |
| Créneau, latéral établi | 0,832 g | 0,834 g |

Les essais établis ne bougent pas (0,2 %, mais hors répétabilité : σ = 0 sur 3 passes). Deux
conséquences, toutes deux dans le bon sens :

1. **`fTractionCurveMax` est bien le plafond d'adhérence latérale, à 0,1 % près.** Le virage 80 est le
   seul essai qui atteigne la limite : son pic corrigé vaut **1,898 g** (σ 0,003) pour un champ déclaré à
   **1,90**. `KMu` = 1,0 n'était vérifié que sur l'axe du freinage (1,88 g roues bloquées) ; il l'est
   maintenant aussi sur l'axe latéral, par un essai indépendant.
2. **Le roulis de GTA est linéaire sur toute la plage mesurée.** 1,014 °/g au virage 40 (1,69 g),
   1,030 au créneau (0,83 g), **1,002** au virage 80 (1,84 g). C'est l'ancienne valeur de 0,912 °/g au
   virage 80 qui faisait croire à un tassement au-delà de 1 g. Cible de `RollCentreScale` : **1,0 °/g**,
   sans réserve.

### Ce qui reste à rejouer

Les colonnes Roblox marquées ⚠ dans « 6. Avant / après » (virage 80 latéral établi et pic, slalom pic
latéral) ont été mesurées avec l'ancienne formule : elles sont surévaluées du même ordre, mais pas du même
montant, et ne sont donc plus comparables à la colonne GTA corrigée. Les traces `DriveBench` n'étant pas
dans le dépôt, il faut **une passe en Studio** avec l'analyseur corrigé pour les remplacer. Les essais
établis (virage 40, créneau) et tout ce qui ne dépend pas de l'accélération latérale (lacet, rayon,
roulis, braquage, dérives de pneu) restent valables.

## La direction a deux étages (cercles à consigne constante, 2026-11-12)

La note « GTA réduit le braquage quand le véhicule glisse, reste à caler, demanderait une piste large »
était ouverte depuis la campagne de direction. Elle est fermée, et elle disait deux choses fausses : ce
n'était pas une loi de **glisse** au sens où je le croyais, et il ne fallait pas une piste plus large mais
un essai d'une autre **forme**.

### Pourquoi le virage 80 ne pouvait rien identifier

Dans le virage 80, la vitesse tombe, la dérive monte et le temps avance **ensemble** : les prédicteurs
candidats sont colinéaires, et n'importe quelle fonction décroissante colle aux données. Deux hypothèses
tirées de cette seule manœuvre sont d'ailleurs mortes à la vérification :

- « l'écart suit la dérive de caisse, −1,035 ° par degré au-delà de 4 ° » : magnifique sur le virage 80 à
  0,3 ° près, mais de **signe opposé** sur les images en glisse des essais `steerfade` ;
- « il y a une butée de vitesse de braquage à 37 °/s » : morte, la roue atteint **575 °/s** ailleurs.

### L'essai qui sépare les variables : le cercle

[`skidpad`](../../tools/fivem-telemetry/README.md) tient une consigne **fixe** et une vitesse **tenue par
le régulateur** : la dérive s'établit à une valeur qui ne dépend plus du temps, et on balaye consigne et
vitesse l'une à l'autre fixée. Il faut pour cela un **carré** plat, pas un couloir.

**Le site.** [`gridprobe`](../../tools/fivem-telemetry/README.md) relève le sol au rayon sur une grille de
120 m de côté ([`tablier-grille.json`](tablier-grille.json)). Le critère de platitude est le résidu autour
d'un plan ajusté **sur le disque testé** : l'ajuster sur toute la grille laisse la périphérie corrompre le
plan et pollue jusqu'au centre (c'est ce qui m'a d'abord fait conclure « aucune zone plate »). Résultat :
un disque de **24 m de rayon** centré sur (−1205, −3032), résidu maximal **19 mm**, pente nulle.

Et une propriété commode : si le virage est déclenché sur le **bord** du disque, un cercle de rayon R y est
inscrit **exactement**, quel que soit R ≤ 24 m — la distance du centre du disque au centre du cercle vaut
|R − 24|, donc le point le plus éloigné est à |R − 24| + R = 24 m. Une seule géométrie suffit donc pour
toutes les vitesses : ligne droite depuis (−1115, −3056) cap 90, virage à droite déclenché à (−1205, −3056).

### Étage 1 : la commande vers les roues

La trace contient deux grandeurs que je n'avais jamais comparées : `steerAngle`, la **commande** (le volant,
0 à 35 °), et `w0str`/`w1str`, l'angle des **roues**. Au virage 80, la commande monte à 35 ° et **y reste** :
ce ne sont pas les ordres qui baissent, ce sont les roues qui ne suivent pas.

Sur les 18 cercles, le rapport roues/commande ne dépend que de la **vitesse**, pas de la commande : à
40 km/h il vaut 0,696 / 0,701 / 0,729 / 0,727 pour des commandes de 14 / 21 / 28 / 35 °. Et il colle à la
loi mesurée à consigne constante, donc le cercle **confirme cette loi par une manœuvre entièrement
différente**.

Un point d'ordre, que le cercle tranche : **GTA plafonne à la butée AVANT de multiplier par la consigne.**
À 15 km/h la loi non plafonnée donnerait 49,8 ° ; si le plafond venait après, une demi-consigne donnerait
16,6 ° et le rapport mesuré vaudrait 1,63. Il vaut 1,12. (J'avais d'abord ajusté la réduction avec la loi
non plafonnée : l'erreur fausse toutes les images sous 22 km/h.)

### Étage 2 : la réponse à l'échelon

La commande et les roues montent à des vitesses **différentes**, les roues plus vite :

| | 0,1 s | 0,2 s | 0,4 s |
|---|---|---|---|
| commande (fraction de l'établi) | 0,58 à 0,65 | 0,78 à 0,86 | 0,95 à 0,98 |
| roues (fraction de l'établi) | 0,62 à 0,82 | 0,85 à 1,05 | 1,00 à 1,12 |

D'où un rapport roues/commande qui **dépasse transitoirement 1,5 fois** sa valeur établie à 68 km/h — ce
qui est un artefact de rapport, pas un dépassement de la direction. L'angle de roue lui-même ne dépasse que
de 4 à 13 % (1,050 à 30 km/h, 1,062 à 40, 1,115 à 50, 1,110 à 60, 1,092 à 70) et atteint 90 % de l'établi
en **0,14 à 0,24 s**. Non modélisé : le moteur applique la valeur établie sans délai.

### La réduction quand l'arrière glisse

Le prédicteur retenu est la **vitesse latérale de l'essieu arrière**, `vLat + b·lacet` :

```
réduction = borne(1 − 0,18 × (|vLat + b·lacet| − 1,8 m/s), 0,30, 1)
```

appliquée au braquage disponible après le fondu en vitesse et le plancher, mais **avant la butée**.

**Pourquoi celui-là.** Sur 7972 images et 27 traces (cercles, virage 40, virage 80, créneau, slalom), c'est
lui qui laisse le moins de dépendance résiduelle à la vitesse, et c'est le seul des bons candidats qui ne
dépende pas de l'angle de roue — la dérive du pneu **avant** se calcule à partir de lui, donc la prendre
comme prédicteur serait circulaire, ce qui explique aussi qu'elle paraisse bonne.

| Prédicteur | Dispersion résiduelle entre vitesses |
|---|---|
| **vitesse latérale arrière** | **0,069** |
| dérive du pneu arrière (angle) | 0,087 |
| dérive du pneu avant | 0,349 (circulaire) |
| accélération latérale | 0,381 |
| dérive de caisse | 0,382 |
| vitesse latérale de la caisse | 0,467 |
| vitesse de lacet | 0,540 |

Écart quadratique moyen **0,066** sur un rapport qui descend jusqu'à 0,30 ; résidu par essai : virage 40
−0,002, cercles +0,007, virage 80 +0,027, créneau −0,064 (ce dernier est le résidu de la loi de base à
60 km/h, pas de la réduction).

**Et ce n'est pas une loi de dérive de caisse** : à 15 km/h le rapport reste à 1,0 jusqu'à 14 ° de dérive de
caisse, alors qu'à 70 km/h il tombe à 0,72 dès 7,4 °. La vitesse latérale arrière explique les deux — en
cercle serré à 15 km/h, le terme géométrique `b·lacet` annule presque `vLat`, donc l'arrière ne glisse pas.

### Vérification du moteur sur les images mesurées

Le moteur tourne sur **1200 images mesurées** (commande stable, 4 roues au sol, 27 traces) et on compare son
angle de roue à celui de GTA. Cela vérifie l'**implémentation** — signes, distance à l'essieu arrière, ordre
vis-à-vis de la butée — et non l'ajustement.

| Essai | Images | Sans la réduction | Avec | Biais avec |
|---|---|---|---|---|
| **Global** | 1200 | 4,040 ° | **1,290 °** | — |
| Virage 80 | 67 | 11,144 ° (biais +9,74) | **2,295 °** | −0,93 ° |
| Cercles | 960 | 3,420 ° | **1,297 °** | −0,35 ° |
| Virage 40 | 81 | 0,363 ° | **0,363 °** | −0,02 ° |
| Créneau | 92 | 0,451 ° | **0,451 °** | +0,28 ° |

**Le virage 40 et le créneau sont inchangés au millième** : la réduction n'agit que là où l'arrière glisse.
`PeakFactor` 0,55 et `RollCentreScale` 0,25, calés sur ces deux essais, ne sont donc pas remis en cause. Le
banc longitudinal reste à 5,3 %.

Mesures complètes : [`skidpad-analyse.json`](skidpad-analyse.json), six traces brutes dans
[`fivem/`](fivem/).

### Le retard de la direction, mesuré et appliqué

L'angle de roue ne saute pas à sa valeur établie : il la rejoint par un **premier ordre**.

```
roue(t+dt) = roue(t) + (cible(t) − roue(t)) × (1 − exp(−dt / SteerTau)),  SteerTau = 0,08 s
```

**Comment c'est mesuré.** Les créneaux alternés de `steerfade` sont des échelons propres à vitesse tenue
sur une ligne droite, et chaque essai en contient quatre : avec les cercles et le créneau, cela fait
**380 fronts** exploitables. Chaque modèle candidat tourne en **simulation libre** — son état est reporté
d'un pas au suivant, jamais recalé sur la mesure — nourri de la vitesse et du lacet mesurés.

| Modèle | Écart sur l'angle de roue |
|---|---|
| sans retard (ancien moteur) | 5,312 ° |
| butée de **vitesse** de braquage seule (240 °/s) | 3,822 ° |
| **retard du premier ordre, τ = 0,08 s** | **3,806 ° (global), 1,305 ° sur les tranches propres** |
| retard + butée de vitesse | 3,692 ° |
| retard à τ variable, `max(0,03 ; 0,125 − 0,0012 v)` | 3,705 ° |

Les tranches 45 et 75 km/h gardent ~5 ° d'écart avec ou sans retard : elles sont contaminées par le régime
de glisse dure, où la réduction sature à son plancher. Sur les tranches propres (15, 30, 60, 90 km/h),
l'écart passe de **5,312 ° à 1,305 °**, soit un facteur 4.

**Ce qui a été écarté, et pourquoi.**

- **Une butée de vitesse de braquage.** Elle fait presque aussi bien (3,82 contre 3,81 °) mais l'ajouter au
  retard ne gagne que 0,02 °, et surtout la réponse normalisée **ne dépend pas de l'amplitude** : à 30 km/h,
  des créneaux de 10–20 ° et de 40–50 ° donnent la même courbe malgré des vitesses de roue de 101 et
  306 °/s. Une butée de vitesse l'interdirait. (Elle avait d'abord semblé bien meilleure — 0,88 ° — mais
  parce que je la recalais sur l'angle mesuré à chaque pas : un prédicteur à un pas, pas une simulation.)
- **Un τ variable avec la vitesse.** Les ajustements par tranche donnent 0,100 s à 15 km/h et 0,050 à 90,
  mais une fois mis sous la forme `max(0,03 ; 0,125 − 0,0012 v)` et ajusté en une seule passe, le gain
  tombe à 1,21 ° contre 1,35 ° — il ne survit pas. Un seul réglage mesuré vaut mieux que trois ajustés.

**Et la commande n'est pas ce qui pilote les roues.** Le τ de `steerAngle` **monte** avec la vitesse
(0,090 s à 15 km/h, 0,170 s à 90), celui des roues **descend**. Les roues arrivent donc avant la commande :
`steerAngle` est l'animation du volant, pas l'ordre qui commande le braquage. C'est ce qui m'avait fait
décrire un « étage 1 commande → roues » ; la relation établie entre les deux reste vraie, mais elle n'est
pas causale.

### Ce qui reste ouvert

- Le **dépassement** résiduel de l'angle de roue (4 à 13 % selon la vitesse) n'est pas modélisé : un premier
  ordre ne dépasse jamais. Il faudrait un second ordre, pour un gain qui reste à démontrer.
- Les trois cercles qui partent en toupie (18 à 21 km/h, dérive 10 à 19 °) gardent un écart de 7 ° : la
  réduction y sature à son plancher de 0,30 alors que GTA braque encore. Régime non calé, et sans intérêt
  pour le calage.
- Le résidu de −0,064 au créneau est celui de la loi de base à 60 km/h, pas de la réduction.

## La courbe du pneu : ce n'est pas sa forme qui manquait (2026-11-12)

Le point ouvert disait : « un seul `PeakFactor` ne tient pas à la fois le créneau, qui voudrait 0,4, et le
virage 40, qui veut 0,55 ; le pneu de Roblox est linéaire jusqu'au pic, celui de GTA s'infléchit tôt ; il
faudrait une courbe à inflexion progressive ». **La forme n'était pas le problème.**

### Ce que les cercles permettent de mesurer

En régime établi, l'équilibre des moments de lacet donne `a·Ff = b·Fr`, et les charges statiques valent
`Nf = m·g·b/L` et `Nr = m·g·a/L` : donc `Ff/Nf = Fr/Nr =` l'accélération latérale en g, **quelles que soient
a et b**. Chaque plateau donne ainsi deux points de la courbe. Et la télémétrie donne, par roue, le
braquage individuel (donc l'Ackermann), la vitesse d'avance (qui diffère d'une roue à l'autre de
`lacet × voie/2`) et la **charge**, par la compression de suspension — dont le sens est vérifié sur des cas
connus : au freinage l'avant passe à 0,241 contre 0,159 à l'arrière, et en virage l'extérieur à 0,218 contre
0,172. Plus aucune hypothèse de charge, de moment ni de voie n'est donc nécessaire.

### Premier résultat : la forme n'est pas identifiable

Cinq formes ajustées sur 33 plateaux, chacune avec son `alphaPic` libre :

| Forme | Écart |
|---|---|
| linéaire jusqu'au pic | 0,1365 g |
| sinus | 0,1491 g |
| tanh | 0,1365 g |
| Möbius `(1+k)s/(1+ks)` | 0,1385 g |
| puissance `s^k` | 0,1310 g |

Elles tiennent dans 0,006 g l'une de l'autre, parce qu'un résidu bien plus grand les domine. **Choisir une
forme là-dessus n'aurait rien mesuré.**

### Le résidu suit la VITESSE, et c'est un défaut de conception de ma campagne

La première campagne de cercles faisait varier la vitesse et le rayon **ensemble** (chaque vitesse avec ses
consignes), donc le résidu n'était pas attribuable. Dix cercles de plus, à **rayon imposé** (8, 12 et 18 m,
la consigne étant calculée à chaque vitesse depuis la loi de braquage), le séparent :

| Rayon 18 m | 29,8 km/h | 39,2 | 48,6 | 57,6 | 66,5 |
|---|---|---|---|---|---|
| écart du modèle en angle | **+25 %** | +10 % | −2 % | −12 % | **−17 %** |

Corrélation de l'écart avec la vitesse **−0,84**, avec le rayon −0,56, avec le patinage longitudinal +0,45.
C'est donc la vitesse. Deux explications écartées en route :

- **la charge** : un offset de précontrainte sur la compression (la compression sous-estime le report, 1,52
  au freinage là où la géométrie impose 1,99) ne gagne que 4 % et laisse la corrélation à −0,85 ;
- **le cercle de frottement** : la roue intérieure délestée patine bel et bien en cercle serré (`sk` jusqu'à
  1,04), mais le plan à rayon imposé montre que la vitesse domine, pas le rayon.

### Le mécanisme : un plafond proportionnel à la vitesse latérale

```
|Fy| ≤ LatVCap × |vitesse latérale au contact| × charge,   LatVCap = 1,25 par (m/s)
```

| | Écart | Corr. vitesse | Corr. rayon |
|---|---|---|---|
| sans plafond | 0,1365 g | −0,840 | −0,560 |
| **avec plafond** | **0,0829 g** | **−0,167** | **+0,022** |

Un seul paramètre tue les deux corrélations et retire 39 % du résidu. La variable « angle de dérive »
sous-corrigeait la vitesse, la variable « vitesse latérale » la sur-corrigeait (corrélation +0,43) : le
plafond fait la bonne chose, puisqu'il n'applique la dépendance que là où elle mord. C'est vraisemblablement
le `fTractionSpringDeltaMax` du handling, décrit comme un débattement latéral de flanc qui ramène le
véhicule à l'arrêt après une glisse — une **longueur**, pas un angle.

### Ce que ça résout

Avec le plafond et un `PeakFactor` **unique** :

| Essai | Avant (linéaire, 0,55, sans plafond) | Après |
|---|---|---|
| Créneau (58,9 km/h) | **−32,7 %** | **−3,8 %** |
| Virage 40 (36,8 km/h) | −12,6 % | −3,6 % |

Les deux essais diffèrent autant en **vitesse** qu'en dérive : c'est pour ça qu'un modèle sans dépendance à
la vitesse ne pouvait pas tenir les deux, et pourquoi le balayage en voulait 0,4 pour l'un et 0,55 pour
l'autre.

### ⚠ Les deux réglages sont couplés — et le plafond seul ne fait presque rien

À `PeakFactor` 0,55, le plafond est **quasi inerte** (0,2611 → 0,2619 g dans le modèle statique) : la courbe
y est déjà sous le plafond partout. Il ne mord que si la courbe est plus raide. C'est le **couple** qui
compte :

| `PeakFactor` | sans plafond | avec plafond |
|---|---|---|
| 0,385 | 0,1746 g | **0,0829 g** |
| 0,45 | 0,1402 g | 0,1249 g |
| 0,55 (en place) | 0,2611 g | 0,2619 g |

`LatVCap` = 1,25 est donc posé dans le moteur, mais **`PeakFactor` reste à 0,55 en attendant un rebalayage
en 3D**, pour deux raisons : le modèle ci-dessus est statique (il prédit l'accélération latérale à partir des
dérives et des charges mesurées, il n'est pas le moteur), et le balayage en 3D est l'autorité sur ce que le
moteur produit vraiment. Prédiction à vérifier : avec le plafond actif, `PeakFactor` devrait descendre vers
**0,385 à 0,45**.

### Ce qui reste

- **La forme de la courbe reste non identifiable** : elle reste donc linéaire jusqu'au pic.
- Il reste **+10 à +14 % vers 38-48 km/h**, là où le plafond cesse de mordre : la transition est un `min`
  dur, un raccord progressif ferait sans doute mieux.
- Mesures complètes : [`tyre-analyse.json`](tyre-analyse.json).

## La côte : le frottement statique, et une anomalie de poussée (2026-11-12)

### Un banc de côte, sans Studio

La côte demandait Studio. Or une pente en ligne droite ne demande au banc que deux choses : la composante
de gravité le long de la pente, et les charges corrigées (`cos` de la pente, plus le report longitudinal
`sin × h/L`). Le solveur 3D n'est pas nécessaire. `lune run tools/roblox-drive-rig/rig.luau cote` rejoue donc
l'essai `hill` en quelques secondes, avec le **profil de pente mesuré** : elle n'est pas constante, elle passe
de **17,1 % à 37 %** pendant les 4 s du lancement, et prendre sa moyenne (25 %) pénalise à tort le début.

Le profil est vérifié de deux façons indépendantes : l'assiette de caisse (colonne `pitch`) et la pente de la
**trajectoire** (`dz` / distance horizontale, qui ne dépend pas de l'assiette). Elles concordent — 25,0 et
25,2 % de moyenne, 39,8 et 40,3 % en fin de lancement — donc le cabrage sous la poussée ne fausse pas la
lecture.

### Le frottement statique : GTA tient, le moteur descendait

**MESURÉ** sur l'essai `hill`, 3 passes : tout relâché pendant 2,0 s sur une pente de 17,1 %, déplacement
**0,000 m**, vitesse 0,00 km/h, boîte **au point mort** et pression de frein **nulle**. Ce n'est donc ni un
frein automatique ni le frein à main : c'est le pneu qui tient.

Le moteur ne pouvait pas : son plancher `VMin` divise le glissement par 1 m/s, donc à l'arrêt le glissement
est nul et la force avec. Le véhicule descendait la pente sur ses pneus (2,9 cm en 2 s au banc).

Deux essais avant d'y arriver, et le premier est instructif :

| | Recul en 2 s | Vitesse de fluage |
|---|---|---|
| sans rien | 2,9 cm | −0,36 km/h |
| **amortisseur** (force ∝ vitesse de glissement) | **5,5 cm** | −0,10 km/h |
| **ressort** (force ∝ glissement accumulé) | **0,1 cm** | −0,13 km/h |

L'amortisseur fait **pire** : une force proportionnelle à la vitesse s'annule avec elle, donc il subsiste une
vitesse de fluage d'équilibre (ici 0,10 km/h, soit 5,5 cm en 2 s — le véhicule flue moins vite, mais plus
longtemps). Le ressort, lui, garde sa force à vitesse nulle. `KStick` = 200 par mètre : la tenue demande
0,8 mm de déformation à 17 % de pente, et le décrochage vient à 9,5 mm, ce qui est l'ordre de grandeur d'un
flanc de pneu. `CStick` = 28 l'amortit.

### GTA pousse plus fort en côte — mesuré, triplement vérifié, et non activé

Le lancement restait à −10,7 % en vitesse finale pour +6,4 % en distance. En cherchant pourquoi, une mesure
inattendue : relevée sur **1046 images à plein gaz en 2ᵉ**, 14 traces (accélérations à plat, côtes, et un
essai [`thrust`](../../tools/fivem-telemetry/README.md) écrit pour ça, qui monte à vitesse **tenue** jusqu'à
une pente donnée puis met plein gaz sur une fenêtre courte, pour que ni la vitesse ni la pente ne bougent) :

```
poussée = 0,400 g + 0,537 × g × sin(pente)        écart 0,081 g
```

| Pente | Images | Poussée mesurée |
|---|---|---|
| plat (< 5 %) | 534 | **0,398 g** |
| 15 à 25 % | 138 | 0,596 g |
| 25 à 35 % | 313 | 0,516 g |
| > 35 % | 61 | 0,647 g |

À plat, les **0,400 g sont exactement `fInitialDriveForce` × rapport × g** (0,2 × 2,0 × 9,81), et la valeur
est constante de 0,50 à 0,90 de régime. En pente, GTA récupère **54 % de la résistance de la pente**. Une
poussée constante donne 0,134 g d'écart, la loi 0,081 g, et le résidu ne corrèle plus ni avec la vitesse
(+0,09) ni avec le régime (+0,08).

**Trois vérifications, parce que le résultat est surprenant.** La pente lue sur la **trajectoire**
(`dz` / distance horizontale), celle lue sur l'**assiette de caisse**, et celle relevée au **rayon sans
véhicule** (`gridprobe` : 18,1 / 23,5 / 29,5 / 34,6 % le long de la montée) concordent. Et le **régime est
identique** à plat et en pente à vitesse égale (0,542 contre 0,543 à 45 km/h) : c'est donc bien le même
rapport, pas une rétrogradation déguisée.

**Deux fausses pistes écartées en route.** D'abord j'ai cru que `pz` mesurait le rebond de caisse et non la
route : une fenêtre de pente longue (±0,4 s, 9 m) ne change rien. Ensuite, des poussées impossibles
(1,2 à 1,37 g, soit trois fois la force disponible) venaient d'**une seule trace**, `hill_essai`, un essai
préliminaire hors campagne : écartée, le reste redevient cohérent.

**Et une ambiguïté non levée** : `GetVehicleWheelPower`, sommée sur les quatre roues, vaut **0,388 à plat
comme en pente**, identique à trois décimales. Si cette colonne était une force, elle prouverait que GTA
n'ajoute rien et que mon bilan est faux. Mais 0,388 est aussi exactement ce qu'on attend d'une puissance
**normalisée** à plein gaz à mi-régime, donc elle ne tranche pas. Le relevé au rayon, lui, tranche : la
pente est bien celle que je croyais.

**Pourquoi ce n'est pas activé** — et la réponse a révélé un défaut plus profond, voir la section suivante.
`SlopeAssist` est dans le moteur avec la valeur mesurée en commentaire, mais à **0** : l'activer donne un
lancement de **51,9 km/h sur 38,8 m** contre 45,1 sur 32,5 pour GTA, soit +15 % et +19 %. Sans l'apport, le
lancement est à −10,6 % et +7,0 %, donc plus proche.

Ce n'est pas que la mesure soit fausse, c'est que le moteur **sur-performe déjà le début du lancement** :
GTA patine son embrayage pendant 1,14 s au départ (voir plus bas), le moteur embraye instantanément. Il
part donc plus fort, et ajouter la poussée de pente par-dessus amplifie l'avance au lieu de combler le
retard. **Les deux doivent être corrigés ensemble** : l'embrayage au départ, puis `SlopeAssist` à 0,537.

### La vraie trouvaille : l'intégration de la roue était instable

En cherchant pourquoi un apport de 9 % de poussée faisait **patiner** la 1ʳᵉ (le régime passait de 0,26 à
0,79 à 13 km/h, la boîte pompait, la distance de lancement tombait de 34,6 à 26,1 m), la cause n'était pas
dans la poussée : l'intégration de la vitesse de rotation de roue tournait **au-delà de sa limite de
stabilité**.

La force du pneu réagit à ω avec la raideur `fmax · r / (KappaPeak · vRef)`. En Euler explicite, la
stabilité demande :

```
h < 2 · KappaPeak · vRef · Iw / (r² · fmax)
```

Au démarrage (`vRef` = `VMin` = 1 m/s, `Iw` = `IwRel`·r²/4 avec `IwRel` = 0,03, soit 1,45 × 10⁻³), cela
donne **h < 3,9 × 10⁻⁴ s**, donc ≈ **43 sous-pas à 60 Hz**. Il y en avait **8**, soit un pas **cinq fois**
au-delà de la limite. La roue s'emballait donc au démarrage, et seul l'écrêtage anti-dépassement le
masquait — or celui-ci est désactivé précisément quand le couple pousse dans le sens du glissement, c'est-à-dire
au démarrage. Le réglage de poussée n'a fait que révéler le défaut.

**Le remède retenu : 16 sous-pas.** Mesuré :

| `SubSteps` | Banc longitudinal | Recul | Lancement | Avec l'apport de pente |
|---|---|---|---|---|
| 8 | 5,32 % | 8,4 mm | 40,2 km/h / 34,6 m | **40,9 / 26,1 — patine** |
| **16** | **5,30 %** | 8,4 mm | 40,2 / 34,5 | 51,9 / 38,8 |
| 32 | 5,35 % | 8,4 mm | 40,3 / 34,7 | 51,9 / 38,8 |
| 64 | 5,36 % | 8,4 mm | 40,2 / 34,7 | 51,9 / 38,9 |

À 16 sous-pas le résultat ne bouge plus (32 et 64 donnent la même chose à 0,1 % près), ce qui est la
signature d'une intégration devenue stable, et le banc longitudinal est inchangé. C'est donc gratuit.

**Ce qui a été essayé et écarté : un pas semi-implicite sur ω** (le même traitement que l'amortisseur de
suspension, `/(1 + h·k/m)`). Il règle l'instabilité plus fondamentalement et rend le résultat indépendant
des sous-pas, mais il fait tomber le banc longitudinal de 5,3 % à **11,6 %** : le calage longitudinal
compensait donc en partie l'instabilité. Un rebalayage des quatre réglages longitudinaux ne récupère que
**6,55 %**, et au prix de valeurs **mesurées** (`EngineBrakeG` de 0,9 à 0,6, calé sur les 115 m de roue
libre). Écarté pour ça : le schéma est plus juste, mais le livrer demanderait de reprendre tout le calage
longitudinal, et c'est un travail à part.

### Et un bug à moi, dans le frottement statique

Le ressort accumulait le glissement avec `dt` au lieu du **pas interne** `h` : sa raideur dépendait donc du
nombre de sous-pas. Le recul de 1 mm annoncé plus haut était un artefact — le ressort était huit fois trop
raide à 8 sous-pas. Corrigé, puis `KStick` recalé au banc (balayage de 200 à 6400) : le recul se divise
exactement par deux quand la raideur double — 8,4 / 4,2 / 2,1 / **1,0** / 0,5 mm — ce qui est la signature
d'un ressort correct, et le banc longitudinal ne bouge pas (5,26 à 5,32 %). À 6400 le comportement devient
erratique. Retenu : `KStick` = 1600, `CStick` = 60, soit **1,0 mm de recul** et 1,2 mm de déformation au
décrochage.

### Et une différence d'embrayage, mesurée mais non corrigée

À l'arrêt, GTA part embrayage à **0,100** et met **1,14 s** à l'engager ; le moteur est à **1,000** dès la
première image. Et GTA transmet du couple pendant ce patinage — il passe de 0 à 24 km/h avec l'embrayage
entre 0,1 et 1,0 — alors que le moteur annule les gaz tant que l'embrayage patine
(`thr = (S.clutch < 1) and 0 or driveIn`). C'est ce qui donne au moteur un départ plus vif puis un retard.

Non corrigé : la transmission du couple à embrayage patinant est aussi ce qui règle le **passage de rapport**,
où le moteur concorde avec GTA (creux de 1,8 par seconde des deux côtés, mesuré). La changer demanderait de
revérifier tout le banc longitudinal, et c'est un travail à part.

## Les aides arcade, mesurées (2026-11-12)

Sept essais ajoutés à l'enregistreur pour les constantes que personne n'a publiées : contrôle en l'air,
retournement, perte d'adhérence au démarrage, réduction d'adhérence du jeu, frein à main en virage,
surfaces, et coupure de puissance en glisse. Véhicule `m422`, et une **propulsion puissante du jeu de
base** (`banshee`) en comparaison, pour séparer ce qui tient au véhicule de ce qui tient au moteur du jeu.
Mesures complètes : [`essais-arcade.json`](essais-arcade.json).

### Ce que l'enregistreur sait lire en plus

Dix canaux : étagement, frein à main vu par le jeu, échelle de braquage, turbo, gravité propre,
multiplicateurs actifs, état de cabrage, température moteur, santé et caractère moteur de chaque roue,
géométrie et flags de roue. Chaque essai rend aussi un **compte rendu d'instrument** : natives absentes du
build, NaN rejetés par canal, et un drapeau `neutre` qui refuse l'essai si un modificateur est posé.

Trois lectures tombent immédiatement :

| Grandeur | Mesure |
|---|---|
| **Étagement réel** | marche arrière −3,333, puis **3,333 / 1,949 / 1,392 / 1,095 / 0,946 / 0,900** |
| **Essieux moteurs** | les **deux** (`w0pwd` = `w2pwd` = 1), ce qui tranche l'ambiguïté de `fDriveBiasFront` |
| **Gravité propre** | 9,8 — donc pas de multiplicateur tout-terrain sur ce véhicule |

La 2ᵉ à 1,949 corrige l'inférence tirée de la poussée à plat (2,03, soit +4 %).

**Aucune ressource du serveur ne modifie la physique** : pas un appel à `SetVehicleCheatPowerIncrease`,
`SetVehicleReduceGrip`, `SetEntityMaxSpeed`, `ModifyVehicleTopSpeed` ni `SetVehicleHandling*` dans
l'ensemble des ressources, et les canaux le confirment en jeu (`powInc` 1,0, `topMod` −1,0, santé moteur
1000 à chaque essai). Le piège 5 du rapport ne s'applique donc pas ici.

### Réduction d'adhérence : l'effet de chaque palier

Un cercle à consigne et vitesse tenues, répété pour chaque réglage. C'est la constante la plus neuve.

| Réglage | Latéral tenu | Part de la référence |
|---|---|---|
| référence | 1,339 g | 100 % |
| `SetVehicleReduceGrip(true)` | 0,141 g | **11 %** |
| palier 0 | 0,150 g | 11 % |
| palier 1 | 0,469 g | 35 % |
| palier 2 | 0,567 g | 42 % |
| palier 3 | 0,981 g | **73 %** |

Le mode binaire se comporte donc comme le **palier 0**, et les paliers vont du plus sévère (0) au plus
doux (3). Réserve : une passe par cas, et le véhicule glisse beaucoup aux paliers bas (dérive de caisse de
17 à 41 °), donc le plateau n'est pas un régime établi franc. L'ordre et les ordres de grandeur sont sûrs,
les valeurs à ±10 %.

### Contrôle en l'air et auto-redressement

Le vol se fait sur un **tremplin posé** (`prop_mp_ramp_02`), approché à 70 km/h : environ une seconde de
vol libre, mesurée sur les images où les quatre compressions de suspension sont nulles. L'entrée n'est
appliquée que pendant ce vol. Trois passes par cas.

| Axe | +1 | −1 | sans entrée | **Couple par unité de consigne** |
|---|---|---|---|---|
| **roulis** | +77,1 °/s² | −79,6 °/s² | +0,4 °/s² | **78,4 °/s², soit 1,37 rad/s²** |
| tangage | +91,7 °/s² | +46,6 °/s² | +1,8 °/s² | non séparable |

Le **roulis est net** : symétrique, biais nul, écart-type de 2 à 4 °/s² sur trois passes. Le **tangage ne
l'est pas** : l'accélération sort positive dans les deux sens, parce que le tremplin imprime lui-même une
rotation de tangage qui domine et diffère d'une passe à l'autre. L'entrée agit bien — l'assiette finale
passe de +25,4 ° à −33,9 ° selon son signe — mais son gain n'est pas isolé par cet essai.

**Il n'y a pas de couple d'auto-redressement en vol.** Sans entrée, les accélérations angulaires valent
+1,8 et +0,4 °/s² : le véhicule **conserve** sa rotation. Un essai antérieur, où il partait à plat et sans
rotation, le confirme en négatif — sa vitesse angulaire est restée exactement nulle pendant toute la chute.
Ce que les mods appellent « auto-correction en vol » n'est donc pas un couple de redressement continu.

### Retournement

Véhicule posé sur le toit ou sur le côté, puis gauche, droite, ou rien.

| Cas | Se redresse en | Vitesse de roulis max |
|---|---|---|
| sur le toit, **sans entrée** | **2,25 s** | 64,3 °/s |
| sur le toit, gauche | 1,95 s | 92,0 °/s |
| sur le toit, droite | 4,26 s | 77,5 °/s |
| sur le côté (les trois cas) | 0,41 s | 168,5 °/s |

**GTA redresse le véhicule tout seul**, sans aucune entrée, en 2,25 s depuis le toit. L'entrée ne fait
qu'accélérer ou ralentir le mouvement, et de façon **asymétrique** (1,95 s contre 4,26). Sur le côté, le
véhicule retombe de lui-même en 0,41 s quelle que soit l'entrée : c'est de la gravité, pas une aide.

### Perte d'adhérence au démarrage : c'est le véhicule, pas une aide

Plein gaz et frein à l'arrêt avec braquage alterné, puis départ arrêté.

| | Lacet gaz+frein | Départ 4 s | **Glissement de roue max** |
|---|---|---|---|
| `m422` (4 roues motrices) | 7,1 °/s | 67,9 km/h sur 45,4 m | **0,079** |
| `banshee` (propulsion) | 5,3 °/s | 88,4 km/h sur 57,2 m | **1,19 à 1,82** |

La propulsion patine de 119 à 182 %, le quatre roues motrices de 7,9 %. La perte d'adhérence au démarrage
est donc **une propriété du véhicule**, pas une aide globale du jeu. Et le « magic movement » de burnout
n'apparaît sur aucun des deux : gaz et frein ensemble ne donnent que 5 à 7 °/s de lacet et moins de 20 cm
de déplacement. L'état de cabrage reste à **0** dans tous les cas, et non à 1 comme l'annonce le rapport
pour « pas de cabrage ».

### Frein à main en virage

Braquage à 0,5 posé, puis frein à main une seconde.

| Vitesse | Phase | Braquage | Lacet | Dérive | Glissement arrière |
|---|---|---|---|---|---|
| 40 km/h | avant | 7,52 ° | 25,0 °/s | 1,36 ° | +0,001 |
| | **pendant** | **4,64 °** | 32,4 °/s | 4,84 ° | **−0,688** |
| | après | 11,37 ° | 29,7 °/s | 3,19 ° | +0,006 |
| 70 km/h | avant | 3,98 ° | 21,9 °/s | 0,65 ° | +0,002 |
| | **pendant** | 3,97 ° | 39,1 °/s | 10,03 ° | **−0,633** |
| | après | 5,63 ° | 28,5 °/s | 3,95 ° | +0,007 |

Trois choses. Le **fondu de braquage n'est pas relâché** : à 40 km/h l'angle de roue *baisse* même
(7,52 → 4,64 °), ce qui est la réduction en glisse déjà mesurée, puisque la dérive y monte à 4,84 ° ; à
70 km/h il ne bouge pas. Les roues arrière **ne se bloquent pas complètement** (−0,69 et −0,63, pas −1,0).
Et le canal `hbOn` passe bien à 1, ce qui prouve que la consigne injectée est prise par le jeu.

### Surfaces : −14 % de vitesse de pointe, et pas d'écrêtage à 130

Avec la `banshee`, cinq passes de chaque côté.

| Surface | Vitesse de pointe |
|---|---|
| bitume (matériau 1) | 146,8 / 146,9 / 147,3 / 147,6 / 148,2 → **147,4 km/h** |
| sable (matériau 21) | 126,1 / 126,5 / 132,4 / 132,4 → **126 à 132 km/h** |

Le sable coûte donc **14 %** de vitesse de pointe. **Il n'y a pas d'écrêtage dur à 130 km/h** : deux passes
le dépassent. La décélération en roue libre ne sépare pas proprement la traînée de surface d'un plafond,
les deux sites n'étant pas assez homogènes sur la distance de roue libre (0,19 à 0,45 g sur sable, 0,22 à
0,31 sur bitume).

### Deux questions tranchées, une qui reste

**L'écart d'embrayage est un artefact d'échantillon.** Le rapport notait 0,1 dans le code du jeu contre
~0,29 dans la télémétrie. Sur **283 traces**, le minimum de `GetVehicleClutch` vaut exactement **0,1000**,
observé sur 5033 images. La native descend donc bien à la valeur du code ; le 0,29 venait d'un essai où
l'embrayage n'est jamais descendu plus bas.

**La coupure de puissance en glisse n'est ni prouvée ni réfutée.** En ligne droite à plein gaz la puissance
de roue vaut 0,32 à 0,34 pour un régime de 0,86 ; en glisse tenue (dérive 27 à 29 °) elle vaut 0,52 à 0,53
pour un régime de 0,46 à 0,48. La puissance est donc **plus élevée** en glisse, ce qui contredit la coupure
— mais le régime et le rapport diffèrent entre les deux phases, donc la comparaison n'est pas valide. Pour
trancher il faudrait tenir le **même rapport et le même régime** des deux côtés, ce que cet essai ne force
pas encore.

### Fiabilité des constantes

| Constante | Valeur | Fiabilité |
|---|---|---|
| Étagement | 3,333 / 1,949 / 1,392 / 1,095 / 0,946 / 0,900 | **sûre** — lue directement, une fois |
| Couple de roulis en l'air | 1,37 rad/s² par unité de consigne | **sûre** — 3 passes, symétrique, σ 2 à 4 °/s² |
| Auto-redressement en vol | nul | **sûre** — deux essais indépendants |
| Redressement depuis le toit | 2,25 s sans entrée | **sûre** sur le principe, 1 passe par cas |
| Paliers de réduction d'adhérence | 11 / 11 / 35 / 42 / 73 % | **ordre sûr, valeurs à ±10 %** — 1 passe, régime pas franc |
| Glissement au démarrage | 0,08 (4×4) contre 1,2 à 1,8 (propulsion) | **sûre** — 3 passes chacun |
| Vitesse de pointe sur sable | −14 % | **sûre** — 5 passes bitume, 4 sable |
| Couple de tangage en l'air | — | **non obtenue** — le tremplin imprime sa propre rotation |
| Coupure de puissance en glisse | — | **non tranchée** — régime et rapport non contrôlés |

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

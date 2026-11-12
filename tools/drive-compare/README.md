# Comparateur d'essais de conduite GTA / Roblox

Un seul analyseur, [`analyze.luau`](analyze.luau), calcule les grandeurs d'un essai (accélération
latérale, dérive, rayon, roulis, lacet, tangage sur une marche…) à partir d'une trace image par image.
Il tourne **tel quel** des deux côtés :

- sur les traces FiveM (`calibration/<véhicule>/fivem/*.json`, enregistrées par
  [`tools/fivem-telemetry`](../fivem-telemetry/)), avec [lune](https://github.com/lune-org/lune) ;
- dans Roblox Studio, côté client du conducteur, sur le champ `samples` des essais de
  [`roblox/DriveBench.lua`](../../skills/fivem-vehicle-to-roblox/roblox/DriveBench.lua), qui
  enregistre les **mêmes colonnes** que la télémétrie FiveM (`Bench.Columns`).

Les deux colonnes d'un tableau de comparaison sortent donc du même code : pas d'écart de définition.

## Lancer côté GTA

Depuis la racine du dépôt :

```bash
lune run tools/drive-compare/gta.luau                      # calibration/m422/fivem par défaut
lune run tools/drive-compare/gta.luau calibration/<v>/fivem
```

Affiche, par essai, la moyenne et l'écart-type des passes en JSON. Sortie de référence du m422 :
[`calibration/m422/fivem-analyse.json`](../../calibration/m422/fivem-analyse.json).

## Lancer côté Roblox

Déposer `analyze.luau` dans le dossier de transfert sous le nom `DriveAnalyze.lua` (ModuleScript) avec
`DriveBench.lua`, **avant** de lancer le Play (un Play est une copie de la place : un module ajouté
pendant le Play n'y arrive pas). Puis, côté client :

```lua
local Bench = require(T.DriveBench)
local A = require(T.DriveAnalyze)
local r = Bench.corner(40, 1, 4)
local m = A.run("corner40", Bench.Columns, r.samples)   -- sans stepCut : la piste Roblox est plate
```

Avec `{ axleFront = a, axleRear = b }` (m du centre de gravité aux essieux ; m422 : 1,38 / 1,41), l'analyseur
ajoute les dérives des pneus avant / arrière et le braquage de roue établis (`steadyTyreSlipFront`,
`steadyTyreSlipRear`, `steadyWheelSteer`) ; côté GTA : `lune run tools/drive-compare/gta.luau <dossier> 1.38 1.41`.
Signe : `vLat` est positif vers la droite dans les deux télémétries, donc la vitesse latérale à l'essieu avant
vaut `vLat − a·wz` et à l'arrière `vLat + b·wz`.

Essais reconnus : `corner40`, `corner80`, `stepsteer`, `slalom`, `handbrake`, `curb20`, `curb60`
(tout autre nom est analysé comme une manœuvre sans fenêtre).

## Fenêtres d'analyse : pourquoi on coupe les traces GTA

Les essais FiveM du créneau, du slalom et du virage 80 ont été faits sur le tablier de l'aéroport de
Los Santos. À ≈ 11 m au nord de la ligne de départ, ce tablier porte une **marche d'environ 0,35 m**
(l'altitude de caisse passe de 13,42 à 13,77–13,82 m). Les trajectoires qui tournent à droite la
franchissent en biais :

| Essai | Franchissement | Ce que ça fausse |
|---|---|---|
| Créneau 60 km/h | ≈ 1,93 s après le braquage | roulis max 3,36 ° (en manœuvre seule : **0,86 °**) |
| Slalom 60 km/h | ≈ 8,4 s | roulis max 3,48 ° (en manœuvre seule : **0,68 °**) |
| Virage 80 km/h | ≈ 1,28 s | roulis 2,52 °, dérive 53,9 °, sortie 14,3 km/h (tout ce qui suit 1,28 s) |

Chaque essai a donc une fenêtre `clean` (`A.Windows`) appliquée aux deux traces, et côté GTA
(`{ stepCut = true }`) la trace est aussi coupée au premier écart d'altitude de caisse de plus de
8 mm. Le virage 40 (rayon 6,3 m) reste près du départ et n'est pas touché.

## Définitions

- **Accélération latérale** : `|d(vLat)/dt − wz × vFwd| / 9,81` (différence centrée). Le terme `vFwd × wz`
  seul, utilisé jusqu'au 2026-11-12, n'est l'accélération latérale qu'en régime **établi** : il surévalue
  de 8 à 11 % un essai où la dérive de caisse croît encore (virage 80, slalom). Voir
  `calibration/m422/README.md`, « Correction de l'instrument ».
- **Dérive** : angle de la vitesse de la caisse, `atan(vLat / |vFwd|)`. C'est la dérive **de la caisse**
  à l'origine du véhicule, pas celle des pneus (voir `calibration/m422/README.md`, « Vérification en 3D »).
- **Établi** : moyenne sur la fenêtre `steady` (virage 40 : 2 à 4 s ; créneau : 1,0 à 1,8 s).
- **Rayon** : vitesse moyenne / lacet moyen sur la fenêtre établie.
- **Roulis par g** : roulis établi / accélération latérale établie.
- **Marche** : assiette et altitude de référence prises 0,5 à 1,5 s après la mise en vitesse ; cabrage et
  plongée relatifs à cette assiette ; montée de caisse = altitude moyenne une fois posé sur le dessus
  (assiette revenue à ±0,3 °) ; vitesse perdue = vitesse au contact − vitesse minimale dans les 6 s.

# Banc de conduite longitudinal (hors Roblox)

`VehicleDynamics` est un module pur : aucune `Instance`, aucun service, seulement des
nombres et des `Vector3`. On peut donc le faire tourner **sans Roblox**, lui fournir des
contacts de roue à plat et intégrer la vitesse soi-même. C'est ce que fait ce banc.

Il sert à **vérifier un calage** : il rejoue en quelques secondes les essais en ligne droite
et affiche l'écart avec les mesures prises dans GTA V (voir
[`calibration/m422/README.md`](../../calibration/m422/README.md)).

## Lancer

Il faut [lune](https://github.com/lune-org/lune) (`rokit add lune-org/lune`), depuis la
racine du dépôt :

```bash
lune run tools/roblox-drive-rig/rig.luau report
```

```bash
lune run tools/roblox-drive-rig/rig.luau report 2.1 0.9 1.5 0.03
```

```bash
lune run tools/roblox-drive-rig/rig.luau scan
```

- `report` affiche chaque essai et son écart avec la mesure GTA. Sans argument il utilise les
  réglages par défaut du module ; avec quatre arguments il surcharge `KDrag`, `EngineBrakeG`,
  `FirstGearForce` et `IwRel`.
- `scan` balaie ces quatre réglages et affiche le jeu qui minimise l'écart quadratique moyen.

Le banc écrit `.VehicleDynamics.luau` à côté de lui : une copie du module avec une ligne
d'import en tête, parce que `VehicleDynamics` lit `Vector3` comme une globale et que lune
n'en fournit pas.

## Ce qu'il couvre

| Couvert | Non couvert |
|---|---|
| 0-60, 0-100, plein gaz 4 s | tenue latérale, dérive |
| passages de rapports (vitesse et régime) | roulis |
| vitesse de pointe | bordure |
| freinage 100-0 (distance, temps, décélération) | côte, démarrage en pente |
| roue libre | frein à main (le lacet) |
| marche arrière | tout ce qui dépend du contact réel |

Ce qui n'est pas couvert demande le solveur 3D de Roblox : `roblox/DriveBench.lua` en Studio.

## Fiabilité

Avant de servir à juger un calage, ce banc a été comparé au **banc Roblox réel** de
[`docs/drive-tests.md`](../../docs/drive-tests.md), avec les réglages d'alors : 0-60 en
4,48 s contre 4,5 mesurés, vitesse de pointe 153,1 contre 151,5 km/h, passages à
43,2 / 75,7 / 106,5 contre 43 / 76 / 106 km/h. Il reproduit donc bien le comportement en
ligne droite du moteur tel qu'il tourne dans Roblox.

Les grandeurs qu'il ignore — report de charge au freinage et à l'accélération, appui
aérodynamique réel, adhérence variable du sol — expliquent le reste de l'écart.

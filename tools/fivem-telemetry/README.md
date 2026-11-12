# `vehicle-telemetry` — enregistrer la physique réelle de GTA V

Ressource FiveM qui **conduit un véhicule toute seule** et enregistre son état image par
image, pour disposer de mesures de référence quand on recrée la conduite GTA ailleurs
(ici : le moteur de conduite Roblox du skill `fivem-vehicle-to-roblox`).

Les essais reprennent exactement ceux du banc Roblox
[`roblox/DriveBench.lua`](../../skills/fivem-vehicle-to-roblox/roblox/DriveBench.lua) :
mêmes consignes, mêmes durées, même tenue de ligne. Les deux colonnes de chiffres sont
donc directement comparables.

## Installation

```
server-data/resources/vehicle-telemetry/      <- copier fxmanifest.lua, client.lua, server.lua
```

puis, dans la console du serveur (ou par toute voie qui exécute une commande serveur) :

```
refresh
ensure vehicle-telemetry
```

La ressource n'écrit que dans son propre dossier `out/`. Elle ne modifie rien dans le jeu
ni dans les autres ressources.

## Pilotage : HTTP sur le port du serveur

Le serveur FiveM sert du HTTP sur son propre port, donc toute la campagne se pilote depuis
un terminal — sans rien taper en jeu :

```bash
curl http://127.0.0.1:<port>/vehicle-telemetry/status
curl -X POST http://127.0.0.1:<port>/vehicle-telemetry/run \
     -d '{"test":"accel","label":"accel_1","params":{"seconds":30}}'
curl "http://127.0.0.1:<port>/vehicle-telemetry/result?id=accel_1" > accel_1.json
```

| Route | Rôle |
|---|---|
| `GET /status` | essai en cours, nombre d'échantillons, dernière erreur |
| `GET /tests` | liste des essais |
| `POST /run` | `{test, label, params}` — lance un essai |
| `POST /stop` | interrompt l'essai en cours |
| `GET /results` | résumé de chaque trace enregistrée |
| `GET /result?id=` | la trace complète |
| `POST /probe` | hauteur du sol le long de lignes (sondage rapide) |
| `POST /curbscan` | recherche d'une marche (bordure) |

## Essais

| Essai | Ce qu'il fait | Principaux résultats |
|---|---|---|
| `accel` | plein gaz jusqu'au plateau | `t60`, `t100`, `t150`, `vmax`, `shifts`, `distance` |
| `brake` | monte à 100 km/h puis frein à fond | `time`, `distance`, `decelG`, `maxYaw` |
| `handbrake` | monte à 60 km/h puis frein à main, **sans corriger le volant** | `maxYaw`, `distance` |
| `corner` | vitesse tenue, braquage à fond | `maxRoll`, `maxYawRate`, `maxSlip`, `maxLatG`, `radiusAtMaxYaw` |
| `reverse` | frein maintenu à l'arrêt (= marche arrière dans GTA) | `minSpeed`, `distance` |
| `curb` | bordure prise de face à vitesse tenue | `maxPitch`, `minWheels`, `airborneFrames`, `maxDrop` |
| `hill` | montée, arrêt, frein à main, tout relâché, plein gaz | `creepHandbrake`, `rollbackReleased`, `launchSpeed` |
| `coast` | lancé puis tout relâché | `marks` (temps et distance à chaque palier de vitesse) |
| `stepsteer` | créneau de braquage à vitesse tenue | `maxYawRate`, `tTo90`, `maxRoll` |
| `slalom` | braquage sinusoïdal | `maxRoll`, `maxYawRate`, `maxSlip` |
| `raw` | entrées constantes (diagnostic) | cap parcouru, angle de roue |
| `surfscan` | relevé du sol le long d'une ligne | profil `d, z, matériau, pitch, roll` |

Paramètres communs : `start` (`{x, y, z, h}` : le véhicule est réparé, remis à plat et
arrêté là avant l'essai), `seconds`, `kmh`, `steer`.

## Ce qui est enregistré, à chaque image

Format colonnaire (`meta.columns` + un tableau de nombres par image) pour que la trace
reste légère.

- temps, durée de l'image (donc la cadence réelle) ;
- entrées imposées : gaz, frein, braquage, frein à main ;
- vitesse, vitesse dans le repère du véhicule, position, rotation, vitesses angulaires ;
- `GetVehicleCurrentRpm`, `GetVehicleCurrentGear`, `GetVehicleNextGear`, `GetVehicleClutch`,
  `GetVehicleThrottleOffset`, `GetVehicleSteeringAngle` ;
- par roue : vitesse, compression de suspension, braquage, longueur du vecteur de traction,
  puissance, pression de frein, vitesse de rotation, matériau du sol ;
- nombre de roues au sol, hauteur au-dessus du sol, accélération.

Au début de chaque essai, les valeurs de handling **réellement chargées** sont relevées
(`GetVehicleHandlingFloat / Int / Vector`) : c'est ce qui permet de vérifier qu'elles
correspondent bien à ce que le skill a exporté.

## Points à connaître

- **Ne pas désactiver les contrôles de conduite.** Sur le build testé,
  `DisableControlAction` masque aussi la valeur injectée par `SetControlNormal` : le
  véhicule ne reçoit alors plus rien (mesuré : `GetVehicleThrottleOffset` reste à 0, régime
  0,20, rapport 0). Les autres contrôles (sortie du véhicule, armes, klaxon) sont bien
  désactivés ; la conduite, elle, est simplement réécrite à chaque image.
- **Le braquage a le même sens que le banc Roblox**, mais c'est contre-intuitif à lire :
  sur le control 59, `+1` donne un angle de roue **négatif** et fait **décroître** le cap.
  Comme le cap GTA croît vers la gauche (0 = nord, 90 = ouest), un cap qui décroît est un
  virage **à droite**. Donc `+1` = droite, comme dans Roblox, et il n'y a rien à inverser.
  Se fier à l'angle de roue seul mène à l'erreur inverse — vérifier avec l'essai `raw`.
- **Vérifier la tenue de ligne avant toute campagne.** Avec un signe inversé, le correcteur
  diverge au lieu de converger : la commande sature (±0,40), le véhicule part en grand
  cercle et la vitesse plafonne. Signature nette dans la trace : `str` collé à la butée et
  écart latéral qui grandit. Correct, l'écart se stabilise (mesuré : 1,7 m au pire sur
  300 m, braquage retombé à ~0).
- **`GetVehicleNumberOfWheelsTouchingSurface` et `GetVehicleWheelXrot` n'existent pas** sur
  ce build : le nombre de roues au sol est recalculé à partir du matériau sous chaque roue,
  et la rotation vient de `GetVehicleWheelRotationSpeed`.
- **Le relevé de sol par téléportation n'est fiable que si la collision est chargée.** Sans
  elle, `SetVehicleOnGroundProperly` ne fait rien et le véhicule garde l'assiette imposée :
  on lit alors une pente exactement nulle sur des kilomètres, ce qui est faux.
  `surfscan` attend donc `HasCollisionLoadedAroundEntity` à chaque point — et même ainsi,
  **une ligne droite ne se valide vraiment qu'en la conduisant**.
- Trafic, piétons et niveau de recherche sont neutralisés pendant les essais ; la météo est
  forcée au beau fixe et l'heure à midi.

## Licence et portée

Cette ressource ne contient aucun fichier du jeu ni d'un mod. Elle ne lit que l'état
d'exécution par les natives FiveM. Les traces produites sont des mesures, pas du contenu
Rockstar.

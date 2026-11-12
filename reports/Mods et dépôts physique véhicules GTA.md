# Les mods GTA V dévoilent ses aides cachées

Aucun mod, dépôt ou moteur open source ne fournit de code qu'on puisse porter tel quel pour obtenir la conduite de GTA V. Ces sources ont une autre valeur : elles **prouvent l'existence des aides arcade du jeu et en donnent la structure**, et elles fournissent des briques de stabilité sous licence permissive. Trois sources seulement lisent réellement le jeu. La première est le Manual Transmission d'ikt, dont les patches mémoire commentés désactivent l'aide au contre-braquage, l'ABS, les chutes d'embrayage et la coupure des gaz aux changements de rapport. La deuxième est l'ensemble des notes GTAVHandlingInfo. La troisième est la famille de natives par roue ajoutée par FiveM. Aucune des deux premières n'a de fichier de licence : on y lit des algorithmes, on n'y copie rien. Le code réellement adaptable vient d'ailleurs : ArcadeCarPhysics, carphysics2d, Godot et l'éditeur de handling de 1amZach (MIT), Bullet (zlib). VDrift et SuperTuxKart (GPLv3) ne servent que d'algorithmes. Côté Roblox, A-Chassis (MPL-2.0) est le seul châssis maintenu qui porte des aides, et aucune ressource n'implémente handling.meta. Croisées avec la campagne de mesure `m422` déjà menée dans ce dépôt, ces sources tranchent plusieurs questions. GTA ne corrige pas la consigne de volant, mais réduit l'angle de roue en aval quand l'arrière glisse, ce qui correspond très probablement au bloc que Manual Transmission court-circuite. Il immobilise la voiture en côte, ne la fait pas pivoter au frein à main en ligne droite et ne donne aucun *curb boost* sur une marche de 15 cm. Pour le moteur Luau, trois priorités s'en dégagent : un ancrage d'adhérence statique à hystérésis, un raccord progressif du plafond latéral déjà mesuré, et un mode dérapage par palier d'adhérence (l'équivalent de `SET_VEHICLE_REDUCE_GRIP_LEVEL`) plutôt qu'un multiplicateur de frein à main. Viennent ensuite le contrôle en l'air et le retournement pilotés par l'entrée, à caler. L'enregistreur existe déjà (`tools/fivem-telemetry`, environ 63 canaux à environ 80 images par seconde). Il lui manque une dizaine de canaux et six essais pour mesurer les constantes que personne n'a publiées.

## Trois sources lisent le jeu, et peu de licences permettent de copier

Le catalogue qui suit classe chaque ressource selon trois niveaux de réutilisabilité.

**Code adaptable** désigne les licences permissives. MIT et zlib exigent seulement de conserver la mention de copyright et la licence. Apache-2.0 ajoute la conservation du fichier NOTICE et la mention des modifications.

**Algorithmes seulement** couvre plusieurs cas : la GPL, la licence PolyForm Noncommercial, les licences maison « all rights reserved », et tout dépôt **sans fichier de licence**, qui reste par défaut sous droits réservés. On peut lire ces sources et réimplémenter l'idée avec ses propres mots et son propre code, mais on n'en copie aucune ligne. La MPL-2.0 occupe un cas intermédiaire. Un fichier repris reste sous MPL et sa source doit rester disponible, ce qui impose de l'isoler dans un fichier distinct. Pour un skill générique, il est plus simple de s'en tenir aux idées.

**Documentation** désigne les pages, guides et présentations sans code.

Les licences ci-dessous ont été vérifiées le 2026-11-12 en lisant le fichier LICENSE des branches `master`/`main` quand il existait. « Aucun fichier » signifie qu'aucun `LICENSE`, `LICENSE.md`, `LICENSE.txt` ni `COPYING` n'a été trouvé à la racine.

### Mods GTA V solo : les patches d'ikt valent plus que tous les packs

Sur une vingtaine de mods pertinents, seuls ceux d'ikt exposent le comportement du jeu au niveau de l'instruction. Tous les autres utilisent une poignée de natives publiques, et leur savoir sur la physique est empirique ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp), [natives.json](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json)). Les packs de handling sont de la donnée. Leur intérêt est le consensus qu'ils dégagent sur ce qui est « arcade » dans les valeurs d'origine.

| Ressource | Licence | Réutilisabilité | Ce qu'on en tire |
|---|---|---|---|
| Manual Transmission & Steering Wheel Support, ikt ([GitHub](https://github.com/ikt32/GTAVManualTransmission)) | Aucun fichier | Algorithmes seulement | Les patches commentés du jeu : « Disables countersteer/steering assist », ABS, chutes d'embrayage, gaz coupés aux changements de rapport ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)). Les « magic movements » en l'air et en burnout ([CustomSteering.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp)). Une aide de maintien en côte ([script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)). L'ordre de priorité des aides ([changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md)) |
| GTAVHandlingReplacement, ikt ([GitHub](https://github.com/ikt32/GTAVHandlingReplacement)) | MIT | Code adaptable, mais en C++ mémoire, donc peu utile à Roblox | Prouve que `CHandlingData` est partagé par modèle. Un réglage par véhicule exige donc une copie des paramètres ([README](https://github.com/ikt32/GTAVHandlingReplacement/blob/master/README.md)) |
| Real Time Handling Editor et GTAVHandlingInfo, ikt ([éditeur](https://github.com/ikt32/GTAVHandlingEditor), [infos](https://github.com/ikt32/GTAVHandlingInfo)) | Aucun fichier | Documentation | `notes.json` donne la sémantique de chaque champ : perte d'adhérence basse vitesse « artificielle », ressort latéral de flanc, force de carrossage, déportance ([notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)) |
| InversePower, ikt (solo, fermé) et son portage FiveM par Blumlaut ([portage](https://github.com/Blumlaut/InversePower-FiveM)) | Aucun fichier | Algorithmes seulement | Couple ajouté proportionnellement à l'angle de dérive et à la faible vitesse ([InversePower.lua](https://github.com/Blumlaut/InversePower-FiveM/blob/master/InversePower.lua)) |
| Custom Torque Map, Custom Gear Ratios et TurboFix, ikt (Patreon, fermés) | Fermé | Documentation | Courbe de couple d'origine, rapports, turbo d'origine limité à « +10 % » de couple ([TurboFix](https://github.com/ikt32/scripts-updates/blob/master/5-turbofix-readme.md)) |
| Guide de handling d'ikt et pack « Project Skill Issue » ([guide](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md), [pack](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md)) | Documentation | Documentation | Le delta « réaliste » par rapport au jeu d'origine : moins d'adhérence, moins de dérive, pas de perte basse vitesse, pas de gravité tout-terrain, pas de plafond sur terre |
| Realistic Driving V, Killatomate ([page](https://www.gta5-mods.com/vehicles/realistic-driving-v)) et Drive V, PermissionToLand ([page](https://www.gta5-mods.com/vehicles/drive-v-realistic-driving-car-handling)) | Conditions de gta5-mods (pas une licence libre) | Documentation | Liste des aides retirées : plafond de 130 km/h sur terre, freins automatiques, inertie de lacet « darty » |
| Guide Handling-Tools d'Eddlm ([guide](https://eddlm.github.io/Handling-Tools/guide)) | Documentation | Documentation | Freinage « par roue » d'environ ¼ de l'adhérence, pivot autour du centre de gravité en l'air et du centre de roulis au sol, déportance |
| TheNewHandlingProject, Eddlm ([GitHub](https://github.com/Eddlm/TheNewHandlingProject)) | Aucun fichier | Ne pas copier les données | Exemple de pack livré comme ressource FiveM de données |
| Autosport Racing System, Eddlm ([GitHub](https://github.com/Eddlm/autosport-racing-system-gta)) | PolyForm Noncommercial | Algorithmes seulement | Second lecteur des mêmes offsets mémoire que Manual Transmission |
| Drift on Demand, Drift Assist, Drift V, Brake To Drift, Traction Control System ([Drift on Demand](https://www.gta5-mods.com/scripts/drift-on-demand), [Drift V](https://www.nexusmods.com/gta5enhanced/mods/1868), [TCS](https://uk.gta5-mods.com/scripts/traction-control-system)) | Fermés | Documentation | Le dérapage par impulsions de `SET_VEHICLE_REDUCE_GRIP`, le couple ajouté en glisse, le contre-braquage et la stabilisation de lacet scriptés |
| Mid-Air AutoCorrection disabler, ARAC, No Car Rolling ([disabler](https://www.gta5-mods.com/scripts/mid-air-autocorrection-aftertouch-control-disabler), [ARAC](https://gta5mod.net/gta-5-mods/scripts/arac-anti-rollover-and-air-control-1-0-1/)) | Fermés | Documentation | Preuve de l'autoredressement en l'air et du retournement quand le véhicule est sur le toit |
| True Realistic Driving V (RealisticMass) ([page](https://www.gta5-mods.com/scripts/true-realistic-driving-v-realistic-mass-v0-1-beta)) | Fermé | Documentation | Revendique que « GTA V doesn't take vehicle mass into account », une affirmation contestable (voir plus bas) |
| NativeDB d'alloc8or ([natives.json](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json)) | Aucun fichier | Documentation | Sémantique des natives : `REDUCE_GRIP(_LEVEL)`, pneus de drift, `CHEAT_POWER_INCREASE`, forces |

### FiveM : des natives par roue et des scripts de cinq lignes

L'écosystème FiveM est large mais peu profond. Presque tous les modes « dérapage » gratuits se résument à appeler `SetVehicleReduceGrip(vehicle, true)` à chaque image tant que la touche Maj est tenue sous une vitesse plafond. vMenu le fait par exemple ([FunctionsController.cs](https://github.com/TomGrobbe/vMenu/blob/master/vMenu/FunctionsController.cs)), tout comme StockholmCityRP ([drift_mode-client.lua](https://github.com/StockholmCityRP/scrp-scripts/blob/master/client/drift_mode-client.lua)).

La vraie richesse est ailleurs : dans les natives ajoutées par CitizenFX qui lisent l'état de chaque roue ([native-decls](https://github.com/citizenfx/fivem/tree/master/ext/native-decls)), et dans quatre outils qui s'en servent pour la télémétrie.

| Ressource | Licence | Réutilisabilité | Ce qu'on en tire |
|---|---|---|---|
| FiveM-DriftCounter, Blumlaut ([driftcounter_c.lua](https://github.com/Blumlaut/FiveM-DriftCounter/blob/master/driftcounter_c.lua)) | MIT | Code adaptable | Métrique d'angle de dérive prête à l'emploi : cap contre vitesse plane, seuil de 30 km/h, zone morte de 15° |
| kq_throttlecontrol, Kuzkay ([client.lua](https://github.com/Kuzkay/kq_throttlecontrol/blob/main/kq_throttlecontrol/client/client.lua)) | MIT | Code adaptable | Antipatinage par plafond de régime au démarrage |
| handlingeditor, 1amZach ([README](https://github.com/1amZach/handlingeditor/blob/main/README.md)) | MIT | Code adaptable | Conversions entre les unités de handling.meta et celles de la mémoire. Télémétrie en direct : g latéral et longitudinal, chronomètre 0-100 |
| fivem-handling-editor, carmineos ([README](https://github.com/carmineos/fivem-handling-editor/blob/master/README.md)) | MIT | Code adaptable | Champs sans effet ou qui ne se mettent à jour qu'après un déplacement ; bogue de type sur `nInitialDriveGears` |
| Az_wheeldamage, Azerothwav ([client.lua](https://github.com/Azerothwav/Az_wheeldamage/blob/main/client/client.lua)) | Apache-2.0 | Code adaptable | Compression nulle = roue en l'air ; garde contre les NaN sur les offsets |
| Boîte de vitesses streetkings ([gearbox_c.lua](https://github.com/streetkings-fivem/streetkings/blob/main/modules/gearbox/gearbox_c.lua)) | Apache-2.0 | Code adaptable | Boîte manuelle par réécriture du handling, calage moteur |
| RAPTOR, TheStoicBear ([README](https://github.com/TheStoicBear/RAPTOR/blob/main/README.md)) | Aucun fichier | Algorithmes seulement | Formules de glissement pour l'antipatinage, l'ABS (relâchement d'environ 20 Hz, seuil de 0,15) et l'ESP ([tsc.lua](https://github.com/TheStoicBear/RAPTOR/blob/main/tsc.lua), [abs.lua](https://github.com/TheStoicBear/RAPTOR/blob/main/abs.lua), [esp.lua](https://github.com/TheStoicBear/RAPTOR/blob/main/esp.lua)) |
| fivem-motion-telemetry, NischGTM ([client.lua](https://github.com/NischGTM/fivem-motion-telemetry/blob/master/client.lua)) | Aucun fichier | Algorithmes seulement | Export des images par WebSocket NUI vers localhost |
| jds-physicsEngine ([telemetry.lua](https://github.com/JustDevelopmentStudio/jds-physicsEngine/blob/main/client/telemetry.lua)) | Aucun fichier | Algorithmes seulement | g latéral et longitudinal par différence de vitesse sur le pas de temps, projetée sur les vecteurs avant et droite |
| cortex-lib `vehicleReplay`, IEver3st ([client.lua](https://github.com/IEver3st/cortex-lib/blob/main/imports/vehicleReplay/client.lua)) | « Free Use License… All rights reserved » | Algorithmes seulement | Détection des natives par leur nom selon le build, gardes NaN et inf, vitesse angulaire des roues |
| qbx_vehiclefailure, vehiclehandler, FiveM-MilageVehicleFailure, HRSGears, ND_Nitro, renzu_tuners ([qbx](https://github.com/Qbox-project/qbx_vehiclefailure/blob/main/client/main.lua), [vehiclehandler](https://github.com/QuantumMalice/vehiclehandler/blob/main/client.lua), [Muhaddil](https://github.com/Muhaddil/FiveM-MilageVehicleFailure/blob/main/client.lua), [HRSGears](https://github.com/HugoSimoes12345/HRSGears/blob/main/client.lua), [ND_Nitro](https://github.com/ND-Framework/ND_Nitro/blob/main/source/client.lua)) | GPL-3.0 | Algorithmes seulement | Boîte manuelle émulée par `fInitialDriveForce × rapport` et `MaxFlatVel / rapport` ; nitro inversement proportionnel à la vitesse ; coupure des contrôles en l'air |
| coii_torqueworks, renzu_turbo, drift_mode ([coii](https://github.com/coiiq/coii_torqueworks/blob/main/client/transmission.lua), [renzu_turbo](https://github.com/renzuzu/renzu_turbo/blob/main/client.lua)) | Aucun fichier | Algorithmes seulement | Détection de `SetVehicleGearRatio`, pression de turbo |
| vMenu, Tom Grobbe ([GitHub](https://github.com/TomGrobbe/vMenu)) | Licence maison | Algorithmes seulement | Bascule de dérapage, multiplicateurs de couple et de puissance |
| Fivem_Drift_Surfaces, DriftJohnson ([README](https://github.com/DriftJohnson/Fivem_Drift_Surfaces/blob/master/README.md)) | Non vérifiée | Documentation | Les tables d'adhérence par surface se diffusent côté serveur |
| Discussion « Manual transmission resource », Syntasu ([Cfx.re](https://forum.cfx.re/t/discussion-research-manual-transmission-resource/146444)) | Documentation | Documentation | Régime normalisé de 0 à 1 ; `SetVehicleHighGear` fige la boîte |
| Documentation des natives CitizenFX ([native-decls](https://github.com/citizenfx/fivem/tree/master/ext/native-decls), [natives](https://github.com/citizenfx/natives)) | Documentation | Documentation | Unités et effets de bord (voir la section sur l'enregistreur) |

### Moteurs open source : l'architecture vient d'ArcadeCarPhysics, la friction de Bullet

Hors de GTA, quatre bases de code permissives se partagent tout ce qu'un châssis raycast de type GTA demande. **ArcadeCarPhysics** vise explicitement « games like GTA, Rocket League or Flatout ». Il fournit l'anti-roulis, la déportance, la stabilisation en vol et les minuteries d'adhérence du frein à main ([README](https://github.com/SergeyMakeev/ArcadeCarPhysics)). **Bullet** fournit le cercle d'adhérence en impulsions et la garde contre les contacts rasants ([btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)). **carphysics2d** fournit le modèle bicyclette, le report de charge et l'arrêt à basse vitesse ([Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)). **Godot** reprend Bullet sous MIT ([vehicle_body_3d.cpp](https://raw.githubusercontent.com/godotengine/godot/master/scene/3d/physics/vehicle_body_3d.cpp)).

| Ressource | Licence | Réutilisabilité | Ce qu'on en tire |
|---|---|---|---|
| ArcadeCarPhysics, Sergey Makeev ([ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)) | MIT | Code adaptable | Stabilisation en vol (portée depuis SuperTuxKart), anti-roulis `(travelL − travelR)·k`, déportance selon la vitesse, courbes de braquage selon la vitesse |
| carphysics2d, spacejack, d'après Marco Monster ([Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)) | MIT | Code adaptable | Dérive par essieu, report de charge `hcg/L·m·ax`, arrêt franc sous 0,5 m/s, braquage `1 − v/280` |
| Bullet btRaycastVehicle, Erwin Coumans ([source](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)) | zlib | Code adaptable | Cercle d'adhérence `maximp = Fz·dt·frictionSlip` ; `rollInfluence` ; garde `n·dir ≥ −0,1` ; force de suspension maximale |
| Godot VehicleBody3D ([source](https://raw.githubusercontent.com/godotengine/godot/master/scene/3d/physics/vehicle_body_3d.cpp)) | MIT | Code adaptable | Même algorithme que Bullet, plus lisible |
| PsRealVehicle, Pushkin Studio ([LICENSE](https://raw.githubusercontent.com/PushkinStudio/PsRealVehicle/master/LICENSE)) | MIT | Code adaptable | Simulation pilotée par les forces (non lue en détail) |
| SuperTuxKart btKart ([btKart.cpp](https://raw.githubusercontent.com/supertuxkart/stk-code/master/src/physics/btKart.cpp)) | GPLv3 | Algorithmes seulement | Axe de redressement non normalisé (« not overcompensating… when the kart is not much away from being upright ») ; impulsion vers le bas proportionnelle à la vitesse |
| VDrift ([cartire1.cpp](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartire1.cpp)) | GPLv3 | Algorithmes seulement | Pacejka avec glissement combiné ; plancher `1/max(|v|, 1e-3)` ; table des glissements de pic selon la charge |
| Randomation Vehicle Physics ([README](https://raw.githubusercontent.com/JustInvoke/Randomation-Vehicle-Physics/master/README.md)) | Aucun fichier | Ne pas copier | Châssis semi-réaliste ex-Asset Store |
| Documentation NWH WheelController3D ([FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)) | Produit commercial | Documentation | Ancrage statique à hystérésis, préréglages Pacejka (dont « Arcade »), ABS à 20 Hz |
| Documentation Vehicle Physics Pro, Edy ([misc topics](https://vehiclephysics.com/advanced/misc-topics-explained/)) | Produit commercial | Documentation | Steering Help, Steering Limit, antipatinage, nombre de sous-pas |
| Conférence Rocket League, Jared Cone, GDC 2018 ([slides](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)) | Documentation | Documentation | Pas fixe à 120 Hz, frottement par ratio, « stay upright », forces appliquées à la hauteur du centre de gravité |
| Conférence « Vehicle Feel Masterclass », Matthew Harris (Criterion), GDC 2018 ([slides](https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf)) | Documentation | Documentation | Couches entrée → aides → simulation ; force de maintien de vitesse ; couple de lacet en dérapage ; ABS coupé en dérapage |
| Article de Rem Voorhuis ([Medium](https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa)) | Pas de licence de code | Documentation | Fondu de la force latérale à l'arrêt, quatre techniques de glissement combiné |
| « Fix Your Timestep! », Gaffer On Games ([article](https://gafferongames.com/post/fix_your_timestep/)) | Documentation | Documentation | Boucle à accumulateur |

### Roblox : A-Chassis seul, et aucun modèle handling.meta

Côté Roblox, l'offre ouverte est mince. Aucun projet n'implémente un modèle à la handling.meta. Le modèle de pneu dominant reste le « coup de rabot » `clamp(−vLat·m, ±μN)`, sans pic d'angle de dérive, d'où les voitures qui tiennent parfaitement puis partent en toupie ([In Depth Scripted Car Physics](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)).

| Ressource | Licence | Réutilisabilité | Ce qu'on en tire |
|---|---|---|---|
| A-Chassis 1.7.x ([GitHub](https://github.com/lisphm/A-Chassis), [releases](https://github.com/lisphm/A-Chassis/releases)) | MPL-2.0 | Algorithmes seulement (copie possible si isolée dans un fichier MPL) | Mise à jour verrouillée à 60 Hz, « dt resetter » contre la mort physique, embrayage piloté par l'écart de régime, ESC au G, assistance au contre-braquage, retournement par AlignOrientation, son local |
| « In Depth Scripted Car Physics » (DevForum, 2025) ([fil](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)) | Pas de licence | Algorithmes seulement | Amortisseur semi-implicite `c/(1 + c·dt/m)`, plusieurs rayons par roue (« wheel casting »), propriété réseau explicite |
| Raycast Suspension Wheel Module ([README](https://raw.githubusercontent.com/LeehamsonThe3rd/raycastsuspensionwheel/main/README.md), [fil](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)) | Pas de licence | Algorithmes seulement | Le frottement de pièce cause un glissement lent à l'arrêt ; la suspension n'est pas répliquée aux observateurs |
| Tutoriel « Vehicle Mechanics Using Constraints » ([fil](https://devforum.roblox.com/t/how-to-implement-vehicle-mechanics-using-constraints/3575431)) | Pas de licence | Documentation | Frein à main par blocage des moteurs arrière, contre-exemple de ce que fait GTA |
| NGChassis ([fil](https://devforum.roblox.com/t/introducing-ngchassis-102-open-source-simple-realistic/986580)) | Pas de licence | Documentation | Dérapage « sur rails » contre dérapage réaliste ; traction à 0,01 donne une toupie incontrôlable |
| Server Authority : plongée technique de Roblox et documentation ([deep dive](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565), [techniques](https://create.roblox.com/docs/projects/server-authority/techniques)) | Documentation | Documentation | Seul `BindToSimulation` est rejoué ; resimulation à 6,25× ; dérive de quantification des movers |
| Fils sur le traversement et la cadence d'images ([traversement](https://devforum.roblox.com/t/objects-going-at-fast-speeds-phase-through-other-objects/3667006), [cadence](https://devforum.roblox.com/t/raycast-suspension-chassis-behaving-inconsistently-on-different-frame-rates/2405111)) | Documentation | Documentation | Pas de détection continue des collisions ; accumulateur à pas fixe |
| Son moteur : fil DevForum et devlog NEODRIVE (non Roblox) ([DevForum](https://devforum.roblox.com/t/how-do-i-achieve-this-type-of-engine-sfx-for-my-vehicle/3184012), [NEODRIVE](https://sevencrane.itch.io/neodrive/devlog/1322297/how-to-make-car-sound)) | Documentation | Documentation | Fondu bilinéaire régime × gaz entre échantillons espacés de 1000 tr/min |
| Petits dépôts GitHub de châssis raycast ([roblox-raycast-car](https://raw.githubusercontent.com/shrx74/roblox-raycast-car/main/README.md), [roblox-vehicle-framework](https://raw.githubusercontent.com/HassanJN66/roblox-vehicle-framework/main/README.md)) | Aucune licence affichée | Ne pas copier | Peu mûrs (0 à 2 étoiles), code non lu |

## Seize comportements cachés, et ce que la mesure m422 en confirme

Les mods ne publient aucune constante interne. En revanche, chaque mod qui désactive une aide prouve qu'elle existe, et la manière dont il la désactive en révèle la nature : entrée, force ou état. La campagne `m422`, 36 essais FiveM rejoués dans le banc Roblox, permet de confronter ces affirmations à des traces ([calibration m422](../calibration/m422/README.md)). Le tableau croise les deux. La dernière colonne donne l'état actuel de `VehicleDynamics` ([VehicleDynamics.lua](../skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua)).

| Comportement | Ce que les mods établissent | Ce que m422 a mesuré | État du moteur Luau |
|---|---|---|---|
| Aide au contre-braquage | Un saut conditionnel du jeu, transformé en JMP par Manual Transmission : « Disables countersteer/steering assist » ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)) | Consigne de volant constante à 35°, angle de roue qui tombe de 12,2° à 3,1° pendant que la dérive passe de 0 à 15° ; aucune correction de la consigne | `CounterSteer = 0` ; réduction `SteerSlide` sur la vitesse latérale arrière, calée |
| Contrôle en l'air | Manual Transmission coupe les commandes gauche/droite et haut/bas pour supprimer les « 'magic' movements, such as burnout or in-air acrobatics » ([CustomSteering.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp)) | Non mesuré | `AirPitch` 4, `AirRoll` 3, `AirDamp` 1,5, non calés |
| Autoredressement en vol | « disables the mid-air adjustments (self-righting) the game does… it tries to » ([disabler](https://www.gta5-mods.com/scripts/mid-air-autocorrection-aftertouch-control-disabler)) ; GTACars ne l'attribue qu'au flag `offroad_abilities_x2` ([glossary](https://gtacars.net/gta5/glossary)) | Non mesuré | Absent |
| Retournement sur le toit | ARAC désactive « the ability to roll your car back over if it's upside down » ([ARAC](https://gta5mod.net/gta-5-mods/scripts/arac-anti-rollover-and-air-control-1-0-1/)) ; flags `reduced/improved_righting_force` ([glossary](https://gtacars.net/gta5/glossary)) | Non mesuré | `RightingK` 6, automatique dès que `up.Y < 0,7` |
| Curb boost | Gain attribué à la compression qui fait monter le régime ([Kotaku](https://kotaku.com/gta-onlines-car-exploit-is-still-polarizing-players-1824264759)) ; un script FiveM promet de retirer la « speed gained from bumps » ([vidéo](https://www.youtube.com/watch?v=NMIaNcNNzZY)) | Marche de 0,149 m à 20 et 60 km/h : aucun gain, 0,06 km/h perdus | `CurbBoost = 0` |
| Perte d'adhérence à basse vitesse | « Artificial grip loss at low speeds… Mostly noticeable when accelerating from a stop » ([notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)) | Les traces d'accélération contiennent la vitesse de chaque roue, mais l'ajustement n'a pas été fait | `1/(1 + k·f)`, `LowSpeedFade` 8 m/s, non calé |
| Gravité tout-terrain | « Remove off-road flags, which artificially boosted gravity » ([PSI](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md)) ; ×1,1 et ×1,2 ([glossary](https://gtacars.net/gta5/glossary)) | Non mesuré | `P.g` lu depuis `GravityMs2`, flags non appliqués |
| Plafond sur terre | « removed 130kph speed cap on dirt roads » ([RDV](https://www.gta5-mods.com/vehicles/realistic-driving-v)) ; « increase surface drag instead » ([PSI](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md)) | Non mesuré | Absent |
| ABS | Bit d'ABS dans les flags de roue, patchable ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)) ; « automated brakes have been disabled » ([RDV](https://www.gta5-mods.com/vehicles/realistic-driving-v)) | 100-0 km/h en 20,6 m à 1,81 g, lacet 0,23°/s | `AbsSlip` 0,18, `AbsRelease` 0,35 |
| Dérapage par réduction d'adhérence | `SET_VEHICLE_REDUCE_GRIP` : « Reduces grip significantly » ; `_LEVEL` de 0 à 3 ; pneus de drift et `_SET_DRIFT_SLIP_ANGLE_LIMITS` ([natives.json](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json)) | Non mesuré | Absent |
| Puissance coupée en glisse | Affirmation d'InversePower : « GTA V cuts off power when your car starts gliding » ([README](https://github.com/Blumlaut/InversePower-FiveM/blob/master/README.md)) | Non isolé | Absent (à juste titre) |
| Maintien à l'arrêt en côte | Manual Transmission ajoute une « hill gravity » : la voiture ne recule pas seule ([script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)) | Recul nul à 16,5 % ; démarrage en côte honnête (environ 0,16 g de pente perdus) | `hold` = frein 0,5 sous 0,6 m/s ; recul de 6,7 cm |
| Décélération gaz relâchés | « Reduce excessive off-throttle slowing » ([PSI](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md)) ; `FREEWHEEL_NO_GAS` ([handling-guide](https://github.com/ikt32/scripts-updates/blob/master/handling-guide.md)) | 110 → 30 km/h en 115 m, environ 0,38 g | `EngineBrakeG` 0,9 au rupteur, calé |
| Frein à main | « allowing handbrake boosting » pour la sous-classe Tuners ([glossary](https://gtacars.net/gta5/glossary)) | À 60 km/h volant droit : lacet 0,13°/s, arrêt en 20 m à 0,71 g | `HandbrakeGripRear` 1,0, calé en ligne droite |
| Rotation liée à la poussée | Le flag `block_increased_rot_velocity_with_drive_force` implique que le jeu ajoute de la vitesse de lacet avec la force motrice ([glossary](https://gtacars.net/gta5/glossary)) | En régime établi, lacet purement cinématique (`v·δ/2,811 m` à 3,9 % près) | Absent |
| Boîte automatique | Chutes d'embrayage au bas régime et au rupteur, gaz levés pendant le passage ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)) | Passage de 0,496 s, gaz à 0, montée à 0,805 en 1ʳᵉ puis environ 0,95 | Calé |

### La « countersteer assist » de GTA agit sur la roue, pas sur le volant

Les deux sources se rejoignent ici, et c'est la découverte la plus utile du croisement. Manual Transmission prouve qu'il existe dans le code un bloc d'aide au braquage, qu'il saute inconditionnellement. Le motif d'octets est attribué à InfamousSabre ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)). La campagne `m422` a établi que la commande ne baisse pas quand l'arrière décroche, mais que **l'angle de roue, lui, s'effondre** ([calibration m422](../calibration/m422/README.md)).

Les deux faits sont compatibles si l'aide du jeu calcule l'angle de roue par rapport à la direction de la vitesse, et non par rapport à la caisse. C'est d'ailleurs exactement la structure de la direction de remplacement qu'ikt a écrite après avoir patché celle du jeu : `steer = travelDir + input·finalReduction·maxSteer`, où `travelDir` est l'angle de la vitesse dans le repère du véhicule ([CustomSteering.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp)). Cette correspondance est une inférence. Elle a toutefois un intérêt pratique immédiat : elle fournit un modèle **structurel** à opposer à la loi empirique `SteerSlide` sur les 27 traces déjà enregistrées, sans nouvelle mesure. L'amélioration n° 3 la détaille.

Le mod Drift V, qui ajoute un « automatic countersteering » scripté ([Nexus](https://www.nexusmods.com/gta5enhanced/mods/1868)), ne contredit rien : il vise un dérapage plus assisté que le jeu d'origine.

### Le frein à main, la côte et la bordure : les mesures démentent les recettes arcade

Trois recettes répandues dans les moteurs arcade seraient fausses pour GTA.

**Le frein à main.** ArcadeCarPhysics divise l'adhérence latérale par cent pendant 2,2 s au frein à main (`handBrakeSlipperyK = 0.01`) ([ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)). carphysics2d réduit l'adhérence arrière par `lockGrip` ([Car.js](https://raw.githubusercontent.com/spacejack/carphysics2d/master/public/js/Car.js)). Or GTA, frein à main serré à 60 km/h volant droit, reste droit à 0,13°/s de lacet ([calibration m422](../calibration/m422/README.md)). Le tête-à-queue au frein à main de GTA doit donc naître du **cercle d'adhérence** : une roue arrière bloquée consomme son adhérence en longitudinal et n'a presque plus de force latérale. Il ne naît pas d'un multiplicateur.

**La côte.** Une adhérence honnête fait reculer la voiture. GTA, lui, la tient immobile, et Manual Transmission doit ajouter une force pour simuler la gravité en côte au point mort ([script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)). Le maintien est donc une aide du jeu, et le recul de 6,7 cm du moteur Roblox est un défaut à corriger.

**La bordure.** La légende du *curb boost* ne se vérifie pas sur une marche franche : GTA avale 15 cm sans gain de vitesse ([calibration m422](../calibration/m422/README.md)). Ce gain dépendait de la cadence d'images sur l'ancienne version PC ([Kotaku](https://kotaku.com/gta-onlines-car-exploit-is-still-polarizing-players-1824264759)), et le désactiver par défaut est le bon choix.

### Deux affirmations de moddeurs à ne pas reprendre

InversePower, Drift Assist et Drift V ajoutent tous du couple proportionnellement à l'angle de dérive. Ils partent de l'idée que le jeu coupe la puissance en glisse ([README InversePower-FiveM](https://github.com/Blumlaut/InversePower-FiveM/blob/master/README.md)). Aucune source ne le prouve. La saturation du cercle d'adhérence suffit à expliquer une perte de poussée en glisse. Un port qui vise la sensation d'origine ne doit donc **pas** activer ce couple par défaut.

De même, RealisticMass affirme que le jeu ignore la masse ([page](https://www.gta5-mods.com/scripts/true-realistic-driving-v-realistic-mass-v0-1-beta)). C'est la lecture déformée d'un fait établi. Adhérence, freinage et poussée sont exprimés en g, donc par unité de masse, et `fMass` ne sert qu'aux collisions ([glossary](https://gtacars.net/gta5/glossary), [Handling-Tools](https://eddlm.github.io/Handling-Tools/guide)). Le moteur Luau, qui calcule en forces spécifiques, est déjà aligné sur ce modèle.

## Douze améliorations du moteur Luau, de la plus rentable à la plus spéculative

Le moteur actuel intègre déjà beaucoup de mesures : traînée, freinage, boîte, loi de braquage en deux étages, retard de direction, plafond latéral `LatVCap`, roulis par centre de roulis ([VehicleDynamics.lua](../skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua)). Les propositions qui suivent partent donc de cet état, pas d'une feuille blanche. Elles sont classées par rapport entre gain de fidélité et coût, et chacune indique sa source et la licence de cette source. Le pseudo-code reprend les noms du module : `T` pour les réglages, `P` pour les paramètres, `S` pour l'état, `w` pour une roue et `h` pour le sous-pas. **C'est un squelette de conception, pas du code testé.**

| Rang | Amélioration | Défaut corrigé | Source (licence) | Mesure nécessaire |
|---|---|---|---|---|
| 1 | Ancrage d'adhérence statique à hystérésis | Recul de 6,7 cm en côte, tremblement à l'arrêt | NWH (documentation) | Aucune : cible m422 déjà connue |
| 2 | Raccord progressif de `LatVCap`, et cercle d'adhérence sans sensibilité à la charge | Résidu de +10 à +14 % vers 38-48 km/h | m422 ; Voorhuis (documentation) ; Bullet (zlib) | Rebalayage de `PeakFactor` |
| 3 | Modèle « angle relatif à la vitesse » opposé à `SteerSlide` | Loi de glisse empirique | Manual Transmission (algorithme seulement) | Aucune : 27 traces existantes |
| 4 | Mode dérapage par palier d'adhérence (`GripLevel`), aide de maintien optionnelle | Pas de dérapage contrôlable | Natives GTA (documentation) ; InversePower (algorithme seulement) ; Criterion (documentation) | Essai `reducegrip` |
| 5 | Frein à main par cercle d'adhérence, ABS coupé sous frein à main | Comportement en virage non mesuré | m422 ; Criterion (documentation) | Essai `handbrake_corner` |
| 6 | Perte d'adhérence basse vitesse calée sur les traces | `LowSpeedFade` deviné | GTAVHandlingInfo (documentation) | Aucune : traces `accel` existantes |
| 7 | Garde Bullet, spherecast balayé, remise à zéro de dt, sous-pas | Rebonds à basse cadence, contacts rasants | Bullet (zlib) ; A-Chassis (MPL, idée) ; VPP (documentation) | Banc à 20 et 30 i/s |
| 8 | Contrôle en l'air avec lacet conservé, autoredressement à axe non normalisé | Le lacet est amorti en vol ; pas d'autoredressement | ArcadeCarPhysics (MIT) ; SuperTuxKart (algorithme seulement) | Essai `airtime` |
| 9 | Retournement piloté par l'entrée gauche/droite | Redressement automatique, y compris dans un talus | ARAC, disabler (documentation) | Essai `flip` |
| 10 | Anti-tonneau sans force fictive | Garde-fou | Bullet `rollInfluence` (zlib) ; Rocket League (documentation) | Aucune |
| 11 | Gravité tout-terrain et traînée de surface | Flags ignorés | PSI, GTACars (documentation) | Essai `offroad` |
| 12 | Son moteur par fondu bilinéaire régime × gaz, local au client | Son sommaire | NEODRIVE (documentation) ; A-Chassis (idée) | Échantillons audio |

### 1. Un ancrage statique remplace le frein fictif et le rabot latéral

Aujourd'hui, le moteur tient la voiture à l'arrêt par un frein fictif de 0,5 sous 0,6 m/s (`hold`). Il borne aussi la force latérale à la vitesse latérale à annuler (`kill`). C'est la stratégie des tutoriels Roblox, et elle laisse un glissement lent. La documentation NWH décrit une solution plus robuste.

Sous **0,4 m/s**, chaque roue passe d'un frottement fondé sur le glissement à un **ancrage ressort-amortisseur** critique. On en sort à **0,4 × 1,5 = 0,6 m/s**, une hystérésis qui « Prevents mode flapping ». La rupture a lieu quand la force dépasse **1,15 fois l'adhérence de pic**, avec un délai de 10 ms avant de pouvoir rentrer et une relaxation de l'ancre de 0,02. Une compensation de pente permet de se garer en côte ([NWH FrictionPreset](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)).

La cible est déjà mesurée : recul nul à 16,5 % moteur tournant, démarrage en côte sans tricherie ([calibration m422](../calibration/m422/README.md)). La seule licence en jeu est celle d'une documentation : on réimplémente l'idée, on ne copie rien.

```lua
-- Par roue, dans la boucle des sous-pas. w.ax, w.ay : déplacement de l'ancre (m, repère roue).
-- Les vitesses sont celles du contact, la vitesse périphérique de la roue étant retranchée en longitudinal.
local ENTER, EXIT, BREAK, RELAX = 0.4, 0.6, 1.15, 0.02           -- NWH
local sx = vLong - omega * w.radius                              -- glissement longitudinal (m/s)
local vs = math.sqrt(sx * sx + vLat * vLat)
if not w.static and vs < ENTER and driveIn < 0.05 and S.time >= (w.cool or 0) then
	w.static, w.ax, w.ay = true, 0, 0
end
if w.static then
	w.ax = (w.ax + sx * h) * (1 - RELAX); w.ay = (w.ay + vLat * h) * (1 - RELAX)
	local k = T.AnchorK                                         -- (m/s²)/m, spécifique ; c critique
	local c = 2 * math.sqrt(k)
	Fx = -(k * w.ax + c * sx) * w.massFrac                      -- force spécifique, comme le reste du module
	Fy = -(k * w.ay + c * vLat) * w.massFrac
	if math.sqrt(Fx * Fx + Fy * Fy) > BREAK * fmax or vs > EXIT or driveIn >= 0.05 then
		w.static, w.cool = false, S.time + 0.01                 -- retour au modèle de pneu
	end
	-- la roue est tenue : pas d'intégration de omega, omega = vLong / r
end
```

Cette version supprime `hold`, qui faisait aussi freiner la voiture dans les manœuvres lentes. Elle rend `kill` superflu à l'arrêt, mais `kill` reste utile en roulant comme garde contre le dépassement. La raideur `AnchorK` se règle pour que le débattement statique en côte reste sous un centimètre, soit `g·sin θ / k < 0,01 m` : `k > 160 (m/s²)/m` à 16,5 %.

### 2. La courbe et le cercle d'adhérence : raccorder le plafond, ne pas ajouter de sensibilité à la charge

La campagne `m422` a montré deux choses. La forme de la montée vers le pic n'est pas identifiable : les formes linéaire, sinus, tanh et puissance tiennent dans 0,006 g l'une de l'autre. En revanche, un **plafond latéral proportionnel à la vitesse latérale au contact**, `|Fy| ≤ 1,25·|vLat|·N`, retire 39 % du résidu. Il laisse toutefois **+10 à +14 % vers 38-48 km/h**, « là où le plafond cesse de mordre : la transition est un `min` dur » ([calibration m422](../calibration/m422/README.md)).

Le correctif évident est un minimum lissé, qui reprend l'idée du fondu de Voorhuis (`lateral_slip_factor = min(|vLat|·3 + |steer|/maxSteer, 1)`) ([Voorhuis](https://medium.com/@remvoorhuis/how-to-program-realistic-vehicle-physics-for-realtime-environments-games-part-i-simple-b4c2375dc7fa)).

```lua
-- minimum lissé : tend vers min(a, b) quand n grandit ; n ≈ 3–6 à ajuster sur les cercles m422
local function softMin(a: number, b: number, n: number): number
	return a * b / (a ^ n + b ^ n) ^ (1 / n)
end
if T.LatVCap > 0 then
	local cap = T.LatVCap * math.abs(vLat) * N[i]
	if cap > 1e-6 then Fy = sign(Fy) * softMin(math.abs(Fy), cap, T.LatVCapSharp) else Fy = 0 end
end
```

Ce réglage est couplé à `PeakFactor` : le plafond est inerte à 0,55, et la prédiction est qu'il faudra descendre vers 0,385-0,45 ([calibration m422](../calibration/m422/README.md)). On rebalaye donc les deux ensemble.

Pour le **cercle d'adhérence**, la formulation actuelle est la bonne. Elle normalise le glissement combiné `s = √(sk² + sa²)` et répartit `F·(sk/s, sa/s)`, ce qui revient au facteur d'échelle de Bullet, `maximp/√(x² + y²)` ([btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)). Les pondérations de type MF 5.2 de VDrift (`Gx = √((a² + 1)/((a² + 1) + b²))`) restent une option GPL, à réimplémenter sans copier ([cartire1.cpp](https://raw.githubusercontent.com/VDrift/vdrift/master/src/physics/cartire1.cpp)).

Il ne faut en revanche **pas** importer la sensibilité à la charge de NWH (exposants 0,85 et 0,8) ([NWH](https://nwhcoding.com/WheelController3D/manual/FrictionPreset.html)). En régime établi, la campagne trouve `Ff/Nf = Fr/Nr` égal à l'accélération latérale, quelles que soient les charges, ce qui indique une adhérence **linéaire en charge** dans GTA ([calibration m422](../calibration/m422/README.md)).

Enfin, si l'on veut une forme Pacejka plutôt que la courbe par morceaux, on peut dériver B, C et D des trois champs de handling. On pose `D = μmax`, puis `C = 1 + (2/π)·acos(μmin/μmax)` pour que l'asymptote vaille μmin, puis `B = tan(π/(2C))/αpic` avec E = 0. Cette dérivation est mienne et non publiée. Elle n'apporte rien tant que la forme reste non identifiable.

### 3. Tester sur les traces existantes le modèle de direction d'ikt

La loi en place, `réduction = borne(1 − 0,18·(|vLat + b·lacet| − 1,8), 0,30, 1)`, est calée sur 7 972 images avec une erreur quadratique moyenne de 0,066 ([VehicleDynamics.lua](../skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua)). Elle reste toutefois empirique. Le modèle d'ikt fournit une hypothèse structurelle à confronter aux mêmes traces : l'angle de roue est l'angle de la vitesse plus une part de la consigne, borné à la butée ([CustomSteering.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp)). Ce modèle est lu, pas copié : le dépôt n'a pas de fichier de licence.

```lua
-- Hypothèse H_MT, à ajuster hors ligne sur les traces m422 (skidpad, virage 80, créneau, slalom).
-- beta : angle de la vitesse dans le repère caisse, ramené dans ±π/2 (signe inversé en marche arrière)
local beta = math.atan2(vLatBody, math.max(math.abs(vFwdBody), 0.5))
local cs = math.clamp(beta * T.CsMult, -T.CsLimit, T.CsLimit)        -- CountersteerMult / Limit chez ikt
local red = 1 + (T.SlideRed - 1) * math.clamp(1 - math.abs(cs) / T.CsLimit, 0, 1) -- map(|cs|, 0, limit, red, 1)
local wheelTarget = math.clamp(cs + inp.Steer * lockAfterFade * red, -lockMax, lockMax)
```

Le critère de décision est simple. H_MT gagne si elle atteint une erreur inférieure ou égale à 0,066 avec au plus trois paramètres, et si elle explique les plateaux du virage 80 (12,2° → 3,1°) sans résidu lié à la vitesse.

Au passage, la loi de fondu en vitesse d'ikt, `mult = 0,15 + 0,9^(v − 7,2)` au-delà de 3 m/s ([CustomSteering.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/CustomSteering.cpp)), recoupe la loi mesurée `1/(1 + (v/15)^2,72)` avec plancher à 0,189. Par mon calcul, elle donne 0,90, 0,59 et 0,24 à 10, 15 et 30 m/s, contre 0,75, 0,50 et 0,19 pour la loi mesurée. La forme et le plancher concordent, et ikt laisse plus de braquage à vitesse moyenne. La loi mesurée reste l'autorité. La concordance confirme seulement qu'elle n'est pas un artefact.

### 4. Un dérapage contrôlable par palier d'adhérence, pas par traction à 0,01

Le jeu expose deux mécanismes de dérapage. Le premier est un mode d'adhérence réduite, `SET_VEHICLE_REDUCE_GRIP`, binaire et assez brutal : Eddlm doit l'alterner 10 images actif et 10 images inactif pour le rendre jouable ([Drift on Demand](https://www.gta5-mods.com/scripts/drift-on-demand)). Le second est sa version graduée en paliers de 0 à 3, `SET_VEHICLE_REDUCE_GRIP_LEVEL`, à quoi s'ajoutent des pneus de drift et `_SET_DRIFT_SLIP_ANGLE_LIMITS` ([natives.json](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json)).

Côté Roblox, l'approche répandue (« traction = 0,01 ») donne une toupie incontrôlable, d'où le débat « rails » contre dérapage réaliste ([NGChassis](https://devforum.roblox.com/t/introducing-ngchassis-102-open-source-simple-realistic/986580)). Le bon modèle est donc **une échelle multiplicative de la courbe**, appliquée à `muMax` et à `muMin`, à paliers. Il laisse le pic d'angle de dérive et le plafond latéral faire le reste.

```lua
-- GRIP_LEVEL[0..3] : facteurs à MESURER par l'essai `reducegrip` (cercle à consigne constante, chaque palier).
-- Le mode binaire (REDUCE_GRIP) = palier le plus bas mesuré. Inconnu : avant + arrière ou arrière seul.
local GRIP_LEVEL = { [0] = 1.0, [1] = T.Grip1, [2] = T.Grip2, [3] = T.Grip3 }
local g = GRIP_LEVEL[S.gripLevel or 0]
fmax *= g                                                   -- avant le plafond latéral
```

Pour un dérapage plus « arcade » que l'original, deux aides optionnelles existent, désactivées par défaut. La première est la loi d'InversePower : `angle = acos(vRel.y/vitesse)` en degrés, `speed_mult = (35 − vitesse)/35`, `mult = 1 + adj·((angle/90)·angle_impact + (angle/90)·speed_mult·speed_impact)`. Elle s'applique au couple seulement entre la zone morte (10°, 15° ou 25°) et 80°, gaz supérieurs au frein ([InversePower.lua](https://github.com/Blumlaut/InversePower-FiveM/blob/master/InversePower.lua)). On la lit sans la copier, faute de licence.

La seconde vient de Criterion : une « Maintain Speed Force » paramétrée par un pourcentage et par l'écart à l'angle de dérapage idéal, plus un « Yaw Torque During a Drift » ([Harris](https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf)). Vehicle Physics Pro montre qu'une limite de braquage combinée à une aide au braquage avec `Limit Proportionality` à 0,6 fait **converger seul** vers un dérapage stable, aux gaz ([VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)).

```lua
-- Optionnel, désactivé par défaut (le jeu d'origine n'en a pas la preuve)
if T.SlideTorque > 0 and speed > 1 then
	local ang = math.deg(math.acos(math.clamp(vFwdBody / speed, -1, 1)))
	if ang > T.SlideDeadzone and ang < 80 and driveIn > brakeIn then
		local sm = (35 - speed) / 35                            -- speed en m/s (GetEntitySpeed)
		aDrive *= 1 + T.SlideTorque * ((ang / 90) * T.SlideAngleImpact + (ang / 90) * sm * T.SlideSpeedImpact)
	end
end
```

### 5. Le frein à main : laisser le cercle d'adhérence produire le dérapage

`HandbrakeGripRear = 1,0` est juste en ligne droite. En virage, rien n'est encore mesuré. La physique prévoit qu'une roue arrière bloquée, dont le `sk` sature, ne garde que `F·sa/s` en latéral, d'où la rotation. Le moteur le fait déjà, puisque la descente vers `muMin` est pilotée par la dérive et qu'une roue bloquée « garde son pic ». La recommandation est donc de **ne pas** ajouter de minuterie d'adhérence à la ArcadeCarPhysics ([ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)), et de mesurer un essai `handbrake_corner` : 60 km/h, braquage à 0,5, frein à main pendant 1 s.

Deux détails sont à reprendre des sources. Criterion coupe l'ABS pendant le dérapage et le réactive au redressement ([Harris](https://media.gdcvault.com/gdc2018/presentations/Harris_Matthew_VehicleFeelMasterclass.pdf)) : le moteur exclut déjà l'ABS des roues sous frein à main. Manual Transmission propose « disable steering reduction on handbrake » ([changelog](https://github.com/ikt32/GTAVManualTransmission/blob/master/doc/changelog.md)), et ArcadeCarPhysics élargit le braquage sous frein à main. Il faut vérifier sur la trace `handbrake_corner` si GTA relâche le fondu de braquage frein à main serré. La colonne d'angle de roue par roue le montre directement.

### 6. Caler la perte d'adhérence au démarrage sur les traces déjà enregistrées

La formule `1/(1 + k·f)` avec `f = 1 − v/LowSpeedFade` est une hypothèse, et `LowSpeedFade` = 8 m/s est deviné. Or les traces `accel` de `m422` contiennent, à chaque image, la vitesse de chaque roue et la vitesse du châssis. Le taux de glissement `(ωr − v)/v` des roues motrices en fonction de `v` donne directement la plage et la forme de la perte, sans nouvel essai.

Pour séparer l'effet de la limite d'adhérence ordinaire, un second jeu d'essais `accel` avec `fLowSpeedTractionLossMult = 0`, posé par `SetVehicleHandlingFloat` puis réapparition du véhicule, isole l'aide. La source décrit l'effet comme « artificial » et « mostly noticeable when accelerating from a stop » ([notes.json](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)).

### 7. Stabilité à pas fixe : quatre gardes empruntées à Bullet et A-Chassis

Le moteur tourne à pas fixe avec 8 sous-pas internes. Vehicle Physics Pro situe la bonne plage entre 4 et 8 et prévient qu'au-delà de 20 les oscillations numériques s'amplifient ([VPP](https://vehiclephysics.com/advanced/misc-topics-explained/)) : 8 est donc raisonnable. Les défauts restants viennent des bords.

**Les contacts rasants.** Bullet annule la vitesse de suspension quand `n·dir ≥ −0,1` et borne la force par `m_maxSuspensionForce` ([btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)). C'est du code zlib, adaptable avec attribution.

**Les bordures entre deux pas.** À 200 km/h, une roue parcourt environ 3,3 studs par pas de 60 Hz à l'échelle de 3,571 studs/m (calcul de ma part), et Roblox n'a pas de détection continue des collisions ([DevForum](https://devforum.roblox.com/t/objects-going-at-fast-speeds-phase-through-other-objects/3667006)). Le spherecast doit donc couvrir la course, plus le rayon, plus `|v_vertical|·dt`.

**La mort physique après un à-coup.** A-Chassis a ajouté un « dt resetter to mitigate physics death » et verrouillé sa mise à jour à 60 Hz ([releases](https://github.com/lisphm/A-Chassis/releases)).

**La force restée appliquée.** Une `VectorForce` reste appliquée à chaque sous-pas de 240 Hz jusqu'à la mise à jour suivante du script, d'où les rebonds observés à 30 images par seconde ([DevForum](https://devforum.roblox.com/t/raycast-car-works-at-60fps-but-not-at-30-or-lower/3629871)).

```lua
local cosN = hit.Normal:Dot(up)                                -- Bullet : n·dir avec dir = −up
if cosN < 0.1 then xdot = 0 end                                -- contact rasant : pas d'amortisseur
N = math.min(N, T.SuspMaxG * P.g)                              -- borne de Bullet, en spécifique
local castLen = (P.upper - P.lower) + w.radius + math.abs(vUp) * dt   -- spherecast balayé
if dt > 1 / 20 then                                            -- à-coup : ne pas intégrer un pas géant
	for i in ipairs(P.wheels) do S.omega[i] = contacts[i].vLong / P.wheels[i].radius end
	return zeroOutput
end
```

### 8. En l'air : garder le lacet et redresser selon l'inclinaison

Le code actuel amortit **toute** la vitesse angulaire en vol (`− w·AirDamp`), lacet compris. SuperTuxKart et ArcadeCarPhysics, eux, n'amortissent que le tangage et le roulis, et conservent le lacet ([btKart.cpp](https://raw.githubusercontent.com/supertuxkart/stk-code/master/src/physics/btKart.cpp), [ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)).

Le redressement automatique y utilise un axe **non normalisé**, `up × worldUp`, dont la norme croît avec l'inclinaison. L'effet est fort sur le flanc, mais il ne surcorrige pas près de l'horizontale. GTA possède bien cet autoredressement d'après le disabler, mais GTACars le réserve à `offroad_abilities_x2`. On l'expose donc avec un gain faible par défaut, multiplié par ce flag, en attendant la mesure. Le code d'ArcadeCarPhysics est sous MIT, donc adaptable. Celui de SuperTuxKart est sous GPL, donc on n'en reprend que l'idée.

```lua
if grounded == 0 then
	local pitch = ((inp.Brake or 0) - (inp.Throttle or 0)) * T.AirPitch      -- entrées haut/bas (MT)
	local roll = -(inp.Steer or 0) * T.AirRoll                               -- entrées gauche/droite (MT)
	local wYaw = upBody * upBody:Dot(w)                                      -- lacet conservé
	local level = upBody:Cross(worldUpBody) * T.AirLevelK * (P.offroadX2 and T.AirLevelX2 or 1)
	torque += (Vector3.new(pitch, 0, roll) + level - (w - wYaw) * T.AirDamp) * T.GyrationSq
end
```

ArcadeCarPhysics réduit aussi l'adhérence à 2 % pendant 1 s après l'atterrissage (`afterFlightSlipperyK`) ([ArcadeCar.cs](https://raw.githubusercontent.com/SergeyMakeev/ArcadeCarPhysics/master/Assets/Scripts/ArcadeCar.cs)). Aucune source GTA ne l'atteste : on ne l'ajoute pas.

### 9. Retourner la voiture à la demande du joueur

Le redressement actuel s'enclenche seul dès que `up.Y < 0,7` à moins de 3 m/s, ce qui peut aussi redresser une voiture garée dans un talus. Les mods GTA décrivent autre chose. Le disabler retire la capacité de « rotate your vehicle… while stuck/upside down » en même temps que le contrôle en l'air, ce qui la range parmi les mouvements pilotés par l'entrée ([disabler](https://www.gta5-mods.com/scripts/mid-air-autocorrection-aftertouch-control-disabler)). ARAC la décrit comme « the ability to roll your car back over » ([ARAC](https://gta5mod.net/gta-5-mods/scripts/arac-anti-rollover-and-air-control-1-0-1/)). Le moteur doit donc donner un **couple de roulis commandé par gauche/droite** quand le véhicule est sur le toit ou le flanc et lent, avec une intensité modulée par les flags `reduced/improved_righting_force` ([glossary](https://gtacars.net/gta5/glossary)).

```lua
if up.Y < 0.3 and speed < T.RightingSpeed and grounded < #P.wheels then
	local k = T.FlipK * (P.improvedRighting and 1.5 or P.reducedRighting and 0.5 or 1) -- facteurs à mesurer
	torque += (fwdBody * (inp.Steer or 0) * k - w * T.FlipDamp) * T.GyrationSq
end
```

### 10. Anti-tonneau : le centre de roulis suffit, la contrainte « stay upright » reste en option

Rocket League liste quatre remèdes contre le tonneau : moins de frottement, braquage limité, contrainte « stay upright », et forces appliquées à la hauteur du centre de gravité ([Cone](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)). Bullet fait la même chose avec `rollInfluence`, qui rapproche le point d'application latéral du centre de gravité ([btRaycastVehicle.cpp](https://raw.githubusercontent.com/bulletphysics/bullet3/master/src/BulletDynamics/Vehicle/btRaycastVehicle.cpp)).

Le moteur a déjà l'équivalent fidèle : les forces latérales sont appliquées à la hauteur du centre de roulis (`RollCentreScale`), et c'est ce point d'application qui donne le roulis mesuré d'environ 1°/g ([calibration m422](../calibration/m422/README.md)). On n'ajoute donc **aucune** force anti-tonneau par défaut, puisque GTA laisse les voitures se retourner. Une contrainte de redressement à seuil élevé (par exemple un roulis supérieur à 60° avec les quatre roues en l'air) peut rester une option du jeu hôte.

### 11. Gravité tout-terrain et traînée de surface plutôt qu'un plafond

Les flags `OFFROAD_ABILITIES` et `_X2` multiplient la gravité par 1,1 et 1,2 ([glossary](https://gtacars.net/gta5/glossary)). La compensation de gravité du module rend l'ajout trivial : `P.g = 9,8 × (1,2 si X2, 1,1 si X, 1 sinon)`. C'est l'aide qui fait « coller » les tout-terrain d'origine.

Le plafond de 130 km/h sur terre a un mécanisme inconnu. Project Skill Issue le remplace par davantage de traînée de surface ([PSI](https://github.com/ikt32/scripts-updates/blob/master/5-handling-pack-readme.md)). On ajoute donc une traînée par matériau, `aSurf = −T.SurfDrag[mat]·v`, appliquée seulement aux roues au sol. On ne pose pas de plafond tant que l'essai `offroad` n'a pas tranché.

### 12. Son moteur : fondu bilinéaire régime × gaz, joué localement

La réponse courante du DevForum est un `PlaybackSpeed` borné entre 0,7 et 1,3 selon la vitesse et le rapport ([DevForum](https://devforum.roblox.com/t/how-do-i-achieve-this-type-of-engine-sfx-for-my-vehicle/3184012)). C'est trop sommaire pour un régime GTA qui chute de manière visible pendant les 0,496 s de chaque passage. La technique de NEODRIVE est meilleure. On enregistre des boucles tous les 1000 tr/min en deux couches, gaz ouverts et gaz fermés, puis on les fond bilinéairement. À 4 800 tr/min et 50 % de gaz, les boucles à 5 000 tr/min jouent à 50 % × 80 % = 40 %, et celles à 4 000 tr/min à 10 % ([NEODRIVE](https://sevencrane.itch.io/neodrive/devlog/1322297/how-to-make-car-sound)).

A-Chassis a abandonné son module de son répliqué par le serveur pour des raisons de bande passante ([releases](https://github.com/lisphm/A-Chassis/releases)). Chaque client joue donc le son localement, à partir des attributs `Rpm` et `Throttle` déjà relayés.

```lua
local rpmD = idle + (S.rpm - 0.2) / 0.8 * (maxRpm - idle)       -- régime normalisé GTA -> tr/min affichés
local thr = S.thrSmooth                                          -- gaz lissés ; 0 pendant un passage (mesuré)
for _, L in layers do                                            -- L.rpm = 1000, 2000, ...
	local wR = math.max(0, 1 - math.abs(rpmD - L.rpm) / 1000)    -- poids triangulaire entre couches voisines
	L.on.Volume, L.off.Volume = wR * thr * master, wR * (1 - thr) * master
	L.on.PlaybackSpeed, L.off.PlaybackSpeed = rpmD / L.rpm, rpmD / L.rpm
end
```

Le turbo d'origine n'ajoute que 10 % de couple une fois chargé ([TurboFix](https://github.com/ikt32/scripts-updates/blob/master/5-turbofix-readme.md)). Son sifflement doit suivre la charge du turbo, pas le seul régime.

## Un enregistreur qui existe déjà, auquel il manque dix canaux et six essais

Le dépôt dispose déjà de `tools/fivem-telemetry`. Cette ressource FiveM conduit seule par `SetControlNormal`, enregistre une ligne par image (environ 80 images par seconde mesurées, 11 à 29 ms) au format colonnaire, et se pilote en HTTP sur le port du serveur ([README](../tools/fivem-telemetry/README.md)). Elle couvre déjà l'essentiel de ce que proposent les quatre meilleures ressources publiques. jds-physicsEngine et fivem-motion-telemetry échantillonnent toutes deux à 50 ms ([telemetry.lua](https://github.com/JustDevelopmentStudio/jds-physicsEngine/blob/main/client/telemetry.lua), [client.lua](https://github.com/NischGTM/fivem-motion-telemetry/blob/master/client.lua)), trop grossier pour les transitoires de pneu. La spécification ci-dessous complète donc l'outil existant au lieu d'en écrire un nouveau. Elle sert à caler le moteur sur le serveur FiveM privé de l'utilisateur.

### Fréquence, horodatage et export

La boucle tourne dans un thread `Wait(0)`, donc une fois par image. Elle horodate chaque ligne par `GetGameTimer()` et enregistre `GetFrameTime()`, car Manual Transmission affirme que la physique et les scripts de GTA sont couplés à la cadence d'images ([5-gears-readme](https://github.com/ikt32/scripts-updates/blob/master/5-gears-readme.md)).

Le build testé n'expose aucun convar de limitation de cadence ([calibration m422](../calibration/m422/README.md)). La seule parade est donc d'enregistrer la durée réelle de chaque image et de rejeter les essais où elle dérive.

Pour les sessions longues, le motif WebSocket NUI de fivem-motion-telemetry, qui envoie les images vers localhost, évite de garder la trace en mémoire. On réimplémente ce motif sans copier le code, faute de licence ([README](https://github.com/NischGTM/fivem-motion-telemetry/blob/master/README.md)). Le format colonnaire actuel (`meta.columns` puis un tableau par image) reste le bon pour rejouer les traces hors ligne dans le module Luau pur.

### Les canaux à lire

Le tableau liste les canaux par native, avec le piège d'unité de chacun. La colonne « Présent » indique s'il est déjà lu par `client.lua`.

| Canal | Native | Unité et piège | Présent |
|---|---|---|---|
| Vitesse du châssis | `GET_ENTITY_SPEED` | m/s ; ×3,6 pour des km/h ([doc](https://github.com/citizenfx/natives/blob/master/ENTITY/GetEntitySpeed.md)) | Oui |
| Vitesse dans le repère du véhicule | `GET_ENTITY_SPEED_VECTOR(e, true)` | y vers l'avant, y négatif en marche arrière ([doc](https://github.com/citizenfx/natives/blob/master/ENTITY/GetEntitySpeedVector.md)) ; **x à droite**, et le signe du terme `a·wz` sur l'essieu avant a déjà piégé une analyse ([VehicleDynamics.lua](../skills/fivem-vehicle-to-roblox/roblox/runtime/VehicleDynamics.lua)) | Oui |
| Rotation, vitesse angulaire | `GET_ENTITY_ROTATION`, `GET_ENTITY_ROTATION_VELOCITY` | Degrés ; le cap croît vers la gauche (0 = nord, 90 = ouest) ([README](../tools/fivem-telemetry/README.md)) | Oui |
| Régime | `GET_VEHICLE_CURRENT_RPM` | Normalisé, environ 0,2 au ralenti et 1,0 au rupteur ; la documentation ne donne aucune plage ([Cfx.re](https://forum.cfx.re/t/discussion-research-manual-transmission-resource/146444)) | Oui |
| Rapport, rapport suivant, rapport max | `GET_VEHICLE_CURRENT_GEAR`, `…NEXT_GEAR`, `…HIGH_GEAR` | Entiers ; 0 = marche arrière | Oui |
| **Étagement** | `GET_VEHICLE_GEAR_RATIO(veh, gear)` | Une fois au début de l'essai ; marche arrière négative ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleGearRatio.md)) ; débloque les boîtes de 7 rapports et plus | **Non** |
| Embrayage | `GET_VEHICLE_CLUTCH` | Plage non documentée ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleClutch.md)) ; m422 lit un minimum d'environ 0,29 là où la mémoire impose 0,1 | Oui |
| Gaz effectifs | `GET_VEHICLE_THROTTLE_OFFSET` | −1 à 1 selon le sens de marche ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleThrottleOffset.md)) | Oui |
| **Frein à main** | `GET_VEHICLE_HANDBRAKE` | Booléen ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleHandbrake.md)) ; confirme que l'entrée injectée est prise | **Non** |
| Volant et angle de roue | `GET_VEHICLE_STEERING_ANGLE`, `GET_VEHICLE_WHEEL_STEERING_ANGLE(veh, i)` | Le premier est la **commande**, plus lente que les roues ; le second, 0 = droit ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelSteeringAngle.md)) ; le contrôle 59 à +1 donne un angle négatif et un virage à droite | Oui |
| **Échelle de braquage** | `GET_VEHICLE_STEERING_SCALE` | Sans unité documentée | **Non** |
| Vitesse de roue | `GET_VEHICLE_WHEEL_SPEED(veh, i)` | m/s à la surface du pneu ; la documentation dit à tort « An integer » ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelSpeed.md)) | Oui |
| Vitesse angulaire de roue | `GET_VEHICLE_WHEEL_ROTATION_SPEED(veh, i)` | rad/s ; le rapport vitesse / vitesse angulaire donne le **rayon effectif** ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelRotationSpeed.md)) | Oui |
| Compression | `GET_VEHICLE_WHEEL_SUSPENSION_COMPRESSION` | Positive ; 0 = roue pendante en l'air ; mètres ou normalisée, non documenté ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelSuspensionCompression.md)) | Oui |
| Vecteur de traction | `GET_VEHICLE_WHEEL_TRACTION_VECTOR_LENGTH` | Sans unité ; environ 0,7 en régime établi, 4 à 5 en patinage ([calibration m422](../calibration/m422/README.md)) | Oui |
| Puissance et pression de frein par roue | `GET_VEHICLE_WHEEL_POWER`, `…BRAKE_PRESSURE` | Pression « around 1.0f when braking » ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelBrakePressure.md)) | Oui |
| **Roue motrice** | `GET_VEHICLE_WHEEL_IS_POWERED`, `GET_VEHICLE_WHEEL_FLAGS` | Un bit des flags de roue ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelIsPowered.md)) ; tranche le cas où `fDriveBiasFront` = 1,0 en mémoire signifie traction ou 50/50 ([1amZach](https://github.com/1amZach/handlingeditor/blob/main/README.md)) | **Non** |
| Matériau | `GET_VEHICLE_WHEEL_SURFACE_MATERIAL` | Index dans materials.dat ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelSurfaceMaterial.md)) | Oui |
| **Géométrie de roue** | `GET_VEHICLE_WHEEL_TIRE_COLLIDER_SIZE`, `…RIM_COLLIDER_SIZE`, `GET_VEHICLE_WHEEL_SIZE` | Taille nulle pour les roues d'origine ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelSize.md)) | **Non** |
| **État des roues et du moteur** | `GET_VEHICLE_WHEEL_HEALTH`, `GET_VEHICLE_ENGINE_TEMPERATURE` | Sert à rejeter un essai fait avec une roue abîmée | **Non** |
| **Turbo** | `GET_VEHICLE_TURBO_PRESSURE` | Sans unité ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleTurboPressure.md)) ; mesure la charge et le « +10 % » | **Non** |
| **Gravité propre** | `GET_VEHICLE_GRAVITY_AMOUNT` | Unité non documentée, supposée en m/s² ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/SetVehicleGravityAmount.md)) ; tranche le ×1,1 et le ×1,2 des flags tout-terrain | **Non** |
| **Multiplicateurs actifs** | `GET_VEHICLE_CHEAT_POWER_INCREASE`, `GET_VEHICLE_TOP_SPEED_MODIFIER` | −1,0 si aucun modificateur n'est posé ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleTopSpeedModifier.md)) ; détecte une ressource du serveur qui fausse la mesure | **Non** |
| **Cabrage** | `GET_VEHICLE_WHEELIE_STATE` | 1 = pas de cabrage, 65 = prêt (burnout), 129 = cabrage ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelieState.md)) | **Non** |
| Handling effectif | `GET_VEHICLE_HANDLING_FLOAT/INT/VECTOR` | **Unités mémoire** : radians, ÷3,6, biais ×2, amortissement ÷10, traînée ÷10 000 ([1amZach](https://github.com/1amZach/handlingeditor/blob/main/README.md)) | Oui, au début |

### Six essais à ajouter, chacun pour une constante que personne n'a publiée

Les essais existants (`accel`, `brake`, `handbrake`, `corner`, `curb`, `hill`, `coast`, `stepsteer`, `steerfade`, `skidpad`, `slalom`) couvrent le moteur, la boîte, le pneu en régime établi et la direction ([README](../tools/fivem-telemetry/README.md)). Les aides arcade restent sans mesure.

**`airtime`.** Saut sur un tremplin construit avec la même méthode que `buildstep`. Le vol se fait sans entrée, puis avec tangage seul, puis roulis seul. La pente de la vitesse angulaire en fonction de l'entrée donne `AirPitch` et `AirRoll`. La vitesse angulaire sans entrée donne l'autoredressement `AirLevelK`. On répète avec `strHandlingFlags` incluant `OFFROAD_ABILITIES_X2`, réglé globalement et suivi d'une réapparition, pour vérifier l'affirmation de GTACars.

**`flip`.** Le véhicule est posé sur le toit, puis on applique gauche, droite et rien. On mesure le couple de retournement et son seuil, avec et sans les flags de redressement.

**`burnout`.** Frein et gaz à l'arrêt, braquage alterné. Les mesures sont la vitesse de lacet selon la consigne gauche/droite et `GET_VEHICLE_WHEELIE_STATE`. C'est le « magic movement » de burnout de Manual Transmission.

**`reducegrip`.** Un cercle `skidpad` à consigne et vitesse tenues, répété pour `SetVehicleReduceGrip` à faux puis vrai, et pour `SetVehicleReduceGripLevel` de 0 à 3. Le rapport des accélérations latérales tenues donne directement `GRIP_LEVEL`. Les pneus de drift (`SET_DRIFT_TYRES`, build 2372 et plus) se testent de la même façon.

**`handbrake_corner`.** Frein à main serré une seconde à 60 km/h, braquage à 0,5. On observe l'angle de roue par roue (le fondu de braquage est-il relâché ?), le lacet et `sk` sur les roues arrière.

**`offroad`.** Accélération jusqu'au plateau puis roue libre sur un chemin de terre repéré par `GET_VEHICLE_WHEEL_SURFACE_MATERIAL`, sur une ligne validée en la conduisant. Le plateau et la décélération séparent le plafond de 130 km/h de la traînée de surface.

Un septième essai, `slidepower`, sert à tester l'affirmation d'InversePower. On tient les gaz à fond dans un dérapage stabilisé et on compare `GET_VEHICLE_WHEEL_POWER` et le régime à ceux de la ligne droite au même rapport. Une puissance de roue qui chute sans chute de régime prouverait la coupure.

Pour comparer les deux moteurs en dérapage, la métrique de FiveM-DriftCounter (MIT) s'applique telle quelle aux traces des deux côtés : `cosX = (−sin(rz)·vx + cos(rz)·vy)/|v|`, angle `= deg(acos(cosX))·0,5`, avec un seuil de 30 km/h et une zone morte de 15° ([driftcounter_c.lua](https://github.com/Blumlaut/FiveM-DriftCounter/blob/master/driftcounter_c.lua)).

### Les pièges, par ordre de gravité

**1. Ne jamais désactiver les contrôles de conduite.** C'est le piège le plus coûteux, et il est déjà documenté dans le dépôt. Sur le build testé, `DisableControlAction` masque aussi la valeur injectée par `SetControlNormal`. Il ne faut **pas** imiter Manual Transmission, qui désactive `VehicleMoveLeftRight/UpDown` pour supprimer les mouvements en l'air ([README](../tools/fivem-telemetry/README.md)).

**2. Réapparaître après toute modification du handling.** `SetVehicleHandlingFloat` exige `ModifyVehicleTopSpeed` pour que la force motrice et la vitesse plate prennent effet, et ce dernier modifie la traînée ([doc](https://github.com/citizenfx/natives/blob/master/VEHICLE/ModifyVehicleTopSpeed.md)). Certains champs ne se mettent à jour « after the car moves a bit or is respawned » ([1amZach](https://github.com/1amZach/handlingeditor/blob/main/README.md)). Les flags ne se règlent que globalement ([doc](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/SetVehicleHandlingFloat.md)). Tout essai qui modifie le handling doit donc réapparaître avant d'enregistrer.

**3. Ne pas confondre les deux numérotations de roues.** Les natives CFX vont de 0 à n−1. Certaines natives du jeu utilisent l'énumération fixe des pneus (0 avant gauche, 1 avant droit, 4 arrière gauche, 5 arrière droit) ([GetVehicleWheelSpeed](https://github.com/citizenfx/fivem/blob/master/ext/native-decls/GetVehicleWheelSpeed.md), [natives.json](https://github.com/alloc8or/gta5-nativedb-data/blob/master/natives.json)).

**4. Se protéger des valeurs absurdes.** Il faut rejeter NaN et inf comme le fait cortex-lib, et détecter les natives absentes par leur nom selon le build. `GetVehicleNumberOfWheelsTouchingSurface` et `GetVehicleWheelXrot` manquent sur le build testé ([client.lua cortex-lib](https://github.com/IEver3st/cortex-lib/blob/main/imports/vehicleReplay/client.lua), [README](../tools/fivem-telemetry/README.md)).

**5. Neutraliser les ressources du serveur privé.** Un mode dérapage, une limitation de vitesse ou une ressource de pannes appelle à chaque image `SetVehicleCheatPowerIncrease`, `SetVehicleReduceGrip` ou `SetEntityMaxSpeed`. C'est par exemple le cas de vMenu et de qbx_vehiclefailure ([vMenu](https://github.com/TomGrobbe/vMenu/blob/master/vMenu/FunctionsController.cs), [qbx](https://github.com/Qbox-project/qbx_vehiclefailure/blob/main/client/main.lua)). Le multiplicateur actif et la santé moteur doivent figurer dans chaque trace, et l'essai doit être refusé s'ils diffèrent des valeurs neutres. Les tables d'adhérence par surface peuvent elles aussi avoir été rediffusées par le serveur ([Fivem_Drift_Surfaces](https://github.com/DriftJohnson/Fivem_Drift_Surfaces/blob/master/README.md)).

**6. Noter le build.** Legacy et Enhanced peuvent différer, et `m422` a été mesuré sur Enhanced (FXServer b177) ([calibration m422](../calibration/m422/README.md)).

## Ce qui reste hors d'atteinte

Plusieurs constantes ne sont publiées nulle part et ne peuvent venir que des essais proposés plus haut : le couple de contrôle en l'air, l'autoredressement en vol et son lien réel avec `offroad_abilities_x2`, le couple de retournement, l'effet chiffré de chaque palier de `SET_VEHICLE_REDUCE_GRIP_LEVEL` et du mode binaire, la plage et la forme de la perte d'adhérence au démarrage, et le mécanisme du plafond sur terre. Aucun mod ne les donne, et le disabler, ARAC et No Car Rolling sont fermés ([disabler](https://www.gta5-mods.com/scripts/mid-air-autocorrection-aftertouch-control-disabler)).

Trois affirmations restent non prouvées. La première est la coupure de puissance en glisse d'InversePower ([README](https://github.com/Blumlaut/InversePower-FiveM/blob/master/README.md)). La deuxième est la vitesse de lacet ajoutée selon la poussée, déduite du seul nom d'un flag ([glossary](https://gtacars.net/gta5/glossary)). La troisième est l'identité entre le bloc patché par Manual Transmission et la réduction d'angle de roue mesurée, qui est mon inférence.

Il reste aussi un écart d'instrument : l'embrayage descend à 0,1 selon le code patché, mais à environ 0,29 dans la télémétrie. Il peut venir de l'échantillonnage ou de la sémantique de `GET_VEHICLE_CLUTCH`, qui n'est pas documentée.

Côté sources, plusieurs codes n'ont pas pu être lus : les deux pastebins d'Eddlm et de Realistic Nitro, les scripts payants et chiffrés (Quags Drift, SHA4OW ABS/TCS, kq_realoffroad), le code de roue d'A-Chassis et le système de dérapage communautaire Roblox d'avril 2025. Les fils GTAForums de Realistic Driving V, qui pourraient contenir des mesures, n'ont pas été lus ([fil](https://gtaforums.com/topic/804249-vrel-realistic-driving-v/page/5/)). Aucun moteur open source ne réimplémente handling.meta. Aucune présentation de Rockstar, Playground ou Ghost sur le dérapage n'a été trouvée. Le lignage Burnout n'est couvert que par les diapositives de Harris.

Enfin, deux réserves de licence demeurent. Les dépôts d'ikt les plus utiles (Manual Transmission, GTAVHandlingInfo, GTAVHandlingEditor) n'ont pas de fichier de licence : ce rapport n'en reprend que des algorithmes et des descriptions, et toute copie de code exigerait l'accord de l'auteur. Randomation Vehicle Physics est dans le même cas.

## Conclusion

Le croisement des mods et des mesures renverse la manière de lire l'écosystème. Les mods de « réalisme » ne sont pas d'abord des sources d'algorithmes. Ils servent de **liste de contrôle négative** : chaque aide qu'un moddeur a dû retirer est une aide que le port doit implémenter, comme une couche explicite, désactivable et calée. Le maintien en côte, la décélération forte gaz relâchés, la réduction d'angle de roue en glisse et la gravité tout-terrain appartiennent à cette catégorie. Inversement, les recettes arcade les plus répandues hors de GTA trahiraient le jeu : l'adhérence divisée par cent au frein à main, l'adhérence réduite après l'atterrissage et la sensibilité à la charge. Les mesures `m422` le montrent déjà.

La conséquence pratique est que le travail restant n'est plus de chercher du code. Une moitié des améliorations (ancrage statique, raccord du plafond, modèle de direction d'ikt, perte d'adhérence au démarrage) se règle **sur des traces déjà enregistrées**, sans retourner en jeu. L'autre moitié, qui couvre tout ce qui touche au vol, au retournement et au dérapage assisté, dépend de six essais FiveM ciblés. Ce sont les seules mesures qui manquent encore pour qu'un skill générique reproduise GTA V plutôt qu'une voiture arcade quelconque.

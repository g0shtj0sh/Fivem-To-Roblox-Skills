# Map d'essai véhicules (`roblox/TestGrounds.lua`)

Une map d'essai **permanente**, façon « grid map » : un plateau quadrillé de 750 × 1 150 m où chaque atelier
isole un comportement du moteur de conduite, avec des panneaux qui disent ce qu'on teste et à quelle valeur.
Contrairement à `TestTrack.lua` (piste créée en Play pour les mesures automatiques), elle se construit **en mode
édition** et s'enregistre avec la place : on y conduit à la main comme dans le jeu.

## Construire

Déposer les scripts avec `scripts/studio_stage.py` (le fichier arrive en ModuleScript `TestGrounds` dans le
dossier de transfert), puis en Edit :

```lua
local T = game.ReplicatedStorage.rbxts_include.F2R_Transfer
local Grounds = require(T.TestGrounds:Clone())        -- Clone : en Edit, require garde la première version
local model, info = Grounds.build(workspace)          -- origine auto : 1 000 studs au-delà de tout (+X)
-- reconstruire au même endroit : Grounds.build(workspace, nil, { replace = true })
```

`info.teleport` (et la pièce invisible `TeleportPoint` du hub) donne le départ, cap vers −Z. Il faut un moyen
d'y aller : une commande d'administration qui pose le joueur, ou son véhicule s'il conduit, sur ce point
(`VehicleAccess.PlaceOnGround(car, point.Position, point.CFrame.LookVector)`, après
`player:RequestStreamAroundAsync`).

Environ 1 570 pièces et 2 050 instances, construites en 7 s. Tout est ancré sauf les cônes, les 45 caisses
de l'atelier crash et la planche de la bascule.

## Ateliers

Repère : origine au centre, hub au sud (+Z), voies parcourues vers −Z, ouest = −X. Cotes en mètres.

| Dossier | Contenu |
|---|---|
| `00_Sol` | dalles de 50 m alternées (repères de vitesse et de distance), muret de 0,8 m tout autour |
| `01_Hub` | aire de départ, `TeleportPoint`, panneaux d'orientation en portique |
| `02_Piste` | ligne droite de 1,1 km, repères tous les 100 m jusqu'à 800 m, zone de freinage, bac à sable |
| `03_Surfaces` | 11 bandes de 300 m : asphalte, béton, pavés, herbe, terre, boue, sable, neige, glacier, glace, µ-split |
| `04_Bosses` | dos-d'âne 5 / 7,5 / 10 / 12,5 / 15 cm, plateaux 10 et 15 cm, coussins 7 cm, bandes rugueuses, tôle ondulée, gendarmes 20 et 30 cm, crête de 1 m |
| `05_Marches` | marches de 5 à 30 cm, bordure d'un seul côté, escalier 5 × 15 cm, trottoir en biais 25 cm, plancher à nids-de-poule |
| `06_Articulation` | bosses alternées 15, 30 et 50 cm, rondins Ø 10 / 24 / 50 cm, rondin en biais, marche de 50 cm, chute de 1 m |
| `07_Sauts` | tremplin GTA (14,6 °), tremplins 5 / 10 / 20 / 30 °, saut de 15 m avec réception, table |
| `08_Pentes` | côtes de 10, 20, 30, 45 et 60 % sur 6 m de dénivelé |
| `09_Devers` | dévers de 10, 20, 30 et 40 °, abordés par le bord bas (ouest) |
| `10_Virage` | virage relevé à 30 °, rayon 46 m, raccordements progressifs sur 40 ° d'arc |
| `11_Maniabilite` | skidpad (cercle de 30 m), slalom de 12 cônes à 18 m, évitement ISO 3888-1 |
| `12_Crash` | mur de béton de 3 m, poteau Ø 30 cm, pile de 45 caisses libres |
| `13_ToutTerrain` | champ de 90 bosses, jardin de rochers, rondins en vrac, bascule, pont étroit de 2,6 m |

Les adhérences affichées sont celles de `VehicleDynamics.MaterialGrip` : la bande « Glace » teste la valeur du
moteur, pas celle de GTA.

## Vérifié en Studio (2026-11-12)

PC Studio, un joueur, `m422` converti (sportive basse, 4 roues motrices), runtime `b43934b2dbff`, passages à
vitesse tenue par `DriveBench` (`Bench.curb` / `Bench.air`), en tenant la ligne. Une passe par essai.

| Atelier | Essai | Résultat |
|---|---|---|
| bosses | 30 km/h sur 508 m, de la première bosse à la crête | passé : assiette max 12,7 °, roulis 3,2 °, jamais en l'air |
| marches | 20 km/h | 5, 10, 15, 20 cm passées ; **bloqué à 30 cm** |
| marches | 15 km/h depuis la bordure d'un côté | bordure passée (roulis 6,2 °) ; **bloqué à l'escalier** |
| articulation | 12 km/h | bosses de 15 cm passées ; **bloqué à 30 cm** (bouclier avant) |
| articulation | 10 km/h | rondins Ø 10 cm passés ; **bloqué à Ø 24 cm** |
| sauts | tremplin 20 °, consigne 60 km/h | décollage 51 km/h, 1,27 s de vol |
| sauts | saut avec réception, consigne 90 km/h | décollage 82 km/h, 1,15 s de vol, reçu sur la pente à 77,7 km/h |
| pentes | côte de 30 % à 25 km/h | montée, vitesse tenue |
| tout-terrain | bascule abordée par le bas, 10 km/h | la planche passe de −7,7 à +7,7 °, traversée |
| tout-terrain | pont étroit, 12 km/h | traversé, quatre roues au sol |
| hub | commande de téléportation avec le véhicule | posé à 1,8 stud du point, droit, conducteur assis |

Les blocages sont attendus pour une voiture basse (garde au sol d'environ 12 cm) : les voies techniques sont
graduées pour situer la limite de chaque véhicule.

**Défauts trouvés par ces essais et corrigés dans le générateur** :
- le saut avec réception avait un vide de 25 m, qui demande ≈ 88 km/h **au décollage** (portée
  v²·sin 24° / g) : décollée à 82 km/h, la voiture percutait la face verticale de 3 m de la réception. Vide
  ramené à 15 m (≈ 68 km/h) ;
- la bascule présentait son extrémité **haute** (2,4 m) à l'arrivée : la voiture se coinçait dessous ;
- les dos-d'âne étaient des blocs et non des cylindres (une « crête » de 1 m faisait 65 m de long), vu par
  `place_check` ;
- une série de bosses de 15 cm et des rondins de Ø 10 et 24 cm ont été ajoutés en tête de la voie
  d'articulation, qui commençait à 30 cm.

**Non vérifié** : surfaces, dévers, virage relevé, skidpad, slalom, évitement, piste de 1 km, crash et champ de
bosses n'ont pas été roulés (vus en capture seulement) ; véhicule haut ou tout-terrain ; téléphone ; plusieurs
joueurs. Le virage relevé montre de fines marches entre ses segments de raccordement (coins de 1 °).

# Moteur de conduite v1 : essais de conduite en Play

Essais du 2026-11-11, faits pour de vrai : agent Claude Code dans la VM Linux de VibeStarter, Roblox
Studio ouvert sur le PC Windows de l'utilisateur, piloté par le MCP « Roblox Studio » (`execute_luau`
Server / Client, `start_stop_play`, `player_input`, `performance_check`). Un seul joueur.
Véhicule : mod FiveM `m422` converti par le skill (2 200 kg, 6 rapports, 4 roues motrices
`DriveBiasFront` 0,5, `DriveForce` 0,2, `DriveMaxFlatVelMs` 45, `RedlineTopGearKmh` 180,
`TractionCurveMax/Min` 1,9 / 1,5, `BrakeForce` 0,6, `SuspensionForce` 1,4, amortissements 0,7 / 1,2,
débattement 0,28 m). Runtime `4e9b56ddd88a` puis banc corrigé (voir « Erreurs du banc »).
Rien n'a été enregistré dans la place : piste et copies créées en Play seulement.

> **Mise à jour du 2026-11-12** : le protocole a été relancé après le calage sur les mesures FiveM, avec une
> piste alignée sur la campagne GTA (marche de 0,149 m × 12,2 m au lieu d'une barre de 0,56 m, côte à 16,5 %),
> le créneau et le slalom, et un analyseur commun aux deux colonnes. Résultats, verdicts et limites :
> [`calibration/m422/README.md`, « Vérification en 3D »](../calibration/m422/README.md#vérification-en-3d-studio-2026-11-12).
> Les chiffres ci-dessous sont ceux du 2026-11-11, avant calage, sur l'ancienne piste.

## Protocole

1. Piste : `roblox/TestTrack.lua` (serveur, en Play) construit une plaque de 2048 × 6144 studs
   (≈ 573 × 1 720 m) **au-delà de tout ce que contient Workspace** (origine automatique, côté +X),
   avec 400 studs derrière le départ, une bordure de 0,15 m et une côte à 15 % (depuis le 2026-11-12 : marche
   de 0,149 m sur 12,2 m à 74 m du départ, côte à 16,5 %). Le véhicule est posé par
   `Track.place(car, lane, player)` (→ `VehicleAccess.PlaceOnGround` → `VehicleAccess.Teleport`).
2. Joueur au volant : `VehicleAccess.Enter(player, car, "DriverSeat")` côté serveur.
3. Mesures : `roblox/DriveBench.lua` côté client du conducteur (`VehicleDrive.SetOverride`), lancées
   en `task.spawn` et relevées toutes les ~10 s (un appel `execute_luau` est coupé vers 14 s ; un Play
   sans appel Studio pendant 3 min est arrêté par VibeStarter).
4. Chaque essai part d'un véhicule arrêté (`settle`) et tient sa ligne en ligne droite (correction
   proportionnelle à l'écart et au cap).

Premiers essais (avant la piste) : la plaque de base de la place était trop courte (≈ 560 m devant le
véhicule) et un autre véhicule stationné bloquait le passage ; une sortie de plaque détruisait le
véhicule (pièces sous `FallenPartsDestroyHeight`). D'où la piste dédiée et la remise après une chute.

## Résultats

| Essai | Mesure | Commentaire |
|---|---|---|
| 0-60 km/h | **4,5 s** | |
| 0-100 km/h | **10,8 s** | 1→2 à 43 km/h, 2→3 à 76, 3→4 à 106, 4→5 à 136 km/h |
| Vitesse de pointe | **151,5 km/h** en 5e (plateau : < 0,3 km/h gagné en 2 s) | `PredictTopSpeed` 156 km/h ; `RedlineTopGearKmh` 180 ; 6e jamais atteinte (régime 0,88 en 5e) ; 1 477 m parcourus |
| 100-0 au frein | **33,3 m, 2,38 s** (1,19 g moyen) | lacet max 0,6°/s, cap tenu (0,008 m d'écart sur 220 m) |
| 60-0 au frein à main | 29,2 m, 3,33 s (0,51 g) | **lacet jusqu'à 69°/s sans braquer** : tête-à-queue |
| Virage plein braquage 40 km/h | 1,07 g, lacet 53°/s, dérive 1,0°, **roulis 0,28°** | vitesse tenue (39,9 km/h) |
| Virage plein braquage 80 km/h | pic 2,04 g (v × lacet, transitoire), dérive 9,5°, roulis 0,29° | sort à 71 km/h, ni retournement ni sortie |
| Bordure 0,15 m à 20 km/h | avant correction : cabrage **11,8°**, avant en l'air ~1 m ; après (`DampVMax` 1 m/s) : **7,6°**, au moins 2 roues au sol, 0,9 km/h perdus | voir « Bordure » |
| Bordure 0,15 m à 60 km/h | 17,6°, 0,15 s en l'air (9 images), pas de retournement (UpVector.Y ≥ 0,95) | vitesse conservée |
| Démarrage en côte 15 % (8,7°) | frein à main 1,5 s : 4,5 cm ; tout relâché 2 s : **6,7 cm** de recul (maintien automatique) ; plein gaz : 0 recul, 43 km/h en 4 s (2e) | |
| Marche arrière (frein maintenu à l'arrêt) | **−58,4 km/h en 4 s**, 34 m | |
| Régime / son / compte-tours | régime normalisé : écart max 0,05 avec vitesse × rapport (116 échantillons, `drive_play`) ; aux passages le régime tombe (0,81 → 0,50) et les boucles moteur passent de la plus aiguë à la suivante, `PlaybackSpeed` suit le régime | cohérent à l'écoute des valeurs ; pas d'écoute humaine |
| Clavier réel (`player_input` W 2 s) | `Throttle` 1,00, 38,5 km/h | chemin d'entrée réel vérifié |
| Manette, tactile | **non vérifiés** : `player_input` (VirtualInput) n'envoie pas l'axe R2 (`Throttle` resté à 0) et n'a pas d'écran tactile | à essayer à la main |
| Descente en roulant (9,7 km/h) | descente côté portière, joueur debout à 6,5 studs, véhicule arrêté en < 1 s, **ancré après 5,4 s** (`ParkAnchorDelay` 5) | |
| Chute dans le vide (Verify `void_play`, véhicule vide) | remis en 0,11-0,23 s à 0,03-0,22 stud de la position sûre, 156/156 pièces | |
| Chute en conduite (plein gaz hors du bord) | rattrapé à y −414 (seuil −440), conducteur toujours assis, aucune violation, puis **stable** (y 1,74, v 0) | après les deux corrections ci-dessous |
| Replacement d'un véhicule conduit (`Track.place`) | position exacte, aucune violation, physique rendue au conducteur | après correction |
| 30 véhicules stationnés + 1 conducteur à 60 km/h | serveur : battement 16,7 ms moyen / 18,2 p95 (sans eux : 16,9 / 19,0) ; client : 14,3 i/s (sans eux : 14,7) | aucun écart mesurable ; rendu Studio plafonné vers 15 i/s pendant tout l'essai (fenêtre de test sans focus) : ne dit rien du rendu sur téléphone |
| Coût de script | `Dyn.step` (8 sous-pas) **18 µs**, 4 spherecasts 10 µs → ≈ 0,03 ms par pas à 60 Hz (client) ; `Access.Step` pour 30 véhicules stationnés **49 µs** toutes les 0,25 s (serveur) | PC Studio, 2 000 et 200 répétitions |
| Verify `drive_play` (client) | **6/6** | pas `BindToSimulation` |
| Verify `void_play`, `flip_play`, `park_play` (serveur) | tous réussis | |

## Défauts trouvés et corrigés pendant les essais

1. **Remise d'un véhicule conduit annulée par le contrôle de vraisemblance.** Un déplacement fait par le
   serveur (remise, téléport, piste) était pris pour une triche : `DriveViolations` +1 et retour à
   l'ancienne place. Correction : `VehicleAccess.Teleport(car, pivot)` (ancre `VehicleRoot` 0,25 s, déplace,
   désancre, rend la physique au conducteur) et une tolérance **portée par un attribut**
   (`TeleportGraceUntil`, heure serveur), pas par une table du module : le code lancé par `execute_luau`
   côté serveur a son propre exemplaire du module (mesuré : la tolérance posée dans un exemplaire était
   invisible pour l'autre). Même cas pour un Actor ou un script qui requiert le module à part.
2. **Véhicule rattrapé d'une chute puis projeté à 60 studs de haut.** Une pièce ancrée garde sa vitesse
   (166 studs/s de chute) et la reprend au désancrage chez le client propriétaire. Correction : vitesses
   annulées avant l'ancrage (serveur) et tant que le véhicule est ancré (client, `VehicleDrive`).
3. **Véhicule relancé après une remise.** Les roues gardaient la vitesse prise en l'air pleins gaz.
   Correction : `VehicleDynamics.reset(sim)` dès que `VehicleRoot` est ancré.
4. **Bordure de 15 cm à 20 km/h : avant qui décolle.** La roue monte de 9 cm en une image (5,4 m/s) ;
   amortissement critique × 5,4 m/s ≈ 38 m/s² (34 mesuré, contre 2,5 au repos). Correction : réglage
   `DampVMax` (1 m/s) qui plafonne la vitesse d'amortisseur (clapets haute vitesse, souplesse du pneu) :
   cabrage 11,8° → 7,6°, plus de décollage.
5. **Remise sur les roues refusée (« moving ») juste après une chute.** Une pièce ancrée garde sa dernière
   vitesse ; `Recover` ne la regarde plus quand le véhicule est ancré.

## Erreurs du banc (mesures écartées)

- `Bench.curb` / `Bench.hill` réimposaient « plein gaz » avant chaque pas : le régulateur ne servait à rien
  (bordure prise à ~85 km/h au lieu de 20 : cabrage 57°, retournement presque). `hold()` accepte désormais
  une fonction d'entrées recalculée à chaque image.
- Un Play travaille sur une copie de la place faite au démarrage : un module mis à jour par la
  synchronisation pendant le Play n'y arrive pas. Relancer le Play après chaque changement de module.
- `settle()` freinait avec la touche frein en marche arrière, ce qui fait reculer (logique GTA). Corrigé :
  l'accélérateur freine en marche arrière.
- La première piste ne dépassait que de 100 studs derrière le départ : la marche arrière est tombée
  (rattrapée par la remise après une chute, ce qui l'a prouvée au passage).

## Ce qui fait déjà « GTA »

- Boîte automatique et régime : montées vers 0,93 du régime, chute de régime au passage, son et
  compte-tours qui suivent (écart ≤ 0,05).
- Frein maintenu à l'arrêt = marche arrière ; accélérateur en marche arrière = frein.
- Démarrage en côte sans recul notable (maintien automatique) ; freinage droit et court.
- Véhicule stable au repos (suspension à la hauteur modélisée), ne se retourne ni en virage serré ni sur
  une bordure à 60 km/h ; remis sur ses roues ou rattrapé d'une chute sans intervention.

## Ce qui ne fait pas encore « GTA » (à calibrer sur des mesures FiveM, étape 6)

Par priorité :

1. **Accélération** : 0-100 en 10,8 s, 3e → 4e en 6 s. Probablement trop lent pour une sportive.
   Réglages : `DriveForce` × rapport, `IwRel`, `KMu`, `ClutchChangeRate`. Mesurer en FiveM le 0-100 et le
   temps passé dans chaque rapport.
2. **Roulis quasi nul** (0,3° à 1 g) : la caisse reste à plat. Réglages : hauteurs de centre de roulis
   (`RollCentreHeightFront/Rear` lues telles quelles), `KArb`, `KSpring`. Mesurer en FiveM le roulis en virage
   stabilisé.
3. **Adhérence latérale** : 1,07 g à 40 km/h, ~2 g en pointe à 80 km/h. Réglages : `KMu`, `PeakFactor`.
   Mesurer en FiveM le rayon d'un virage plein braquage à 40 et 80 km/h.
4. **Frein à main en ligne droite** : tête-à-queue (69°/s) sans braquer. Réglage : `HandbrakeGripRear`.
   Mesurer en FiveM le lacet au frein à main à 60 km/h, volant droit.
5. **Marche arrière** : −58 km/h en 4 s, sans doute trop vite. Mesurer en FiveM la vitesse atteinte en 4 s.
6. **Bordure** : encore 7,6° de cabrage à 20 km/h. Réglages : `DampVMax` (0,6-1), `BumpK`. Mesurer en FiveM.
7. **Vitesse de pointe** : 151,5 km/h mesurés, 156 prédits, `RedlineTopGearKmh` 180. Mesurer la pointe en
   FiveM pour trancher entre `DriveMaxFlatVel` et la traînée.

## Limites

- Un seul véhicule (4 roues motrices) ; ni propulsion, ni moto, ni véhicule lourd.
- PC Studio : aucune mesure sur téléphone ; le rendu client plafonnait vers 15 i/s pendant les essais.
- Manette et tactile non vérifiés en automatique.
- Les essais sont reproductibles avec `TestTrack.lua` et `DriveBench.lua` (scripts disponibles) ; chaque
  chiffre ci-dessus vient d'une seule passe (pas de répétition statistique).

## Conduite des essais en Studio (2026-11-12)

- Déposer `DriveBench.lua`, `TestTrack.lua` **et** `tools/drive-compare/analyze.luau` (sous le nom
  `DriveAnalyze.lua`) dans le dossier de transfert **avant** le Play.
- Joueur au volant : téléporter d'abord le personnage à côté de la portière (`Access.Enter` refuse
  au-delà de sa portée, `too_far`), puis `Access.Enter(player, car, "DriverSeat")`.
- Côté client, une file d'essais (`task.spawn`) qui garde seulement les grandeurs de l'analyseur ;
  relever toutes les ~13 s. Les traces brutes (15 à 40 Ko par essai) restent dans le client.
- Réglages en direct pour un balayage : `sim.T[k]` est relu à chaque pas ; `PeakFactor` demande de
  recalculer `sim.P.alphaPeak`, et la hauteur de centre de roulis se change dans `sim.P.wheels[i].rc`.
- Entre deux passages de marche, le serveur replace le véhicule au départ de la voie dès qu'il est
  arrêté au-delà de 110 m (le client ne peut pas le demander par un attribut : il ne se réplique pas
  vers le serveur).
- **Zone morte de l'axe GTA (0,25)** : les essais FiveM ont été enregistrés avec des consignes brutes ; `DriveBench` passe au moteur la demande effective (`Bench.gtaAxis` : créneau 0,5 → 1/3, slalom écrêté). Sans elle, créneau et slalom braquent 1,5 fois trop.
- Un virage qui « décroche » peut être la boîte : relever le rapport (`gear`) avant d'accuser le pneu (2026-11-12 : rétrogradage 2→1 à 36 km/h en virage serré, corrigé par `DownshiftRpmThrottle`).
- **`steerAngle` et `w0str`/`w1str` ne sont pas la même chose** : `steerAngle` est la **commande** (le volant, 0 à 35 °, qui monte progressivement), `w0str`/`w1str` l'angle réellement pris par les **roues**. Au virage 80 la commande monte à 35 ° et y reste pendant que les roues retombent : lire l'une pour l'autre fait conclure à tort que GTA « annule les ordres ».
- **Un modèle se juge en simulation LIBRE**, son état reporté d'un pas au suivant. Recalé sur la mesure à chaque pas, c'est un prédicteur à un pas : il paraît toujours meilleur. C'est ce qui a failli faire retenir une butée de vitesse de braquage (0,88 ° recalé, 3,82 ° en simulation libre) à la place du retard du premier ordre.
- **Une manœuvre où tout varie ensemble ne peut identifier aucune loi.** Dans un virage pris à vitesse décroissante, vitesse, dérive et temps sont colinéaires : toute fonction décroissante colle. Pour séparer les variables il faut un essai qui en fixe une — le **cercle** à consigne constante et vitesse tenue (`skidpad`). Deux lois déduites du seul virage 80 se sont révélées fausses à la vérification, dont une de signe opposé.
- **L'accélération latérale d'un transitoire ne se lit pas sur `v × wz`** : il manque `d(vLat)/dt`. Sur un essai où la dérive de caisse croît encore (virage 80, slalom), `v × wz` surévalue de 8 à 11 %. Une cible qui dépasse `fTractionCurveMax` est le signe qu'on mesure mal, pas que le véhicule dépasse son adhérence.
- Le frein à main se mesure depuis un départ propre sur la ligne : enchaîné après le slalom, il est
  entré en correction de cap et a donné 36,5 °/s de lacet au lieu de 1,4.


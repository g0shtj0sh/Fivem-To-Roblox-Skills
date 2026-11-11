# Reconstruire en Luau la conduite de GTA V

On peut reproduire assez fidèlement la conduite de GTA V dans Roblox, mais pas en portant du code existant. **Aucune décompilation publique du solveur pneu/boîte de GTA V n'existe**, et une partie du modèle (forme de la courbe d'adhérence, loi des ressorts, loi de l'anti-roulis) devra être calée par des mesures dans FiveM. Ce qui est solidement établi suffit pourtant à fixer l'ossature du moteur :

- un moteur à **régime normalisé** (0,2 au ralenti, 1,0 au rupteur), sans régime réel ni rapport de pont ;
- un **couple plat jusqu'à 0,8 de régime, qui descend ensuite à 60 %** au rupteur ;
- une vitesse maximale par rapport égale à `fDriveMaxFlatVel / rapport`, avec `fDriveMaxFlatVel = 1,2 × fInitialDriveMaxFlatVel / 3,6` ;
- un embrayage qui **tombe à 0,1 à chaque changement de rapport** et remonte en `0,9 / fClutchChangeRateScale` secondes ;
- des **forces exprimées par unité de masse** : `fMass` ne sert qu'aux collisions ;
- des conversions au chargement vérifiées en mémoire : traînée ×0,0001, amortissement ÷10, angles en radians, biais ×2.

J'ai recoupé ces formules avec les vitesses de pointe mesurées par Broughy1322. Une traînée `a = fInitialDragCoeff × 10⁻⁴ × v²` (en m/s²) prédit la vitesse de pointe de la Blista à 0,1 km/h près, celle de l'Adder à 1,1 % près et celle de la Pariah à 4,7 % près. C'est une hypothèse de travail utile, mais elle reste à confirmer.

Côté Roblox, l'architecture recommandée repose sur six choix :

- un châssis à corps rigide unique, avec des roues en spherecast ;
- un module de simulation en Luau pur, exécuté à pas fixe via `RunService:BindToSimulation`, avec des sous-pas internes ;
- des forces calculées comme des accélérations, puis multipliées par `AssemblyMass` et par le nombre de studs par mètre ;
- une gravité ramenée à 9,8 m/s², soit environ 35 studs/s² à l'échelle 3,571 du convertisseur ;
- la propriété réseau confiée au conducteur dans un premier temps ;
- le mode Server Authority (sorti le 9 juillet 2026), à évaluer ensuite, en tenant compte de bogues connus sur les `VectorForce`.

Un prérequis s'impose avant tout : l'exporteur actuel (`summarize_handling`) ne transmet qu'environ 18 champs. Il omet notamment `fTractionCurveLateral`, l'amortissement, l'anti-roulis, les taux d'embrayage et la déportance. Sans ces champs, aucune fidélité n'est possible.

## Ce que l'on sait vraiment : le moteur, la boîte et les unités sont établis ; le pneu ne l'est pas

### Trois niveaux de preuve, aucun solveur décompilé

Les connaissances publiques sur la physique des véhicules de GTA V viennent de trois sources :

- le **chargeur de handling de FiveM**, qui reproduit les conversions que le jeu applique au chargement ([HandlingLoader.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp)) ;
- les **dumps de réflexion du parseur RAGE**, qui donnent l'offset, le type et la valeur initiale de chaque champ de `CHandlingData` pour chaque build ([rage-parser-dumps](https://github.com/alexguirre/rage-parser-dumps)) ;
- les mods d'ikt (Manual Transmission, Custom Torque Map, Custom Gear Ratios, Real-Time Handling Editor), qui lisent et patchent la mémoire du jeu ([GTAVManualTransmission](https://github.com/ikt32/GTAVManualTransmission)).

Il s'y ajoute deux sources plus ciblées. GTACars.net publie des formules de déportance « taken directly from disassembled game code » ([GTACars Downforce](https://gtacars.net/gta5/downforce)). Eddlm a confirmé ses formules en lisant la mémoire en mode solo ([Handling-Tools](https://eddlm.github.io/Handling-Tools/handling)).

En revanche, une recherche ciblée n'a trouvé **aucune décompilation publique de la conversion du glissement en force (CWheel), de `CTransmission::Process`, ni du code d'anti-roulis**. Il n'existe pas non plus de projet Unity, Godot ou Roblox qui réimplémente handling.meta. Le travail sera donc original.

Le tableau ci-dessous classe ce qui est connu par niveau de confiance. « Vérifié » signifie : issu du désassemblage, de la réflexion ou d'écritures en mémoire. « Mesuré » signifie : ajusté sur des essais en jeu. « Supposé » signifie : déduit de la structure des données ou de la lignée GTA SA/IV.

| Élément du modèle | Ce qui est établi | Niveau |
|---|---|---|
| Conversions au chargement | La vitesse plate est divisée par 3,6 ; un champ dérivé `fDriveMaxFlatVel` vaut ×1,2. Traînée ×0,0001. Amortissements ×0,1. Braquage et `fTractionCurveLateral` en radians, avec leurs inverses. Inverses `1/fTractionCurveMax` et `1/(Max−Min)`. Biais avant/arrière stockés en (2b, 2(1−b)). ([HandlingLoader.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp), [HandlingConversion.cpp](https://github.com/ikt32/GTAVHandlingEditor/blob/master/RTHandlingEditor/HandlingConversion.cpp)) | Vérifié |
| Régime moteur | « Internal game data only uses engine speed as a ratio of 0.2 (idle) to 1.0 (rev limit) ». Il n'y a pas de rapport de pont. ([CTM readme](https://github.com/ikt32/scripts-updates/blob/master/5-ctm-readme.md)) | Mesuré + mémoire |
| Courbe de couple | Identique pour tous les moteurs : plate jusqu'à 80 % du régime, puis 60 % au rupteur. Le premier rapport a toujours le couple plein. ([CTM readme](https://github.com/ikt32/scripts-updates/blob/master/5-ctm-readme.md)) | Mesuré |
| Vitesse par rapport | `maxSpeed = DriveMaxFlatVel / ratio[gear]`. La vitesse est linéaire en régime. ([VehicleExtensions.hpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/VehicleExtensions.hpp)) | Mémoire |
| Embrayage au changement de rapport | Il tombe à 0,1 (instruction `mov [rbx+40h], 0x3DCCCCCD`), puis remonte de `fClutchChangeRateScale` par seconde. Les gaz sont coupés pendant le passage. Le jeu fait aussi tomber l'embrayage au rupteur. ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp), [script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)) | Vérifié |
| Masse | `fMass` « does not impact performance or handling behaviour in any way », et ne sert qu'aux collisions. ([GTACars glossary](https://gtacars.net/gta5/glossary)) | Consensus des testeurs |
| Déportance par roue (WDV) | Formules par catégorie (classique, ancienne, nouvelle, monoplace). ([GTACars Downforce](https://gtacars.net/gta5/downforce)) | Vérifié |
| Gravité | Base implicite de 9,8 m/s². Les flags tout-terrain la portent à 10,78 m/s² (×1,1) ou 11,76 m/s² (×1,2). ([GTACars glossary](https://gtacars.net/gta5/glossary)) | Datamining |
| État par roue | Charge, vecteur de traction (X/Y/longueur), puissance, pression de frein, vitesse de rotation (rad/s), angle de braquage, adhérence du matériau. ([VehicleExtraNatives.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/extra-natives-five/src/VehicleExtraNatives.cpp)) | Mémoire |
| ABS et aide au contre-braquage | Un bit d'ABS par roue, et un saut conditionnel d'assistance au braquage, tous deux patchables. ([MemoryPatcher.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/MemoryPatcher.cpp)) | Vérifié |
| Forme de la courbe d'adhérence | Probablement une interpolation linéaire de Max vers Min (le jeu précalcule les inverses). La position du pic est disputée. | Supposé |
| Ressort, amortisseur, anti-roulis, centre de roulis | Seule la description qualitative est connue, et le modèle de GTA SA donne un gabarit. | Supposé |
| Traînée | « Proportional to velocity squared », valeur stockée ×0,0001. La formule d'Eddlm est incohérente avec les mesures. ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Partiel |

### Un modèle piloté par le régime, hérité de GTA SA

Le code de GTA San Andreas, entièrement décompilé, montre les motifs de conception que les champs de V portent encore ([gta-reversed](https://github.com/gta-reversed/gta-reversed)) :

- le même **facteur 1,2 entre la vitesse « plate » et la vitesse maximale** (`m_MaxVelocity = maxVelocity * 1.2f`) ([cHandlingDataMgr.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/cHandlingDataMgr.cpp)) ;
- des **paires de biais (2b, 2(1−b))** ;
- un **cercle d'adhérence par roue**. Au-delà de la limite, la force est ramenée à la limite et multipliée par un facteur de perte ([Vehicle.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/Entity/Vehicle/Vehicle.cpp)) ;
- un **ressort proportionnel à la compression × la masse × le niveau de force × le biais** ([Physical.cpp](https://github.com/gta-reversed/gta-reversed/blob/master/source/game_sa/Entity/Physical.cpp)).

Ces éléments servent de gabarit structurel. Ce n'est pas le code de V.

GTA V garde ce squelette, mais remplace la boîte de SA par un moteur à régime normalisé. Le régime y est la variable d'état principale. Broughy1322 le résume ainsi : « the speed of cars in GTA Online is all based on the engine revs ». Les dataminers attribuent d'ailleurs le *curb boost* (gain de vitesse sur les bordures) au fait que la compression de la suspension fait monter le régime ([Kotaku](https://kotaku.com/gta-onlines-car-exploit-is-still-polarizing-players-1824264759)).

Conséquence pratique : un clone qui calcule seulement « couple → accélération des roues » ratera la sensation GTA. Il faut un état de régime qui entraîne les roues motrices, plus des forces de pneu par roue bornées par un cercle d'adhérence qui dépend de la charge.

## Référence handling.meta : conversions, formules et arbitrages

### Deux couches de conversion à ne pas confondre

Une valeur de handling.meta subit deux transformations. La première est **la conversion du jeu au chargement** (fichier → `CHandlingData` en mémoire). Elle est vérifiée, et le port Luau doit la reproduire exactement, faute de quoi les handlings tunés ne se comporteront pas pareil. La seconde est **la conversion vers Roblox**, en studs, RMU et studs/s². Elle relève d'un choix d'architecture (voir la section sur l'architecture).

Le tableau suivant couvre la première couche, avec le sens physique utilisable et l'état des litiges. Les abréviations « b » et « 2b/2(1−b) » désignent la paire avant/arrière stockée par le jeu.

| Paramètre | Conversion au chargement | Sens et formule utilisable | Confiance / litige |
|---|---|---|---|
| `fMass` | aucune | kg ; collisions uniquement ([GTACars](https://gtacars.net/gta5/glossary)) | Consensus |
| `fInitialDragCoeff` | ×0,0001 ([HandlingLoader.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp)) | Traînée en v². Hypothèse ajustée ici : `a = valeur·10⁻⁴·v²` en m/s² | La formule d'Eddlm `(v·Cd·10⁻⁴)²` donne environ 0,002 g à 200 km/h, donc elle est fausse telle que transcrite |
| `fDownforceModifier` | aucune | WDV par roue, ajoutée à l'adhérence (détail plus bas) ([GTACars Downforce](https://gtacars.net/gta5/downforce)) | Vérifié ; forme « exponentielle » de la montée non publiée |
| `vecCentreOfMassOffset` | aucune | m, repère modèle (+x droite, +y avant, +z haut) ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Fiable |
| `vecInertiaMultiplier` | aucune | Multiplicateur d'inertie (x tangage, y roulis, z lacet) ; z > 2 recommandé ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Inertie de base inconnue |
| `fDriveBiasFront` | Fichier < 0,1 → (0, 1) ; > 0,9 → (1, 0) ; sinon (2b, 2(1−b)) ([HandlingLoader.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp)) | Répartition du couple moteur | Disputé : l'éditeur d'ikt ne traite que 0,0 et 1,0 exactement |
| `nInitialDriveGears` | Bornée à 10 (b1604+) | +1 rapport par amélioration de transmission ([GTACars](https://gtacars.net/gta5/glossary)) | 7 contre 8 rapports max avant b1604 |
| `fInitialDriveForce` | aucune | `a ≈ DriveForce × rapport × couple(régime) × g` ; « baseline ≈ 10·DriveForce m/s² » ([GTACars](https://gtacars.net/gta5/glossary), [Eddlm](https://eddlm.github.io/Handling-Tools/handling)) | Multiplication directe par le rapport non confirmée |
| `fDriveInertia` | aucune | Vitesse de montée du régime embrayage ouvert : `Δrpm = gaz·2·DI·dt` selon l'émulation MT ([script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)) | Eddlm donne « ralenti→rupteur ≈ 1/DI s », d'où un écart d'environ ×2,5 |
| `fClutchChangeRateScaleUp/DownShift` | aucune | Durée d'un passage = `0,9 / valeur` s ([GTACars](https://gtacars.net/gta5/glossary)) | Eddlm donne `1/valeur` ; le mécanisme 0,1→1 tranche pour 0,9 |
| `fInitialDriveMaxFlatVel` | ÷3,6 ; champ dérivé ×1,2 (= valeur/3,0 m/s) ([HandlingConversion.cpp](https://github.com/ikt32/GTAVHandlingEditor/blob/master/RTHandlingEditor/HandlingConversion.cpp)) | Vitesse au rupteur d'un rapport = `(valeur/3)/rapport` m/s ; rapport de pointe 0,9 → ×1,333 km/h | Fiable |
| `fBrakeForce` | aucune | Freinage demandé « en g par roue » ; blocage si `> fTractionCurveMax/4` ([Eddlm](https://eddlm.github.io/Handling-Tools/handling), [GTAMods](https://gtamods.com/wiki/Handling.meta)) | Empirique |
| `fBrakeBiasFront` | (2b, 2(1−b)) | Par essieu ; MT applique `fBrakeForce·entrée·biais` par roue ([script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)) | Fiable |
| `fHandBrakeForce` | aucune | Tout ou rien, roues arrière seulement ([GTACars](https://gtacars.net/gta5/glossary)) | Fiable |
| `fSteeringLock` | degrés → radians, plus inverse | Angle de la roue intérieure à l'arrêt, réduit avec la vitesse ([GTACars](https://gtacars.net/gta5/glossary)) | DWNSTR (« multiplicateur 0,1–0,75 ») est faux |
| `fTractionCurveMax` | inverse stocké | Adhérence de pic, « ≈ g » ([GTACars](https://gtacars.net/gta5/glossary)) | Les véhicules d'origine ont 2,0–2,6, donc l'échelle réelle est inconnue |
| `fTractionCurveMin` | `1/(Max−Min)` stocké | Adhérence en glisse, roue bloquée ou patinage | Fiable |
| `fTractionCurveLateral` | degrés → radians, plus inverse | Angle de dérive du pic | **Disputé** : pic à valeur/2 ([GTAMods](https://gtamods.com/wiki/Handling.meta), [Eddlm](https://eddlm.github.io/Handling-Tools/handling)) contre valeur entière ([GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json), [DrivingAssists.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/DrivingAssists.cpp)) |
| `fTractionSpringDeltaMax` | inverse stocké | m de débattement latéral du flanc ; ramène la voiture à l'arrêt après une glisse ([GTACars](https://gtacars.net/gta5/glossary)) | Raideur inconnue |
| `fLowSpeedTractionLossMult` | aucune | Adhérence à basse vitesse ≈ `1/(1+k)` ; effet artificiel de burnout ([GTACars](https://gtacars.net/gta5/glossary)) | Plage de vitesse inconnue |
| `fCamberStiffnesss` | aucune | Force latérale dans le sens du roulis du châssis ; 0–1 ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Loi inconnue |
| `fTractionBiasFront` | (2b, 2(1−b)) | Adhérence par essieu ; 0 ou 1 donne des pneus sans adhérence ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Fiable |
| `fTractionLossMult` | aucune | Échelle de la perte d'adhérence selon le matériau (materials.dat) ([GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)) | Fiable |
| `fSuspensionForce` | aucune | Commentaire Rockstar : « 1 / (Force * NumWheels) = Lower limit for zero force at full extension » ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | **Loi inconnue** |
| `fSuspensionCompDamp` / `ReboundDamp` | ×0,1 | `Damp = Force/2` « cancels the compression in 1 bounce » ; `Comp + Rebound = Force` donne un comportement stable ([GTACars](https://gtacars.net/gta5/glossary), [GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)) | Mesuré |
| `fSuspensionUpperLimit` / `LowerLimit` / `Raise` | aucune | m par rapport au repos (compression, détente, hauteur de caisse) ([GTACars](https://gtacars.net/gta5/glossary)) | Fiable |
| `fSuspensionBiasFront` | (2b, 2(1−b)) | > 0,5 : avant plus raide | Fiable |
| `fAntiRollBarForce` | aucune | « Spring constant transmitted to the opposite wheel » ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Loi inconnue |
| `fAntiRollBarBiasFront` | (2b, 2(1−b)) | — | **Disputé** : « 0 front, 1 rear » ([GTAMods](https://gtamods.com/wiki/Handling.meta)) contre « 1 = avant seul » ([GTACars](https://gtacars.net/gta5/glossary)) |
| `fRollCentreHeightFront/Rear` | aucune | m depuis le bas des roues ; au-dessus du centre de gravité, la caisse penche vers l'intérieur ([GTACars](https://gtacars.net/gta5/glossary)) | Implémentation inconnue |
| `fToeFront/Rear`, `fCamberFront/Rear`, `fCastor` (CCarHandlingData) | aucune | degrés/45 ; ≈ degrés/22,5 ; 0,01 = 1° ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Wiki seulement |
| `fMaxDriveBiasTransfer`, `strAdvancedFlags` | aucune | Différentiels, boîtes, `HARD_REV_LIMIT`, `CAN_WHEELIE`… ([GTAMods](https://gtamods.com/wiki/Handling.meta)) | Effets décrits, pas de formules |

Plusieurs flags changent le modèle et doivent être décodés depuis les chaînes hexadécimales :

- **Freinage.** `MF_ABS_STD` (ABS « arcade », glissement minimal), `MF_ABS_ALT_STD` (ABS « réaliste »).
- **Pneus.** `HF_HAS_RALLY_TYRES` inverse la courbe : l'adhérence part de Min et monte vers Max avec le glissement.
- **Moteur et boîte.** `HF_FREEWHEEL_NO_GAS` supprime le frein moteur. `HF_CVT` part d'un rapport 5,0 et descend à 0,9 à 90 % de la vitesse plate. `CF_HARD_REV_LIMIT` impose une vitesse maximale stricte par rapport.
- **Gravité.** Les `HF_OFFROAD_ABILITIES*` la multiplient par 1,1 ou 1,2.

Source pour l'ensemble : [GTACars glossary](https://gtacars.net/gta5/glossary).

### Les litiges, et le choix à retenir pour chacun

| Litige | Positions | Arbitrage recommandé |
|---|---|---|
| Position du pic de `fTractionCurveLateral` | valeur/2 (GTAMods, Eddlm) contre valeur entière (GTACars, ikt, qui compare la dérive mesurée à la valeur en radians) | Paramètre `PeakFactor` réglable, 0,5 par défaut pour les véhicules d'origine (22,5° → pic à 11°, cohérent avec « tend to stay below half »). À trancher par un essai sur plateau circulaire |
| Durée de passage | `0,9/x` contre `1/x` | `0,9/x` : c'est exactement le temps pour que l'embrayage monte de 0,1 à 1,0 au taux x/s, mécanisme vérifié dans le code |
| Sens de `fAntiRollBarBiasFront` | 0 = avant contre 1 = avant | 1 = avant : la conversion mémoire le traite comme les autres `*BiasFront` (avant = 2b) ([HandlingConversion.cpp](https://github.com/ikt32/GTAVHandlingEditor/blob/master/RTHandlingEditor/HandlingConversion.cpp)) |
| Seuil de `fDriveBiasFront` | < 0,1 / > 0,9 contre 0 / 1 exacts | Seuils 0,1 / 0,9 (FiveM et GTACars concordent) |
| Échelle de `fTractionCurveMax` | « ≈ g » contre des valeurs d'origine de 2,0–2,6 | Constante `k_mu` à caler (voir la calibration) ; ne pas supposer 1 g par unité |
| `fPercentSubmerged` | 0,85 contre 85,0 | 85,0 (le jeu calcule `100/valeur`) |
| `CF_ASSIST_TRACTION_CONTROL` | « drift physics » contre « just reduce throttle » | Antipatinage par réduction des gaz (note du code source citée par GTACars) |

### Ce que l'exporteur actuel doit ajouter

Dans le dépôt, `skills/fivem-vehicle-to-roblox/scripts/f2r/meta.py` (`summarize_handling`) n'exporte dans `VehicleConfig.Handling` que les champs suivants :

- `MassKg`, `DragCoeff`, `CentreOfMassOffset`, `DriveBiasFront`, `Gears`, `DriveForce`, `DriveInertia`, `MaxFlatVelKmh` ;
- `BrakeForce`, `BrakeBiasFront`, `HandBrakeForce`, `SteeringLockDeg` ;
- `TractionCurveMax/Min` ;
- `SuspensionForce`, les limites de suspension et `Raise` ;
- les flags modèle et handling.

`parse_handling` conserve pourtant l'élément XML complet (`element_to_obj`), donc l'ajout est trivial. Il faut exporter en plus, avec les valeurs du fichier (non converties) :

- **pneus** : `TractionCurveLateral`, `TractionBiasFront`, `TractionLossMult`, `LowSpeedTractionLossMult`, `TractionSpringDeltaMax`, `CamberStiffness` ;
- **suspension et roulis** : `SuspensionCompDamp`, `SuspensionReboundDamp`, `SuspensionBiasFront`, `AntiRollBarForce`, `AntiRollBarBiasFront`, `RollCentreHeightFront/Rear` ;
- **boîte** : `ClutchChangeRateScaleUpShift/DownShift` ;
- **aéro et inertie** : `DownforceModifier`, `InertiaMultiplier`, `PercentSubmerged` ;
- **le bloc `SubHandlingData/CCarHandlingData`** : `strAdvancedFlags`, `fMaxDriveBiasTransfer`, toe, carrossage, chasse ;
- **les flags décodés en entiers**.

Pour les améliorations de performance, il faut aussi exporter les `statMods` de carcols : moteur en %, transmission, turbo. Le runtime pourra ainsi appliquer les niveaux `Perf_<Slot>` que `VehicleCustomization` pose déjà en attribut.

## Les mesures en jeu qui servent de cibles de calibration

### Trois voitures mesurées valident l'équation de vitesse de pointe

Le seul jeu de mesures dures publié est celui de Broughy1322. Ses vitesses de pointe sont mesurées voiture entièrement améliorée, sur route plate et lisse, entre deux checkpoints. Elles sont arrondies à 0,25 mph, avec un écart-type maximal de 0,25 mph, sur la version Expanded & Enhanced « where fps has no impact on performance » ([méthodologie GTACars](https://gtacars.net/gta5/topspeed)). Le moteur amélioré multiplie `fInitialDriveForce` par `1 + 0,2 × modificateur/100` ([GTAMods Carcols](https://gtamods.com/wiki/Carcols.ymt)), ce que confirment les valeurs « Engine (Maxed) » des fiches.

J'ai appliqué la chaîne suivante :

- vitesse au rupteur en dernier rapport = `flatVel/3,6 × 1,2 / 0,9` ;
- couple de 1 jusqu'à 0,8 de régime, puis décroissance linéaire vers 0,6, maintenu à 0,6 au-delà ;
- accélération motrice = `DriveForce_amélioré × 0,9 × couple × 9,8` ;
- traînée `fInitialDragCoeff × 10⁻⁴ × v²` ;
- vitesse d'équilibre = là où les deux accélérations s'égalent.

| Véhicule | flatVel | Traînée | DriveForce amélioré | Rapports (origine) | Vmax mesurée | Vmax au rupteur (×1,333) | Vmax prédite | Écart |
|---|---|---|---|---|---|---|---|---|
| Blista | 135 | 8,0 | 0,276 | 5 | 168,98 km/h | 180,0 km/h | 168,9 km/h | −0,0 % |
| Adder | 160 | 7,8 | 0,384 | 6 | 203,18 km/h | 213,3 km/h | 200,9 km/h | −1,1 % |
| Pariah | 155,1 | 9,1 | 0,5778 | 6 | 218,87 km/h | 206,8 km/h | 208,7 km/h | −4,7 % |

Mesures et valeurs de handling : [Blista](https://gtacars.net/gta5/blista), [Adder](https://gtacars.net/gta5/adder), [Pariah](https://gtacars.net/gta5/pariah).

Cette chaîne est mon propre recoupement, à partir des formules citées plus haut. Ce n'est pas une formule publiée.

Le résultat est frappant. La valeur stockée par le jeu (`valeur × 0,0001`) fonctionne directement comme coefficient d'accélération en v², ce qui concorde avec le commentaire Rockstar « proportional to velocity squared ». Le recoupement confirme aussi que **les voitures d'origine plafonnent à 94–95 % de leur vitesse au rupteur**, à cause de la chute du couple au-delà de 0,8.

La Blista est le cas le plus propre. Avec l'amélioration de transmission, elle passe de 5 à 6 rapports, pour lesquels la table de rapports est connue. L'Adder et la Pariah passent à 7 rapports, dont l'étagement n'est pas publié. La Pariah dépasse même sa vitesse au rupteur de 6 %. Cela confirme la remarque d'Eddlm : une voiture puissante « can easily go over this speed… under performance upgrades » ([Eddlm](https://eddlm.github.io/Handling-Tools/handling)). Il en découle deux règles pour le clone : le rupteur ne doit pas être un plafond strict, sauf avec `CF_HARD_REV_LIMIT`, et l'étagement à 7 rapports ou plus devra être mesuré.

### Étagements, passages de rapports et accélération

Les tables de rapports par défaut lues en mémoire par l'outil d'Eddlm sont les suivantes, avec un dernier rapport toujours à 0,9 :

| Nombre de rapports | Rapports |
|---|---|
| 4 | 3,33 / 1,826 / 1,222 / 0,9 |
| 5 | 3,33 / 1,934 / 1,358 / 1,054 / 0,9 |
| 6 | 3,333 / 1,949 / 1,392 / 1,095 / 0,946 / 0,9 |

Source : [handling.html](https://github.com/eddlm/Handling-Tools/blob/master/handling.html).

Pour 6 rapports, la boîte automatique passe le rapport suivant à 22, 45, 60, 76 et 88 % de la vitesse de pointe. Ramené au régime du rapport quitté, cela donne un premier passage vers 0,82 puis des passages entre 0,92 et 0,97 (calcul de ma part). C'est la cible pour le seuil de montée de rapport.

Les temps de passage découlent directement de `0,9/x` :

| Véhicule | `fClutchChangeRateScale` | Temps de passage |
|---|---|---|
| Pariah | 3,4 | ≈ 0,26 s |
| Adder | 3,0 | ≈ 0,30 s |
| Blista | 1,7 | ≈ 0,53 s |

Valeurs tirées des fiches [GTACars](https://gtacars.net/gta5/pariah). L'amélioration de transmission multiplie le taux par 1 à 2 selon le modificateur ([script.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/script.cpp)).

En premier rapport, l'Adder améliorée demande en théorie `0,384 × 3,333 × 9,8 ≈ 12,5 m/s²` (environ 1,3 g). C'est donc l'adhérence, et le burnout artificiel, qui limitent le départ. Le moteur ne le limite pas.

Aucune table de 0–100 km/h n'a été publiée pour les véhicules d'origine. Le seul repère d'accélération documenté vient d'un pack réaliste : une R32 GT-R, réglée sur les temps réels 0-100/150/200 km/h (5,2 / 11,5 / 22 s), les reproduit à environ 1 s près, avec environ 1,3 g d'adhérence soutenue ([GTAVHandlingPack BNR32](https://github.com/ikt32/GTAVHandlingPack/blob/master/y97y-BNR32/README.md)).

### Adhérence, freinage, déportance et aides : surtout des repères qualitatifs

Côté adhérence et freinage, les repères sont les suivants :

- Adder Max/Min 2,5/2,38 ; Pariah 2,625/2,45 ; Blista 2,05/1,75 ; angle latéral 21,5–22,5° partout ([fiches GTACars](https://gtacars.net/gta5/adder)) ;
- aucune mesure publiée d'accélération latérale sur plateau circulaire ou de distance de freinage 100–0 ;
- seul indice chiffré : l'éditeur d'Eddlm annonce « 60-0 mph in ~1.71s » (environ 1,6 g), sans préciser les valeurs utilisées ([Eddlm](https://eddlm.github.io/Handling-Tools/handling)).

Côté déportance, les valeurs ont été extraites du code :

- **véhicule ordinaire** : WDV fixe de 0,035 par roue, 0,07 avec n'importe quel aileron non d'origine. Les ailerons « have no effect on top speed », et un grand aileron n'est pas meilleur qu'un petit ([GTACars Upgrades](https://gtacars.net/gta5/upgrades)) ;
- **ancien modèle** (modificateur ≤ 100) : montée de 0 à `mod × 0,035` à 90 % de la vitesse plate, ×1,25 avec aileron ;
- **nouveau modèle** (> 100) : de `(mod/100)·0,035·0,3` jusqu'à 40 % de la vitesse plate, puis montée jusqu'à `·0,86` à 90 % ; **ignoré en solo** ([GTACars Downforce](https://gtacars.net/gta5/downforce)) ;
- Eddlm précise que la WDV « is added to the wheel grip, multiply by the four wheels », exprimée en g ([Eddlm](https://eddlm.github.io/Handling-Tools/handling)).

Les aides arcade documentées sont les suivantes :

- adhérence à basse vitesse ≈ `1/(1+k)` (Adder 1,5 ; Pariah 1,15 ; Blista 0,7) ;
- frein moteur actif par défaut (le flag `freewheel_no_gas` existe pour le supprimer) ;
- force de redressement par défaut (flags `reduced/improved_righting_force`) ;
- autostabilisation en l'air seulement avec `offroad_abilities_x2` ;
- réduction du braquage avec la vitesse « using a percentage of the original steering lock » ([GTACars glossary](https://gtacars.net/gta5/glossary), [GTAMods](https://gtamods.com/wiki/Handling.meta)).

Aucune de ces aides n'a de constante publiée : ni vitesse d'extinction de la perte basse vitesse, ni pourcentage de braquage, ni gain du curb boost.

## Architecture Roblox : corps rigide, spherecast et pas fixe

### Raycast contre contraintes : le raycast gagne, maintenant que le pas fixe existe

Les châssis à contraintes (A-Chassis, le buggy du modèle Racing, MotorVehicle) tournent dans le solveur à 240 Hz. Ils sont donc indépendants de la fréquence d'images ([MotorVehicle](https://devforum.roblox.com/t/motorvehicle-chassis-programming-made-easy/2136669)). Mais ils n'exposent qu'une raideur de `SpringConstraint` et un couple de moteur, sans force de pneu dépendant du glissement. Le modèle de GTA (courbes Max/Min/Lateral par roue, biais d'adhérence, déportance ajoutée à l'adhérence) ne peut pas s'y exprimer. Le modèle Racing de 2024 souffrait en plus de projections lors des collisions à haute vitesse ([DevForum Racing Template](https://devforum.roblox.com/t/new-studio-racing-template/2805745)).

Les châssis raycast donnent ce contrôle par roue. Jusqu'ici, ils échouaient pour une seule raison : **l'intégration dépendait de la fréquence d'images**. Une barre anti-roulis « fine in 40-60 frames » vibrait au-delà ([DevForum Pacejka](https://devforum.roblox.com/t/a-vehicle-chassis-with-the-pacejka-friction-circle-raycast-suspension-gearbox/2400821)), et la raideur variait avec les FPS jusqu'à l'adoption d'un amortisseur semi-implicite ([DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)).

`RunService:BindToSimulation(fn, Enum.StepFrequency, priority)` lève ce verrou. Il appelle une fonction « at a fixed frequency which is independent of the frame rate » et exige `Workspace.UseFixedSimulation` ([RunService](https://create.roblox.com/docs/reference/engine/classes/RunService)).

La recommandation se décompose ainsi :

- **Châssis.** Un seul corps rigide, ou un assemblage soudé avec des enfants `Massless`. Il porte une coque de collision à faible friction pour les chocs.
- **Contact.** Un `Spherecast` par roue, lancé depuis le haut du débattement.
- **Forces.** Une force totale et un couple total calculés en Luau, puis écrits dans **une seule `VectorForce`** (`ApplyAtCenterOfMass`, `RelativeTo = World`) et **un seul `Torque`** (monde). Il vaut mieux éviter huit `VectorForce` par voiture : le centre de roulis se traite alors simplement dans le calcul du moment.
- **Roues visuelles.** Elles ne doivent jamais entrer en collision.
- **Solveur.** Régler `Workspace.PhysicsSteppingMethod` sur Fixed (240 Hz), que la documentation recommande pour les jeux de course ([Adaptive timestepping](https://create.roblox.com/docs/physics/adaptive-timestepping)).

### Boucle à pas fixe avec sous-pas internes

Seule `Enum.StepFrequency.Hz60` est documentée dans les exemples ([Server Authority deep dive](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)). L'existence de fréquences plus élevées n'est pas vérifiée. Il faut donc **sous-échantillonner en interne**, par exemple 4 sous-pas de 1/240 s par tick à 60 Hz, comme conseillé sur le DevForum ([7th attempt](https://devforum.roblox.com/t/trying-to-create-ray-cast-suspension-editable-open-stable-and-optimized/3494597)).

Pendant ces sous-pas, on n'intègre que les états raides : vitesse angulaire des roues, glissement, état de l'embrayage et du régime. La vitesse du châssis reste figée. On écrit ensuite la **moyenne** des forces dans la `VectorForce`, que le solveur maintient constante sur ses propres sous-pas.

Si `UseFixedSimulation` ne peut pas être activé, le repli est `PreSimulation`, qui remplace `Stepped` et s'exécute avant la physique, avec son `deltaTimeSim`. Le code d'exemple de `references/roblox-integration.md` utilise `Heartbeat`. Il doit migrer.

### Unités, échelle et gravité : calculer en accélérations, convertir à la frontière

Le convertisseur utilise par défaut `StudsPerMeter = 3,571`, soit 1 stud = 0,28 m, ce qui correspond à la convention officielle ([Roblox units](https://create.roblox.com/docs/physics/units)). Mais `Workspace.Gravity` vaut 196,2 studs/s² ([Workspace](https://create.roblox.com/docs/reference/engine/classes/Workspace)). À cette échelle, cela fait environ 54,9 m/s², soit 5,6 g. La valeur 196,2 correspond à l'ancienne convention de 5 cm par stud. Une voiture GTA placée telle quelle tomberait et rebondirait comme sur une planète lourde.

Comme GTA exprime moteur, freins et adhérence **par unité de masse**, la solution la plus robuste est de faire travailler le module de simulation entièrement en **forces spécifiques** (m/s², donc N/kg). On convertit à la frontière :

- force Roblox = `a_SI × StudsPerMeter × AssemblyMass` ;
- couple Roblox = `τ_spécifique × StudsPerMeter² × AssemblyMass`.

La conduite devient alors indépendante de la masse réelle du modèle Roblox, exactement comme dans GTA. `fMass` ne sert plus qu'à régler la densité via `CustomPhysicalProperties`, pour que les collisions entre véhicules gardent des rapports de masse plausibles.

Pour la gravité, on a deux options. La première consiste à fixer `Workspace.Gravity ≈ 35` (9,8 × 3,571), puis à réajuster les sauts des personnages. La seconde, préférable si le jeu dépend de la gravité par défaut, consiste à ajouter dans la force du véhicule une **compensation verticale** `(Workspace.Gravity/StudsPerMeter − g_cible)`, en m/s², vers le haut. Elle reproduit au passage la gravité propre à chaque véhicule que GTA stocke dans `CVehicle` ([VehicleExtensions.cpp](https://github.com/ikt32/GTAVManualTransmission/blob/master/Gears/Memory/VehicleExtensions.cpp)), et donc les flags tout-terrain ×1,1 et ×1,2.

Deux autres points d'échelle sont à traiter :

- **Axes.** Le centre de gravité GTA (+x droite, +y avant, +z haut) se convertit en `(x, z, −y) × StudsPerMeter` dans le repère de `VehicleRoot`, à condition que `LookVector` pointe vers l'avant, ce qui est à vérifier selon l'orientation produite par le convertisseur.
- **Rayons de contact.** À 300 km/h, une voiture parcourt environ 5 studs par tick de 60 Hz. Les spherecasts doivent donc couvrir débattement + rayon de roue + `v·dt` (calcul de ma part ; aucune documentation Roblox sur la détection continue des collisions n'a été trouvée).

### Réseau : propriété du conducteur d'abord, Server Authority ensuite

**Mode A, propriété au conducteur.** C'est le schéma classique. Le serveur appelle `SetNetworkOwner(conducteur)` à l'entrée dans le siège et `SetNetworkOwner(nil)` à la sortie, en remettant les forces à zéro à chaque changement de propriétaire ([DevForum In Depth](https://devforum.roblox.com/t/in-depth-scripted-car-physics/3915628)). La simulation tourne sur le client du conducteur, ce qui donne une latence d'entrée nulle et le coût serveur le plus bas. Le revers : « Roblox cannot verify physics calculations when a client has ownership » ([Network ownership](https://create.roblox.com/docs/physics/network-ownership)). Le serveur doit donc valider au minimum :

- que la vitesse reste inférieure à la vitesse théorique `(flatVel/3)/rapport_min × marge` ;
- que les déplacements d'une mise à jour à l'autre restent plausibles ;
- que le siège est bien occupé.

L'amélioration de la réplication physique (`ImprovedPhysicsReplication`, déployée depuis le 15 juin 2026) corrige les saccades au changement de propriétaire ([DevForum Physics Replication](https://devforum.roblox.com/t/upcoming-improvements-to-physics-replication/4675512)).

**Mode B, Server Authority** (sortie complète le 9 juillet 2026). La voiture reste au serveur et le client la prédit. Le même module Luau tourne dans `BindToSimulation` des deux côtés, avec rollback et resimulation en cas d'écart ([Server authority](https://create.roblox.com/docs/projects/server-authority), [Full Release](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993)). Ses coûts et risques sont documentés :

- une erreur de prédiction à 100 ms coûte « 6.25x the simulation load » ;
- les `VectorForce` « appear to be bugged and applying too much force » ;
- la quantification fait dériver certains movers ;
- il faut appeler `SetPredictionMode` sur la voiture de chaque joueur ([deep dive](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)) ;
- un véhicule qui « floats up and down » a été signalé en production ([DevForum bugs](https://devforum.roblox.com/t/multiple-server-authority-game-breaking-bugs/4738901)).

Deux points du dépôt bloquent aussi ce mode. Premièrement, `VehicleInput.lua` repose sur `ContextActionService`, alors que Server Authority exige l'Input Action System. Deuxièmement, les modèles convertis portent déjà de nombreux attributs (`Mod_*`, `Color_*`, `Door_*`, `Extra_*`, `WindowDown_*`, `Perf_*`), alors que la limite est de **64 attributs par instance** en Server Authority. L'état de simulation (vitesses des roues, rapport, embrayage, régime) devra donc vivre sur une instance dédiée, et rester restituable lors d'un rollback.

La recommandation : livrer le mode A, en écrivant un module de simulation pur (sans Instance, état passé explicitement) qui rendra le mode B quasi gratuit. Ensuite, évaluer le mode B sur le « Racing – Server Authority Template » officiel.

### Rendu des roues : le runtime existant suffit, à condition de l'alimenter

`VehicleRuntime` anime déjà les roues par `Joint.Transform`. Il calcule la rotation à partir de `WheelSpin` (rad/s, positif en marche avant), le débattement à partir de `Suspension` (m, positif vers le haut, converti avec `Spm`), et le braquage à partir de `Steer × WheelSteer`. Il bascule sur une estimation tirée de la vitesse du châssis si la télémétrie date de plus de 0,5 s.

Cette estimation répartit linéairement N rapports sur la vitesse maximale, ce qui n'a rien à voir avec l'étagement GTA. Le moteur physique doit donc appeler `Runtime.SetTelemetry` à chaque tick pour le conducteur.

Pour les autres joueurs, seuls `Rpm`, `Gear`, `Throttle` et `Steer` sont relayés en attributs, à 10 Hz. Chaque client devrait lancer localement un raycast cosmétique par roue sur les voitures distantes proches, et appeler `SetTelemetry` avec ce débattement. C'est la solution retenue par la communauté contre l'absence de réplication des suspensions ([DevForum Raycast Suspension](https://devforum.roblox.com/t/raycast-suspension-wheel-module-an-alternative-to-standard-physics-based-wheels/2170837)).

## Plan d'implémentation en huit étapes, avec pseudo-code Luau

Le code ci-dessous est un **squelette de conception**, pas du code testé. Les constantes en MAJUSCULES sont les paramètres inconnus à caler. L'organisation proposée sous `ReplicatedStorage/FiveMVehicles/GtaPhysics/` comprend trois modules :

- `Params` : handling.meta → valeurs runtime ;
- `Sim` : simulation pure, en forces spécifiques ;
- `Driver` : contacts, actionneurs, télémétrie.

### Étape 0 : étendre l'export et convertir comme le jeu

On ajoute à `summarize_handling` les champs listés dans la section de référence, puis on reproduit la couche de chargement du jeu.

```lua
--!strict
-- GtaPhysics/Params.lua : cfg.Handling (valeurs FICHIER) -> paramètres runtime SI
local G0 = 9.8 -- gravité de base implicite de GTA V (10.78 / 1.1)

-- Rapports lus en mémoire (outil d'Eddlm). >= 7 rapports : inconnus, à mesurer dans FiveM.
local DEFAULT_RATIOS = {
	{ 0.9 }, { 3.33, 0.9 }, { 3.33, 1.565, 0.9 }, { 3.33, 1.826, 1.222, 0.9 },
	{ 3.33, 1.934, 1.358, 1.054, 0.9 }, { 3.333, 1.949, 1.392, 1.095, 0.946, 0.9 },
}

local function pair(b: number): (number, number) -- convention du jeu : (2b, 2(1-b))
	return 2 * b, 2 * (1 - b)
end

local Params = {}

function Params.build(h, up) -- up : niveaux d'amélioration (attributs Perf_*) + statMods carcols
	up = up or {}
	local P = {}
	P.g = G0 * (h.OffroadX2 and 1.2 or h.Offroad and 1.1 or 1)
	-- Moteur / boîte
	P.driveForce = h.DriveForce * (1 + 0.2 * (up.EngineModPct or 0) / 100) -- carcols statMods
	P.initialFlatVel = h.MaxFlatVelKmh / 3.6                                -- m/s
	P.flatVel = P.initialFlatVel * 1.2                                       -- fDriveMaxFlatVel
	P.nGears = math.clamp(h.Gears + ((up.Transmission or 0) > 0 and 1 or 0), 1, 10)
	P.ratios = h.GearRatios or DEFAULT_RATIOS[math.min(P.nGears, 6)]         -- TODO >= 7
	P.reverseRatio = -P.ratios[1]                                            -- HYPOTHÈSE
	local tm = 1 + (up.TransmissionModPct or 0) / 100                        -- map 0..100 -> 1..2
	P.clutchUp = (h.ClutchChangeRateScaleUpShift or 1) * tm                  -- passage = 0.9 / taux
	P.clutchDown = (h.ClutchChangeRateScaleDownShift or 1) * tm
	P.driveInertia = h.DriveInertia or 1
	local db = h.DriveBiasFront or 0
	if db < 0.1 then P.driveF, P.driveR = 0, 1
	elseif db > 0.9 then P.driveF, P.driveR = 1, 0
	else P.driveF, P.driveR = db, 1 - db end -- (2b, 2(1-b)) normalisé à somme 1 : HYPOTHÈSE à caler
	-- Freins
	P.brake, P.handbrake = h.BrakeForce, h.HandBrakeForce
	P.brakeF, P.brakeR = pair(h.BrakeBiasFront)
	-- Pneus
	P.muMax = h.TractionCurveMax * K_MU          -- K_MU : échelle « ~g » à caler (1.0 au départ)
	P.muMin = h.TractionCurveMin * K_MU
	P.alphaPeak = math.rad(h.TractionCurveLateral or 22.5) * (h.PeakFactor or 0.5) -- litige 0.5 / 1.0
	P.kappaPeak = KAPPA_PEAK                     -- glissement longitudinal du pic : absent de V
	P.falloff = FALLOFF                          -- largeur de la décroissance Max -> Min
	P.tracF, P.tracR = pair(h.TractionBiasFront or 0.5)
	P.lossMult = h.TractionLossMult or 1
	P.lowSpeedLoss = h.LowSpeedTractionLossMult or 1
	P.sidewall = h.TractionSpringDeltaMax or 0.1 -- m
	P.camber = h.CamberStiffness or 0
	P.rally = h.HasRallyTyres == true
	-- Suspension (valeurs fichier ; ζ = 2·Damp/Force donne ζ = 1 quand Damp = Force/2)
	P.suspForce = h.SuspensionForce
	P.suspF, P.suspR = pair(h.SuspensionBiasFront or 0.5)
	P.zetaComp = 2 * (h.SuspensionCompDamp or h.SuspensionForce / 2) / h.SuspensionForce
	P.zetaReb = 2 * (h.SuspensionReboundDamp or h.SuspensionForce / 2) / h.SuspensionForce
	P.upper, P.lower, P.raise = h.SuspensionUpperLimit, h.SuspensionLowerLimit, h.SuspensionRaise
	P.arb = h.AntiRollBarForce or 0
	P.arbF, P.arbR = pair(h.AntiRollBarBiasFront or 0.5) -- 1 = avant
	P.rcF, P.rcR = h.RollCentreHeightFront or 0, h.RollCentreHeightRear or 0
	-- Aéro / direction / flags
	P.dragK = (h.DragCoeff or 10) * 1e-4        -- a_drag = dragK · v²  (ajusté sur Blista/Adder)
	P.dfMod, P.spoiler = h.DownforceModifier or 0, up.Spoiler == true
	P.steerLock = math.rad(h.SteeringLockDeg)
	P.freewheel, P.hardRev = h.FreewheelNoGas == true, h.HardRevLimit == true
	P.abs = h.AbsMode -- nil | "std" | "alt"
	return P
end

return Params
```

L'amortissement exploite la règle mesurée selon laquelle `Damp = Force/2` « annule en un rebond ». Cela revient à définir un taux d'amortissement critique ζ = 2·Damp/Force. Ce taux ne dépend pas de l'échelle ×0,1 et satisfait aussi `Comp + Rebound = Force` → ζ moyen = 1.

### Étape 1 : contact et suspension

Pour chaque roue, on lance un `workspace:Spherecast` (rayon = rayon du pneu) depuis le point d'ancrage décalé de `upper + raise`, vers le bas du châssis, sur une longueur `upper − lower + v·dt`. On en tire la compression `x` (en m, 0 = détente maximale) et la vitesse du point de contact (`GetVelocityAtPosition`), projetée dans le repère de la roue.

La loi de ressort de V est inconnue. L'hypothèse la plus simple qui respecte à la fois la lignée SA (force ∝ masse × niveau de force × biais) et le commentaire Rockstar est la suivante : `k = Force × biais × m·g / course`. Le tassement statique vaut alors `1/(Force × NbRoues × biais)` de la course, ce que je propose comme lecture de « 1/(Force·NumWheels) ». C'est une interprétation, à valider par la hauteur de caisse mesurée dans FiveM.

```lua
-- Sim.lua (extrait) : forces SPÉCIFIQUES (N/kg = m/s²) ; la masse n'intervient jamais.
local function suspension(P, w, x: number, xdot: number, h: number): number
	local L = P.upper - P.lower
	local k = P.suspForce * w.suspMult * P.g / L * K_SPRING      -- K_SPRING = 1 si l'hypothèse tient
	local mc = 0.25                                              -- quart de masse, en spécifique
	local zeta = (xdot > 0) and P.zetaComp or P.zetaReb
	local c = zeta * 2 * math.sqrt(k * mc)
	c = c / (1 + c * h / mc)                                     -- amortisseur semi-implicite (DevForum)
	local F = k * x + c * xdot
	if x > L then F += BUMP_K * (x - L) end                      -- butée
	return math.max(F, 0)                                        -- force normale N (spécifique)
end

local function antiRoll(P, axle, wl, wr)
	if not (wl.grounded and wr.grounded) then return end
	local L = P.upper - P.lower
	local kA = P.arb * axle.arbMult * P.g / L * K_ARB            -- loi inconnue : K_ARB à caler
	local dF = kA * (wl.x - wr.x)
	wl.N = math.max(wl.N + dF, 0); wr.N = math.max(wr.N - dF, 0)
end
```

### Étape 2 : pneus, avec une courbe paramétrée par Max, Min et Lateral

La forme retenue suit les champs précalculés par le jeu. On définit un glissement combiné normalisé `s` (1 = pic). Sous le pic, la force monte linéairement jusqu'à `fTractionCurveMax`. Au-delà, elle décroît linéairement vers `fTractionCurveMin`. Avec `HF_HAS_RALLY_TYRES`, la courbe s'inverse.

Le glissement longitudinal du pic n'existe plus dans V (`fTractionCurveLongitudinal` a disparu depuis IV) ([GTAMods handling.dat](https://gtamods.com/wiki/Handling.dat)). Il devient une constante à caler.

```lua
local V_MIN = 1.0 -- m/s : plancher de vitesse pour les dérives (anti-jitter)

local function muOf(P, s: number): number
	if P.rally then return P.muMin + (P.muMax - P.muMin) * math.min(s, 1) end
	if s <= 1 then return P.muMax end
	local t = math.min((s - 1) / P.falloff, 1)
	return P.muMax + (P.muMin - P.muMax) * t                     -- lerp via 1/(Max-Min) du jeu
end

-- renvoie (Fx longitudinal, Fy latéral) spécifiques dans le repère de la roue
local function tyre(P, w, vLong: number, vLat: number, gripMult: number, extraGrip: number)
	local vRef = math.max(math.abs(vLong), V_MIN)
	local alpha = math.atan2(vLat, vRef)                         -- angle de dérive
	local kappa = (w.omega * w.radius - vLong) / vRef            -- taux de glissement
	local sa, sk = alpha / P.alphaPeak, kappa / P.kappaPeak
	local s = math.sqrt(sa * sa + sk * sk)
	w.slip = s
	if s < 1e-6 then return 0, 0 end
	local Fmax = (w.N * muOf(P, s) + extraGrip) * gripMult       -- extraGrip = déportance WDV
	local F = Fmax * math.min(s, 1)                              -- montée linéaire jusqu'au pic
	return F * sk / s, -F * sa / s                               -- cercle (ellipse) d'adhérence
end
```

Le multiplicateur d'adhérence de chaque roue combine quatre facteurs :

- le biais d'essieu (`tracF`/`tracR`, valant 1 pour 0,5) ;
- l'adhérence du matériau sous la roue, élevée à `fTractionLossMult` : on mappe `RaycastResult.Material` vers une table inspirée de materials.dat ;
- la perte à basse vitesse (étape 7) ;
- la déportance, ajoutée en `extraGrip = WDV × g` par roue, d'après « added to the wheel grip ».

Sous `V_MIN`, on remplace la force latérale par un **ressort de flanc** : le déplacement du point de contact est mémorisé et borné à `fTractionSpringDeltaMax`, et la force vaut `−k·d − c·vLat`. C'est exactement l'effet « pull back towards the direction it came from » décrit par GTACars, et cela supprime la glisse et le tremblement à l'arrêt.

### Étape 3 : moteur, embrayage, boîte et régime

```lua
local UPSHIFT_RPM, DOWNSHIFT_RPM = 0.93, 0.55 -- 0.93 dérivé des seuils d'Eddlm ; descente à caler

local function torqueCurve(rpm: number, gear: number): number
	if gear == 1 or rpm <= 0.8 then return 1 end
	return math.max(1 - 2 * (rpm - 0.8), 0.6)                    -- 1 -> 0.6 entre 0.8 et 1.0
end

local function shift(S, newGear: number, dir: number)
	S.gear, S.shiftDir, S.clutch = newGear, dir, 0.1             -- l'embrayage tombe à 0.1 (code du jeu)
end

-- drivenSpeed : vitesse périphérique moyenne (ω·r) des roues motrices, en m/s
local function engine(S, P, c, drivenSpeed: number, h: number): number
	local gear = S.gear
	local ratio = (gear > 0) and P.ratios[gear] or P.reverseRatio
	local gearTop = P.flatVel / math.abs(ratio)
	if S.clutch < 1 then
		S.clutch = math.min(1, S.clutch + ((S.shiftDir >= 0) and P.clutchUp or P.clutchDown) * h)
	end
	local throttle = (S.clutch < 1) and 0 or c.Throttle          -- gaz coupés pendant le passage
	-- régime : lié aux roues si embrayé, libre sinon (émulation MT ; la loi de descente est une HYPOTHÈSE)
	local free = math.clamp(S.rpm + (2 * throttle - 1) * 2 * P.driveInertia * h, 0.2, 1)
	local wheel = math.abs(drivenSpeed) / gearTop
	S.rpm = math.max(0.2, wheel * S.clutch + free * (1 - S.clutch))
	-- rupteur : le jeu fait retomber l'embrayage à 0.1 ; plafond strict seulement si HARD_REV_LIMIT
	local cut = 1
	if S.rpm >= 1 then
		if P.hardRev then cut = 0 elseif gear == P.nGears then S.clutch = math.min(S.clutch, 0.1) end
	end
	-- boîte automatique
	if S.clutch >= 1 and gear > 0 then
		if S.rpm > UPSHIFT_RPM and gear < P.nGears then shift(S, gear + 1, 1)
		elseif gear > 1 and S.rpm < DOWNSHIFT_RPM
			and S.rpm * P.ratios[gear - 1] / ratio < UPSHIFT_RPM then shift(S, gear - 1, -1) end
	end
	local tq = torqueCurve(S.rpm, gear) * (1 + 0.1 * (S.turbo or 0)) -- turbo : +10 % une fois chargé
	return P.driveForce * ratio * tq * throttle * S.clutch * cut * P.g -- m/s², signe = sens du rapport
end
```

L'accélération motrice spécifique est répartie selon `driveF`/`driveR`, puis divisée par le nombre de roues motrices de l'essieu. Elle est appliquée comme couple `T = a_roue × r` sur la roue. On intègre ω à chaque sous-pas, avec une inertie de roue elle aussi spécifique : `Iw = IW_REL × r² / 4`, pour que le patinage ne dépende pas de la masse, comme dans GTA. La réaction du sol vaut `−Fx·r`.

Pour la marche arrière, le passage se fait quand le frein est maintenu à l'arrêt, avec `reverseRatio` et un plafond à mesurer. La télémétrie convertit le régime normalisé en tr/min affichables avec `Idle + (rpm − 0,2)/0,8 × (MaxRpm − Idle)`, ce qui correspond aux `IdleRpm`/`MaxRpm` audio déjà présents dans `cfg.Audio`.

### Étape 4 : freins, ABS et frein à main

```lua
local function wheelTorques(P, S, c, w, aDriveWheel: number, h: number)
	local axleBrake = w.front and P.brakeF or P.brakeR
	local brakeA = P.brake * c.Brake * axleBrake * P.g             -- « g par roue » (Eddlm, MT)
	if c.Handbrake and not w.front then brakeA += P.handbrake * P.g end -- tout ou rien, arrière seul
	if P.abs and not (c.Handbrake and not w.front) and w.slip > ABS_SLIP[P.abs] then
		brakeA *= ABS_RELEASE                                       -- std : glissement mini ; alt : plus permissif
	end
	local Iw = IW_REL * w.radius * w.radius / 4
	local omega = w.omega + (aDriveWheel * w.radius - w.Fx * w.radius) / Iw * h
	local dB = brakeA * w.radius / Iw * h                          -- le frein ne peut pas inverser ω
	w.omega = (math.abs(omega) <= dB) and 0 or (omega - math.sign(omega) * dB)
end
```

Avec cette échelle, `fBrakeForce = 1` demande environ 4 g sur l'ensemble des roues. La roue bloque donc dès que `fBrakeForce > μ/4`, ce qui reproduit la règle empirique de GTAMods. La décélération réelle est plafonnée par l'adhérence. C'est pourquoi la constante `K_MU` est le premier réglage à faire.

### Étape 5 : anti-roulis, centre de roulis et carrossage

L'anti-roulis s'applique sur les forces normales avant l'appel aux pneus (fonction `antiRoll` ci-dessus).

Pour le **centre de roulis**, on ne fait pas appliquer la force latérale au point de contact dans le calcul du moment. On l'applique à un point situé à `fRollCentreHeight` au-dessus du bas de la roue, dans le plan de l'essieu. Le bras de levier du roulis devient alors `h_CG − h_RC`. Si le centre de roulis passe au-dessus du centre de gravité, la caisse penche vers l'intérieur, comme le décrivent GTAMods et GTACars. C'est le comportement documenté, obtenu sans constante supplémentaire.

Le **carrossage** (`fCamberStiffnesss`) ajoute par roue au sol une force latérale `camber × sin(roulis) × N`, orientée dans le sens du roulis du châssis. La loi exacte est inconnue, d'où un gain `K_CAMBER` à caler.

### Étape 6 : traînée et déportance

```lua
local function wdv(P, v: number): number -- valeur de déportance par roue, en « g d'adhérence »
	local sp = P.spoiler and 1.25 or 1
	if P.dfMod <= 1 then return P.spoiler and 0.07 or 0.035 end   -- véhicule « regular »
	if P.dfMod <= 100 then                                         -- ancien modèle
		local t = math.clamp(v / (0.9 * P.initialFlatVel), 0, 1)
		return P.dfMod * 0.035 * t * t * sp                        -- forme exacte : calculateurs Desmos GTACars
	end
	local t = math.clamp((v / P.initialFlatVel - 0.4) / 0.5, 0, 1) -- nouveau modèle (> 100)
	return (P.dfMod / 100) * 0.035 * (0.3 + 0.56 * t) * sp         -- ignoré en solo : vérifier FiveM
end
-- traînée omnidirectionnelle appliquée au centre de gravité :
-- aDrag = -P.dragK * v.Magnitude * v      (v = vitesse du châssis en m/s)
```

La forme quadratique de la montée est une approximation. GTACars publie les calculateurs Desmos exacts, qu'il faudra reprendre ([GTACars Downforce](https://gtacars.net/gta5/downforce)). On ne sait pas encore si FiveM applique le « nouveau modèle » (réservé au multijoueur) : il faut le vérifier en mesurant l'adhérence à vitesse égale avec un modificateur supérieur à 100.

### Étape 7 : aides arcade

```lua
local function assists(P, S, c, speed: number, beta: number)
	-- 1. Perte d'adhérence artificielle à basse vitesse (burnout) : 1/(1+k), effacée avec la vitesse
	local f = math.clamp(1 - speed / LOWSPEED_FADE, 0, 1)          -- LOWSPEED_FADE ≈ 10 m/s : à caler
	local lowGrip = 1 / (1 + P.lowSpeedLoss * f)
	-- 2. Braquage réduit avec la vitesse, vers l'angle de dérive optimal
	local target = math.max(P.alphaPeak * STEER_PEAK_GAIN, P.steerLock * STEER_MIN_PCT)
	local lock = P.steerLock + (target - P.steerLock) * math.clamp(speed / STEER_FADE, 0, 1)
	-- 3. Contre-braquage assisté (le jeu en a un) : ajoute k·β à la consigne
	local steer = math.clamp(c.Steer * lock + COUNTERSTEER_K * beta, -P.steerLock, P.steerLock)
	-- 4. Frein moteur gaz relâchés (sauf HF_FREEWHEEL_NO_GAS) : décélération ∝ régime
	local engBrake = (not P.freewheel and c.Throttle == 0 and S.clutch >= 1)
		and ENGINE_BRAKE_G * P.g * (S.rpm - 0.2) / 0.8 or 0
	return lowGrip, steer, lock, engBrake
end
-- 5. Si renversé (UpVector·Y < 0.3) et lent : couple de redressement RIGHTING_K autour de l'axe avant.
-- 6. En l'air : couple de tangage/roulis piloté par Steer/Throttle (AIR_CONTROL_K) ;
--    autostabilisation seulement si OFFROAD_ABILITIES_X2.
-- 7. Optionnel (curb boost) : rpm += CURB_GAIN * max(xdot_roues_motrices, 0) * h ; désactivé
--    pour les monoplaces (flag avancé 0x8000000).
```

### Étape 8 : la boucle complète, les actionneurs et la télémétrie

```lua
-- GtaPhysics/Driver (LocalScript du conducteur en mode A ; ModuleScript partagé en mode B)
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local SUB = 4

RunService:BindToSimulation(function(dt) -- exige Workspace.UseFixedSimulation ; signature à vérifier
	if not Input.Enabled or not car then return end
	local root, spm = car.VehicleRoot, cfg.StudsPerMeter or 3.571
	local contacts = Contact.sample(car, rig, spm, dt)            -- spherecasts -> mètres, repère roue
	local out = Sim.step(S, P, Input.Controls, contacts, dt, SUB) -- force/couple spécifiques (monde, SI)
	-- compensation de gravité : on vise P.g au lieu de Workspace.Gravity
	local aGrav = Vector3.yAxis * (Workspace.Gravity / spm - P.g)
	local m = root.AssemblyMass
	rig.Force.Force = (out.force + aGrav) * spm * m               -- VectorForce, ApplyAtCenterOfMass
	rig.Torque.Torque = out.torque * spm * spm * m                -- Torque, RelativeTo World
	Runtime.SetTelemetry(car, {
		Rpm = idle + (S.rpm - 0.2) / 0.8 * (maxRpm - idle), Gear = S.gear,
		Throttle = Input.Controls.Throttle, Brake = Input.Controls.Brake,
		Speed = out.vLong, Steer = Input.Controls.Steer, WheelSteer = out.lock,
		WheelSpin = out.omegaByBone,                              -- rad/s, + = marche avant
		Suspension = out.travelByBone,                            -- m, + = vers le haut, relatif au repos
	})
end, Enum.StepFrequency.Hz60, Enum.RenderPriority.Input.Value)
```

`Sim.step` enchaîne, pour chaque sous-pas :

1. suspension, puis anti-roulis, ce qui donne N ;
2. aides (adhérence basse vitesse, braquage) ;
3. moteur, ce qui donne l'accélération motrice ;
4. pneus avec ω courant, ce qui donne Fx et Fy ;
5. intégration de ω (moteur, frein, réaction du sol).

À chaque sous-pas, il accumule aussi `Σ F` et `Σ (r_application × F)` autour de `AssemblyCenterOfMass`. Après les sous-pas, il ajoute la traînée et le frein moteur, puis renvoie la moyenne. Le moteur du dépôt peut ainsi rester un module pur, testable hors de Roblox.

## Calibrer contre FiveM : des traces temporelles, pas des impressions

La méthode recommandée consiste à rejouer dans la simulation Luau, hors ligne, **exactement les mêmes entrées** que celles enregistrées dans FiveM sur le même véhicule converti, puis à comparer les traces temporelles. Côté FiveM, un script client enregistre à chaque image :

- le temps et la vitesse ;
- la vitesse dans le repère du véhicule et la rotation (roulis, lacet) ;
- `GET_VEHICLE_CURRENT_RPM`, le rapport engagé et les rapports via `GET_VEHICLE_GEAR_RATIO` ;
- par roue, `GET_VEHICLE_WHEEL_SPEED` et `GET_VEHICLE_WHEEL_TRACTION_VECTOR_LENGTH` ;
- les valeurs effectives lues par `GET_VEHICLE_HANDLING_FLOAT` ([VehicleExtraNatives.cpp](https://github.com/citizenfx/fivem/blob/master/code/components/extra-natives-five/src/VehicleExtraNatives.cpp), [cfxnatives](https://cfxnatives.dev/natives/GET_VEHICLE_HANDLING_FLOAT)).

Le protocole de Broughy fixe les règles de bonne pratique : route ordinaire plate et lisse (les pièces de stunt donnent des vitesses plus basses), checkpoints, et plusieurs passages ([GTACars Top Speed](https://gtacars.net/gta5/topspeed)). Il faut **plafonner FiveM à 60 FPS** : sur l'ancienne version PC, certains effets, comme le curb boost, augmentaient avec la fréquence d'images ([Kotaku](https://kotaku.com/gta-onlines-car-exploit-is-still-polarizing-players-1824264759)). Il faut aussi désactiver toutes les améliorations, ou les noter.

| Essai | Manœuvre | Grandeurs comparées | Paramètres calés |
|---|---|---|---|
| Accélération | Plein gaz en ligne droite, de 0 à la vitesse de pointe | v(t), régime(t), rapport(t), Vmax | `UPSHIFT/DOWNSHIFT_RPM`, `IW_REL`, multiplication par le rapport, traînée |
| Décélération libre | Gaz relâchés depuis la vitesse de pointe, puis au point mort | v(t) | Traînée (au point mort) puis `ENGINE_BRAKE_G` (en prise) |
| Départ arrêté | Plein gaz depuis l'arrêt | Vitesse de roue contre vitesse du sol | `LOWSPEED_FADE`, `KAPPA_PEAK`, `K_MU` longitudinal |
| Freinage | 100→0 km/h, freinage maximal, avec et sans ABS | Distance, a(t), blocage | `K_MU`, `ABS_SLIP`, frein à main |
| Plateau circulaire | Rayon constant, vitesse croissante | Accélération latérale max, dérive à la limite | `K_MU`, `PeakFactor`, `FALLOFF` |
| Coup de volant | Braquage soudain à vitesse fixe | Taux de lacet(t), roulis(t) | `K_ARB`, centres de roulis, `K_CAMBER`, inertie (lest) |
| Chute | Lâcher de 0,5 m, puis mesure de la hauteur de caisse à l'arrêt | Compression(t), tassement | `K_SPRING`, interprétation de `fSuspensionForce` |
| Passages de rapport | Plein gaz | Durée de chute du régime | Vérifie `0,9/x` |

Je propose de commencer par des tolérances serrées sur ce qui est bien établi :

- vitesse de pointe à ±2 % ;
- temps de passage de rapport à une image près ;
- 0–100 km/h à ±5 %.

Ensuite viennent des tolérances plus larges sur le comportement du pneu : accélération latérale maximale à ±10 %, et allure du taux de lacet.

L'ajustement se fait par moindres carrés sur v(t), régime(t) et taux de lacet(t), un groupe de paramètres à la fois, dans l'ordre du tableau. Comme la simulation est pure, elle peut tourner hors de Roblox dans un runtime Luau autonome, en intégration continue. Les trois points de vitesse de pointe ci-dessus (Blista, Adder, Pariah) servent de premier test de non-régression avant même le premier essai FiveM.

## Ce qui reste inconnu

Le manque le plus lourd est la **loi pneu**. On ne connaît ni la forme exacte de la courbe (linéaire, en morceaux ou autre), ni la position du pic latéral (×0,5 ou ×1), ni la définition du glissement longitudinal, ni la largeur de la décroissance, ni l'échelle réelle de `fTractionCurveMax`. Les véhicules d'origine affichent 2,0 à 2,6 « g », alors que les packs réalistes valident 1,0 ≈ 1 g. Aucune décompilation publique du chemin CWheel ne permet de trancher, et ikt lui-même qualifie plusieurs de ces formules d'« uncertain » ([GTAVHandlingInfo](https://github.com/ikt32/GTAVHandlingInfo/blob/master/notes.json)).

Viennent ensuite les lois sans formule publiée :

- ressort (`fSuspensionForce`) ;
- anti-roulis ;
- centre de roulis ;
- carrossage ;
- raideur de flanc ;
- répartition du couple entre les roues d'un même essieu (différentiel ouvert ou partage égal) ;
- normalisation des paires de biais pour la propulsion, qui pose une question non résolue : (0, 1) en propulsion contre (1, 1) en 4×4 à 0,5.

Côté boîte, il manque :

- les rapports pour 7 à 10 rapports (« shorter gears for gears 7 and up » selon ikt, l'inverse selon GTAMods) ;
- les seuils de rétrogradage ;
- le rapport et la vitesse maximale en marche arrière ;
- la loi de descente du régime embrayage ouvert, avec un écart d'un facteur 2,5 entre les deux sources sur `fDriveInertia` ;
- le comportement exact au-delà du rupteur, qu'illustre la Pariah.

Pour les aides, aucune constante n'est publiée : ni vitesse d'extinction de la perte basse vitesse, ni pourcentage de braquage à haute vitesse, ni gain du contre-braquage, ni force de redressement, ni contrôle en l'air, ni gain du curb boost.

Côté Roblox, plusieurs points restent à vérifier :

- les valeurs de `Enum.StepFrequency` au-delà de 60 Hz ;
- l'utilisation de `UseFixedSimulation` hors Server Authority ;
- le coût CPU d'un châssis raycast avec 30 voitures ou plus ;
- le comportement réel des `VectorForce` en Server Authority ;
- l'implémentation des roues dans le modèle Racing officiel en Server Authority, jamais inspectée.

Enfin, rien ne distingue les versions Legacy et Enhanced de GTA V. FiveM tourne sur des builds Legacy, alors que les mesures de Broughy sont faites sur Expanded & Enhanced.

## Conclusion

Le point central est que GTA V n'est pas une simulation de véhicule au sens physique : c'est un **modèle à forces spécifiques et à régime normalisé**, dont plusieurs équations sont presque fermées. Avec quatre nombres de handling.meta (vitesse plate, force motrice, traînée, nombre de rapports), on prédit la vitesse de pointe mesurée de la Blista à 0,1 km/h près. Cela inverse l'ordre de travail habituel. Il faut d'abord valider le moteur, la boîte et la traînée, qui sont déterminés et vérifiables tout de suite, et seulement ensuite ouvrir le chantier du pneu, où se concentre l'incertitude. Exprimer toute la simulation en m/s² et multiplier par `AssemblyMass` à la frontière a aussi un effet de bord précieux : la conduite devient immunisée contre les masses parfois fantaisistes des modèles convertis.

Sur la fidélité, le facteur limitant n'est plus Roblox. `BindToSimulation` a supprimé la dépendance aux FPS qui avait fait échouer tous les châssis raycast communautaires. Le facteur limitant, c'est l'absence de données sur la loi pneu et la loi de suspension de GTA V. Le chemin critique est donc une **campagne de mesures FiveM instrumentée**, avec les natives par roue et des traces rejouées. Les litiges de la communauté (pic à la moitié ou à la totalité de l'angle latéral, sens du biais d'anti-roulis, échelle du « g ») ne doivent pas être tranchés à l'avance : il faut les exposer comme paramètres et les régler sur ces traces.

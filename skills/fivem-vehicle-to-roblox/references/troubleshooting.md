# Dépannage

| Symptôme | Cause probable | Correction |
|---|---|---|
| `code 2 : ressources binaires… gta-extract indisponible` | pas de SDK .NET 8 | installer .NET 8 (`winget install Microsoft.DotNet.SDK.8`, `sudo apt install dotnet-sdk-8.0`) puis relancer ; ou export XML via CodeWalker |
| `gta-extract : RPF illisible` | `dlc.rpf` chiffré NG | l'ouvrir dans OpenIV, extraire le dossier, zipper, relancer |
| `conversion XML vide` sur un `.awc` | AWC chiffré (son du jeu) | ignorer (son synthétisé) ou fournir des .wav |
| Setup : « pièce de référence introuvable » | l'importeur a renommé les MeshParts | ré-importer sans fusion de meshes ; vérifier que les noms des MeshParts = noms des nœuds du GLB |
| Setup : « recalage imprécis / miroir » | option d'axe de l'importeur modifiée | ré-importer avec les options par défaut |
| Véhicule énorme / minuscule | échelle de jeu différente | relancer avec `--studs-per-meter` (ex. 3.0 ou 4.5) |
| Roues mal orientées | os de roue tourné dans le modèle | régler `VehicleConfig.Wheels[...]` ou signaler ; la rotation se fait autour de l'axe X de la racine |
| Portière qui s'ouvre vers l'intérieur / à l'envers (élytres, papillon) | heuristique de sens | modifier `VehicleConfig.Hinges[os].Axis` (inverser le signe) / `OpenAngle` |
| Couleurs grises / blanches | textures partagées `vehshare` absentes | normal : couleur unie ; `Custom.SetColor` pour ajuster |
| Phares qui n'éclairent pas | `Headlights = 0` | touche H ; vérifier `Light_headlight_*` sous `VehicleRoot` |
| Pas de son | SoundId vides | uploader `sounds/` puis `--sound-ids`, ou renseigner `SoundId` (attribut `SourceFile`) |
| Moteur trop « synthétique » | son vanilla non fourni | placer des boucles .wav (ralenti / régimes) dans le zip et relancer |
| Trop de pièces / lag | modèle très détaillé | `--lod med`, ou `--max-tris` plus grand n'aide pas (limite Roblox) |
| Mod visible en permanence | `Mod_<Slot>` ≠ 0 ou Refresh non appelé | `Custom.SetMod(car, slot, 0)` côté serveur |

## Ressources du jeu de base (textures partagées, son vanilla)

| Symptôme | Cause | Correctif |
|---|---|---|
| `report.md` : « N texture(s) absente(s) du pack (souvent partagées avec le jeu…) » | le serveur d'assets GTA V n'était pas joignable | lancer `tools/gta-asset-server/start-server.bat` sur le PC et le déclarer dans vibestarter (*My MCP servers* → `http://127.0.0.1:27300/mcp`), puis relancer |
| « N texture(s) introuvables même dans GTA V » | textures propres au mod (badges, emblèmes, compteurs) absentes du zip, ou cibles de rendu `script_rt_*` créées à l'exécution | normal : couleur moyenne utilisée. Demander les `.ytd` manquants à l'auteur du mod si le visuel compte |
| « Son moteur synthétisé » alors que le serveur tourne | `audioNameHash` inconnu du jeu (son custom d'un autre mod) | fournir des `.wav` de boucles moteur dans le zip |
| Textures/son figés après une mise à jour du jeu | cache local | relancer avec `--retry-gamefiles` |
| Le serveur tourne mais la VM ne le voit pas | connecteur MCP absent, ou serveur démarré après la VM | vérifier *My MCP servers* ; `curl http://127.0.0.1:27300/health` sur le PC |
| Conversion hors ligne volontaire | — | `--no-game-server` |

Avec le serveur, le klaxon et les trois tonalités de sirène viennent aussi du jeu. Si le
rapport indique « Klaxon : synthétisé » ou « Sirènes : synthétisées » alors que le serveur
tourne, c'est que les flux trouvés avaient une durée invraisemblable (ils sont alors écartés)
ou que le véhicule n'a pas de sirène dans le jeu. Pour comprendre un cas précis, lancer la
commande de diagnostic `audio_chain` : elle montre la chaîne entière, le `.rel` qui a gagné
et la durée de chaque flux. Voir `references/game-assets.md`.

## Automatisation dans Studio (mesuré le 2026-11-10, voir docs/studio-import-tests.md)

| Symptôme | Cause | Correction |
|---|---|---|
| « You must install .NET to run this application » alors que `dotnet` est installé dans `~/.dotnet` | l'exécutable natif de gta-extract ne cherche pas `~/.dotnet` | corrigé : le convertisseur lance `dotnet gta-extract.dll` (et règle `DOTNET_ROOT`) |
| MeshPart créée par EditableMesh vide après sauvegarde | contenu `Object` non sérialisé | ne pas utiliser EditableMesh pour le véhicule : upload du GLB + `insert_asset` |
| `loadstring() is not available` | appel côté client en Play | utiliser le module `Verify` (`require(module)(opts)`) ; `loadstring` seulement en Edit / serveur |
| Correctif du runtime sans effet en Edit | `require` garde la première version de la session | requérir une copie (`module:Clone()`) ; en Play, `require` est neuf |
| Porte / lumière « ne bouge pas » dans un test | Studio sans focus : `RenderStepped` figé | Verify compte les images et signale « rendu figé » ; relancer le groupe |
| Véhicule qui flotte après import | hauteur d'insertion conservée | le Setup pose le véhicule au sol (`_G.F2R_NO_GROUND = true` pour l'éviter) |
| Restaurer une sauvegarde laisse les néons allumés | `Custom.Apply` ne réinitialisait pas les clés absentes | corrigé : néons, xénons, mods, extras, vitres, perfs reviennent à l'origine |
| Centaines de « Failed to load sound … no permission » | sons d'autres véhicules de la place | sans rapport : lire le rapport de Verify |
| `CollisionFidelity` d'une MeshPart reste `Default` après l'avoir écrite par script | propriété non modifiable par script (ignorée sans erreur, mesuré) | `AssetService:CreateMeshPartAsync(part.MeshContent, {CollisionFidelity = …})` puis `part:ApplyMesh(tmp)` : taille et position gardées |
| Véhicule inerte en jeu (ni lumières, ni portes, ni sons) alors que tout est installé | `FiveMVehiclesClient` attachait le rendu une seule fois, avant la fin de la réplication | corrigé (attente de `game.Loaded` + nouvelles tentatives) ; Verify contrôle « rendu attaché par FiveMVehiclesClient » |
| Joueur qui flotte au-dessus du capot / hitbox en boîte | collision non reprise du .yft | collision GTA (automatique) ; si le .yft n'a pas de `Physics`, la boîte reste (avertissement du rapport) |
| On ne peut pas monter en marchant | le siège est dans le volume de collision | invite F par siège (`VehicleAccess.Enter`), jamais de marche jusqu'au siège |
| À la descente le joueur revient sur son siège | téléportation faite par le serveur seul : le client, propriétaire de son personnage, l'écrase | le serveur envoie `PlaceAt` au client qui se pose lui-même (et pose aussi côté serveur) |
| Joueur poussé / véhicule qui glisse juste après la descente | la portière encore ouverte (animée côté client) balaie le joueur | occupant sans collision avec le véhicule jusqu'à la fermeture de la portière (`OccupantGrace`) |
| Descente refusée des deux côtés en pente | boîte de test d'espace libre qui touche le sol incliné | la boîte commence 0,6 stud au-dessus du sol (tolère ~15°) |
| Invites des portières, de montée ou sons très loin du véhicule | `Attachment.WorldPosition` réglé avant `Parent` (devient une position locale) | parent d'abord ; Verify `access` contrôle tous les attachments |
| Tête de l'avatar dans le pavillon | véhicule à l'échelle réelle, avatar Roblox grand | échelle conseillée par Verify `seats_play` |
| Véhicule conduit replacé par le serveur qui revient à son ancienne place, `DriveViolations` +1 | `PivotTo` serveur : le client propriétaire renvoie l'ancienne position, le contrôle de vraisemblance voit un saut | `VehicleAccess.Teleport` / `PlaceOnGround` (ancrage 0,25 s + attribut `TeleportGraceUntil`) |
| Tolérance de téléport sans effet quand le déplacement vient d'`execute_luau` serveur | ce code a son propre exemplaire du module (tables séparées) | tolérance portée par un attribut du modèle (corrigé) |
| Véhicule rattrapé d'une chute puis projeté en l'air | une pièce ancrée garde sa vitesse et la reprend au désancrage | vitesses annulées avant l'ancrage et pendant (corrigé) |
| Véhicule qui repart seul après une remise | roues encore lancées dans la simulation | `VehicleDynamics.reset` dès que `VehicleRoot` est ancré (corrigé) |
| Véhicule disparu après une sortie de carte | pièces détruites sous `FallenPartsDestroyHeight` | remise automatique (`VoidMargin`, `VoidRecoveries`) ; Verify `void_play` |
| Bordure : l'avant décolle à basse vitesse | amortisseur sans plafond (5 m/s en une image) | `DampVMax` (1 m/s par défaut) |
| Marche de trottoir : caisse renvoyée, roues en l'air à 60 km/h, cabrage qui monte avec la vitesse | la roue monte la marche en une image et dépasse la course restante : la butée `BumpK` frappe | `BumpK` 0 (défaut depuis le 2026-11-12) ; banc : `TestTrack` voie `curb` |
| Roulis presque nul en virage (0,2 °/g) | forces latérales appliquées à la hauteur du centre de roulis, bras de levier de 0,05–0,15 m | `RollCentreScale` (0 → ≈ 1 °/g, voir `calibration/m422/README.md` avant de l'adopter) |
| Accélération molle (0,26 g), patinage bloqué loin du pic | inertie de roue trop forte (`IwRel` 1,5) | `IwRel` 0,25 et 8 sous-pas |
| Boîte qui pompe 1 ↔ 2 | après la montée, le régime tombe sous le seuil de descente | hystérésis : descente seulement si le rapport inférieur resterait sous 0,85 × seuil de montée |
| Ligne droite volant lâché : virage de très grand rayon (~3,7 km) | légère dissymétrie (conducteur assis d'un côté) | normal ; le banc tient sa ligne (`Bench.setLine`) |
| Essai long coupé, résultat perdu | `execute_luau` coupé vers 14 s ; Play arrêté après 3 min sans appel Studio | essais en `task.spawn`, relevés toutes les ~10 s ; ne pas laisser le Play sans appel |
| Module mis à jour sans effet pendant un Play | le Play tourne sur une copie de la place | relancer le Play |
| Essai de conduite : véhicule qui tombe de la plaque ou bute sur un autre véhicule | piste trop courte, décor sur le passage | `TestTrack.lua` : plaque dédiée loin de la carte |
| Manette / tactile : aucun effet avec `player_input` | VirtualInput n'envoie ni axe de gâchette ni toucher | essai manuel |

## Étrier de frein immobile pendant que la roue braque (ou qui traverse la jante)

- **Cause** (corrigée le 2026-11-11) : l'étrier est porté par l'os `hub_*`, ignoré jusque-là : il était
  soudé à la carrosserie et restait droit quand la roue braquait ou montait.
- **Correction** : les os `hub_*` et `suspension_*` sont des pivots (`CONFIG.WheelFollowers`), animés par
  `VehicleRuntime` à partir de leur roue (braquage autour de l'axe de la roue pour `hub_*`, course de
  suspension pour les deux, jamais la rotation de la roue). Reconvertir et réinstaller le véhicule.
- **Contrôle** : Verify Play client, groupe `joints` : « hub_lf braque avec wheel_lf sans tourner ».

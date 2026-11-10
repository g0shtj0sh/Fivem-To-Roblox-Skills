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

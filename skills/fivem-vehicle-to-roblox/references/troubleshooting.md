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

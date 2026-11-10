# Serveur d'assets GTA V (côté PC)

Beaucoup de véhicules FiveM réutilisent des ressources du **jeu de base** sans les inclure
dans le zip : textures partagées (`vehshare.ytd`, `txdRelationships`, `vehicle_generic_*`)
et son moteur « vanilla » désigné par `audioNameHash` (ex. `CARBONIZZARE`).

Ce petit serveur tourne sur le PC où GTA V est installé et les fournit au pipeline, qui
tourne dans la VM. Sans lui, le skill met une couleur unie à la place des textures et
synthétise le moteur.

## Démarrage

```bat
start-server.bat
```

Le script détecte GTA V, installe Pillow/numpy si besoin, compile `gta-extract` la première
fois, puis écoute sur `http://127.0.0.1:27300/mcp`.

Options : `start-server.bat [port] ["chemin\vers\GTA V"]`.

Détection automatique testée : registre Rockstar, bibliothèques Steam
(`libraryfolders.vdf`), manifestes Epic, chemins usuels (`Program Files\Rockstar Games`,
`D:\Jeux\Rockstar Games`…). L'édition **Enhanced** (gen9) est préférée si les deux sont
présentes. Le dossier retenu est mémorisé dans `~/.fivem2roblox/gta-server.json`.

Prérequis : Python 3.10+, SDK .NET 8+, git (les deux derniers seulement pour la première
compilation de `gta-extract`).

## Branchement dans vibestarter

Une seule fois : **Paramètres › My MCP servers › ajouter un serveur HTTP** avec l'URL

```
http://127.0.0.1:27300/mcp
```

Le chemin n'a pas d'importance (`/mcp`, `/mc`, `/` fonctionnent). vibestarter relaie ce
serveur dans la VM ; `scripts/f2r/gamelib.py` le trouve seul, sans que l'agent ait besoin de
l'avoir dans son contexte. Voir `docs/transport-tests.md` pour le pourquoi de ce canal.

Vérification rapide depuis le PC :

```bat
curl http://127.0.0.1:27300/health
```

## Outils MCP exposés

| Outil | Rôle |
|---|---|
| `gta_status` | dossier du jeu, nombre d'entrées RPF, taille des morceaux |
| `gta_find_textures` | dit lesquelles existent, sans rien transférer |
| `gta_prepare_textures` | extrait → PNG ≤ 1024 px (puissance de 2, alpha conservé) → manifeste |
| `gta_prepare_audio` | suit `audioNameHash` → dat151 → dat54 → AWC → `.wav` |
| `gta_chunk` | un morceau d'un fichier du lot, en base64 |
| `gta_build_index` | index complet des textures véhicules (~30 s, optionnel) |

Chaque lot renvoie, par fichier, sa taille, son **SHA-256** et son nombre de morceaux ;
la VM vérifie l'empreinte après réassemblage et jette le fichier en cas d'écart.

## Comment le son vanilla est retrouvé

```
audioNameHash (ex. CARBONIZZARE)
  └─ Dat151CarAudioSettings                  (game.dat151.rel)
       ├─ GranularEngine
       │    └─ Dat151GranularEngineAudioSettings
       │         ├─ EngineAccel  ─┐
       │         └─ ExhaustAccel ─┴─ Dat54GranularSound   (sounds.dat54.rel)
       │                               └─ Channel0..5 : ContainerName + FileName
       │                                    └─ x64/audio/sfx/<conteneur>.rpf/<nom>.awc
       │                                         └─ engine_accel.wav, engine_decel.wav,
       │                                            engine_idle.wav, exhaust_*.wav
       └─ HornSounds / SirenSounds (voir limites)
```

Les six flux moteur/échappement sont exactement ceux que `scripts/f2r/audio.py` sait
découper en boucles (`pick_stream` cherche `engine_accel`, `decel`, `idle`…).

## Sécurité

* Écoute sur **127.0.0.1 uniquement**, jamais sur le réseau local.
* GTA V est ouvert en **lecture seule** ; rien n'est écrit, déplacé ou supprimé dans le jeu.
* Seules des textures de dictionnaires de véhicules et des sons référencés par un
  `audioNameHash` de véhicule sont servis — pas d'accès à un chemin arbitraire du jeu.
* `gta_chunk` n'accepte qu'un identifiant de lot sans séparateur de chemin, et le fichier
  demandé doit figurer dans le manifeste de ce lot.
* Les lots sont mis en cache sous `%LOCALAPPDATA%\fivem2roblox\asset-server\bundles`.
* Rien de ce qui est extrait du jeu ne doit être commité ni redistribué : ce sont des
  ressources Rockstar, destinées à ton usage.

## Limites connues

* **Klaxon et sirène ne sont pas fiables.** La chaîne est bien suivie jusqu'aux sons
  feuilles, mais les `.rel` de tous les DLC sont chargés sans respecter l'ordre de priorité
  des DLC (défaut documenté dans `GameFileCache` de CodeWalker : *« DLC orders won't be
  correct so likely will select wrong versions of things »*), et les flux obtenus ne
  correspondent pas toujours au bon AWC. Le pipeline garde donc son klaxon et ses sirènes
  synthétisés, qui fonctionnent. Le **moteur**, lui, est validé.
* Les textures purement « mod » (badges, emblèmes, compteurs propres au véhicule) absentes
  du zip ne sont pas dans le jeu de base : elles resteront manquantes, c'est normal.
* `script_rt_*` sont des cibles de rendu créées à l'exécution par le jeu : elles n'existent
  pas comme textures stockées.
* Le format BC7 n'est pas décompressé par CodeWalker ; dans ce cas le serveur tente d'abord
  Pillow sur le `.dds`, ce qui couvre la plupart des cas.

## Dépannage

| Symptôme | Cause / correctif |
|---|---|
| « GTA V introuvable » | lancer `start-server.bat 27300 "D:\chemin\vers\GTA V"`, ou définir `GTAV_FOLDER` |
| « bin\gta-extract.exe absent » | installer le SDK .NET 8 et git, puis relancer (compilation auto) |
| Le port 27300 est pris | `start-server.bat 27400` puis adapter l'URL du connecteur MCP |
| La VM ne voit rien | vérifier que le serveur tourne et que le connecteur MCP est bien déclaré ; `docs/transport-tests.md` |
| Textures introuvables | lancer une fois avec `--build-index` (index complet, ~30 s) |

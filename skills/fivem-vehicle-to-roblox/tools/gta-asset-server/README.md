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
| `gta_prepare_audio` | suit `audioNameHash` → dat151 → dat54 → AWC → `.wav` : moteur, klaxon, sirènes |
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
       ├─ Engine (véhicules sans moteur granulaire : camions, anciens modèles)
       │    └─ Dat151VehicleEngineAudioSettings
       │         └─ LowEngineLoop / HighEngineLoop / RevsOffLoop / LowExhaustLoop…
       ├─ HornSounds   ─┐  Dat54SoundHashList → MultitrackSound → WrapperSound
       └─ SirenSounds  ─┘  Dat54SoundSet → Randomized → VariableBlock → Envelope
                           → ParameterTransform → WrapperSound → Dat54SimpleSound
                                └─ ContainerName + FileName → .awc → .wav
```

Les six flux moteur/échappement sont exactement ceux que `scripts/f2r/audio.py` sait
découper en boucles (`pick_stream` cherche `engine_accel`, `decel`, `idle`…), et le klaxon
comme les sirènes sortent sous les noms attendus par le runtime Roblox : `horn`,
`siren_wail`, `siren_yelp`, `siren_priority`.

### Deux détails sans lesquels rien ne marche

**1. Ordre des DLC.** Les `.rel` audio existent en plusieurs versions (base, `update.rpf`,
puis chaque DLC). Les charger à plat fait gagner une version arbitraire. Le serveur passe
donc par `GameFileCache` de CodeWalker, qui lit `update/update.rpf/common/data/dlclist.xml`,
trie les `setup2.xml` par leur attribut `order`, et charge les `.rel` dans cet ordre : la
version la plus prioritaire écrase les précédentes. Effet mesuré : **177 813 → 35 582**
entrées dat151, et un véhicule du DLC 2026 (`polignus`) résolu depuis
`dlcpacks/mp2026_01/.../dlc26-1_game.dat151.rel` et non depuis une vieille version.
`gta-extract game-serve` expose `dlc_order` pour vérifier la liste (103 paquets ici).

**2. Les identifiants de flux AWC ne font que 29 bits.** `AwcStreamInfo.Read` fait
`Id = RawVal & 0x1FFFFFFF`, les 3 bits hauts servant au nombre de morceaux, alors que le
`FileName` d'un dat54 est un hash sur 32 bits. Comparer les deux directement échoue pour
tout flux dont le nom n'est pas dans la table de chaînes — c'est-à-dire presque tous les
klaxons et sirènes. Il faut masquer le hash avant la comparaison, et le fichier exporté par
CodeWalker s'appelle alors `0x` + l'identifiant **masqué** en hexadécimal.

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

## Diagnostic

`gta-extract game-serve` répond aussi à des commandes faites pour comprendre un cas qui
coince, sans lancer le jeu :

| Commande | Ce qu'elle montre |
|---|---|
| `audio_chain` | la chaîne complète d'un `audioNameHash`, maillon par maillon, avec le `.rel` qui a gagné, et (si `out` est fourni) le `.wav` et la durée de chaque feuille |
| `dlc_order` | la liste ordonnée des DLC telle que le jeu la voit |
| `list_car_audio` | quels véhicules sont définis par quel `.rel` (filtrable) |
| `find_stream` | pour un conteneur : tous les AWC candidats, et lequel contient le flux |
| `scan_stream` | balaye les AWC à la recherche d'un identifiant de flux |
| `list_awc_streams` | les identifiants de flux d'un AWC donné |

Exemple : `{"cmd":"audio_chain","audioName":"POLICE","out":"C:/tmp/pol","props":true}`.

## Limites connues

* **Le classement des sirènes vient du jeu**, pas d'une heuristique : `SirenSounds` pointe
  sur un `Dat54SoundSet` dont chaque entrée porte un `ScriptName`, c'est-à-dire un
  emplacement nommé (`Main`, `Fast`, `Slow`, `Warning`, `Horn`…). Ces emplacements sont les
  mêmes pour tous les véhicules d'urgence. On en tire `wail` ← `Main`, `yelp` ← `Fast`,
  `priority` ← `Warning`, avec des replis déclarés. Deux emplacements sur neuf n'ont pas pu
  être nommés et sont référencés par leur hash ; ils ne servent pas à la correspondance.
  Reste un repli par durée si un emplacement est vide ou invraisemblable, et un flux hors
  bornes (klaxon 0,08–5 s, sirène 0,2–20 s) est écarté au profit de la synthèse.
* L'emplacement `Horn` du jeu de sirènes est un bip de 0,08 s, **pas** un klaxon : le klaxon
  du véhicule vient de `HornSounds`, pas de là.
* **Véhicules sans moteur granulaire** (camions, modèles anciens : `GranularEngine = 0`) :
  le son vient de `Dat151VehicleEngineAudioSettings`, c'est-à-dire des boucles bas et haut
  régime, pas d'un balayage d'accélération. Les boucles produites sont donc moins nuancées
  que pour un véhicule granulaire. Le manifeste indique `engine_kind: "loops"`.
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

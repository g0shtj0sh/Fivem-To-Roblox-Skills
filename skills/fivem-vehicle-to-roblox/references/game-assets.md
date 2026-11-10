# Ressources du jeu de base : textures partagées et son vanilla

Un pack de véhicule FiveM ne contient presque jamais tout. Deux manques reviennent sans arrêt :

1. **Textures partagées.** Le `.yft` référence `vehicle_generic_detail2`, `plate01`,
   `vehicle_generic_tyrewall_normal`… qui vivent dans `vehshare.ytd` du jeu, pas dans le zip.
   `vehicles.meta` le dit explicitement via `txdRelationships` (`<parent>vehshare</parent>`).
2. **Son vanilla.** `vehicles.meta` donne `<audioNameHash>CARBONIZZARE</audioNameHash>` :
   le véhicule emprunte le son d'un véhicule du jeu, et aucun `.awc` n'est fourni.

Sans accès au jeu, le pipeline met une couleur moyenne et synthétise le moteur. Avec le
**serveur d'assets** (`tools/gta-asset-server/`, à lancer sur le PC où GTA V est installé),
il utilise les vraies ressources.

## Qui fait quoi

```
      VM Linux (vibestarter)                        PC Windows
  ┌──────────────────────────────┐           ┌──────────────────────────────┐
  │ convert_vehicle.py           │           │ start-server.bat             │
  │   └─ f2r/gamelib.py  ────────┼── MCP ───▶│   server.py (127.0.0.1)      │
  │        cache + SHA-256       │           │     └─ gta-extract game-serve│
  │                              │           │          └─ CodeWalker.Core  │
  └──────────────────────────────┘           │               └─ GTA V (RO)  │
                                             └──────────────────────────────┘
```

Le canal est un **connecteur MCP de vibestarter** : c'est la seule voie VM → PC fiable
(gvproxy n'autorise que les deux ports de vibestarter). `gamelib.py` lance lui-même
`~/.vibestarter/mcp-stub.cjs`, donc ça marche depuis Claude Code, Codex ou un simple script.
Les mesures et les options écartées sont dans [`docs/transport-tests.md`](../../../docs/transport-tests.md).

## Déroulé d'une conversion

1. `GameAssets.discover()` cherche un serveur : `F2R_GAME_SERVER_URL` d'abord, puis les
   connecteurs MCP déclarés dans `~/.claude.json` et `~/.codex/config.toml`. Un serveur est
   reconnu s'il expose l'outil `gta_prepare_textures`. Rien trouvé → `None`, et le pipeline
   continue exactement comme avant.
2. **Avant** de construire les matériaux, `collect_missing_textures()` liste les noms
   référencés par les pièces (`tex_diffuse`, `tex_normal`, `tex_livery`) absents des sources
   locales. On ne demande donc au PC que le strict nécessaire.
3. `gta_prepare_textures` reçoit ces noms plus deux indices : le `txdName` du véhicule et ses
   `dependentTxds`. Le PC cherche dans l'ordre : dictionnaires indiqués → `<véhicule>.ytd` →
   préfixe du nom de texture → `vehshare*.ytd`, sans scan complet. Les DDS trouvés sont
   convertis en **PNG ≤ 1024 px**, puissance de 2, **alpha conservé** : c'est la VM qui
   décidera du rôle (couleur ou normal map), donc la conversion reste neutre.
4. Les PNG arrivent par morceaux de 6 Mo, vérifiés au **SHA-256**, et sont injectés dans les
   sources de `TextureStore`. Le reste du pipeline les traite comme s'ils venaient du zip —
   y compris la détection des livrées (`store.siblings`).
5. Si le pack n'a aucun `.awc`, `gta_prepare_audio` suit `audioNameHash` et renvoie six
   `.wav` : `engine_accel`, `engine_decel`, `engine_idle`, `exhaust_accel`, `exhaust_decel`,
   `exhaust_idle`. Ces noms sont exactement ceux que `pick_stream()` de `f2r/audio.py`
   reconnaît : la découpe en boucles par régime se fait ensuite sans changement.

## Chaîne audio dans les fichiers du jeu

```
audioNameHash
  └─ Dat151CarAudioSettings                       game.dat151.rel
       ├─ GranularEngine
       │    └─ Dat151GranularEngineAudioSettings
       │         ├─ EngineAccel ─┐
       │         └─ ExhaustAccel ┴─ Dat54GranularSound     sounds.dat54.rel
       │                              └─ Channel0..5 : ContainerName + FileName
       │                                   └─ x64/audio/sfx/<conteneur>.rpf/<nom>.awc
       └─ HornSounds, SirenSounds, StartupRevs
```

Détail qui coûte du temps si on l'ignore : le `ContainerName` du dat54 vaut par exemple
`streamed_vehicles_granular/supercar_4_eur_v8`, alors que le chemin réel dans les RPF est
`x64/audio/sfx/streamed_vehicles_granular.rpf/supercar_4_eur_v8.awc`. Le segment `.rpf`
**ne fait pas partie du hash** : il faut le retirer avant de calculer le hash Jenkins.

## Cache et reprise

* Textures : `~/.cache/fivem2roblox/textures/<max_size>/<nom>.png`
* Sons : `~/.cache/fivem2roblox/audio/<audioname>/<flux>.wav`
* Textures déjà cherchées en vain : `~/.cache/fivem2roblox/missing_textures.json`
  (évite de redemander à chaque conversion)
* `--retry-gamefiles` ignore ces caches. `F2R_CACHE_DIR` déplace le cache.

## Variables d'environnement

| Variable | Effet |
|---|---|
| `F2R_GAME_SERVER_URL` | URL HTTP du serveur, court-circuite la découverte MCP |
| `F2R_GAME_CONNECTOR` | nom (partiel) du connecteur MCP à préférer |
| `F2R_NO_GAME_SERVER` | désactive complètement la récupération |
| `F2R_GAME_TIMEOUT` | délai par appel, en secondes (défaut 240) |
| `F2R_CACHE_DIR` | emplacement du cache |

## Ce qui marche, ce qui ne marche pas

Validé sur GTA V **Enhanced** 1.0.1158.16 avec un véhicule FiveM réel
(`ferrari_f430scuderia`, `audioNameHash = CARBONIZZARE`) : **7 textures reprises du jeu** et
**le vrai son moteur découpé en boucles**.

* ✅ textures de `vehshare*.ytd` et des dictionnaires de véhicules, y compris les formats que
  Pillow refuse (A8, L8…) grâce à un décodage de repli par CodeWalker ;
* ✅ moteur et échappement (accélération, décélération, ralenti) ;
* ❌ **klaxon et sirène** : la chaîne est suivie jusqu'aux sons feuilles, mais les `.rel` de
  tous les DLC sont chargés sans respecter leur ordre de priorité (défaut connu de
  `GameFileCache` dans CodeWalker) et les flux obtenus ne pointent pas toujours sur le bon
  AWC. Le pipeline garde donc son klaxon et ses sirènes synthétisés ;
* ❌ textures propres au mod (badges, emblèmes, compteurs du véhicule) : elles ne sont pas
  dans le jeu de base, rien à récupérer ;
* ❌ `script_rt_*` : cibles de rendu créées à l'exécution, pas des textures stockées.

> Les ressources extraites appartiennent à Rockstar Games. Elles servent à ta conversion
> locale ; ne les commite pas et ne les redistribue pas.

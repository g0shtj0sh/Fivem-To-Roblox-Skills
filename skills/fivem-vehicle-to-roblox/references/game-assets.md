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
5. Si le pack n'a aucun `.awc`, `gta_prepare_audio` suit `audioNameHash` et renvoie les
   `.wav` du jeu : `engine_accel`, `engine_decel`, `engine_idle`, `exhaust_accel`,
   `exhaust_decel`, `exhaust_idle`, plus `horn` et, pour un véhicule d'urgence,
   `siren_wail`, `siren_yelp`, `siren_priority`. Ces noms sont exactement ceux que
   `pick_stream()` de `f2r/audio.py` reconnaît et ceux que le runtime Roblox cherche
   (`Sounds.Horn`, `Sounds.Siren_<kind>`) : la découpe en boucles par régime et le branchement
   des sirènes se font ensuite sans changement.

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
       ├─ Engine  (si GranularEngine = 0 : camions, modèles anciens)
       │    └─ Dat151VehicleEngineAudioSettings
       │         └─ LowEngineLoop / HighEngineLoop / RevsOffLoop / Low+HighExhaustLoop
       ├─ HornSounds
       │    └─ Dat54SoundHashList → MultitrackSound → WrapperSound → Dat54SimpleSound
       └─ SirenSounds
            └─ Dat54SoundSet → RandomizedSound → VariableBlockSound → EnvelopeSound
                 → ParameterTransformSound → WrapperSound → Dat54SimpleSound
```

Les types intermédiaires sont nombreux et n'ont aucune interface commune : le parcours suit
donc, par réflexion, tous les tableaux `MetaHash[]` (`ChildSoundsHashes`, `SoundHashes`…) et
tout champ `MetaHash` qui désigne lui-même un son connu, jusqu'aux `Dat54SimpleSound` qui
portent le couple `ContainerName` + `FileName`.

### Trois pièges qui coûtent cher

**Le `.rpf` ne fait pas partie du hash du conteneur.** Le `ContainerName` du dat54 vaut par
exemple `streamed_vehicles_granular/supercar_4_eur_v8`, alors que le chemin réel est
`x64/audio/sfx/streamed_vehicles_granular.rpf/supercar_4_eur_v8.awc` : il faut retirer les
segments d'archive avant de calculer le hash Jenkins.

**Les identifiants de flux AWC ne font que 29 bits.** `AwcStreamInfo.Read` applique
`Id = RawVal & 0x1FFFFFFF` (les 3 bits hauts comptent les morceaux), alors que le `FileName`
d'un dat54 est un hash 32 bits. Sans masquage, tout flux dont le nom n'est pas dans la table
de chaînes reste introuvable — c'est le cas de presque tous les klaxons et sirènes, et c'était
la vraie cause de leur échec. Le fichier exporté par CodeWalker porte le nom
`0x` + identifiant **masqué**.

**Les `.rel` doivent être chargés dans l'ordre des DLC.** Sinon une version ancienne d'une
entrée peut gagner. On délègue à `GameFileCache` de CodeWalker, qui lit `dlclist.xml`, trie
les `setup2.xml` par `order` et charge dans cet ordre. Mesure : 177 813 → 35 582 entrées
dat151 (les doublons sont correctement arbitrés au lieu d'être empilés).

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
* ✅ **klaxon** : résolu pour les 9 véhicules testés (4 à 8 flux candidats chacun, le plus
  long étant retenu ; 0,10 à 1,19 s à 32 kHz) ;
* ✅ **sirènes** : les trois tonalités (`wail`, `yelp`, `priority`) sont livrées pour
  POLICE, POLICE2, SHERIFF, AMBULANCE, FIRETRUK et POLIGNUS (DLC 2026) ;
* ✅ le classement wail / yelp / priority vient des **emplacements nommés du
  `Dat54SoundSet`** du jeu, pas d'une heuristique (voir plus bas) ;
* ⚠️ véhicules sans moteur granulaire : boucles bas/haut régime au lieu d'un balayage ;
* ❌ textures propres au mod (badges, emblèmes, compteurs du véhicule) : elles ne sont pas
  dans le jeu de base, rien à récupérer ;
* ❌ `script_rt_*` : cibles de rendu créées à l'exécution, pas des textures stockées.

## Comment les sirènes sont classées

Le runtime Roblox attend `Sounds.Siren_wail`, `Siren_yelp` et `Siren_priority`. La bonne
source n'est ni le nom du flux (presque toujours un hash inconnu) ni sa durée, mais le
**`Dat54SoundSet`** vers lequel pointe `SirenSounds` : chacune de ses entrées est un
`Dat54SoundSetItem` qui porte un **`ScriptName`**, c'est-à-dire l'emplacement nommé dans
lequel le jeu lui-même range ce son.

Piège : `CodeWalker` recopie bien ces entrées dans `SoundSets[]`, mais il remplit aussi
`ChildSoundsHashes` avec les seuls enfants. Un parcours générique passe donc par
`ChildSoundsHashes` et **perd le `ScriptName`** — le seul libellé fiable de toute la chaîne.
Il faut lire `SoundSets[]` explicitement. Et chaque emplacement doit être résolu avec son
propre jeu de « déjà vu » : plusieurs emplacements partagent des sous-arbres, et un ensemble
partagé masque les feuilles des emplacements suivants.

Les neuf emplacements sont **identiques pour tous les véhicules d'urgence** (vérifié sur
POLICE, POLICE2, SHERIFF, AMBULANCE, FIRETRUK et POLIGNUS du DLC 2026) ; seuls les sons
enfants changent. Quatre noms ont pu être retrouvés par hash Jenkins, deux autres par
composition, deux restent identifiés par leur hash :

| Emplacement | Hash | Contenu observé |
|---|---|---|
| `Main` | 1305684053 | **la sirène propre au véhicule** : 6,34 s (POLICE), 3,77 s (AMBULANCE), 6,33 s (FIRETRUK), 4,55 s (POLIGNUS) |
| `Fast` | 1689781374 | tonalité rapide du véhicule : 0,29–0,35 s |
| `Slow` | 3303937151 | variante lente, sert de repli |
| `Warning` | 3911129148 | hi-lo court, identique partout : 0,29 s |
| `Horn` | 1043621919 | bip de sirène (0,08 s), **pas** le klaxon du véhicule |
| `Horn_Fast` / `Horn_Slow` | 3410657623 / 3642518543 | combinaisons génériques |
| `Blip` | — | bip court |
| `Shared` | 1410818973 | identique pour tous les véhicules |

Correspondance appliquée, par ordre de préférence :

| Tonalité Roblox | Emplacement | Repli |
|---|---|---|
| `wail` | `Main` | `Slow` |
| `yelp` | `Fast` | `Slow` |
| `priority` | `Warning` | `Horn_Fast` |

Chaque candidat doit en plus tenir dans une fenêtre de durée plausible (`wail` ≥ 1,5 s ;
`yelp` et `priority` entre 0,15 et 2,5 s) et ne pas reprendre un flux déjà attribué. Si un
emplacement est vide ou invraisemblable, on retombe sur l'ordre des durées, puis sur la
synthèse. Un flux hors bornes (klaxon 0,08–5 s, sirène 0,2–20 s) est écarté : mieux vaut une
sirène synthétique correcte qu'un bruit de 20 ms.

Résultat : les six véhicules d'urgence testés obtiennent leurs trois tonalités, et chacun
reçoit **sa** sirène, pas une sirène générique.

## Vérifier sans lancer GTA V

```bash
# chaine complete + sources .rel gagnantes + durees des .wav
echo '{"cmd":"audio_chain","audioName":"POLICE","out":"/tmp/pol","props":true}' \
  | tools/gta-extract/bin/gta-extract game-serve -g "<dossier GTA>" --gen9
```

Autres commandes : `dlc_order`, `list_car_audio`, `find_stream`, `scan_stream`,
`list_awc_streams`. Détails dans `tools/gta-asset-server/README.md`.

> Les ressources extraites appartiennent à Rockstar Games. Elles servent à ta conversion
> locale ; ne les commite pas et ne les redistribue pas.

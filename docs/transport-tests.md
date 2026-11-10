# Transport PC → VM vibestarter : options testées et choix retenu

Le pipeline `fivem-vehicle-to-roblox` tourne dans la **VM Linux de vibestarter**, alors que
l'installation de GTA V est sur le **PC Windows hôte**. Il faut donc un canal pour que la VM
récupère textures et sons du jeu de base. Ce document liste ce qui a été mesuré, pourquoi
l'option retenue l'a été, et ce qui n'a pas pu être vérifié.

Mesures faites le 2026-11-10 sur : Windows 11 Pro 26200, vibestarter (QEMU + gvproxy),
GTA V **Enhanced** 1.0.1158.16 (`D:\Jeux\Rockstar Games\Grand Theft Auto V Enhanced`),
.NET SDK 8.0.420, Python 3.14.2.

## Comment la VM est réellement reliée au PC

`vibe-starter.exe` lance QEMU **sans pile réseau propre** :

```
-netdev socket,id=net0,connect=127.0.0.1:43939 -device virtio-net-pci,...
```

tout le réseau passe donc par **gvproxy** (gvisor-tap-vsock), configuré par
`D:\VibeStarter\vm\gvproxy.yaml` :

```yaml
stack:
  subnet: '10.0.2.0/24'
  gatewayIP: '10.0.2.3'
  deviceIP: '10.0.2.15'      # la VM
  hostIP: '10.0.2.2'         # le PC
  nat:
    '10.0.2.2': '127.0.0.1'
  allowedHostPorts:          # <= LE point clé
    - 30422
    - 30423
  forwards:
    '127.0.0.1:43938': '10.0.2.15:22'
    '127.0.0.1:34872': '10.0.2.15:34872'
    '127.0.0.1:34880': '10.0.2.15:34880'
    ...
```

**C'est l'explication du blocage observé** : la VM *peut* joindre le PC via `10.0.2.2`
(qui est NATé vers `127.0.0.1`), mais `allowedHostPorts` n'autorise que **30422 et 30423**,
occupés par vibe-starter lui-même. Tout autre port renvoie « connexion refusée ».
Ce n'est pas un pare-feu : c'est une liste blanche de la passerelle.

Autre fait important : **`gvproxy.yaml` est régénéré à chaque démarrage de la VM**
(horodatage identique à celui du boot). Toute modification manuelle est donc perdue.

## Les options, une par une

### 1. SSH / SCP du PC vers la VM — **écarté**

| Point | Mesure |
|---|---|
| Accessible ? | oui, `127.0.0.1:43938` → `10.0.2.15:22` |
| Bannière | `SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.16` |
| Méthodes d'auth | `publickey` **uniquement** (`Permission denied (publickey)`) |
| Clé privée sur disque ? | **non trouvée** |

La clé publique de l'hôte est injectée dans la ligne de commande du noyau
(`vibestarter.authkey=…`, un `ssh-ed25519 … vibestarter-host` encodé en base64) : elle est
donc **générée à chaque démarrage** et la clé privée reste en mémoire de `vibe-starter.exe`.
Aucun fichier de clé n'existe sous `%APPDATA%`, `%LOCALAPPDATA%\Vibe Starter` ni
`D:\VibeStarter` (un marqueur `agent-credentials-removed.marker` va dans ce sens).

Conséquence : impossible de s'authentifier depuis le PC sans détourner un secret de
vibestarter. Et même si on y arrivait, le sens est mauvais : SSH depuis le PC est un *push*,
alors que le pipeline a besoin d'un *pull* déclenché depuis la VM. Un tunnel inverse
(`ssh -R`) résoudrait ça élégamment, mais il reste bloqué par l'authentification.

### 2. Dossier partagé (virtiofs / 9p / option vibestarter) — **impossible sans modifier le lancement de la VM**

La ligne de commande QEMU complète ne contient **ni `-virtfs`, ni `-fsdev`, ni
`device virtio-9p`, ni `vhost-user-fs`**. Les seuls disques sont :

* `vibestarter-guest.squashfs` (système, `readonly=on`) ;
* `D:\VibeStarter\vm\user.qcow2` (27,4 Go, les projets).

`%LOCALAPPDATA%\Vibe Starter\resources\vm\share\` ne contient que des ROM de firmware
(`bios-256k.bin`, `efi-virtio.rom`…), pas un partage de fichiers.
Ajouter un partage demanderait de changer la commande QEMU, c'est-à-dire de patcher
vibestarter — refusé (fragile, écrasé à chaque mise à jour).

`D:\VibeStarter\vm\backups\projects\*.tar.gz` existe bien (snapshots de 2,3 à 4,7 Go) mais
ce sont des **sauvegardes ponctuelles**, pas une synchronisation vivante : inutilisable comme
transport.

### 3. Ajouter un port à `allowedHostPorts` — **écarté (fragile)**

Techniquement la meilleure voie : un serveur HTTP sur `127.0.0.1:27300` deviendrait joignable
en `http://10.0.2.2:27300` depuis la VM, à pleine vitesse et sans limite de taille.
Mais `gvproxy.yaml` est réécrit à chaque démarrage de la VM, et gvproxy est ici lancé
**sans API de contrôle** (`gvproxy.exe -config …` seulement, aucun `-listen` : pas de
`/services/forwarder/expose` à chaud). Il faudrait donc repatcher le fichier *et* redémarrer
la VM après chaque lancement de vibestarter. Rejeté : contraire à « aucune action manuelle »
et au garde-fou « sauvegarder avant de toucher à la config ».

### 4. Canal d'upload de vibestarter (glisser-déposer, 100 Mo) — **écarté (API interne)**

Les ports exposés ont été caractérisés :

| Port | Sens | Réponse |
|---|---|---|
| 30422 | PC | `HTTP/1.0 404` — `Server: tiny-http (Rust)` |
| 30423 | PC | `HTTP/1.0 401` — `Server: tiny-http (Rust)` (passerelle authentifiée) |
| 34872 | VM | `HTTP/1.0 401` — *« This sync server is managed by VibeStarter and needs its token »* |
| 34880‑34886 | VM | TCP non HTTP (ferme la connexion) |

Il existe donc bien un **serveur de synchronisation dans la VM** (34872), protégé par un
jeton. C'est une API interne non documentée, dont le jeton et le protocole peuvent changer à
chaque version. Écarté : on ne construit pas un pipeline sur une API privée.

### 5. Connecteur MCP de vibestarter — **RETENU**

C'est le seul canal **documenté, utilisateur, et qui survit aux redémarrages** : un serveur
HTTP déclaré sur `127.0.0.1` dans *Paramètres › My MCP servers* est relayé dans la VM par
`node ~/.vibestarter/mcp-stub.cjs`, lui-même branché sur la passerelle (10.0.2.2:30422/30423,
les deux ports autorisés).

Propriété décisive : **un script de la VM peut lancer le stub lui-même** et parler JSON-RPC
sur stdin/stdout. `convert_vehicle.py` n'a donc pas besoin que le serveur soit dans le
contexte de l'agent : ça marche pour Claude Code, Codex, ou un simple `python`.

Limites connues de la passerelle (mesurées précédemment par l'utilisateur, non re-mesurées
ici faute d'accès à la VM) : **~33 Mo par message** (25 Mo de base64 passent, 50 Mo
échouent avec `-32000 "The MCP server sent a message too large to pass on."`) et un débit
d'environ **0,75 Mo/s**. Le serveur découpe donc en morceaux de **6 Mo** (≈ 8 Mo en base64),
très en dessous du plafond.

## Comparaison

| Critère | SSH | Dossier partagé | `allowedHostPorts` | Upload vibestarter | **MCP (retenu)** |
|---|---|---|---|---|---|
| Faisable sans patcher vibestarter | ❌ clé éphémère | ❌ | ⚠️ redémarrage requis | ⚠️ jeton interne | ✅ |
| Survit à un redémarrage | — | — | ❌ réécrit | ⚠️ | ✅ |
| Sens VM → PC (pull) | ❌ push | ✅ | ✅ | ❌ | ✅ |
| Débit | n/a | n/a | ~ natif | n/a | ~0,75 Mo/s |
| Taille max | n/a | n/a | illimité | 100 Mo | 33 Mo/message (découpé) |
| Écoute 127.0.0.1 seulement | — | — | ✅ | — | ✅ |
| Tout agent de la VM | — | ✅ | ✅ | ❌ | ✅ |
| Zéro action manuelle par véhicule | — | ✅ | ✅ | ❌ | ✅ |

## Ce que ça donne en pratique

Le volume à transférer a été rendu petit exprès : les textures sont converties en **PNG
≤ 1024 px côté PC** et seuls les flux audio utiles sont envoyés (accel/decel/idle, moteur et
échappement), pas l'AWC entier.

Mesures sur le véhicule de test réel (`ferrari_f430scuderia`, `audioNameHash =
CARBONIZZARE`) :

| Lot | Contenu | Taille | Morceaux de 6 Mo |
|---|---|---|---|
| Textures | 7 PNG reprises du jeu | **≈ 3,0 Mo** | 1 par fichier |
| Son vanilla | 6 wav moteur/échappement + klaxon | **≈ 2,8 Mo** | 1 par fichier |
| **Total** | | **≈ 5,8 Mo** | |

Pour un véhicule d'urgence, les trois sirènes ajoutent environ **0,45 Mo** (wail ~6,3 s =
396 Ko, yelp et priority ~20 Ko chacun), soit toujours moins d'un morceau.

À 0,75 Mo/s cela représente **≈ 8 s** de transfert par véhicule, une seule fois (le cache
`~/.cache/fivem2roblox/` évite de le refaire). Sur la boucle locale du PC, le même transfert
prend 0,09 s (**32 Mo/s**) : le goulot est bien la passerelle, pas le serveur.

Autres mesures côté PC :

| Opération | Durée |
|---|---|
| Scan des RPF de GTA V (5 407 archives, 397 448 entrées, 0 erreur) | **6,2 – 7,9 s** (une fois) |
| Index complet des textures véhicules (4 840 `.ytd` → 3 684 textures) | **28 s** (optionnel) |
| `gta_find_textures` (6 noms) | 0,33 s |
| `gta_prepare_textures` (6 textures → PNG) | 1,96 s |
| `gta_prepare_audio` (ADDER) | 0,82 s — puis **0,009 s** en cache |
| Conversion complète du véhicule de test | **29 s** |

## Honnêteté sur les limites de ces tests

* Les mesures **PC → PC** (serveur, extraction, conversion, débit en boucle locale) ont été
  faites et sont reproductibles.
* Le segment **VM → passerelle → PC** n'a **pas** pu être mesuré dans cette session : il n'y
  a aucun moyen d'exécuter une commande dans la VM depuis le PC (SSH verrouillé, cf. §1).
  Les chiffres de 33 Mo et 0,75 Mo/s viennent des mesures antérieures de l'utilisateur.
  Le premier lancement depuis la VM reste donc à confirmer.
* Le choix du canal MCP, lui, ne repose pas sur une mesure mais sur la lecture de
  `gvproxy.yaml`, qui est sans ambiguïté sur ce que la VM peut joindre.

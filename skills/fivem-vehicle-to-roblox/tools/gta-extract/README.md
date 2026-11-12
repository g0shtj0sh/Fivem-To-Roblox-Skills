# `gta-extract`

Convertisseur **headless** des ressources binaires GTA V / FiveM vers le format XML de
CodeWalker, plus les fichiers qui en sortent : textures `.dds` et sons `.wav`. Il s'appuie sur
[CodeWalker.Core](https://github.com/dexyfex/CodeWalker) (licence MIT), cloné et compilé par
`build.ps1` / `build.sh` dans `.cache/CodeWalker` — aucun contenu Rockstar n'est versionné ici.

C'est l'outil qu'utilise le skill pour lire `.yft` / `.ytd`, et celui qui sert à sortir les sons
d'un `.awc` sans ouvrir l'interface de CodeWalker.

## Compiler

```powershell
skills\fivem-vehicle-to-roblox\tools\gta-extract\build.ps1
```

```bash
skills/fivem-vehicle-to-roblox/tools/gta-extract/build.sh
```

Pré-requis : **SDK .NET 8** et **git**. Résultat : `bin/gta-extract.exe`. Le skill le compile
tout seul au premier lancement.

## `export` — convertir des fichiers

```
gta-extract export <fichier|dossier> [...] -o <dossier_sortie> [-g <dossier GTA V>] [--legacy]
```

| Option | Rôle |
|---|---|
| `-o <dossier>` | dossier de sortie (obligatoire) |
| `-g <dossier>` | installation GTA V, pour la **clé de déchiffrement des `.awc`** |
| `--legacy` | force l'édition Legacy ; par défaut Enhanced/gen9 est détecté via `GTA5_Enhanced.exe` |

Extensions traitées : `.yft` `.ydr` `.ydd` `.ytd` `.awc` `.rel`, récursivement. Un `.rpf` donné en
entrée est parcouru, archives imbriquées comprises. La sortie reproduit l'arborescence d'entrée.
Chaque fichier donne `<nom>.<ext>.xml` **plus** un sous-dossier `<nom>/` contenant ses fichiers
extraits — les `.dds` d'un `.ytd`, les `.wav` d'un `.awc`. Une ligne JSON par fichier est écrite
sur la sortie standard, et le bilan sur l'erreur standard.

### Les `.awc` sont chiffrés : il faut le jeu installé

Les conteneurs audio de GTA V sont chiffrés **en entier** (XXTEA) avec une clé qui n'existe que
dans l'exécutable du jeu. Les packs de sons moddés étant des copies de ces conteneurs, ils le sont
aussi. Sans la clé, CodeWalker ne lit même pas l'en-tête.

Le dossier du jeu est cherché dans cet ordre :

1. `-g <dossier>` ;
2. la variable d'environnement `GTAV_FOLDER` ;
3. `~/.fivem2roblox/gta-server.json`, écrit par
   [`tools/gta-asset-server`](../gta-asset-server/README.md) la première fois qu'il tourne.

S'il n'est trouvé nulle part et qu'un `.awc` chiffré se présente, l'erreur le dit au lieu de
partir en `NullReferenceException`. Les autres formats n'ont pas besoin de la clé : elle n'est
chargée que si on la trouve. **GTA V n'est lu, jamais écrit.**

### Convertir un pack de sons entier

Un pack de sons se présente comme un dossier par conteneur (`RESIDENT`, `STREAMED_VEHICLES`,
`WEAPONS_PLAYER`…) rempli de `.awc`, à côté des `.rpf` qui les empaquettent. Pour garder le
classement par conteneur, une passe par dossier :

```bash
EXE=skills/fivem-vehicle-to-roblox/tools/gta-extract/bin/gta-extract.exe
SRC="<dossier du pack>"
OUT="<dossier de sortie>"
for d in "$SRC"/*/; do "$EXE" export "$d" -o "$OUT/$(basename "$d")"; done
```

```powershell
$exe = "skills\fivem-vehicle-to-roblox\tools\gta-extract\bin\gta-extract.exe"
Get-ChildItem "<dossier du pack>" -Directory | ForEach-Object {
    & $exe export $_.FullName -o "<dossier de sortie>\$($_.Name)"
}
```

Inutile de traiter les `.rpf` du pack en plus : ils contiennent les mêmes `.awc`. Compter sur
l'ordre de grandeur **1 Go de `.wav` pour 1 Go de `.awc`** — le son est déjà du PCM, le
déchiffrement ne le décompresse pas.

### Les noms de flux sortent souvent en `0x…`

Dans un `.awc`, chaque flux est désigné par un **hash Jenkins** ; le nom en clair n'est stocké ni
dans le conteneur, ni dans les `.rel` d'audio du jeu, qui ne nomment que les conteneurs
(`STREAMED_VEHICLES\SUPERCAR_1`) et pas leurs flux. Un hash ne s'inverse pas : un nom ne
réapparaît que si la chaîne exacte est connue d'avance.

`gta-extract` en retrouve une partie : beaucoup de conteneurs nomment leurs flux
`<nom du conteneur>_<rôle>` (`4_cylinder_saloon_1_start`, `4x4_engine_idle`), alors avant de lire
un `.awc` l'outil sème l'index avec cette combinaison pour tous les rôles listés dans
`extra_strings.txt`. Le rendement dépend du conteneur : mesuré sur un pack complet, **environ la
moitié des flux de `STREAMED_VEHICLES`** y répondent, contre quasiment rien dans les conteneurs de
bruitages (`RESIDENT`, `WEAPONS_PLAYER`), qui emploient d'autres conventions. Le reste garde son
hash.

Pour reconnaître un son resté anonyme, lire son en-tête dans le `.xml` : codec, fréquence,
nombre d'échantillons, points de boucle. Deux flux de même durée dans un conteneur de véhicule
sont presque toujours la paire moteur / échappement d'un même régime.

Pour en nommer d'autres, ajouter le **rôle** (pas le nom complet) à `extra_strings.txt` puis
recompiler : le préfixe est ajouté automatiquement. Les rôles déjà listés ont été trouvés par
recherche exhaustive sur les hash des conteneurs du jeu.

## À la main, dans CodeWalker (sans .NET)

1. Lancer `CodeWalker RPF Explorer.exe` et lui indiquer le dossier GTA V (les clés en sont
   extraites au démarrage).
2. *File › Open folder* sur le dossier du pack, ou ouvrir le `.rpf` directement.
3. Double-cliquer un `.awc` : la liste des flux s'affiche, avec durée et fréquence.
4. Sélectionner les flux, *Save WAV*. Ou clic droit sur le `.awc` › *Export XML*, qui écrit le
   `.xml` et le dossier de `.wav` — exactement ce que fait `export` ci-dessus.

L'interface est plus pratique pour écouter un flux et en choisir un ; la ligne de commande pour
traiter 100 conteneurs d'affilée.

## Autres commandes

| Commande | Rôle |
|---|---|
| `xml2bin <fichier.xml> -o <binaire>` | opération inverse (tests) |
| `probe -g <dossier GTA V> [--gen9]` | diagnostic : ouvre les RPF du jeu et liste les erreurs |
| `game-serve -g <dossier GTA V> [--gen9]` | service interrogé par `tools/gta-asset-server` pour retrouver textures partagées et son vanilla d'un véhicule |

La chaîne `audioNameHash` → `dat151` → `dat54` → `.awc` → `.wav`, qui récupère automatiquement le
**vrai son d'un véhicule du jeu**, est documentée dans
[`references/game-assets.md`](../../references/game-assets.md) et
[`tools/gta-asset-server/README.md`](../gta-asset-server/README.md).

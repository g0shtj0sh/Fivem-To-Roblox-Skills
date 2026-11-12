# FiveM → Roblox Skills

Skills pour Claude permettant d'importer du contenu FiveM / GTA V dans Roblox.

## `fivem-vehicle-to-roblox`

Donne simplement le **zip d'un véhicule FiveM / GTA V** à Claude : il produit un pack Roblox complet
où tout fonctionne, sauf la physique (gérée par ton propre moteur) :

| Domaine | Ce qui est converti |
|---|---|
| Modèle | `.yft` → GLB, 1 MeshPart par pièce/matériau, découpage ≤ 19 000 triangles, LOD au choix |
| Textures | `.ytd` / textures intégrées → PNG ≤ 1024 px, normal maps converties, livrées |
| Roues | roue unique GTA instanciée ×4 (ou ×6…), rotation, braquage, suspension (Motor6D) |
| Ouvrants | portières, capot, coffre articulés (ProximityPrompt « G »), volant animé, vitres |
| Lumières | phares (codes/pleins, xénon), feux, stop, 3ᵉ feu, clignotants, warnings, recul, feux de jour, gyrophares séquencés (carcols) |
| Sons | moteur multi-couches selon régime/charge (son custom .awc découpé, sinon synthèse), démarreur, klaxon, clignotant, sirènes |
| Contrôles | clavier / manette / mobile façon GTA, exposés à ton moteur physique (`VehicleInput.Controls`) |
| Custom | mods des kits carcols (spoiler, pare-chocs…), 6 couches de peinture, livrées, extras, teinte, néons, plaque, niveaux de perf ; sauvegarde/restauration |
| Données | `handling.meta`, `vehicles.meta`, `carvariations.meta`, `carcols.meta` exportés pour ton moteur |
| Jeu de base | textures partagées (`vehshare`, `txdRelationships`) et **vrais sons** du véhicule vanilla (`audioNameHash`) — moteur, klaxon et sirènes wail/yelp/priority — récupérés dans ton installation GTA V, voir ci-dessous |

Voir [`skills/fivem-vehicle-to-roblox/SKILL.md`](skills/fivem-vehicle-to-roblox/SKILL.md) et les
références dans `skills/fivem-vehicle-to-roblox/references/`.

### Installer le skill

- **Claude.ai / application Claude** : zipper le dossier `skills/fivem-vehicle-to-roblox` puis
  *Paramètres › Fonctionnalités › Skills › Importer un skill* (exécution de code activée).
- **Claude Code** : copier le dossier dans `~/.claude/skills/` (ou `.claude/skills/` d'un projet).

Ensuite : « Convertis ce véhicule pour Roblox » + le zip.

### Ressources du jeu de base (optionnel mais recommandé)

Beaucoup de véhicules payants réutilisent des ressources du jeu sans les inclure : textures
partagées (`vehshare.ytd`, `vehicle_generic_*`) et sons « vanilla » désignés par
`audioNameHash` (moteur, klaxon, sirènes). Par défaut le skill met une couleur unie et
synthétise les sons.

Pour obtenir **la texture exacte et le vrai son**, lance sur le PC où GTA V est installé :

```bat
skills\fivem-vehicle-to-roblox\tools\gta-asset-server\start-server.bat
```

puis déclare-le une seule fois dans vibestarter : *Paramètres › My MCP servers* → serveur
HTTP `http://127.0.0.1:27300/mcp`. Les conversions suivantes s'en servent automatiquement
(avec cache local et contrôle SHA-256), et retombent proprement sur l'ancien comportement si
le serveur est éteint.

- GTA V **Enhanced** (gen9) et **Legacy** sont tous deux gérés, détection automatique
  (Steam / Epic / Rockstar Launcher).
- GTA V est ouvert en **lecture seule** ; le serveur n'écoute que sur `127.0.0.1`.
- Détails : [`tools/gta-asset-server/README.md`](skills/fivem-vehicle-to-roblox/tools/gta-asset-server/README.md),
  [`references/game-assets.md`](skills/fivem-vehicle-to-roblox/references/game-assets.md),
  et [`docs/transport-tests.md`](docs/transport-tests.md) pour le choix du canal.

### Pré-requis

- Python 3.10+, `pip install -r skills/fivem-vehicle-to-roblox/requirements.txt` (numpy, Pillow).
- Pour lire les fichiers binaires GTA (`.yft/.ytd/.awc/.rpf`) : **SDK .NET 8** — l'outil
  `tools/gta-extract` (basé sur [CodeWalker.Core](https://github.com/dexyfex/CodeWalker), MIT) est compilé
  automatiquement au premier lancement. Sans .NET : exporter les fichiers en XML avec CodeWalker
  (clic droit › *Export XML*) et donner ces XML au skill.
  Le même outil sort les sons d'un `.awc` en `.wav`, un conteneur ou un pack entier :
  [`tools/gta-extract/README.md`](skills/fivem-vehicle-to-roblox/tools/gta-extract/README.md).
- Optionnel : `ffmpeg` (sons en .ogg), clé API Open Cloud pour uploader les sons automatiquement.

### Avec Roblox Studio connecté (MCP Roblox Studio)

« Convertis ce véhicule » + le zip : Claude convertit, uploade le modèle et les sons en assets
privés, insère le véhicule dans `Workspace.F2R_ImportTest`, lance le Setup et le vérifie
(`roblox/Verify.lua` : structure, échelle, roues, articulations, lumières, sons, custom, test de
conduite en Play), corrige puis rend un rapport court. Mesures et choix :
[`docs/studio-import-tests.md`](docs/studio-import-tests.md).

### Utilisation manuelle (sans Claude)

```bash
cd skills/fivem-vehicle-to-roblox
python scripts/convert_vehicle.py ~/Downloads/ma_voiture.zip -o ./out
# Studio : Importer 3D -> out/<nom>/<nom>.glb, sélectionner le modèle,
#          Modèle > Exécuter un script -> out/<nom>/<nom>_Setup.lua
```

Tests (aucun contenu Rockstar requis) :

```bash
python skills/fivem-vehicle-to-roblox/tests/test_pipeline.py   # véhicule synthétique de bout en bout
python skills/fivem-vehicle-to-roblox/tests/test_gamelib.py    # récupération des ressources du jeu (faux serveur)
```

> Vérifie la licence du mod avant de publier un véhicule sur Roblox. GTA V est une marque de Rockstar Games.

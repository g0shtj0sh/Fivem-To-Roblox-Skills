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

Voir [`skills/fivem-vehicle-to-roblox/SKILL.md`](skills/fivem-vehicle-to-roblox/SKILL.md) et les
références dans `skills/fivem-vehicle-to-roblox/references/`.

### Installer le skill

- **Claude.ai / application Claude** : zipper le dossier `skills/fivem-vehicle-to-roblox` puis
  *Paramètres › Fonctionnalités › Skills › Importer un skill* (exécution de code activée).
- **Claude Code** : copier le dossier dans `~/.claude/skills/` (ou `.claude/skills/` d'un projet).

Ensuite : « Convertis ce véhicule pour Roblox » + le zip.

### Pré-requis

- Python 3.10+, `pip install -r skills/fivem-vehicle-to-roblox/requirements.txt` (numpy, Pillow).
- Pour lire les fichiers binaires GTA (`.yft/.ytd/.awc/.rpf`) : **SDK .NET 8** — l'outil
  `tools/gta-extract` (basé sur [CodeWalker.Core](https://github.com/dexyfex/CodeWalker), MIT) est compilé
  automatiquement au premier lancement. Sans .NET : exporter les fichiers en XML avec CodeWalker
  (clic droit › *Export XML*) et donner ces XML au skill.
- Optionnel : `ffmpeg` (sons en .ogg), clé API Open Cloud pour uploader les sons automatiquement.

### Utilisation manuelle (sans Claude)

```bash
cd skills/fivem-vehicle-to-roblox
python scripts/convert_vehicle.py ~/Downloads/ma_voiture.zip -o ./out
# Studio : Importer 3D -> out/<nom>/<nom>.glb, sélectionner le modèle,
#          Modèle > Exécuter un script -> out/<nom>/<nom>_Setup.lua
```

Test : `python skills/fivem-vehicle-to-roblox/tests/test_pipeline.py` (véhicule synthétique, sans contenu Rockstar).

> Vérifie la licence du mod avant de publier un véhicule sur Roblox. GTA V est une marque de Rockstar Games.

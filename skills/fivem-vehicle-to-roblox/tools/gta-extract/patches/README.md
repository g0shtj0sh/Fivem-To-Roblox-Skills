# Correctifs appliqués au clone de CodeWalker

`build.ps1` / `build.sh` clonent [CodeWalker](https://github.com/dexyfex/CodeWalker) (MIT) à une
révision figée dans `.cache/CodeWalker`, remettent l'arbre à l'état de cette révision, puis
appliquent les `*.patch` de ce dossier dans l'ordre alphabétique. Rien n'est modifié à la main dans
le clone : il est écrasé à chaque compilation.

Un correctif qui ne s'applique plus arrête la compilation au lieu de passer inaperçu — c'est le
signal qu'il est soit intégré en amont (le supprimer), soit à réécrire pour la nouvelle révision.

| Correctif | Ce qu'il répare |
|---|---|
| `0001-awc-chiffrement-longueur-non-alignee.patch` | `AwcFile.Decrypt_RSXXTEA` / `Encrypt_RSXXTEA` allouaient `longueur / 4` mots puis y recopiaient `longueur` octets : toute donnée audio dont la longueur n'est pas un multiple de 4 faisait échouer la lecture du `.awc` entier (`Offset and length were out of bounds for the array`). Les fichiers de Rockstar sont alignés, mais pas toujours ceux remballés par les packs moddés. Le correctif ne traite que les mots complets et laisse la queue en clair, ce que fait déjà l'encodage par blocs. |

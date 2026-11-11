# Corps des occupants adapté à l'habitacle (VehicleSeatFit) — essais du 2026-11-11

## Problème
Assis, un avatar Roblox sort du véhicule : bras dans la portière, tête et chapeau dans le pavillon,
pieds dans le plancher. Demande : « que ça rentre parfaitement, quitte à réduire le perso », R15.

## Méthode
- **Conversion** (`scripts/f2r/cabin.py`) : voxels de 4 cm sur la carrosserie visible (sans roues,
  étriers, suspension, mods), parois épaissies d'une cellule (ferme les jours ≤ 8 cm), air extérieur
  rempli depuis le bord de la grille, air de l'habitacle depuis chaque siège (os + 25 à 80 cm).
  Interdit = air extérieur, ou à plus de 8 cm de l'air de l'habitacle. RLE base 36 dans `CONFIG.Cabin`.
- **Runtime** (`roblox/runtime/VehicleSeatFit.lua`) : client de l'occupant, 27 points par pièce du corps
  (sans accessoires) ; recherche, dans cet ordre de préférence, k (corps, 1 → 0,5), kw (largeur en plus,
  1 → 0,6), recul du siège (0 à 20 cm), hauteur (−30 à +40 cm, la plus basse valide) ; serveur :
  `VehicleEvent` « Fit », bornes, échelles, `SeatWeld.C0` décalé, accessoires hors habitacle masqués ;
  5 passes au plus ; `Restore` à la descente.

## Pièges mesurés
- Un R15 réduit **assis** flotte : la soudure du siège ne suit pas (bas des cuisses +0,29 stud après
  ×0,8 / ×0,7). Corrigé par le décalage de `SeatWeld.C0`.
- Le `Seat` Roblox est 30 cm sous l'os du siège GTA : corps dans le coussin et pieds dans le plancher.
  Sans recherche de hauteur, la réduction descend au minimum (×0,5) sans résoudre.
- Accessoires hauts (chapeau, « pousse » sur la tête) : toujours hors habitacle ; les compter
  rapetisse tout le corps → masqués à la place.

## Mesures (Studio PC, véhicule de test m422 coupé, avatar R15 du testeur, un passage chacune)
| Réglage permis | k (corps) | kw (largeur) | recul | hauteur |
|---|---|---|---|---|
| échelle seule, accessoires comptés | 0,50 (butée) | 0,60 (butée) | — | — |
| + hauteur, sans accessoires | 0,56 | 0,86 | 0 | +38 cm |
| + hauteur + recul (retenu) — conducteur | 0,64 | 0,78 (largeur finale ×0,50) | 20 cm | +18 cm |
| idem — passager | 0,72 | 0,65 | 20 cm | +12 cm |
- Verify `fit_play` 3/3 : 0 point hors habitacle sur 405, posé (25 points dans le coussin 6 cm plus bas).
- Montée par `Access.Enter`, 3 passes, réglage stable en ≈ 3,6 s ; même résultat à la deuxième montée ;
  descente : échelles 1/1/1/1 et accessoire réaffiché.
- Verify Edit 51/0 après rotation du véhicule de 180° (les contrôles d'orientation sont maintenant dans le
  repère de `VehicleRoot`, pas du monde).

## Limites, suite
- La posture assise Roblox (tibias verticaux, bras le long du corps) est faite pour une chaise : c'est
  elle qui impose la forte réduction dans un coupé bas. Une **posture de conduite** (jambes tendues vers
  les pédales, mains au volant), jouée sur tous les clients, permettrait de garder un corps bien plus grand.
- Non vérifié : multijoueur (ce que voit un autre joueur), téléphone, R6, véhicules à habitacle ouvert.

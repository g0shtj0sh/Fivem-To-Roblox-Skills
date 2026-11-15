# Son moteur façon GTA — deux couches, boucles à régime mesuré (2026-11-15)

Demande de l'utilisateur (brolver-rp) : « améliorer tout le système » du son moteur pour qu'il marche comme GTA V et
donne la meilleure qualité possible avec les sons du projet plus tard (packs sous licence). Les sons de GTA ne
servent qu'à la mise au point, **en local**, et ne sont pas mis en ligne.

## Ce que fait GTA V (conférence GDC 2014 de Rockstar North, « The Sound of GTA V »)
Deux sources par voiture : **moteur** (côté capot, vers l'avant) et **échappement** (aux pots, vers l'arrière,
audible plus loin) ; chacune enregistrée en montée de régime rapport engagé (accélération ≈ 7 s), en
décélération pied levé et au ralenti ; moteur granulaire au régime courant ; voitures des PNJ en version
allégée (boucles seules).

## Ce que fait le skill maintenant
- **Convertisseur** (`scripts/f2r/engine_loops.py`, appelé par `audio.py`) :
  - régime **mesuré** dans chaque balayage : saillance par somme d'harmoniques sur spectre blanchi + meilleur
    chemin monotone (programmation dynamique) ; une courbe commune aux pistes synchrones (moteur + échappement) ;
  - haut du balayage calé sur le rupteur ; le bas en découle (mesuré sur le « Banshee » : ×4,4, ≈ 1 600 → 7 060
    tr/min ; la décélération ≈ 2 000 → 7 060) ;
  - 8 paliers par balayage (écart de hauteur constant), fenêtre **relue à vitesse variable** pour une hauteur
    constante, longueur = nombre entier de cycles moteur, fondu de raccord sur 2 cycles ; un seul gain par
    couche (niveaux relatifs gardés) ;
  - sortie : `engine_on_1..8`, `engine_off_1..8`, `engine_idle`, idem `exhaust_*` (34 boucles), `Layer` dans
    `Audio.EngineLoops`, `ExhaustPosition` = moyenne des os `exhaust*` ;
  - sans son de jeu : moteur **original de synthèse** (balayages synthétiques) passé par la même chaîne.
- **Setup** : sons d'échappement sur l'attache `SoundsExhaust` (portée 12–320 studs), moteur sur `Sounds`
  (8–170 studs).
- **Runtime** (`VehicleRuntime`, `Runtime.EngineAudio`) : par couche, fondu à puissance constante entre les deux
  boucles voisines du régime (le ralenti ouvre chaque liste), `PlaybackSpeed = régime / régime de la boucle`
  (0,5–2), passage enfoncé ↔ relâché lissé (0,06 s / 0,12 s) en puissance constante, boucles muettes arrêtées,
  départ à une position aléatoire ; au-delà de 140 studs la couche moteur se tait (échappement seul) ; en vue
  intérieure (`VehicleCamera.IsPov`), égaliseur sur l'échappement (aigus −14 dB, médiums −6 dB) et moteur
  ×1,25 ; un `SoundGroup` par couche et par véhicule (client). Ancien format (une couche, `Idle`) toujours lu.

## Mesures (hors ligne, Python)
| | Variation de hauteur dans une boucle | Raccord (saut / écart ordinaire p95) |
|---|---|---|
| ancien découpage (4 morceaux de 0,52 s) | 0,6 à 1,75 demi-ton | ≤ 0,75 |
| nouveau, « Banshee » accélération | ≤ 0,13 demi-ton | ≤ 0,96 |
| nouveau, « Banshee » décélération | jusqu'à 1,3 demi-ton aux 2 paliers les plus bas | ≤ 0,96 |
| nouveau, synthèse | ≤ 0,13 demi-ton | ≤ 2,15 (1 boucle), sinon ≤ 1 |

Suivi du régime validé sur un balayage de synthèse à régime connu : erreur médiane 0,15 demi-ton ; pistes moteur
et échappement d'une même prise GTA : écart médian 0,03 demi-ton.

## Essai en jeu (Play Studio PC, m422, 1 joueur, boucles de synthèse originales)
Ralenti : 2 sons (ralentis moteur + échappement). Accélération : 2 voisins par couche, hauteur ×0,8–1,3, 4 voix.
Lever de pied : bascule vers les boucles relâché en ≈ 0,3 s, 8 voix au plus pendant la bascule. Échappement à
+8,5 studs (arrière), moteur à −5,1 (avant). Touche V : vue intérieure → égaliseur actif ; V à nouveau → inactif.
**Non vérifié** : rendu à l'oreille (l'agent n'entend pas), deuxième joueur, téléphone, coût avec plusieurs
voitures.

## Pour de vrais sons plus tard
Balayages (accélération / décélération / ralenti, moteur et échappement séparés) : le convertisseur fait tout.
Packs à boucles déjà découpées (ex. Skril Studio : idle → very_high, `_on` / `_off`) : il reste à écrire
l'import qui mesure le régime de chaque boucle (même suivi, entre boucles) — pas encore fait.

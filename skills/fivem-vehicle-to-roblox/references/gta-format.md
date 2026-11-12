# Format des véhicules GTA V / FiveM — mémo technique

## Contenu typique d'une ressource FiveM

```
ma_voiture/
  fxmanifest.lua            (data_file 'VEHICLE_METADATA_FILE' 'data/vehicles.meta' ...)
  stream/
    adder.yft               modèle (fragment) — LOD "normal"
    adder_hi.yft            modèle haute définition (préféré par le convertisseur)
    adder.ytd / adder+hi.ytd  textures (dictionnaire)
    adder_wing_1.yft ...    pièces de mods (référencées par carcols.meta)
  data/
    vehicles.meta           modelName, handlingId, audioNameHash, type, classe, flags, wheelScale
    carvariations.meta      couleurs par défaut (indices palette), kits, lightSettings, sirenSettings
    carcols.meta            kits de mods (visibleMods, statMods), réglages lumières, sirènes
    handling.meta           physique GTA (exportée telle quelle dans vehicle_config.json)
  audioconfig/ + sfx/       (optionnel) son custom : *.dat151.rel / *.dat54.rel + dlc_xxx/*.awc
```
Les addons solo arrivent souvent en `dlc.rpf` : `gta-extract` le parcourt (sauf RPF chiffré NG).

## Repères

- GTA : X droite, **Y avant**, Z haut. Sortie (= Roblox) : X droite, Y haut, **Z arrière** (avant = −Z).
- Conversion : `(x, y, z)_gta → (x, z, −y)`. Unités : mètres, puis `StudsPerMeter` (3.571 par défaut).

## Os importants

| Os | Rôle dans Roblox |
|---|---|
| `chassis` (racine), `bodyshell` | carrosserie fixe (soudée à `VehicleRoot`) |
| `wheel_lf/rf/lr/rr`, `wheel_lm1..3/rm1..3` | pivots Motor6D (rotation X, braquage Y, suspension) |
| `hub_lf/rf/lr/rr` | étrier de frein (et son logo) : suit sa roue (braquage + suspension) **sans tourner avec elle** ; braquage autour de l'axe vertical de la roue |
| `suspension_lf/rf/lr/rr` | bras / jambe de force d'un seul tenant de la caisse à la roue : **pivote** autour d'un axe longitudinal posé à son extrémité côté caisse (lu dans sa géométrie au repos), de l'angle qui fait suivre à l'aplomb de la roue sa course verticale ; ni braquage ni rotation de roue (approximation : le vrai mouvement GTA de ces os n'est pas vérifié) |
| `door_dside_f/r`, `door_pside_f/r` | charnières (axe Z de l'os, sens calculé pour s'ouvrir vers l'extérieur) |
| `bonnet`, `boot`, `boot_2` | charnières (axe X de l'os, sens vers le haut) |
| `steeringwheel` | volant (axe = colonne, ±270°) |
| `headlight_l/r`, `taillight_l/r`, `brakelight_l/r/m`, `indicator_lf/rf/lr/rr`, `reversinglight_l/r`, `extralight_1..4` | position des sources lumineuses |
| `siren1..20`, `siren_glass1..20` | gyrophares (clignotement séquencé, rotation éventuelle) |
| `extra_1..N` | extras activables (`Custom.SetExtra`) |
| `window_lf/rf/lr/rr`, `windscreen` | vitres (`Custom.SetWindowDown`) |
| `seat_dside_f`, `seat_pside_f`, ... | sièges Roblox (`DriverSeat` = `seat_dside_f`) |
| `misc_a..z`, `bumper_f/r`, `spoiler`... | points d'attache / pièces masquées par les mods (`turnOffBones`) |
| `engine` | position des sons moteur |

## Roues

Le jeu n'a qu'**une** roue modélisée (`wheel_lf`), stockée dans un *enfant physique* du fragment
(`Physics/LOD1/Children/Item/Drawable`, relié à l'os par `BoneTag`). Le convertisseur l'instancie sur
toutes les roues présentes ; côté opposé = rotation de 180° autour de l'axe vertical. Si `wheel_lr` a
sa propre géométrie, elle sert pour l'arrière ; sinon le rapport `wheelScaleRear / wheelScale` est appliqué.

## Lumières (shader `vehicle_lightsemissive`)

L'ID de lumière est dans **le canal alpha de `Colour0`** de chaque sommet (source : Sollumz) :

| ID | Lumière | ID | Lumière |
|---|---|---|---|
| 0 | toujours allumée (feux de jour) | 9 | stop gauche |
| 1 | phare gauche | 10 | stop droit |
| 2 | phare droit | 11 | 3ᵉ feu stop |
| 3 | feu arrière gauche | 12 | recul gauche |
| 4 | feu arrière droit | 13 | recul droit |
| 5/6 | clignotant AV G/D | 14–17 | extralight 1–4 |
| 7/8 | clignotant AR G/D | | |

Chaque ID devient une pièce séparée (attribut `LightRole`) qui passe en `Neon` quand elle s'allume.
Sans `Colour0`, l'ID est déduit de l'os de lumière le plus proche.

## Couches de peinture

Codées dans `matDiffuseColor` : `x = 2` et `y = z = id` → 1 Primaire, 2 Secondaire, 3 Nacré,
4 Jantes, 5 Défaut (blanc), 6 Garniture intérieure, 7 Tableau de bord (source : Sollumz).
Sinon `matDiffuseColor` est une couleur fixe (`CustomColor`). Les couleurs par défaut viennent de
`carvariations.meta` (`indices` = primaire, secondaire, nacré, jantes, intérieur, tableau de bord)
via la palette `scripts/f2r/gta_colors.py`.

## Livrées

`vehicle_paint3` porte la livrée dans `DiffuseSampler2` (texture `<nom>_sign_1`, `_sign_2`…), sur le
**2ᵉ jeu d'UV** (`TexCoord1`). Les pièces concernées sont exportées avec cet UV ; dans Roblox la
livrée est une `SurfaceAppearance` en `AlphaMode.Overlay` (la peinture apparaît sous la transparence).
Chaque livrée transite dans le GLB via un petit carré `LIVERY_TEX_n`, récupéré puis supprimé par le Setup.
Les livrées de type mod (`VMT_LIVERY_MOD`) sont gérées comme des mods géométriques.

## Mods (carcols.meta › Kits)

`visibleMods/Item` : `modelName` (+ `linkedModels`), `type` (VMT_SPOILER…), `bone` d'attache,
`turnOffBones` (os d'origine masqués quand le mod est posé). L'index Roblox = rang du mod dans son
type (1 = premier, 0 = d'origine). `statMods` (moteur, freins, boîte, suspension, blindage) sont
exportés dans `VehicleConfig.StatMods` pour le moteur physique.

## Shaders → rendu Roblox

| Shader | Kind | Rendu |
|---|---|---|
| `vehicle_paint*` | paint | `Part.Color` = couleur de la couche (+ texture teintée si présente) |
| `vehicle_vehglass*` | glass | Material Glass, transparence réglable (teinte) |
| `vehicle_lightsemissive` | light | lentille → Neon colorée quand allumée |
| `vehicle_lightsemissive_siren` | siren | gyrophare |
| `vehicle_tire`, `vehicle_track*` | tire | texture (ou gris foncé) |
| `vehicle_licenseplate` | plate | SurfaceGui avec texte |
| `vehicle_badges`, `vehicle_decal*` | decal | SurfaceAppearance en transparence |
| autres (`vehicle_mesh`, `interior`, `emissive`...) | mesh… | texture diffuse + normal map |

## Son

Les sons vanilla (`audioNameHash` = ADDER, SULTAN…) ne sont pas dans le pack : un moteur est
synthétisé (nombre de cylindres estimé). Un son custom (`.awc`) est exporté en `.wav` ; le plus long
flux (ou celui nommé *accel*) est découpé en 4 boucles à régimes croissants — approximation du moteur
granulaire de GTA.

# Chocs et gravité en vol (2026-11-15)

Plainte de l'utilisateur (brolver-rp, m422) : « on a l'impression d'une gravité basse » en saut, et au choc à
pleine vitesse « la gravité n'est pas réaliste ».

## Mesures
- **GTA (traces FiveM de la campagne m422, vols libres sans contact, ajustement z(t) du 2ᵉ degré, résidu < 1 cm)** :
  9,76–9,80 m/s² sur 14 vols (`airr_*`, `b2_*`, `v_off_sable_*`, `off_sandy_a`). La colonne `grav` vaut 9,8.
  Script : `scripts/vehicles/physics-gravity/gta_air_gravity.py` du projet brolver-rp.
- **Roblox (Play Studio PC, m422, conducteur à bord, chute de 30 studs sur une dalle)** : 34,6–34,7 studs/s²
  = **9,68–9,71 m/s²** à l'échelle du véhicule (3,571 studs/m). Le moteur reproduit donc la gravité de GTA.
  `Workspace.Gravity` = 196,2 studs/s² = 54,9 m/s² à la même échelle : personnages et objets libres tombent
  5,7 × plus vite que la voiture — d'où l'impression de « Lune » à côté du reste de Roblox.
- **Choc frontal contre un mur de béton à 106 km/h** : la voiture repartait en arrière à 36 km/h en une image
  (restitution 0,32), à plat. Cause : coque de collision en Plastic par défaut (élasticité 0,5 ; béton 0,2 ;
  Roblox fait la moyenne pondérée). → `VehicleCollision.ApplyCrashMaterial` : élasticité fixée, poids 100 sur
  la coque, les roues de collision et la `Hitbox` (Setup + démarrage serveur, idempotent ; la restitution vaut
  alors ≈ `CrashElasticity` quel que soit l'obstacle).
  - Essai 0 : 103 km/h → 0 en une image, rebond 1 km/h. **Refusé par l'utilisateur** (« ça rebondit plus du
    tout… ça s'arrête net »).
  - **Retenu 0,15** (ordre de grandeur d'une voiture réelle en choc frontal) : 106 km/h → **−14,6 km/h**,
    secousse verticale 8 cm, caisse qui reste presque à plat.

## Gravité en vol (choix de l'utilisateur, brolver-rp)
`Dyn.Tuning.AirGravityScale` (défaut 1 = GTA), relevable par l'attribut `AirGravityScale` du dossier
`ReplicatedStorage.FiveMVehicles` (réglage du jeu, conservé par une réinstallation du runtime — vérifié) ou par
`DriveTuning` du véhicule ; force ajoutée seulement quand les 4 roues ont décollé, conduite au sol inchangée.
brolver-rp : **1,5** (choisi parmi ×1 / ×1,5 / ×2). Mesuré : chute libre 14,55–14,62 m/s².

## Non fait / ouvert
- Pas de tangage au choc (arrêt « rigide », caisse à plat) : non comparé à GTA (aucune trace de choc).

## Retour en arrière sur les chocs (2026-11-15, même soir) — décision de l'utilisateur
« Reviens à ce qu'on avait avant… je veux retrouver les rebonds et tout d'avant, juste avec une gravité un peu plus
lourde. » → `ApplyCrashMaterial` retiré du runtime, du Setup et du serveur ; pièces de collision remises sans
`CustomPhysicalProperties` (Plastic, élasticité 0,5). Vérifié : 106 km/h → −37,1 km/h (identique à l'état
initial). Gravité en vol ×1,5 gardée (14,55 m/s²). Les mesures ci-dessus restent valables comme historique.

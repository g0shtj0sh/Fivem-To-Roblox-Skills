--!nonstrict
-- FiveMVehicles/VehicleDynamics (ModuleScript, pur : aucune Instance, aucun service)
-- Simulation de conduite façon GTA V à partir de VehicleConfig.Handling (handling.meta converti).
-- Tout est calculé en grandeurs SPÉCIFIQUES (m/s² = N/kg, m, m/s, rad/s) : la masse du modèle Roblox
-- n'intervient jamais ; le contrôleur (VehicleDrive) multiplie par AssemblyMass et StudsPerMeter à la frontière.
--
--   local Dyn = require(FiveMVehicles.VehicleDynamics)
--   local sim = Dyn.new(cfg, comLocalMeters, tuningOverrides)  -- cfg = require(car.VehicleConfig)
--   local out = Dyn.step(sim, inputs, contacts, dt, ctx)        -- voir le format plus bas
--
-- Repère local (celui de VehicleRoot, en mètres) : x droite, y haut, z arrière (l'avant est -z).
-- Formules : reports/Physique véhicules GTA V Roblox.md (moteur à régime normalisé 0,2 → 1, couple plat
-- jusqu'à 0,8 puis 60 % au rupteur, vitesse d'un rapport = DriveMaxFlatVel / rapport, embrayage 0,1 → 1 au
-- taux ClutchChangeRate, paires de biais (2b, 2(1−b)), traînée k·v², pneus Max / Min / Lateral).
-- Les lois encore inconnues sont des RÉGLAGES (Dyn.Tuning) : à caler sur des traces FiveM.

local Dyn = {}

-- ------------------------------------------------------------------ réglages (constantes à caler)
Dyn.Tuning = {
	-- Les valeurs marquées MESURÉ viennent de la campagne FiveM sur le m422 : voir
	-- calibration/m422/README.md et les traces de calibration/m422/fivem/.
	KMu = 1.0, -- échelle de TractionCurveMax/Min en « g ». MESURÉ : 100-0 km/h roues bloquées donne 1,88 g de
	-- moyenne et 2,09–2,14 g de pic pour fTractionCurveMax = 1,90 → le champ EST une accélération en g.
	PeakFactor = 0.55, -- pic latéral = TractionCurveLateral × PeakFactor. REBALAYÉ EN 3D (2026-11-12, après la
	-- direction mesurée, banc avec zone morte, DownshiftRpm 0,35) de 0,4 à 1,0 : 0,55 tient le virage 40 km/h
	-- établi à 1,675 g / 6,37 m / dérive de caisse 4,35 ° (GTA 1,690 g / 6,29 m / 4,44 °) et ses pneus à
	-- 9,5 ° avant / 8,3 ° arrière (GTA 9,35 / 8,35). Dérive des pneus = braquage − angle de la vitesse à
	-- l'essieu, l'essieu avant allant à vLat − a·wz (x à DROITE dans la télémétrie FiveM) : le « vLat + a·wz »
	-- qui donnait 13,7–17,2 ° et poussait vers 0,8–1,0 inversait ce signe (il donne 34 ° avec le braquage
	-- signé). Au-delà, 0,6 → 6,27 m mais dérive 3,85 ° ; 0,8 → 6,06 m, 1,66 °, pneus 12,3 / 11,5 °. Limite :
	-- au créneau (0,83 g) GTA est plus raide (pneus à 3,1 °, Roblox 4,5 ° à 0,55) — la forme du pneu
	-- (linéaire jusqu'au pic) ne peut pas tenir les deux points. Le « bascule au-delà de 0,55 » des balayages
	-- précédents était la boîte (DownshiftRpm 0,45 : rétrogradage 2→1 à 36 km/h en virage), pas le pneu.
	KappaPeak = 0.12, -- glissement longitudinal du pic (champ absent de GTA V)
	Falloff = 1.5, -- largeur (en multiples du pic) de la descente de Max vers Min
	-- Plafond de la force LATERALE, proportionnel à la vitesse latérale au contact :
	--     |Fy| ≤ LatVCap × |vitesse latérale| × charge
	-- MESURÉ (2026-11-12) sur 33 plateaux établis : 22 cercles `skidpad` (dont 10 à rayon imposé, pour
	-- séparer la vitesse du rayon), le virage 40, le virage 80 et le créneau. Sans ce plafond, le modèle
	-- latéral a un résidu qui suit la VITESSE et non le rayon : à rayon fixé (18 m) il passe de +25 % à
	-- 30 km/h à −17 % à 66 km/h, corrélation −0,84 avec la vitesse contre −0,56 avec le rayon. Avec le
	-- plafond, les deux corrélations tombent à −0,17 et +0,02, et l'écart de 0,137 g à 0,083 g, pour UN seul
	-- paramètre. C'est vraisemblablement le `fTractionSpringDeltaMax` du handling, décrit comme un
	-- débattement latéral de flanc qui ramène le véhicule à l'arrêt après une glisse.
	-- CE QUE ÇA RÉSOUT : le point ouvert « un seul `PeakFactor` ne tient pas à la fois le créneau (qui
	-- voudrait 0,4) et le virage 40 (0,55) ». Ce n'était pas la forme de la courbe mais ce plafond : avec
	-- lui et un `PeakFactor` unique, le créneau passe de −32,7 % à −3,8 % et le virage 40 de −12,6 % à
	-- −3,6 %. Les deux essais diffèrent autant en vitesse (58,9 et 36,8 km/h) qu'en dérive.
	-- CE QUI RESTE : la forme de la courbe n'est toujours PAS identifiable — linéaire, sinus, tanh, Möbius
	-- et puissance tiennent dans 0,001 g l'une de l'autre — donc elle reste linéaire jusqu'au pic. Et il
	-- reste +10 à +14 % vers 38-48 km/h, là où le plafond cesse de mordre : la transition est sans doute
	-- trop brutale (un min dur), un raccord progressif ferait mieux.
	LatVCap = 1.25, -- par (m/s) de vitesse latérale ; 0 = désactivé
	FalloffKappa = 0.1, -- poids du glissement LONGITUDINAL dans cette descente. MESURÉ : au freinage les roues
	-- se bloquent complètement (glissement −1,0) et l'adhérence reste à son pic (1,88 g pour 1,90) : dans GTA
	-- la chute d'adhérence est pilotée par la dérive, pas par le blocage. 1 = ancien comportement.
	-- CONSERVÉ après vérification en Studio (2026-11-12) : 100-0 en 19,6 m à 1,87 g (GTA 20,6 m, 1,81 g). À 1,
	-- le 3D donne 20,6 m mais le banc longitudinal 22,9 m (+11 %) : le banc freine moins fort que le 3D (pas de
	-- report de charge en tangage). Le frein à main 60-0 reste trop court à toutes les valeurs (15,7 m à 0,1 ;
	-- 17,6 m à 1 ; GTA 20,0 m) : ce n'est pas ce réglage qui le règle.
	VMin = 1.0, -- m/s : plancher de vitesse pour les glissements (anti-tremblement)
	-- Frottement STATIQUE. Le plancher `VMin` divise le glissement par 1 m/s à l'arrêt : le glissement
	-- devient donc nul, et la force avec. Le véhicule descend alors la pente sur ses pneus. GTA, lui,
	-- TIENT : MESURÉ sur l'essai `hill`, 3 passes — tout relâché pendant 2,0 s sur une pente de 17,1 %,
	-- déplacement **0,000 m**, vitesse 0,00 km/h, boîte au point mort et pression de frein **nulle**. Ce
	-- n'est donc ni un frein automatique ni le frein à main : c'est le pneu qui tient.
	-- On abaisse donc le plancher quand la roue ET le sol sont quasi immobiles, ce qui fait du pneu un
	-- ressort raide à l'arrêt, et on borne la force longitudinale à ce qui annule le glissement en un pas
	-- (comme le fait déjà le latéral), sans quoi la raideur ferait osciller.
	-- Il faut un RESSORT sur le glissement accumulé, et non un amortisseur : une force proportionnelle à
	-- la vitesse de glissement s'annule avec elle, donc il subsiste une vitesse de fluage d'équilibre
	-- (mesurée au banc : 0,10 km/h, soit 5,5 cm en 2 s — pire que sans rien). Le ressort, lui, garde sa
	-- force à vitesse nulle. Il décroche à l'adhérence, ce qui redonne le frottement cinétique.
	VStick = 0.30, -- m/s : en dessous, la roue et le sol sont considérés immobiles
	-- CALÉ au banc (balayage de 200 à 6400) : le recul se divise exactement par deux quand la raideur
	-- double — 8,4 / 4,2 / 2,1 / 1,0 / 0,5 mm — ce qui est la signature d'un ressort correct, et le banc
	-- longitudinal ne bouge pas (5,26 à 5,32 %). À 6400 le comportement devient erratique (le recul remonte
	-- à 4,3 mm avec `CStick` 28) : 1600 garde donc une marge. Déformation au décrochage : 1,2 mm, l'ordre
	-- de grandeur d'un flanc de pneu.
	KStick = 1600, -- par mètre de glissement accumulé ; recul 1,0 mm sur 17 % de pente (GTA : 0,0)
	CStick = 60, -- amortissement du ressort : sans lui il oscillerait. 60 reste propre jusqu'à KStick 6400,
	-- là où 28 décroche — d'où ce choix plutôt que le ≈ 2√K théorique.
	KSpring = 1.0, -- k = SuspensionForce × biais × g / course × KSpring (hypothèse)
	BumpK = 0, -- m/s² par m au-delà de la butée de compression. VÉRIFIÉ EN STUDIO (2026-11-12) : la marche de
	-- 0,149 m prise à 60 km/h monte la roue en une image et dépasse les 0,10 m de course restante au repos ;
	-- à 400 la butée renvoyait la caisse : +8,4 / −17,7 ° de tangage, 3 images en l'air, 8,7 km/h perdus. À 0 :
	-- +3,0 / −2,4 °, 4 roues au sol, 0,45 km/h perdus (GTA +2,2 / −2,6 °, 4 roues, 0,03 km/h). 50 abîme déjà
	-- (+4,8 / −5,7 °, 2 roues). GTA lui-même comprime au-delà de sa course nominale (0,326 à 60 km/h).
	DampVMax = 1.0, -- m/s : vitesse d'amortisseur plafonnée (clapets haute vitesse, souplesse du pneu).
	--                 Sans plafond, une bordure de 15 cm à 20 km/h (5,4 m/s en une image) fait décoller l'avant.
	-- VÉRIFIÉ EN STUDIO (2026-11-12), marche de 0,149 m × 12,2 m, BumpK 0 : 1,0 → cabrage +4,7 ° à 20 km/h et
	-- +3,0 ° à 60 ; 0,5 → +4,5 ° et +3,8 ° (GTA +3,45 ° et +2,2 °). Seul 1,0 garde la signature GTA (le cabrage
	-- BAISSE nettement avec la vitesse). 0,25 : 24 images en l'air à 60 km/h. Le 0,5 posé d'après la mesure
	-- (2026-11-12, nuit) n'était pas la cause : c'était la butée (BumpK).
	RollCentreScale = 0.25, -- hauteur des centres de roulis (RollCentreHeightFront/Rear) × ce facteur : c'est là
	-- que VehicleDrive applique les forces LATÉRALES des pneus. C'est elle qui règle le roulis, pas KSpring / KArb :
	-- sur le m422 (centre de gravité 0,45 m au-dessus du sol, centres de roulis 0,3 / 0,4 m), le bras de levier
	-- n'est que de 0,15 m à l'avant et 0,05 m à l'arrière → 0,22 °/g calculé, 0,22 °/g mesuré en Studio. À 0, le
	-- bras redevient la hauteur du centre de gravité : 0,94 °/g mesuré (GTA ≈ 1,0 °/g).
	-- BALAYÉ EN 3D (2026-11-12, PeakFactor 0,55) : 1 → roulis 0,38 ° au virage 40 ; 0,5 → 0,97 ° ; 0,25 → 1,26 °
	-- (0,76 °/g ; GTA 1,71 °, 1,01 °/g) ; créneau 0,20 / 0,52 / 0,67 ° (GTA 0,86 °). 0,25 est la valeur la plus
	-- basse qui tient : à 0,1 et à 0 le virage 40 s'effondre (0,89 et 1,16 g, 24 km/h). Cause démontrée : la roue
	-- ARRIÈRE INTÉRIEURE se déleste et patine (130 km/h de vitesse de roue pour 35 km/h), le régime — moyenne
	-- des roues motrices — s'emballe, la boîte monte en 3ᵉ et le véhicule perd sa motricité. GTA, lui, roule par
	-- moments sur 2 ou 3 roues au virage 40 sans rien perdre. Pour aller vers 1 °/g : traiter d'abord ce
	-- patinage (répartition du couple, régime pris sur la vitesse du véhicule), puis redescendre ce réglage.
	KArb = 1.0, -- anti-roulis : kA = AntiRollBarForce × biais × g / course × KArb (loi inconnue)
	IwRel = 0.03, -- inertie de roue + transmission, spécifique : Iw = IwRel × r² / 4 (1,5 mesuré trop lourd :
	-- la roue accélérait au rythme de la voiture et le pneu restait sous son pic, 0,26 g au lieu de ~0,6 g).
	-- CALÉ sur les mesures m422 : 0,25 ajoutait 25 % d'inertie équivalente, ce qui rendait impossible de tenir
	-- à la fois le 0-100 et la vitesse de pointe. À 0,03 les deux tombent ensemble (banc longitudinal).
	KDrag = 2.1, -- multiplie le coefficient de traînée issu du chargement (DragCoeff × 1e-4), dont le facteur
	-- n'était qu'une hypothèse. MESURÉ : plateau à 118,9 km/h en 4ᵉ (régime 0,806) pour fInitialDragCoeff = 8,0.
	-- Apport de poussée EN PENTE. MESURÉ (2026-11-12) sur 1046 images à plein gaz en 2ᵉ, 14 traces
	-- (accélérations à plat, côtes, et l'essai `thrust` à pente et vitesse imposées) :
	--     poussée = 0,400 g + 0,537 × g × sin(pente)
	-- soit, à plat, exactement `fInitialDriveForce` × rapport × g (0,2 × 2,0 × g = 0,40 g, constant de
	-- 0,50 à 0,90 de régime sur 534 images), et en pente **54 % de la résistance de la pente récupérés**.
	-- Écart 0,081 g contre 0,134 g pour une poussée constante.
	-- Vérifié trois fois, parce que le résultat est surprenant : la pente lue sur la TRAJECTOIRE
	-- (dz / distance horizontale), celle lue sur l'assiette de caisse, et celle relevée au RAYON sans
	-- véhicule (18,1 / 23,5 / 29,5 / 34,6 % le long de la montée) concordent. Et le régime est identique
	-- à plat et en pente à vitesse égale (0,542 contre 0,543 à 45 km/h), donc c'est bien le même rapport.
	-- LIMITE : les essais en côte lient encore la pente à la vitesse (chaque trace a la sienne), donc les
	-- résidus par tranche de pente gardent une structure de ±0,08 g. La valeur 0,54 est à affiner.
	-- Jamais mesuré en DESCENTE : l'apport est donc borné à la montée (`max(0, sin)`).
	-- Inactif si l'appelant ne fournit pas `ctx.slopeSin` : aucune régression pour le code existant.
	-- NON ACTIVÉ (0 au lieu de la valeur mesurée 0,537), et c'est délibéré : l'activer fait PATINER le
	-- démarrage en côte. Au banc, en 1ʳᵉ sur 17 % de pente, le régime passe de 0,26 à 0,79 à 13 km/h, la
	-- boîte monte en 2ᵉ puis redescend et pompe, et la distance de lancement tombe de 34,6 à 26,1 m. Un
	-- apport de 9 % de la poussée ne devrait pas suffire à déclencher ça : l'interaction avec la dynamique
	-- de rotation de roue (`IwRel` = 0,03, inertie très faible) n'est pas comprise, et livrer le réglage
	-- sans la comprendre remplacerait une erreur de 10 % par un défaut de comportement.
	-- La mesure, elle, tient : voir ci-dessus. Mettre 0,537 pour la réactiver une fois le patinage compris.
	SlopeAssist = 0, -- fraction de g·sin(pente) ajoutée à la poussée, sous les gaz. MESURÉ : 0,537
	FirstGearForce = 1.5, -- la 1ʳᵉ de GTA pousse plus fort que DriveForce × rapport × g. MESURÉ : 10,5 à 12,4 m/s²
	-- en 1ʳᵉ là où la loi donne 6,53 (les 2ᵉ et 3ᵉ, elles, suivent la loi à 2 et 5 % près). Le rapport de
	-- VITESSE de la 1ʳᵉ reste 3,333 : le régime de passage mesuré (0,821) le confirme à 0,002 près.
	UpshiftRpm = 0.95, -- montée de rapport (régime normalisé). MESURÉ : 2→3 à 0,974 et 3→4 à 0,954.
	UpshiftRpmFirst = 0.82, -- la 1ʳᵉ passe PLUS TÔT. MESURÉ : 1→2 à 0,821–0,827, soit 40,0 km/h.
	DownshiftRpm = 0.45, -- descente de rapport GAZ RELÂCHÉS (régime sous lequel on rétrograde). GTA : 2→1 en roue
	-- libre à 0,404–0,410 (34 km/h, 3 passes) ; 0,45 garde la roue libre 110-30 du banc longitudinal à −1,7 %
	-- (0,35 l'allonge à +9,2 %).
	DownshiftRpmThrottle = 0.35, -- la même, SOUS GAZ (> 0,05). MESURÉ : 2→1 à 0,348–0,353 sous plein gaz (virage
	-- 80, 3 passes, 30,2–30,6 km/h). Avant le 2026-11-12, un seul seuil à 0,45 : au virage 40 la 2ᵉ rétrogradait
	-- à 34–36 km/h alors que GTA y reste (36,5 km/h, 0,79 de gaz) ; la 1ʳᵉ engagée faisait pomper la boîte et
	-- tomber la vitesse à 27 km/h — c'est ce qui faisait « basculer » les balayages de PeakFactor au-delà de 0,55.
	DownshiftMargin = 0.85, -- et seulement si le rapport inférieur resterait sous UpshiftRpm × marge (anti-pompage :
	-- après une montée 1→2 le régime tombe à 0,93 × 1,949 / 3,333 ≈ 0,54, mesuré)
	ReverseHold = 0.25, -- s à l'arrêt, frein maintenu, avant de passer la marche arrière
	ShiftLockout = 0.35, -- s minimum entre deux passages automatiques
	EngineBrakeG = 0.9, -- frein moteur (en g) au rupteur, gaz relâchés (proportionnel au régime). MESURÉ :
	-- en roue libre rapport engagé, 110 → 30 km/h en 115 m ; traînée retirée, le frein moteur vaut 2,7 à
	-- 3,0 m/s² sur toute la plage (≈ 0,29 g). Valeur calée pour reproduire les 115 m sur banc longitudinal.
	LowSpeedFade = 8, -- m/s : vitesse où la perte d'adhérence au démarrage (burnout) disparaît
	-- BURN façon GTA V (2026-11-14) : W + S tenus ensemble, arrêté ou presque, en marche avant → les roues
	-- motrices sont libérées du frein et patinent, les autres restent freinées (native SET_VEHICLE_BURNOUT :
	-- « spins the driven wheels with the others braked, so you don't go anywhere ») ; A / D en même temps font
	-- tourner la voiture autour de l'avant (donuts). Relâcher S lance la voiture. Seuils posés à l'œil, NON
	-- MESURÉS dans FiveM : à caler sur une trace GTA (vitesse de sortie, régime tenu, dérive en donut).
	BurnoutInput = 0.5, -- gaz ET frein au-delà de cette valeur
	BurnoutEnter = 2.5, -- m/s : vitesse sous laquelle le burn démarre
	BurnoutExit = 6, -- m/s : vitesse au-delà de laquelle il s'arrête (hystérésis : la voiture rampe un peu)
	BurnoutYawRate = 80, -- °/s : donut (burn + direction), la voiture pivote autour de l'avant. Posé à l'œil.
	BurnoutYawGain = 6, -- 1/s : vitesse à laquelle la rotation rejoint sa cible
	BurnoutGrip = 0.35, -- part de l'adhérence gardée par les roues qui patinent pendant le burn
	BurnoutPush = 0.25, -- part de la poussée des roues qui patinent transmise au sol pendant le burn (la voiture
	-- reste presque sur place, comme dans GTA ; 1 = poussée entière contre le frein avant)
	-- Départ arrêté, MESURÉ (accel 1-3, m422, FiveM) : à l'arrêt en 1ʳᵉ l'embrayage est à 0,10 ; sous les gaz il
	-- monte (≈ 1,7 /s, la vitesse d'un passage) et GTA transmet la poussée PENDANT ce patinage. Puissance de roue
	-- relevée 0,008 / 0,037 / 0,098 / 0,170 (pleine) à un embrayage de 0,10 / 0,26 / 0,43 / 0,59 ; les quatre
	-- roues restent à la vitesse de la voiture (glissement < 0,08), 0 → 40 km/h en 1,31 s. Avant le 2026-11-12
	-- le moteur partait embrayé (1,0) avec toute la poussée à la première image : en 3D le report de charge
	-- délestait l'avant de 24 %, l'avant patinait (59 km/h de roue à 9 km/h), le régime de roue montait la 2ᵉ à
	-- 10 km/h, les gaz étaient coupés pendant l'embrayage puis la 1ʳᵉ revenait : une seconde sans poussée.
	TorqueFallSlope = 1.2, -- couple au-delà de 0,8 de régime : 1 − pente × (régime − 0,8), plancher 0,6. MESURÉ (accel
	-- 1-3, fenêtres de 0,3 s embrayées, traînée retirée) : poussée relative 0,95 / 0,86–0,88 / 0,78–0,82 à 0,85 /
	-- 0,90 / 0,95, la même en 2ᵉ et en 3ᵉ, soit une pente de 1,2. L'ancienne (2, soit 0,6 au rupteur) était posée
	-- sans mesure. Banc longitudinal : 0-100 −2,3 %, vitesse de pointe +1,2 % ; écart quadratique 6,2 → 5,6 %.
	LaunchClutch = 0.1, -- embrayage à l'arrêt, 1ʳᵉ engagée, gaz relâchés
	LaunchFull = 0.6, -- embrayage à partir duquel toute la poussée passe pendant le départ
	LaunchCurve = 1.3, -- forme de la montée de poussée : ((embrayage − 0,1) / 0,5)^1,3 (écart < 0,05 aux 4 points)
	LaunchSpeed = 1.0, -- m/s : sous cette vitesse, gaz relâchés en 1ʳᵉ, l'embrayage revient à LaunchClutch
	LaunchRpm = 0.42, -- régime tenu pendant le patinage du départ. MESURÉ : 0,31 / 0,40 / 0,45 à un embrayage de
	-- 0,26 / 0,43 / 0,59, puis 0,36–0,46 jusqu'à l'embrayage complet (au-dessus du régime de roue : le moteur
	-- « prend des tours » au départ, ce que le son fait entendre)
	-- La direction, MESURÉE : essai `steerfade` (consigne constante en créneaux alternés), 20 plateaux
	-- établis de 15 à 105 km/h, calibration/m422/steerfade-analyse.json. Le braquage de roue réellement
	-- obtenu à pleine demande vaut 30,62 ° jusqu'à 30 km/h (butée mécanique), puis 21,20 / 14,69 / 10,81 /
	-- 8,27 / 6,61 ° à 45 / 60 / 75 / 90 / 105 km/h. Les six consignes relevées à 60 km/h donnent la même
	-- valeur à 0,39 ° près. L'ancien réglage (fondu linéaire, 28 ; 0,3 ; 1,6) collait à 15 km/h mais
	-- braquait 2,30 × trop à 105 : c'était là toute la direction « deux fois trop forte » vue en 3D.
	SteerFade = 15.0, -- m/s : vitesse où le braquage tombe à la MOITIÉ de SteeringLock (sens changé avec la
	-- forme de la loi, voir ci-dessous). MESURÉ avec SteerFadePower, les deux ajustés ensemble sur les sept
	-- vitesses, plafond et plancher étant eux-mêmes mesurés et non ajustés : RMS 0,78 °, écart relatif
	-- maximal 11,6 % (à 90 km/h). Le fondu linéaire précédent laissait 2,07 ° de RMS et 16 % d'écart.
	SteerFadePower = 2.72, -- exposant du fondu : lock = SteeringLock / (1 + (v/SteerFade)^SteerFadePower).
	-- La forme linéaire ne pouvait pas être à la fois plate sous 30 km/h et lente au-delà, et son résidu
	-- tombait justement dans la bande 30-45 km/h où vivent les essais de virage : au virage 40 km/h elle
	-- donnait 23,6 ° contre 26,17 ° mesurés (−9,7 %), cette forme donne 26,03 ° (−0,5 %). C'est ce qui a
	-- décidé l'adoption : le balayage de PeakFactor se fait sur ce virage.
	SteerLockMeanPct = 0.875, -- butée mécanique, en fraction de SteeringLock. MESURÉ : 30,625 ° pour
	-- fSteeringLock = 35 °. C'est la MOYENNE des deux roues avant — l'intérieure va à 35 °, l'extérieure à
	-- 26,25 °, soit un rapport d'Ackermann de 0,75 — et le moteur n'appliquant qu'un angle unique aux deux
	-- roues, c'est bien la moyenne qu'il doit viser. À 15 et 30 km/h les consignes 0,80 et 1,00 donnent
	-- toutes deux exactement cette valeur. Mettre 1 pour l'ancien comportement.
	SteerMinPct = 0.1889, -- braquage minimal (fraction de SteeringLock) à haute vitesse. MESURÉ : 6,61 °
	-- à 105 km/h. Ce plancher n'agit qu'au-delà de 95 km/h, où il rattrape la queue de la courbe.
	SteerPeakGain = 0, -- CONTREDIT PAR LA MESURE, désactivé. Ce garde-fou imposait au braquage de rester
	-- au-dessus de 1,6 × l'angle de dérive du pic, soit 15,2 ° : il était donc actif dès 100 km/h et
	-- expliquait l'essentiel de l'écart haute vitesse. GTA ne le respecte pas : à 105 km/h il ne braque que
	-- 6,61 °, bien SOUS l'angle du pic latéral (9,5 ° pour PeakFactor 0,5). Le véhicule n'est pas censé
	-- pouvoir atteindre son pic latéral à haute vitesse.
	-- Le lacet, lui, est PUREMENT CINÉMATIQUE dans GTA : sur 20 plateaux, de 15 à 102 km/h et de 0,56 ° à
	-- 16,6 ° de braquage, lacet = v × braquage / 2,811 m à 3,9 % près (écart-type 0,038 m). Ni sous-virage
	-- ni survirage dans cette plage : si le braquage est juste, le lacet suit. C'est le critère de
	-- vérification en 3D.
	CounterSteer = 0, -- aide au contre-braquage (rad par rad de dérive du véhicule) ; 0 = désactivée.
	-- MESURÉ : GTA n'en applique aucune, du moins pas sur l'entrée. Au virage 80, la commande (`steerAngle`,
	-- le volant) monte à 35 ° et y RESTE pendant que la dérive de caisse passe de 0 à 15 ° et que l'angle de
	-- roue tombe de 12,2 ° à 3,1 °. Si le jeu corrigeait la consigne, la commande baisserait. Elle ne baisse
	-- pas : tout se joue en aval, et c'est `SteerSlideV0/K/Min` qui le décrit.
	-- Réduction du braquage quand l'ARRIÈRE glisse, appliquée au braquage disponible APRÈS le fondu en
	-- vitesse et le plancher, mais AVANT la butée mécanique. MESURÉ (2026-11-12) sur 7972 images et
	-- 27 traces (18 cercles à consigne constante `skidpad` + virage 40, virage 80, créneau, slalom) :
	--   réduction = borne(1 − SteerSlideK × (|vLat + b·lacet| − SteerSlideV0), SteerSlideMin, 1)
	-- écart quadratique moyen 0,066 sur un rapport qui descend jusqu'à 0,30 ; résidu par essai : virage 40
	-- −0,002, cercles +0,007, virage 80 +0,027, créneau −0,064 (ce dernier est le résidu de la loi de base
	-- à 60 km/h, pas de la réduction). Le prédicteur est la vitesse latérale de l'essieu ARRIÈRE : c'est le
	-- seul des bons candidats qui ne dépende pas de l'angle de roue (la dérive du pneu AVANT se calcule à
	-- partir de lui, donc la prendre comme prédicteur serait circulaire), et c'est lui qui laisse le moins
	-- de dépendance résiduelle à la vitesse (0,069 contre 0,087 pour l'angle de dérive arrière).
	-- Ce que ça remplace : la note « GTA réduit le braquage quand le véhicule glisse, non calé ». Ce n'était
	-- pas une loi de glisse mais ceci, et le virage 80 s'explique entièrement par là.
	SteerSlideV0 = 1.8, -- m/s : seuil, en dessous duquel rien n'est réduit
	SteerSlideK = 0.18, -- par m/s au-delà du seuil
	SteerSlideMin = 0.30, -- plancher de la réduction
	-- Retard de la direction : l'angle de roue de GTA ne saute pas à sa valeur établie, il la rejoint par un
	-- premier ordre. MESURÉ (2026-11-12) sur 380 fronts de consigne à vitesse tenue, tirés des créneaux
	-- alternés de `steerfade`, des cercles `skidpad` et du créneau : écart sur l'angle de roue 5,52 ° sans
	-- retard, **1,35 ° avec**, sur les tranches de vitesse non contaminées par la glisse dure (15, 30, 60,
	-- 90 km/h). Ce qui a été écarté :
	--   • une butée de VITESSE de braquage : 3,82 ° contre 3,71 ° pour le retard, et l'ajouter au retard ne
	--     gagne que 0,02 ° ; de plus la réponse normalisée ne dépend pas de l'amplitude (à 30 km/h, des
	--     créneaux de 10–20 ° et de 40–50 ° donnent la même courbe malgré 101 et 306 °/s de vitesse de roue),
	--     ce qu'une butée de vitesse ne permettrait pas.
	--   • un τ variable avec la vitesse : les ajustements par tranche donnaient 0,100 s à 15 km/h et 0,050 à
	--     90, mais la forme `max(0,03 ; 0,125 − 0,0012 v)` ne gagne que 1,21 ° contre 1,35 ° — le gain ne
	--     survit pas à un ajustement en une seule passe, donc un seul réglage mesuré vaut mieux que trois
	--     ajustés.
	-- À ne pas confondre avec la colonne `steerAngle` de la télémétrie FiveM, qui est la COMMANDE (le volant,
	-- 0 à 35 °) : elle est PLUS LENTE que les roues (τ de 0,090 s à 15 km/h montant à 0,170 s à 90 km/h, et
	-- croissant quand celui des roues décroît). C'est donc l'animation du volant, pas ce qui pilote les roues.
	SteerTau = 0.08, -- s : constante de temps de l'angle de roue ; 0 = instantané (ancien comportement)
	AbsSlip = 0.18, -- ABS : glissement au-delà duquel le frein est relâché
	AbsRelease = 0.35, -- ABS : fraction du freinage gardée quand il relâche
	-- FREIN À MAIN EN VIRAGE, recalé le 2026-11-13 (« le frein à main ne déclenche pas bien le drift ») sur les
	-- traces GTA `hbcorner_40/70` (consigne 0,5, frein à main 1 s, protocole Bench.hbcorner) :
	--   70 km/h, pendant | GTA : lacet 38,8 °/s (max 47), dérive 9,9 ° (jusqu'à 17), roues arr. −0,63 ; après 3,7 °
	--   ancien (1,0)    | 36,4 (40), dérive 3,2 °, −0,51 ; après 0,6 °  → l'arrière ne décrochait pas
	--   0,8 / 0,6        | tête-à-queue (lacet jusqu'à 159 / 225 °/s) : le blocage passait par le cercle
	--                      d'adhérence et ôtait 60 à 80 % du latéral, la rotation s'emballait
	-- Retenu : le latéral sous frein à main ne passe plus par le cercle d'adhérence (VehicleDynamics, boucle des
	-- pneus), vaut HandbrakeGripRear à faible dérive et revient en entier entre HandbrakeSlideStart et
	-- HandbrakeSlideFull degrés de dérive de la roue : la glisse se borne d'elle-même et se rattrape au relâchement.
	--   0,4 [8-20]       | lacet 57,6 (66), dérive 9,3 °, −0,53 ; après 2,1 ° ; braquage 3,8 ° (GTA 4,0)
	--   (0,5 [6-16] : lacet 42,7 mais dérive 5,1 ; 0,3 [8-20] : dérive 10,9, lacet 63)
	--   60-0 en ligne droite : lacet max 3,0 °/s (GTA 0,13), 17,6 m (GTA 20,0) — la voiture reste droite.
	-- LIMITES : le lacet reste ~1,5 × GTA quand la dérive est juste ; à 40 km/h la dérive reste à 1,3 ° (GTA 4,8)
	-- car notre braquage REMONTE quand la vitesse tombe (9,4 ° contre 4,6 dans GTA). Une passe par réglage.
	HandbrakeSlideStart = 8, -- degrés de dérive de la roue arrière où l'adhérence ôtée commence à revenir
	HandbrakeSlideFull = 20, -- degrés où elle est entièrement revenue
	HandbrakeGripRear = 0.4, -- part du latéral arrière gardée sous frein à main, à faible dérive. Avant le 2026-11-13 :
	-- 1,0, pris sur la ligne droite (« GTA bloque l'arrière sans lui faire perdre son adhérence latérale »), qui
	-- reste vrai : en ligne droite la dérive est nulle, et il n'y a rien à faire glisser.
	-- CONTRÔLE EN L'AIR. MESURÉ (2026-11-12) sur 15 vols au tremplin, 3 passes par cas. GTA
	-- n'applique pas un couple amorti : il applique un couple CONSTANT, saturé par un PLAFOND de
	-- vitesse angulaire, et borne l'assiette en piqué. Les trois valeurs ci-dessous sont lues
	-- séparément, parce qu'une accélération angulaire moyennée sur tout le vol mélange la montée
	-- et le plateau — c'est ce qui donnait 78,4 °/s² en roulis et un tangage incohérent.
	AirPitch = 1.585, -- rad/s² par unité d'entrée, tangage. MESURÉ : +92,9 et −88,8 °/s² (σ 1,0 à
	-- 1,1), soit 90,8 °/s² par unité, symétrie 96 %.
	AirRoll = 1.586, -- idem en roulis : +89,8 et −91,9 °/s² (σ 0,6 à 1,5), symétrie 98 %. Les deux
	-- axes tombent sur le MÊME chiffre à la troisième décimale en radians ; ils restent deux
	-- réglages parce que rien ne garantit que ce soit vrai pour tous les véhicules.
	AirRateMax = 1.066, -- rad/s : plafond de vitesse angulaire en vol, soit 61,1 °/s. MESURÉ : 9
	-- vols sur 15 y butent (σ 1,1) ; les 6 autres sont des cas qui n'ont pas le temps de
	-- l'atteindre. Le plateau est bien du vol libre — un vol tient +60 à +63 °/s pendant 0,15 s à
	-- 1,5 m du sol, les quatre suspensions à zéro. À 0, pas de plafond.
	AirPitchFloor = -0.658, -- rad : assiette minimale en vol, soit −37,7 °. MESURÉ : les trois
	-- passes en piqué s'arrêtent à −37,6 / −37,4 / −38,2 ° et le taux y repasse par zéro à −37,5 /
	-- −37,2 / −38,0. Ce n'est pas l'atterrissage : le véhicule est alors à 1,50 m du sol.
	-- La borne est PROPRE AU PIQUÉ, vérifié avec un vol allongé (tremplin à 450 m, approche à
	-- 90 km/h, 1,24 s de vol) : le roulis atteint ±51 à ±52 ° sur six passes en tournant ENCORE à
	-- ±63 °/s quand il se pose, et jusqu'à 89,6 ° en rotation libre ; le cabrage monte à +40,6 °,
	-- au-delà des 37,7 du piqué, sans fléchir. Il n'y a donc ni borne de roulis ni borne de
	-- cabrage à ajouter, et celle du piqué n'est pas symétrique. Au-delà de +40 ° de cabrage la
	-- queue touche le sol : le tremplin ne peut pas répondre plus loin.
	AirBoundTorque = 12.4, -- rad/s² : couple maximal d'arrêt à la borne d'assiette, soit 710 °/s².
	-- MESURÉ grossièrement — le taux passe de −58 à +13 °/s en ≈ 0,10 s, sur 3 passes. Un ordre de
	-- grandeur au-dessus du couple de contrôle : à la borne, GTA ARRÊTE la rotation, il ne la
	-- contre pas doucement. La valeur exacte n'est pas calée, seul son ordre l'est.
	AirDamp = 0, -- amortissement angulaire en l'air. MESURÉ NUL : sans entrée l'accélération
	-- angulaire vaut +1,1 °/s² et le véhicule garde ses −28 à −32 °/s pendant toute la seconde de
	-- vol. C'est le plafond qui borne la rotation, pas un amortissement. Le réglage reste exposé
	-- pour qui veut l'ancien comportement (il valait 1,5, posé au doigt).
	RightingK = 6, -- couple de redressement doux (rad/s² à 90°), véhicule couché et lent
	RightingSpeed = 3, -- m/s : au-dessus, pas de redressement
	GyrationSq = 1.6, -- m² : rayon de giration² nominal pour convertir accélérations angulaires en couples spécifiques
	-- MESURÉ (2026-11-12) : 8 sous-pas ne suffisaient pas. La stabilité de l'intégration de ω demande
	-- h < 2·KappaPeak·vRef·Iw/(r²·fmax), soit 3,9 × 10⁻⁴ s au démarrage, donc ≈ 43 sous-pas à 60 Hz avec
	-- `IwRel` = 0,03 ; avec 8, le pas était CINQ fois au-delà de la limite et la roue s'emballait au
	-- démarrage. Seul l'écrêtage anti-dépassement le masquait, et il est justement désactivé quand le
	-- couple pousse dans le sens du glissement, c'est-à-dire au démarrage. Symptôme mesuré : un apport de
	-- 9 % de poussée (`SlopeAssist`) faisait patiner la 1ʳᵉ en côte et la boîte pompait.
	-- 16 sous-pas suffisent en pratique : le banc longitudinal reste à 5,30 % (contre 5,29 à 8) et le
	-- résultat ne bouge plus (32 et 64 donnent la même chose à 0,1 % près), ce qui est la signature d'une
	-- intégration devenue stable. Au-delà, on ne paie que du temps de calcul.
	SubSteps = 16, -- sous-pas internes (roues, embrayage, régime)
	CurbBoost = 0, -- gain de régime par compression (effet « curb boost » du jeu) ; 0 = désactivé
}

-- Rapports par défaut lus en mémoire dans le jeu (dernier rapport toujours 0,9). >= 7 rapports : étagement
-- inconnu, interpolé géométriquement entre 3,333 et 0,9 (à mesurer).
local DEFAULT_RATIOS = {
	[1] = { 0.9 },
	[2] = { 3.33, 0.9 },
	[3] = { 3.33, 1.565, 0.9 },
	[4] = { 3.33, 1.826, 1.222, 0.9 },
	[5] = { 3.33, 1.934, 1.358, 1.054, 0.9 },
	[6] = { 3.333, 1.949, 1.392, 1.095, 0.946, 0.9 },
}
local function ratiosFor(n)
	n = math.clamp(math.floor(n), 1, 10)
	if DEFAULT_RATIOS[n] then
		return table.clone(DEFAULT_RATIOS[n])
	end
	local t = {}
	for i = 1, n do
		t[i] = 3.333 * (0.9 / 3.333) ^ ((i - 1) / (n - 1))
	end
	return t
end

local MATERIAL_GRIP = { -- adhérence relative du sol (inspirée de materials.dat), 1 = route
	Asphalt = 1, Concrete = 1, Plastic = 1, SmoothPlastic = 1, Brick = 0.95, Cobblestone = 0.9, Pavement = 1,
	Wood = 0.9, WoodPlanks = 0.9, Metal = 0.9, DiamondPlate = 0.9, CorrodedMetal = 0.9, Slate = 0.95, Granite = 0.95,
	Basalt = 0.95, Rock = 0.9, Limestone = 0.9, Sandstone = 0.85, Grass = 0.7, LeafyGrass = 0.7, Ground = 0.75,
	Mud = 0.55, Sand = 0.55, Snow = 0.45, Glacier = 0.3, Ice = 0.2, Salt = 0.6, Fabric = 0.8, Foil = 0.8,
}
function Dyn.MaterialGrip(materialName)
	return MATERIAL_GRIP[materialName] or 0.9
end

local function sign(x)
	return x > 0 and 1 or (x < 0 and -1 or 0)
end

-- ------------------------------------------------------------------ paramètres + état
function Dyn.new(cfg, comLocal, overrides)
	local T = table.clone(Dyn.Tuning)
	for k, v in pairs(cfg.DriveTuning or {}) do
		T[k] = v
	end
	for k, v in pairs(overrides or {}) do
		T[k] = v
	end
	local h = cfg.Handling or {}
	local P = { T = T }
	P.g = h.GravityMs2 or 9.8
	P.gearbox = h.Gearbox or "auto"
	P.driveForce = h.DriveForce or 0.2
	P.flatVel = h.DriveMaxFlatVelMs or ((h.MaxFlatVelKmh or 140) / 3.6 * 1.2)
	P.initialFlatVel = h.MaxFlatVelMs or (P.flatVel / 1.2)
	P.nGears = (P.gearbox == "electric") and 1 or math.clamp(h.Gears or 5, 1, 10)
	P.ratios = (P.gearbox == "electric") and { 0.9 } or ratiosFor(P.nGears)
	P.reverseRatio = P.ratios[1]
	P.clutchUp = math.max(h.ClutchChangeRateUp or 1.0, 0.1)
	P.clutchDown = math.max(h.ClutchChangeRateDown or 1.0, 0.1)
	P.driveInertia = h.DriveInertia or 1
	local df, dr = h.DriveFront, h.DriveRear -- 2b / 2(1−b), seuils 0,1 / 0,9 déjà appliqués par l'export
	if df == nil then
		local b = h.DriveBiasFront or 0
		df, dr = (b < 0.1 and 0) or (b > 0.9 and 2) or 2 * b, (b < 0.1 and 2) or (b > 0.9 and 0) or 2 * (1 - b)
	end
	P.driveShareF, P.driveShareR = df / 2, dr / 2 -- fractions du couple total (somme 1)
	P.brake = h.BrakeForce or 0.8
	P.brakeF, P.brakeR = h.BrakeFront or 1, h.BrakeRear or 1
	P.handbrake = h.HandBrakeForce or 0.7
	P.muMax = (h.TractionCurveMax or 2) * T.KMu
	P.muMin = (h.TractionCurveMin or 1.8) * T.KMu
	P.alphaPeak = math.max((h.TractionCurveLateralRad or math.rad(h.TractionCurveLateralDeg or 22.5)) * T.PeakFactor, math.rad(3))
	P.tracF, P.tracR = h.TractionFront or 1, h.TractionRear or 1
	P.lossMult = h.TractionLossMult or 1
	P.lowSpeedLoss = h.LowSpeedTractionLossMult or 1
	P.rally = false
	for _, n in ipairs((h.Flags and h.Flags.Handling and h.Flags.Handling.Names) or {}) do
		if n == "HAS_RALLY_TYRES" then
			P.rally = true
		elseif n == "FREEWHEEL_NO_GAS" then
			P.freewheel = true
		elseif n == "CVT" then
			P.cvt = true
		end
	end
	for _, n in ipairs((h.Flags and h.Flags.Model and h.Flags.Model.Names) or {}) do
		if n == "ABS_STD" or n == "ABS_ALT_STD" or n == "ABS_OPTION" then
			P.abs = true
		end
	end
	for _, n in ipairs((h.CarHandling and h.CarHandling.AdvancedFlags and h.CarHandling.AdvancedFlags.Names) or {}) do
		if n == "HARD_REV_LIMIT" or n == "CF_HARD_REV_LIMIT" then
			P.hardRev = true
		end
	end
	-- suspension
	P.upper = h.SuspensionUpperLimit or 0.1
	P.lower = h.SuspensionLowerLimit or -0.15
	P.raise = h.SuspensionRaise or 0
	P.travel = math.max(P.upper - P.lower, 0.05)
	local sf = h.SuspensionForce or 2
	P.suspF, P.suspR = h.SuspensionFront or 1, h.SuspensionRear or 1
	P.kF = sf * P.suspF * P.g / P.travel * T.KSpring
	P.kR = sf * P.suspR * P.g / P.travel * T.KSpring
	P.zetaComp = 2 * (h.SuspensionCompDamp or sf / 2) / sf
	P.zetaReb = 2 * (h.SuspensionReboundDamp or sf / 2) / sf
	P.arbF = (h.AntiRollBarForce or 0) * (h.AntiRollFront or 1) * P.g / P.travel * T.KArb
	P.arbR = (h.AntiRollBarForce or 0) * (h.AntiRollRear or 1) * P.g / P.travel * T.KArb
	P.rcF, P.rcR = h.RollCentreHeightFront or 0, h.RollCentreHeightRear or 0
	-- aéro, direction
	P.dragK = (h.DragAccelCoeff or ((h.DragCoeff or 10) * 1e-4)) * T.KDrag
	P.dfMod = h.DownforceModifier or 0
	P.steerLock = h.SteeringLockRad or math.rad(h.SteeringLockDeg or 35)

	-- roues : position de repos (m, repère local), rayon, rôle
	local wheels = {}
	for bone, w in pairs(cfg.Wheels or {}) do
		table.insert(wheels, {
			bone = bone,
			rest = Vector3.new(w.Position[1], w.Position[2], w.Position[3]),
			radius = math.max(w.Radius or 0.33, 0.1),
			front = w.Front == true,
			left = w.Left == true,
			steer = w.Steer == true,
		})
	end
	table.sort(wheels, function(a, b)
		return a.bone < b.bone
	end)
	local nF, nR = 0, 0
	for _, w in ipairs(wheels) do
		if w.front then
			nF += 1
		else
			nR += 1
		end
	end
	-- répartition statique de la charge selon le centre de gravité (le long de z)
	comLocal = comLocal or Vector3.zero
	local zF, zR = 0, 0
	for _, w in ipairs(wheels) do
		if w.front then
			zF += w.rest.Z / math.max(nF, 1)
		else
			zR += w.rest.Z / math.max(nR, 1)
		end
	end
	local base = math.max(zR - zF, 0.5)
	local fracF = math.clamp((zR - comLocal.Z) / base, 0.15, 0.85)
	-- distance du centre de gravité à l'essieu ARRIÈRE (m) : sert à la vitesse latérale de
	-- l'arrière, vLat + b·lacet, qui pilote la réduction du braquage en glisse (voir Dyn.Tuning)
	P.axleRear = math.clamp(zR - comLocal.Z, 0.3, base)
	for _, w in ipairs(wheels) do
		w.load = P.g * (w.front and fracF / math.max(nF, 1) or (1 - fracF) / math.max(nR, 1)) -- N spécifique au repos
		w.massFrac = w.load / P.g
		w.k = w.front and P.kF or P.kR
		w.driveShare = (w.front and P.driveShareF / math.max(nF, 1)) or (P.driveShareR / math.max(nR, 1))
		w.brakeBias = w.front and P.brakeF or P.brakeR
		w.trac = w.front and P.tracF or P.tracR
		w.rc = (w.front and P.rcF or P.rcR) * (T.RollCentreScale or 1)
		w.Iw = T.IwRel * w.radius * w.radius / 4
		w.x0 = -P.lower -- compression au repos (depuis la détente maximale)
	end
	P.wheels = wheels
	P.nDriven = 0
	for _, w in ipairs(wheels) do
		if w.driveShare > 0 then
			P.nDriven += 1
		end
	end
	-- roues qui patinent pendant le burn : les motrices ; une transmission intégrale garde l'avant freiné
	for _, w in ipairs(wheels) do
		w.burnSpin = w.driveShare > 0 and (P.nDriven < #wheels or not w.front)
	end
	P.nBurnSpin = 0
	for _, w in ipairs(wheels) do
		if w.burnSpin then
			P.nBurnSpin += 1
		end
	end

	local S = {
		rpm = 0.2, gear = 1, clutch = 1, shiftDir = 0, lastShift = -1, time = 0,
		reverseTimer = 0, steerAngle = 0, lock = P.steerLock,
		omega = {}, x = {}, slip = {}, slipV = {}, stick = {}, burnout = false,
	}
	for i, w in ipairs(wheels) do
		S.omega[i] = 0
		S.x[i] = w.x0
		S.slip[i] = 0
		S.slipV[i] = 0
		S.stick[i] = 0
	end
	return { P = P, S = S, T = T }
end

-- Remet l'état dynamique au repos (roues arrêtées, ralenti, 1re) : après un téléport, une remise sur
-- les roues ou une chute rattrapée, sinon les roues lancées en l'air relancent le véhicule.
function Dyn.reset(sim)
	local S, P = sim.S, sim.P
	S.rpm, S.gear, S.clutch, S.shiftDir, S.reverseTimer = 0.2, 1, 1, 0, 0
	S.launch = false
	S.burnout = false
	for i, w in ipairs(P.wheels) do
		S.omega[i] = 0
		S.x[i] = w.x0
		S.slip[i] = 0
		S.slipV[i] = 0
		S.stick[i] = 0
	end
end

-- ------------------------------------------------------------------ morceaux du modèle
local function torqueCurve(rpm, gear, T)
	if gear == 1 or rpm <= 0.8 then
		return 1
	end
	local slope = (T and T.TorqueFallSlope) or 2
	return math.max(1 - slope * (rpm - 0.8), 0.6) -- plat jusqu'à 0,8, puis décroissance linéaire
end

local function muOf(P, s)
	if P.rally then
		return P.muMin + (P.muMax - P.muMin) * math.min(s, 1)
	end
	if s <= 1 then
		return P.muMax
	end
	local t = math.min((s - 1) / P.T.Falloff, 1)
	return P.muMax + (P.muMin - P.muMax) * t
end

local function gearRatio(P, S, vf)
	if S.gear < 0 then
		return P.reverseRatio
	end
	if P.cvt then -- 5,0 au départ, 0,9 à 90 % de la vitesse plate
		local t = math.clamp(math.abs(vf) / (0.9 * P.initialFlatVel), 0, 1)
		return 5 + (0.9 - 5) * t
	end
	return P.ratios[math.clamp(S.gear, 1, P.nGears)]
end

local function shift(S, newGear, dir)
	S.gear, S.shiftDir, S.clutch, S.lastShift = newGear, dir, 0.1, S.time
	S.launch = false
end

-- downforce (« WDV ») ajoutée à l'adhérence de chaque roue, en g
local function wdv(P, v)
	if P.dfMod <= 1 then
		return 0.035
	end
	if P.dfMod <= 100 then
		local t = math.clamp(v / (0.9 * P.initialFlatVel), 0, 1)
		return P.dfMod * 0.035 * t * t
	end
	local t = math.clamp((v / P.initialFlatVel - 0.4) / 0.5, 0, 1)
	return (P.dfMod / 100) * 0.035 * (0.3 + 0.56 * t)
end

-- ------------------------------------------------------------------ pas de simulation
--[[
inputs : { Throttle 0..1, Brake 0..1, Steer -1..1, Handbrake bool, Engine bool, GearUp bool, GearDown bool }
contacts[i] (même ordre que sim.P.wheels) :
  { grounded, x (m, compression depuis la détente max), xdot (m/s, + = se comprime), vLong, vLat (m/s, repère roue :
    avant / droite), grip (adhérence du sol 0..1) }
ctx : { vBody (Vector3 m/s, repère local), wBody (Vector3 rad/s, local), up (haut du monde exprimé en local) }
renvoie out :
  wheels[i] = { Fz, Fx, Fy (m/s², repère roue : haut / avant / droite), steer (rad), point (Vector3 m, local) }
  body = Vector3 (m/s², local) : traînée ; torque = Vector3 (couple spécifique m²/s², local) : aides
  rpm (0,2..1), gear (-1 = arrière), clutch, speed (m/s, + avant), omega[i], travel[i] (m, + = vers le haut),
  lock (rad), steerAngle (rad), reverse (bool)
--- `ctx.slopeSin` (optionnel) : sinus de la pente longitudinale, positif en montee. Sert a l'apport
--- de poussee en pente (SlopeAssist). Absent ou nul, le comportement est celui d'un sol plat.
--- `ctx.up` sert aussi a la borne d'assiette en vol : l'assiette se lit par asin(-up.Z), le roulis
--- se faisant autour de Z et ne touchant donc pas sa composante Z. Un appelant qui omet `up` garde
--- le plafond de vitesse angulaire mais perd la borne (asin(0) place la marge hors d'atteinte).
--- `ctx.wBody` : X = tangage (positif leve le nez), Y = lacet, Z = roulis.
]]
function Dyn.step(sim, inp, contacts, dt, ctx)
	local P, S, T = sim.P, sim.S, sim.T
	dt = math.clamp(dt, 1 / 480, 1 / 15)
	S.time += dt
	local vBody = ctx.vBody or Vector3.zero
	local vf = -vBody.Z -- vitesse vers l'avant
	local speed = vBody.Magnitude
	local engineOn = inp.Engine ~= false

	-- marche arrière façon GTA : à l'arrêt, frein maintenu -> arrière ; en arrière, « frein » accélère
	local throttle, brake = inp.Throttle or 0, inp.Brake or 0
	-- arrêté en marche arrière (S tenu) puis W ajouté : GTA part en burn, pas en marche arrière freinée
	if S.gear < 0 and throttle > T.BurnoutInput and brake > T.BurnoutInput and math.abs(vf) < T.BurnoutEnter then
		S.gear, S.clutch, S.reverseTimer = 1, 1, 0
	end
	if S.gear >= 1 then
		if brake > 0.1 and throttle < 0.05 and vf < 0.8 then
			S.reverseTimer += dt
			if S.reverseTimer >= T.ReverseHold then
				S.gear, S.clutch, S.reverseTimer = -1, 1, 0
			end
		else
			S.reverseTimer = 0
		end
	else
		if throttle > 0.1 and brake < 0.05 and vf > -0.8 then
			S.reverseTimer += dt
			if S.reverseTimer >= T.ReverseHold * 0.5 then
				S.gear, S.clutch, S.reverseTimer = 1, 1, 0
			end
		else
			S.reverseTimer = 0
		end
	end
	local driveIn, brakeIn
	if S.gear < 0 then
		driveIn, brakeIn = brake, throttle
	else
		driveIn, brakeIn = throttle, brake
	end
	if not engineOn then
		driveIn = 0
	end

	-- burn façon GTA (voir Dyn.Tuning, BurnoutInput) : W + S en marche avant, à l'arrêt ou presque
	local wantBurn = S.gear >= 1 and engineOn and throttle > T.BurnoutInput and brake > T.BurnoutInput
	S.burnout = wantBurn and math.abs(vf) < (S.burnout and T.BurnoutExit or T.BurnoutEnter)
	local burnout = S.burnout

	-- rapports manuels (impulsions)
	if inp.GearUp and S.gear >= 1 and S.gear < P.nGears then
		shift(S, S.gear + 1, 1)
	elseif inp.GearDown and S.gear > 1 then
		shift(S, S.gear - 1, -1)
	end

	-- direction : braquage réduit avec la vitesse. Forme MESURÉE dans GTA (essai `steerfade`, 20 plateaux
	-- à consigne constante de 15 à 105 km/h) : une décroissance en 1/(1 + (v/SteerFade)^SteerFadePower),
	-- plafonnée par la butée mécanique et planchée à haute vitesse. Voir Dyn.Tuning pour les mesures.
	local cap = P.steerLock * T.SteerLockMeanPct
	local floor = math.min(math.max(P.alphaPeak * T.SteerPeakGain, P.steerLock * T.SteerMinPct), cap)
	local fade = 1 + (math.abs(vf) / T.SteerFade) ^ T.SteerFadePower
	-- quand l'arrière glisse, le braquage obtenu tombe (MESURÉ ; voir Dyn.Tuning). Le prédicteur est la
	-- vitesse latérale de l'essieu arrière, et la réduction s'applique AVANT la butée : à basse vitesse la
	-- demande dépasse la butée, donc une réduction de 30 % n'y change encore rien — ce que la mesure montre.
	local wYaw = (ctx.wBody or Vector3.zero).Y
	local vRear = vBody.X + P.axleRear * wYaw
	local slide = math.max(0, math.abs(vRear) - T.SteerSlideV0)
	local slideCut = math.clamp(1 - T.SteerSlideK * slide, T.SteerSlideMin, 1)
	S.steerSlideCut = slideCut
	local lock = math.clamp(math.max(P.steerLock / fade, floor) * slideCut, 0, cap)
	local beta = (math.abs(vf) > 2) and math.atan2(vBody.X, math.abs(vf)) or 0
	S.lock = lock
	-- l'angle de roue rejoint sa cible par un premier ordre (MESURÉ ; voir Dyn.Tuning)
	local steerTarget = math.clamp(-(inp.Steer or 0) * lock + T.CounterSteer * beta, -cap, cap)
	local steerA = (T.SteerTau > 0) and (1 - math.exp(-dt / T.SteerTau)) or 1
	S.steerAngle += (steerTarget - S.steerAngle) * steerA
	S.steerTarget = steerTarget

	-- suspension -> charges normales
	local N = {}
	for i, w in ipairs(P.wheels) do
		local c = contacts[i]
		if c and c.grounded then
			local x, xdot = c.x, c.xdot
			local mc = w.massFrac
			local zeta = (xdot > 0) and P.zetaComp or P.zetaReb
			local cd = zeta * 2 * math.sqrt(w.k * mc)
			cd = cd / (1 + cd * dt / mc) -- amortisseur semi-implicite
			local F = w.load + w.k * (x - w.x0) + cd * math.clamp(xdot, -T.DampVMax, T.DampVMax)
			if x > P.travel then
				F += T.BumpK * (x - P.travel)
			end
			N[i] = math.max(F, 0)
			S.x[i] = x
		else
			N[i] = 0
			S.x[i] = 0
		end
	end
	-- anti-roulis par essieu
	for _, front in ipairs({ true, false }) do
		local l, r
		for i, w in ipairs(P.wheels) do
			if w.front == front then
				if w.left then
					l = l or i
				else
					r = r or i
				end
			end
		end
		if l and r and N[l] > 0 and N[r] > 0 then
			local kA = front and P.arbF or P.arbR
			local dF = kA * (S.x[l] - S.x[r])
			N[l] = math.max(N[l] + dF, 0)
			N[r] = math.max(N[r] - dF, 0)
		end
	end

	-- aides : perte d'adhérence au démarrage, déportance
	local lowF = (driveIn > 0.3) and math.clamp(1 - speed / T.LowSpeedFade, 0, 1) or 0
	local lowGrip = 1 / (1 + P.lowSpeedLoss * lowF)
	local extraGrip = wdv(P, speed) * P.g

	-- à l'arrêt sans gaz ni frein, le véhicule se tient (ne roule pas tout seul en pente), comme dans le jeu
	local hold = (driveIn < 0.05 and math.abs(vf) < 0.6) and 0.5 or 0

	-- départ arrêté façon GTA (MESURÉ, voir Dyn.Tuning) : à l'arrêt en 1ʳᵉ sans gaz, l'embrayage revient à
	-- LaunchClutch ; sous les gaz il monte et la poussée passe pendant le patinage (S.launch)
	if S.gear == 1 and math.abs(vf) < (T.LaunchSpeed or 0) and driveIn < 0.05 and (S.clutch >= 1 or S.launch) then
		S.clutch, S.shiftDir, S.launch = T.LaunchClutch or 0.1, 1, true
	end
	local launchHold = S.launch and driveIn < 0.05

	-- sous-pas : régime, embrayage, roues, pneus
	local nSub = math.max(1, T.SubSteps)
	local h = dt / nSub
	local sumFx, sumFy = {}, {}
	for i in ipairs(P.wheels) do
		sumFx[i], sumFy[i] = 0, 0
	end
	for _ = 1, nSub do
		-- vitesse périphérique moyenne des roues motrices
		local drivenSpeed, nd = 0, 0
		for i, w in ipairs(P.wheels) do
			-- burn : le moteur ne voit que les roues qui patinent (l'avant d'une 4×4 est freiné, sans couple)
			if (burnout and w.burnSpin) or (not burnout and w.driveShare > 0) then
				drivenSpeed += math.abs(S.omega[i]) * w.radius
				nd += 1
			end
		end
		drivenSpeed = nd > 0 and drivenSpeed / nd or math.abs(vf)
		local ratio = gearRatio(P, S, vf)
		local gearTop = P.flatVel / math.abs(ratio)
		if S.clutch < 1 and not launchHold then
			S.clutch = math.min(1, S.clutch + ((S.shiftDir >= 0) and P.clutchUp or P.clutchDown) * h)
			-- départ : l'embrayage ne se ferme qu'une fois les roues au régime tenu par le moteur (MESURÉ : GTA plafonne
			-- vers 0,7–0,8 puis ferme à 0,93 s, 24,9 km/h, régime de roue 0,51) ; sinon le régime retombe d'un coup
			if S.launch and drivenSpeed / gearTop < (T.LaunchRpm or 0.42) then
				S.clutch = math.min(S.clutch, 0.8)
			end
		end
		-- passage de rapport : gaz coupés tant que l'embrayage patine ; départ arrêté : la poussée passe
		local thr = (S.clutch < 1 and not S.launch) and 0 or driveIn
		local engage = S.clutch
		if S.launch then
			if S.clutch >= 1 then
				S.launch = false
			else
				local span = math.max((T.LaunchFull or 0.6) - (T.LaunchClutch or 0.1), 1e-3)
				engage = math.clamp((S.clutch - (T.LaunchClutch or 0.1)) / span, 0, 1) ^ (T.LaunchCurve or 1)
			end
		end
		local free = math.clamp(S.rpm + (2 * thr - 1) * 2 * P.driveInertia * h, 0.2, 1)
		local wheelRpm = drivenSpeed / gearTop
		S.rpm = math.clamp(math.max(0.2, wheelRpm * S.clutch + free * (1 - S.clutch)), 0.2, 1.05)
		if S.launch and thr > 0.05 then
			local lr = T.LaunchRpm or 0.42
			local up = math.clamp((S.clutch - (T.LaunchClutch or 0.1)) / 0.4, 0, 1)
			S.rpm = math.max(S.rpm, 0.2 + (lr - 0.2) * up * thr)
		end
		if not engineOn then
			S.rpm = math.max(wheelRpm, 0)
		end
		local cut = 1
		if burnout then
			-- burn : le régime se tient juste sous le rupteur (coupure progressive). Une coupure nette à 1
			-- faisait chuter les roues de 75 à 5 rad/s à chaque rebond (banc 2026-11-14) et la tache noire
			-- ne se formait jamais.
			cut = math.clamp((1 - S.rpm) / 0.05, 0, 1)
		end
		if S.rpm >= 1 then
			if P.hardRev or (not burnout and wheelRpm > (math.abs(vf) / gearTop) * 1.15 + 0.05) then
				-- roues qui patinent (roue délestée d'un différentiel libre, départ) : seul le rupteur borne leur
				-- régime, sinon elles s'emballent sans fin
				cut = 0
			elseif (S.gear == P.nGears or S.gear < 0) and not P.cvt then
				-- MESURÉ : la marche arrière plafonne à −48,8 km/h, soit exactement
				-- DriveMaxFlatVel / 3,333 = 48,6 km/h. Le rupteur s'applique donc aussi en arrière.
				S.clutch = math.min(S.clutch, 0.1) -- le jeu laisse retomber l'embrayage au rupteur
			end
		end
		-- boîte automatique
		if P.gearbox ~= "manual" and not P.cvt and S.clutch >= 1 and S.gear >= 1 and S.time - S.lastShift > T.ShiftLockout then
			local upRpm = (S.gear == 1) and (T.UpshiftRpmFirst or T.UpshiftRpm) or T.UpshiftRpm
			-- roues qui PATINENT (régime > 115 % de celui de la vitesse de la voiture) : la montée se décide sur la
			-- vitesse de la voiture, sinon 2ᵉ à 10 km/h au démarrage puis retour en 1ʳᵉ (GTA reste en 1ʳᵉ).
			-- Sous ce seuil (glissement normal de traction, ~1 %), rien ne change : le régime de roue décide.
			local bodyRpm = math.abs(vf) / gearTop
			local shiftRpm = (S.rpm > bodyRpm * 1.15) and bodyRpm or S.rpm
			if shiftRpm > upRpm and S.gear < P.nGears and driveIn > 0.05 then
				shift(S, S.gear + 1, 1)
			elseif S.gear > 1
				and S.rpm < ((driveIn > 0.05) and (T.DownshiftRpmThrottle or T.DownshiftRpm) or T.DownshiftRpm)
				and S.rpm * P.ratios[S.gear - 1] / ratio < upRpm * T.DownshiftMargin then
				shift(S, S.gear - 1, -1)
			end
		end
		local dir = (S.gear < 0) and -1 or 1
		-- la marche arriere emploie le rapport de 1re (3,333) : elle recoit donc le meme gain
		local gearForce = (S.gear == 1 or S.gear < 0) and (T.FirstGearForce or 1) or 1
		local aDrive = P.driveForce * math.abs(ratio) * torqueCurve(S.rpm, S.gear, T) * thr * engage * cut * P.g * dir
			* gearForce
		-- en pente, GTA pousse plus fort : 54 % de la résistance de la pente récupérés (MESURÉ ; voir
		-- Dyn.Tuning). `ctx.slopeSin` est le sinus de la pente longitudinale, positif en montée ; absent,
		-- l'apport est nul et le comportement est celui d'avant.
		local slopeSin = math.max(ctx.slopeSin or 0, 0)
		if slopeSin > 0 and T.SlopeAssist > 0 then
			aDrive += T.SlopeAssist * P.g * slopeSin * thr * engage * dir
		end
		-- frein moteur, gaz relâchés, embrayé (sauf FREEWHEEL_NO_GAS)
		local engBrake = (not P.freewheel and thr < 0.05 and S.clutch >= 1 and engineOn) and T.EngineBrakeG * P.g * (S.rpm - 0.2) / 0.8 or 0

		for i, w in ipairs(P.wheels) do
			local c = contacts[i] or { grounded = false, vLong = 0, vLat = 0, grip = 1 }
			local vLong, vLat = c.vLong or 0, c.vLat or 0
			local aW = aDrive * w.driveShare
			if burnout then
				-- burn : tout le couple va aux roues qui patinent (une transmission intégrale garde l'avant
				-- freiné et sans couple) ; sans ça la poussée partagée ne vainc pas l'adhérence (essai m422 4×4)
				aW = w.burnSpin and aDrive / math.max(P.nBurnSpin, 1) or 0
			end
			-- « g par roue » × biais d'essieu (2b) : BrakeForce = 1 demande ≈ 4 g en tout ; la roue bloque dès que
			-- BrakeForce > adhérence / 4 (règle connue du jeu), l'ABS relâche alors
			local brakeA = P.brake * math.max(brakeIn, hold) * w.brakeBias * P.g
			if burnout and w.burnSpin then
				brakeA = 0 -- la roue motrice est libérée du frein : elle patine
			end
			local hand = inp.Handbrake and not w.front
			if hand then
				brakeA += P.handbrake * P.g
			end
			if w.driveShare > 0 and engBrake > 0 then
				brakeA += engBrake * w.driveShare
			end
			local omega = S.omega[i]
			local Fx, Fy = 0, 0
			if c.grounded and N[i] > 0 then
				-- à l'arrêt, le plancher VMin annule le glissement donc la force : GTA tient (voir Dyn.Tuning)
				local still = math.abs(vLong) < T.VStick and math.abs(omega * w.radius) < T.VStick
				local vRef = math.max(math.abs(vLong), T.VMin)
				local kappa = (omega * w.radius - vLong) / vRef
				local alpha = math.atan2(vLat, vRef)
				local sk, sa = kappa / T.KappaPeak, alpha / P.alphaPeak
				local s = math.sqrt(sk * sk + sa * sa)
				-- la descente Max → Min est pilotée par la dérive : une roue bloquée garde son pic (mesuré)
				local skF = sk * T.FalloffKappa
				local sFall = math.sqrt(skF * skF + sa * sa)
				S.slip[i] = s
				-- vitesse de glissement au contact (m/s) : ce qui fait la trace et la fumée (VehicleTyreFx)
				local vSlipLong = omega * w.radius - vLong
				S.slipV[i] = math.sqrt(vSlipLong * vSlipLong + vLat * vLat)
				local grip = 1 - (1 - (c.grip or 1)) * P.lossMult
				local fmax = (N[i] * muOf(P, sFall) * w.trac * (w.driveShare > 0 and lowGrip or 1) + extraGrip * w.massFrac * 4) * grip
				if burnout and w.burnSpin then
					fmax *= T.BurnoutGrip -- la roue décroche et patine même sur un moteur modeste (GTA force le patinage)
				end
				if s > 1e-6 then
					local F = fmax * math.min(s, 1)
					Fx = F * sk / s
					Fy = -F * sa / s
				end
				if burnout and not w.burnSpin then
					-- donut : l'avant freiné tient latéralement (pivot), sinon toute la voiture glisse de côté
					Fy = -fmax * math.clamp(sa, -1, 1)
				end
				if hand then
					-- la glisse se borne d'elle-même : l'adhérence perdue revient à mesure que l'angle de dérive de la
					-- roue grandit (HandbrakeSlideStart → HandbrakeSlideFull), sinon la rotation s'emballe
					-- Le latéral d'une roue tenue par le frein à main ne dépend PAS de son blocage (MESURÉ en ligne droite :
					-- GTA bloque l'arrière sans lui ôter son adhérence latérale) : il ne passe pas par le cercle
					-- d'adhérence, où un blocage (glissement −0,5 à −0,7) le réduisait de 60 à 80 % et faisait partir
					-- la voiture en tête-à-queue dès que l'arrière décrochait.
					local aDeg = math.deg(math.abs(alpha))
					local back = math.clamp((aDeg - T.HandbrakeSlideStart) / math.max(T.HandbrakeSlideFull - T.HandbrakeSlideStart, 1e-3), 0, 1)
					Fy = -fmax * math.clamp(sa, -1, 1) * (T.HandbrakeGripRear + (1 - T.HandbrakeGripRear) * back)
				end
				-- plafond latéral proportionnel à la vitesse latérale au contact (MESURÉ ; voir Dyn.Tuning).
				-- Il ne touche QUE le latéral : en ligne droite vLat ≈ 0, donc Fy ≈ 0 de toute façon, et la
				-- motricité n'est pas concernée.
				if T.LatVCap > 0 then
					local latCap = T.LatVCap * math.abs(vLat) * N[i]
					if math.abs(Fy) > latCap then
						Fy = sign(Fy) * latCap
					end
				end
				-- à basse vitesse, ne jamais renvoyer plus que la vitesse latérale à annuler (pas de tremblement)
				local kill = math.abs(vLat) * w.massFrac / dt
				if math.abs(Fy) > kill then
					Fy = sign(Fy) * kill
				end
				-- frottement STATIQUE : ressort sur le glissement accumulé, qui ne s'annule pas à vitesse
				-- nulle (voir Dyn.Tuning). Il décroche à l'adhérence et rend alors la main au glissement.
				if still and not (burnout and w.burnSpin) then
					local vSlip = vLong - omega * w.radius
					S.stick[i] += vSlip * h -- le PAS INTERNE, pas dt : sinon la raideur dépend de SubSteps
					local Fs = -(T.KStick * S.stick[i] + T.CStick * vSlip) * N[i] / P.g
					if math.abs(Fs) > fmax then
						-- décrochage : on rend la force à l'adhérence, et on garde le glissement accumulé
						-- à la valeur qui la produit (sans quoi il continuerait de croître sans effet).
						-- Il FAUT l'affecter : sinon la roue motrice part sans réaction du sol et s'emballe.
						Fs = sign(Fs) * fmax
						S.stick[i] = -sign(vSlip) * fmax * P.g / math.max(T.KStick * N[i], 1e-6)
					end
					Fx = Fs
				else
					S.stick[i] = 0
				end
				-- ABS
				if P.abs and brakeIn > 0 and not hand and kappa < -T.AbsSlip then
					brakeA *= T.AbsRelease
				end
				-- roue : couple moteur, réaction du sol, frein (qui ne peut pas inverser ω)
				local wDrive = (aW - Fx) * w.radius / w.Iw
				local slipBefore = omega * w.radius - vLong
				local o = omega + wDrive * h
				local dB = brakeA * w.radius / w.Iw * h
				if math.abs(o) <= dB then
					o = 0
				else
					o -= sign(o) * dB
				end
				-- pas de dépassement du roulement libre (stabilité des sous-pas)
				if aW == 0 and brakeA == 0 then
					o = vLong / w.radius
				elseif sign(o * w.radius - vLong) ~= sign(slipBefore) and slipBefore ~= 0 and aW * sign(slipBefore) <= 0 then
					o = vLong / w.radius
				end
				S.omega[i] = o
			else
				-- en l'air : la roue tourne librement (moteur), se freine, perd lentement sa vitesse
				local o = omega + (aW * w.radius / w.Iw - 0.5 * omega) * h
				local dB = brakeA * w.radius / w.Iw * h
				if math.abs(o) <= dB then
					o = 0
				else
					o -= sign(o) * dB
				end
				S.omega[i] = o
				S.slip[i] = 0
				S.slipV[i] = 0
			end
			-- burn : la roue garde toute la réaction du sol (elle patine), la caisse n'en reçoit qu'une part
			sumFx[i] += (burnout and w.burnSpin) and Fx * T.BurnoutPush or Fx
			sumFy[i] += Fy
		end
		-- burn : les roues motrices patinent ensemble (deux traces, deux fumées, comme dans GTA) ; sans ça, la
		-- moins chargée part seule et l'autre reste tenue (essai du 2026-11-14 : une seule roue arrière tournait)
		if burnout then
			local top
			for i, w in ipairs(P.wheels) do
				if w.burnSpin and (top == nil or math.abs(S.omega[i]) > math.abs(top)) then
					top = S.omega[i]
				end
			end
			for i, w in ipairs(P.wheels) do
				if w.burnSpin then
					S.omega[i] = top
				end
			end
		end
	end

	-- sorties
	local out = {
		wheels = {}, omega = {}, travel = {}, rpm = S.rpm, gear = S.gear, clutch = S.clutch,
		speed = vf, lock = lock, steerAngle = S.steerAngle, reverse = S.gear < 0, burnout = burnout,
	}
	for i, w in ipairs(P.wheels) do
		local x = S.x[i]
		local wheelCenter = w.rest + Vector3.new(0, P.upper + P.raise - (P.travel - x), 0)
		local contactY = wheelCenter.Y - w.radius
		out.wheels[i] = {
			Fz = N[i],
			Fx = sumFx[i] / nSub,
			Fy = sumFy[i] / nSub,
			steer = w.steer and S.steerAngle or 0,
			point = Vector3.new(wheelCenter.X, contactY, wheelCenter.Z), -- contact (charge normale)
			lateralPoint = Vector3.new(wheelCenter.X, contactY + w.rc, wheelCenter.Z), -- centre de roulis
			slip = S.slip[i], -- glissement combiné (> 1 : au-delà du pic d'adhérence)
			slipV = S.slipV[i], -- vitesse de glissement au contact (m/s)
			grounded = contacts[i] ~= nil and contacts[i].grounded == true,
		}
		out.omega[i] = S.omega[i]
		out.travel[i] = (contacts[i] and contacts[i].grounded) and (x - w.x0) or (-w.x0)
	end
	-- traînée (omnidirectionnelle, au centre de gravité)
	out.body = -vBody * (P.dragK * speed)
	-- aides angulaires (couples spécifiques, repère local)
	local torque = Vector3.zero
	local grounded = 0
	for i in ipairs(P.wheels) do
		if contacts[i] and contacts[i].grounded then
			grounded += 1
		end
	end
	local w = ctx.wBody or Vector3.zero
	if grounded == 0 then
		-- EN L'AIR : couple constant, plafond de vitesse angulaire, borne d'assiette en piqué.
		-- Voir les mesures sur AirPitch / AirRateMax / AirPitchFloor dans Dyn.Tuning.
		local ax = ((inp.Brake or 0) - (inp.Throttle or 0)) * T.AirPitch -- W pique du nez, S le relève
		local az = -(inp.Steer or 0) * T.AirRoll
		-- Le plafond. On ne coupe pas le couple APRÈS franchissement — ça dépasserait de a·dt, soit
		-- 1,5 °/s à 60 Hz, et le résultat dépendrait du pas. On plafonne le couple à ce qui atteint
		-- PILE la limite dans ce pas. L'écrêtage reste à SENS UNIQUE, volontairement : la marge
		-- restante est planchée à zéro, donc le couple ne devient jamais négatif pour ramener une
		-- rotation déjà au-delà. GTA ne ramène rien (c'est la mesure de l'auto-redressement nul),
		-- il refuse seulement d'en ajouter : un véhicule qui part en vrille garde sa vrille.
		if T.AirRateMax > 0 then
			if ax > 0 then
				ax = math.min(ax, math.max(T.AirRateMax - w.X, 0) / dt)
			elseif ax < 0 then
				ax = math.max(ax, -math.max(T.AirRateMax + w.X, 0) / dt)
			end
			if az > 0 then
				az = math.min(az, math.max(T.AirRateMax - w.Z, 0) / dt)
			elseif az < 0 then
				az = math.max(az, -math.max(T.AirRateMax + w.Z, 0) / dt)
			end
		end
		-- La borne d'assiette en piqué. `ctx.up` est le haut du monde exprimé en repère local ; le
		-- roulis se fait autour de Z et ne touche donc pas sa composante Z, si bien que asin(−up.Z)
		-- est l'assiette seule, sans couplage avec le roulis.
		--
		-- `AirPitchFloor` est l'assiette où la rotation S'ARRÊTE, pas celle où le freinage commence.
		-- C'est ce que la mesure donne : en jeu le taux tient −58 °/s puis s'annule en ≈ 0,10 s, et
		-- l'assiette finale est la même aux trois passes. On limite donc le taux de piqué par ce
		-- qu'il reste de marge, comme un freinage qui doit s'arrêter pile au mur :
		-- ω ≤ √(2·AirBoundTorque·marge). À marge nulle la limite vaut zéro, donc le cas « déjà à la
		-- borne » est le même calcul, sans branche séparée.
		local pitchAngle = math.asin(math.clamp(-(ctx.up or Vector3.yAxis).Z, -1, 1))
		local margin = math.max(pitchAngle - T.AirPitchFloor, 0)
		local dive = -w.X -- taux de piqué, compté positif
		-- `margin / dt` borne aussi le taux : c'est celui qui amène exactement à la borne en un
		-- pas, donc rien ne peut la franchir même quand la racine est encore large.
		local diveMax = math.min(math.sqrt(2 * T.AirBoundTorque * margin), margin / dt)
		-- Même structure que le plafond : d'abord l'entrée ne peut pas pousser le piqué au-delà de
		-- ce qui reste admissible. À la borne `diveMax` vaut zéro, donc l'entrée de piqué est
		-- REFUSÉE. C'est indispensable : si on se contente de freiner après coup, l'entrée
		-- réinjecte un pas de rotation que le freinage efface au pas suivant, et l'assiette
		-- descend en escalier indéfiniment (mesuré : 0,75 °/s de fuite, sans fin).
		if ax < 0 then
			ax = math.max(ax, -math.max(diveMax - dive, 0) / dt)
		end
		-- ensuite, si le piqué dépasse déjà ce qui est admissible, il est freiné. C'est le seul
		-- rappel du modèle : le plafond, lui, ne ramène jamais rien.
		local need = (dive - diveMax) / dt
		if need > 0 then
			ax = math.max(ax, math.min(need, T.AirBoundTorque))
		end
		-- Le nez ne REMONTE pas tout seul au-delà : en jeu il revient de −37,6 à −35,5 °, mais une
		-- partie de ce retour est l'atterrissage et je n'ai pas isolé le couple qui le produit.
		-- Le véhicule reste donc à la borne plutôt que d'être repoussé par une valeur inventée.
		torque += (Vector3.new(ax, 0, az) - w * T.AirDamp) * T.GyrationSq
	end
	-- donut : burn + direction, la voiture tourne sur elle-même autour de l'avant (pivot tenu par les roues
	-- avant freinées) ; direction à gauche (Steer < 0) → rotation vers la gauche (+Y)
	if burnout and grounded > 0 and math.abs(inp.Steer or 0) > 0.1 then
		local target = -(inp.Steer or 0) * math.rad(T.BurnoutYawRate)
		local acc = math.clamp((target - w.Y) * T.BurnoutYawGain, -math.rad(400), math.rad(400))
		torque += Vector3.new(0, acc, 0) * T.GyrationSq
	end
	local up = ctx.up or Vector3.yAxis
	if up.Y < 0.7 and speed < T.RightingSpeed and grounded < #P.wheels then
		-- couché ou presque : couple doux vers la position droite
		local axis = Vector3.yAxis:Cross(up)
		torque += (axis * T.RightingK - w * 1.0) * T.GyrationSq
	end
	out.torque = torque
	return out
end

-- Vitesse de pointe théorique (m/s) : là où la poussée du dernier rapport égale la traînée (sans adhérence).
function Dyn.PredictTopSpeed(sim)
	local P = sim.P
	local ratio = P.ratios[P.nGears]
	local gearTop = P.flatVel / ratio
	local best = 0
	for i = 1, 400 do
		local v = gearTop * 1.1 * i / 400
		local rpm = v / gearTop
		local a = P.driveForce * ratio * torqueCurve(rpm, P.nGears, P.T) * P.g
			* ((P.nGears == 1) and (P.T.FirstGearForce or 1) or 1)
		if P.hardRev and rpm >= 1 then
			a = 0
		end
		if a >= P.dragK * v * v then
			best = v
		end
	end
	return best
end

return Dyn

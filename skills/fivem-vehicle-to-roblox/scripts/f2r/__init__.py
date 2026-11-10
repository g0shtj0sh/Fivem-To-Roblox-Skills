"""f2r — pipeline de conversion d'un véhicule FiveM / GTA V vers Roblox.

Modules :
    util       journalisation, hash joaat, extraction d'archives sûre, helpers XML
    inventory  inventaire d'un pack FiveM (stream/, data/, audioconfig/, sfx/...)
    meta       lecture de vehicles.meta, carcols.meta, carvariations.meta, handling.meta
    cwxml      lecture du XML CodeWalker (.yft.xml/.ydr.xml/.ytd.xml/.awc.xml)
    vehicle    assemblage : squelette, pièces, roues, lumières, mods, extras
    textures   DDS -> PNG (<= 1024 px), cartes normales / rugosité
    gltf       écriture GLB (glTF 2.0 binaire) sans dépendance externe
    audio      sons moteur (découpe AWC ou synthèse), klaxon, sirène, clignotant
    roblox     génération du script d'installation Luau + modules runtime
"""

__version__ = "1.0.0"

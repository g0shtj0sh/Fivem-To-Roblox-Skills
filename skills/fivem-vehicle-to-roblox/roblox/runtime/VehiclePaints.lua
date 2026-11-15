--!nonstrict
-- FiveMVehicles/VehiclePaints (ModuleScript, ReplicatedStorage) — GÉNÉRÉ par
-- scripts/f2r/gta_colors.py (lua_module) : ne pas éditer à la main.
-- Palette des 160 peintures de véhicule GTA V (index carvariations / vMenu) : nom d'origine,
-- libellé français, couleur, groupe de menu et finition par défaut. Partagée client / serveur :
-- un menu de custom liste Paints.Group("Classic") ; le serveur applique par
-- VehicleCustomization.SetPaint(model, layer, index, finish).
-- Source des couleurs : documentation alt:V / rebar-altv (docs/data/vehicle-colors.md).

local Paints = {}

Paints.List = {
	[0] = { Name = "Metallic Black", Label = "Noir", Hex = "#0d1116", Group = "Classic", Finish = "Metallic" },
	[1] = { Name = "Metallic Graphite Black", Label = "Noir graphite", Hex = "#1c1d21", Group = "Classic", Finish = "Metallic" },
	[2] = { Name = "Metallic Black Steal", Label = "Noir acier", Hex = "#32383d", Group = "Classic", Finish = "Metallic" },
	[3] = { Name = "Metallic Dark Silver", Label = "Argent foncé", Hex = "#454b4f", Group = "Classic", Finish = "Metallic" },
	[4] = { Name = "Metallic Silver", Label = "Argent", Hex = "#999da0", Group = "Classic", Finish = "Metallic" },
	[5] = { Name = "Metallic Blue Silver", Label = "Argent bleuté", Hex = "#c2c4c6", Group = "Classic", Finish = "Metallic" },
	[6] = { Name = "Metallic Steel Gray", Label = "Gris acier", Hex = "#979a97", Group = "Classic", Finish = "Metallic" },
	[7] = { Name = "Metallic Shadow Silver", Label = "Argent ombré", Hex = "#637380", Group = "Classic", Finish = "Metallic" },
	[8] = { Name = "Metallic Stone Silver", Label = "Argent pierre", Hex = "#63625c", Group = "Classic", Finish = "Metallic" },
	[9] = { Name = "Metallic Midnight Silver", Label = "Argent nuit", Hex = "#3c3f47", Group = "Classic", Finish = "Metallic" },
	[10] = { Name = "Metallic Gun Metal", Label = "Gris canon", Hex = "#444e54", Group = "Classic", Finish = "Metallic" },
	[11] = { Name = "Metallic Anthracite Grey", Label = "Gris anthracite", Hex = "#1d2129", Group = "Classic", Finish = "Metallic" },
	[12] = { Name = "Matte Black", Label = "Noir", Hex = "#13181f", Group = "Matte", Finish = "Matte" },
	[13] = { Name = "Matte Gray", Label = "Gris", Hex = "#26282a", Group = "Matte", Finish = "Matte" },
	[14] = { Name = "Matte Light Grey", Label = "Gris clair", Hex = "#515554", Group = "Matte", Finish = "Matte" },
	[15] = { Name = "Util Black", Label = "Noir", Hex = "#151921", Group = "Utility", Finish = "Classic" },
	[16] = { Name = "Util Black Poly", Label = "Noir poly", Hex = "#1e2429", Group = "Utility", Finish = "Classic" },
	[17] = { Name = "Util Dark silver", Label = "Argent foncé", Hex = "#333a3c", Group = "Utility", Finish = "Classic" },
	[18] = { Name = "Util Silver", Label = "Argent", Hex = "#8c9095", Group = "Utility", Finish = "Classic" },
	[19] = { Name = "Util Gun Metal", Label = "Gris canon", Hex = "#39434d", Group = "Utility", Finish = "Classic" },
	[20] = { Name = "Util Shadow Silver", Label = "Argent ombré", Hex = "#506272", Group = "Utility", Finish = "Classic" },
	[21] = { Name = "Worn Black", Label = "Noir", Hex = "#1e232f", Group = "Worn", Finish = "Worn" },
	[22] = { Name = "Worn Graphite", Label = "Graphite", Hex = "#363a3f", Group = "Worn", Finish = "Worn" },
	[23] = { Name = "Worn Silver Grey", Label = "Gris argent", Hex = "#a0a199", Group = "Worn", Finish = "Worn" },
	[24] = { Name = "Worn Silver", Label = "Argent", Hex = "#d3d3d3", Group = "Worn", Finish = "Worn" },
	[25] = { Name = "Worn Blue Silver", Label = "Argent bleuté", Hex = "#b7bfca", Group = "Worn", Finish = "Worn" },
	[26] = { Name = "Worn Shadow Silver", Label = "Argent ombré", Hex = "#778794", Group = "Worn", Finish = "Worn" },
	[27] = { Name = "Metallic Red", Label = "Rouge", Hex = "#c00e1a", Group = "Classic", Finish = "Metallic" },
	[28] = { Name = "Metallic Torino Red", Label = "Rouge Torino", Hex = "#da1918", Group = "Classic", Finish = "Metallic" },
	[29] = { Name = "Metallic Formula Red", Label = "Rouge Formula", Hex = "#b6111b", Group = "Classic", Finish = "Metallic" },
	[30] = { Name = "Metallic Blaze Red", Label = "Rouge flamme", Hex = "#a51e23", Group = "Classic", Finish = "Metallic" },
	[31] = { Name = "Metallic Graceful Red", Label = "Rouge gracieux", Hex = "#7b1a22", Group = "Classic", Finish = "Metallic" },
	[32] = { Name = "Metallic Garnet Red", Label = "Rouge grenat", Hex = "#8e1b1f", Group = "Classic", Finish = "Metallic" },
	[33] = { Name = "Metallic Desert Red", Label = "Rouge désert", Hex = "#6f1818", Group = "Classic", Finish = "Metallic" },
	[34] = { Name = "Metallic Cabernet Red", Label = "Rouge cabernet", Hex = "#49111d", Group = "Classic", Finish = "Metallic" },
	[35] = { Name = "Metallic Candy Red", Label = "Rouge bonbon", Hex = "#b60f25", Group = "Classic", Finish = "Metallic" },
	[36] = { Name = "Metallic Sunrise Orange", Label = "Orange aurore", Hex = "#d44a17", Group = "Classic", Finish = "Metallic" },
	[37] = { Name = "Metallic Classic Gold", Label = "Or classique", Hex = "#c2944f", Group = "Classic", Finish = "Metallic" },
	[38] = { Name = "Metallic Orange", Label = "Orange", Hex = "#f78616", Group = "Classic", Finish = "Metallic" },
	[39] = { Name = "Matte Red", Label = "Rouge", Hex = "#cf1f21", Group = "Matte", Finish = "Matte" },
	[40] = { Name = "Matte Dark Red", Label = "Rouge foncé", Hex = "#732021", Group = "Matte", Finish = "Matte" },
	[41] = { Name = "Matte Orange", Label = "Orange", Hex = "#f27d20", Group = "Matte", Finish = "Matte" },
	[42] = { Name = "Matte Yellow", Label = "Jaune", Hex = "#ffc91f", Group = "Matte", Finish = "Matte" },
	[43] = { Name = "Util Red", Label = "Rouge", Hex = "#9c1016", Group = "Utility", Finish = "Classic" },
	[44] = { Name = "Util Bright Red", Label = "Rouge vif", Hex = "#de0f18", Group = "Utility", Finish = "Classic" },
	[45] = { Name = "Util Garnet Red", Label = "Rouge grenat", Hex = "#8f1e17", Group = "Utility", Finish = "Classic" },
	[46] = { Name = "Worn Red", Label = "Rouge", Hex = "#a94744", Group = "Worn", Finish = "Worn" },
	[47] = { Name = "Worn Golden Red", Label = "Rouge doré", Hex = "#b16c51", Group = "Worn", Finish = "Worn" },
	[48] = { Name = "Worn Dark Red", Label = "Rouge foncé", Hex = "#371c25", Group = "Worn", Finish = "Worn" },
	[49] = { Name = "Metallic Dark Green", Label = "Vert foncé", Hex = "#132428", Group = "Classic", Finish = "Metallic" },
	[50] = { Name = "Metallic Racing Green", Label = "Vert course", Hex = "#122e2b", Group = "Classic", Finish = "Metallic" },
	[51] = { Name = "Metallic Sea Green", Label = "Vert océan", Hex = "#12383c", Group = "Classic", Finish = "Metallic" },
	[52] = { Name = "Metallic Olive Green", Label = "Vert olive", Hex = "#31423f", Group = "Classic", Finish = "Metallic" },
	[53] = { Name = "Metallic Green", Label = "Vert", Hex = "#155c2d", Group = "Classic", Finish = "Metallic" },
	[54] = { Name = "Metallic Gasoline Blue Green", Label = "Bleu-vert essence", Hex = "#1b6770", Group = "Classic", Finish = "Metallic" },
	[55] = { Name = "Matte Lime Green", Label = "Vert citron", Hex = "#66b81f", Group = "Matte", Finish = "Matte" },
	[56] = { Name = "Util Dark Green", Label = "Vert foncé", Hex = "#22383e", Group = "Utility", Finish = "Classic" },
	[57] = { Name = "Util Green", Label = "Vert", Hex = "#1d5a3f", Group = "Utility", Finish = "Classic" },
	[58] = { Name = "Worn Dark Green", Label = "Vert foncé", Hex = "#2d423f", Group = "Worn", Finish = "Worn" },
	[59] = { Name = "Worn Green", Label = "Vert", Hex = "#45594b", Group = "Worn", Finish = "Worn" },
	[60] = { Name = "Worn Sea Wash", Label = "Vert d'eau", Hex = "#65867f", Group = "Worn", Finish = "Worn" },
	[61] = { Name = "Metallic Midnight Blue", Label = "Bleu nuit", Hex = "#222e46", Group = "Classic", Finish = "Metallic" },
	[62] = { Name = "Metallic Dark Blue", Label = "Bleu foncé", Hex = "#233155", Group = "Classic", Finish = "Metallic" },
	[63] = { Name = "Metallic Saxony Blue", Label = "Bleu saxe", Hex = "#304c7e", Group = "Classic", Finish = "Metallic" },
	[64] = { Name = "Metallic Blue", Label = "Bleu", Hex = "#47578f", Group = "Classic", Finish = "Metallic" },
	[65] = { Name = "Metallic Mariner Blue", Label = "Bleu marin", Hex = "#637ba7", Group = "Classic", Finish = "Metallic" },
	[66] = { Name = "Metallic Harbor Blue", Label = "Bleu port", Hex = "#394762", Group = "Classic", Finish = "Metallic" },
	[67] = { Name = "Metallic Diamond Blue", Label = "Bleu diamant", Hex = "#d6e7f1", Group = "Classic", Finish = "Metallic" },
	[68] = { Name = "Metallic Surf Blue", Label = "Bleu surf", Hex = "#76afbe", Group = "Classic", Finish = "Metallic" },
	[69] = { Name = "Metallic Nautical Blue", Label = "Bleu nautique", Hex = "#345e72", Group = "Classic", Finish = "Metallic" },
	[70] = { Name = "Metallic Bright Blue", Label = "Bleu vif", Hex = "#0b9cf1", Group = "Classic", Finish = "Metallic" },
	[71] = { Name = "Metallic Purple Blue", Label = "Bleu violet", Hex = "#2f2d52", Group = "Classic", Finish = "Metallic" },
	[72] = { Name = "Metallic Spinnaker Blue", Label = "Bleu spinnaker", Hex = "#282c4d", Group = "Classic", Finish = "Metallic" },
	[73] = { Name = "Metallic Ultra Blue", Label = "Bleu ultra", Hex = "#2354a1", Group = "Classic", Finish = "Metallic" },
	[74] = { Name = "Metallic Bright Blue", Label = "Bleu ciel vif", Hex = "#6ea3c6", Group = "Classic", Finish = "Metallic" },
	[75] = { Name = "Util Dark Blue", Label = "Bleu foncé", Hex = "#112552", Group = "Utility", Finish = "Classic" },
	[76] = { Name = "Util Midnight Blue", Label = "Bleu nuit", Hex = "#1b203e", Group = "Utility", Finish = "Classic" },
	[77] = { Name = "Util Blue", Label = "Bleu", Hex = "#275190", Group = "Utility", Finish = "Classic" },
	[78] = { Name = "Util Sea Foam Blue", Label = "Bleu écume", Hex = "#608592", Group = "Utility", Finish = "Classic" },
	[79] = { Name = "Util Lightning blue", Label = "Bleu éclair", Hex = "#2446a8", Group = "Utility", Finish = "Classic" },
	[80] = { Name = "Util Maui Blue Poly", Label = "Bleu Maui", Hex = "#4271e1", Group = "Utility", Finish = "Classic" },
	[81] = { Name = "Util Bright Blue", Label = "Bleu vif", Hex = "#3b39e0", Group = "Utility", Finish = "Classic" },
	[82] = { Name = "Matte Dark Blue", Label = "Bleu foncé", Hex = "#1f2852", Group = "Matte", Finish = "Matte" },
	[83] = { Name = "Matte Blue", Label = "Bleu", Hex = "#253aa7", Group = "Matte", Finish = "Matte" },
	[84] = { Name = "Matte Midnight Blue", Label = "Bleu nuit", Hex = "#1c3551", Group = "Matte", Finish = "Matte" },
	[85] = { Name = "Worn Dark blue", Label = "Bleu foncé", Hex = "#4c5f81", Group = "Worn", Finish = "Worn" },
	[86] = { Name = "Worn Blue", Label = "Bleu", Hex = "#58688e", Group = "Worn", Finish = "Worn" },
	[87] = { Name = "Worn Light blue", Label = "Bleu clair", Hex = "#74b5d8", Group = "Worn", Finish = "Worn" },
	[88] = { Name = "Metallic Taxi Yellow", Label = "Jaune taxi", Hex = "#ffcf20", Group = "Classic", Finish = "Metallic" },
	[89] = { Name = "Metallic Race Yellow", Label = "Jaune course", Hex = "#fbe212", Group = "Classic", Finish = "Metallic" },
	[90] = { Name = "Metallic Bronze", Label = "Bronze", Hex = "#916532", Group = "Classic", Finish = "Metallic" },
	[91] = { Name = "Metallic Yellow Bird", Label = "Jaune canari", Hex = "#e0e13d", Group = "Classic", Finish = "Metallic" },
	[92] = { Name = "Metallic Lime", Label = "Citron vert", Hex = "#98d223", Group = "Classic", Finish = "Metallic" },
	[93] = { Name = "Metallic Champagne", Label = "Champagne", Hex = "#9b8c78", Group = "Classic", Finish = "Metallic" },
	[94] = { Name = "Metallic Pueblo Beige", Label = "Beige Pueblo", Hex = "#503218", Group = "Classic", Finish = "Metallic" },
	[95] = { Name = "Metallic Dark Ivory", Label = "Ivoire foncé", Hex = "#473f2b", Group = "Classic", Finish = "Metallic" },
	[96] = { Name = "Metallic Choco Brown", Label = "Brun chocolat", Hex = "#221b19", Group = "Classic", Finish = "Metallic" },
	[97] = { Name = "Metallic Golden Brown", Label = "Brun doré", Hex = "#653f23", Group = "Classic", Finish = "Metallic" },
	[98] = { Name = "Metallic Light Brown", Label = "Brun clair", Hex = "#775c3e", Group = "Classic", Finish = "Metallic" },
	[99] = { Name = "Metallic Straw Beige", Label = "Beige paille", Hex = "#ac9975", Group = "Classic", Finish = "Metallic" },
	[100] = { Name = "Metallic Moss Brown", Label = "Brun mousse", Hex = "#6c6b4b", Group = "Classic", Finish = "Metallic" },
	[101] = { Name = "Metallic Biston Brown", Label = "Brun bistre", Hex = "#402e2b", Group = "Classic", Finish = "Metallic" },
	[102] = { Name = "Metallic Beechwood", Label = "Hêtre", Hex = "#a4965f", Group = "Classic", Finish = "Metallic" },
	[103] = { Name = "Metallic Dark Beechwood", Label = "Hêtre foncé", Hex = "#46231a", Group = "Classic", Finish = "Metallic" },
	[104] = { Name = "Metallic Choco Orange", Label = "Orange chocolat", Hex = "#752b19", Group = "Classic", Finish = "Metallic" },
	[105] = { Name = "Metallic Beach Sand", Label = "Sable", Hex = "#bfae7b", Group = "Classic", Finish = "Metallic" },
	[106] = { Name = "Metallic Sun Bleeched Sand", Label = "Sable délavé", Hex = "#dfd5b2", Group = "Classic", Finish = "Metallic" },
	[107] = { Name = "Metallic Cream", Label = "Crème", Hex = "#f7edd5", Group = "Classic", Finish = "Metallic" },
	[108] = { Name = "Util Brown", Label = "Brun", Hex = "#3a2a1b", Group = "Utility", Finish = "Classic" },
	[109] = { Name = "Util Medium Brown", Label = "Brun moyen", Hex = "#785f33", Group = "Utility", Finish = "Classic" },
	[110] = { Name = "Util Light Brown", Label = "Brun clair", Hex = "#b5a079", Group = "Utility", Finish = "Classic" },
	[111] = { Name = "Metallic White", Label = "Blanc", Hex = "#fffff6", Group = "Classic", Finish = "Metallic" },
	[112] = { Name = "Metallic Frost White", Label = "Blanc givré", Hex = "#eaeaea", Group = "Classic", Finish = "Metallic" },
	[113] = { Name = "Worn Honey Beige", Label = "Beige miel", Hex = "#b0ab94", Group = "Worn", Finish = "Worn" },
	[114] = { Name = "Worn Brown", Label = "Brun", Hex = "#453831", Group = "Worn", Finish = "Worn" },
	[115] = { Name = "Worn Dark Brown", Label = "Brun foncé", Hex = "#2a282b", Group = "Worn", Finish = "Worn" },
	[116] = { Name = "Worn straw beige", Label = "Beige paille", Hex = "#726c57", Group = "Worn", Finish = "Worn" },
	[117] = { Name = "Brushed Steel", Label = "Acier brossé", Hex = "#6a747c", Group = "Metals", Finish = "Metal" },
	[118] = { Name = "Brushed Black steel", Label = "Acier noir brossé", Hex = "#354158", Group = "Metals", Finish = "Metal" },
	[119] = { Name = "Brushed Aluminium", Label = "Aluminium brossé", Hex = "#9ba0a8", Group = "Metals", Finish = "Metal" },
	[120] = { Name = "Chrome", Label = "Chrome", Hex = "#5870a1", Group = "Chrome", Finish = "Chrome" },
	[121] = { Name = "Worn Off White", Label = "Blanc cassé", Hex = "#eae6de", Group = "Worn", Finish = "Worn" },
	[122] = { Name = "Util Off White", Label = "Blanc cassé", Hex = "#dfddd0", Group = "Utility", Finish = "Classic" },
	[123] = { Name = "Worn Orange", Label = "Orange", Hex = "#f2ad2e", Group = "Worn", Finish = "Worn" },
	[124] = { Name = "Worn Light Orange", Label = "Orange clair", Hex = "#f9a458", Group = "Worn", Finish = "Worn" },
	[125] = { Name = "Metallic Securicor Green", Label = "Vert Securicor", Hex = "#83c566", Group = "Classic", Finish = "Metallic" },
	[126] = { Name = "Worn Taxi Yellow", Label = "Jaune taxi", Hex = "#f1cc40", Group = "Worn", Finish = "Worn" },
	[127] = { Name = "police car blue", Label = "Bleu police", Hex = "#4cc3da", Group = "Classic", Finish = "Metallic" },
	[128] = { Name = "Matte Green", Label = "Vert", Hex = "#4e6443", Group = "Matte", Finish = "Matte" },
	[129] = { Name = "Matte Brown", Label = "Brun", Hex = "#bcac8f", Group = "Matte", Finish = "Matte" },
	[130] = { Name = "Worn Orange", Label = "Orange pâle", Hex = "#f8b658", Group = "Worn", Finish = "Worn" },
	[131] = { Name = "Matte White", Label = "Blanc", Hex = "#fcf9f1", Group = "Matte", Finish = "Matte" },
	[132] = { Name = "Worn White", Label = "Blanc", Hex = "#fffffb", Group = "Worn", Finish = "Worn" },
	[133] = { Name = "Worn Olive Army Green", Label = "Vert armée", Hex = "#81844c", Group = "Worn", Finish = "Worn" },
	[134] = { Name = "Pure White", Label = "Blanc pur", Hex = "#ffffff", Group = "Classic", Finish = "Metallic" },
	[135] = { Name = "Hot Pink", Label = "Rose vif", Hex = "#f21f99", Group = "Classic", Finish = "Metallic" },
	[136] = { Name = "Salmon pink", Label = "Rose saumon", Hex = "#fdd6cd", Group = "Classic", Finish = "Metallic" },
	[137] = { Name = "Metallic Vermillion Pink", Label = "Rose vermillon", Hex = "#df5891", Group = "Classic", Finish = "Metallic" },
	[138] = { Name = "Orange", Label = "Orange vif", Hex = "#f6ae20", Group = "Classic", Finish = "Metallic" },
	[139] = { Name = "Green", Label = "Vert pomme", Hex = "#b0ee6e", Group = "Classic", Finish = "Metallic" },
	[140] = { Name = "Blue", Label = "Bleu cyan", Hex = "#08e9fa", Group = "Classic", Finish = "Metallic" },
	[141] = { Name = "Mettalic Black Blue", Label = "Noir bleuté", Hex = "#0a0c17", Group = "Classic", Finish = "Metallic" },
	[142] = { Name = "Metallic Black Purple", Label = "Noir violacé", Hex = "#0c0d18", Group = "Classic", Finish = "Metallic" },
	[143] = { Name = "Metallic Black Red", Label = "Noir rougeâtre", Hex = "#0e0d14", Group = "Classic", Finish = "Metallic" },
	[144] = { Name = "hunter green", Label = "Vert chasseur", Hex = "#9f9e8a", Group = "Classic", Finish = "Metallic" },
	[145] = { Name = "Metallic Purple", Label = "Violet", Hex = "#621276", Group = "Classic", Finish = "Metallic" },
	[146] = { Name = "Metaillic V Dark Blue", Label = "Bleu très foncé", Hex = "#0b1421", Group = "Classic", Finish = "Metallic" },
	[147] = { Name = "MODSHOP BLACK1", Label = "Noir atelier", Hex = "#11141a", Group = "Classic", Finish = "Metallic" },
	[148] = { Name = "Matte Purple", Label = "Violet", Hex = "#6b1f7b", Group = "Matte", Finish = "Matte" },
	[149] = { Name = "Matte Dark Purple", Label = "Violet foncé", Hex = "#1e1d22", Group = "Matte", Finish = "Matte" },
	[150] = { Name = "Metallic Lava Red", Label = "Rouge lave", Hex = "#bc1917", Group = "Classic", Finish = "Metallic" },
	[151] = { Name = "Matte Forest Green", Label = "Vert forêt", Hex = "#2d362a", Group = "Matte", Finish = "Matte" },
	[152] = { Name = "Matte Olive Drab", Label = "Vert olive", Hex = "#696748", Group = "Matte", Finish = "Matte" },
	[153] = { Name = "Matte Desert Brown", Label = "Brun désert", Hex = "#7a6c55", Group = "Matte", Finish = "Matte" },
	[154] = { Name = "Matte Desert Tan", Label = "Beige désert", Hex = "#c3b492", Group = "Matte", Finish = "Matte" },
	[155] = { Name = "Matte Foilage Green", Label = "Vert feuillage", Hex = "#5a6352", Group = "Matte", Finish = "Matte" },
	[156] = { Name = "DEFAULT ALLOY COLOR", Label = "Alliage d'origine", Hex = "#81827f", Group = "Alloy", Finish = "Metallic" },
	[157] = { Name = "Epsilon Blue", Label = "Bleu Epsilon", Hex = "#afd6e4", Group = "Classic", Finish = "Metallic" },
	[158] = { Name = "Pure Gold", Label = "Or pur", Hex = "#7a6440", Group = "Metals", Finish = "Metal" },
	[159] = { Name = "Brushed Gold", Label = "Or brossé", Hex = "#7f6a48", Group = "Metals", Finish = "Metal" },
}

-- Groupes affichés par un menu (ordre de GTA / vMenu) et finitions applicables.
Paints.Groups = { "Classic", "Matte", "Metals", "Chrome", "Utility", "Worn", "Alloy" }
Paints.Finishes = { "Classic", "Metallic", "Pearl", "Matte", "Metal", "Chrome", "Worn" }

for _, p in pairs(Paints.List) do
	p.Color = Color3.fromHex(p.Hex)
end

function Paints.Get(index)
	return type(index) == "number" and Paints.List[index] or nil
end

-- Index de la palette (ordre croissant) d'un groupe.
function Paints.Group(name)
	local out = {}
	for i = 0, 159 do
		local p = Paints.List[i]
		if p and p.Group == name then
			table.insert(out, i)
		end
	end
	return out
end

-- Peinture de la palette la plus proche d'une couleur (retour à une couleur du jeu).
function Paints.Nearest(color)
	local best, bestD = 0, math.huge
	for i, p in pairs(Paints.List) do
		local d = (p.Color.R - color.R) ^ 2 + (p.Color.G - color.G) ^ 2 + (p.Color.B - color.B) ^ 2
		if d < bestD then
			best, bestD = i, d
		end
	end
	return best
end

return Paints

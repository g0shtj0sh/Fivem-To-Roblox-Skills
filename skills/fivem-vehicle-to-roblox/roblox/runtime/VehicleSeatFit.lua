--!nonstrict
-- VehicleSeatFit (ModuleScript, ReplicatedStorage.FiveMVehicles)
-- Adapte le corps d'un occupant à l'habitacle : ni bras dans la portière, ni tête dans le pavillon,
-- ni pieds dans le plancher.
--
-- Données : CONFIG.Cabin (calculé par le convertisseur, f2r/cabin.py) = grille de cellules
-- « interdites » (air extérieur, ou enfoncé de plus de Tolerance dans une paroi), repère du véhicule
-- (VehicleRoot), mètres.
--
-- Déroulé :
--  1. client de l'occupant (c'est lui qui anime son personnage) : mesure 27 points par pièce du
--     corps assis ; cherche le réglage qui les ramène tous dans l'habitacle, par ordre de
--     préférence : le corps le plus grand (k), puis le plus large (kw), puis le siège le moins
--     reculé, puis le plus bas (posé sur le coussin, pas en l'air) ;
--  2. serveur (VehicleEvent « Fit ») : vérifie que le joueur est assis dans ce véhicule, borne les
--     valeurs, applique les échelles (R15 : BodyHeight/Width/Depth/HeadScale ; R6 : ScaleTo), décale
--     la soudure du siège (hauteur, recul) et masque les accessoires qui dépassent encore (un
--     chapeau ne doit pas rapetisser tout le corps) ;
--  3. le client remesure et recommence au besoin (5 passes au plus).
-- À la descente, le serveur rend au joueur sa taille et ses accessoires (Restore).
-- Désactiver pour un véhicule : attribut SeatFit = false sur le modèle.

local Fit = {}

Fit.MinScale = 0.5 -- réduction maximale de tout le corps
Fit.MinWidth = 0.6 -- réduction maximale de la largeur, en plus
Fit.Step = 0.02
Fit.Passes = 5
Fit.SettleTime = 0.45 -- s : le temps que l'animation d'assise se pose
-- Hauteur d'assise cherchée (mètres, relative à l'état actuel) : le siège Roblox n'est pas à la
-- hauteur du coussin du modèle (mesuré : corps enfoncé dans le coussin, pieds dans le plancher).
Fit.LiftMin = -0.3
Fit.LiftMax = 0.4
Fit.LiftStep = 0.02
-- Recul du siège cherché (mètres, + = vers l'arrière), du moins reculé au plus reculé
Fit.Shifts = { 0, 0.05, 0.1, 0.15, 0.2, -0.05 }

local grids = setmetatable({}, { __mode = "k" })

local function config(model)
	local cfgModule = model:FindFirstChild("VehicleConfig")
	if not cfgModule then
		return nil
	end
	local ok, cfg = pcall(require, cfgModule)
	return ok and cfg or nil
end

-- Grille décodée (buffer d'un octet par cellule), mise en cache par modèle
function Fit.Grid(model)
	local g = grids[model]
	if g ~= nil then
		return g or nil
	end
	local cfg = config(model)
	local c = cfg and cfg.Cabin
	if not c or c.Open or type(c.Bad) ~= "string" then
		grids[model] = false
		return nil
	end
	local nx, ny, nz = c.Dims[1], c.Dims[2], c.Dims[3]
	local n = nx * ny * nz
	local b = buffer.create(n)
	local i, v = 0, 0
	for tok in string.gmatch(c.Bad, "[^,]+") do
		local run = tonumber(tok, 36)
		if v == 1 and run > 0 then
			buffer.fill(b, i, 1, math.min(run, n - i))
		end
		i += run
		v = 1 - v
	end
	g = {
		buf = b,
		nx = nx,
		ny = ny,
		nz = nz,
		ox = c.Origin[1],
		oy = c.Origin[2],
		oz = c.Origin[3],
		cell = c.Cell,
		spm = cfg.StudsPerMeter or 3.571,
	}
	grids[model] = g
	return g
end

-- p : Vector3 en mètres, repère du véhicule
function Fit.IsBad(g, p)
	local ix = math.floor((p.X - g.ox) / g.cell)
	local iy = math.floor((p.Y - g.oy) / g.cell)
	local iz = math.floor((p.Z - g.oz) / g.cell)
	if ix < 0 or iy < 0 or iz < 0 or ix >= g.nx or iy >= g.ny or iz >= g.nz then
		return true
	end
	return buffer.readu8(g.buf, ix + g.nx * (iy + g.ny * iz)) == 1
end

local GRID3 = { -1, 0, 1 }

local function partPoints(p, rcf, spm, out)
	local h = p.Size / 2
	local cf = p.CFrame
	for _, sx in ipairs(GRID3) do
		for _, sy in ipairs(GRID3) do
			for _, sz in ipairs(GRID3) do
				local w = cf:PointToWorldSpace(Vector3.new(sx * h.X, sy * h.Y, sz * h.Z))
				table.insert(out, rcf:PointToObjectSpace(w) / spm)
			end
		end
	end
	return out
end

local function isAccessoryPart(p)
	return p.Parent ~= nil and p.Parent:IsA("Accessory")
end

-- Points du corps (mètres, repère du véhicule) : 27 par pièce visible, sans les accessoires
function Fit.Sample(char, root, spm)
	local pts = {}
	for _, p in ipairs(char:GetDescendants()) do
		if p:IsA("BasePart") and p.Name ~= "HumanoidRootPart" and p.Transparency < 0.99 and not isAccessoryPart(p) then
			partPoints(p, root.CFrame, spm, pts)
		end
	end
	return pts
end

-- Accessoires visibles dont au moins un point sort de l'habitacle
function Fit.OutsideAccessories(g, char, root)
	local out = {}
	for _, acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") then
			local h = acc:FindFirstChildWhichIsA("BasePart")
			if h and h.Transparency < 0.99 then
				for _, p in ipairs(partPoints(h, root.CFrame, g.spm, {})) do
					if Fit.IsBad(g, p) then
						table.insert(out, acc)
						break
					end
				end
			end
		end
	end
	return out
end

function Fit.CountBad(g, pts)
	local n = 0
	for _, p in ipairs(pts) do
		if Fit.IsBad(g, p) then
			n += 1
		end
	end
	return n
end

-- Dessus du siège, mètres, repère du véhicule (centre de la réduction)
function Fit.Anchor(seat, root, spm)
	local top = seat.CFrame:PointToWorldSpace(Vector3.new(0, seat.Size.Y / 2, 0))
	return root.CFrame:PointToObjectSpace(top) / spm
end

local function allGood(g, pts, a, sx, sy, sz, lift, shift)
	for _, p in ipairs(pts) do
		local q = Vector3.new(a.X + (p.X - a.X) * sx, a.Y + lift + (p.Y - a.Y) * sy, a.Z + shift + (p.Z - a.Z) * sz)
		if Fit.IsBad(g, q) then
			return false
		end
	end
	return true
end

-- Réglage (relatif à l'état actuel) qui ramène tous les points dans l'habitacle.
-- Renvoie k, kw, lift (m, + = plus haut), shift (m, + = plus en arrière), ok.
function Fit.Solve(g, pts, anchor, minK, minW)
	minK = minK or Fit.MinScale
	minW = minW or Fit.MinWidth
	local k = 1
	while k >= minK - 1e-6 do
		local kw = 1
		while kw >= minW - 1e-6 do
			for _, shift in ipairs(Fit.Shifts) do
				local lift = Fit.LiftMin
				while lift <= Fit.LiftMax + 1e-6 do
					if allGood(g, pts, anchor, k * kw, k, k, lift, shift) then
						return k, kw, lift, shift, true
					end
					lift += Fit.LiftStep
				end
			end
			kw -= Fit.Step
		end
		k -= Fit.Step
	end
	return minK, minW, 0, 0, false
end

-- ------------------------------------------------------------------ serveur

local SCALES = { "BodyHeightScale", "BodyWidthScale", "BodyDepthScale", "HeadScale" }
local baseC0 = setmetatable({}, { __mode = "k" })

local function scaleValue(hum, name)
	local v = hum:FindFirstChild(name)
	return v and v:IsA("NumberValue") and v or nil
end

local function isNum(x)
	return type(x) == "number" and x == x and x > -1e6 and x < 1e6
end

local function fmtFit(k, kw, dy, dz)
	return string.format("%.3f,%.3f,%.3f,%.3f", k, kw, dy, dz)
end
Fit.Format = fmtFit

local function setAccessoryHidden(acc, hidden)
	for _, p in ipairs(acc:GetDescendants()) do
		if p:IsA("BasePart") then
			if hidden then
				if p:GetAttribute("F2RFitTransparency") == nil then
					p:SetAttribute("F2RFitTransparency", p.Transparency)
				end
				p.Transparency = 1
			elseif p:GetAttribute("F2RFitTransparency") ~= nil then
				p.Transparency = p:GetAttribute("F2RFitTransparency")
				p:SetAttribute("F2RFitTransparency", nil)
			end
		end
	end
end

-- k : tout le corps, kw : largeur en plus, dy : abaissement de la soudure du siège (studs),
-- dz : recul (studs). Tous absolus (relatifs à la taille d'origine du joueur). hide : accessoires
-- du joueur à masquer.
function Fit.Apply(player, model, k, kw, dy, dz, hide)
	if not (isNum(k) and isNum(kw) and isNum(dy) and isNum(dz)) or model:GetAttribute("SeatFit") == false then
		return false
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if not seat or not seat:IsDescendantOf(model) then
		return false
	end
	k = math.clamp(k, Fit.MinScale, 1)
	kw = math.clamp(kw, Fit.MinWidth, 1)
	dy = math.clamp(dy, -4, 4)
	dz = math.clamp(dz, -3, 3)
	local r15 = hum.RigType == Enum.HumanoidRigType.R15 and scaleValue(hum, "BodyHeightScale") ~= nil
	if hum:GetAttribute("F2RFitOrig") == nil then
		if r15 then
			local o = {}
			for i, n in ipairs(SCALES) do
				local v = scaleValue(hum, n)
				o[i] = string.format("%.5f", v and v.Value or 1)
			end
			hum:SetAttribute("F2RFitOrig", "R15:" .. table.concat(o, ","))
		else
			hum:SetAttribute("F2RFitOrig", string.format("R6:%.5f", char:GetScale()))
		end
	end
	local orig = hum:GetAttribute("F2RFitOrig")
	if r15 and string.sub(orig, 1, 4) == "R15:" then
		local o = {}
		for x in string.gmatch(string.sub(orig, 5), "[^,]+") do
			table.insert(o, tonumber(x))
		end
		local f = { k, k * kw, k, k }
		for i, n in ipairs(SCALES) do
			local v = scaleValue(hum, n)
			if v and o[i] then
				v.Value = o[i] * f[i]
			end
		end
	elseif string.sub(orig, 1, 3) == "R6:" then
		char:ScaleTo(tonumber(string.sub(orig, 4)) * k * kw)
	end
	local weld = seat:FindFirstChild("SeatWeld")
	if weld and weld:IsA("Weld") then
		if baseC0[weld] == nil then
			baseC0[weld] = weld.C0
		end
		weld.C0 = CFrame.new(0, -dy, dz) * baseC0[weld]
	end
	if type(hide) == "table" then
		for _, acc in ipairs(hide) do
			if typeof(acc) == "Instance" and acc:IsA("Accessory") and acc.Parent == char then
				setAccessoryHidden(acc, true)
			end
		end
	end
	hum:SetAttribute("F2RFit", fmtFit(k, kw, dy, dz))
	return true
end

-- Taille et accessoires d'origine rendus (descente, changement de siège)
function Fit.Restore(hum)
	if not hum or not hum.Parent then
		return false
	end
	local char = hum.Parent
	for _, acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") then
			setAccessoryHidden(acc, false)
		end
	end
	local orig = hum:GetAttribute("F2RFitOrig")
	if orig == nil then
		return false
	end
	if string.sub(orig, 1, 4) == "R15:" then
		local i = 0
		for x in string.gmatch(string.sub(orig, 5), "[^,]+") do
			i += 1
			local v = scaleValue(hum, SCALES[i])
			if v then
				v.Value = tonumber(x)
			end
		end
	elseif string.sub(orig, 1, 3) == "R6:" then
		char:ScaleTo(tonumber(string.sub(orig, 4)))
	end
	hum:SetAttribute("F2RFitOrig", nil)
	hum:SetAttribute("F2RFit", nil)
	return true
end

-- ------------------------------------------------------------------ client

-- Lancé par FiveMVehiclesClient quand le joueur local s'assoit. Résultat dans l'attribut
-- F2RFitResult du personnage (local) : « ok|k|kw|dy|dz|points hors habitacle|accessoires masqués|passes ».
function Fit.RunClient(model, seat, remote)
	local g = Fit.Grid(model)
	local player = game:GetService("Players").LocalPlayer
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not g or not hum or model:GetAttribute("SeatFit") == false then
		return
	end
	char:SetAttribute("F2RFitResult", "running")
	task.wait(Fit.SettleTime)
	local root = model.PrimaryPart
	local k, kw, dy, dz = 1, 1, 0, 0 -- absolus ; dy, dz en studs (soudure du siège)
	local bad, passes, solved = 0, 0, true
	local function send(hide)
		local want = fmtFit(k, kw, math.clamp(dy, -4, 4), math.clamp(dz, -3, 3))
		remote:FireServer(model, "Fit", k, kw, dy, dz, hide)
		local t0 = os.clock()
		while hum:GetAttribute("F2RFit") ~= want and os.clock() - t0 < 2 do
			task.wait()
		end
		task.wait(0.2) -- mise à l'échelle et soudure appliquées ici aussi
	end
	for pass = 1, Fit.Passes do
		if hum.SeatPart ~= seat or not root then
			char:SetAttribute("F2RFitResult", "cancelled")
			return
		end
		passes = pass
		local pts = Fit.Sample(char, root, g.spm)
		bad = Fit.CountBad(g, pts)
		local rk, rkw, lift, shift, ok = Fit.Solve(g, pts, Fit.Anchor(seat, root, g.spm), Fit.MinScale / k, Fit.MinWidth / kw)
		solved = ok
		if bad == 0 and rk >= 0.999 and rkw >= 0.999 and math.abs(lift) < Fit.LiftStep * 0.5 and shift == 0 then
			break -- dedans, et rien de plus grand ni de plus bas possible
		end
		k = math.max(Fit.MinScale, k * rk)
		kw = math.max(Fit.MinWidth, kw * rkw)
		dy = math.clamp(dy - lift * g.spm, -4, 4)
		dz = math.clamp(dz + shift * g.spm, -3, 3)
		send(nil)
	end
	local hidden = 0
	if hum.SeatPart == seat and root then
		bad = Fit.CountBad(g, Fit.Sample(char, root, g.spm)) -- état final, après la dernière passe
		local acc = Fit.OutsideAccessories(g, char, root)
		hidden = #acc
		if hidden > 0 then
			send(acc)
		end
	end
	char:SetAttribute(
		"F2RFitResult",
		string.format("%s|%.3f|%.3f|%.3f|%.3f|%d|%d|%d", bad == 0 and "ok" or (solved and "partial" or "nofit"), k, kw, dy, dz, bad, hidden, passes)
	)
end

return Fit

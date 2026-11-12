--!nonstrict
--[[
	Analyse des vols au tremplin par air.luau, le même code pour les deux colonnes.
		lune run tools/drive-compare/vol.luau <trace.json> [<trace.json> …]
	Lit les traces FiveM (`meta.columns`, `samples`, `meta.params.axis/amp`) et les traces Roblox exportées par
	DriveBench (`columns`, `samples`, `axis`, `amp`, ou un tableau de tels essais). Affiche une ligne par vol,
	puis un JSON complet (`--json`).
]]
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local Air = require("./air")

local asJson = false
local runs = {}
local function add(label, columns, samples, axis, amp)
	local m = Air.analyze(columns, samples, { axis = axis, amp = amp })
	m.label = label
	table.insert(runs, m)
end
for _, path in ipairs(process.args) do
	if path == "--json" then
		asJson = true
		continue
	end
	local d = serde.decode("json", fs.readFile(path))
	if d.meta and d.meta.columns then
		local p = d.meta.params or {}
		add(d.label or path, d.meta.columns, d.samples, p.axis or "rien", p.amp or 0)
	elseif d.columns then
		add(d.label or path, d.columns, d.samples, d.axis, d.amp)
	elseif type(d) == "table" and d[1] then
		for i, r in ipairs(d) do
			add(r.label or (path .. "#" .. i), r.columns, r.samples, r.axis, r.amp)
		end
	end
end

local function f(x)
	return x == nil and "—" or string.format("%.1f", x)
end
for _, m in ipairs(runs) do
	if m.error then
		print(string.format("%-28s %s", m.label, m.error))
		continue
	end
	local line = string.format("%-28s %-7s %+d  vol %.2f s (%d img, %s ms)  pire %s°/s%s", m.label, m.axis, m.amp,
		m.airSeconds or 0, m.flightFrames, f(m.frameMs), f(m.worstRate), m.tumble and "  CULBUTE" or "")
	if m.torque then
		line ..= string.format("  | couple %s °/s² (%d img)  plafond %s (%d img%s)  extrême %s°  fin %s°/s (−%s)",
			f(m.torque.accel), m.torque.n, f(m.ceiling.extreme), m.ceiling.frames, m.ceiling.retained and "" or ", non retenu",
			f(m.extreme), f(m.rateAtEnd), f(m.slowdown))
	end
	if m.bound then
		line ..= string.format("  borne %s° (taux nul à %s°)", f(m.bound.minPitch), f(m.bound.pitchAtZeroRate))
	end
	if m.drift then
		line ..= string.format("  | dérive tangage %s °/s² (%s→%s), roulis %s °/s²", f(m.drift.pitch.accel),
			f(m.drift.pitch.from), f(m.drift.pitch.to), f(m.drift.roll.accel))
	end
	if m.impact then
		line ..= string.format("  | choc à %.2f s : %s %s→%s °/s, assiette %s°, pz %s, h %s", m.impact.t, m.impact.axis,
			f(m.impact.from), f(m.impact.to), f(m.impact.pitch), f(m.impact.pz), f(m.impact.heightAbove))
	end
	print(line)
end
if asJson then
	print(serde.encode("json", runs, true))
end

--!nonstrict
--[[
	Grandeurs des essais FiveM, calculées par analyze.luau (le même code que dans Studio).
		lune run tools/drive-compare/gta.luau [calibration/m422/fivem] [a b]
	Affiche, par essai, la moyenne et l'écart-type des trois passes, en JSON.
	a b : distances (m) du centre de gravité aux essieux avant / arrière (m422 converti : 1.38 1.41) ;
	ajoutent les dérives des pneus et le braquage de roue établis (analyze.luau, opts.axleFront/axleRear).
]]
local fs = require("@lune/fs")
local serde = require("@lune/serde")
local process = require("@lune/process")
local A = require("./analyze")

local dir = process.args[1] or "calibration/m422/fivem"
local axleA, axleB = tonumber(process.args[2] or ""), tonumber(process.args[3] or "")
local tests = { "corner40", "corner80", "stepsteer", "slalom", "handbrake", "curb20", "curb60" }
local out = {}
for _, test in ipairs(tests) do
	local runs = {}
	for n = 1, 9 do
		local path = string.format("%s/%s_%d.json", dir, test, n)
		if not fs.isFile(path) then
			break
		end
		local d = serde.decode("json", fs.readFile(path))
		local m = A.run(test, d.meta.columns, d.samples, { stepCut = true, axleFront = axleA, axleRear = axleB })
		table.insert(runs, m)
	end
	local agg = {}
	for k, v in pairs(runs[1] or {}) do
		if type(v) == "number" then
			local s, s2, n = 0, 0, 0
			for _, r in ipairs(runs) do
				if type(r[k]) == "number" then
					s += r[k]
					s2 += r[k] * r[k]
					n += 1
				end
			end
			local mu = s / n
			agg[k] = { mean = math.floor(mu * 1000 + 0.5) / 1000, sd = math.floor(math.sqrt(math.max(s2 / n - mu * mu, 0)) * 1000 + 0.5) / 1000, n = n }
		elseif type(v) == "boolean" then
			agg[k] = v
		end
	end
	out[test] = agg
end
print(serde.encode("json", out, true))

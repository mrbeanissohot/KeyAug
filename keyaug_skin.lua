--[[
    Assault Rifle only - auto-equip an "Aug" skin (client-side, visual only)

    - Only the weapon named "AssaultRifle" / "Assault Rifle" is touched
      (case-insensitive, spaces ignored). Every other weapon uses the real game logic.
    - Looks through CosmeticLibrary for every Skin whose name contains KEYWORD
      and equips one automatically.
    - Nothing is sent to the server, so only you see it.

    Based on the structure of the decoded Rivals unlocker. Untested against the live
    game: if a module path or field name changed in an update, the pcall guards will
    print a warning instead of erroring.
]]

-- (wrapped in pcall so a failure here can never stop the Keyaug script below)
local frontOk, frontErr = pcall(function()

---------------------------------------------------------------- config
local KEYWORD = "aug"   -- any skin whose name contains this (case-insensitive)
local PICK    = nil     -- optional: exact skin name to prefer, e.g. "Aug Something"
---------------------------------------------------------------------------

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local lp      = Players.LocalPlayer

local ctrl = lp.PlayerScripts:WaitForChild("Controllers", 10)
local mods = RS:WaitForChild("Modules", 10)

local enumLib = require(mods:WaitForChild("EnumLibrary", 10))
if enumLib then pcall(function() enumLib:WaitForEnumBuilder() end) end
local cosLib  = require(mods:WaitForChild("CosmeticLibrary", 10))
local datCtrl = require(ctrl:WaitForChild("PlayerDataController", 10))

local Cosmetics = cosLib.Cosmetics

---------------------------------------------------------------- helpers
local function wepName(w)
    if type(w) == "table" then w = w.Name end
    return w
end

local function isAR(w)
    w = wepName(w)
    if type(w) ~= "string" then return false end
    return (w:lower():gsub("%s+", "")) == "assaultrifle"
end

local function isAugName(n)
    return type(n) == "string" and n:lower():find(KEYWORD, 1, true) ~= nil
end

local function isAugSkin(n)
    local c = isAugName(n) and Cosmetics[n]
    return c and c.Type == "Skin" or false
end

local function mkSkin(name)
    local base = Cosmetics[name]
    if not base then return nil end
    local d = {}
    for k, v in pairs(base) do d[k] = v end
    d.Name = name
    d.Type = d.Type or "Skin"
    d.Seed = d.Seed or math.random(1, 1000000)
    if enumLib then
        local ok, id = pcall(enumLib.ToEnum, enumLib, name)
        if ok and id then
            d.Enum = id
            d.ObjectID = d.ObjectID or id
        end
    end
    return d
end

---------------------------------------------------------------- find + pick the skin
local matches = {}
for name, c in pairs(Cosmetics) do
    if type(name) == "string" and c.Type == "Skin" and isAugName(name) then
        table.insert(matches, name)
    end
end
table.sort(matches)

if #matches == 0 then
    warn("[AR-Aug] no skins containing '" .. KEYWORD .. "' found")
    return
end

local chosen = matches[1]
if PICK and isAugSkin(PICK) then chosen = PICK end

local arSkin = mkSkin(chosen)
print(("[AR-Aug] %d matching skin(s); equipping '%s'"):format(#matches, chosen))
print("[AR-Aug] matches: " .. table.concat(matches, ", "))

---------------------------------------------------------------- ownership (AR + Aug skins only)
for _, key in ipairs({ "OwnsCosmetic", "OwnsCosmeticNormally", "OwnsCosmeticUniversally", "OwnsCosmeticForWeapon" }) do
    local orig = cosLib[key]
    if type(orig) == "function" then
        cosLib[key] = function(self, inv, nm, wep, ...)
            if isAR(wep) and isAugSkin(nm) then return true end
            return orig(self, inv, nm, wep, ...)
        end
    end
end

---------------------------------------------------------------- inventory view
local origGet = datCtrl.Get
datCtrl.Get = function(self, key, ...)
    local val = origGet(self, key, ...)
    if key == "CosmeticInventory" then
        local prx = {}
        if val then for k, v in pairs(val) do prx[k] = v end end
        return setmetatable(prx, {
            __index = function(_, k)
                if isAugSkin(k) then return true end
                return nil
            end,
        })
    end
    return val
end

---------------------------------------------------------------- loadout view (AR only)
local origGetWep = datCtrl.GetWeaponData
datCtrl.GetWeaponData = function(self, wn, ...)
    local d = origGetWep(self, wn, ...)
    if not d then return nil end
    if isAR(wn) and arSkin then
        local m = {}
        for k, v in pairs(d) do m[k] = v end
        m.Name = wn
        m.Skin = arSkin
        return m
    end
    return d
end

---------------------------------------------------------------- remotes (only swallow AR + Aug equips)
local fightCtrl
pcall(function() fightCtrl = require(ctrl:WaitForChild("FighterController", 10)) end)

if hookmetamethod and getnamecallmethod then
    local remotes  = RS:FindFirstChild("Remotes")
    local dataRem  = remotes and remotes:FindFirstChild("Data")
    local equipRem = dataRem and dataRem:FindFirstChild("EquipCosmetic")

    if equipRem then
        local old
        old = hookmetamethod(game, "__namecall", function(self, ...)
            if self == equipRem and getnamecallmethod() == "FireServer" then
                local a = { ... }
                local wn, ct, cn = a[1], a[2], a[3]
                if isAR(wn) and ct == "Skin" and isAugSkin(cn) then
                    arSkin = mkSkin(cn)  -- user picked another Aug skin in the UI
                    task.defer(function()
                        pcall(function() datCtrl.CurrentData:Replicate("WeaponInventory") end)
                    end)
                    return
                end
            end
            return old(self, ...)
        end)
    end
else
    warn("[AR-Aug] hookmetamethod not available; UI equips will still hit the server")
end

---------------------------------------------------------------- first-person viewmodel
local function applySkin(data, enumFn)
    if not (arSkin and data) then return end
    if enumFn then
        data[enumFn("Skin")] = arSkin
        data[enumFn("Name")] = arSkin.Name
    else
        data.Skin = arSkin
        data.Name = arSkin.Name
    end
end

local buildingWep
local cliItem
pcall(function()
    cliItem = require(lp.PlayerScripts.Modules.ClientReplicatedClasses.ClientFighter.ClientItem)
end)

if cliItem and cliItem._CreateViewModel then
    local origCVM = cliItem._CreateViewModel
    cliItem._CreateViewModel = function(self, vmRef, ...)
        local owner = self.ClientFighter and self.ClientFighter.Player
        buildingWep = (owner == lp) and self.Name or nil
        if owner == lp and isAR(self.Name) then
            local dk = self:ToEnum("Data")
            if vmRef[dk] then
                applySkin(vmRef[dk], function(n) return self:ToEnum(n) end)
            elseif vmRef.Data then
                applySkin(vmRef.Data)
            end
        end
        local r = origCVM(self, vmRef, ...)
        buildingWep = nil
        return r
    end
end

pcall(function()
    local vmMod = lp.PlayerScripts.Modules.ClientReplicatedClasses.ClientFighter.ClientItem:FindFirstChild("ClientViewModel")
    if not vmMod then return end
    local CVM = require(vmMod)
    local origNew = CVM.new
    CVM.new = function(repData, cliItm, ...)
        local owner = cliItm.ClientFighter and cliItm.ClientFighter.Player
        local wn = buildingWep or cliItm.Name
        if owner == lp and isAR(wn) and arSkin then
            local RC = require(RS.Modules.ReplicatedClass)
            local dk = RC:ToEnum("Data")
            repData[dk] = repData[dk] or {}
            repData[dk][RC:ToEnum("Skin")] = arSkin
        end
        return origNew(repData, cliItm, ...)
    end
end)

task.defer(function()
    pcall(function() datCtrl.CurrentData:Replicate("WeaponInventory") end)
end)

print("[AR-Aug] loaded")

end)
if not frontOk then warn("[AR-Aug] front block failed: " .. tostring(frontErr)) end


-- ===== KEYAUG SKIN =====

local CONFIG = [==[
{
"replacement_rules": [
{ "name": "Body", "replace_ids": [18687757654], "mode": "cdn", "enabled": true, "cdn_url": "https://raw.githubusercontent.com/boxyghosly/RivalsSkinChanger/refs/heads/main/KeyaugBody9.obj", "scale": "aug", "texture": "key", "trail": true },
{ "name": "Remove", "replace_ids": [18687757291, 18687757011, 18687756555, 18687757157], "mode": "id", "enabled": true },
{ "name": "shootingsound", "replace_ids": [17662574783], "mode": "cdn", "enabled": true, "cdn_url": "https://raw.githubusercontent.com/boxyghosly/RivalsSkinChanger/main/kaug.mp3" },
{ "name": "Removeshootsound", "replace_ids": [18764343961], "mode": "id", "enabled": true },
{ "name": "Removebolt", "replace_ids": [18687757424], "mode": "id", "enabled": true },
{ "name": "Removemag", "replace_ids": [18687756845], "mode": "id", "enabled": true },
{ "name": "Mag", "replace_ids": [18687756685], "mode": "cdn", "enabled": true, "cdn_url": "https://raw.githubusercontent.com/boxyghosly/RivalsSkinChanger/refs/heads/main/KeyaugMag1.obj", "scale": "mag", "texture": "key" },
{ "name": "Reloadsound1", "replace_ids": [13455395017], "mode": "cdn", "enabled": true, "cdn_url": "https://raw.githubusercontent.com/boxyghosly/RivalsSkinChanger/main/kaug%20reload%2017.mp3" },
{ "name": "Reloadsound2", "replace_ids": [13236549929], "mode": "cdn", "enabled": true, "cdn_url": "https://raw.githubusercontent.com/boxyghosly/RivalsSkinChanger/main/kaug%20reload%2029.mp3" },
{ "name": "Reloadsound3", "replace_ids": [13236549962], "mode": "cdn", "enabled": true, "cdn_url": "https://raw.githubusercontent.com/boxyghosly/RivalsSkinChanger/main/kaug%20reload%2062.mp3" },
{ "name": "icoh", "replace_ids": [18770201102, 18770192853], "mode": "cdn", "enabled": true, "cdn_url": "https://raw.githubusercontent.com/boxyghosly/RivalsSkinChanger/main/iconkeyaug.png" }
]
}
]==]

local CDN_FOLDER = "AWildcat/keyaug"
local MESH_METHOD = "both"  -- "both", "direct" or "apply" (try another if meshes don't show)
local CONVERT_OBJ = true    -- true = turn downloaded .obj into Roblox .mesh
local REFRESH = false       -- true = delete cached downloads and download everything again

-- size multipliers (used by the "scale" field in the rules)
local SCALES = {
	aug = 1.2,  -- Keyaug body
	mag = 0.7,  -- Keyaug magazine
}

-- true  = weapon icons use the generated textures
-- false = weapon icons use the original GitHub pngs
local ICONS_USE_TEXTURES = false

-- texture version: change it to force the generated textures to be rebuilt
local TEXTURE_VERSION = "v2"

-- ===== KEY SKIN COLORS (edit these to match the skin exactly) =====
local KEY_BASE   = { 255, 196, 40 }  -- main key color (gold)
local KEY_DARK   = { 150, 100, 10 }  -- darker stripe / shading
local KEY_EDGE   = { 255, 240, 170 } -- bright border highlight

-- ===== TRAIL SETTINGS =====
local TRAIL_COLOR_A = Color3.fromRGB(255, 196, 40)
local TRAIL_COLOR_B = Color3.fromRGB(255, 240, 170)
local TRAIL_LIFETIME = 0.3
local TRAIL_WIDTH = 0.06


---

-- environment check

local missing = {}
for _, p in ipairs({
	{ "isfile", isfile }, { "writefile", writefile },
	{ "getcustomasset", getcustomasset }, { "makefolder", makefolder }, { "isfolder", isfolder },
}) do
	if type(p[2]) ~= "function" then missing[#missing + 1] = p[1] end
end
if #missing > 0 then
	warn("[Keyaug] Delta is missing: " .. table.concat(missing, ", ") .. " - cannot run")
	return
end

if not isfolder("AWildcat") then pcall(makefolder, "AWildcat") end
if not isfolder(CDN_FOLDER) then pcall(makefolder, CDN_FOLDER) end

if REFRESH and listfiles and delfile then
	for _, f in ipairs(listfiles(CDN_FOLDER)) do pcall(delfile, f) end
	print("[Keyaug] cache cleared")
end


---

-- download + convert

local function hashStr(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return string.format("%08x", h)
end

local function download(url)
	local ok, res = pcall(function() return game:HttpGet(url) end)
	if ok and type(res) == "string" and #res > 0 then return res end
	local req = request or http_request or (syn and syn.request)
	if req then
		local ok2, r = pcall(req, { Url = url, Method = "GET" })
		if ok2 and r and r.StatusCode == 200 and type(r.Body) == "string" and #r.Body > 0 then
			return r.Body
		end
	end
	return nil
end

local function objToMesh(text)
	local v, vt, vn, out = {}, {}, {}, {}
	local tris, faces = 0, 0

	local function idx(s, n)
		if s == nil or s == "" then return nil end
		local i = tonumber(s)
		if not i then return nil end
		if i < 0 then return n + i + 1 end
		return i
	end

	local function corner(a, b, c)
		local p = v[idx(a, #v) or 0]
		if not p then return nil end
		local n = vn[idx(c, #vn) or 0] or { 0, 1, 0 }
		local t = vt[idx(b, #vt) or 0] or { 0, 0 }
		return string.format("[%.5f,%.5f,%.5f][%.4f,%.4f,%.4f][%.5f,%.5f,0]",
			p[1], p[2], p[3], n[1], n[2], n[3], t[1], 1 - t[2])
	end

	for line in text:gmatch("[^\r\n]+") do
		local c = line:sub(1, 2)
		if c == "v " then
			local x, y, z = line:match("^v%s+(%S+)%s+(%S+)%s+(%S+)")
			v[#v + 1] = { tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0 }
		elseif c == "vt" then
			local u, w = line:match("^vt%s+(%S+)%s+(%S+)")
			vt[#vt + 1] = { tonumber(u) or 0, tonumber(w) or 0 }
		elseif c == "vn" then
			local x, y, z = line:match("^vn%s+(%S+)%s+(%S+)%s+(%S+)")
			vn[#vn + 1] = { tonumber(x) or 0, tonumber(y) or 1, tonumber(z) or 0 }
		elseif c == "f " then
			local corners = {}
			for tok in line:gmatch("%S+") do
				if tok ~= "f" then
					local a, b, cc = tok:match("^(%-?%d+)/?(%-?%d*)/?(%-?%d*)")
					local s = a and corner(a, b, cc)
					if s then corners[#corners + 1] = s end
				end
			end
			for i = 2, #corners - 1 do
				out[#out + 1] = corners[1]
				out[#out + 1] = corners[i]
				out[#out + 1] = corners[i + 1]
				tris = tris + 1
			end
			faces = faces + 1
			if faces % 4000 == 0 then task.wait() end
		end
	end
	if tris == 0 then return nil, 0 end
	return "version 1.00\n" .. tris .. "\n" .. table.concat(out), tris
end

local stats = { cached = 0, downloaded = 0, failed = 0 }
local failedList = {}
local cdnAssets = {}

local function loadAsset(path)
	for _ = 1, 5 do
		if isfile(path) then
			local ok, asset = pcall(getcustomasset, path)
			if ok and asset then return asset end
		end
		task.wait(0.3)
	end
	return nil
end

local loading = {}
local loadCdnInner

local function loadCdn(url)
	if cdnAssets[url] then return cdnAssets[url] end
	if loading[url] then
		while loading[url] do task.wait() end
		return cdnAssets[url]
	end
	loading[url] = true
	local ok, res = pcall(loadCdnInner, url)
	loading[url] = nil
	if ok then return res end
	return nil
end

loadCdnInner = function(url)
	local name = url:match("[^/]+$") or url
	local ext = (url:match("%.(%w+)$") or "bin"):lower()
	local convert = (ext == "obj" and CONVERT_OBJ)
	local path = CDN_FOLDER .. "/" .. hashStr(url) .. "." .. (convert and "mesh" or ext)

	if isfile(path) then
		stats.cached += 1
	else
		print("[Keyaug] downloading " .. name)
		local data = download(url)
		if not data then
			stats.failed += 1
			failedList[#failedList + 1] = name .. " (download failed)"
			return nil
		end
		-- GitHub returns a tiny "404: Not Found" text for bad links
		if #data < 200 and data:find("404") then
			stats.failed += 1
			failedList[#failedList + 1] = name .. " (404 not found)"
			return nil
		end
		if convert then
			local mesh, tris = objToMesh(data)
			if not mesh then
				stats.failed += 1
				failedList[#failedList + 1] = name .. " (no faces in obj)"
				return nil
			end
			print(("[Keyaug] %s -> %d triangles"):format(name, tris))
			if tris > 20000 then
				warn("[Keyaug] " .. name .. " has over 20k triangles, Roblox may refuse it")
			end
			data = mesh
		end
		if not pcall(writefile, path, data) then
			stats.failed += 1
			failedList[#failedList + 1] = name .. " (could not save)"
			return nil
		end
		stats.downloaded += 1
	end

	local asset = loadAsset(path)
	if not asset then
		stats.failed += 1
		failedList[#failedList + 1] = name .. " (getcustomasset failed)"
		return nil
	end
	cdnAssets[url] = asset
	return asset
end


---

-- custom texture generator (builds real PNG files, no downloads needed)

local crcTable = {}
for i = 0, 255 do
	local c = i
	for _ = 1, 8 do
		if bit32.band(c, 1) == 1 then
			c = bit32.bxor(bit32.rshift(c, 1), 0xEDB88320)
		else
			c = bit32.rshift(c, 1)
		end
	end
	crcTable[i] = c
end

local function crc32(s)
	local c = 0xFFFFFFFF
	for i = 1, #s do
		c = bit32.bxor(crcTable[bit32.band(bit32.bxor(c, s:byte(i)), 0xFF)], bit32.rshift(c, 8))
	end
	return bit32.bxor(c, 0xFFFFFFFF)
end

local function adler32(s)
	local a, b = 1, 0
	for i = 1, #s do
		a = (a + s:byte(i)) % 65521
		b = (b + a) % 65521
	end
	return b * 65536 + a
end

local function pngChunk(kind, data)
	return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", crc32(kind .. data))
end

local function makePng(w, h, pixel)
	local rows = {}
	for y = 0, h - 1 do
		local row = { "\0" }
		for x = 0, w - 1 do
			local r, g, b = pixel(x, y)
			row[#row + 1] = string.char(r, g, b)
		end
		rows[#rows + 1] = table.concat(row)
	end
	local raw = table.concat(rows)

	-- zlib stream made of "stored" (uncompressed) deflate blocks
	local blocks = { "\120\1" }
	local pos = 1
	while pos <= #raw do
		local piece = raw:sub(pos, pos + 65534)
		pos += #piece
		local final = (pos > #raw) and 1 or 0
		blocks[#blocks + 1] = string.char(final)
			.. string.pack("<I2", #piece)
			.. string.pack("<I2", bit32.band(bit32.bnot(#piece), 0xFFFF))
			.. piece
	end
	blocks[#blocks + 1] = string.pack(">I4", adler32(raw))

	return "\137PNG\r\n\26\n"
		.. pngChunk("IHDR", string.pack(">I4I4", w, h) .. "\8\2\0\0\0")
		.. pngChunk("IDAT", table.concat(blocks))
		.. pngChunk("IEND", "")
end

local RED = { 205, 20, 30 }
local WHITE = { 245, 245, 245 }
local BLACK = { 0, 0, 0 }

local TEXTURES = {
	-- assault rifle: white + red diagonal stripes with a red edge
	ar = function(x, y)
		local c
		if x < 8 or y < 8 or x >= 248 or y >= 248 then
			c = RED
		elseif ((x + y) // 32) % 2 == 0 then
			c = RED
		else
			c = WHITE
		end
		return c[1], c[2], c[3]
	end,
	-- sniper: black with white stripes
	sniper = function(x, y)
		local c = BLACK
		if (x - y) % 64 < 14 then c = WHITE end
		return c[1], c[2], c[3]
	end,
	-- daggers: plain black
	dagger = function()
		return 0, 0, 0
	end,
	-- key skin: gold base, soft darker diagonal bands, bright edge highlight
	key = function(x, y)
		local c = KEY_BASE
		if x < 6 or y < 6 or x >= 250 or y >= 250 then
			c = KEY_EDGE
		elseif ((x + y) // 24) % 2 == 0 then
			c = KEY_DARK
		end
		return c[1], c[2], c[3]
	end,
}

local textureAssets = {}

local function texAsset(key)
	if textureAssets[key] then return textureAssets[key] end
	local gen = TEXTURES[key]
	if not gen then
		warn("[Keyaug] unknown texture: " .. tostring(key))
		return nil
	end
	local path = CDN_FOLDER .. "/tex_" .. key .. "_" .. TEXTURE_VERSION .. ".png"
	if not isfile(path) then
		local ok, png = pcall(makePng, 256, 256, gen)
		if not ok or not pcall(writefile, path, png) then
			stats.failed += 1
			failedList[#failedList + 1] = "texture " .. key .. " (could not build)"
			return nil
		end
		print("[Keyaug] built texture: " .. key)
	end
	local asset = loadAsset(path)
	if not asset then
		stats.failed += 1
		failedList[#failedList + 1] = "texture " .. key .. " (getcustomasset failed)"
		return nil
	end
	textureAssets[key] = asset
	return asset
end


---

-- rules

local HttpService = game:GetService("HttpService")
local AssetService = game:GetService("AssetService")
local rules = HttpService:JSONDecode(CONFIG).replacement_rules
local lookup, meshCache = {}, {}
local registered, swapped = 0, 0

local function parseId(v)
	return tonumber(tostring(v):match("(%d+)"))
end

local function resolve(rule)
	if rule.mode == "texture" then
		return texAsset(rule.texture)
	end
	if rule.mode == "cdn" then
		return loadCdn(rule.cdn_url)
	end
	if rule.with_id then return "rbxassetid://" .. rule.with_id end
	return ""
end

local function flatten(list, out)
	for _, r in ipairs(list) do
		if r.type == "group" then
			flatten(r.children or {}, out)
		elseif r.enabled then
			local skip = (r.icon == "texture" and not ICONS_USE_TEXTURES)
				or (r.icon == "original" and ICONS_USE_TEXTURES)
			if not skip then out[#out + 1] = r end
		end
	end
	return out
end

-- resolve (download / convert) EVERY rule at the same time
local active = flatten(rules, {})
local targets = {}
local pendingCount = #active
for i, rule in ipairs(active) do
	task.spawn(function()
		local ok, res = pcall(resolve, rule)
		if ok then targets[i] = res end
		pendingCount -= 1
	end)
end
while pendingCount > 0 do task.wait() end

-- register in the original rule order so overlapping ids behave the same
local meshAssets = {}
for i, rule in ipairs(active) do
	local target = targets[i]
	if target ~= nil then
		registered += 1

		local entry = { target = target, trail = rule.trail }
		if rule.scale then entry.scale = SCALES[rule.scale] end
		if rule.texture and rule.mode ~= "texture" then
			entry.texture = texAsset(rule.texture)
		end
		if target ~= "" and rule.mode ~= "texture" and (rule.texture or rule.scale) then
			meshAssets[target] = true
		end

		for _, id in ipairs(rule.replace_ids) do
			local n = parseId(id)
			if n then lookup[n] = entry end
		end
	end
end

-- pre-load every replacement mesh at once so all weapons swap instantly
if MESH_METHOD ~= "direct" then
	local warming = 0
	for asset in pairs(meshAssets) do
		warming += 1
		task.spawn(function()
			pcall(function()
				meshCache[asset] = AssetService:CreateMeshPartAsync(asset)
			end)
			warming -= 1
		end)
	end
	local t0 = os.clock()
	while warming > 0 and os.clock() - t0 < 15 do task.wait() end
end

print(("[Keyaug] rules ready: %d | cached: %d | downloaded: %d | failed: %d"):format(
	registered, stats.cached, stats.downloaded, stats.failed))
for _, f in ipairs(failedList) do warn("[Keyaug] FAILED: " .. f) end


---

-- apply to the game

local PROPS = {
	MeshPart = { "MeshId", "TextureID" },
	SpecialMesh = { "MeshId", "TextureId" },
	Sound = { "SoundId" },
	Decal = { "Texture" },
	Texture = { "Texture" },
	ImageLabel = { "Image" },
	ImageButton = { "Image" },
	SurfaceAppearance = { "ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap" },
}

local seen = setmetatable({}, { __mode = "k" })
local forcedTexture = setmetatable({}, { __mode = "k" }) -- inst -> custom texture asset
local scaleState = setmetatable({}, { __mode = "k" })    -- inst -> target size/scale (false = pending)
local trailed = setmetatable({}, { __mode = "k" })       -- inst -> true once a trail is attached

local function hideMesh(inst)
	pcall(function()
		if inst:IsA("MeshPart") then
			inst.Transparency = 1
		elseif inst:IsA("SpecialMesh") then
			inst.Scale = Vector3.new(0, 0, 0)
		end
	end)
end

-- adds a colored trail that follows the weapon
local function addTrail(inst)
	if trailed[inst] then return end
	local part = inst
	if inst:IsA("SpecialMesh") then part = inst.Parent end
	if not part or not part:IsA("BasePart") then return end
	trailed[inst] = true

	pcall(function()
		local a0 = Instance.new("Attachment")
		a0.Name = "KeyTrailA"
		a0.Position = Vector3.new(0, TRAIL_WIDTH, 0)
		a0.Parent = part

		local a1 = Instance.new("Attachment")
		a1.Name = "KeyTrailB"
		a1.Position = Vector3.new(0, -TRAIL_WIDTH, 0)
		a1.Parent = part

		local trail = Instance.new("Trail")
		trail.Name = "KeyTrail"
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = TRAIL_LIFETIME
		trail.MinLength = 0.05
		trail.FaceCamera = true
		trail.LightEmission = 0.8
		trail.LightInfluence = 0
		trail.Color = ColorSequence.new(TRAIL_COLOR_A, TRAIL_COLOR_B)
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.Parent = part
	end)
end

local function applyMesh(inst, asset)
	if not inst:IsA("MeshPart") then
		pcall(function() inst.MeshId = asset end)
		return
	end
	if MESH_METHOD ~= "apply" then
		pcall(function() inst.MeshId = asset end)
	end
	if MESH_METHOD ~= "direct" then
		local ok, err = pcall(function()
			local mp = meshCache[asset]
			if not mp then
				mp = AssetService:CreateMeshPartAsync(asset)
				meshCache[asset] = mp
			end
			inst:ApplyMesh(mp)
		end)
		if not ok then warn("[Keyaug] ApplyMesh failed: " .. tostring(err)) end
	end
end

local function setTarget(inst, value)
	pcall(function()
		if inst:IsA("MeshPart") then
			inst.Size = value
		else
			inst.Scale = value
		end
	end)
end

local function applyScale(inst, factor)
	if not factor or factor == 1 then return end
	local st = scaleState[inst]
	if st ~= nil then
		-- already scaled (or pending): just re-assert the size after a mesh swap
		if st then
			task.defer(setTarget, inst, st)
		end
		return
	end
	scaleState[inst] = false
	task.spawn(function()
		task.wait(0.1) -- let the new mesh settle so we multiply its real size
		local target
		pcall(function()
			if inst:IsA("MeshPart") then
				target = inst.Size * factor
			elseif inst:IsA("SpecialMesh") then
				target = inst.Scale * factor
			end
		end)
		if target then
			scaleState[inst] = target
			setTarget(inst, target)
		end
	end)
end

local function setTexture(inst, asset)
	local prop = inst:IsA("SpecialMesh") and "TextureId" or "TextureID"
	forcedTexture[inst] = asset
	pcall(function() inst[prop] = asset end)
end

local function handle(inst, p)
	local ok, cur = pcall(function() return inst[p] end)
	if not ok then return end

	-- keep our custom texture if the game tries to change it back
	local forced = forcedTexture[inst]
	if forced and (p == "TextureID" or p == "TextureId") then
		if cur ~= forced then
			pcall(function() inst[p] = forced end)
		end
		return
	end

	local id = parseId(cur)
	local entry = id and lookup[id]
	if entry == nil then return end
	local new = entry.target

	swapped += 1
	if swapped <= 15 then
		print("[Keyaug] swapped " .. inst.ClassName .. "." .. p .. " (" .. tostring(id) .. ")")
	end

	if p == "MeshId" then
		if new == "" then
			hideMesh(inst)
		else
			applyMesh(inst, new)
			if entry.texture then setTexture(inst, entry.texture) end
			applyScale(inst, entry.scale)
			if entry.trail then addTrail(inst) end
		end
	else
		pcall(function() inst[p] = new end)
	end
end

local function apply(inst)
	local props = PROPS[inst.ClassName]
	if not props or seen[inst] then return end
	seen[inst] = true
	for _, p in ipairs(props) do
		task.spawn(handle, inst, p)
		pcall(function()
			inst:GetPropertyChangedSignal(p):Connect(function()
				handle(inst, p)
			end)
		end)
	end
end

local function scan()
	local n = 0
	for _, d in ipairs(game:GetDescendants()) do
		apply(d)
		n += 1
		if n % 2000 == 0 then task.wait() end
	end
end

local function scanNil()
	if type(getnilinstances) ~= "function" then return end
	pcall(function()
		for _, d in ipairs(getnilinstances()) do
			apply(d)
			for _, c in ipairs(d:GetDescendants()) do apply(c) end
		end
	end)
end

game.DescendantAdded:Connect(apply)
scan()
scanNil()

-- catch parts that load late
task.spawn(function()
	while true do
		task.wait(2)
		scan()
		scanNil()
	end
end)

print("[Keyaug] loaded")


-- Manor Lords Co-op (UE4SS Lua mod)
--
-- Each player is a separate lord with their own region on one shared map.
-- The host's game is the reference world. A guest joins: receives the host's save, loads it,
-- turns every other lord into a passive copy, picks a free region and settles it. From then on
-- each side reports the buildings of the lords it owns, and applies the other side's reports to
-- its passive copies. Calendar and speed (fixed 1x) follow the host.
--
-- The native half (coopnative.dll, same folder) does what Lua cannot: TCP, building creation,
-- the building capture hook. See docs/PROTOCOL.md.

local VERSION = "0.1.0"
local PROTO = 1

-- ------------------------------------------------------------------ paths and config
local SCRIPT_SRC = debug.getinfo(1, "S").source:gsub("^@", "")
local MOD_DIR = (function()
    -- Lua's io.open and package.loadlib use the Windows ANSI functions: an absolute path with
    -- non-ASCII characters (an accent in a user or library name) is not found. Relative paths
    -- from the game's Win64 folder are plain ASCII, so try those first.
    local abs = SCRIPT_SRC:gsub("[/\\]Scripts[/\\]main%.lua$", ""):gsub("/", "\\") .. "\\"
    for _, cand in ipairs({ "ue4ss\\Mods\\ManorLordsCoop\\", "Mods\\ManorLordsCoop\\", abs }) do
        local f = io.open(cand .. "Scripts\\main.lua", "r")
        if f then f:close(); return cand end
    end
    return abs
end)()

local function read_config()
    local c = { role = "off", address = "127.0.0.1", port = "27015", lord = "", region = "" }
    local f = io.open(MOD_DIR .. "config.txt", "r")
    if f then
        for line in f:lines() do
            local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
            if k and not line:match("^%s*#") then c[k:lower()] = v end
        end
        f:close()
    end
    -- the test lab sets these
    for k, env in pairs({ role = "COOP_ROLE", address = "COOP_ADDRESS", port = "COOP_PORT", lord = "COOP_LORD", region = "COOP_REGION" }) do
        local v = os.getenv(env)
        if v and v ~= "" then c[k] = v end
    end
    return c
end
local CFG = read_config()
local TEST = os.getenv("COOP_TEST") or ""       -- lab bot scenario, empty for players

local RUN_DIR = MOD_DIR .. "run\\"
local STATUS_PATH = os.getenv("COOP_STATUS") or (RUN_DIR .. "status.txt")
local INBOX_PATH = os.getenv("COOP_NATIVE_IN") or (RUN_DIR .. "inbox.txt")
local OUTBOX_PATH = os.getenv("COOP_NATIVE_OUT") or (RUN_DIR .. "outbox.txt")
local SAVES_DIR = (os.getenv("LOCALAPPDATA") or "") .. "\\ManorLords\\Saved\\SaveGames\\"
local WORLD_SLOT = "coop_world"
local GUESTS_PATH = os.getenv("COOP_GUESTS") or (RUN_DIR .. "guests.txt")

local function read_guests()
    local g = {}
    local f = io.open(GUESTS_PATH, "r")
    if f then for line in f:lines() do if line ~= "" then g[line] = true end end; f:close() end
    return g
end
local function remember_guest(name)
    local g = read_guests()
    if g[name] then return end
    local f = io.open(GUESTS_PATH, "a")
    if f then f:write(name .. "\n"); f:close() end
end

-- ------------------------------------------------------------------ small helpers
local function status(line)
    print("[ManorLordsCoop] " .. line .. "\n")
    local f = io.open(STATUS_PATH, "a")
    if f then f:write(line .. "\n"); f:close() end
end

local function valid(o) return o ~= nil and o.IsValid ~= nil and o:IsValid() end
local function str(v)
    if v == nil then return "" end
    local ok, s = pcall(function() return v:ToString() end)
    if ok then return s end
    return tostring(v)
end
local function esc(s) return (s:gsub("[%%%s]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function same(a, b) return valid(a) and valid(b) and a:GetAddress() == b:GetAddress() end
local function world_name()
    local w = FindFirstOf("World")
    return valid(w) and w:GetFullName() or ""
end
local function engine() return FindFirstOf("RTSMultiEngineCPP") end
local function lord_name(p) return valid(p) and str(p.lordsName) or "" end
local function file_size(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local n = f:seek("end"); f:close(); return n
end

-- ------------------------------------------------------------------ native helper
local native_ok = false
local function load_native()
    local f, err = package.loadlib(MOD_DIR .. "coopnative.dll", "*")
    if not f then status("ERROR cannot load coopnative.dll: " .. tostring(err)); return false end
    return true
end
local function native(text)
    -- the patched debug UFunction ignores its object, so the class default object works anywhere
    -- (the main menu has no SMUnit)
    local unit = StaticFindObject("/Script/ManorLords.Default__SMUnit")
    if not valid(unit) then unit = FindFirstOf("SMUnit") end
    if not valid(unit) then return false end
    local ok, e = pcall(function() unit:writeUnitDebugLog(text) end)
    if not ok then status("ERROR native command failed: " .. tostring(e)) end
    return ok
end
local function send(msg) return native("net send " .. msg) end

-- incremental readers for the native inbox (network) and outbox (building reports)
local function make_reader(path)
    local pos = 0
    return function()
        local f = io.open(path, "rb")
        if not f then return {} end
        f:seek("set", pos)
        local data = f:read("*a") or ""
        f:close()
        local lines = {}
        local consumed = 0
        for line in data:gmatch("([^\n]*)\n") do
            consumed = consumed + #line + 1
            lines[#lines + 1] = line
        end
        pos = pos + consumed
        return lines
    end
end
local read_inbox = make_reader(INBOX_PATH)
local read_outbox = make_reader(OUTBOX_PATH)

-- outbox lines: "setup 0x<addr> <id> <type> local|remote|field" and, before a "field" one,
-- "fielddata 0x<addr> <shape payload>" (what commitField gave the building)
local field_shapes = {}
local building_types = {}       -- addr -> type, from every setup report (owner or not)
local function outbox_events()
    local ev = {}
    for _, line in ipairs(read_outbox()) do
        local a, id, t, r = line:match("^setup 0x(%x+) (%-?%d+) (%-?%d+) (%a+)$")
        if a then
            local addr = tonumber(a, 16)
            building_types[addr] = tonumber(t)
            ev[#ev + 1] = { addr = addr, id = tonumber(id), type = tonumber(t), remote = (r == "remote"), field = (r == "field"),
                            by_road = (r == "road"),
                            shape = field_shapes[addr] }
            field_shapes[addr] = nil
        else
            local fa, payload = line:match("^fielddata 0x(%x+) (.*)$")
            if fa then field_shapes[tonumber(fa, 16)] = payload end
            local ra, rpay = line:match("^road 0x(%x+) (.*)$")
            if ra then ev[#ev + 1] = { road = true, pawn = tonumber(ra, 16), payload = rpay } end
        end
    end
    return ev
end

local function buildings()
    local list = {}
    for _, b in ipairs(FindAllOf("SMBuildingMaster") or {}) do
        if valid(b) then
            local l = b:K2_GetActorLocation()
            local root = true
            pcall(function() root = valid(b:K2_GetRootComponent()) end)
            if root and not (l.X == 0 and l.Y == 0 and l.Z == 0) then list[#list + 1] = b end
        end
    end
    return list
end
local function by_addr()
    local m = {}
    for _, b in ipairs(buildings()) do m[b:GetAddress()] = b end
    return m
end

-- ------------------------------------------------------------------ lords
-- passive lord: an AI lord whose three AI timers are cleared (isAI stays true: false crashes)
local passive_lords = {}                                    -- name -> true: keep their AI off
local passive_watch = {}                                    -- name -> ticks left of close watching
local function is_ai_lord(p)
    local ok, cls = pcall(function() return p:GetClass():GetFName():ToString() end)
    return ok and cls == "PawnCPP_AI"
end
local function make_passive(p)
    -- only AI lords have AI timers: on the player's pawn these properties do not exist
    if not valid(p) or not is_ai_lord(p) then return end
    pcall(function()
        local n = str(p.lordsName)
        if not passive_lords[n] then passive_watch[n] = 60 end  -- 15 s: the game may start its AI late
        passive_lords[n] = true
    end)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    for _, h in ipairs({ "AICommandHandle", "AIGeneralStrategyHandle", "AILetterwritingHandle" }) do
        pcall(function() ksl:K2_ClearTimerHandle(p, p[h]) end)
    end
end

local function find_lord(name)
    for _, p in ipairs(FindAllOf("PawnCPP") or {}) do
        if valid(p) and lord_name(p) == name then return p end
    end
    return nil
end

local function spawn_passive(name, color)
    local eng = engine()
    eng:spawnNewAILord(name, false, nil, false)
    local p = find_lord(name)
    if not valid(p) then return nil end
    if color then pcall(function() p.playerColor = color end) else pcall(function() local c = eng:getUnusedPlayerColor(); if c then p.playerColor = c end end) end
    make_passive(p)
    return p
end

local function region_by_tag(tag)
    for _, r in ipairs(FindAllOf("Region") or {}) do
        if valid(r) and str(r.regionUniqueTag) == tag then return r end
    end
    return nil
end

local function settle(pawn, region, loc, seed)
    native("srand " .. seed)                                -- same village layout on both sides
    pawn:finalizeClaim(region, false)                       -- settleRegion needs the region owned first
    pawn:settleRegion(region, { Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z }, Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 } }, 1, 1, nil)
end

local function ownership_table()
    local lines = {}
    for _, r in ipairs(FindAllOf("Region") or {}) do
        if valid(r) then
            lines[#lines + 1] = string.format("REGION %s %s %d", str(r.regionUniqueTag),
                valid(r.ownerPawn) and esc(lord_name(r.ownerPawn)) or "-", r.isSettled and 1 or 0)
        end
    end
    return lines
end

-- ------------------------------------------------------------------ session state
local S = {
    phase = "boot",          -- boot, menu, hosting, joining, loading, playing, refused
    role = CFG.role,
    peer = false,            -- connected
    welcomed = false,
    local_lords = {},        -- name -> true: lords this machine is the authority for
    files = {},              -- received world files
    world_sent = false,
    host_regions = {},       -- tag -> { owner=, settled= } (guest side)
    alive = {},              -- addr -> { lord=, x=, y=, z= } buildings of local lords (removal detection)
    last_day = nil,
    ticks = 0,
    settle_pending = nil,
    bot = {},
}

local function is_local_lord(name) return S.local_lords[name] == true end   -- false: a guest's lord
S.known = {}                 -- addr -> true: buildings already classified (sent, received, starters, existing)
S.owner_of = {}              -- addr -> owner name when last checked ("" = none)
S.road_made = {}             -- addr -> true: buildings a road commit or replay made

-- remember the current buildings of local lords, so a later disappearance can be reported
local function track_existing()
    for _, b in ipairs(buildings()) do
        S.known[b:GetAddress()] = true
        pcall(function() S.owner_of[b:GetAddress()] = lord_name(b.ownerPawn) end)
        local owner = ""
        pcall(function() owner = lord_name(b.ownerPawn) end)
        if is_local_lord(owner) then
            local l = b:K2_GetActorLocation()
            S.alive[b:GetAddress()] = { lord = owner, x = l.X, y = l.Y, z = l.Z }
        end
    end
end

-- ------------------------------------------------------------------ building facts
local remove_building                                      -- defined below
local function report_new_buildings(starters_for)
    local bm = nil
    local starters = {}
    for _, e in ipairs(outbox_events()) do
        if e.road then
            -- a player's road commit that succeeded (the native side reports only those)
            local owner = ""
            for _, p in ipairs(FindAllOf("PawnCPP") or {}) do if valid(p) and p:GetAddress() == e.pawn then owner = lord_name(p) end end
            if is_local_lord(owner) and S.peer and S.phase == "playing" then
                send("ROAD " .. esc(owner) .. " " .. e.payload)
            end
        elseif not e.remote then
            bm = bm or by_addr()
            local b = bm[e.addr]
            if valid(b) then
                local owner = ""
                pcall(function() owner = lord_name(b.ownerPawn) end)
                if owner ~= "" or S.allow_foreign then S.known[e.addr] = true; S.owner_of[e.addr] = owner end   -- no owner yet: the scan decides later
                if not is_local_lord(owner) and owner ~= "" and S.phase == "playing" and not S.allow_foreign then
                    -- the local simulation made a building for a lord the other machine owns: only the
                    -- owner creates that lord's buildings (it will send it), so drop this copy
                    status("dropped a locally made building of " .. owner .. " (type " .. e.type .. "): the owner sends its own")
                    pcall(remove_building, b)
                elseif is_local_lord(owner) then
                    local l, r = b:K2_GetActorLocation(), b:K2_GetActorRotation()
                    S.alive[e.addr] = { lord = owner, x = l.X, y = l.Y, z = l.Z }
                    if starters_for == owner then
                        starters[#starters + 1] = string.format("%.1f %.1f", l.X, l.Y)
                    elseif e.by_road then
                        -- made by a road commit: the other side's road replay makes it too
                        S.road_made[e.addr] = true
                    elseif S.peer and S.phase == "playing" then
                        if e.shape then
                            send(string.format("FLD %s %d %d %.1f %.1f %.1f %.2f %s", esc(owner), e.id, e.type, l.X, l.Y, l.Z, r.Yaw, e.shape))
                        else
                            send(string.format("BLD %s %d %d %.1f %.1f %.1f %.2f", esc(owner), e.id, e.type, l.X, l.Y, l.Z, r.Yaw))
                        end
                    end
                end
            end
        end
    end
    return starters
end

local function report_removed()
    if not S.peer or S.phase ~= "playing" then return end
    local bm = by_addr()
    for addr, info in pairs(S.alive) do
        if not valid(bm[addr]) then
            send(string.format("RM %s %.1f %.1f %.1f", esc(info.lord), info.x, info.y, info.z))
            S.alive[addr] = nil
        end
    end
end

local function apply_bld(lord, btype, x, y, z, yaw, shape)
    local pawn = find_lord(lord)
    if not valid(pawn) then status("WARN BLD for unknown lord " .. lord); return end
    local eng = engine()
    local loc = { X = x, Y = y, Z = z }
    local r = eng:getRegionByPos(loc, false)
    report_new_buildings(nil)                               -- flush our own reports first
    if shape then
        native(string.format("fieldbuild %d %.1f %.1f %.1f %.2f %x %x %s", btype, x, y, z, yaw, eng:GetAddress(), valid(r) and r:GetAddress() or 0, shape))
    else
        native(string.format("build %d %.1f %.1f %.1f %.2f %x %x", btype, x, y, z, yaw, eng:GetAddress(), valid(r) and r:GetAddress() or 0))
    end
    local bm = by_addr()
    for _, e in ipairs(outbox_events()) do
        local b = bm[e.addr]
        if e.remote and valid(b) then
            S.known[e.addr] = true
            if not same(b.ownerPawn, pawn) then b.ownerPawn = pawn end
            S.owner_of[e.addr] = lord
        end
    end
end

-- shape payload from a building's reflected arrays (when the native capture did not see it)
local function shape_from_building(b)
    local function pts(arr)
        local out = {}
        local n = 0
        pcall(function()
            n = #arr
            for i = 1, n do local v = arr[i]; out[#out + 1] = string.format("%d %d %d", math.floor(v.X * 10), math.floor(v.Y * 10), math.floor(v.Z * 10)) end
        end)
        return #out .. (#out > 0 and (" " .. table.concat(out, " ")) or "")
    end
    local nb = 0
    pcall(function() nb = #b.fieldBorderPoints end)
    if nb == 0 then return nil end
    local w, cw = 0, 0
    pcall(function() w = b.fieldWorkersNeeded end)
    pcall(function() cw = b.borderIsClockwise and 1 or 0 end)
    return string.format("%d 1 %d P %s B %s H %s %s", w, cw, pts(b.FieldPoints), pts(b.fieldBorderPoints), string.rep("0", 96), string.rep("0", 384))
end

-- every building not yet classified: send ours, drop the other side's local copies.
-- Known buildings that change owner: a change to one of our lords is sent (OWN); a change to the
-- other side's lord made by our own simulation is undone (the owner's OWN decides).
local function scan_buildings()
    if S.phase ~= "playing" then return end
    for _, b in ipairs(buildings()) do
        local addr = b:GetAddress()
        if S.known[addr] then
            local now = ""
            pcall(function() now = lord_name(b.ownerPawn) end)
            local before = S.owner_of[addr]
            if before == nil then S.owner_of[addr] = now
            elseif now ~= before then
                local l = b:K2_GetActorLocation()
                if is_local_lord(now) then
                    S.owner_of[addr] = now
                    S.alive[addr] = { lord = now, x = l.X, y = l.Y, z = l.Z }
                    if S.peer then send(string.format("OWN %s %.1f %.1f %.1f", esc(now), l.X, l.Y, l.Z)) end
                elseif now ~= "" and not S.allow_foreign then
                    local prev = before ~= "" and find_lord(before) or nil
                    pcall(function() b.ownerPawn = prev end)
                    status("undid a local owner change to " .. now .. " (the owner decides)")
                else
                    S.owner_of[addr] = now
                end
            end
        end
        if not S.known[addr] then
            local owner = ""
            pcall(function() owner = lord_name(b.ownerPawn) end)
            if owner ~= "" then
                S.known[addr] = true
                S.owner_of[addr] = owner
                local l, r = b:K2_GetActorLocation(), b:K2_GetActorRotation()
                if is_local_lord(owner) then
                    S.alive[addr] = { lord = owner, x = l.X, y = l.Y, z = l.Z }
                    local t = building_types[addr]
                    if S.peer and t then
                        local shape = shape_from_building(b)
                        if shape then
                            send(string.format("FLD %s 0 %d %.1f %.1f %.1f %.2f %s", esc(owner), t, l.X, l.Y, l.Z, r.Yaw, shape))
                        else
                            send(string.format("BLD %s 0 %d %.1f %.1f %.1f %.2f", esc(owner), t, l.X, l.Y, l.Z, r.Yaw))
                        end
                    end
                    status("late building of " .. owner .. " (type " .. tostring(t) .. ") found by scan")
                elseif not S.allow_foreign then
                    status("dropped a building of " .. owner .. " made by the local simulation (found by scan)")
                    pcall(remove_building, b)
                end
            end
        end
    end
end

-- replay a road on a passive lord: start point + points, then commitRoad (works without a cursor)
local function apply_road(lord, payload)
    local pawn = find_lord(lord)
    if not valid(pawn) then status("WARN ROAD for unknown lord " .. lord); return end
    local nums = {}
    for v in payload:gmatch("%-?%d+") do nums[#nums + 1] = tonumber(v) / 10 end
    -- payload: 1 sx sy sz n x y z ...  (the numbers were tenths)
    if #nums < 5 then return end
    local start = { X = nums[2], Y = nums[3], Z = nums[4] }
    local n = math.floor(nums[5] * 10 + 0.5)
    local pts = {}
    for i = 0, n - 1 do
        local k = 6 + i * 3
        if nums[k + 2] then pts[#pts + 1] = { X = nums[k], Y = nums[k + 1], Z = nums[k + 2] } end
    end
    if #pts < 2 then return end
    report_new_buildings(nil)
    native("remote 1")
    pcall(function()
        pawn:setRoadMode(true, start, true)
        pawn.roadStartPos = start
        pawn.roadPoints = pts
        pawn:commitRoad()
        pawn:setRoadMode(false, start, false)
    end)
    native("remote 0")
    for _, e in ipairs(outbox_events()) do
        if e.addr then S.road_made[e.addr] = true; S.known[e.addr] = true; S.owner_of[e.addr] = lord end
    end
end

-- the end of demolish() without its side effects (demolish can spawn a replacement building)
remove_building = function(b)
    local eng = engine()
    local reg = eng:getRegionByPos(b:K2_GetActorLocation(), false)
    eng:eraseBuildingReferences(b)
    if valid(reg) then
        reg:accomodateHomelessFamilies(b)
        reg:accomodateHomelessLivestock(b)
        reg:redistributeMilitiaRecruits()
    end
    b:K2_DestroyActor()
end

local function apply_rm(lord, x, y)
    local best, bd = nil, 1e18
    for _, b in ipairs(buildings()) do
        local owner = ""
        pcall(function() owner = lord_name(b.ownerPawn) end)
        if owner == lord then
            local l = b:K2_GetActorLocation()
            local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
            if d < bd then best, bd = b, d end
        end
    end
    if best and bd < 100 * 100 then remove_building(best) else status("WARN RM: no building of " .. lord .. " near " .. x .. "," .. y) end
end

-- ------------------------------------------------------------------ world transfer (host)
local function send_world()
    local eng = engine()
    eng.playerRef:requestSaveFile(WORLD_SLOT, WORLD_SLOT)
    S.save_wait = { t = 0, last = -1 }
end

local function poll_world_saved()
    local w = S.save_wait
    if not w then return end
    w.t = w.t + 1
    local size = file_size(SAVES_DIR .. WORLD_SLOT .. ".sav")
    local dsize = file_size(SAVES_DIR .. WORLD_SLOT .. "_descr.sav")
    if size and dsize and size == w.last and size > 0 then
        S.save_wait = nil
        for _, n in ipairs({ WORLD_SLOT .. ".sav", WORLD_SLOT .. "_descr.sav" }) do native("net sendfile " .. n) end
        for i = 1, 8 do
            local n = WORLD_SLOT .. "_coat_" .. i .. ".png"
            if file_size(SAVES_DIR .. n) then native("net sendfile " .. n) end
        end
        for _, line in ipairs(ownership_table()) do send(line) end
        -- who owns every building: a loaded save can give ownerless buildings to the main pawn
        for _, b in ipairs(buildings()) do
            local owner = ""
            pcall(function() owner = lord_name(b.ownerPawn) end)
            if owner ~= "" then
                local l = b:K2_GetActorLocation()
                send(string.format("BOWN %s %.1f %.1f", esc(owner), l.X, l.Y))
            end
        end
        send("HOST_LORD " .. esc(lord_name(engine().playerRef)))
        send("WORLD_SENT " .. WORLD_SLOT)
        S.world_sent = true
        status("world sent (" .. size .. " bytes)")
        return
    end
    w.last = size or -1
    if w.t > 120 then status("ERROR world save did not finish"); S.save_wait = nil end
end

-- ------------------------------------------------------------------ guest: load and take a region
local function load_world()
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local desc = gs:LoadGameFromSlot(WORLD_SLOT .. "_descr", 0)
    if not valid(desc) then status("ERROR received world has no descriptor"); return false end
    local gi = FindFirstOf("BP_MLGameInstance_C")
    gi.savefileToLoad = WORLD_SLOT                            -- without this LoadGame starts a new game
    FindFirstOf("mainMenu_widget_C"):LoadGame({ SlotIndex = 0, Descriptor = desc })
    return true
end

local function guest_take_over()
    local eng = engine()
    local me = eng.playerRef
    local host_name = S.host_lord or lord_name(me)
    -- coming back: our lord is in the host's world as a passive AI copy; rename it first so that
    -- nothing confuses it with our own pawn, then take its land back below
    local my_name0 = CFG.lord ~= "" and CFG.lord or "Guest"
    local old = nil
    for _, p in ipairs(FindAllOf("PawnCPP_AI") or {}) do if valid(p) and lord_name(p) == my_name0 then old = p end end
    if valid(old) then old.lordsName = my_name0 .. "~" end
    -- every AI lord (baron, outlaws) is the host's: make them passive here
    for _, p in ipairs(FindAllOf("PawnCPP_AI") or {}) do if valid(p) then make_passive(p) end end
    S.all_ai_passive = true                                 -- here every AI lord is the host's
    -- the loaded main pawn is the host's lord: hand its regions and buildings to a passive copy
    local puppet = spawn_passive(host_name, me.playerColor)
    if not valid(puppet) then status("ERROR could not create the host's lord"); return false end
    for _, r in ipairs(FindAllOf("Region") or {}) do if valid(r) and same(r.ownerPawn, me) then r.ownerPawn = puppet end end
    for _, b in ipairs(buildings()) do if same(b.ownerPawn, me) then b.ownerPawn = puppet end end
    local my_name = CFG.lord ~= "" and CFG.lord or "Guest"
    if valid(old) then
        local nr, nb = 0, 0
        for _, r in ipairs(FindAllOf("Region") or {}) do if valid(r) and same(r.ownerPawn, old) then r.ownerPawn = me; nr = nr + 1 end end
        for _, b in ipairs(buildings()) do if same(b.ownerPawn, old) then b.ownerPawn = me; nb = nb + 1 end end
        pcall(function() me.playerColor = old.playerColor end)
        S.resumed = true
        status("resumed our lord " .. my_name .. ": " .. nr .. " regions, " .. nb .. " buildings")
    end
    me.lordsName = my_name
    pcall(function() local c = eng:getUnusedPlayerColor(); if c then me.playerColor = c end end)
    S.local_lords = { [my_name] = true }
    S.my_name = my_name
    -- align every building's owner with the host's table (nearest within 1 m; absent = no owner)
    if S.bown then
        local fixed = 0
        local pawns = {}
        local function pawn_of(name)
            if pawns[name] == nil then pawns[name] = find_lord(name) or false end
            return pawns[name] or nil
        end
        for _, b in ipairs(buildings()) do
            local l = b:K2_GetActorLocation()
            local want, bd = nil, 100 * 100
            for _, e in ipairs(S.bown) do
                local d = (e.x - l.X) ^ 2 + (e.y - l.Y) ^ 2
                if d < bd then want, bd = e.lord, d end
            end
            local now = ""
            pcall(function() now = lord_name(b.ownerPawn) end)
            if (want or "") ~= now then
                local p = want and pawn_of(want) or nil
                if want == nil or valid(p) then
                    pcall(function() b.ownerPawn = p end)
                    fixed = fixed + 1
                end
            end
        end
        status("aligned " .. fixed .. " building owners with the host")
    end
    status("you are " .. my_name .. "; host lord is " .. host_name)
    return true
end

local function pick_region()
    local cands = {}
    for _, sp in ipairs(FindAllOf("BP_VillageSpawner_C") or {}) do
        if valid(sp) and sp.CanBePlayer and not sp.banditCamp and not sp.Tradepoint and valid(sp.Region) then
            local tag = str(sp.Region.regionUniqueTag)
            local h = S.host_regions[tag]
            if h and h.owner == "-" and h.settled == 0 and not valid(sp.Region.ownerPawn) and not sp.Region.isSettled then
                cands[#cands + 1] = sp
            end
        end
    end
    table.sort(cands, function(a, b) return str(a.Region.regionUniqueTag) < str(b.Region.regionUniqueTag) end)
    for _, sp in ipairs(cands) do
        if CFG.region ~= "" and (str(sp.Region.regionUniqueTag) == CFG.region or str(sp.Region.regionName) == CFG.region) then return sp end
    end
    return cands[1]
end

local function guest_settle()
    local sp = pick_region()
    if not sp then status("ERROR no free region left"); return end
    local me = engine().playerRef
    local l = sp:K2_GetActorLocation()
    local seed = math.random(1, 1000000)
    local tag = str(sp.Region.regionUniqueTag)
    settle(me, sp.Region, l, seed)
    local starters = report_new_buildings(S.my_name)
    send(string.format("SETTLE %s %s %.1f %.1f %.1f %d", esc(S.my_name), tag, l.X, l.Y, l.Z, seed))
    status("settled " .. str(sp.Region.regionName) .. " (" .. tag .. "), " .. #starters .. " starting buildings")
end

-- ------------------------------------------------------------------ host: a guest's region
local function host_apply_settle(lord, tag, x, y, z, seed)
    local r = region_by_tag(tag)
    if not valid(r) or valid(r.ownerPawn) or r.isSettled then
        send("SETTLE_REFUSED " .. tag)
        status("refused " .. lord .. " in " .. tag .. ": region not free here")
        return
    end
    S.local_lords[lord] = false                            -- the guest owns this lord
    remember_guest(lord)
    report_new_buildings(nil)
    local p = find_lord(lord) or spawn_passive(lord, nil)
    S.allow_foreign = true
    settle(p, r, { X = x, Y = y, Z = z }, seed)
    report_new_buildings(nil)                              -- its starting buildings: made by settle on both sides
    S.allow_foreign = false
    S.guest_settled = true
    send("SETTLE_OK " .. esc(lord) .. " " .. tag)
    status(lord .. " joined in " .. str(r.regionName) .. " (" .. tag .. ")")
end

-- ------------------------------------------------------------------ messages
local function on_message(m)
    local cmd, rest = m:match("^(%S+)%s*(.*)$")
    if not cmd then return end
    if cmd == "HELLO" and S.role == "host" then
        local proto, ver, gamever, lord = rest:match("^(%d+) (%S+) (%S+) (%S+)$")
        local gi = FindFirstOf("BP_MLGameInstance_C")
        local my_gamever = esc(str(gi.Version))
        lord = lord and unesc(lord) or ""
        if tonumber(proto) ~= PROTO or ver ~= VERSION then send("REFUSE mod_version " .. VERSION); status("refused a guest: mod " .. tostring(ver) .. " (we have " .. VERSION .. ")")
        elseif gamever ~= my_gamever then send("REFUSE game_version " .. my_gamever); status("refused a guest: game " .. unesc(gamever or "?"))
        elseif lord == "" or (find_lord(lord) and not read_guests()[lord]) then send("REFUSE lord_name_taken"); status("refused a guest: lord name '" .. lord .. "' is taken")
        elseif find_lord(lord) then
            -- a guest we know is back: it takes its lord again from the world we send
            send("WELCOME " .. PROTO .. " " .. VERSION)
            status("guest " .. lord .. " is back, sending the world")
            send_world()
        else
            send("WELCOME " .. PROTO .. " " .. VERSION)
            status("guest " .. lord .. " accepted, sending the world")
            send_world()
        end
    elseif cmd == "WELCOME" and S.role == "join" then
        S.welcomed = true
        status("host accepted us, receiving the world")
    elseif cmd == "REFUSE" then
        S.phase = "refused"
        status("REFUSED by host: " .. rest)
    elseif cmd == "REGION" then
        local tag, owner, settled = rest:match("^(%S+) (%S+) (%d)$")
        if tag then S.host_regions[tag] = { owner = owner, settled = tonumber(settled) } end
    elseif cmd == "BOWN" and S.role == "join" then
        local lord, x, y = rest:match("^(%S+) (%S+) (%S+)$")
        if lord then S.bown = S.bown or {}; S.bown[#S.bown + 1] = { lord = unesc(lord), x = tonumber(x), y = tonumber(y) } end
    elseif cmd == "HOST_LORD" then
        S.host_lord = unesc(rest)
    elseif cmd == "WORLD_SENT" then
        S.world_sent = true
    elseif cmd == "SETTLE" and S.role == "host" then
        local lord, tag, x, y, z, seed = rest:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%d+)$")
        if lord then host_apply_settle(unesc(lord), tag, tonumber(x), tonumber(y), tonumber(z), seed) end
    elseif cmd == "LORD_SETTLE" and S.role == "join" then
        -- a new host-owned lord took a region: make a passive copy and settle it the same way
        local lord, tag, x, y, z, seed = rest:match("^(%S+) (%S+) (%S+) (%S+) (%S+) (%d+)$")
        if lord then
            lord = unesc(lord)
            local r = region_by_tag(tag)
            local p = find_lord(lord) or spawn_passive(lord, nil)
            report_new_buildings(nil)
            S.allow_foreign = true
            if valid(r) and valid(p) then settle(p, r, { X = tonumber(x), Y = tonumber(y), Z = tonumber(z) }, seed) end
            report_new_buildings(nil)
            S.allow_foreign = false
            status("host lord " .. lord .. " settled " .. tag)
        end
    elseif cmd == "RESUME" and S.role == "host" then
        S.guest_settled = true
        S.guest_resumed = (S.guest_resumed or 0) + 1
        status("guest " .. unesc(rest) .. " resumed its lord")
    elseif cmd == "SETTLE_OK" then
        status("host confirmed our region")
    elseif cmd == "SETTLE_REFUSED" then
        status("ERROR host refused our region " .. rest .. " (our world differs from the host's)")
    elseif cmd == "BLD" then
        local lord, id, t, x, y, z, yaw = rest:match("^(%S+) (%-?%d+) (%-?%d+) (%S+) (%S+) (%S+) (%S+)$")
        if lord and not is_local_lord(unesc(lord)) then apply_bld(unesc(lord), tonumber(t), tonumber(x), tonumber(y), tonumber(z), tonumber(yaw)) end
    elseif cmd == "FLD" then
        local lord, id, t, x, y, z, yaw, shape = rest:match("^(%S+) (%-?%d+) (%-?%d+) (%S+) (%S+) (%S+) (%S+) (.*)$")
        if lord and not is_local_lord(unesc(lord)) then apply_bld(unesc(lord), tonumber(t), tonumber(x), tonumber(y), tonumber(z), tonumber(yaw), shape) end
    elseif cmd == "OWN" then
        local lord, x, y = rest:match("^(%S+) (%S+) (%S+)")
        if lord and not is_local_lord(unesc(lord)) then
            lord = unesc(lord); x = tonumber(x); y = tonumber(y)
            local p = find_lord(lord)
            local best, bd = nil, 1e18
            for _, b in ipairs(buildings()) do
                local l = b:K2_GetActorLocation()
                local d = (l.X - x) ^ 2 + (l.Y - y) ^ 2
                if d < bd then best, bd = b, d end
            end
            if valid(p) and best and bd < 100 * 100 then
                best.ownerPawn = p
                S.known[best:GetAddress()] = true
                S.owner_of[best:GetAddress()] = lord
            end
        end
    elseif cmd == "ROAD" then
        local lord, payload = rest:match("^(%S+) (.*)$")
        if lord and not is_local_lord(unesc(lord)) then apply_road(unesc(lord), payload) end
    elseif cmd == "RM" then
        local lord, x, y = rest:match("^(%S+) (%S+) (%S+)")
        if lord and not is_local_lord(unesc(lord)) then apply_rm(unesc(lord), tonumber(x), tonumber(y)) end
    elseif cmd == "DAY" and S.role == "join" then
        local d = tonumber(rest)
        local eng = engine()
        local mine = -1
        pcall(function() mine = eng:getDaysTotal() end)
        if d and mine ~= d then pcall(function() eng:setDay(d) end) end
    elseif cmd == "BOT" then
        S.bot.peer_msg = rest
    end
end

local function on_inbox(line)
    if line:sub(1, 4) == "MSG " then on_message(line:sub(5)); return end
    if line:sub(1, 6) == "NATIVE" then
        native_ok = line:find("ready") ~= nil
        status(native_ok and ("native helper ready") or ("ERROR native helper: " .. line))
        if TEST == "bootcheck" then status(native_ok and "RESULT: PASS bootcheck" or "RESULT: FAIL bootcheck") end
    elseif line == "NET connected" then
        S.peer = true
        status("connected")
        if S.role == "join" then
            local gi = FindFirstOf("BP_MLGameInstance_C")
            local name = CFG.lord ~= "" and CFG.lord or "Guest"
            send(string.format("HELLO %d %s %s %s", PROTO, VERSION, esc(str(gi.Version)), esc(name)))
        end
    elseif line == "NET disconnected" then
        S.peer = false
        status("DISCONNECTED")
    elseif line:sub(1, 10) == "FILE_DONE " then
        S.files[line:sub(11)] = true
    elseif line:sub(1, 4) == "NET " then
        status(line)
    end
end

-- ------------------------------------------------------------------ fixed speed, calendar
local function keep_time()
    local eng = engine()
    if not valid(eng) then return end
    if eng.gameSpeed ~= 1.0 then pcall(function() eng:setGameSpeed(1.0) end) end
    if S.role == "host" and S.peer then
        local d = nil
        pcall(function() d = eng:getDaysTotal() end)
        if d and d ~= S.last_day then S.last_day = d; send("DAY " .. d) end
    end
end

-- ------------------------------------------------------------------ test bot (lab only)
local Bot = {}
function Bot.start_new_game()
    local menu = FindFirstOf("mainMenu_widget_C")
    if not valid(menu) then return end
    if TEST == "campaign2" then
        -- the host comes back another day: load the co-op game it saved
        local slot = "coop_campaign"
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local desc = gs:LoadGameFromSlot(slot .. "_descr", 0)
        FindFirstOf("BP_MLGameInstance_C").savefileToLoad = slot
        menu:LoadGame({ SlotIndex = 0, Descriptor = desc })
        status("BOT loading the saved co-op game " .. slot)
        return
    end
    menu:startNewGame()
end
function Bot.build_some(lord, n)
    local p = find_lord(lord)
    local home = nil
    for _, b in ipairs(buildings()) do if same(b.ownerPawn, p) then home = b:K2_GetActorLocation(); break end end
    if not home then status("BOT no home for " .. lord); return end
    local eng = engine()
    local types = { 3, 3, 13, 4, 3 }
    for i = 1, n do
        local ang = (i / n) * 6.283
        local loc = { X = home.X + math.cos(ang) * 2500, Y = home.Y + math.sin(ang) * 2500, Z = home.Z }
        local r = eng:getRegionByPos(loc, false)
        native(string.format("buildlocal %d %.1f %.1f %.1f %.2f %x %x", types[(i - 1) % #types + 1], loc.X, loc.Y, loc.Z, i * 30.0, eng:GetAddress(), valid(r) and r:GetAddress() or 0))
    end
    status("BOT built " .. n .. " for " .. lord)
end
function Bot.remove_one(lord)
    local p = find_lord(lord)
    local list = {}
    for _, b in ipairs(buildings()) do if same(b.ownerPawn, p) then list[#list + 1] = b end end
    table.sort(list, function(a, b) return a:K2_GetActorLocation().X < b:K2_GetActorLocation().X end)
    if #list > 0 then remove_building(list[#list]); status("BOT removed one of " .. lord) end
end
function Bot.shapes()
    -- field buildings: point counts per lord, to compare shapes on both copies
    for _, b in ipairs(buildings()) do
        local owner = ""
        pcall(function() owner = lord_name(b.ownerPawn) end)
        local nf, nb = 0, 0
        pcall(function() nf = #b.FieldPoints; nb = #b.fieldBorderPoints end)
        if owner ~= "" and nb > 0 then
            local l = b:K2_GetActorLocation()
            status(string.format("SHAPE lord=%s at=%d,%d points=%d border=%d", esc(owner), math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5), nf, nb))
        end
    end
end
function Bot.state()
    -- per lord: sorted positions (10 cm), compared by the lab between the two copies
    local per = {}
    for _, b in ipairs(buildings()) do
        local owner = ""
        pcall(function() owner = lord_name(b.ownerPawn) end)
        if owner ~= "" and not S.road_made[b:GetAddress()] then
            local l = b:K2_GetActorLocation()
            per[owner] = per[owner] or {}
            table.insert(per[owner], string.format("%d,%d", math.floor(l.X / 10 + 0.5), math.floor(l.Y / 10 + 0.5)))
        end
    end
    for owner, list in pairs(per) do
        table.sort(list)
        status("STATE lord=" .. esc(owner) .. " n=" .. #list .. " " .. table.concat(list, " "))
    end
    for _, p in ipairs(FindAllOf("PawnCPP_AI") or {}) do
        if valid(p) then
            local g = -1
            pcall(function() g = p.AI_general_cycles end)
            status("AISTATE lord=" .. esc(lord_name(p)) .. " passive=" .. tostring(passive_lords[lord_name(p)] == true or S.all_ai_passive == true) .. " cycles=" .. tostring(g))
        end
    end
    local regions = {}
    for _, r in ipairs(FindAllOf("Region") or {}) do
        if valid(r) then regions[#regions + 1] = str(r.regionUniqueTag) .. "=" .. (valid(r.ownerPawn) and esc(lord_name(r.ownerPawn)) or "-") .. (r.isSettled and "*" or "") end
    end
    table.sort(regions)
    status("STATE regions " .. table.concat(regions, " "))
end
-- a square field drawn around a point: smooth points (P) and a closed border (B), tenths of a unit
local function square_shape(cx, cy, z, half)
    local corners = { { cx - half, cy - half }, { cx + half, cy - half }, { cx + half, cy + half }, { cx - half, cy + half } }
    local P, B = {}, {}
    for i = 1, 4 do
        local a, b = corners[i], corners[i % 4 + 1]
        for k = 0, 2 do
            local t = k / 3
            P[#P + 1] = string.format("%d %d %d", math.floor((a[1] + (b[1] - a[1]) * t) * 10), math.floor((a[2] + (b[2] - a[2]) * t) * 10), math.floor(z * 10))
        end
        B[#B + 1] = string.format("%d %d %d", math.floor(a[1] * 10), math.floor(a[2] * 10), math.floor(z * 10))
    end
    B[#B + 1] = B[1]
    return string.format("P %d %s B %d %s", #P, table.concat(P, " "), #B, table.concat(B, " "))
end
function Bot.fields(lord)
    local p = find_lord(lord)
    local home = nil
    for _, b in ipairs(buildings()) do if same(b.ownerPawn, p) then home = b:K2_GetActorLocation(); break end end
    if not home then return end
    local eng = engine()
    for i, t in ipairs({ 5, 10 }) do                        -- a field and a pasture
        local cx, cy = home.X + (i == 1 and 4000 or -4000), home.Y + 3000
        local r = eng:getRegionByPos({ X = cx, Y = cy, Z = home.Z }, false)
        native(string.format("testfield %d %.1f %.1f %.1f 0 %x %x 2 1 1 %s", t, cx, cy, home.Z, eng:GetAddress(),
            valid(r) and r:GetAddress() or 0, square_shape(cx, cy, home.Z, 1200)))
    end
    status("BOT drew a field and a pasture for " .. lord)
end

-- scenario "mirror": both sides build, then each removes one; then quiet, then STATE
function Bot.tick()
    if TEST == "" or S.phase ~= "playing" then return end
    local b = S.bot
    b.t = (b.t or 0) + 1                                    -- seconds in "playing"
    local me = S.role == "host" and lord_name(engine().playerRef) or S.my_name
    if TEST == "mirror" then
        if S.role == "host" and not b.ready then
            if S.guest_settled then b.ready = true; b.t0 = b.t end
            return
        end
        if S.role == "join" and not b.ready then b.ready = true; b.t0 = b.t end
        local t = b.t - b.t0
        if t == 10 then Bot.build_some(me, 5) end
        if t == 25 then Bot.remove_one(me) end
        if t == 60 then Bot.state(); status("RESULT: PASS mirror (compare STATE lines)"); b.done = true end
    elseif TEST == "aibuild" then
        -- the host spawns an AI builder lord (host-owned): its houses, plots and fields reach the guest
        if S.role == "host" and not b.ready then
            if S.guest_settled then
                b.ready = true; b.t0 = b.t
                local eng = engine()
                eng:spawnNewAILord("Bot Builder", false, nil, true)
                local p = find_lord("Bot Builder")
                local sp = nil
                for _, c in ipairs(FindAllOf("BP_VillageSpawner_C") or {}) do
                    if valid(c) and c.CanBePlayer and not c.banditCamp and not c.Tradepoint and valid(c.Region)
                       and not valid(c.Region.ownerPawn) and not c.Region.isSettled then sp = c; break end
                end
                S.local_lords["Bot Builder"] = true
                local seed = math.random(1, 1000000)
                settle(p, sp.Region, sp:K2_GetActorLocation(), seed)
                report_new_buildings("Bot Builder")
                local l = sp:K2_GetActorLocation()
                send(string.format("LORD_SETTLE %s %s %.1f %.1f %.1f %d", esc("Bot Builder"), str(sp.Region.regionUniqueTag), l.X, l.Y, l.Z, seed))
                status("BOT spawned an AI builder in " .. str(sp.Region.regionUniqueTag))
            end
            return
        end
        if S.role == "join" and not b.ready then b.ready = true; b.t0 = b.t end
        local t = b.t - b.t0
        if t == 100 then Bot.state(); Bot.shapes(); status("RESULT: PASS aibuild (compare STATE lines)"); b.done = true end
    elseif TEST == "roads" then
        if S.role == "host" and not b.ready then
            if S.guest_settled then b.ready = true; b.t0 = b.t end
            return
        end
        if S.role == "join" and not b.ready then b.ready = true; b.t0 = b.t end
        local t = b.t - b.t0
        if t == 10 then
            -- a real road commit by the main pawn, like a player's: try places until one is accepted
            local p = engine().playerRef
            local home = nil
            for _, bb in ipairs(buildings()) do if same(bb.ownerPawn, p) then home = bb:K2_GetActorLocation(); break end end
            local made = false
            for _, off in ipairs({ { 1500, 0 }, { -1500, 0 }, { 0, 1500 }, { 0, -1500 }, { 3000, 0 }, { -3000, 0 }, { 0, 3000 }, { 0, -3000 } }) do
                local n0 = #(FindAllOf("Road") or {})
                local a = { X = home.X + off[1] - 1000, Y = home.Y + off[2] - 2500, Z = home.Z }
                local m = { X = home.X + off[1], Y = home.Y + off[2], Z = home.Z }
                local c = { X = home.X + off[1] + 1000, Y = home.Y + off[2] + 2500, Z = home.Z }
                pcall(function()
                    p:setRoadMode(true, a, true)
                    p.roadStartPos = a
                    p.roadPoints = { a, m, c }
                    p:commitRoad()
                    p:setRoadMode(false, a, false)
                end)
                if #(FindAllOf("Road") or {}) > n0 then made = true; status("BOT built a real road for " .. me .. " at offset " .. off[1] .. "," .. off[2]); break end
            end
            if not made then
                -- no cursor in the lab: send a synthetic road so the receiving side is still tested
                local a = { X = home.X + 1500, Y = home.Y - 2500, Z = home.Z }
                local m = { X = home.X + 1500, Y = home.Y, Z = home.Z }
                local c = { X = home.X + 1500, Y = home.Y + 2500, Z = home.Z }
                local function t10(v) return string.format("%d %d %d", math.floor(v.X * 10), math.floor(v.Y * 10), math.floor(v.Z * 10)) end
                send("ROAD " .. esc(me) .. " 1 " .. t10(a) .. " 3 " .. t10(a) .. " " .. t10(m) .. " " .. t10(c))
                status("BOT could not build a real road for " .. me .. " (no cursor in the lab); sent a synthetic one")
            end
        end
        if t == 40 then
            status("ROADSTATE count=" .. #(FindAllOf("Road") or {}))
            Bot.state(); status("RESULT: PASS roads (compare ROADSTATE)"); b.done = true
        end
    elseif TEST == "campaign" then
        -- day 1: the guest settles and builds, the host saves, then the lab stops both
        if S.role == "host" then
            if not b.ready then if S.guest_settled then b.ready = true; b.t0 = b.t end return end
            local t = b.t - b.t0
            if t == 30 then engine().playerRef:requestSaveFile("coop_campaign", "coop_campaign"); status("BOT saved coop_campaign") end
            if t == 45 then Bot.state(); status("RESTART_NOW") end
            return
        end
        if not b.ready then b.ready = true; b.t0 = b.t end
        if b.t - b.t0 == 5 then Bot.build_some(me, 3) end
    elseif TEST == "campaign2" then
        -- day 2: the host loaded the saved game, the guest comes back and must get its lord back
        if S.role == "host" then
            if (S.guest_resumed or 0) >= 1 then
                b.r = (b.r or 0) + 1
                if b.r == 40 then Bot.state(); status("RESULT: PASS campaign (compare STATE lines)"); b.done = true end
            end
            return
        end
        if not b.ready then b.ready = true; b.t0 = b.t end
        if b.t - b.t0 == 35 then
            Bot.state()
            status(S.resumed and "RESULT: PASS campaign (compare STATE lines)" or "RESULT: FAIL campaign: did not resume")
            b.done = true
        end
    elseif TEST == "rejoin" or TEST == "rejoin2" then
        -- the guest builds, leaves (the lab stops it), comes back and must get its lord back
        if S.role == "host" then
            if not b.ready then if S.guest_settled then b.ready = true end return end
            if (S.guest_resumed or 0) >= 1 then
                b.r = (b.r or 0) + 1
                if b.r == 40 then Bot.state(); status("RESULT: PASS rejoin (compare STATE lines)"); b.done = true end
            end
            return
        end
        if not b.ready then b.ready = true; b.t0 = b.t end
        local t = b.t - b.t0
        if TEST == "rejoin" then
            if t == 5 then Bot.build_some(me, 3) end
            if t == 25 then status("REJOIN_NOW") end
        else
            if t == 35 then
                Bot.state()
                status(S.resumed and "RESULT: PASS rejoin (compare STATE lines)" or "RESULT: FAIL rejoin: did not resume")
                b.done = true
            end
        end
    elseif TEST == "fields" then
        if S.role == "host" and not b.ready then
            if S.guest_settled then b.ready = true; b.t0 = b.t end
            return
        end
        if S.role == "join" and not b.ready then b.ready = true; b.t0 = b.t end
        local t = b.t - b.t0
        if t == 10 then Bot.fields(me) end
        if t == 45 then Bot.state(); Bot.shapes(); status("RESULT: PASS fields (compare STATE lines)"); b.done = true end
    end
end

-- ------------------------------------------------------------------ main loop
status("ManorLordsCoop " .. VERSION .. " role=" .. CFG.role .. (TEST ~= "" and (" test=" .. TEST) or "") .. " dir=" .. MOD_DIR)
if CFG.role ~= "host" and CFG.role ~= "join" then
    status("co-op is off (set role = host or join in config.txt)")
    return
end
math.randomseed(os.time())

local busy = false
local sec = 0
LoopAsync(250, function()
    if busy then return false end
    busy = true
    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            S.ticks = S.ticks + 1
            if S.phase == "refused" then return end
            if S.phase == "boot" then
                if S.native_loaded == nil then
                    S.native_loaded = load_native()
                    if not S.native_loaded then
                        S.phase = "refused"
                        status("co-op disabled: the native helper did not load")
                        if TEST ~= "" then status("RESULT: FAIL native helper did not load") end
                        return
                    end
                end
                for _, line in ipairs(read_inbox()) do on_inbox(line) end
                if world_name():find("MainMenu") and FindFirstOf("mainMenu_widget_C") then S.phase = "menu" end
                return
            end
            for _, line in ipairs(read_inbox()) do on_inbox(line) end
            local in_game = (not world_name():find("MainMenu")) and valid(engine()) and valid(engine().playerRef)
            if next(passive_watch) and in_game then
                for name, left in pairs(passive_watch) do
                    for _, p in ipairs(FindAllOf("PawnCPP_AI") or {}) do
                        if valid(p) and lord_name(p) == name then make_passive(p) end
                    end
                    passive_watch[name] = (left > 1) and (left - 1) or nil
                end
            end
            local whole_second = (S.ticks % 4 == 0)
            if S.phase == "menu" then
                if S.role == "host" then
                    if TEST ~= "" and not S.bot.started then S.bot.started = true; Bot.start_new_game() end
                    if in_game then
                        S.phase = "hosting"
                        S.local_lords = {}
                        for _, p in ipairs(FindAllOf("PawnCPP") or {}) do if valid(p) then S.local_lords[lord_name(p)] = true end end
                        if CFG.lord ~= "" then engine().playerRef.lordsName = CFG.lord; S.local_lords[CFG.lord] = true end
                        -- lords of guests from earlier sessions stay theirs, and passive here
                        for name in pairs(read_guests()) do
                            local gp = find_lord(name)
                            if valid(gp) then S.local_lords[name] = false; make_passive(gp); status("known guest lord " .. name .. " is passive here") end
                        end
                        read_outbox()
                        track_existing()
                        S.road_count = #(FindAllOf("Road") or {})
                        native("net host " .. CFG.port)
                        status("hosting on port " .. CFG.port .. " as " .. lord_name(engine().playerRef))
                    end
                elseif S.role == "join" then
                    if not S.join_started and native_ok then
                        S.join_started = true
                        native("net join " .. CFG.address .. " " .. CFG.port)
                        status("joining " .. CFG.address .. ":" .. CFG.port)
                    end
                    local need = { WORLD_SLOT .. ".sav", WORLD_SLOT .. "_descr.sav" }
                    local have = S.world_sent
                    for _, n in ipairs(need) do have = have and S.files[n] end
                    if have and not S.loading then
                        S.loading = true
                        status("world received, loading")
                        if not load_world() then S.phase = "refused" end
                    end
                    if S.loading and in_game then S.phase = "loading"; S.load_t = 0 end
                end
                return
            end
            if S.phase == "loading" then
                S.load_t = S.load_t + 1
                if S.load_t == 20 then                      -- let the loaded world settle for 5 s
                    if guest_take_over() then
                        read_outbox()
                        if S.resumed then send("RESUME " .. esc(S.my_name)) else guest_settle() end
                        track_existing()
                        S.road_count = #(FindAllOf("Road") or {})
                        S.phase = "playing"
                    end
                end
                return
            end
            if S.role == "host" and whole_second and S.save_wait then poll_world_saved() end
            if S.phase == "hosting" then
                if S.peer and S.world_sent then S.phase = "playing" end
            end
            if S.phase == "playing" or S.phase == "hosting" then
                if whole_second then
                    report_new_buildings(nil)
                    if sec % 2 == 0 then scan_buildings() end
                    report_removed()
                    keep_time()
                    sec = sec + 1
                    if sec % 5 == 0 then
                        -- the game can start a lord's AI after we created it: clear its timers again
                        for _, p in ipairs(FindAllOf("PawnCPP_AI") or {}) do
                            if valid(p) and (passive_lords[lord_name(p)] or S.all_ai_passive) then make_passive(p) end
                        end
                    end
                    if sec % 5 == 0 and S.role == "host" then
                        -- lords the game creates later (new bandits, AI lords) are the host's
                        for _, p in ipairs(FindAllOf("PawnCPP") or {}) do
                            local n = lord_name(p)
                            if valid(p) and S.local_lords[n] == nil then S.local_lords[n] = true end
                        end
                    end
                    Bot.tick()
                end
            end
        end)
        if not ok then status("ERROR " .. tostring(err)) end
        busy = false
    end)
    return false
end)

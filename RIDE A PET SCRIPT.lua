--[[
╭──────────────────────────────────────────────────────────────────────╮
│              NUXEON — Modular Script Loader                      │
│         Auto-cache · Version check · Multi-game routing              │
╰──────────────────────────────────────────────────────────────────────╯

    Rewritten:
    • Capability detection uses type() consistently (no typeof on HttpGet)
    • HTTP retry uses exponential backoff
    • Module load prints progress [N/Total] in real time
    • Health check verifies REQUIRED keys after all modules load
    • Route fallback logs which route was selected and why
    • cleanSourceCode handles all common BOM variants
    • Cache.clear() also removes the version file so a full refresh is clean
    • All Thai comments translated to English for maintainability
]]

-- ── Configuration ────────────────────────────────────────────────────
local CONFIG = {
    BASE_URL    = "https://raw.githubusercontent.com/LostInSyntaxx/RideAPet/main/src/",
    VERSION_URL = "https://raw.githubusercontent.com/LostInSyntaxx/RideAPet/main/version.txt",
    CACHE_DIR   = "NYXEON RIDE A PET",
    NAMESPACE   = "EggsESP",

    USE_DISK_CACHE = true,
    FORCE_REFRESH  = false,
    MAX_RETRIES    = 3,
    RETRY_DELAY    = 0.5,   -- base seconds; multiplied by attempt number (exponential)

    -- Load order matters — each module may depend on the previous
    MODULES = {
        "LoadingScreen", "Config", "Services", "State", "Utils",
        "Webhook", "Stability", "Interaction", "Movement", "Plot",
        "ESP", "Farm", "Rebirth", "UI", "Bootstrap",
    },

    -- Keys that must exist on the namespace after all modules load
    REQUIRED = {
        "Config", "Services", "StateStore", "Utils",
        "ESP", "Farm", "Rebirth", "Movement", "Plot", "UI",
    },

    -- Game-specific routing table
    -- Add entries here for each new game; last entry with isDefault=true is fallback
    GAME_ROUTES = {
        {
            name     = "Pull An Egg",
            url      = "https://raw.githubusercontent.com/LostInSyntaxx/RideAPet/main/scripts/pull_an_egg.lua",
            placeIds = { 70640255604878 },
            gameIds  = { 10649255304 },
        },
        {
            name      = "Ride A Pet",
            isDefault = true,
            modules   = true,   -- uses the modular loader path
        },
    },
}

-- ── Logger ───────────────────────────────────────────────────────────
local LOG = "[NYXEON RIDE A PET]"
local Log = {
    info  = function(m) print(LOG .. "  " .. tostring(m)) end,
    ok    = function(m) print(LOG .. " ✓  " .. tostring(m)) end,
    warn  = function(m) warn (LOG .. " ⚠  " .. tostring(m)) end,
    err   = function(m) warn (LOG .. " ✗  " .. tostring(m)) end,
    step  = function(i, n, m) print(LOG .. (" [%d/%d] "):format(i, n) .. tostring(m)) end,
}

-- ── Capability detection ─────────────────────────────────────────────
local CAP = {
    readfile   = type(readfile)   == "function",
    writefile  = type(writefile)  == "function",
    isfile     = type(isfile)     == "function",
    isfolder   = type(isfolder)   == "function",
    makefolder = type(makefolder) == "function",
    delfile    = type(delfile)    == "function",
    loadstring = type(loadstring) == "function",
}

local DISK_OK = CONFIG.USE_DISK_CACHE
    and CAP.readfile and CAP.writefile
    and CAP.isfile   and CAP.isfolder
    and CAP.makefolder

-- ── Source sanitisation ──────────────────────────────────────────────
-- Strips UTF-8 BOM (3-byte) and UTF-16 BOMs, then leading whitespace.
local function cleanSource(src)
    if not src then return "" end
    -- UTF-8 BOM: EF BB BF
    if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end
    -- UTF-16 LE BOM: FF FE
    if src:sub(1, 2) == "\255\254"     then src = src:sub(3) end
    -- UTF-16 BE BOM: FE FF
    if src:sub(1, 2) == "\254\255"     then src = src:sub(3) end
    return src:match("^%s*(.-)%s*$") or src
end

-- ── HTTP with exponential backoff ────────────────────────────────────
local function httpGet(url)
    for attempt = 1, CONFIG.MAX_RETRIES do
        local ok, result = pcall(function() return game:HttpGet(url, true) end)
        if ok and type(result) == "string" and #result > 0 then
            return result
        end
        if attempt < CONFIG.MAX_RETRIES then
            task.wait(CONFIG.RETRY_DELAY * attempt)
        end
    end
    Log.err("HTTP failed (" .. CONFIG.MAX_RETRIES .. " attempts) → " .. tostring(url))
    return nil
end

-- ── Game-loaded gate ─────────────────────────────────────────────────
local function waitForGame()
    local deadline = os.clock() + 8
    while (game.PlaceId == 0 or game.GameId == 0) and os.clock() < deadline do
        task.wait(0.1)
    end
    if game.PlaceId == 0 then
        Log.warn("PlaceId still 0 after wait — loader may behave unexpectedly")
    end
end

-- ── Disk cache ───────────────────────────────────────────────────────
local Cache = { memory = {}, dir = CONFIG.CACHE_DIR }

function Cache.init(subDir)
    if subDir then
        Cache.dir = CONFIG.CACHE_DIR .. "/" .. subDir:gsub("[%s%c%p]", "_")
    end
    if not DISK_OK then return end
    if not isfolder(CONFIG.CACHE_DIR) then pcall(makefolder, CONFIG.CACHE_DIR) end
    if not isfolder(Cache.dir)        then pcall(makefolder, Cache.dir)        end
end

function Cache.read(name)
    if Cache.memory[name] then return Cache.memory[name] end
    if DISK_OK then
        local path = Cache.dir .. "/" .. name .. ".lua"
        if isfile(path) then
            local ok, data = pcall(readfile, path)
            if ok and data and #data > 0 then
                Cache.memory[name] = data
                return data
            end
        end
    end
    return nil
end

function Cache.write(name, data)
    if not data or #data == 0 then return end
    Cache.memory[name] = data
    if DISK_OK then
        pcall(writefile, Cache.dir .. "/" .. name .. ".lua", data)
    end
end

function Cache.clear()
    Cache.memory = {}
    if not (DISK_OK and isfolder(Cache.dir)) then return end
    -- Clear module files
    for _, name in ipairs(CONFIG.MODULES) do
        local path = Cache.dir .. "/" .. name .. ".lua"
        if isfile(path) and CAP.delfile then pcall(delfile, path) end
    end
    -- Also remove version file so next run fetches fresh
    local vpath = Cache.dir .. "/_version.txt"
    if isfile(vpath) and CAP.delfile then pcall(delfile, vpath) end
end

-- ── Version check ────────────────────────────────────────────────────
local function checkVersion()
    if not CONFIG.VERSION_URL then return nil, false end
    local remoteRaw = httpGet(CONFIG.VERSION_URL)
    if not remoteRaw then
        Log.warn("Could not fetch remote version — using cached modules as-is")
        return nil, false
    end
    local remoteVer = remoteRaw:match("^%s*(.-)%s*$")

    local localVer = nil
    if DISK_OK then
        local path = Cache.dir .. "/_version.txt"
        if isfile(path) then
            local ok, data = pcall(readfile, path)
            if ok and data then localVer = data:match("^%s*(.-)%s*$") end
        end
    else
        localVer = Cache.memory._version
    end

    if localVer ~= remoteVer then
        Log.info(("Version: %s → %s (cache invalidated)"):format(
            tostring(localVer or "none"), remoteVer))
        return remoteVer, true
    end
    return remoteVer, false
end

local function saveVersion(ver)
    if not ver then return end
    if DISK_OK then
        pcall(writefile, Cache.dir .. "/_version.txt", ver)
    end
    Cache.memory._version = ver
end

-- ── Route matching ───────────────────────────────────────────────────
local function matchRoute(route)
    local pid = game.PlaceId
    local gid = game.GameId
    for _, id in ipairs(route.placeIds or {}) do
        if pid == tonumber(id) then return true, "PlaceId=" .. tostring(id) end
    end
    for _, id in ipairs(route.gameIds or {}) do
        if gid == tonumber(id) then return true, "GameId=" .. tostring(id) end
    end
    return false, nil
end

-- ── Fetch a single module (cache → HTTP → stale) ─────────────────────
local function fetchModule(name, forceRefresh)
    if not forceRefresh and not CONFIG.FORCE_REFRESH then
        local cached = Cache.read(name)
        if cached then return cached, "cache" end
    end
    local src = httpGet(CONFIG.BASE_URL .. name .. ".lua")
    if src then
        Cache.write(name, src)
        return src, "http"
    end
    -- HTTP failed — fall back to stale cache
    local stale = Cache.read(name)
    if stale then
        Log.warn("Using stale cache for: " .. name)
        return stale, "stale"
    end
    return nil, "failed"
end

-- ── Compile and execute a Lua source string ──────────────────────────
local function compileAndRun(name, src)
    if not src or #src < 10 then
        Log.err("Empty/invalid source: " .. name)
        return false
    end
    src = cleanSource(src)
    local chunk, compileErr = loadstring(src, "=" .. name)
    if not chunk then
        Log.err("Compile [" .. name .. "]: " .. tostring(compileErr))
        return false
    end
    local ok, runtimeErr = pcall(chunk)
    if not ok then
        Log.err("Runtime [" .. name .. "]: " .. tostring(runtimeErr))
        return false
    end
    return true
end

-- ── Health check: verify all REQUIRED keys exist on the namespace ────
local function healthCheck(NS)
    local missing = {}
    for _, key in ipairs(CONFIG.REQUIRED) do
        if NS[key] == nil then
            table.insert(missing, key)
        end
    end
    if #missing > 0 then
        Log.err("Health check failed — missing: " .. table.concat(missing, ", "))
        return false
    end
    return true
end

-- ── Single-script route (e.g. Pull An Egg) ───────────────────────────
local function runSingleScript(route, matchedBy)
    Log.info("🎮 Route → " .. route.name .. "  (" .. tostring(matchedBy) .. ")")
    local src = httpGet(route.url)
    if not src then
        Log.err("Download failed: " .. route.name)
        return false
    end
    src = cleanSource(src)
    local fn, loadErr = loadstring(src)
    if not fn then
        Log.err("Compile [" .. route.name .. "]: " .. tostring(loadErr))
        Log.warn("First line: " .. (src:match("([^\r\n]+)") or "EMPTY"))
        return false
    end
    local ok, runtimeErr = pcall(fn)
    if not ok then
        Log.err("Runtime [" .. route.name .. "]: " .. tostring(runtimeErr))
        return false
    end
    Log.ok(route.name .. " loaded.")
    return true
end

-- ── Modular route (e.g. Ride A Pet) ──────────────────────────────────
local function runModular(route, t0)
    Log.info("🐾 Route → " .. route.name .. "  (modular, " .. #CONFIG.MODULES .. " modules)")
    Cache.init(route.name)

    local newVer, needsRefresh = checkVersion()
    if needsRefresh then Cache.clear() end

    getgenv()[CONFIG.NAMESPACE] = getgenv()[CONFIG.NAMESPACE] or {}
    local NS = getgenv()[CONFIG.NAMESPACE]
    NS.Modules = NS.Modules or {}

    local total = #CONFIG.MODULES
    local stats = {cache = 0, http = 0, stale = 0, failed = 0}

    for i, name in ipairs(CONFIG.MODULES) do
        local src, source = fetchModule(name, needsRefresh)
        if src then
            Log.step(i, total, name .. "  [" .. source .. "]")
            local ok = compileAndRun(name, src)
            stats[ok and source or "failed"] = (stats[ok and source or "failed"] or 0) + 1
            if not ok then stats.failed += 1 end
        else
            Log.step(i, total, name .. "  [FAILED]")
            stats.failed += 1
        end
    end

    if stats.failed > 0 then
        Log.err(stats.failed .. " module(s) failed to load")
    end

    if not healthCheck(NS) then
        Log.err("Aborting — required namespace keys missing")
        return false
    end

    if newVer and stats.failed == 0 then saveVersion(newVer) end

    Log.ok(("Done in %.2fs  |  cache:%d  http:%d  stale:%d  failed:%d"):format(
        os.clock() - t0, stats.cache, stats.http, stats.stale, stats.failed))
    return stats.failed == 0
end

-- ── Main entry point ─────────────────────────────────────────────────
local function main()
    local t0 = os.clock()

    if not CAP.loadstring then
        Log.err("Executor does not support loadstring — aborted")
        return
    end

    waitForGame()
    Log.info(("PlaceId: %d  |  GameId: %d"):format(game.PlaceId, game.GameId))

    -- Route selection: first specific match wins, then default fallback
    local selected, matchedBy = nil, nil
    for _, route in ipairs(CONFIG.GAME_ROUTES) do
        local matched, by = matchRoute(route)
        if matched then
            selected, matchedBy = route, by
            break
        end
    end
    if not selected then
        for _, route in ipairs(CONFIG.GAME_ROUTES) do
            if route.isDefault then
                selected, matchedBy = route, "default fallback"
                break
            end
        end
    end

    if not selected then
        Log.err("No route matched PlaceId " .. tostring(game.PlaceId) .. " and no default defined")
        return
    end

    if selected.url then
        -- Single-file route
        if not runSingleScript(selected, matchedBy) then
            Log.warn("Single-script route failed — no fallback available")
        end
    elseif selected.modules then
        -- Modular route
        runModular(selected, t0)
    else
        Log.err("Route '" .. tostring(selected.name) .. "' has neither url nor modules — skipped")
    end
end

-- Guard the entire loader so a top-level error is visible
local ok, err = pcall(main)
if not ok then
    warn("[NYXEON RIDE A PET] ✗ Fatal: " .. tostring(err))
end
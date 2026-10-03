local ADDON, ns = ...
local Ledger = ns.Ledger

local SALT = "GoldTrace:v1:"
local PEER_MAX_AGE = 30 * 86400

local floor, format = math.floor, string.format

-- Event dispatch. Names starting with "GT_" are internal signals sent with ns.Fire.
local frame = CreateFrame("Frame")
local handlers = {}

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if event:sub(1, 3) ~= "GT_" then
            -- Unknown events throw on some clients; a missing event just never fires.
            pcall(frame.RegisterEvent, frame, event)
        end
    end
    table.insert(handlers[event], fn)
end

function ns.Fire(event, ...)
    local list = handlers[event]
    if list then
        for _, fn in ipairs(list) do fn(...) end
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    ns.Fire(event, ...)
end)

function ns.Print(msg)
    print("|cffffd100GoldTrace:|r " .. msg)
end

-- Midnight-era clients hand addons opaque "secret" values in some situations;
-- comparing or concatenating them throws, so check before touching.
function ns.IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- "Name-Realm" key for a character. Returns nil if the name can't be read.
function ns.Key(name, realm)
    if type(name) ~= "string" or ns.IsSecret(name) or name == "" then return nil end
    if name:find("-", 1, true) then return (name:gsub("%s", "")) end
    if type(realm) ~= "string" or ns.IsSecret(realm) or realm == "" then realm = ns.realm end
    if not realm then return nil end
    return name .. "-" .. realm:gsub("%s", "")
end

function ns.SaltFor(key)
    return SALT .. key
end

function ns.Money(copper)
    copper = floor(copper + 0.5)
    local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
    if g > 0 then return format("%dg %ds", g, s) end
    if s > 0 then return format("%ds %dc", s, c) end
    return format("%dc", c)
end

local function InitDB()
    if type(GoldTraceDB) ~= "table" then GoldTraceDB = {} end
    local db = GoldTraceDB
    for _, k in ipairs({ "chars", "peers", "transit", "opts" }) do
        if type(db[k]) ~= "table" then db[k] = {} end
    end
    if type(db.pool) ~= "table" then
        db.pool = { clean = 0, unverified = 0, flagged = 0, untracked = 0 }
    end
    if type(db.opts.warnPct) ~= "number" then db.opts.warnPct = 10 end
    ns.db = db
end

local function InitChar()
    local name, realm = UnitFullName("player")
    ns.realm = (realm and realm ~= "" and realm) or GetNormalizedRealmName()
    ns.me = ns.Key(name, ns.realm)
    if not ns.me then return end
    ns.salt = ns.SaltFor(ns.me)

    local db, money, now = ns.db, GetMoney(), time()
    local char = db.chars[ns.me]
    if type(char) ~= "table" then
        char = Ledger.New(money, now, ns.salt)
    elseif not Ledger.Verify(char, ns.salt) then
        char = Ledger.New(money, now, ns.salt, true)
        ns.Print("saved data for this character failed its integrity check and was reset.")
    else
        Ledger.Reconcile(char, ns.salt, money, now)
    end
    db.chars[ns.me] = char
    ns.char = char

    for key, peer in pairs(db.peers) do
        if type(peer) ~= "table" or type(peer.seen) ~= "number" or now - peer.seen > PEER_MAX_AGE then
            db.peers[key] = nil
        end
    end

    ns.Fire("GT_READY")
end

ns.On("ADDON_LOADED", function(name)
    if name == ADDON then InitDB() end
end)

ns.On("PLAYER_ENTERING_WORLD", function()
    if not ns.char and ns.db then InitChar() end
end)

SLASH_GOLDTRACE1 = "/goldtrace"
SLASH_GOLDTRACE2 = "/gtrace"
SlashCmdList.GOLDTRACE = function(msg)
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    if cmd == "" then
        ns.ToggleLedger()
    elseif cmd == "warn" then
        local n = tonumber(arg)
        if n and n >= 0 and n <= 100 then
            ns.db.opts.warnPct = n
            ns.Print(format("unknown-origin warning now shows at %d%% or more.", n))
        else
            ns.Print(format("warning threshold is %d%%. Change it with /goldtrace warn <0-100>.", ns.db.opts.warnPct))
        end
    elseif cmd == "test" then
        local passed, failures = ns.RunTests()
        ns.Print(format("self-test: %d passed, %d failed.", passed, #failures))
        for _, name in ipairs(failures) do ns.Print("  failed: " .. name) end
    else
        ns.Print("/goldtrace - open your ledger")
        ns.Print("/goldtrace warn <0-100> - unknown-origin warning threshold (percent)")
        ns.Print("/goldtrace test - run the built-in self-test")
    end
end

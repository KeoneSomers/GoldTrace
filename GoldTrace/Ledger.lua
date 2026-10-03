-- Per-character gold ledger. Pure Lua (no WoW API) so it can be tested standalone.
--
-- A character's balance is held in provenance buckets (copper):
--   clean       earned from the game: quests, loot, vendors, normal auctions
--   unverified  came from a character that doesn't run the addon; origin unknown
--   flagged     large one-sided transfers from strangers, or overpriced auctions
--   untracked   held before the addon was installed, or gained while it was off
-- Gold keeps its bucket when it moves, so passing it through an alt doesn't clean it.
local _, ns = ...
local Seal = ns.Seal

local Ledger = {}
ns.Ledger = Ledger

local floor, min, format, concat = math.floor, math.min, string.format, table.concat

local BUCKETS = { "clean", "unverified", "flagged", "untracked" }
-- Rounding remainders on income go to the least favourable bucket first, so
-- splitting a transfer into many tiny ones can't nudge gold towards "clean".
local INCOME_REMAINDER = { "flagged", "unverified", "untracked", "clean" }
local SOURCES = { "quest", "loot", "vendor", "ah", "mail", "trade", "alt", "gbank", "bank", "offline", "other" }
local IS_SOURCE, IS_BUCKET = {}, {}
for _, s in ipairs(SOURCES) do IS_SOURCE[s] = true end
for _, b in ipairs(BUCKETS) do IS_BUCKET[b] = true end

local MAX_LOG, PRUNE = 300, 50
local FLAG_MIN = 100000 -- 10g: one-sided transfers below this are never flagged

Ledger.BUCKETS = BUCKETS
Ledger.SOURCES = SOURCES
Ledger.MAX_LOG = MAX_LOG

local function num(n)
    return format("%.0f", n)
end

local function Total(b)
    return (b.clean or 0) + (b.unverified or 0) + (b.flagged or 0) + (b.untracked or 0)
end
Ledger.Total = Total

-- Splits an integer amount across buckets in proportion to `weights`; the parts
-- always sum to exactly `amount`. With `capped`, no part exceeds its weight
-- (used when draining a balance; requires amount <= Total(weights)).
function Ledger.Split(amount, weights, capped)
    local sum = Total(weights)
    if sum <= 0 or amount <= 0 then return nil end

    local parts, rem = {}, amount
    for _, k in ipairs(BUCKETS) do
        local w = weights[k] or 0
        local p = floor(amount * (w / sum))
        if capped and p > w then p = w end
        parts[k] = p
        rem = rem - p
    end

    local order = capped and BUCKETS or INCOME_REMAINDER
    local guard = 0
    while rem ~= 0 and guard < 64 do
        guard = guard + 1
        for _, k in ipairs(order) do
            local w = weights[k] or 0
            if rem > 0 and w > 0 and (not capped or parts[k] < w) then
                parts[k] = parts[k] + 1
                rem = rem - 1
            elseif rem < 0 and parts[k] > 0 then
                parts[k] = parts[k] - 1
                rem = rem + 1
            end
        end
    end
    return parts
end

local function canon(e)
    local p = e.p
    return concat({ num(e.t), e.k, num(e.a), e.s, num(p[1]), num(p[2]), num(p[3]), num(p[4]), e.w or "" }, ":")
end

local function sealOf(char, salt)
    local t = { char.head, num(char.money), num(char.first), num(char.tampered), num(char.rc) }
    for _, k in ipairs(BUCKETS) do
        t[#t + 1] = num(char.b[k])
        t[#t + 1] = num(char.inc[k])
    end
    for _, k in ipairs(SOURCES) do
        t[#t + 1] = num(char.src[k] or 0)
    end
    t[#t + 1] = salt
    return Seal.hash(concat(t, "|"))
end

local function append(char, salt, e)
    e.h = Seal.hash(char.head .. "|" .. canon(e) .. "|" .. salt)
    char.head = e.h
    local log = char.log
    log[#log + 1] = e
    if #log >= MAX_LOG + PRUNE then
        -- Drop the oldest entries; the chain is then verified from `base`.
        local n = #log
        char.base = log[PRUNE].h
        for i = 1, n - PRUNE do log[i] = log[i + PRUNE] end
        for i = n - PRUNE + 1, n do log[i] = nil end
    end
end

function Ledger.New(money, now, salt, tampered)
    local char = {
        v = 1,
        money = money,
        first = now,
        tampered = tampered and now or 0,
        rc = 0, -- trades confirmed by the other player's receipt
        b = { clean = 0, unverified = 0, flagged = 0, untracked = money },
        inc = { clean = 0, unverified = 0, flagged = 0, untracked = 0 },
        src = {},
        log = {},
        base = "0",
        head = "0",
    }
    char.seal = sealOf(char, salt)
    return char
end

-- `mix` is a bucket name, or a table of bucket weights (e.g. the sender's balance).
-- Returns the parts actually credited.
function Ledger.Income(char, salt, amount, source, mix, who, now)
    if amount <= 0 then return nil end
    if not IS_SOURCE[source] then source = "other" end

    local parts
    if type(mix) == "table" then
        if Total(mix) == amount then
            parts = { clean = mix.clean or 0, unverified = mix.unverified or 0,
                      flagged = mix.flagged or 0, untracked = mix.untracked or 0 }
        else
            parts = Ledger.Split(amount, mix)
        end
    end
    if not parts then
        parts = { clean = 0, unverified = 0, flagged = 0, untracked = 0 }
        parts[IS_BUCKET[mix] and mix or "unverified"] = amount
    end

    for _, k in ipairs(BUCKETS) do
        char.b[k] = char.b[k] + parts[k]
        char.inc[k] = char.inc[k] + parts[k]
    end
    char.src[source] = (char.src[source] or 0) + amount
    char.money = char.money + amount
    append(char, salt, { t = now, k = "i", a = amount, s = source, w = who,
        p = { parts.clean, parts.unverified, parts.flagged, parts.untracked } })
    char.seal = sealOf(char, salt)
    return parts
end

-- Drains every bucket proportionally. Returns the parts removed.
function Ledger.Spend(char, salt, amount, source, who, now)
    if amount <= 0 then return nil end
    if not IS_SOURCE[source] then source = "other" end

    local parts = Ledger.Split(min(amount, Total(char.b)), char.b, true)
        or { clean = 0, unverified = 0, flagged = 0, untracked = 0 }
    for _, k in ipairs(BUCKETS) do
        char.b[k] = char.b[k] - parts[k]
    end
    char.money = char.money - amount
    append(char, salt, { t = now, k = "s", a = amount, s = source, w = who,
        p = { parts.clean, parts.unverified, parts.flagged, parts.untracked } })
    char.seal = sealOf(char, salt)
    return parts
end

-- Brings the ledger in line with the real balance after time spent with the addon off.
function Ledger.Reconcile(char, salt, money, now)
    local diff = money - char.money
    if diff > 0 then
        Ledger.Income(char, salt, diff, "offline", "untracked", nil, now)
    elseif diff < 0 then
        Ledger.Spend(char, salt, -diff, "offline", nil, now)
    end
end

function Ledger.Verify(char, salt)
    local ok, good = pcall(function()
        local h = char.base
        for _, e in ipairs(char.log) do
            h = Seal.hash(h .. "|" .. canon(e) .. "|" .. salt)
            if h ~= e.h then return false end
        end
        if h ~= char.head then return false end
        if Total(char.b) ~= char.money then return false end
        return char.seal == sealOf(char, salt)
    end)
    return ok and good or false
end

function Ledger.Receipt(char, salt)
    char.rc = char.rc + 1
    char.seal = sealOf(char, salt)
end

-- Gold from a character with no addon data. Large gifts with nothing given in
-- return, relative to what this character demonstrably had, are flagged.
function Ledger.ClassifyStranger(char, amount, oneSided)
    if oneSided and amount >= FLAG_MIN and amount > 0.5 * (char.inc.clean + char.b.untracked) then
        return "flagged"
    end
    return "unverified"
end

-- The summary shared with other players.
function Ledger.Profile(char)
    return {
        c = char.b.clean, u = char.b.unverified, f = char.b.flagged, n = char.b.untracked,
        ic = char.inc.clean, iu = char.inc.unverified, fi = char.inc.flagged,
        first = char.first, tamp = char.tampered, rc = char.rc, head = char.head,
    }
end

local FIELDS = { "c", "u", "f", "n", "ic", "iu", "fi", "first", "tamp", "rc" }

function Ledger.EncodeProfile(p)
    local t = { "P", "1" }
    for _, k in ipairs(FIELDS) do t[#t + 1] = num(p[k]) end
    t[#t + 1] = p.head
    return concat(t, "|")
end

function Ledger.DecodeProfile(text)
    if type(text) ~= "string" then return nil end
    local f = {}
    for tok in text:gmatch("[^|]+") do f[#f + 1] = tok end
    if f[1] ~= "P" or f[2] ~= "1" or #f < #FIELDS + 3 then return nil end

    local p = {}
    for i, k in ipairs(FIELDS) do
        local v = tonumber(f[i + 2])
        if not v or v ~= v or v < 0 or v > 1e15 then return nil end
        p[k] = floor(v)
    end
    p.head = f[#FIELDS + 3]
    return p
end

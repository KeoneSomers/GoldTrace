-- /goldtrace window: the player's own score, bucket breakdown, alts and recent entries.
local _, ns = ...
local Score, Ledger, UI = ns.Score, ns.Ledger, ns.UI

local floor, format = math.floor, string.format

local WIDTH, HEIGHT, PAD = 440, 520, 16
local INNER = WIDTH - 2 * PAD
local RECENT, MAX_ALTS = 10, 6

local SOURCE_LABELS = {
    quest = "Quests", loot = "Loot", vendor = "Vendors", ah = "Auctions", mail = "Mail", trade = "Trades",
    alt = "Own characters", gbank = "Guild bank", bank = "Account bank", offline = "While addon was off", other = "Other",
}
local PART_NAMES = { "clean", "unknown origin", "flagged", "untracked" }

local frame, bar, body

local function Hex(k)
    local c = UI.COLORS[k]
    return format("|cff%02x%02x%02x", floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255))
end

local function Build()
    frame = CreateFrame("Frame", "GoldTraceLedgerFrame", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetClampedToScreen(true)
    if frame.TitleText then
        frame.TitleText:SetText("GoldTrace")
    elseif frame.SetTitle then
        frame:SetTitle("GoldTrace")
    end
    tinsert(UISpecialFrames, "GoldTraceLedgerFrame")

    bar = UI.CreateBar(frame, INNER, 14)
    bar:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -36)

    body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -10)
    body:SetWidth(INNER)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetWordWrap(true)
    body:SetSpacing(2)
end

local function EntryLine(e)
    local kinds = {}
    for i, name in ipairs(PART_NAMES) do
        if e.p[i] > 0 then kinds[#kinds + 1] = name end
    end
    local sign = e.k == "i" and "|cff40d050+" or "|cffff6060-"
    return format("|cffaaaaaa%s|r  %s%s|r  %s%s%s", date("%m/%d %H:%M", e.t), sign, ns.Money(e.a),
        SOURCE_LABELS[e.s] or e.s, e.w and ("  " .. e.w) or "",
        e.k == "i" and #kinds > 0 and ("  |cffaaaaaa(" .. table.concat(kinds, ", ") .. ")|r") or "")
end

local function Refresh()
    local char, now, opts = ns.char, time(), { warnPct = ns.db.opts.warnPct, own = true }
    local r = Score.Compute(Ledger.Profile(char), now, opts)
    bar:SetShares(r.shares)

    local lines = {}
    local function add(s) lines[#lines + 1] = s end

    add(format("|cffffd100%s|r    Score %s%d|r   %s confidence   %d confirmed trade(s)",
        ns.me, UI.ScoreColor(r.score), r.score, r.confLabel, char.rc))
    add("")
    for _, k in ipairs(UI.ORDER) do
        local share = r.total > 0 and char.b[k] / r.total * 100 or 0
        add(format("%s%s|r  %s  (%d%%)", Hex(k), UI.LABELS[k], ns.Money(char.b[k]), floor(share + 0.5)))
    end
    if #r.flags > 0 then
        add("")
        add(UI.FlagText(r.flags))
    end

    local src = {}
    for _, s in ipairs(Ledger.SOURCES) do
        if (char.src[s] or 0) > 0 then src[#src + 1] = SOURCE_LABELS[s] .. " " .. ns.Money(char.src[s]) end
    end
    if #src > 0 then
        add("")
        add("|cffffd100Income since install|r")
        add(table.concat(src, "  |  "))
    end

    local alts = {}
    for key, alt in pairs(ns.db.chars) do
        if key ~= ns.me and #alts < MAX_ALTS and type(alt) == "table" and type(alt.b) == "table" then
            -- Other characters' saved data hasn't been verified this session; skip any that are malformed.
            local ok, line = pcall(function()
                local ar = Score.Compute(Ledger.Profile(alt), now, opts)
                return format("%s  %s%d|r  %s", key, UI.ScoreColor(ar.score), ar.score, ns.Money(alt.money))
            end)
            if ok then alts[#alts + 1] = line end
        end
    end
    if #alts > 0 then
        add("")
        add("|cffffd100Your other characters|r")
        table.sort(alts)
        for _, s in ipairs(alts) do add(s) end
    end

    add("")
    add("|cffffd100Recent|r")
    local log = char.log
    if #log == 0 then add("|cffaaaaaaNothing recorded yet.|r") end
    for i = #log, math.max(1, #log - RECENT + 1), -1 do
        add(EntryLine(log[i]))
    end

    body:SetText(table.concat(lines, "\n"))
end

function ns.ToggleLedger()
    if not ns.char then
        ns.Print("still loading; try again in a moment.")
        return
    end
    if not frame then Build() end
    if frame:IsShown() then
        frame:Hide()
    else
        Refresh()
        frame:Show()
    end
end

ns.On("GT_CHANGED", function()
    if frame and frame:IsShown() then Refresh() end
end)

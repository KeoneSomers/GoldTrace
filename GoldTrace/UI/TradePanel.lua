-- Panel shown beside the trade window with the other player's score, plus a
-- one-line score on player tooltips for anyone we already have data for.
local _, ns = ...
local Score = ns.Score

local UI = {}
ns.UI = UI

local floor, format = math.floor, string.format

local WIDTH, PAD = 250, 12
local INNER = WIDTH - 2 * PAD
local REPLY_WAIT = 3          -- seconds to wait for the partner's addon to answer
local STALE = 600             -- older cached profiles are labelled as cached

UI.COLORS = {
    clean = { 0.25, 0.8, 0.3 },
    untracked = { 0.55, 0.55, 0.55 },
    unverified = { 1, 0.75, 0.1 },
    flagged = { 0.9, 0.2, 0.2 },
}
UI.ORDER = { "clean", "untracked", "unverified", "flagged" }
UI.LABELS = { clean = "Clean", untracked = "Untracked", unverified = "Unknown origin", flagged = "Flagged" }

local SEV_COLOR = { red = "|cffff4040", amber = "|cffffc020", info = "|cffaaaaaa" }

function UI.ScoreColor(score)
    if score >= 75 then return "|cff40d050" end
    if score >= 45 then return "|cffffc020" end
    return "|cffff4040"
end

function UI.FlagText(flags)
    local lines = {}
    for _, f in ipairs(flags) do
        lines[#lines + 1] = SEV_COLOR[f.sev] .. f.text .. "|r"
    end
    return table.concat(lines, "\n")
end

-- Horizontal bar split by bucket share.
function UI.CreateBar(parent, width, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(width, height)
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)

    bar.seg = {}
    for _, k in ipairs(UI.ORDER) do
        local tex = bar:CreateTexture(nil, "ARTWORK")
        tex:SetColorTexture(unpack(UI.COLORS[k]))
        tex:SetHeight(height)
        bar.seg[k] = tex
    end

    function bar:SetShares(shares)
        local x = 0
        for _, k in ipairs(UI.ORDER) do
            local tex = self.seg[k]
            local w = shares and floor(width * (shares[k] or 0) + 0.5) or 0
            if w >= 1 then
                tex:ClearAllPoints()
                tex:SetPoint("LEFT", self, "LEFT", x, 0)
                tex:SetWidth(w)
                tex:Show()
                x = x + w
            else
                tex:Hide()
            end
        end
    end
    return bar
end

------------------------------------------------------------------------
-- Trade panel
------------------------------------------------------------------------

if not TradeFrame then return end

local panel = CreateFrame("Frame", "GoldTraceTradePanel", UIParent, "BackdropTemplate")
panel:SetWidth(WIDTH)
panel:SetPoint("TOPLEFT", TradeFrame, "TOPRIGHT", 2, -12)
panel:SetFrameStrata(TradeFrame:GetFrameStrata())
panel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:Hide()

local function Text(font, anchor, gap)
    local fs = panel:CreateFontString(nil, "OVERLAY", font)
    fs:SetWidth(INNER)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(true)
    if anchor then
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -gap)
    else
        fs:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
    end
    return fs
end

local title = Text("GameFontNormal")
local scoreText = Text("GameFontNormalLarge", title, 6)
local bar = UI.CreateBar(panel, INNER, 10)
bar:SetPoint("TOPLEFT", scoreText, "BOTTOMLEFT", 0, -6)
local body = Text("GameFontHighlightSmall", bar, 8)
local offer = Text("GameFontHighlightSmall", body, 8)

local function Layout()
    local h = PAD + title:GetStringHeight() + 6 + scoreText:GetStringHeight() + 6 + 10
        + 8 + body:GetStringHeight() + 8 + offer:GetStringHeight() + PAD
    panel:SetHeight(h)
end

local function Render()
    local tr = ns.Sources.trade
    if not tr or not tr.open or not ns.char then return end
    title:SetText("GoldTrace" .. (tr.key and ("  |cffffffff" .. tr.key .. "|r") or ""))

    local peer = tr.key and ns.db.peers[tr.key]
    local result
    if peer and peer.p then
        result = Score.Compute(peer.p, time(), { warnPct = ns.db.opts.warnPct, localBad = peer.bad })
        scoreText:SetText(format("%s%d|r  |cffffffff%s confidence|r",
            UI.ScoreColor(result.score), result.score, result.confLabel))
        bar:SetShares(result.shares)
        local text = UI.FlagText(result.flags)
        if text == "" then text = "|cff40d050No concerns found.|r" end
        local age = time() - peer.seen
        if age > STALE then
            text = text .. format("\n|cffaaaaaaNo reply just now; showing data from %d hour(s) ago.|r", floor(age / 3600))
        end
        body:SetText(text)
    elseif not tr.key then
        scoreText:SetText("|cffaaaaaa?|r")
        bar:SetShares(nil)
        body:SetText("Couldn't read this player's name, so no data can be shown.")
    elseif GetTime() - tr.t < REPLY_WAIT then
        scoreText:SetText("|cffaaaaaa...|r")
        bar:SetShares(nil)
        body:SetText("Asking the other player's addon...")
    else
        scoreText:SetText("|cffffc020No data|r")
        bar:SetShares(nil)
        body:SetText("|cffffc020This player isn't running GoldTrace. The origin of their gold is unknown; accept with caution.|r")
    end

    if tr.their > 0 then
        local line = "They are offering " .. ns.Money(tr.their) .. "."
        local sh = result and result.shares
        if sh then
            local unknown, flagged = tr.their * sh.unverified, tr.their * sh.flagged
            if flagged >= 1 then
                line = line .. format("\n|cffff4040About %s of it is flagged.|r", ns.Money(flagged))
            end
            if unknown >= 1 and sh.unverified * 100 >= ns.db.opts.warnPct then
                line = line .. format("\n|cffffc020About %s of it is of unknown origin.|r", ns.Money(unknown))
            end
        elseif not result then
            line = line .. "\n|cffffc020It will be recorded as unknown origin on your character.|r"
        end
        offer:SetText(line)
    else
        offer:SetText("")
    end
    Layout()
end

ns.On("GT_TRADE_SHOW", function(tr)
    panel:Show()
    Render()
    C_Timer.After(REPLY_WAIT + 0.1, function()
        if ns.Sources.trade == tr then Render() end
    end)
end)
ns.On("GT_TRADE_UPDATE", Render)
ns.On("GT_PEER", function(key)
    local tr = ns.Sources.trade
    if tr and tr.key == key then Render() end
end)
ns.On("GT_TRADE_CLOSED", function() panel:Hide() end)

------------------------------------------------------------------------
-- Tooltip
------------------------------------------------------------------------

local function AddTooltipLine(tooltip)
    if tooltip ~= GameTooltip or not ns.char then return end
    -- Unit data can be secret in combat and instances; anything unreadable is skipped.
    pcall(function()
        local _, unit = tooltip:GetUnit()
        if not unit or ns.IsSecret(unit) or not UnitIsPlayer(unit) then return end
        local key = ns.Key(UnitName(unit))
        local peer = key and ns.db.peers[key]
        if not (peer and peer.p) then return end
        local r = Score.Compute(peer.p, time(), { warnPct = ns.db.opts.warnPct, localBad = peer.bad })
        tooltip:AddLine(format("GoldTrace: %s%d|r |cffaaaaaa(%s confidence)|r",
            UI.ScoreColor(r.score), r.score, r.confLabel))
    end)
end

if TooltipDataProcessor and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, AddTooltipLine)
elseif GameTooltip:HasScript("OnTooltipSetUnit") then
    GameTooltip:HookScript("OnTooltipSetUnit", AddTooltipLine)
end

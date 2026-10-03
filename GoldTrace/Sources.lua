-- Works out where each change in the player's gold came from and records it in
-- the ledger. Player-to-player channels (trade, mail, guild bank) are identified
-- precisely via hooks; everything else falls back to which window is open.
local ADDON, ns = ...
local Ledger = ns.Ledger

local S = {}
ns.Sources = S

local min = math.min

local EXPECT_TTL = 15        -- seconds an expected money change stays valid
local TRADE_GRACE = 15       -- seconds after the trade window closes
local TRADE_PROFILE_AGE = 600
local MAIL_PROFILE_AGE = 7 * 86400
local POSTAGE_SLACK = 10000  -- postage on top of gold sent by mail
local MAX_TRADE_SLOTS = 6    -- slot 7 is "will not be traded"

-- AH sale is suspicious when the unit price is this far above a reference price.
local AH_MIN = 100000        -- 10g
local AH_MARKET_MULT = 10
local AH_VENDOR_MULT = 200

local ctx = {}               -- which windows are open
local lootAt = 0
local expects = {}
local inbox = {}
local vendorSpent = 0        -- spent at vendors this session; sales up to this are refunds
local altChecked = {}

------------------------------------------------------------------------
-- Provenance of incoming gold
------------------------------------------------------------------------

-- Income that is the player's own gold coming back (refunds, returned mail):
-- credited in the current proportions so it changes nothing.
local function NeutralMix()
    local b = ns.char.b
    if Ledger.Total(b) > 0 then return b end
    return "clean"
end

local function AltMix(key, amount)
    local list = ns.db.transit[ns.me]
    if type(list) == "table" then
        for i, tr in ipairs(list) do
            if tr.from == key and tr.a == amount then
                tremove(list, i)
                return { clean = tr.p[1], unverified = tr.p[2], flagged = tr.p[3], untracked = tr.p[4] }
            end
        end
    end
    -- No record of the send (e.g. posted before a reload); use the alt's balance,
    -- provided its saved ledger is intact.
    local alt = ns.db.chars[key]
    if altChecked[key] == nil then
        altChecked[key] = Ledger.Verify(alt, ns.SaltFor(key))
    end
    if altChecked[key] and Ledger.Total(alt.b) > 0 then return alt.b end
    return "unverified"
end

-- Returns the bucket mix for gold received from another character, and whether
-- that character is one of the player's own.
local function MixFromPlayer(key, amount, oneSided, maxAge)
    local db = ns.db
    if key and key ~= ns.me and type(db.chars[key]) == "table" then
        return AltMix(key, amount), true
    end
    local peer = key and db.peers[key]
    if peer and peer.p and time() - peer.seen <= maxAge then
        local p = peer.p
        local mix = { clean = p.c, unverified = p.u, flagged = p.f, untracked = p.n }
        if Ledger.Total(mix) > 0 then return mix, false end
    end
    return Ledger.ClassifyStranger(ns.char, amount, oneSided), false
end

local function AHSuspicious(itemName, buyout, count)
    if not itemName or not buyout or buyout < AH_MIN then return false end
    if not (C_Item and C_Item.GetItemInfo) then return false end
    local _, link, quality, _, _, _, _, _, _, _, sellPrice = C_Item.GetItemInfo(itemName)
    if not link then return false end
    local unit = buyout / ((count and count > 0) and count or 1)

    local market
    if Auctionator and Auctionator.API and Auctionator.API.v1 and Auctionator.API.v1.GetAuctionPriceByItemLink then
        local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemLink, ADDON, link)
        if ok and type(price) == "number" and price > 0 then market = price end
    end
    if market then return unit > AH_MARKET_MULT * market end
    -- No price data: only judge grey and white items, against their vendor value.
    return quality ~= nil and quality <= 1 and sellPrice ~= nil and sellPrice > 0
        and unit > AH_VENDOR_MULT * sellPrice
end

------------------------------------------------------------------------
-- Expected money changes (set by hooks just before the gold moves)
------------------------------------------------------------------------

local function Expect(e)
    e.t = GetTime()
    expects[#expects + 1] = e
end

local function TakeExpect(delta)
    local now = GetTime()
    for i = #expects, 1, -1 do
        if now - expects[i].t > EXPECT_TTL then tremove(expects, i) end
    end
    for i, e in ipairs(expects) do
        local hit = e.amount == delta
        if not hit and e.atLeast and delta < 0 then
            hit = -delta >= e.atLeast and -delta <= e.atLeast + POSTAGE_SLACK
        end
        if hit then
            tremove(expects, i)
            return e
        end
    end
end

------------------------------------------------------------------------
-- Applying a change
------------------------------------------------------------------------

local function ApplyTrade(tr, delta, now)
    local char, salt = ns.char, ns.salt
    if delta > 0 then
        local oneSided = tr.mine == 0 and tr.myItems == 0
        local mix = MixFromPlayer(tr.key, delta, oneSided, TRADE_PROFILE_AGE)
        Ledger.Income(char, salt, delta, "trade", mix, tr.key, now)
    else
        Ledger.Spend(char, salt, -delta, "trade", tr.key, now)
    end
    if tr.key then ns.Comms.TradeDone(tr.key, delta) end
end

local function ApplyIncome(delta, e, now)
    local char, salt = ns.char, ns.salt
    if e then
        Ledger.Income(char, salt, delta, e.source, e.mix and e.mix(delta) or "clean", e.who, now)
    elseif ctx.mail then
        -- Taken from the mailbox by a route the hooks didn't see: assume the worst case.
        Ledger.Income(char, salt, delta, "mail", "unverified", nil, now)
    elseif GetTime() - lootAt < 2 then
        Ledger.Income(char, salt, delta, "loot", "clean", nil, now)
    elseif ctx.merchant then
        -- Selling back what was just bought is a refund, not new clean income.
        local refund = min(delta, vendorSpent)
        if refund > 0 then
            vendorSpent = vendorSpent - refund
            Ledger.Income(char, salt, refund, "vendor", NeutralMix(), nil, now)
        end
        if delta > refund then
            Ledger.Income(char, salt, delta - refund, "vendor", "clean", nil, now)
        end
    elseif ctx.ah then
        Ledger.Income(char, salt, delta, "ah", NeutralMix(), nil, now)
    else
        Ledger.Income(char, salt, delta, "other", "clean", nil, now)
    end
end

local function ApplySpend(amount, e, now)
    local char, salt, db = ns.char, ns.salt, ns.db
    local source = e and e.source
        or ctx.merchant and "vendor" or ctx.mail and "mail" or ctx.ah and "ah" or "other"
    local parts = Ledger.Spend(char, salt, amount, source, e and e.who, now)
    if source == "vendor" then vendorSpent = vendorSpent + amount end

    if e and e.pool then
        for _, k in ipairs(Ledger.BUCKETS) do db.pool[k] = db.pool[k] + parts[k] end
    elseif e and e.send and e.who and e.who ~= ns.me and type(db.chars[e.who]) == "table" then
        -- Gold mailed to an alt: remember its makeup so the alt inherits it on pickup.
        local sent = Ledger.Split(e.send, parts)
        if sent then
            local list = db.transit[e.who]
            if type(list) ~= "table" then
                list = {}
                db.transit[e.who] = list
            end
            list[#list + 1] = { from = ns.me, a = e.send, t = now,
                p = { sent.clean, sent.unverified, sent.flagged, sent.untracked } }
            while #list > 50 do tremove(list, 1) end
        end
    end
end

local function OnMoney()
    local char = ns.char
    if not char then return end
    local delta = GetMoney() - char.money
    if delta == 0 then return end
    local now = time()

    local tr = S.trade
    if tr and (tr.open or GetTime() - tr.closed < TRADE_GRACE) and tr.their - tr.mine == delta then
        S.trade = nil
        ApplyTrade(tr, delta, now)
    else
        local e = TakeExpect(delta)
        if delta > 0 then
            ApplyIncome(delta, e, now)
        else
            ApplySpend(-delta, e, now)
        end
    end
    ns.Fire("GT_CHANGED")
end

ns.On("PLAYER_MONEY", OnMoney)

------------------------------------------------------------------------
-- Context: windows, loot, quests
------------------------------------------------------------------------

local function TrackWindow(name, showEvent, hideEvent)
    ns.On(showEvent, function() ctx[name] = true end)
    ns.On(hideEvent, function() ctx[name] = nil end)
end
TrackWindow("merchant", "MERCHANT_SHOW", "MERCHANT_CLOSED")
TrackWindow("mail", "MAIL_SHOW", "MAIL_CLOSED")
TrackWindow("ah", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED")

local function MarkLoot() lootAt = GetTime() end
ns.On("LOOT_READY", MarkLoot)
ns.On("LOOT_OPENED", MarkLoot)
ns.On("LOOT_CLOSED", MarkLoot)
ns.On("CHAT_MSG_MONEY", MarkLoot)

ns.On("QUEST_TURNED_IN", function(_, _, money)
    if type(money) == "number" and not ns.IsSecret(money) and money > 0 then
        Expect({ amount = money, source = "quest" })
    end
end)

------------------------------------------------------------------------
-- Trade
------------------------------------------------------------------------

local function TradeMoney(fn)
    local v = fn and fn()
    if ns.IsSecret(v) then return 0 end
    return tonumber(v) or 0
end

local function CountItems(fn)
    local n = 0
    if fn then
        for i = 1, MAX_TRADE_SLOTS do
            local name = fn(i)
            if ns.IsSecret(name) or (name and name ~= "") then n = n + 1 end
        end
    end
    return n
end

local function SnapTrade()
    local tr = S.trade
    if not tr or not tr.open then return end
    tr.mine = TradeMoney(GetPlayerTradeMoney)
    tr.their = TradeMoney(GetTargetTradeMoney)
    tr.myItems = CountItems(GetTradePlayerItemInfo)
    tr.theirItems = CountItems(GetTradeTargetItemInfo)
    ns.Fire("GT_TRADE_UPDATE", tr)
end

ns.On("TRADE_SHOW", function()
    local name, realm = UnitName("NPC")
    local key = ns.Key(name, realm)
    S.trade = { key = key, mine = 0, their = 0, myItems = 0, theirItems = 0, open = true, t = GetTime() }
    ns.Fire("GT_TRADE_SHOW", S.trade)
    SnapTrade()
end)

for _, event in ipairs({ "TRADE_MONEY_CHANGED", "PLAYER_TRADE_MONEY", "TRADE_PLAYER_ITEM_CHANGED",
                         "TRADE_TARGET_ITEM_CHANGED", "TRADE_ACCEPT_UPDATE" }) do
    ns.On(event, SnapTrade)
end

ns.On("TRADE_CLOSED", function()
    local tr = S.trade
    if tr and tr.open then
        tr.open = false
        tr.closed = GetTime()
    end
    ns.Fire("GT_TRADE_CLOSED")
end)

ns.On("UI_INFO_MESSAGE", function(_, msg)
    if not ns.IsSecret(msg) and msg == ERR_TRADE_CANCELLED then S.trade = nil end
end)

------------------------------------------------------------------------
-- Mail
------------------------------------------------------------------------

local function MailInfo(i)
    if not GetInboxHeaderInfo then return nil end
    local _, _, sender, subject, money, cod, _, _, _, wasReturned, _, canReply = GetInboxHeaderInfo(i)
    if ns.IsSecret(sender) or ns.IsSecret(money) then return nil end
    local info = { sender = sender, subject = subject, money = money or 0, cod = cod or 0,
                   returned = wasReturned, canReply = canReply }
    if GetInboxInvoiceInfo then
        local invType, itemName, _, _, buyout, _, _, _, _, _, count = GetInboxInvoiceInfo(i)
        info.invType, info.itemName, info.buyout, info.count = invType, itemName, buyout, count
    end
    return info
end

ns.On("MAIL_INBOX_UPDATE", function()
    wipe(inbox)
    for i = 1, (GetInboxNumItems and GetInboxNumItems() or 0) do
        inbox[i] = MailInfo(i)
    end
end)

local function IsCODPayment(subject)
    if type(subject) ~= "string" or ns.IsSecret(subject) or not COD_PAYMENT then return false end
    local prefix = COD_PAYMENT:match("^(.-)%%s")
    return prefix ~= nil and prefix ~= "" and subject:sub(1, #prefix) == prefix
end

local function MailTake(i)
    if not ns.char then return end
    local info = MailInfo(i)
    if not info or info.money <= 0 then info = inbox[i] end
    if not info or info.money <= 0 then return end

    local e = { amount = info.money }
    if info.invType == "seller" then
        e.source = "ah"
        e.who = info.itemName
        local bad = AHSuspicious(info.itemName, info.buyout, info.count)
        e.mix = function() return bad and "flagged" or "clean" end
    elseif info.returned or not info.canReply then
        -- Returned mail, auction refunds and other system mail: the player's own gold.
        e.source = "mail"
        e.mix = NeutralMix
    else
        local key = ns.Key(info.sender)
        local oneSided = not IsCODPayment(info.subject)
        local mix, isAlt = MixFromPlayer(key, info.money, oneSided, MAIL_PROFILE_AGE)
        e.source = isAlt and "alt" or "mail"
        e.who = key
        e.mix = function() return mix end
    end
    Expect(e)
end

local function MailTakeItem(i)
    if not ns.char then return end
    local info = MailInfo(i) or inbox[i]
    if info and info.cod > 0 then
        Expect({ amount = -info.cod, source = "mail", who = ns.Key(info.sender) })
    end
end

if TakeInboxMoney then hooksecurefunc("TakeInboxMoney", MailTake) end
if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", MailTake) end
if TakeInboxItem then hooksecurefunc("TakeInboxItem", MailTakeItem) end

if SendMail then
    hooksecurefunc("SendMail", function(recipient)
        local amount = GetSendMailMoney and GetSendMailMoney() or 0
        if type(amount) == "number" and amount > 0 then
            Expect({ atLeast = amount, send = amount, source = "mail", who = ns.Key(recipient) })
        end
    end)
end

------------------------------------------------------------------------
-- Shared banks
------------------------------------------------------------------------

-- Account bank (if this client has one): its gold is tracked as a pool so that
-- depositing and withdrawing on another character doesn't clean it.
local function PoolMix(amount)
    local pool = ns.db.pool
    local take = min(amount, Ledger.Total(pool))
    local mix = { clean = 0, unverified = 0, flagged = 0, untracked = amount - take }
    local parts = take > 0 and Ledger.Split(take, pool, true)
    if parts then
        for _, k in ipairs(Ledger.BUCKETS) do
            pool[k] = pool[k] - parts[k]
            mix[k] = mix[k] + parts[k]
        end
    else
        mix.untracked = amount
    end
    return mix
end

if C_Bank and C_Bank.DepositMoney then
    hooksecurefunc(C_Bank, "DepositMoney", function(_, amount)
        if type(amount) == "number" and amount > 0 then
            Expect({ amount = -amount, source = "bank", pool = true })
        end
    end)
end
if C_Bank and C_Bank.WithdrawMoney then
    hooksecurefunc(C_Bank, "WithdrawMoney", function(_, amount)
        if type(amount) == "number" and amount > 0 then
            Expect({ amount = amount, source = "bank", mix = PoolMix })
        end
    end)
end

-- Guild bank gold could have been deposited by anyone.
if WithdrawGuildBankMoney then
    hooksecurefunc("WithdrawGuildBankMoney", function(amount)
        if type(amount) == "number" and amount > 0 then
            Expect({ amount = amount, source = "gbank", mix = function() return "unverified" end })
        end
    end)
end
if DepositGuildBankMoney then
    hooksecurefunc("DepositGuildBankMoney", function(amount)
        if type(amount) == "number" and amount > 0 then
            Expect({ amount = -amount, source = "gbank" })
        end
    end)
end

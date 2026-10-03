-- Peer-to-peer sharing over hidden addon messages.
--   Q|1                  "send me your profile" (whispered to a trade partner)
--   P|1|...              a profile (see Ledger.EncodeProfile)
--   R|<net copper>       receipt after a trade: what the sender's gold changed by
local _, ns = ...
local Ledger = ns.Ledger

local Comms = {}
ns.Comms = Comms

local PREFIX = "GoldTrace"
local SEND_GAP = 0.4          -- seconds between our own messages
local REPLY_GAP = 5           -- per-sender limit on answering profile requests
local GROUP_GAP = 300
local RECEIPT_WINDOW = 30

local format = string.format

local nextSendAt = 0
local lastReply = {}
local lastGroupSend = 0
local myTrades = {}           -- [key] = { net, t }: our side, waiting for their receipt
local theirReceipts = {}      -- [key] = { net, t }: their receipt, waiting for our side

local function RawSend(text, channel, target)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end
    if ChatThrottleLib then
        ChatThrottleLib:SendAddonMessage("NORMAL", PREFIX, text, channel, target)
    else
        C_ChatInfo.SendAddonMessage(PREFIX, text, channel, target)
    end
end

local function Send(text, channel, target)
    local now = GetTime()
    local at = math.max(now, nextSendAt)
    nextSendAt = at + SEND_GAP
    if at <= now then
        RawSend(text, channel, target)
    else
        C_Timer.After(at - now, function() RawSend(text, channel, target) end)
    end
end

local function ProfileText()
    return Ledger.EncodeProfile(Ledger.Profile(ns.char))
end

function Comms.Request(key)
    Send("Q|1", "WHISPER", key)
end

local function Peer(key)
    local peer = ns.db.peers[key]
    if type(peer) ~= "table" then
        peer = { bad = 0, seen = time() }
        ns.db.peers[key] = peer
    end
    return peer
end

-- A trade is corroborated when both sides report equal and opposite changes.
local function Settle(key, myNet, theirNet)
    if theirNet == -myNet then
        Ledger.Receipt(ns.char, ns.salt)
    else
        local peer = Peer(key)
        peer.bad = (peer.bad or 0) + 1
    end
    ns.Fire("GT_CHANGED")
end

function Comms.TradeDone(key, net)
    Send(format("R|%.0f", net), "WHISPER", key)
    local theirs = theirReceipts[key]
    theirReceipts[key] = nil
    if theirs and GetTime() - theirs.t < RECEIPT_WINDOW then
        Settle(key, net, theirs.net)
    else
        myTrades[key] = { net = net, t = GetTime() }
    end
end

local function OnReceipt(key, theirNet)
    local mine = myTrades[key]
    myTrades[key] = nil
    if mine and GetTime() - mine.t < RECEIPT_WINDOW then
        Settle(key, mine.net, theirNet)
    else
        theirReceipts[key] = { net = theirNet, t = GetTime() }
    end
end

ns.On("CHAT_MSG_ADDON", function(prefix, text, channel, sender)
    if ns.IsSecret(prefix) or ns.IsSecret(text) or ns.IsSecret(sender) or ns.IsSecret(channel) then return end
    if prefix ~= PREFIX or not ns.char or type(text) ~= "string" then return end
    local key = ns.Key(sender)
    if not key or key == ns.me then return end

    local kind = text:sub(1, 1)
    if kind == "Q" then
        local now = GetTime()
        if now - (lastReply[key] or -REPLY_GAP) >= REPLY_GAP then
            lastReply[key] = now
            Send(ProfileText(), "WHISPER", key)
        end
    elseif kind == "P" then
        local p = Ledger.DecodeProfile(text)
        if p then
            local peer = Peer(key)
            peer.p = p
            peer.seen = time()
            ns.Fire("GT_PEER", key)
        end
    elseif kind == "R" and channel == "WHISPER" then
        local net = tonumber(text:match("^R|(-?%d+)$"))
        if net then OnReceipt(key, net) end
    end
end)

ns.On("GT_TRADE_SHOW", function(tr)
    if tr.key then Comms.Request(tr.key) end
end)

ns.On("GT_READY", function()
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.After(15, function()
        if IsInGuild() then Send(ProfileText(), "GUILD") end
    end)
end)

ns.On("GROUP_ROSTER_UPDATE", function()
    if not ns.char or not IsInGroup(LE_PARTY_CATEGORY_HOME) then return end
    local now = GetTime()
    if now - lastGroupSend < GROUP_GAP and lastGroupSend > 0 then return end
    lastGroupSend = now
    Send(ProfileText(), IsInRaid(LE_PARTY_CATEGORY_HOME) and "RAID" or "PARTY")
end)

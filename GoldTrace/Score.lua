-- Turns a shared profile into a 0-100 score, a confidence level and plain-language
-- flags. Pure Lua. The receiver always computes the score itself from the raw
-- bucket numbers, so everyone is judged by the same rules.
local _, ns = ...

local Score = {}
ns.Score = Score

local floor, min, max, format = math.floor, math.min, math.max, string.format

-- How much each kind of gold counts towards the score.
local WEIGHT = { clean = 1, untracked = 0.5, unverified = 0.35, flagged = 0 }
-- How long a detected edit of the saved data keeps the score capped.
local TAMPER_DAYS = 30

local function pct(x)
    return floor(x * 100 + 0.5)
end

-- opts.warnPct   unverified share (percent) at which the unknown-origin caution appears
-- opts.localBad  receipt mismatches this client has seen from that player
-- opts.own       true when describing the player's own character
function Score.Compute(p, now, opts)
    opts = opts or {}
    local warnPct = opts.warnPct or 10
    local whose = opts.own and "your" or "this player's"

    local total = p.c + p.u + p.f + p.n
    local shares, qBalance
    if total > 0 then
        shares = { clean = p.c / total, unverified = p.u / total, flagged = p.f / total, untracked = p.n / total }
        qBalance = shares.clean * WEIGHT.clean + shares.untracked * WEIGHT.untracked
            + shares.unverified * WEIGHT.unverified
    end

    local lifetime = p.ic + p.iu + p.fi
    local qLifetime = lifetime > 0 and (p.ic * WEIGHT.clean + p.iu * WEIGHT.unverified) / lifetime or nil

    local q
    if qBalance and qLifetime then
        q = 0.7 * qBalance + 0.3 * qLifetime
    else
        q = qBalance or qLifetime or 0.5
    end

    local bad = opts.localBad or 0
    local score = floor(q * 100 + 0.5) - min(30, 10 * bad)
    local tampered = p.tamp > 0 and now - p.tamp < TAMPER_DAYS * 86400
    if tampered then score = min(score, 25) end
    score = max(0, min(100, score))

    local tracked = shares and (1 - shares.untracked) or (lifetime > 0 and 1 or 0)
    local ageDays = max(0, (now - p.first) / 86400)
    local conf = 0.5 * tracked + 0.3 * min(ageDays / 14, 1) + 0.2 * min(p.rc / 5, 1)
    if tampered then conf = min(conf, 0.2) end
    local confLabel = conf < 0.34 and "Low" or conf < 0.67 and "Medium" or "High"

    local flags = {}
    local function flag(sev, text)
        flags[#flags + 1] = { sev = sev, text = text }
    end

    if tampered then
        flag("red", "Saved addon data was edited by hand; the ledger was reset.")
    end
    if shares and shares.flagged >= 0.01 then
        flag("red", format("%d%% of %s gold is flagged (large one-sided transfers from strangers or overpriced auctions).",
            pct(shares.flagged), whose))
    end
    if lifetime > 0 and p.fi / lifetime >= 0.1 and not (shares and shares.flagged >= 0.01) then
        flag("red", format("%d%% of %s tracked income was flagged, though it has since been spent.",
            pct(p.fi / lifetime), whose))
    end
    if shares and p.u > 0 and p.u * 100 >= warnPct * total then
        if opts.own then
            flag("amber", format("%d%% of your gold came from characters without GoldTrace. Other players will see it as unknown origin.",
                pct(shares.unverified)))
        else
            flag("amber", format("%d%% of this player's gold came from characters without GoldTrace. Its origin is unknown; accept with caution.",
                pct(shares.unverified)))
        end
    end
    if bad > 0 then
        flag("amber", format("%d trade receipt(s) from this player did not match your own record.", bad))
    end
    if shares and shares.untracked >= 0.5 then
        flag("info", format("%d%% of %s gold predates the addon, so it can't be traced.", pct(shares.untracked), whose))
    end
    if ageDays < 3 then
        flag("info", format("Ledger is only %d day(s) old.", floor(ageDays)))
    end
    if not shares then
        flag("info", "No gold held right now; score is based on past income.")
    end

    return {
        score = score,
        conf = conf,
        confLabel = confLabel,
        shares = shares,
        flags = flags,
        total = total,
    }
end

-- Self-tests for the pure modules. Run in game with `/goldtrace test`, or from a
-- command line with `lua tests/run.lua`.
local _, ns = ...
local Seal, Ledger, Score = ns.Seal, ns.Ledger, ns.Score

function ns.RunTests()
    local passed, failures = 0, {}
    local function check(name, cond)
        if cond then
            passed = passed + 1
        else
            failures[#failures + 1] = name
        end
    end

    local SALT, T0 = "test-salt", 1000000

    -- Seal
    check("sha256 empty", Seal.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    check("sha256 abc", Seal.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    check("sha256 two blocks", Seal.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

    -- Split
    local parts = Ledger.Split(2, { clean = 1, unverified = 1, flagged = 1, untracked = 0 }, true)
    check("split capped sums", Ledger.Total(parts) == 2)
    check("split capped respects caps", parts.clean <= 1 and parts.unverified <= 1 and parts.flagged <= 1)
    parts = Ledger.Split(1001, { clean = 600, unverified = 0, flagged = 400, untracked = 0 })
    check("split sums exactly", Ledger.Total(parts) == 1001)
    check("split remainder goes to worst bucket", parts.clean == 600 and parts.flagged == 401)

    -- New character: everything it already holds is untracked
    local c = Ledger.New(5000, T0, SALT)
    check("new is untracked", c.b.untracked == 5000 and Ledger.Total(c.b) == c.money)
    check("new verifies", Ledger.Verify(c, SALT))

    -- Income and proportional spending
    Ledger.Income(c, SALT, 5000, "quest", "clean", nil, T0 + 1)
    check("income clean", c.b.clean == 5000 and c.money == 10000 and c.src.quest == 5000)
    local spent = Ledger.Spend(c, SALT, 4000, "vendor", nil, T0 + 2)
    check("spend proportional", spent.clean == 2000 and spent.untracked == 2000)
    check("balance matches buckets", Ledger.Total(c.b) == c.money and c.money == 6000)
    check("verifies after activity", Ledger.Verify(c, SALT))

    -- Strangers
    check("small gift unverified", Ledger.ClassifyStranger(c, 50000, true) == "unverified")
    check("large one-sided gift flagged", Ledger.ClassifyStranger(c, 5000000, true) == "flagged")
    check("large sale unverified", Ledger.ClassifyStranger(c, 5000000, false) == "unverified")

    -- Alt laundering: flagged gold stays flagged after moving alt -> main
    local alt = Ledger.New(0, T0, SALT)
    Ledger.Income(alt, SALT, 600, "loot", "clean", nil, T0)
    Ledger.Income(alt, SALT, 400, "trade", "flagged", "Seller-Realm", T0)
    local sent = Ledger.Spend(alt, SALT, 500, "mail", "Main-Realm", T0)
    check("alt drains proportionally", sent.clean == 300 and sent.flagged == 200)
    local main = Ledger.New(0, T0, SALT)
    Ledger.Income(main, SALT, 500, "alt", sent, "Alt-Realm", T0)
    check("main inherits alt mix", main.b.clean == 300 and main.b.flagged == 200)
    Ledger.Income(main, SALT, 100, "trade", alt.b, "Alt-Realm", T0)
    check("mix weights inherit", main.b.clean == 360 and main.b.flagged == 240)

    -- Tampering
    c.b.clean = c.b.clean + 100000
    c.money = c.money + 100000
    check("edited buckets detected", not Ledger.Verify(c, SALT))
    c.b.clean = c.b.clean - 100000
    c.money = c.money - 100000
    check("restored verifies", Ledger.Verify(c, SALT))
    c.log[1].s = "loot"
    check("edited entry detected", not Ledger.Verify(c, SALT))
    c.log[1].s = "quest"
    check("wrong salt detected", not Ledger.Verify(c, "other-salt"))
    check("malformed data detected", not Ledger.Verify({ log = {}, base = "0", head = "0" }, SALT))

    -- Pruning keeps the chain valid
    local big = Ledger.New(0, T0, SALT)
    for i = 1, Ledger.MAX_LOG + 120 do
        Ledger.Income(big, SALT, 1, "loot", "clean", nil, T0 + i)
    end
    check("log is bounded", #big.log < Ledger.MAX_LOG + 50)
    check("pruned chain verifies", Ledger.Verify(big, SALT))
    check("pruned totals intact", big.b.clean == Ledger.MAX_LOG + 120)

    -- Reconcile
    local r = Ledger.New(1000, T0, SALT)
    Ledger.Reconcile(r, SALT, 1500, T0)
    check("offline gain untracked", r.b.untracked == 1500 and r.money == 1500)
    Ledger.Reconcile(r, SALT, 200, T0)
    check("offline loss", r.money == 200 and Ledger.Total(r.b) == 200 and Ledger.Verify(r, SALT))

    -- Profile wire format
    local p = Ledger.Profile(main)
    local back = Ledger.DecodeProfile(Ledger.EncodeProfile(p))
    check("profile round trip", back and back.c == p.c and back.f == p.f and back.first == p.first and back.head == p.head)
    check("profile fits one message", #Ledger.EncodeProfile(p) < 255)
    check("garbage rejected", Ledger.DecodeProfile("P|1|x|y") == nil and Ledger.DecodeProfile("hello") == nil)
    check("negative rejected", Ledger.DecodeProfile("P|1|-5|0|0|0|0|0|0|0|0|0|ab") == nil)

    -- Score
    local now = T0 + 30 * 86400
    local function prof(cl, u, f, n)
        return { c = cl, u = u, f = f, n = n, ic = cl, iu = u, fi = f, first = T0, tamp = 0, rc = 5, head = "0" }
    end
    local s = Score.Compute(prof(1000, 0, 0, 0), now)
    check("all clean scores 100", s.score == 100 and s.confLabel == "High" and #s.flags == 0)
    s = Score.Compute(prof(0, 0, 1000, 0), now)
    check("all flagged scores 0", s.score == 0 and s.flags[1].sev == "red")
    s = Score.Compute(prof(620, 380, 0, 0), now)
    check("unknown-origin warning", s.flags[1] and s.flags[1].sev == "amber" and s.flags[1].text:find("38%%") ~= nil)
    s = Score.Compute(prof(950, 50, 0, 0), now)
    check("below threshold no warning", #s.flags == 0)
    s = Score.Compute(prof(950, 50, 0, 0), now, { warnPct = 5 })
    check("threshold configurable", #s.flags == 1)
    local t = prof(1000, 0, 0, 0)
    t.tamp = now - 86400
    s = Score.Compute(t, now)
    check("tampered capped", s.score <= 25 and s.confLabel == "Low")
    t.tamp = now - 60 * 86400
    check("tamper cap expires", Score.Compute(t, now).score == 100)
    s = Score.Compute(prof(1000, 0, 0, 0), now, { localBad = 2 })
    check("receipt mismatch penalty", s.score == 80)

    return passed, failures
end

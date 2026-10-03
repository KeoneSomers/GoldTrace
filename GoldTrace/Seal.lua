-- SHA-256 used to seal the ledger. Pure Lua 5.1 + the `bit` library, no WoW API,
-- so it also runs under a standalone interpreter for tests.
--
-- This is tamper *evidence*, not secrecy: the salt lives in the addon source, so a
-- determined player can recompute hashes. It stops casual edits to the saved file.
local _, ns = ...

local Seal = {}
ns.Seal = Seal

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift
local byte, char, format, rep, sub = string.byte, string.char, string.format, string.rep, string.sub

local MOD = 4294967296

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function rrot(x, n)
    return bor(rshift(x, n), band(lshift(x, 32 - n), 0xffffffff))
end

function Seal.sha256(msg)
    local len = #msg
    local pad = 56 - ((len + 1) % 64)
    if pad < 0 then pad = pad + 64 end
    local bits = len * 8
    msg = msg .. "\128" .. rep("\0", pad) .. char(0, 0, 0, 0,
        band(rshift(bits, 24), 255), band(rshift(bits, 16), 255), band(rshift(bits, 8), 255), band(bits, 255))

    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local w = {}

    for i = 1, #msg, 64 do
        for j = 0, 15 do
            local b1, b2, b3, b4 = byte(msg, i + j * 4, i + j * 4 + 3)
            w[j] = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        end
        for j = 16, 63 do
            local v = w[j - 15]
            local s0 = bxor(bxor(rrot(v, 7), rrot(v, 18)), rshift(v, 3))
            v = w[j - 2]
            local s1 = bxor(bxor(rrot(v, 17), rrot(v, 19)), rshift(v, 10))
            w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % MOD
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for j = 0, 63 do
            local S1 = bxor(bxor(rrot(e, 6), rrot(e, 11)), rrot(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = (h + S1 + ch + K[j + 1] + w[j]) % MOD
            local S0 = bxor(bxor(rrot(a, 2), rrot(a, 13)), rrot(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local t2 = (S0 + maj) % MOD
            h, g, f, e = g, f, e, (d + t1) % MOD
            d, c, b, a = c, b, a, (t1 + t2) % MOD
        end

        h0, h1, h2, h3 = (h0 + a) % MOD, (h1 + b) % MOD, (h2 + c) % MOD, (h3 + d) % MOD
        h4, h5, h6, h7 = (h4 + e) % MOD, (h5 + f) % MOD, (h6 + g) % MOD, (h7 + h) % MOD
    end

    return format("%08x%08x%08x%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4, h5, h6, h7)
end

-- Short digest stored per ledger entry; 64 bits is plenty for tamper evidence
-- and keeps the saved file small.
function Seal.hash(msg)
    return sub(Seal.sha256(msg), 1, 16)
end

-- Minimal stand-ins for what the pure modules expect from the WoW client.
-- Only the `bit` library is needed.
if not bit then
    local ok, lib = pcall(require, "bit")
    if ok then
        bit = lib
    elseif bit32 then
        bit = { band = bit32.band, bor = bit32.bor, bxor = bit32.bxor, bnot = bit32.bnot,
                lshift = bit32.lshift, rshift = bit32.rshift }
    elseif _VERSION ~= "Lua 5.1" then
        -- Lua 5.3+: native operators, compiled from a string so 5.1 can still parse this file.
        bit = assert(load([[
            local M = 0xffffffff
            return {
                band = function(a, b) return (a & b) & M end,
                bor = function(a, b) return (a | b) & M end,
                bxor = function(a, b) return (a ~ b) & M end,
                bnot = function(a) return (~a) & M end,
                lshift = function(a, n) return (a << n) & M end,
                rshift = function(a, n) return (a & M) >> n end,
            }
        ]]))()
    else
        error("these tests need LuaJIT, Lua 5.2+, or a 'bit' library for Lua 5.1")
    end
end

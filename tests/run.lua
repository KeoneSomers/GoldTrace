-- Runs the addon's self-tests outside the game:  lua tests/run.lua
-- (from the repository root). The same tests run in game with /goldtrace test.
local root = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]*$")
root = root and (root .. "/") or ""

dofile(root .. "tests/wow_stub.lua")

local ns = {}
for _, file in ipairs({ "Seal.lua", "Ledger.lua", "Score.lua", "Tests.lua" }) do
    local chunk = assert(loadfile(root .. "GoldTrace/" .. file))
    chunk("GoldTrace", ns)
end

local passed, failures = ns.RunTests()
print(("%d passed, %d failed"):format(passed, #failures))
for _, name in ipairs(failures) do print("  failed: " .. name) end
os.exit(#failures == 0 and 0 or 1)

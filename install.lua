-- CCOOM installer/bootstrap. Run this once on the CC:Tweaked computer:
--   wget https://raw.githubusercontent.com/ob-105/CCOOM/main/install.lua install
--   install
--
-- This just fetches update.lua from GitHub and runs it, which does the
-- actual file sync into /ccoom. After this first run, ccoom/startup
-- auto-updates itself the same way every time you launch it -- you only
-- need to re-run this bootstrap if /ccoom gets deleted or badly corrupted.

local REPO = "ob-105/CCOOM"
local BRANCH = "main"
local INSTALL_DIR = "ccoom"
local HEADERS = { ["User-Agent"] = "CCOOM-Installer" }

if not fs.exists(INSTALL_DIR) then
  fs.makeDir(INSTALL_DIR)
end

local url = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/dist/update.lua"
local resp, err = http.get(url, HEADERS, true)
if not resp then
  error(
    "HTTP request failed for " .. url .. ": " .. tostring(err) ..
    "\nIs the HTTP API enabled on this server? (computercraft-server.toml -> http.enabled/http.rules)"
  )
end
local code = resp.readAll()
resp.close()

local updaterPath = fs.combine(INSTALL_DIR, "update.lua")
local f = fs.open(updaterPath, "wb")
f.write(code)
f.close()

dofile(updaterPath)

print("")
print("Installed. Run: " .. INSTALL_DIR .. "/startup")

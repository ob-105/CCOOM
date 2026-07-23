-- CCOOM installer. Run this on the CC:Tweaked computer itself:
--   wget https://raw.githubusercontent.com/ob-105/CCOOM/main/install.lua install
--   install
--
-- Fetches every file under dist/ from GitHub via the HTTP API and writes it
-- to /ccoom on this computer, then tells you how to run it. Requires the
-- HTTP API to be enabled on this server (computercraft-server.toml's
-- http.enabled / http.rules) -- if requests fail immediately, that's the
-- first thing to check with whoever runs the server.

local REPO = "ob-105/CCOOM"
local BRANCH = "main"
local INSTALL_DIR = "ccoom"
local HEADERS = { ["User-Agent"] = "CCOOM-Installer" }

local function httpGet(url, binary)
  local resp, err = http.get(url, HEADERS, binary)
  if not resp then
    error(
      "HTTP request failed for " .. url .. ": " .. tostring(err) ..
      "\nIs the HTTP API enabled on this server? (computercraft-server.toml -> http.enabled/http.rules)"
    )
  end
  local data = resp.readAll()
  resp.close()
  return data
end

local unserializeJSON = textutils.unserialiseJSON or textutils.unserializeJSON

print("Fetching file listing from GitHub...")
local treeUrl = "https://api.github.com/repos/" .. REPO .. "/git/trees/" .. BRANCH .. "?recursive=1"
local tree = unserializeJSON(httpGet(treeUrl, false))
if not tree or not tree.tree then
  error("Could not parse repo file listing (unexpected GitHub API response)")
end

local files = {}
for _, entry in ipairs(tree.tree) do
  if entry.type == "blob" and entry.path:sub(1, 5) == "dist/" then
    table.insert(files, entry.path)
  end
end
print("Found " .. #files .. " files to install.")

if fs.exists(INSTALL_DIR) then
  print("Removing existing /" .. INSTALL_DIR .. "...")
  fs.delete(INSTALL_DIR)
end

local rawBase = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/"

for i, path in ipairs(files) do
  local localPath = fs.combine(INSTALL_DIR, path:sub(6)) -- strip leading "dist/"
  print("[" .. i .. "/" .. #files .. "] " .. localPath)

  local content = httpGet(rawBase .. path, true)
  local f = fs.open(localPath, "wb")
  f.write(content)
  f.close()
end

print("")
print("Done. Run: " .. INSTALL_DIR .. "/startup")

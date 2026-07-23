-- CCOOM auto-updater. Runs automatically at the start of every
-- ccoom/startup, and is also what install.lua invokes for the very first
-- install. Diffs the local /ccoom copy against the GitHub repo's current
-- file tree by git blob sha (stored in a local manifest) and only
-- downloads files that are new or actually changed -- no full wipe.

local REPO = "ob-105/CCOOM"
local BRANCH = "main"
local INSTALL_DIR = "ccoom"
local MANIFEST_PATH = fs.combine(INSTALL_DIR, ".manifest")
local HEADERS = { ["User-Agent"] = "CCOOM-Updater" }

local function httpGet(url, binary)
  local resp, err = http.get(url, HEADERS, binary)
  if not resp then
    error("HTTP request failed for " .. url .. ": " .. tostring(err))
  end
  local data = resp.readAll()
  resp.close()
  return data
end

local function loadManifest()
  if not fs.exists(MANIFEST_PATH) then
    return {}
  end
  local f = fs.open(MANIFEST_PATH, "r")
  local content = f.readAll()
  f.close()
  local ok, data = pcall(textutils.unserialize, content)
  if ok and type(data) == "table" then
    return data
  end
  return {}
end

local function saveManifest(manifest)
  local f = fs.open(MANIFEST_PATH, "w")
  f.write(textutils.serialize(manifest))
  f.close()
end

local function sync()
  if not http then
    error("HTTP API not available")
  end

  print("Checking for CCOOM updates...")
  local unserializeJSON = textutils.unserialiseJSON or textutils.unserializeJSON
  local treeUrl = "https://api.github.com/repos/" .. REPO .. "/git/trees/" .. BRANCH .. "?recursive=1"
  local tree = unserializeJSON(httpGet(treeUrl, false))
  if not tree or not tree.tree then
    error("Could not parse repo file listing (unexpected GitHub API response)")
  end

  local remote = {}
  for _, entry in ipairs(tree.tree) do
    if entry.type == "blob" and entry.path:sub(1, 5) == "dist/" then
      remote[entry.path] = entry.sha
    end
  end

  local manifest = loadManifest()
  local rawBase = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/"

  local updated, removed, unchanged = 0, 0, 0

  for path, sha in pairs(remote) do
    local localPath = fs.combine(INSTALL_DIR, path:sub(6)) -- strip leading "dist/"
    if manifest[path] == sha and fs.exists(localPath) then
      unchanged = unchanged + 1
    else
      local dir = fs.getDir(localPath)
      if dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
      end
      local content = httpGet(rawBase .. path, true)
      local f = fs.open(localPath, "wb")
      f.write(content)
      f.close()
      manifest[path] = sha
      updated = updated + 1
    end
  end

  for path in pairs(manifest) do
    if not remote[path] then
      local localPath = fs.combine(INSTALL_DIR, path:sub(6))
      if fs.exists(localPath) then
        fs.delete(localPath)
      end
      manifest[path] = nil
      removed = removed + 1
    end
  end

  saveManifest(manifest)
  print(("CCOOM up to date (%d updated, %d removed, %d unchanged)"):format(updated, removed, unchanged))
end

local ok, err = pcall(sync)
if not ok then
  print("Update check failed, continuing with existing files: " .. tostring(err))
end

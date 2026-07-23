-- CCOOM entry point. Run from the CraftOS shell as: ccoom/startup
-- (or place at the computer's actual root and rename to "startup" to
-- auto-run on boot -- not recommended yet while iterating).

local root = fs.getDir(shell.getRunningProgram())

local function loadLua(relPath)
  return dofile(fs.combine(root, relPath))
end

local function readBinary(relPath)
  local f = fs.open(fs.combine(root, relPath), "rb")
  local data = f.readAll()
  f.close()
  return data
end

local palette = loadLua("assets/palette.lua")
local BinReader = loadLua("engine/binreader.lua")
local Level = loadLua("engine/level.lua")
local Engine = loadLua("engine/engine.lua")

local level = Level.parse(readBinary("assets/level1.dat"), BinReader)

Engine.run(palette, level, root)

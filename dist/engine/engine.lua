-- CCOOM stage-1 engine: textured raycasting walls only (no floor/ceiling
-- textures, no sprites, no sound, no collision yet -- those are later
-- build-order stages).

local Engine = {}

-- Tunable constants: these are best-guess starting points and will very
-- likely need adjusting once you actually see this running in-game.
local FOV = math.rad(66)
local WALL_SCALE = 1 / 64      -- world-units-to-screen-height scale factor
local MOVE_SPEED = 180         -- map units/second
local TURN_SPEED = 2.2         -- radians/second
local CEILING_COLOR = "0"      -- blit hex digit, placeholder flat shade
local FLOOR_COLOR = "7"        -- blit hex digit, placeholder flat shade

-- Textures are stored 4-bit-per-pixel (two pixels per byte, low nibble
-- first) behind a 2-byte (width, height) header -- see tools/build.py.
local function loadTexture(root, texId)
  local f = fs.open(fs.combine(root, "assets/textures/" .. texId .. ".tex"), "rb")
  if not f then
    return false
  end
  local header = f.read(2)
  local tw = string.byte(header, 1)
  local th = string.byte(header, 2)
  local rowBytes = math.floor((tw + 1) / 2)
  local data = f.read(rowBytes * th)
  f.close()
  return { w = tw, h = th, data = data, rowBytes = rowBytes }
end

local function texturePixel(tex, row, col)
  local byteIdx = row * tex.rowBytes + math.floor(col / 2) + 1
  local byteVal = string.byte(tex.data, byteIdx)
  if col % 2 == 0 then
    return byteVal % 16
  else
    return math.floor(byteVal / 16)
  end
end

local BLIT_HEX = "0123456789abcdef"

function Engine.run(paletteTbl, level, root)
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()

  for i = 0, 15 do
    local c = paletteTbl[i + 1]
    term.setPaletteColor(2 ^ i, c[1] / 255, c[2] / 255, c[3] / 255)
  end

  local textures = {}
  local function getTexture(texId)
    if textures[texId] == nil then
      textures[texId] = loadTexture(root, texId)
    end
    return textures[texId]
  end

  local walls = level.walls
  local sectors = level.sectors
  local numWalls = #walls

  -- precompute wall lengths once
  for i = 1, numWalls do
    local wall = walls[i]
    local ex, ey = wall.x2 - wall.x1, wall.y2 - wall.y1
    wall.length = math.sqrt(ex * ex + ey * ey)
  end

  local px, py = level.player_start.x, level.player_start.y
  local angle = math.rad(level.player_start.angle)

  local keysDown = {}
  local running = true

  local halfTanFov = math.tan(FOV / 2)

  local function render()
    local dirx, diry = math.cos(angle), math.sin(angle)
    local planex, planey = -diry * halfTanFov, dirx * halfTanFov

    -- bg[row] is an array of w single-char blit hex digits
    local bg = {}
    for row = 1, h do
      local line = {}
      local horizon = h / 2
      local shade = row <= horizon and CEILING_COLOR or FLOOR_COLOR
      for col = 1, w do line[col] = shade end
      bg[row] = line
    end

    for col = 1, w do
      local camx = (w > 1) and (2 * (col - 1) / (w - 1) - 1) or 0
      local rdx = dirx + planex * camx
      local rdy = diry + planey * camx

      local bestT, bestWall, bestS = math.huge, nil, 0
      for i = 1, numWalls do
        local wall = walls[i]
        local ex, ey = wall.x2 - wall.x1, wall.y2 - wall.y1
        local det = ex * rdy - ey * rdx
        if det ~= 0 then
          local ax, ay = wall.x1 - px, wall.y1 - py
          local t = (ex * ay - ey * ax) / det
          if t > 0.01 and t < bestT then
            local s = (rdx * ay - rdy * ax) / det
            if s >= 0 and s <= 1 then
              bestT, bestWall, bestS = t, wall, s
            end
          end
        end
      end

      if bestWall then
        local sector = sectors[bestWall.sector + 1] -- Lua tables are 1-indexed, sector ids from Python are 0-indexed
        local wallHeight = sector.ceiling - sector.floor
        local lineHeight = math.max(1, math.floor(h * wallHeight * WALL_SCALE / bestT))
        local lineTop = math.floor(h / 2 - lineHeight / 2)
        local lineBottom = lineTop + lineHeight

        local tex = getTexture(bestWall.tex_id)
        local texU
        if tex then
          texU = math.floor((bestS * bestWall.length + bestWall.x_offset)) % tex.w
        end

        local rowStart = math.max(1, lineTop + 1)
        local rowEnd = math.min(h, lineBottom)
        for row = rowStart, rowEnd do
          local colorIdx
          if tex then
            local frac = (row - 1 - lineTop) / lineHeight
            local texV = math.floor((frac * wallHeight + bestWall.y_offset)) % tex.h
            colorIdx = texturePixel(tex, texV, texU)
          end
          if colorIdx == nil then
            bg[row][col] = "8" -- fallback shade if the texture failed to load
          else
            bg[row][col] = BLIT_HEX:sub(colorIdx + 1, colorIdx + 1)
          end
        end
      end
    end

    local blankText = string.rep(" ", w)
    local blankFg = string.rep("0", w)
    for row = 1, h do
      term.setCursorPos(1, row)
      term.blit(blankText, blankFg, table.concat(bg[row]))
    end
  end

  local timerId = os.startTimer(0)
  while running do
    local ev = { os.pullEvent() }
    local name = ev[1]

    if name == "timer" and ev[2] == timerId then
      local dt = 0.05
      local dirx, diry = math.cos(angle), math.sin(angle)
      if keysDown[keys.w] then
        px = px + dirx * MOVE_SPEED * dt
        py = py + diry * MOVE_SPEED * dt
      end
      if keysDown[keys.s] then
        px = px - dirx * MOVE_SPEED * dt
        py = py - diry * MOVE_SPEED * dt
      end
      if keysDown[keys.a] then
        angle = angle - TURN_SPEED * dt
      end
      if keysDown[keys.d] then
        angle = angle + TURN_SPEED * dt
      end
      if keysDown[keys.q] then
        running = false
      end

      render()
      timerId = os.startTimer(0)
    elseif name == "key" then
      keysDown[ev[2]] = true
    elseif name == "key_up" then
      keysDown[ev[2]] = nil
    elseif name == "terminate" then
      running = false
    end
  end

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()
  term.setCursorPos(1, 1)
end

return Engine

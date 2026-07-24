-- CCOOM stage-2 engine: textured raycasting walls, floor/ceiling flat
-- casting, wall collision, distance fog, full 2x3 teletext sub-pixel
-- resolution, and a minimap overlay. No sprites/enemies/sound yet -- those
-- are later build-order stages.

local Engine = {}

-- Tunable constants: these are best-guess starting points and will very
-- likely need adjusting once you actually see this running in-game.
local FOV = math.rad(66)
-- Pinhole-camera projection scale: a wall of world-height H at perpendicular
-- distance D projects to screen-height (subH * H * WALL_SCALE / D). Derived
-- from the FOV rather than guessed -- the previous hardcoded 1/64 was ~64x
-- too small, so every wall rendered at a sub-pixel sliver (invisible against
-- the ceiling/floor placeholder, not actually "missing").
local WALL_SCALE = 1 / (2 * math.tan(FOV / 2))
local MOVE_SPEED = 180         -- map units/second
local TURN_SPEED = 2.2         -- radians/second
local PLAYER_RADIUS = 16       -- map units; matches Doom's own player radius
local EYE_HEIGHT = 41          -- map units above/below center; matches Doom's default view height
local FLAT_TILE = 64           -- Doom flats are always 64x64 world units
local CEILING_IDX = 0          -- palette index, fallback if a ceiling flat fails to load
local FLOOR_IDX = 7            -- palette index, fallback if a floor flat fails to load
local FALLBACK_IDX = 8         -- palette index shown if a wall texture failed to load

-- Distance fog: fades toward the darkest available palette color between
-- FOG_START and FOG_END map units, using ordered (Bayer) dithering so a
-- 16-color palette can still show a gradient instead of a hard cutoff.
-- Gives a depth cue that raw texture color alone doesn't provide.
local FOG_START = 250
local FOG_END = 1700
local BAYER4 = {
  { 0, 8, 2, 10 },
  { 12, 4, 14, 6 },
  { 3, 11, 1, 9 },
  { 15, 7, 13, 5 },
}

-- CC:Tweaked's font has "teletext" mosaic characters at byte codes 128-159:
-- each splits a cell into a 2-wide x 3-tall grid of sub-pixels, encoded as
-- 128 + sum of bit weights (1,2,4,8,16) for each of the first 5 sub-cells
-- that differs from the 6th (bottom-right), which is always the background
-- color. We use the full grid (both sub-columns, not just sub-rows), giving
-- 2x horizontal and 3x vertical resolution -- at the cost of roughly
-- doubling the per-frame ray-cast count (the expensive part of rendering).
-- Bit-encoding verified against 9551-Dev/pixelbox_lite.
local SUB_ROWS = 3
local SUB_COLS = 2

-- Minimap: small north-up 2D overlay in the top-left corner so orientation
-- doesn't depend on 3D render resolution at all.
local MINIMAP_COLS = 15
local MINIMAP_ROWS = 9
local MINIMAP_WORLD_RADIUS = 700 -- map units shown from center to edge

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

-- Flats tile every FLAT_TILE world units; Lua's % already follows the
-- floor-division convention (result has the same sign as the divisor), so
-- negative world coordinates wrap correctly with no extra correction.
local function sampleFlat(tex, wx, wy)
  if not tex then
    return nil
  end
  local texX = math.floor((wx % FLAT_TILE) * tex.w / FLAT_TILE)
  local texY = math.floor((wy % FLAT_TILE) * tex.h / FLAT_TILE)
  if texX >= tex.w then texX = tex.w - 1 end
  if texY >= tex.h then texY = tex.h - 1 end
  return texturePixel(tex, texY, texX)
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

  -- Pick palette indices for fog and the minimap by inspecting brightness,
  -- since the actual 16-color palette is generated per-build and its
  -- indices aren't known ahead of time.
  local brightestIdx, darkestIdx = 0, 0
  local brightestSum, darkestSum = -1, math.huge
  for i = 0, 15 do
    local c = paletteTbl[i + 1]
    local sum = c[1] + c[2] + c[3]
    if sum > brightestSum then brightestSum, brightestIdx = sum, i end
    if sum < darkestSum then darkestSum, darkestIdx = sum, i end
  end
  local FOG_IDX = darkestIdx
  local MINIMAP_PLAYER_IDX = brightestIdx
  local MINIMAP_WALL_IDX = darkestIdx == 0 and 1 or 0 -- any index distinct from FOG_IDX

  local function applyFog(colorIdx, dist, sc, sr)
    if dist <= FOG_START then
      return colorIdx
    end
    local fogAmount = (dist - FOG_START) / (FOG_END - FOG_START)
    if fogAmount >= 1 then
      return FOG_IDX
    end
    local bx, by = (sc - 1) % 4 + 1, (sr - 1) % 4 + 1
    if fogAmount > BAYER4[by][bx] / 16 then
      return FOG_IDX
    end
    return colorIdx
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

  local subW = w * SUB_COLS
  local subH = h * SUB_ROWS
  local horizonRow = subH / 2

  -- Perpendicular distance to the floor/ceiling plane at each sub-row,
  -- precomputed once since it only depends on screen geometry (not the
  -- player's position/angle, which change every frame). Same derivation as
  -- WALL_SCALE, solved for distance given a fixed EYE_HEIGHT offset from
  -- center instead of a fixed wall height.
  local subRowDist = {}
  for sr = 1, subH do
    local p
    if sr > horizonRow then
      p = sr - horizonRow
    elseif sr < horizonRow then
      p = horizonRow - sr
    end
    if p and p > 0 then
      subRowDist[sr] = EYE_HEIGHT * subH * WALL_SCALE / p
    end
  end

  local function collides(x, y)
    for i = 1, numWalls do
      local wall = walls[i]
      local abx, aby = wall.x2 - wall.x1, wall.y2 - wall.y1
      local apx, apy = x - wall.x1, y - wall.y1
      local abLenSq = abx * abx + aby * aby
      local t = 0
      if abLenSq > 0 then
        t = (apx * abx + apy * aby) / abLenSq
        if t < 0 then
          t = 0
        elseif t > 1 then
          t = 1
        end
      end
      local cx, cy = wall.x1 + t * abx, wall.y1 + t * aby
      local dx, dy = x - cx, y - cy
      if dx * dx + dy * dy < PLAYER_RADIUS * PLAYER_RADIUS then
        return true
      end
    end
    return false
  end

  local subMMW, subMMH = MINIMAP_COLS * SUB_COLS, MINIMAP_ROWS * SUB_ROWS
  local unitsPerSubCol = (2 * MINIMAP_WORLD_RADIUS) / subMMW
  local unitsPerSubRow = (2 * MINIMAP_WORLD_RADIUS) / subMMH
  local minimapRejectDistSq = (MINIMAP_WORLD_RADIUS * 1.5) ^ 2

  local function drawMinimap(buf)
    for i = 1, numWalls do
      local wall = walls[i]
      local dx1, dy1 = wall.x1 - px, wall.y1 - py
      local dx2, dy2 = wall.x2 - px, wall.y2 - py
      if math.min(dx1 * dx1 + dy1 * dy1, dx2 * dx2 + dy2 * dy2) <= minimapRejectDistSq then
        local c1 = subMMW / 2 + dx1 / unitsPerSubCol
        local r1 = subMMH / 2 + dy1 / unitsPerSubRow
        local c2 = subMMW / 2 + dx2 / unitsPerSubCol
        local r2 = subMMH / 2 + dy2 / unitsPerSubRow
        local steps = math.min(32, math.max(1, math.floor(math.max(math.abs(c2 - c1), math.abs(r2 - r1)))))
        for step = 0, steps do
          local t = step / steps
          local c = math.floor(c1 + (c2 - c1) * t + 0.5)
          local r = math.floor(r1 + (r2 - r1) * t + 0.5)
          if c >= 1 and c <= subMMW and r >= 1 and r <= subMMH then
            buf[r][c] = MINIMAP_WALL_IDX
          end
        end
      end
    end

    local centerC, centerR = math.floor(subMMW / 2 + 0.5), math.floor(subMMH / 2 + 0.5)
    buf[centerR][centerC] = MINIMAP_PLAYER_IDX
    local faceC = math.floor(centerC + math.cos(angle) * 2 + 0.5)
    local faceR = math.floor(centerR + math.sin(angle) * 2 + 0.5)
    if faceC >= 1 and faceC <= subMMW and faceR >= 1 and faceR <= subMMH then
      buf[faceR][faceC] = MINIMAP_PLAYER_IDX
    end
  end

  local function render()
    local dirx, diry = math.cos(angle), math.sin(angle)
    local planex, planey = -diry * halfTanFov, dirx * halfTanFov

    -- buf[subrow][subcol] holds a palette index (0-15) at full sub-pixel resolution
    local buf = {}
    for sr = 1, subH do
      local line = {}
      local shade = sr <= horizonRow and CEILING_IDX or FLOOR_IDX
      for sc = 1, subW do line[sc] = shade end
      buf[sr] = line
    end

    for sc = 1, subW do
      local camx = (subW > 1) and (2 * (sc - 1) / (subW - 1) - 1) or 0
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
        local lineHeight = math.max(1, math.floor(subH * wallHeight * WALL_SCALE / bestT))
        local lineTop = math.floor(subH / 2 - lineHeight / 2)
        local lineBottom = lineTop + lineHeight

        local ceilTex = getTexture(sector.ceiling_flat_id)
        local floorTex = getTexture(sector.floor_flat_id)
        for sr = 1, lineTop do
          local d = subRowDist[sr]
          if d then
            local wx, wy = px + d * rdx, py + d * rdy
            local idx = sampleFlat(ceilTex, wx, wy) or CEILING_IDX
            buf[sr][sc] = applyFog(idx, d, sc, sr)
          end
        end
        for sr = lineBottom + 1, subH do
          local d = subRowDist[sr]
          if d then
            local wx, wy = px + d * rdx, py + d * rdy
            local idx = sampleFlat(floorTex, wx, wy) or FLOOR_IDX
            buf[sr][sc] = applyFog(idx, d, sc, sr)
          end
        end

        local tex = getTexture(bestWall.tex_id)
        local texU
        if tex then
          texU = math.floor((bestS * bestWall.length + bestWall.x_offset)) % tex.w
        end

        local rowStart = math.max(1, lineTop + 1)
        local rowEnd = math.min(subH, lineBottom)
        for sr = rowStart, rowEnd do
          local colorIdx
          if tex then
            local frac = (sr - 1 - lineTop) / lineHeight
            local texV = math.floor((frac * wallHeight + bestWall.y_offset)) % tex.h
            colorIdx = texturePixel(tex, texV, texU)
          end
          buf[sr][sc] = applyFog(colorIdx or FALLBACK_IDX, bestT, sc, sr)
        end
      end
    end

    drawMinimap(buf)

    -- Pack every 2x3 sub-pixel block into one terminal cell using a
    -- teletext glyph (see the module comment for the bit-encoding).
    for row = 1, h do
      local baseRow = (row - 1) * SUB_ROWS
      local textChars, fgChars, bgChars = {}, {}, {}
      for col = 1, w do
        local baseCol = (col - 1) * SUB_COLS
        local topLeft = buf[baseRow + 1][baseCol + 1]
        local topRight = buf[baseRow + 1][baseCol + 2]
        local midLeft = buf[baseRow + 2][baseCol + 1]
        local midRight = buf[baseRow + 2][baseCol + 2]
        local botLeft = buf[baseRow + 3][baseCol + 1]
        local baseline = buf[baseRow + 3][baseCol + 2]

        local code = 128
        local fgIdx = baseline
        if topLeft ~= baseline then
          code = code + 1
          fgIdx = topLeft
        end
        if topRight ~= baseline then
          code = code + 2
          if fgIdx == baseline then fgIdx = topRight end
        end
        if midLeft ~= baseline then
          code = code + 4
          if fgIdx == baseline then fgIdx = midLeft end
        end
        if midRight ~= baseline then
          code = code + 8
          if fgIdx == baseline then fgIdx = midRight end
        end
        if botLeft ~= baseline then
          code = code + 16
          if fgIdx == baseline then fgIdx = botLeft end
        end

        textChars[col] = string.char(code)
        fgChars[col] = BLIT_HEX:sub(fgIdx + 1, fgIdx + 1)
        bgChars[col] = BLIT_HEX:sub(baseline + 1, baseline + 1)
      end
      term.setCursorPos(1, row)
      term.blit(table.concat(textChars), table.concat(fgChars), table.concat(bgChars))
    end
  end

  local timerId = os.startTimer(0)
  while running do
    local ev = { os.pullEvent() }
    local name = ev[1]

    if name == "timer" and ev[2] == timerId then
      local dt = 0.05
      local dirx, diry = math.cos(angle), math.sin(angle)

      local moveDir = 0
      if keysDown[keys.w] then moveDir = moveDir + 1 end
      if keysDown[keys.s] then moveDir = moveDir - 1 end
      if moveDir ~= 0 then
        local nx = px + dirx * MOVE_SPEED * dt * moveDir
        local ny = py + diry * MOVE_SPEED * dt * moveDir
        if not collides(nx, py) then
          px = nx
        end
        if not collides(px, ny) then
          py = ny
        end
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

-- CCOOM stage-2 engine: textured raycasting walls, per-ray portal-aware
-- floor/ceiling flat casting, wall collision, banded distance fog, full
-- 2x3 teletext sub-pixel resolution, and a full-screen map mode (press M).
-- No sprites/enemies/sound yet -- those are later build-order stages.

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

-- Distance fog: darkens color toward black in discrete bands between
-- FOG_START and FOG_END map units, remapping each of the 16 palette colors
-- to whichever of the SAME 16 colors is nearest to its darkened version
-- (there's no room to add new palette entries). This replaced an earlier
-- per-pixel ordered-dither version of fog: dithering added fine-grained
-- pixel noise on top of already-detailed, grimy Doom textures, which at
-- this render resolution just looked like static rather than a gradient.
-- Flat per-band recoloring has no such artifact.
local FOG_START = 300
local FOG_END = 1800
local FOG_BANDS = 6

-- CC:Tweaked's font has "teletext" mosaic characters at byte codes 128-159:
-- each splits a cell into a 2-wide x 3-tall grid of sub-pixels, encoded as
-- 128 + sum of bit weights (1,2,4,8,16) for each of the first 5 sub-cells
-- that differs from the 6th (bottom-right), which is always the background
-- color. Bit-encoding verified against 9551-Dev/pixelbox_lite.
--
-- SUB_COLS is a hardware constant (the glyph is always 2 wide), not a
-- quality toggle: casting one independent ray per sub-column doubled the
-- per-frame ray-cast count (already the dominant cost, further stacked with
-- portal tracing) and made the game noticeably choppy. Instead we cast one
-- ray per terminal column (matching the vertical-only version's cost) and
-- duplicate its result into both sub-columns -- full 3x vertical detail
-- stays, horizontal detail drops back to one sample per character cell.
local SUB_ROWS = 3
local SUB_COLS = 2

-- Walls/portals farther than this are already fully fogged to a flat color
-- (see FOG_END below), so we skip testing them per-ray entirely -- filtered
-- to a smaller "nearby" list once per frame instead of scanning everything
-- on every single ray.
local RENDER_DIST = 2000

-- Full-screen map mode (toggled with M), styled after Doom's automap:
-- shows every wall in the level at a fixed scale that fits the screen,
-- rather than a small always-on corner minimap.
local MAP_ZOOM_MARGIN = 0.9 -- fraction of screen the level bounding box fills

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

  -- Find the brightest/darkest available palette indices (used for the map
  -- screen's line/background colors) and build the banded fog remap table.
  local brightestIdx, darkestIdx = 0, 0
  local brightestSum, darkestSum = -1, math.huge
  for i = 0, 15 do
    local c = paletteTbl[i + 1]
    local sum = c[1] + c[2] + c[3]
    if sum > brightestSum then brightestSum, brightestIdx = sum, i end
    if sum < darkestSum then darkestSum, darkestIdx = sum, i end
  end
  local MAP_WALL_IDX = brightestIdx
  local MAP_BG_IDX = darkestIdx

  local fogTable = {}
  for band = 0, FOG_BANDS do
    local darken = band / FOG_BANDS
    local row = {}
    for origIdx = 0, 15 do
      local oc = paletteTbl[origIdx + 1]
      local tr, tg, tb = oc[1] * (1 - darken), oc[2] * (1 - darken), oc[3] * (1 - darken)
      local bestIdx, bestDist = origIdx, math.huge
      for cand = 0, 15 do
        local cc = paletteTbl[cand + 1]
        local dr, dg, db = tr - cc[1], tg - cc[2], tb - cc[3]
        local dist = dr * dr + dg * dg + db * db
        if dist < bestDist then
          bestDist, bestIdx = dist, cand
        end
      end
      row[origIdx] = bestIdx
    end
    fogTable[band] = row
  end

  local function applyFog(colorIdx, dist)
    if dist <= FOG_START then
      return colorIdx
    end
    local band
    if dist >= FOG_END then
      band = FOG_BANDS
    else
      band = math.floor((dist - FOG_START) / (FOG_END - FOG_START) * FOG_BANDS)
    end
    return fogTable[band][colorIdx]
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
  local portals = level.portals
  local numWalls = #walls
  local numPortals = #portals

  -- precompute wall lengths once, and the level's bounding box (for map mode)
  local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
  for i = 1, numWalls do
    local wall = walls[i]
    local ex, ey = wall.x2 - wall.x1, wall.y2 - wall.y1
    wall.length = math.sqrt(ex * ex + ey * ey)
    minX = math.min(minX, wall.x1, wall.x2)
    maxX = math.max(maxX, wall.x1, wall.x2)
    minY = math.min(minY, wall.y1, wall.y2)
    maxY = math.max(maxY, wall.y1, wall.y2)
  end

  local px, py = level.player_start.x, level.player_start.y
  local angle = math.rad(level.player_start.angle)

  local keysDown = {}
  local running = true
  local showMap = false

  local halfTanFov = math.tan(FOV / 2)

  local subW = w * SUB_COLS
  local subH = h * SUB_ROWS
  local horizonRow = subH / 2

  local mapCenterX, mapCenterY = (minX + maxX) / 2, (minY + maxY) / 2
  local mapWorldW, mapWorldH = math.max(1, maxX - minX), math.max(1, maxY - minY)
  local mapScale = math.min(subW / mapWorldW, subH / mapWorldH) * MAP_ZOOM_MARGIN

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

  -- Approximates "which sector is the player standing in" (as a sector
  -- index, not the sector object) as the sector of whichever wall segment
  -- is nearest to the player's actual position -- cheap (no stored sector
  -- polygons needed) and correct as long as the player is closer to their
  -- own room's walls than to another room's, which holds except right at a
  -- doorway threshold. This is only the STARTING sector for a ray; per-pixel
  -- floor/ceiling texturing then traces forward through actual portal
  -- crossings (see the portal-walk in render()) so the texture change
  -- happens exactly at the doorway in the image, not as a sudden whole-
  -- screen swap when the player's own position crosses some threshold.
  local function currentSector()
    local bestDistSq, bestSector = math.huge, 0
    for i = 1, numWalls do
      local wall = walls[i]
      local abx, aby = wall.x2 - wall.x1, wall.y2 - wall.y1
      local apx, apy = px - wall.x1, py - wall.y1
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
      local dx, dy = px - cx, py - cy
      local distSq = dx * dx + dy * dy
      if distSq < bestDistSq then
        bestDistSq, bestSector = distSq, wall.sector
      end
    end
    return bestSector
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

  local function newBuf(fillIdx)
    local buf = {}
    for sr = 1, subH do
      local line = {}
      for sc = 1, subW do line[sc] = fillIdx end
      buf[sr] = line
    end
    return buf
  end

  -- Packs every 2x3 sub-pixel block into one terminal cell using a teletext
  -- glyph (see the module comment for the bit-encoding) and blits it.
  local function flushBuffer(buf)
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

  local function plotLine(buf, c1, r1, c2, r2, colorIdx)
    local steps = math.min(64, math.max(1, math.floor(math.max(math.abs(c2 - c1), math.abs(r2 - r1)))))
    for step = 0, steps do
      local t = step / steps
      local c = math.floor(c1 + (c2 - c1) * t + 0.5)
      local r = math.floor(r1 + (r2 - r1) * t + 0.5)
      if c >= 1 and c <= subW and r >= 1 and r <= subH then
        buf[r][c] = colorIdx
      end
    end
  end

  local function renderMap()
    local buf = newBuf(MAP_BG_IDX)

    for i = 1, numWalls do
      local wall = walls[i]
      local c1 = subW / 2 + (wall.x1 - mapCenterX) * mapScale
      local r1 = subH / 2 + (wall.y1 - mapCenterY) * mapScale
      local c2 = subW / 2 + (wall.x2 - mapCenterX) * mapScale
      local r2 = subH / 2 + (wall.y2 - mapCenterY) * mapScale
      plotLine(buf, c1, r1, c2, r2, MAP_WALL_IDX)
    end

    local pc = subW / 2 + (px - mapCenterX) * mapScale
    local pr = subH / 2 + (py - mapCenterY) * mapScale
    plotLine(buf, pc, pr, pc + math.cos(angle) * 3, pr + math.sin(angle) * 3, MAP_WALL_IDX)

    flushBuffer(buf)
  end

  local function render()
    local dirx, diry = math.cos(angle), math.sin(angle)
    local planex, planey = -diry * halfTanFov, dirx * halfTanFov

    -- Computed once per frame, not per column/ray -- the seed sector each
    -- column's portal walk starts from (see currentSector's comment).
    local startSectorIdx = currentSector()

    -- Cull walls/portals farther than RENDER_DIST once per frame (see the
    -- constant's comment) instead of testing all of them on every ray.
    local renderDistSq = RENDER_DIST * RENDER_DIST
    local activeWalls, numActiveWalls = {}, 0
    for i = 1, numWalls do
      local wall = walls[i]
      local dx1, dy1 = wall.x1 - px, wall.y1 - py
      local dx2, dy2 = wall.x2 - px, wall.y2 - py
      if math.min(dx1 * dx1 + dy1 * dy1, dx2 * dx2 + dy2 * dy2) < renderDistSq then
        numActiveWalls = numActiveWalls + 1
        activeWalls[numActiveWalls] = wall
      end
    end
    local activePortals, numActivePortals = {}, 0
    for i = 1, numPortals do
      local portal = portals[i]
      local dx1, dy1 = portal.x1 - px, portal.y1 - py
      local dx2, dy2 = portal.x2 - px, portal.y2 - py
      if math.min(dx1 * dx1 + dy1 * dy1, dx2 * dx2 + dy2 * dy2) < renderDistSq then
        numActivePortals = numActivePortals + 1
        activePortals[numActivePortals] = portal
      end
    end

    local buf = {}
    for sr = 1, subH do
      local line = {}
      local shade = sr <= horizonRow and CEILING_IDX or FLOOR_IDX
      for sc = 1, subW do line[sc] = shade end
      buf[sr] = line
    end

    for col = 1, w do
      local camx = (w > 1) and (2 * (col - 1) / (w - 1) - 1) or 0
      local rdx = dirx + planex * camx
      local rdy = diry + planey * camx
      local sc1 = (col - 1) * SUB_COLS + 1
      local sc2 = sc1 + 1

      local bestT, bestWall, bestS = math.huge, nil, 0
      for i = 1, numActiveWalls do
        local wall = activeWalls[i]
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

        -- Find every portal this ray crosses before reaching the solid
        -- wall, so floor/ceiling texturing can switch sector exactly at
        -- each crossing distance instead of using one sector for the whole
        -- column (which is what caused the instant, whole-screen swap).
        local crossT, crossPortal, numCross = {}, {}, 0
        for i = 1, numActivePortals do
          local portal = activePortals[i]
          local ex, ey = portal.x2 - portal.x1, portal.y2 - portal.y1
          local det = ex * rdy - ey * rdx
          if det ~= 0 then
            local ax, ay = portal.x1 - px, portal.y1 - py
            local t = (ex * ay - ey * ax) / det
            if t > 0.01 and t < bestT then
              local s = (rdx * ay - rdy * ax) / det
              if s >= 0 and s <= 1 then
                numCross = numCross + 1
                crossT[numCross] = t
                crossPortal[numCross] = portal
              end
            end
          end
        end
        -- insertion sort by distance (numCross is small: a handful at most)
        for i = 2, numCross do
          local t, p, j = crossT[i], crossPortal[i], i - 1
          while j >= 1 and crossT[j] > t do
            crossT[j + 1], crossPortal[j + 1] = crossT[j], crossPortal[j]
            j = j - 1
          end
          crossT[j + 1], crossPortal[j + 1] = t, p
        end

        local function sectorAt(d)
          local idx = startSectorIdx
          for i = 1, numCross do
            if crossT[i] > d then break end
            local p = crossPortal[i]
            idx = (idx == p.front_sector) and p.back_sector or p.front_sector
          end
          return sectors[idx + 1]
        end

        for sr = 1, lineTop do
          local d = subRowDist[sr]
          if d then
            local wx, wy = px + d * rdx, py + d * rdy
            local tex = getTexture(sectorAt(d).ceiling_flat_id)
            local idx = sampleFlat(tex, wx, wy) or CEILING_IDX
            local shaded = applyFog(idx, d)
            buf[sr][sc1] = shaded
            buf[sr][sc2] = shaded
          end
        end
        for sr = lineBottom + 1, subH do
          local d = subRowDist[sr]
          if d then
            local wx, wy = px + d * rdx, py + d * rdy
            local tex = getTexture(sectorAt(d).floor_flat_id)
            local idx = sampleFlat(tex, wx, wy) or FLOOR_IDX
            local shaded = applyFog(idx, d)
            buf[sr][sc1] = shaded
            buf[sr][sc2] = shaded
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
          local shaded = applyFog(colorIdx or FALLBACK_IDX, bestT)
          buf[sr][sc1] = shaded
          buf[sr][sc2] = shaded
        end
      end
    end

    flushBuffer(buf)
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

      if showMap then
        renderMap()
      else
        render()
      end
      timerId = os.startTimer(0)
    elseif name == "key" then
      if ev[2] == keys.m then
        showMap = not showMap
      else
        keysDown[ev[2]] = true
      end
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

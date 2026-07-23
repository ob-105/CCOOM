-- Parses the packed-binary level1.dat format written by tools/convert_level.py.
-- Layout: player_start(i16 x,y,angle), sector_count(u16), sectors[floor(i16),
-- ceiling(i16), light(u8)], wall_count(u16), walls[x1,y1,x2,y2(i16 each),
-- sector(u16), tex_id(u8), x_offset(i16), y_offset(i16)].

local Level = {}

function Level.parse(data, BinReaderModule)
  local r = BinReaderModule.new(data)
  local level = {}

  level.player_start = { x = r:i16(), y = r:i16(), angle = r:i16() }

  local sectorCount = r:u16()
  local sectors = {}
  for i = 1, sectorCount do
    sectors[i] = { floor = r:i16(), ceiling = r:i16(), light = r:u8() }
  end
  level.sectors = sectors

  local wallCount = r:u16()
  local walls = {}
  for i = 1, wallCount do
    walls[i] = {
      x1 = r:i16(), y1 = r:i16(), x2 = r:i16(), y2 = r:i16(),
      sector = r:u16(), tex_id = r:u8(),
      x_offset = r:i16(), y_offset = r:i16(),
    }
  end
  level.walls = walls

  return level
end

return Level

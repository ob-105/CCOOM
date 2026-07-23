-- Minimal little-endian binary reader. CC:Tweaked's Lua runtime doesn't
-- provide string.pack/unpack (a Lua 5.3 feature), so level/texture data is
-- decoded by hand from raw byte strings.

local BinReader = {}
BinReader.__index = BinReader

function BinReader.new(data)
  return setmetatable({ data = data, pos = 1 }, BinReader)
end

function BinReader:u8()
  local v = string.byte(self.data, self.pos)
  self.pos = self.pos + 1
  return v
end

function BinReader:u16()
  local a = string.byte(self.data, self.pos)
  local b = string.byte(self.data, self.pos + 1)
  self.pos = self.pos + 2
  return a + b * 256
end

function BinReader:i16()
  local v = self:u16()
  if v >= 32768 then
    v = v - 65536
  end
  return v
end

return BinReader

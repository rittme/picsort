-- Tiny EXIF reader: extracts DateTimeOriginal (or DateTime) from JPEG APP1.
-- Returns unix-epoch seconds, or nil. Pure Lua, reads ~64KB max.

local M = {}

local function u16(s, o, be)
  local a, b = s:byte(o), s:byte(o+1)
  if be then return a*256 + b end
  return b*256 + a
end
local function u32(s, o, be)
  local a,b,c,d = s:byte(o),s:byte(o+1),s:byte(o+2),s:byte(o+3)
  if be then return ((a*256+b)*256+c)*256+d end
  return ((d*256+c)*256+b)*256+a
end

local function parseDate(str)
  -- "YYYY:MM:DD HH:MM:SS"
  local Y,Mo,D,h,m,s = str:match("(%d+):(%d+):(%d+) (%d+):(%d+):(%d+)")
  if not Y then return nil end
  return os.time{ year=tonumber(Y), month=tonumber(Mo), day=tonumber(D),
                  hour=tonumber(h), min=tonumber(m), sec=tonumber(s) }
end

local function parseTIFF(buf)
  -- buf starts at TIFF header
  if #buf < 8 then return nil end
  local bo = buf:sub(1,2)
  local be
  if bo == "MM" then be = true
  elseif bo == "II" then be = false
  else return nil end
  local magic = u16(buf, 3, be)
  if magic ~= 42 then return nil end
  local ifd0 = u32(buf, 5, be)
  if ifd0 + 2 > #buf then return nil end

  local function readIFD(off)
    if off + 2 > #buf then return nil, nil end
    local n = u16(buf, off+1, be)
    local entries = {}
    local exifOff
    for i = 0, n-1 do
      local e = off + 2 + i*12
      if e + 12 > #buf then break end
      local tag  = u16(buf, e+1, be)
      local typ  = u16(buf, e+3, be)
      local cnt  = u32(buf, e+5, be)
      local val  = u32(buf, e+9, be)
      entries[tag] = { typ=typ, cnt=cnt, val=val, off=e+9 }
      if tag == 0x8769 then exifOff = val end
    end
    return entries, exifOff
  end

  local function readAscii(entry)
    if entry.typ ~= 2 then return nil end
    local len = entry.cnt
    local data
    if len <= 4 then
      data = buf:sub(entry.off+1, entry.off+len)
    else
      local o = entry.val + 1
      if o + len - 1 > #buf then return nil end
      data = buf:sub(o, o+len-1)
    end
    return (data:gsub("%z+$",""))
  end

  local ifd0e, exifOff = readIFD(ifd0+1) -- 1-indexed
  if not ifd0e then return nil end

  local s
  if exifOff then
    local exife = readIFD(exifOff+1)
    if exife then
      if exife[0x9003] then s = readAscii(exife[0x9003]) -- DateTimeOriginal
      elseif exife[0x9004] then s = readAscii(exife[0x9004]) end -- DateTimeDigitized
    end
  end
  if not s and ifd0e[0x0132] then s = readAscii(ifd0e[0x0132]) end -- DateTime
  return s and parseDate(s) or nil
end

function M.dateTaken(filepath)
  local f = io.open(filepath, "rb")
  if not f then return nil end
  -- Only handle JPEG
  local sig = f:read(2)
  if sig ~= "\xff\xd8" then f:close(); return nil end
  -- Walk segments looking for APP1 "Exif\0\0"
  local taken
  local read = 2
  while read < 200000 do
    local hdr = f:read(2)
    if not hdr or #hdr < 2 then break end
    if hdr:byte(1) ~= 0xff then break end
    local marker = hdr:byte(2)
    if marker == 0xda or marker == 0xd9 then break end -- SOS / EOI
    local lenb = f:read(2)
    if not lenb or #lenb < 2 then break end
    local seglen = lenb:byte(1)*256 + lenb:byte(2)
    if seglen < 2 then break end
    local body = f:read(seglen - 2)
    if not body then break end
    read = read + 4 + (seglen - 2)
    if marker == 0xe1 and body:sub(1,6) == "Exif\0\0" then
      taken = parseTIFF(body:sub(7))
      break
    end
  end
  f:close()
  return taken
end

return M

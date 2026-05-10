-- picsort: redbean + fullmoon photo-rating app
-- Serves images from the directory the binary was launched from (recursive),
-- lets LAN users rate them 1-5 (or 0 = delete), shows averages.

local fm  = require "fullmoon"
local exif = require "exif"

-- ---------------------------------------------------------------------------
-- Paths / config
-- ---------------------------------------------------------------------------
local ROOT = unix.getcwd()           -- folder where the user launched picsort
local DBPATH = path.join(ROOT, "picsort.db")
local IMAGE_EXT = { jpg=true, jpeg=true, png=true, gif=true, webp=true,
                    heic=true, heif=true, bmp=true, tif=true, tiff=true }

-- ---------------------------------------------------------------------------
-- DB
-- ---------------------------------------------------------------------------
local sqlite3 = lsqlite3
local db = sqlite3.open(DBPATH)
db:exec[[
  PRAGMA journal_mode=WAL;
  PRAGMA synchronous=NORMAL;
  CREATE TABLE IF NOT EXISTS ratings (
    path     TEXT NOT NULL,
    username TEXT NOT NULL,
    score    INTEGER NOT NULL,
    updated  INTEGER NOT NULL,
    PRIMARY KEY(path, username)
  );
  CREATE TABLE IF NOT EXISTS file_meta (
    path  TEXT PRIMARY KEY,
    mtime INTEGER NOT NULL,
    size  INTEGER NOT NULL,
    taken INTEGER  -- unix seconds; null if unknown
  );
]]

local function dbq(sql, ...)
  local stmt = assert(db:prepare(sql))
  stmt:bind_values(...)
  local rows = {}
  for r in stmt:nrows() do rows[#rows+1] = r end
  stmt:finalize()
  return rows
end
local function dbexec(sql, ...)
  local stmt = assert(db:prepare(sql))
  stmt:bind_values(...)
  stmt:step(); stmt:finalize()
end

-- ---------------------------------------------------------------------------
-- Filesystem scan
-- ---------------------------------------------------------------------------
local function isImage(name)
  local ext = name:match("%.([^.]+)$")
  return ext and IMAGE_EXT[ext:lower()] or false
end

local function safeJoin(base, p)
  -- prevent path-traversal: resolved path must stay under base
  local full = path.join(base, p)
  -- normalize: drop ..
  if full:find("%.%.") then return nil end
  return full
end

local function scanImages()
  local out = {}
  local function walk(dir, rel)
    local d = unix.opendir(dir)
    if not d then return end
    while true do
      local name, kind = d:read()
      if not name then break end
      if name ~= "." and name ~= ".." and not name:match("^%.") then
        local full = path.join(dir, name)
        local relp = rel == "" and name or (rel .. "/" .. name)
        if kind == unix.DT_DIR then
          walk(full, relp)
        else
          if isImage(name) then out[#out+1] = relp end
        end
      end
    end
  end
  walk(ROOT, "")
  return out
end

-- ---------------------------------------------------------------------------
-- EXIF / mtime caching
-- ---------------------------------------------------------------------------
local function statFile(full)
  local st, err = unix.stat(full)
  if not st then return nil, err end
  -- mtim returns (sec, ns)
  local sec = st:mtim()
  return sec, st:size()
end

local function getTaken(relp)
  local full = path.join(ROOT, relp)
  local mtime, size = statFile(full)
  if not mtime then return nil end
  local rows = dbq("SELECT mtime,size,taken FROM file_meta WHERE path=?", relp)
  local r = rows[1]
  if r and r.mtime == mtime and r.size == size then
    return r.taken or mtime, mtime
  end
  -- (re)parse exif
  local taken = exif.dateTaken(full)
  dbexec("INSERT OR REPLACE INTO file_meta(path,mtime,size,taken) VALUES(?,?,?,?)",
         relp, mtime, size, taken)
  return taken or mtime, mtime
end

-- ---------------------------------------------------------------------------
-- Username cookie
-- ---------------------------------------------------------------------------
local function getUser(r)
  local u = GetCookie("picsort_user")
  if u and #u > 0 and #u <= 64 then return u end
  return nil
end

-- ---------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------
fm.setTemplate("index", [=[<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>picsort</title>
<link rel="stylesheet" href="/static/app.css">
</head><body>
<header><h1>picsort</h1><span id="who"></span><span id="stats"></span></header>
<main id="grid"></main>
<div id="lightbox" class="hidden">
  <div class="lb-img"><img id="lb-pic"></div>
  <div class="lb-bar">
    <span id="lb-name"></span>
    <span id="lb-avg"></span>
    <span id="lb-mine"></span>
    <button id="lb-close">✕</button>
  </div>
</div>
<dialog id="namedlg">
  <form method="dialog">
    <h2>Pick a username</h2>
    <p>Anyone on this LAN using the same name shares ratings. No password.</p>
    <input id="name" autofocus required minlength="1" maxlength="64" placeholder="e.g. alex">
    <button>Enter</button>
  </form>
</dialog>
<script src="/static/app.js"></script>
</body></html>]=])

fm.setRoute("/", fm.serveContent("index"))

-- serve embedded static assets (in the zip under /static/)
fm.setRoute("/static/*p", function(r)
  local data = LoadAsset("/static/"..r.params.p)
  if not data then return fm.serveError(404) end
  local ext = r.params.p:match("%.([^.]+)$") or ""
  local mime = ({css="text/css",js="application/javascript",
                 png="image/png",svg="image/svg+xml"})[ext] or "text/plain"
  return fm.serveResponse(200, { ContentType=mime,
                                  ["Cache-Control"]="public,max-age=300" }, data)
end)

fm.setRoute("/api/me", function(r)
  return fm.serveContent("json", { user = getUser(r) })
end)

fm.setRoute({"/api/login", method="POST"}, function(r)
  local name = (r.params.name or ""):gsub("^%s+",""):gsub("%s+$","")
  if #name == 0 or #name > 64 then return fm.serveError(400, "bad name") end
  SetCookie("picsort_user", name, { path="/", maxage=60*60*24*365, samesite="Lax" })
  return fm.serveContent("json", { ok=true, user=name })
end)

fm.setRoute({"/api/logout", method="POST"}, function(r)
  SetCookie("picsort_user", "", { path="/", maxage=0 })
  return fm.serveContent("json", { ok=true })
end)

-- list every image with ratings + EXIF taken-at
fm.setRoute("/api/images", function(r)
  local me = getUser(r)
  local files = scanImages()
  -- Build taken-at map (cached)
  local items = {}
  for _, p in ipairs(files) do
    local taken = getTaken(p)
    items[#items+1] = { path = p, taken = taken or 0 }
  end
  table.sort(items, function(a, b)
    if a.taken ~= b.taken then return a.taken < b.taken end
    return a.path < b.path
  end)
  -- Pull all ratings in one go
  local rmap = {}
  for row in db:nrows("SELECT path,username,score FROM ratings") do
    local list = rmap[row.path]
    if not list then list = {}; rmap[row.path] = list end
    list[#list+1] = { user = row.username, score = row.score }
  end
  for _, it in ipairs(items) do
    local rs = rmap[it.path] or {}
    local sum, n, mine = 0, 0, nil
    for _, x in ipairs(rs) do
      if x.score >= 1 and x.score <= 5 then
        sum = sum + x.score; n = n + 1
      end
      if me and x.user == me then mine = x.score end
    end
    it.scores = rs
    it.avg    = n > 0 and (sum / n) or nil
    it.count  = n
    it.mine   = mine
    -- count delete-votes (0)
    local del = 0
    for _, x in ipairs(rs) do if x.score == 0 then del = del + 1 end end
    it.deletes = del
  end
  return fm.serveContent("json", { images = items, you = me })
end)

fm.setRoute({"/api/rate", method="POST"}, function(r)
  local me = getUser(r)
  if not me then return fm.serveError(401, "no user") end
  local p     = r.params.path
  local score = tonumber(r.params.score)
  if not p or not score or score < 0 or score > 5 or score % 1 ~= 0 then
    return fm.serveError(400, "bad params")
  end
  -- validate that path is a real image inside ROOT
  local full = safeJoin(ROOT, p)
  if not full or not unix.stat(full) or not isImage(p) then
    return fm.serveError(404, "no such image")
  end
  dbexec("INSERT INTO ratings(path,username,score,updated) VALUES(?,?,?,?) "
      .."ON CONFLICT(path,username) DO UPDATE SET score=excluded.score,updated=excluded.updated",
      p, me, score, os.time())
  return fm.serveContent("json", { ok=true })
end)

fm.setRoute({"/api/unrate", method="POST"}, function(r)
  local me = getUser(r)
  if not me then return fm.serveError(401, "no user") end
  local p = r.params.path
  if not p then return fm.serveError(400) end
  dbexec("DELETE FROM ratings WHERE path=? AND username=?", p, me)
  return fm.serveContent("json", { ok=true })
end)

-- raw image bytes
fm.setRoute("/img/*p", function(r)
  local rel = r.params.p
  if not rel or rel:find("%.%.") or not isImage(rel) then
    return fm.serveError(404)
  end
  local full = path.join(ROOT, rel)
  local f = io.open(full, "rb")
  if not f then return fm.serveError(404) end
  local data = f:read("*a"); f:close()
  local ext = rel:match("%.([^.]+)$"):lower()
  local mime = ({jpg="image/jpeg",jpeg="image/jpeg",png="image/png",
                 gif="image/gif",webp="image/webp",heic="image/heic",
                 heif="image/heif",bmp="image/bmp",tif="image/tiff",
                 tiff="image/tiff"})[ext] or "application/octet-stream"
  return fm.serveResponse(200, { ContentType = mime,
                                  ["Cache-Control"] = "public,max-age=3600" }, data)
end)

-- ---------------------------------------------------------------------------
-- Boot banner: list LAN IPs prominently
-- ---------------------------------------------------------------------------
local function lanIPs()
  local ips, seen = {}, {}
  local f = io.popen("hostname -I 2>/dev/null || ipconfig getifaddr en0 2>/dev/null")
  if f then
    local line = f:read("*a") or ""
    f:close()
    for ip in line:gmatch("(%d+%.%d+%.%d+%.%d+)") do
      if not seen[ip] and ip ~= "127.0.0.1" and not ip:match("^169%.254") then
        seen[ip] = true; ips[#ips+1] = ip
      end
    end
  end
  return ips
end

local port = arg and tonumber(arg[1]) or 8080

local function banner()
  local ips = lanIPs()
  io.stderr:write("\n  picsort serving "..ROOT.."\n")
  io.stderr:write("  on port "..port.."\n")
  if #ips == 0 then
    io.stderr:write("  (no LAN IP detected; try http://localhost:"..port.."/)\n")
  else
    for _, ip in ipairs(ips) do
      io.stderr:write("    http://"..ip..":"..port.."/\n")
    end
  end
  io.stderr:write("\n")
end

function OnServerStart() banner() end

-- Bind only on 0.0.0.0:port (overrides default 127.0.0.1:8080).
fm.run{ port = port, addr = {"0.0.0.0"} }

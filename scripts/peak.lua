-- peak.lua  v1.7.0  - clip guard: one static NEGATIVE trim per file so the output stays <= target (-1 dBTP).
-- No limiter, no compression, no positive gain: the dynamics stay the recording's.
-- Meter: a true-peak meter (ebur128, 4x oversampled) at the end of the audio chain measures what each file sends to the
--   output on its path (3D renderer, 3D stereo, stereo fold, plain stereo). The peak is stored per file; from the next
--   open the trim is min(0, target - true peak), set before the first sample.
-- First watch (nothing measured yet): a safe default per path (renderer -13.5, fold -8.5, 3D stereo -6.0, stereo 0 dB),
--   from measured worst cases. Measurement pass (auto_measure, default yes): when a file opens unmeasured, a fast
--   headless pass (below-normal priority) measures the whole file on the path you hear while you play or pause; when
--   it completes the measured trim is applied at once (0.2 s ramp, no position change) and stored. On demand: Alt+P,
--   the card's "Measure now", script-message peak-measure-now. Pre-roll (preroll_max minutes, default 0 = off): a
--   file up to that length with no measurement holds its start, like a stream buffering, until it is measured, so the
--   exact trim holds from the first sample (a song waits about 3 s); pressing play skips the wait. Measure a folder ahead: the card's "Measure folder" (script-message
--   peak-analyze-folder [dir]) or `mpv --idle=once --script-opts=peak-analyze=<folder>` measures every media file in a
--   folder in fast headless runs (one at a time, waiting while a file plays).
-- Options (script-opts/peak.conf or script-opts-append=peak-<key>=<value>): enabled (yes), target (-1), renderer_default,
--   fold_default, stereo3d_default, stereo_default, store_dir ("" = ~~/cache/measure | media = a .mpv-measure folder
--   beside each media file | a folder path), lookahead (minutes measured at file start before 3 s of play; 0 = off),
--   store_max (3000), house (a uniform trim every path gets at least, 0), auto_measure (yes), preroll_max (0), preroll_wait (20 s).
-- Key Alt+p / script-message set-peak yes|no. State user-data/peak; badge "PK -x.x" on the card.

local mp = require "mp"
local utils = require "mp.utils"
local options = require "mp.options"
local opts = { auto_measure = true, preroll_max = 0, preroll_wait = 20, progress_file = "", precache = false, store_dir = "", analyze = "", lookahead = 0, enabled = true, target = -1.0, renderer_default = -13.5, fold_default = -8.5, stereo3d_default = -6.0, stereo_default = 0.0, store_max = 3000, house = 0.0, roots = "" }
options.read_options(opts, "peak")
local LABEL = "@peakmeter"
local base_gain = mp.get_property_number("volume-gain", 0)
local cur = { key = nil, file = nil, entry = nil, kind = nil, graph = nil, tp = {}, played = {}, trim = nil, source = nil }
local mjob = nil   -- v1.3.0: the running measurement pass { key, id, pct, t0, pfile }
local pre = nil    -- v1.4.0: pre-roll hold { key, was_paused, unpausing } while a short file's start waits for its pass

-- store ------------------------------------------------------------------------------------------------------------
local dir_ok = nil
local function config_dir() return mp.command_native({ "expand-path", "~~/cache/measure" }) end
local function media_dir()   -- v1.2.0 store_dir=media: a .mpv-measure folder beside the media file (nil for a stream)
    local f = cur and cur.file
    if not f or f:find("^%a[%w+.-]*://") then return nil end
    local d = utils.split_path(f)
    return utils.join_path(d, ".mpv-measure")
end
-- file under one of the roots (option roots, ";"-separated, the nearest = longest match), else ~~/cache/measure
local function root_dir(f)
    if not f or f:find("^%a[%w+.-]*://") then return nil end
    local lf = f:lower():gsub("\\", "/")
    local best = nil
    for r in tostring(opts.roots or ""):gmatch("[^;]+") do
        local lr = r:lower():gsub("\\", "/"):gsub("/+$", "")
        if lr ~= "" and lf:sub(1, #lr + 1) == lr .. "/" and (not best or #lr > #best.l) then best = { l = lr, r = (r:gsub("[/\\]+$", "")) } end
    end
    return best and utils.join_path(best.r, ".mpv-measure") or nil
end
local function store_dir(which)
    -- v1.2.0 store_dir: "" = ~~/cache/measure (default), "media" = beside the media file, "root" = the media root's
    -- index (v1.7.0), else a folder path
    local sd = tostring(opts.store_dir or "")
    local d
    if which == "config" or sd == "" then d = config_dir()
    elseif sd == "media" then d = media_dir() or config_dir()
    elseif sd == "root" then d = root_dir(cur and cur.file) or config_dir()
    else d = mp.command_native({ "expand-path", sd }) end
    if dir_ok ~= d and not utils.file_info(d) then
        -- cmd's mkdir needs backslashes (forward slashes: "The syntax of the command is incorrect"); it makes parents too
        mp.command_native({ name = "subprocess", args = { "cmd", "/c", "mkdir", (d:gsub("/", "\\")) }, playback_only = false,
            capture_stdout = true, capture_stderr = true })
        if d:find("[/\\]%.mpv%-measure$") then   -- the index folder is hidden (only that folder is touched)
            mp.command_native({ name = "subprocess", args = { "attrib", "+h", (d:gsub("/", "\\")) }, playback_only = false,
                capture_stdout = true, capture_stderr = true })
        end
    end
    dir_ok = d
    return d
end
local function hash(s, mul, seed)   -- 32-bit multiplicative string hash in plain arithmetic (exact in doubles)
    local h = seed
    for i = 1, #s do h = (h * mul + s:byte(i)) % 4294967296 end
    return string.format("%08x", h)
end
-- v1.7.0: content key for store_dir=root: "c" + size + two hashes over 64 KB at the start, middle and end of the file,
-- so an entry survives a move (D: -> E:) or a rename. The path key (v1.0) stays the fallback for the old store.
local CHUNK = 65536
local function content_key(path, size)
    local f = io.open(path, "rb")
    if not f then return nil end
    local parts = {}
    for _, off in ipairs({ 0, math.max(0, math.floor(size / 2) - CHUNK / 2), math.max(0, size - CHUNK) }) do
        f:seek("set", off); parts[#parts + 1] = f:read(CHUNK) or ""
    end
    f:close()
    local b = table.concat(parts)
    return string.format("c%x_", size) .. hash(b, 33, 5381) .. hash(b, 131, 7)
end
local function file_key(path)
    if not path or path:find("^%a[%w+.-]*://") then return nil end
    local info = utils.file_info(path)
    if not info or not info.is_file then return nil end
    local id = path:lower():gsub("\\", "/") .. "|" .. tostring(info.size) .. "|" .. tostring(math.floor(info.mtime or 0))
    local pkey = hash(id, 33, 5381) .. hash(id, 131, 7)
    if opts.store_dir == "root" then return content_key(path, info.size) or pkey, info, pkey end
    return pkey, info, pkey
end
local function store_read(key)
    local f = io.open(utils.join_path(store_dir(key == "_output" and "config" or nil), key .. ".json"), "rb")
    -- store_dir=media: a measurement made before (in the config cache) still counts
    if not f and opts.store_dir == "media" then f = io.open(utils.join_path(store_dir("config"), key .. ".json"), "rb") end
    -- v1.7.0 store_dir=root: an entry of the old path-keyed store still counts (read only)
    if not f and opts.store_dir == "root" and cur and key == cur.key and cur.pkey then
        f = io.open(utils.join_path(store_dir("config"), cur.pkey .. ".json"), "rb")
    end
    if not f then return nil end
    local s = f:read("*a"); f:close()
    return utils.parse_json(s)
end
local function store_prune(dir)
    local files = utils.readdir(dir, "files") or {}
    if #files <= opts.store_max then return end
    local list = {}
    for _, n in ipairs(files) do
        if n:match("%.json$") then local i = utils.file_info(utils.join_path(dir, n)); list[#list + 1] = { n = n, t = i and i.mtime or 0 } end
    end
    table.sort(list, function(a, b) return a.t < b.t end)
    for i = 1, #list - math.floor(opts.store_max * 0.9) do os.remove(utils.join_path(dir, list[i].n)) end
end
local function store_write(key, e)
    local dir = store_dir(key == "_output" and "config" or nil)
    local p = utils.join_path(dir, key .. ".json")
    local f = io.open(p .. ".tmp", "wb")
    if not f then return end
    f:write(utils.format_json(e)); f:close()
    os.remove(p); os.rename(p .. ".tmp", p)
    store_prune(dir)
end

-- path kind, meter graph, trim ----------------------------------------------------------------------------------------
local function db(lin) return (lin and lin > 0) and 20 * math.log10(lin) or nil end
local function kind_now()
    local t = mp.get_property_native("current-tracks/audio")
    local b = mp.get_property_native("user-data/binaural") or {}
    local ob = mp.get_property_native("user-data/objects") or {}
    if not t and not ob.owns then return nil end
    local n = t and tonumber(t["demux-channel-count"]) or 8
    if b.active or ob.owns then return "renderer", n, t end
    if b.stereo and b.stereo.active then return "stereo3d", n, t end
    if n > 2 then return "fold", n, t end
    return "stereo", n, t
end
-- The fold inside the meter: swresample to stereo in float with rematrix_maxval=1000, which is mpv's own fold (mpv
-- folds with swresample, audio-normalize-downmix=no -> rematrix_maxval 1000: C and surrounds 0.707, LFE dropped). It
-- takes any input layout and passes stereo through, so one graph serves the fold, 3D audio and stereo paths (no
-- switch, no re-init when binaural.lua inserts its renderer). Only when the output is stereo: a multichannel endpoint
-- gets the channels unfolded (then the meter sees the channels, never stored as a fold peak, see poll).
-- The output's channel count: live from audio-out-params, else the last one seen (store entry "_output"), so the meter
-- is in place before the first sample (a filter change mid-stream re-inits the chain: a test lost 0.12 s that way).
local out_ch = nil
local FOLD = "aformat=sample_fmts=flt|fltp,aresample=out_chlayout=stereo:rematrix_maxval=1000,"
local function note_output(aop)
    -- the device's count shows only for a multichannel source with neither our fold nor the 3D renderer in the chain;
    -- noted here (before the meter decision), not in a separate observer: observer order is not fixed (a test race)
    local c = tonumber(aop["channel-count"])
    local t = mp.get_property_native("current-tracks/audio")
    local b = mp.get_property_native("user-data/binaural") or {}
    local n = t and tonumber(t["demux-channel-count"]) or 0
    if c and c ~= out_ch and n > 2 and not b.active and not (cur.graph or ""):find("out_chlayout", 1, true) then
        out_ch = c; store_write("_output", { v = 1, channels = c, updated = os.time() })
    end
end
local function meter_graph()
    local aop = mp.get_property_native("audio-out-params") or {}
    note_output(aop)
    -- while our fold is in the chain the output is stereo because of it: then only the remembered device count counts
    local folded = cur.graph and cur.graph:find("out_chlayout", 1, true)
    local c = folded and out_ch or (aop["channel-count"] or out_ch)
    local pre = (c == 2) and FOLD or ""
    return "lavfi=[" .. pre .. "ebur128=peak=true:metadata=1:framelog=quiet]"
end
local function default_trim(kind)
    local h = math.min(0, tonumber(opts.house) or 0)
    if kind == "renderer" then return math.min(h, opts.renderer_default) end
    if kind == "fold" then return math.min(h, opts.fold_default) end
    if kind == "stereo3d" then return math.min(h, tonumber(opts.stereo3d_default) or -6.0) end
    return math.min(h, opts.stereo_default)
end
local function trim_for(kind)
    local pk = cur.entry and cur.entry.peak and cur.entry.peak[kind]
    local d = default_trim(kind)
    if pk and pk.tp then
        local need = math.min(0, tonumber(opts.house) or 0, opts.target - pk.tp)
        if pk.complete then return need, "cache", pk.tp, true end
        if need < d then return need, "seen", pk.tp, false end
    end
    return d, "default", pk and pk.tp or nil, false
end
-- v1.5.0 (audit F6): user-data is set only when the value changed (was: every 0.5 s with identical values)
local last_pub = {}
local function set_changed(name, v)
    local j = utils.format_json(v)
    if last_pub[name] == j then return end
    last_pub[name] = j
    mp.set_property_native(name, v)
end
local function publish()
    local tp = cur.kind and cur.tp[cur.kind]
    -- v1.1.0: background work for the panel's activity line: measuring while this path has no complete measurement
    local busy = (opts.enabled and cur.kind ~= nil and cur.key ~= nil and not cur.complete) or false
    local pct, detail = nil, "this file's peak; exact trim from the next open"
    if mjob and mjob.key == cur.key then   -- v1.3.0: a measurement pass runs for this file: its progress
        busy = true; pct = mjob.pct or 0; detail = "this file's peak; applied when done"
    elseif busy then
        local dur = cur.duration or mp.get_property_number("duration")
        if dur and dur > 0 then pct = math.min(99, math.floor(100 * (cur.played[cur.kind] or 0) / dur)) end
    end
    local word = "measuring"
    if pre and pre.key == cur.key then word = "buffering \194\183 measuring"; detail = "starts when measured; press play to start now" end
    set_changed("user-data/activity/peak", { busy = busy, word = word,
        detail = busy and detail or "",
        pct = pct, mark = (opts.enabled and cur.trim and cur.trim < 0) and string.format("PK %+.1f", cur.trim) or "" })
    set_changed("user-data/peak", { enabled = opts.enabled, kind = cur.kind, trim = cur.trim, source = cur.source,
        tp_seen = tp, tp_cached = cur.tp_cached, complete = cur.complete or false, cached = cur.key ~= nil })
end
-- v1.3.0: a trim change during playback (a measurement pass completed) moves the gain in 10 steps over 0.2 s, no jump
local ramp_t = nil
local function set_gain(v, ramp)
    if ramp_t then ramp_t:kill(); ramp_t = nil end
    local from = mp.get_property_number("volume-gain", v)
    if not ramp or math.abs(from - v) < 0.05 then mp.set_property_number("volume-gain", v); return end
    local i = 0
    ramp_t = mp.add_periodic_timer(0.02, function()
        i = i + 1
        mp.set_property_number("volume-gain", from + (v - from) * i / 10)
        if i >= 10 then ramp_t:kill(); ramp_t = nil; mp.msg.verbose(string.format("ramp done: %.2f -> %.2f dB", from, v)) end
    end)
end
local function apply(ramp)
    if not opts.enabled or not cur.kind then
        set_gain(base_gain, false); cur.trim = nil; cur.source = nil; publish(); return
    end
    cur.trim, cur.source, cur.tp_cached, cur.complete = trim_for(cur.kind)
    set_gain(base_gain + cur.trim, ramp)
    publish()
end
local function kind_complete(kind)   -- v1.6.0 (F7); a measuring child (precache) always meters
    if opts.precache then return false end
    local pk = cur.entry and cur.entry.peak and cur.entry.peak[kind]
    return (pk and pk.complete) == true
end
local function present_last()
    local af = mp.get_property_native("af") or {}
    return #af > 0 and af[#af].label == "peakmeter"
end
local function update()
    local kind, n, t = kind_now()
    -- v1.5.0 (pipeline audit F5): between on_preloaded and file-loaded mpv reports no current track yet; keep the meter
    -- placed before the audio output opened instead of removing and re-adding it
    if not kind and cur.preloading then return end
    -- v1.6.0 (audit F7): no meter for a path whose measurement is complete in the cache; one already running this file
    -- stays (removing it would re-init the audio chain mid-play)
    local g = nil
    if opts.enabled and kind then
        if kind_complete(kind) then
            note_output(mp.get_property_native("audio-out-params") or {})
            g = present_last() and cur.graph or nil
        else g = meter_graph() end
    end
    local placed = present_last()
    if g ~= cur.graph or (g ~= nil) ~= placed then
        local af = mp.get_property_native("af") or {}
        for _, f in ipairs(af) do if f.label == "peakmeter" then mp.commandv("af", "remove", LABEL); break end end
        if g then mp.commandv("af", "add", LABEL .. ":" .. g) end
        cur.graph = g
    end
    if kind ~= cur.kind then
        cur.kind = kind; cur.kind_since = mp.get_property_number("time-pos") or 0
        -- precache: the path settled after the start (untimed: the 3D chain comes in seconds of audio late) -> measure
        -- the whole file again on this path from 0:00
        if opts.precache and cur.kind_since > 0.5 then
            cur.tp[kind] = nil; cur.kind_since = 0; mp.commandv("seek", "0", "absolute+exact")
            mp.msg.info("PRECACHE path " .. kind .. " settled late: from 0:00 again")
        end
        apply()
    end
end

-- live reading, accumulation, saving ---------------------------------------------------------------------------------
local last_t = nil
local function poll()
    if not cur.kind or not cur.graph then return end
    local md = mp.get_property_native("af-metadata/peakmeter")
    local tp = md and db(tonumber(md["lavfi.r128.true_peak"]))
    -- a fold meter without the fold inside it (multichannel endpoint, unknown layout, output not open yet) sees the
    -- channels before mpv's fold: not a fold peak, never stored (the default trim stays)
    local valid = cur.kind ~= "fold" or cur.graph:find("out_chlayout", 1, true)
    if tp and valid then cur.tp[cur.kind] = math.max(cur.tp[cur.kind] or -200, tp) end
    if not valid then last_t = mp.get_property_number("time-pos"); return end
    cur.duration = mp.get_property_number("duration") or cur.duration   -- end-file no longer has it
    local pos = mp.get_property_number("time-pos")
    if pos and last_t and not mp.get_property_bool("pause") and pos > last_t and pos - last_t < 2 then
        cur.played[cur.kind] = (cur.played[cur.kind] or 0) + (pos - last_t)
    end
    last_t = pos
    publish()
    -- v1.3.0: a measurement pass child reports its progress to the player through a small file (every 0.5 s)
    if opts.precache and opts.progress_file ~= "" and pos and cur.duration and cur.duration > 0 then
        local now = mp.get_time()
        if not cur.pw or now - cur.pw >= 0.5 then
            cur.pw = now
            local f = io.open(opts.progress_file, "wb")
            if f then f:write(string.format("%d", math.floor(100 * pos / cur.duration))); f:close() end
        end
    end
end
local function save()
    if not cur.key then return end
    local e = store_read(cur.key) or { v = 1 }
    e.v = 1; e.path = cur.file; e.size = cur.info.size; e.mtime = cur.info.mtime; e.updated = os.time()
    e.peak = e.peak or {}
    local dur = cur.duration or mp.get_property_number("duration")
    local changed = false
    for kind, tp in pairs(cur.tp) do
        local o = e.peak[kind] or {}
        local played = cur.played[kind] or 0
        -- complete = (nearly) the whole duration went through the meter on this path: >= 97 % or all but 2 s
        local complete = (o.complete == true) or (dur and dur > 0 and (played >= 0.97 * dur or dur - played <= 2)) or false
        local ntp = math.max(o.tp or -200, tp)
        if ntp ~= o.tp or complete ~= o.complete or played > (o.played or 0) then changed = true end
        e.peak[kind] = { tp = math.floor(ntp * 100 + 0.5) / 100, complete = complete, played = math.max(o.played or 0, math.floor(played)),
            duration = dur and math.floor(dur) or o.duration }
    end
    if changed then store_write(cur.key, e) end
    cur.duration = dur
end
mp.register_event("start-file", function()
    save()
    local path = mp.get_property("path")
    if path and not path:find("^%a[%w+.-]*://") and not path:match("^%a:") and not path:match("^[/\\]") then
        path = utils.join_path(mp.get_property("working-directory") or "", path)
    end
    local key, info, pkey = file_key(path)
    cur = { key = key, pkey = pkey, info = info, file = path, entry = nil, kind = nil, graph = cur.graph, tp = {}, played = {} }
    cur.entry = key and store_read(key) or nil   -- v1.2.0: after cur.file is set (store_dir=media reads beside it)
    last_t = nil
end)
-- before the first audio (track list known, nothing decoded yet): the most conservative trim the file's channel count
-- can need; the exact path (3D audio or fold) is decided ~0.2-0.4 s later (binaural.lua), then the trim follows it.
mp.add_hook("on_preloaded", 50, function()
    cur.preloading = true
    if not opts.enabled then return end
    local n, sel = 2, nil
    for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
        if tr.type == "audio" and (tr.selected or not sel) then sel = tr; n = tonumber(tr["demux-channel-count"]) or n; if tr.selected then break end end
    end
    local kinds = (n > 2) and { "renderer", "fold" } or { "stereo", "stereo3d" }
    local w = 0
    for _, k in ipairs(kinds) do w = math.min(w, (trim_for(k))) end
    mp.set_property_number("volume-gain", base_gain + w)
    -- the meter for the likely path, before decoding starts (no re-init mid-stream); binaural.lua may switch the path
    -- a moment later (its own insertion re-inits the chain anyway), update() then follows
    -- v1.6.0 (audit F7): binaural.lua v1.7.0 decides its path at on_preloaded 40 (before this hook); when its state is for
    -- this track (same channel count) the path is known now, else both candidates stay
    local b = mp.get_property_native("user-data/binaural") or {}
    if tonumber(b.channels) == n then
        if b.active then kinds = { "renderer" }
        elseif b.stereo and b.stereo.active then kinds = { "stereo3d" }
        elseif n == 2 then kinds = { "stereo" } end   -- multichannel without 3D audio: fold, or renderer if objects attaches
    end
    -- every likely path already measured -> no meter (a leftover from the previous file goes now,
    -- before the audio output opens)
    local all_done = true
    for _, k in ipairs(kinds) do if not kind_complete(k) then all_done = false end end
    if all_done then
        for _, f in ipairs(mp.get_property_native("af") or {}) do if f.label == "peakmeter" then mp.commandv("af", "remove", LABEL); break end end
        cur.graph = nil
        mp.msg.verbose("meter skipped: " .. table.concat(kinds, "/") .. " measured")
        return
    end
    local g = meter_graph()
    if g ~= cur.graph or not present_last() then
        for _, f in ipairs(mp.get_property_native("af") or {}) do if f.label == "peakmeter" then mp.commandv("af", "remove", LABEL); break end end
        mp.commandv("af", "add", LABEL .. ":" .. g)
        cur.graph = g
    end
end)
do local e = store_read("_output"); out_ch = e and tonumber(e.channels) or nil end
mp.register_event("end-file", function() save() end)
mp.register_event("file-loaded", function() cur.preloading = false; update() end)
mp.register_event("shutdown", function() save(); mp.set_property_number("volume-gain", base_gain) end)
for _, p in ipairs({ "current-tracks/audio", "user-data/binaural", "user-data/objects", "audio-out-params", "af" }) do
    mp.observe_property(p, "native", function() update() end)
end
mp.add_periodic_timer(opts.precache and 0.05 or 0.5, poll)
-- v1.2.0 precache: a headless measuring run (see header)
if opts.precache then
    mp.observe_property("eof-reached", "bool", function(_, v)
        if not v then return end
        poll()
        local dur = mp.get_property_number("duration")
        local tp = cur.kind and cur.tp[cur.kind]
        local pos = mp.get_property_number("time-pos")
        local whole = tp and dur and dur > 0 and (cur.kind_since or 0) <= 1.0 and pos and pos >= dur - 2
        if whole then cur.played[cur.kind] = dur; cur.duration = dur end
        save()
        mp.msg.info(string.format("PRECACHE key=%s kind=%s tp=%s whole=%s dur=%s", tostring(cur.key), tostring(cur.kind),
            tp and string.format("%.2f", tp) or "nil", tostring(whole or false), tostring(dur)))
        mp.commandv("quit", whole and "0" or "5")
    end)
end
mp.add_periodic_timer(60, save)
local function set_enabled(v, say)
    opts.enabled = v; cur.kind = nil; update(); apply()
    if say then
        mp.osd_message("Peak trim: " .. (v and ("on" .. (cur.trim and string.format(" (%+.1f dB, %s)", cur.trim, cur.source) or "")) or "off"), 2)
    end
end
mp.add_key_binding("Alt+p", "peak-toggle", function() set_enabled(not opts.enabled, true) end)
mp.register_script_message("set-peak", function(v) v = tostring(v or ""):lower(); set_enabled(v == "yes" or v == "on" or v == "1" or v == "true", true) end)
publish()

-- v1.2.0 Measure folder / CLI analyze / look-ahead: headless children of this mpv in precache mode -----------------------
local MEDIA = {}
for e in ("mp3 m4a aac flac wav opus ogg wma ac3 eac3 dts thd mka mkv mp4 webm m4v mov avi ts m2ts wmv"):gmatch("%S+") do MEDIA[e] = true end
local function mpv_exe()
    local e = mp.command_native({ "expand-path", "~~exe_dir/mpv.exe" })
    if e and utils.file_info(e) then return e end
    return "mpv"
end
local function child_args(path, extra)
    local b = mp.get_property_native("user-data/binaural") or {}
    local a = { mpv_exe(), "--vid=no", "--ao=null", "--ao-null-untimed=yes", "--audio-channels=stereo", "--keep-open=yes",
        "--no-terminal", "--idle=no", "--force-window=no", "--save-position-on-quit=no", "--script-opts-append=objects-enabled=no",
        "--script-opts-append=peak-precache=yes", "--script-opts-append=peak-analyze=", "--script-opts-append=peak-lookahead=0",
        "--priority=belownormal" }
    -- v1.3.0: the child uses this player's config folder (its scripts, options and measurement store), also when mpv
    -- was started with --config-dir (found by the release test: the child stored into the default folder)
    local cd = mp.command_native({ "expand-path", "~~/" })
    if cd and cd ~= "" then a[#a + 1] = "--config-dir=" .. cd end
    -- the 3D gate in the child sees the null device: hand it this player's device when that is a listed headphone
    if b.headphones and b.device and b.device ~= "" then a[#a + 1] = "--script-opts-append=binaural-device=" .. b.device end
    if (opts.store_dir or "") ~= "" then a[#a + 1] = "--script-opts-append=peak-store_dir=" .. opts.store_dir end
    if (opts.roots or "") ~= "" then a[#a + 1] = "--script-opts-append=peak-roots=" .. opts.roots end   -- v1.7.0: same index
    for _, x in ipairs(extra or {}) do a[#a + 1] = x end
    a[#a + 1] = path
    return a
end
local fjob = nil
local function complete_for(f, key)   -- the child's entry, read where the child stores it (media: beside that file)
    if not key then return false end
    local e
    if opts.store_dir == "media" then
        local fh = io.open(utils.join_path(utils.join_path(utils.split_path(f), ".mpv-measure"), key .. ".json"), "rb")
        if fh then e = utils.parse_json(fh:read("*a")); fh:close() end
    else e = store_read(key) end
    for _, v in pairs(e and e.peak or {}) do if v.complete then return true end end
    return false
end
local function folder_activity(busy, detail, pct)
    mp.set_property_native("user-data/activity/peak_folder", { busy = busy, word = "measuring folder", detail = detail or "", pct = pct })
end
local function measure_folder(dir, quit_after)
    if fjob then mp.osd_message("Measure folder: already running", 2); return end
    if not dir or dir == "" then
        local p = mp.get_property("path")
        dir = p and not p:find("^%a[%w+.-]*://") and utils.split_path(p) or nil
    end
    if not dir then mp.osd_message("Measure folder: no folder (open a local file first)", 3); if quit_after then mp.commandv("quit", "2") end; return end
    local list = {}
    for _, n in ipairs(utils.readdir(dir, "files") or {}) do
        local ext = n:match("%.([%w]+)$")
        if ext and MEDIA[ext:lower()] then list[#list + 1] = utils.join_path(dir, n) end
    end
    table.sort(list)
    fjob = { dir = dir, list = list, i = 0, ok = 0 }
    mp.msg.info(string.format("Measure folder: %d media files in %s", #list, dir))
    local function step()
        if not fjob then return end
        local playing = mp.get_property("path") ~= nil and not mp.get_property_bool("pause") and not mp.get_property_bool("idle-active")
        if playing and not quit_after then
            folder_activity(true, string.format("%d/%d, waiting while a file plays", fjob.i, #fjob.list)); mp.add_timeout(2, step); return
        end
        fjob.i = fjob.i + 1
        if fjob.i > #fjob.list then
            local m = string.format("Measure folder: %d of %d files measured", fjob.ok, #fjob.list)
            mp.msg.info(m .. " in " .. fjob.dir); mp.osd_message(m, 3); folder_activity(false, "")
            fjob = nil
            if quit_after then mp.commandv("quit", "0") end
            return
        end
        folder_activity(true, string.format("%d/%d", fjob.i, #fjob.list), math.floor(100 * (fjob.i - 1) / math.max(1, #fjob.list)))
        local f = fjob.list[fjob.i]
        local key = file_key(f)
        local stored_at, finished, wd = nil, false, nil
        local id = mp.command_native_async({ name = "subprocess", args = child_args(f), playback_only = false,
            capture_stdout = true, capture_stderr = true }, function(ok, r)
            finished = true; if wd then wd:kill() end
            if complete_for(f, key) then fjob.ok = fjob.ok + 1 end
            step()
        end)
        -- a child that stored its result but does not exit (seen once in a test) is ended after 10 s
        wd = mp.add_periodic_timer(2, function()
            if finished then return end
            if not stored_at and complete_for(f, key) then stored_at = mp.get_time() end
            if stored_at and mp.get_time() - stored_at > 10 then mp.msg.info("Measure folder: child stalled after storing, ended"); mp.abort_async_command(id) end
        end)
    end
    step()
end
mp.register_script_message("peak-analyze-folder", function(d) measure_folder(d, false) end)
if not opts.precache and (opts.analyze or "") ~= "" then mp.add_timeout(0.2, function() measure_folder(opts.analyze, true) end) end
mp.register_event("file-loaded", function()
    local n = tonumber(opts.lookahead) or 0
    if opts.precache or n <= 0 or not cur.key or not opts.enabled then return end
    for _, v in pairs(cur.entry and cur.entry.peak or {}) do if v.complete then return end end   -- already measured
    local key, t0 = cur.key, mp.get_time()
    mp.command_native_async({ name = "subprocess", args = child_args(cur.file, { "--length=" .. tostring(n * 60) }), playback_only = false,
        capture_stdout = true, capture_stderr = true }, function()
        if cur.key ~= key then return end
        local pos = mp.get_property_number("time-pos") or 0
        local e = store_read(key)
        if e and pos <= 3 then
            cur.entry = e; apply()
            mp.msg.info(string.format("look-ahead: opening %d min measured in %.1f s, trim %s (%s)", n, mp.get_time() - t0, tostring(cur.trim), tostring(cur.source)))
        else
            mp.msg.info(string.format("look-ahead: done at %.1f s of playback - counts from the next open", pos))
        end
    end)
end)

-- v1.3.0 measurement pass: the whole file measured in a fast headless child (precache mode: the path this player
-- plays, below-normal priority) while playback goes on with the first-watch trim; when it completes, the measured trim
-- is applied at once (0.2 s ramp, no position change) and the entry is stored. Auto when a file opens with no complete
-- measurement (option auto_measure, default yes); on demand: Alt+P, script-message peak-measure-now (card "Measure
-- now"). One pass at a time: a new file or a new request ends the running one; quitting ends it too.
local function pass_stop()
    if not mjob then return end
    local j = mjob; mjob = nil
    if j.wd then j.wd:kill() end
    if not j.done then mp.abort_async_command(j.id) end
    os.remove(j.pfile)
    publish()
end
-- v1.4.0 pre-roll: like a stream buffering, a short unmeasured file (duration <= preroll_max minutes) holds its start
-- paused while the pass measures the whole file; the measured static trim is set before the first sample, then it
-- plays. Pressing play skips the wait (the pass goes on and applies with the ramp). preroll_wait (s) caps the hold.
local function preroll_end(start)
    if not pre then return end
    local p = pre; pre = nil
    if p.timer then p.timer:kill() end
    mp.set_property_native("user-data/start_hold/peak", false)
    -- another script's start hold (aspect-rtx clean start) still running: that script starts playback when it is done
    local other = false
    for _, v in pairs(mp.get_property_native("user-data/start_hold") or {}) do if v == true then other = true end end
    if start and not p.was_paused and not other then mp.set_property_bool("pause", false) end
    publish()
end
local function measure_now(manual)
    if opts.precache or not cur.key or not cur.file then
        if manual then mp.osd_message("Measure now: local files only", 2) end; return
    end
    -- for this file goes on; a press only shows its progress, an auto start does nothing
    if mjob and not mjob.done and mjob.key == cur.key then
        if manual then mp.osd_message(string.format("Measuring\226\128\166 %d%%", mjob.pct or 0), 2) end
        mp.msg.info(string.format("measure now: pass already running (%d%%), kept", mjob.pct or 0))
        return
    end
    pass_stop()
    local key, t0 = cur.key, mp.get_time()
    local pfile = utils.join_path(store_dir("config"), string.format("_progress_%d.txt", utils.getpid()))
    os.remove(pfile)
    local j = { key = key, pct = 0, t0 = t0, pfile = pfile }
    mjob = j
    local extra = { "--script-opts-append=peak-progress_file=" .. pfile }
    -- a re-measure keeps the higher of the stored and the new peak (the store never lowers a peak)
    j.id = mp.command_native_async({ name = "subprocess", args = child_args(cur.file, extra), playback_only = false,
        capture_stdout = true, capture_stderr = true }, function(ok, r)
        j.done = true
        if mjob ~= j then return end            -- stopped, or another file / pass took over
        pass_stop()
        local e = (cur.key == key) and store_read(key) or nil
        local pk = e and e.peak and cur.kind and e.peak[cur.kind]
        local pr = pre ~= nil and pre.key == key           -- still holding the start: set the trim, no ramp, then play
        if pk and pk.complete then
            local old = cur.trim
            cur.entry = e; apply(not pr)
            if pr then mp.msg.info(string.format("pre-roll: measured in %.1f s, playing", mp.get_time() - t0)) end
            mp.msg.info(string.format("measure pass: %s tp %.2f dBTP in %.1f s, trim %s -> %s (%s)", cur.kind, pk.tp,
                mp.get_time() - t0, tostring(old), tostring(cur.trim), tostring(cur.source)))
            if manual then mp.osd_message(string.format("Peak measured: %+.1f dBTP, trim %+.1f dB", pk.tp, cur.trim), 3) end
        else
            mp.msg.info(string.format("measure pass: no complete result for path %s (rc %s)", tostring(cur.kind),
                tostring(r and r.status)))
            if manual then mp.osd_message("Measure now: no result for this path", 3) end
        end
        if pr then preroll_end(true) end
    end)
    j.wd = mp.add_periodic_timer(0.5, function()
        local f = io.open(pfile, "rb")
        if f then local v = tonumber(f:read("*a")); f:close(); if v then j.pct = math.max(0, math.min(99, v)) end end
        if mjob == j then publish() end
    end)
    mp.msg.info("measure pass started" .. (manual and " (manual)" or " (auto)"))
    if manual then mp.osd_message("Measuring this file (applied when done)", 2) end
end
mp.add_key_binding("Alt+P", "peak-measure-now", function() measure_now(true) end)
mp.register_script_message("peak-measure-now", function() measure_now(true) end)
mp.register_event("start-file", function() preroll_end(true); pass_stop() end)   -- a held start never carries its pause over
mp.register_event("shutdown", function() pass_stop() end)
mp.observe_property("pause", "bool", function(_, v)
    if pre and v == false then mp.msg.info("pre-roll skipped (play pressed): the trim follows when the pass completes"); preroll_end(false) end
end)
mp.add_hook("on_preloaded", 60, function()
    local mx = tonumber(opts.preroll_max) or 0
    if opts.precache or mx <= 0 or not opts.auto_measure or not opts.enabled or not cur.key then return end
    local dur = mp.get_property_number("duration")
    if not dur or dur <= 0 or dur > mx * 60 then return end
    for _, v in pairs(cur.entry and cur.entry.peak or {}) do if v.complete then return end end   -- measured before
    -- paused by the user, not by another script's start hold (shared flags user-data/start_hold/<script>)
    local was = mp.get_property_bool("pause") and not (mp.get_property_native("user-data/start_hold") or {}).aspect_rtx
    -- the pass itself starts from file-loaded (+1 s, below), once binaural.lua has settled the path it measures
    pre = { key = cur.key, was_paused = was }
    mp.set_property_native("user-data/start_hold/peak", true)
    mp.set_property_bool("pause", true)
    pre.timer = mp.add_timeout(tonumber(opts.preroll_wait) or 20, function()
        mp.msg.info("pre-roll: wait cap reached, playing; the trim follows when the pass completes"); preroll_end(true)
    end)
    mp.msg.info(string.format("pre-roll: holding the start (%.1f min file)", dur / 60))
    publish()
end)
mp.register_event("file-loaded", function()
    if opts.precache or not opts.auto_measure or not opts.enabled or not cur.key then return end
    local key = cur.key
    -- 1 s in, the path is settled (binaural decides ~0.2-0.4 s after the start): measured on this path already -> no pass
    mp.add_timeout(1.0, function()
        if cur.key ~= key or mjob then return end
        local pk = cur.kind and cur.entry and cur.entry.peak and cur.entry.peak[cur.kind]
        if pk and pk.complete then return end
        measure_now(false)
    end)
end)

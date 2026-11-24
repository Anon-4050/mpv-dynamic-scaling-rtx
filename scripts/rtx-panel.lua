-- rtx-panel.lua  v3.7.0  - on-screen card (top-right corner on hover, Alt+b pins it) that follows the signal chain:
--   PRESET   Faithful | Immersive | Custom (a preset only sets the switches below; Custom = your own mix)
--   SOURCE   video codec, size, frame rate; audio codec, channels
--   VIDEO    Crop -> Show as -> VSR -> RTX HDR -> Smooth
--   AUDIO    3D audio -> EQ (Off | your profiles) -> Peak trim (+ Measure now, Measure folder) -> Output (device, channels, format)
-- Compact view (default): one line per stage with only what is on or waiting; More opens every option, Less goes back.
-- Every option is its own badge (blue fill = chosen and working, blue outline = chosen but waiting, with the reason in
-- grey). A small line at the top-right shows background work ("measuring 40 %") and then discreet marks of what is
-- applied ("3D . EQ . PK -2.4"), option applied_marks = keep | hide.
-- Faithful = original frame and exact fold: Crop Off, Show Fit, VSR On (a plain upscaler), RTX HDR Off, Smooth Off,
-- 3D audio Off, EQ On (when you have a profile), Peak On. Immersive = Crop Auto, Show Fill, VSR On, RTX HDR Fullscreen, Smooth Auto, 3D audio On,
-- EQ On, Peak On. The card holds no playback logic: clicks send the scripts' own script-messages.
-- Options (script-opts/rtx_panel.conf or script-opts-append=rtx_panel-<name>=<value>): view (compact | detail),
-- pinned (yes | no), leave_grace (s, default 0.4), applied_marks (keep | hide), preset (custom | faithful | immersive:
-- applied once at the first file), bed_label (default "3D").

local mp = require 'mp'
local options = require 'mp.options'
local utils = require 'mp.utils'   -- v3.6.0: saved default (JSON)
local opts = { leave_grace = 0.4, pinned = false, view = "compact", bed_label = "3D", objects_label = "OBJ", applied_marks = "keep", preset = "custom", immersive_show = "fill", edge_px = 4 }
options.read_options(opts, "rtx_panel")

local ov = mp.create_osd_overlay("ass-events")
local pinned = opts.pinned
local marks_keep = tostring(opts.applied_marks):lower() ~= "hide"   -- v3.1.0
local more = tostring(opts.view):lower() == "detail"   -- v3.0.0: detail view (More) or the compact strip
local visible = false
local hover = false
local hide_timer = nil
local boxes = {}          -- hit boxes: {name, x1, y1, x2, y2}
local panel_box = nil     -- whole card {x1, y1, x2, y2}
local last_box = nil      -- v2.3.0: the card as last drawn (the show zone while hidden)
local captured = false

local function ass_color(bgr) return string.format("&H%s&", bgr) end
local C = {                                          -- BGR
    card = "141414",
    sel_fill = "C87A2A", sel_text = "FFFFFF",        -- chosen and working: blue fill
    wait_line = "E0A050", wait_text = "FFFFFF",      -- chosen, waiting: blue outline
    opt_fill = "2A2A2A", opt_line = "5A5A5A", opt_text = "D8D8D8",
    name = "F0F0F0", reason = "C0C0C0", dim = "8C8C8C",
}

-- Rows from published script state ----------------------------------------------------------------------------
-- badge = {id, label, look = "sel" | "wait" | "opt", act = {...}}; row = {title, reason, group, badges, chips}
-- chips (v3.0.0) = the row's badges for the compact strip: the feature while it is on or waiting, click = off.
local function cmd(...) return { ... } end
local function chip(r, id, label, look, act)
    r.chips[#r.chips + 1] = { id = id, label = label, look = look, act = act, reason = r.reason }
end
-- v3.2.0 presets: the switches each preset sets, the commands that set them, and the current match
local PRESETS = {
    faithful  = { crop = "original", show = "fit", vsr = true, hdr = "off", smooth = "off", bin = false, obj = false, eq = true, peak = true },
    immersive = { crop = "detect", show = "fill", vsr = true, hdr = "fullscreen", smooth = "auto", bin = true, obj = true, eq = true, peak = true },
}
-- mode Immersive sets (fill | half | fit, default fill); the preset match follows it
do local s = tostring(opts.immersive_show or ""):lower(); if s == "fill" or s == "half" or s == "fit" then PRESETS.immersive.show = s end end
local function yn(b) return b and "yes" or "no" end
local function preset_cmds(p)
    local P = type(p) == "table" and p or PRESETS[p]   -- v3.6.0: a preset name or a saved switch set
    return {
        cmd("script-message-to", "aspect_rtx", "set-crop", P.crop), cmd("script-message-to", "aspect_rtx", "set-show", P.show),
        cmd("script-message-to", "aspect_rtx", "set-vsr", yn(P.vsr)), cmd("script-message-to", "aspect_rtx", "set-hdr-mode", P.hdr),
        cmd("script-message-to", "smooth", "set-mode", P.smooth),
        cmd("script-message-to", "binaural", "set-binaural", yn(P.bin)), cmd("script-message-to", "binaural", "set-binaural-stereo", yn(P.bin)),
        cmd("script-message-to", "objects", "set-objects", yn(P.obj)), cmd("script-message-to", "eq", "set-eq", yn(P.eq)),
        cmd("script-message-to", "peak", "set-peak", yn(P.peak)),
    }
end
local function current_switches()
    local a = mp.get_property_native("user-data/aspect_rtx") or {}
    local s = mp.get_property_native("user-data/smooth") or {}
    local bz = mp.get_property_native("user-data/binaural") or {}
    local ob = mp.get_property_native("user-data/objects")
    local k = mp.get_property_native("user-data/eq")
    local pk = mp.get_property_native("user-data/peak") or {}
    local hdr = (a.hdr_want == false and "off") or (a.hdr_windowed and "always") or "fullscreen"
    -- v3.7.0 fix: "(x == nil) and nil or x.f" indexed nil when the script is absent (Lua: "true and nil" falls through
    -- to the "or" branch); hit in the release config (no objects.lua, no EQ profile) as soon as the card opened
    local obj, eq = nil, nil
    if ob ~= nil then obj = ob.enabled and true or false end
    if k ~= nil then eq = k.on and true or false end
    return { crop = a.crop_mode or "original", show = a.show or "fit", vsr = a.vsr_want ~= false, hdr = hdr, smooth = s.mode,
        bin = (bz.on or (bz.stereo and bz.stereo.mode)) and true or false,
        obj = obj, eq = eq, peak = pk.enabled ~= false }
end
local function preset_now()
    local c = current_switches()
    for _, p in ipairs({ "faithful", "immersive" }) do
        local ok = true
        for key, want in pairs(PRESETS[p]) do
            -- a switch whose script is absent (nil) does not count; smooth absent likewise
            if c[key] ~= nil and c[key] ~= want then ok = false end
        end
        if ok then return p end
    end
    return "custom"
end
-- to ~~/cache/rtx-panel-default.json, applied at the first file instead of the preset option; Reset default deletes it
-- and goes back to the shipped default. Hand-written confs are never edited.
local DEF_FILE = mp.command_native({ "expand-path", "~~/cache/rtx-panel-default.json" })
local function saved_default()
    local f = io.open(DEF_FILE, "rb"); if not f then return nil end
    local t = utils.parse_json(f:read("*a") or ""); f:close()
    return type(t) == "table" and type(t.switches) == "table" and t or nil
end
mp.register_script_message("make-default", function()
    local c = current_switches()
    local sw = {}
    for _, k in ipairs({ "crop", "show", "vsr", "hdr", "smooth", "bin", "obj", "eq", "peak" }) do if c[k] ~= nil then sw[k] = c[k] end end
    local f = io.open(DEF_FILE .. ".tmp", "wb")
    if not f then mp.osd_message("Could not save the default", 3); return end
    f:write(utils.format_json({ v = 1, preset = preset_now(), switches = sw, saved = os.time() })); f:close()
    os.remove(DEF_FILE); os.rename(DEF_FILE .. ".tmp", DEF_FILE)
    mp.msg.info("default saved: " .. utils.format_json(sw))
    mp.osd_message("Saved as default", 2); if redraw_panel then redraw_panel() end
end)
mp.register_script_message("reset-default", function()
    os.remove(DEF_FILE)
    local p = tostring(opts.preset or "custom"):lower()
    if PRESETS[p] then for _, c in ipairs(preset_cmds(p)) do mp.commandv((table.unpack or unpack)(c)) end end
    mp.msg.info("default reset to the shipped preset " .. p)
    mp.osd_message("Default reset (" .. p .. ")", 2); if redraw_panel then redraw_panel() end
end)
function preset_row()
    if not mp.get_property_native("user-data/aspect_rtx") then return nil end
    local now = preset_now()
    local r = { title = "Preset", reason = (now == "faithful" and "as made: original frame, exact fold")
        or (now == "immersive" and ("3D audio, " .. PRESETS.immersive.show .. ", upscale, HDR, smooth")) or "your own mix", group = "preset", badges = {}, chips = {} }
    for _, p in ipairs({ { "faithful", "Faithful" }, { "immersive", "Immersive" }, { "custom", "Custom" } }) do
        local b = { id = "preset:" .. p[1], label = p[2], look = (now == p[1]) and "sel" or "opt", act = (p[1] ~= "custom") and preset_cmds(p[1]) or nil }
        r.badges[#r.badges + 1] = b
    end
    r.chips = {}; for _, b in ipairs(r.badges) do r.chips[#r.chips + 1] = b end
    r.badges[#r.badges + 1] = { id = "preset:save", label = "Make default", look = "opt", act = cmd("script-message-to", "rtx_panel", "make-default") }
    if saved_default() then r.badges[#r.badges + 1] = { id = "preset:reset", label = "Reset default", look = "opt", act = cmd("script-message-to", "rtx_panel", "reset-default") } end
    return r
end
function source_row()
    local v = mp.get_property_native("current-tracks/video")
    local au = mp.get_property_native("current-tracks/audio")
    if not v and not au then return nil end
    local vt = ""
    if v and not v.image and not v.albumart then
        local fps = tonumber(v["demux-fps"])
        vt = string.format("%s %sx%s%s", tostring(v.codec or "?"):upper(), tostring(v["demux-w"] or "?"), tostring(v["demux-h"] or "?"),
            fps and string.format(" %gp", math.floor(fps * 100 + 0.5) / 100) or "")
    end
    local at = au and string.format("%s %s", tostring(au.codec or "?"):upper(), tostring(au["demux-channels"] or au["demux-channel-count"] or "")) or "no audio"
    local r = { title = "Source", reason = "", group = "source", badges = {}, chips = {} }
    if vt ~= "" then r.badges[#r.badges + 1] = { id = "src:video", label = vt, look = "none", act = nil } end
    r.badges[#r.badges + 1] = { id = "src:audio", label = at, look = "none", act = nil }
    r.chips = r.badges
    return r
end
local function rows()
    local a = mp.get_property_native("user-data/aspect_rtx") or {}
    local v = mp.get_property_native("current-tracks/video")
    local has_video = v ~= nil and not v.image and not v.albumart
    local starting = has_video and a.sig == nil
    local out = {}

    -- v3.2.0: PRESET (Faithful | Immersive | Custom) and SOURCE rows, the head of the chain
    local pre = preset_row()
    if pre then out[#out + 1] = pre end
    local src = source_row()
    if src then out[#out + 1] = src end

    -- Crop (v3.0.0: was "Bars")
    local mode = a.crop_mode or "original"
    local crop = { title = "Crop", reason = "", group = "video", badges = {}, chips = {} }
    local crop_look, crop_label = nil, nil
    local function crop_badge(id, label)
        local chosen = (id == "original" and mode == "original") or id == mode
        local look = "opt"
        if chosen then
            look = "sel"
            if id ~= "original" and has_video and not starting and not (a.bars_cut or (a.bars_cut == nil and a.crop)) then
                look = "wait"; crop.reason = (a.crop_na and a.crop_na ~= "") and a.crop_na or "nothing to cut"
            end
            if id ~= "original" then crop_look, crop_label = look, (id == "detect") and ((a.bars_det and a.bars_det ~= "") and a.bars_det or "Auto") or label end
        end
        crop.badges[#crop.badges + 1] = { id = "crop:" .. id, label = label, look = look,
            act = cmd("script-message-to", "aspect_rtx", "set-crop", id) }
    end
    if a.presets then crop_badge("detect", "Auto" .. ((a.bars_det and a.bars_det ~= "") and (" " .. a.bars_det) or "")) end
    crop_badge("original", "Off")
    for _, l in ipairs(a.presets or {}) do crop_badge(l, l) end
    if not has_video then crop.reason = "no video" elseif starting then crop.reason = "starting" end
    if crop_look then chip(crop, "c:crop", "Crop " .. crop_label, crop_look, cmd("script-message-to", "aspect_rtx", "set-crop", "original")) end
    out[#out + 1] = crop

    -- Show as (v2.4.0; only with aspect-rtx >= v4.1.0, which publishes show_presets)
    if a.show_presets then
        local smode = a.show or "fit"
        local sh = { title = "Show as", reason = "", group = "video", badges = {}, chips = {} }
        local sh_look, sh_label = nil, nil
        local function show_badge(id, label)
            local look = "opt"
            if id == smode then
                look = "sel"
                if id ~= "fit" and has_video and not starting and not a.show_cut then
                    look = "wait"; sh.reason = (a.show_na and a.show_na ~= "") and a.show_na or "nothing to cut"
                end
                if id ~= "fit" then sh_look, sh_label = look, label end
            end
            sh.badges[#sh.badges + 1] = { id = "show:" .. id, label = label, look = look,
                act = cmd("script-message-to", "aspect_rtx", "set-show", id) }
        end
        show_badge("fit", "Fit"); show_badge("half", "Half"); show_badge("fill", "Fill")
        for _, l in ipairs(a.show_presets) do show_badge(l, l) end
        if not has_video then sh.reason = "no video" elseif starting then sh.reason = "starting" end
        if sh_look then chip(sh, "c:show", "Show " .. sh_label, sh_look, cmd("script-message-to", "aspect_rtx", "set-show", "fit")) end
        out[#out + 1] = sh
    end

    -- VSR / RTX HDR
    local function why_wait(na)
        return (not has_video and "no video") or (starting and "starting") or (na ~= "" and na) or "waiting"
    end
    local function onoff(key, title, want, running, na, on_label)
        local r = { title = title, reason = "", group = "video", badges = {}, chips = {} }
        local on_look = "opt"
        if want then
            on_look = running and "sel" or "wait"
            if not running then r.reason = why_wait(na) end
        end
        r.badges[1] = { id = key .. ":off", label = "Off", look = want and "opt" or "sel",
            act = cmd("script-message-to", "aspect_rtx", "set-" .. key, "no") }
        r.badges[2] = { id = key .. ":on", label = on_label, look = on_look,
            act = cmd("script-message-to", "aspect_rtx", "set-" .. key, "yes") }
        if not want and has_video and not starting and na and na ~= "" then r.reason = na end
        return r
    end
    local scale = tonumber(a.scale)
    local vsr_on = (a.vsr and scale) and string.format("On %gx", scale) or "On"
    local rv = onoff("vsr", "VSR", a.vsr_want ~= false, a.vsr, a.vsr_na or "", vsr_on)
    if a.vsr_want ~= false then
        chip(rv, "c:vsr", (vsr_on:gsub("^On", "VSR")), rv.badges[2].look, cmd("script-message-to", "aspect_rtx", "set-vsr", "no"))
    end
    out[#out + 1] = rv
    -- v3.0.0: RTX HDR Off | Fullscreen | Always (aspect-rtx >= v4.4.0 set-hdr-mode; it publishes hdr_windowed since
    -- v4.3.0). Without hdr_windowed (older aspect-rtx) the v2 row Off | On.
    local hdr_want = a.hdr_want ~= false
    local rh
    if a.hdr_windowed ~= nil then
        local hmode = (not hdr_want and "off") or (a.hdr_windowed and "always") or "fullscreen"
        rh = { title = "RTX HDR", reason = "", group = "video", badges = {}, chips = {} }
        local na = a.hdr_na or ""
        for _, m in ipairs({ { "off", "Off" }, { "fullscreen", "Fullscreen" }, { "always", "Always" } }) do
            local look = "opt"
            if m[1] == hmode then look = (m[1] == "off" or a.hdr) and "sel" or "wait" end
            rh.badges[#rh.badges + 1] = { id = "hdr:" .. m[1], label = m[2], look = look,
                act = cmd("script-message-to", "aspect_rtx", "set-hdr-mode", m[1]) }
        end
        if hdr_want and not a.hdr then rh.reason = why_wait(na)
        elseif not hdr_want and has_video and not starting and na ~= "" then rh.reason = na end
    else
        rh = onoff("hdr", "RTX HDR", hdr_want, a.hdr, a.hdr_na or "", "On")
    end
    -- v2.2: the detected Windows display mode (aspect-rtx >= v3.3) when the row has no other reason to show
    if rh.reason == "" and has_video and a.display then rh.reason = a.display end
    if hdr_want then
        chip(rh, "c:hdr", (a.hdr_windowed and "HDR always") or "HDR", a.hdr and "sel" or "wait",
            cmd("script-message-to", "aspect_rtx", "set-hdr", "no"))
    end
    out[#out + 1] = rh

    -- intuitive and cluttering"]; winhdr.lua and its script-opt winhdr-mode (winhdr.conf) keep working unchanged.
    -- Smooth (smooth.lua v2.2: mode auto|on|off; v3.0.0: row title back to "Smooth", was "Interpolation")
    local s = mp.get_property_native("user-data/smooth")
    if s then
        local r = { title = "Smooth", reason = "", group = "video", badges = {}, chips = {} }
        for _, m in ipairs({ { "auto", "Auto" }, { "on", "On" }, { "off", "Off" } }) do
            local look = "opt"
            if s.mode == m[1] then look = (m[1] == "off" or s.on) and "sel" or "wait" end
            r.badges[#r.badges + 1] = { id = "smooth:" .. m[1], label = m[2], look = look,
                act = cmd("script-message-to", "smooth", "set-mode", m[1]) }
        end
        if s.mode == "auto" then r.reason = s.on and "on: uneven cadence" or ("idle: " .. (s.na ~= "" and s.na or "-"))
        elseif s.mode == "on" and not s.on then r.reason = "no video" end
        -- strip: forced on (lit, or outlined while it cannot run) or auto while it runs; auto standing by is not shown
        if s.mode == "on" or (s.mode == "auto" and s.on) then
            chip(r, "c:smooth", "Smooth", s.on and "sel" or "wait", cmd("script-message-to", "smooth", "set-mode", "off"))
        end
        out[#out + 1] = r
    end

    -- v2.7.0: calibrated headphone renderer (binaural.lua); reason = what it does with this track
    local bz = mp.get_property_native("user-data/binaural")
    if bz then
        -- mode-only "3D" badge + a separate "3D stereo" row). On = binaural.lua's renderer for surround / TrueHD and its
        -- virtual speakers for stereo: the click sets both switches (set-binaural + set-binaural-stereo, the one that
        -- matters for this file last, so its OSD shows); Alt+u / Alt+U and the binaural options stay as they are, and so
        -- do the per-source defaults. Objects: the OBJ badge (Alt+o) appears only on a source with an Atmos layer.
        -- The grey line says what it does for this file.
        local ob = mp.get_property_native("user-data/objects")
        local objects_on = ob and ob.layer == "objects"
        local st = bz.stereo or {}
        local n = tonumber(bz.channels)
        local stereo_src = n == 2
        local on = (stereo_src and st.mode) or (not stereo_src and bz.on) or false
        local playing = objects_on or (stereo_src and st.active) or (not stereo_src and bz.active) or false
        local r = { title = "3D audio", reason = "", group = "audio", badges = {}, chips = {} }
        if objects_on then r.reason = "objects (Atmos)"
        elseif playing and stereo_src then r.reason = "stereo \226\134\146 2 speakers in front"
        elseif playing then r.reason = "surround \226\134\146 " .. ((n == 8 and "7.1") or (n == 6 and "5.1") or (tostring(n) .. " ch")) .. " around you"
        elseif on then
            r.reason = (n == nil and "no audio") or (n == 1 and "mono: untouched")
                or (stereo_src and (st.reason ~= "" and st.reason or st.why)) or (not stereo_src and (bz.reason ~= "" and bz.reason or bz.why)) or "waiting"
        elseif n == 1 then r.reason = "mono: untouched" end
        local function both(v)
            local a1 = cmd("script-message-to", "binaural", "set-binaural", v)
            local a2 = cmd("script-message-to", "binaural", "set-binaural-stereo", v)
            return stereo_src and { a1, a2 } or { a2, a1 }
        end
        r.badges[1] = { id = "bin:off", label = "Off", look = on and "opt" or "sel", act = both("no") }
        r.badges[2] = { id = "bin:on", label = "On", look = on and (playing and "sel" or "wait") or "opt", act = both("yes") }
        -- strip: "3D" while on (lit while it plays, outlined while it waits); click = off
        if on then chip(r, "bin:on", opts.bed_label, r.badges[2].look, r.badges[1].act) end
        if ob and ob.atmos and (ob.layer == "objects" or ob.layer == "bed") then
            local act = cmd("script-binding", "objects/objects-toggle")
            r.badges[#r.badges + 1] = { id = "bin:obj", label = opts.objects_label, look = objects_on and "sel" or "wait", act = act }
            if not objects_on and (ob.why or "") ~= "" then r.reason = (opts.objects_label .. ": " .. ob.why) end
            chip(r, "bin:obj", opts.objects_label, objects_on and "sel" or "wait", act)
        end
        out[#out + 1] = r
    end
    -- EQ (only when an EQ script is loaded); v3.2.0: after 3D audio, as in the chain
    -- v3.7.0: Off | one badge per profile (eq.lua); a profile badge turns the EQ on with it
    local k = mp.get_property_native("user-data/eq")
    if k and type(k.profiles) == "table" and #k.profiles > 0 then
        local au = mp.get_property_native("current-tracks/audio")
        local r = { title = "EQ", reason = au == nil and "no audio" or "", group = "audio", badges = {}, chips = {} }
        local off = cmd("script-message-to", "eq", "set-eq", "no")
        r.badges[1] = { id = "eq:off", label = "Off", look = k.on and "opt" or "sel", act = (k.on and off) or nil }
        for i, n in ipairs(k.profiles) do
            local sel = k.on and n == k.profile
            local lab = #n > 20 and (n:sub(1, 19) .. "~") or n
            r.badges[#r.badges + 1] = { id = "eq:p" .. i, label = lab, look = sel and "sel" or "opt", act = (not sel and cmd("script-message-to", "eq", "set-profile", n)) or nil }
        end
        if k.on then chip(r, "c:eq", "EQ", "sel", off) end
        out[#out + 1] = r
    end
    -- v2.10.0: peak trim (peak.lua): Off | On, status "PK -x.x" = the static trim of this file (filled = from a
    -- measurement of this file, outlined = first-watch default for its path)
    local pk = mp.get_property_native("user-data/peak")
    if pk then
        local rp = { title = "Peak trim", reason = "", group = "audio", badges = {}, chips = {} }
        local off = cmd("script-message-to", "peak", "set-peak", "no")
        rp.badges[1] = { id = "pk:off", label = "Off", look = pk.enabled and "opt" or "sel", act = off }
        rp.badges[2] = { id = "pk:on", label = "On", look = pk.enabled and "sel" or "opt",
            act = cmd("script-message-to", "peak", "set-peak", "yes") }
        if pk.enabled and pk.trim then
            rp.badges[3] = { id = "pk:val", label = string.format("PK %+.1f", pk.trim), look = (pk.source == "default") and "wait" or "sel", act = nil }
            local kw = ({ renderer = "3D audio", fold = "surround to stereo", stereo = "stereo", stereo3d = "3D audio (stereo)" })[pk.kind] or tostring(pk.kind)
            rp.reason = (pk.source == "default" and "first watch: safe default, " or "measured, ") .. kw
                .. (pk.tp_seen and string.format(", peak %+.1f dB", pk.tp_seen) or "")
            chip(rp, "pk:val", rp.badges[3].label, rp.badges[3].look, off)
        elseif pk.enabled then
            chip(rp, "c:pk", "Peak", "sel", off)
        end
        -- v3.3.0: measure this file now (peak.lua >= v1.3.0; applied when the pass completes)
        rp.badges[#rp.badges + 1] = { id = "pk:now", label = "Measure now", look = "opt",
            act = cmd("script-message-to", "peak", "peak-measure-now") }
        -- v3.2.0: measure the playing file's folder now (peak.lua >= v1.2.0)
        rp.badges[#rp.badges + 1] = { id = "pk:folder", label = "Measure folder", look = "opt",
            act = cmd("script-message-to", "peak", "peak-analyze-folder") }
        out[#out + 1] = rp
    end
    -- v3.2.0: Output = the end of the audio chain (device, channels, sample format); status only
    local aop = mp.get_property_native("audio-out-params")
    if aop and aop["channel-count"] then
        local bzo = mp.get_property_native("user-data/binaural") or {}
        local fmt = tostring(aop.format or "")
        local lab = string.format("%d-ch %s", aop["channel-count"], (fmt:find("float") and "float") or (fmt:find("s32") and "32-bit") or (fmt:find("s16") and "16-bit") or fmt)
        local ro = { title = "Output", reason = tostring(bzo.device or mp.get_property("audio-device") or "") .. (bzo.headphones and " (headphones)" or ""),
            group = "audio", badges = { { id = "out:fmt", label = lab, look = "none", act = nil } }, chips = {} }
        out[#out + 1] = ro
    end
    -- v3.1.0: background work (user-data/activity/<name>), one badge per busy job, the details as the grey line
    local act = mp.get_property_native("user-data/activity") or {}
    local names = {}
    for nm, e in pairs(act) do if type(e) == "table" and e.busy then names[#names + 1] = nm end end
    table.sort(names)
    if #names > 0 then
        local rw = { title = "Working", reason = "", group = "work", badges = {}, chips = {} }
        local det = {}
        for _, nm in ipairs(names) do
            local e = act[nm]
            local lb = tostring(e.word or nm) .. (tonumber(e.pct) and string.format(" %d%%", e.pct) or "")
            rw.badges[#rw.badges + 1] = { id = "work:" .. nm, label = lb, look = "wait", act = nil }
            rw.chips[#rw.chips + 1] = { id = "work:" .. nm, label = lb, look = "wait", act = nil, reason = "" }
            if (e.detail or "") ~= "" then det[#det + 1] = e.detail end
        end
        rw.reason = table.concat(det, "; ")
        for _, c in ipairs(rw.chips) do c.reason = rw.reason end
        out[#out + 1] = rw
    end
    -- v3.1.0: the applied marks Keep | Hide (detail view only)
    local rm = { title = "Marks", reason = "after background work", group = "panel", badges = {}, chips = {} }
    rm.badges[1] = { id = "marks:keep", label = "Keep", look = marks_keep and "sel" or "opt", act = "marks-keep" }
    rm.badges[2] = { id = "marks:hide", label = "Hide", look = marks_keep and "opt" or "sel", act = "marks-hide" }
    out[#out + 1] = rm
    return out
end

-- v3.0.0: the two views from the rows
local function detail_view(list)
    local out, last = {}, nil
    for _, r in ipairs(list) do
        if r.group ~= last then
            out[#out + 1] = { title = ({ audio = "AUDIO", work = "BACKGROUND", panel = "PANEL", preset = "PRESET", source = "SOURCE" })[r.group] or "VIDEO", reason = "", header = true, badges = {} }
            last = r.group
        end
        out[#out + 1] = r
    end
    return out
end
local function compact_view(list)
    local out = {}
    for _, g in ipairs({ { "preset", "Preset" }, { "source", "Source" }, { "video", "Video" }, { "audio", "Audio" }, { "work", "Working" } }) do
        local line = { title = g[2], reason = "", badges = {} }
        for _, r in ipairs(list) do
            if r.group == g[1] then
                for _, c in ipairs(r.chips) do
                    line.badges[#line.badges + 1] = c
                    if line.reason == "" and c.look == "wait" and (c.reason or "") ~= "" then line.reason = c.label .. ": " .. c.reason end
                end
            end
        end
        if (g[1] == "preset" or g[1] == "source") then
            if #line.badges > 0 then out[#out + 1] = line end
        elseif g[1] == "work" then
            for _, r in ipairs(list) do if r.group == "work" then line.reason = r.reason end end
            if #line.badges > 0 then out[#out + 1] = line end   -- the Working line only while something runs
        else
            if #line.badges == 0 then
                line.badges[1] = { id = "none:" .. g[1], label = "none", look = "none", act = nil }
            end
            out[#out + 1] = line
        end
    end
    return out
end

-- Drawing -----------------------------------------------------------------------------------------------------
local function rect(x1, y1, x2, y2, fill, fill_a, line, line_a, bord)
    return string.format("{\\an7\\pos(0,0)\\bord%g\\shad0\\1c%s\\1a&H%s&\\3c%s\\3a&H%s&\\p1}m %d %d l %d %d %d %d %d %d{\\p0}",
        bord, ass_color(fill), fill_a, ass_color(line), line_a, x1, y1, x2, y1, x2, y2, x1, y2)
end
local function text(an, x, y, size, color, alpha, bold, s)
    s = tostring(s):gsub("\\", "/"):gsub("{", "("):gsub("}", ")")
    return string.format("{\\an%d\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s\\1a&H%s&\\b%d}%s",
        an, x, y, size, ass_color(color), alpha, bold and 1 or 0, s)
end

local unpack_ = table.unpack or unpack
local show, arm_hide, cancel_hide, draw_indicator -- forward (v2.6.0: cancel_hide too; Alt+b pin crashed)

local function draw()
    local dim = mp.get_property_native("osd-dimensions")
    if not visible or not dim or (dim.w or 0) <= 0 then
        ov:remove(); boxes = {}; panel_box = nil
        mp.set_property_native("user-data/rtx_panel", { visible = false })
        return
    end
    local W, H = dim.w, dim.h
    local u = math.max(H / 1080, 0.5)
    local pad, gap, rgap = math.floor(12 * u), math.floor(6 * u), math.floor(6 * u)
    local bh = math.floor(40 * u)
    local hh = math.floor(22 * u)                     -- v3.0.0: group header row (detail view)
    local fs, fs2 = math.floor(19 * u), math.floor(15 * u)
    local namew = math.floor((more and 150 or 90) * u)
    local function bw(label) return math.max(math.floor(58 * u), math.floor(#label * fs * 0.56 + 24 * u)) end

    local list = more and detail_view(rows()) or compact_view(rows())
    -- footer: More | Pin (compact) or Less | Pin | Info (detail), right-aligned
    local foot = { { id = "more", label = more and "Less" or "More", look = "opt", act = "more" },
        { id = "pin", label = pinned and "Pinned" or "Pin", look = pinned and "sel" or "opt", act = "pin" } }
    if more then foot[3] = { id = "info", label = "Info", look = "opt", act = cmd("script-binding", "aspect_rtx/ar-status") } end
    list[#list + 1] = { title = "", reason = "", footer = true, badges = foot }
    local titles = {}   -- v3.2.0: every drawn row's title in order (tests: the signal-chain order)
    for _, r in ipairs(list) do if not r.footer then titles[#titles + 1] = r.title end end

    -- (estimated 0.55 x font size per character, UTF-8 bytes counted as characters, so arrows count wide) goes on its
    -- own line under the row, across the card, cut with "..." if even that is too narrow. Never under a badge.
    local function tw(s) return #s * fs2 * 0.55 end
    local subh = math.floor(fs2 * 1.35)
    local maxw, cardh = 0, pad + pad - rgap
    for _, r in ipairs(list) do
        local w = 0
        for i, b in ipairs(r.badges) do b.w = bw(b.label); w = w + b.w + (i > 1 and gap or 0) end
        r.w = w
        r.below = (not r.header and not r.footer and r.reason ~= "" and tw(r.reason) > namew - gap) or false
        r.h = r.header and hh or (bh + (r.below and subh or 0))
        cardh = cardh + r.h + rgap
        if not r.footer and w > maxw then maxw = w end
    end
    local cardw = math.max(pad + namew + maxw + pad, pad + list[#list].w + pad)
    for _, r in ipairs(list) do
        if r.below then
            local room = math.floor((cardw - 2 * pad) / (fs2 * 0.55))
            if #r.reason > room then r.reason = r.reason:sub(1, math.max(room - 3, 1)):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "..." end
        end
    end
    local cx1 = W - cardw - math.floor(18 * u)
    local cy1 = math.floor(18 * u) + (dim.mt or 0)
    local out, pub, prow = {}, {}, {}
    boxes = {}
    out[#out + 1] = rect(cx1, cy1, cx1 + cardw, cy1 + cardh, C.card, "18", C.card, "18", 0)

    local y1 = cy1 + pad
    for _, r in ipairs(list) do
        local yr = y1 + r.h                             -- end of the row (with its reason line)
        local y2 = r.header and yr or (y1 + bh)         -- end of the badge line
        if r.header then
            out[#out + 1] = text(1, cx1 + pad, y2, fs2, C.dim, "00", true, r.title)
        elseif r.title ~= "" then
            if r.below then
                out[#out + 1] = text(4, cx1 + pad, (y1 + y2) / 2, fs, C.name, "00", true, r.title)
                out[#out + 1] = text(4, cx1 + pad, y2 + subh / 2, fs2, C.reason, "00", false, r.reason)
            elseif r.reason ~= "" then
                out[#out + 1] = text(4, cx1 + pad, y1 + bh * 0.32, fs, C.name, "00", true, r.title)
                out[#out + 1] = text(4, cx1 + pad, y1 + bh * 0.78, fs2, C.reason, "00", false, r.reason)
            else
                out[#out + 1] = text(4, cx1 + pad, (y1 + y2) / 2, fs, C.name, "00", true, r.title)
            end
        end
        local x = r.footer and (cx1 + cardw - pad - r.w) or (cx1 + pad + namew)
        if r.reason ~= "" and not r.header and not r.footer then   -- v3.0.1: reason geometry for tests (estimated)
            prow[#prow + 1] = { title = r.title, reason = r.reason, below = r.below, rx2 = math.floor(cx1 + pad + tw(r.reason)), bx1 = x }
        end
        for _, b in ipairs(r.badges) do
            local x1, x2 = x, x + b.w
            local mx, my = math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2)
            if b.look == "sel" then
                out[#out + 1] = rect(x1, y1, x2, y2, C.sel_fill, "10", C.sel_fill, "10", 0)
                out[#out + 1] = text(5, mx, my, fs, C.sel_text, "00", true, b.label)
            elseif b.look == "wait" then
                out[#out + 1] = rect(x1, y1, x2, y2, C.opt_fill, "30", C.wait_line, "00", math.max(1, 2 * u))
                out[#out + 1] = text(5, mx, my, fs, C.wait_text, "00", true, b.label)
            elseif b.look == "none" then                -- v3.0.0: empty strip line, plain grey text
                out[#out + 1] = text(4, x1, my, fs, C.dim, "00", false, b.label)
            else
                out[#out + 1] = rect(x1, y1, x2, y2, C.opt_fill, "30", C.opt_line, "40", math.max(1, 1 * u))
                out[#out + 1] = text(5, mx, my, fs, C.opt_text, "00", false, b.label)
            end
            if b.look ~= "none" then boxes[#boxes + 1] = { name = b.id, act = b.act, x1 = x1, y1 = y1, x2 = x2, y2 = y2 } end
            pub[#pub + 1] = { name = b.id, look = b.look, label = b.label, sub = r.reason, cx = mx, cy = my }
            x = x2 + gap
        end
        y1 = yr + rgap
    end
    panel_box = { x1 = cx1, y1 = cy1, x2 = cx1 + cardw, y2 = cy1 + cardh }
    last_box = panel_box
    ov.res_x, ov.res_y = W, H
    ov.data = table.concat(out, "\n")
    ov:update()
    mp.set_property_native("user-data/rtx_panel", { visible = true, pinned = pinned, view = more and "detail" or "compact", buttons = pub, rows = prow, titles = titles })
end

-- Mouse capture only while over the card ----------------------------------------------------------------------
local function hit(x, y)
    for _, b in ipairs(boxes) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b end
    end
end
local function toggle_pin()
    pinned = not pinned
    if pinned then cancel_hide(); show(true) else arm_hide() end
    draw()
    mp.osd_message("RTX panel " .. (pinned and "pinned (Alt+b to unpin)" or "auto (shows in the top-right corner)"), 1.5)
end
local function toggle_more() more = not more; draw() end
local function on_left(e)
    if e.event ~= "down" and e.event ~= "press" then return end
    local m = mp.get_property_native("mouse-pos") or {}
    local b = hit(m.x or -1, m.y or -1)
    if not b or not b.act then return end
    if b.act == "pin" then toggle_pin() elseif b.act == "more" then toggle_more()
    elseif b.act == "marks-keep" or b.act == "marks-hide" then
        marks_keep = (b.act == "marks-keep"); draw(); draw_indicator()
    elseif type(b.act[1]) == "table" then for _, c in ipairs(b.act) do mp.commandv(unpack_(c)) end   -- v3.0.1: a sequence
    else mp.commandv(unpack_(b.act)) end
end
local function swallow() end
local function set_capture(on)
    if on == captured then return end
    captured = on
    if on then
        mp.add_forced_key_binding("MBTN_LEFT", "rtxp-left", on_left, { complex = true })
        mp.add_forced_key_binding("MBTN_RIGHT", "rtxp-right", swallow)
        mp.add_forced_key_binding("MBTN_LEFT_DBL", "rtxp-dbl", swallow)
    else
        mp.remove_key_binding("rtxp-left"); mp.remove_key_binding("rtxp-right"); mp.remove_key_binding("rtxp-dbl")
    end
end

show = function(on)
    if on == visible then return end
    visible = on
    -- v2.2.1: no Windows HDR re-check on open (it ran PowerShell on mouse movement); aspect-rtx re-checks on display
    -- moves and on a panel action (set-hdr / set-winhdr) instead.
    draw()
    draw_indicator()
    if not on then set_capture(false) end
end
-- v2.3.0: hide leave_grace s after the pointer left the zone (timer started once on leaving, cancelled on return)
arm_hide = function()
    if pinned or hide_timer or not visible then return end
    hide_timer = mp.add_timeout(tonumber(opts.leave_grace) or 0.4, function()
        hide_timer = nil
        if not pinned then show(false) end
    end)
end
cancel_hide = function() if hide_timer then hide_timer:kill(); hide_timer = nil end end
-- where initial smaller box is or on touching right window / screen edge"): the card opens only (a) over the small
-- top-right box (the status line's area, at least a fixed corner box, also while the line is faded) or (b) on the
-- right edge (edge_px wide strip). Open, it stays while the pointer is over the card (small margin) and hides
-- leave_grace s after it leaves. Movement anywhere else never opens it (was: the top-right 40 % x 45 % / card + 40 px).
local ind_w = 0   -- width of the status line as last drawn (px)
local function open_zone(m)
    local dim = mp.get_property_native("osd-dimensions") or {}
    local W, H = dim.w or 0, dim.h or 0
    if W <= 0 or H <= 0 then return false end
    local u = math.max(H / 1080, 0.5)
    if m.x >= W - (tonumber(opts.edge_px) or 4) then return true end                    -- (b) right edge
    local bw = math.max(math.floor(240 * u), ind_w + math.floor(36 * u))
    return m.x >= W - bw and m.y <= math.floor(48 * u) + (dim.mt or 0)                    -- (a) the small box
end
local function keep_zone(m)
    if not last_box then return false end
    local dim = mp.get_property_native("osd-dimensions") or {}
    local mg = math.floor(12 * math.max((dim.h or 1080) / 1080, 0.5))
    return m.x >= last_box.x1 - mg and m.x <= last_box.x2 + mg and m.y >= last_box.y1 - mg and m.y <= last_box.y2 + mg
end
local function in_zone(m) return open_zone(m) or (visible and keep_zone(m)) end

mp.observe_property("mouse-pos", "native", function(_, m)
    if not m then return end
    hover = m.hover and panel_box ~= nil and m.x >= panel_box.x1 and m.x <= panel_box.x2
        and m.y >= panel_box.y1 and m.y <= panel_box.y2 or false
    if m.hover and in_zone(m) then
        cancel_hide(); show(true)
    elseif not pinned then
        arm_hide()
    end
    set_capture(visible and hover)
end)

-- v3.1.0: the activity / applied-marks line (top-right, small, low contrast; hidden while the card is open) ----------
local ind = mp.create_osd_overlay("ass-events")
ind.z = -1
local MARK = { ["c:vsr"] = "VSR", ["c:hdr"] = "HDR", ["bin:on"] = nil, ["bin:obj"] = nil, ["c:eq"] = "EQ", ["c:smooth"] = "Smooth" }
local last_marks, marks_since = nil, 0
local function marks_text()
    local m = {}
    for _, r in ipairs(rows()) do
        for _, c in ipairs(r.chips or {}) do
            if c.id == "bin:on" and c.look == "sel" then m[#m + 1] = opts.bed_label
            elseif c.id == "bin:obj" and c.look == "sel" then m[#m + 1] = "Atmos"
            elseif c.id == "pk:val" then m[#m + 1] = c.label .. (c.look == "wait" and " (1st)" or "")
            elseif MARK[c.id] and c.look == "sel" then m[#m + 1] = MARK[c.id] end
        end
    end
    for _, e in pairs(mp.get_property_native("user-data/activity") or {}) do   -- marks of scripts the panel has no row for
        if type(e) == "table" and not e.busy and (e.mark or "") ~= "" then
            local dup = false
            for _, x in ipairs(m) do if x:find(e.mark, 1, true) then dup = true end end
            if not dup then m[#m + 1] = e.mark end
        end
    end
    return table.concat(m, "  \194\183  ")
end
local last_line = nil
draw_indicator = function()
    local dim = mp.get_property_native("osd-dimensions")
    if visible or not dim or (dim.w or 0) <= 0 then
        if last_line ~= "#hidden" then last_line = "#hidden"; ind:remove(); mp.set_property_native("user-data/rtx_panel_line", { text = "", hidden = true }) end
        return
    end
    local W, H = dim.w, dim.h
    local u = math.max(H / 1080, 0.5)
    local busy = {}
    local act = mp.get_property_native("user-data/activity") or {}
    local names = {}
    for nm, e in pairs(act) do if type(e) == "table" and e.busy then names[#names + 1] = nm end end
    table.sort(names)
    for _, nm in ipairs(names) do
        local e = act[nm]
        busy[#busy + 1] = tostring(e.word or nm) .. (tonumber(e.pct) and string.format(" %d%%", e.pct) or "")
    end
    local s, a
    if #busy > 0 then
        s = "\226\151\143 " .. table.concat(busy, "  \194\183  "); a = "50"; last_marks = nil
    else
        s = marks_text()
        if s ~= last_marks then
            -- v3.2.0: the fade restarts only when a mark is ADDED (new tech applied), not when one drops away
            local added = last_marks == nil
            if not added then
                for x in (s .. "  \194\183  "):gmatch("(.-)  \194\183  ") do
                    if x ~= "" and not last_marks:find(x, 1, true) then added = true end
                end
            end
            last_marks = s
            if added then marks_since = mp.get_time() end
        end
        if not marks_keep and mp.get_time() - marks_since > 4 then s = "" end
        a = "90"
    end
    -- v3.3.1 (audit F6): the line and the overlay are re-sent only when the text, its look or the window size changed
    local key = s .. "|" .. tostring(#busy > 0) .. "|" .. a .. "|" .. W .. "x" .. H .. "|" .. tostring(dim.mt)
    if key == last_line then return end
    last_line = key
    mp.set_property_native("user-data/rtx_panel_line", { text = s, busy = #busy > 0 })   -- for tests / other scripts
    if s == "" then ind_w = 0; ind:remove(); return end
    local fs = math.floor(15 * u)
    local nch = 0; for _ in s:gmatch("[^\128-\191]") do nch = nch + 1 end   -- characters, not bytes
    ind_w = math.floor(nch * fs * 0.55)                                         -- v3.5.0: the small box for open_zone
    s = s:gsub("\\", "/"):gsub("{", "("):gsub("}", ")")
    ind.res_x, ind.res_y = W, H
    ind.data = string.format("{\\an9\\pos(%d,%d)\\fs%d\\bord1\\shad0\\1c&HC8C8C8&\\3c&H000000&\\1a&H%s&\\3a&HC0&}%s",
        W - math.floor(18 * u), math.floor(12 * u) + (dim.mt or 0), fs, a, s)
    ind:update()
end
mp.add_periodic_timer(1.0, function() draw_indicator() end)

local function redraw() if visible then draw() end end
redraw_panel = redraw   -- v3.6.0: Make / Reset default refresh the card
for _, p in ipairs({ "user-data/activity", "user-data/aspect_rtx", "user-data/winhdr", "user-data/eq", "user-data/binaural", "user-data/objects", "user-data/peak", "user-data/smooth", "osd-dimensions",
                     "current-tracks/video", "current-tracks/audio" }) do
    mp.observe_property(p, "native", redraw)
end

mp.add_key_binding("Alt+b", "toggle", toggle_pin)
-- v3.0.0: More / Less from a key or another script (script-binding rtx_panel/view, script-message-to rtx_panel set-view)
mp.add_key_binding(nil, "view", toggle_more)
mp.register_script_message("set-view", function(v)
    local d = tostring(v or ""):lower() == "detail"
    if d ~= more then toggle_more() end
end)

if pinned then show(true) end
-- v3.2.0: option preset = faithful | immersive: applied once, at the first file (after the scripts published their state)
local preset_done = false
mp.register_event("file-loaded", function()
    local p = tostring(opts.preset or "custom"):lower()
    local d = saved_default()   -- v3.6.0: a saved default wins over the preset option
    if preset_done or (not d and not PRESETS[p]) then return end
    preset_done = true
    mp.add_timeout(1.5, function()
        for _, c in ipairs(preset_cmds(d and d.switches or p)) do mp.commandv(unpack_(c)) end
        mp.msg.info(d and ("saved default applied: " .. utils.format_json(d.switches)) or ("preset " .. p .. " applied"))
    end)
end)

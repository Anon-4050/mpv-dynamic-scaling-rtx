-- smooth.lua  v2.3.1: interpolation (motion smoothing), Alt+i. Direct choice: script-message-to smooth set-mode auto|on|off.
-- Smoothing = interpolation=yes + tscale=oversample: mpv blends the two real frames around each display refresh where
-- they straddle it (no motion invention, no new frames). Needs video-sync=display-resample* (mpv.conf keeps
-- display-resample-vdrop).
-- Modes (option smooth-default=auto|on|off, default auto; Alt+i or the panel button cycles auto -> on -> off -> auto
-- until mpv quits, OSD shows the mode and whether it is applied):
--   auto: ON only when the cadence does not match - display-resample active and the display rate is NOT a whole
--         multiple of the video rate (e.g. 25 fps on 120 Hz). Stays off for 24/30/60 fps on 120 Hz ("even cadence"),
--         without display resample ("no resample"), without video, for a heavy file ("heavy file") and for the rest
--         of a file once frames drop ("frames dropping").
--   on:   ON whenever there is video (forced; useful only to compare). Ignores the heavy-file and drop rules.
--   off:  never.
-- Publishes user-data/smooth = {mode, want, on, na} for rtx-panel.lua (want = mode ~= "off"; na = why auto is off).
--
-- Heavy files and drops (v2.3): auto stays off when the decoded pixel rate (w*h*fps, before any RTX upscale) is
-- above heavy_mpxs, and a watchdog turns it off for the rest of the file when dropped + delayed frames reach
-- drop_limit within drop_window seconds while it is on (one OSD line). A seek, (re)start, fullscreen toggle or filter change re-arms a grace period.
-- Options (mpv.conf: script-opts-append=smooth-<name>=<value>): default, heavy_mpxs (250 Mpx/s; 0 = no static rule),
--   heavy_bits (0 = any bit depth), drop_limit (4), drop_window (10 s), grace (3 s).
-- Calibration (one laptop RTX GPU, 60 Hz display, fullscreen, 20 s per run, 2 runs each, interpolation
-- on vs off): GPU load on/off - 1080p 10-bit HEVC 24p (RTX VSR running) 37.9/36.6 and 43.2/38.1 %; 4K 8-bit HEVC 25p
-- 27.6/27.4 and 28.4/27.3 %; 4K 10-bit PQ HDR HEVC 24p 32.8/31.5 and 31.6/28.6 %. So interpolation cost at most
-- ~5 GPU points; dropped/delayed frames with interpolation on: 0 in all 6 runs. 4K without VSR is the light case
-- (GPU ~0.9 GHz / 11 W against ~2.4 GHz / 33-38 W for 1080p + VSR), and no tested class is heavy at 60 Hz.
-- So the static rule only catches what lies beyond the tested range: more than 250 Mpx/s decoded (4K above 30 fps,
-- e.g. 4K50; tested max 3840x1600x23.976 = 147 Mpx/s). The watchdog covers the rest, per machine.

local mp = require 'mp'
local options = require 'mp.options'
local opts = {
    default = "auto",
    heavy_mpxs = 250,     -- decoded pixel rate (Mpx/s, w*h*fps) above which a file is heavy; 0 = no static rule ...
    heavy_bits = 0,       -- ... and only when the bit depth is at least this (0 = any depth)
    drop_limit = 4,       -- watchdog: this many dropped + delayed frames ...
    drop_window = 10,     -- ... within this many seconds of play with interpolation on turns it off for the file
    grace = 3,            -- seconds after a (re)start or seek that the watchdog ignores
}
options.read_options(opts, "smooth")

local MODES = { auto = true, on = true, off = true }
local alias = { yes = "on", no = "off" }        -- v1 values (smooth-default=yes|no)
local mode = alias[opts.default] or opts.default
if not MODES[mode] then mode = "auto" end

local function has_video()
    local v = mp.get_property_native("current-tracks/video")
    return v and not v.image and not v.albumart
end
local function na_reason()
    if not has_video() then return "no video" end
    if not tostring(mp.get_property("video-sync", "")):find("^display%-resample") then return "no resample" end
    if not mp.get_property_bool("display-sync-active", false) then return "no resample" end
    local dfps = mp.get_property_number("display-fps")
    -- container rate first. Without it, mpv's estimate wobbles (28.98 for a 30 fps clip), which would turn auto ON on an
    -- even cadence, so the estimate is snapped to a standard rate within 4 %,
    -- and stays off ("fps unknown") when it cannot.
    local vfps = mp.get_property_number("container-fps")
    if not vfps or vfps <= 0 then
        local est = mp.get_property_number("estimated-vf-fps")
        if not est or est <= 0 then return "fps unknown" end
        local best
        for _, r in ipairs({ 23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60, 100, 119.88, 120 }) do
            if math.abs(est / r - 1) < 0.04 and (not best or math.abs(est - r) < math.abs(est - best)) then best = r end
        end
        if not best then return "fps unknown" end
        vfps = best
    end
    if dfps and vfps and vfps > 0 then
        local r = dfps / vfps
        local n = math.floor(r + 0.5)
        -- within display-resample's speed range (1 %): mpv plays it at an exact multiple
        if n >= 1 and math.abs(r / n - 1) < 0.01 then return "even cadence" end
    end
    return ""
end

-- v2.3 heavy file: decoded size (not the RTX-upscaled output) and bit depth from the decoder's pixel format
-- (yuv420p10le -> 10, p010 -> 10, nv12/yuv420p -> 8).
local function bits_of(pf)
    pf = tostring(pf or "")
    return tonumber(pf:match("^p0(%d%d)") or pf:match("p(%d%d)") or pf:match("^y(%d%d)")) or 8
end
local function heavy()
    local p = mp.get_property_native("video-dec-params")
    if opts.heavy_mpxs <= 0 or not p or not p.w or not p.h then return false end
    local fps = mp.get_property_number("container-fps") or mp.get_property_number("estimated-vf-fps") or 0
    return p.w * p.h * fps / 1e6 > opts.heavy_mpxs and bits_of(p.pixelformat) >= opts.heavy_bits
end

-- v2.3 watchdog: while auto has interpolation on and the file plays, count new dropped + delayed frames over a
-- sliding window; over the limit -> off for the rest of this file ("frames dropping"), one OSD line.
local tripped, grace_until, hist = false, 0, {}
local function counts()
    return (mp.get_property_number("frame-drop-count") or 0) + (mp.get_property_number("vo-delayed-frame-count") or 0)
end
local function rearm() grace_until = mp.get_time() + opts.grace; hist = {} end
local function auto_na()
    local na = na_reason()
    if na ~= "" then return na end
    if heavy() then return "heavy file" end
    if tripped then return "frames dropping" end
    return ""
end

local last = nil
local function update(announce)
    local na = mode == "auto" and auto_na() or na_reason()
    local on = (mode == "on" and has_video()) or (mode == "auto" and na == "")
    if mp.get_property_bool("interpolation") ~= on then
        if on then mp.set_property("tscale", "oversample") end
        mp.set_property_bool("interpolation", on)
    end
    local key = mode .. tostring(on) .. na
    if key ~= last then
        last = key
        mp.set_property_native("user-data/smooth", { mode = mode, want = mode ~= "off", on = on, na = na })
        mp.msg.verbose("smooth: mode=" .. mode .. " on=" .. tostring(on) .. " na=" .. na)
    end
    if announce then
        local s = mode == "auto" and ("AUTO - " .. (on and "on (cadence does not match)" or ("off (" .. na .. ")")))
            or mode == "on" and "ON (forced)" or "OFF"
        mp.osd_message("Interpolation: " .. s, 2)
    end
end

local NEXT = { auto = "on", on = "off", off = "auto" }
mp.add_key_binding("Alt+i", "toggle", function() mode = NEXT[mode]; update(true) end)
-- v2.2 (rtx-panel direct choice): script-message set-mode auto|on|off (no-op when already set).
mp.register_script_message("set-mode", function(v)
    v = alias[tostring(v or ""):lower()] or tostring(v or ""):lower()
    if MODES[v] and v ~= mode then mode = v; update(true) end
end)
for _, p in ipairs({ "current-tracks/video", "video-sync", "display-sync-active", "display-fps", "container-fps" }) do
    mp.observe_property(p, "native", function() update(false) end)
end
mp.observe_property("video-dec-params", "native", function() update(false) end)
-- v2.3 watchdog state: per file; a seek or (re)start re-arms the grace period (seek/start drops are not load).
mp.register_event("start-file", function() tripped = false; rearm() end)
mp.register_event("playback-restart", rearm)
mp.observe_property("pause", "bool", function(_, p) if not p then rearm() end end)
-- A fullscreen toggle or a filter-chain rebuild (crop/VSR change) drops frames by itself: re-arm too.
mp.observe_property("fullscreen", "bool", rearm)
mp.observe_property("vf", "native", rearm)
local function watchdog()
    if mode ~= "auto" or tripped or not mp.get_property_bool("interpolation", false) then hist = {}; return end
    if mp.get_property_bool("pause", false) or mp.get_property_bool("seeking", false) then hist = {}; return end
    local now = mp.get_time()
    if now < grace_until then hist = {}; return end
    local c = counts()
    hist[#hist + 1] = { t = now, c = c }
    while #hist > 1 and now - hist[1].t > opts.drop_window do table.remove(hist, 1) end
    if c - hist[1].c >= opts.drop_limit then
        tripped = true
        mp.msg.info(string.format("smooth: %d dropped/delayed frames in %.0f s with interpolation on -> off for this file",
            c - hist[1].c, now - hist[1].t))
        update(false)
        mp.osd_message("Interpolation off for this file: frames dropping", 3)
    end
end
-- display-sync-active is not reported to observers; re-check once a second (cheap, no change = no action).
mp.add_periodic_timer(1, function() watchdog(); update(false) end)
update(false)

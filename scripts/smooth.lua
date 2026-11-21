-- smooth.lua v2.1: motion smoothing, Alt+i.
-- Smoothing = interpolation=yes + tscale=oversample: mpv blends the two real frames around each display refresh where
-- they straddle it (no motion invention, no new frames). Needs video-sync=display-resample* (mpv.conf keeps
-- display-resample-vdrop).
-- Modes (option smooth-default=auto|on|off, default auto; Alt+i or the panel button cycles auto -> on -> off -> auto
-- for the session, OSD shows the mode and whether it is applied):
--   auto: ON only when the cadence does not match - display-resample active and the display rate is NOT a whole
--         multiple of the video rate (e.g. 25 fps on 120 Hz). Stays off for 24/30/60 fps on 120 Hz ("even cadence"),
--         without display resample ("no resample") and without video.
--   on:   ON whenever there is video (forced; useful only to compare).
--   off:  never.
-- Publishes user-data/smooth = {mode, want, on, na} for rtx-panel.lua (want = mode ~= "off"; na = why auto is off).

local mp = require 'mp'
local options = require 'mp.options'
local opts = { default = "auto" }
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

local last = nil
local function update(announce)
    local na = na_reason()
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
        mp.osd_message("Smooth motion: " .. s, 2)
    end
end

local NEXT = { auto = "on", on = "off", off = "auto" }
mp.add_key_binding("Alt+i", "toggle", function() mode = NEXT[mode]; update(true) end)
for _, p in ipairs({ "current-tracks/video", "video-sync", "display-sync-active", "display-fps", "container-fps" }) do
    mp.observe_property(p, "native", function() update(false) end)
end
-- display-sync-active is not reported to observers; re-check once a second (cheap, no change = no action).
mp.add_periodic_timer(1, function() update(false) end)
update(false)

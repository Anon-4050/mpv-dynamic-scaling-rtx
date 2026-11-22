-- rtx-panel.lua  v2.3.1: on-screen selector card, top-right. One row per setting, every option as its
-- own badge, so the current choice is visible at a glance and any option is one click away (no cycling).
--
--   Crop     Off | Auto | 1.9 | ...      (Auto = display ratio; one badge per aspect-rtx preset; a choice that does not apply
--                                         shows why: "fits the display", "narrower than the display", "portrait picture")
--   VSR      Off | On                    (On shows the live scale, e.g. "On 1.5x")
--   RTX HDR  Off | On                    (with no other reason to show: the detected mode, "display HDR" / "display SDR")
--   Interpolation  Auto | On | Off       (smooth.lua: mpv interpolation; row only when smooth.lua is loaded)
--   EQ       Off | On                    (row only when an EQ script publishes user-data/kz_eq; none is included)
--                              Pin | Info
--
-- Looks: chosen and working = blue fill; chosen but waiting = blue outline, with the reason in small grey text
--        under the row name ("windowed", "HDR source", "even cadence", ...); other options = dark.
-- Show/hide (hover-to-show, leave-to-hide): the card appears when the pointer moves into its corner (the card area plus
--        a margin; the top-right 40 % x 45 % before it was first shown) and hides leave_grace (0.4 s) after the pointer
--        leaves that zone or the window. 0.4 s: crossing or overshooting the card edge takes ~0.1-0.25 s, so a shorter
--        grace flickers; past ~0.5 s it feels sticky. Coming back within the grace keeps it open. Pin (or Alt+b) keeps
--        it up. The OSC stays at the bottom, the card at the top-right.
-- Clicks go to the scripts' own script-messages (aspect-rtx: set-crop / set-vsr / set-hdr; smooth.lua: set-mode), so
--        keys and badges always agree; this script holds no playback logic. Mouse buttons are captured only while the
--        pointer is over the card, so window dragging, double-click fullscreen and the OSC keep working elsewhere.
-- Options (mpv.conf: script-opts-append=rtx_panel-<name>=<value>): leave_grace (s, default 0.4), pinned (yes/no).

local mp = require 'mp'
local options = require 'mp.options'
local opts = { leave_grace = 0.4, pinned = false }
options.read_options(opts, "rtx_panel")

local ov = mp.create_osd_overlay("ass-events")
local pinned = opts.pinned
local visible = false
local hover = false
local hide_timer = nil
local boxes = {}          -- hit boxes: {name, x1, y1, x2, y2}
local panel_box = nil     -- whole card {x1, y1, x2, y2}
local last_box = nil      -- The card as last drawn (the show zone while hidden)
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
-- badge = {id, label, look = "sel" | "wait" | "opt", act = {...}}; row = {title, reason, badges}
local function cmd(...) return { ... } end
local function rows()
    local a = mp.get_property_native("user-data/aspect_rtx") or {}
    local v = mp.get_property_native("current-tracks/video")
    local has_video = v ~= nil and not v.image and not v.albumart
    local starting = has_video and a.sig == nil
    local out = {}

    -- Crop
    local mode = a.crop_mode or "original"
    local crop = { title = "Crop", reason = "", badges = {} }
    local function crop_badge(id, label)
        local chosen = (id == "original" and mode == "original") or id == mode
        local look = "opt"
        if chosen then
            look = "sel"
            if id ~= "original" and has_video and not starting and not a.crop then
                look = "wait"; crop.reason = (a.crop_na and a.crop_na ~= "") and a.crop_na or "nothing to cut"
            end
        end
        crop.badges[#crop.badges + 1] = { id = "crop:" .. id, label = label, look = look,
            act = cmd("script-message-to", "aspect_rtx", "set-crop", id) }
    end
    crop_badge("original", "Off")
    if a.presets then crop_badge("auto", "Auto") end   -- aspect-rtx crop mode auto (display ratio, gated)
    for _, l in ipairs(a.presets or {}) do crop_badge(l, l) end
    if not has_video then crop.reason = "no video" elseif starting then crop.reason = "starting" end
    out[#out + 1] = crop

    -- VSR / RTX HDR
    local function onoff(key, title, want, running, na, on_label)
        local r = { title = title, reason = "", badges = {} }
        local on_look = "opt"
        if want then
            on_look = running and "sel" or "wait"
            if not running then
                r.reason = (not has_video and "no video") or (starting and "starting") or (na ~= "" and na) or "waiting"
            end
        end
        r.badges[1] = { id = key .. ":off", label = "Off", look = want and "opt" or "sel",
            act = cmd("script-message-to", "aspect_rtx", "set-" .. key, "no") }
        r.badges[2] = { id = key .. ":on", label = on_label, look = on_look,
            act = cmd("script-message-to", "aspect_rtx", "set-" .. key, "yes") }
        if not want and has_video and not starting and na and na ~= "" then r.reason = na end
        return r
    end
    local scale = tonumber(a.scale)
    out[#out + 1] = onoff("vsr", "VSR", a.vsr_want ~= false, a.vsr, a.vsr_na or "",
        (a.vsr and scale) and string.format("On %gx", scale) or "On")
    out[#out + 1] = onoff("hdr", "RTX HDR", a.hdr_want ~= false, a.hdr, a.hdr_na or "", "On")
    -- the detected display mode when the row has no other reason to show
    if out[#out].reason == "" and has_video and a.display then out[#out].reason = a.display end

    -- Windows HDR row: only when a script publishes user-data/winhdr (none is included here)
    local wh = mp.get_property_native("user-data/winhdr")
    if wh then
        local r = { title = "Windows HDR", reason = wh.last or "", badges = {} }
        for _, m in ipairs({ { "keep", "Keep" }, { "on_fs", "On FS" }, { "on", "On" }, { "onoff_fs", "On/Off FS" }, { "onoff", "On/Off" } }) do
            r.badges[#r.badges + 1] = { id = "winhdr:" .. m[1], label = m[2], look = wh.mode == m[1] and "sel" or "opt",
                act = cmd("script-message-to", "winhdr", "set-winhdr", m[1]) }
        end
        out[#out + 1] = r
    end
    -- Interpolation (smooth.lua: mode auto|on|off)
    local s = mp.get_property_native("user-data/smooth")
    if s then
        local r = { title = "Interpolation", reason = "", badges = {} }
        for _, m in ipairs({ { "auto", "Auto" }, { "on", "On" }, { "off", "Off" } }) do
            local look = "opt"
            if s.mode == m[1] then look = (m[1] == "off" or s.on) and "sel" or "wait" end
            r.badges[#r.badges + 1] = { id = "smooth:" .. m[1], label = m[2], look = look,
                act = cmd("script-message-to", "smooth", "set-mode", m[1]) }
        end
        if s.mode == "auto" then r.reason = s.on and "on: uneven cadence" or ("idle: " .. (s.na ~= "" and s.na or "-"))
        elseif s.mode == "on" and not s.on then r.reason = "no video" end
        out[#out + 1] = r
    end

    -- EQ (only when an EQ script publishes user-data/kz_eq; none is included here)
    local k = mp.get_property_native("user-data/kz_eq")
    if k then
        local au = mp.get_property_native("current-tracks/audio")
        local r = { title = "EQ", reason = au == nil and "no audio" or "", badges = {} }
        local toggle = cmd("script-binding", "kz_eq/kz-eq-toggle")
        r.badges[1] = { id = "eq:off", label = "Off", look = k.on and "opt" or "sel", act = (k.on and toggle) or nil }
        r.badges[2] = { id = "eq:on", label = "On", look = k.on and "sel" or "opt", act = (not k.on and toggle) or nil }
        out[#out + 1] = r
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
local show, arm_hide -- forward

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
    local fs, fs2 = math.floor(19 * u), math.floor(15 * u)
    local namew = math.floor(150 * u)
    local function bw(label) return math.max(math.floor(58 * u), math.floor(#label * fs * 0.56 + 24 * u)) end

    local list = rows()
    -- footer: Pin | Info, right-aligned
    list[#list + 1] = { title = "", reason = "", footer = true, badges = {
        { id = "pin", label = pinned and "Pinned" or "Pin", look = pinned and "sel" or "opt", act = "pin" },
        { id = "info", label = "Info", look = "opt", act = cmd("script-binding", "aspect_rtx/ar-status") } } }

    local maxw = 0
    for _, r in ipairs(list) do
        local w = 0
        for i, b in ipairs(r.badges) do b.w = bw(b.label); w = w + b.w + (i > 1 and gap or 0) end
        r.w = w
        if w > maxw then maxw = w end
    end
    local cardw = pad + namew + maxw + pad
    local cardh = pad + #list * bh + (#list - 1) * rgap + pad
    local cx1 = W - cardw - math.floor(18 * u)
    local cy1 = math.floor(18 * u) + (dim.mt or 0)
    local out, pub = {}, {}
    boxes = {}
    out[#out + 1] = rect(cx1, cy1, cx1 + cardw, cy1 + cardh, C.card, "18", C.card, "18", 0)

    for ri, r in ipairs(list) do
        local y1 = cy1 + pad + (ri - 1) * (bh + rgap)
        local y2 = y1 + bh
        if r.title ~= "" then
            if r.reason ~= "" then
                out[#out + 1] = text(4, cx1 + pad, y1 + bh * 0.32, fs, C.name, "00", true, r.title)
                out[#out + 1] = text(4, cx1 + pad, y1 + bh * 0.78, fs2, C.reason, "00", false, r.reason)
            else
                out[#out + 1] = text(4, cx1 + pad, (y1 + y2) / 2, fs, C.name, "00", true, r.title)
            end
        end
        local x = r.footer and (cx1 + cardw - pad - r.w) or (cx1 + pad + namew)
        for _, b in ipairs(r.badges) do
            local x1, x2 = x, x + b.w
            local mx, my = math.floor((x1 + x2) / 2), math.floor((y1 + y2) / 2)
            if b.look == "sel" then
                out[#out + 1] = rect(x1, y1, x2, y2, C.sel_fill, "10", C.sel_fill, "10", 0)
                out[#out + 1] = text(5, mx, my, fs, C.sel_text, "00", true, b.label)
            elseif b.look == "wait" then
                out[#out + 1] = rect(x1, y1, x2, y2, C.opt_fill, "30", C.wait_line, "00", math.max(1, 2 * u))
                out[#out + 1] = text(5, mx, my, fs, C.wait_text, "00", true, b.label)
            else
                out[#out + 1] = rect(x1, y1, x2, y2, C.opt_fill, "30", C.opt_line, "40", math.max(1, 1 * u))
                out[#out + 1] = text(5, mx, my, fs, C.opt_text, "00", false, b.label)
            end
            boxes[#boxes + 1] = { name = b.id, act = b.act, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
            pub[#pub + 1] = { name = b.id, look = b.look, label = b.label, sub = r.reason, cx = mx, cy = my }
            x = x2 + gap
        end
    end
    panel_box = { x1 = cx1, y1 = cy1, x2 = cx1 + cardw, y2 = cy1 + cardh }
    last_box = panel_box
    ov.res_x, ov.res_y = W, H
    ov.data = table.concat(out, "\n")
    ov:update()
    mp.set_property_native("user-data/rtx_panel", { visible = true, pinned = pinned, buttons = pub })
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
local function on_left(e)
    if e.event ~= "down" and e.event ~= "press" then return end
    local m = mp.get_property_native("mouse-pos") or {}
    local b = hit(m.x or -1, m.y or -1)
    if not b or not b.act then return end
    if b.act == "pin" then toggle_pin() else mp.commandv(unpack_(b.act)) end
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
    draw()
    if not on then set_capture(false) end
end
-- Hide leave_grace s after the pointer left the zone (timer started once on leaving, cancelled on return)
arm_hide = function()
    if pinned or hide_timer or not visible then return end
    hide_timer = mp.add_timeout(tonumber(opts.leave_grace) or 0.4, function()
        hide_timer = nil
        if not pinned then show(false) end
    end)
end
local function cancel_hide() if hide_timer then hide_timer:kill(); hide_timer = nil end end
-- the show zone: the card plus a margin, from the top edge (a corner is easy to hit); before the first show, the
-- top-right 40 % x 45 % of the window
local function in_zone(m)
    local dim = mp.get_property_native("osd-dimensions") or {}
    local W, H = dim.w or 0, dim.h or 0
    if W <= 0 or H <= 0 then return false end
    local mg = math.floor(40 * math.max(H / 1080, 0.5))
    local x1, y2
    if last_box then x1, y2 = last_box.x1 - mg, last_box.y2 + mg else x1, y2 = W * 0.6, H * 0.45 end
    return m.x >= x1 and m.y <= y2
end

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

local function redraw() if visible then draw() end end
for _, p in ipairs({ "user-data/aspect_rtx", "user-data/winhdr", "user-data/kz_eq", "user-data/smooth", "osd-dimensions",
                     "current-tracks/video", "current-tracks/audio" }) do
    mp.observe_property(p, "native", redraw)
end

mp.add_key_binding("Alt+b", "toggle", toggle_pin)

if pinned then show(true) end

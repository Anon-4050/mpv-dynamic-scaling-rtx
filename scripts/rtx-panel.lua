-- rtx-panel.lua v1.1a: on-screen toggle row, top-right: Crop | VSR | RTX HDR | Smooth | Info.
-- Shows live state from user-data/aspect_rtx (aspect-rtx.lua >= v3.2.1) and user-data/smooth (smooth.lua).
-- Clicks call the existing script bindings, so keys and buttons always agree; this script holds no playback logic.
--
-- Looks: ON = filled blue, OFF = dark with outline, N/A = dark, no outline, grey label with the reason under it
--        ("armed" = the feature is switched on and starts by itself once it applies, e.g. on going fullscreen).
-- Show/hide: appears on mouse movement (like mpv's OSC) and hides 2.5 s after the mouse stops, unless the pointer
--        is on the panel. Alt+b pins / unpins it. The OSC sits at the bottom, the panel at the top-right.
-- Clicks: left = toggle; right-click on Crop = crop off. Mouse buttons are captured only while the pointer is
--        over the panel, so window dragging, double-click fullscreen and the OSC keep working elsewhere.
-- Options (mpv.conf: script-opts-append=rtx_panel-<name>=<value>): hide_after (s, default 2.5), pinned (yes/no).

local mp = require 'mp'
local options = require 'mp.options'
local opts = { hide_after = 2.5, pinned = false }
options.read_options(opts, "rtx_panel")

local ov = mp.create_osd_overlay("ass-events")
local pinned = opts.pinned
local visible = false
local hover = false
local hide_timer = nil
local boxes = {}          -- hit boxes: {name, x1, y1, x2, y2}
local panel_box = nil     -- whole panel {x1, y1, x2, y2}
local captured = false

local function ass_color(bgr) return string.format("&H%s&", bgr) end
local C = {
    on_fill = "C87A2A", on_text = "FFFFFF",         -- BGR: blue fill
    off_fill = "1E1E1E", off_line = "D0D0D0", off_text = "F0F0F0",
    na_fill = "1E1E1E", na_text = "8C8C8C", na_sub = "B4B4B4",
}

-- Button states from published script state ------------------------------------------------------------------
local function states()
    local a = mp.get_property_native("user-data/aspect_rtx") or {}
    local v = mp.get_property_native("current-tracks/video")
    local has_video = v ~= nil and not v.image and not v.albumart
    local function rtx_btn(name, label, running, want, na)
        if not has_video then return { name = name, label = label, look = "na", sub = "no video" } end
        if a.sig == nil then return { name = name, label = label, look = "na", sub = "starting" } end
        if na and na ~= "" then
            return { name = name, label = label, look = "na", sub = na .. (want and " - armed" or "") }
        end
        return { name = name, label = label, look = running and "on" or "off", sub = running and "" or "off" }
    end
    local list = {}
    -- Crop
    local mode = a.crop_mode or "original"
    local crop_label = mode == "original" and "Crop off" or ("Crop " .. mode)
    if not has_video then list[#list + 1] = { name = "crop", label = "Crop", look = "na", sub = "no video" }
    elseif mode ~= "original" and not a.crop then
        list[#list + 1] = { name = "crop", label = crop_label, look = "off", sub = "nothing to cut" }
    else list[#list + 1] = { name = "crop", label = crop_label, look = a.crop and "on" or "off", sub = "" } end
    -- VSR / HDR
    local scale = tonumber(a.scale)
    list[#list + 1] = rtx_btn("vsr", (a.vsr and scale) and string.format("VSR %gx", scale) or "VSR", a.vsr, a.vsr_want, a.vsr_na)
    list[#list + 1] = rtx_btn("hdr", "RTX HDR", a.hdr, a.hdr_want, a.hdr_na)
    -- Smooth (smooth.lua v2: mode auto|on|off; click cycles auto -> on -> off)
    local s = mp.get_property_native("user-data/smooth")
    local sm = { name = "smooth", label = "Smooth" }
    if not s then sm.look, sm.sub = "na", "not loaded"
    elseif s.mode == "off" then sm.look, sm.sub = "off", "off"
    elseif s.mode == "on" then sm.look, sm.sub = s.on and "on" or "na", s.on and "forced" or "forced - no video"
    elseif s.on then sm.look, sm.sub = "on", "auto"                       -- auto, cadence does not match
    else sm.look, sm.sub = "na", "auto: " .. tostring(s.na ~= "" and s.na or "idle") end
    list[#list + 1] = sm
    -- Info
    list[#list + 1] = { name = "info", label = "Info", look = "off", sub = "" }
    return list
end

local ACTIONS = {
    crop = { left = "script-binding aspect_rtx/ar-cycle", right = "script-binding aspect_rtx/ar-off" },
    vsr  = { left = "script-binding aspect_rtx/ar-vsr" },
    hdr  = { left = "script-binding aspect_rtx/ar-hdr" },
    smooth = { left = "script-binding smooth/toggle" },
    info = { left = "script-binding aspect_rtx/ar-status" },
}

-- Drawing -----------------------------------------------------------------------------------------------------
local function rect(x1, y1, x2, y2, fill, fill_a, line, line_a, bord)
    return string.format("{\\an7\\pos(0,0)\\bord%g\\shad0\\1c%s\\1a&H%s&\\3c%s\\3a&H%s&\\p1}m %d %d l %d %d %d %d %d %d{\\p0}",
        bord, ass_color(fill), fill_a, ass_color(line), line_a, x1, y1, x2, y1, x2, y2, x1, y2)
end
local function text(x, y, size, color, alpha, s)
    s = s:gsub("\\", "/"):gsub("{", "("):gsub("}", ")")
    return string.format("{\\an5\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c%s\\1a&H%s&\\b1}%s", x, y, size, ass_color(color), alpha, s)
end

local published = {}
local function draw()
    local dim = mp.get_property_native("osd-dimensions")
    if not visible or not dim or (dim.w or 0) <= 0 then
        ov:remove(); boxes = {}; panel_box = nil
        mp.set_property_native("user-data/rtx_panel", { visible = false })
        return
    end
    local W, H = dim.w, dim.h
    local u = math.max(H / 1080, 0.5)
    local bw, bh, gap = math.floor(128 * u), math.floor(50 * u), math.floor(8 * u)
    local fs, fs2 = math.floor(19 * u), math.floor(14 * u)
    local list = states()
    local total = #list * bw + (#list - 1) * gap
    local x0 = W - total - math.floor(18 * u)
    local y0 = math.floor(18 * u) + (dim.mt or 0)
    local out, pub = {}, {}
    boxes = {}
    for i, b in ipairs(list) do
        local x1 = x0 + (i - 1) * (bw + gap)
        local x2, y1, y2 = x1 + bw, y0, y0 + bh
        if b.look == "on" then
            out[#out + 1] = rect(x1, y1, x2, y2, C.on_fill, "20", C.on_fill, "20", 0)
            out[#out + 1] = text((x1 + x2) / 2, (y1 + y2) / 2, fs, C.on_text, "00", b.label)
        elseif b.look == "off" then
            out[#out + 1] = rect(x1, y1, x2, y2, C.off_fill, "40", C.off_line, "30", math.max(1, 1.5 * u))
            local cy = (b.sub ~= "" and b.name ~= "info") and (y1 + bh * 0.38) or (y1 + y2) / 2
            out[#out + 1] = text((x1 + x2) / 2, cy, fs, C.off_text, "00", b.label)
            if b.sub ~= "" and b.name ~= "info" then
                out[#out + 1] = text((x1 + x2) / 2, y1 + bh * 0.76, fs2, C.off_text, "50", b.sub)
            end
        else -- n/a
            out[#out + 1] = rect(x1, y1, x2, y2, C.na_fill, "50", C.na_fill, "50", 0)
            out[#out + 1] = text((x1 + x2) / 2, y1 + bh * 0.38, fs, C.na_text, "40", b.label)
            out[#out + 1] = text((x1 + x2) / 2, y1 + bh * 0.76, fs2, C.na_sub, "20", b.sub)
        end
        boxes[#boxes + 1] = { name = b.name, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
        pub[#pub + 1] = { name = b.name, look = b.look, label = b.label, sub = b.sub,
                          cx = math.floor((x1 + x2) / 2), cy = math.floor((y1 + y2) / 2) }
    end
    panel_box = { x1 = x0 - gap, y1 = y0 - gap, x2 = x0 + total + gap, y2 = y0 + bh + gap }
    ov.res_x, ov.res_y = W, H
    ov.data = table.concat(out, "\n")
    ov:update()
    mp.set_property_native("user-data/rtx_panel", { visible = true, pinned = pinned, buttons = pub })
end

-- Mouse capture only while over the panel --------------------------------------------------------------------
local function hit(x, y)
    for _, b in ipairs(boxes) do
        if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then return b.name end
    end
end
local function on_click(which)
    return function(e)
        if e.event ~= "down" and e.event ~= "press" then return end
        local m = mp.get_property_native("mouse-pos") or {}
        local name = hit(m.x or -1, m.y or -1)
        local act = name and ACTIONS[name] and ACTIONS[name][which]
        if act then mp.command(act) end
    end
end
local function swallow() end
local function set_capture(on)
    if on == captured then return end
    captured = on
    if on then
        mp.add_forced_key_binding("MBTN_LEFT", "rtxp-left", on_click("left"), { complex = true })
        mp.add_forced_key_binding("MBTN_RIGHT", "rtxp-right", on_click("right"), { complex = true })
        mp.add_forced_key_binding("MBTN_LEFT_DBL", "rtxp-dbl", swallow)
    else
        mp.remove_key_binding("rtxp-left"); mp.remove_key_binding("rtxp-right"); mp.remove_key_binding("rtxp-dbl")
    end
end

local function show(on)
    if on == visible then return end
    visible = on
    draw()
    if not on then set_capture(false) end
end
local function arm_hide()
    if hide_timer then hide_timer:kill() end
    if pinned then return end
    hide_timer = mp.add_timeout(opts.hide_after, function()
        if not pinned and not hover then show(false) end
    end)
end

local last_xy = nil
mp.observe_property("mouse-pos", "native", function(_, m)
    if not m then return end
    local xy = (m.x or 0) .. "," .. (m.y or 0)
    local moved = xy ~= last_xy
    last_xy = xy
    hover = m.hover and panel_box ~= nil and m.x >= panel_box.x1 and m.x <= panel_box.x2
        and m.y >= panel_box.y1 and m.y <= panel_box.y2 or false
    if m.hover and moved then show(true); arm_hide() end
    if not m.hover and not pinned then show(false) end
    set_capture(visible and hover)
end)

local function redraw() if visible then draw() end end
mp.observe_property("user-data/aspect_rtx", "native", redraw)
mp.observe_property("user-data/smooth", "native", redraw)
mp.observe_property("osd-dimensions", "native", redraw)
mp.observe_property("current-tracks/video", "native", redraw)

mp.add_key_binding("Alt+b", "toggle", function()
    pinned = not pinned
    if pinned then show(true) else arm_hide() end
    draw()
    mp.osd_message("RTX panel " .. (pinned and "pinned (Alt+b to unpin)" or "auto (shows on mouse move)"), 1.5)
end)

if pinned then show(true) end

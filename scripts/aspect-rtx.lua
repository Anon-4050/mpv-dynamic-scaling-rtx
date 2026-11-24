-- aspect-rtx.lua  v4.8.1  (tested on mpv 0.42, NVIDIA RTX laptop GPU, Windows 11, gpu-next + d3d11, hwdec=d3d11va-copy)
-- Live aspect-ratio crop fed into NVIDIA RTX VSR / RTX Video HDR via d3d11vpp. Chain: crop -> d3d11vpp -> renderer.
-- Runs no external program except ffprobe (optional, for the start-up pre-build) and changes no system setting.
--
-- Crop: a preset ratio, Auto (one-shot detection of black bars burned into the picture) or Off. Show as: Fit | Half |
--   Fill | a preset - cuts the sides of a picture wider than the screen after the crop.
-- VSR: fullscreen only (in a window it would upscale to the screen and shrink back). It runs only from a scale of
--   vsr_min_scale (1.3) up: below that it costs GPU load for almost no gain ("scale too small"). Stutter guard: while VSR
--   runs, >= vsr_guard_frames dropped + delayed frames in vsr_guard_window s turn VSR off for that file ("VSR off:
--   stutter"); the next file starts as set.
-- RTX Video HDR: Off | Fullscreen | Always (hdr_mode); only for SDR video on a display with Windows HDR on at mpv start.
--   Its output is tagged with the live display peak (hdr_peak).
-- Keys: Alt+a cycle crop presets, Alt+0 crop off, Ctrl+Shift+R VSR, Ctrl+Shift+H RTX HDR. Script-messages for the
--   panel: set-crop, set-show, set-vsr, set-hdr-mode (set-hdr, set-hdr-windowed kept as aliases).
-- Options: script-opts/aspect_rtx.conf (see the file and the README).

local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    presets  = "16:9,1.9",
    vsr      = true,
    hdr      = true,
    hdr_peak = "auto",    -- "auto" / "display" (/ "nvidia", old name) = live display peak; or a fixed number of nits
    peak_store = "~~cache/aspect-rtx-display-peak.txt",   -- last known display peak ("" = do not store)
    peak_max = 2000,      -- v4.6.0: display peak readings above this are ignored (Windows reports an uncalibrated 3290)
    hdr_display = "auto",
    ratio_tol = 0.02,     -- v4.0.0 gate: no crop when picture and display ratios differ by this fraction or less
    clamp    = false,     -- v4.0.0, opt-in since v4.0.1: crop mode auto only trims the sides of a wider picture
    pix_fmt  = "auto",
    start    = "",           -- v4.2.0: empty = use bars (was "16:9")
    bars     = "auto",       -- v4.2.0: auto = one-shot burned-in bar detection per file | off | a preset label
    crop     = "",           -- v4.4.0: new name of bars (panel row "Crop"); empty = use bars
    show     = "fit",        -- v4.2.0: Show as at launch (fit | half | fill | a show_presets label)
    show_presets = "",       -- v4.2.0: empty = presets
    display_aspect = "",     -- v4.2.0: empty = the display's ratio
    fullscreen_only = true,
    hdr_windowed = false,  -- v4.3.0: RTX HDR keeps running in a window (VSR never does)
    hdr_mode = "",         -- v4.4.0: off | fullscreen | always; empty = from hdr + hdr_windowed (aliases)
    icc_sdr  = "auto",    -- v3.3.2: icc-profile-auto on an SDR display without RTX HDR, off otherwise. auto = only if it
    luma     = true,      -- append format=max-luma tag after RTX HDR
    prebuild = "ffprobe", -- v3.2.9: ffprobe used to build the chain before the decoder starts ("" = off)
    display_store = "~~cache/aspect-rtx-display.txt",   -- v3.2.9: last known display size + HDR mode
    vsr_min_scale = 1.3,     -- v4.5.1: no VSR below this scale (load for almost no gain)
    vsr_guard = true,        -- v4.5.0: VSR off for the file when it makes playback stutter
    vsr_guard_frames = 10,   -- dropped + delayed frames ...
    vsr_guard_window = 4,    -- ... within this many seconds
    vsr_guard_settle = 3,    -- seconds ignored after a rebuild / seek / file start
}
options.read_options(opts, "aspect_rtx")

local function parse_ratio(s)
    local a, b = s:match("^([%d%.]+)%s*[:/]%s*([%d%.]+)$")
    if a then return tonumber(a) / tonumber(b) end
    return tonumber(s)
end

local presets, labels = {}, {}
for tok in opts.presets:gmatch("[^,]+") do
    tok = tok:match("^%s*(.-)%s*$")
    local r = parse_ratio(tok)
    if r and r > 0 then
        presets[#presets + 1] = r
        labels[#labels + 1] = tok
    end
end

local idx = 0     -- 0 = original (no crop), else index into presets
local show_r, show_l = {}, {}   -- v4.1.0: Show as presets
for tok in ((opts.show_presets ~= "" and opts.show_presets) or opts.presets):gmatch("[^,]+") do
    tok = tok:match("^%s*(.-)%s*$")
    local r = parse_ratio(tok)
    if r and r > 0 then show_r[#show_r + 1] = r; show_l[#show_l + 1] = tok end
end
-- Show as: "fit", "half", "fill" or a show_presets label (lower-case match); old names kept as aliases
local function show_norm(v)
    local s = tostring(v or ""):lower():match("^%s*(.-)%s*$")
    if s == "" or s == "fit" or s == "original" or s == "off" or s == "none" or s == "0" then return "fit" end
    if s == "fill" or s == "screen" or s == "display" then return "fill" end
    if s == "half" then return "half" end
    for _, l in ipairs(show_l) do if l:lower() == s then return l end end
    return nil
end
local show = show_norm(opts.show) or "fit"
local picked = false   -- v4.0.1: the user chose the crop (key, panel, script-message); until then it is the start crop
local auto_sel = false -- v4.0.3: crop mode auto = crop to the display ratio, gated (ratio_tol) and optionally clamped
local bars_auto = false   -- v4.2.0: Bars mode Auto = one-shot bar detection per file
local det = { idx = 0, label = nil, state = "", gen = 0, path = nil }   -- v4.2.0: this file's detection
local start_detect   -- forward (v4.2.0)
do
    local s = tostring(opts.start):lower():match("^%s*(.-)%s*$")
    if s == "" then   -- v4.2.0: start empty -> the bars option
        s = tostring(opts.crop ~= "" and opts.crop or opts.bars):lower():match("^%s*(.-)%s*$")   -- v4.4.0 crop = bars
        if s == "auto" or s == "detect" or s == "" then bars_auto = true; s = "original" end
    end
    if s == "auto" then s = "original"; if show == "fit" then show = "fill" end end   -- v4.1.1 compatibility (Fill)
    for i, l in ipairs(labels) do if l:lower() == s then idx = i end end
    if idx == 0 and not (s == "original" or s == "off" or s == "none" or s == "0") then
        local n = tonumber(s); if n and n >= 1 and n <= #presets and n % 1 == 0 then idx = n end
    end
end
local use_vsr, use_hdr = opts.vsr, opts.hdr
local vsr_block = false   -- v4.5.0: the stutter guard turned VSR off for this file
local last_sig = nil
local last_parts = {}   -- v4.6.0: the crop / rtx / luma strings of the last full build
local applying = false
local want = {}          -- labels we expect in vf after the last apply
local retries = 0

-- Display mode: mpv logs the DXGI output colourspace at every video-output init.
local disp_hdr = (opts.hdr_display == "yes")
local disp_known = (opts.hdr_display ~= "auto")
local apply   -- forward
local redo_pre   -- forward (v3.2.9)
local recheck_hold   -- forward (v3.2.9)
local pv = { used = false, verified = true }   -- v3.2.9: pre-build used the cached display mode / mode confirmed
local mpv_hdr = nil      -- v3.3: the mode mpv's video output read at its init (its swapchain and HDR passthrough follow it)
local os_hdr = nil       -- v3.3: the mode Windows reports now (OS re-check), nil = not checked
local rtx_dev = true     -- v3.3.1: video device is NVIDIA RTX (from mpv's "Device Name" log line; assumed until read)

-- v3.2.9: last known display (size, HDR mode), for the build before the video output exists. Written on change.
local DSTORE = opts.display_store ~= "" and mp.command_native({ "expand-path", opts.display_store }) or nil
local last_disp = {}
if DSTORE then
    local fh = io.open(DSTORE, "r")
    local l = fh and fh:read("*l") or ""
    if fh then fh:close() end
    local w, h, hd = l:match("^(%d+)x(%d+) (%d)")
    if w then last_disp = { w = tonumber(w), h = tonumber(h), hdr = hd == "1" } end
end
local function store_display(w, h, hdr)
    local n = { w = w or last_disp.w, h = h or last_disp.h }
    if hdr == nil then n.hdr = last_disp.hdr else n.hdr = hdr end
    if n.w == last_disp.w and n.h == last_disp.h and n.hdr == last_disp.hdr then return end
    last_disp = n
    if not (DSTORE and n.w and n.h and n.hdr ~= nil) then return end
    local fh = io.open(DSTORE, "w")
    if fh then fh:write(string.format("%dx%d %d\n", n.w, n.h, n.hdr and 1 or 0)); fh:close() end
end

-- ICC only on an SDR display. With Windows HDR on, mpv's swapchain is PQ/BT.2020, but icc-profile-auto=yes made
-- libplacebo encode to the ICC profile (target srgb/bt.709, 80 nits), so HDR video was tone-mapped to SDR and SDR
-- 80 nits; ICC off -> target pq bt.2020 441 nits. The display mode is the live read, else the cached one.
local hdr_running = false
local icc_user = mp.get_property_bool("icc-profile-auto", false)   -- v3.3.1: the user's own setting at start
local function set_icc(hdr_running_now)
    local m = tostring(opts.icc_sdr):lower()
    if m == "no" or m == "false" then return end
    local disp_is_hdr = (disp_known and disp_hdr) or (not disp_known and last_disp.hdr == true)
    local wanted = (icc_user or m == "yes" or m == "true") and not hdr_running_now and not disp_is_hdr   -- auto: off stays off
    if mp.get_property_bool("icc-profile-auto") ~= wanted then
        mp.set_property_bool("icc-profile-auto", wanted)
        mp.msg.info("icc-profile-auto=" .. (wanted and "yes" or "no") .. (hdr_running_now and " (RTX HDR running)"
            or disp_is_hdr and " (HDR display)" or " (SDR display, RTX HDR not running)"))
    end
end

-- v3.3.1/v3.3.2: the video device must be an NVIDIA RTX GPU (mpv logs its d3d11 "Device Name" at video-output init);
-- read whatever hdr_display is set to
mp.enable_messages("v")
-- v4.6.1 (audit F6): both lines come once, at video-output start; then the v-level subscription ends (it delivered every
-- v message of the player to this script)
local logs_seen = {}
local function logs_done()
    if logs_seen.dev and (logs_seen.cs or opts.hdr_display ~= "auto") then
        mp.add_timeout(0, function() mp.enable_messages("no") end)
    end
end
mp.register_event("log-message", function(e)
    if e.prefix ~= "vo/gpu-next/d3d11" and e.prefix ~= "vo/gpu/d3d11" then return end
    local dn = e.text:match("^Device Name: (.-)%s*$")
    if not dn then return end
    logs_seen.dev = true; logs_done()
    local ok = dn:find("NVIDIA", 1, true) ~= nil and dn:find("RTX", 1, true) ~= nil
    if ok ~= rtx_dev then rtx_dev = ok; last_sig = nil; mp.add_timeout(0, function() apply(false) end) end
    if not ok then mp.msg.info("no NVIDIA RTX device (" .. dn .. "): VSR and RTX HDR off") end
end)
if opts.hdr_display == "auto" then
    mp.register_event("log-message", function(e)
        if e.prefix ~= "vo/gpu-next/d3d11" and e.prefix ~= "vo/gpu/d3d11" then return end
        local cs = e.text:match("Queried output: .-colorspace: (%S+)")
        if not cs then return end
        logs_seen.cs = true; logs_done()
        local h = cs:find("G2084", 1, true) ~= nil
        mpv_hdr = h
        local was_known = disp_known
        disp_known = true
        if not was_known and h == disp_hdr then mp.add_timeout(0, function() apply(false) end) end   -- republish state
        store_display(nil, nil, h)
        mp.msg.verbose("display mode read: " .. (h and "HDR" or "SDR") .. (h ~= disp_hdr and " (differs)" or ""))
        if h == disp_hdr then pv.verified = true; if recheck_hold then mp.add_timeout(0, recheck_hold) end end
        if h ~= disp_hdr then
            disp_hdr = h
            last_sig = nil
            -- v3.2.9: a pre-build made with a stale cached display mode is rebuilt at once from the same data (the
            -- video output reports its mode before the decoder starts), behind the start hold.
            mp.add_timeout(0, function()
                if not (redo_pre and redo_pre()) then apply(false) end
                pv.verified = true
                if recheck_hold then recheck_hold() end
            end)
        end
    end)
end
-- v4.0.0: the Windows side (OS query, Windows HDR switch, restore records) lives in winhdr.lua - local, optional,
-- not part of this script. It publishes user-data/winhdr {os_hdr, os_cap, seq, mode, last}; this script only reads
-- it. Without winhdr.lua the display mode is mpv's own read (above), else the last known one (display_store).
local os_seq = nil
local function sync_os()
    if opts.hdr_display ~= "auto" then return end
    local w = mp.get_property_native("user-data/winhdr")
    if type(w) ~= "table" or w.seq == nil or w.seq == os_seq then return end
    os_seq = w.seq
    if type(w.os_hdr) ~= "boolean" then os_hdr = nil; return end
    local h = w.os_hdr
    os_hdr = h
    local eff = h and mpv_hdr ~= false            -- HDR only if mpv's swapchain is HDR too (or not started yet)
    if disp_known and eff == disp_hdr then return end
    disp_hdr, disp_known = eff, true
    if mpv_hdr == nil then store_display(nil, nil, h) end
    last_sig = nil
    apply(false)
end
mp.observe_property("user-data/winhdr", "native", function() sync_os() end)
local function recheck(why) mp.commandv("script-message", "winhdr-recheck", why) end   -- no-op without winhdr.lua
-- mpv's own read can be missed when its video output starts before this script listens (seen once in a test run):
-- 1.5 s after the file loaded, take the renderer's target (PQ = HDR swapchain; not with ICC on, whose target is the
-- profile), and ask winhdr.lua if it is loaded.
mp.register_event("file-loaded", function()
    mp.add_timeout(1.5, function()
        if disp_known or opts.hdr_display ~= "auto" then return end
        recheck("unread")
        local t = mp.get_property_native("video-target-params")
        if not (t and t.gamma) or mp.get_property_bool("icc-profile-auto") then return end
        mpv_hdr = t.gamma == "pq"; disp_known = true
        mp.msg.verbose("display mode from the render target: " .. (mpv_hdr and "HDR" or "SDR"))
        if mpv_hdr ~= disp_hdr then disp_hdr = mpv_hdr; last_sig = nil end
        store_display(nil, nil, mpv_hdr)
        apply(false)
    end)
end)

set_icc(false)   -- no RTX HDR before the first apply
mp.register_event("end-file", function() hdr_running = false; set_icc(false) end)

local function rtx_ok()
    return (not opts.fullscreen_only) or mp.get_property_bool("fullscreen", false)
end
local hdr_win = opts.hdr_windowed   -- v4.3.0: runtime state of hdr_windowed (Alt+h / panel)
do   -- v4.4.0: hdr_mode overrides hdr + hdr_windowed when set
    local m = tostring(opts.hdr_mode):lower():match("^%s*(.-)%s*$")
    if m == "off" or m == "no" then use_hdr = false
    elseif m == "fullscreen" or m == "drop" then use_hdr, hdr_win = true, false
    elseif m == "always" or m == "keep" then use_hdr, hdr_win = true, true end
end
local function hdr_ok() return hdr_win or rtx_ok() end   -- RTX HDR only; VSR keeps rtx_ok()

local function even(n) return 2 * math.floor(n / 2 + 0.5) end

local OURS = { ar_crop = true, ar_rtx = true, ar_luma = true }

local function remove_ours()
    for _, f in ipairs(mp.get_property_native("vf", {})) do
        if f.label and OURS[f.label] then
            mp.commandv("vf", "remove", "@" .. f.label)
        end
    end
end

-- RTX HDR peak tag (v3.2.5): fixed number, or the live display peak (video-target-params max-luma from a PQ
-- target = the stats "Display:" value). With ICC on (v3.2.2) the target is the profile (sRGB, 80 nits), not the
-- display, so only PQ targets count. The last known value is stored so RTX HDR starts at the right tag.
local FALLBACK_PEAK = 600          -- only when no display peak was ever read
local STORE = opts.peak_store ~= "" and mp.command_native({ "expand-path", opts.peak_store }) or nil
local disp_peak, disp_src = nil, nil
if STORE then
    local fh = io.open(STORE, "r")
    local v = fh and tonumber(fh:read("*l") or "")
    if fh then fh:close() end
    -- v4.6.0: 10000 is mpv's placeholder for an unread display, and readings above peak_max are not plausible
    if v and v >= 80 and v < 10000 and v <= opts.peak_max then disp_peak, disp_src = math.floor(v + 0.5), "display, last known" end
    mp.msg.verbose("display peak store " .. STORE .. ": " .. tostring(disp_peak or "empty"))
end
local function store_peak(v)
    if not STORE then return end
    local fh = io.open(STORE, "w")
    if fh then fh:write(tostring(v), "\n"); fh:close() else mp.msg.verbose("display peak store not writable: " .. STORE) end
end
-- Read the live display peak; adopt it when it differs from the current value by more than 5 nits (hysteresis,
-- so rounding noise like 440.66 vs 441 never rebuilds the chain).
local implausible_said = false
local function read_display_peak()
    local t = mp.get_property_native("video-target-params")
    local m = t and t.gamma == "pq" and tonumber(t["max-luma"])
    if not (m and m >= 80 and m < 10000) then return false end
    if m > opts.peak_max then
        if not implausible_said then implausible_said = true; mp.msg.verbose(string.format("display peak %d nits ignored (above peak_max %d)", m, opts.peak_max)) end
        return false
    end
    m = math.floor(m + 0.5)
    if disp_peak and disp_src == "display" and math.abs(m - disp_peak) <= 5 then return false end
    local moved = (disp_peak == nil) or math.abs(m - disp_peak) > 5
    mp.msg.verbose(string.format("display peak read %d nits (was %s, %s)", m, tostring(disp_peak or "unknown"),
        moved and "re-tag" or "confirmed, no re-tag"))
    if moved then disp_peak = m; store_peak(m) end
    disp_src = "display"
    return moved
end

local function peak_nits()
    local n = tonumber(opts.hdr_peak)
    if n and n > 0 then return math.floor(n + 0.5), "fixed" end
    read_display_peak()
    if disp_peak then return disp_peak, disp_src end
    return FALLBACK_PEAK, "fallback"
end

local function publish(state)
    mp.set_property_native("user-data/aspect_rtx", state)
    -- v4.4.1: background work for the panel's activity line (rtx-panel >= v3.1.0): bar detection running
    mp.set_property_native("user-data/activity/aspect_rtx", { busy = det.state == "detecting", word = "finding bars",
        detail = (det.state == "detecting") and "looking for black bars in the picture (Crop Auto)" or "",
        mark = vsr_block and "VSR off: stutter" or nil })
end

apply = function(force, pre)
    if applying then return end
    local d = pre or mp.get_property_native("video-dec-params")
    if not (mp.get_property("path") and d and d.w and d.h) then return end
    local hw = pre and pre.hw or mp.get_property("hwdec-current", "")
    if hw == "" then return end                       -- decoder not up yet; observer re-fires
    local gpu = (hw == "d3d11va" or hw == "d3d11va-copy")   -- else (software etc.): crop only, no RTX
    local dw = mp.get_property_number("display-width")
    local dh = mp.get_property_number("display-height")
    if dw and dh then store_display(dw, dh, nil) elseif pre then dw, dh = pre.dw, pre.dh end
    if not (dw and dh) then return end

    local w, h = d.w, d.h
    local cw, ch, x, y = w, h, 0, 0
    local crop_na = ""
    local rot = ((tonumber(d.rotate) or 0) % 180) == 90   -- v4.0.2: shown rotated by 90/270
    local show_na = ""
    local dar = (d.aspect and d.aspect > 0) and d.aspect or (w / h)   -- display aspect (handles non-square pixels)
    if rot then dar = 1 / dar end      -- v4.0.2: the picture as displayed (renderer rotates after the filters)
    local disp_r = dw / dh
    local disp_a = parse_ratio(tostring(opts.display_aspect or ""))   -- v4.2.0: override for Half / Fill
    if disp_a and disp_a > 0 then disp_r = disp_a end
    local fx, fy = 1, 1                -- v4.1.0: kept fraction of the displayed width / height
    local bidx = bars_auto and det.idx or idx   -- v4.2.0: Bars Auto uses the detected preset
    if bars_auto and det.state ~= "" then crop_na = det.state end
    if bidx > 0 or auto_sel then
        local r = presets[bidx]
        -- v4.0.3: only crop mode auto (display ratio) is gated and optionally clamped; a preset - the fixed start one
        -- or one the user picked - applies its exact ratio. A start crop skips portrait pictures.
        if auto_sel then r = disp_r end
        if (auto_sel or not picked) and dar < 1 then
            crop_na = "portrait picture"
        elseif auto_sel and math.abs(dar - disp_r) <= (tonumber(opts.ratio_tol) or 0.02) * disp_r then
            crop_na = "fits the display"
        elseif auto_sel and opts.clamp and dar < disp_r then
            crop_na = "narrower than the display"
        else
            if r < dar - 0.005 then fx = r / dar          -- narrower target: cut the displayed sides
            elseif r > dar + 0.005 then fy = dar / r end  -- wider target: cut the displayed top/bottom (bars)
        end
    end
    -- v4.1.0 step 2, Show as: cut the sides of the step-1 picture to the target ratio; never top/bottom
    local bars_cut = (fx < 1 or fy < 1)
    local fx1 = fx
    local c = dar * fx / fy                -- displayed ratio of the picture after step 1
    local show_ratio = c                   -- v4.2.0: the ratio Show as aims at (Fit = the picture as it is)
    if show == "half" or show == "fill" then
        -- v4.2.0: only a picture wider than the screen is cut; never top/bottom to fill a narrower one
        local tol = (tonumber(opts.ratio_tol) or 0.02) * disp_r
        show_ratio = (show == "fill") and disp_r or math.sqrt(c * disp_r)
        if math.abs(c - disp_r) <= tol then show_na = "fits the display"; show_ratio = c
        elseif c < disp_r then show_na = "picture not wider than the screen"; show_ratio = c
        else fx = fx * show_ratio / c end
    elseif show ~= "fit" then
        local sr; for i, l in ipairs(show_l) do if l == show then sr = show_r[i] end end
        if sr and sr < c - 0.005 then fx = fx * sr / c; show_ratio = sr
        elseif sr and sr > c + 0.005 then show_na = "wider than the picture" end
    end
    local show_cut = fx < fx1
    -- map to the coded frame: displayed width = coded width, or coded height when rotated by 90/270; never past it
    local kw, kh = fx, fy
    if rot then kw, kh = fy, fx end
    if kw < 1 then cw = math.min(w, even(w * kw)); x = even((w - cw) / 2) end
    if kh < 1 then ch = math.min(h, even(h * kh)); y = even((h - ch) / 2) end
    local cropped = (cw ~= w or ch ~= h)
    -- A physical crop needs copy-back frames (with zero-copy d3d11va the crop is metadata only and RTX would
    -- process the full frame). mpv.conf keeps d3d11va-copy on always; this flip is only a fallback.
    if cropped and gpu and hw == "d3d11va" then
        mp.set_property("hwdec", "d3d11va-copy")   -- re-triggers apply()
        return
    end

    local pf = d["hw-pixelformat"] or d.pixelformat or ""
    local is_sdr = not (d.primaries == "bt.2020" or d.gamma == "pq" or d.gamma == "hlg")
    local is_10 = pf:find("10") ~= nil

    local scale = math.floor((rot and math.min(dw / ch, dh / cw) or math.min(dw / cw, dh / ch)) * 10) / 10
    local vsr = use_vsr and not vsr_block and gpu and rtx_dev and rtx_ok() and scale > 1 and scale >= opts.vsr_min_scale
    local hdr = use_hdr and gpu and rtx_dev and is_sdr and hdr_ok() and disp_hdr

    local rtx = nil
    if vsr or hdr then
        local p = {}
        if vsr then
            p[#p + 1] = "scaling-mode=nvidia"
            p[#p + 1] = "scale=" .. scale
        end
        local fmt
        if opts.pix_fmt ~= "auto" then fmt = opts.pix_fmt
        elseif hdr then fmt = is_10 and "x2bgr10" or nil   -- nv12 blocks HDR activation
        else fmt = is_10 and "nv12" or nil end
        if fmt then p[#p + 1] = "format=" .. fmt end
        if hdr then p[#p + 1] = "nvidia-true-hdr" end
        rtx = "@ar_rtx:d3d11vpp=" .. table.concat(p, ":")
    end
    local crop = cropped and
        string.format("@ar_crop:lavfi=[crop=%d:%d:%d:%d]", cw, ch, x, y) or nil
    local peak, peak_src = peak_nits()
    local luma = (hdr and opts.luma) and ("@ar_luma:format=max-luma=" .. peak) or nil

    local sig = (crop or "") .. "|" .. (rtx or "") .. "|" .. (luma or "")
    -- State for rtx-panel.lua (v3.2.1): published on every apply, including the unchanged-signature path.
    local vsr_na = (use_vsr and vsr_block and "stutter: off for this file") or (not rtx_dev and "no RTX GPU") or (not gpu and "software decode") or (scale <= 1 and "no upscale") or (scale < opts.vsr_min_scale and "scale too small") or (not rtx_ok() and "windowed") or ""
    local hdr_na = (not rtx_dev and "no RTX GPU") or (not is_sdr and "HDR source") or (not gpu and "software decode")
        or (not disp_hdr and ((os_hdr and mpv_hdr == false) and "restart mpv (HDR turned on)" or disp_known and "Windows HDR off" or "display not read")) or (not hdr_ok() and "windowed") or ""
    local state = { crop = crop ~= nil, rtx = rtx ~= nil, vsr = vsr, hdr = hdr, display_hdr = disp_hdr,
        display = disp_known and ("display " .. ((os_hdr ~= nil and os_hdr or disp_hdr) and "HDR" or "SDR")) or "display not read",
        crop_mode = bars_auto and "detect" or auto_sel and "auto" or idx > 0 and labels[idx] or "original", bars_det = det.label, vsr_want = use_vsr, hdr_want = use_hdr, scale = scale,
        vsr_na = vsr_na, hdr_na = hdr_na, peak = luma and peak or nil, peak_src = luma and peak_src or nil, sig = sig,
        presets = labels, crop_na = crop_na, mpv_hdr = mpv_hdr,
        show = show, show_presets = show_l, show_na = show_na, bars_cut = bars_cut, show_cut = show_cut,
        show_ratio = math.floor(show_ratio * 100 + 0.5) / 100, hdr_windowed = hdr_win }
    local hdr_msg = hdr and "on" or (not use_hdr and "off") or (not rtx_dev and "n/a (no RTX GPU)") or (not is_sdr and "n/a (HDR source)")
        or (not disp_hdr and (disp_known and "n/a (Windows HDR off)" or "n/a (display not read yet)"))
        or (not hdr_ok() and "paused (windowed)") or (not gpu and "n/a (software decode)") or "off"
    local msg = string.format("Bars %s \194\183 Show %s  %dx%d | VSR %s | HDR %s",
        bars_auto and ("Auto" .. (det.label and (" " .. det.label) or "") .. (crop_na ~= "" and (" (" .. crop_na .. ")") or ""))
            or (auto_sel or idx > 0) and ((auto_sel and "auto" or labels[idx]) .. (crop_na ~= "" and (" (" .. crop_na .. ")") or "")) or "off",
        (show:sub(1, 1):upper() .. show:sub(2)) .. (show_na ~= "" and (" (" .. show_na .. ")")
            or ((show == "fit" or show == "half" or show == "fill") and string.format(" (%.2f)", show_ratio)) or ""), cw, ch, vsr and (scale .. "x") or (not rtx_dev and use_vsr and "n/a (no RTX GPU)") or "off", hdr_msg)
    if sig ~= last_sig then retries = 0 end
    -- v3.2.2: ICC on unless RTX HDR is applied. Order: ICC off BEFORE RTX HDR starts; ICC on only ~0.3 s AFTER it
    -- stops, so PQ frames still in flight are not tone-mapped to the profile's 80-nit white (seen in test b_rtxhdr).
    hdr_running = hdr
    if hdr or sig == last_sig then set_icc(hdr) end
    if sig == last_sig and not force then publish(state); return msg end

    -- v4.6.0 (pipeline audit F4): only the peak tag changed -> replace @ar_luma alone; mpv keeps the unchanged
    -- @ar_crop / @ar_rtx instances, so RTX HDR is not re-initialised (was one d3d11vpp re-init per open)
    local lp = last_parts
    if not force and last_sig and lp.crop == crop and lp.rtx == rtx and lp.luma and luma and lp.luma ~= luma then
        applying = true
        mp.commandv("vf", "remove", "@ar_luma")
        mp.commandv("vf", "append", luma)
        lp.luma = luma; last_sig = sig
        applying = false
        mp.msg.info("RTX HDR peak re-tag " .. peak .. " nits (" .. peak_src .. "), chain kept")
        publish(state)
        return msg
    end
    applying = true
    remove_ours()
    last_parts = { crop = crop, rtx = rtx, luma = luma }
    if crop then mp.commandv("vf", "append", crop) end
    if rtx then mp.commandv("vf", "append", rtx) end
    if luma then mp.commandv("vf", "append", luma) end
    want = { ar_crop = crop ~= nil, ar_rtx = rtx ~= nil, ar_luma = luma ~= nil }
    last_sig = sig
    applying = false
    if luma then mp.msg.info("RTX HDR peak tag " .. peak .. " nits (" .. peak_src .. ")") end
    if not hdr then mp.add_timeout(0.3, function() if not hdr_running then set_icc(false) end end) end
    publish(state)
    return msg
end

-- Re-apply if mpv dropped one of our filters (e.g. "Disabling filter ar_crop because it has failed").
mp.observe_property("vf", "native", function(_, vf)
    if applying or not last_sig then return end
    local have = {}
    for _, f in ipairs(vf or {}) do if f.label and OURS[f.label] then have[f.label] = true end end
    for l in pairs(OURS) do
        if (want[l] or false) ~= (have[l] or false) then
            if retries < 3 then
                retries = retries + 1
                mp.msg.warn("filter chain lost @" .. l .. "; re-applying (try " .. retries .. ")")
                mp.add_timeout(0.3, function() last_sig = nil; apply(true) end)
            elseif retries == 3 then
                retries = 4
                mp.msg.error("filter chain could not be restored (@" .. l .. ")")
                mp.osd_message("aspect-rtx: filter @" .. l .. " failed", 3)
            end
            return
        end
    end
end)

local function say()
    local m = apply(true)
    if m then mp.osd_message(m, 2) end
end

mp.add_key_binding("Alt+a", "ar-cycle", function()
    picked = true; auto_sel = false; bars_auto = false; idx = (idx + 1) % (#presets + 1); say() end)
mp.add_key_binding("Alt+0", "ar-off", function() picked = true; auto_sel = false; bars_auto = false; idx = 0; say() end)
mp.add_key_binding("Alt+1", "ar-1", function() picked = true; auto_sel = false; bars_auto = false; idx = 0; say() end)
local function by_name(n) for i, l in ipairs(labels) do if l == n then return i end end end
mp.add_key_binding("Alt+2", "ar-2", function() local i = by_name("16:9"); if i then picked = true; auto_sel = false; bars_auto = false; idx = i; say() end end)
mp.add_key_binding("Alt+3", "ar-3", function() local i = by_name("1.9"); if i then picked = true; auto_sel = false; bars_auto = false; idx = i; say() end end)
-- mpv writes shifted letters as uppercase (Ctrl+R = Ctrl+Shift+r), so bind both spellings.
local function bind2(k1, k2, name, fn)
    mp.add_key_binding(k1, name, fn)
    mp.add_key_binding(k2, name .. "-b", fn)
end
bind2("Ctrl+Shift+R", "Ctrl+R", "ar-vsr", function() use_vsr = not use_vsr; say() end)
bind2("Ctrl+Shift+H", "Ctrl+H", "ar-hdr", function() use_hdr = not use_hdr; say() end)
-- v4.3.0: RTX HDR in a window, keep | drop (VSR stays fullscreen-only)
local function set_hdr_win(b)
    hdr_win = b
    local m = apply(true)
    mp.osd_message("RTX HDR in window: " .. (b and "Keep" or "Drop") .. (m and ("\n" .. m) or ""), 2)
end
mp.add_key_binding("Alt+h", "ar-hdr-windowed", function() set_hdr_win(not hdr_win) end)
-- v3.2.7: direct choices (rtx-panel v2). No-op when the value is already set (no rebuild, no OSD).
local function yes(v) v = tostring(v or ""):lower(); return v == "yes" or v == "on" or v == "true" or v == "1" end
mp.register_script_message("set-crop", function(v)
    local s = tostring(v or ""):lower()
    local i = 0
    if s == "detect" then     -- v4.2.0: Bars Auto (one-shot detection; runs now if this file has none yet)
        if not bars_auto or not picked then
            picked = true; auto_sel = false; bars_auto = true; idx = 0
            if det.path ~= mp.get_property("path") and start_detect then start_detect() end
            say()
        end
        return
    end
    local a = (s == "auto")   -- v4.1.1: compatibility - Bars off + Show as Fill
    if a then
        if idx ~= 0 or show ~= "fill" or not picked then picked = true; auto_sel = false; bars_auto = false; idx = 0; show = "fill"; say() end
        return
    end
    if not (a or s == "original" or s == "off" or s == "none" or s == "0") then
        for j, l in ipairs(labels) do if l:lower() == s then i = j end end
        if i == 0 then mp.msg.warn("set-crop: unknown preset '" .. tostring(v) .. "'"); return end
    end
    -- v4.0.1: picking the preset already shown (e.g. the gated start preset) makes it apply too
    if i ~= idx or not picked then picked = true; auto_sel = false; bars_auto = false; idx = i; say() end
end)
-- v4.1.0/v4.2.0: Show as (fit | half | fill | a show_presets label; aliases original, screen); carries to the next file
mp.register_script_message("set-show", function(v)
    local n = show_norm(v)
    if not n then mp.msg.warn("set-show: unknown value '" .. tostring(v) .. "'"); return end
    if n ~= show then show = n; say() end
end)
mp.register_script_message("set-vsr", function(v) local b = yes(v); if b ~= use_vsr then use_vsr = b; say() end end)
mp.register_script_message("set-hdr-windowed", function(v) local b = yes(v); if b ~= hdr_win then set_hdr_win(b) end end)
-- v4.4.0: RTX HDR as one three-way setting (panel row RTX HDR Off | Fullscreen | Always); one rebuild
mp.register_script_message("set-hdr-mode", function(v)
    v = tostring(v or ""):lower()
    local h, w = true, hdr_win
    if v == "off" or v == "no" then h = false
    elseif v == "fullscreen" or v == "drop" then w = false
    elseif v == "always" or v == "keep" then w = true
    else return end
    recheck("panel")
    if h == use_hdr and w == hdr_win then return end
    use_hdr, hdr_win = h, w
    say()
end)
mp.register_script_message("set-hdr", function(v) local b = yes(v); recheck("panel"); if b ~= use_hdr then use_hdr = b; say() end end)
bind2("Ctrl+Shift+S", "Ctrl+S", "ar-status", function()
    mp.osd_message("vf: " .. mp.get_property("vf", "none") .. "\nhwdec: " ..
        mp.get_property("hwdec-current", "none") .. "\ndisplay: " ..
        (disp_known and (disp_hdr and "HDR" or "SDR") or "unknown") .. " | csp: " ..
        mp.get_property("d3d11-output-csp", "?") .. " | icc: " .. tostring(mp.get_property_bool("icc-profile-auto")), 5)
end)

-- v3.2.5: no forced rebuild on file-loaded (it built the chain a second time at every start). mpv keeps the vf list
-- across files; apply() rebuilds when the chain must change, and the vf observer restores a dropped filter.
publish({ presets = labels, crop_mode = bars_auto and "detect" or auto_sel and "auto" or idx > 0 and labels[idx] or "original", vsr_want = use_vsr, hdr_want = use_hdr,
    show = show, show_presets = show_l })

-- v3.2.8 start hold: playback starts paused and resumes once the video output runs at the chain's size, so the
-- first played frame is already filtered and audio starts with it. Without it, the chain often landed after the
-- first frame (mpv delivers decoder data late while it opens the audio device): rebuild, +0.3-1 s, A/V spike.
-- No guessing: release is driven by the real video-out-params. Never holds a file the user started paused;
-- releases on no video, end-file, or after hold_max seconds.
local HOLD_MAX = 3
local hold = { active = false, timer = nil }
-- v3.3.1 (review nit): the user pressing pause during the hold ends it; the release then leaves pause alone.
mp.observe_property("pause", "bool", function(_, p)
    if hold.active and p == false then
        hold.active = false; mp.set_property_native("user-data/start_hold/aspect_rtx", false)
        if hold.timer then hold.timer:kill(); hold.timer = nil end
        mp.msg.verbose("start hold cancelled (pause changed by the user)")
    end
end)
local function release(why)
    if not hold.active then return end
    hold.active = false; mp.set_property_native("user-data/start_hold/aspect_rtx", false)
    if hold.timer then hold.timer:kill(); hold.timer = nil end
    -- v4.5.2: another script still holds the start (peak.lua pre-roll): it starts playback when it is done
    for k, v in pairs(mp.get_property_native("user-data/start_hold") or {}) do
        if v == true then mp.msg.verbose("start hold released (" .. why .. "), " .. k .. " still holds"); return end
    end
    mp.set_property_bool("pause", false)
    mp.msg.verbose("start hold released (" .. why .. ")")
end
mp.add_hook("on_preloaded", 50, function()
    if mp.get_property_bool("pause") then return end
    hold.active = true; hold.loaded = false
    mp.set_property_native("user-data/start_hold/aspect_rtx", true)   -- v4.5.2: shared start-hold flags
    mp.set_property_bool("pause", true)
    -- v3.2.9: the safety timeout starts at file-loaded (below), not here: the GPU context is created between these
    -- two points and took 7-9 s on a paging system (live check 2026-11-22), which ran a timer started here out.
end)
mp.register_event("end-file", function() release("end-file") end)
local function check_hold()
    if not (hold.active and hold.loaded) then return end
    if pv.used and not pv.verified then return end   -- v3.2.9: wait until the cached display mode is confirmed
    local t = mp.get_property_native("current-tracks/video")
    if t == nil or t.image or t.albumart then release("no video"); return end
    local st = mp.get_property_native("user-data/aspect_rtx")
    local o = mp.get_property_native("video-out-params")
    if not (st and st.sig and o and o.w and last_sig) then return end
    if st.sig == "||" then release("no chain"); return end
    local have = {}
    for _, f in ipairs(mp.get_property_native("vf", {})) do if f.label then have[f.label] = true end end
    if (want.ar_rtx and not have.ar_rtx) or (want.ar_crop and not have.ar_crop) then return end
    local d = mp.get_property_native("video-dec-params") or {}
    -- the chain is live once the output size is no longer the decoder size (VSR) or equals the crop (crop only)
    if want.ar_rtx and st.vsr then
        if o.w ~= d.w or o.h ~= d.h then release("chain up") end
    elseif want.ar_crop and not want.ar_rtx then
        if o.w ~= d.w or o.h ~= d.h then release("crop up") end
    else
        release("chain set (no resize)")
    end
end
mp.observe_property("video-out-params", "native", check_hold)
mp.observe_property("user-data/aspect_rtx", "native", check_hold)
mp.register_event("file-loaded", function()
    hold.loaded = true
    if hold.active and not hold.timer then hold.timer = mp.add_timeout(HOLD_MAX, function() release("timeout") end) end
    check_hold()
end)
recheck_hold = check_hold

-- v3.2.9 pre-build: the chain is built before mpv creates the video output and the decoder, so the first decoded
-- frame already goes through it and the hold above releases at the first output config (no rebuild). Inputs:
-- ffprobe (started at on_load, in parallel with mpv opening the file) for bit depth and colour; track-list for size
-- and pixel aspect; the last known display size and HDR mode. The later apply() with the real decoder data changes
-- nothing when these matched; otherwise it rebuilds once (behind the hold) as before.
local utils = require 'mp.utils'
local probe = { done = true, info = nil, waiting = nil }
local function dv_profile(s)
    for _, d in ipairs(s and s.side_data_list or {}) do if d.dv_profile then return tonumber(d.dv_profile) end end
end
local function prebuild()
    local function skip(why) mp.msg.verbose("pre-build skipped: " .. why) end
    if mp.get_property("hwdec", "") ~= "d3d11va-copy" then return skip("hwdec is not d3d11va-copy") end
    -- the display mode is read from the d3d11 output: only with gpu-context/gpu-api unset (auto/empty list) or d3d11
    local function d3d(v) v = tostring(v or ""); return v == "" or v == "auto" or v:find("d3d11", 1, true) ~= nil end
    local ctx, api = mp.get_property("gpu-context", ""), mp.get_property("gpu-api", "")
    if not (d3d(ctx) and d3d(api)) then return skip("gpu-context '" .. ctx .. "', gpu-api '" .. api .. "'") end
    if not (probe.info and probe.info.streams) then return skip("no ffprobe data") end
    if not (last_disp.w and last_disp.h) then return skip("display size not known yet") end
    local vid = mp.get_property("vid", "auto")
    local t
    for _, x in ipairs(mp.get_property_native("track-list", {})) do
        if x.type == "video" and not x.albumart and not x.image then
            if tostring(x.id) == vid then t = x; break end
            if vid == "auto" and (t == nil or (x.default and not t.default)) then t = x end
        end
    end
    if not (t and t["demux-w"] and t["demux-h"]) then return skip("no video track size") end
    local s
    for _, x in ipairs(probe.info.streams) do
        if x.index == t["ff-index"] and x.codec_type == "video" then s = x end
    end
    if not s then return skip("ffprobe stream not matched") end
    if dv_profile(s) == 5 then return skip("Dolby Vision profile 5") end
    pv.used, pv.verified = true, disp_known   -- live mode already known (video output up) = nothing to confirm
    if not disp_known and last_disp.hdr ~= nil then disp_hdr = last_disp.hdr end
    local w, h, par = t["demux-w"], t["demux-h"], tonumber(t["demux-par"]) or 1
    local tr = s.color_transfer
    probe.pre = { w = w, h = h, aspect = w * par / h, rotate = tonumber(t["demux-rotation"]) or 0, hw = "d3d11va-copy", dw = last_disp.w, dh = last_disp.h,
        pixelformat = s.pix_fmt or "", primaries = s.color_primaries == "bt2020" and "bt.2020" or nil,
        gamma = (tr == "smpte2084" and "pq") or (tr == "arib-std-b67" and "hlg") or nil }
    local m = apply(false, probe.pre)
    mp.msg.verbose("pre-build: " .. tostring(m))
end
redo_pre = function()
    if not (probe.pre and hold.active) then return false end
    local m = apply(true, probe.pre)
    mp.msg.info("pre-build redone, display mode differed from the cache: " .. tostring(m))
    return true
end
-- v3.3.1 (review F5): ffprobe as an absolute path. A bare name is looked up in PATH folders only (absolute ones),
-- never in mpv's current folder (Windows CreateProcess searches it before PATH).
local ff_exe = nil
local function resolve_exe(p)
    p = mp.command_native({ "expand-path", p })
    if p:find("[/\\]") then return p end
    local name = p:lower():find("%.exe$") and p or (p .. ".exe")
    for dir in (os.getenv("PATH") or ""):gmatch("[^;]+") do
        dir = dir:gsub('"', "")
        if dir:match("^%a:[/\\]") or dir:match("^[/\\][/\\]") then
            local f = dir:gsub("[/\\]+$", "") .. "\\" .. name
            local fh = io.open(f, "rb")
            if fh then fh:close(); return f end
        end
    end
    return ""
end
mp.add_hook("on_load", 50, function()
    probe.done, probe.info, probe.pre = true, nil, nil
    probe.gen = (probe.gen or 0) + 1
    local gen = probe.gen
    pv.used, pv.verified = false, true
    local path = mp.get_property("path", "")
    if opts.prebuild == "" or path == "" or path:find("://", 1, true) then return end
    if ff_exe == nil then
        ff_exe = resolve_exe(opts.prebuild)
        if ff_exe == "" then mp.msg.warn("pre-build: ffprobe '" .. opts.prebuild .. "' not found in PATH; pre-build off") end
    end
    if ff_exe == "" then return end
    probe.done = false
    local ff = ff_exe
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
        args = { ff, "-v", "error", "-select_streams", "v",
                 "-show_entries", "stream=index,codec_type,pix_fmt,color_primaries,color_transfer:stream_side_data=dv_profile",
                 "-of", "json", path } },
        function(ok, r)
            if gen ~= probe.gen then return end   -- answer for an earlier file (v3.3.1, review F6)
            probe.done = true
            if ok and r and r.status == 0 then probe.info = utils.parse_json(r.stdout or "") end
            if not probe.info then mp.msg.verbose("pre-build: ffprobe gave nothing (" .. tostring(r and r.error_string) .. ")") end
            if probe.waiting then local go = probe.waiting; probe.waiting = nil; go() end
        end)
end)
-- v4.0.0: pre-build at on_preloaded 40. winhdr.lua (if loaded) switches Windows HDR at on_preloaded 30 and publishes
-- the mode before it lets the load go on, so the switch is done when this runs; mpv creates its video output after.
mp.add_hook("on_preloaded", 40, function(hk)
    hk:defer()
    local finished = false
    local function go()
        if finished then return end
        finished = true
        sync_os(); prebuild(); hk:cont()
    end
    if probe.done then return go() end
    probe.waiting = go
    mp.add_timeout(1, function()   -- never wait longer than 1 s for ffprobe
        if probe.waiting == go then probe.waiting = nil; mp.msg.verbose("pre-build: ffprobe timeout"); go() end
    end)
end)

mp.register_event("file-loaded", function() apply(false) end)
-- v4.5.0 VSR stutter guard (see header)
local guard = { hist = {}, quiet_until = 0 }
-- v4.8.0 (pipeline audit, watchdog merge): smooth.lua v2.4.0 is the one reader of the drop counters and publishes
-- user-data/drops on change; the guard counts from that. Its own 1 s read stays only as a fallback without smooth.lua.
local function drop_total() return (mp.get_property_number("frame-drop-count") or 0) + (mp.get_property_number("vo-delayed-frame-count") or 0) end
local shared_reader = false
-- the shared path ticks only when the total changed, so it takes its baseline at the reset (one read per event)
local function guard_reset() guard.hist = {}; guard.last = shared_reader and drop_total() or nil; guard.quiet_until = mp.get_time() + opts.vsr_guard_settle end
mp.register_event("start-file", function() vsr_block = false; guard_reset() end)
mp.register_event("seek", guard_reset)
mp.register_event("playback-restart", guard_reset)
mp.observe_property("vf", "native", guard_reset)        -- every rebuild resets the counters
mp.observe_property("pause", "bool", guard_reset)
-- transition opens the settle window (vsr_guard_settle s): also fullscreen, window resize, audio output (re)init,
-- display mode / HDR switch (the events above cover start, seek, first frame, pause / pre-roll, any chain change)
for _, p in ipairs({ "fullscreen", "osd-dimensions", "audio-out-params", "display-fps", "user-data/winhdr" }) do
    mp.observe_property(p, "native", guard_reset)
end
local function guard_tick(n)
    if not opts.vsr_guard or vsr_block then return end
    local st = mp.get_property_native("user-data/aspect_rtx") or {}
    if not st.vsr or mp.get_property_bool("pause") or mp.get_property_bool("seeking") then guard.last = n; return end
    n = n or drop_total()
    local now = mp.get_time()
    if guard.last and n >= guard.last and now >= guard.quiet_until then guard.hist[#guard.hist + 1] = { now, n - guard.last } end
    guard.last = n
    local sum = 0
    for i = #guard.hist, 1, -1 do
        if now - guard.hist[i][1] < opts.vsr_guard_window then sum = sum + guard.hist[i][2] else table.remove(guard.hist, i) end
    end
    if sum >= opts.vsr_guard_frames then
        vsr_block = true
        mp.msg.info(string.format("VSR guard: %d dropped/delayed frames in %d s -> VSR off for this file", sum, opts.vsr_guard_window))
        apply(true)
        mp.osd_message("VSR off: stutter (this file)", 3)
    end
end
mp.observe_property("user-data/smooth", "native", function(_, v) shared_reader = v ~= nil end)
mp.observe_property("user-data/drops", "native", function(_, v) if shared_reader and v and v.c then guard_tick(v.c) end end)
mp.add_periodic_timer(1, function() if not shared_reader then guard_tick() end end)
-- v4.2.0 Bars Auto: one-shot burned-in bar detection per file (see header). Results only for the file they ran on.
mp.register_event("start-file", function() det.gen = det.gen + 1; det.idx, det.label, det.path = 0, nil, nil; det.state = bars_auto and "detecting" or "" end)
start_detect = function()
    local path = mp.get_property("path"); local dur = mp.get_property_number("duration")
    det.gen = det.gen + 1; local gen = det.gen
    det.idx, det.label, det.path = 0, nil, path
    local function done(state, i, label)
        if gen ~= det.gen then return end
        det.state, det.idx, det.label = state, i or 0, label
        mp.set_property_native("user-data/aspect_rtx_detect", { label = label or "", state = state, gen = gen })
        if bars_auto then local m = apply(false); if m then mp.osd_message(m, 2) end end   -- rebuilds only if the crop changed
    end
    if not path or path:match("^%a[%w+.-]*://") then return done("stream") end
    local v; for _, x in ipairs(mp.get_property_native("track-list") or {}) do if x.type == "video" and x.selected then v = x end end
    if not (dur and dur > 0 and v and v["demux-w"] and not v.image and not v.albumart) then return done("no video") end
    local w, h = v["demux-w"], v["demux-h"]
    local dar = w * (tonumber(v["demux-par"]) or 1) / h
    if ((tonumber(v["demux-rotation"]) or 0) % 180) == 90 or dar < 1 then return done("portrait picture") end
    if ff_exe == nil then ff_exe = resolve_exe(opts.prebuild) end
    local ffm = (ff_exe and ff_exe ~= "") and ff_exe:gsub("[Ff][Ff][Pp][Rr][Oo][Bb][Ee](%.[Ee][Xx][Ee])$", "ffmpeg%1") or ""
    if ffm == "" or ffm == ff_exe then ffm = resolve_exe("ffmpeg") end
    if not ffm or ffm == "" then return done("no ffmpeg") end
    det.state = "detecting"
    local pts, i, hs, t0 = 8, 0, {}, mp.get_time()
    local function decide()
        local ms = math.floor((mp.get_time() - t0) * 1000)
        if #hs < 3 then mp.msg.info(("bars detect: undecided (%d valid) in %d ms"):format(#hs, ms)); return done("undecided") end
        local ch = 0; for _, y in ipairs(hs) do ch = math.max(ch, y) end
        local cr = dar * h / ch
        if math.abs(cr - dar) <= 0.03 * dar or ch >= h - 8 then
            mp.msg.info(("bars detect: no bars (%dx%d) in %d ms"):format(w, ch, ms)); return done("no bars found")
        end
        local best, bd = 0, 1e9
        for j, r in ipairs(presets) do if math.abs(r - cr) < bd then best, bd = j, math.abs(r - cr) end end
        if best == 0 or bd > 0.03 * cr then
            mp.msg.info(("bars detect: %.3f matches no preset in %d ms"):format(cr, ms)); return done(("%.2f, no preset"):format(cr))
        end
        mp.msg.info(("bars detect: %s (picture %dx%d, %.3f) in %d ms"):format(labels[best], w, ch, cr, ms))
        done("", best, labels[best])
    end
    local function step()
        if gen ~= det.gen then return end
        i = i + 1
        if i > pts then return decide() end
        local ts = dur * (0.05 + 0.8 * (i - 1) / (pts - 1))
        mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
            args = { ffm, "-hide_banner", "-nostdin", "-noaccurate_seek", "-ss", ("%.2f"):format(ts), "-i", path, "-map", "0:v:0",
                "-an", "-sn", "-dn", "-frames:v", "4", "-vf", "cropdetect=limit=0.1:round=2:reset=0", "-f", "null", "-" } },
            function(_, r)
                local last
                for cw_, ch_ in tostring(r and r.stderr or ""):gmatch("w:(%-?%d+) h:(%-?%d+)") do last = { tonumber(cw_), tonumber(ch_) } end
                if last and last[1] > 0 and last[2] > 0 and last[1] * last[2] >= 0.25 * w * h then hs[#hs + 1] = last[2] end
                step()
            end)
    end
    apply(false)
    step()
end
mp.register_event("file-loaded", function() if bars_auto then start_detect() end end)
mp.observe_property("video-dec-params", "native", function() apply(false) end)
mp.observe_property("hwdec-current", "native", function() apply(false) end)
mp.observe_property("display-height", "native", function() apply(false) end)
mp.observe_property("fullscreen", "native", function() apply(false) end)
-- Live display peak (v3.2.5): follow it while playing; re-tag only when it moves by more than 5 nits (the sig
-- compare in apply() then rebuilds once). A confirm of the stored value causes no rebuild.
if not tonumber(opts.hdr_peak) then
    mp.observe_property("video-target-params", "native", function()
        if read_display_peak() then apply(false) end
    end)
end

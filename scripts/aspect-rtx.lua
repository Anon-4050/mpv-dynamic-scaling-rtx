-- aspect-rtx.lua  v4.0.3  (tested on mpv 0.42, NVIDIA RTX laptop GPU, Windows 11, gpu-next + d3d11, hwdec=d3d11va-copy)
-- Live aspect-ratio crop fed into NVIDIA RTX VSR / RTX Video HDR via d3d11vpp. Chain: crop -> d3d11vpp -> renderer.
-- Runs no external program except ffprobe (optional, for the start-up pre-build) and changes no system setting.
--
-- Crop: a preset (the `start` one, or one you pick by key, panel or script-message) crops every file to its exact
--   ratio. Crop mode auto (start=auto, or the panel's Auto) crops to the display's ratio, and only when the picture
--   ratio differs from it by more than ratio_tol (2 %): 16:9 video on a 16:9 display is left as is. Optional clamp:
--   auto only trims the sides of a picture wider than the display. The display ratio is the monitor's, not the
--   window's (mpv sizes the window to the video, so a window ratio would follow the crop).
--   Rotated video (90 / 270, e.g. phone clips): crop and VSR scale work on the picture as shown; the start crop skips
--   portrait pictures.
-- HDR peak tag: RTX Video HDR output is tagged with the live display peak that mpv reads from Windows (the value in
--   stats "Display: x / N cd/m2"), re-tagged when it moves by more than 5 nits. Without a tag, mpv's d3d11vpp assumes
--   1000 nits ("This is only a guess"). The last known peak is kept in ~~cache/aspect-rtx-display-peak.txt so RTX HDR
--   starts with one filter build at the right value; 600 nits is used only when no value was ever stored.
-- Display mode: mpv's own read of the output colour space when its video output starts (DXGI, G2084 = Windows HDR
--   on), else the render target, else the last known mode. A Windows HDR change after mpv started needs a restart.
--   Another script may publish the mode Windows reports in user-data/winhdr {os_hdr, seq}; this script reads it.
-- ICC (option icc_sdr): icc-profile-auto=yes only on an SDR display while RTX HDR is not running; off while RTX HDR is
--   applied and whenever the display is in HDR mode (an HDR swapchain with ICC on would be encoded to the profile's
--   80-nit SDR white). auto = only if icc-profile-auto was on at start; yes = always; no = never touched.
-- Start-up: playback starts paused (start hold) and resumes once the chain is live, so the first played frame is
--   already filtered and audio starts with it. The chain is pre-built before the decoder starts, from ffprobe (bit
--   depth, colour), the track list (size, pixel aspect) and the last known display (size, HDR mode; display_store).
--   If the display mode turns out different, the chain is rebuilt once behind the hold. Measured against v1.0.0
--   (n=10, order rotated): first play unchanged (2.03 s both), worst A/V sync 16 ms vs 62 ms.
-- VSR and RTX HDR run only when mpv's video device is an NVIDIA RTX GPU (else the panel shows "no RTX GPU").
-- Credits: VSR / RTX HDR core based on "AutoVSR + RTX HDR" by anthonybaldwin (gist 1e49b28b49babf64f159cb793c506333),
--   a fork of natyusha's autovsr.lua (gist e230a176d41e3092676c4e941ded406a), itself based on AutoVSR by azumukupoe
--   (gist a56a78d71cf26a8f682dc06407e615db), from Andarwinux's answer in mpv discussion #14804
--   (discussioncomment-10570208). See README, Credits.
-- Supersedes mpv-dynamic-scaling.lua (now in legacy/). Do not load it, or any other script that sets d3d11vpp, with this one.
--
-- Keys (rebind in input.conf: "KEY script-binding aspect_rtx/<name>"):
--   Alt+a          ar-cycle   cycle: original -> presets -> original
--   Alt+1/2/3      original / 16:9 / 1.9:1 directly
--   Alt+0          ar-off     crop off
--   Ctrl+Shift+R (or Ctrl+R)   ar-vsr     VSR on/off (start state: aspect_rtx-vsr=yes|no)
--   Ctrl+Shift+H (or Ctrl+H)   ar-hdr     RTX Video HDR on/off (SDR sources, HDR display only)
--   Ctrl+Shift+S (or Ctrl+S)   ar-status  show filter chain, decoder, display mode
-- Script-messages (direct choice, used by rtx-panel.lua; no-op when already set):
--   script-message-to aspect_rtx set-crop <preset label|auto|original>
--   script-message-to aspect_rtx set-vsr yes|no        script-message-to aspect_rtx set-hdr yes|no
--
-- Options (mpv.conf: script-opts-append=aspect_rtx-<name>=<value>, or script-opts/aspect_rtx.conf: <name>=<value>):
--   presets   comma list of ratios (decimal or W:H), default "16:9,1.9" (IMAX digital = 1.90:1)
--   start     crop mode at launch: original | auto | 16:9 | 1.9 (any preset name). Default 16:9.
--   ratio_tol 0.02 (default): auto-crop tolerance (see above).   clamp  no (default) | yes (auto only trims the sides
--             of a picture wider than the display).
--   fullscreen_only  yes (default): RTX VSR/HDR run only in fullscreen; crop still works windowed.
--   vsr / hdr start state (yes/no); hdr_peak = RTX HDR peak tag in nits, or "auto" / "display" (default): the
--             display peak mpv reads from Windows (video-target-params/max-luma), followed live.
--   hdr_display  auto (default): RTX HDR only when the display is in HDR mode (read by mpv) | yes | no
--   icc_sdr   auto (default) | yes | no (see ICC above).
--   prebuild  ffprobe for the start-up pre-build: "ffprobe" (default, looked up in the PATH folders only, never the
--             current folder), a full path to ffprobe(.exe), or "" = off.
--   display_store  last known display size + HDR mode, default ~~cache/aspect-rtx-display.txt ("" = do not store).
--   pix_fmt   "auto" (default) or force nv12 / p010 / x2bgr10.
--
-- Design notes (from a 60-step GPU stress test):
--   * The output colourspace (d3d11-output-csp) is never changed at runtime: every change rebuilt the whole video
--     output and decoder (~1.5 s black). mpv's default "auto" follows the display.
--   * RTX HDR runs only when the display is in HDR mode. On an SDR desktop it was an uncalibrated round trip
--     (SDR -> PQ at 10000 nits -> tone-mapped back to SDR).
--   * If mpv drops one of our filters (e.g. during a video-output rebuild), the chain is re-applied (max 3 tries).
--
-- Needs: mpv >= 0.40, hwdec=d3d11va-copy (mpv.conf; the script flips from d3d11va only as a fallback),
-- gpu-context=d3d11, "Super Resolution" (and RTX HDR) enabled in the NVIDIA app. Optional: ffprobe (pre-build).

local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    presets  = "16:9,1.9",
    vsr      = true,
    hdr      = true,
    hdr_peak = "auto",    -- "auto" / "display" (/ "nvidia", old name) = live display peak; or a fixed number of nits
    peak_store = "~~cache/aspect-rtx-display-peak.txt",   -- last known display peak ("" = do not store)
    hdr_display = "auto",
    ratio_tol = 0.02,     -- Gate: no crop when picture and display ratios differ by this fraction or less
    clamp    = false,     -- opt-in: crop mode auto only trims the sides of a wider picture
    pix_fmt  = "auto",
    start    = "16:9",
    fullscreen_only = true,
    icc_sdr  = "auto",    -- icc-profile-auto on an SDR display without RTX HDR, off otherwise. auto = only if it
                          -- was on at start; yes = always; no = leave mpv.conf's
    luma     = true,      -- append format=max-luma tag after RTX HDR
    prebuild = "ffprobe", -- Ffprobe used to build the chain before the decoder starts ("" = off)
    display_store = "~~cache/aspect-rtx-display.txt",   -- Last known display size + HDR mode
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
local picked = false   -- The user chose the crop (key, panel, script-message); until then it is the start crop
local auto_sel = false -- Crop mode auto = crop to the display ratio, gated (ratio_tol) and optionally clamped
do
    local s = tostring(opts.start):lower():match("^%s*(.-)%s*$")
    auto_sel = (s == "auto")
    for i, l in ipairs(labels) do if l:lower() == s then idx = i end end
    if idx == 0 and not (s == "original" or s == "off" or s == "none" or s == "0") then
        local n = tonumber(s); if n and n >= 1 and n <= #presets and n % 1 == 0 then idx = n end
    end
end
local use_vsr, use_hdr = opts.vsr, opts.hdr
local last_sig = nil
local applying = false
local want = {}          -- labels we expect in vf after the last apply
local retries = 0

-- Display mode: mpv logs the DXGI output colourspace at every video-output init.
local disp_hdr = (opts.hdr_display == "yes")
local disp_known = (opts.hdr_display ~= "auto")
local apply   -- forward
local redo_pre   -- forward
local recheck_hold   -- forward
local pv = { used = false, verified = true }   -- Pre-build used the cached display mode / mode confirmed
local mpv_hdr = nil      -- The mode mpv's video output read at its init (its swapchain and HDR passthrough follow it)
local os_hdr = nil       -- The mode Windows reports now (OS re-check), nil = not checked
local rtx_dev = true     -- Video device is NVIDIA RTX (from mpv's "Device Name" log line; assumed until read)

-- Last known display (size, HDR mode), for the build before the video output exists. Written on change.
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

-- ICC only on an SDR display. With Windows HDR on, mpv's swapchain is PQ/BT.2020, but icc-profile-auto=yes makes
-- libplacebo encode to the ICC profile (target srgb/bt.709, 80 nits), so HDR video would be tone-mapped to SDR and
-- SDR video squeezed into 80 nits. Measured with Windows HDR on (Dolby Vision profile 8 source): ICC on -> target
-- srgb bt.709 80 nits; ICC off -> target pq bt.2020 441 nits. The display mode is the live read, else the cached one.
local hdr_running = false
local icc_user = mp.get_property_bool("icc-profile-auto", false)   -- The user's own setting at start
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

-- The video device must be an NVIDIA RTX GPU (mpv logs its d3d11 "Device Name" at video-output init);
-- read whatever hdr_display is set to
mp.enable_messages("v")
mp.register_event("log-message", function(e)
    if e.prefix ~= "vo/gpu-next/d3d11" and e.prefix ~= "vo/gpu/d3d11" then return end
    local dn = e.text:match("^Device Name: (.-)%s*$")
    if not dn then return end
    local ok = dn:find("NVIDIA", 1, true) ~= nil and dn:find("RTX", 1, true) ~= nil
    if ok ~= rtx_dev then rtx_dev = ok; last_sig = nil; mp.add_timeout(0, function() apply(false) end) end
    if not ok then mp.msg.info("no NVIDIA RTX device (" .. dn .. "): VSR and RTX HDR off") end
end)
if opts.hdr_display == "auto" then
    mp.register_event("log-message", function(e)
        if e.prefix ~= "vo/gpu-next/d3d11" and e.prefix ~= "vo/gpu/d3d11" then return end
        local cs = e.text:match("Queried output: .-colorspace: (%S+)")
        if not cs then return end
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
            -- A pre-build made with a stale cached display mode is rebuilt at once from the same data (the
            -- video output reports its mode before the decoder starts), behind the start hold.
            mp.add_timeout(0, function()
                if not (redo_pre and redo_pre()) then apply(false) end
                pv.verified = true
                if recheck_hold then recheck_hold() end
            end)
        end
    end)
end
-- Optional: another script may publish the mode Windows reports in user-data/winhdr {os_hdr, seq}; this script only
-- reads it. Without one, the display mode is mpv's own read (above), else the last known one (display_store).
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
local function recheck(why) mp.commandv("script-message", "winhdr-recheck", why) end   -- no-op unless a script listens
-- mpv's own read can be missed when its video output starts before this script listens: 1.5 s after the file
-- loaded, take the renderer's target (PQ = HDR swapchain; not with ICC on, whose target is the profile).
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

local function even(n) return 2 * math.floor(n / 2 + 0.5) end

local OURS = { ar_crop = true, ar_rtx = true, ar_luma = true }

local function remove_ours()
    for _, f in ipairs(mp.get_property_native("vf", {})) do
        if f.label and OURS[f.label] then
            mp.commandv("vf", "remove", "@" .. f.label)
        end
    end
end

-- RTX HDR peak tag: fixed number, or the live display peak (video-target-params max-luma from a PQ
-- target = the stats "Display:" value). With ICC on the target is the profile (sRGB, 80 nits), not the
-- display, so only PQ targets count. The last known value is stored so RTX HDR starts at the right tag.
local FALLBACK_PEAK = 600          -- only when no display peak was ever read
local STORE = opts.peak_store ~= "" and mp.command_native({ "expand-path", opts.peak_store }) or nil
local disp_peak, disp_src = nil, nil
if STORE then
    local fh = io.open(STORE, "r")
    local v = fh and tonumber(fh:read("*l") or "")
    if fh then fh:close() end
    if v and v >= 80 and v <= 10000 then disp_peak, disp_src = math.floor(v + 0.5), "display, last known" end
    mp.msg.verbose("display peak store " .. STORE .. ": " .. tostring(disp_peak or "empty"))
end
local function store_peak(v)
    if not STORE then return end
    local fh = io.open(STORE, "w")
    if fh then fh:write(tostring(v), "\n"); fh:close() else mp.msg.verbose("display peak store not writable: " .. STORE) end
end
-- Read the live display peak; adopt it when it differs from the current value by more than 5 nits (hysteresis,
-- so rounding noise like 440.66 vs 441 never rebuilds the chain).
local function read_display_peak()
    local t = mp.get_property_native("video-target-params")
    local m = t and t.gamma == "pq" and tonumber(t["max-luma"])
    if not (m and m >= 80 and m <= 10000) then return false end
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
    local rot = ((tonumber(d.rotate) or 0) % 180) == 90   -- Shown rotated by 90/270
    if idx > 0 or auto_sel then
        local r = presets[idx]
        local dar = (d.aspect and d.aspect > 0) and d.aspect or (w / h)   -- display aspect (handles non-square pixels)
        if rot then dar = 1 / dar end      -- The picture as displayed (renderer rotates after the filters)
        local disp_r = dw / dh
        -- Only crop mode auto (display ratio) is gated and optionally clamped; a preset - the fixed start one
        -- or one the user picked - applies its exact ratio. A start crop skips portrait pictures.
        if auto_sel then r = disp_r end
        if (auto_sel or not picked) and dar < 1 then
            crop_na = "portrait picture"
        elseif auto_sel and math.abs(dar - disp_r) <= (tonumber(opts.ratio_tol) or 0.02) * disp_r then
            crop_na = "fits the display"
        elseif auto_sel and opts.clamp and dar < disp_r then
            crop_na = "narrower than the display"
        else
            -- displayed sides = coded width, or coded height when rotated by 90/270
            local cut_w = (r < dar - 0.005)    -- narrower target: cut the displayed sides
            local cut_h = (r > dar + 0.005)    -- wider target: cut the displayed top/bottom
            local f = cut_w and (r / dar) or cut_h and (dar / r) or 1
            if (cut_w and not rot) or (cut_h and rot) then
                cw = math.min(w, even(w * f)); x = even((w - cw) / 2)
            elseif cut_w or cut_h then
                ch = math.min(h, even(h * f)); y = even((h - ch) / 2)
            end
        end
    end
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
    local vsr = use_vsr and gpu and rtx_dev and rtx_ok() and scale > 1
    local hdr = use_hdr and gpu and rtx_dev and is_sdr and rtx_ok() and disp_hdr

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
    -- State for rtx-panel.lua: published on every apply, including the unchanged-signature path.
    local vsr_na = (not rtx_dev and "no RTX GPU") or (not gpu and "software decode") or (scale <= 1 and "no upscale") or (not rtx_ok() and "windowed") or ""
    local hdr_na = (not rtx_dev and "no RTX GPU") or (not is_sdr and "HDR source") or (not gpu and "software decode")
        or (not disp_hdr and ((os_hdr and mpv_hdr == false) and "restart mpv (HDR turned on)" or disp_known and "Windows HDR off" or "display not read")) or (not rtx_ok() and "windowed") or ""
    local state = { crop = crop ~= nil, rtx = rtx ~= nil, vsr = vsr, hdr = hdr, display_hdr = disp_hdr,
        display = disp_known and ("display " .. ((os_hdr ~= nil and os_hdr or disp_hdr) and "HDR" or "SDR")) or "display not read",
        crop_mode = auto_sel and "auto" or idx > 0 and labels[idx] or "original", vsr_want = use_vsr, hdr_want = use_hdr, scale = scale,
        vsr_na = vsr_na, hdr_na = hdr_na, peak = luma and peak or nil, peak_src = luma and peak_src or nil, sig = sig,
        presets = labels, crop_na = crop_na, mpv_hdr = mpv_hdr }
    local hdr_msg = hdr and "on" or (not use_hdr and "off") or (not rtx_dev and "n/a (no RTX GPU)") or (not is_sdr and "n/a (HDR source)")
        or (not disp_hdr and (disp_known and "n/a (Windows HDR off)" or "n/a (display not read yet)"))
        or (not rtx_ok() and "paused (windowed)") or (not gpu and "n/a (software decode)") or "off"
    local msg = string.format("crop %s %dx%d | VSR %s | HDR %s",
        (auto_sel or idx > 0) and ((auto_sel and "auto" or labels[idx]) .. (crop_na ~= "" and (" (" .. crop_na .. ")") or "")) or "off", cw, ch, vsr and (scale .. "x") or (not rtx_dev and use_vsr and "n/a (no RTX GPU)") or "off", hdr_msg)
    if sig ~= last_sig then retries = 0 end
    -- ICC on unless RTX HDR is applied. Order: ICC off BEFORE RTX HDR starts; ICC on only ~0.3 s AFTER it
    -- stops, so PQ frames still in flight are not tone-mapped to the profile's 80-nit white.
    hdr_running = hdr
    if hdr or sig == last_sig then set_icc(hdr) end
    if sig == last_sig and not force then publish(state); return msg end

    applying = true
    remove_ours()
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
    picked = true; auto_sel = false; idx = (idx + 1) % (#presets + 1); say() end)
mp.add_key_binding("Alt+0", "ar-off", function() picked = true; auto_sel = false; idx = 0; say() end)
mp.add_key_binding("Alt+1", "ar-1", function() picked = true; auto_sel = false; idx = 0; say() end)
local function by_name(n) for i, l in ipairs(labels) do if l == n then return i end end end
mp.add_key_binding("Alt+2", "ar-2", function() local i = by_name("16:9"); if i then picked = true; auto_sel = false; idx = i; say() end end)
mp.add_key_binding("Alt+3", "ar-3", function() local i = by_name("1.9"); if i then picked = true; auto_sel = false; idx = i; say() end end)
-- mpv writes shifted letters as uppercase (Ctrl+R = Ctrl+Shift+r), so bind both spellings.
local function bind2(k1, k2, name, fn)
    mp.add_key_binding(k1, name, fn)
    mp.add_key_binding(k2, name .. "-b", fn)
end
bind2("Ctrl+Shift+R", "Ctrl+R", "ar-vsr", function() use_vsr = not use_vsr; say() end)
bind2("Ctrl+Shift+H", "Ctrl+H", "ar-hdr", function() use_hdr = not use_hdr; say() end)
-- Direct choices (rtx-panel.lua). No-op when the value is already set (no rebuild, no OSD).
local function yes(v) v = tostring(v or ""):lower(); return v == "yes" or v == "on" or v == "true" or v == "1" end
mp.register_script_message("set-crop", function(v)
    local s = tostring(v or ""):lower()
    local i = 0
    local a = (s == "auto")   -- Crop to the display ratio, gated
    if not (a or s == "original" or s == "off" or s == "none" or s == "0") then
        for j, l in ipairs(labels) do if l:lower() == s then i = j end end
        if i == 0 then mp.msg.warn("set-crop: unknown preset '" .. tostring(v) .. "'"); return end
    end
    -- Picking the preset already shown (e.g. the gated start preset) makes it apply too
    if i ~= idx or a ~= auto_sel or not picked then picked = true; auto_sel = a; idx = i; say() end
end)
mp.register_script_message("set-vsr", function(v) local b = yes(v); if b ~= use_vsr then use_vsr = b; say() end end)
mp.register_script_message("set-hdr", function(v) local b = yes(v); recheck("panel"); if b ~= use_hdr then use_hdr = b; say() end end)
bind2("Ctrl+Shift+S", "Ctrl+S", "ar-status", function()
    mp.osd_message("vf: " .. mp.get_property("vf", "none") .. "\nhwdec: " ..
        mp.get_property("hwdec-current", "none") .. "\ndisplay: " ..
        (disp_known and (disp_hdr and "HDR" or "SDR") or "unknown") .. " | csp: " ..
        mp.get_property("d3d11-output-csp", "?") .. " | icc: " .. tostring(mp.get_property_bool("icc-profile-auto")), 5)
end)

-- No forced rebuild on file-loaded (that would build the chain a second time at every start). mpv keeps the vf list
-- across files; apply() rebuilds when the chain must change, and the vf observer restores a dropped filter.
publish({ presets = labels, crop_mode = auto_sel and "auto" or idx > 0 and labels[idx] or "original", vsr_want = use_vsr, hdr_want = use_hdr })

-- Start hold: playback starts paused and resumes once the video output runs at the chain's size, so the
-- first played frame is already filtered and audio starts with it. Without it, the chain often landed after the
-- first frame (mpv delivers decoder data late while it opens the audio device): rebuild, +0.3-1 s, A/V spike.
-- No guessing: release is driven by the real video-out-params. Never holds a file the user started paused;
-- releases on no video, end-file, or after hold_max seconds.
local HOLD_MAX = 3
local hold = { active = false, timer = nil }
-- The user pressing pause during the hold ends it; the release then leaves pause alone.
mp.observe_property("pause", "bool", function(_, p)
    if hold.active and p == false then
        hold.active = false
        if hold.timer then hold.timer:kill(); hold.timer = nil end
        mp.msg.verbose("start hold cancelled (pause changed by the user)")
    end
end)
local function release(why)
    if not hold.active then return end
    hold.active = false
    if hold.timer then hold.timer:kill(); hold.timer = nil end
    mp.set_property_bool("pause", false)
    mp.msg.verbose("start hold released (" .. why .. ")")
end
mp.add_hook("on_preloaded", 50, function()
    if mp.get_property_bool("pause") then return end
    hold.active = true; hold.loaded = false
    mp.set_property_bool("pause", true)
    -- The safety timeout starts at file-loaded (below), not here: the GPU context is created between these two
    -- points and can take several seconds under memory pressure (7-9 s seen), which would run out a timer started here.
end)
mp.register_event("end-file", function() release("end-file") end)
local function check_hold()
    if not (hold.active and hold.loaded) then return end
    if pv.used and not pv.verified then return end   -- Wait until the cached display mode is confirmed
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

-- Pre-build: the chain is built before mpv creates the video output and the decoder, so the first decoded
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
-- Ffprobe as an absolute path. A bare name is looked up in PATH folders only (absolute ones),
-- never in mpv's current folder.
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
            if gen ~= probe.gen then return end   -- answer for an earlier file
            probe.done = true
            if ok and r and r.status == 0 then probe.info = utils.parse_json(r.stdout or "") end
            if not probe.info then mp.msg.verbose("pre-build: ffprobe gave nothing (" .. tostring(r and r.error_string) .. ")") end
            if probe.waiting then local go = probe.waiting; probe.waiting = nil; go() end
        end)
end)
-- Pre-build at on_preloaded 40 (a script that changes the display mode should do it at a lower priority, so it is
-- done when this runs); mpv creates its video output after.
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
mp.observe_property("video-dec-params", "native", function() apply(false) end)
mp.observe_property("hwdec-current", "native", function() apply(false) end)
mp.observe_property("display-height", "native", function() apply(false) end)
mp.observe_property("fullscreen", "native", function() apply(false) end)
-- Live display peak: follow it while playing; re-tag only when it moves by more than 5 nits (the sig
-- compare in apply() then rebuilds once). A confirm of the stored value causes no rebuild.
if not tonumber(opts.hdr_peak) then
    mp.observe_property("video-target-params", "native", function()
        if read_display_peak() then apply(false) end
    end)
end

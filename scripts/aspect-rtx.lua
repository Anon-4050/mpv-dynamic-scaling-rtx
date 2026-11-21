-- aspect-rtx.lua  v3.2.5  (tested on mpv 0.42, RTX 4050 Laptop, Windows 11, gpu-next + d3d11, hwdec=d3d11va-copy)
-- HDR peak tag: RTX Video HDR output is tagged with the live display peak that mpv reads from Windows (the value in
--   stats "Display: x / N cd/m2"), re-tagged when it moves by more than 5 nits. Without a tag, mpv's d3d11vpp assumes
--   1000 nits ("This is only a guess"). The last known peak is kept in ~~cache/aspect-rtx-display-peak.txt so RTX HDR
--   starts with one filter build at the right value; 600 nits is used only when no value was ever stored.
-- ICC: icc-profile-auto=yes whenever RTX HDR is not running (windowed, toggled off, HDR source, SDR display, no video);
--   off only while RTX HDR is applied (on an HDR swapchain the ICC target would be the profile's 80-nit white).
-- Live aspect-ratio crop fed into NVIDIA RTX VSR / RTX Video HDR via d3d11vpp.
-- Chain: crop -> d3d11vpp (VSR and/or HDR) -> mpv renderer.
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
--
-- Options (mpv.conf: script-opts-append=aspect_rtx-<name>=<value>):
--   presets   comma list of ratios (decimal or W:H), default "16:9,1.9" (IMAX digital = 1.90:1)
--   start     crop mode at launch: original | 16:9 | 1.9 (any preset name). Default 16:9.
--   fullscreen_only  yes (default): RTX VSR/HDR run only in fullscreen; crop still works windowed.
--   vsr / hdr start state (yes/no); hdr_peak = RTX HDR peak tag in nits, or "auto" / "display" (default): the
--             display peak mpv reads from Windows (video-target-params/max-luma, the "Display: x / N cd/m2" stats
--             line), followed live. The NVIDIA app caps its RTX HDR peak slider at the same display value.
--   hdr_display  auto (default): RTX HDR only when Windows HDR is on (read from mpv's display query) | yes | no
--   pix_fmt   "auto" (default) or force nv12 / p010 / x2bgr10.
--
-- Design notes (from a 60-step GPU stress test):
--   * The output colourspace (d3d11-output-csp) is never changed at runtime: every change rebuilt the whole video
--     output and decoder (~1.5 s black). mpv's default "auto" follows the display.
--   * RTX HDR runs only when the display is in HDR mode. On an SDR desktop it was an uncalibrated round trip
--     (SDR -> PQ at 10000 nits -> tone-mapped back to SDR).
--   * ICC follows whether RTX HDR is running (see above).
--   * If mpv drops one of our filters (e.g. during a video-output rebuild), the chain is re-applied (max 3 tries).
--
-- Needs: mpv >= 0.40, hwdec=d3d11va-copy (mpv.conf; the script flips from d3d11va only as a fallback),
-- gpu-context=d3d11, "Super Resolution" (and RTX HDR) enabled in the NVIDIA app.

local mp = require 'mp'
local options = require 'mp.options'

local opts = {
    presets  = "16:9,1.9",
    vsr      = true,
    hdr      = true,
    hdr_peak = "auto",    -- "auto" / "display" (/ "nvidia", old name) = live display peak; or a fixed number of nits
    peak_store = "~~cache/aspect-rtx-display-peak.txt",   -- last known display peak ("" = do not store)
    hdr_display = "auto",
    pix_fmt  = "auto",
    start    = "16:9",
    fullscreen_only = true,
    icc_sdr  = true,      -- manage icc-profile-auto: yes unless RTX HDR is running; no = leave mpv.conf's
    luma     = true,      -- append format=max-luma tag after RTX HDR
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
do
    local s = tostring(opts.start):lower():match("^%s*(.-)%s*$")
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

local function set_icc(hdr_running)
    if not opts.icc_sdr then return end
    local wanted = not hdr_running
    if mp.get_property_bool("icc-profile-auto") ~= wanted then
        mp.set_property_bool("icc-profile-auto", wanted)
        mp.msg.info("icc-profile-auto=" .. (wanted and "yes" or "no") .. (hdr_running and " (RTX HDR running)" or " (RTX HDR not running)"))
    end
end

if opts.hdr_display == "auto" then
    mp.enable_messages("v")
    mp.register_event("log-message", function(e)
        if e.prefix ~= "vo/gpu-next/d3d11" and e.prefix ~= "vo/gpu/d3d11" then return end
        local cs = e.text:match("Queried output: .-colorspace: (%S+)")
        if not cs then return end
        local h = cs:find("G2084", 1, true) ~= nil
        disp_known = true
        if h ~= disp_hdr then
            disp_hdr = h
            last_sig = nil
            mp.add_timeout(0, function() apply(false) end)
        end
    end)
end
local hdr_running = false
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

apply = function(force)
    if applying then return end
    local d = mp.get_property_native("video-dec-params")
    if not (mp.get_property("path") and d and d.w and d.h) then return end
    local hw = mp.get_property("hwdec-current", "")
    if hw == "" then return end                       -- decoder not up yet; observer re-fires
    local gpu = (hw == "d3d11va" or hw == "d3d11va-copy")   -- else (software etc.): crop only, no RTX
    local dw = mp.get_property_number("display-width")
    local dh = mp.get_property_number("display-height")
    if not (dw and dh) then return end

    local w, h = d.w, d.h
    local cw, ch, x, y = w, h, 0, 0
    if idx > 0 then
        local r = presets[idx]
        local dar = (d.aspect and d.aspect > 0) and d.aspect or (w / h)   -- display aspect (handles non-square pixels)
        if r < dar - 0.005 then            -- narrower target: cut the sides
            cw = math.min(w, even(w * r / dar)); x = even((w - cw) / 2)
        elseif r > dar + 0.005 then        -- wider target: cut top/bottom
            ch = math.min(h, even(h * dar / r)); y = even((h - ch) / 2)
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

    local scale = math.floor(math.min(dw / cw, dh / ch) * 10) / 10
    local vsr = use_vsr and gpu and rtx_ok() and scale > 1
    local hdr = use_hdr and gpu and is_sdr and rtx_ok() and disp_hdr

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
    local vsr_na = (not gpu and "software decode") or (scale <= 1 and "no upscale") or (not rtx_ok() and "windowed") or ""
    local hdr_na = (not is_sdr and "HDR source") or (not gpu and "software decode")
        or (not disp_hdr and (disp_known and "Windows HDR off" or "display not read")) or (not rtx_ok() and "windowed") or ""
    local state = { crop = crop ~= nil, rtx = rtx ~= nil, vsr = vsr, hdr = hdr, display_hdr = disp_hdr,
        crop_mode = idx > 0 and labels[idx] or "original", vsr_want = use_vsr, hdr_want = use_hdr, scale = scale,
        vsr_na = vsr_na, hdr_na = hdr_na, peak = luma and peak or nil, peak_src = luma and peak_src or nil, sig = sig }
    local hdr_msg = hdr and "on" or (not use_hdr and "off") or (not is_sdr and "n/a (HDR source)")
        or (not disp_hdr and (disp_known and "n/a (Windows HDR off)" or "n/a (display not read yet)"))
        or (not rtx_ok() and "paused (windowed)") or (not gpu and "n/a (software decode)") or "off"
    local msg = string.format("crop %s %dx%d | VSR %s | HDR %s",
        idx > 0 and labels[idx] or "off", cw, ch, vsr and (scale .. "x") or "off", hdr_msg)
    if sig ~= last_sig then retries = 0 end
    -- v3.2.2: ICC on unless RTX HDR is applied. Order: ICC off BEFORE RTX HDR starts; ICC on only ~0.3 s AFTER it
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
    idx = (idx + 1) % (#presets + 1); say() end)
mp.add_key_binding("Alt+0", "ar-off", function() idx = 0; say() end)
mp.add_key_binding("Alt+1", "ar-1", function() idx = 0; say() end)
local function by_name(n) for i, l in ipairs(labels) do if l == n then return i end end end
mp.add_key_binding("Alt+2", "ar-2", function() local i = by_name("16:9"); if i then idx = i; say() end end)
mp.add_key_binding("Alt+3", "ar-3", function() local i = by_name("1.9"); if i then idx = i; say() end end)
-- mpv writes shifted letters as uppercase (Ctrl+R = Ctrl+Shift+r), so bind both spellings.
local function bind2(k1, k2, name, fn)
    mp.add_key_binding(k1, name, fn)
    mp.add_key_binding(k2, name .. "-b", fn)
end
bind2("Ctrl+Shift+R", "Ctrl+R", "ar-vsr", function() use_vsr = not use_vsr; say() end)
bind2("Ctrl+Shift+H", "Ctrl+H", "ar-hdr", function() use_hdr = not use_hdr; say() end)
bind2("Ctrl+Shift+S", "Ctrl+S", "ar-status", function()
    mp.osd_message("vf: " .. mp.get_property("vf", "none") .. "\nhwdec: " ..
        mp.get_property("hwdec-current", "none") .. "\ndisplay: " ..
        (disp_known and (disp_hdr and "HDR" or "SDR") or "unknown") .. " | csp: " ..
        mp.get_property("d3d11-output-csp", "?") .. " | icc: " .. tostring(mp.get_property_bool("icc-profile-auto")), 5)
end)

-- v3.2.5: no forced rebuild on file-loaded (it built the chain a second time at every start). mpv keeps the vf list
-- across files; apply() rebuilds when the chain must change, and the vf observer restores a dropped filter.
mp.register_event("file-loaded", function() apply(false) end)
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

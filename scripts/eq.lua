-- eq.lua  v1.0.0  - headphone EQ from your own profile (Alt+e, script-message set-eq yes|no, set-profile <name>).
-- Ships with NO profile: a correction is right only for the headphone it was measured for. Put your headphone's AutoEQ
-- result (https://github.com/jaakkopasanen/AutoEq) as a .txt file into script-opts/eq/ - "... ParametricEQ.txt" (Preamp
-- + PK/LSC/HSC filters) or "... GraphicEQ.txt" (one GraphicEQ: line). File name = profile name; the card's EQ row lists
-- them (no profile = no row, nothing happens). Filter: audio filter @kzcal = volume (preamp) + firequalizer (GraphicEQ)
-- or equalizer/lowshelf/highshelf (ParametricEQ). Options (script-opts/eq.conf): default (no) = on at start, profile
-- ("" = the first by name), dir (~~/script-opts/eq). State user-data/eq = {on, profile, profiles}.

local mp = require 'mp'
local options = require 'mp.options'
local utils = require 'mp.utils'
local opts = { default = false, profile = "", dir = "~~/script-opts/eq" }
options.read_options(opts, "eq")
local LABEL = "@kzcal"

local function parse(text)
    local pre, ge, f = nil, nil, {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if not line:match("^%s*#") then
            local p = line:match("^%s*Preamp:%s*([-+]?[%d%.]+)%s*dB")
            if p then pre = p end
            local g = line:match("^%s*GraphicEQ:%s*(.-)%s*$")
            if g then ge = g end
            local on, ty, rest = line:match("^%s*Filter%s*%d*:%s*(%u+)%s+(%u+)%s+(.*)$")
            if on == "ON" then
                local fc = rest:match("Fc%s+([%d%.]+)%s*Hz"); local gain = rest:match("Gain%s+([-+]?[%d%.]+)%s*dB")
                local q = rest:match("Q%s+([%d%.]+)")
                local kind = ({ PK = "equalizer", PEQ = "equalizer", LSC = "lowshelf", LS = "lowshelf", HSC = "highshelf", HS = "highshelf" })[ty]
                if kind and fc and gain then f[#f + 1] = { kind = kind, fc = fc, gain = gain, q = q or (kind == "equalizer" and "1" or "0.71") } end
            end
        end
    end
    local vol = "volume=" .. (pre or "0") .. "dB"
    if ge then
        local e = {}
        for fr, g in ge:gmatch("([%d%.]+)%s+([-+]?[%d%.]+)") do e[#e + 1] = "entry(" .. fr .. "," .. g .. ")" end
        if #e > 1 then return vol .. ",firequalizer=gain_entry='" .. table.concat(e, ";") .. "':zero_phase=on" end
        return nil, "GraphicEQ line without 'frequency gain' pairs"
    end
    if #f > 0 then
        local parts = { vol }
        for _, x in ipairs(f) do parts[#parts + 1] = string.format("%s=f=%s:t=q:w=%s:g=%s", x.kind, x.fc, x.q, x.gain) end
        return table.concat(parts, ",")
    end
    return nil, "no GraphicEQ line and no ON filters"
end

-- profiles: name -> graph, read once at start
local DIR = mp.command_native({ "expand-path", opts.dir })
local names, graph = {}, {}
for _, fn in ipairs(utils.readdir(DIR, "files") or {}) do
    if fn:lower():match("%.txt$") then
        local fh = io.open(utils.join_path(DIR, fn), "rb")
        if fh then
            local g, why = parse(fh:read("*a") or ""); fh:close()
            local n = fn:sub(1, -5)
            if g then names[#names + 1] = n; graph[n] = g else mp.msg.warn("profile " .. fn .. " skipped: " .. why) end
        end
    end
end
table.sort(names, function(a, b) return a:lower() < b:lower() end)
local cur = graph[opts.profile] and opts.profile or names[1]
if opts.profile ~= "" and not graph[opts.profile] then mp.msg.warn("profile '" .. opts.profile .. "' not found in " .. DIR) end
mp.msg.verbose(#names .. " EQ profile(s) in " .. DIR .. (cur and (", current " .. cur) or ""))

local function is_on()
    for _, f in ipairs(mp.get_property_native("af") or {}) do
        if f.label == "kzcal" then return true end
    end
    return false
end
local function add() mp.commandv("af", "add", LABEL .. ":lavfi=[" .. graph[cur] .. "]") end
local function eq_toggle()
    if not cur then mp.osd_message("EQ: no profile in script-opts/eq", 2); return end
    if is_on() then
        mp.commandv("af", "remove", LABEL)
        mp.osd_message("EQ: OFF", 2)
    else
        add()
        mp.osd_message(is_on() and ("EQ: ON (" .. cur .. ")") or ("EQ: " .. cur .. " failed to load"), 2)
    end
end
mp.add_key_binding("Alt+e", "eq-toggle", eq_toggle)

local function publish() if cur then mp.set_property_native("user-data/eq", { on = is_on(), profile = cur, profiles = names }) end end
if cur and opts.default and not is_on() then add() end
mp.observe_property("af", "native", publish)
mp.register_event("file-loaded", function()
    if cur and not _G.__eq_announced then
        _G.__eq_announced = true
        mp.osd_message(is_on() and ("EQ: ON (" .. cur .. ", Alt+e to toggle)") or "EQ: OFF", 2)
    end
end)
mp.register_script_message("set-eq", function(v)
    local want = ({ yes = true, on = true, ["1"] = true, ["true"] = true })[tostring(v or ""):lower()] == true
    if cur and want ~= is_on() then eq_toggle() end
end)
mp.register_script_message("set-profile", function(n)
    if not graph[n] then mp.osd_message("EQ: no profile '" .. tostring(n) .. "'", 2); return end
    local was = is_on(); cur = n
    if was then mp.commandv("af", "remove", LABEL) end
    add(); publish()
    mp.osd_message(is_on() and ("EQ: ON (" .. cur .. ")") or ("EQ: " .. cur .. " failed to load"), 2)
end)

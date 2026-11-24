-- binaural.lua  v1.7.0  - calibrated headphone renderer ("3D audio") in mpv's own filter chain.
-- Surround (more than 2 channels): the channels play as loudspeakers at their standard positions (ITU-R BS.775; 7.1
--   per BS.2051) through measured head-related responses (sofalizer, SADIE II D2 KEMAR 48 kHz). Each speaker position
--   gets its own EQ so its both-ear power per 1/3 octave equals its share in mpv's plain stereo fold; the level is
--   loudness-matched to the fold. LFE is kept at the speaker convention (+10 dB in-band); surrounds play as discrete
--   speakers. No compression or normalisation.
-- Stereo ("3D stereo", option stereo): two virtual loudspeakers at +-30 deg, so music is heard in front instead of
--   inside the head; EQ in L/R and M/S keeps the plain stereo's timbre and loudness for any mix.
-- Headphone gate: it switches on automatically only when the output device is on your headphone list (option
--   headphones); on any other device mpv's plain fold plays.
-- HRTF file: download SADIE II (University of York), subject D2, 48 kHz HRIR, as a .sofa file and put it at
--   ~~/hrtf/SADIE_II_D2_KEMAR_48K.sofa (or set option sofa). Without it the script stays off.
-- Options (script-opts/binaural.conf or script-opts-append=binaural-<key>=<value>):
--   headphones=<names>  endpoints that are headphones, separated by , or ; (substrings of the device description),
--                       e.g. headphones=USB DAC;Headphones (default empty: off everywhere until you list them)
--   default=yes|no      automatic gate on (default yes)
--   codecs=<list>       codecs the gate renders (mpv codec names; default truehd; * = every multichannel codec)
--   trim=<dB>           static trim (-12..+6), default 0.3 = loudness-matched to the fold
--   stereo=yes|no       3D stereo at start (default no); stereo_trim=<dB> (default 0, loudness-matched)
--   sofa=<path>         HRTF set; device=<description> forces the device (outputs other than WASAPI)
-- Keys: Alt+u 3D audio on/off for this file, Alt+U 3D stereo on/off. Script-messages set-binaural / set-binaural-stereo
-- yes|no. State user-data/binaural.

local mp = require "mp"
local options = require "mp.options"
local opts = { default = true, sofa = "~~/hrtf/SADIE_II_D2_KEMAR_48K.sofa", trim = 0.3, headphones = "", device = "", codecs = "truehd",
               stereo = false, stereo_trim = 0 }
local LABEL = "@binaural"
local LFEGAIN, OFFSET = 6.41, 0.37   -- measured: LFE +10 dB in-band; HRTF offset after sofalizer's 3 dB per channel
local EQ = "entry(20,0.13);entry(22,0.13);entry(25,0.14);entry(28,0.15);entry(32,0.16);entry(36,0.17);entry(40,0.18);entry(45,0.20);entry(50,0.22);entry(57,0.25);entry(63,0.28);entry(71,0.32);entry(80,0.36);entry(90,0.40);entry(101,0.46);entry(113,0.50);entry(127,0.52);entry(143,0.54);entry(160,0.51);entry(180,0.44);entry(202,0.28);entry(226,0.14);entry(254,-0.06);entry(285,-0.26);entry(320,-0.39);entry(359,-0.40);entry(403,-0.29);entry(453,-0.13);entry(508,0.06);entry(570,0.19);entry(640,0.41);entry(718,0.98);entry(806,1.57);entry(905,1.25);entry(1016,0.40);entry(1140,0.51);entry(1280,1.74);entry(1437,2.92);entry(1613,3.20);entry(1810,1.82);entry(2032,-0.14);entry(2281,-1.69);entry(2560,-2.73);entry(2874,-2.88);entry(3225,-2.03);entry(3620,-0.81);entry(4064,-1.43);entry(4561,-2.83);entry(5120,-2.49);entry(5747,-0.88);entry(6451,0.80);entry(7241,1.35);entry(8127,-0.50);entry(9123,-0.68);entry(10240,-0.88);entry(11494,-2.78);entry(12902,-2.81);entry(14482,-1.31);entry(16255,1.64);entry(18246,5.68)"
local PRE = { [6] = "firequalizer=gain='gain_interpolate(f+100000*ch)':gain_entry='entry(19.7,-0.03);entry(24.8,-0.02);entry(31.2,0.00);entry(39.4,0.04);entry(49.6,0.09);entry(62.5,0.17);entry(78.7,0.27);entry(99.2,0.41);entry(125.0,0.53);entry(157.5,0.55);entry(198.4,0.33);entry(250.0,-0.11);entry(315.0,-0.47);entry(396.9,-0.23);entry(500.0,0.23);entry(630.0,0.02);entry(793.7,1.88);entry(1000.0,0.32);entry(1259.9,1.32);entry(1587.4,4.07);entry(2000.0,0.29);entry(2519.8,-3.16);entry(3174.8,-1.89);entry(4000.0,-0.79);entry(5039.7,-3.14);entry(6349.6,2.02);entry(8000.0,-0.88);entry(10079.4,-1.47);entry(12699.2,-4.72);entry(16000.0,1.62);entry(20158.7,8.93);entry(100019.7,0.13);entry(100024.8,0.14);entry(100031.2,0.16);entry(100039.4,0.20);entry(100049.6,0.25);entry(100062.5,0.32);entry(100078.7,0.43);entry(100099.2,0.57);entry(100125.0,0.70);entry(100157.5,0.72);entry(100198.4,0.48);entry(100250.0,-0.04);entry(100315.0,-0.54);entry(100396.9,-0.53);entry(100500.0,-0.03);entry(100630.0,0.21);entry(100793.7,2.21);entry(101000.0,-0.22);entry(101259.9,1.58);entry(101587.4,4.17);entry(102000.0,0.07);entry(102519.8,-3.19);entry(103174.8,-2.53);entry(104000.0,-0.50);entry(105039.7,-3.89);entry(106349.6,0.92);entry(108000.0,-0.34);entry(110079.4,3.46);entry(112699.2,-4.21);entry(116000.0,2.40);entry(120158.7,5.25);entry(200019.7,0.26);entry(200024.8,0.27);entry(200031.2,0.30);entry(200039.4,0.33);entry(200049.6,0.39);entry(200062.5,0.47);entry(200078.7,0.59);entry(200099.2,0.74);entry(200125.0,0.88);entry(200157.5,0.89);entry(200198.4,0.62);entry(200250.0,0.09);entry(200315.0,-0.33);entry(200396.9,-0.12);entry(200500.0,0.55);entry(200630.0,0.80);entry(200793.7,2.93);entry(201000.0,0.40);entry(201259.9,1.65);entry(201587.4,5.65);entry(202000.0,-0.03);entry(202519.8,-2.71);entry(203174.8,-1.67);entry(204000.0,0.39);entry(205039.7,-0.17);entry(206349.6,5.84);entry(208000.0,3.61);entry(210079.4,0.59);entry(212699.2,-4.05);entry(216000.0,3.26);entry(220158.7,4.58);entry(301000.0,0.00);entry(401000.0,0.00);entry(501000.0,0.00)':multi=on:zero_phase=on,firequalizer=gain='gain_interpolate(f+100000*ch)':gain_entry='entry(1000.0,0.00);entry(101000.0,0.00);entry(201000.0,0.00);entry(301000.0,0.00);entry(400019.7,-3.52);entry(400024.8,-3.51);entry(400031.2,-3.49);entry(400039.4,-3.46);entry(400049.6,-3.43);entry(400062.5,-3.37);entry(400078.7,-3.29);entry(400099.2,-3.20);entry(400125.0,-3.11);entry(400157.5,-3.10);entry(400198.4,-3.27);entry(400250.0,-3.63);entry(400315.0,-3.96);entry(400396.9,-3.83);entry(400500.0,-3.67);entry(400630.0,-4.21);entry(400793.7,-1.90);entry(401000.0,-3.78);entry(401259.9,-5.15);entry(401587.4,-1.59);entry(402000.0,0.37);entry(402519.8,1.96);entry(403174.8,-2.70);entry(404000.0,1.86);entry(405039.7,-1.76);entry(406349.6,-8.12);entry(408000.0,-5.73);entry(410079.4,-2.12);entry(412699.2,-6.17);entry(416000.0,-4.15);entry(420158.7,-6.63);entry(500019.7,-3.24);entry(500024.8,-3.22);entry(500031.2,-3.20);entry(500039.4,-3.17);entry(500049.6,-3.11);entry(500062.5,-3.04);entry(500078.7,-2.93);entry(500099.2,-2.79);entry(500125.0,-2.67);entry(500157.5,-2.68);entry(500198.4,-2.95);entry(500250.0,-3.50);entry(500315.0,-4.00);entry(500396.9,-4.00);entry(500500.0,-3.74);entry(500630.0,-3.90);entry(500793.7,-1.55);entry(501000.0,-3.83);entry(501259.9,-4.59);entry(501587.4,-1.46);entry(502000.0,1.42);entry(502519.8,3.70);entry(503174.8,-0.54);entry(504000.0,1.53);entry(505039.7,-3.35);entry(506349.6,-8.25);entry(508000.0,-5.26);entry(510079.4,-0.13);entry(512699.2,-10.37);entry(516000.0,-2.23);entry(520158.7,-4.66)':multi=on:zero_phase=on", [8] = "firequalizer=gain='gain_interpolate(f+100000*ch)':gain_entry='entry(19.7,-0.03);entry(24.8,-0.02);entry(31.2,0.00);entry(39.4,0.04);entry(49.6,0.09);entry(62.5,0.17);entry(78.7,0.27);entry(99.2,0.41);entry(125.0,0.53);entry(157.5,0.55);entry(198.4,0.33);entry(250.0,-0.11);entry(315.0,-0.47);entry(396.9,-0.23);entry(500.0,0.23);entry(630.0,0.02);entry(793.7,1.88);entry(1000.0,0.32);entry(1259.9,1.32);entry(1587.4,4.07);entry(2000.0,0.29);entry(2519.8,-3.16);entry(3174.8,-1.89);entry(4000.0,-0.79);entry(5039.7,-3.14);entry(6349.6,2.01);entry(8000.0,-0.89);entry(10079.4,-1.47);entry(12699.2,-4.72);entry(16000.0,1.62);entry(20158.7,8.93);entry(100019.7,0.13);entry(100024.8,0.14);entry(100031.2,0.16);entry(100039.4,0.19);entry(100049.6,0.25);entry(100062.5,0.32);entry(100078.7,0.43);entry(100099.2,0.57);entry(100125.0,0.70);entry(100157.5,0.72);entry(100198.4,0.48);entry(100250.0,-0.04);entry(100315.0,-0.54);entry(100396.9,-0.53);entry(100500.0,-0.03);entry(100630.0,0.21);entry(100793.7,2.21);entry(101000.0,-0.22);entry(101259.9,1.58);entry(101587.4,4.17);entry(102000.0,0.07);entry(102519.8,-3.19);entry(103174.8,-2.53);entry(104000.0,-0.50);entry(105039.7,-3.89);entry(106349.6,0.92);entry(108000.0,-0.34);entry(110079.4,3.46);entry(112699.2,-4.21);entry(116000.0,2.40);entry(120158.7,5.25);entry(200019.7,0.26);entry(200024.8,0.27);entry(200031.2,0.30);entry(200039.4,0.33);entry(200049.6,0.39);entry(200062.5,0.48);entry(200078.7,0.59);entry(200099.2,0.74);entry(200125.0,0.88);entry(200157.5,0.89);entry(200198.4,0.62);entry(200250.0,0.09);entry(200315.0,-0.33);entry(200396.9,-0.12);entry(200500.0,0.55);entry(200630.0,0.80);entry(200793.7,2.93);entry(201000.0,0.40);entry(201259.9,1.65);entry(201587.4,5.65);entry(202000.0,-0.03);entry(202519.8,-2.71);entry(203174.8,-1.67);entry(204000.0,0.39);entry(205039.7,-0.17);entry(206349.6,5.84);entry(208000.0,3.61);entry(210079.4,0.59);entry(212699.2,-4.06);entry(216000.0,3.26);entry(220158.7,4.58);entry(301000.0,0.00);entry(401000.0,0.00);entry(501000.0,0.00);entry(601000.0,0.00);entry(701000.0,0.00)':multi=on:zero_phase=on,firequalizer=gain='gain_interpolate(f+100000*ch)':gain_entry='entry(1000.0,0.00);entry(101000.0,0.00);entry(201000.0,0.00);entry(301000.0,0.00);entry(400019.7,-3.12);entry(400024.8,-3.11);entry(400031.2,-3.10);entry(400039.4,-3.08);entry(400049.6,-3.05);entry(400062.5,-3.00);entry(400078.7,-2.94);entry(400099.2,-2.86);entry(400125.0,-2.79);entry(400157.5,-2.77);entry(400198.4,-2.88);entry(400250.0,-3.09);entry(400315.0,-3.21);entry(400396.9,-2.83);entry(400500.0,-2.56);entry(400630.0,-3.22);entry(400793.7,-1.17);entry(401000.0,-2.81);entry(401259.9,-4.41);entry(401587.4,-1.60);entry(402000.0,-0.73);entry(402519.8,0.46);entry(403174.8,-0.48);entry(404000.0,2.18);entry(405039.7,5.82);entry(406349.6,-3.21);entry(408000.0,-4.48);entry(410079.4,-3.10);entry(412699.2,-5.69);entry(416000.0,-0.93);entry(420158.7,-4.56);entry(500019.7,-2.98);entry(500024.8,-2.97);entry(500031.2,-2.95);entry(500039.4,-2.93);entry(500049.6,-2.89);entry(500062.5,-2.83);entry(500078.7,-2.76);entry(500099.2,-2.66);entry(500125.0,-2.58);entry(500157.5,-2.58);entry(500198.4,-2.74);entry(500250.0,-3.01);entry(500315.0,-3.12);entry(500396.9,-2.68);entry(500500.0,-2.36);entry(500630.0,-3.02);entry(500793.7,-1.22);entry(501000.0,-2.45);entry(501259.9,-4.39);entry(501587.4,-1.66);entry(502000.0,-0.91);entry(502519.8,2.05);entry(503174.8,2.03);entry(504000.0,3.54);entry(505039.7,3.81);entry(506349.6,-3.66);entry(508000.0,-3.99);entry(510079.4,-0.26);entry(512699.2,-5.44);entry(516000.0,1.27);entry(520158.7,0.26);entry(600019.7,-3.65);entry(600024.8,-3.63);entry(600031.2,-3.62);entry(600039.4,-3.59);entry(600049.6,-3.55);entry(600062.5,-3.49);entry(600078.7,-3.41);entry(600099.2,-3.31);entry(600125.0,-3.22);entry(600157.5,-3.21);entry(600198.4,-3.40);entry(600250.0,-3.81);entry(600315.0,-4.21);entry(600396.9,-4.15);entry(600500.0,-4.06);entry(600630.0,-4.58);entry(600793.7,-2.30);entry(601000.0,-4.21);entry(601259.9,-5.39);entry(601587.4,-1.76);entry(602000.0,-1.22);entry(602519.8,-0.93);entry(603174.8,-3.53);entry(604000.0,-0.61);entry(605039.7,-4.79);entry(606349.6,-8.51);entry(608000.0,-5.60);entry(610079.4,-0.26);entry(612699.2,3.28);entry(616000.0,-6.31);entry(620158.7,-4.89);entry(701000.0,0.00)':multi=on:zero_phase=on,firequalizer=gain='gain_interpolate(f+100000*ch)':gain_entry='entry(1000.0,0.00);entry(101000.0,0.00);entry(201000.0,0.00);entry(301000.0,0.00);entry(401000.0,0.00);entry(501000.0,0.00);entry(601000.0,0.00);entry(700019.7,-3.51);entry(700024.8,-3.50);entry(700031.2,-3.48);entry(700039.4,-3.45);entry(700049.6,-3.41);entry(700062.5,-3.34);entry(700078.7,-3.25);entry(700099.2,-3.13);entry(700125.0,-3.04);entry(700157.5,-3.05);entry(700198.4,-3.29);entry(700250.0,-3.77);entry(700315.0,-4.21);entry(700396.9,-4.17);entry(700500.0,-4.01);entry(700630.0,-4.46);entry(700793.7,-2.23);entry(701000.0,-4.17);entry(701259.9,-5.11);entry(701587.4,-1.28);entry(702000.0,-0.31);entry(702519.8,0.53);entry(703174.8,-2.16);entry(704000.0,-0.61);entry(705039.7,-5.63);entry(706349.6,-9.01);entry(708000.0,-5.60);entry(710079.4,-1.69);entry(712699.2,-3.87);entry(716000.0,-2.59);entry(720158.7,-7.85)':multi=on:zero_phase=on" }   -- per-channel EQ (binaural_cal2.py, binaural_chain2.json)
local PRE2 = "aformat=sample_fmts=flt|fltp,firequalizer=gain='gain_interpolate(f+100000*ch)':gain_entry='entry(19.7,-0.40);entry(24.8,-0.39);entry(31.2,-0.38);entry(39.4,-0.37);entry(49.6,-0.35);entry(62.5,-0.33);entry(78.7,-0.30);entry(99.2,-0.27);entry(125.0,-0.23);entry(157.5,-0.19);entry(198.4,-0.13);entry(250.0,-0.05);entry(315.0,0.06);entry(396.9,0.16);entry(500.0,0.13);entry(630.0,-0.09);entry(793.7,-0.16);entry(1000.0,0.27);entry(1259.9,-0.16);entry(1587.4,-0.08);entry(2000.0,0.15);entry(2519.8,0.00);entry(3174.8,0.35);entry(4000.0,-0.16);entry(5039.7,0.39);entry(6349.6,0.56);entry(8000.0,-0.23);entry(10079.4,-2.63);entry(12699.2,-0.18);entry(16000.0,-0.39);entry(20158.7,1.86);entry(100019.7,0.40);entry(100024.8,0.39);entry(100031.2,0.38);entry(100039.4,0.37);entry(100049.6,0.35);entry(100062.5,0.33);entry(100078.7,0.30);entry(100099.2,0.27);entry(100125.0,0.23);entry(100157.5,0.19);entry(100198.4,0.13);entry(100250.0,0.05);entry(100315.0,-0.06);entry(100396.9,-0.16);entry(100500.0,-0.13);entry(100630.0,0.09);entry(100793.7,0.16);entry(101000.0,-0.27);entry(101259.9,0.16);entry(101587.4,0.08);entry(102000.0,-0.15);entry(102519.8,-0.00);entry(103174.8,-0.35);entry(104000.0,0.16);entry(105039.7,-0.39);entry(106349.6,-0.56);entry(108000.0,0.23);entry(110079.4,2.63);entry(112699.2,0.18);entry(116000.0,0.39);entry(120158.7,-1.86)':multi=on:zero_phase=on:delay=0.05,pan=stereo|FL=0.5*FL+0.5*FR|FR=0.5*FL-0.5*FR,firequalizer=gain='gain_interpolate(f+100000*ch)':gain_entry='entry(19.7,-2.84);entry(24.8,-2.82);entry(31.2,-2.80);entry(39.4,-2.77);entry(49.6,-2.73);entry(62.5,-2.66);entry(78.7,-2.57);entry(99.2,-2.46);entry(125.0,-2.34);entry(157.5,-2.28);entry(198.4,-2.36);entry(250.0,-2.60);entry(315.0,-2.70);entry(396.9,-2.17);entry(500.0,-1.09);entry(630.0,-0.26);entry(793.7,2.65);entry(1000.0,1.60);entry(1259.9,2.49);entry(1587.4,12.47);entry(2000.0,3.95);entry(2519.8,-2.15);entry(3174.8,-3.59);entry(4000.0,-2.51);entry(5039.7,-2.74);entry(6349.6,2.79);entry(8000.0,-1.93);entry(10079.4,3.19);entry(12699.2,-5.88);entry(16000.0,2.44);entry(20158.7,6.48);entry(100019.7,17.20);entry(100024.8,17.00);entry(100031.2,16.80);entry(100039.4,16.55);entry(100049.6,16.16);entry(100062.5,15.61);entry(100078.7,14.87);entry(100099.2,13.91);entry(100125.0,12.70);entry(100157.5,11.17);entry(100198.4,9.22);entry(100250.0,6.87);entry(100315.0,4.51);entry(100396.9,2.72);entry(100500.0,1.62);entry(100630.0,0.60);entry(100793.7,1.36);entry(101000.0,-0.98);entry(101259.9,0.27);entry(101587.4,1.29);entry(102000.0,-1.73);entry(102519.8,-4.35);entry(103174.8,-0.15);entry(104000.0,2.38);entry(105039.7,-4.46);entry(106349.6,0.56);entry(108000.0,0.56);entry(110079.4,-0.47);entry(112699.2,-3.47);entry(116000.0,1.70);entry(120158.7,7.55)':multi=on:zero_phase=on:delay=0.05,pan=stereo|FL=FL+FR|FR=FL-FR"   -- 3D stereo: L/R EQ, pan to M/S, M/S EQ, pan back (binaural_cal_stereo.py)
local SPK51 = "FL 30|FR 330|FC 0|SL 110|SR 250|BL 110|BR 250"   -- BS.775 (5.1 side or back)
local SPK71 = "FL 30|FR 330|FC 0|SL 90|SR 270|BL 135|BR 225"    -- BS.2051 0+7+0
local override = nil   -- manual on/off for the current file (Alt+u, panel); nil = the device gate decides
local st_mode = nil    -- 3D stereo for the session (Alt+U, panel); nil = option stereo
local dev = nil        -- { name, desc } of the endpoint the audio output opened
local cur = nil        -- graph string currently inserted (nil = none)
local state = { on = false, active = false, reason = "", why = "", osd = "" }
local last_track = nil -- the audio track as last seen; while objects.lua owns the audio mpv reports none
local update

local function sofa_path()
    local p = mp.command_native({ "expand-path", opts.sofa }) or opts.sofa
    return (p:gsub("\\", "/"):gsub(":", "\\:"))   -- second-level escape for the drive colon inside the lavfi graph
end
local function sofa_ok()   -- v1.6.1: without the HRTF file the script stays off (sofalizer would fail the whole chain)
    local p = mp.command_native({ "expand-path", opts.sofa }) or opts.sofa
    local i = require("mp.utils").file_info(p)
    return i ~= nil and i.is_file
end
local function present()
    for _, f in ipairs(mp.get_property_native("af") or {}) do if f.label == "binaural" then return true end end
    return false
end
local function owned_now()
    local ob = mp.get_property_native("user-data/objects")
    return (ob and ob.owns) and true or false
end
local preloading = false   -- v1.7.0: between on_preloaded and file-loaded the selected track is read from track-list
local function track()
    local t = mp.get_property_native("current-tracks/audio")
    if t then last_track = t; return t end
    if owned_now() then return last_track end
    if preloading then
        local sel = nil
        for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
            if tr.type == "audio" and (tr.selected or not sel) then sel = tr; if tr.selected then break end end
        end
        return sel
    end
    return nil
end
local function channels()
    local t = track()
    return t and tonumber(t["demux-channel-count"]) or nil
end
local function codec_ok()
    local t = track(); local c = t and tostring(t.codec or ""):lower() or ""
    for item in tostring(opts.codecs or ""):gmatch("[^,;]+") do
        item = item:match("^%s*(.-)%s*$"):lower()
        if item == "*" or (item ~= "" and item == c) then return true, c end
    end
    return false, c
end
local function trim_db() return math.max(-12, math.min(tonumber(opts.trim) or 0, 6)) end
local function strim_db() return math.max(-12, math.min(tonumber(opts.stereo_trim) or 0, 6)) end
local function graph(n)
    if n == 2 then
        return string.format("lavfi=[%s,sofalizer=sofa='%s':speakers='FL 30|FR 330':normalize=0:interpolate=0:type=freq:gain=%.2f]",
            PRE2, sofa_path(), 3 * 2 + OFFSET + strim_db())
    end
    local spk = (n and n > 6) and SPK71 or SPK51
    local pre = PRE[n]
    if pre then   -- v1.5.0: per-channel EQ before the HRTFs, every position matched to its fold contribution
        return string.format("lavfi=[%s,sofalizer=sofa='%s':speakers='%s':normalize=0:interpolate=0:type=freq:lfegain=%.2f:gain=%.2f]",
            pre, sofa_path(), spk, LFEGAIN, 3 * n + OFFSET + trim_db())
    end           -- other channel counts (rare): the v1.0 frontal EQ after the HRTFs
    return string.format("lavfi=[sofalizer=sofa='%s':speakers='%s':normalize=0:interpolate=0:type=freq:lfegain=%.2f:gain=%.2f,firequalizer=gain_entry='%s':zero_phase=on]",
        sofa_path(), spk, LFEGAIN, 3 * n + OFFSET + trim_db(), EQ)
end
local function device()
    local f = tostring(opts.device or "")
    if f ~= "" then return { name = f, desc = f } end
    return dev
end
local function on_list(d)
    if not d then return false end
    local dd, dn = tostring(d.desc):lower(), tostring(d.name):lower()
    for item in tostring(opts.headphones or ""):gmatch("[^,;]+") do
        item = item:match("^%s*(.-)%s*$"):lower()
        if item ~= "" and (dd:find(item, 1, true) or dn:find(item, 1, true)) then return true end
    end
    return false
end
local function decide()
    if override ~= nil then return override, "manual" end
    local d = device()
    if not opts.default then return false, "off by option" end
    if not d then return false, "device unknown" end
    if not on_list(d) then return false, "speakers" end
    local ok, c = codec_ok()
    if not ok and c ~= "" and (channels() or 0) > 2 then return false, c .. ": fold (auto only for " .. opts.codecs .. ")" end
    return true, "headphones: " .. d.desc
end
local function decide_st()   -- 3D stereo: the session switch, then the same headphone gate (no codec gate)
    local m = st_mode
    if m == nil then m = opts.stereo and true or false end
    if not m then return false, "off", m end
    local d = device()
    if not d then return false, "device unknown", m end
    if not on_list(d) then return false, "speakers", m end
    return true, "headphones: " .. d.desc, m
end
local function publish() mp.set_property_native("user-data/binaural", state) end
update = function(say, which)
    local n = channels()
    local en, why = decide()
    local sen, swhy, smode = decide_st()
    local want = (en and n ~= nil and n > 2) or (sen and n == 2)
    local owned = owned_now()
    local hrtf = sofa_ok()
    local g = (want and not owned and hrtf) and graph(n) or nil
    if g ~= cur or (g ~= nil) ~= present() then        -- touch the chain only when the decision changed
        if present() then mp.commandv("af", "remove", LABEL) end   -- (v1.6.0: also for 3D stereo, same label)
        if g then mp.commandv("af", "pre", LABEL .. ":" .. g) end
        cur = g
    end
    local ok_chain = want and (present() or owned)
    local active = ok_chain and n ~= nil and n > 2           -- the multichannel renderer plays
    local sactive = ok_chain and n == 2                      -- 3D stereo plays
    local d = device()
    local osd = "3D audio: " .. (en and "on" or "off") .. " (" .. why .. ")"
    if en and n and n <= 2 then osd = osd .. " - " .. (n == 2 and "stereo source: see 3D stereo (Alt+U)" or "mono source untouched") end
    if en and n and n > 2 and not active then osd = osd .. " - failed to load" end
    local sosd = "3D stereo: " .. (smode and "on" or "off") .. (smode and (" (" .. swhy .. ")") or "")
    if sen and n and n ~= 2 then sosd = sosd .. " - " .. (n == 1 and "mono source untouched" or "multichannel source: 3D audio decides") end
    if sen and n == 2 and not sactive then sosd = sosd .. " - failed to load" end
    state = { on = en, active = active, channels = n, device = d and d.desc or nil, headphones = on_list(d),
        manual = override ~= nil, why = why, osd = osd, owned = owned, trim = trim_db(),
        graph = (n and n >= 2 and (n > 2 or sen)) and graph(n):match("^lavfi=%[(.*)%]$") or nil,
        reason = (not en and "") or (n == nil and "no audio") or (n <= 2 and (n == 2 and "stereo source: 3D stereo row" or "mono source: untouched"))
            or (not active and (hrtf and "failed to load" or "no HRTF file (see README)")) or (owned and (n .. " ch -> binaural (object layer)")) or (n .. " ch -> binaural"),
        stereo = { mode = smode, on = sen, active = sactive, why = swhy, osd = sosd, trim = strim_db(),
            reason = (not smode and "") or (not sen and swhy) or (n == nil and "no audio")
                or (n ~= 2 and (n == 1 and "mono source" or "multichannel source")) or (not sactive and (hrtf and "failed to load" or "no HRTF file (see README)"))
                or "2 ch -> virtual speakers" } }
    publish()
    if say then mp.osd_message(which == "stereo" and sosd or osd, 2) end
end
options.read_options(opts, "binaural", function() update(true) end)
-- v1.7.0 (pipeline audit F5): the endpoint is remembered across sessions, so the first file's chain is decided before
-- the audio output opens (was: decided from the WASAPI log line after it opened -> a second audio init per open).
local DEVSTORE = mp.command_native({ "expand-path", "~~/cache/binaural-device.txt" })
do
    local fh = DEVSTORE and io.open(DEVSTORE, "r")
    if fh then
        local n, d = (fh:read("*l") or ""), (fh:read("*l") or ""); fh:close()
        if n ~= "" then dev = { name = n, desc = d, remembered = true } end
    end
end
local function set_dev(name, desc)
    local old = dev and dev.name
    local was_remembered = dev and dev.remembered
    dev = { name = name, desc = desc }
    if old ~= name and DEVSTORE then
        local fh = io.open(DEVSTORE, "w"); if fh then fh:write(name, "\n", desc or "", "\n"); fh:close() end
    end
    if old ~= name then update(old ~= nil and not was_remembered) end   -- OSD on a device change during the session
end
mp.enable_messages("v")
mp.register_event("log-message", function(e)
    if e.prefix ~= "ao/wasapi" then return end
    local id, desc = tostring(e.text):match("^Selecting device '(.-)' %((.*)%)")
    if id then set_dev("wasapi/" .. id, desc) end
end)
mp.observe_property("audio-device", "string", function(_, v)
    if not v or v == "" or v == "auto" then return end      -- auto: the WASAPI log names the default endpoint
    for _, e in ipairs(mp.get_property_native("audio-device-list") or {}) do
        if e.name == v then set_dev(v, e.description or v); return end
    end
end)
mp.register_event("start-file", function() override = nil; last_track = nil end)
-- v1.7.0: decide and insert before the audio output opens (one audio init per open)
mp.add_hook("on_preloaded", 40, function() preloading = true; update(false) end)
mp.register_event("file-loaded", function() preloading = false end)
mp.observe_property("current-tracks/audio", "native", function() update(false) end)
mp.observe_property("user-data/objects/owns", "native", function() update(false) end)
mp.add_key_binding("Alt+u", "binaural-toggle", function() override = not state.on; update(true) end)
mp.register_script_message("set-binaural", function(v)
    v = tostring(v or ""):lower(); override = (v == "yes" or v == "on" or v == "true" or v == "1"); update(true)
end)
mp.add_key_binding("Alt+U", "binaural-stereo-toggle", function()
    st_mode = not (state.stereo and state.stereo.mode); update(true, "stereo")
end)
mp.register_script_message("set-binaural-stereo", function(v)
    v = tostring(v or ""):lower(); st_mode = (v == "yes" or v == "on" or v == "true" or v == "1"); update(true, "stereo")
end)
publish()

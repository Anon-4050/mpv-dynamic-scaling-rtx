-- mpv-dynamic-scaling.lua
-- Author: Anon-4050 (with DeepThink R1)
-- Description: Dynamically adjusts scaling filters based on window size and video properties (HDR, bit depth, etc.)

mp.set_property("scale", "no") -- Disable MPV's default scaling

local function update_filters()
    local dW = mp.get_property_native("display-width")
    local dH = mp.get_property_native("display-height")
    local vW = mp.get_property_native("width")
    local vH = mp.get_property_native("height")
    if not (dW and dH and vW and vH) then return end

    local scale = math.floor((math.max(dW, dH) / math.max(vW, vH)) * 1000 + 0.5) / 1000

    local pixfmt = mp.get_property_native("video-params/hw-pixelformat")
                  or mp.get_property_native("video-params/pixelformat")
                  or ""
    local is_8bit = (pixfmt == "nv12" or pixfmt == "yuv420p")

    local primaries = (mp.get_property("video-params/primaries") or ""):lower()
    local transfer  = (mp.get_property("video-params/transfer") or ""):lower()
    local is_hdr = (primaries:find("bt.2020") ~= nil) or (transfer:find("pq") ~= nil)

    local chain = ""
    if not is_hdr then
        chain = is_8bit 
            and "d3d11vpp=scaling-mode=nvidia:scale=" .. scale .. ":nvidia-true-hdr"
            or  "format=nv12,d3d11vpp=scaling-mode=nvidia:scale=" .. scale .. ":nvidia-true-hdr"
    else
        chain = "d3d11vpp=scaling-mode=nvidia:scale=" .. scale
    end

    mp.command("vf set " .. chain)
end

local observed_properties = {
    "display-width", "display-height", "width", "height",
    "video-params/hw-pixelformat", "video-params/pixelformat",
    "video-params/primaries", "video-params/transfer"
}

for _, prop in ipairs(observed_properties) do
    mp.observe_property(prop, "native", update_filters)
end

mp.add_timeout(0.1, update_filters)
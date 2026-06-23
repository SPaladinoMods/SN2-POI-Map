local Lang = require("lang")

local MANIFEST_PATH = "./ue4ss/Mods/SN2ModSettings/registrations/SN2-POI-Map.lua"
local VERSION = "1.0.2"
local isWritingManifest = false

local function ensureRegistrationDirectory()
    if not os or not os.execute then return end
    os.execute('mkdir ".\\ue4ss\\Mods\\SN2ModSettings\\registrations" >nul 2>nul')
end

local function esc(value)
    return tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
end

local function option(groupName, token)
    return esc(Lang.getOptionLabel(groupName, token))
end

local function buildManifest()
    return string.format([[
return {
    name = "SN2-POI-Map",
    display = "%s",
    version = "%s",
    github = "SPaladinoMods/SN2-POI-Map",
    settings = {
        {
            key = "MinimapEnabled",
            title = "%s",
            description = "%s",
            type = "toggle",
            default = true,
        },
        {
            key = "ShowMinimapAtStartup",
            title = "%s",
            description = "%s",
            type = "toggle",
            default = true,
        },
        {
            key = "LogLevel",
            title = "%s",
            description = "%s",
            type = "rotator",
            options = { "%s", "%s", "%s", "%s", "%s" },
            default = "%s",
        },
        {
            key = "MinimapAnchor",
            title = "%s",
            description = "%s",
            type = "rotator",
            options = { "%s", "%s", "%s", "%s" },
            default = "%s",
        },
        {
            key = "FogOfWarEnabled",
            title = "%s",
            description = "%s",
            type = "toggle",
            default = true,
        },
        {
            key = "MinimapWidth",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 360,
            min = 180,
            max = 720,
            step = 10,
            format = "integer",
        },
        {
            key = "MinimapMarginTop",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 24,
            min = 0,
            max = 240,
            step = 4,
            format = "integer",
        },
        {
            key = "MinimapMarginRight",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 24,
            min = 0,
            max = 240,
            step = 4,
            format = "integer",
        },
        {
            key = "MinimapBackgroundAlpha",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 0.55,
            min = 0.0,
            max = 1.0,
            step = 0.05,
            format = "float",
        },
        {
            key = "MinimapMapAlpha",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 0.92,
            min = 0.1,
            max = 1.0,
            step = 0.05,
            format = "float",
        },
        {
            key = "MarkerSize",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 12,
            min = 8,
            max = 24,
            step = 1,
            format = "integer",
        },
        {
            key = "MarkerColorPreset",
            title = "%s",
            description = "%s",
            type = "rotator",
            options = { "%s", "%s", "%s", "%s", "%s", "%s", "%s", "%s", "%s" },
            default = "%s",
        },
        {
            key = "ShowOtherPlayers",
            title = "%s",
            description = "%s",
            type = "toggle",
            default = false,
        },
        {
            key = "OtherPlayerMarkerSize",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 9,
            min = 7,
            max = 12,
            step = 1,
            format = "integer",
            enabled_by = "ShowOtherPlayers",
        },
        {
            key = "FogRevealRadius",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 1,
            min = 1,
            max = 4,
            step = 1,
            format = "integer",
        },
        {
            key = "FogAlpha",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 0.95,
            min = 0.0,
            max = 1.0,
            step = 0.05,
            format = "float",
        },
        {
            key = "FogVisualThrottleMs",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 750,
            min = 100,
            max = 3000,
            step = 50,
            format = "integer",
        },
        {
            key = "FogSaveThrottleMs",
            title = "%s",
            description = "%s",
            type = "slider",
            default = 20000,
            min = 1000,
            max = 60000,
            step = 1000,
            format = "integer",
        },
    },
}
]],
        esc(Lang.L("mod_display")),
        VERSION,
        esc(Lang.L("setting_enable_minimap_title")),
        esc(Lang.L("setting_enable_minimap_desc")),
        esc(Lang.L("setting_show_minimap_startup_title")),
        esc(Lang.L("setting_show_minimap_startup_desc")),
        esc(Lang.L("setting_log_level_title")),
        esc(Lang.L("setting_log_level_desc")),
        option("log_level", "Off"),
        option("log_level", "Error"),
        option("log_level", "Warning"),
        option("log_level", "Info"),
        option("log_level", "Verbose"),
        option("log_level", "Info"),
        esc(Lang.L("setting_minimap_anchor_title")),
        esc(Lang.L("setting_minimap_anchor_desc")),
        option("minimap_anchor", "TopLeft"),
        option("minimap_anchor", "TopRight"),
        option("minimap_anchor", "BottomLeft"),
        option("minimap_anchor", "BottomRight"),
        option("minimap_anchor", "BottomRight"),
        esc(Lang.L("setting_fog_enabled_title")),
        esc(Lang.L("setting_fog_enabled_desc")),
        esc(Lang.L("setting_minimap_width_title")),
        esc(Lang.L("setting_minimap_width_desc")),
        esc(Lang.L("setting_minimap_margin_top_title")),
        esc(Lang.L("setting_minimap_margin_top_desc")),
        esc(Lang.L("setting_minimap_margin_right_title")),
        esc(Lang.L("setting_minimap_margin_right_desc")),
        esc(Lang.L("setting_minimap_background_alpha_title")),
        esc(Lang.L("setting_minimap_background_alpha_desc")),
        esc(Lang.L("setting_minimap_map_alpha_title")),
        esc(Lang.L("setting_minimap_map_alpha_desc")),
        esc(Lang.L("setting_marker_size_title")),
        esc(Lang.L("setting_marker_size_desc")),
        esc(Lang.L("setting_marker_color_title")),
        esc(Lang.L("setting_marker_color_desc")),
        option("marker_color_preset", "White"),
        option("marker_color_preset", "Cyan"),
        option("marker_color_preset", "Blue"),
        option("marker_color_preset", "Green"),
        option("marker_color_preset", "Yellow"),
        option("marker_color_preset", "Orange"),
        option("marker_color_preset", "Red"),
        option("marker_color_preset", "Purple"),
        option("marker_color_preset", "Pink"),
        option("marker_color_preset", "Green"),
        esc(Lang.L("setting_show_other_players_title")),
        esc(Lang.L("setting_show_other_players_desc")),
        esc(Lang.L("setting_other_player_marker_size_title")),
        esc(Lang.L("setting_other_player_marker_size_desc")),
        esc(Lang.L("setting_fog_reveal_radius_title")),
        esc(Lang.L("setting_fog_reveal_radius_desc")),
        esc(Lang.L("setting_fog_alpha_title")),
        esc(Lang.L("setting_fog_alpha_desc")),
        esc(Lang.L("setting_fog_visual_throttle_title")),
        esc(Lang.L("setting_fog_visual_throttle_desc")),
        esc(Lang.L("setting_fog_save_throttle_title")),
        esc(Lang.L("setting_fog_save_throttle_desc"))
    )
end

local function writeManifest()
    if isWritingManifest then
        return false
    end

    isWritingManifest = true

    ensureRegistrationDirectory()

    local file = io.open(MANIFEST_PATH, "w")
    if not file then
        isWritingManifest = false
        print("[SN2-POI-Map] SN2ModSettings registration skipped; directory not available")
        return false
    end

    file:write(buildManifest())
    file:close()
    isWritingManifest = false
    print("[SN2-POI-Map] SN2ModSettings registration written")
    return true
end

pcall(function()
    Lang.refresh()
end)

Lang.addRefreshListener(writeManifest)
writeManifest()

return true

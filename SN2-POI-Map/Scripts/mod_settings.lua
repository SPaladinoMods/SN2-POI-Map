local MANIFEST_PATH = "./ue4ss/Mods/SN2ModSettings/registrations/SN2-POI-Map.lua"

local function ensureRegistrationDirectory()
    if not os or not os.execute then return end
    os.execute('mkdir ".\\ue4ss\\Mods\\SN2ModSettings\\registrations" >nul 2>nul')
end

local function writeManifest()
    ensureRegistrationDirectory()

    local file = io.open(MANIFEST_PATH, "w")
    if not file then
        print("[SN2-POI-Map] SN2ModSettings registration skipped; directory not available")
        return false
    end

    file:write([[
return {
    name = "SN2-POI-Map",
    display = "SN2-POI-Map",
    version = "1.0.1",
    github = "SPaladinoMods/SN2-POI-Map",
    settings = {
        {
            key = "MinimapEnabled",
            title = "Enable Minimap",
            description = "Turns the small on-screen minimap on or off.",
            type = "toggle",
            default = true,
        },
        {
            key = "ShowMinimapAtStartup",
            title = "Show Minimap at Startup",
            description = "Shows the minimap when a save finishes loading.",
            type = "toggle",
            default = true,
        },
        {
            key = "LogLevel",
            title = "Log Level",
            description = "Controls how much SN2-POI-Map prints to the UE4SS console.",
            type = "rotator",
            options = { "Off", "Error", "Warning", "Info", "Verbose" },
            default = "Info",
        },
        {
            key = "MinimapAnchor",
            title = "Minimap Anchor",
            description = "Chooses which corner of the screen the minimap uses.",
            type = "rotator",
            options = { "TopLeft", "TopRight", "BottomLeft", "BottomRight" },
            default = "BottomRight",
        },
        {
            key = "FogOfWarEnabled",
            title = "Enable Fog of War",
            description = "Hides unexplored map areas until they are revealed.",
            type = "toggle",
            default = true,
        },
        {
            key = "MinimapWidth",
            title = "Minimap Width",
            description = "Controls the minimap width in pixels.",
            type = "slider",
            default = 360,
            min = 180,
            max = 720,
            step = 10,
            format = "integer",
        },
        {
            key = "MinimapMarginTop",
            title = "Minimap Top Margin",
            description = "Moves the minimap down from the top edge of the screen.",
            type = "slider",
            default = 24,
            min = 0,
            max = 240,
            step = 4,
            format = "integer",
        },
        {
            key = "MinimapMarginRight",
            title = "Minimap Side Margin",
            description = "Moves the minimap inward from the anchored screen edge.",
            type = "slider",
            default = 24,
            min = 0,
            max = 240,
            step = 4,
            format = "integer",
        },
        {
            key = "MinimapBackgroundAlpha",
            title = "Minimap Background Opacity",
            description = "Controls the dark backdrop opacity behind the minimap.",
            type = "slider",
            default = 0.55,
            min = 0.0,
            max = 1.0,
            step = 0.05,
            format = "float",
        },
        {
            key = "MinimapMapAlpha",
            title = "Minimap Map Opacity",
            description = "Controls the map image opacity inside the minimap.",
            type = "slider",
            default = 0.92,
            min = 0.1,
            max = 1.0,
            step = 0.05,
            format = "float",
        },
        {
            key = "MarkerSize",
            title = "Player Marker Size",
            description = "Changes the size of the player's arrow marker on the maps.",
            type = "slider",
            default = 12,
            min = 8,
            max = 24,
            step = 1,
            format = "integer",
        },
        {
            key = "MarkerColorPreset",
            title = "Player Marker Color",
            description = "Changes the player's arrow marker color.",
            type = "rotator",
            options = { "White", "Cyan", "Blue", "Green", "Yellow", "Orange", "Red", "Purple", "Pink" },
            default = "Green",
        },
        {
            key = "ShowOtherPlayers",
            title = "Show Other Players",
            description = "Shows experimental multiplayer markers for other players on the maps.",
            type = "toggle",
            default = false,
        },
        {
            key = "OtherPlayerMarkerSize",
            title = "Other Player Marker Size",
            description = "Changes the size of other player markers on the maps.",
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
            title = "Fog Reveal Radius",
            description = "Controls how many fog cells around the player are revealed at once.",
            type = "slider",
            default = 1,
            min = 1,
            max = 4,
            step = 1,
            format = "integer",
        },
        {
            key = "FogAlpha",
            title = "Fog Opacity",
            description = "Controls how opaque unrevealed fog appears on the map.",
            type = "slider",
            default = 0.95,
            min = 0.0,
            max = 1.0,
            step = 0.05,
            format = "float",
        },
        {
            key = "FogVisualThrottleMs",
            title = "Fog Visual Throttle",
            description = "Batches fog texture refreshes to reduce hitching while exploring.",
            type = "slider",
            default = 750,
            min = 100,
            max = 3000,
            step = 50,
            format = "integer",
        },
        {
            key = "FogSaveThrottleMs",
            title = "Fog Save Throttle",
            description = "Batches fog progress writes to disk. Higher values write less often.",
            type = "slider",
            default = 20000,
            min = 1000,
            max = 60000,
            step = 1000,
            format = "integer",
        },
    },
}
]])

    file:close()
    print("[SN2-POI-Map] SN2ModSettings registration written")
    return true
end

writeManifest()

return true

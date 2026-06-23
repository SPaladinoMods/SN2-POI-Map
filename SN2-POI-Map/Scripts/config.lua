local Config = {
    -- Key to open/close the large map (UE4SS key names: "M", "TAB", "F6", etc.) https://docs.ue4ss.com/lua-api/table-definitions/key.html
    OpenMapKey = "M",
    -- Modifier keys for the open map key (e.g. {"SHIFT"}, {"CONTROL"})
    OpenMapModifiers = {},

    -- Key to show/hide the minimap
    HideMapKey = "H",
    -- Modifier keys for the hide map key
    HideMapModifiers = {},

    -- Zoom in / out keys. They affect whichever map is currently shown.
    ZoomInKey = "ADD",
    ZoomInModifiers = {},
    ZoomOutKey = "SUBTRACT",
    ZoomOutModifiers = {},

    -- Large-map pan keys. Active only while the large map is open and zoomed past 1.0.
    PanUpKey = "UP_ARROW",
    PanUpModifiers = {},
    PanDownKey = "DOWN_ARROW",
    PanDownModifiers = {},
    PanLeftKey = "LEFT_ARROW",
    PanLeftModifiers = {},
    PanRightKey = "RIGHT_ARROW",
    PanRightModifiers = {},

    -- If true, the minimap is visible when the game starts
    ShowMinimapAtStartup = true,
    -- Default map refresh interval (milliseconds)
    UpdateIntervalMs = 500,
    -- Delay before the first attempt to attach the overlay to the HUD (ms)
    AttachInitialDelayMs = 250,
    -- Successive retry delays if the overlay fails to attach (ms)
    AttachRetryDelaysMs = { 250, 500, 1000, 2000, 5000 },
    -- How often the game window size is polled for changes (ms)
    ViewportPollIntervalMs = 1000,
    -- Key debounce time to prevent double presses (ms)
    KeyDebounceMs = 600,

    Localization = {
        -- "auto" follows the game's active language. Use a culture code like "fr" or "pt-BR" to force one.
        Language = "auto",
        -- Delay before re-checking the language after the mod first loads.
        StartupRefreshDelayMs = 3000,
        -- Delay before re-checking the language after ApplySettings fires.
        ApplySettingsRefreshDelayMs = 750,
        -- Periodic language polling interval so manifest rewrites do not depend only on one UI hook.
        PollIntervalMs = 1000,
    },

    Map = {
        ImageFile = "subnautica2_world_base.jpg",
        ImageWidth = 10423,
        ImageHeight = 5044,
        ProjectionMode = "DirectImage",
        PlayerProjectionMode = "DirectImage",
        ImageFromWorldXScale = 0.032374468782,
        ImageFromWorldXOffset = 12648.058095,
        ImageFromWorldYScale = 0.035855059642,
        ImageFromWorldYOffset = -13027.687750,
        LngFromXScale = 0.0000028912681189998626,
        LngFromXOffset = -0.049961343800042045,
        LatFromYScale = -0.000002992336954998909,
        LatFromYOffset = 2.0063350541995395,
        BoundsWest = -1.13,
        BoundsEast = -0.345,
        BoundsSouth = 0.565,
        BoundsNorth = 0.895,
        HorizontalAxis = "X",
        VerticalAxis = "Y",
        WorldMinX = -70000.0,
        WorldMaxX = 70000.0,
        WorldMinY = -70000.0,
        WorldMaxY = 70000.0,
        AutoCenterOnFirstPlayerPosition = false,
        AutoCenterSpanX = 140000.0,
        AutoCenterSpanY = 140000.0,
        InitialMapU = 0.5,
        InitialMapV = 0.5,
        InvertVertical = true,
        ClampMarkerToMap = true,
    },

    Minimap = {
        -- Enables or disables the minimap
        Enabled = true,
        -- Minimap refresh interval (ms)
        UpdateIntervalMs = 500,
        -- Screen anchor for the minimap ("TopRight", "TopLeft", "BottomRight", "BottomLeft", "Center")
        Anchor = "BottomRight",
        -- Fixed minimap width in pixels (height adapts to the image aspect ratio)
        Width = 360,
        -- Zoom factor: 1.0 = whole map fits the box; higher = magnified and follows the player
        Zoom = 3.0,
        ZoomMin = 1.0,
        ZoomMax = 12.0,
        ZoomStep = 0.5,
        -- Margin from the top of the screen (pixels)
        MarginTop = 24,
        -- Margin from the right of the screen (pixels)
        MarginRight = 24,
        -- Opacity of the dark background behind the minimap (0.0 = transparent, 1.0 = opaque)
        BackgroundAlpha = 0.55,
        -- Opacity of the map image itself
        MapAlpha = 0.92,
        -- Border thickness around the minimap (pixels)
        BorderThickness = 2,
    },

    LargeMap = {
        -- Large map refresh interval (ms, faster since it's the main focus)
        UpdateIntervalMs = 200,
        -- Screen anchor for the large map (centered)
        Anchor = "Center",
        -- Large map width as a fraction of the screen (0.90 = 90%)
        WidthRatio = 0.90,
        -- Large map height as a fraction of the screen (0.72 = 72%)
        HeightRatio = 0.72,
        -- Zoom factor: 1.0 = whole map fits the box; higher = magnified
        Zoom = 1.0,
        ZoomMin = 1.0,
        ZoomMax = 8.0,
        ZoomStep = 0.5,
        -- Pan distance per arrow press, as a fraction of the visible view
        PanStep = 0.25,
        -- Opacity of the dark background behind the large map
        BackgroundAlpha = 0.88,
        -- Opacity of the map image
        MapAlpha = 1.0,
        -- Border thickness (pixels)
        BorderThickness = 3,
        -- If true, dims the entire screen behind the large map
        DimBackground = true,
    },

    Marker = {
        -- Player marker image file (directional arrow)
        ImageFile = "WhiteArrow.png",
        -- Marker size in pixels
        Size = 12,
        -- Named color preset used by the in-game settings menu
        ColorPreset = "Green",
        -- Pixel movement threshold before redrawing the marker (avoids micro-updates)
        MoveThresholdPixels = 4,
        -- Rotation threshold in degrees before redrawing the marker heading
        HeadingThresholdDegrees = 3,
        -- Movement threshold in UE units before the player is considered to have moved
        WorldMoveThreshold = 150.0,
        -- Marker color (R, G, B, A; default orange tint)
        Color = { R = 0.22745098, G = 0.75294118, B = 0.29019608, A = 1.0 },
    },

    Multiplayer = {
        -- If true, opening the map does not pause networked worlds
        DisablePauseInMultiplayer = true,
        -- If true, experimental other-player markers are shown on the map
        ShowOtherPlayers = false,
        -- Player actor classes to scan for other players
        PlayerActorClasses = { "BP_Character_01_C" },
        -- Maximum number of other player markers to draw
        MaxPlayerMarkers = 7,
        -- Other player marker size in pixels
        OtherPlayerMarkerSize = 9,
        -- Other player marker color (R, G, B, A; orange here)
        OtherPlayerMarkerColor = { R = 0.94117647, G = 0.51372549, B = 0.22745098, A = 1.0 },
    },

    FogOfWar = {
        -- Enables or disables fog of war
        Enabled = true,
        -- Number of horizontal cells in the fog grid
        GridWidth = 114,
        -- Number of vertical cells in the fog grid
        GridHeight = 48,
        -- Reveal radius around the player (in cells)
        RevealRadius = 1,
        -- Folder name under %LOCALAPPDATA%\Subnautica2\Saved for per-save fog files
        RuntimeFolderName = "SN2-POI-Map",
        -- Fallback folder if the active game save slot cannot be detected
        FallbackSaveSlotName = "unsaved",
        -- Save file for fog state (which cells have been revealed), stored per save slot
        SaveFile = "fog_state.dat",
        -- Runtime TGA texture generated from the fog state, stored per save slot
        OverlayFile = "fog_overlay.tga",
        -- Opacity of unrevealed fog (0.0 = invisible, 1.0 = fully opaque)
        FogAlpha = 0.95,
        -- Batch on-screen fog texture refreshes so exploring does not write/import on every cell crossing
        VisualThrottleMs = 750,
        -- Batch fog progress saves. A map change still forces a save.
        SaveThrottleMs = 20000,
        -- Periodic fog/POI state flush interval, even without a manual game save
        AutoSaveIntervalMs = 300000,
    },

    Debug = {
        Enabled = false,
        LogLevel = "Info",
        LogPosition = false,
        DrawCoordinates = false,
    },
}

return Config

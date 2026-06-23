local UEHelpers = require("UEHelpers")
local Config = require("config")
local Json = require("json")
-- Writes the optional SN2ModSettings registration when that mod is installed.
pcall(require, "mod_settings")

local MOD_NAME = "SN2-POI-Map"
local VISIBLE = 3 -- ESlateVisibility::HitTestInvisible
local HIDDEN = 2  -- ESlateVisibility::Hidden
local DEFAULT_ATTACH_RETRY_DELAYS_MS = { 250, 500, 1000, 2000, 5000 }

local mapVisible = Config.ShowMinimapAtStartup ~= false
local largeMapOpen = false
minimapZoom = (Config.Minimap and Config.Minimap.Zoom) or 1.0
largeMapZoom = (Config.LargeMap and Config.LargeMap.Zoom) or 1.0
largeMapViewU = nil
largeMapViewV = nil
local textureLoadAttempted = false
local pixelLoadAttempted = false
local arrowLoadAttempted = false
local attachAttemptQueued = false
local attachAttemptToken = 0
local attachAttemptGameThreadToken = 0
local attachRetryIndex = 1
local updateLoopActive = false
local attachAttemptLogged = false
local overlayAttachedLogged = false
local updateErrorLogged = false
local poiRowToggleLocked = false
local poiMousePositionWarningLogged = false
local poiAllVisible = true
local poiAllRowVisibleState = nil
local poiAllRowHitRect = nil

local getMousePositionOnViewport
local getPoiPanelTargetAtScreenPosition

local poiCategories = nil
local poiCategoriesById = {}
local poiPointsByCategoryId = {}
local poiIconManifestById = {}
local poiLabelManifestById = {}
local poiLabelColumnInfo = nil
local poiDataLoadAttempted = false
local poiLabelColumnTexture = CreateInvalidObject()
local poiLabelColumnTextureAttempted = false

-- Shared POI icon sizing for all category markers.
local POI_ICON_SCALE = 4.0
local POI_ICON_BASE_SIZE = 9.6
local POI_MARKER_SIZE = math.floor((POI_ICON_BASE_SIZE * POI_ICON_SCALE) + 0.5)
local POI_MARKER_ANCHOR_X = 0.5
local POI_MARKER_ANCHOR_Y = 1.0
DEFAULT_REMOTE_PLAYER_CLASSES = { "BP_Character_01_C" }

local calibrationLogged = false
local mapPauseApplied = false
multiplayerPauseSuppressedLogged = false
local scheduleMapWork
local markOverlayStateDirty
local updateRequested = false
local overlayGeneration = 0
local frameSample = {}
local drawState = {}
local mapPoint = {}
remotePlayerSamples = {}
lastRemotePlayersKey = nil
local cachedScreenW = 1920
local cachedScreenH = 1080
local viewportDirty = true
local viewportPollCountdown = 0

-- Fog-of-war reveal state is stored separately from the map and POI marker layers.
local fogGrid = {}
local fogDirty = false
local fogLastCellX = nil
local fogLastCellY = nil
fogSaveDirty = false
fogFlushPending = false
fogSavePending = false
fogRuntime = {
    slotName = nil,
    directory = nil,
    pathLogged = false,
    sessionFallbackSlotName = nil,
    nextAutoSaveAt = nil,
}
poiRuntime = {
    stateFileName = "poi_category_state.dat",
}
local isFogEnabled
local loadFogTexture

isFogEnabled = function()
    return Config.FogOfWar and Config.FogOfWar.Enabled ~= false
end

local renderingLibrary = CreateInvalidObject()
local widgetLayoutLibrary = CreateInvalidObject()
local mapTexture = CreateInvalidObject()
local pixelTexture = CreateInvalidObject()
local arrowTexture = CreateInvalidObject()
local fogTexture = CreateInvalidObject()

local overlay = {
    hudScreen = CreateInvalidObject(),
    root = CreateInvalidObject(),
    canvas = CreateInvalidObject(),
    canvasSlot = nil,
    viewport = CreateInvalidObject(),
    viewportSlot = nil,
    dim = CreateInvalidObject(),
    dimSlot = nil,
    map = CreateInvalidObject(),
    mapSlot = nil,
    borderTop = CreateInvalidObject(),
    borderTopSlot = nil,
    borderRight = CreateInvalidObject(),
    borderRightSlot = nil,
    borderBottom = CreateInvalidObject(),
    borderBottomSlot = nil,
    borderLeft = CreateInvalidObject(),
    borderLeftSlot = nil,
    marker = CreateInvalidObject(),
    markerSlot = nil,
    remotePlayerMarkers = {},
    remotePlayerMarkerSlots = {},
    remotePlayerMarkerVisibleStates = {},
    remotePlayerMarkerKeys = {},
    mapTextureApplied = false,
    markerTextureApplied = false,
    remotePlayerTextureApplied = false,
    remotePlayerMarkerSize = nil,
    fog = CreateInvalidObject(),
    fogSlot = nil,
    fogTextureApplied = false,
    poiPanel = CreateInvalidObject(),
    poiPanelSlot = nil,
    poiMarkersByCategoryId = {},
    poiMarkerSlotsByCategoryId = {},
    poiAllRow = CreateInvalidObject(),
    poiAllRowSlot = nil,
    poiRowsByCategoryId = {},
    poiRowSlotsByCategoryId = {},
    poiLabelColumn = CreateInvalidObject(),
    poiLabelColumnSlot = nil,
    lastCanvasVisible = nil,
    lastDimVisible = nil,
    lastMarkerVisible = nil,
    lastMarkerXKey = nil,
    lastMarkerYKey = nil,
    lastMarkerAngleKey = nil,
    lastMarkerSize = nil,
    lastHeadingAngleKey = nil,
}

local widgetClasses = {}
local runtimeBounds = nil
local configuredBounds = {
    MinX = Config.Map.WorldMinX,
    MaxX = Config.Map.WorldMaxX,
    MinY = Config.Map.WorldMinY,
    MaxY = Config.Map.WorldMaxY,
}

local function log(message, level)
    local current = (((Config or {}).Debug or {}).LogLevel) or "Info"
    local currentPriority = 3
    local requestedPriority = 3

    if current == "Off" then
        currentPriority = 0
    elseif current == "Error" then
        currentPriority = 1
    elseif current == "Warning" then
        currentPriority = 2
    elseif current == "Verbose" then
        currentPriority = 4
    end

    if level == "Error" then
        requestedPriority = 1
    elseif level == "Warning" then
        requestedPriority = 2
    elseif level == "Verbose" then
        requestedPriority = 4
    end

    if currentPriority == 0 or requestedPriority > currentPriority then
        return
    end

    print(string.format("[%s][%s] %s\n", MOD_NAME, level or "Info", message))
end

local function isValid(object)
    return object and object.IsValid and object:IsValid()
end

local scratchVec2 = { X = 0.0, Y = 0.0 }
local function vec2(x, y)
    scratchVec2.X = x
    scratchVec2.Y = y
    return scratchVec2
end

local function color(value, fallbackAlpha)
    value = value or {}
    return {
        R = value.R or 1.0,
        G = value.G or 1.0,
        B = value.B or 1.0,
        A = value.A or fallbackAlpha or 1.0,
    }
end

local COLOR_BLACK = { R = 0.0, G = 0.0, B = 0.0, A = 0.45 }
local COLOR_WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local COLOR_BORDER = { R = 0.0, G = 0.8, B = 1.0, A = 0.85 }
local COLOR_MARKER = color((Config.Marker or {}).Color, 1.0)
COLOR_REMOTE_PLAYER = color(((Config.Multiplayer or {}).OtherPlayerMarkerColor or { R = 1.0, G = 0.68, B = 0.12, A = 1.0 }), 1.0)

function normalizeMinimapAnchor(value)
    if value == "TopLeft" or value == "TopRight" or value == "BottomLeft" or value == "BottomRight" or value == "Center" then
        return value
    end
    return "BottomRight"
end

function applyMarkerColorPreset(presetName)
    local safeName = type(presetName) == "string" and presetName or "Green"
    local preset = { R = 0.0, G = 0.9, B = 1.0, A = 1.0 }
    if safeName == "White" then
        preset = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    elseif safeName == "Blue" then
        preset = { R = 0.2, G = 0.5, B = 1.0, A = 1.0 }
    elseif safeName == "Green" then
        preset = { R = 0.25, G = 0.95, B = 0.35, A = 1.0 }
    elseif safeName == "Yellow" then
        preset = { R = 1.0, G = 0.92, B = 0.2, A = 1.0 }
    elseif safeName == "Orange" then
        preset = { R = 0.94117647, G = 0.51372549, B = 0.22745098, A = 1.0 }
    elseif safeName == "Red" then
        preset = { R = 1.0, G = 0.22, B = 0.22, A = 1.0 }
    elseif safeName == "Purple" then
        preset = { R = 0.72, G = 0.4, B = 1.0, A = 1.0 }
    elseif safeName == "Pink" then
        preset = { R = 1.0, G = 0.45, B = 0.78, A = 1.0 }
    else
        safeName = "Green"
    end
    Config.Marker.ColorPreset = safeName
    Config.Marker.Color = Config.Marker.Color or {}
    Config.Marker.Color.R = preset.R
    Config.Marker.Color.G = preset.G
    Config.Marker.Color.B = preset.B
    Config.Marker.Color.A = preset.A
    COLOR_MARKER.R = preset.R
    COLOR_MARKER.G = preset.G
    COLOR_MARKER.B = preset.B
    COLOR_MARKER.A = preset.A
    overlay.lastMarkerColorKey = nil
end

applyMarkerColorPreset((Config.Marker or {}).ColorPreset or "Green")

local lastWorldX = nil
local lastWorldY = nil
local lastForwardX = nil
local lastForwardY = nil

local cachedPawn = CreateInvalidObject()
local pawnCheckCountdown = 0
local PAWN_CHECK_INTERVAL = 10

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function quantize(value, step)
    step = step or 1
    if step <= 0 then return value end
    return math.floor((value / step) + 0.5)
end

local function safeCall(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        log(label .. " failed: " .. tostring(result), "Error")
        return nil
    end
    return result
end

local function resetOverlayCaches()
    overlay.lastLayoutLarge = nil
    overlay.lastLayoutScreenW = nil
    overlay.lastLayoutScreenH = nil
    overlay.lastLayoutXKey = nil
    overlay.lastLayoutYKey = nil
    overlay.lastLayoutWidthKey = nil
    overlay.lastLayoutHeightKey = nil
    overlay.lastLayoutMapAlpha = nil
    overlay.lastLayoutBackgroundAlpha = nil
    overlay.lastLayoutBorderThickness = nil
    overlay.lastLayoutDimVisible = nil
    overlay.lastCanvasVisible = nil
    overlay.lastDimVisible = nil
    overlay.lastMarkerVisible = nil
    overlay.lastMarkerXKey = nil
    overlay.lastMarkerYKey = nil
    overlay.lastMarkerAngleKey = nil
    overlay.lastMarkerSize = nil
    overlay.lastHeadingAngleKey = nil
    overlay.remotePlayerMarkerVisibleStates = {}
    overlay.remotePlayerMarkerKeys = {}
    overlay.remotePlayerMarkerSize = nil
    lastRemotePlayersKey = nil
    overlay.lastPoiPanelVisible = nil
    overlay.lastPoiPanelRowsVisible = nil
    overlay.lastPoiLabelColumnVisible = nil
end

local function clearOverlayWidgetRefs(clearOwner)
    if clearOwner then
        overlay.hudScreen = CreateInvalidObject()
        overlay.root = CreateInvalidObject()
    end

    overlay.canvas = CreateInvalidObject()
    overlay.canvasSlot = nil
    overlay.viewport = CreateInvalidObject()
    overlay.viewportSlot = nil
    overlay.dim = CreateInvalidObject()
    overlay.dimSlot = nil
    overlay.map = CreateInvalidObject()
    overlay.mapSlot = nil
    overlay.borderTop = CreateInvalidObject()
    overlay.borderTopSlot = nil
    overlay.borderRight = CreateInvalidObject()
    overlay.borderRightSlot = nil
    overlay.borderBottom = CreateInvalidObject()
    overlay.borderBottomSlot = nil
    overlay.borderLeft = CreateInvalidObject()
    overlay.borderLeftSlot = nil
    overlay.marker = CreateInvalidObject()
    overlay.markerSlot = nil
    overlay.remotePlayerMarkers = {}
    overlay.remotePlayerMarkerSlots = {}
    overlay.remotePlayerMarkerVisibleStates = {}
    overlay.remotePlayerMarkerKeys = {}
    overlay.mapTextureApplied = false
    overlay.markerTextureApplied = false
    overlay.remotePlayerTextureApplied = false
    overlay.remotePlayerMarkerSize = nil
    overlay.fog = CreateInvalidObject()
    overlay.fogSlot = nil
    overlay.fogTextureApplied = false
    overlay.poiPanel = CreateInvalidObject()
    overlay.poiPanelSlot = nil
    overlay.poiMarkersByCategoryId = {}
    overlay.poiMarkerSlotsByCategoryId = {}
    overlay.poiAllRow = CreateInvalidObject()
    overlay.poiAllRowSlot = nil
    overlay.poiRowsByCategoryId = {}
    overlay.poiRowSlotsByCategoryId = {}
    overlay.poiLabelColumn = CreateInvalidObject()
    overlay.poiLabelColumnSlot = nil
    poiAllRowVisibleState = nil
    poiAllRowHitRect = nil
    resetOverlayCaches()
end

local function detachOverlay(clearOwner)
    if overlay.canvas and overlay.canvas:IsValid() then
        safeCall("Remove overlay canvas", function()
            overlay.canvas:RemoveFromParent()
        end)
    end

    clearOverlayWidgetRefs(clearOwner)
end

local function sameObject(a, b)
    if not a or not b or not a:IsValid() or not b:IsValid() then return false end
    local okA, addressA = pcall(function() return a:GetAddress() end)
    local okB, addressB = pcall(function() return b:GetAddress() end)
    return okA and okB and addressA == addressB
end

local function isAbsolutePath(path)
    return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function normalizePath(path)
    return (path:gsub("/", "\\"))
end

local function joinPath(basePath, fileName)
    return normalizePath(basePath):gsub("[\\/]+$", "") .. "\\" .. fileName
end

fogRuntime.readAllTextFile = function(path)
    local file = io.open(path, "rb")
    if not file then return nil end

    local text = file:read("*a")
    file:close()
    return text
end

fogRuntime.sanitizePathPart = function(value, fallback)
    local result = tostring(value or ""):gsub("[^%w_%-%.]", "_")
    if result == "" then return fallback or "unknown" end
    return result
end

fogRuntime.normalizeSlotName = function(value)
    local slotName = fogRuntime.sanitizePathPart(fogRuntime.coerceString(value), "")
    if slotName == ""
        or slotName == "global"
        or slotName == "Empty"
        or slotName == "None"
        or slotName == "Untitled"
        or slotName == "Invalid"
    then
        return nil
    end

    return slotName
end

fogRuntime.readReflectedField = function(source, fieldName)
    if source == nil then return nil end

    local ok, value = pcall(function()
        return source[fieldName]
    end)
    if ok and value ~= nil then
        return value
    end

    return nil
end

fogRuntime.ensureDirectory = function(path)
    if not path or path == "" then return false end
    if not os or not os.execute then return false end

    local safePath = tostring(path):gsub('"', "")
    local ok = pcall(function()
        os.execute('mkdir "' .. safePath .. '" >nul 2>nul')
    end)
    return ok
end

local function getScriptAssetRoot()
    if not debug or not debug.getinfo then return nil end

    local source = debug.getinfo(1, "S").source
    if not source or source:sub(1, 1) ~= "@" then return nil end

    local scriptPath = source:sub(2):gsub("\\", "/")
    local modRoot = scriptPath:match("^(.*)/Scripts/[^/]+$")
    if not modRoot then return nil end

    return normalizePath(modRoot .. "/Scripts")
end

local function getAssetPath(fileName)
    if isAbsolutePath(fileName) then return fileName end

    local scriptAssetRoot = getScriptAssetRoot()
    if not scriptAssetRoot then return fileName end

    return joinPath(scriptAssetRoot, fileName)
end

fogRuntime.getGameSavedRoot = function()
    local fogCfg = Config.FogOfWar or {}
    if fogCfg.RuntimeRoot and fogCfg.RuntimeRoot ~= "" then
        return normalizePath(fogCfg.RuntimeRoot)
    end

    if not os or not os.getenv then return nil end
    local ok, localAppData = pcall(os.getenv, "LOCALAPPDATA")
    if not ok or not localAppData or localAppData == "" then return nil end

    return joinPath(joinPath(localAppData, "Subnautica2"), "Saved")
end

fogRuntime.coerceString = function(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end

    local ok, text = pcall(function()
        if value.ToString then
            return value:ToString()
        end
        return nil
    end)
    if ok and text and text ~= "" then
        return text
    end

    local fallback = tostring(value)
    if fallback == "" then return nil end
    return fallback
end

fogRuntime.coerceBool = function(value)
    if value == nil then return false end
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end

    local text = fogRuntime.coerceString(value)
    if not text then return false end
    text = text:lower()
    return text == "true" or text == "1"
end

fogRuntime.coerceDateTimeScore = function(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end

    if type(value) == "table" then
        local ticks = value.Ticks or value.ticks or value.Value or value.value
        if type(ticks) == "number" then
            return ticks
        end
    end

    local ok, ticks = pcall(function()
        if value.GetTicks then
            return value:GetTicks()
        end
        return nil
    end)
    if ok and type(ticks) == "number" then
        return ticks
    end

    local text = fogRuntime.coerceString(value)
    if not text then return nil end

    local numeric = tonumber(text)
    if numeric then return numeric end

    local digits = text:match("(%d+)")
    if digits then
        return tonumber(digits)
    end

    return nil
end

fogRuntime.getCurrentLevelCandidates = function()
    local candidates = {}
    local seen = {}
    local world = UEHelpers.GetWorld()
    if not isValid(world) then return candidates end

    local function addCandidate(value)
        local text = fogRuntime.coerceString(value)
        if not text or text == "" then return end
        if seen[text] then return end
        seen[text] = true
        candidates[#candidates + 1] = text
    end

    local okName, worldName = pcall(function()
        return world:GetName()
    end)
    if okName and worldName then
        addCandidate(worldName)
        if not tostring(worldName):find("/", 1, true) then
            addCandidate("/Game/Maps/Main/" .. tostring(worldName))
        end
    end

    local persistentLevel = world.PersistentLevel
    if isValid(persistentLevel) then
        local okOuter, outer = pcall(function()
            return persistentLevel:GetOuter()
        end)
        if okOuter and isValid(outer) then
            local okOuterName, outerName = pcall(function()
                return outer:GetName()
            end)
            if okOuterName and outerName then
                addCandidate(outerName)
                if not tostring(outerName):find("/", 1, true) then
                    addCandidate("/Game/Maps/Main/" .. tostring(outerName))
                end
            end
        end
    end

    return candidates
end

fogRuntime.findSaveGameSubsystem = function()
    local subsystem = FindFirstOf("UWESaveGameSubsystem")
    if subsystem and subsystem:IsValid() then
        return subsystem
    end
    return CreateInvalidObject()
end

fogRuntime.resolveSlotFromActiveSave = function()
    local subsystem = fogRuntime.findSaveGameSubsystem()
    if not subsystem:IsValid() then return nil end

    local saveContext = fogRuntime.readReflectedField(subsystem, "SaveContext")
    if not saveContext then
        if not fogRuntime.saveContextWarningLogged then
            fogRuntime.saveContextWarningLogged = true
            log("Save slot detection: UWESaveGameSubsystem.SaveContext is not readable yet", "Verbose")
        end
        return nil
    end

    local activeSave = fogRuntime.readReflectedField(saveContext, "ActiveSave")
    if isValid(activeSave) then
        local okSlot, slotText = pcall(function()
            return activeSave:GetSlotName()
        end)
        local slotName = okSlot and fogRuntime.normalizeSlotName(slotText) or nil
        if slotName then
            if fogRuntime.lastActiveSaveSlotLogged ~= slotName then
                fogRuntime.lastActiveSaveSlotLogged = slotName
                log("Resolved active save slot from UWESaveGameSubsystem.SaveContext: " .. slotName)
            end
            return slotName
        end

        local metaData = fogRuntime.readReflectedField(activeSave, "MetaData")
        slotName = metaData and fogRuntime.normalizeSlotName(fogRuntime.readReflectedField(metaData, "SlotName")) or nil
        if slotName then
            if fogRuntime.lastActiveSaveSlotLogged ~= slotName then
                fogRuntime.lastActiveSaveSlotLogged = slotName
                log("Resolved active save slot from active save metadata: " .. slotName)
            end
            return slotName
        end
    end

    local collection = fogRuntime.readReflectedField(saveContext, "SaveGameCollection")
    if isValid(collection) then
        local containerInfo = fogRuntime.readReflectedField(collection, "ContainerInfo")
        local slotName = containerInfo and fogRuntime.normalizeSlotName(fogRuntime.readReflectedField(containerInfo, "SlotName")) or nil
        if slotName then
            if fogRuntime.lastActiveSaveSlotLogged ~= slotName then
                fogRuntime.lastActiveSaveSlotLogged = slotName
                log("Resolved active save slot from save collection: " .. slotName)
            end
            return slotName
        end
    end

    return nil
end

fogRuntime.resolveSlotFromSaveMetadata = function()
    local subsystem = fogRuntime.findSaveGameSubsystem()
    if not subsystem:IsValid() then return nil end

    local levelCandidates = fogRuntime.getCurrentLevelCandidates()
    if #levelCandidates == 0 then return nil end

    local wantMultiplayer = isMultiplayerWorld(UEHelpers.GetWorld())
    local existingSlot = fogRuntime.slotName
    local latestSlotByLevel = nil
    local bestSlot = nil
    local bestPriority = nil
    local bestLoadedScore = nil
    local bestModifiedScore = nil
    local slotDetails = {}

    local function considerInfo(info)
        if not info then return end

        local slotName = fogRuntime.normalizeSlotName(info.SlotName)
        if not slotName then return end

        local isMultiplayer = fogRuntime.coerceBool(info.bIsMultiplayerSave) or fogRuntime.coerceBool(info.bWasMultiplayerSave)
        if isMultiplayer ~= wantMultiplayer then
            return
        end

        local loadedScore = fogRuntime.coerceDateTimeScore(info.LastLoaded)
        local modifiedScore = fogRuntime.coerceDateTimeScore(info.LastModified)
        local priority = 1
        if existingSlot and existingSlot == slotName then
            priority = 3
        elseif latestSlotByLevel and latestSlotByLevel == slotName then
            priority = 2
        end

        slotDetails[#slotDetails + 1] = string.format(
            "%s(priority=%d,lastLoaded=%s,lastModified=%s)",
            slotName,
            priority,
            tostring(loadedScore),
            tostring(modifiedScore)
        )

        if not bestSlot
            or priority > bestPriority
            or (priority == bestPriority and (loadedScore or -1) > (bestLoadedScore or -1))
            or (priority == bestPriority and (loadedScore or -1) == (bestLoadedScore or -1) and (modifiedScore or -1) > (bestModifiedScore or -1))
        then
            bestSlot = slotName
            bestPriority = priority
            bestLoadedScore = loadedScore
            bestModifiedScore = modifiedScore
        end
    end

    for _, levelCandidate in ipairs(levelCandidates) do
        local okLatest, latestSlot = pcall(function()
            return subsystem:GetLastModifiedSaveForLevel(levelCandidate)
        end)
        latestSlotByLevel = okLatest and fogRuntime.normalizeSlotName(latestSlot) or nil

        local okInfos, infos = pcall(function()
            return subsystem:GetAllSaveInfoForLevel(levelCandidate)
        end)
        if okInfos and infos then
            for i = 1, #infos do
                considerInfo(infos[i])
            end
        end

        if bestSlot then
            log(
                "Resolved save slot from metadata for level '" .. tostring(levelCandidate) .. "' (multiplayer=" .. tostring(wantMultiplayer) .. "): "
                    .. bestSlot .. " via [" .. table.concat(slotDetails, ", ") .. "]",
                "Verbose"
            )
            return bestSlot
        end
    end

    return nil
end

fogRuntime.readLatestLoggedSlotName = function()
    local savedRoot = fogRuntime.getGameSavedRoot()
    if not savedRoot then return nil end

    local logPath = joinPath(joinPath(savedRoot, "Logs"), "Subnautica2.log")
    local logText = fogRuntime.readAllTextFile(logPath)
    if not logText then return nil end

    local slotName = nil
    for match in logText:gmatch("Init save system with slotname:%s*([%w_%-%.]+)") do
        slotName = match
    end
    if not slotName then
        for match in logText:gmatch("SaveSlotName=([%w_%-%.]+)") do
            slotName = match
        end
    end

    return fogRuntime.normalizeSlotName(slotName)
end

fogRuntime.detectSaveSlotName = function()
    local fogCfg = Config.FogOfWar or {}
    local fallbackBase = fogRuntime.sanitizePathPart(fogCfg.FallbackSaveSlotName or "unsaved", "unsaved")
    if not fogRuntime.sessionFallbackSlotName then
        local suffix = "session"
        if os and os.time then
            suffix = tostring(os.time())
        end
        fogRuntime.sessionFallbackSlotName = fallbackBase .. "_" .. suffix
    end

    local slotName = fogRuntime.resolveSlotFromActiveSave()
    if not slotName or slotName == "" then
        slotName = fogRuntime.resolveSlotFromSaveMetadata()
    end
    if not slotName or slotName == "" then
        slotName = fogRuntime.readLatestLoggedSlotName()
    end
    if (not slotName or slotName == "") and fogRuntime.slotName and not fogRuntime.isTransientSlotName(fogRuntime.slotName) then
        slotName = fogRuntime.slotName
    end
    if not slotName or slotName == "" then
        slotName = fogRuntime.slotName or fogRuntime.sessionFallbackSlotName
        if slotName == fogRuntime.sessionFallbackSlotName and not fogRuntime.fallbackSlotWarningLogged then
            fogRuntime.fallbackSlotWarningLogged = true
            log("Save slot detection fell back to transient slot '" .. tostring(slotName) .. "'. Fog will not persist per save until the active save slot is readable.", "Warning")
        end
    end

    fogRuntime.slotName = slotName
    return fogRuntime.slotName
end

fogRuntime.resetPaths = function()
    fogRuntime.slotName = nil
    fogRuntime.directory = nil
    fogRuntime.pathLogged = false
    fogRuntime.nextAutoSaveAt = nil
end

fogRuntime.isTransientSlotName = function(slotName)
    local fallbackBase = fogRuntime.sanitizePathPart((Config.FogOfWar or {}).FallbackSaveSlotName or "unsaved", "unsaved")
    return type(slotName) == "string" and slotName:sub(1, #fallbackBase + 1) == (fallbackBase .. "_")
end

fogRuntime.getDirectory = function()
    if fogRuntime.directory then return fogRuntime.directory end

    local savedRoot = fogRuntime.getGameSavedRoot()
    local slotName = fogRuntime.detectSaveSlotName()
    if savedRoot then
        local rootName = fogRuntime.sanitizePathPart((Config.FogOfWar or {}).RuntimeFolderName or MOD_NAME, MOD_NAME)
        fogRuntime.directory = joinPath(joinPath(savedRoot, rootName), slotName)
        fogRuntime.ensureDirectory(fogRuntime.directory)
    else
        fogRuntime.directory = getScriptAssetRoot() or "."
    end

    if not fogRuntime.pathLogged then
        fogRuntime.pathLogged = true
        log("Fog of war runtime slot '" .. slotName .. "': " .. fogRuntime.directory)
    end

    return fogRuntime.directory
end

fogRuntime.copyFileContents = function(sourcePath, destinationPath)
    if not sourcePath or not destinationPath then return false end

    local source = io.open(sourcePath, "rb")
    if not source then return false end

    local data = source:read("*a")
    source:close()

    local destination = io.open(destinationPath, "wb")
    if not destination then return false end

    destination:write(data or "")
    destination:close()
    return true
end

fogRuntime.fileExistsIo = function(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

fogRuntime.promoteTransientSlotIfReady = function()
    local currentSlot = fogRuntime.slotName
    local resolvedSlot = fogRuntime.detectSaveSlotName()
    if not resolvedSlot or resolvedSlot == "" then
        return false
    end
    if resolvedSlot == currentSlot and currentSlot ~= nil then
        return false
    end

    local oldSlot = currentSlot
    local oldDir = nil
    if oldSlot and oldSlot ~= "" then
        local shouldSaveOldState = oldSlot == resolvedSlot or fogRuntime.isTransientSlotName(oldSlot)
        if fogSaveDirty and shouldSaveOldState then
            safeCall("Fog save before slot promotion", saveFogState)
            fogSaveDirty = false
        elseif fogSaveDirty and not shouldSaveOldState then
            log("Discarding dirty fog state during save slot switch '" .. tostring(oldSlot) .. "' -> '" .. tostring(resolvedSlot) .. "'")
            fogSaveDirty = false
        end
        local savedRoot = fogRuntime.getGameSavedRoot()
        if savedRoot then
            local rootName = fogRuntime.sanitizePathPart((Config.FogOfWar or {}).RuntimeFolderName or MOD_NAME, MOD_NAME)
            oldDir = joinPath(joinPath(savedRoot, rootName), oldSlot)
        end
    end

    fogRuntime.directory = nil
    fogRuntime.pathLogged = false

    local newDir = fogRuntime.getDirectory()
    local fogCfg = Config.FogOfWar or {}
    local newFogPath = joinPath(newDir, fogCfg.SaveFile or "fog_state.dat")
    local newPoiPath = joinPath(newDir, poiRuntime.stateFileName)

    if oldDir and fogRuntime.isTransientSlotName(oldSlot) then
        local oldFogPath = joinPath(oldDir, fogCfg.SaveFile or "fog_state.dat")
        local oldPoiPath = joinPath(oldDir, poiRuntime.stateFileName)

        if fogRuntime.fileExistsIo(oldFogPath) and not fogRuntime.fileExistsIo(newFogPath) and fogRuntime.copyFileContents(oldFogPath, newFogPath) then
            log("Fog of war migrated transient slot '" .. oldSlot .. "' into save slot '" .. resolvedSlot .. "'")
        end
        if fogRuntime.fileExistsIo(oldPoiPath) and not fogRuntime.fileExistsIo(newPoiPath) and fogRuntime.copyFileContents(oldPoiPath, newPoiPath) then
            log("POI category state migrated transient slot '" .. oldSlot .. "' into save slot '" .. resolvedSlot .. "'")
        end
    end

    fogRuntime.reloadForCurrentSave()
    poiRuntime.reloadCategoryStateForCurrentSave()
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
    return true
end

fogRuntime.scheduleSaveStateFlush = function(reason)
    if fogRuntime.saveStateFlushPending then return end
    fogRuntime.saveStateFlushPending = true
    ExecuteWithDelay(0, function()
        ExecuteInGameThread(function()
            fogRuntime.saveStateFlushPending = false
            safeCall("Sync save slot before state flush", function()
                fogRuntime.promoteTransientSlotIfReady()
            end)
            if isFogEnabled() and fogSaveDirty then
                safeCall("Fog state save (" .. tostring(reason or "manual") .. ")", saveFogState)
                fogSaveDirty = false
            elseif isFogEnabled() then
                safeCall("Fog state save (" .. tostring(reason or "manual") .. ")", saveFogState)
            end
            safeCall("POI category save (" .. tostring(reason or "manual") .. ")", function()
                poiRuntime.saveCategoryState()
            end)
            local intervalMs = ((Config.FogOfWar or {}).AutoSaveIntervalMs) or 300000
            if os and os.time and intervalMs > 0 then
                local intervalSeconds = math.max(60, math.floor((intervalMs / 1000) + 0.5))
                fogRuntime.nextAutoSaveAt = os.time() + intervalSeconds
            end
        end)
    end)
end

poiRuntime.resetCategoryStateToDefaults = function()
    poiAllVisible = true
    for _, category in ipairs(poiCategories or {}) do
        category.visible = category.defaultEnabled == true
        category.rowVisibleState = nil
        category.markerVisibleState = nil
        category.markerLayoutKey = nil
        if not category.visible then
            poiAllVisible = false
        end

        for _, point in ipairs(category.points or {}) do
            point.markerVisibleState = nil
        end
    end

    poiAllRowVisibleState = nil
end

poiRuntime.refreshAllVisible = function()
    poiAllVisible = true
    for _, category in ipairs(poiCategories or {}) do
        if not category.visible then
            poiAllVisible = false
            return false
        end
    end

    return true
end

poiRuntime.getCategoryStatePath = function()
    return joinPath(fogRuntime.getDirectory(), poiRuntime.stateFileName)
end

poiRuntime.saveCategoryState = function()
    local path = poiRuntime.getCategoryStatePath()
    local file = io.open(path, "w")
    if not file then
        log("Failed to save POI category state: " .. tostring(path))
        return false
    end

    for _, category in ipairs(poiCategories or {}) do
        file:write(tostring(category.id) .. "=" .. (category.visible and "1" or "0") .. "\n")
    end

    file:close()
    return true
end

poiRuntime.loadCategoryState = function()
    poiRuntime.resetCategoryStateToDefaults()

    local path = poiRuntime.getCategoryStatePath()
    local file = io.open(path, "r")
    if not file then
        log("POI category state: no save found for slot '" .. fogRuntime.detectSaveSlotName() .. "', using defaults")
        return false
    end

    for line in file:lines() do
        local categoryIdText, visibleText = line:match("^%s*(%d+)%s*=%s*([01])%s*$")
        local category = categoryIdText and poiCategoriesById[tonumber(categoryIdText)] or nil
        if category then
            category.visible = visibleText == "1"
            category.rowVisibleState = nil
            category.markerVisibleState = nil
            category.markerLayoutKey = nil
            for _, point in ipairs(category.points or {}) do
                point.markerVisibleState = nil
            end
        end
    end

    file:close()
    poiRuntime.refreshAllVisible()
    poiAllRowVisibleState = nil
    log("POI category state loaded for slot '" .. fogRuntime.detectSaveSlotName() .. "'")
    return true
end

poiRuntime.reloadCategoryStateForCurrentSave = function()
    fogRuntime.resetPaths()
    if poiCategories then
        poiRuntime.loadCategoryState()
    end
end

local function findDefaultObject(path)
    local object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    return CreateInvalidObject()
end

local function getRenderingLibrary()
    if renderingLibrary:IsValid() then return renderingLibrary end
    renderingLibrary = findDefaultObject("/Script/Engine.Default__KismetRenderingLibrary")
    return renderingLibrary
end

local function getWidgetLayoutLibrary()
    if widgetLayoutLibrary:IsValid() then return widgetLayoutLibrary end
    widgetLayoutLibrary = findDefaultObject("/Script/UMG.Default__WidgetLayoutLibrary")
    return widgetLayoutLibrary
end

local function loadTexture(fileName, attemptedFlagName)
    local target = arrowTexture
    if attemptedFlagName == "map" then
        target = mapTexture
    elseif attemptedFlagName == "pixel" then
        target = pixelTexture
    end
    if target:IsValid() then return target end

    if attemptedFlagName == "map" and textureLoadAttempted then return target end
    if attemptedFlagName == "pixel" and pixelLoadAttempted then return target end
    if attemptedFlagName == "arrow" and arrowLoadAttempted then return target end

    local world = UEHelpers.GetWorld()
    local renderer = getRenderingLibrary()
    if not world:IsValid() or not renderer:IsValid() then return target end

    local path = getAssetPath(fileName)
    if not fileExists(path) then
        log("Texture not found: " .. path)
        if attemptedFlagName == "map" then
            textureLoadAttempted = true
        elseif attemptedFlagName == "pixel" then
            pixelLoadAttempted = true
        else
            arrowLoadAttempted = true
        end
        return target
    end

    if attemptedFlagName == "map" then
        textureLoadAttempted = true
    elseif attemptedFlagName == "pixel" then
        pixelLoadAttempted = true
    else
        arrowLoadAttempted = true
    end

    local texture = safeCall("ImportFileAsTexture2D(" .. fileName .. ")", function()
        return renderer:ImportFileAsTexture2D(world, path)
    end)

    if texture and texture:IsValid() then
        if attemptedFlagName == "map" then
            mapTexture = texture
        elseif attemptedFlagName == "pixel" then
            pixelTexture = texture
        else
            arrowTexture = texture
        end
        log("Texture loaded: " .. path)
        return texture
    end

    return target
end

local function loadMapTexture()
    return loadTexture(Config.Map.ImageFile or "subnautica2_world_base.jpg", "map")
end

local function loadPixelTexture()
    return loadTexture("pixel.png", "pixel")
end

local function loadArrowTexture()
    return loadTexture((Config.Marker or {}).ImageFile or "MapArrowRight.png", "arrow")
end

local function readTextAsset(fileName, label)
    local path = getAssetPath(fileName)
    local file = io.open(path, "rb")
    if not file then
        log(label .. " file not found: " .. path)
        return nil
    end

    local text = file:read("*a")
    file:close()
    return text, path
end

local function loadJsonAsset(fileName, label)
    local text, path = readTextAsset(fileName, label)
    if not text then return nil end

    local ok, data = pcall(Json.decode, text)
    if not ok then
        log(label .. " JSON parse failed: " .. tostring(data))
        return nil
    end

    log(label .. " JSON loaded: " .. path)
    return data
end

local function normalizeAssetFileName(fileName)
    if not fileName or fileName == "" then return nil end
    return (tostring(fileName):gsub("%.(png|jpg|json)%.lua$", ".%1"))
end

local function findClass(shortName)
    if widgetClasses[shortName] and widgetClasses[shortName]:IsValid() then
        return widgetClasses[shortName]
    end

    local candidates = {
        "Class /Script/UMG." .. shortName,
        "/Script/UMG." .. shortName,
    }

    for _, candidate in ipairs(candidates) do
        local class = StaticFindObject(candidate)
        if class and class:IsValid() then
            widgetClasses[shortName] = class
            return class
        end
    end

    log("UMG class not found: " .. shortName)
    return CreateInvalidObject()
end

local function constructWidget(shortName, outer)
    local class = findClass(shortName)
    if not class:IsValid() or not outer or not outer:IsValid() then return CreateInvalidObject() end

    local widget = safeCall("StaticConstructObject(" .. shortName .. ")", function()
        return StaticConstructObject(class, outer)
    end)

    if widget and widget:IsValid() then return widget end
    return CreateInvalidObject()
end

function poiFindFirstObjectOfClass(className)
    local ok, object = pcall(function()
        return FindFirstOf(className)
    end)
    if ok and isValid(object) then return object end
    return CreateInvalidObject()
end

function poiFindAllObjectsOfClassQuiet(className)
    local ok, objects = pcall(function()
        return FindAllOf(className)
    end)
    if ok and type(objects) == "table" then return objects end
    return {}
end

function poiWidgetHasRootWidget(widget)
    return isValid(widget)
        and isValid(widget.WidgetTree)
        and isValid(widget.WidgetTree.RootWidget)
end

function poiFindWidgetByClassNames(classNames, accepts)
    for _, className in ipairs(classNames) do
        local first = poiFindFirstObjectOfClass(className)
        if isValid(first) and (not accepts or accepts(first)) then return first end

        for _, candidate in ipairs(poiFindAllObjectsOfClassQuiet(className)) do
            if isValid(candidate) and (not accepts or accepts(candidate)) then
                return candidate
            end
        end
    end

    return CreateInvalidObject()
end

local function findHudScreen()
    local controller = UEHelpers.GetPlayerController()
    if controller:IsValid() and controller.MyHUD and controller.MyHUD:IsValid() then
        local hud = controller.MyHUD
        if hud.HUDScreen and hud.HUDScreen:IsValid() then return hud.HUDScreen end
    end

    return poiFindWidgetByClassNames({ "WBP_HUDScreen_C", "WBP_HUDScreen" }, poiWidgetHasRootWidget)
end

local function getRootWidget(hudScreen)
    if not hudScreen or not hudScreen:IsValid() then return CreateInvalidObject() end
    if hudScreen.WidgetTree and hudScreen.WidgetTree:IsValid() and hudScreen.WidgetTree.RootWidget and hudScreen.WidgetTree.RootWidget:IsValid() then
        return hudScreen.WidgetTree.RootWidget
    end
    return CreateInvalidObject()
end

local function findMainScreen()
    return poiFindWidgetByClassNames({ "WBP_MainScreen_C", "WBP_MainScreen" }, function(screen)
        return isValid(screen.Layers) or poiWidgetHasRootWidget(screen)
    end)
end

local function getOverlayRootAndOuter(hudScreen)
    local mainScreen = findMainScreen()
    if mainScreen:IsValid() then
        local outer = mainScreen.WidgetTree and mainScreen.WidgetTree:IsValid() and mainScreen.WidgetTree or mainScreen
        if mainScreen.Layers and mainScreen.Layers:IsValid() then
            return mainScreen.Layers, outer
        end

        local mainRoot = getRootWidget(mainScreen)
        if mainRoot:IsValid() then return mainRoot, outer end
    end

    local hudRoot = getRootWidget(hudScreen)
    if not hudRoot:IsValid() then return CreateInvalidObject(), CreateInvalidObject() end

    local hudOuter = hudScreen.WidgetTree and hudScreen.WidgetTree:IsValid() and hudScreen.WidgetTree or hudScreen
    return hudRoot, hudOuter
end

function poiIsGameplayWorld()
    local world = UEHelpers.GetWorld()
    if not isValid(world) then return false end

    local ok, name = pcall(function()
        return world:GetFullName()
    end)
    if ok and tostring(name):find("L_Main", 1, true) then return true end

    ok, name = pcall(function()
        return world:GetName()
    end)
    return ok and tostring(name):find("L_Main", 1, true) ~= nil
end

function poiCanUseMapOverlay()
    return poiIsGameplayWorld() and isValid(findHudScreen())
end

local function addToCanvas(parent, child)
    if not parent or not parent:IsValid() or not child or not child:IsValid() then return nil end

    local slot = safeCall("AddChildToCanvas", function()
        return parent:AddChildToCanvas(child)
    end)
    if slot and slot:IsValid() then return slot end

    slot = safeCall("AddChild", function()
        return parent:AddChild(child)
    end)
    if slot and slot:IsValid() then return slot end

    return nil
end

local function setWidgetVisibility(widget, visible)
    if widget and widget:IsValid() then
        widget:SetVisibility(visible and VISIBLE or HIDDEN)
    end
end

local function setCachedWidgetVisibility(cacheField, widget, visible)
    if overlay[cacheField] == visible then return end
    setWidgetVisibility(widget, visible)
    overlay[cacheField] = visible
end

local function setMarkerVisibility(visible)
    if overlay.lastMarkerVisible == visible then return end
    setWidgetVisibility(overlay.marker, visible)
    overlay.lastMarkerVisible = visible
end

local function setImageTexture(image, texture, tint)
    if not image or not image:IsValid() or not texture or not texture:IsValid() then return end
    safeCall("SetBrushFromTexture", function() image:SetBrushFromTexture(texture, false) end)
    safeCall("SetColorAndOpacity", function() image:SetColorAndOpacity(tint or { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }) end)
end

local function createImage(parent, outer, zOrder, texture, tint)
    local image = constructWidget("Image", outer or parent)
    if not image:IsValid() then return CreateInvalidObject(), nil end

    local slot = addToCanvas(parent, image)
    if slot and slot:IsValid() then slot:SetZOrder(zOrder or 0) end
    setImageTexture(image, texture, tint)
    image:SetVisibility(VISIBLE)
    return image, slot
end

local function setSlotAnchors(slot, minX, minY, maxX, maxY, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetMinimum(vec2(minX, minY))
    slot:SetMaximum(vec2(maxX, maxY))
    slot:SetAlignment(vec2(0.0, 0.0))
    slot:SetAutoSize(false)
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setSlotFill(slot, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetMinimum(vec2(0.0, 0.0))
    slot:SetMaximum(vec2(1.0, 1.0))
    slot:SetPosition(vec2(0.0, 0.0))
    slot:SetSize(vec2(0.0, 0.0))
    slot:SetAlignment(vec2(0.0, 0.0))
    slot:SetAutoSize(false)
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setSlotTopLeft(slot, zOrder)
    setSlotAnchors(slot, 0.0, 0.0, 0.0, 0.0, zOrder)
end

local setSlotRect
local setWidgetRenderTranslation

local function loadPoiIconManifest()
    if next(poiIconManifestById) then return poiIconManifestById end

    local manifest = loadJsonAsset("icons\\icon_manifest.json", "POI icon manifest")
    local icons = manifest and manifest.icons or {}
    for _, icon in ipairs(icons) do
        local categoryId = tonumber(icon.category_id)
        if categoryId then
            poiIconManifestById[categoryId] = icon
        end
    end

    log("POI icon manifest entries indexed: " .. tostring(#icons))
    return poiIconManifestById
end

local function loadPoiLabelManifest()
    if next(poiLabelManifestById) then return poiLabelManifestById end

    local manifest = loadJsonAsset("labels\\label_manifest.json", "POI label manifest")
    poiLabelColumnInfo = manifest and manifest.column or nil
    local labels = manifest and manifest.labels or {}
    for _, label in ipairs(labels) do
        local categoryId = tonumber(label.category_id)
        if categoryId then
            poiLabelManifestById[categoryId] = label
        end
    end

    log("POI label manifest entries indexed: " .. tostring(#labels))
    return poiLabelManifestById
end

local function normalizePoiCategory(rawCategory, iconById, labelById)
    local categoryId = tonumber(rawCategory.category_id)
    if not categoryId then return nil end

    local iconInfo = iconById[categoryId] or {}
    local iconFile = normalizeAssetFileName(iconInfo.file or rawCategory.file)
    local iconPath = iconFile and joinPath("icons", iconFile) or nil
    local labelInfo = labelById[categoryId] or {}
    local defaultEnabled = rawCategory.default_enabled
    if defaultEnabled == nil then
        defaultEnabled = categoryId == 15598 or rawCategory.title == "Lifepod"
    else
        defaultEnabled = defaultEnabled == true
    end

    return {
        id = categoryId,
        categoryId = categoryId,
        key = tostring(categoryId),
        title = rawCategory.title or iconInfo.title or tostring(categoryId),
        icon = rawCategory.icon or iconInfo.icon or "",
        groupId = tonumber(rawCategory.group_id),
        expectedCount = tonumber(rawCategory.count),
        iconPath = iconPath,
        iconWidth = tonumber(iconInfo.width),
        iconHeight = tonumber(iconInfo.height),
        labelWidth = tonumber(labelInfo.width),
        labelHeight = tonumber(labelInfo.height),
        defaultEnabled = defaultEnabled,
        visible = defaultEnabled,
        texture = CreateInvalidObject(),
        textureAttempted = false,
        textureApplied = false,
        markerVisibleState = nil,
        markerLayoutKey = nil,
        rowVisibleState = nil,
        points = {},
    }
end

local function loadPoiData()
    if poiCategories then return poiCategories end
    if poiDataLoadAttempted then return {} end
    poiDataLoadAttempted = true

    poiCategories = {}
    poiCategoriesById = {}
    poiPointsByCategoryId = {}

    local config = loadJsonAsset("poi_toggle_config.json", "POI toggle config")
    local pointList = loadJsonAsset("poi_points.json", "POI points")
    if not config or not config.categories or not pointList then
        log("POI data unavailable; no category markers will be created")
        return poiCategories
    end

    local iconById = loadPoiIconManifest()
    local labelById = loadPoiLabelManifest()
    for _, rawCategory in ipairs(config.categories) do
        local category = normalizePoiCategory(rawCategory, iconById, labelById)
        if category then
            poiCategories[#poiCategories + 1] = category
            poiCategoriesById[category.id] = category
            poiPointsByCategoryId[category.id] = category.points
        end
    end

    local skipped = 0
    for _, rawPoint in ipairs(pointList) do
        local categoryId = tonumber(rawPoint.category_id)
        local category = categoryId and poiCategoriesById[categoryId] or nil
        local x = tonumber(rawPoint.crop_x)
        local y = tonumber(rawPoint.crop_y)
        if category and x and y then
            category.points[#category.points + 1] = {
                id = tonumber(rawPoint.id) or 0,
                title = rawPoint.title or "",
                categoryId = categoryId,
                x = x,
                y = y,
                lat = tonumber(rawPoint.lat),
                lon = tonumber(rawPoint.lon),
                raw = rawPoint,
            }
        else
            skipped = skipped + 1
        end
    end

    log("POI categories loaded: " .. tostring(#poiCategories))
    log("POI points loaded: " .. tostring(#pointList) .. " (skipped=" .. tostring(skipped) .. ")")
    for _, category in ipairs(poiCategories) do
        log(string.format(
            "POI category %d '%s': points=%d default=%s icon=%s",
            category.id,
            category.title,
            #category.points,
            category.defaultEnabled and "on" or "off",
            category.iconPath or "(missing)"
        ))
    end

    poiRuntime.loadCategoryState()

    return poiCategories
end

local function loadPoiCategoryTexture(category)
    if category.texture and category.texture:IsValid() then return category.texture end
    if category.textureAttempted then return category.texture end

    if not category.iconPath then
        category.textureAttempted = true
        log("POI category has no icon file: " .. category.title)
        return category.texture
    end

    local world = UEHelpers.GetWorld()
    local renderer = getRenderingLibrary()
    if not world:IsValid() or not renderer:IsValid() then return category.texture end

    local path = getAssetPath(category.iconPath)
    if not fileExists(path) then
        category.textureAttempted = true
        log("POI icon texture not found for " .. category.title .. ": " .. path)
        return category.texture
    end

    category.textureAttempted = true
    local texture = safeCall("ImportPOIMarkerTexture(" .. category.title .. ")", function()
        return renderer:ImportFileAsTexture2D(world, path)
    end)

    if texture and texture:IsValid() then
        category.texture = texture
        log("POI icon texture loaded for " .. category.title .. ": " .. path)
    else
        category.texture = CreateInvalidObject()
        log("WARNING: POI icon texture invalid for " .. category.title .. ": " .. path)
    end

    return category.texture
end

local function applyPoiCategoryTexture(category)
    if category.textureApplied then return end

    local texture = loadPoiCategoryTexture(category)
    if not texture or not texture:IsValid() then return end

    local markers = overlay.poiMarkersByCategoryId and overlay.poiMarkersByCategoryId[category.id] or nil
    if not markers then return end

    for _, marker in ipairs(markers) do
        setImageTexture(marker, texture, COLOR_WHITE)
    end

    category.textureApplied = true
end

local function loadPoiLabelColumnTexture()
    if poiLabelColumnTexture and poiLabelColumnTexture:IsValid() then return poiLabelColumnTexture end
    if poiLabelColumnTextureAttempted then return poiLabelColumnTexture end

    local columnInfo = poiLabelColumnInfo
    local fileName = columnInfo and normalizeAssetFileName(columnInfo.file) or nil
    if not fileName then
        poiLabelColumnTextureAttempted = true
        log("POI label column file missing from manifest")
        return poiLabelColumnTexture
    end

    local world = UEHelpers.GetWorld()
    local renderer = getRenderingLibrary()
    if not world:IsValid() or not renderer:IsValid() then return poiLabelColumnTexture end

    local labelPath = joinPath("labels", fileName)
    local path = getAssetPath(labelPath)
    if not fileExists(path) then
        poiLabelColumnTextureAttempted = true
        log("POI label column texture not found: " .. path)
        return poiLabelColumnTexture
    end

    poiLabelColumnTextureAttempted = true
    local texture = safeCall("ImportPOILabelColumnTexture", function()
        return renderer:ImportFileAsTexture2D(world, path)
    end)

    if texture and texture:IsValid() then
        poiLabelColumnTexture = texture
        log("POI label column texture loaded: " .. path)
    else
        poiLabelColumnTexture = CreateInvalidObject()
        log("WARNING: POI label column texture invalid: " .. path)
    end

    return poiLabelColumnTexture
end

local function createPoiCategoryMarkers(category, widgetOuter)
    local icon = loadPoiCategoryTexture(category)
    overlay.poiMarkersByCategoryId[category.id] = {}
    overlay.poiMarkerSlotsByCategoryId[category.id] = {}
    local markerParent = overlay.viewport:IsValid() and overlay.viewport or overlay.canvas

    for i, _ in ipairs(category.points) do
        local marker, slot = createImage(markerParent, widgetOuter, 2, icon, COLOR_WHITE)
        setSlotTopLeft(slot, 1000)
        if slot then slot:SetSize(vec2(POI_MARKER_SIZE, POI_MARKER_SIZE)) end
        setWidgetVisibility(marker, false)

        overlay.poiMarkersByCategoryId[category.id][i] = marker
        overlay.poiMarkerSlotsByCategoryId[category.id][i] = slot
    end

    category.textureApplied = icon and icon:IsValid()
    log(category.title .. " POI markers created: " .. tostring(#overlay.poiMarkersByCategoryId[category.id]))
end

function getMultiplayerConfig()
    return Config.Multiplayer or {}
end

function getRemotePlayerMarkerSize()
    return (getMultiplayerConfig().OtherPlayerMarkerSize or 9)
end

function getRemotePlayerMarkerLimit()
    return (getMultiplayerConfig().MaxPlayerMarkers or 7)
end

function isRemotePlayerMarkersEnabled()
    return getMultiplayerConfig().ShowOtherPlayers == true
end

function createRemotePlayerMarkers(widgetOuter)
    overlay.remotePlayerMarkers = {}
    overlay.remotePlayerMarkerSlots = {}
    overlay.remotePlayerMarkerVisibleStates = {}
    overlay.remotePlayerMarkerKeys = {}
    overlay.remotePlayerMarkerSize = nil

    local arrow = loadArrowTexture()
    local limit = getRemotePlayerMarkerLimit()
    for i = 1, limit do
        local marker, slot = createImage(overlay.canvas, widgetOuter, 1001, arrow, COLOR_REMOTE_PLAYER)
        setSlotTopLeft(slot, 1001)
        setWidgetVisibility(marker, false)
        if marker and marker:IsValid() then marker:SetRenderTransformPivot(vec2(0.5, 0.5)) end
        overlay.remotePlayerMarkers[i] = marker
        overlay.remotePlayerMarkerSlots[i] = slot
    end

    overlay.remotePlayerTextureApplied = arrow and arrow:IsValid()
end

local function getPoiMarkerRect(mapX, mapY)
    local width = POI_MARKER_SIZE
    local height = POI_MARKER_SIZE
    return mapX - (width * POI_MARKER_ANCHOR_X), mapY - (height * POI_MARKER_ANCHOR_Y), width, height
end

local function createAllPoiCategoryMarkers(widgetOuter)
    overlay.poiMarkersByCategoryId = {}
    overlay.poiMarkerSlotsByCategoryId = {}

    for _, category in ipairs(loadPoiData()) do
        createPoiCategoryMarkers(category, widgetOuter)
    end
end

fogRuntime.isPoiPointRevealed = function(point)
    if not isFogEnabled() then return true end
    if not point then return false end

    local u, v = poiPointToUV(point)
    if not u or not v then return false end

    local fogCfg = Config.FogOfWar or {}
    local fw = fogCfg.GridWidth or 57
    local fh = fogCfg.GridHeight or 24
    if fw <= 0 or fh <= 0 then return true end

    local cx = clamp(math.floor(u * fw) + 1, 1, fw)
    local cy = clamp(math.floor(v * fh) + 1, 1, fh)
    return fogGrid[cy] and fogGrid[cy][cx] == true
end

local function updatePoiCategoryMarkers(category, state, layoutChanged)
    local markers = overlay.poiMarkersByCategoryId and overlay.poiMarkersByCategoryId[category.id] or nil
    local slots = overlay.poiMarkerSlotsByCategoryId and overlay.poiMarkerSlotsByCategoryId[category.id] or nil
    if not markers or not slots then return end

    applyPoiCategoryTexture(category)
    local baseVisible = largeMapOpen and category.visible
    local layoutKey = tostring(state.layoutXKey) .. ":" .. tostring(state.layoutYKey) .. ":" .. tostring(state.layoutWidthKey) .. ":" .. tostring(state.layoutHeightKey)
        .. ":" .. tostring(state.mapLocalXKey) .. ":" .. tostring(state.mapLocalYKey) .. ":" .. tostring(state.mapWKey) .. ":" .. tostring(state.mapHKey)
    local markerLayoutChanged = category.markerLayoutKey ~= layoutKey

    for i, marker in ipairs(markers) do
        if marker and marker:IsValid() then
            local point = category.points[i]
            local u, v = poiPointToUV(point)
            local mapX = nil
            local mapY = nil
            if u and v and state.mapW and state.mapH then
                mapX = (u * state.mapW) + (state.mapLocalX or 0.0)
                mapY = (v * state.mapH) + (state.mapLocalY or 0.0)
            end
            local onScreen = mapX ~= nil and mapY ~= nil
                and mapX >= -POI_MARKER_SIZE and mapX <= (state.width + POI_MARKER_SIZE)
                and mapY >= -POI_MARKER_SIZE and mapY <= (state.height + POI_MARKER_SIZE)
            local visible = baseVisible and onScreen and fogRuntime.isPoiPointRevealed(point)
            local visibleChanged = point and point.markerVisibleState ~= visible
            if visibleChanged then
                setWidgetVisibility(marker, visible)
            end

            if visible and (layoutChanged or markerLayoutChanged or visibleChanged) then
                local slot = slots[i]
                if point and slot then
                    if layoutChanged then
                        setSlotRect(slot, 0.0, 0.0, POI_MARKER_SIZE, POI_MARKER_SIZE, 1000)
                    end

                    local x, y = getPoiMarkerRect(mapX, mapY)
                    setWidgetRenderTranslation(marker, x, y)
                end
            end

            if point then
                point.markerVisibleState = visible
            end
        end
    end

    category.markerVisibleState = baseVisible
    category.markerLayoutKey = baseVisible and layoutKey or nil
end

local function updateAllPoiCategoryMarkers(state, layoutChanged)
    for _, category in ipairs(loadPoiData()) do
        updatePoiCategoryMarkers(category, state, layoutChanged)
    end
end

local function setPoiRowColor(widget, visible, hovered)
    if not widget or not widget:IsValid() then return end

    if visible and hovered then
        widget:SetColorAndOpacity({ R = 0.18, G = 0.90, B = 0.28, A = 1.0 })
    elseif visible then
        widget:SetColorAndOpacity({ R = 0.05, G = 0.60, B = 0.10, A = 0.85 })
    elseif hovered then
        widget:SetColorAndOpacity({ R = 0.92, G = 0.22, B = 0.16, A = 1.0 })
    else
        widget:SetColorAndOpacity({ R = 0.60, G = 0.08, B = 0.05, A = 0.85 })
    end
end

local function getPoiPanelHoverTarget(panelVisible)
    if not panelVisible or not getMousePositionOnViewport or not getPoiPanelTargetAtScreenPosition then
        return nil, nil
    end

    local x, y, alternateX, alternateY = getMousePositionOnViewport(true)
    local target, category = getPoiPanelTargetAtScreenPosition(x, y)
    if not target and alternateX and alternateY then
        target, category = getPoiPanelTargetAtScreenPosition(alternateX, alternateY)
    end

    return target, category
end

local function createPoiCategoryRows(widgetOuter, pixel)
    overlay.poiRowsByCategoryId = {}
    overlay.poiRowSlotsByCategoryId = {}
    overlay.poiAllRow = CreateInvalidObject()
    overlay.poiAllRowSlot = nil
    overlay.poiLabelColumn = CreateInvalidObject()
    overlay.poiLabelColumnSlot = nil

    overlay.poiAllRow, overlay.poiAllRowSlot = createImage(
        overlay.canvas,
        widgetOuter,
        1002,
        pixel,
        poiAllVisible and { R = 0.05, G = 0.60, B = 0.10, A = 0.85 } or { R = 0.60, G = 0.08, B = 0.05, A = 0.85 }
    )
    setSlotTopLeft(overlay.poiAllRowSlot, 1002)
    setWidgetVisibility(overlay.poiAllRow, false)

    for _, category in ipairs(loadPoiData()) do
        local row, slot = createImage(
            overlay.canvas,
            widgetOuter,
            1002,
            pixel,
            category.visible and { R = 0.05, G = 0.60, B = 0.10, A = 0.85 } or { R = 0.60, G = 0.08, B = 0.05, A = 0.85 }
        )
        setSlotTopLeft(slot, 1002)
        setWidgetVisibility(row, false)
        overlay.poiRowsByCategoryId[category.id] = row
        overlay.poiRowSlotsByCategoryId[category.id] = slot
        category.rowVisibleState = nil
    end

    local labelTexture = loadPoiLabelColumnTexture()
    if labelTexture and labelTexture:IsValid() then
        overlay.poiLabelColumn, overlay.poiLabelColumnSlot = createImage(overlay.canvas, widgetOuter, 1002, labelTexture, COLOR_WHITE)
        setSlotTopLeft(overlay.poiLabelColumnSlot, 1002)
        setWidgetVisibility(overlay.poiLabelColumn, false)
    end
end

local function updatePoiPanelRows(layoutChanged)
    local categories = loadPoiData()
    local panelVisible = largeMapOpen and #categories > 0
    setCachedWidgetVisibility("lastPoiPanelVisible", overlay.poiPanel, panelVisible)

    if overlay.lastPoiPanelRowsVisible ~= panelVisible then
        setWidgetVisibility(overlay.poiAllRow, panelVisible)
        for _, category in ipairs(categories) do
            setWidgetVisibility(overlay.poiRowsByCategoryId[category.id], panelVisible)
        end
        overlay.lastPoiPanelRowsVisible = panelVisible
    end
    setCachedWidgetVisibility("lastPoiLabelColumnVisible", overlay.poiLabelColumn, panelVisible)

    if not panelVisible then
        poiAllRowHitRect = nil
        for _, category in ipairs(categories) do
            category.rowHitRect = nil
            category.rowVisibleState = nil
        end
        return
    end

    if layoutChanged then
        local panelX = 24
        local panelY = 70
        local rowH = 28
        local rowGap = 8
        local chipSize = 22
        local labelGap = 10
        local columnInfo = poiLabelColumnInfo or {}
        rowH = tonumber(columnInfo.row_height) or rowH
        rowGap = tonumber(columnInfo.row_gap) or rowGap
        local labelW = tonumber(columnInfo.width) or 0
        local rowCount = #categories + 1
        local labelH = tonumber(columnInfo.height) or ((rowCount * rowH) + (math.max(0, rowCount - 1) * rowGap))
        local panelW = math.max(300, 16 + chipSize + labelGap + labelW + 16)
        local panelH = 32 + math.max(labelH, (rowCount * rowH) + (math.max(0, rowCount - 1) * rowGap))
        local rowX = panelX + 16
        local rowY = panelY + 16

        setSlotRect(overlay.poiPanelSlot, panelX, panelY, panelW, panelH, 1001)
        setSlotRect(overlay.poiLabelColumnSlot, rowX + chipSize + labelGap, rowY, labelW, labelH, 1002)
        setSlotRect(overlay.poiAllRowSlot, rowX, rowY + math.floor((rowH - chipSize) / 2), chipSize, chipSize, 1002)
        poiAllRowHitRect = { X = rowX, Y = rowY, Width = panelW - 32, Height = rowH }
        for index, category in ipairs(categories) do
            local y = rowY + ((rowH + rowGap) * index)
            local slot = overlay.poiRowSlotsByCategoryId[category.id]
            setSlotRect(slot, rowX, y + math.floor((rowH - chipSize) / 2), chipSize, chipSize, 1002)
            category.rowHitRect = { X = rowX, Y = y, Width = panelW - 32, Height = rowH }
        end
    end

    local hoverTarget, hoverCategory = getPoiPanelHoverTarget(panelVisible)
    local allHovered = hoverTarget == "all"
    local allRowState = tostring(poiAllVisible) .. ":" .. tostring(allHovered)
    if poiAllRowVisibleState ~= allRowState then
        setPoiRowColor(overlay.poiAllRow, poiAllVisible, allHovered)
        poiAllRowVisibleState = allRowState
    end

    for _, category in ipairs(categories) do
        local hovered = hoverTarget == "category" and hoverCategory == category
        local rowState = tostring(category.visible) .. ":" .. tostring(hovered)
        if category.rowVisibleState ~= rowState then
            setPoiRowColor(overlay.poiRowsByCategoryId[category.id], category.visible, hovered)
            category.rowVisibleState = rowState
        end
    end
end

local function setAllPoiCategoriesVisible(visible)
    poiAllVisible = visible
    for _, category in ipairs(loadPoiData()) do
        category.visible = visible
        category.rowVisibleState = nil
    end
    poiAllRowVisibleState = nil
    poiRuntime.saveCategoryState()

    log("All POI markers " .. (poiAllVisible and "shown" or "hidden"))
end

local function areAllPoiCategoriesVisible()
    for _, category in ipairs(loadPoiData()) do
        if not category.visible then return false end
    end

    return true
end

local function setPoiCategoryVisible(category, visible)
    if not category then return end
    if category.visible == visible then return end

    category.visible = visible
    poiAllVisible = areAllPoiCategoriesVisible()
    poiAllRowVisibleState = nil

    category.rowVisibleState = nil

    poiRuntime.saveCategoryState()
    log("POI category " .. category.title .. " " .. (visible and "shown" or "hidden"))
end




local function attachOverlay()
    if not poiIsGameplayWorld() then
        if not attachAttemptLogged then
            attachAttemptLogged = true
            log("WBP_HUDScreen is not available in a gameplay world yet, waiting...")
        end
        return false
    end

    local hudScreen = findHudScreen()
    if not hudScreen:IsValid() then
        if not attachAttemptLogged then
            attachAttemptLogged = true
            log("WBP_HUDScreen is not available in a gameplay world yet, waiting...")
        end
        return false
    end

    local root, widgetOuter = getOverlayRootAndOuter(hudScreen)
    if not root:IsValid() or not widgetOuter:IsValid() then
        if not attachAttemptLogged then
            attachAttemptLogged = true
            log("HUD/MainScreen root is not available yet, waiting...")
        end
        return false
    end

    local sameHud = (not isValid(hudScreen) and not isValid(overlay.hudScreen)) or sameObject(overlay.hudScreen, hudScreen)
    if overlay.canvas:IsValid() and sameHud and sameObject(overlay.root, root) then return true end
    if overlay.canvas:IsValid() then detachOverlay(false) end

    overlay.hudScreen = hudScreen
    overlay.root = root

    overlay.canvas = constructWidget("CanvasPanel", widgetOuter)
    if not overlay.canvas:IsValid() then return false end

    overlay.canvasSlot = addToCanvas(root, overlay.canvas)
    if not overlay.canvasSlot then
        log("Failed to add CanvasPanel to HUD root: " .. root:GetFullName())
        overlay.canvas = CreateInvalidObject()
        return false
    end
    setSlotFill(overlay.canvasSlot, 9999)

    resetOverlayCaches()
    overlay.lastCanvasVisible = false

    local pixel = loadPixelTexture()
    local map = loadMapTexture()

    overlay.dim, overlay.dimSlot = createImage(overlay.canvas, widgetOuter, 980, pixel, COLOR_BLACK)
    setSlotFill(overlay.dimSlot, 980)
    overlay.viewport = constructWidget("CanvasPanel", widgetOuter)
    overlay.viewportSlot = overlay.viewport:IsValid() and addToCanvas(overlay.canvas, overlay.viewport) or nil
    if overlay.viewportSlot then setSlotTopLeft(overlay.viewportSlot, 990) end
    safeCall("Viewport ClipToBounds", function() overlay.viewport:SetClipping(1) end)
    local mapParent = overlay.viewport:IsValid() and overlay.viewport or overlay.canvas
    overlay.map, overlay.mapSlot = createImage(mapParent, widgetOuter, 0, map, COLOR_WHITE)
    setSlotTopLeft(overlay.mapSlot, 0)
    overlay.mapTextureApplied = map:IsValid()
    overlay.borderTop, overlay.borderTopSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderTopSlot, 991)
    overlay.borderRight, overlay.borderRightSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderRightSlot, 991)
    overlay.borderBottom, overlay.borderBottomSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderBottomSlot, 991)
    overlay.borderLeft, overlay.borderLeftSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderLeftSlot, 991)
    local arrow = loadArrowTexture()
    overlay.marker, overlay.markerSlot = createImage(overlay.canvas, widgetOuter, 1001, arrow, COLOR_MARKER)
    setSlotTopLeft(overlay.markerSlot, 1001)
    overlay.markerTextureApplied = arrow:IsValid()
    createRemotePlayerMarkers(widgetOuter)

    createAllPoiCategoryMarkers(widgetOuter)

    -- POI category panel background; row hit testing is handled separately.
    overlay.poiPanel, overlay.poiPanelSlot = createImage(overlay.canvas, widgetOuter, 1001, pixel, { R = 0.0, G = 0.0, B = 0.0, A = 0.65 })
    setSlotTopLeft(overlay.poiPanelSlot, 1001)
    setWidgetVisibility(overlay.poiPanel, false)
    createPoiCategoryRows(widgetOuter, pixel)

    local fogTex = loadFogTexture()
    local fogParent = overlay.viewport:IsValid() and overlay.viewport or overlay.canvas
    overlay.fog, overlay.fogSlot = createImage(fogParent, widgetOuter, 1, fogTex, COLOR_WHITE)
    setSlotTopLeft(overlay.fogSlot, 1)
    overlay.fogTextureApplied = fogTex:IsValid()
    setWidgetVisibility(overlay.fog, isFogEnabled())


    overlay.marker:SetRenderTransformPivot(vec2(0.5, 0.5))
    overlay.canvas:SetVisibility(HIDDEN)

    if not overlayAttachedLogged then
        overlayAttachedLogged = true
        log("UMG overlay attached to HUD: " .. root:GetFullName())
    end

    return true
end

local function ensureOverlayAttached()
    if overlay.canvas:IsValid() then return true end
    return attachOverlay()
end

setSlotRect = function(slot, x, y, width, height, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetPosition(vec2(x, y))
    slot:SetSize(vec2(width, height))
    if zOrder then slot:SetZOrder(zOrder) end
end

setWidgetRenderTranslation = function(widget, x, y)
    if not widget or not widget:IsValid() then return end
    widget:SetRenderTranslation(vec2(x, y))
end

local function getViewportSize()
    local world = UEHelpers.GetWorld()
    local layout = getWidgetLayoutLibrary()
    if world:IsValid() and layout:IsValid() then
        local size = safeCall("GetViewportSize", function()
            return layout:GetViewportSize(world)
        end)
        if size and size.X and size.Y and size.X > 0 and size.Y > 0 then
            local scale = safeCall("GetViewportScale", function()
                return layout:GetViewportScale(world)
            end)
            if scale and scale > 0 and scale ~= 1.0 then
                return size.X / scale, size.Y / scale
            end
            return size.X, size.Y
        end
    end
    return 1920, 1080
end

local function warnMousePositionUnavailable(message)
    if poiMousePositionWarningLogged then return end
    poiMousePositionWarningLogged = true
    log(message)
end

getMousePositionOnViewport = function(silent)
    local world = UEHelpers.GetWorld()
    local layout = getWidgetLayoutLibrary()
    if world:IsValid() and layout:IsValid() then
        local ok, position = pcall(function()
            return layout:GetMousePositionOnViewport(world)
        end)
        if ok and position and position.X and position.Y then
            local scaleOk, scale = pcall(function()
                return layout:GetViewportScale(world)
            end)
            if scaleOk and scale and scale > 0 and scale ~= 1.0 then
                return position.X, position.Y, position.X / scale, position.Y / scale
            end
            return position.X, position.Y
        end
    end

    if not silent then
        warnMousePositionUnavailable("POI row click ignored: mouse position was not available")
    end
    return nil, nil
end

local function isPointInRect(x, y, rect)
    return rect
        and x >= rect.X and x <= rect.X + rect.Width
        and y >= rect.Y and y <= rect.Y + rect.Height
end

getPoiPanelTargetAtScreenPosition = function(x, y)
    if not x or not y then return nil, nil end

    if isPointInRect(x, y, poiAllRowHitRect) then
        return "all", nil
    end

    for _, category in ipairs(loadPoiData()) do
        if isPointInRect(x, y, category.rowHitRect) then
            return "category", category
        end
    end

    return nil, nil
end

local function togglePoiCategoryAtMousePosition()
    if not largeMapOpen then return end
    if poiRowToggleLocked then return end

    local x, y, rawX, rawY = getMousePositionOnViewport()
    local target, category = getPoiPanelTargetAtScreenPosition(x, y)
    if not target and rawX and rawY then
        target, category = getPoiPanelTargetAtScreenPosition(rawX, rawY)
    end
    if not target then return end

    poiRowToggleLocked = true

    if target == "all" then
        setAllPoiCategoriesVisible(not poiAllVisible)
    else
        setPoiCategoryVisible(category, not category.visible)
    end

    markOverlayStateDirty(false)
    scheduleMapWork(0, false)
end

local function getViewportPollSampleCount()
    local interval = Config.UpdateIntervalMs or 100
    if largeMapOpen and Config.LargeMap and Config.LargeMap.UpdateIntervalMs then
        interval = Config.LargeMap.UpdateIntervalMs
    elseif Config.Minimap and Config.Minimap.UpdateIntervalMs then
        interval = Config.Minimap.UpdateIntervalMs
    end
    local pollInterval = Config.ViewportPollIntervalMs or 1000
    if interval <= 0 then return 10 end
    local count = math.floor((pollInterval / interval) + 0.5)
    if count < 1 then return 1 end
    return count
end

local function getCachedViewportSize(force)
    if force or viewportDirty or viewportPollCountdown <= 0 then
        cachedScreenW, cachedScreenH = getViewportSize()
        viewportDirty = false
        viewportPollCountdown = getViewportPollSampleCount()
    else
        viewportPollCountdown = viewportPollCountdown - 1
    end

    return cachedScreenW, cachedScreenH
end

local function getAspectRatio()
    local width = Config.Map.ImageWidth or 1
    local height = Config.Map.ImageHeight or 1
    if height == 0 then return 1.0 end
    return width / height
end

local function fitToAspect(maxW, maxH)
    local aspect = getAspectRatio()
    local width = maxW
    local height = width / aspect
    if height > maxH then
        height = maxH
        width = height * aspect
    end
    return width, height
end

local function getLayoutBox(layout, screenW, screenH)
    local maxW = layout.Width or (screenW * (layout.WidthRatio or 0.25))
    local maxH = layout.Height or (screenH * (layout.HeightRatio or 0.25))
    local width, height = fitToAspect(maxW, maxH)
    local anchor = layout.Anchor or "TopRight"
    local x = layout.X or 0
    local y = layout.Y or 0

    if anchor == "TopRight" then
        x = screenW - width - (layout.MarginRight or 16)
        y = layout.MarginTop or 16
    elseif anchor == "TopLeft" then
        x = layout.MarginLeft or 16
        y = layout.MarginTop or 16
    elseif anchor == "BottomRight" then
        x = screenW - width - (layout.MarginRight or 16)
        y = screenH - height - (layout.MarginBottom or 16)
    elseif anchor == "BottomLeft" then
        x = layout.MarginLeft or 16
        y = screenH - height - (layout.MarginBottom or 16)
    elseif anchor == "Center" then
        x = ((screenW - width) / 2.0) + (layout.OffsetX or 0)
        y = ((screenH - height) / 2.0) + (layout.OffsetY or 0)
    end

    return x, y, width, height
end

local function getAxisValue(vector, axisName)
    if not vector then return nil end
    return vector[axisName or "X"]
end

local function getBoundsForLocation(worldX, worldY)
    return configuredBounds
end
local function initFogGrid()
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24

    fogGrid = {}
    for y = 1, h do
        fogGrid[y] = {}
        for x = 1, w do
            fogGrid[y][x] = false
        end
    end
end

local function getFogSavePath()
    local fogCfg = Config.FogOfWar or {}
    return joinPath(fogRuntime.getDirectory(), fogCfg.SaveFile or "fog_state.dat")
end

local function saveFogState()
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24
    local path = getFogSavePath()

    local file = io.open(path, "w")
    if not file then return end

    for y = 1, h do
        local row = {}
        for x = 1, w do
            row[x] = (fogGrid[y] and fogGrid[y][x]) and "1" or "0"
        end
        file:write(table.concat(row) .. "\n")
    end

    file:close()
end

fogRuntime.loadStateFromPath = function(path)
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24

    local file = io.open(path, "r")
    if not file then return false end

    for y = 1, h do
        local line = file:read("*l")
        if not line then break end
        if not fogGrid[y] then fogGrid[y] = {} end

        for x = 1, math.min(w, #line) do
            fogGrid[y][x] = line:sub(x, x) == "1"
        end
    end

    file:close()
    return true
end

fogRuntime.loadState = function()
    return fogRuntime.loadStateFromPath(getFogSavePath())
end

local function getFogTGAPath()
    local fogCfg = Config.FogOfWar or {}
    return joinPath(fogRuntime.getDirectory(), fogCfg.OverlayFile or "fog_overlay.tga")
end

local function writeFogTGA()
    local fogCfg = Config.FogOfWar or {}
    local w = fogCfg.GridWidth or 57
    local h = fogCfg.GridHeight or 24
    local alpha = math.floor((fogCfg.FogAlpha or 0.95) * 255)
    local path = getFogTGAPath()

    local file = io.open(path, "wb")
    if not file then
        log("Failed to write fog TGA: " .. path)
        return false
    end

    file:write(string.char(
        0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        w % 256, math.floor(w / 256),
        h % 256, math.floor(h / 256),
        32, 0x28
    ))

    local revealed = string.char(0, 0, 0, 0)
    local fog = string.char(0, 0, 0, alpha)
    local parts = {}

    for y = 1, h do
        local row = fogGrid[y]
        for x = 1, w do
            parts[#parts + 1] = (row and row[x]) and revealed or fog
        end
    end

    file:write(table.concat(parts))
    file:close()
    return true
end

local function worldToUV(worldX, worldY)
    local mapConfig = Config.Map
    local imageW = mapConfig.ImageWidth or 1
    local imageH = mapConfig.ImageHeight or 1
    if imageW <= 0 or imageH <= 0 then return nil, nil end

    local imageX = (worldX * (mapConfig.ImageFromWorldXScale or 1.0)) + (mapConfig.ImageFromWorldXOffset or 0.0)
    local imageY = (worldY * (mapConfig.ImageFromWorldYScale or 1.0)) + (mapConfig.ImageFromWorldYOffset or 0.0)

    local u = imageX / imageW
    local v = imageY / imageH

    if mapConfig.ClampMarkerToMap ~= false then
        u = clamp(u, 0.0, 1.0)
        v = clamp(v, 0.0, 1.0)
    end

    return u, v
end

poiPointToUV = function(point)
    if not point then return nil, nil end

    local imageW = Config.Map.ImageWidth or 1
    local imageH = Config.Map.ImageHeight or 1
    if imageW <= 0 or imageH <= 0 then return nil, nil end

    return clamp((point.x or 0) / imageW, 0.0, 1.0), clamp((point.y or 0) / imageH, 0.0, 1.0)
end

local function updateFogAtPosition(worldX, worldY)
    if not isFogEnabled() then return end

    local u, v = worldToUV(worldX, worldY)
    if not u or not v then return end

    local fogCfg = Config.FogOfWar or {}
    local fw = fogCfg.GridWidth or 57
    local fh = fogCfg.GridHeight or 24
    local cx = clamp(math.floor(u * fw) + 1, 1, fw)
    local cy = clamp(math.floor(v * fh) + 1, 1, fh)

    if cx == fogLastCellX and cy == fogLastCellY then return end
    fogLastCellX = cx
    fogLastCellY = cy

    local radius = fogCfg.RevealRadius or 2
    local changed = false
    for dy = -radius, radius do
        local gy = cy + dy
        if gy >= 1 and gy <= fh then
            if not fogGrid[gy] then fogGrid[gy] = {} end
            for dx = -radius, radius do
                local gx = cx + dx
                if gx >= 1 and gx <= fw then
                    if not fogGrid[gy][gx] then
                        fogGrid[gy][gx] = true
                        changed = true
                    end
                end
            end
        end
    end

    if changed then
        fogSaveDirty = true
        scheduleFogFlush()
    end
end

loadFogTexture = function(forceReload)
    if not forceReload and fogTexture:IsValid() then return fogTexture end

    local path = getFogTGAPath()
    if not fileExists(path) then return fogTexture end

    local world = UEHelpers.GetWorld()
    local renderer = getRenderingLibrary()
    if not world:IsValid() or not renderer:IsValid() then return fogTexture end

    local tex = safeCall("ImportFogTexture", function()
        return renderer:ImportFileAsTexture2D(world, path)
    end)

    if tex and tex:IsValid() then
        fogTexture = tex
    end

    return fogTexture
end

scheduleFogFlush = function()
    if fogFlushPending then return end
    fogFlushPending = true
    local delay = (Config.FogOfWar and Config.FogOfWar.VisualThrottleMs) or 750
    ExecuteWithDelay(delay, function()
        ExecuteInGameThread(flushFogVisual)
    end)
end

flushFogVisual = function()
    fogFlushPending = false
    if not isFogEnabled() then return end

    safeCall("Fog TGA write", writeFogTGA)
    fogDirty = false

    if overlay.fog and overlay.fog:IsValid() then
        local fogTex = loadFogTexture(true)
        if fogTex and fogTex:IsValid() then
            setImageTexture(overlay.fog, fogTex, COLOR_WHITE)
            overlay.fogTextureApplied = true
        end
    else
        fogTexture = CreateInvalidObject()
    end

    scheduleFogSave()
end

scheduleFogSave = function()
    if fogSavePending or not fogSaveDirty then return end
    fogSavePending = true
    local delay = (Config.FogOfWar and Config.FogOfWar.SaveThrottleMs) or 20000
    ExecuteWithDelay(delay, function()
        ExecuteInGameThread(flushFogSave)
    end)
end

flushFogSave = function()
    fogSavePending = false
    if fogSaveDirty then
        safeCall("Fog state save", saveFogState)
        fogSaveDirty = false
    end
end

fogRuntime.reloadForCurrentSave = function()
    if not isFogEnabled() then return end

    fogRuntime.resetPaths()
    initFogGrid()
    fogTexture = CreateInvalidObject()
    fogDirty = true
    fogSaveDirty = false
    fogFlushPending = false
    fogSavePending = false
    fogLastCellX = nil
    fogLastCellY = nil

    local loaded = fogRuntime.loadState()
    local slotName = fogRuntime.detectSaveSlotName()
    if not loaded and not fogRuntime.isTransientSlotName(slotName) then
        local legacyPath = getAssetPath((Config.FogOfWar or {}).SaveFile or "fog_state.dat")
        if legacyPath ~= getFogSavePath() and fileExists(legacyPath) then
            loaded = fogRuntime.loadStateFromPath(legacyPath)
            if loaded then
                saveFogState()
                log("Fog of war migrated legacy state into save slot '" .. slotName .. "'")
            end
        end
    end

    if loaded then
        log("Fog of war loaded for save slot '" .. slotName .. "'")
    else
        log("Fog of war: no save found for slot '" .. slotName .. "', starting fresh")
    end

    writeFogTGA()
    log("Fog of war enabled (" .. (Config.FogOfWar.GridWidth or 57) .. "x" .. (Config.FogOfWar.GridHeight or 24) .. ")")
end

local function getPlayerLocationAndForward()
    pawnCheckCountdown = pawnCheckCountdown - 1
    if pawnCheckCountdown <= 0 or not cachedPawn:IsValid() then
        cachedPawn = UEHelpers.GetPlayer()
        pawnCheckCountdown = PAWN_CHECK_INTERVAL
    end
    if not cachedPawn:IsValid() then return nil, nil end
    return cachedPawn:K2_GetActorLocation(), cachedPawn:GetActorForwardVector(), cachedPawn
end

function findAllObjectsOfClass(className)
    local ok, objects = pcall(function()
        return FindAllOf(className)
    end)
    if not ok or type(objects) ~= "table" then return {} end
    return objects
end

function objectKey(object)
    if not object or not object:IsValid() then return nil end
    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    if ok and name then return name end
    ok, name = pcall(function()
        return object:GetName()
    end)
    if ok and name then return name end
    return tostring(object)
end

function getRemotePlayerClassNames()
    local configured = getMultiplayerConfig().PlayerActorClasses
    if type(configured) == "table" and #configured > 0 then return configured end
    return DEFAULT_REMOTE_PLAYER_CLASSES
end

function isObjectInWorld(object, world)
    if not world or not world:IsValid() then return true end

    local ok, objectWorld = pcall(function()
        return object:GetWorld()
    end)
    if not ok or not isValid(objectWorld) then return false end

    return sameObject(objectWorld, world)
end

function collectRemotePlayerSamples(localPawn)
    for i = #remotePlayerSamples, 1, -1 do
        remotePlayerSamples[i] = nil
    end

    if not isRemotePlayerMarkersEnabled() then return remotePlayerSamples end

    local seen = {}
    local limit = getRemotePlayerMarkerLimit()
    local localWorld = nil
    if localPawn and localPawn:IsValid() then
        local okWorld, world = pcall(function()
            return localPawn:GetWorld()
        end)
        if okWorld and isValid(world) then
            localWorld = world
        end
    end

    for _, className in ipairs(getRemotePlayerClassNames()) do
        for _, actor in pairs(findAllObjectsOfClass(className)) do
            if actor and actor:IsValid() and not sameObject(actor, localPawn) and isObjectInWorld(actor, localWorld) then
                local key = objectKey(actor)
                if key and not seen[key] then
                    seen[key] = true
                    local okLocation, location = pcall(function()
                        return actor:K2_GetActorLocation()
                    end)
                    if okLocation and location then
                        local okForward, forward = pcall(function()
                            return actor:GetActorForwardVector()
                        end)
                        forward = okForward and forward or nil
                        remotePlayerSamples[#remotePlayerSamples + 1] = {
                            worldX = getAxisValue(location, Config.Map.HorizontalAxis) or 0.0,
                            worldY = getAxisValue(location, Config.Map.VerticalAxis) or 0.0,
                            forwardX = forward and (getAxisValue(forward, Config.Map.HorizontalAxis) or 1.0) or 1.0,
                            forwardY = forward and (getAxisValue(forward, Config.Map.VerticalAxis) or 0.0) or 0.0,
                        }
                        if #remotePlayerSamples >= limit then
                            return remotePlayerSamples
                        end
                    end
                end
            end
        end
    end

    return remotePlayerSamples
end

function buildRemotePlayersKey(players)
    local marker = Config.Marker or {}
    local moveThreshold = marker.MoveThresholdPixels or 1
    local headingThreshold = marker.HeadingThresholdDegrees or 1
    local parts = {}
    for i, player in ipairs(players or {}) do
        local angle = math.deg(math.atan(player.forwardY or 0.0, player.forwardX or 1.0))
        parts[i] = tostring(quantize(player.worldX or 0.0, moveThreshold))
            .. ":" .. tostring(quantize(player.worldY or 0.0, moveThreshold))
            .. ":" .. tostring(quantize(angle, headingThreshold))
    end
    return table.concat(parts, ";")
end

function getMapHeadingAngle(forwardX, forwardY)
    forwardX = forwardX or 1.0
    forwardY = forwardY or 0.0
    if Config.Map.ProjectionMode ~= "DirectImage" and Config.Map.InvertVertical ~= false then forwardY = -forwardY end
    return math.deg(math.atan(forwardY, forwardX))
end

local function sampleToMapPoint(sample, mapX, mapY, mapW, mapH, out)
    local u, v = worldToUV(sample.worldX, sample.worldY)
    if not u or not v then return nil end

    out.X = mapX + (u * mapW)
    out.Y = mapY + (v * mapH)
    out.U = u
    out.V = v
    out.ForwardX = sample.forwardX
    out.ForwardY = sample.forwardY
    return out
end

local function isMapActive()
    return largeMapOpen or (mapVisible and Config.Minimap and Config.Minimap.Enabled ~= false)
end

local function needsHiddenApply()
    return overlay.canvas:IsValid() and overlay.lastCanvasVisible ~= false
end

markOverlayStateDirty = function(forceViewport)
    overlayGeneration = overlayGeneration + 1
    resetOverlayCaches()
    lastWorldX = nil
    if forceViewport ~= false then viewportDirty = true end
end

local function hasPlayerMoved(worldX, worldY, forwardX, forwardY)
    if not lastWorldX then return true end
    local threshold = (Config.Marker or {}).WorldMoveThreshold or 50.0
    local dx = worldX - lastWorldX
    local dy = worldY - lastWorldY
    if (dx * dx + dy * dy) >= (threshold * threshold) then return true end
    local dfx = forwardX - (lastForwardX or 0)
    local dfy = forwardY - (lastForwardY or 0)
    if (dfx * dfx + dfy * dfy) > 0.001 then return true end
    return false
end

local function collectFrameSample()
    local active = isMapActive()
    if not active and not needsHiddenApply() then return nil end
    if not ensureOverlayAttached() then return nil end

    local screenW, screenH = getCachedViewportSize(viewportDirty)
    local sample = frameSample
    sample.generation = overlayGeneration
    sample.screenW = screenW
    sample.screenH = screenH

    if not active then
        sample.hidden = true
        return sample
    end

    local location, forward, localPawn = getPlayerLocationAndForward()
    if not location then return nil end

    local worldX = getAxisValue(location, Config.Map.HorizontalAxis) or 0.0
    local worldY = getAxisValue(location, Config.Map.VerticalAxis) or 0.0
    local forwardX = forward and (getAxisValue(forward, Config.Map.HorizontalAxis) or 1.0) or 1.0
    local forwardY = forward and (getAxisValue(forward, Config.Map.VerticalAxis) or 0.0) or 0.0
    local remotePlayers = collectRemotePlayerSamples(localPawn)
    local remotePlayersKey = buildRemotePlayersKey(remotePlayers)

    if not hasPlayerMoved(worldX, worldY, forwardX, forwardY) and remotePlayersKey == lastRemotePlayersKey and not viewportDirty then
        return nil
    end

    lastWorldX = worldX
    lastWorldY = worldY
    lastForwardX = forwardX
    lastForwardY = forwardY
    lastRemotePlayersKey = remotePlayersKey

    updateFogAtPosition(worldX, worldY)

    sample.hidden = false
    sample.worldX = worldX
    sample.worldY = worldY
    sample.forwardX = forwardX
    sample.forwardY = forwardY
    sample.remotePlayers = sample.remotePlayers or {}
    for i = #sample.remotePlayers, 1, -1 do
        sample.remotePlayers[i] = nil
    end
    for i, player in ipairs(remotePlayers) do
        sample.remotePlayers[i] = sample.remotePlayers[i] or {}
        sample.remotePlayers[i].worldX = player.worldX
        sample.remotePlayers[i].worldY = player.worldY
        sample.remotePlayers[i].forwardX = player.forwardX
        sample.remotePlayers[i].forwardY = player.forwardY
    end

    return sample
end

function clearRemoteDrawState(state)
    state.remotePlayers = state.remotePlayers or {}
    for i = #state.remotePlayers, 1, -1 do
        state.remotePlayers[i] = nil
    end
    state.remotePlayerCount = 0
    state.remotePlayerMarkerSize = nil
end

local function buildDrawState(sample)
    local state = drawState
    local shouldShow = isMapActive()

    state.generation = sample.generation
    state.shouldShow = shouldShow and not sample.hidden
    state.largeMapOpen = largeMapOpen
    state.screenW = sample.screenW
    state.screenH = sample.screenH
    state.layout = nil
    state.point = nil
    state.markerXKey = nil
    state.markerYKey = nil
    state.markerAngleKey = nil
    state.markerSize = nil
    state.angle = 0.0
    state.angleKey = nil
    state.mapLocalX = nil
    state.mapLocalY = nil
    state.mapW = nil
    state.mapH = nil
    state.markerX = nil
    state.markerY = nil
    state.markerOnScreen = false
    clearRemoteDrawState(state)

    if not shouldShow or sample.hidden then
        state.shouldShow = false
        return state
    end

    local layout = largeMapOpen and Config.LargeMap or Config.Minimap
    local x, y, width, height = getLayoutBox(layout, sample.screenW, sample.screenH)
    local thickness = layout.BorderThickness or 2
    local point = nil
    local angle = 0.0
    local angleKey = 0
    local marker = Config.Marker or {}
    local moveThreshold = marker.MoveThresholdPixels or 1
    local headingThreshold = marker.HeadingThresholdDegrees or 1

    if shouldShow then
        point = sampleToMapPoint(sample, x, y, width, height, mapPoint)
        if point then
            angle = getMapHeadingAngle(point.ForwardX, point.ForwardY)

            local zoom = largeMapOpen and largeMapZoom or minimapZoom
            if not zoom or zoom < 1.0 then zoom = 1.0 end
            local mapW = width * zoom
            local mapH = height * zoom
            local u = point.U or 0.5
            local v = point.V or 0.5
            local cu = u
            local cv = v
            if largeMapOpen then
                if largeMapViewU == nil then largeMapViewU = u end
                if largeMapViewV == nil then largeMapViewV = v end
                cu = largeMapViewU
                cv = largeMapViewV
            end

            local mapLocalX = clamp((width * 0.5) - (cu * mapW), width - mapW, 0.0)
            local mapLocalY = clamp((height * 0.5) - (cv * mapH), height - mapH, 0.0)
            local markerX = x + (u * mapW) + mapLocalX
            local markerY = y + (v * mapH) + mapLocalY

            state.mapLocalX = mapLocalX
            state.mapLocalY = mapLocalY
            state.mapW = mapW
            state.mapH = mapH
            state.markerX = markerX
            state.markerY = markerY
            state.markerOnScreen = markerX >= x and markerX <= (x + width)
                and markerY >= y and markerY <= (y + height)

            angleKey = quantize(angle, headingThreshold)
            state.markerXKey = quantize(markerX, moveThreshold)
            state.markerYKey = quantize(markerY, moveThreshold)
            state.markerAngleKey = angleKey
            state.markerSize = marker.Size or 8
        end

        state.remotePlayerMarkerSize = getRemotePlayerMarkerSize()
        for _, player in ipairs(sample.remotePlayers or {}) do
            local remotePoint = {}
            if point and sampleToMapPoint(player, x, y, width, height, remotePoint) then
                local remoteX = x + ((remotePoint.U or 0.5) * state.mapW) + state.mapLocalX
                local remoteY = y + ((remotePoint.V or 0.5) * state.mapH) + state.mapLocalY
                local remote = {
                    x = remoteX,
                    y = remoteY,
                    angle = getMapHeadingAngle(remotePoint.ForwardX, remotePoint.ForwardY),
                }
                remote.onScreen = remoteX >= x and remoteX <= (x + width)
                    and remoteY >= y and remoteY <= (y + height)
                remote.angleKey = quantize(remote.angle, headingThreshold)
                remote.xKey = quantize(remote.x, moveThreshold)
                remote.yKey = quantize(remote.y, moveThreshold)
                state.remotePlayerCount = state.remotePlayerCount + 1
                state.remotePlayers[state.remotePlayerCount] = remote
            end
        end
    end

    state.x = x
    state.y = y
    state.width = width
    state.height = height
    state.thickness = thickness
    state.layout = layout
    state.layoutXKey = math.floor(x)
    state.layoutYKey = math.floor(y)
    state.layoutWidthKey = math.floor(width)
    state.layoutHeightKey = math.floor(height)
    state.layoutMapAlpha = layout.MapAlpha or 1.0
    state.layoutBackgroundAlpha = layout.BackgroundAlpha or 0.45
    state.layoutDimVisible = largeMapOpen and layout.DimBackground ~= false
    state.mapLocalXKey = quantize(state.mapLocalX or 0.0, 1)
    state.mapLocalYKey = quantize(state.mapLocalY or 0.0, 1)
    state.mapWKey = quantize(state.mapW or width, 1)
    state.mapHKey = quantize(state.mapH or height, 1)
    state.point = point
    state.angle = angle
    state.angleKey = angleKey
    return state
end

local function hasLayoutChanged(state)
    return overlay.lastLayoutLarge ~= state.largeMapOpen
        or overlay.lastLayoutScreenW ~= state.screenW
        or overlay.lastLayoutScreenH ~= state.screenH
        or overlay.lastLayoutXKey ~= state.layoutXKey
        or overlay.lastLayoutYKey ~= state.layoutYKey
        or overlay.lastLayoutWidthKey ~= state.layoutWidthKey
        or overlay.lastLayoutHeightKey ~= state.layoutHeightKey
        or overlay.lastLayoutMapAlpha ~= state.layoutMapAlpha
        or overlay.lastLayoutBackgroundAlpha ~= state.layoutBackgroundAlpha
        or overlay.lastLayoutBorderThickness ~= state.thickness
        or overlay.lastLayoutDimVisible ~= state.layoutDimVisible
end

local function rememberLayoutState(state)
    overlay.lastLayoutLarge = state.largeMapOpen
    overlay.lastLayoutScreenW = state.screenW
    overlay.lastLayoutScreenH = state.screenH
    overlay.lastLayoutXKey = state.layoutXKey
    overlay.lastLayoutYKey = state.layoutYKey
    overlay.lastLayoutWidthKey = state.layoutWidthKey
    overlay.lastLayoutHeightKey = state.layoutHeightKey
    overlay.lastLayoutMapAlpha = state.layoutMapAlpha
    overlay.lastLayoutBackgroundAlpha = state.layoutBackgroundAlpha
    overlay.lastLayoutBorderThickness = state.thickness
    overlay.lastLayoutDimVisible = state.layoutDimVisible
end

function updateRemotePlayerMarkers(state, layoutChanged)
    local markers = overlay.remotePlayerMarkers or {}
    local slots = overlay.remotePlayerMarkerSlots or {}
    local count = state.remotePlayerCount or 0
    local size = state.remotePlayerMarkerSize or getRemotePlayerMarkerSize()
    local shapeChanged = overlay.remotePlayerMarkerSize ~= size

    if not overlay.remotePlayerTextureApplied then
        local arrow = loadArrowTexture()
        if arrow and arrow:IsValid() then
            for _, marker in ipairs(markers) do
                setImageTexture(marker, arrow, COLOR_REMOTE_PLAYER)
            end
            overlay.remotePlayerTextureApplied = true
        end
    end

    for i, marker in ipairs(markers) do
        local remote = (i <= count) and state.remotePlayers[i] or nil
        local visible = state.shouldShow and remote ~= nil and remote.onScreen ~= false

        if overlay.remotePlayerMarkerVisibleStates[i] ~= visible then
            setWidgetVisibility(marker, visible)
            overlay.remotePlayerMarkerVisibleStates[i] = visible
        end

        if visible and marker and marker:IsValid() then
            local slot = slots[i]
            if layoutChanged or shapeChanged then
                setSlotRect(slot, 0.0, 0.0, size * 2, size * 2, 1001)
            end

            local key = tostring(remote.xKey) .. ":" .. tostring(remote.yKey) .. ":" .. tostring(remote.angleKey) .. ":" .. tostring(size)
            if overlay.remotePlayerMarkerKeys[i] ~= key then
                setWidgetRenderTranslation(marker, remote.x - size, remote.y - size)
                marker:SetRenderTransformAngle(remote.angle)
                overlay.remotePlayerMarkerKeys[i] = key
            end
        else
            overlay.remotePlayerMarkerKeys[i] = nil
        end
    end

    overlay.remotePlayerMarkerSize = size
end

local function applyDrawState(state)
    if not state then return end
    if state.generation ~= overlayGeneration then return end
    if not ensureOverlayAttached() then return end

    setCachedWidgetVisibility("lastCanvasVisible", overlay.canvas, state.shouldShow)
    if not state.shouldShow then
        return
    end

    local layout = state.layout
    local layoutChanged = hasLayoutChanged(state)

    if layoutChanged and overlay.canvasSlot and overlay.canvasSlot:IsValid() then
        setSlotFill(overlay.canvasSlot, 9999)
    end

    if not overlay.mapTextureApplied then
        local map = loadMapTexture()
        if map:IsValid() then
            COLOR_WHITE.A = layout.MapAlpha or 1.0
            setImageTexture(overlay.map, map, COLOR_WHITE)
            COLOR_WHITE.A = 1.0
            overlay.mapTextureApplied = true
        end
    elseif layoutChanged and overlay.map:IsValid() then
        COLOR_WHITE.A = layout.MapAlpha or 1.0
        overlay.map:SetColorAndOpacity(COLOR_WHITE)
        COLOR_WHITE.A = 1.0
    end

    if not overlay.markerTextureApplied then
        local arrow = loadArrowTexture()
        if arrow:IsValid() then
            setImageTexture(overlay.marker, arrow, COLOR_MARKER)
            overlay.markerTextureApplied = true
        end
    end

    if overlay.marker and overlay.marker:IsValid() then
        local markerColorKey = tostring(COLOR_MARKER.R) .. ":" .. tostring(COLOR_MARKER.G) .. ":" .. tostring(COLOR_MARKER.B) .. ":" .. tostring(COLOR_MARKER.A)
        if overlay.lastMarkerColorKey ~= markerColorKey then
            overlay.marker:SetColorAndOpacity(COLOR_MARKER)
            overlay.lastMarkerColorKey = markerColorKey
        end
    end

    if layoutChanged then
        rememberLayoutState(state)
        setCachedWidgetVisibility("lastDimVisible", overlay.dim, state.layoutDimVisible)
        setSlotFill(overlay.dimSlot, 980)
        if overlay.dim:IsValid() then
            COLOR_BLACK.A = layout.BackgroundAlpha or 0.45
            overlay.dim:SetColorAndOpacity(COLOR_BLACK)
        end

        setSlotRect(overlay.viewportSlot, state.x, state.y, state.width, state.height, 990)
        setSlotRect(overlay.borderTopSlot, state.x, state.y, state.width, state.thickness, 991)
        setSlotRect(overlay.borderRightSlot, state.x + state.width - state.thickness, state.y, state.thickness, state.height, 991)
        setSlotRect(overlay.borderBottomSlot, state.x, state.y + state.height - state.thickness, state.width, state.thickness, 991)
        setSlotRect(overlay.borderLeftSlot, state.x, state.y, state.thickness, state.height, 991)
    end

    if isFogEnabled() and overlay.fog:IsValid() then
        if fogDirty then
            fogDirty = false
            local fogTex = loadFogTexture(true)
            if fogTex:IsValid() then
                setImageTexture(overlay.fog, fogTex, COLOR_WHITE)
                overlay.fogTextureApplied = true
            end
        elseif not overlay.fogTextureApplied then
            local fogTex = loadFogTexture()
            if fogTex:IsValid() then
                setImageTexture(overlay.fog, fogTex, COLOR_WHITE)
                overlay.fogTextureApplied = true
            end
        end
    end

    -- Keep the fog layer aligned with the visible map bounds.
    if overlay.fog and overlay.fog:IsValid() then
        setCachedWidgetVisibility("lastFogVisible", overlay.fog, isFogEnabled())
    end

    local hasPoint = state.point ~= nil
    if hasPoint and state.mapW and state.mapH then
        setSlotRect(overlay.mapSlot, state.mapLocalX or 0.0, state.mapLocalY or 0.0, state.mapW, state.mapH, 0)
        if isFogEnabled() and overlay.fog:IsValid() then
            setSlotRect(overlay.fogSlot, state.mapLocalX or 0.0, state.mapLocalY or 0.0, state.mapW, state.mapH, 1)
        end
    end

    updateAllPoiCategoryMarkers(state, layoutChanged)
    updateRemotePlayerMarkers(state, layoutChanged)
    updatePoiPanelRows(layoutChanged)
    poiRowToggleLocked = false

    setMarkerVisibility(hasPoint and state.markerOnScreen ~= false)
    if not hasPoint then
        return
    end

    local size = state.markerSize or 8
    local markerChanged = overlay.lastMarkerXKey ~= state.markerXKey
        or overlay.lastMarkerYKey ~= state.markerYKey
        or overlay.lastMarkerAngleKey ~= state.markerAngleKey
        or overlay.lastMarkerSize ~= size
    if not markerChanged then
        return
    end

    local shapeChanged = overlay.lastMarkerSize ~= size
    overlay.lastMarkerXKey = state.markerXKey
    overlay.lastMarkerYKey = state.markerYKey
    overlay.lastMarkerAngleKey = state.markerAngleKey
    overlay.lastMarkerSize = size

    if shapeChanged then
        setSlotRect(overlay.markerSlot, 0.0, 0.0, size * 2, size * 2, 1001)
    end
    setWidgetRenderTranslation(overlay.marker, state.markerX - size, state.markerY - size)

    if overlay.lastHeadingAngleKey ~= state.angleKey then
        overlay.lastHeadingAngleKey = state.angleKey
        overlay.marker:SetRenderTransformAngle(state.angle)
    end
end

local function processFrameSample(sample)
    if not sample then return end
    local state = buildDrawState(sample)
    applyDrawState(state)
end

local function resetOverlay()
    detachOverlay(true)
    markOverlayStateDirty(true)
    runtimeBounds = nil
    overlayAttachedLogged = false
    attachAttemptLogged = false
    textureLoadAttempted = false
    pixelLoadAttempted = false
    arrowLoadAttempted = false
    mapTexture = CreateInvalidObject()
    pixelTexture = CreateInvalidObject()
    arrowTexture = CreateInvalidObject()
    fogTexture = CreateInvalidObject()
    poiLabelColumnTexture = CreateInvalidObject()
    poiLabelColumnTextureAttempted = false
    if poiCategories then
        for _, category in ipairs(poiCategories) do
            category.texture = CreateInvalidObject()
            category.textureAttempted = false
            category.textureApplied = false
            category.markerVisibleState = nil
            category.markerLayoutKey = nil
            category.rowVisibleState = nil
            for _, point in ipairs(category.points or {}) do
                point.markerVisibleState = nil
            end
        end
    end
    fogLastCellX = nil
    fogLastCellY = nil
    fogDirty = false
    fogFlushPending = false
    fogSavePending = false
    largeMapViewU = nil
    largeMapViewV = nil
    cachedPawn = CreateInvalidObject()
    pawnCheckCountdown = 0
    viewportPollCountdown = 0
    lastWorldX = nil
    lastWorldY = nil
    lastForwardX = nil
    lastForwardY = nil
    attachRetryIndex = 1
end

local function gameThreadUpdate()
    local sample = collectFrameSample()
    if sample then
        processFrameSample(sample)
    end
end

local function gameThreadUpdateSafe()
    local ok, err = pcall(gameThreadUpdate)
    if not ok and not updateErrorLogged then
        updateErrorLogged = true
        log("Update failed: " .. tostring(err))
    end
end

local function requestUpdate()
    if not isMapActive() and not needsHiddenApply() then return end
    updateRequested = true
end

local scheduleAttachAttempt

local function cancelAttachAttempt()
    attachAttemptToken = attachAttemptToken + 1
    attachAttemptQueued = false
end

local function stopUpdateLoop()
    updateLoopActive = false
    updateRequested = false
end

local function startUpdateLoop()
    updateLoopActive = true
    requestUpdate()
end

local function restartUpdateLoop()
    stopUpdateLoop()
    startUpdateLoop()
end

local function getAttachRetryDelayMs()
    local delays = Config.AttachRetryDelaysMs or DEFAULT_ATTACH_RETRY_DELAYS_MS
    local count = #delays
    if count <= 0 then return 1000 end

    local index = attachRetryIndex
    if index > count then index = count end
    attachRetryIndex = attachRetryIndex + 1
    return delays[index] or 1000
end

local function runAttachAttemptSafe()
    attachAttemptQueued = false
    if overlay.canvas:IsValid() then
        attachRetryIndex = 1
        startUpdateLoop()
        requestUpdate()
        return
    end
    if not isMapActive() then return end

    local ok, attached = pcall(attachOverlay)
    if not ok then
        log("Attach failed: " .. tostring(attached))
        attached = false
    end

    if attached then
        attachRetryIndex = 1
        startUpdateLoop()
        requestUpdate()
    else
        scheduleAttachAttempt(getAttachRetryDelayMs())
    end
end

local function runAttachAttemptOnGameThread()
    if attachAttemptGameThreadToken ~= attachAttemptToken then return end
    runAttachAttemptSafe()
end

scheduleAttachAttempt = function(delayMs)
    if attachAttemptQueued or overlay.canvas:IsValid() or not isMapActive() then return end

    attachAttemptQueued = true
    attachAttemptToken = attachAttemptToken + 1
    local token = attachAttemptToken

    local function run()
        if token ~= attachAttemptToken then return end
        attachAttemptGameThreadToken = token
        ExecuteInGameThread(runAttachAttemptOnGameThread)
    end

    if delayMs and delayMs > 0 then
        ExecuteWithDelay(delayMs, run)
    else
        run()
    end
end

function isStandaloneNetMode(netMode)
    if netMode == nil then return false end
    if type(netMode) == "number" then return netMode == 0 end

    local text = tostring(netMode)
    return text == "0" or text:find("Standalone", 1, true) ~= nil
end

function isMultiplayerWorld(world)
    if not world or not world:IsValid() then return false end

    local okNetMode, netMode = pcall(function()
        return world:GetNetMode()
    end)
    if okNetMode and netMode ~= nil then
        return not isStandaloneNetMode(netMode)
    end

    local okNetDriver, netDriver = pcall(function()
        return world.NetDriver
    end)
    return okNetDriver and isValid(netDriver)
end

local function setGamePausedForLargeMap(shouldPause)
    local world = UEHelpers.GetWorld()
    if not world:IsValid() then return end

    if shouldPause and getMultiplayerConfig().DisablePauseInMultiplayer ~= false and isMultiplayerWorld(world) then
        if not multiplayerPauseSuppressedLogged then
            multiplayerPauseSuppressedLogged = true
            log("Large map pause skipped in multiplayer world")
        end
        mapPauseApplied = false
        return
    end

    if not shouldPause and not mapPauseApplied then return end

    local gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if not gameplayStatics or not gameplayStatics:IsValid() then return end

    safeCall("SetGamePausedForLargeMap", function()
        gameplayStatics:SetGamePaused(world, shouldPause)
    end)

    mapPauseApplied = shouldPause
end

local largeMapPreviousMouseCursor = nil

local function setLargeMapCursorVisible(shouldShow)
    local controller = UEHelpers.GetPlayerController()
    if not controller or not controller:IsValid() then
        log("Large map cursor: PlayerController not valid")
        return
    end

    safeCall("SetLargeMapCursorVisible", function()
        if shouldShow then
            largeMapPreviousMouseCursor = controller.bShowMouseCursor
            controller.bShowMouseCursor = true
            log("Large map cursor shown")
        else
            if largeMapPreviousMouseCursor ~= nil then
                controller.bShowMouseCursor = largeMapPreviousMouseCursor
                largeMapPreviousMouseCursor = nil
                log("Large map cursor restored")
            else
                controller.bShowMouseCursor = false
                log("Large map cursor hidden")
            end
        end
    end)
end

local function closeLargeMap(reason)
    if not largeMapOpen then return end

    largeMapOpen = false

    -- Restore pause before cursor/input state so ESC closes only this map overlay.
    setGamePausedForLargeMap(false)
    setLargeMapCursorVisible(false)

    if reason and reason ~= "" then
        log("Large map closed (" .. reason .. ")")
    else
        log("Large map closed")
    end

    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end
scheduleMapWork = function(delayMs, restartLoop)
    if isMapActive() then
        if overlay.canvas:IsValid() then
            if restartLoop then
                restartUpdateLoop()
            else
                startUpdateLoop()
            end
            requestUpdate()
        else
            scheduleAttachAttempt(delayMs or Config.AttachInitialDelayMs or 250)
        end
        return
    end

    cancelAttachAttempt()
    stopUpdateLoop()
    if needsHiddenApply() then requestUpdate() end
end

local function translateModifiers(modifierNames)
    local translated = {}
    if type(modifierNames) ~= "table" then return translated end

    for _, modifierName in ipairs(modifierNames) do
        local modifier = ModifierKey[modifierName]
        if modifier then
            translated[#translated + 1] = modifier
        else
            log("Invalid modifier in config: " .. tostring(modifierName))
        end
    end

    return translated
end


-- Optional compatibility with SN2ModSettings SharedVariable values.
local function pushSharedSetting(key, value)
    -- Use rawget so UE4SS does not throw "Global for __index doesn't exist" when ModRef is unavailable.
    local modRef = rawget(_G, "ModRef")
    if not modRef then
        return false
    end

    local ok, err = pcall(function()
        if not modRef.SetSharedVariable then
            return
        end

        modRef:SetSharedVariable("SN2ModSettings/SN2-POI-Map/" .. key, value)
    end)

    if not ok then
        log("SharedVariable push failed for " .. tostring(key) .. ": " .. tostring(err))
        return false
    end

    return true
end

local function registerConfiguredKey(label, keyName, modifierNames, callback)
    if not keyName or keyName == "" then return end

    local key = Key[keyName]
    if not key then
        log("Invalid key for " .. label .. ": " .. tostring(keyName))
        return
    end

    local modifiers = translateModifiers(modifierNames)
    if #modifiers > 0 then
        RegisterKeyBind(key, modifiers, callback)
    else
        RegisterKeyBind(key, callback)
    end

    log(label .. " bind: " .. keyName)
end

registerConfiguredKey("OpenMap", Config.OpenMapKey, Config.OpenMapModifiers, function()
    if not poiCanUseMapOverlay() then return end

    if largeMapOpen then
        closeLargeMap("")
        return
    end

    largeMapOpen = true
    largeMapViewU = nil
    largeMapViewV = nil
    setLargeMapCursorVisible(true)
    setGamePausedForLargeMap(true)

    log("Large map opened")
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end)

RegisterKeyBind(Key.ESCAPE, function()
    closeLargeMap("ESC")
end)

registerConfiguredKey("HideMap", Config.HideMapKey, Config.HideMapModifiers, function()
    if not poiCanUseMapOverlay() then return end

    local newVisible = not (mapVisible and Config.Minimap.Enabled ~= false)

    mapVisible = newVisible
    Config.Minimap.Enabled = newVisible

    if not mapVisible then closeLargeMap("") end

    pushSharedSetting("MinimapEnabled", newVisible)

    log("Minimap " .. (mapVisible and "shown" or "hidden"))
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end)

function adjustZoom(zoomIn)
    if not poiCanUseMapOverlay() then return end

    local layout = largeMapOpen and Config.LargeMap or (mapVisible and Config.Minimap or nil)
    if not layout then return end

    local step = layout.ZoomStep or 0.5
    local delta = zoomIn and step or -step
    local zmin = layout.ZoomMin or 1.0
    local zmax = layout.ZoomMax or (largeMapOpen and 8.0 or 12.0)

    if largeMapOpen then
        largeMapZoom = clamp(largeMapZoom + delta, zmin, zmax)
        log(string.format("Large map zoom: %.2f", largeMapZoom))
    else
        minimapZoom = clamp(minimapZoom + delta, zmin, zmax)
        log(string.format("Minimap zoom: %.2f", minimapZoom))
    end

    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end

registerConfiguredKey("ZoomIn", Config.ZoomInKey, Config.ZoomInModifiers, function()
    adjustZoom(true)
end)

registerConfiguredKey("ZoomOut", Config.ZoomOutKey, Config.ZoomOutModifiers, function()
    adjustZoom(false)
end)

function adjustPan(du, dv)
    if not poiCanUseMapOverlay() then return end
    if not largeMapOpen then return end
    if largeMapViewU == nil or largeMapViewV == nil then return end

    local zoom = largeMapZoom
    if not zoom or zoom < 1.0 then zoom = 1.0 end
    local step = ((Config.LargeMap and Config.LargeMap.PanStep) or 0.25) / zoom

    largeMapViewU = clamp(largeMapViewU + du * step, 0.0, 1.0)
    largeMapViewV = clamp(largeMapViewV + dv * step, 0.0, 1.0)
    markOverlayStateDirty(true)
    scheduleMapWork(0, true)
end

registerConfiguredKey("PanUp", Config.PanUpKey, Config.PanUpModifiers, function()
    adjustPan(0, -1)
end)

registerConfiguredKey("PanDown", Config.PanDownKey, Config.PanDownModifiers, function()
    adjustPan(0, 1)
end)

registerConfiguredKey("PanLeft", Config.PanLeftKey, Config.PanLeftModifiers, function()
    adjustPan(-1, 0)
end)

registerConfiguredKey("PanRight", Config.PanRightKey, Config.PanRightModifiers, function()
    adjustPan(1, 0)
end)

if Key.LEFT_MOUSE_BUTTON then
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function()
        if not poiCanUseMapOverlay() then return end
        togglePoiCategoryAtMousePosition()
    end)
    log("POI category row click bind: LEFT_MOUSE_BUTTON")
else
    log("POI category row click bind unavailable: LEFT_MOUSE_BUTTON key not found")
end

safeCall("Register ClientRestart hook", function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        scheduleMapWork(Config.AttachInitialDelayMs or 250, true)
    end)
end)

safeCall("Register SaveHandle Store hook", function()
    RegisterHook("/Script/UWESaveSystem.UWESaveHandle:Store", function()
        fogRuntime.scheduleSaveStateFlush("game save")
    end)
end)

RegisterLoadMapPostHook(function()
    if fogSaveDirty then
        safeCall("Fog save on map change", saveFogState)
        fogSaveDirty = false
    end

    stopUpdateLoop()
    cancelAttachAttempt()
    if isFogEnabled() then fogRuntime.reloadForCurrentSave() end
    poiRuntime.reloadCategoryStateForCurrentSave()
    resetOverlay()
    scheduleMapWork(Config.AttachInitialDelayMs or 250, true)
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function()
            safeCall("Sync active save slot (1s after load)", function()
                fogRuntime.promoteTransientSlotIfReady()
            end)
        end)
    end)
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            safeCall("Sync active save slot (3s after load)", function()
                fogRuntime.promoteTransientSlotIfReady()
            end)
        end)
    end)
end)

if isFogEnabled() then
    fogRuntime.reloadForCurrentSave()
end


local function getSharedSetting(key, fallback)
    -- Use rawget so UE4SS does not throw "Global for __index doesn't exist" when ModRef is unavailable.
    local modRef = rawget(_G, "ModRef")
    if not modRef then
        return fallback
    end

    local ok, value = pcall(function()
        if not modRef.GetSharedVariable then
            return nil
        end

        return modRef:GetSharedVariable("SN2ModSettings/SN2-POI-Map/" .. key)
    end)

    if not ok or value == nil then
        return fallback
    end

    if type(value) ~= type(fallback) then
        return fallback
    end

    return value
end

local function applyBasicModSettings()
    local changed = false
    local value = nil

    value = getSharedSetting("LogLevel", Config.Debug.LogLevel or "Info")
    if value == "Off" or value == "Error" or value == "Warning" or value == "Info" or value == "Verbose" then
        Config.Debug.LogLevel = value
    end

    value = getSharedSetting("MinimapEnabled", Config.Minimap.Enabled)
    if Config.Minimap.Enabled ~= value or mapVisible ~= value then
        Config.Minimap.Enabled = value
        mapVisible = value
        if not mapVisible then largeMapOpen = false end
        changed = true
        log("Setting applied: Minimap.Enabled = " .. tostring(value), "Verbose")
    end

    value = getSharedSetting("ShowMinimapAtStartup", Config.ShowMinimapAtStartup)
    if Config.ShowMinimapAtStartup ~= value then
        Config.ShowMinimapAtStartup = value
        changed = true
        log("Setting applied: ShowMinimapAtStartup = " .. tostring(value), "Verbose")
    end

    value = normalizeMinimapAnchor(getSharedSetting("MinimapAnchor", Config.Minimap.Anchor))
    if Config.Minimap.Anchor ~= value then
        Config.Minimap.Anchor = value
        changed = true
        log("Setting applied: Minimap.Anchor = " .. tostring(value), "Verbose")
    end

    value = getSharedSetting("FogOfWarEnabled", Config.FogOfWar.Enabled)
    if Config.FogOfWar.Enabled ~= value then
        Config.FogOfWar.Enabled = value
        changed = true
        log("Setting applied: FogOfWar.Enabled = " .. tostring(value), "Verbose")
        if value then
            fogRuntime.reloadForCurrentSave()
        else
            fogTexture = CreateInvalidObject()
            fogDirty = false
        end
    end

    value = clamp(getSharedSetting("MinimapWidth", Config.Minimap.Width), 180, 720)
    if Config.Minimap.Width ~= value then
        Config.Minimap.Width = value
        changed = true
        log("Setting applied: Minimap.Width = " .. tostring(value), "Verbose")
    end

    value = clamp(quantize(getSharedSetting("MinimapMarginTop", Config.Minimap.MarginTop), 1), 0, 240)
    if Config.Minimap.MarginTop ~= value then
        Config.Minimap.MarginTop = value
        changed = true
        log("Setting applied: Minimap.MarginTop = " .. tostring(value), "Verbose")
    end

    value = clamp(quantize(getSharedSetting("MinimapMarginRight", Config.Minimap.MarginRight), 1), 0, 240)
    if Config.Minimap.MarginRight ~= value then
        Config.Minimap.MarginRight = value
        changed = true
        log("Setting applied: Minimap.MarginRight = " .. tostring(value), "Verbose")
    end

    value = clamp(getSharedSetting("MinimapBackgroundAlpha", Config.Minimap.BackgroundAlpha), 0.0, 1.0)
    if Config.Minimap.BackgroundAlpha ~= value then
        Config.Minimap.BackgroundAlpha = value
        changed = true
        log("Setting applied: Minimap.BackgroundAlpha = " .. tostring(value), "Verbose")
    end

    value = clamp(getSharedSetting("MinimapMapAlpha", Config.Minimap.MapAlpha), 0.1, 1.0)
    if Config.Minimap.MapAlpha ~= value then
        Config.Minimap.MapAlpha = value
        changed = true
        log("Setting applied: Minimap.MapAlpha = " .. tostring(value), "Verbose")
    end

    value = clamp(quantize(getSharedSetting("MarkerSize", Config.Marker.Size), 1), 8, 24)
    if Config.Marker.Size ~= value then
        Config.Marker.Size = value
        changed = true
        log("Setting applied: Marker.Size = " .. tostring(value), "Verbose")
    end

    value = getSharedSetting("MarkerColorPreset", Config.Marker.ColorPreset or "Green")
    if Config.Marker.ColorPreset ~= value then
        applyMarkerColorPreset(value)
        changed = true
        log("Setting applied: Marker.ColorPreset = " .. tostring(Config.Marker.ColorPreset), "Verbose")
    end

    value = getSharedSetting("ShowOtherPlayers", Config.Multiplayer.ShowOtherPlayers)
    if Config.Multiplayer.ShowOtherPlayers ~= value then
        Config.Multiplayer.ShowOtherPlayers = value
        changed = true
        log("Setting applied: Multiplayer.ShowOtherPlayers = " .. tostring(value), "Verbose")
    end

    value = clamp(quantize(getSharedSetting("OtherPlayerMarkerSize", Config.Multiplayer.OtherPlayerMarkerSize), 1), 7, 12)
    if Config.Multiplayer.OtherPlayerMarkerSize ~= value then
        Config.Multiplayer.OtherPlayerMarkerSize = value
        changed = true
        log("Setting applied: Multiplayer.OtherPlayerMarkerSize = " .. tostring(value), "Verbose")
    end

    value = clamp(quantize(getSharedSetting("FogRevealRadius", Config.FogOfWar.RevealRadius), 1), 1, 4)
    if Config.FogOfWar.RevealRadius ~= value then
        Config.FogOfWar.RevealRadius = value
        changed = true
        log("Setting applied: FogOfWar.RevealRadius = " .. tostring(value), "Verbose")
    end

    value = clamp(getSharedSetting("FogAlpha", Config.FogOfWar.FogAlpha), 0.0, 1.0)
    if Config.FogOfWar.FogAlpha ~= value then
        Config.FogOfWar.FogAlpha = value
        fogDirty = true
        fogTexture = CreateInvalidObject()
        changed = true
        log("Setting applied: FogOfWar.FogAlpha = " .. tostring(value), "Verbose")
        if isFogEnabled() then
            flushFogVisual()
        end
    end

    value = clamp(quantize(getSharedSetting("FogVisualThrottleMs", Config.FogOfWar.VisualThrottleMs), 1), 100, 3000)
    if Config.FogOfWar.VisualThrottleMs ~= value then
        Config.FogOfWar.VisualThrottleMs = value
        changed = true
        log("Setting applied: FogOfWar.VisualThrottleMs = " .. tostring(value), "Verbose")
    end

    value = clamp(quantize(getSharedSetting("FogSaveThrottleMs", Config.FogOfWar.SaveThrottleMs), 1), 1000, 60000)
    if Config.FogOfWar.SaveThrottleMs ~= value then
        Config.FogOfWar.SaveThrottleMs = value
        changed = true
        log("Setting applied: FogOfWar.SaveThrottleMs = " .. tostring(value), "Verbose")
    end

    if changed then
        markOverlayStateDirty(true)
        scheduleMapWork(0, true)
    end
end

local function gameThreadLoopTick()
    applyBasicModSettings()

    fogRuntime.slotPollCountdown = (fogRuntime.slotPollCountdown or 0)
    if fogRuntime.slotPollCountdown <= 0 then
        fogRuntime.slotPollCountdown = 120
        safeCall("Promote transient fog save slot", function()
            fogRuntime.promoteTransientSlotIfReady()
        end)
    else
        fogRuntime.slotPollCountdown = fogRuntime.slotPollCountdown - 1
    end

    if poiIsGameplayWorld() and isFogEnabled() and os and os.time then
        local intervalMs = ((Config.FogOfWar or {}).AutoSaveIntervalMs) or 300000
        if intervalMs > 0 then
            local intervalSeconds = math.max(60, math.floor((intervalMs / 1000) + 0.5))
            local now = os.time()
            if not fogRuntime.nextAutoSaveAt then
                fogRuntime.nextAutoSaveAt = now + intervalSeconds
            elseif now >= fogRuntime.nextAutoSaveAt then
                fogRuntime.nextAutoSaveAt = now + intervalSeconds
                safeCall("Periodic fog state save", function()
                    fogRuntime.scheduleSaveStateFlush("interval")
                end)
            end
        end
    end

    local active = isMapActive()
    local hiddenApply = needsHiddenApply()
    if not active and not hiddenApply then
        updateLoopActive = false
        updateRequested = false
        return
    end

    if updateLoopActive or updateRequested or hiddenApply then
        updateRequested = false
        gameThreadUpdateSafe()
    end
end

local function backgroundLoopTick()
    ExecuteInGameThread(gameThreadLoopTick)
end

LoopAsync(Config.UpdateIntervalMs or 250, backgroundLoopTick)


scheduleMapWork(Config.AttachInitialDelayMs or 250, true)
log("Loaded. UMG rendering active. M opens/closes the large map, H hides/shows the minimap, POI panel rows toggle categories/all.")

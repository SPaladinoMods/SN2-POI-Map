local Config = require("config")

local lang = {}

local listeners = {}
local missingKeysLogged = {}

local english = {}
local active = {}
local rawCultureCode = "en"
local selectedCultureCode = "en"
local resolvedCultureCode = "en"
local cultureCandidates = { "en" }
local resolvedLanguagePath = nil

local OPTION_GROUPS = {
    log_level = { "Off", "Error", "Warning", "Info", "Verbose" },
    minimap_anchor = { "TopLeft", "TopRight", "BottomLeft", "BottomRight" },
    marker_color_preset = { "White", "Cyan", "Blue", "Green", "Yellow", "Orange", "Red", "Purple", "Pink" },
}

local function log(message)
    print(string.format("[SN2-POI-Map][Lang] %s\n", tostring(message)))
end

local function normalizePath(path)
    return (tostring(path or ""):gsub("/", "\\"))
end

local function joinPath(basePath, fileName)
    return normalizePath(basePath):gsub("[\\/]+$", "") .. "\\" .. tostring(fileName or "")
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
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
    if type(fileName) ~= "string" or fileName == "" then return fileName end
    if fileName:match("^%a:[/\\]") or fileName:match("^[/\\][/\\]") then
        return normalizePath(fileName)
    end

    local scriptAssetRoot = getScriptAssetRoot()
    if not scriptAssetRoot then return normalizePath(fileName) end

    return joinPath(scriptAssetRoot, fileName)
end

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalizeCulture(code)
    local text = trim(code)
    if text == "" then return "en" end
    text = text:gsub("_", "-")
    return text
end

local function appendUnique(list, seen, value)
    if value and value ~= "" then
        local key = value:lower()
        if not seen[key] then
            seen[key] = true
            list[#list + 1] = value
        end
    end
end

local function buildCultureCandidates(code)
    local normalized = normalizeCulture(code)
    local list = {}
    local seen = {}
    local segments = {}

    for segment in normalized:gmatch("[^-]+") do
        segments[#segments + 1] = segment
    end

    for i = #segments, 1, -1 do
        appendUnique(list, seen, table.concat(segments, "-", 1, i))
    end
    appendUnique(list, seen, "en")

    return list
end

local function loadLanguageFile(code)
    local relativePath = joinPath("Languages", code .. ".lua")
    local absolutePath = getAssetPath(relativePath)
    if not absolutePath or not fileExists(absolutePath) then
        return nil, absolutePath
    end

    local chunk, loadErr = loadfile(absolutePath)
    if not chunk then
        log("Failed to compile language file: " .. tostring(absolutePath) .. " (" .. tostring(loadErr) .. ")")
        return nil, absolutePath
    end

    local ok, result = pcall(chunk)
    if not ok or type(result) ~= "table" then
        log("Failed to execute language file: " .. tostring(absolutePath) .. " (" .. tostring(result) .. ")")
        return nil, absolutePath
    end

    return result, absolutePath
end

local function getConfiguredOverride()
    local localizationConfig = (Config or {}).Localization or {}
    local value = trim(localizationConfig.Language or "auto")
    if value == "" or value:lower() == "auto" then
        return nil
    end
    return normalizeCulture(value)
end

local kil = nil
local okFind, resultFind = pcall(function()
    return StaticFindObject("/Script/Engine.Default__KismetInternationalizationLibrary")
end)
if okFind and resultFind then
    kil = resultFind
end

local function detectGameCulture()
    if not kil then return "en" end

    local ok, code = pcall(function()
        local value = kil:GetCurrentLanguage()
        if value and value.ToString then
            return value:ToString()
        end
        return value
    end)

    if not ok or not code or code == "" then
        return "en"
    end

    return normalizeCulture(code)
end

local function notifyListeners()
    for _, listener in ipairs(listeners) do
        local ok, err = pcall(listener, lang)
        if not ok then
            log("Refresh listener failed: " .. tostring(err))
        end
    end
end

function lang.addRefreshListener(callback)
    if type(callback) ~= "function" then return end
    listeners[#listeners + 1] = callback
end

function lang.getRawCultureCode()
    return rawCultureCode
end

function lang.getSelectedCultureCode()
    return selectedCultureCode
end

function lang.getResolvedCultureCode()
    return resolvedCultureCode
end

function lang.getResolvedLanguagePath()
    return resolvedLanguagePath
end

function lang.getCultureCandidates()
    return cultureCandidates
end

function lang.refresh()
    local overrideCulture = getConfiguredOverride()
    local detectedCulture = detectGameCulture()
    local targetCulture = overrideCulture or detectedCulture or "en"
    local candidates = buildCultureCandidates(targetCulture)

    local nextActive = english
    local nextResolvedCode = "en"
    local nextResolvedPath = resolvedLanguagePath

    for _, code in ipairs(candidates) do
        local data, path = loadLanguageFile(code)
        if data then
            nextActive = data
            nextResolvedCode = code
            nextResolvedPath = path
            break
        end
    end

    local changed = rawCultureCode ~= detectedCulture
        or selectedCultureCode ~= targetCulture
        or resolvedCultureCode ~= nextResolvedCode
        or resolvedLanguagePath ~= nextResolvedPath

    rawCultureCode = detectedCulture
    selectedCultureCode = targetCulture
    resolvedCultureCode = nextResolvedCode
    resolvedLanguagePath = nextResolvedPath
    cultureCandidates = candidates
    active = nextActive

    if changed then
        log("Raw culture: " .. tostring(rawCultureCode))
        log("Selected culture: " .. tostring(selectedCultureCode))
        log("Resolved culture: " .. tostring(resolvedCultureCode))
        log("Language file: " .. tostring(resolvedLanguagePath or "(embedded fallback)"))
        notifyListeners()
    end

    return changed
end

function lang.lookup(key, fallback, ...)
    local entry = active[key]
    if entry == nil then
        entry = english[key]
    end

    if entry == nil then
        if not missingKeysLogged[key] then
            missingKeysLogged[key] = true
            log("Missing translation key: " .. tostring(key))
        end
        return fallback or key
    end

    if type(entry) == "function" then
        return entry(...)
    end

    if select("#", ...) > 0 then
        return string.format(entry, ...)
    end

    return entry
end

function lang.L(key, ...)
    return lang.lookup(key, key, ...)
end

function lang.getOptionLabel(groupName, token)
    local key = string.format("option_%s_%s", tostring(groupName), tostring(token))
    local value = active[key] or english[key]
    return value or tostring(token)
end

function lang.decodeOptionLabel(groupName, value)
    if value == nil then return nil end
    if type(value) ~= "string" then return value end

    local options = OPTION_GROUPS[groupName]
    if not options then return value end

    local trimmed = trim(value)
    if trimmed == "" then return trimmed end

    for _, token in ipairs(options) do
        if trimmed == token then
            return token
        end

        local label = lang.getOptionLabel(groupName, token)
        if trimmed:lower() == tostring(label):lower() then
            return token
        end
    end

    return value
end

function lang.resolveAssetPath(relativePath)
    if type(relativePath) ~= "string" or relativePath == "" then
        return relativePath
    end

    local candidateCodes = cultureCandidates or { "en" }
    for _, code in ipairs(candidateCodes) do
        if code ~= "en" then
            local localizedRelative = joinPath(joinPath("Languages", code), relativePath)
            local localizedPath = getAssetPath(localizedRelative)
            if localizedPath and fileExists(localizedPath) then
                return localizedPath
            end
        end
    end

    return getAssetPath(relativePath)
end

local localizationConfig = (Config or {}).Localization or {}
local startupDelayMs = tonumber(localizationConfig.StartupRefreshDelayMs) or 3000
local applySettingsDelayMs = tonumber(localizationConfig.ApplySettingsRefreshDelayMs) or 750
local pollIntervalMs = tonumber(localizationConfig.PollIntervalMs) or 1000

english = loadLanguageFile("en") or {}
active = english
resolvedLanguagePath = getAssetPath(joinPath("Languages", "en.lua"))
lang.refresh()

ExecuteWithDelay(startupDelayMs, function()
    ExecuteInGameThread(function()
        lang.refresh()
    end)
end)

local applySettingsPath = "/Script/Subnautica2.SN2SettingsViewModel:ApplySettings"
local applySettingsObject = StaticFindObject(applySettingsPath)
if applySettingsObject then
    RegisterHook(applySettingsPath, function()
        lang.refresh()
        ExecuteWithDelay(applySettingsDelayMs, function()
            ExecuteInGameThread(function()
                lang.refresh()
            end)
        end)
    end)
end

LoopAsync(pollIntervalMs, function()
    ExecuteInGameThread(function()
        lang.refresh()
    end)
end)

return lang

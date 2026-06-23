local source = debug and debug.getinfo and debug.getinfo(1, "S").source or nil
local basePath = source and source:sub(1, 1) == "@" and source:sub(2):gsub("[/\\][^/\\]+$", "") or nil

if not basePath then
    return {}
end

local chunk = loadfile(basePath .. "\\es-419.lua")
if not chunk then
    return {}
end

local ok, result = pcall(chunk)
if ok and type(result) == "table" then
    return result
end

return {}

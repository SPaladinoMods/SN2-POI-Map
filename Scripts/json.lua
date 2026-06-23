local Json = {}

local function decode_error(text, pos, message)
    error(string.format("JSON decode error at byte %d: %s", pos or 0, message), 0)
end

local function is_space(char)
    return char == " " or char == "\t" or char == "\r" or char == "\n"
end

local function skip_space(text, pos)
    local len = #text
    while pos <= len and is_space(text:sub(pos, pos)) do
        pos = pos + 1
    end
    return pos
end

local function parse_value(text, pos)
    pos = skip_space(text, pos)
    local char = text:sub(pos, pos)

    if char == "{" then
        return Json._parse_object(text, pos)
    elseif char == "[" then
        return Json._parse_array(text, pos)
    elseif char == '"' then
        return Json._parse_string(text, pos)
    elseif char == "-" or char:match("%d") then
        return Json._parse_number(text, pos)
    elseif text:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif text:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif text:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    end

    decode_error(text, pos, "unexpected value")
end

function Json._parse_string(text, pos)
    pos = pos + 1
    local len = #text
    local pieces = {}
    local start = pos

    while pos <= len do
        local char = text:sub(pos, pos)
        if char == '"' then
            pieces[#pieces + 1] = text:sub(start, pos - 1)
            return table.concat(pieces), pos + 1
        elseif char == "\\" then
            pieces[#pieces + 1] = text:sub(start, pos - 1)
            local escape = text:sub(pos + 1, pos + 1)
            if escape == '"' or escape == "\\" or escape == "/" then
                pieces[#pieces + 1] = escape
                pos = pos + 2
            elseif escape == "b" then
                pieces[#pieces + 1] = "\b"
                pos = pos + 2
            elseif escape == "f" then
                pieces[#pieces + 1] = "\f"
                pos = pos + 2
            elseif escape == "n" then
                pieces[#pieces + 1] = "\n"
                pos = pos + 2
            elseif escape == "r" then
                pieces[#pieces + 1] = "\r"
                pos = pos + 2
            elseif escape == "t" then
                pieces[#pieces + 1] = "\t"
                pos = pos + 2
            elseif escape == "u" then
                local hex = text:sub(pos + 2, pos + 5)
                local code = tonumber(hex, 16)
                if not code then decode_error(text, pos, "invalid unicode escape") end
                if code < 128 then
                    pieces[#pieces + 1] = string.char(code)
                elseif utf8 and utf8.char then
                    pieces[#pieces + 1] = utf8.char(code)
                else
                    pieces[#pieces + 1] = "?"
                end
                pos = pos + 6
            else
                decode_error(text, pos, "invalid escape sequence")
            end
            start = pos
        else
            pos = pos + 1
        end
    end

    decode_error(text, pos, "unterminated string")
end

function Json._parse_number(text, pos)
    local start = pos
    local len = #text

    if text:sub(pos, pos) == "-" then pos = pos + 1 end
    while pos <= len and text:sub(pos, pos):match("%d") do pos = pos + 1 end
    if text:sub(pos, pos) == "." then
        pos = pos + 1
        while pos <= len and text:sub(pos, pos):match("%d") do pos = pos + 1 end
    end
    local exp = text:sub(pos, pos)
    if exp == "e" or exp == "E" then
        pos = pos + 1
        local sign = text:sub(pos, pos)
        if sign == "+" or sign == "-" then pos = pos + 1 end
        while pos <= len and text:sub(pos, pos):match("%d") do pos = pos + 1 end
    end

    local number = tonumber(text:sub(start, pos - 1))
    if number == nil then decode_error(text, start, "invalid number") end
    return number, pos
end

function Json._parse_array(text, pos)
    local result = {}
    pos = skip_space(text, pos + 1)
    if text:sub(pos, pos) == "]" then return result, pos + 1 end

    while true do
        local value
        value, pos = parse_value(text, pos)
        result[#result + 1] = value
        pos = skip_space(text, pos)

        local char = text:sub(pos, pos)
        if char == "]" then
            return result, pos + 1
        elseif char ~= "," then
            decode_error(text, pos, "expected ',' or ']'")
        end
        pos = skip_space(text, pos + 1)
    end
end

function Json._parse_object(text, pos)
    local result = {}
    pos = skip_space(text, pos + 1)
    if text:sub(pos, pos) == "}" then return result, pos + 1 end

    while true do
        if text:sub(pos, pos) ~= '"' then decode_error(text, pos, "expected object key") end

        local key
        key, pos = Json._parse_string(text, pos)
        pos = skip_space(text, pos)
        if text:sub(pos, pos) ~= ":" then decode_error(text, pos, "expected ':'") end
        pos = skip_space(text, pos + 1)

        local value
        value, pos = parse_value(text, pos)
        result[key] = value
        pos = skip_space(text, pos)

        local char = text:sub(pos, pos)
        if char == "}" then
            return result, pos + 1
        elseif char ~= "," then
            decode_error(text, pos, "expected ',' or '}'")
        end
        pos = skip_space(text, pos + 1)
    end
end

function Json.decode(text)
    if type(text) ~= "string" then
        error("JSON decode expected a string", 0)
    end
    if text:sub(1, 3) == "\239\187\191" then
        text = text:sub(4)
    end

    local value, pos = parse_value(text, 1)
    pos = skip_space(text, pos)
    if pos <= #text then
        decode_error(text, pos, "trailing data")
    end
    return value
end

return Json

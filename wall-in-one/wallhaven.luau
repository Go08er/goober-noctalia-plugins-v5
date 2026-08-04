--!nonstrict
-- Wall-in-One Wallhaven API v1 provider.
--
-- The public API is intentionally kept behind a small state protocol. The
-- service accepts one operation at a time, never places an API key in a URL,
-- bounds every response before decoding it, and only downloads media that was
-- returned by the current result set. It does not own deletion policy.

local SCHEMA = 1
local COMMAND_KEY = "wall_in_one_wallhaven_command_v1"
local STATUS_KEY = "wall_in_one_wallhaven_status_v1"
local RESULTS_KEY = "wall_in_one_wallhaven_results_v1"

-- Wallhaven's official API documentation publishes this origin and prefix.
-- There is no supported api.wallhaven.cc hostname as of this implementation.
local API_ORIGIN = "https://wallhaven.cc"
local API_PREFIX = "/api/v1"
local SITE_ORIGIN = "https://wallhaven.cc"
local SHORT_ORIGIN = "https://whvn.cc"
local CDN_ORIGIN = "https://w.wallhaven.cc"
local THUMB_ORIGIN = "https://th.wallhaven.cc"

local MAX_NONCE = 9007199254740991
local MAX_BODY_BYTES = 512 * 1024
local MAX_RESULTS = 24
local MAX_TAGS = 48
local MAX_QUERY_BYTES = 256
local MAX_TEXT_BYTES = 512
local MAX_URL_BYTES = 2048
local MAX_PATH_BYTES = 4000
local MAX_PAGE = 10000
local MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
local MIN_API_INTERVAL_SECONDS = 2
local API_FETCH_TIMEOUT_MS = 40 * 1000
local MEDIA_FETCH_TIMEOUT_MS = 130 * 1000
local IMAGE_VALIDATION_TIMEOUT_MS = 60 * 1000
local FETCH_PROTOCOL = "WIO-FETCH1"

-- Download destinations are coordinator-owned. Commands travel through
-- plugin-global state, so the provider must independently derive the only
-- directory it is willing to write rather than trusting paths in that state.
local MANAGED_PARENT_DIRECTORY = "Wall-in-One"
local MANAGED_WALLHAVEN_DIRECTORY = "Wallhaven"
local MANAGED_MARKER_NAME = ".managed-by-wall-in-one-v1.json"
local MAX_MANAGED_MARKER_BYTES = 16 * 1024

local SORTING_VALUES = {
    date_added = true,
    relevance = true,
    random = true,
    views = true,
    favorites = true,
    toplist = true,
    hot = true,
}

local ORDER_VALUES = {
    asc = true,
    desc = true,
}

local TOP_RANGE_VALUES = {
    ["1d"] = true,
    ["3d"] = true,
    ["1w"] = true,
    ["1M"] = true,
    ["3M"] = true,
    ["6M"] = true,
    ["1y"] = true,
}

local COLOR_VALUES = {
    ["660000"] = true,
    ["990000"] = true,
    ["cc0000"] = true,
    ["cc3333"] = true,
    ["ea4c88"] = true,
    ["993399"] = true,
    ["663399"] = true,
    ["333399"] = true,
    ["0066cc"] = true,
    ["0099cc"] = true,
    ["66cccc"] = true,
    ["77cc33"] = true,
    ["669900"] = true,
    ["336600"] = true,
    ["666600"] = true,
    ["999900"] = true,
    ["cccc33"] = true,
    ["ffff00"] = true,
    ["ffcc33"] = true,
    ["ff9900"] = true,
    ["ff6600"] = true,
    ["cc6633"] = true,
    ["996633"] = true,
    ["663300"] = true,
    ["000000"] = true,
    ["999999"] = true,
    ["cccccc"] = true,
    ["ffffff"] = true,
    ["424153"] = true,
}

local statusSequence = 0
local resultsSequence = 0
local lastStatusFingerprint = ""
local lastApiStart = 0
local activeOperation = nil
local running = true
local operationGeneration = 1
local transportSequence = 0
local boundedFetchHelper

local status = {
    schema = SCHEMA,
    sequence = 0,
    ready = true,
    running = true,
    available = false,
    authenticated = false,
    api_origin = API_ORIGIN,
    busy = false,
    active_action = "",
    active_nonce = 0,
    active_id = "",
    last_nonce = 0,
    last_completed_nonce = 0,
    last_action = "",
    last_error = "",
    last_error_kind = "",
    configuration_error = "",
    last_request_at = "",
    last_success_at = "",
    last_download = {},
    updated_at = "",
}

local results = {
    schema = SCHEMA,
    sequence = 0,
    nonce = 0,
    kind = "empty",
    source_url = SITE_ORIGIN,
    filters = {},
    meta = {},
    items = {},
    selected = {},
}

local previousStatus = noctalia.state.get(STATUS_KEY)
if type(previousStatus) == "table" then
    local previousSequence = math.floor(tonumber(previousStatus.sequence) or 0)
    if previousSequence >= 0 and previousSequence <= MAX_NONCE then
        statusSequence = previousSequence
    end
    local previousNonce = math.floor(tonumber(previousStatus.last_nonce) or 0)
    if previousNonce >= 0 and previousNonce <= MAX_NONCE then
        status.last_nonce = previousNonce
    end
    local previousCompleted = math.floor(tonumber(previousStatus.last_completed_nonce) or 0)
    if previousCompleted >= 0 and previousCompleted <= MAX_NONCE then
        status.last_completed_nonce = previousCompleted
    end
end

local previousResults = noctalia.state.get(RESULTS_KEY)
if type(previousResults) == "table" then
    local previousSequence = math.floor(tonumber(previousResults.sequence) or 0)
    if previousSequence >= 0 and previousSequence <= MAX_NONCE then
        resultsSequence = previousSequence
    end
end

-- Configuration and primitive validation ------------------------------------

local function nowSeconds()
    return math.floor(tonumber(noctalia.formatTime("%s")) or 0)
end

local function nowText()
    return noctalia.formatTime("%Y-%m-%d %H:%M:%S")
end

local function settingBool(key, fallback)
    local value = noctalia.getConfig(key)
    return if type(value) == "boolean" then value else fallback
end

local function settingString(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) ~= "string" or value:find("%S") == nil then
        return fallback
    end
    return value
end

local function boundedText(value, maximum)
    if type(value) ~= "string" then
        return ""
    end
    local text = value:gsub("[%c]", " ")
    text = noctalia.string.trim(text)
    if #text > maximum then
        text = text:sub(1, maximum)
    end
    return text
end

local function validAbsolutePath(value)
    return type(value) == "string"
        and #value > 1
        and #value <= MAX_PATH_BYTES
        and value:sub(1, 1) == "/"
        and value:sub(-1) ~= "/"
        and not value:find("[%c\\]")
        and not value:find("//", 1, true)
        and not value:find("/./", 1, true)
        and not value:find("/../", 1, true)
        and not value:match("/%.%.$")
        and not value:match("/%.$")
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function apiKey()
    local value = noctalia.getConfig("wallhaven_api_key")
    if value == nil or value == "" then
        return "", nil
    end
    if type(value) ~= "string" then
        return "", "The Wallhaven API key setting must be text"
    end
    local key = noctalia.string.trim(value)
    if key == "" then
        return "", nil
    end
    if #key > 256 or key:find("[%c:]") or not key:match("^[%w_-]+$") then
        return "", "The Wallhaven API key setting contains unsupported characters"
    end
    return key, nil
end

local function validNonce(value)
    local nonce = tonumber(value)
    if nonce == nil or nonce < 1 or nonce > MAX_NONCE or nonce ~= math.floor(nonce) then
        return nil
    end
    return nonce
end

local function validWallpaperId(value)
    if type(value) ~= "string" then
        return nil
    end
    local id = value:lower()
    if #id ~= 6 or not id:match("^[%l%d]+$") then
        return nil
    end
    return id
end

local function finiteInteger(value, fallback, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= number or number == math.huge or number == -math.huge then
        number = fallback
    end
    number = math.floor(number)
    return math.max(minimum, math.min(maximum, number))
end

local function urlEncode(value)
    local text = tostring(value or "")
    local encoded = {}
    local hex = "0123456789ABCDEF"
    for index = 1, #text do
        local byte = string.byte(text, index)
        local unreserved = (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
            or (byte >= 48 and byte <= 57)
            or byte == 45
            or byte == 46
            or byte == 95
            or byte == 126
        if unreserved then
            table.insert(encoded, string.char(byte))
        else
            local high = math.floor(byte / 16) + 1
            local low = (byte % 16) + 1
            table.insert(encoded, "%" .. hex:sub(high, high) .. hex:sub(low, low))
        end
    end
    return table.concat(encoded)
end

local captureRootExists

local function refreshAvailability()
    local key, keyError = apiKey()
    status.ready = running
    status.running = running
    status.authenticated = key ~= ""
    status.configuration_error = tostring(keyError or "")
    status.available = running
        and settingBool("use_wallhaven", true)
        and keyError == nil
        and captureRootExists()
        and noctalia.commandExists("curl")
        and boundedFetchHelper() ~= nil
end

-- Coordinator-owned storage -------------------------------------------------

local function normalizedDirectory(value)
    if type(value) ~= "string" or value == "" or #value > MAX_PATH_BYTES then
        return nil
    end
    value = value:gsub("/+$", "")
    if
        value == ""
        or value == "/"
        or value:sub(1, 1) ~= "/"
        or value:find("[%c\\]")
        or value:find("//", 1, true)
    then
        return nil
    end
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return nil
        end
    end
    return value
end

local function captureDirectory()
    local configured = settingString("capture_directory", "")
    if configured == "" then
        return nil
    end
    return normalizedDirectory(noctalia.expandPath(configured))
end

captureRootExists = function()
    local root = captureDirectory()
    local info = root ~= nil and noctalia.fileInfo(root) or nil
    return type(info) == "table" and info.isDir == true
end

local function wallhavenManagedDirectory()
    local root = captureDirectory()
    if root == nil then
        return nil, "The configured wallpaper image directory is not a safe absolute path"
    end
    local directory = root .. "/" .. MANAGED_PARENT_DIRECTORY .. "/" .. MANAGED_WALLHAVEN_DIRECTORY
    if #directory > MAX_PATH_BYTES then
        return nil, "The managed Wallhaven directory path is too long"
    end
    return directory, nil
end

local function validateManagedDirectory(directory)
    local directoryInfo = noctalia.fileInfo(directory)
    if type(directoryInfo) ~= "table" or directoryInfo.isDir ~= true then
        return false, "The coordinator-managed Wallhaven directory does not exist"
    end

    local markerPath = directory .. "/" .. MANAGED_MARKER_NAME
    local markerInfo = noctalia.fileInfo(markerPath)
    local markerBytes = type(markerInfo) == "table" and math.floor(tonumber(markerInfo.size) or 0) or 0
    if
        type(markerInfo) ~= "table"
        or markerInfo.isDir == true
        or markerBytes < 1
        or markerBytes > MAX_MANAGED_MARKER_BYTES
    then
        return false, "The managed Wallhaven directory has no valid ownership marker"
    end

    local raw = noctalia.readFile(markerPath)
    if type(raw) ~= "string" or #raw ~= markerBytes then
        return false, "The managed Wallhaven ownership marker could not be read"
    end
    local marker = noctalia.json.decode(raw)
    if
        type(marker) ~= "table"
        or tonumber(marker.schema) ~= 1
        or marker.plugin ~= "goober/wall-in-one"
        or marker.kind ~= "wallhaven"
        or marker.ownership ~= "managed"
    then
        return false, "The managed Wallhaven directory ownership marker is invalid"
    end
    return true, nil
end

-- State publication ----------------------------------------------------------

local function statusFingerprint()
    local encoded = noctalia.json.encode({
        ready = status.ready,
        running = status.running,
        available = status.available,
        authenticated = status.authenticated,
        api_origin = status.api_origin,
        busy = status.busy,
        active_action = status.active_action,
        active_nonce = status.active_nonce,
        active_id = status.active_id,
        last_nonce = status.last_nonce,
        last_completed_nonce = status.last_completed_nonce,
        last_action = status.last_action,
        last_error = status.last_error,
        last_error_kind = status.last_error_kind,
        configuration_error = status.configuration_error,
        last_request_at = status.last_request_at,
        last_success_at = status.last_success_at,
        last_download = status.last_download,
    })
    return tostring(encoded or "")
end

local function publishStatus(force)
    refreshAvailability()
    status.busy = type(activeOperation) == "table"
    status.active_action = if type(activeOperation) == "table" then tostring(activeOperation.action or "") else ""
    status.active_nonce = if type(activeOperation) == "table" then tonumber(activeOperation.nonce) or 0 else 0
    status.active_id = if type(activeOperation) == "table" and activeOperation.action == "download"
        then tostring(activeOperation.id or "")
        else ""

    local fingerprint = statusFingerprint()
    if force ~= true and fingerprint == lastStatusFingerprint then
        return false
    end
    lastStatusFingerprint = fingerprint
    statusSequence += 1
    status.sequence = statusSequence
    status.updated_at = nowText()
    noctalia.state.set(STATUS_KEY, status)
    return true
end

local function publishResults()
    resultsSequence += 1
    results.sequence = resultsSequence
    noctalia.state.set(RESULTS_KEY, results)
end

local function rejectCommand(nonce, action, kind, message)
    status.last_completed_nonce = math.max(status.last_completed_nonce, nonce)
    status.last_action = action
    status.last_error_kind = kind
    status.last_error = boundedText(message, MAX_TEXT_BYTES)
    publishStatus()
end

local function beginOperation(nonce, action, activeId)
    local operation = {
        nonce = nonce,
        action = action,
        id = if action == "download" then validWallpaperId(activeId) or "" else "",
        discarded = false,
        generation = operationGeneration,
    }
    activeOperation = operation
    status.last_action = action
    status.last_error = ""
    status.last_error_kind = ""
    publishStatus()
    return operation
end

local function operationIsCurrent(operation)
    return running
        and activeOperation == operation
        and operation.generation == operationGeneration
end

local function finishDiscarded(operation)
    if not operationIsCurrent(operation) then
        return true
    end
    if operation.discarded ~= true then
        return false
    end
    activeOperation = nil
    publishStatus()
    return true
end

local function finishOperationError(operation, kind, message)
    if not operationIsCurrent(operation) then
        return
    end
    activeOperation = nil
    status.last_completed_nonce = math.max(status.last_completed_nonce, operation.nonce)
    status.last_action = operation.action
    status.last_error_kind = kind
    status.last_error = boundedText(message, MAX_TEXT_BYTES)
    publishStatus()
end

local function finishOperationSuccess(operation)
    if not operationIsCurrent(operation) then
        return false
    end
    activeOperation = nil
    status.last_completed_nonce = math.max(status.last_completed_nonce, operation.nonce)
    status.last_action = operation.action
    status.last_error_kind = ""
    status.last_error = ""
    status.last_success_at = nowText()
    publishStatus()
    return true
end

-- Wallhaven URL and response normalization ----------------------------------

local function normalizedCdnUrl(value, expectedId)
    if type(value) ~= "string" or #value > MAX_URL_BYTES or value:find("[%c]") then
        return nil
    end
    local bucket, id, extension =
        value:match("^https://w%.wallhaven%.cc/full/([%l%d][%l%d])/wallhaven%-([%l%d]+)%.([%l%d]+)$")
    if id == nil or id ~= expectedId or bucket ~= expectedId:sub(1, 2) then
        return nil
    end
    extension = extension:lower()
    if extension ~= "jpg" and extension ~= "png" then
        return nil
    end
    return CDN_ORIGIN .. "/full/" .. bucket .. "/wallhaven-" .. id .. "." .. extension, extension
end

local function normalizedThumbUrl(value)
    if type(value) ~= "string" or #value > MAX_URL_BYTES or value:find("[%c?#]") then
        return ""
    end
    if value:sub(1, #THUMB_ORIGIN + 1) ~= THUMB_ORIGIN .. "/" then
        return ""
    end
    local path = value:sub(#THUMB_ORIGIN + 2)
    if path == "" or path:find("//", 1, true) or path:find("/%.?%./") or not path:match("^[%w%._/%-]+$") then
        return ""
    end
    return THUMB_ORIGIN .. "/" .. path
end

local function normalizedColors(value)
    local colors = {}
    if type(value) ~= "table" then
        return colors
    end
    for _, candidate in ipairs(value) do
        if #colors >= 8 then
            break
        end
        if type(candidate) == "string" then
            local color = candidate:lower()
            if color:match("^#[%da-f][%da-f][%da-f][%da-f][%da-f][%da-f]$") then
                table.insert(colors, color)
            end
        end
    end
    return colors
end

local function normalizedTags(value)
    local tags = {}
    if type(value) ~= "table" then
        return tags
    end
    for _, candidate in ipairs(value) do
        if #tags >= MAX_TAGS then
            break
        end
        if type(candidate) == "table" then
            local tagId = finiteInteger(candidate.id, 0, 0, MAX_NONCE)
            local name = boundedText(candidate.name, 160)
            if tagId > 0 and name ~= "" then
                table.insert(tags, {
                    id = tagId,
                    name = name,
                    alias = boundedText(candidate.alias, 160),
                    category = boundedText(candidate.category, 80),
                    purity = boundedText(candidate.purity, 16),
                })
            end
        end
    end
    return tags
end

local function normalizeWallpaper(value, includeDetail)
    if type(value) ~= "table" then
        return nil, "wallpaper result is not an object"
    end
    local id = validWallpaperId(value.id)
    if id == nil then
        return nil, "wallpaper result has an invalid ID"
    end
    local path, extension = normalizedCdnUrl(value.path, id)
    if path == nil then
        return nil, "wallpaper result has an unsupported media URL"
    end

    local fileType = boundedText(value.file_type, 32):lower()
    if (extension == "jpg" and fileType ~= "image/jpeg") or (extension == "png" and fileType ~= "image/png") then
        return nil, "wallpaper result file type does not match its URL"
    end

    local dimensionX = finiteInteger(value.dimension_x, 0, 0, 1000000)
    local dimensionY = finiteInteger(value.dimension_y, 0, 0, 1000000)
    local fileSize = finiteInteger(value.file_size, 0, 0, MAX_NONCE)
    local item = {
        id = id,
        url = SITE_ORIGIN .. "/w/" .. id,
        short_url = SHORT_ORIGIN .. "/" .. id,
        path = path,
        extension = extension,
        file_type = fileType,
        file_size = fileSize,
        views = finiteInteger(value.views, 0, 0, MAX_NONCE),
        favorites = finiteInteger(value.favorites, 0, 0, MAX_NONCE),
        purity = boundedText(value.purity, 16),
        category = boundedText(value.category, 32),
        dimension_x = dimensionX,
        dimension_y = dimensionY,
        resolution = if dimensionX > 0 and dimensionY > 0
            then tostring(dimensionX) .. "x" .. tostring(dimensionY)
            else boundedText(value.resolution, 32),
        ratio = boundedText(value.ratio, 32),
        source = boundedText(value.source, MAX_TEXT_BYTES),
        created_at = boundedText(value.created_at, 64),
        colors = normalizedColors(value.colors),
        thumbs = {},
    }

    if type(value.thumbs) == "table" then
        item.thumbs = {
            large = normalizedThumbUrl(value.thumbs.large),
            original = normalizedThumbUrl(value.thumbs.original),
            small = normalizedThumbUrl(value.thumbs.small),
        }
    end
    if includeDetail == true then
        item.tags = normalizedTags(value.tags)
        if type(value.uploader) == "table" then
            item.uploader = {
                username = boundedText(value.uploader.username, 80),
                group = boundedText(value.uploader.group, 40),
            }
        else
            item.uploader = {}
        end
    end
    return item, nil
end

local function findResult(id)
    for _, item in ipairs(results.items) do
        if type(item) == "table" and item.id == id then
            return item
        end
    end
    if type(results.selected) == "table" and results.selected.id == id then
        return results.selected
    end
    return nil
end

-- Search filters and HTTP ----------------------------------------------------

local function validatedBits(value, fallback, label)
    local bits = if value == nil or value == "" then fallback else tostring(value)
    if #bits ~= 3 or not bits:match("^[01][01][01]$") or bits == "000" then
        return nil, label .. " must be a three-bit Wallhaven mask"
    end
    return bits, nil
end

local function validatedResolution(value)
    if value == nil or value == "" then
        return "", nil
    end
    if type(value) ~= "string" or #value > 24 then
        return nil, "Minimum resolution must look like 1920x1080"
    end
    local width, height = value:match("^(%d+)x(%d+)$")
    width = tonumber(width)
    height = tonumber(height)
    if width == nil or height == nil or width < 1 or height < 1 or width > 100000 or height > 100000 then
        return nil, "Minimum resolution must look like 1920x1080"
    end
    return tostring(math.floor(width)) .. "x" .. tostring(math.floor(height)), nil
end

local function validatedResolutions(value)
    if value == nil or value == "" then
        return "", nil
    end
    if type(value) ~= "string" or #value > 192 or value:find("[%c%s]") then
        return nil, "Exact resolutions must be comma-separated values such as 1920x1080,2560x1440"
    end
    local resolutions = {}
    for token in value:gmatch("[^,]+") do
        if #resolutions >= 12 then
            return nil, "resolutions accepts at most twelve exact values"
        end
        local normalized = validatedResolution(token)
        if normalized == nil or normalized == "" then
            return nil, "Exact resolutions must be comma-separated values such as 1920x1080,2560x1440"
        end
        table.insert(resolutions, normalized)
    end
    if #resolutions == 0 or table.concat(resolutions, ",") ~= value then
        return nil, "Exact resolutions must be comma-separated values such as 1920x1080,2560x1440"
    end
    return table.concat(resolutions, ","), nil
end

local function validatedRatios(value)
    if value == nil or value == "" then
        return "", nil
    end
    if type(value) ~= "string" or #value > 96 or value:find("[%c%s]") then
        return nil, "ratios must be a comma-separated list such as 16x9,16x10"
    end
    local ratios = {}
    for token in value:gmatch("[^,]+") do
        if #ratios >= 8 then
            return nil, "ratios accepts at most eight values"
        end
        local width, height = token:match("^(%d+)x(%d+)$")
        width = tonumber(width)
        height = tonumber(height)
        if width == nil or height == nil or width < 1 or height < 1 or width > 1000 or height > 1000 then
            return nil, "ratios must be a comma-separated list such as 16x9,16x10"
        end
        table.insert(ratios, tostring(math.floor(width)) .. "x" .. tostring(math.floor(height)))
    end
    if #ratios == 0 or table.concat(ratios, ",") ~= value then
        return nil, "ratios must be a comma-separated list such as 16x9,16x10"
    end
    return table.concat(ratios, ","), nil
end

local function validatedColor(value)
    if value == nil or value == "" then
        return "", nil
    end
    if type(value) ~= "string" then
        return nil, "colors must be one of Wallhaven's documented color values"
    end
    local color = value:lower():gsub("^#", "")
    if not COLOR_VALUES[color] then
        return nil, "colors must be one of Wallhaven's documented color values"
    end
    return color, nil
end

local function validatedSearchFilters(command, hasApiKey)
    local supplied = if type(command.filters) == "table" then command.filters else command
    local query = if supplied.query == nil then "" else supplied.query
    if type(query) ~= "string" or #query > MAX_QUERY_BYTES or query:find("[%c]") then
        return nil, "query must be control-free text no longer than 256 bytes"
    end
    query = noctalia.string.trim(query)

    local categories, categoriesError = validatedBits(supplied.categories, "111", "categories")
    if categories == nil then
        return nil, categoriesError
    end
    local purity, purityError = validatedBits(supplied.purity, "100", "purity")
    if purity == nil then
        return nil, purityError
    end
    if purity:sub(3, 3) == "1" and not hasApiKey then
        return nil, "NSFW search requires a Wallhaven API key"
    end

    local sorting = tostring(supplied.sorting or "date_added"):lower()
    if not SORTING_VALUES[sorting] then
        return nil, "sorting is not supported by Wallhaven API v1"
    end
    local order = tostring(supplied.order or "desc"):lower()
    if not ORDER_VALUES[order] then
        return nil, "order must be asc or desc"
    end

    local atleast, atleastError = validatedResolution(supplied.atleast)
    if atleast == nil then
        return nil, atleastError
    end
    local resolutions, resolutionsError = validatedResolutions(supplied.resolutions)
    if resolutions == nil then
        return nil, resolutionsError
    end
    if atleast ~= "" and resolutions ~= "" then
        return nil, "Choose either minimum resolution or exact resolutions, not both"
    end
    local ratios, ratiosError = validatedRatios(supplied.ratios)
    if ratios == nil then
        return nil, ratiosError
    end
    local colors, colorsError = validatedColor(supplied.colors)
    if colors == nil then
        return nil, colorsError
    end

    local topRange = tostring(supplied.top_range or supplied.topRange or "1M")
    if not TOP_RANGE_VALUES[topRange] then
        return nil, "topRange must be one of 1d, 3d, 1w, 1M, 3M, 6M, or 1y"
    end

    local seed = tostring(supplied.seed or "")
    local validSeed = seed:match("^[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]$")
    if seed ~= "" and (sorting ~= "random" or validSeed == nil) then
        return nil, "seed must be empty or a six-character alphanumeric value used with random sorting"
    end

    local pageValue = tonumber(supplied.page or 1)
    if pageValue == nil or pageValue < 1 or pageValue > MAX_PAGE or pageValue ~= math.floor(pageValue) then
        return nil, "page must be an integer from 1 through " .. tostring(MAX_PAGE)
    end

    return {
        query = query,
        categories = categories,
        purity = purity,
        sorting = sorting,
        order = order,
        atleast = atleast,
        resolutions = resolutions,
        ratios = ratios,
        colors = colors,
        top_range = topRange,
        seed = seed,
        page = pageValue,
    },
        nil
end

local function searchUrl(filters)
    local parameters = {}
    local function append(name, value)
        if value ~= nil and value ~= "" then
            table.insert(parameters, urlEncode(name) .. "=" .. urlEncode(value))
        end
    end
    append("q", filters.query)
    append("categories", filters.categories)
    append("purity", filters.purity)
    append("sorting", filters.sorting)
    append("order", filters.order)
    append("atleast", filters.atleast)
    append("resolutions", filters.resolutions)
    append("ratios", filters.ratios)
    append("colors", filters.colors)
    if filters.sorting == "toplist" then
        append("topRange", filters.top_range)
    elseif filters.sorting == "random" then
        append("seed", filters.seed)
    end
    append("page", tostring(filters.page))
    return API_ORIGIN .. API_PREFIX .. "/search?" .. table.concat(parameters, "&")
end

boundedFetchHelper = function()
    local pluginDirectory = noctalia.pluginDir()
    if type(pluginDirectory) ~= "string" then
        return nil
    end
    pluginDirectory = pluginDirectory:gsub("/+$", "")
    if not validAbsolutePath(pluginDirectory) then
        return nil
    end
    local path = pluginDirectory .. "/scripts/bounded-fetch"
    return if validAbsolutePath(path) and noctalia.fileExists(path) then path else nil
end

local function transportDirectory()
    local dataDirectory = noctalia.pluginDataDir()
    if type(dataDirectory) ~= "string" then
        return nil, "Plugin transport storage is unavailable"
    end
    dataDirectory = dataDirectory:gsub("/+$", "")
    if not validAbsolutePath(dataDirectory) then
        return nil, "Plugin transport storage is unavailable"
    end
    local directory = dataDirectory .. "/bounded-fetch"
    if not validAbsolutePath(directory) then
        return nil, "Plugin transport storage path is invalid"
    end
    local made, makeError = noctalia.mkdirAll(directory)
    if made ~= true then
        return nil, tostring(makeError or "Could not create plugin transport storage")
    end
    local info = noctalia.fileInfo(directory)
    if type(info) ~= "table" or info.isDir ~= true then
        return nil, "Plugin transport storage is not a directory"
    end
    return directory, nil
end

local function removeTransportFile(path)
    if validAbsolutePath(path) and noctalia.fileExists(path) then
        noctalia.removeFile(path)
    end
end

local function cleanupOperationTransport(operation, keepResponse)
    if type(operation) ~= "table" then
        return
    end
    removeTransportFile(operation.transport_guard)
    removeTransportFile(operation.credential_path)
    if keepResponse ~= true then
        removeTransportFile(operation.response_path)
    end
end

local function allocateApiTransport(operation, key)
    local directory, directoryError = transportDirectory()
    if directory == nil then
        return false, directoryError
    end
    for _ = 1, 8 do
        transportSequence += 1
        local token = tostring(math.floor(noctalia.nowMs()))
            .. "-"
            .. tostring(operation.nonce)
            .. "-"
            .. tostring(transportSequence)
        local responsePath = directory .. "/wallhaven-api-" .. token .. ".json"
        local guardPath = directory .. "/.wall-in-one-guard-wallhaven-" .. token
        local credentialPath = if key ~= ""
            then directory .. "/.wall-in-one-secret-wallhaven-" .. token
            else ""
        if
            not noctalia.fileExists(responsePath)
            and not noctalia.fileExists(guardPath)
            and (credentialPath == "" or not noctalia.fileExists(credentialPath))
        then
            local guardWritten, guardError = noctalia.writeFile(guardPath, FETCH_PROTOCOL .. "\n")
            if guardWritten ~= true then
                return false, tostring(guardError or "Could not create request cancellation guard")
            end
            operation.response_path = responsePath
            operation.transport_guard = guardPath
            if credentialPath ~= "" then
                local credentialWritten, credentialError =
                    noctalia.writeFile(credentialPath, "X-API-Key: " .. key .. "\n")
                if credentialWritten ~= true then
                    cleanupOperationTransport(operation, false)
                    return false, tostring(credentialError or "Could not stage the private API header")
                end
                operation.credential_path = credentialPath
            end
            return true, nil
        end
    end
    return false, "Could not allocate unique request transport files"
end

local function allocateMediaTransport(operation, request)
    local directory = request.staging:match("^(.+)/[^/]+$")
    if not validAbsolutePath(directory) then
        return false, "Managed media transport directory is invalid"
    end
    for _ = 1, 8 do
        transportSequence += 1
        local token = tostring(math.floor(noctalia.nowMs()))
            .. "-"
            .. tostring(operation.nonce)
            .. "-"
            .. tostring(transportSequence)
        local guardPath = directory .. "/.wall-in-one-guard-wallhaven-media-" .. token
        if not noctalia.fileExists(guardPath) then
            local guardWritten, guardError = noctalia.writeFile(guardPath, FETCH_PROTOCOL .. "\n")
            if guardWritten ~= true then
                return false, tostring(guardError or "Could not create download cancellation guard")
            end
            operation.response_path = request.staging
            operation.transport_guard = guardPath
            return true, nil
        end
    end
    return false, "Could not allocate a unique download cancellation guard"
end

local function boundedFetchResult(result)
    if type(result) ~= "table" then
        return nil, "transport", "Bounded fetch returned no process result", 0
    end
    local output = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local protocol, outcome, profile, statusCode, effectiveUrl, contentType, bytes, path = output:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$"
    )
    if
        protocol == FETCH_PROTOCOL
        and outcome == "ok"
        and result.timedOut ~= true
        and tonumber(result.exitCode) == 0
    then
        return {
            profile = profile,
            status = math.floor(tonumber(statusCode) or 0),
            effective_url = effectiveUrl,
            content_type = contentType,
            bytes = math.floor(tonumber(bytes) or 0),
            path = path,
        },
            nil,
            nil,
            0
    end

    local errorProtocol, errorOutcome, kind, errorStatus, detail =
        output:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if errorProtocol == FETCH_PROTOCOL and errorOutcome == "error" then
        return nil, boundedText(kind, 80), boundedText(detail, 320), math.floor(tonumber(errorStatus) or 0)
    end
    if result.timedOut == true then
        return nil, "timeout", "Bounded fetch exceeded Noctalia's process timeout", 0
    end
    local fallback = boundedText(result.stderr or result.stdout, 320)
    if fallback == "" then
        fallback = "Bounded fetch exited without a valid protocol result"
    end
    return nil, "protocol", fallback, 0
end

local function validateFetchedFile(operation, transport, profile, url, maximumBytes)
    if
        type(transport) ~= "table"
        or transport.profile ~= profile
        or transport.status < 200
        or transport.status >= 300
        or transport.effective_url ~= url
        or transport.path ~= operation.response_path
        or transport.bytes < 1
        or transport.bytes > maximumBytes
    then
        return false, "Bounded fetch returned mismatched response metadata"
    end
    local info = noctalia.fileInfo(operation.response_path)
    if
        type(info) ~= "table"
        or info.isDir == true
        or math.floor(tonumber(info.size) or 0) ~= transport.bytes
    then
        return false, "Bounded fetch response file does not match its metadata"
    end
    return true, nil
end

local function httpError(statusCode)
    if statusCode == 401 then
        return "authentication", "Wallhaven rejected the API key or this content requires authentication"
    elseif statusCode == 429 then
        return "rate_limit", "Wallhaven's API rate limit was reached; wait before trying again"
    elseif statusCode >= 500 then
        return "remote", "Wallhaven is temporarily unavailable"
    end
    return "http", "Wallhaven returned HTTP " .. tostring(statusCode)
end

local function beginApiRequest(nonce, action, url, key, callback)
    local now = nowSeconds()
    if lastApiStart > 0 and now - lastApiStart < MIN_API_INTERVAL_SECONDS then
        rejectCommand(nonce, action, "rate_limit", "Wait two seconds between Wallhaven API requests")
        return
    end
    lastApiStart = now
    status.last_request_at = nowText()
    local operation = beginOperation(nonce, action)
    local allocated, allocationError = allocateApiTransport(operation, key)
    if allocated ~= true then
        finishOperationError(operation, "local", allocationError)
        return
    end
    local helper = boundedFetchHelper()
    if helper == nil then
        cleanupOperationTransport(operation, false)
        finishOperationError(operation, "local", "The bundled bounded-fetch helper is unavailable")
        return
    end
    local command = table.concat({
        "exec bash",
        shellQuote(helper),
        "wallhaven-api",
        shellQuote(url),
        shellQuote(operation.response_path),
        shellQuote(operation.transport_guard),
        shellQuote(operation.credential_path or "-"),
        "0",
    }, " ")
    local accepted = noctalia.runAsync(command, function(result)
        if not operationIsCurrent(operation) then
            cleanupOperationTransport(operation, false)
            return
        end
        if finishDiscarded(operation) then
            cleanupOperationTransport(operation, false)
            return
        end
        local transport, transportKind, transportMessage, transportStatus = boundedFetchResult(result)
        removeTransportFile(operation.transport_guard)
        removeTransportFile(operation.credential_path)
        if transport == nil then
            removeTransportFile(operation.response_path)
            if transportKind == "http" and transportStatus > 0 then
                local kind, message = httpError(transportStatus)
                finishOperationError(operation, kind, message)
            elseif transportKind == "timeout" or transportKind == "transport" then
                finishOperationError(operation, "network", transportMessage)
            else
                finishOperationError(operation, transportKind or "response", transportMessage)
            end
            return
        end
        local valid, validationError = validateFetchedFile(operation, transport, "wallhaven-api", url, MAX_BODY_BYTES)
        if valid ~= true or transport.content_type ~= "application/json" then
            removeTransportFile(operation.response_path)
            finishOperationError(operation, "response", validationError or "Wallhaven returned a non-JSON response")
            return
        end
        local body, readError = noctalia.readFile(operation.response_path)
        removeTransportFile(operation.response_path)
        if type(body) ~= "string" or #body ~= transport.bytes or #body > MAX_BODY_BYTES then
            finishOperationError(operation, "response", readError or "Wallhaven response could not be read safely")
            return
        end
        local decoded, decodeError = noctalia.json.decode(body)
        if type(decoded) ~= "table" then
            finishOperationError(
                operation,
                "response",
                "Wallhaven returned invalid JSON: " .. boundedText(decodeError, 160)
            )
            return
        end
        callback(operation, decoded)
    end, API_FETCH_TIMEOUT_MS)
    if accepted ~= true then
        cleanupOperationTransport(operation, false)
        finishOperationError(operation, "local", "Noctalia could not start bounded Wallhaven transport")
    end
end

-- Search and detail actions --------------------------------------------------

local function search(command, nonce, key)
    local filters, filterError = validatedSearchFilters(command, key ~= "")
    if filters == nil then
        rejectCommand(nonce, "search", "validation", filterError)
        return
    end
    beginApiRequest(nonce, "search", searchUrl(filters), key, function(operation, decoded)
        if type(decoded.data) ~= "table" then
            finishOperationError(operation, "response", "Wallhaven's search response did not include a result list")
            return
        end
        local items = {}
        local dropped = 0
        for _, candidate in ipairs(decoded.data) do
            if #items >= MAX_RESULTS then
                break
            end
            local item = normalizeWallpaper(candidate, false)
            if item ~= nil then
                table.insert(items, item)
            else
                dropped += 1
            end
        end

        local meta = if type(decoded.meta) == "table" then decoded.meta else {}
        results.nonce = nonce
        results.kind = "search"
        results.source_url = searchUrl(filters)
        results.filters = filters
        results.meta = {
            current_page = finiteInteger(meta.current_page, filters.page, 1, MAX_PAGE),
            last_page = finiteInteger(meta.last_page, filters.page, 1, MAX_NONCE),
            per_page = finiteInteger(meta.per_page, MAX_RESULTS, 1, MAX_RESULTS),
            total = finiteInteger(meta.total, #items, 0, MAX_NONCE),
            seed = boundedText(meta.seed, 32),
            dropped = dropped,
        }
        results.items = items
        results.selected = {}
        publishResults()
        finishOperationSuccess(operation)
    end)
end

local function detail(command, nonce, key)
    local id = validWallpaperId(command.id)
    if id == nil then
        rejectCommand(nonce, "detail", "validation", "detail requires a valid six-character wallpaper ID")
        return
    end
    if findResult(id) == nil then
        rejectCommand(nonce, "detail", "selection", "detail only accepts an ID from the current Wallhaven results")
        return
    end
    local url = API_ORIGIN .. API_PREFIX .. "/w/" .. id
    beginApiRequest(nonce, "detail", url, key, function(operation, decoded)
        local selected, selectedError = normalizeWallpaper(decoded.data, true)
        if selected == nil or selected.id ~= id then
            finishOperationError(
                operation,
                "response",
                selectedError or "Wallhaven returned details for a different wallpaper"
            )
            return
        end
        results.nonce = nonce
        results.kind = "detail"
        results.selected = selected
        publishResults()
        finishOperationSuccess(operation)
    end)
end

-- Managed download action ----------------------------------------------------

local function captureHelper()
    local pluginDirectory = noctalia.pluginDir()
    if type(pluginDirectory) ~= "string" or pluginDirectory == "" or pluginDirectory:find("[%c]") then
        return nil
    end
    local path = pluginDirectory:gsub("/+$", "") .. "/scripts/capture-still"
    return if noctalia.fileExists(path) then path else nil
end

local function commandFailureDetail(result)
    if type(result) ~= "table" then
        return "image validation did not return a process result"
    end
    local detail = noctalia.string.trim(tostring(result.stderr or ""))
    if detail == "" then
        detail = noctalia.string.trim(tostring(result.stdout or ""))
    end
    if detail == "" then
        detail = if result.timedOut == true then "image validation timed out" else "image validation failed"
    end
    return boundedText(detail, 320)
end

local function cleanupNewFile(path)
    if validAbsolutePath(path) and noctalia.fileExists(path) then
        noctalia.removeFile(path)
    end
end

local function validatedDownload(command, nonce)
    local id = validWallpaperId(command.id)
    if id == nil then
        return nil, "download requires a valid six-character wallpaper ID"
    end
    local item = findResult(id)
    if item == nil then
        return nil, "download only accepts a wallpaper from the current result set"
    end
    if type(command.url) ~= "string" or (command.url ~= item.path and command.url ~= item.short_url) then
        return nil, "download requires the exact selected Wallhaven media or short URL"
    end
    local downloadUrl, extension = normalizedCdnUrl(item.path, id)
    if downloadUrl == nil then
        return nil, "the selected wallpaper has no supported Wallhaven CDN URL"
    end
    local advertisedBytes = math.floor(tonumber(item.file_size) or 0)
    if advertisedBytes < 1 or advertisedBytes > MAX_DOWNLOAD_BYTES then
        return nil, "the selected wallpaper does not advertise a valid size within the 64 MiB limit"
    end

    local managedDirectory, directoryError = wallhavenManagedDirectory()
    if managedDirectory == nil then
        return nil, directoryError
    end
    local target = command.target_path
    local requiredTarget = managedDirectory .. "/wallhaven-" .. id .. "." .. extension
    if target ~= requiredTarget or not validAbsolutePath(target) then
        return nil, "target_path must be the coordinator-managed Wall-in-One/Wallhaven destination"
    end
    local staging = command.staging_path
    local requiredStaging = target .. ".wallhaven-" .. tostring(nonce) .. ".stage"
    if staging ~= requiredStaging or not validAbsolutePath(staging) then
        return nil, "staging_path must equal target_path plus .wallhaven-<nonce>.stage"
    end

    local directoryOk, markerError = validateManagedDirectory(managedDirectory)
    if directoryOk ~= true then
        return nil, markerError
    end
    local sidecar = target .. ".wallhaven.json"
    local sidecarStage = staging .. ".wallhaven.json"
    local nativePart = staging .. ".part"
    if
        noctalia.fileExists(target)
        or noctalia.fileExists(staging)
        or noctalia.fileExists(nativePart)
        or noctalia.fileExists(sidecar)
        or noctalia.fileExists(sidecarStage)
    then
        return nil, "download refuses to overwrite an existing target, staging file, native part, or provenance sidecar"
    end

    return {
        id = id,
        item = item,
        requested_url = command.url,
        download_url = downloadUrl,
        extension = extension,
        target = target,
        staging = staging,
        native_part = nativePart,
        sidecar = sidecar,
        sidecar_stage = sidecarStage,
        managed_directory = managedDirectory,
    },
        nil
end

local function validateRequestDestination(request)
    local currentDirectory, directoryError = wallhavenManagedDirectory()
    if currentDirectory == nil then
        return false, directoryError
    end
    if currentDirectory ~= request.managed_directory then
        return false, "The configured Wallhaven directory changed during download"
    end
    local expectedTarget = currentDirectory .. "/wallhaven-" .. request.id .. "." .. request.extension
    local expectedStaging = expectedTarget .. ".wallhaven-" .. tostring(request.nonce) .. ".stage"
    if request.target ~= expectedTarget or request.staging ~= expectedStaging then
        return false, "The Wallhaven download destination no longer matches its coordinator request"
    end
    return validateManagedDirectory(currentDirectory)
end

-- Download validation and promotion -----------------------------------------

local function cleanupDownloadStaging(request)
    for _, path in ipairs({ request.staging, request.native_part, request.sidecar_stage }) do
        cleanupNewFile(path)
    end
end

local function downloadCanContinue(operation, request)
    if not operationIsCurrent(operation) then
        cleanupDownloadStaging(request)
        return false
    end
    if finishDiscarded(operation) then
        cleanupDownloadStaging(request)
        return false
    end
    return true
end

local function failDownload(operation, request, kind, message)
    cleanupDownloadStaging(request)
    if operationIsCurrent(operation) then
        finishOperationError(operation, kind, message)
    end
end

local function validatedStagingSize(request)
    local info = noctalia.fileInfo(request.staging)
    if type(info) ~= "table" or info.isDir == true then
        return nil, "Wallhaven download did not produce a regular file"
    end
    local bytes = math.floor(tonumber(info.size) or 0)
    if bytes < 1 or bytes > MAX_DOWNLOAD_BYTES then
        return nil, "Wallhaven download is empty or exceeds 64 MiB"
    end
    local advertisedBytes = math.floor(tonumber(request.item.file_size) or 0)
    if advertisedBytes < 1 or bytes ~= advertisedBytes then
        return nil, "Downloaded size does not match Wallhaven metadata"
    end
    return bytes, nil
end

local function promoteValidatedDownload(operation, request, bytes)
    if not downloadCanContinue(operation, request) then
        return
    end
    local destinationOk, destinationError = validateRequestDestination(request)
    if destinationOk ~= true then
        failDownload(operation, request, "configuration", destinationError)
        return
    end

    -- The Noctalia file API does not expose rename-no-replace. Recheck the
    -- coordinator-owned names immediately before promotion; the coordinator
    -- serializes writers to this managed directory.
    if noctalia.fileExists(request.target) or noctalia.fileExists(request.sidecar) then
        failDownload(operation, request, "conflict", "The managed download target appeared during validation")
        return
    end

    local downloadedAt = nowText()
    local sidecarValue = {
        schema = SCHEMA,
        plugin = "goober/wall-in-one",
        provider = "Wallhaven",
        source = "wallhaven",
        id = request.id,
        url = request.download_url,
        path = request.target,
        page_url = SITE_ORIGIN .. "/w/" .. request.id,
        source_page = SITE_ORIGIN .. "/w/" .. request.id,
        bytes = bytes,
        downloaded_at = downloadedAt,
        downloaded_at_epoch = nowSeconds(),
    }
    local encoded, encodeError = noctalia.json.encode(sidecarValue, true)
    if type(encoded) ~= "string" or #encoded > 64 * 1024 then
        failDownload(operation, request, "local", encodeError or "Could not encode Wallhaven provenance")
        return
    end
    local wrote, writeError = noctalia.writeFile(request.sidecar_stage, encoded .. "\n")
    if wrote ~= true then
        failDownload(operation, request, "local", writeError or "Could not stage Wallhaven provenance")
        return
    end

    if not downloadCanContinue(operation, request) then
        return
    end
    destinationOk, destinationError = validateRequestDestination(request)
    if destinationOk ~= true then
        failDownload(operation, request, "configuration", destinationError)
        return
    end

    local promoted, promoteError = noctalia.renameFile(request.staging, request.target)
    if promoted ~= true then
        failDownload(operation, request, "local", promoteError or "Could not promote the Wallhaven image")
        return
    end
    local sidecarPromoted, sidecarError = noctalia.renameFile(request.sidecar_stage, request.sidecar)
    if sidecarPromoted ~= true then
        -- Never leave an untracked file that the coordinator could mistake
        -- for a managed download.
        cleanupNewFile(request.target)
        cleanupDownloadStaging(request)
        finishOperationError(operation, "local", sidecarError or "Could not promote Wallhaven provenance")
        return
    end

    status.last_download = {
        id = request.id,
        url = request.download_url,
        path = request.target,
        sidecar = request.sidecar,
        bytes = bytes,
        downloaded_at = downloadedAt,
    }
    finishOperationSuccess(operation)
end

local function validateDownloadedImage(operation, request, downloadedBytes)
    local helper = captureHelper()
    if helper == nil then
        failDownload(operation, request, "local", "The bundled image validation helper is unavailable")
        return
    end

    -- `copy` validates/decodes into a helper-owned temporary file, then moves
    -- it over the request-specific staging path. The source and destination
    -- intentionally match: Luau never materializes the image bytes.
    local command = table.concat({
        "bash",
        shellQuote(helper),
        "copy",
        shellQuote(request.staging),
        shellQuote(request.staging),
        shellQuote(""),
    }, " ")
    local started = noctalia.runAsync(command, function(result)
        if not downloadCanContinue(operation, request) then
            return
        end
        if
            type(result) ~= "table"
            or result.timedOut == true
            or tonumber(result.exitCode) ~= 0
        then
            failDownload(
                operation,
                request,
                "validation",
                "Downloaded content does not match its image extension or failed decode validation: "
                    .. commandFailureDetail(result)
            )
            return
        end

        local validatedBytes, sizeError = validatedStagingSize(request)
        if validatedBytes == nil then
            failDownload(operation, request, "validation", sizeError)
            return
        end
        if validatedBytes ~= downloadedBytes then
            failDownload(operation, request, "validation", "Image size changed during out-of-process validation")
            return
        end
        promoteValidatedDownload(operation, request, validatedBytes)
    end, IMAGE_VALIDATION_TIMEOUT_MS)
    if started ~= true then
        failDownload(operation, request, "local", "Noctalia could not start image validation")
    end
end

local function download(command, nonce)
    local request, requestError = validatedDownload(command, nonce)
    if request == nil then
        rejectCommand(nonce, "download", "validation", requestError)
        return
    end
    request.nonce = nonce

    local operation = beginOperation(nonce, "download", request.id)
    operation.request = request
    status.last_request_at = nowText()
    local allocated, allocationError = allocateMediaTransport(operation, request)
    if allocated ~= true then
        failDownload(operation, request, "local", allocationError)
        return
    end
    local helper = boundedFetchHelper()
    if helper == nil then
        cleanupOperationTransport(operation, false)
        failDownload(operation, request, "local", "The bundled bounded-fetch helper is unavailable")
        return
    end
    local expectedBytes = math.floor(tonumber(request.item.file_size) or 0)
    local transportCommand = table.concat({
        "exec bash",
        shellQuote(helper),
        "wallhaven-media",
        shellQuote(request.download_url),
        shellQuote(request.staging),
        shellQuote(operation.transport_guard),
        shellQuote("-"),
        tostring(expectedBytes),
    }, " ")
    local accepted = noctalia.runAsync(transportCommand, function(result)
        if not downloadCanContinue(operation, request) then
            cleanupOperationTransport(operation, false)
            return
        end
        local transport, transportKind, transportMessage, transportStatus = boundedFetchResult(result)
        cleanupOperationTransport(operation, transport ~= nil)
        if transport == nil then
            local kind = if transportKind == "timeout" or transportKind == "transport" then "network"
                elseif transportKind == "http" and transportStatus >= 500 then "remote"
                elseif transportKind == "http" then "http"
                else transportKind or "validation"
            failDownload(operation, request, kind, transportMessage)
            return
        end
        local valid, validationError =
            validateFetchedFile(operation, transport, "wallhaven-media", request.download_url, MAX_DOWNLOAD_BYTES)
        local expectedContentType = if request.extension == "jpg" then "image/jpeg" else "image/png"
        if
            valid ~= true
            or transport.content_type ~= expectedContentType
            or transport.bytes ~= expectedBytes
        then
            failDownload(
                operation,
                request,
                "validation",
                validationError or "Wallhaven media transport metadata did not match the selected wallpaper"
            )
            return
        end
        local bytes, sizeError = validatedStagingSize(request)
        if bytes == nil then
            failDownload(operation, request, "validation", sizeError)
            return
        end
        validateDownloadedImage(operation, request, bytes)
    end, MEDIA_FETCH_TIMEOUT_MS)
    if accepted ~= true then
        cleanupOperationTransport(operation, false)
        failDownload(operation, request, "local", "Noctalia could not start bounded Wallhaven media transport")
    end
end

-- Command protocol and lifecycle --------------------------------------------

local function cancelActiveOperation()
    local operation = activeOperation
    if type(operation) ~= "table" then
        return false
    end
    operation.discarded = true
    operationGeneration += 1
    cleanupOperationTransport(operation, false)
    if type(operation.request) == "table" then
        cleanupDownloadStaging(operation.request)
    end
    activeOperation = nil
    return true
end

local function clear(command, nonce)
    cancelActiveOperation()
    results.nonce = nonce
    results.kind = "empty"
    results.source_url = SITE_ORIGIN
    results.filters = {}
    results.meta = {}
    results.items = {}
    results.selected = {}
    publishResults()
    status.last_completed_nonce = math.max(status.last_completed_nonce, nonce)
    status.last_action = "clear"
    status.last_error = ""
    status.last_error_kind = ""
    publishStatus()
end

local function handleCommand(command)
    if type(command) ~= "table" then
        return
    end
    local nonce = validNonce(command.nonce)
    if nonce == nil or nonce <= status.last_nonce then
        return
    end
    status.last_nonce = nonce

    local action = boundedText(command.action, 32):lower()
    if action == "clear" then
        clear(command, nonce)
        return
    end
    if type(activeOperation) == "table" then
        rejectCommand(nonce, action, "busy", "A Wallhaven operation is already in flight")
        return
    end

    refreshAvailability()
    if not status.available then
        local reason = if status.configuration_error ~= ""
            then status.configuration_error
            else "Wallhaven integration is disabled or unavailable"
        rejectCommand(nonce, action, "unavailable", reason)
        return
    end
    local key, keyError = apiKey()
    if keyError ~= nil then
        rejectCommand(nonce, action, "configuration", keyError)
        return
    end

    if action == "search" then
        search(command, nonce, key)
    elseif action == "detail" then
        detail(command, nonce, key)
    elseif action == "download" then
        download(command, nonce)
    else
        rejectCommand(nonce, action, "unsupported", "Unsupported Wallhaven action")
    end
end

function onConfigChanged()
    refreshAvailability()
    if not status.available and type(activeOperation) == "table" then
        cancelActiveOperation()
    end
    publishStatus()
end

function onExit(_signal, _reason)
    running = false
    cancelActiveOperation()
    operationGeneration += 1
    publishStatus(true)
end

publishResults()
publishStatus(true)
noctalia.state.watch(COMMAND_KEY, handleCommand)
handleCommand(noctalia.state.get(COMMAND_KEY))

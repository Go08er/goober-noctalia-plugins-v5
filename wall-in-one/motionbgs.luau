--!nonstrict
-- Wall-in-One MotionBGS public-page provider.
--
-- MotionBGS does not publish a stable API. This service therefore treats its
-- public HTML as a best-effort data source. It does not execute page markup,
-- bypass Cloudflare, crawl in bulk, or follow cross-origin links. All network
-- work is serialized through scripts/motionbgs-provider, which adds hard
-- response size/time limits and atomic downloads.

local SCHEMA = 1
local COMMAND_KEY = "wall_in_one_motionbgs_command_v1"
local COMMAND_ACK_KEY = "wall_in_one_motionbgs_command_ack_v1"
local STATUS_KEY = "wall_in_one_motionbgs_status_v1"
local RESULTS_KEY = "wall_in_one_motionbgs_results_v1"
local BASE_URL = "https://motionbgs.com"
local MAX_NONCE = 9007199254740991
local MAX_RESULTS = 24
local MAX_QUERY_BYTES = 80
local MAX_QUEUE = 8
local MAX_CACHE_SEARCHES = 8
local MAX_CACHE_DETAILS = 48
local MAX_CACHE_BYTES = 2 * 1024 * 1024
local MAX_HTML_RESPONSE_BYTES = 1024 * 1024
local MAX_PROVIDER_SIDECAR_BYTES = 64 * 1024
local REQUEST_DELAY_MS = 1000
local DOWNLOAD_TIMEOUT_SECONDS = 45
local MANAGED_DOWNLOAD_SUFFIX = "/Wall-in-One/MotionBGS"
local MANAGED_DIRECTORY_MARKER = ".wall-in-one-motionbgs-managed.json"
local MANAGED_DIRECTORY_MARKER_CONTENT =
    '{"schema":1,"owner":"goober/wall-in-one","provider":"MotionBGS","deletion_authority":"adjacent .motionbgs.json sidecar required"}\n'
local MAX_MANAGED_MARKER_BYTES = #MANAGED_DIRECTORY_MARKER_CONTENT

local sequence = 0
local operationSequence = 0
local operationGeneration = 0
local networkBusy = false
local activeOperation = nil
local pendingOperations = {}
local lastNetworkStartMs = 0
local dataDirectory = ""
local cacheDirectory = ""
local cachePath = ""
local helperPath = ""

local cache = {
    schema = SCHEMA,
    searches = {},
    search_order = {},
    details = {},
    detail_order = {},
}

local status = {
    schema = SCHEMA,
    sequence = 0,
    available = false,
    curl_available = noctalia.commandExists("curl"),
    helper_available = false,
    busy = false,
    active_action = "",
    queue_depth = 0,
    last_nonce = 0,
    last_completed_nonce = 0,
    last_action = "",
    last_error = "",
    last_error_kind = "",
    site_changed = false,
    last_request_at = "",
    last_success_at = "",
    last_download = {},
    download_directory = "",
    updated_at = "",
}

local results = {
    schema = SCHEMA,
    sequence = 0,
    nonce = 0,
    query = "",
    source_url = BASE_URL,
    cached = false,
    fetched_at = 0,
    items = {},
    selected = {},
}

local previousStatus = noctalia.state.get(STATUS_KEY)
if type(previousStatus) == "table" then
    local previousNonce = tonumber(previousStatus.last_nonce)
    if previousNonce ~= nil and previousNonce >= 0 and previousNonce <= MAX_NONCE then
        status.last_nonce = math.floor(previousNonce)
    end
end

local function bounded(value, maximum)
    local text = tostring(value or ""):gsub("[%c]", " ")
    text = noctalia.string.trim(text)
    if #text > maximum then
        text = text:sub(1, maximum)
    end
    return text
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function nowSeconds()
    return tonumber(noctalia.formatTime("%s")) or 0
end

local function settingString(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) ~= "string" then
        return fallback
    end
    return noctalia.string.trim(value)
end

local function settingInt(key, fallback, minimum, maximum)
    local value = math.floor(tonumber(noctalia.getConfig(key)) or fallback)
    return math.max(minimum, math.min(maximum, value))
end

local function settingBool(key, fallback)
    local value = noctalia.getConfig(key)
    return if type(value) == "boolean" then value else fallback
end

local function validAbsolutePath(value)
    return type(value) == "string"
        and value:sub(1, 1) == "/"
        and value ~= "/"
        and value:find("[%c]") == nil
        and not value:find("/%./")
        and not value:match("/%.$")
        and not value:find("/%.%./")
        and not value:match("/%.%.$")
end

local function readBoundedRegularFile(path, maximumBytes)
    maximumBytes = math.floor(tonumber(maximumBytes) or 0)
    if not validAbsolutePath(path) or maximumBytes < 1 then
        return nil
    end
    local info = noctalia.fileInfo(path)
    local expectedBytes = type(info) == "table" and math.floor(tonumber(info.size) or 0) or 0
    if type(info) ~= "table" or info.isDir == true or expectedBytes < 1 or expectedBytes > maximumBytes then
        return nil
    end
    local raw = noctalia.readFile(path)
    if type(raw) ~= "string" or #raw ~= expectedBytes or #raw > maximumBytes then
        return nil
    end
    return raw
end

local function configuredDirectory(key)
    local configured = settingString(key, "")
    if configured == "" then
        return ""
    end
    local directory = noctalia.expandPath(configured)
    if not validAbsolutePath(directory) or directory == "/" then
        return ""
    end
    return directory:gsub("/+$", "")
end

local function configuredDownloadDirectory()
    if settingString("motionbgs_download_directory", "") ~= "" then
        -- An invalid explicit override fails closed; it must never silently
        -- redirect a download into the managed default.
        return configuredDirectory("motionbgs_download_directory")
    end
    local videoRoot = configuredDirectory("video_directory")
    return if videoRoot == "" then "" else videoRoot .. MANAGED_DOWNLOAD_SUFFIX
end

local function usesManagedDownloadDirectory()
    return settingString("motionbgs_download_directory", "") == ""
end

local function cacheTtlSeconds()
    return settingInt("motionbgs_cache_minutes", 30, 5, 1440) * 60
end

local function configuredResultLimit()
    return settingInt("motionbgs_result_limit", MAX_RESULTS, 1, MAX_RESULTS)
end

local function configuredDownloadLimit()
    return settingInt("motionbgs_max_download_mb", 256, 16, 512)
end

local function configuredQuality()
    local quality = settingString("motionbgs_quality", "hd"):lower()
    return if quality == "4k" then "4k" else "hd"
end

local function providerAvailable()
    return settingBool("use_motionbgs", true)
        and status.curl_available
        and status.helper_available
        and cacheDirectory ~= ""
end

local function writeManagedDirectoryMarker(directory)
    local marker = directory .. "/" .. MANAGED_DIRECTORY_MARKER
    if noctalia.fileExists(marker) then
        local current = readBoundedRegularFile(marker, MAX_MANAGED_MARKER_BYTES)
        if current ~= MANAGED_DIRECTORY_MARKER_CONTENT then
            return false, "the managed MotionBGS directory marker is invalid"
        end
        return true, nil
    end

    local temporary = marker .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, MANAGED_DIRECTORY_MARKER_CONTENT)
    if wrote ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(writeError or "could not write the managed MotionBGS directory marker")
    end
    local installed, installError = noctalia.renameFile(temporary, marker)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or "could not install the managed MotionBGS directory marker")
    end
    return true, nil
end

local function prepareDownloadDirectory()
    local directory = configuredDownloadDirectory()
    if directory == "" then
        return "", "Select a Wall-in-One video directory or an explicit MotionBGS download directory first"
    end
    if not usesManagedDownloadDirectory() then
        return directory, nil
    end
    if not providerAvailable() then
        return "", "MotionBGS integration is disabled or its local scraper requirements are unavailable"
    end

    local videoRoot = configuredDirectory("video_directory")
    local rootInfo = videoRoot ~= "" and noctalia.fileInfo(videoRoot) or nil
    if type(rootInfo) ~= "table" or rootInfo.isDir ~= true then
        return "", "The selected Wall-in-One video directory does not exist"
    end
    local made, makeError = noctalia.mkdirAll(directory)
    if made ~= true then
        return "", tostring(makeError or "could not create the managed MotionBGS download directory")
    end
    local marked, markerError = writeManagedDirectoryMarker(directory)
    if marked ~= true then
        return "", markerError
    end
    return directory, nil
end

local function publishStatus()
    sequence += 1
    status.sequence = sequence
    status.busy = networkBusy
    status.active_action = if type(activeOperation) == "table" then tostring(activeOperation.kind or "") else ""
    status.queue_depth = #pendingOperations
    status.download_directory = configuredDownloadDirectory()
    status.available = providerAvailable()
    status.updated_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    noctalia.state.set(STATUS_KEY, status)
end

local function publishResults()
    results.sequence += 1
    noctalia.state.set(RESULTS_KEY, results)
end

local function publishAck(nonce, state, errorMessage)
    noctalia.state.set(COMMAND_ACK_KEY, {
        schema = SCHEMA,
        nonce = nonce,
        state = state,
        error = bounded(errorMessage, 400),
        updated_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
    })
end

local function completeNonce(nonce, action)
    status.last_completed_nonce = math.max(status.last_completed_nonce, tonumber(nonce) or 0)
    status.last_action = tostring(action or "")
    status.last_error = ""
    status.last_error_kind = ""
    status.site_changed = false
    status.last_success_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishAck(nonce, "complete", "")
    publishStatus()
end

local function failNonce(nonce, action, kind, message)
    status.last_completed_nonce = math.max(status.last_completed_nonce, tonumber(nonce) or 0)
    status.last_action = tostring(action or "")
    status.last_error_kind = bounded(kind, 80)
    status.last_error = bounded(message, 400)
    status.site_changed = kind == "site-markup" or kind == "challenge"
    publishAck(nonce, "error", status.last_error)
    noctalia.log("wall-in-one MotionBGS: " .. status.last_error_kind .. ": " .. status.last_error)
    publishStatus()
end

local function cleanupOperationResponse(operation)
    if type(operation) ~= "table" then
        return
    end
    local path = operation.response_path
    if validAbsolutePath(path) and noctalia.fileExists(path) then
        noctalia.removeFile(path)
    end
end

local function acknowledgeCancellation(operation, message)
    if type(operation) ~= "table" or operation.cancelled == true then
        return
    end
    operation.cancelled = true
    local nonce = tonumber(operation.nonce)
    if nonce ~= nil and nonce == math.floor(nonce) and nonce > 0 and nonce <= MAX_NONCE then
        status.last_completed_nonce = math.max(status.last_completed_nonce, nonce)
        publishAck(nonce, "error", message)
    end
end

local function invalidateOperations(message, forceBarrier)
    local active = type(activeOperation) == "table" and activeOperation or nil
    local hasCurrent = #pendingOperations > 0 or (active ~= nil and active.cancelled ~= true)
    if not hasCurrent and forceBarrier ~= true then
        return false
    end

    operationGeneration += 1
    local detail = bounded(message, 400)
    for _, operation in ipairs(pendingOperations) do
        cleanupOperationResponse(operation)
        acknowledgeCancellation(operation, detail)
    end
    pendingOperations = {}
    if active ~= nil then
        cleanupOperationResponse(active)
        acknowledgeCancellation(active, detail)
    end

    if hasCurrent then
        status.last_action = "cancel"
        status.last_error_kind = "cancelled"
        status.last_error = detail
        status.site_changed = false
    end
    publishStatus()
    return hasCurrent
end

local function nonceValue(value)
    local nonce = tonumber(value)
    if nonce == nil or nonce ~= math.floor(nonce) or nonce <= 0 or nonce > MAX_NONCE then
        return nil
    end
    return nonce
end

local function validSlug(value)
    if type(value) ~= "string" or #value == 0 or #value > 120 then
        return nil
    end
    local slug = value:lower()
    return if slug:match("^[a-z0-9][a-z0-9-]*$") ~= nil then slug else nil
end

local function normalizeSiteUrl(value)
    if type(value) ~= "string" or value == "" or value:find("[%c]") or value:find("\\", 1, true) then
        return nil
    end
    if value:sub(1, 1) == "/" and value:sub(1, 2) ~= "//" then
        value = BASE_URL .. value
    end
    if value ~= BASE_URL and value:sub(1, #BASE_URL + 1) ~= BASE_URL .. "/" then
        return nil
    end
    if value:find("#", 1, true) then
        return nil
    end
    local path = value:sub(#BASE_URL + 1)
    if path:find("/%.%./") or path:match("/%.%.$") then
        return nil
    end
    return value
end

local function htmlDecode(value)
    local text = tostring(value or "")
    text = text:gsub("&amp;", "&")
    text = text:gsub("&quot;", '"')
    text = text:gsub("&#0*39;", "'")
    text = text:gsub("&apos;", "'")
    text = text:gsub("&lt;", "<")
    text = text:gsub("&gt;", ">")
    text = text:gsub("&nbsp;", " ")
    return text
end

local function stripMarkup(value)
    local text = tostring(value or ""):gsub("<[^>]*>", " ")
    return bounded(htmlDecode(text):gsub("%s+", " "), 240)
end

local function attributeValue(attributes, key)
    local escapedKey = key:gsub("([^%w])", "%%%1")
    local prefix = "^" .. escapedKey
    local spaced = "%s" .. escapedKey
    local value = attributes:match(prefix .. '%s*=%s*"([^"]*)"') or attributes:match(spaced .. '%s*=%s*"([^"]*)"')
    if value == nil then
        value = attributes:match(prefix .. "%s*=%s*'([^']*)'") or attributes:match(spaced .. "%s*=%s*'([^']*)'")
    end
    if value == nil then
        value = attributes:match(prefix .. "%s*=%s*([^%s>]+)") or attributes:match(spaced .. "%s*=%s*([^%s>]+)")
    end
    return if value ~= nil then htmlDecode(value) else nil
end

local function hasClass(attributes, wanted)
    local classes = attributeValue(attributes, "class")
    if classes == nil then
        return false
    end
    for className in classes:gmatch("[^%s]+") do
        if className == wanted then
            return true
        end
    end
    return false
end

local function spanText(body, className)
    for attributes, inner in body:gmatch("<[sS][pP][aA][nN]%s+([^>]-)>(.-)</[sS][pP][aA][nN]>") do
        if hasClass(attributes, className) then
            return stripMarkup(inner)
        end
    end
    return ""
end

local function firstImage(body)
    for attributes in body:gmatch("<[iI][mM][gG]%s+([^>]-)>") do
        local source = attributeValue(attributes, "src") or attributeValue(attributes, "data-src")
        local normalized = normalizeSiteUrl(source)
        if normalized ~= nil then
            return normalized
        end
    end
    for attributes in body:gmatch("<[sS][oO][uU][rR][cC][eE]%s+([^>]-)>") do
        local source = attributeValue(attributes, "srcset") or attributeValue(attributes, "src")
        if source ~= nil then
            source = source:match("^([^,%s]+)") or source
        end
        local normalized = normalizeSiteUrl(source)
        if normalized ~= nil then
            return normalized
        end
    end
    return ""
end

local function challengePage(html)
    local lower = tostring(html or ""):lower()
    return lower:find("<title>just a moment", 1, true) ~= nil
        or lower:find("id=challenge-error-text", 1, true) ~= nil
        or lower:find('id="challenge-error-text"', 1, true) ~= nil
        or lower:find("checking your browser", 1, true) ~= nil
end

local function parseSearchHtml(html, limit)
    if challengePage(html) then
        return nil, "challenge", "MotionBGS returned an anti-bot challenge; no bypass was attempted"
    end

    local found = {}
    local seen = {}
    for attributes, body in html:gmatch("<[aA]%s+([^>]-)>(.-)</[aA]>") do
        if #found >= limit then
            break
        end
        local href = attributeValue(attributes, "href")
        local titleAttribute = attributeValue(attributes, "title") or ""
        local title = spanText(body, "ttl")
        local candidate = title ~= "" or titleAttribute:lower():find("live wallpaper", 1, true) ~= nil
        if candidate and href ~= nil then
            local path = href
            if path:sub(1, #BASE_URL) == BASE_URL then
                path = path:sub(#BASE_URL + 1)
            end
            local slug = path:match("^/([a-z0-9][a-z0-9-]*)/?$")
            if slug ~= nil and not seen[slug] then
                if title == "" then
                    title = titleAttribute:gsub("[Ll]ive%s+[Ww]allpaper", "")
                    title = bounded(title, 240)
                end
                local sourceUrl = normalizeSiteUrl("/" .. slug)
                local thumbnail = firstImage(body)
                local quality = spanText(body, "frm")
                if quality == "" then
                    quality = titleAttribute:match("([4][Kk])") or titleAttribute:match("([Hh][Dd])") or ""
                end
                local id = thumbnail:match("/media/(%d+)/") or ""
                table.insert(found, {
                    slug = slug,
                    id = id,
                    title = title ~= "" and title or slug,
                    quality = bounded(quality, 20):upper(),
                    source_url = sourceUrl,
                    thumbnail_url = thumbnail,
                    provider = "MotionBGS",
                })
                seen[slug] = true
            end
        end
    end

    if #found == 0 then
        local lower = tostring(html or ""):lower()
        local explicitEmpty = lower:find("no wallpapers", 1, true) ~= nil
            or lower:find("nothing found", 1, true) ~= nil
            or lower:find("no results", 1, true) ~= nil
        if not explicitEmpty then
            return nil,
                "site-markup",
                "MotionBGS returned no recognizable wallpaper cards; its public markup may have changed"
        end
    end
    return found, nil, nil
end

local function metaContent(html, propertyName)
    for attributes in html:gmatch("<[mM][eE][tT][aA]%s+([^>]-)>") do
        local name = attributeValue(attributes, "property") or attributeValue(attributes, "name")
        if type(name) == "string" and name:lower() == propertyName:lower() then
            return attributeValue(attributes, "content") or ""
        end
    end
    return ""
end

local function parseDetailsHtml(html, slug)
    if challengePage(html) then
        return nil, "challenge", "MotionBGS returned an anti-bot challenge; no bypass was attempted"
    end

    local title = metaContent(html, "og:title")
    if title == "" then
        title = html:match("<[tT][iI][tT][lL][eE]>(.-)</[tT][iI][tT][lL][eE]>") or ""
    end
    title = stripMarkup(title):gsub("%s+[Ll]ive%s+[Ww]allpaper%s*$", "")

    local preview = normalizeSiteUrl(metaContent(html, "og:video")) or ""
    local poster = normalizeSiteUrl(metaContent(html, "og:image")) or ""
    if preview == "" then
        for attributes in html:gmatch("<[sS][oO][uU][rR][cC][eE]%s+([^>]-)>") do
            local mediaType = (attributeValue(attributes, "type") or ""):lower()
            local source = normalizeSiteUrl(attributeValue(attributes, "src"))
            if source ~= nil and (mediaType == "video/mp4" or source:match("%.mp4$")) then
                preview = source
                break
            end
        end
    end

    local downloads = {}
    local wallpaperId = ""
    for attributes, body in html:gmatch("<[aA]%s+([^>]-)>(.-)</[aA]>") do
        local href = attributeValue(attributes, "href")
        if href ~= nil then
            local path = href
            if path:sub(1, #BASE_URL) == BASE_URL then
                path = path:sub(#BASE_URL + 1)
            end
            local quality, id = path:match("^/dl/([%w]+)/(%d+)/?$")
            quality = type(quality) == "string" and quality:lower() or nil
            if (quality == "hd" or quality == "4k") and id ~= nil then
                local normalized = normalizeSiteUrl("/dl/" .. quality .. "/" .. id .. "/")
                local bodyText = stripMarkup(body)
                local width, height = bodyText:match("(%d+)%s*[xX]%s*(%d+)")
                local size = bodyText:match("%(([%d%.]+)%s*[Mm][Bb]%)") or ""
                downloads[quality] = {
                    id = id,
                    quality = quality,
                    label = quality:upper(),
                    resolution = if width ~= nil then width .. "x" .. height else "",
                    advertised_size_mb = tonumber(size) or 0,
                    url = normalized,
                }
                wallpaperId = wallpaperId ~= "" and wallpaperId or id
            end
        end
    end

    if next(downloads) == nil or wallpaperId == "" then
        return nil,
            "site-markup",
            "MotionBGS did not expose recognizable HD/4K download links; its public markup may have changed"
    end

    local duration = html:match('"duration"%s*:%s*"(PT[^"]+)"') or ""
    return {
        slug = slug,
        id = wallpaperId,
        title = title ~= "" and title or slug,
        source_url = BASE_URL .. "/" .. slug,
        preview_url = preview,
        poster_url = poster,
        duration = bounded(duration, 40),
        downloads = downloads,
        fetched_at = nowSeconds(),
        provider = "MotionBGS",
    },
        nil,
        nil
end

local function trimOrder(order, values, maximum)
    while #order > maximum do
        local removed = table.remove(order, 1)
        values[removed] = nil
    end
end

local function touchOrder(order, key)
    for index = #order, 1, -1 do
        if order[index] == key then
            table.remove(order, index)
        end
    end
    table.insert(order, key)
end

local function validCachedSearch(key, record)
    if
        type(key) ~= "string"
        or key == ""
        or #key > MAX_QUERY_BYTES
        or key:find("[%c]") ~= nil
        or type(record) ~= "table"
        or type(record.query) ~= "string"
        or record.query == ""
        or #record.query > MAX_QUERY_BYTES
        or record.query:find("[%c]") ~= nil
        or normalizeSiteUrl(record.source_url) == nil
        or type(record.items) ~= "table"
        or #record.items > MAX_RESULTS
        or tonumber(record.fetched_at) == nil
    then
        return false
    end
    for _, item in ipairs(record.items) do
        if
            type(item) ~= "table"
            or validSlug(item.slug) == nil
            or normalizeSiteUrl(item.source_url) == nil
            or (tostring(item.thumbnail_url or "") ~= "" and normalizeSiteUrl(item.thumbnail_url) == nil)
        then
            return false
        end
    end
    return true
end

local function validCachedDetail(key, record)
    if
        validSlug(key) == nil
        or type(record) ~= "table"
        or validSlug(record.slug) ~= key
        or tostring(record.id or ""):match("^%d+$") == nil
        or normalizeSiteUrl(record.source_url) == nil
        or type(record.downloads) ~= "table"
        or tonumber(record.fetched_at) == nil
    then
        return false
    end
    local validDownload = false
    for _, quality in ipairs({ "hd", "4k" }) do
        local download = record.downloads[quality]
        if download ~= nil then
            if
                type(download) ~= "table"
                or tostring(download.id or ""):match("^%d+$") == nil
                or tostring(download.quality or ""):lower() ~= quality
                or normalizeSiteUrl(download.url) == nil
            then
                return false
            end
            validDownload = true
        end
    end
    return validDownload
end

local function rebuildOrderedCache(order, values, maximum, validator)
    local reversed = {}
    local seen = {}
    if type(order) == "table" and type(values) == "table" then
        for index = #order, 1, -1 do
            if #reversed >= maximum then
                break
            end
            local key = order[index]
            if type(key) == "string" and not seen[key] then
                seen[key] = true
                local record = values[key]
                if validator(key, record) then
                    table.insert(reversed, { key = key, record = record })
                end
            end
        end
    end

    local rebuiltValues = {}
    local rebuiltOrder = {}
    for index = #reversed, 1, -1 do
        local selected = reversed[index]
        rebuiltValues[selected.key] = selected.record
        table.insert(rebuiltOrder, selected.key)
    end
    return rebuiltValues, rebuiltOrder
end

local function normalizeCache(candidate)
    if type(candidate) ~= "table" or tonumber(candidate.schema) ~= SCHEMA then
        return nil
    end
    local searches, searchOrder =
        rebuildOrderedCache(candidate.search_order, candidate.searches, MAX_CACHE_SEARCHES, validCachedSearch)
    local details, detailOrder =
        rebuildOrderedCache(candidate.detail_order, candidate.details, MAX_CACHE_DETAILS, validCachedDetail)
    return {
        schema = SCHEMA,
        searches = searches,
        search_order = searchOrder,
        details = details,
        detail_order = detailOrder,
    }
end

local function saveCache()
    if cachePath == "" then
        return false
    end
    local encoded, encodeError = noctalia.json.encode(cache, true)
    if type(encoded) ~= "string" or #encoded > MAX_CACHE_BYTES then
        status.last_error_kind = "cache"
        status.last_error = bounded(encodeError or "MotionBGS cache exceeded its safe size", 320)
        return false
    end
    local temporary = cachePath .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        noctalia.removeFile(temporary)
        status.last_error_kind = "cache"
        status.last_error = bounded(writeError or "could not write MotionBGS cache", 320)
        return false
    end
    local installed, installError = noctalia.renameFile(temporary, cachePath)
    if installed ~= true then
        noctalia.removeFile(temporary)
        status.last_error_kind = "cache"
        status.last_error = bounded(installError or "could not install MotionBGS cache", 320)
        return false
    end
    return true
end

local function loadCache()
    if cachePath == "" or not noctalia.fileExists(cachePath) then
        return
    end
    local raw = readBoundedRegularFile(cachePath, MAX_CACHE_BYTES)
    if type(raw) ~= "string" or #raw > MAX_CACHE_BYTES then
        return
    end
    local decoded = noctalia.json.decode(raw)
    local normalized = normalizeCache(decoded)
    if normalized ~= nil then
        cache = normalized
    end
end

local function fresh(timestamp)
    local age = nowSeconds() - (tonumber(timestamp) or 0)
    return age >= 0 and age <= cacheTtlSeconds()
end

local function searchKey(query)
    return query:lower():gsub("%s+", " ")
end

local function cacheSearch(query, sourceUrl, items)
    local key = searchKey(query)
    cache.searches[key] = {
        query = query,
        source_url = sourceUrl,
        fetched_at = nowSeconds(),
        items = items,
    }
    touchOrder(cache.search_order, key)
    trimOrder(cache.search_order, cache.searches, MAX_CACHE_SEARCHES)
    local saved = saveCache()
    local entry = cache.searches[key]
    if not saved then
        cache.searches[key] = nil
        for index = #cache.search_order, 1, -1 do
            if cache.search_order[index] == key then
                table.remove(cache.search_order, index)
            end
        end
    end
    return entry, saved
end

local function cacheDetail(detail)
    cache.details[detail.slug] = detail
    touchOrder(cache.detail_order, detail.slug)
    trimOrder(cache.detail_order, cache.details, MAX_CACHE_DETAILS)
    local saved = saveCache()
    if not saved then
        cache.details[detail.slug] = nil
        for index = #cache.detail_order, 1, -1 do
            if cache.detail_order[index] == detail.slug then
                table.remove(cache.detail_order, index)
            end
        end
    end
    return saved
end

local function setVisibleSearch(entry, nonce, cached)
    results.nonce = nonce
    results.query = tostring(entry.query or "")
    results.source_url = normalizeSiteUrl(entry.source_url) or BASE_URL
    results.cached = cached == true
    results.fetched_at = tonumber(entry.fetched_at) or 0
    results.items = type(entry.items) == "table" and entry.items or {}
    results.selected = {}
    publishResults()
end

local function setVisibleDetail(detail, nonce, cached)
    results.nonce = nonce
    results.cached = cached == true
    results.selected = detail
    publishResults()
end

local function helperResult(result)
    if type(result) ~= "table" then
        return nil, "transport", "MotionBGS helper returned no process result"
    end
    local output = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local protocol, outcome, a, b, c, d, e =
        output:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
    if protocol == "WIO-MBG1" and outcome == "ok" then
        local effectiveUrl = normalizeSiteUrl(b)
        if effectiveUrl == nil then
            return nil, "protocol", "MotionBGS helper returned a cross-origin or malformed effective URL"
        end
        return {
            status = tonumber(a) or 0,
            effective_url = effectiveUrl,
            content_type = c,
            bytes = tonumber(d) or 0,
            path = e,
        },
            nil,
            nil
    end

    local errorProtocol, errorOutcome, kind, detail = output:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorProtocol == "WIO-MBG1" and errorOutcome == "error" then
        return nil, bounded(kind, 80), bounded(detail, 400)
    end
    if result.timedOut == true then
        return nil, "timeout", "MotionBGS helper exceeded Noctalia's process timeout"
    end
    local fallback = bounded(result.stderr or result.stdout, 400)
    if fallback == "" then
        fallback = "MotionBGS helper exited without a valid protocol result"
    end
    return nil, "protocol", fallback
end

local function responsePath(operation)
    operationSequence += 1
    return cacheDirectory .. "/response-" .. tostring(operation.nonce) .. "-" .. tostring(operationSequence) .. ".html"
end

local function enqueue(operation)
    if not providerAvailable() then
        return false, "unavailable"
    end
    if #pendingOperations >= MAX_QUEUE then
        return false, "queue-full"
    end
    operation.generation = operation.generation or operationGeneration
    if operation.generation ~= operationGeneration then
        return false, "cancelled"
    end
    table.insert(pendingOperations, operation)
    publishStatus()
    return true, nil
end

local pumpQueue

local function finishNetworkOperation(operation)
    if activeOperation == operation then
        networkBusy = false
        activeOperation = nil
    end
    publishStatus()
    pumpQueue()
end

local function performSearch(operation, transport)
    local raw = readBoundedRegularFile(transport.path, MAX_HTML_RESPONSE_BYTES)
    noctalia.removeFile(transport.path)
    if type(raw) ~= "string" then
        failNonce(operation.nonce, "search", "local-io", "search response could not be read safely")
        return
    end
    local items, kind, parseError = parseSearchHtml(raw, operation.limit)
    if items == nil then
        failNonce(operation.nonce, "search", kind, parseError)
        return
    end
    local entry, saved = cacheSearch(operation.query, transport.effective_url or operation.url, items)
    setVisibleSearch(entry, operation.nonce, false)
    if not saved then
        failNonce(
            operation.nonce,
            "search",
            "cache",
            status.last_error ~= "" and status.last_error or "Could not persist the MotionBGS search cache"
        )
        return
    end
    completeNonce(operation.nonce, "search")
end

local function enqueueDownload(operation, detail)
    local quality = operation.quality
    local choice = type(detail.downloads) == "table" and detail.downloads[quality] or nil
    if type(choice) ~= "table" or tostring(choice.id or ""):match("^%d+$") == nil then
        failNonce(
            operation.nonce,
            "download",
            "quality",
            "Selected MotionBGS quality is not available for this wallpaper"
        )
        return false
    end
    local queued, enqueueError = enqueue({
        kind = "download",
        nonce = operation.nonce,
        slug = detail.slug,
        id = choice.id,
        title = detail.title,
        quality = quality,
        generation = operation.generation or operationGeneration,
    })
    if not queued then
        if enqueueError == "unavailable" then
            failNonce(operation.nonce, "download", "unavailable", "MotionBGS integration became unavailable")
        elseif enqueueError == "cancelled" then
            failNonce(operation.nonce, "download", "cancelled", "MotionBGS request was cancelled")
        else
            failNonce(operation.nonce, "download", "queue-full", "MotionBGS request queue is full")
        end
    end
    return queued
end

local function performDetails(operation, transport)
    local raw = readBoundedRegularFile(transport.path, MAX_HTML_RESPONSE_BYTES)
    noctalia.removeFile(transport.path)
    if type(raw) ~= "string" then
        failNonce(
            operation.nonce,
            operation.after_download and "download" or "details",
            "local-io",
            "detail response could not be read safely"
        )
        return
    end
    local detail, kind, parseError = parseDetailsHtml(raw, operation.slug)
    if detail == nil then
        failNonce(operation.nonce, operation.after_download and "download" or "details", kind, parseError)
        return
    end
    local saved = cacheDetail(detail)
    setVisibleDetail(detail, operation.nonce, false)
    if not saved then
        failNonce(
            operation.nonce,
            operation.after_download and "download" or "details",
            "cache",
            status.last_error ~= "" and status.last_error or "Could not persist the MotionBGS detail cache"
        )
        return
    end
    if operation.after_download then
        if not enqueueDownload(operation, detail) then
            return
        end
    else
        completeNonce(operation.nonce, "details")
    end
end

local function validatedDownloadPath(operation, transport)
    if type(operation) ~= "table" or type(transport) ~= "table" then
        return nil
    end
    local directory = tostring(operation.download_directory or "")
    local prefix = directory ~= "" and directory .. "/" or ""
    local path = tostring(transport.path or "")
    local basename = if prefix ~= "" and path:sub(1, #prefix) == prefix then path:sub(#prefix + 1) else ""
    local stem = tostring(operation.slug or "") .. "." .. tostring(operation.quality or "")
    local escapedStem = stem:gsub("([^%w])", "%%%1")
    local suffix = basename:match("^" .. escapedStem .. "%-(%d+)%.mp4$")
    local expectedName = basename == stem .. ".mp4"
        or (suffix ~= nil and #suffix <= 4 and tonumber(suffix) ~= nil and tonumber(suffix) <= 9999)
    local info = validAbsolutePath(path) and noctalia.fileInfo(path) or nil
    local sidecarPath = path .. ".motionbgs.json"
    local sidecarRaw = validAbsolutePath(path) and readBoundedRegularFile(sidecarPath, MAX_PROVIDER_SIDECAR_BYTES)
        or nil
    local sidecar = type(sidecarRaw) == "string"
            and #sidecarRaw <= MAX_PROVIDER_SIDECAR_BYTES
            and noctalia.json.decode(sidecarRaw)
        or nil
    local bytes = tonumber(transport.bytes) or 0
    local maximumBytes = (tonumber(operation.download_limit_mb) or 0) * 1024 * 1024
    if
        not validAbsolutePath(path)
        or prefix == ""
        or path:sub(1, #prefix) ~= prefix
        or not expectedName
        or type(info) ~= "table"
        or info.isDir == true
        or bytes <= 0
        or tonumber(info.size) ~= bytes
        or maximumBytes <= 0
        or bytes > maximumBytes
        or (transport.content_type ~= "video/mp4" and transport.content_type ~= "application/octet-stream")
        or (tonumber(transport.status) or 0) < 200
        or (tonumber(transport.status) or 0) >= 300
        or type(sidecar) ~= "table"
        or tonumber(sidecar.schema) ~= 1
        or sidecar.plugin ~= "goober/wall-in-one"
        or sidecar.provider ~= "MotionBGS"
        or sidecar.path ~= path
        or sidecar.source_page ~= BASE_URL .. "/" .. tostring(operation.slug or "")
        or sidecar.download_url ~= transport.effective_url
        or sidecar.quality ~= operation.quality
        or tonumber(sidecar.bytes) ~= bytes
    then
        return nil
    end
    return path
end

local function cleanupCancelledDownload(operation, result)
    local transport = helperResult(result)
    local path = validatedDownloadPath(operation, transport)
    if path ~= nil then
        noctalia.removeFile(path)
        noctalia.removeFile(path .. ".motionbgs.json")
    end
end

local function performDownload(operation, transport)
    local path = validatedDownloadPath(operation, transport)
    if path == nil then
        failNonce(operation.nonce, "download", "protocol", "MotionBGS helper returned an unsafe download result")
        return
    end
    status.last_download = {
        path = path,
        sidecar = path .. ".motionbgs.json",
        slug = operation.slug,
        title = operation.title,
        quality = operation.quality,
        bytes = transport.bytes,
        source_url = BASE_URL .. "/" .. operation.slug,
        download_url = transport.effective_url or "",
        downloaded_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
    }
    completeNonce(operation.nonce, "download")
end

local function launchOperation(operation)
    if
        type(operation) ~= "table"
        or operation.cancelled == true
        or operation.generation ~= operationGeneration
        or not providerAvailable()
    then
        return false
    end
    local command
    local timeout = 30000
    if operation.kind == "search" or operation.kind == "details" then
        operation.response_path = responsePath(operation)
        command = "exec bash "
            .. shellQuote(helperPath)
            .. " fetch-html "
            .. shellQuote(operation.url)
            .. " "
            .. shellQuote(operation.response_path)
    elseif operation.kind == "download" then
        local directory, directoryError = prepareDownloadDirectory()
        if directory == "" then
            failNonce(
                operation.nonce,
                "download",
                "configuration",
                directoryError
            )
            return false
        end
        local info = noctalia.fileInfo(directory)
        if type(info) ~= "table" or info.isDir ~= true then
            failNonce(
                operation.nonce,
                "download",
                "configuration",
                "Configured MotionBGS download directory does not exist"
            )
            return false
        end
        operation.download_directory = directory
        operation.download_limit_mb = configuredDownloadLimit()
        command = "exec bash "
            .. shellQuote(helperPath)
            .. " download "
            .. shellQuote(operation.id)
            .. " "
            .. shellQuote(operation.slug)
            .. " "
            .. shellQuote(operation.quality)
            .. " "
            .. shellQuote(directory)
            .. " "
            .. shellQuote(bounded(operation.title, 240))
            .. " "
            .. shellQuote(tostring(operation.download_limit_mb))
            .. " "
            .. shellQuote(tostring(DOWNLOAD_TIMEOUT_SECONDS))
        timeout = 60000
    else
        failNonce(operation.nonce, operation.kind, "internal", "Unknown MotionBGS queue operation")
        return false
    end

    networkBusy = true
    activeOperation = operation
    lastNetworkStartMs = noctalia.nowMs()
    status.last_request_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishStatus()

    local accepted = noctalia.runAsync(command, function(result)
        if operation.cancelled == true or operation.generation ~= operationGeneration or not providerAvailable() then
            if operation.kind == "download" then
                cleanupCancelledDownload(operation, result)
            end
            cleanupOperationResponse(operation)
            finishNetworkOperation(operation)
            return
        end

        local transport, kind, message = helperResult(result)
        if transport == nil then
            if operation.response_path ~= nil and noctalia.fileExists(operation.response_path) then
                noctalia.removeFile(operation.response_path)
            end
            failNonce(operation.nonce, operation.kind, kind, message)
        elseif transport.effective_url == nil then
            if operation.response_path ~= nil and noctalia.fileExists(operation.response_path) then
                noctalia.removeFile(operation.response_path)
            end
            failNonce(operation.nonce, operation.kind, "protocol", "MotionBGS helper returned a cross-origin URL")
        elseif
            (operation.kind == "search" or operation.kind == "details")
            and transport.path ~= operation.response_path
        then
            if operation.response_path ~= nil and noctalia.fileExists(operation.response_path) then
                noctalia.removeFile(operation.response_path)
            end
            failNonce(operation.nonce, operation.kind, "protocol", "MotionBGS helper returned the wrong response path")
        elseif operation.kind == "search" then
            performSearch(operation, transport)
        elseif operation.kind == "details" then
            performDetails(operation, transport)
        else
            performDownload(operation, transport)
        end
        finishNetworkOperation(operation)
    end, timeout)

    if not accepted then
        networkBusy = false
        activeOperation = nil
        failNonce(operation.nonce, operation.kind, "launch", "Noctalia refused the MotionBGS helper process")
        return false
    end
    return true
end

pumpQueue = function()
    if not providerAvailable() then
        invalidateOperations("MotionBGS integration became unavailable", false)
        return
    end
    if networkBusy or #pendingOperations == 0 then
        return
    end
    if noctalia.nowMs() - lastNetworkStartMs < REQUEST_DELAY_MS then
        return
    end
    local operation = table.remove(pendingOperations, 1)
    launchOperation(operation)
end

local function normalizedQuery(value)
    if type(value) ~= "string" or value:find("[%c]") then
        return nil
    end
    local query = noctalia.string.trim(value):gsub("%s+", " ")
    if query == "" or #query > MAX_QUERY_BYTES then
        return nil
    end
    return query
end

local function handleSearch(command, nonce)
    local query = normalizedQuery(command.query)
    if query == nil then
        failNonce(nonce, "search", "invalid-query", "Search query must be 1-80 bytes and contain no controls")
        return
    end
    local limit = math.floor(tonumber(command.limit) or configuredResultLimit())
    limit = math.max(1, math.min(MAX_RESULTS, limit))
    local cached = cache.searches[searchKey(query)]
    if command.force ~= true and type(cached) == "table" and fresh(cached.fetched_at) then
        setVisibleSearch(cached, nonce, true)
        completeNonce(nonce, "search")
        return
    end
    local url = BASE_URL .. "/search?q=" .. noctalia.string.urlEncode(query)
    local queued, enqueueError = enqueue({ kind = "search", nonce = nonce, query = query, limit = limit, url = url })
    if not queued then
        if enqueueError == "unavailable" then
            failNonce(nonce, "search", "unavailable", "MotionBGS integration became unavailable")
        else
            failNonce(nonce, "search", "queue-full", "MotionBGS request queue is full")
        end
    end
end

local function handleDetails(command, nonce, afterDownload)
    local slug = validSlug(command.slug)
    if slug == nil then
        failNonce(nonce, afterDownload and "download" or "details", "invalid-slug", "MotionBGS slug is invalid")
        return
    end
    local detail = cache.details[slug]
    local quality = tostring(command.quality or configuredQuality()):lower()
    if quality ~= "hd" and quality ~= "4k" then
        failNonce(nonce, afterDownload and "download" or "details", "invalid-quality", "Quality must be hd or 4k")
        return
    end
    if command.force ~= true and type(detail) == "table" and fresh(detail.fetched_at) then
        setVisibleDetail(detail, nonce, true)
        if afterDownload then
            enqueueDownload({ nonce = nonce, quality = quality }, detail)
        else
            completeNonce(nonce, "details")
        end
        return
    end
    local queued, enqueueError = enqueue({
        kind = "details",
        nonce = nonce,
        slug = slug,
        quality = quality,
        after_download = afterDownload,
        url = BASE_URL .. "/" .. slug,
    })
    if not queued then
        local action = afterDownload and "download" or "details"
        if enqueueError == "unavailable" then
            failNonce(nonce, action, "unavailable", "MotionBGS integration became unavailable")
        else
            failNonce(nonce, action, "queue-full", "MotionBGS request queue is full")
        end
    end
end

local function handleCommand(command)
    if type(command) ~= "table" or tonumber(command.schema or SCHEMA) ~= SCHEMA then
        return
    end
    local nonce = nonceValue(command.nonce)
    if nonce == nil or nonce <= status.last_nonce then
        return
    end
    status.last_nonce = nonce
    local action = tostring(command.action or "")
    publishAck(nonce, "accepted", "")
    publishStatus()

    if action == "clear" then
        invalidateOperations("MotionBGS requests were cancelled by cache clear", true)
        cache = { schema = SCHEMA, searches = {}, search_order = {}, details = {}, detail_order = {} }
        results.query = ""
        results.source_url = BASE_URL
        results.cached = false
        results.fetched_at = 0
        results.items = {}
        results.selected = {}
        local saved = saveCache()
        publishResults()
        if not saved then
            failNonce(
                nonce,
                "clear",
                "cache",
                status.last_error ~= "" and status.last_error or "Could not persist the cleared MotionBGS cache"
            )
        else
            completeNonce(nonce, "clear")
        end
        return
    end

    if not status.available then
        failNonce(
            nonce,
            action,
            "unavailable",
            "MotionBGS integration is disabled or curl/helper storage is unavailable"
        )
        return
    end
    if action == "search" then
        handleSearch(command, nonce)
    elseif action == "details" then
        handleDetails(command, nonce, false)
    elseif action == "download" then
        handleDetails(command, nonce, true)
    else
        failNonce(nonce, action, "unsupported-action", "Unsupported MotionBGS action: " .. bounded(action, 80))
    end
    pumpQueue()
end

local function initializeStorage()
    local pluginDirectory = noctalia.pluginDir()
    if validAbsolutePath(pluginDirectory) then
        helperPath = pluginDirectory:gsub("/+$", "") .. "/scripts/motionbgs-provider"
        status.helper_available = noctalia.fileExists(helperPath)
    end
    local directory = noctalia.pluginDataDir()
    if not validAbsolutePath(directory) then
        return
    end
    dataDirectory = directory:gsub("/+$", "")
    cacheDirectory = dataDirectory .. "/motionbgs"
    local made = noctalia.mkdirAll(cacheDirectory)
    if made ~= true then
        cacheDirectory = ""
        return
    end
    cachePath = cacheDirectory .. "/cache-v1.json"
    loadCache()
    if usesManagedDownloadDirectory() then
        -- This is deliberately separate from pluginDataDir()/motionbgs, which
        -- stores only bounded HTML metadata. Do not create a media directory
        -- until the integration is enabled, curl/helper storage is ready, and
        -- the user-selected video root exists.
        prepareDownloadDirectory()
    end
end

function update()
    pumpQueue()
end

function onConfigChanged()
    status.curl_available = noctalia.commandExists("curl")
    status.helper_available = helperPath ~= "" and noctalia.fileExists(helperPath)
    if usesManagedDownloadDirectory() then
        prepareDownloadDirectory()
    end
    if not providerAvailable() then
        local invalidated = invalidateOperations("MotionBGS integration was disabled or became unavailable", false)
        if not invalidated then
            publishStatus()
        end
    else
        publishStatus()
        pumpQueue()
    end
end

function onExit(_signal, _reason)
    -- No cleanup subprocess is needed. In-flight runAsync work is cancelled by
    -- the service host, and the helper installs only complete atomic files.
    operationGeneration += 1
    local cancellation = "MotionBGS service stopped before the request completed"
    local hadOperations = #pendingOperations > 0
        or (type(activeOperation) == "table" and activeOperation.cancelled ~= true)
    cleanupOperationResponse(activeOperation)
    acknowledgeCancellation(activeOperation, cancellation)
    for _, operation in ipairs(pendingOperations) do
        cleanupOperationResponse(operation)
        acknowledgeCancellation(operation, cancellation)
    end
    pendingOperations = {}
    networkBusy = false
    activeOperation = nil
    if hadOperations then
        status.last_action = "cancel"
        status.last_error_kind = "cancelled"
        status.last_error = cancellation
        status.site_changed = false
    end
    status.available = false
    status.busy = false
    status.active_action = ""
    status.queue_depth = 0
    noctalia.state.set(STATUS_KEY, status)
end

noctalia.setUpdateInterval(250)
initializeStorage()
publishResults()
publishStatus()
noctalia.state.watch(COMMAND_KEY, handleCommand)
handleCommand(noctalia.state.get(COMMAND_KEY))

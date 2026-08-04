--!nonstrict
-- Wall-in-One bridge for the separately installed MotionBGS helper.
--
-- Noctalia loads this entry in an isolated ScriptRuntime. Network access,
-- HTML parsing, provider caching, and media installation therefore live in
-- the one-shot wall-in-one-motionbgs program. This bridge only validates
-- settings, serializes bounded requests, validates bounded normalized results,
-- and preserves the plugin's versioned state protocol.

local SCHEMA = 1
local RPC_SCHEMA = 1
local COMMAND_KEY = "wall_in_one_motionbgs_command_v1"
local COMMAND_ACK_KEY = "wall_in_one_motionbgs_command_ack_v1"
local STATUS_KEY = "wall_in_one_motionbgs_status_v1"
local RESULTS_KEY = "wall_in_one_motionbgs_results_v1"
local BASE_URL = "https://motionbgs.com"
local INSTALL_URL = "https://github.com/Go08er/goober-noctalia-plugins-v5/tree/main/motionbgs-helper"
local BINARY_NAME = "wall-in-one-motionbgs"
local PROBE_PROTOCOL = "WIO-MBGS-PROBE1"
local RPC_PROTOCOL = "WIO-MBGS-RPC1"
local MAX_NONCE = 9007199254740991
local MAX_RESULTS = 48
local MAX_QUERY_BYTES = 80
local MAX_PAGE = 10000
local MAX_QUEUE = 8
local MAX_REQUEST_BYTES = 8 * 1024
local MAX_RESPONSE_BYTES = 128 * 1024
local MAX_PROVIDER_SIDECAR_BYTES = 64 * 1024
-- The helper gets a slightly shorter end-to-end budget than the host process.
-- That leaves the launcher/callback five seconds to report and clean up after
-- a bounded 20-second detail request plus request spacing and a 50-second
-- media transfer.
local DOWNLOAD_OPERATION_BUDGET_MS = 75000
local DOWNLOAD_TIMEOUT_MS = 80000
local RPC_OPERATION_BUDGET_MS = 30000
local RPC_TIMEOUT_MS = 40000
local PROBE_TIMEOUT_MS = 5000
local OPERATION_GUARD_CONTENT = "WIO-MBGS-GUARD1\n"
local MANAGED_DOWNLOAD_SUFFIX = "/Wall-in-One/MotionBGS"
local MANAGED_DIRECTORY_MARKER = ".wall-in-one-motionbgs-managed.json"
local MANAGED_DIRECTORY_MARKER_CONTENT =
    '{"schema":1,"owner":"goober/wall-in-one","provider":"MotionBGS","deletion_authority":"adjacent .motionbgs.json sidecar required"}\n'
local MAX_MANAGED_MARKER_BYTES = #MANAGED_DIRECTORY_MARKER_CONTENT

local sequence = 0
local operationSequence = 0
local operationGeneration = 0
local probeGeneration = 0
local probeBusy = false
local probeNonce = 0
local runtimeToken = tostring(math.floor(noctalia.nowMs()))
local activeOperation = nil
local pendingOperations = {}
local dataDirectory = ""
local rpcDirectory = ""
local cacheDirectory = ""
local launcherPath = ""
local binaryCommand = ""

local status = {
    schema = SCHEMA,
    sequence = 0,
    available = false,
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
    launcher_available = false,
    binary_available = false,
    binary_compatible = false,
    binary_path = "",
    binary_source = "",
    binary_version = "",
    binary_protocol = 0,
    probe_state = "idle",
    availability_reason = "initializing",
    install_url = INSTALL_URL,
}

local results = {
    schema = SCHEMA,
    sequence = 0,
    nonce = 0,
    mode = "search",
    query = "",
    genre = "",
    page = 1,
    source_url = BASE_URL,
    cached = false,
    fetched_at = 0,
    items = {},
    meta = {
        current_page = 1,
        has_previous = false,
        has_next = false,
        pageable = false,
        total_hint = 0,
    },
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

local function settingString(key, fallback)
    local value = noctalia.getConfig(key)
    return if type(value) == "string" then noctalia.string.trim(value) else fallback
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
        and #value > 1
        and #value <= 4096
        and value:sub(1, 1) == "/"
        and value:find("[%c\\]") == nil
        and not value:find("//", 1, true)
        and not value:find("/./", 1, true)
        and not value:match("/%.$")
        and not value:find("/../", 1, true)
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
    if not validAbsolutePath(directory) then
        return ""
    end
    return directory:gsub("/+$", "")
end

local function configuredVideoRootExists()
    local root = configuredDirectory("video_directory")
    local info = root ~= "" and noctalia.fileInfo(root) or nil
    return type(info) == "table" and info.isDir == true
end

local function configuredDownloadDirectory()
    local root = configuredDirectory("video_directory")
    return if root == "" then "" else root .. MANAGED_DOWNLOAD_SUFFIX
end

local function configuredResultLimit()
    return settingInt("motionbgs_result_limit", MAX_RESULTS, 1, MAX_RESULTS)
end

local function configuredCacheSeconds()
    return settingInt("motionbgs_cache_minutes", 30, 5, 1440) * 60
end

local function configuredDownloadLimit()
    return settingInt("motionbgs_max_download_mb", 256, 16, 512)
end

local function configuredQuality()
    return if settingString("motionbgs_quality", "hd"):lower() == "4k" then "4k" else "hd"
end

local function nonceValue(value)
    local nonce = tonumber(value)
    if nonce == nil or nonce ~= math.floor(nonce) or nonce <= 0 or nonce > MAX_NONCE then
        return nil
    end
    return nonce
end

local function validSlug(value)
    if type(value) ~= "string" or #value < 1 or #value > 120 then
        return nil
    end
    local slug = value:lower()
    return if slug:match("^[a-z0-9][a-z0-9-]*$") ~= nil then slug else nil
end

local function normalizedQuery(value)
    if type(value) ~= "string" or value:find("[%c]") ~= nil then
        return nil
    end
    local query = noctalia.string.trim(value):gsub("%s+", " ")
    return if query ~= "" and #query <= MAX_QUERY_BYTES then query else nil
end

local function normalizedBrowseRequest(candidate)
    local mode = tostring(type(candidate) == "table" and candidate.mode or "search"):lower()
    if mode ~= "search" and mode ~= "latest" and mode ~= "genre" and mode ~= "4k" and mode ~= "hd" then
        return nil, "Browse mode must be search, latest, genre, 4k, or hd"
    end
    local page = tonumber(type(candidate) == "table" and candidate.page or 1)
    if page == nil or page ~= math.floor(page) or page < 1 or page > MAX_PAGE then
        return nil, "Page must be an integer from 1 through " .. tostring(MAX_PAGE)
    end
    local query = ""
    local genre = ""
    if mode == "search" then
        query = normalizedQuery(candidate.query)
        if query == nil then
            return nil, "Search query must be 1-80 bytes and contain no controls"
        elseif page ~= 1 then
            return nil, "MotionBGS text search does not expose pagination"
        end
    elseif mode == "genre" then
        genre = validSlug(candidate.genre)
        if genre == nil then
            return nil, "Genre/tag must be a lowercase MotionBGS slug such as nature or anime"
        end
    elseif mode == "hd" and page ~= 1 then
        return nil, "MotionBGS HD browsing is limited to the first page"
    end
    return { mode = mode, query = query, genre = genre, page = page }, nil
end

local function normalizeSiteUrl(value)
    if type(value) ~= "string" or #value < #BASE_URL or #value > 2048 or value:find("[%c\\#]") ~= nil then
        return nil
    end
    if value ~= BASE_URL and value:sub(1, #BASE_URL + 1) ~= BASE_URL .. "/" then
        return nil
    end
    local path = value:sub(#BASE_URL + 1)
    if path:find("/../", 1, true) or path:match("/%.%.$") then
        return nil
    end
    return value
end

local function sitePath(value)
    local normalized = normalizeSiteUrl(value)
    if normalized == nil then
        return nil
    end
    local suffix = normalized:sub(#BASE_URL + 1)
    local path = suffix:match("^([^?]*)") or ""
    path = path:gsub("/+$", "")
    return if path == "" then "/" else path
end

local function canonicalSearchSlug(value)
    local query = normalizedQuery(value)
    return if query ~= nil then validSlug(query:lower():gsub("%s+", "-")) else nil
end

local function queryEncode(value)
    local encoded = {}
    local hex = "0123456789ABCDEF"
    local text = tostring(value or "")
    for index = 1, #text do
        local byte = string.byte(text, index)
        local unreserved = (byte >= 65 and byte <= 90)
            or (byte >= 97 and byte <= 122)
            or (byte >= 48 and byte <= 57)
            or byte == 45
            or byte == 46
            or byte == 95
            or byte == 126
        if byte == 32 then
            table.insert(encoded, "+")
        elseif unreserved then
            table.insert(encoded, string.char(byte))
        else
            local high = math.floor(byte / 16) + 1
            local low = (byte % 16) + 1
            table.insert(encoded, "%" .. hex:sub(high, high) .. hex:sub(low, low))
        end
    end
    return table.concat(encoded)
end

local function listingRouteMatches(request, value)
    local actual = sitePath(value)
    if actual == nil then
        return false
    end
    if request.mode == "search" then
        local canonical = canonicalSearchSlug(request.query)
        local expected = BASE_URL .. "/search?q=" .. queryEncode(request.query)
        return value == expected
            or (value:find("?", 1, true) == nil and canonical ~= nil and actual == "/tag:" .. canonical)
    elseif request.mode == "latest" then
        return value:find("?", 1, true) == nil
            and actual == (if request.page == 1 then "/" else "/" .. tostring(request.page))
    elseif request.mode == "genre" then
        return value:find("?", 1, true) == nil
            and actual == "/tag:" .. request.genre .. (if request.page == 1 then "" else "/" .. tostring(request.page))
    elseif request.mode == "4k" then
        return value:find("?", 1, true) == nil
            and actual == "/4k" .. (if request.page == 1 then "" else "/" .. tostring(request.page))
    end
    return value:find("?", 1, true) == nil and actual == "/hd"
end

local function normalizeStillImageUrl(value)
    local normalized = normalizeSiteUrl(value)
    if normalized == nil then
        return nil
    end
    local mediaId, filename = normalized:match(
        "^https://motionbgs%.com/media/([0-9]+)/([A-Za-z0-9][A-Za-z0-9._-]*)$"
    )
    if mediaId == nil then
        local width, height
        width, height, mediaId, filename = normalized:match(
            "^https://motionbgs%.com/i/c/([1-9][0-9]*)x([1-9][0-9]*)/media/([0-9]+)/([A-Za-z0-9][A-Za-z0-9._-]*)$"
        )
        if width == nil or tonumber(width) > 4096 or height == nil or tonumber(height) > 4096 then
            return nil
        end
    end
    if mediaId == nil or #mediaId > 12 or filename == nil or #filename > 240 then
        return nil
    end
    local lower = filename:lower()
    return if lower:match("%.jpe?g$") or lower:match("%.png$") or lower:match("%.webp$") then normalized else nil
end

local function providerAvailable()
    return settingBool("use_motionbgs", true)
        and configuredVideoRootExists()
        and dataDirectory ~= ""
        and cacheDirectory ~= ""
        and status.launcher_available == true
        and status.binary_compatible == true
        and probeBusy ~= true
end

local function publishStatus()
    sequence += 1
    status.sequence = sequence
    status.busy = probeBusy or type(activeOperation) == "table"
    status.active_action = if probeBusy then "probe" elseif type(activeOperation) == "table" then tostring(activeOperation.kind or "") else ""
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
    noctalia.log("wall-in-one MotionBGS bridge: " .. status.last_error_kind .. ": " .. status.last_error)
    publishStatus()
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
    if directory == "" or not configuredVideoRootExists() then
        return "", "Select an existing Wall-in-One video directory first"
    end
    local made, makeError = noctalia.mkdirAll(directory)
    if made ~= true then
        return "", tostring(makeError or "could not create the managed MotionBGS directory")
    end
    local marked, markerError = writeManagedDirectoryMarker(directory)
    if marked ~= true then
        return "", markerError
    end
    return directory, nil
end

local function initializeStorage()
    dataDirectory = ""
    rpcDirectory = ""
    cacheDirectory = ""
    launcherPath = ""
    status.launcher_available = false
    local pluginDirectory = noctalia.pluginDir()
    local pluginDataDirectory = noctalia.pluginDataDir()
    if validAbsolutePath(pluginDirectory) then
        launcherPath = pluginDirectory:gsub("/+$", "") .. "/scripts/motionbgs-provider"
    end
    status.launcher_available = validAbsolutePath(launcherPath) and noctalia.fileExists(launcherPath)
    if not validAbsolutePath(pluginDataDirectory) then
        status.availability_reason = "storage-unavailable"
        return false
    end
    if not settingBool("use_motionbgs", true) or not configuredVideoRootExists() then
        status.availability_reason = if settingBool("use_motionbgs", true) then "video-root-missing" else "disabled"
        return true
    end
    dataDirectory = pluginDataDirectory:gsub("/+$", "") .. "/motionbgs-bridge-v1"
    cacheDirectory = dataDirectory .. "/cache"
    rpcDirectory = cacheDirectory .. "/rpc"
    if noctalia.mkdirAll(cacheDirectory) ~= true or noctalia.mkdirAll(rpcDirectory) ~= true then
        dataDirectory = ""
        rpcDirectory = ""
        cacheDirectory = ""
        status.availability_reason = "storage-unavailable"
        return false
    end
    -- Successful calls remove both files. A killed shell can strand a tiny
    -- request/response pair, so clear only our strictly named transient files
    -- when this service runtime starts; the helper cache is separate.
    local rpcNames = noctalia.listDir(rpcDirectory)
    if type(rpcNames) == "table" then
        for _, name in ipairs(rpcNames) do
            if type(name) == "string"
                and #name <= 160
                and (name:match("^request%-%d+%-%d+%-%d+%.json%.tmp$")
                    or name:match("^request%-%d+%-%d+%-%d+%.json$")
                    or name:match("^response%-%d+%-%d+%-%d+%.json%.tmp$")
                    or name:match("^response%-%d+%-%d+%-%d+%.json$")
                    or name:match("^%.wall%-in%-one%-motionbgs%-guard%-%d+%-%d+%-%d+%.tmp$")
                    or name:match("^%.wall%-in%-one%-motionbgs%-guard%-%d+%-%d+%-%d+$"))
            then
                noctalia.removeFile(rpcDirectory .. "/" .. name)
            end
        end
    end
    -- cache-v2 held HTML-era plugin cache. The external helper owns its new
    -- schema and never reads the retired file.
    local legacy = pluginDataDirectory:gsub("/+$", "") .. "/motionbgs/cache-v2.json"
    if noctalia.fileExists(legacy) then
        noctalia.removeFile(legacy)
    end
    return true
end

local function configuredBinary()
    local configured = settingString("motionbgs_binary_path", "")
    if configured ~= "" then
        local expanded = noctalia.expandPath(configured)
        local info = validAbsolutePath(expanded) and noctalia.fileInfo(expanded) or nil
        if type(info) == "table" and info.isDir ~= true and (tonumber(info.size) or 0) > 0 then
            return expanded, "configured", ""
        end
        return "", "configured", "Configured MotionBGS helper path is not a readable regular file"
    end
    if noctalia.commandExists(BINARY_NAME) then
        return BINARY_NAME, "path", ""
    end
    return "", "path", "Install wall-in-one-motionbgs or select its absolute path"
end

local function cleanupOperationFiles(operation)
    if type(operation) ~= "table" then
        return
    end
    -- Removing the guard first is the process-boundary cancellation signal.
    -- The request and response are transport artifacts and can follow it.
    for _, path in ipairs({ operation.guard_path, operation.request_path, operation.response_path }) do
        if validAbsolutePath(path) and noctalia.fileExists(path) then
            noctalia.removeFile(path)
        end
    end
end

local function invalidateOperations(message)
    operationGeneration += 1
    local detail = bounded(message, 400)
    for _, operation in ipairs(pendingOperations) do
        cleanupOperationFiles(operation)
        if nonceValue(operation.nonce) ~= nil then
            publishAck(operation.nonce, "error", detail)
        end
    end
    pendingOperations = {}
    if type(activeOperation) == "table" then
        cleanupOperationFiles(activeOperation)
        if nonceValue(activeOperation.nonce) ~= nil then
            publishAck(activeOperation.nonce, "error", detail)
        end
        activeOperation.cancelled = true
    end
    activeOperation = nil
    publishStatus()
end

local function processFailureDetail(result, fallback)
    if type(result) ~= "table" then
        return fallback
    end
    local detail = bounded(result.stderr, 400)
    if detail == "" then
        detail = bounded(result.stdout, 400)
    end
    return if detail ~= "" then detail else fallback
end

local function probeResult(result)
    if type(result) ~= "table" then
        return nil, "probe-failed", "MotionBGS helper returned no probe result"
    end
    if result.timedOut == true then
        return nil, "probe-failed", "MotionBGS helper probe timed out"
    end
    local line = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local errorProtocol, errorOutcome, errorKind, errorDetail = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorProtocol == PROBE_PROTOCOL and errorOutcome == "error" then
        return nil, bounded(errorKind, 80), bounded(errorDetail, 400)
    end
    if tonumber(result.exitCode) ~= 0 then
        return nil, "probe-failed", processFailureDetail(result, "MotionBGS helper probe failed")
    end
    local protocol, outcome, versionProtocol, version, capabilities = line:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    if protocol ~= PROBE_PROTOCOL or outcome ~= "ok" or tonumber(versionProtocol) ~= RPC_SCHEMA then
        return nil, "binary-incompatible", "MotionBGS helper uses an incompatible protocol"
    end
    if #version > 80 or version:find("[%c]") ~= nil or #capabilities > 200 then
        return nil, "binary-incompatible", "MotionBGS helper probe fields exceed protocol bounds"
    end
    local found = {}
    for capability in capabilities:gmatch("[^,]+") do
        found[capability] = true
    end
    for _, required in ipairs({ "search", "details", "download", "clear" }) do
        if not found[required] then
            return nil, "binary-incompatible", "MotionBGS helper is missing capability: " .. required
        end
    end
    return { version = version, protocol = RPC_SCHEMA }, nil, nil
end

local pumpQueue

local function publishProbeFailure(commandNonce, state, message)
    status.binary_compatible = false
    status.probe_state = state
    status.availability_reason = state
    if commandNonce > 0 then
        probeNonce = 0
        failNonce(commandNonce, "probe", state, message)
    else
        local expectedConfigurationGap = state == "disabled" or state == "video-root-missing"
        status.last_error_kind = if expectedConfigurationGap then "" else state
        status.last_error = if expectedConfigurationGap then "" else bounded(message, 400)
        publishStatus()
    end
end

local function startProbe(_force, commandNonce)
    local requestedNonce = nonceValue(commandNonce) or 0
    if probeNonce > 0 and probeNonce ~= requestedNonce then
        publishAck(probeNonce, "error", "MotionBGS helper probe was superseded")
    end
    probeNonce = requestedNonce
    probeGeneration += 1
    local generation = probeGeneration
    probeBusy = false
    status.binary_available = false
    status.binary_compatible = false
    status.binary_version = ""
    status.binary_protocol = 0
    status.binary_path = ""
    status.binary_source = ""
    if not settingBool("use_motionbgs", true) then
        publishProbeFailure(requestedNonce, "disabled", "MotionBGS integration is disabled")
        return
    end
    if not configuredVideoRootExists() then
        publishProbeFailure(requestedNonce, "video-root-missing", "Select an existing video directory first")
        return
    end
    if not status.launcher_available then
        publishProbeFailure(requestedNonce, "launcher-missing", "The bundled MotionBGS launcher is missing")
        return
    end
    local selected, source, selectionError = configuredBinary()
    status.binary_source = source
    if selected == "" then
        publishProbeFailure(requestedNonce, "binary-missing", selectionError)
        return
    end
    binaryCommand = selected
    status.binary_available = true
    status.binary_path = selected
    status.probe_state = "probing"
    status.availability_reason = "probing"
    probeBusy = true
    publishStatus()
    local command = "exec bash "
        .. shellQuote(launcherPath)
        .. " probe "
        .. shellQuote(binaryCommand)
    local started = noctalia.runAsync(command, function(result)
        if generation ~= probeGeneration then
            return
        end
        probeBusy = false
        local probe, kind, message = probeResult(result)
        if probe == nil then
            publishProbeFailure(requestedNonce, kind, message)
            return
        end
        status.binary_compatible = true
        status.binary_version = probe.version
        status.binary_protocol = probe.protocol
        status.probe_state = "ready"
        status.availability_reason = "ready"
        status.last_error_kind = ""
        status.last_error = ""
        prepareDownloadDirectory()
        if requestedNonce > 0 then
            probeNonce = 0
            completeNonce(requestedNonce, "probe")
        else
            publishStatus()
        end
        pumpQueue()
    end, PROBE_TIMEOUT_MS)
    if started ~= true then
        probeBusy = false
        publishProbeFailure(requestedNonce, "probe-failed", "Noctalia refused the MotionBGS helper probe")
    end
end

local function normalizeSearchItem(item)
    if type(item) ~= "table" then
        return nil
    end
    local slug = validSlug(item.slug)
    local sourceUrl = normalizeSiteUrl(item.source_url)
    local thumbnail = tostring(item.thumbnail_url or "")
    if slug == nil or sourceUrl ~= BASE_URL .. "/" .. slug then
        return nil
    end
    if thumbnail ~= "" then
        thumbnail = normalizeStillImageUrl(thumbnail)
        if thumbnail == nil then
            return nil
        end
    end
    local identifier = tostring(item.id or "")
    if identifier ~= "" and (identifier:match("^%d+$") == nil or #identifier > 12) then
        return nil
    end
    return {
        slug = slug,
        id = identifier,
        title = bounded(item.title ~= "" and item.title or slug, 240),
        quality = bounded(item.quality, 20):upper(),
        source_url = sourceUrl,
        thumbnail_url = thumbnail,
        provider = "MotionBGS",
    }
end

local function normalizeMeta(candidate, request, itemCount)
    if type(candidate) ~= "table" then
        return nil
    end
    local page = request.page
    local currentPage = tonumber(candidate.current_page)
    local totalHint = tonumber(candidate.total_hint)
    if currentPage ~= page or totalHint == nil or totalHint < 0 or totalHint > MAX_NONCE then
        return nil
    end
    if type(candidate.has_previous) ~= "boolean"
        or type(candidate.has_next) ~= "boolean"
        or type(candidate.pageable) ~= "boolean"
    then
        return nil
    end
    local expectedPageable = request.mode == "latest" or request.mode == "genre" or request.mode == "4k"
    if candidate.pageable ~= expectedPageable
        or (not expectedPageable and (candidate.has_previous or candidate.has_next))
        or (page == 1 and candidate.has_previous)
    then
        return nil
    end
    return {
        current_page = page,
        has_previous = candidate.has_previous,
        has_next = candidate.has_next,
        pageable = candidate.pageable,
        total_hint = math.floor(totalHint),
        count = itemCount,
    }
end

local function normalizeDetail(candidate, expectedSlug)
    if type(candidate) ~= "table" then
        return nil
    end
    local slug = validSlug(candidate.slug)
    local identifier = tostring(candidate.id or "")
    local sourceUrl = normalizeSiteUrl(candidate.source_url)
    local fetchedAt = if type(candidate.fetched_at) == "number" then candidate.fetched_at else nil
    local poster = tostring(candidate.poster_url or "")
    local preview = tostring(candidate.preview_url or "")
    if slug ~= expectedSlug
        or identifier:match("^%d+$") == nil
        or #identifier > 12
        or fetchedAt == nil
        or fetchedAt < 0
        or fetchedAt > 9999999999
        or math.floor(fetchedAt) ~= fetchedAt
    then
        return nil
    end
    if sourceUrl ~= BASE_URL .. "/" .. slug then
        return nil
    end
    if poster ~= "" then
        poster = normalizeStillImageUrl(poster)
        if poster == nil then
            return nil
        end
    end
    if preview ~= "" and normalizeSiteUrl(preview) == nil then
        return nil
    end
    local downloads = {}
    for _, quality in ipairs({ "hd", "4k" }) do
        local value = type(candidate.downloads) == "table" and candidate.downloads[quality] or nil
        if value ~= nil then
            local id = type(value) == "table" and tostring(value.id or "") or ""
            local url = type(value) == "table" and normalizeSiteUrl(value.url) or nil
            if id:match("^%d+$") == nil
                or #id > 12
                or tostring(value.quality or ""):lower() ~= quality
                or url ~= BASE_URL .. "/dl/" .. quality .. "/" .. id .. "/"
            then
                return nil
            end
            downloads[quality] = {
                id = id,
                quality = quality,
                label = quality:upper(),
                resolution = bounded(value.resolution, 40),
                advertised_size_mb = math.max(0, tonumber(value.advertised_size_mb) or 0),
                url = url,
            }
        end
    end
    if next(downloads) == nil then
        return nil
    end
    local identifierMatches = false
    for _, download in pairs(downloads) do
        if type(download) == "table" and download.id == identifier then
            identifierMatches = true
            break
        end
    end
    if not identifierMatches then
        return nil
    end
    return {
        slug = slug,
        id = identifier,
        title = bounded(candidate.title ~= "" and candidate.title or slug, 240),
        source_url = sourceUrl,
        preview_url = preview,
        poster_url = poster,
        thumbnail_url = poster,
        duration = bounded(candidate.duration, 40),
        downloads = downloads,
        fetched_at = fetchedAt,
        provider = "MotionBGS",
    }
end

local function resetResults(nonce)
    results.nonce = nonce or 0
    results.mode = "search"
    results.query = ""
    results.genre = ""
    results.page = 1
    results.source_url = BASE_URL
    results.cached = false
    results.fetched_at = 0
    results.items = {}
    results.meta = {
        current_page = 1,
        has_previous = false,
        has_next = false,
        pageable = false,
        total_hint = 0,
    }
    results.selected = {}
    publishResults()
end

local function validateDownload(operation, candidate, detail)
    if type(candidate) ~= "table" then
        return nil
    end
    local directory = tostring(operation.download_directory or "")
    local prefix = directory ~= "" and directory .. "/" or ""
    local path = tostring(candidate.path or "")
    local basename = prefix ~= "" and path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or ""
    local stem = tostring(operation.slug or "") .. "." .. tostring(operation.quality or "")
    local escapedStem = stem:gsub("([^%w])", "%%%1")
    local suffix = basename:match("^" .. escapedStem .. "%-(%d+)%.mp4$")
    local expectedName = basename == stem .. ".mp4"
        or (suffix ~= nil and #suffix <= 4 and tonumber(suffix) ~= nil and tonumber(suffix) <= 9999)
    if not validAbsolutePath(path) or basename == "" or basename:find("/", 1, true) or not expectedName then
        return nil
    end
    local sidecarPath = tostring(candidate.sidecar or "")
    if sidecarPath ~= path .. ".motionbgs.json" then
        return nil
    end
    local info = noctalia.fileInfo(path)
    local bytes = math.floor(tonumber(candidate.bytes) or 0)
    local maximum = configuredDownloadLimit() * 1024 * 1024
    local sidecarRaw = readBoundedRegularFile(sidecarPath, MAX_PROVIDER_SIDECAR_BYTES)
    local sidecar = type(sidecarRaw) == "string" and noctalia.json.decode(sidecarRaw) or nil
    local expectedDownload = type(detail) == "table"
            and type(detail.downloads) == "table"
            and type(detail.downloads[operation.quality]) == "table"
            and detail.downloads[operation.quality].url
        or nil
    local normalizedDownload = type(sidecar) == "table" and normalizeSiteUrl(sidecar.download_url) or nil
    local expectedId = type(detail) == "table"
            and type(detail.downloads) == "table"
            and type(detail.downloads[operation.quality]) == "table"
            and tostring(detail.downloads[operation.quality].id or "")
        or ""
    local mediaId = type(normalizedDownload) == "string" and normalizedDownload:match(
        "^https://motionbgs%.com/media/([0-9]+)/[A-Za-z0-9][A-Za-z0-9._-]*%.mp4$"
    ) or nil
    local downloadRouteMatches = normalizedDownload == expectedDownload
        or (mediaId ~= nil and mediaId == expectedId)
    local digest = tostring(candidate.sha256 or "")
    local contentType = tostring(candidate.content_type or "")
    local downloadedAt = tostring(candidate.downloaded_at or "")
    if type(info) ~= "table"
        or info.isDir == true
        or bytes < 1
        or bytes > maximum
        or math.floor(tonumber(info.size) or 0) ~= bytes
        or type(sidecar) ~= "table"
        or tonumber(sidecar.schema) ~= 1
        or sidecar.plugin ~= "goober/wall-in-one"
        or sidecar.provider ~= "MotionBGS"
        or sidecar.path ~= path
        or sidecar.title ~= detail.title
        or sidecar.source_page ~= BASE_URL .. "/" .. tostring(operation.slug or "")
        or not downloadRouteMatches
        or sidecar.quality ~= operation.quality
        or tonumber(sidecar.bytes) ~= bytes
        or contentType ~= tostring(sidecar.content_type or "")
        or (contentType ~= "video/mp4" and contentType ~= "application/octet-stream")
        or digest:match("^[0-9a-f]+$") == nil
        or #digest ~= 64
        or sidecar.sha256 ~= digest
        or sidecar.downloaded_at ~= downloadedAt
        or candidate.slug ~= operation.slug
        or candidate.title ~= detail.title
        or candidate.quality ~= operation.quality
        or candidate.source_url ~= sidecar.source_page
        or candidate.download_url ~= sidecar.download_url
        or downloadedAt:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") == nil
    then
        return nil
    end
    return {
        path = path,
        sidecar = sidecarPath,
        slug = operation.slug,
        title = bounded(candidate.title, 240),
        quality = operation.quality,
        bytes = bytes,
        source_url = sidecar.source_page,
        download_url = normalizedDownload,
        downloaded_at = bounded(candidate.downloaded_at, 80),
    }
end

local function applyRpcResponse(operation, payload)
    if type(payload) ~= "table"
        or tonumber(payload.schema) ~= RPC_SCHEMA
        or tostring(payload.request_id or "") ~= operation.request_id
        or tostring(payload.action or "") ~= operation.kind
    then
        return false, "protocol", "MotionBGS helper returned a mismatched response envelope"
    end
    if payload.ok ~= true then
        local failure = type(payload.error) == "table" and payload.error or {}
        return false, bounded(failure.kind or "provider", 80), bounded(failure.message or "MotionBGS request failed", 400)
    end
    if operation.kind == "search" then
        local sourceUrl = normalizeSiteUrl(payload.source_url)
        local fetchedAt = if type(payload.fetched_at) == "number" then payload.fetched_at else nil
        local rawItems = type(payload.items) == "table" and payload.items or nil
        if sourceUrl == nil
            or not listingRouteMatches(operation.request, sourceUrl)
            or payload.mode ~= operation.request.mode
            or payload.query ~= operation.request.query
            or payload.genre ~= operation.request.genre
            or tonumber(payload.page) ~= operation.request.page
            or (payload.cached ~= true and payload.cached ~= false)
            or fetchedAt == nil
            or fetchedAt < 0
            or fetchedAt > 9999999999
            or math.floor(fetchedAt) ~= fetchedAt
            or rawItems == nil
            or #rawItems > operation.limit
        then
            return false, "protocol", "MotionBGS helper returned an invalid search result"
        end
        local items = {}
        for _, rawItem in ipairs(rawItems) do
            local item = normalizeSearchItem(rawItem)
            if item == nil then
                return false, "protocol", "MotionBGS helper returned an unsafe search item"
            end
            table.insert(items, item)
        end
        local meta = normalizeMeta(payload.meta, operation.request, #items)
        if meta == nil then
            return false, "protocol", "MotionBGS helper returned invalid pagination metadata"
        end
        results.nonce = operation.nonce
        results.mode = operation.request.mode
        results.query = operation.request.query
        results.genre = operation.request.genre
        results.page = operation.request.page
        results.source_url = sourceUrl
        results.cached = payload.cached
        results.fetched_at = fetchedAt
        results.items = items
        results.meta = meta
        results.selected = {}
        publishResults()
    elseif operation.kind == "details" then
        local detail = normalizeDetail(payload.selected, operation.slug)
        local responseSource = normalizeSiteUrl(payload.source_url)
        local fetchedAt = if type(payload.fetched_at) == "number" then payload.fetched_at else nil
        if detail == nil
            or (payload.cached ~= true and payload.cached ~= false)
            or responseSource ~= detail.source_url
            or fetchedAt == nil
            or fetchedAt ~= detail.fetched_at
        then
            return false, "protocol", "MotionBGS helper returned an unsafe detail record"
        end
        results.nonce = operation.nonce
        results.cached = payload.cached
        results.fetched_at = fetchedAt
        results.selected = detail
        publishResults()
    elseif operation.kind == "download" then
        local detail = normalizeDetail(payload.selected, operation.slug)
        local responseSource = normalizeSiteUrl(payload.source_url)
        local fetchedAt = if type(payload.fetched_at) == "number" then payload.fetched_at else nil
        if detail == nil
            or (payload.cached ~= true and payload.cached ~= false)
            or responseSource ~= detail.source_url
            or fetchedAt == nil
            or fetchedAt ~= detail.fetched_at
        then
            return false, "protocol", "MotionBGS helper returned an unsafe download detail"
        end
        local download = validateDownload(operation, payload.download, detail)
        if download == nil then
            return false, "protocol", "MotionBGS helper returned an unsafe download installation"
        end
        results.nonce = operation.nonce
        results.cached = payload.cached
        results.fetched_at = fetchedAt
        results.selected = detail
        publishResults()
        status.last_download = download
    elseif operation.kind == "clear" then
        if payload.cleared ~= true then
            return false, "protocol", "MotionBGS helper returned an invalid clear result"
        end
        resetResults(operation.nonce)
    else
        return false, "protocol", "MotionBGS helper returned an unsupported action"
    end
    return true, nil, nil
end

local function launcherRpcResult(operation, result)
    if type(result) ~= "table" then
        return nil, "transport", "MotionBGS launcher returned no process result"
    end
    if result.timedOut == true then
        return nil, "timeout", "MotionBGS helper exceeded its bounded process timeout"
    end
    local line = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local errorProtocol, errorOutcome, kind, detail = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorProtocol == RPC_PROTOCOL and errorOutcome == "error" then
        return nil, bounded(kind, 80), bounded(detail, 400)
    end
    if tonumber(result.exitCode) ~= 0 then
        return nil, "transport", processFailureDetail(result, "MotionBGS helper process failed")
    end
    local protocol, outcome, requestId, path, bytes = line:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    if protocol == RPC_PROTOCOL and outcome == "ok" then
        local expectedBytes = math.floor(tonumber(bytes) or 0)
        if requestId ~= operation.request_id
            or path ~= operation.response_path
            or expectedBytes < 1
            or expectedBytes > MAX_RESPONSE_BYTES
        then
            return nil, "protocol", "MotionBGS launcher completion envelope did not match the request"
        end
        local raw = readBoundedRegularFile(path, MAX_RESPONSE_BYTES)
        if type(raw) ~= "string" or #raw ~= expectedBytes then
            return nil, "protocol", "MotionBGS launcher response file was missing or changed"
        end
        local decoded = noctalia.json.decode(raw)
        if type(decoded) ~= "table" then
            return nil, "protocol", "MotionBGS launcher response was not valid JSON"
        end
        return decoded, nil, nil
    end
    return nil, "protocol", processFailureDetail(result, "MotionBGS launcher returned an invalid envelope")
end

local function atomicWriteJson(path, value)
    local encoded, encodeError = noctalia.json.encode(value, true)
    if type(encoded) ~= "string" or #encoded + 1 > MAX_REQUEST_BYTES then
        return false, tostring(encodeError or "request exceeded its protocol size limit")
    end
    local temporary = path .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(writeError or "could not write request staging file")
    end
    local installed, installError = noctalia.renameFile(temporary, path)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or "could not install request file")
    end
    return true, nil
end

local function atomicWriteGuard(path)
    if not validAbsolutePath(path) then
        return false, "guard path is invalid"
    end
    local temporary = path .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, OPERATION_GUARD_CONTENT)
    if wrote ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(writeError or "could not write cancellation guard")
    end
    local installed, installError = noctalia.renameFile(temporary, path)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or "could not install cancellation guard")
    end
    return true, nil
end

local function finishOperation(operation)
    cleanupOperationFiles(operation)
    if activeOperation == operation then
        activeOperation = nil
    end
    publishStatus()
    pumpQueue()
end

local function requestPaths(operation)
    operationSequence += 1
    local token = runtimeToken .. "-" .. tostring(operation.nonce) .. "-" .. tostring(operationSequence)
    return rpcDirectory .. "/request-" .. token .. ".json",
        rpcDirectory .. "/response-" .. token .. ".json",
        rpcDirectory .. "/.wall-in-one-motionbgs-guard-" .. token
end

local function requestPayload(operation)
    local payload = {
        schema = RPC_SCHEMA,
        request_id = operation.request_id,
        action = operation.kind,
        cache_directory = cacheDirectory,
        cache_ttl_seconds = configuredCacheSeconds(),
        guard_path = operation.guard_path,
        operation_timeout_ms = if operation.kind == "download"
            then DOWNLOAD_OPERATION_BUDGET_MS
            else RPC_OPERATION_BUDGET_MS,
    }
    if operation.kind == "search" then
        payload.mode = operation.request.mode
        payload.query = operation.request.query
        payload.genre = operation.request.genre
        payload.page = operation.request.page
        payload.limit = operation.limit
        payload.force = operation.force == true
    elseif operation.kind == "details" then
        payload.slug = operation.slug
        payload.force = operation.force == true
    elseif operation.kind == "download" then
        payload.slug = operation.slug
        payload.quality = operation.quality
        payload.force = operation.force == true
        payload.max_download_bytes = configuredDownloadLimit() * 1024 * 1024
        payload.download_timeout_seconds = 50
        payload.download_directory = operation.download_directory
        payload.managed_marker_path = operation.download_directory .. "/" .. MANAGED_DIRECTORY_MARKER
    end
    return payload
end

local function launchOperation(operation)
    if type(operation) ~= "table"
        or operation.cancelled == true
        or operation.generation ~= operationGeneration
        or not providerAvailable()
    then
        return false
    end
    if operation.kind == "download" then
        local directory, directoryError = prepareDownloadDirectory()
        if directory == "" then
            failNonce(operation.nonce, operation.kind, "configuration", directoryError)
            return false
        end
        operation.download_directory = directory
    end
    operation.request_id = tostring(operation.nonce) .. "-" .. tostring(operationSequence + 1)
    operation.request_path, operation.response_path, operation.guard_path = requestPaths(operation)
    local guarded, guardError = atomicWriteGuard(operation.guard_path)
    if not guarded then
        failNonce(operation.nonce, operation.kind, "local-io", guardError)
        cleanupOperationFiles(operation)
        return false
    end
    local wrote, writeError = atomicWriteJson(operation.request_path, requestPayload(operation))
    if not wrote then
        failNonce(operation.nonce, operation.kind, "local-io", writeError)
        cleanupOperationFiles(operation)
        return false
    end
    activeOperation = operation
    status.last_request_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishStatus()
    local command = "exec bash "
        .. shellQuote(launcherPath)
        .. " rpc "
        .. shellQuote(binaryCommand)
        .. " "
        .. shellQuote(operation.request_path)
        .. " "
        .. shellQuote(operation.response_path)
        .. " "
        .. shellQuote(operation.guard_path)
    local timeout = if operation.kind == "download" then DOWNLOAD_TIMEOUT_MS else RPC_TIMEOUT_MS
    local started = noctalia.runAsync(command, function(result)
        if operation.cancelled == true or operation.generation ~= operationGeneration then
            cleanupOperationFiles(operation)
            if activeOperation == operation then
                activeOperation = nil
            end
            publishStatus()
            pumpQueue()
            return
        end
        local payload, kind, message = launcherRpcResult(operation, result)
        if payload == nil then
            failNonce(operation.nonce, operation.kind, kind, message)
        else
            local applied, applyKind, applyError = applyRpcResponse(operation, payload)
            if applied then
                completeNonce(operation.nonce, operation.kind)
            else
                failNonce(operation.nonce, operation.kind, applyKind, applyError)
            end
        end
        finishOperation(operation)
    end, timeout)
    if started ~= true then
        activeOperation = nil
        failNonce(operation.nonce, operation.kind, "launch", "Noctalia refused the MotionBGS helper process")
        cleanupOperationFiles(operation)
        return false
    end
    return true
end

pumpQueue = function()
    if activeOperation ~= nil or probeBusy or not providerAvailable() or #pendingOperations == 0 then
        return
    end
    local operation = table.remove(pendingOperations, 1)
    if not launchOperation(operation) then
        publishStatus()
        pumpQueue()
    end
end

local function enqueue(operation)
    if not providerAvailable() then
        return false, "unavailable"
    end
    if #pendingOperations >= MAX_QUEUE then
        return false, "queue-full"
    end
    operation.generation = operationGeneration
    table.insert(pendingOperations, operation)
    publishStatus()
    pumpQueue()
    return true, nil
end

local function queueOrFail(operation)
    local queued, reason = enqueue(operation)
    if not queued then
        failNonce(
            operation.nonce,
            operation.kind,
            reason,
            if reason == "queue-full" then "MotionBGS request queue is full" else "MotionBGS helper is unavailable"
        )
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
    if action == "probe" then
        invalidateOperations("MotionBGS requests were cancelled by a helper reprobe")
        startProbe(true, nonce)
        return
    end
    if not providerAvailable() then
        failNonce(nonce, action, "unavailable", "MotionBGS integration requires a compatible external helper")
        return
    end
    if action == "search" then
        local request, requestError = normalizedBrowseRequest(command)
        if request == nil then
            failNonce(nonce, action, "invalid-browse", requestError)
            return
        end
        queueOrFail({
            kind = action,
            nonce = nonce,
            request = request,
            limit = math.max(1, math.min(MAX_RESULTS, math.floor(tonumber(command.limit) or configuredResultLimit()))),
            force = command.force == true,
        })
    elseif action == "details" or action == "download" then
        local slug = validSlug(command.slug)
        if slug == nil then
            failNonce(nonce, action, "invalid-slug", "MotionBGS slug is invalid")
            return
        end
        local quality = tostring(command.quality or configuredQuality()):lower()
        if quality ~= "hd" and quality ~= "4k" then
            failNonce(nonce, action, "invalid-quality", "Quality must be hd or 4k")
            return
        end
        queueOrFail({
            kind = action,
            nonce = nonce,
            slug = slug,
            quality = quality,
            force = command.force == true,
        })
    elseif action == "clear" then
        queueOrFail({ kind = action, nonce = nonce })
    else
        failNonce(nonce, action, "unsupported-action", "Unsupported MotionBGS action: " .. bounded(action, 80))
    end
end

function onConfigChanged()
    invalidateOperations("MotionBGS configuration changed")
    initializeStorage()
    startProbe(true)
end

function onExit(_signal, _reason)
    probeGeneration += 1
    probeBusy = false
    invalidateOperations("MotionBGS service stopped before the request completed")
    status.available = false
    status.busy = false
    status.active_action = ""
    status.queue_depth = 0
    status.probe_state = "stopped"
    status.availability_reason = "stopped"
    noctalia.state.set(STATUS_KEY, status)
end

initializeStorage()
resetResults(0)
publishStatus()
noctalia.state.watch(COMMAND_KEY, handleCommand)
handleCommand(noctalia.state.get(COMMAND_KEY))
startProbe(false)

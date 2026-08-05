--!nonstrict
-- Thin Wallhaven bridge for the separately installed Wall-in-One backend.
--
-- Noctalia loads this service in an isolated ScriptRuntime with a strict CPU
-- budget. Network I/O, rate limiting, JSON response shaping, image validation,
-- and no-replace installation therefore live in wall-in-one-backend. This
-- service only discovers that program, writes bounded request envelopes,
-- incrementally validates normalized results, and preserves the public v1
-- command/status/results state protocol consumed by the coordinator and panel.

local SCHEMA = 1
local RPC_SCHEMA = 1
local COMMAND_KEY = "wall_in_one_wallhaven_command_v1"
local STATUS_KEY = "wall_in_one_wallhaven_status_v1"
local RESULTS_KEY = "wall_in_one_wallhaven_results_v1"
local BACKEND_STATUS_KEY = "wall_in_one_backend_status_v1"
local API_ORIGIN = "https://wallhaven.cc"
local SITE_ORIGIN = "https://wallhaven.cc"
local SHORT_ORIGIN = "https://whvn.cc"
local CDN_ORIGIN = "https://w.wallhaven.cc"
local THUMB_ORIGIN = "https://th.wallhaven.cc"
local INSTALL_URL = "https://github.com/Go08er/goober-noctalia-plugins-v5/tree/main/wall-in-one-backend"
local BINARY_NAME = "wall-in-one-backend"
local BACKEND_POINTER_NAME = "backend-path"
local MAX_BACKEND_POINTER_BYTES = 4097
local PROBE_PROTOCOL = "WIO-BACKEND-PROBE1"
local RPC_PROTOCOL = "WIO-BACKEND-RPC1"
local GUARD_CONTENT = "WIO-BACKEND-GUARD1\n"
local REQUIRED_CAPABILITIES = {
    ["wallhaven.search"] = true,
    ["wallhaven.detail"] = true,
    ["wallhaven.download"] = true,
    ["wallhaven.clear"] = true,
}

local MAX_NONCE = 9007199254740991
local MAX_RESULTS = 24
local MAX_TAGS = 48
local MAX_TEXT_BYTES = 512
local MAX_URL_BYTES = 2048
local MAX_PATH_BYTES = 4096
local MAX_REQUEST_BYTES = 64 * 1024
-- scripts/backend-provider is the enforcing boundary. Provider results are
-- normalized metadata and must fit its current 128 KiB response profile.
local MAX_RESPONSE_BYTES = 128 * 1024
local VALIDATION_BATCH = 4
local PROBE_TIMEOUT_MS = 5000
local RPC_OPERATION_BUDGET_MS = 45000
local DOWNLOAD_OPERATION_BUDGET_MS = 120000
local RPC_TIMEOUT_MS = 55000
local DOWNLOAD_TIMEOUT_MS = 130000
local MANAGED_DIRECTORY_SUFFIX = "/Wall-in-One/Wallhaven"

local statusSequence = 0
local resultsSequence = 0
local operationSequence = 0
local operationGeneration = 0
local probeGeneration = 0
local runtimeToken = tostring(math.floor(noctalia.nowMs()))
local running = true
local dataDirectory = ""
local transportDirectory = ""
local launcherPath = ""
local binaryCommand = ""
local probeBusy = false
local activeOperation = nil
local completedProbes = {}
local completedTransports = {}
local validation = nil

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
    local previousNonce = math.floor(tonumber(previousStatus.last_nonce) or 0)
    local previousCompleted = math.floor(tonumber(previousStatus.last_completed_nonce) or 0)
    if previousSequence >= 0 and previousSequence <= MAX_NONCE then
        statusSequence = previousSequence
    end
    if previousNonce >= 0 and previousNonce <= MAX_NONCE then
        status.last_nonce = previousNonce
    end
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

local function nowText()
    return noctalia.formatTime("%Y-%m-%d %H:%M:%S")
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

local function settingBool(key, fallback)
    local value = noctalia.getConfig(key)
    return if type(value) == "boolean" then value else fallback
end

local function validAbsolutePath(value)
    return type(value) == "string"
        and #value > 1
        and #value <= MAX_PATH_BYTES
        and value:sub(1, 1) == "/"
        and value:sub(-1) ~= "/"
        and value:find("[%c\\]") == nil
        and not value:find("//", 1, true)
        and not value:find("/./", 1, true)
        and not value:match("/%.$")
        and not value:find("/../", 1, true)
        and not value:match("/%.%.$")
end

local function directChildOf(path, directory)
    if not validAbsolutePath(path) or not validAbsolutePath(directory) then
        return false
    end
    directory = directory:gsub("/+$", "")
    if path:sub(1, #directory + 1) ~= directory .. "/" then
        return false
    end
    local name = path:sub(#directory + 2)
    return name ~= "" and not name:find("/", 1, true) and name:find("[%c]") == nil
end

local function readBoundedRegularFile(path, maximumBytes)
    if not validAbsolutePath(path) or maximumBytes < 1 then
        return nil
    end
    local info = noctalia.fileInfo(path)
    local bytes = type(info) == "table" and math.floor(tonumber(info.size) or 0) or 0
    if type(info) ~= "table" or info.isDir == true or bytes < 1 or bytes > maximumBytes then
        return nil
    end
    local raw = noctalia.readFile(path)
    return if type(raw) == "string" and #raw == bytes then raw else nil
end

local function nonceValue(value)
    local nonce = tonumber(value)
    if nonce == nil or nonce ~= math.floor(nonce) or nonce <= 0 or nonce > MAX_NONCE then
        return nil
    end
    return nonce
end

local function validWallpaperId(value)
    if type(value) ~= "string" then
        return nil
    end
    local identifier = value:lower()
    return if #identifier == 6 and identifier:match("^[a-z0-9]+$") ~= nil then identifier else nil
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
    if #key > 256 or key:find("[%c:]") or key:match("^[%w_-]+$") == nil then
        return "", "The Wallhaven API key setting contains unsupported characters"
    end
    return key, nil
end

local function configuredImageRoot()
    local configured = settingString("capture_directory", "")
    if configured == "" then
        return ""
    end
    local root = noctalia.expandPath(configured)
    root = type(root) == "string" and root:gsub("/+$", "") or ""
    if not validAbsolutePath(root) then
        return ""
    end
    local info = noctalia.fileInfo(root)
    return if type(info) == "table" and info.isDir == true then root else ""
end

local function managedDirectory()
    local root = configuredImageRoot()
    if root == "" then
        return ""
    end
    local directory = root .. MANAGED_DIRECTORY_SUFFIX
    return if validAbsolutePath(directory) then directory else ""
end

local function validatedExecutable(path, sourceLabel)
    if not validAbsolutePath(path) then
        return "", sourceLabel .. " is not a safe absolute path"
    end
    local info = noctalia.fileInfo(path)
    if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) <= 0 then
        return "", sourceLabel .. " is not a readable non-empty regular file"
    end
    if noctalia.commandExists(path) ~= true then
        return "", sourceLabel .. " is not executable"
    end
    return path, ""
end

local function pointerBinary()
    local pluginDataDirectory = noctalia.pluginDataDir()
    if not validAbsolutePath(pluginDataDirectory) then
        return "", false, "Backend pointer storage is unavailable"
    end
    local pointerPath = pluginDataDirectory:gsub("/+$", "") .. "/" .. BACKEND_POINTER_NAME
    if not noctalia.fileExists(pointerPath) then
        return "", false, ""
    end
    local raw = readBoundedRegularFile(pointerPath, MAX_BACKEND_POINTER_BYTES)
    if type(raw) ~= "string" then
        return "", true, "Backend pointer is not a bounded non-empty regular file"
    end
    if raw:sub(-1) == "\n" then
        raw = raw:sub(1, -2)
    end
    if raw == "" or raw:find("[\r\n]") ~= nil then
        return "", true, "Backend pointer must contain exactly one path line"
    end
    local selected, reason = validatedExecutable(raw, "Backend pointer target")
    return selected, true, reason
end

local function configuredBinary()
    local configured = settingString("backend_binary_path", "")
    if configured ~= "" then
        local selected, reason = validatedExecutable(noctalia.expandPath(configured), "Configured Wall-in-One backend path")
        return selected, "configured", reason
    end
    local pointed, pointerPresent, pointerError = pointerBinary()
    if pointerPresent then
        return pointed, "pointer", pointerError
    end
    if noctalia.commandExists(BINARY_NAME) then
        return BINARY_NAME, "path", ""
    end
    return "", "path", "Install wall-in-one-backend with the in-app setup commands"
end

local function refreshAvailability()
    local key, keyError = apiKey()
    local rootReady = configuredImageRoot() ~= ""
    status.ready = running
    status.running = running
    status.authenticated = key ~= ""
    status.configuration_error = tostring(keyError or "")
    status.available = running
        and settingBool("use_wallhaven", true)
        and rootReady
        and keyError == nil
        and status.launcher_available == true
        and status.binary_compatible == true
        and probeBusy ~= true
    if not running then
        status.availability_reason = "stopped"
    elseif not settingBool("use_wallhaven", true) then
        status.availability_reason = "disabled"
    elseif not rootReady then
        status.availability_reason = "image-root-missing"
    elseif keyError ~= nil then
        status.availability_reason = "configuration"
    elseif status.probe_state ~= "ready" then
        status.availability_reason = status.probe_state
    else
        status.availability_reason = "ready"
    end
end

local function publishStatus()
    refreshAvailability()
    status.busy = probeBusy or type(activeOperation) == "table" or type(validation) == "table"
    status.active_action = if type(activeOperation) == "table" then tostring(activeOperation.action or "") else ""
    status.active_nonce = if type(activeOperation) == "table" then tonumber(activeOperation.nonce) or 0 else 0
    status.active_id = if type(activeOperation) == "table" and activeOperation.action == "download"
        then tostring(activeOperation.id or "")
        else ""
    statusSequence += 1
    status.sequence = statusSequence
    status.updated_at = nowText()
    noctalia.state.set(STATUS_KEY, status)
end

local function publishResults()
    resultsSequence += 1
    results.sequence = resultsSequence
    noctalia.state.set(RESULTS_KEY, results)
end

local function failNonce(nonce, action, kind, message)
    status.last_completed_nonce = math.max(status.last_completed_nonce, tonumber(nonce) or 0)
    status.last_action = tostring(action or "")
    status.last_error_kind = bounded(kind or "backend", 80)
    status.last_error = bounded(message or "Wallhaven request failed", MAX_TEXT_BYTES)
    noctalia.log("wall-in-one Wallhaven bridge: " .. status.last_error_kind .. ": " .. status.last_error)
    publishStatus()
end

local function completeNonce(nonce, action)
    status.last_completed_nonce = math.max(status.last_completed_nonce, tonumber(nonce) or 0)
    status.last_action = tostring(action or "")
    status.last_error_kind = ""
    status.last_error = ""
    status.last_success_at = nowText()
    publishStatus()
end

local function resetResults(nonce)
    results.nonce = tonumber(nonce) or 0
    results.kind = "empty"
    results.source_url = SITE_ORIGIN
    results.filters = {}
    results.meta = {}
    results.items = {}
    results.selected = {}
    publishResults()
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

local function initializeStorage()
    dataDirectory = ""
    transportDirectory = ""
    launcherPath = ""
    status.launcher_available = false
    local pluginDirectory = noctalia.pluginDir()
    local pluginDataDirectory = noctalia.pluginDataDir()
    if validAbsolutePath(pluginDirectory) then
        launcherPath = pluginDirectory:gsub("/+$", "") .. "/scripts/backend-provider"
    end
    status.launcher_available = validAbsolutePath(launcherPath) and noctalia.fileExists(launcherPath)
    if not validAbsolutePath(pluginDataDirectory) then
        status.probe_state = "storage-unavailable"
        return false
    end
    dataDirectory = pluginDataDirectory:gsub("/+$", "")
    transportDirectory = dataDirectory .. "/wallhaven-bridge-v2/rpc"
    if noctalia.mkdirAll(transportDirectory) ~= true then
        dataDirectory = ""
        transportDirectory = ""
        status.probe_state = "storage-unavailable"
        return false
    end
    local names = noctalia.listDir(transportDirectory)
    if type(names) == "table" then
        for _, name in ipairs(names) do
            if type(name) == "string"
                and #name <= 180
                and (
                    name:match("^request%-%d+%-%d+%-%d+%.json%.tmp$")
                    or name:match("^request%-%d+%-%d+%-%d+%.json$")
                    or name:match("^response%-%d+%-%d+%-%d+%.json$")
                    or name:match("^%.wall%-in%-one%-backend%-guard%-%d+%-%d+%-%d+$")
                    or name:match("^%.wall%-in%-one%-backend%-wallhaven%-key%-%d+%-%d+%-%d+$")
                )
            then
                noctalia.removeFile(transportDirectory .. "/" .. name)
            end
        end
    end
    return true
end

local function probeResult(result)
    if type(result) ~= "table" then
        return nil, "probe-failed", "Wall-in-One backend returned no probe result"
    elseif result.timedOut == true then
        return nil, "probe-failed", "Wall-in-One backend probe timed out"
    end
    local line = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local errorWire, outcome, kind, detail = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorWire == PROBE_PROTOCOL and outcome == "error" then
        return nil, bounded(kind, 80), bounded(detail, 400)
    elseif tonumber(result.exitCode) ~= 0 then
        return nil, "probe-failed", processFailureDetail(result, "Wall-in-One backend probe failed")
    end
    local wire, success, protocol, version, capabilities = line:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    if wire ~= PROBE_PROTOCOL or success ~= "ok" or tonumber(protocol) ~= RPC_SCHEMA then
        return nil, "binary-incompatible", "Wall-in-One backend uses an incompatible protocol"
    end
    local found = {}
    for capability in tostring(capabilities):gmatch("[^,]+") do
        found[capability] = true
    end
    for capability, _ in pairs(REQUIRED_CAPABILITIES) do
        if found[capability] ~= true then
            return nil, "binary-incompatible", "Wall-in-One backend is missing capability: " .. capability
        end
    end
    if #version > 80 or version:find("[%c]") ~= nil or #capabilities > 400 then
        return nil, "binary-incompatible", "Wall-in-One backend probe fields exceed protocol bounds"
    end
    return { protocol = RPC_SCHEMA, version = version }, nil, nil
end

local function startProbe()
    probeGeneration += 1
    local generation = probeGeneration
    probeBusy = false
    binaryCommand = ""
    status.binary_available = false
    status.binary_compatible = false
    status.binary_path = ""
    status.binary_source = ""
    status.binary_version = ""
    status.binary_protocol = 0
    if dataDirectory == "" or transportDirectory == "" then
        status.probe_state = "storage-unavailable"
        status.last_error_kind = status.probe_state
        status.last_error = "Wallhaven backend transport storage is unavailable"
        publishStatus()
        return
    elseif not status.launcher_available then
        status.probe_state = "launcher-missing"
        status.last_error_kind = status.probe_state
        status.last_error = "The bundled Wall-in-One backend launcher is unavailable"
        publishStatus()
        return
    end
    local selected, source, selectionError = configuredBinary()
    status.binary_source = source
    if selected == "" then
        status.probe_state = "binary-missing"
        status.last_error_kind = status.probe_state
        status.last_error = bounded(selectionError .. ". Get it from " .. INSTALL_URL, 400)
        publishStatus()
        return
    end
    binaryCommand = selected
    status.binary_available = true
    status.binary_path = selected
    status.probe_state = "probing"
    probeBusy = true
    publishStatus()
    local command = "exec bash " .. shellQuote(launcherPath) .. " probe " .. shellQuote(binaryCommand)
    local started = noctalia.runAsync(command, function(result)
        table.insert(completedProbes, { generation = generation, result = result })
    end, PROBE_TIMEOUT_MS)
    if started ~= true then
        probeBusy = false
        status.probe_state = "probe-failed"
        status.last_error_kind = status.probe_state
        status.last_error = "Noctalia refused the Wall-in-One backend probe"
        publishStatus()
    end
end

local function processCompletedProbe()
    local completed = table.remove(completedProbes, 1)
    if type(completed) ~= "table" then
        return false
    end
    if completed.generation ~= probeGeneration then
        return true
    end
    probeBusy = false
    local probe, kind, message = probeResult(completed.result)
    if probe == nil then
        status.binary_compatible = false
        status.probe_state = kind
        status.last_error_kind = bounded(kind, 80)
        status.last_error = bounded(message, 400)
    else
        status.binary_compatible = true
        status.binary_version = probe.version
        status.binary_protocol = probe.protocol
        status.probe_state = "ready"
        status.last_error_kind = ""
        status.last_error = ""
        status.configuration_error = ""
    end
    publishStatus()
    return true
end

local function atomicWrite(path, content, maximumBytes)
    if not validAbsolutePath(path) or type(content) ~= "string" or #content < 1 or #content > maximumBytes then
        return false, "transport content is invalid"
    end
    local temporary = path .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, content)
    if wrote ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(writeError or "could not write transport staging file")
    end
    local installed, installError = noctalia.renameFile(temporary, path)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or "could not install transport file")
    end
    return true, nil
end

local function cleanupOperationFiles(operation, keepResponse)
    if type(operation) ~= "table" then
        return
    end
    for _, path in ipairs({ operation.guard_path, operation.request_path, operation.api_key_path }) do
        if validAbsolutePath(path) and noctalia.fileExists(path) then
            noctalia.removeFile(path)
        end
    end
    if keepResponse ~= true
        and validAbsolutePath(operation.response_path)
        and noctalia.fileExists(operation.response_path)
    then
        noctalia.removeFile(operation.response_path)
    end
end

local function requestPaths(operation)
    operationSequence += 1
    local token = runtimeToken .. "-" .. tostring(operation.nonce) .. "-" .. tostring(operationSequence)
    return transportDirectory .. "/request-" .. token .. ".json",
        transportDirectory .. "/response-" .. token .. ".json",
        transportDirectory .. "/.wall-in-one-backend-guard-" .. token,
        transportDirectory .. "/.wall-in-one-backend-wallhaven-key-" .. token
end

local function requestPayload(operation)
    local payload = {
        schema = RPC_SCHEMA,
        request_id = operation.request_id,
        action = "wallhaven." .. operation.action,
        transport_directory = transportDirectory,
        guard_path = operation.guard_path,
        operation_timeout_ms = if operation.action == "download"
            then DOWNLOAD_OPERATION_BUDGET_MS
            else RPC_OPERATION_BUDGET_MS,
        api_key_path = operation.api_key_path or "",
    }
    if operation.action == "search" then
        payload.filters = operation.filters
    elseif operation.action == "detail" then
        payload.id = operation.id
    elseif operation.action == "download" then
        payload.item = operation.item
        payload.image_root = operation.image_root
        payload.target_path = operation.target_path
    end
    return payload
end

local function launcherTransport(operation, result)
    if type(result) ~= "table" then
        return nil, "transport", "Wall-in-One backend returned no process result"
    elseif result.timedOut == true then
        return nil, "timeout", "Wall-in-One backend exceeded its bounded process timeout"
    end
    local line = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local errorWire, outcome, kind, detail = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorWire == RPC_PROTOCOL and outcome == "error" then
        return nil, bounded(kind, 80), bounded(detail, 400)
    elseif tonumber(result.exitCode) ~= 0 then
        return nil, "transport", processFailureDetail(result, "Wall-in-One backend process failed")
    end
    local wire, success, requestId, path, bytes = line:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    local expectedBytes = math.floor(tonumber(bytes) or 0)
    if wire ~= RPC_PROTOCOL
        or success ~= "ok"
        or requestId ~= operation.request_id
        or path ~= operation.response_path
        or not directChildOf(path, transportDirectory)
        or expectedBytes < 2
        or expectedBytes > MAX_RESPONSE_BYTES
    then
        return nil, "protocol", "Wall-in-One backend returned an invalid Wallhaven completion envelope"
    end
    local raw = readBoundedRegularFile(path, MAX_RESPONSE_BYTES)
    if type(raw) ~= "string" or #raw ~= expectedBytes then
        return nil, "protocol", "Wall-in-One backend response was missing or changed"
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table" then
        return nil, "protocol", "Wall-in-One backend response was not valid JSON"
    end
    return decoded, nil, nil
end

local function finiteInteger(value, fallback, minimum, maximum)
    local number = tonumber(value)
    if number == nil or number ~= math.floor(number) or number < minimum or number > maximum then
        return fallback
    end
    return number
end

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
    for _, candidate in ipairs(type(value) == "table" and value or {}) do
        if #colors >= 8 then
            break
        end
        local color = type(candidate) == "string" and candidate:lower() or ""
        if color:match("^#[%da-f][%da-f][%da-f][%da-f][%da-f][%da-f]$") then
            table.insert(colors, color)
        end
    end
    return colors
end

local function normalizedTags(value)
    local tags = {}
    for _, candidate in ipairs(type(value) == "table" and value or {}) do
        if #tags >= MAX_TAGS then
            break
        end
        if type(candidate) == "table" then
            local id = finiteInteger(candidate.id, 0, 0, MAX_NONCE)
            local name = bounded(candidate.name, 160)
            if id > 0 and name ~= "" then
                table.insert(tags, {
                    id = id,
                    name = name,
                    alias = bounded(candidate.alias, 160),
                    category = bounded(candidate.category, 80),
                    purity = bounded(candidate.purity, 16),
                })
            end
        end
    end
    return tags
end

local function normalizeWallpaper(value, includeDetail)
    if type(value) ~= "table" then
        return nil
    end
    local id = validWallpaperId(value.id)
    local path, extension = normalizedCdnUrl(value.path, id or "")
    if id == nil or path == nil then
        return nil
    end
    local fileType = bounded(value.file_type, 32):lower()
    if (extension == "jpg" and fileType ~= "image/jpeg") or (extension == "png" and fileType ~= "image/png") then
        return nil
    end
    local dimensionX = finiteInteger(value.dimension_x, 0, 0, 1000000)
    local dimensionY = finiteInteger(value.dimension_y, 0, 0, 1000000)
    local item = {
        id = id,
        url = SITE_ORIGIN .. "/w/" .. id,
        short_url = SHORT_ORIGIN .. "/" .. id,
        path = path,
        extension = extension,
        file_type = fileType,
        file_size = finiteInteger(value.file_size, 0, 0, MAX_NONCE),
        views = finiteInteger(value.views, 0, 0, MAX_NONCE),
        favorites = finiteInteger(value.favorites, 0, 0, MAX_NONCE),
        purity = bounded(value.purity, 16),
        category = bounded(value.category, 32),
        dimension_x = dimensionX,
        dimension_y = dimensionY,
        resolution = if dimensionX > 0 and dimensionY > 0
            then tostring(dimensionX) .. "x" .. tostring(dimensionY)
            else bounded(value.resolution, 32),
        ratio = bounded(value.ratio, 32),
        source = bounded(value.source, MAX_TEXT_BYTES),
        created_at = bounded(value.created_at, 64),
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
        item.uploader = if type(value.uploader) == "table" then {
            username = bounded(value.uploader.username, 80),
            group = bounded(value.uploader.group, 40),
        } else {}
    end
    return item
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

local function validSourceUrl(value, action)
    if type(value) ~= "string" or #value > MAX_URL_BYTES or value:find("[%c]") then
        return nil
    end
    if action == "search" then
        return if value:sub(1, #API_ORIGIN + 15) == API_ORIGIN .. "/api/v1/search?" then value else nil
    elseif action == "detail" then
        return if value:sub(1, #API_ORIGIN + 10) == API_ORIGIN .. "/api/v1/w/" then value else nil
    end
    return nil
end

local function filtersMatch(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then
        return false
    end
    for _, key in ipairs({
        "query",
        "categories",
        "purity",
        "sorting",
        "order",
        "atleast",
        "resolutions",
        "ratios",
        "colors",
        "top_range",
        "seed",
        "page",
    }) do
        if left[key] ~= right[key] then
            return false
        end
    end
    return true
end

local function validateDownloadResult(operation, value)
    if type(value) ~= "table" then
        return nil
    end
    local id = validWallpaperId(value.id)
    local path = tostring(value.path or "")
    local sidecar = tostring(value.sidecar or "")
    local bytes = finiteInteger(value.bytes, 0, 1, 64 * 1024 * 1024)
    local info = validAbsolutePath(path) and noctalia.fileInfo(path) or nil
    if id ~= operation.id
        or tostring(value.url or "") ~= operation.item.path
        or path ~= operation.target_path
        or sidecar ~= path .. ".wallhaven.json"
        or bytes ~= operation.item.file_size
        or tonumber(value.dimension_x) ~= operation.item.dimension_x
        or tonumber(value.dimension_y) ~= operation.item.dimension_y
        or type(info) ~= "table"
        or info.isDir == true
        or math.floor(tonumber(info.size) or 0) ~= bytes
        or not noctalia.fileExists(sidecar)
        or bounded(value.downloaded_at, 80) == ""
    then
        return nil
    end
    return {
        id = id,
        url = operation.item.path,
        path = path,
        sidecar = sidecar,
        bytes = bytes,
        dimension_x = operation.item.dimension_x,
        dimension_y = operation.item.dimension_y,
        downloaded_at = bounded(value.downloaded_at, 80),
    }
end

local function beginValidation(operation, payload)
    local expectedAction = "wallhaven." .. operation.action
    if type(payload) ~= "table"
        or tonumber(payload.schema) ~= RPC_SCHEMA
        or tostring(payload.request_id or "") ~= operation.request_id
        or tostring(payload.action or "") ~= expectedAction
    then
        return false, "protocol", "Wall-in-One backend returned a mismatched Wallhaven response envelope"
    end
    if payload.ok ~= true then
        local failure = type(payload.error) == "table" and payload.error or {}
        return false, bounded(failure.kind or "provider", 80), bounded(failure.message or "Wallhaven request failed", 400)
    end
    if operation.action == "search" then
        local sourceUrl = validSourceUrl(payload.source_url, "search")
        local items = type(payload.items) == "table" and payload.items or nil
        if payload.kind ~= "search"
            or sourceUrl == nil
            or items == nil
            or #items > MAX_RESULTS
            or not filtersMatch(payload.filters, operation.filters)
        then
            return false, "protocol", "Wall-in-One backend returned an invalid Wallhaven search result"
        end
        validation = {
            operation = operation,
            payload = payload,
            source_url = sourceUrl,
            raw_items = items,
            items = {},
            index = 1,
        }
        return true, nil, nil
    elseif operation.action == "detail" then
        local selected = normalizeWallpaper(payload.selected, true)
        local sourceUrl = validSourceUrl(payload.source_url, "detail")
        if payload.kind ~= "detail"
            or selected == nil
            or selected.id ~= operation.id
            or sourceUrl ~= API_ORIGIN .. "/api/v1/w/" .. operation.id
        then
            return false, "protocol", "Wall-in-One backend returned an invalid Wallhaven detail result"
        end
        results.nonce = operation.nonce
        results.kind = "detail"
        results.source_url = sourceUrl
        results.selected = selected
        publishResults()
    elseif operation.action == "download" then
        local download = validateDownloadResult(operation, payload.download)
        if payload.kind ~= "download" or download == nil then
            return false, "protocol", "Wall-in-One backend returned an invalid Wallhaven download installation"
        end
        status.last_download = download
    else
        return false, "protocol", "Wall-in-One backend returned an unsupported Wallhaven response"
    end
    return true, nil, nil
end

local function finishOperation(operation)
    cleanupOperationFiles(operation, false)
    if activeOperation == operation then
        activeOperation = nil
    end
    validation = nil
    publishStatus()
end

local function stepValidation()
    local context = validation
    if type(context) ~= "table" then
        return false
    end
    local budget = VALIDATION_BATCH
    while budget > 0 and context.index <= #context.raw_items do
        local item = normalizeWallpaper(context.raw_items[context.index], false)
        if item == nil then
            local operation = context.operation
            failNonce(operation.nonce, operation.action, "protocol", "Wall-in-One backend returned an unsafe Wallhaven item")
            finishOperation(operation)
            return true
        end
        table.insert(context.items, item)
        context.index += 1
        budget -= 1
    end
    if context.index <= #context.raw_items then
        return true
    end
    local operation = context.operation
    local payload = context.payload
    local meta = type(payload.meta) == "table" and payload.meta or {}
    results.nonce = operation.nonce
    results.kind = "search"
    results.source_url = context.source_url
    results.filters = operation.filters
    results.meta = {
        current_page = finiteInteger(meta.current_page, tonumber(results.filters.page) or 1, 1, 10000),
        last_page = finiteInteger(meta.last_page, tonumber(results.filters.page) or 1, 1, MAX_NONCE),
        per_page = finiteInteger(meta.per_page, MAX_RESULTS, 1, MAX_RESULTS),
        total = finiteInteger(meta.total, #context.items, 0, MAX_NONCE),
        seed = bounded(meta.seed, 32),
        dropped = finiteInteger(meta.dropped, 0, 0, MAX_NONCE),
    }
    results.items = context.items
    results.selected = {}
    publishResults()
    completeNonce(operation.nonce, operation.action)
    finishOperation(operation)
    return true
end

local function processCompletedTransport()
    local completed = table.remove(completedTransports, 1)
    if type(completed) ~= "table" then
        return false
    end
    local operation = completed.operation
    if type(operation) ~= "table" or operation.cancelled == true or operation.generation ~= operationGeneration then
        cleanupOperationFiles(operation, false)
        return true
    end
    local payload, kind, message = launcherTransport(operation, completed.result)
    cleanupOperationFiles(operation, true)
    if payload == nil then
        failNonce(operation.nonce, operation.action, kind, message)
        finishOperation(operation)
        return true
    end
    local started, validationKind, validationMessage = beginValidation(operation, payload)
    if not started then
        failNonce(operation.nonce, operation.action, validationKind, validationMessage)
        finishOperation(operation)
        return true
    end
    if type(validation) ~= "table" then
        completeNonce(operation.nonce, operation.action)
        finishOperation(operation)
    else
        publishStatus()
    end
    return true
end

local function launchOperation(operation, key)
    operation.request_path, operation.response_path, operation.guard_path, operation.api_key_path = requestPaths(operation)
    operation.request_id = tostring(operation.nonce) .. "-" .. tostring(operationSequence)
    if key == "" then
        operation.api_key_path = ""
    else
        local wroteKey, keyError = atomicWrite(operation.api_key_path, "X-API-Key: " .. key .. "\n", 280)
        if not wroteKey then
            failNonce(operation.nonce, operation.action, "local-io", keyError)
            cleanupOperationFiles(operation, false)
            return false
        end
    end
    local guarded, guardError = atomicWrite(operation.guard_path, GUARD_CONTENT, #GUARD_CONTENT)
    if not guarded then
        failNonce(operation.nonce, operation.action, "local-io", guardError)
        cleanupOperationFiles(operation, false)
        return false
    end
    local encoded, encodeError = noctalia.json.encode(requestPayload(operation), true)
    if type(encoded) ~= "string" or #encoded + 1 > MAX_REQUEST_BYTES then
        failNonce(operation.nonce, operation.action, "local-io", tostring(encodeError or "request exceeded its size limit"))
        cleanupOperationFiles(operation, false)
        return false
    end
    local wrote, writeError = atomicWrite(operation.request_path, encoded .. "\n", MAX_REQUEST_BYTES)
    if not wrote then
        failNonce(operation.nonce, operation.action, "local-io", writeError)
        cleanupOperationFiles(operation, false)
        return false
    end
    activeOperation = operation
    status.last_request_at = nowText()
    status.last_action = operation.action
    status.last_error = ""
    status.last_error_kind = ""
    publishStatus()
    local credentialPrefix = if operation.api_key_path ~= ""
        then "chmod 0600 -- " .. shellQuote(operation.api_key_path) .. " && "
        else ""
    local command = credentialPrefix
        .. "exec bash "
        .. shellQuote(launcherPath)
        .. " rpc "
        .. shellQuote(binaryCommand)
        .. " "
        .. shellQuote(operation.request_path)
        .. " "
        .. shellQuote(operation.response_path)
        .. " "
        .. shellQuote(operation.guard_path)
    local timeout = if operation.action == "download" then DOWNLOAD_TIMEOUT_MS else RPC_TIMEOUT_MS
    local started = noctalia.runAsync(command, function(result)
        table.insert(completedTransports, { operation = operation, result = result })
    end, timeout)
    if started ~= true then
        activeOperation = nil
        failNonce(operation.nonce, operation.action, "launch", "Noctalia refused the Wall-in-One backend process")
        cleanupOperationFiles(operation, false)
        return false
    end
    return true
end

local function cancelCurrent()
    operationGeneration += 1
    if type(activeOperation) == "table" then
        activeOperation.cancelled = true
        if validAbsolutePath(activeOperation.guard_path) and noctalia.fileExists(activeOperation.guard_path) then
            noctalia.removeFile(activeOperation.guard_path)
        end
        cleanupOperationFiles(activeOperation, false)
    end
    activeOperation = nil
    validation = nil
end

local function commandFilters(command)
    local supplied = type(command.filters) == "table" and command.filters or {}
    local query = type(supplied.query) == "string" and noctalia.string.trim(supplied.query) or ""
    local sorting = type(supplied.sorting) == "string" and supplied.sorting:lower() or "date_added"
    local order = type(supplied.order) == "string" and supplied.order:lower() or "desc"
    local colors = type(supplied.colors) == "string" and supplied.colors:lower():gsub("^#", "") or ""
    return {
        query = query,
        categories = type(supplied.categories) == "string" and supplied.categories or "111",
        purity = type(supplied.purity) == "string" and supplied.purity or "100",
        sorting = sorting,
        order = order,
        atleast = type(supplied.atleast) == "string" and supplied.atleast or "",
        resolutions = type(supplied.resolutions) == "string" and supplied.resolutions or "",
        ratios = type(supplied.ratios) == "string" and supplied.ratios or "",
        colors = colors,
        top_range = type(supplied.top_range) == "string" and supplied.top_range or "1M",
        seed = type(supplied.seed) == "string" and supplied.seed or "",
        page = tonumber(supplied.page) or 1,
    }
end

local function downloadOperation(command, nonce)
    local id = validWallpaperId(command.id)
    local item = id ~= nil and findResult(id) or nil
    if item == nil then
        return nil, "download only accepts a wallpaper from the current result set"
    end
    if command.url ~= item.path and command.url ~= item.short_url then
        return nil, "download requires the exact selected Wallhaven media or short URL"
    end
    local root = configuredImageRoot()
    local directory = managedDirectory()
    local target = tostring(command.target_path or "")
    local requiredTarget = directory .. "/wallhaven-" .. id .. "." .. tostring(item.extension or "")
    local requiredStaging = requiredTarget .. ".wallhaven-" .. tostring(nonce) .. ".stage"
    if root == "" or directory == "" or target ~= requiredTarget or not validAbsolutePath(target) then
        return nil, "target_path must be the coordinator-managed Wall-in-One/Wallhaven destination"
    elseif command.staging_path ~= requiredStaging then
        return nil, "staging_path must equal target_path plus .wallhaven-<nonce>.stage"
    elseif noctalia.fileExists(target) or noctalia.fileExists(target .. ".wallhaven.json") then
        return nil, "download refuses to overwrite an existing target or provenance sidecar"
    end
    return {
        nonce = nonce,
        action = "download",
        id = id,
        image_root = root,
        target_path = target,
        item = {
            id = id,
            path = item.path,
            short_url = item.short_url,
            file_type = item.file_type,
            file_size = item.file_size,
            dimension_x = item.dimension_x,
            dimension_y = item.dimension_y,
        },
    }, nil
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
    local action = bounded(command.action, 32):lower()
    if action == "clear" then
        -- The backend's Wallhaven side is one-shot and holds no provider
        -- state. Preserve the v1 protocol's immediate clear/cancel semantics
        -- without spawning a no-op process; the probe still requires the
        -- wallhaven.clear capability so incompatible binaries degrade early.
        cancelCurrent()
        resetResults(nonce)
        completeNonce(nonce, action)
        return
    elseif type(activeOperation) == "table" or type(validation) == "table" then
        failNonce(nonce, action, "busy", "A Wallhaven operation is already in flight")
        return
    end
    refreshAvailability()
    if status.available ~= true then
        failNonce(
            nonce,
            action,
            "unavailable",
            if status.configuration_error ~= ""
                then status.configuration_error
                else "Wallhaven requires a compatible external Wall-in-One backend and an image directory"
        )
        return
    end
    local key, keyError = apiKey()
    if keyError ~= nil then
        failNonce(nonce, action, "configuration", keyError)
        return
    end
    local operation
    local operationError
    if action == "search" then
        operation = { nonce = nonce, action = action, filters = commandFilters(command) }
    elseif action == "detail" then
        local id = validWallpaperId(command.id)
        if id == nil or findResult(id) == nil then
            operationError = "detail only accepts an ID from the current Wallhaven results"
        else
            operation = { nonce = nonce, action = action, id = id }
        end
    elseif action == "download" then
        operation, operationError = downloadOperation(command, nonce)
        key = ""
    else
        operationError = "Unsupported Wallhaven action"
    end
    if operation == nil then
        failNonce(nonce, action, "validation", operationError)
        return
    end
    operation.generation = operationGeneration
    launchOperation(operation, key)
end

function update()
    noctalia.setUpdateInterval(
        if #completedProbes > 0 or #completedTransports > 0 or type(validation) == "table" then 100 else 1000
    )
    if processCompletedProbe() then
        return
    end
    if processCompletedTransport() then
        return
    end
    stepValidation()
end

function onConfigChanged()
    cancelCurrent()
    probeGeneration += 1
    probeBusy = false
    initializeStorage()
    startProbe()
end

function onExit(_signal, _reason)
    running = false
    probeGeneration += 1
    probeBusy = false
    cancelCurrent()
    status.ready = false
    status.running = false
    status.available = false
    status.busy = false
    status.active_action = ""
    status.active_nonce = 0
    status.active_id = ""
    status.probe_state = "stopped"
    publishStatus()
end

initializeStorage()
resetResults(0)
publishStatus()
noctalia.state.watch(COMMAND_KEY, handleCommand)
noctalia.state.watch(BACKEND_STATUS_KEY, function(backendState)
    if type(backendState) == "table"
        and backendState.available == true
        and status.binary_compatible ~= true
        and not probeBusy
    then
        startProbe()
    end
end)
handleCommand(noctalia.state.get(COMMAND_KEY))
startProbe()

--!nonstrict
-- Process bridge for the separately installed Wall-in-One Python backend.
--
-- Noctalia loads each service in an isolated ScriptRuntime.  This service is
-- deliberately limited to binary discovery, bounded file transport, and
-- incremental validation of normalized backend results.  Filesystem walking
-- and metadata parsing belong to wall-in-one-backend.

local SCHEMA = 1
local RPC_SCHEMA = 1
local COMMAND_KEY = "wall_in_one_backend_command_v1"
local COMMAND_ACK_KEY = "wall_in_one_backend_command_ack_v1"
local STATUS_KEY = "wall_in_one_backend_status_v1"
local RESULTS_KEY = "wall_in_one_backend_results_v1"
local PALETTE_COMMAND_KEY = "wall_in_one_backend_palette_command_v1"
local PALETTE_RESULTS_KEY = "wall_in_one_backend_palette_results_v1"
local BINARY_NAME = "wall-in-one-backend"
local BACKEND_POINTER_NAME = "backend-path"
local MAX_BACKEND_POINTER_BYTES = 4097
local DISCOVERY_RETRY_MS = 3000
local PROBE_PROTOCOL = "WIO-BACKEND-PROBE1"
local RPC_PROTOCOL = "WIO-BACKEND-RPC1"
local GUARD_CONTENT = "WIO-BACKEND-GUARD1\n"
local REQUIRED_CAPABILITY = "library.scan"
local MAX_NONCE = 9007199254740991
local MAX_REQUEST_BYTES = 64 * 1024
local MAX_RESPONSE_BYTES = 128 * 1024
local MAX_PAGE_BYTES = 128 * 1024
local LIBRARY_PAGE_SIZE = 12
local PALETTE_PAGE_SIZE = 16
local MAX_LIBRARY_ITEMS = 512
local MAX_PALETTE_ITEMS = 512
local MAX_WORKSHOP_ROOTS = 8
local VALIDATION_BATCH = 8
local PROBE_TIMEOUT_MS = 5000
local RPC_OPERATION_BUDGET_MS = 45000
local RPC_TIMEOUT_MS = 55000
local PAGED_DOMAINS = {
    library = {
        sections = { "stills", "videos", "workshops" },
        page_size = LIBRARY_PAGE_SIZE,
        max_items = MAX_LIBRARY_ITEMS,
        filename_prefix = ".wall-in-one-library-",
        page_action = "library.page",
    },
    palettes = {
        sections = { "community", "custom" },
        page_size = PALETTE_PAGE_SIZE,
        max_items = MAX_PALETTE_ITEMS,
        filename_prefix = ".wall-in-one-palettes-",
        page_action = "palettes.page",
    },
}

local sequence = 0
local operationSequence = 0
local operationGeneration = 0
local probeGeneration = 0
local runtimeToken = tostring(math.floor(noctalia.nowMs()))
local dataDirectory = ""
local transportDirectory = ""
local launcherPath = ""
local binaryCommand = ""
local probeBusy = false
local activeOperation = nil
local pendingOperation = nil
local pendingPaletteOperation = nil
local lastDispatchedAction = ""
local completedTransport = nil
local validation = nil
local nextDiscoveryAtMs = 0

local status = {
    schema = SCHEMA,
    sequence = 0,
    ready = true,
    available = false,
    busy = false,
    active_action = "",
    last_nonce = 0,
    last_completed_nonce = 0,
    last_action = "",
    last_error = "",
    last_error_kind = "",
    launcher_available = false,
    binary_available = false,
    binary_compatible = false,
    binary_path = "",
    binary_source = "",
    binary_version = "",
    binary_protocol = 0,
    capabilities = "",
    probe_state = "idle",
    availability_reason = "initializing",
    updated_at = "",
}

local results = {
    schema = SCHEMA,
    sequence = 0,
    nonce = 0,
    action = "",
    ok = false,
    library = {},
    error = {},
}

local paletteResults = {
    schema = SCHEMA,
    sequence = 0,
    nonce = 0,
    action = "palettes.inventory",
    ok = false,
    palettes = {},
    error = {},
}
local lastPaletteNonce = 0
local previousPaletteResult = noctalia.state.get(PALETTE_RESULTS_KEY)
if type(previousPaletteResult) == "table" then
    lastPaletteNonce = math.max(0, math.floor(tonumber(previousPaletteResult.nonce) or 0))
    paletteResults.sequence = math.max(0, math.floor(tonumber(previousPaletteResult.sequence) or 0))
end

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

local function optionalAbsolutePath(value)
    value = tostring(value or "")
    return value == "" or validAbsolutePath(value)
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
    return name ~= "" and not name:find("/", 1, true) and not name:find("[%c]")
end

local function ownedPageName(name)
    return type(name) == "string"
        and #name <= 160
        and (
            name:match("^%.wall%-in%-one%-library%-[A-Za-z0-9._-]+%-[%a]+%-%d+%.json$")
            or name:match("^%.wall%-in%-one%-palettes%-[A-Za-z0-9._-]+%-community%-%d+%.json$")
            or name:match("^%.wall%-in%-one%-palettes%-[A-Za-z0-9._-]+%-custom%-%d+%.json$")
        ) ~= nil
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

local function nonceValue(value)
    local nonce = tonumber(value)
    if nonce == nil or nonce ~= math.floor(nonce) or nonce <= 0 or nonce > MAX_NONCE then
        return nil
    end
    return nonce
end

local function publishStatus()
    sequence += 1
    status.sequence = sequence
    status.busy = probeBusy
        or activeOperation ~= nil
        or validation ~= nil
        or pendingOperation ~= nil
        or pendingPaletteOperation ~= nil
    status.active_action = if probeBusy
        then "probe"
        elseif type(activeOperation) == "table" then tostring(activeOperation.action or "")
        else ""
    status.available = status.launcher_available == true and status.binary_compatible == true and probeBusy ~= true
    status.updated_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    noctalia.state.set(STATUS_KEY, status)
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

local function publishResult(nonce, ok, libraryValue, kind, message)
    results.sequence += 1
    results.nonce = nonce
    results.action = "library.scan"
    results.ok = ok == true
    results.library = if ok == true and type(libraryValue) == "table" then libraryValue else {}
    results.error = if ok == true then {} else {
        kind = bounded(kind or "backend", 80),
        message = bounded(message or "Wall-in-One backend request failed", 400),
    }
    noctalia.state.set(RESULTS_KEY, results)
end

local function publishPaletteResult(nonce, ok, paletteValue, kind, message)
    paletteResults.sequence += 1
    paletteResults.nonce = nonce
    paletteResults.ok = ok == true
    paletteResults.palettes = if ok == true and type(paletteValue) == "table" then paletteValue else {}
    paletteResults.error = if ok == true then {} else {
        kind = bounded(kind or "backend", 80),
        message = bounded(message or "Palette inventory backend request failed", 400),
    }
    noctalia.state.set(PALETTE_RESULTS_KEY, paletteResults)
end

local function failNonce(nonce, action, kind, message)
    status.last_completed_nonce = math.max(status.last_completed_nonce, tonumber(nonce) or 0)
    status.last_action = tostring(action or "")
    status.last_error_kind = bounded(kind or "backend", 80)
    status.last_error = bounded(message or "Wall-in-One backend request failed", 400)
    if action == "library.scan" then
        publishAck(nonce, "error", status.last_error)
        publishResult(nonce, false, nil, status.last_error_kind, status.last_error)
    elseif action == "palettes.inventory" then
        publishPaletteResult(nonce, false, nil, status.last_error_kind, status.last_error)
    end
    noctalia.log("wall-in-one backend bridge: " .. status.last_error_kind .. ": " .. status.last_error)
    publishStatus()
end

local function completeNonce(nonce, action, libraryValue)
    status.last_completed_nonce = math.max(status.last_completed_nonce, tonumber(nonce) or 0)
    status.last_action = tostring(action or "")
    status.last_error = ""
    status.last_error_kind = ""
    if action == "library.scan" then
        publishAck(nonce, "complete", "")
        publishResult(nonce, true, libraryValue, nil, nil)
    elseif action == "palettes.inventory" then
        publishPaletteResult(nonce, true, libraryValue, nil, nil)
    end
    publishStatus()
end

local function cleanupOperationFiles(operation, keepResponse)
    if type(operation) ~= "table" then
        return
    end
    for _, path in ipairs({ operation.guard_path, operation.request_path }) do
        if validAbsolutePath(path) and noctalia.fileExists(path) then
            noctalia.removeFile(path)
        end
    end
    if keepResponse ~= true and validAbsolutePath(operation.response_path) and noctalia.fileExists(operation.response_path) then
        noctalia.removeFile(operation.response_path)
    end
    for _, path in ipairs(type(operation.page_paths) == "table" and operation.page_paths or {}) do
        if directChildOf(path, transportDirectory)
            and ownedPageName(path:sub(#transportDirectory + 2))
            and noctalia.fileExists(path)
        then
            noctalia.removeFile(path)
        end
    end
    operation.page_paths = {}
end

local function validatedExecutable(path, sourceLabel)
    if not validAbsolutePath(path) then
        return "", sourceLabel .. " is not a safe absolute path"
    end
    local info = noctalia.fileInfo(path)
    if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) <= 0 then
        return "", sourceLabel .. " is not a readable non-empty regular file"
    end
    -- Noctalia's commandExists accepts absolute paths and checks X_OK plus
    -- regular-file status.  This catches a downloaded-but-not-chmodded helper
    -- before the launcher spends a process slot probing it.
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
        status.availability_reason = "storage-unavailable"
        return false
    end
    dataDirectory = pluginDataDirectory:gsub("/+$", "")
    transportDirectory = dataDirectory .. "/backend-bridge-v1/rpc"
    if noctalia.mkdirAll(transportDirectory) ~= true then
        dataDirectory = ""
        transportDirectory = ""
        status.availability_reason = "storage-unavailable"
        return false
    end
    local names = noctalia.listDir(transportDirectory)
    if type(names) == "table" then
        for _, name in ipairs(names) do
            if type(name) == "string"
                and #name <= 160
                and (
                    name:match("^request%-%d+%-%d+%-%d+%.json%.tmp$")
                    or name:match("^request%-%d+%-%d+%-%d+%.json$")
                    or name:match("^response%-%d+%-%d+%-%d+%.json%.tmp$")
                    or name:match("^response%-%d+%-%d+%-%d+%.json$")
                    or name:match("^%.wall%-in%-one%-backend%-guard%-%d+%-%d+%-%d+%.tmp$")
                    or name:match("^%.wall%-in%-one%-backend%-guard%-%d+%-%d+%-%d+$")
                    or ownedPageName(name)
                )
            then
                noctalia.removeFile(transportDirectory .. "/" .. name)
            end
        end
    end
    return true
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
        return nil, "probe-failed", "Wall-in-One backend returned no probe result"
    elseif result.timedOut == true then
        return nil, "probe-failed", "Wall-in-One backend probe timed out"
    end
    local line = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local errorWire, errorOutcome, errorKind, errorDetail = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorWire == PROBE_PROTOCOL and errorOutcome == "error" then
        return nil, bounded(errorKind, 80), bounded(errorDetail, 400)
    elseif tonumber(result.exitCode) ~= 0 then
        return nil, "probe-failed", processFailureDetail(result, "Wall-in-One backend probe failed")
    end
    local wire, outcome, protocol, version, capabilities = line:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    if wire ~= PROBE_PROTOCOL or outcome ~= "ok" or tonumber(protocol) ~= RPC_SCHEMA then
        return nil, "binary-incompatible", "Wall-in-One backend uses an incompatible protocol"
    end
    local found = {}
    for capability in tostring(capabilities):gmatch("[^,]+") do
        found[capability] = true
    end
    if found[REQUIRED_CAPABILITY] ~= true then
        return nil, "binary-incompatible", "Wall-in-One backend is missing capability: " .. REQUIRED_CAPABILITY
    end
    if #version > 80 or version:find("[%c]") ~= nil or #capabilities > 400 then
        return nil, "binary-incompatible", "Wall-in-One backend probe fields exceed protocol bounds"
    end
    return { protocol = RPC_SCHEMA, version = version, capabilities = capabilities }, nil, nil
end

local pump

local function startProbe()
    probeGeneration += 1
    local generation = probeGeneration
    nextDiscoveryAtMs = math.floor(tonumber(noctalia.nowMs()) or 0) + DISCOVERY_RETRY_MS
    probeBusy = false
    binaryCommand = ""
    status.binary_available = false
    status.binary_compatible = false
    status.binary_path = ""
    status.binary_source = ""
    status.binary_version = ""
    status.binary_protocol = 0
    status.capabilities = ""
    if dataDirectory == "" or transportDirectory == "" then
        status.probe_state = "storage-unavailable"
        status.availability_reason = status.probe_state
        publishStatus()
        return
    elseif not status.launcher_available then
        status.probe_state = "launcher-missing"
        status.availability_reason = status.probe_state
        publishStatus()
        return
    end
    local selected, source, selectionError = configuredBinary()
    status.binary_source = source
    if selected == "" then
        status.probe_state = "binary-missing"
        status.availability_reason = status.probe_state
        status.last_error_kind = ""
        status.last_error = ""
        publishStatus()
        return
    end
    binaryCommand = selected
    status.binary_available = true
    status.binary_path = selected
    status.probe_state = "probing"
    status.availability_reason = "probing"
    probeBusy = true
    publishStatus()
    local command = "exec bash " .. shellQuote(launcherPath) .. " probe " .. shellQuote(binaryCommand)
    local started = noctalia.runAsync(command, function(result)
        if generation ~= probeGeneration then
            return
        end
        probeBusy = false
        local probe, kind, message = probeResult(result)
        if probe == nil then
            status.binary_compatible = false
            status.probe_state = kind
            status.availability_reason = kind
            status.last_error_kind = bounded(kind, 80)
            status.last_error = bounded(message or selectionError, 400)
            publishStatus()
            return
        end
        status.binary_compatible = true
        status.binary_version = probe.version
        status.binary_protocol = probe.protocol
        status.capabilities = probe.capabilities
        nextDiscoveryAtMs = 0
        status.probe_state = "ready"
        status.availability_reason = "ready"
        status.last_error_kind = ""
        status.last_error = ""
        publishStatus()
        pump()
    end, PROBE_TIMEOUT_MS)
    if started ~= true then
        probeBusy = false
        status.probe_state = "probe-failed"
        status.availability_reason = status.probe_state
        status.last_error_kind = status.probe_state
        status.last_error = "Noctalia refused the Wall-in-One backend probe"
        publishStatus()
    end
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

local function requestPaths(operation)
    operationSequence += 1
    local token = runtimeToken .. "-" .. tostring(operation.nonce) .. "-" .. tostring(operationSequence)
    return transportDirectory .. "/request-" .. token .. ".json",
        transportDirectory .. "/response-" .. token .. ".json",
        transportDirectory .. "/.wall-in-one-backend-guard-" .. token
end

local function requestPayload(operation)
    if operation.action == "palettes.inventory" then
        return {
            schema = RPC_SCHEMA,
            request_id = operation.request_id,
            action = operation.action,
            guard_path = operation.guard_path,
            operation_timeout_ms = RPC_OPERATION_BUDGET_MS,
            transport_directory = transportDirectory,
            data_directory = dataDirectory,
            custom_directory = operation.custom_directory,
            cache_path = dataDirectory .. "/palettes-cache.json",
            force_refresh = operation.force_refresh == true,
        }
    end
    return {
        schema = RPC_SCHEMA,
        request_id = operation.request_id,
        action = "library.scan",
        guard_path = operation.guard_path,
        operation_timeout_ms = RPC_OPERATION_BUDGET_MS,
        transport_directory = transportDirectory,
        data_directory = dataDirectory,
        runtime_path = dataDirectory .. "/runtime.json",
        instance_id = operation.instance_id,
        image_root = operation.image_root,
        video_root = operation.video_root,
        workshop_roots = operation.workshop_roots,
        wallhaven_directory = operation.wallhaven_directory,
        automatic_stills_directory = operation.automatic_stills_directory,
        motionbgs_directory = operation.motionbgs_directory,
    }
end

local function transportPayload(operation, result)
    if type(result) ~= "table" then
        return nil, "transport", "Wall-in-One backend returned no process result"
    elseif result.timedOut == true then
        return nil, "timeout", "Wall-in-One backend exceeded its bounded process timeout"
    end
    local line = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local errorWire, errorOutcome, kind, detail = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorWire == RPC_PROTOCOL and errorOutcome == "error" then
        return nil, bounded(kind, 80), bounded(detail, 400)
    elseif tonumber(result.exitCode) ~= 0 then
        return nil, "transport", processFailureDetail(result, "Wall-in-One backend process failed")
    end
    local wire, outcome, requestId, path, bytes = line:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    local expectedBytes = math.floor(tonumber(bytes) or 0)
    if wire ~= RPC_PROTOCOL
        or outcome ~= "ok"
        or requestId ~= operation.request_id
        or path ~= operation.response_path
        or expectedBytes < 2
        or expectedBytes > MAX_RESPONSE_BYTES
    then
        return nil, "protocol", "Wall-in-One backend returned an invalid completion envelope"
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

local function noControls(value, maximum)
    return type(value) == "string" and #value <= maximum and value:find("[%c]") == nil
end

local function finiteInteger(value, minimum)
    local number = tonumber(value)
    return number ~= nil and number == math.floor(number) and number >= minimum and number <= 9007199254740991
end

local function normalizeMediaEntry(candidate, mediaType, context)
    if type(candidate) ~= "table" then
        return nil
    end
    local path = tostring(candidate.path or "")
    local name = tostring(candidate.name or "")
    local identifier = tostring(candidate.id or "")
    local provider = tostring(candidate.provider or "")
    local ownership = tostring(candidate.ownership or "")
    local managed = candidate.managed == true
    local deletable = candidate.deletable == true
    local sidecar = tostring(candidate.sidecar or "")
    local expectedPrefix = mediaType .. ":" .. context.instance_id .. ":"
    local token = identifier:sub(#expectedPrefix + 1)
    if not validAbsolutePath(path)
        or not noControls(name, 255)
        or name == ""
        or name:find("/", 1, true)
        or identifier:sub(1, #expectedPrefix) ~= expectedPrefix
        or #token ~= 24
        or token:match("^[0-9a-f]+$") == nil
        or tostring(candidate.media_type or "") ~= mediaType
        or not finiteInteger(candidate.size, 1)
        or not finiteInteger(candidate.mtime, 0)
        or (ownership ~= "user" and ownership ~= "managed")
        or (managed ~= deletable)
        or (managed and ownership ~= "managed")
        or (not managed and (ownership ~= "user" or provider ~= "local" or sidecar ~= ""))
        or (managed and not validAbsolutePath(sidecar))
        or context.ids[identifier]
        or context.paths[mediaType .. "\0" .. path]
    then
        return nil
    end
    local entry = {
        id = identifier,
        path = path,
        name = name,
        size = math.floor(tonumber(candidate.size)),
        mtime = math.floor(tonumber(candidate.mtime)),
        media_type = mediaType,
        provider = provider,
        ownership = ownership,
        managed = managed,
        deletable = deletable,
        sidecar = sidecar,
    }
    if managed then
        if provider == "MotionBGS" then
            local slug = tostring(candidate.provider_id or ""):lower()
            local quality = tostring(candidate.quality or ""):lower()
            local sourceUrl = tostring(candidate.source_url or "")
            if mediaType ~= "video"
                or not directChildOf(path, context.motionbgs_directory)
                or sidecar ~= path .. ".motionbgs.json"
                or slug:match("^[a-z0-9][a-z0-9-]*$") == nil
                or #slug > 120
                or (quality ~= "hd" and quality ~= "4k")
                or sourceUrl ~= "https://motionbgs.com/" .. slug
            then
                return nil
            end
            entry.provider_id = slug
            entry.quality = quality
            entry.source_url = sourceUrl
            context.provider_installs.motionbgs[slug .. ":" .. quality] = path
        elseif provider == "Wallhaven" then
            local providerId = tostring(candidate.provider_id or ""):lower()
            local sourceUrl = tostring(candidate.source_url or "")
            if mediaType ~= "image"
                or not directChildOf(path, context.wallhaven_directory)
                or sidecar ~= path .. ".wallhaven.json"
                or providerId:match("^[a-z0-9]+$") == nil
                or #providerId > 16
                or sourceUrl:sub(1, #"https://wallhaven.cc/") ~= "https://wallhaven.cc/"
            then
                return nil
            end
            entry.provider_id = providerId
            entry.source_url = sourceUrl
            context.provider_installs.wallhaven[providerId] = path
        elseif mediaType == "image" and directChildOf(path, context.automatic_stills_directory) then
            local dynamicId = tostring(candidate.dynamic_id or "")
            if not noControls(provider, 80)
                or provider == ""
                or sidecar ~= path .. ".wall-in-one.json"
                or dynamicId == ""
                or #dynamicId > 4096
                or dynamicId:find("[%c]")
            then
                return nil
            end
            entry.dynamic_id = dynamicId
        else
            return nil
        end
    end
    local pairedPreview = tostring(candidate.paired_preview or "")
    if pairedPreview ~= "" then
        if mediaType ~= "video" or not validAbsolutePath(pairedPreview) then
            return nil
        end
        entry.paired_preview = pairedPreview
        context.representative_stills.video[path] = pairedPreview
    elseif mediaType == "video" then
        entry.paired_preview = ""
    end
    context.ids[identifier] = true
    context.paths[mediaType .. "\0" .. path] = true
    return entry
end

local function normalizeWorkshopEntry(candidate, context)
    if type(candidate) ~= "table" then
        return nil
    end
    local id = tostring(candidate.id or "")
    local title = tostring(candidate.title or "")
    local kind = tostring(candidate.kind or "")
    local directory = tostring(candidate.directory or "")
    local preview = tostring(candidate.preview or "")
    local pairedPreview = tostring(candidate.paired_preview or "")
    if id:match("^%d+$") == nil
        or #id > 24
        or not noControls(title, 320)
        or title == ""
        or not noControls(kind, 320)
        or kind == ""
        or not validAbsolutePath(directory)
        or (preview ~= "" and not validAbsolutePath(preview))
        or (pairedPreview ~= "" and not validAbsolutePath(pairedPreview))
        or tostring(candidate.ownership or "") ~= "steam"
        or candidate.managed == true
        or candidate.deletable == true
        or context.workshop_ids[id]
    then
        return nil
    end
    context.workshop_ids[id] = true
    if pairedPreview ~= "" then
        context.representative_stills.workshop[id] = pairedPreview
    end
    return {
        id = id,
        title = title,
        kind = kind,
        directory = directory,
        preview = preview,
        paired_preview = pairedPreview,
        ownership = "steam",
        managed = false,
        deletable = false,
    }
end

local function normalizePaletteMode(candidate)
    if type(candidate) ~= "table" or type(candidate.accents) ~= "table" or #candidate.accents > 4 then
        return nil
    end
    local surface = tostring(candidate.surface or "")
    if surface ~= "" and surface:match("^#%x%x%x%x%x%x$") == nil then
        return nil
    end
    local accents = {}
    for _, value in ipairs(candidate.accents) do
        local color = tostring(value or "")
        if color:match("^#%x%x%x%x%x%x$") == nil then
            return nil
        end
        table.insert(accents, color:upper())
    end
    return { surface = surface:upper(), accents = accents }
end

local function normalizePaletteEntry(candidate, section, context)
    local name = type(candidate) == "table" and tostring(candidate.name or "") or ""
    local preview = type(candidate) == "table" and candidate.preview or nil
    local dark = type(preview) == "table" and normalizePaletteMode(preview.dark) or nil
    local light = type(preview) == "table" and normalizePaletteMode(preview.light) or nil
    if name == ""
        or not noControls(name, 160)
        or dark == nil
        or light == nil
        or (section == "custom" and #dark.accents == 0 and #light.accents == 0)
        or context.seen[section][name]
    then
        return nil
    end
    local result = { name = name, preview = { dark = dark, light = light } }
    if section == "community" then
        local md5 = tostring(candidate.md5 or "")
        if md5 ~= "" and (#md5 ~= 32 or md5:match("^%x+$") == nil) then
            return nil
        end
        result.md5 = md5:lower()
    end
    context.seen[section][name] = true
    return result
end

local function normalizePageSections(operation, sections, domain)
    local normalizedSections = {}
    operation.page_paths = {}
    for _, sectionName in ipairs(domain.sections) do
        local section = sections[sectionName]
        local count = type(section) == "table" and tonumber(section.count) or nil
        local pages = type(section) == "table" and section.pages or nil
        if count == nil
            or count ~= math.floor(count)
            or count < 0
            or count > domain.max_items
            or type(pages) ~= "table"
            or #pages ~= math.ceil(count / domain.page_size)
        then
            local suffix = if domain == PAGED_DOMAINS.palettes then " palette pages" else " page metadata"
            return nil, "Wall-in-One backend returned invalid " .. sectionName .. suffix
        end
        local normalizedPages = {}
        local described = 0
        for pageIndex, descriptor in ipairs(pages) do
            local expectedCount = math.min(domain.page_size, count - ((pageIndex - 1) * domain.page_size))
            local path = type(descriptor) == "table" and tostring(descriptor.path or "") or ""
            local bytes = type(descriptor) == "table" and tonumber(descriptor.bytes) or nil
            local itemCount = type(descriptor) == "table" and tonumber(descriptor.count) or nil
            local expectedName = domain.filename_prefix
                .. operation.request_id
                .. "-"
                .. sectionName
                .. "-"
                .. tostring(pageIndex)
                .. ".json"
            local validCount = if domain == PAGED_DOMAINS.palettes
                then itemCount == expectedCount
                else itemCount ~= nil
                    and itemCount == math.floor(itemCount)
                    and itemCount >= 1
                    and itemCount <= domain.page_size
            if type(descriptor) ~= "table"
                or tonumber(descriptor.page) ~= pageIndex
                or not directChildOf(path, transportDirectory)
                or path:sub(#transportDirectory + 2) ~= expectedName
                or bytes == nil
                or bytes ~= math.floor(bytes)
                or bytes < 2
                or bytes > MAX_PAGE_BYTES
                or not validCount
            then
                local detail = if domain == PAGED_DOMAINS.palettes
                    then "palette page"
                    else sectionName .. " page"
                return nil, "Wall-in-One backend returned an unsafe " .. detail
            end
            described += itemCount
            table.insert(normalizedPages, {
                page = pageIndex,
                path = path,
                bytes = math.floor(bytes),
                count = math.floor(itemCount),
            })
            table.insert(operation.page_paths, path)
        end
        if described ~= count then
            local detail = if domain == PAGED_DOMAINS.palettes
                then "palette page counts did not match"
                else "page counts did not match " .. sectionName
            return nil, "Wall-in-One backend " .. detail
        end
        normalizedSections[sectionName] = { count = math.floor(count), pages = normalizedPages }
    end
    return normalizedSections, nil
end

local function beginPaletteValidation(operation, payload)
    if type(payload) ~= "table"
        or tonumber(payload.schema) ~= RPC_SCHEMA
        or tostring(payload.request_id or "") ~= operation.request_id
        or tostring(payload.action or "") ~= "palettes.inventory"
    then
        return false, "protocol", "Wall-in-One backend returned a mismatched palette response envelope"
    end
    if payload.ok ~= true then
        local failure = type(payload.error) == "table" and payload.error or {}
        return false, bounded(failure.kind or "backend", 80), bounded(failure.message or "Palette inventory failed", 400)
    end
    local inventory = payload.inventory
    local sections = type(inventory) == "table" and inventory.sections or nil
    local cache = type(inventory) == "table" and inventory.cache or nil
    local invalidCustom = type(inventory) == "table" and tonumber(inventory.invalid_custom) or nil
    local fetchedAt = type(cache) == "table" and tonumber(cache.fetched_at) or nil
    local source = type(cache) == "table" and tostring(cache.source or "") or ""
    if type(inventory) ~= "table"
        or tonumber(inventory.page_size) ~= PALETTE_PAGE_SIZE
        or type(sections) ~= "table"
        or inventory.custom_directory ~= operation.custom_directory
        or invalidCustom == nil
        or invalidCustom ~= math.floor(invalidCustom)
        or invalidCustom < 0
        or invalidCustom > 1024
        or type(cache) ~= "table"
        or type(cache.loaded) ~= "boolean"
        or type(cache.fresh) ~= "boolean"
        or ({ none = true, primary = true, backup = true, network = true })[source] ~= true
        or fetchedAt == nil
        or fetchedAt ~= math.floor(fetchedAt)
        or fetchedAt < 0
        or tonumber(cache.ttl_seconds) ~= 21600
        or type(inventory.signature) ~= "string"
        or #inventory.signature ~= 64
        or inventory.signature:match("^%x+$") == nil
    then
        return false, "protocol", "Wall-in-One backend returned invalid palette inventory metadata"
    end
    local normalizedSections, sectionError = normalizePageSections(operation, sections, PAGED_DOMAINS.palettes)
    if normalizedSections == nil then
        return false, "protocol", sectionError
    end
    validation = {
        kind = "palettes",
        operation = operation,
        inventory = inventory,
        sections = normalizedSections,
        section_order = PAGED_DOMAINS.palettes.sections,
        section_index = 1,
        page_index = 1,
        current_page = nil,
        current_item = 1,
        output = { community = {}, custom = {} },
        seen = { community = {}, custom = {} },
    }
    return true, nil, nil
end

local function beginValidation(operation, payload)
    if operation.action == "palettes.inventory" then
        return beginPaletteValidation(operation, payload)
    end
    if type(payload) ~= "table"
        or tonumber(payload.schema) ~= RPC_SCHEMA
        or tostring(payload.request_id or "") ~= operation.request_id
        or tostring(payload.action or "") ~= "library.scan"
    then
        return false, "protocol", "Wall-in-One backend returned a mismatched response envelope"
    end
    if payload.ok ~= true then
        local failure = type(payload.error) == "table" and payload.error or {}
        return false, bounded(failure.kind or "backend", 80), bounded(failure.message or "Library scan failed", 400)
    end
    local manifest = payload.library
    local sections = type(manifest) == "table" and manifest.sections or nil
    if type(manifest) ~= "table"
        or tonumber(manifest.schema) ~= RPC_SCHEMA
        or tonumber(manifest.page_size) ~= LIBRARY_PAGE_SIZE
        or type(sections) ~= "table"
    then
        return false, "protocol", "Wall-in-One backend returned an invalid library manifest"
    end
    local normalizedSections, sectionError = normalizePageSections(operation, sections, PAGED_DOMAINS.library)
    if normalizedSections == nil then
        return false, "protocol", sectionError
    end
    validation = {
        kind = "library",
        operation = operation,
        sections = normalizedSections,
        section_order = PAGED_DOMAINS.library.sections,
        section_index = 1,
        page_index = 1,
        current_page = nil,
        current_item = 1,
        output = { stills = {}, videos = {}, workshops = {} },
        ids = {},
        paths = {},
        workshop_ids = {},
        provider_installs = { wallhaven = {}, motionbgs = {} },
        representative_stills = { video = {}, workshop = {} },
        instance_id = operation.instance_id,
        wallhaven_directory = operation.wallhaven_directory,
        automatic_stills_directory = operation.automatic_stills_directory,
        motionbgs_directory = operation.motionbgs_directory,
    }
    return true, nil, nil
end

local function finishOperation(operation)
    cleanupOperationFiles(operation, false)
    if activeOperation == operation then
        activeOperation = nil
    end
    validation = nil
    publishStatus()
    pump()
end

local function validationFailure(context, message)
    local operation = context.operation
    failNonce(operation.nonce, operation.action, "protocol", message)
    finishOperation(operation)
end

local function completedValidationValue(context)
    if context.kind == "palettes" then
        local source = context.inventory
        local cache = source.cache
        return {
            community = context.output.community,
            custom = context.output.custom,
            custom_directory = source.custom_directory,
            invalid_custom = math.floor(tonumber(source.invalid_custom)),
            custom_error = bounded(source.custom_error, 640),
            community_error = bounded(source.community_error, 640),
            cache_error = bounded(source.cache_error, 640),
            cache = {
                loaded = cache.loaded == true,
                source = bounded(cache.source, 80),
                fetched_at = math.floor(tonumber(cache.fetched_at)),
                fetched_at_text = bounded(cache.fetched_at_text, 80),
                fresh = cache.fresh == true,
                ttl_seconds = 21600,
            },
            network_attempted = source.network_attempted == true,
            last_event = bounded(source.last_event, 80),
            last_refresh_at = bounded(source.last_refresh_at, 80),
            last_success_at = bounded(source.last_success_at, 80),
            custom_refreshed_at = bounded(source.custom_refreshed_at, 80),
            signature = tostring(source.signature):lower(),
        }
    end
    return {
        stills = context.output.stills,
        videos = context.output.videos,
        workshops = context.output.workshops,
        provider_installs = context.provider_installs,
        representative_stills = context.representative_stills,
    }
end

local function normalizeValidationEntry(context, sectionName, candidate)
    if context.kind == "palettes" then
        return normalizePaletteEntry(candidate, sectionName, context)
    elseif sectionName == "stills" then
        return normalizeMediaEntry(candidate, "image", context)
    elseif sectionName == "videos" then
        return normalizeMediaEntry(candidate, "video", context)
    end
    return normalizeWorkshopEntry(candidate, context)
end

local function stepValidation()
    local context = validation
    if type(context) ~= "table" then
        return false
    end
    local domain = PAGED_DOMAINS[context.kind]
    local sectionName = context.section_order[context.section_index]
    while sectionName ~= nil and context.page_index > #context.sections[sectionName].pages do
        if #context.output[sectionName] ~= context.sections[sectionName].count then
            local itemKind = if context.kind == "palettes" then "palette" else "item"
            validationFailure(context, "Wall-in-One backend " .. itemKind .. " count changed while reading " .. sectionName)
            return true
        end
        context.section_index += 1
        context.page_index = 1
        sectionName = context.section_order[context.section_index]
    end
    if sectionName == nil then
        local operation = context.operation
        completeNonce(operation.nonce, operation.action, completedValidationValue(context))
        finishOperation(operation)
        return true
    end

    if context.current_page == nil then
        local descriptor = context.sections[sectionName].pages[context.page_index]
        local raw = readBoundedRegularFile(descriptor.path, MAX_PAGE_BYTES)
        if type(raw) ~= "string" or #raw ~= descriptor.bytes then
            local pageKind = if context.kind == "palettes" then "palette page" else "page"
            validationFailure(context, "Wall-in-One backend " .. pageKind .. " was missing or changed")
            return true
        end
        local page = noctalia.json.decode(raw)
        noctalia.removeFile(descriptor.path)
        if type(page) ~= "table"
            or tonumber(page.schema) ~= RPC_SCHEMA
            or tostring(page.request_id or "") ~= context.operation.request_id
            or tostring(page.action or "") ~= domain.page_action
            or tostring(page.section or "") ~= sectionName
            or tonumber(page.page) ~= context.page_index
            or tonumber(page.total_pages) ~= #context.sections[sectionName].pages
            or type(page.items) ~= "table"
            or #page.items ~= descriptor.count
            or #page.items > domain.page_size
        then
            local pageKind = if context.kind == "palettes" then "palette" else sectionName
            validationFailure(context, "Wall-in-One backend returned an invalid " .. pageKind .. " page")
            return true
        end
        context.current_page = page.items
        context.current_item = 1
    end

    local budget = VALIDATION_BATCH
    while budget > 0 and context.current_item <= #context.current_page do
        local candidate = context.current_page[context.current_item]
        local normalized = normalizeValidationEntry(context, sectionName, candidate)
        if normalized == nil then
            local entryKind = if context.kind == "palettes" then " palette entry" else " entry"
            validationFailure(context, "Wall-in-One backend returned an unsafe " .. sectionName .. entryKind)
            return true
        end
        table.insert(context.output[sectionName], normalized)
        context.current_item += 1
        budget -= 1
    end
    if context.current_item > #context.current_page then
        context.current_page = nil
        context.current_item = 1
        context.page_index += 1
    end
    return true
end

local function processCompletedTransport()
    local completed = completedTransport
    completedTransport = nil
    if type(completed) ~= "table" then
        return false
    end
    local operation = completed.operation
    if type(operation) ~= "table" or operation.cancelled == true or operation.generation ~= operationGeneration then
        cleanupOperationFiles(operation, false)
        if activeOperation == operation then
            activeOperation = nil
        end
        publishStatus()
        pump()
        return true
    end
    local payload, kind, message = transportPayload(operation, completed.result)
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
    publishStatus()
    return true
end

local function launchOperation(operation)
    if type(operation) ~= "table" or operation.generation ~= operationGeneration or status.available ~= true then
        return false
    end
    operation.request_path, operation.response_path, operation.guard_path = requestPaths(operation)
    operation.request_id = tostring(operation.nonce) .. "-" .. tostring(operationSequence)
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
    lastDispatchedAction = operation.action
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
    local started = noctalia.runAsync(command, function(result)
        completedTransport = { operation = operation, result = result }
    end, RPC_TIMEOUT_MS)
    if started ~= true then
        activeOperation = nil
        failNonce(operation.nonce, operation.action, "launch", "Noctalia refused the Wall-in-One backend process")
        cleanupOperationFiles(operation, false)
        return false
    end
    return true
end

pump = function()
    if activeOperation ~= nil or probeBusy or validation ~= nil or status.available ~= true then
        return
    end
    local operation = nil
    if pendingOperation ~= nil and pendingPaletteOperation ~= nil then
        if lastDispatchedAction == "library.scan" then
            operation = pendingPaletteOperation
            pendingPaletteOperation = nil
        else
            operation = pendingOperation
            pendingOperation = nil
        end
    elseif pendingOperation ~= nil then
        operation = pendingOperation
        pendingOperation = nil
    elseif pendingPaletteOperation ~= nil then
        operation = pendingPaletteOperation
        pendingPaletteOperation = nil
    end
    if type(operation) == "table" and not launchOperation(operation) then
        publishStatus()
        pump()
    end
end

local function normalizedCommand(command)
    local workshopRoots = {}
    local seen = {}
    for _, root in ipairs(type(command.workshop_roots) == "table" and command.workshop_roots or {}) do
        root = tostring(root or ""):gsub("/+$", "")
        if not validAbsolutePath(root) or seen[root] or #workshopRoots >= MAX_WORKSHOP_ROOTS then
            return nil
        end
        seen[root] = true
        table.insert(workshopRoots, root)
    end
    local normalized = {
        action = "library.scan",
        nonce = nonceValue(command.nonce),
        instance_id = tostring(command.instance_id or ""),
        image_root = tostring(command.image_root or ""):gsub("/+$", ""),
        video_root = tostring(command.video_root or ""):gsub("/+$", ""),
        workshop_roots = workshopRoots,
        wallhaven_directory = tostring(command.wallhaven_directory or ""):gsub("/+$", ""),
        automatic_stills_directory = tostring(command.automatic_stills_directory or ""):gsub("/+$", ""),
        motionbgs_directory = tostring(command.motionbgs_directory or ""):gsub("/+$", ""),
    }
    if normalized.nonce == nil
        or normalized.instance_id == ""
        or #normalized.instance_id > 80
        or normalized.instance_id:find("[%c]")
        or not optionalAbsolutePath(normalized.image_root)
        or not optionalAbsolutePath(normalized.video_root)
        or not optionalAbsolutePath(normalized.wallhaven_directory)
        or not optionalAbsolutePath(normalized.automatic_stills_directory)
        or not optionalAbsolutePath(normalized.motionbgs_directory)
    then
        return nil
    end
    return normalized
end

local function normalizedPaletteCommand(command)
    local normalized = {
        action = "palettes.inventory",
        nonce = nonceValue(command.nonce),
        custom_directory = tostring(command.custom_directory or ""):gsub("/+$", ""),
        force_refresh = command.force_refresh == true,
    }
    if normalized.nonce == nil
        or not validAbsolutePath(normalized.custom_directory)
        or type(command.force_refresh) ~= "boolean"
    then
        return nil
    end
    return normalized
end

local function cancelCurrent(message)
    operationGeneration += 1
    local processAlreadyReturned = validation ~= nil or completedTransport ~= nil
    if type(activeOperation) == "table" then
        activeOperation.cancelled = true
        failNonce(activeOperation.nonce, activeOperation.action, "cancelled", message)
        if validAbsolutePath(activeOperation.guard_path) and noctalia.fileExists(activeOperation.guard_path) then
            noctalia.removeFile(activeOperation.guard_path)
        end
        if processAlreadyReturned then
            cleanupOperationFiles(activeOperation, false)
            activeOperation = nil
        end
    end
    if type(pendingOperation) == "table" then
        failNonce(pendingOperation.nonce, pendingOperation.action, "cancelled", message)
    end
    if type(pendingPaletteOperation) == "table" then
        failNonce(pendingPaletteOperation.nonce, pendingPaletteOperation.action, "cancelled", message)
    end
    pendingOperation = nil
    pendingPaletteOperation = nil
    completedTransport = nil
    validation = nil
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
    if action == "probe" then
        cancelCurrent("Wall-in-One backend requests were cancelled by a reprobe")
        startProbe()
        return
    elseif action ~= "library.scan" then
        failNonce(nonce, action, "unsupported-action", "Unsupported Wall-in-One backend action: " .. bounded(action, 80))
        return
    end
    local operation = normalizedCommand(command)
    if operation == nil then
        failNonce(nonce, action, "invalid-request", "Library scan request was invalid")
        return
    elseif status.available ~= true then
        failNonce(nonce, action, "unavailable", "Library scanning requires a compatible Wall-in-One backend")
        return
    end
    if type(pendingOperation) == "table" then
        failNonce(
            pendingOperation.nonce,
            pendingOperation.action,
            "superseded",
            "Library scan was superseded by newer settings"
        )
    end
    pendingOperation = operation
    operation.generation = operationGeneration
    publishStatus()
    pump()
end


local function handlePaletteCommand(command)
    if type(command) ~= "table" or tonumber(command.schema or SCHEMA) ~= SCHEMA then
        return
    end
    local nonce = nonceValue(command.nonce)
    if nonce == nil or nonce <= lastPaletteNonce then
        return
    end
    lastPaletteNonce = nonce
    local action = tostring(command.action or "")
    if action ~= "palettes.inventory" then
        -- This state key is palette-owned, so malformed commands still receive
        -- a typed palette result instead of leaving the client waiting forever.
        failNonce(nonce, "palettes.inventory", "unsupported-action", "Unsupported palette backend action")
        return
    end
    local operation = normalizedPaletteCommand(command)
    if operation == nil then
        failNonce(nonce, action, "invalid-request", "Palette inventory request was invalid")
        return
    elseif status.available ~= true then
        failNonce(nonce, action, "unavailable", "Palette inventory requires a compatible Wall-in-One backend")
        return
    end
    if type(pendingPaletteOperation) == "table" then
        failNonce(
            pendingPaletteOperation.nonce,
            pendingPaletteOperation.action,
            "superseded",
            "Palette inventory was superseded by a newer request"
        )
    end
    pendingPaletteOperation = operation
    operation.generation = operationGeneration
    publishStatus()
    pump()
end

function update()
    noctalia.setUpdateInterval(if completedTransport ~= nil or validation ~= nil then 100 else 1000)
    if processCompletedTransport() then
        return
    end
    stepValidation()
    local now = math.floor(tonumber(noctalia.nowMs()) or 0)
    if not probeBusy
        and status.available ~= true
        and status.launcher_available == true
        and dataDirectory ~= ""
        and transportDirectory ~= ""
        and now >= nextDiscoveryAtMs
    then
        -- Discovery polling is metadata-only.  Do not keep executing the same
        -- incompatible or failed backend; probe only when a missing candidate
        -- appears or a higher-precedence source (notably backend-path) wins.
        local selected, source = configuredBinary()
        local changed = selected ~= ""
            and (
                status.probe_state == "binary-missing"
                or selected ~= status.binary_path
                or source ~= status.binary_source
            )
        if changed then
            startProbe()
        else
            nextDiscoveryAtMs = now + DISCOVERY_RETRY_MS
        end
    end
end

function onConfigChanged()
    cancelCurrent("Wall-in-One backend configuration changed")
    initializeStorage()
    startProbe()
end

function onExit(_signal, _reason)
    probeGeneration += 1
    probeBusy = false
    cancelCurrent("Wall-in-One backend service stopped")
    cleanupOperationFiles(activeOperation, false)
    activeOperation = nil
    completedTransport = nil
    status.ready = false
    status.available = false
    status.busy = false
    status.active_action = ""
    status.capabilities = ""
    status.probe_state = "stopped"
    status.availability_reason = "stopped"
    publishStatus()
end

initializeStorage()
publishStatus()
noctalia.state.watch(COMMAND_KEY, handleCommand)
noctalia.state.watch(PALETTE_COMMAND_KEY, handlePaletteCommand)
handleCommand(noctalia.state.get(COMMAND_KEY))
handlePaletteCommand(noctalia.state.get(PALETTE_COMMAND_KEY))
startProbe()

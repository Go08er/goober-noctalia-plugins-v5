--!nonstrict
-- Wall-in-One palette inventory service.
--
-- This entry presents the backend's normalized inventory and owns isolated
-- adaptive-preview generation. It never changes Noctalia's active theme. The
-- coordinator can consume the versioned snapshot below and remains the sole
-- authority for applying an entry's requested palette.
--
-- Commands are `{ schema=1, nonce, action="refresh", force? }` or
-- `{ schema=1, nonce, action="preview", key, path, scheme }`. Preview results
-- are published at `status.preview` as idle/loading/ready/error.

local STATUS_KEY = "wall_in_one_palettes_status_v1"
local COMMAND_KEY = "wall_in_one_palettes_command_v1"
local BACKEND_STATUS_KEY = "wall_in_one_backend_status_v1"
local BACKEND_PALETTE_COMMAND_KEY = "wall_in_one_backend_palette_command_v1"
local BACKEND_PALETTE_RESULTS_KEY = "wall_in_one_backend_palette_results_v1"
local PROTOCOL = 1
local BACKEND_CAPABILITY = "palettes.inventory"

local MAX_PALETTES = 512
local MAX_ERROR_BYTES = 640
local MAX_NONCE = 9007199254740991
local MAX_PREVIEW_KEY_BYTES = 160
local MAX_PREVIEW_SOURCE_BYTES = 512 * 1024 * 1024
local MAX_PREVIEW_OUTPUT_BYTES = 512 * 1024
local MAX_PREVIEW_CACHE_ENTRIES = 16
local MAX_PREVIEW_SWEEP_ENTRIES = 512
local COMMUNITY_TTL_SECONDS = 6 * 60 * 60
local PREVIEW_HASH_TIMEOUT_MS = 20 * 1000
local PREVIEW_TIMEOUT_MS = 20 * 1000

-- These names are pinned to Noctalia 5.0.0. A minimum-version change must
-- deliberately re-audit them against the shell's theme implementation.
local PINNED_WALLPAPER = {
    { name = "m3-content" },
    { name = "m3-tonal-spot" },
    { name = "m3-fruit-salad" },
    { name = "m3-rainbow" },
    { name = "m3-monochrome" },
    { name = "vibrant" },
    { name = "faithful" },
    { name = "soft" },
    { name = "dysfunctional" },
    { name = "muted" },
}

local PINNED_WALLPAPER_SCHEMES = {}
for _, entry in ipairs(PINNED_WALLPAPER) do
    PINNED_WALLPAPER_SCHEMES[entry.name] = true
end

-- Preview roles pinned from Noctalia c366a35, src/theme/builtin_palettes.cpp.
local PINNED_BUILTIN = {
    {
        name = "Ayu",
        preview = {
            dark = { surface = "#0B0E14", accents = { "#E6B450", "#AAD94C", "#39BAE6", "#D95757" } },
            light = { surface = "#F8F9FA", accents = { "#FF8F40", "#86B300", "#55B4D4", "#E65050" } },
        },
    },
    {
        name = "Catppuccin",
        preview = {
            dark = { surface = "#1E1E2E", accents = { "#CBA6F7", "#FAB387", "#94E2D5", "#F38BA8" } },
            light = { surface = "#EFF1F5", accents = { "#8839EF", "#FE640B", "#40A02B", "#D20F39" } },
        },
    },
    {
        name = "Dracula",
        preview = {
            dark = { surface = "#282A36", accents = { "#BD93F9", "#FF79C6", "#8BE9FD", "#FF5555" } },
            light = { surface = "#F8F8F2", accents = { "#8332F4", "#FF1399", "#0398B9", "#FF5555" } },
        },
    },
    {
        name = "Eldritch",
        preview = {
            dark = { surface = "#212337", accents = { "#37F499", "#04D1F9", "#A48CF2", "#F16C75" } },
            light = { surface = "#F0F3F4", accents = { "#FB5BB6", "#0AD6FF", "#8A69F7", "#FB5B66" } },
        },
    },
    {
        name = "Gruvbox",
        preview = {
            dark = { surface = "#282828", accents = { "#B8BB26", "#FABD2F", "#83A598", "#FB4934" } },
            light = { surface = "#FBF1C7", accents = { "#98971A", "#D79921", "#458588", "#CC241D" } },
        },
    },
    {
        name = "Kanagawa",
        preview = {
            dark = { surface = "#1F1F28", accents = { "#76946A", "#C0A36E", "#7E9CD8", "#C34043" } },
            light = { surface = "#F2ECBC", accents = { "#6F894E", "#77713F", "#4D699B", "#C84053" } },
        },
    },
    {
        name = "Noctalia",
        preview = {
            dark = { surface = "#070722", accents = { "#FFF59B", "#A9AEFE", "#9BFECE", "#FD4663" } },
            light = { surface = "#E6E8FA", accents = { "#5D65F5", "#8E93D8", "#0E0E43", "#FD4663" } },
        },
    },
    {
        name = "Nord",
        preview = {
            dark = { surface = "#2E3440", accents = { "#8FBCBB", "#88C0D0", "#5E81AC", "#BF616A" } },
            light = { surface = "#ECEFF4", accents = { "#5E81AC", "#64ADC2", "#6FA9A8", "#BF616A" } },
        },
    },
    {
        name = "Rosé Pine",
        preview = {
            dark = { surface = "#191724", accents = { "#EBBCBA", "#9CCFD8", "#31748F", "#EB6F92" } },
            light = { surface = "#FFFAF3", accents = { "#D7827E", "#56949F", "#286983", "#B4637A" } },
        },
    },
    {
        name = "Tokyo-Night",
        preview = {
            dark = { surface = "#1A1B26", accents = { "#7AA2F7", "#BB9AF7", "#9ECE6A", "#F7768E" } },
            light = { surface = "#E1E2E7", accents = { "#2E7DE9", "#9854F1", "#587539", "#F52A65" } },
        },
    },
}

local INSTANCE_ID = (tostring(noctalia.nowMs()) .. "-" .. tostring({}))
    :gsub("[^%w%-]", "")
    :sub(1, 48)

local communityPalettes = {}
local customPalettes = {}
local communityInFlight = false
local ready = false
local imageRoot = ""
local configurationError = ""
local cacheLoaded = false
local cacheSource = "none"
local cacheFetchedAt = 0
local cacheFetchedAtText = ""
local customDirectory = ""
local customInvalidCount = 0
local communityError = ""
local customError = ""
local cacheError = ""
local commandError = ""
local lastErrorAt = ""
local lastRefreshAt = ""
local lastCommunitySuccessAt = ""
local lastCustomRefreshAt = ""
local lastEvent = "starting"
local lastCommandNonce = 0
local statusRevision = 0
local lastPublishedSignature = ""
local inventoryRetryRequested = false
local inventoryRetryForce = false
local inventorySignature = ""
local inventoryCommandSequence = 0
local pendingInventoryNonce = 0
local pendingInventoryForce = false
local lastInventoryResultSequence = 0
local completedInventoryResult = nil
local previewGeneration = 1
local previewSequence = 0
local activePreviewOperation = nil
local pendingPreviewRequest = nil
local previewCache = {}
local previewCacheOrder = {}
local previewStatus = {
    state = "idle",
    key = "",
    path = "",
    scheme = "",
    fingerprint = "",
    preview = nil,
    error = "",
}

local function nowSeconds()
    return math.max(0, math.floor(tonumber(noctalia.formatTime("%s")) or 0))
end

local function nowText()
    return noctalia.formatTime("%Y-%m-%d %H:%M:%S")
end

local function bounded(value, maximum)
    local text = tostring(value or ""):gsub("[%c]", " ")
    if #text > maximum then
        return text:sub(1, maximum)
    end
    return text
end

local function validAbsolutePath(value)
    return type(value) == "string"
        and #value > 1
        and #value <= 4096
        and value:sub(1, 1) == "/"
        and value:sub(-1) ~= "/"
        and value:find("[%c\\]") == nil
        and value:find("//", 1, true) == nil
        and value:find("/./", 1, true) == nil
        and value:find("/../", 1, true) == nil
        and value:match("/%.$") == nil
        and value:match("/%.%.$") == nil
end

local function configuredImageRoot()
    local configured = noctalia.getConfig("capture_directory")
    if type(configured) ~= "string" or configured:find("%S") == nil then
        return nil, "Select an existing wallpaper image directory first"
    end
    local expanded = noctalia.expandPath(configured)
    if type(expanded) ~= "string" then
        return nil, "The selected wallpaper image directory is not a safe absolute path"
    end
    expanded = expanded:gsub("/+$", "")
    if expanded == "" or expanded == "/" or not validAbsolutePath(expanded) then
        return nil, "The selected wallpaper image directory is not a safe absolute path"
    end
    local info = noctalia.fileInfo(expanded)
    if type(info) ~= "table" or info.isDir ~= true then
        return nil, "The selected wallpaper image directory does not exist"
    end
    return expanded, nil
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function validPreviewKey(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= MAX_PREVIEW_KEY_BYTES
        and value:find("[%c]") == nil
end

local function normalizedColor(value)
    if type(value) ~= "string" or value:match("^#%x%x%x%x%x%x$") == nil then
        return ""
    end
    return value:upper()
end

local function modeField(candidate, field)
    if type(candidate) ~= "table" then
        return ""
    end
    return normalizedColor(candidate[field])
end

local function normalizedPreviewMode(candidate)
    if type(candidate) ~= "table" then
        return { surface = "", accents = {} }
    end

    local accents = {}
    if type(candidate.accents) == "table" then
        for index = 1, math.min(#candidate.accents, 4) do
            local color = normalizedColor(candidate.accents[index])
            if color ~= "" then
                table.insert(accents, color)
            end
        end
    else
        for _, field in ipairs({ "primary", "secondary", "tertiary", "error" }) do
            local color = modeField(candidate, field)
            if color ~= "" then
                table.insert(accents, color)
            end
        end
    end

    return {
        surface = modeField(candidate, "surface"),
        accents = accents,
    }
end

local function copyPreviewMode(mode)
    local accents = {}
    for _, color in ipairs(type(mode) == "table" and type(mode.accents) == "table" and mode.accents or {}) do
        table.insert(accents, tostring(color))
    end
    return {
        surface = type(mode) == "table" and tostring(mode.surface or "") or "",
        accents = accents,
    }
end

local function copyAdaptivePreview(preview)
    return {
        dark = copyPreviewMode(type(preview) == "table" and preview.dark or nil),
        light = copyPreviewMode(type(preview) == "table" and preview.light or nil),
    }
end

local function normalizedAdaptivePreview(candidate)
    if type(candidate) ~= "table" then
        return nil, "Noctalia returned a non-object palette preview"
    end

    local normalized = {}
    for _, modeName in ipairs({ "dark", "light" }) do
        local mode = candidate[modeName]
        if type(mode) ~= "table" then
            return nil, "Noctalia's palette preview is missing the " .. modeName .. " mode"
        end

        -- Copy only the five public preview roles. In particular, do not let
        -- an unexpected `accents` array bypass role-by-role validation.
        local previewMode = normalizedPreviewMode({
            surface = mode.surface,
            primary = mode.primary,
            secondary = mode.secondary,
            tertiary = mode.tertiary,
            error = mode.error,
        })
        if previewMode.surface == "" or #previewMode.accents ~= 4 then
            return nil, "Noctalia's " .. modeName .. " palette preview has invalid color roles"
        end
        normalized[modeName] = previewMode
    end
    return normalized, nil
end

local function configPalettesDirectory()
    local base = noctalia.getenv("NOCTALIA_CONFIG_HOME")
    if type(base) ~= "string" or base == "" then
        base = noctalia.getenv("XDG_CONFIG_HOME")
    end
    if type(base) ~= "string" or base == "" then
        local home = noctalia.getenv("HOME")
        if type(home) == "string" and home ~= "" then
            base = home .. "/.config"
        end
    end
    if type(base) ~= "string" or base == "" then
        return nil, "HOME and the Noctalia/XDG config overrides are unavailable"
    end
    if base:sub(1, 1) ~= "/" or base:find("[%c]") then
        return nil, "Noctalia config home is not a safe absolute path"
    end
    base = base:gsub("/+$", "")
    return base .. "/noctalia/palettes", nil
end

local function cacheIsFresh()
    local now = nowSeconds()
    return cacheLoaded
        and now > 0
        and cacheFetchedAt > 0
        and now >= cacheFetchedAt
        and now - cacheFetchedAt < COMMUNITY_TTL_SECONDS
end

local function signatureToken(value)
    local text = tostring(value or "")
    return tostring(#text) .. ":" .. text
end

local function previewMetadataFingerprint(path, size, mtime, scheme)
    return table.concat({
        "metadata",
        signatureToken(path),
        tostring(size),
        tostring(mtime),
        signatureToken(scheme),
    }, "|")
end

local function previewFingerprint(path, size, mtime, digest, scheme)
    return table.concat({
        "sha256",
        signatureToken(path),
        tostring(size),
        tostring(mtime),
        signatureToken(digest),
        signatureToken(scheme),
    }, "|")
end

local function normalizedSha256(value)
    local line = tostring(value or ""):match("([^\r\n]+)%s*$") or ""
    local token = line:match("^%s*(%S+)") or ""
    if #token ~= 64 or token:match("^%x+$") == nil then
        return nil
    end
    return token:lower()
end

local function adaptivePreviewSignature(preview)
    local parts = {}
    for _, modeName in ipairs({ "dark", "light" }) do
        local mode = type(preview) == "table" and preview[modeName] or nil
        table.insert(parts, signatureToken(type(mode) == "table" and mode.surface or ""))
        for _, color in ipairs(type(mode) == "table" and type(mode.accents) == "table" and mode.accents or {}) do
            table.insert(parts, signatureToken(color))
        end
    end
    return table.concat(parts, "|")
end

local function combinedError()
    local errors = {}
    for _, message in ipairs({ communityError, customError, cacheError, commandError }) do
        if tostring(message or "") ~= "" then
            table.insert(errors, tostring(message))
        end
    end
    return bounded(table.concat(errors, "; "), MAX_ERROR_BYTES)
end

local function statusSignature()
    return table.concat({
        INSTANCE_ID,
        tostring(ready),
        imageRoot,
        configurationError,
        tostring(communityInFlight),
        combinedError(),
        lastErrorAt,
        lastRefreshAt,
        lastCommunitySuccessAt,
        lastCustomRefreshAt,
        lastEvent,
        tostring(lastCommandNonce),
        tostring(cacheLoaded),
        cacheSource,
        tostring(cacheFetchedAt),
        cacheFetchedAtText,
        customDirectory,
        tostring(customInvalidCount),
        previewStatus.state,
        previewStatus.key,
        previewStatus.path,
        previewStatus.scheme,
        previewStatus.fingerprint,
        previewStatus.error,
        adaptivePreviewSignature(previewStatus.preview),
        inventorySignature,
    }, "\0")
end

local function statusSnapshot()
    local errorMessage = combinedError()
    return {
        protocol = PROTOCOL,
        instance_id = INSTANCE_ID,
        revision = statusRevision,
        ready = ready,
        available = ready,
        image_root = imageRoot,
        configuration_error = configurationError,
        refreshing = communityInFlight,
        degraded = errorMessage ~= "",
        error = errorMessage,
        error_at = lastErrorAt,
        last_refresh_at = lastRefreshAt,
        last_success_at = lastCommunitySuccessAt,
        custom_refreshed_at = lastCustomRefreshAt,
        last_event = lastEvent,
        last_nonce = lastCommandNonce,
        custom_directory = customDirectory,
        preview = {
            state = previewStatus.state,
            key = previewStatus.key,
            path = previewStatus.path,
            scheme = previewStatus.scheme,
            fingerprint = previewStatus.fingerprint,
            preview = if type(previewStatus.preview) == "table"
                then copyAdaptivePreview(previewStatus.preview)
                else {},
            error = previewStatus.error,
        },
        cache = {
            loaded = cacheLoaded,
            source = cacheSource,
            fetched_at = cacheFetchedAt,
            fetched_at_text = cacheFetchedAtText,
            fresh = cacheIsFresh(),
            ttl_seconds = COMMUNITY_TTL_SECONDS,
        },
        counts = {
            wallpaper = if ready then #PINNED_WALLPAPER else 0,
            builtin = if ready then #PINNED_BUILTIN else 0,
            community = #communityPalettes,
            custom = #customPalettes,
            invalid_custom = customInvalidCount,
        },
        palettes = {
            wallpaper = if ready then PINNED_WALLPAPER else {},
            builtin = if ready then PINNED_BUILTIN else {},
            community = communityPalettes,
            custom = customPalettes,
        },
    }
end

local function publishStatus(force)
    local signature = statusSignature()
    if force ~= true and signature == lastPublishedSignature then
        return false
    end
    lastPublishedSignature = signature
    statusRevision = if statusRevision >= MAX_NONCE then 1 else statusRevision + 1
    noctalia.state.set(STATUS_KEY, statusSnapshot())
    return true
end

local function nextPreviewGeneration()
    previewGeneration = if previewGeneration >= MAX_NONCE then 1 else previewGeneration + 1
    return previewGeneration
end

local function previewSourceInfo(path)
    if not validAbsolutePath(path) then
        return nil, "Palette preview source must be a safe absolute image path"
    end
    local info = noctalia.fileInfo(path)
    local size = type(info) == "table" and tonumber(info.size) or nil
    -- Some valid immutable sources (notably Nix-store files) can report an
    -- epoch or sub-second timestamp through the host API. Content identity is
    -- enforced separately with matching pre/post SHA-256 digests, so mtime is
    -- a cache hint rather than a reason to reject an otherwise bounded file.
    local mtime = type(info) == "table" and (tonumber(info.mtime) or 0) or 0
    if
        type(info) ~= "table"
        or info.isDir == true
        or size == nil
        or size % 1 ~= 0
        or size < 1
        or size > MAX_PREVIEW_SOURCE_BYTES
        or mtime ~= mtime
        or mtime < 0
        or mtime > MAX_NONCE
    then
        return nil, "Palette preview source is not a bounded regular image file"
    end
    return { size = math.floor(size), mtime = math.floor(mtime) }, nil
end

local function setPreviewStatus(state, request, preview, errorMessage)
    local source = type(request) == "table" and request or {}
    previewStatus = {
        state = state,
        key = tostring(source.key or ""),
        path = tostring(source.path or ""),
        scheme = tostring(source.scheme or ""),
        fingerprint = tostring(source.fingerprint or ""),
        preview = if type(preview) == "table" then copyAdaptivePreview(preview) else nil,
        error = bounded(errorMessage or "", MAX_ERROR_BYTES),
    }
    publishStatus(false)
end

local function touchPreviewCache(fingerprint)
    for index, value in ipairs(previewCacheOrder) do
        if value == fingerprint then
            table.remove(previewCacheOrder, index)
            break
        end
    end
    table.insert(previewCacheOrder, fingerprint)
end

local function getCachedPreview(fingerprint)
    local preview = previewCache[fingerprint]
    if type(preview) ~= "table" then
        return nil
    end
    touchPreviewCache(fingerprint)
    return copyAdaptivePreview(preview)
end

local function cachePreview(fingerprint, preview)
    previewCache[fingerprint] = copyAdaptivePreview(preview)
    touchPreviewCache(fingerprint)
    while #previewCacheOrder > MAX_PREVIEW_CACHE_ENTRIES do
        local discarded = table.remove(previewCacheOrder, 1)
        previewCache[discarded] = nil
    end
end

local function previewDirectory()
    local dataDirectory = noctalia.pluginDataDir()
    if type(dataDirectory) ~= "string" then
        return nil, "Plugin palette-preview storage is unavailable"
    end
    dataDirectory = dataDirectory:gsub("/+$", "")
    if not validAbsolutePath(dataDirectory) then
        return nil, "Plugin palette-preview storage is unavailable"
    end
    local directory = dataDirectory .. "/palette-preview"
    local made, makeError = noctalia.mkdirAll(directory)
    if made ~= true then
        return nil, tostring(makeError or "Could not create palette-preview storage")
    end
    local info = noctalia.fileInfo(directory)
    if type(info) ~= "table" or info.isDir ~= true then
        return nil, "Plugin palette-preview storage is not a directory"
    end
    return directory, nil
end

local function removePreviewFile(path)
    if validAbsolutePath(path) and noctalia.fileExists(path) then
        noctalia.removeFile(path)
    end
end

local function ownedPreviewFilename(value)
    local name = tostring(value or "")
    return name:match("^preview%-%d+%-%d+%-%d+%.json$") ~= nil
        or name:match("^%.wall%-in%-one%-preview%-%d+%-%d+%-%d+$") ~= nil
end

local function sweepOwnedPreviewFiles()
    local directory = previewDirectory()
    if directory == nil then
        return 0
    end
    local names = noctalia.listDir(directory)
    if type(names) ~= "table" then
        return 0
    end
    local removed = 0
    for index = 1, math.min(#names, MAX_PREVIEW_SWEEP_ENTRIES) do
        local name = tostring(names[index] or "")
        if ownedPreviewFilename(name) then
            removePreviewFile(directory .. "/" .. name)
            removed += 1
        end
    end
    return removed
end

local function cleanupPreviewOperation(operation)
    if type(operation) ~= "table" then
        return
    end
    removePreviewFile(operation.guard_path)
    removePreviewFile(operation.output_path)
end

local function allocatePreviewFiles(operation)
    local directory, directoryError = previewDirectory()
    if directory == nil then
        return false, directoryError
    end
    for _ = 1, 8 do
        previewSequence += 1
        local token = tostring(math.floor(noctalia.nowMs()))
            .. "-"
            .. tostring(lastCommandNonce)
            .. "-"
            .. tostring(previewSequence)
        local outputPath = directory .. "/preview-" .. token .. ".json"
        local guardPath = directory .. "/.wall-in-one-preview-" .. token
        if not noctalia.fileExists(outputPath) and not noctalia.fileExists(guardPath) then
            local wrote, writeError = noctalia.writeFile(guardPath, "WIO-PREVIEW1\n")
            if wrote ~= true then
                return false, tostring(writeError or "Could not reserve palette-preview output")
            end
            operation.output_path = outputPath
            operation.guard_path = guardPath
            return true, nil
        end
    end
    return false, "Could not allocate unique palette-preview files"
end

local function previewOperationIsCurrent(operation)
    return ready
        and activePreviewOperation == operation
        and operation.generation == previewGeneration
        and type(operation.request) == "table"
        and previewStatus.key == operation.request.key
        and previewStatus.fingerprint == operation.request.fingerprint
end

local startPreviewOperation

local function startPendingPreview()
    if not ready or activePreviewOperation ~= nil then
        return
    end
    local request = pendingPreviewRequest
    pendingPreviewRequest = nil
    if type(request) == "table" and request.generation == previewGeneration then
        startPreviewOperation(request)
    end
end

local function sourceStillMatchesRequest(request)
    local currentSource, sourceError = previewSourceInfo(request.path)
    if
        currentSource == nil
        or currentSource.size ~= request.size
        or currentSource.mtime ~= request.mtime
    then
        return false, sourceError or "Palette preview source changed while Noctalia was reading it"
    end
    return true, nil
end

local function finishPreviewOperation(operation, result)
    local current = previewOperationIsCurrent(operation)
    if activePreviewOperation == operation then
        activePreviewOperation = nil
    end
    if not current then
        cleanupPreviewOperation(operation)
        startPendingPreview()
        return
    end

    local request = operation.request
    local function fail(message)
        cleanupPreviewOperation(operation)
        setPreviewStatus("error", request, nil, message)
        startPendingPreview()
    end

    if type(result) ~= "table" then
        fail("Noctalia's palette-preview command returned no process result")
        return
    end
    if result.timedOut == true then
        fail("Noctalia's palette-preview command exceeded the 20 second timeout")
        return
    end
    if tonumber(result.exitCode) ~= 0 then
        local detail = bounded(result.stderr or result.stdout, 400)
        if detail == "" then
            detail = "Noctalia's palette-preview command failed"
        end
        fail(detail)
        return
    end

    local postDigest = normalizedSha256(result.stdout)
    if postDigest == nil or postDigest ~= request.digest then
        fail("Palette preview source content changed while Noctalia was reading it")
        return
    end
    local sourceMatches, sourceError = sourceStillMatchesRequest(request)
    if not sourceMatches then
        fail(sourceError)
        return
    end

    local info = noctalia.fileInfo(operation.output_path)
    local outputSize = type(info) == "table" and tonumber(info.size) or nil
    if
        type(info) ~= "table"
        or info.isDir == true
        or outputSize == nil
        or outputSize % 1 ~= 0
        or outputSize < 1
        or outputSize > MAX_PREVIEW_OUTPUT_BYTES
    then
        fail("Noctalia returned an invalid or oversized palette-preview file")
        return
    end

    local body, readError = noctalia.readFile(operation.output_path)
    cleanupPreviewOperation(operation)
    if
        type(body) ~= "string"
        or #body ~= math.floor(outputSize)
        or #body > MAX_PREVIEW_OUTPUT_BYTES
    then
        setPreviewStatus(
            "error",
            request,
            nil,
            readError or "Noctalia's palette-preview file could not be read exactly"
        )
        startPendingPreview()
        return
    end

    local decoded, decodeError = noctalia.json.decode(body)
    local preview, previewError = normalizedAdaptivePreview(decoded)
    if preview == nil then
        setPreviewStatus(
            "error",
            request,
            nil,
            previewError or decodeError or "Noctalia returned invalid palette-preview JSON"
        )
        startPendingPreview()
        return
    end

    cachePreview(request.fingerprint, preview)
    setPreviewStatus("ready", request, preview, "")
    startPendingPreview()
end

local function startHashedPreviewGeneration(operation)
    local request = operation.request
    local allocated, allocationError = allocatePreviewFiles(operation)
    if allocated ~= true then
        activePreviewOperation = nil
        cleanupPreviewOperation(operation)
        setPreviewStatus("error", request, nil, allocationError)
        startPendingPreview()
        return false
    end

    operation.phase = "theme"
    local command = table.concat({
        "umask 077; noctalia theme",
        shellQuote(request.path),
        "--scheme",
        shellQuote(request.scheme),
        "--both -o",
        shellQuote(operation.output_path),
        "&& test -f",
        shellQuote(operation.guard_path),
        "&& sha256sum --",
        shellQuote(request.path),
        "|| { rm -f --",
        shellQuote(operation.output_path),
        "; exit 1; }",
    }, " ")
    local accepted = noctalia.runAsync(command, function(result)
        finishPreviewOperation(operation, result)
    end, PREVIEW_TIMEOUT_MS)
    if accepted ~= true then
        activePreviewOperation = nil
        cleanupPreviewOperation(operation)
        setPreviewStatus("error", request, nil, "Noctalia could not start adaptive palette generation")
        startPendingPreview()
        return false
    end
    return true
end

local function finishPreviewHashOperation(operation, result)
    local current = previewOperationIsCurrent(operation)
    if not current then
        if activePreviewOperation == operation then
            activePreviewOperation = nil
        end
        cleanupPreviewOperation(operation)
        startPendingPreview()
        return
    end

    local request = operation.request
    local function fail(message)
        if activePreviewOperation == operation then
            activePreviewOperation = nil
        end
        cleanupPreviewOperation(operation)
        setPreviewStatus("error", request, nil, message)
        startPendingPreview()
    end

    if type(result) ~= "table" then
        fail("The palette-preview content digest returned no process result")
        return
    end
    if result.timedOut == true then
        fail("The palette-preview content digest exceeded the 20 second timeout")
        return
    end
    if tonumber(result.exitCode) ~= 0 then
        local detail = bounded(result.stderr or result.stdout, 400)
        fail(if detail ~= "" then detail else "The palette-preview content digest failed")
        return
    end

    local digest = normalizedSha256(result.stdout)
    if digest == nil then
        fail("The palette-preview content digest returned malformed output")
        return
    end
    local sourceMatches, sourceError = sourceStillMatchesRequest(request)
    if not sourceMatches then
        fail(sourceError)
        return
    end

    request.digest = digest
    request.fingerprint = previewFingerprint(request.path, request.size, request.mtime, digest, request.scheme)
    local cached = getCachedPreview(request.fingerprint)
    if cached ~= nil then
        activePreviewOperation = nil
        cleanupPreviewOperation(operation)
        setPreviewStatus("ready", request, cached, "")
        startPendingPreview()
        return
    end

    setPreviewStatus("loading", request, nil, "")
    startHashedPreviewGeneration(operation)
end

startPreviewOperation = function(request)
    if not ready or type(request) ~= "table" or request.generation ~= previewGeneration then
        return false
    end
    if activePreviewOperation ~= nil then
        pendingPreviewRequest = request
        return false
    end
    if not noctalia.commandExists("noctalia") then
        setPreviewStatus("error", request, nil, "The installed Noctalia CLI is required for adaptive previews")
        return false
    end
    if not noctalia.commandExists("sha256sum") then
        setPreviewStatus("error", request, nil, "sha256sum is required for content-safe adaptive previews")
        return false
    end

    local operation = { request = request, generation = request.generation, phase = "hash" }
    activePreviewOperation = operation
    local command = "exec sha256sum -- " .. shellQuote(request.path)
    local accepted = noctalia.runAsync(command, function(result)
        finishPreviewHashOperation(operation, result)
    end, PREVIEW_HASH_TIMEOUT_MS)
    if accepted ~= true then
        activePreviewOperation = nil
        cleanupPreviewOperation(operation)
        setPreviewStatus("error", request, nil, "Noctalia could not start the palette-preview content digest")
        startPendingPreview()
        return false
    end
    return true
end

local function previewRequest(command)
    if not validPreviewKey(command.key) then
        return nil, "Palette preview key is missing or exceeds its bounded format"
    end
    if not validAbsolutePath(command.path) then
        return nil, "Palette preview source must be a safe absolute image path"
    end
    if type(command.scheme) ~= "string" or PINNED_WALLPAPER_SCHEMES[command.scheme] ~= true then
        return nil, "Palette preview scheme is not supported by this Noctalia version"
    end
    local source, sourceError = previewSourceInfo(command.path)
    if source == nil then
        return nil, sourceError
    end
    return {
        key = command.key,
        path = command.path,
        scheme = command.scheme,
        size = source.size,
        mtime = source.mtime,
        digest = "",
        fingerprint = previewMetadataFingerprint(command.path, source.size, source.mtime, command.scheme),
    }, nil
end

local function requestAdaptivePreview(command)
    local generation = nextPreviewGeneration()
    local request, requestError = previewRequest(command)
    if request == nil then
        pendingPreviewRequest = nil
        local rejected = {
            key = if validPreviewKey(command.key) then command.key else "",
            path = if validAbsolutePath(command.path) then command.path else "",
            scheme = if type(command.scheme) == "string" and PINNED_WALLPAPER_SCHEMES[command.scheme]
                then command.scheme
                else "",
            fingerprint = "",
        }
        setPreviewStatus("error", rejected, nil, requestError)
        return false
    end
    request.generation = generation

    setPreviewStatus("loading", request, nil, "")
    if activePreviewOperation ~= nil then
        pendingPreviewRequest = request
        return true
    end
    return startPreviewOperation(request)
end

local function backendSupportsPalettes()
    local status = noctalia.state.get(BACKEND_STATUS_KEY)
    local capabilities = type(status) == "table" and tostring(status.capabilities or "") or ""
    return type(status) == "table"
        and status.available == true
        and ("," .. capabilities .. ","):find("," .. BACKEND_CAPABILITY .. ",", 1, true) ~= nil
end

local function nextInventoryNonce()
    local previous = noctalia.state.get(BACKEND_PALETTE_COMMAND_KEY)
    local previousNonce = type(previous) == "table" and tonumber(previous.nonce) or 0
    inventoryCommandSequence = math.max(inventoryCommandSequence, previousNonce) + 1
    if inventoryCommandSequence > MAX_NONCE then
        inventoryCommandSequence = 1
    end
    return inventoryCommandSequence
end

local function requestInventory(force, reason)
    if communityInFlight then
        lastEvent = "refresh-in-flight"
        publishStatus(false)
        return false
    end
    local customPath, customPathError = configPalettesDirectory()
    if customPath == nil then
        customDirectory = ""
        communityError = bounded(customPathError, MAX_ERROR_BYTES)
        lastErrorAt = nowText()
        lastEvent = "backend-unavailable"
        publishStatus(false)
        return false
    end
    customDirectory = customPath
    if not backendSupportsPalettes() then
        inventoryRetryRequested = true
        inventoryRetryForce = inventoryRetryForce or force == true
        communityError = "Install a compatible wall-in-one-backend or select its executable path"
        lastErrorAt = nowText()
        lastEvent = "backend-unavailable"
        publishStatus(false)
        return false
    end
    local effectiveForce = force == true or inventoryRetryForce
    inventoryRetryRequested = false
    inventoryRetryForce = false
    pendingInventoryNonce = nextInventoryNonce()
    pendingInventoryForce = effectiveForce
    communityInFlight = true
    lastEvent = bounded(reason or "refresh-started", 80)
    noctalia.state.set(BACKEND_PALETTE_COMMAND_KEY, {
        schema = PROTOCOL,
        nonce = pendingInventoryNonce,
        action = BACKEND_CAPABILITY,
        custom_directory = customPath,
        force_refresh = effectiveForce,
    })
    publishStatus(false)
    return true
end

local function adoptInventoryResult(candidate)
    local sequence = type(candidate) == "table" and tonumber(candidate.sequence) or nil
    if sequence == nil or sequence <= lastInventoryResultSequence then
        return false
    end
    lastInventoryResultSequence = math.floor(sequence)
    if tostring(candidate.action or "") ~= BACKEND_CAPABILITY
        or tonumber(candidate.nonce) ~= pendingInventoryNonce
    then
        return false
    end
    local attemptedForce = pendingInventoryForce
    communityInFlight = false
    pendingInventoryNonce = 0
    pendingInventoryForce = false
    if candidate.ok ~= true then
        local failure = type(candidate.error) == "table" and candidate.error or {}
        local kind = tostring(failure.kind or "")
        inventoryRetryRequested = kind == "unavailable" or kind == "cancelled"
        inventoryRetryForce = inventoryRetryRequested and (inventoryRetryForce or attemptedForce)
        communityError = bounded(failure.message or "Palette inventory backend failed", MAX_ERROR_BYTES)
        lastErrorAt = nowText()
        lastEvent = "refresh-failed"
        publishStatus(false)
        return true
    end
    local inventory = candidate.palettes
    local cache = type(inventory) == "table" and inventory.cache or nil
    if type(inventory) ~= "table"
        or type(inventory.community) ~= "table"
        or type(inventory.custom) ~= "table"
        or #inventory.community > MAX_PALETTES
        or #inventory.custom > MAX_PALETTES
        or type(cache) ~= "table"
        or type(inventory.signature) ~= "string"
        or #inventory.signature ~= 64
        or inventory.signature:match("^%x+$") == nil
    then
        communityError = "Palette inventory backend returned an invalid normalized result"
        lastErrorAt = nowText()
        lastEvent = "refresh-failed"
        publishStatus(false)
        return true
    end
    communityPalettes = inventory.community
    customPalettes = inventory.custom
    customDirectory = bounded(inventory.custom_directory, 4096)
    customInvalidCount = math.floor(tonumber(inventory.invalid_custom) or 0)
    communityError = bounded(inventory.community_error, MAX_ERROR_BYTES)
    customError = bounded(inventory.custom_error, MAX_ERROR_BYTES)
    cacheError = bounded(inventory.cache_error, MAX_ERROR_BYTES)
    cacheLoaded = cache.loaded == true
    cacheSource = bounded(cache.source, 80)
    cacheFetchedAt = math.floor(tonumber(cache.fetched_at) or 0)
    cacheFetchedAtText = bounded(cache.fetched_at_text, 80)
    lastRefreshAt = bounded(inventory.last_refresh_at, 80)
    lastCommunitySuccessAt = bounded(inventory.last_success_at, 80)
    lastCustomRefreshAt = bounded(inventory.custom_refreshed_at, 80)
    lastEvent = bounded(inventory.last_event, 80)
    inventorySignature = inventory.signature:lower()
    inventoryRetryForce = false
    if combinedError() ~= "" then
        lastErrorAt = nowText()
    end
    publishStatus(false)
    return true
end

local function clearInventoryState()
    communityPalettes = {}
    customPalettes = {}
    cacheLoaded = false
    cacheSource = "none"
    cacheFetchedAt = 0
    cacheFetchedAtText = ""
    customDirectory = ""
    customInvalidCount = 0
    communityError = ""
    customError = ""
    cacheError = ""
    commandError = ""
    lastErrorAt = ""
    lastRefreshAt = ""
    lastCommunitySuccessAt = ""
    lastCustomRefreshAt = ""
    inventorySignature = ""
    pendingPreviewRequest = nil
    previewCache = {}
    previewCacheOrder = {}
    previewStatus = {
        state = "idle",
        key = "",
        path = "",
        scheme = "",
        fingerprint = "",
        preview = nil,
        error = "",
    }
end

local function deactivateForMissingImageRoot(reason)
    nextPreviewGeneration()
    cleanupPreviewOperation(activePreviewOperation)
    inventoryRetryRequested = false
    inventoryRetryForce = false
    completedInventoryResult = nil
    pendingInventoryNonce = 0
    pendingInventoryForce = false
    activePreviewOperation = nil
    communityInFlight = false
    ready = false
    imageRoot = ""
    configurationError = bounded(reason or "Select an existing wallpaper image directory first", MAX_ERROR_BYTES)
    clearInventoryState()
    lastEvent = "waiting-for-image-directory"
end

local function initializeForImageRoot(root)
    -- Reaching plugin-owned cache or Noctalia's custom palette directory is
    -- permitted only after the user-selected image root has been validated.
    imageRoot = root
    configurationError = ""
    clearInventoryState()
    sweepOwnedPreviewFiles()
    ready = true
    lastEvent = "image-directory-ready"
end

local function commandNonce(command)
    local nonce = type(command) == "table" and tonumber(command.nonce) or nil
    if nonce == nil or nonce % 1 ~= 0 or nonce <= 0 or nonce > MAX_NONCE then
        return nil
    end
    return nonce
end

local function handleCommand(command)
    local nonce = commandNonce(command)
    if nonce == nil or nonce <= lastCommandNonce then
        return false
    end
    lastCommandNonce = nonce
    commandError = ""

    local action = tostring(command.action or "")
    if
        tonumber(command.schema) ~= PROTOCOL
        or (tostring(command.action or "") ~= "refresh" and action ~= "preview")
    then
        commandError = "Palette command was rejected because its schema or action is invalid"
        lastErrorAt = nowText()
        lastEvent = "command-rejected"
        publishStatus(false)
        return true
    end

    if ready then
        local currentRoot, rootError = configuredImageRoot()
        if currentRoot == nil or currentRoot ~= imageRoot then
            deactivateForMissingImageRoot(rootError or "Wallpaper image directory changed")
        end
    end
    if not ready then
        commandError = if configurationError ~= ""
            then configurationError
            else "Select an existing wallpaper image directory first"
        lastErrorAt = nowText()
        lastEvent = "command-unavailable"
        publishStatus(false)
        return true
    end

    if action == "refresh" then
        requestInventory(command.force == true, "refresh-started")
    else
        requestAdaptivePreview(command)
    end
    publishStatus(false)
    return true
end

function update()
    noctalia.setUpdateInterval(if completedInventoryResult ~= nil then 100 else 1000)
    if completedInventoryResult ~= nil then
        local candidate = completedInventoryResult
        completedInventoryResult = nil
        adoptInventoryResult(candidate)
    end
    if inventoryRetryRequested and ready then
        if backendSupportsPalettes() then
            requestInventory(inventoryRetryForce, "backend-ready")
        end
    end
end

function onConfigChanged()
    local configuredRoot, rootError = configuredImageRoot()
    if configuredRoot == nil then
        deactivateForMissingImageRoot(rootError)
        publishStatus(false)
        return
    end
    if not ready or configuredRoot ~= imageRoot then
        if ready then
            deactivateForMissingImageRoot("Wallpaper image directory changed")
        end
        initializeForImageRoot(configuredRoot)
        -- A newly authorized root gets one normal TTL-gated catalog refresh.
        requestInventory(false, "image-directory-ready")
        publishStatus(false)
        return
    end

    -- The backend re-scans custom files while honoring the community TTL.
    requestInventory(false, "custom-refreshed")
    publishStatus(false)
end

function onExit(_signal, _reason)
    nextPreviewGeneration()
    cleanupPreviewOperation(activePreviewOperation)
    inventoryRetryRequested = false
    inventoryRetryForce = false
    completedInventoryResult = nil
    pendingInventoryNonce = 0
    pendingInventoryForce = false
    activePreviewOperation = nil
    pendingPreviewRequest = nil
    previewCache = {}
    previewCacheOrder = {}
    communityInFlight = false
    ready = false
    imageRoot = ""
    configurationError = ""
    lastEvent = "stopped"
    previewStatus = {
        state = "idle",
        key = "",
        path = "",
        scheme = "",
        fingerprint = "",
        preview = nil,
        error = "",
    }
    -- Teardown must stay inside Noctalia's callback budget. Publishing the
    -- regular snapshot here would re-sign and copy every discovered palette
    -- even though the service is already stopping. Consumers only need a
    -- bounded terminal marker; startup replaces it before accepting commands.
    statusRevision = if statusRevision >= MAX_NONCE then 1 else statusRevision + 1
    noctalia.state.set(STATUS_KEY, {
        protocol = PROTOCOL,
        instance_id = INSTANCE_ID,
        revision = statusRevision,
        ready = false,
        available = false,
        image_root = "",
        configuration_error = "",
        refreshing = false,
        degraded = false,
        error = "",
        error_at = "",
        last_refresh_at = "",
        last_success_at = "",
        custom_refreshed_at = "",
        last_event = "stopped",
        last_nonce = lastCommandNonce,
        custom_directory = "",
        preview = {
            state = "idle",
            key = "",
            path = "",
            scheme = "",
            fingerprint = "",
            preview = {},
            error = "",
        },
        cache = {
            loaded = false,
            source = "none",
            fetched_at = 0,
            fetched_at_text = "",
            fresh = false,
            ttl_seconds = COMMUNITY_TTL_SECONDS,
        },
        counts = {
            wallpaper = 0,
            builtin = 0,
            community = 0,
            custom = 0,
            invalid_custom = 0,
        },
        palettes = {
            wallpaper = {},
            builtin = {},
            community = {},
            custom = {},
        },
    })
end

-- Preserve command monotonicity across a hot reload before clearing readiness.
local previousStatus = noctalia.state.get(STATUS_KEY)
if type(previousStatus) == "table" and tonumber(previousStatus.protocol) == PROTOCOL then
    local previousNonce = tonumber(previousStatus.last_nonce)
    if previousNonce ~= nil and previousNonce >= 0 and previousNonce <= MAX_NONCE then
        lastCommandNonce = math.floor(previousNonce)
    end
end
local startupImageRoot, startupImageRootError = configuredImageRoot()
noctalia.state.set(STATUS_KEY, {
    protocol = PROTOCOL,
    instance_id = INSTANCE_ID,
    revision = 0,
    ready = false,
    available = false,
    image_root = "",
    configuration_error = tostring(startupImageRootError or ""),
    last_nonce = lastCommandNonce,
    preview = {
        state = "idle",
        key = "",
        path = "",
        scheme = "",
        fingerprint = "",
        preview = {},
        error = "",
    },
})

noctalia.state.watch(COMMAND_KEY, handleCommand)
noctalia.state.watch(BACKEND_PALETTE_RESULTS_KEY, function(nextResult)
    completedInventoryResult = if type(nextResult) == "table" then nextResult else nil
end)

if startupImageRoot ~= nil then
    initializeForImageRoot(startupImageRoot)
else
    deactivateForMissingImageRoot(startupImageRootError)
end

-- Watches do not replay a command that landed during service replacement.
-- Consume it once if its nonce is newer; otherwise perform one TTL-gated
-- startup refresh. There is intentionally no periodic network poller.
handleCommand(noctalia.state.get(COMMAND_KEY))
if ready and not communityInFlight then
    requestInventory(false, "startup-refresh")
end
publishStatus(false)

--!nonstrict
-- Wall-in-One full-size hub. It controls its coordinator and renderer only
-- through versioned shared state; website links are always explicit actions.

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"
local CONFIG_STATE_KEY = "wall_in_one_config_state_v1"
local RUNTIME_STATE_KEY = "wall_in_one_runtime_state_v1"
local LIBRARY_STATE_KEY = "wall_in_one_library_state_v1"
local RENDERER_STATUS_KEY = "wall_in_one_renderer_status_v1"
local MOTIONBGS_STATUS_KEY = "wall_in_one_motionbgs_status_v1"
local MOTIONBGS_RESULTS_KEY = "wall_in_one_motionbgs_results_v1"
local PALETTES_STATUS_KEY = "wall_in_one_palettes_status_v1"
local WALLHAVEN_STATUS_KEY = "wall_in_one_wallhaven_status_v1"
local WALLHAVEN_RESULTS_KEY = "wall_in_one_wallhaven_results_v1"
local PROVIDER_RESULT_CHUNK = 12
local LIBRARY_ENTRY_CHUNK = 8
local PLAYLIST_ENTRY_CHUNK = 12
local PAIRING_CARD_CHUNK = 12
local ENTRY_SOURCE_PAGE_SIZE = 6
local STILL_CHOICE_RECONCILE_BATCH = 32
local WORKSHOP_INDEX_RECONCILE_BATCH = 32
local PALETTE_INDEX_RECONCILE_BATCH = 32
local BROWSER_GRID_COLUMNS = 4
local PLAYLIST_LIBRARY_COLUMNS = 3
local DRAG_RECONCILE_BATCH = 64
local LIBRARY_PAGE_SIZE = 24
local PLAYLIST_NAV_PAGE_SIZE = 16

local status = nil
local lifecycleStatus = nil
local configState = nil
local runtimeState = nil
local libraryState = nil
local rendererState = nil
local motionBgsState = nil
local motionBgsResultsState = nil
local palettesState = nil
local wallhavenState = nil
local wallhavenResultsState = nil
local commandSequence = 0
local motionBrowseDraft = {
    mode = "search",
    query = "",
    genre = "nature",
    page = "1",
}
local pendingDeleteItemId = ""
local pendingDeletePlaylistId = ""
local isOpen = false

-- Panel navigation is intentionally local presentation state. The coordinator
-- remains the only owner of persisted playlists and per-output schedules.
local activePage = "main"
local activeSubpage = ""
local selectedScreen = ""

-- Panel-only editing state. Persistent data always comes back through the
-- coordinator's protocol-4 state domains; these drafts never bypass it.
local selectedPlaylistId = ""
local newPlaylistNameDraft = ""
local playlistNameDraft = ""
local playlistIntervalDraft = ""
local entryLabelDraft = ""
local entryMediaKindDraft = "static"
local entryMediaSourceDraft = ""
local entryStillModeDraft = "automatic"
local entryStillPathDraft = ""
local entryThemeModeDraft = "inherit"
local entryThemeSourceDraft = "inherit"
local entryThemeSelectionDraft = ""
local entryAddedAtDraft = ""
local playlistEntryPage = 1
local providerResultPages = { wallhaven = 1, motionbgs = 1 }
local providerResultEpochs = { wallhaven = 0, motionbgs = 0 }
local libraryPageStills = 1
local libraryPageVideos = 1
local libraryPageWorkshops = 1

local pairingEditorOpen = false
local pairingEditorKind = "static"
local editingPairingId = ""
local pairingEditorRevision = 0
local pairingStillPickerPage = 1
local pairingManualStillOpen = false
local playlistEntryEditorOpen = false
local editingPlaylistEntryId = ""
local editingPlaylistEntryPairingId = ""
local editingPlaylistEntryPlaylistId = ""
local editingPlaylistEntryIndex = 0
local playlistEntrySourceKind = "static"
local playlistEntrySourcePage = 1
local pendingResetPairingId = ""
local playlistLibraryFilter = "all"
local playlistLibraryPage = 1
local playlistNavigationPage = 1
local displayPlaylistVisible = PAIRING_CARD_CHUNK
local adaptivePreviewSequence = 0
local adaptivePreviewInstance = ""
local adaptivePreviewKeys = {}
local adaptivePreviewStates = {}
local libraryPairingCache = { index = {}, instance = "", revision = -1, source = nil }

-- Declarative drag payloads and drop values are deliberately short, opaque
-- panel-session tokens. Persistent pairing, playlist, and entry identifiers
-- stay in these lookup tables instead of crossing the UI drag channel.
local dragTokenSequence = 0
local dragPairingByToken = {}
local dragPairingTokenById = {}
local dragLibraryPairingByToken = {}
local dragLibraryPairingTokenBySignature = {}
local dragPlaylistByToken = {}
local dragPlaylistTokenById = {}
local dragEntryByToken = {}
local dragEntryTokenByPlaylist = {}
local dragTargetByToken = {}
local dragTargetTokenByPlaylist = {}
local dragTokensDirty = true
local dragTokenGeneration = 0
local dragReconcile = nil

local editingScheduleId = ""
local scheduleEditorOpen = false
local scheduleNameDraft = ""
local schedulePlaylistDraft = ""
local scheduleStartDraft = "08:00"
local scheduleEndDraft = "18:00"
local scheduleEnabledDraft = true
local scheduleAllDayDraft = false
local scheduleWeekdaysDraft = { true, true, true, true, true, true, true }
local scheduleMonthsDraft = { true, true, true, true, true, true, true, true, true, true, true, true }
local scheduleDraftError = ""
local scheduleInsertBeforeDraft = ""
local screenIntervalDraft = ""
local screenOrderDraft = ""

local wallhavenSearchDraft = ""
local wallhavenCategoriesDraft = "111"
local wallhavenPurityDraft = "100"
local wallhavenSortingDraft = "date_added"
local wallhavenOrderDraft = "desc"
local wallhavenResolutionDraft = {
    mode = "atleast",
    value = "",
    top_range = "1M",
}
local wallhavenRatiosDraft = ""
local wallhavenColorDraft = ""
local wallhavenPageDraft = "1"
-- Text inputs are host-owned after creation. Bump only when code (rather than
-- typing) replaces a draft so the new value is visibly installed.
local wallhavenSearchInputRevision = 0
local wallhavenPageInputRevision = 0
local motionQueryInputRevision = 0
local motionGenreInputRevision = 0
local motionPageInputRevision = 0
local render
local closePlaylistEntryEditor
local refreshPanelState
local reloadSharedState

-- The backend setup instructions are immutable for this panel runtime. Build
-- them once: a missing backend must not add string-building work to every
-- render while Noctalia is already protecting a tight callback budget.
local BACKEND_INSTALL_REF = "4b226a8b2fa8ad41aae1245dcc8e6bfa2bf1c391"
local BACKEND_INSTALL_SHA256 = "49a5f9ef0248779492849ca6378853dbc0fba3350d4fd360ee9425fb1101703a"
local backendSetupCache = nil
local backendSetupCopyFeedback = ""

local function backendSetupShellQuote(value)
    return "'" .. tostring(value or ""):gsub("'", "'\"'\"'") .. "'"
end

local function backendSetupDetails()
    if type(backendSetupCache) == "table" then
        return backendSetupCache
    end
    local pluginDataDirectory = tostring(noctalia.pluginDataDir() or ""):gsub("/+$", "")
    local pointerPath = pluginDataDirectory .. "/backend-path"
    local rawBase = "https://raw.githubusercontent.com/Go08er/goober-noctalia-plugins-v5/"
        .. BACKEND_INSTALL_REF
        .. "/wall-in-one-backend"
    local curlProgram = "curl --disable --fail --silent --show-error --location --max-redirs 0"
        .. " --proto '=https' --proto-redir '=https' --tlsv1.2"
    local commands = table.concat({
        "installed=0; install_dir=\"$(pwd -P)\" || install_dir=; backend=\"$install_dir/wall-in-one-backend\"; pointer_dir="
            .. backendSetupShellQuote(pluginDataDirectory)
            .. "; expected="
            .. backendSetupShellQuote(BACKEND_INSTALL_SHA256)
            .. "; base="
            .. backendSetupShellQuote(rawBase)
            .. "; stage=; test -n \"$install_dir\" && stage=\"$(mktemp -d --tmpdir=\"$install_dir\" .wall-in-one-backend.XXXXXX)\"",
        "test -n \"$stage\" && "
            .. curlProgram
            .. " --max-filesize 1048576 --output \"$stage/wall-in-one-backend\" \"$base/wall-in-one-backend\" && "
            .. curlProgram
            .. " --max-filesize 4096 --output \"$stage/wall-in-one-backend.sha256\" \"$base/wall-in-one-backend.sha256\"",
        "test -n \"$stage\" && { checksum_line=\"$(<\"$stage/wall-in-one-backend.sha256\")\"; test \"$checksum_line\" = \"$expected  wall-in-one-backend\" && test \"$(wc -l < \"$stage/wall-in-one-backend.sha256\")\" = 1 && (cd \"$stage\" && sha256sum -c -- wall-in-one-backend.sha256 && : > .verified); }",
        "test -n \"$stage\" && test -f \"$stage/.verified\" && chmod 0755 -- \"$stage/wall-in-one-backend\" && mv -fT -- \"$stage/wall-in-one-backend\" \"$backend\" && rm -f -- \"$stage/wall-in-one-backend.sha256\" \"$stage/.verified\" && rmdir -- \"$stage\" && mkdir -p -- \"$pointer_dir\" && pointer_tmp=\"$(mktemp --tmpdir=\"$pointer_dir\" .backend-path.XXXXXX)\" && printf '%s\\n' \"$backend\" > \"$pointer_tmp\" && chmod 0600 -- \"$pointer_tmp\" && mv -fT -- \"$pointer_tmp\" \"$pointer_dir/backend-path\" && installed=1",
        "test \"$installed\" = 1 && ./wall-in-one-backend self-test",
    }, "\n")
    backendSetupCache = {
        commands = commands,
        pointer_path = pointerPath,
    }
    return backendSetupCache
end

local preview = {}
do
local BACKEND_STATUS_KEY = "wall_in_one_backend_status_v1"
local RPC_SCHEMA = 1
local RPC_ACTION = "preview.sync"
local RPC_PROTOCOL = "WIO-BACKEND-RPC1"
local GUARD_CONTENT = "WIO-BACKEND-GUARD1\n"
local MAX_REQUEST_BYTES = 64 * 1024
local MAX_RESPONSE_BYTES = 128 * 1024
local MAX_ITEMS = 13
local PAGE_ITEMS = 12
local RPC_TIMEOUT_MS = 55000
local ACTIVE_POLL_MS = 50
local IDLE_POLL_MS = 5000
local MAX_RETRIES = 32

local backendStatus = nil
local storageInitialized = false
local storageReady = false
local cacheDirectory = ""
local rpcDirectory = ""
local launcherPath = ""
local thumbnailHelperPath = ""
local previewPaths = {}
local previewRecords = {}
local currentPlan = nil
local pendingPlan = nil
local activeOperation = nil
local completedOperation = nil
local cancelRequested = false
local renderPending = false
local generation = 0
local operationSequence = 0
local runtimeToken = tostring(math.floor(noctalia.nowMs()))
local clockMs = 0
local retryAtMs = 0
local retryCount = 0
local pendingCount = 0
local updateInterval = 0
local lastError = ""
local scopeName = ""

local function bounded(value, maximum)
    local text = tostring(value or ""):gsub("[%c]", " ")
    text = noctalia.string.trim(text)
    return if #text > maximum then text:sub(1, maximum) else text
end

local function absolutePath(value)
    return type(value) == "string"
        and #value > 1
        and #value <= 4096
        and value:sub(1, 1) == "/"
        and value:find("[%c\\]") == nil
        and not value:find("//", 1, true)
        and not value:find("/./", 1, true)
        and not value:find("/../", 1, true)
        and not value:match("/%.$")
        and not value:match("/%.%.$")
end

local function directChild(path, directory)
    if not absolutePath(path) or not absolutePath(directory) then
        return false
    end
    directory = directory:gsub("/+$", "")
    local prefix = directory .. "/"
    if path:sub(1, #prefix) ~= prefix then
        return false
    end
    local name = path:sub(#prefix + 1)
    return name ~= "" and not name:find("/", 1, true) and name:find("[%c\\]") == nil
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function setUpdateInterval(interval)
    if updateInterval ~= interval then
        noctalia.setUpdateInterval(interval)
        updateInterval = interval
    end
end

local function wakeUpdate()
    setUpdateInterval(ACTIVE_POLL_MS)
end

local function identifier(provider, value)
    if type(value) ~= "string" then
        return nil
    end
    local candidate = value:lower()
    if provider == "wallhaven" then
        return if #candidate == 6 and candidate:match("^[a-z0-9]+$") ~= nil then candidate else nil
    elseif provider == "motionbgs" then
        return if #candidate >= 1
                and #candidate <= 120
                and candidate:match("^[a-z0-9][a-z0-9-]*$") ~= nil
            then candidate
            else nil
    end
    return nil
end

local function previewUrl(provider, value)
    if type(value) ~= "string"
        or value == ""
        or #value > 2048
        or value:find("[%c\\#]") ~= nil
        or value:find("/../", 1, true) ~= nil
        or value:match("/%.%.$") ~= nil
    then
        return nil
    end
    if provider == "wallhaven" then
        local bucket, itemId, extension = value:match(
            "^https://th%.wallhaven%.cc/lg/([a-z0-9][a-z0-9])/([a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9])%.([a-z]+)$"
        )
        if itemId ~= nil
            and bucket == itemId:sub(1, 2)
            and (extension == "jpg" or extension == "jpeg" or extension == "png" or extension == "webp")
        then
            return value
        end
        return nil
    end
    if provider == "motionbgs" then
        local mediaId, filename = value:match(
            "^https://motionbgs%.com/media/([0-9]+)/([A-Za-z0-9][A-Za-z0-9._-]*)$"
        )
        if mediaId == nil then
            local width, height
            width, height, mediaId, filename = value:match(
                "^https://motionbgs%.com/i/c/([1-9][0-9]*)x([1-9][0-9]*)/media/([0-9]+)/([A-Za-z0-9][A-Za-z0-9._-]*)$"
            )
            if width == nil or tonumber(width) > 4096 or height == nil or tonumber(height) > 4096 then
                return nil
            end
        end
        if mediaId ~= nil
            and #mediaId <= 12
            and filename ~= nil
            and #filename <= 240
            and (filename:lower():match("%.jpe?g$")
                or filename:lower():match("%.png$")
                or filename:lower():match("%.webp$"))
        then
            return value
        end
    end
    return nil
end

local function itemFields(provider, item)
    if type(item) ~= "table" then
        return nil
    end
    local rawId
    local rawUrl
    if provider == "wallhaven" then
        local thumbs = type(item.thumbs) == "table" and item.thumbs or {}
        rawId = tostring(item.id or "")
        rawUrl = tostring(thumbs.large or "")
    else
        rawId = tostring(item.slug or "")
        rawUrl = tostring(item.thumbnail_url or item.poster_url or "")
    end
    local safeId = identifier(provider, rawId)
    local safeUrl = previewUrl(provider, rawUrl)
    if safeId == nil or safeUrl == nil then
        return nil
    end
    return { provider = provider, id = safeId, url = safeUrl, key = provider .. ":" .. safeId }
end

local function selectedFields(provider, selected)
    if type(selected) ~= "table" then
        return nil
    end
    if provider == "wallhaven" then
        return itemFields(provider, selected)
    end
    local copy = {
        slug = selected.slug,
        thumbnail_url = selected.poster_url or selected.thumbnail_url,
    }
    return itemFields(provider, copy)
end

local function ownedFilename(provider, itemId, value)
    if type(value) ~= "string" or #value > 255 or value:find("[/\\%c]") ~= nil then
        return false
    end
    local fileProvider, fileId, stamp, sequence, extension = value:match(
        "^(wallhaven)%-([a-z0-9]+)%-([0-9]+)%-([0-9]+)%.([a-z]+)$"
    )
    if fileProvider == nil then
        fileProvider, fileId, stamp, sequence, extension = value:match(
            "^(motionbgs)%-([a-z0-9][a-z0-9-]*)%-([0-9]+)%-([0-9]+)%.([a-z]+)$"
        )
    end
    return fileProvider == provider
        and fileId == itemId
        and #stamp <= 20
        and #sequence <= 12
        and (extension == "jpg" or extension == "png" or extension == "webp")
end

local function backendHasCapability(candidate, name)
    local capabilities = type(candidate) == "table" and candidate.capabilities or nil
    if type(capabilities) == "table" then
        if capabilities[name] == true then
            return true
        end
        for _, capability in ipairs(capabilities) do
            if capability == name then
                return true
            end
        end
    elseif type(capabilities) == "string" then
        for capability in capabilities:gmatch("[^,]+") do
            if capability == name then
                return true
            end
        end
    end
    return false
end

local function safeBinary(candidate)
    local value = type(candidate) == "table" and tostring(candidate.binary_path or "") or ""
    if value == "wall-in-one-backend" then
        return value
    end
    return if absolutePath(value) then value else ""
end

local function backendAvailable()
    return type(backendStatus) == "table"
        and backendStatus.available == true
        and backendHasCapability(backendStatus, RPC_ACTION)
        and safeBinary(backendStatus) ~= ""
end

local function initializeStorage()
    if storageInitialized then
        return storageReady
    end
    storageInitialized = true
    local pluginDirectory = noctalia.pluginDir()
    local dataDirectory = noctalia.pluginDataDir()
    if not absolutePath(pluginDirectory) or not absolutePath(dataDirectory) then
        lastError = "Provider preview storage is unavailable"
        return false
    end
    pluginDirectory = pluginDirectory:gsub("/+$", "")
    dataDirectory = dataDirectory:gsub("/+$", "")
    launcherPath = pluginDirectory .. "/scripts/backend-provider"
    thumbnailHelperPath = pluginDirectory .. "/scripts/provider-thumbnail"
    cacheDirectory = dataDirectory .. "/provider-previews/v1"
    rpcDirectory = cacheDirectory .. "/rpc"
    if not absolutePath(launcherPath)
        or not absolutePath(thumbnailHelperPath)
        or not noctalia.fileExists(launcherPath)
        or not noctalia.fileExists(thumbnailHelperPath)
        or noctalia.mkdirAll(rpcDirectory) ~= true
    then
        lastError = "Provider preview bridge is unavailable"
        return false
    end
    storageReady = true
    return true
end

local function atomicWrite(path, content, maximum)
    if not directChild(path, rpcDirectory) or type(content) ~= "string" or #content < 1 or #content > maximum then
        return false
    end
    local temporary = path .. ".tmp"
    noctalia.removeFile(temporary)
    if noctalia.fileExists(path) or noctalia.writeFile(temporary, content) ~= true then
        noctalia.removeFile(temporary)
        return false
    end
    if noctalia.renameFile(temporary, path) ~= true then
        noctalia.removeFile(temporary)
        return false
    end
    return true
end

local function cleanupOperation(operation)
    if type(operation) ~= "table" then
        return
    end
    for _, path in ipairs({ operation.guard_path, operation.request_path, operation.response_path }) do
        if directChild(path, rpcDirectory) and noctalia.fileExists(path) then
            noctalia.removeFile(path)
        end
    end
end

local function requestRender()
    renderPending = true
    wakeUpdate()
end

local function scheduleRetry()
    if currentPlan == nil or retryCount >= MAX_RETRIES then
        retryAtMs = 0
        if pendingCount > 0 then
            lastError = "Provider preview retry limit reached"
        end
        return
    end
    retryCount += 1
    local delay = math.min(2000, 100 + (retryCount * 100))
    retryAtMs = clockMs + delay
    wakeUpdate()
end

local function responsePayload(operation, result)
    if type(result) ~= "table" or result.timedOut == true then
        return nil, "Provider preview backend timed out"
    end
    local line = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local errorWire, errorOutcome, _kind, detail = line:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t(.*)$")
    if errorWire == RPC_PROTOCOL and errorOutcome == "error" then
        return nil, bounded(detail, 400)
    elseif tonumber(result.exitCode) ~= 0 then
        local fallback = bounded(result.stderr, 400)
        return nil, if fallback ~= "" then fallback else "Provider preview backend failed"
    end
    local wire, outcome, requestId, responsePath, reportedBytes = line:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)$"
    )
    local bytes = tonumber(reportedBytes)
    if wire ~= RPC_PROTOCOL
        or outcome ~= "ok"
        or requestId ~= operation.request_id
        or responsePath ~= operation.response_path
        or bytes == nil
        or bytes < 2
        or bytes > MAX_RESPONSE_BYTES
    then
        return nil, "Provider preview backend returned an invalid completion"
    end
    local info = noctalia.fileInfo(responsePath)
    if type(info) ~= "table" or info.isDir == true or math.floor(tonumber(info.size) or 0) ~= bytes then
        return nil, "Provider preview backend response is not a bounded regular file"
    end
    local raw = noctalia.readFile(responsePath)
    if type(raw) ~= "string" or #raw ~= bytes then
        return nil, "Provider preview backend response could not be read"
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table"
        or tonumber(decoded.schema) ~= RPC_SCHEMA
        or decoded.action ~= RPC_ACTION
        or decoded.request_id ~= operation.request_id
        or decoded.ok ~= true
        or type(decoded.items) ~= "table"
        or #decoded.items ~= #operation.items
    then
        return nil, "Provider preview backend returned an invalid payload"
    end
    return decoded, nil
end

local function applyResponse(operation, payload)
    local nextPending = tonumber(payload.pending_count)
    if nextPending == nil or nextPending ~= math.floor(nextPending) or nextPending < 0 or nextPending > #operation.items then
        return false, "Provider preview backend returned an invalid pending count"
    end
    local seen = {}
    local changed = false
    local countedPending = 0
    local nextRecords = {}
    local nextPaths = {}
    -- Retry operations intentionally omit items that already failed, so one
    -- bad remote thumbnail cannot starve the rest of the visible page. Keep
    -- every validated record from this result generation while the retry
    -- response updates only the still-pending subset.
    if type(currentPlan) == "table" and currentPlan.generation == operation.generation then
        for _, planned in ipairs(currentPlan.items) do
            local previous = previewRecords[planned.key]
            if type(previous) == "table" and previous.url == planned.url then
                nextRecords[planned.key] = previous
                if previous.path ~= nil then
                    nextPaths[planned.key] = previous.path
                end
            end
        end
    end
    for _, result in ipairs(payload.items) do
        local index = tonumber(type(result) == "table" and result.index or nil)
        if index == nil or index ~= math.floor(index) or index < 1 or index > #operation.items or seen[index] then
            return false, "Provider preview backend returned an invalid item index"
        end
        seen[index] = true
        local requested = operation.items[index]
        local state = tostring(result.state or "")
        if state ~= "ready" and state ~= "pending" and state ~= "error" then
            return false, "Provider preview backend returned an invalid item state"
        end
        local path = nil
        if state == "ready" then
            local filename = tostring(result.filename or "")
            if not ownedFilename(requested.provider, requested.id, filename) then
                return false, "Provider preview backend returned an unsafe cache filename"
            end
            path = cacheDirectory .. "/" .. filename
            if not directChild(path, cacheDirectory) then
                return false, "Provider preview backend returned a cache path outside its directory"
            end
        elseif state == "pending" then
            countedPending += 1
        end
        local previous = previewRecords[requested.key]
        local errorMessage = if state == "error" then bounded(result.error, 240) else ""
        if type(previous) ~= "table"
            or previous.url ~= requested.url
            or previous.state ~= state
            or previous.path ~= path
            or previous.error ~= errorMessage
        then
            changed = true
        end
        nextRecords[requested.key] = {
            provider = requested.provider,
            id = requested.id,
            url = requested.url,
            state = state,
            path = path,
            kind = bounded(result.kind, 40),
            error = errorMessage,
        }
        if path ~= nil then
            nextPaths[requested.key] = path
        end
    end
    if countedPending ~= nextPending then
        return false, "Provider preview backend pending count did not match item states"
    end
    -- Adopt a nonce-bound response only after every ordinal has validated;
    -- a malformed tail can never leave a partially replaced visible page.
    previewRecords = nextRecords
    previewPaths = nextPaths
    pendingCount = nextPending
    return changed, nil
end

local function finishCompletion()
    local completion = completedOperation
    completedOperation = nil
    if type(completion) ~= "table" then
        return false
    end
    local operation = completion.operation
    if activeOperation == operation then
        activeOperation = nil
    end
    local stale = type(operation) ~= "table" or operation.generation ~= generation or operation.cancelled == true
    local payload
    local failure
    if not stale then
        payload, failure = responsePayload(operation, completion.result)
    end
    cleanupOperation(operation)
    if stale then
        return false
    elseif payload == nil then
        lastError = bounded(failure, 400)
        pendingCount = #operation.items
        scheduleRetry()
        return false
    end
    local changed, applyError = applyResponse(operation, payload)
    if applyError ~= nil then
        lastError = applyError
        pendingCount = #operation.items
        scheduleRetry()
        return false
    end
    lastError = ""
    if pendingCount > 0 then
        scheduleRetry()
    else
        retryAtMs = 0
        retryCount = 0
    end
    return changed
end

local function launchPlan(plan)
    if type(plan) ~= "table" or plan.generation ~= generation or #plan.items < 1 then
        return false
    end
    if not initializeStorage() or not backendAvailable() then
        return false
    end
    operationSequence += 1
    local token = runtimeToken .. "-" .. tostring(generation) .. "-" .. tostring(operationSequence)
    local operation = {
        generation = generation,
        request_id = token,
        items = plan.items,
        request_path = rpcDirectory .. "/request-" .. token .. ".json",
        response_path = rpcDirectory .. "/response-" .. token .. ".json",
        guard_path = rpcDirectory .. "/.wall-in-one-backend-guard-" .. token,
    }
    local payload = {
        schema = RPC_SCHEMA,
        action = RPC_ACTION,
        request_id = operation.request_id,
        transport_directory = rpcDirectory,
        guard_path = operation.guard_path,
        operation_timeout_ms = math.min(45000, RPC_TIMEOUT_MS - 5000),
        thumbnail_helper = thumbnailHelperPath,
        items = {},
    }
    for _, item in ipairs(operation.items) do
        table.insert(payload.items, { provider = item.provider, id = item.id, url = item.url })
    end
    local encoded = noctalia.json.encode(payload, true)
    if type(encoded) ~= "string"
        or #encoded + 1 > MAX_REQUEST_BYTES
        or not atomicWrite(operation.guard_path, GUARD_CONTENT, #GUARD_CONTENT)
        or not atomicWrite(operation.request_path, encoded .. "\n", MAX_REQUEST_BYTES)
    then
        cleanupOperation(operation)
        lastError = "Could not prepare provider preview request"
        scheduleRetry()
        return false
    end
    activeOperation = operation
    local command = "exec bash "
        .. shellQuote(launcherPath)
        .. " rpc "
        .. shellQuote(safeBinary(backendStatus))
        .. " "
        .. shellQuote(operation.request_path)
        .. " "
        .. shellQuote(operation.response_path)
        .. " "
        .. shellQuote(operation.guard_path)
    local started = noctalia.runAsync(command, function(result)
        completedOperation = { operation = operation, result = result }
        wakeUpdate()
    end, RPC_TIMEOUT_MS)
    if started ~= true then
        activeOperation = nil
        cleanupOperation(operation)
        lastError = "Noctalia refused the provider preview backend process"
        scheduleRetry()
        return false
    end
    return true
end

local function buildPlan(provider, scope, items, first, last, selected, enabled)
    generation += 1
    scopeName = tostring(scope or "")
    retryAtMs = 0
    retryCount = 0
    pendingCount = 0
    lastError = ""
    local oldRecords = previewRecords
    local oldPaths = previewPaths
    previewRecords = {}
    previewPaths = {}
    local requests = {}
    local seen = {}
    local startIndex = math.max(1, math.floor(tonumber(first) or 1))
    local endIndex = math.min(#items, math.floor(tonumber(last) or 0), startIndex + PAGE_ITEMS - 1)
    local function append(candidate)
        if type(candidate) ~= "table" or seen[candidate.key] or #requests >= MAX_ITEMS then
            return
        end
        seen[candidate.key] = true
        table.insert(requests, candidate)
        local previous = oldRecords[candidate.key]
        if type(previous) == "table" and previous.url == candidate.url and oldPaths[candidate.key] ~= nil then
            previewRecords[candidate.key] = previous
            previewPaths[candidate.key] = oldPaths[candidate.key]
        else
            previewRecords[candidate.key] = {
                provider = candidate.provider,
                id = candidate.id,
                url = candidate.url,
                state = "pending",
                path = nil,
                error = "",
            }
        end
    end
    for index = startIndex, endIndex do
        append(itemFields(provider, items[index]))
    end
    append(selectedFields(provider, selected))
    currentPlan = {
        generation = generation,
        provider = provider,
        scope = scopeName,
        source = items,
        selected = selected,
        first = startIndex,
        last = endIndex,
        enabled = enabled == true,
        items = requests,
    }
    pendingPlan = if currentPlan.enabled and #requests > 0 then currentPlan else nil
    if activeOperation ~= nil then
        activeOperation.cancelled = true
        cancelRequested = true
    end
    wakeUpdate()
end

local function plan(provider, scope, items, first, last, selected, enabled)
    local source = type(items) == "table" and items or {}
    local startIndex = math.max(1, math.floor(tonumber(first) or 1))
    local endIndex = math.min(#source, math.floor(tonumber(last) or 0), startIndex + PAGE_ITEMS - 1)
    if type(currentPlan) == "table"
        and currentPlan.provider == provider
        and currentPlan.scope == tostring(scope or "")
        and currentPlan.source == source
        and currentPlan.selected == selected
        and currentPlan.first == startIndex
        and currentPlan.last == endIndex
        and currentPlan.enabled == (enabled == true)
    then
        return
    end
    buildPlan(provider, scope, source, startIndex, endIndex, selected, enabled)
end

local function node(provider, item, width, height, _glyph)
    local rawId = if provider == "wallhaven" then item.id else item.slug
    local key = provider .. ":" .. tostring(rawId or ""):lower()
    local path = previewPaths[key]
    if path ~= nil then
        return ui.image({
            width = width,
            height = height,
            path = path,
            fit = "cover",
            radius = 8,
            border = "outline/0.35",
            borderWidth = 1,
        })
    end
    return ui.box({
        width = width,
        height = height,
        radius = 8,
        fill = "surface_variant/0.55",
        border = "outline/0.35",
        borderWidth = 1,
    })
end

local function cancel()
    generation += 1
    currentPlan = nil
    pendingPlan = nil
    retryAtMs = 0
    retryCount = 0
    pendingCount = 0
    scopeName = ""
    previewRecords = {}
    previewPaths = {}
    if activeOperation ~= nil then
        activeOperation.cancelled = true
        cancelRequested = true
        wakeUpdate()
    end
end

local function hasWork()
    return completedOperation ~= nil
        or (cancelRequested and activeOperation ~= nil)
        or (not storageInitialized and type(pendingPlan) == "table" and backendAvailable())
        or (type(pendingPlan) == "table" and storageReady and backendAvailable() and activeOperation == nil and retryAtMs == 0)
end

local function step()
    if cancelRequested and activeOperation ~= nil then
        cancelRequested = false
        if directChild(activeOperation.guard_path, rpcDirectory) then
            noctalia.removeFile(activeOperation.guard_path)
        end
        return true, false
    elseif completedOperation ~= nil then
        local changed = finishCompletion()
        return true, changed and isOpen
    elseif not storageInitialized and type(pendingPlan) == "table" and backendAvailable() then
        initializeStorage()
        return true, false
    elseif type(pendingPlan) == "table"
        and pendingPlan.generation == generation
        and retryAtMs == 0
        and activeOperation == nil
        and backendAvailable()
    then
        local nextPlan = pendingPlan
        pendingPlan = nil
        return launchPlan(nextPlan), false
    end
    return false, false
end

preview.plan = plan
preview.node = node
preview.absolutePath = absolutePath
preview.refreshClock = function()
    clockMs = math.max(0, math.floor(tonumber(noctalia.nowMs()) or 0))
end
preview.retryDue = function()
    return retryAtMs > 0 and clockMs >= retryAtMs and currentPlan ~= nil and backendAvailable()
end
preview.retry = function()
    if currentPlan ~= nil then
        retryAtMs = 0
        local items = {}
        for _, item in ipairs(currentPlan.items) do
            local record = previewRecords[item.key]
            if type(record) ~= "table" or record.state == "pending" then
                table.insert(items, item)
            end
        end
        if #items > 0 then
            pendingPlan = { generation = currentPlan.generation, items = items }
            wakeUpdate()
        else
            pendingCount = 0
        end
    end
end
preview.step = step
preview.hasBoundedWork = hasWork
preview.wake = function()
    wakeUpdate()
end
preview.requestRender = requestRender
preview.takeRender = function()
    if not renderPending then
        return false
    end
    renderPending = false
    return true
end
preview.settle = function(otherBoundedWork)
    panel.setNeedsFrameTick(otherBoundedWork == true)
    if otherBoundedWork == true or renderPending or hasWork() then
        wakeUpdate()
    elseif retryAtMs > 0 then
        setUpdateInterval(math.min(IDLE_POLL_MS, math.max(ACTIVE_POLL_MS, retryAtMs - clockMs)))
    else
        setUpdateInterval(IDLE_POLL_MS)
    end
end
preview.debugSnapshot = function(key)
    local entries = 0
    local paths = 0
    for _ in pairs(previewRecords) do entries += 1 end
    for _ in pairs(previewPaths) do paths += 1 end
    local record = previewRecords[tostring(key or "")]
    return {
        initialized = storageInitialized,
        ready = storageReady and backendAvailable(),
        initialization_phase = if storageInitialized then "nil" else "storage",
        initialization_requested = not storageInitialized and currentPlan ~= nil,
        queue_depth = if pendingPlan ~= nil then 1 else 0,
        active = if activeOperation ~= nil then 1 else 0,
        manifest_dirty = false,
        render_pending = renderPending,
        is_open = isOpen,
        active_page = activePage,
        active_subpage = activeSubpage,
        entries = entries,
        paths = paths,
        key_last_used = nil,
        clock = math.floor(clockMs / 1000),
        update_interval = updateInterval,
        scope = scopeName,
        sweep_index = 0,
        sweep_limit = if type(currentPlan) == "table" then #currentPlan.items else 0,
        pending_count = pendingCount,
        retry_count = retryCount,
        backend_available = backendAvailable(),
        last_error = lastError,
        record_state = if type(record) == "table" then record.state else "",
        drag_tokens_dirty = dragTokensDirty,
    }
end
preview.initializeScheduler = function()
    panel.setWantsSecondTicks(true)
    setUpdateInterval(IDLE_POLL_MS)
end
preview.setBackendStatus = function(nextStatus)
    local wasAvailable = backendAvailable()
    local previousBinary = safeBinary(backendStatus)
    backendStatus = nextStatus
    local available = backendAvailable()
    local changed = wasAvailable ~= available or previousBinary ~= safeBinary(backendStatus)
    if changed and activeOperation ~= nil then
        activeOperation.cancelled = true
        cancelRequested = true
    end
    if available and type(currentPlan) == "table" and currentPlan.enabled and #currentPlan.items > 0 then
        pendingPlan = currentPlan
        retryAtMs = 0
    end
    if changed then
        wakeUpdate()
    end
    return changed
end
preview.backendAvailable = backendAvailable
preview.backendSnapshot = function()
    return backendStatus
end
preview.backendStatusKey = BACKEND_STATUS_KEY
preview.cancel = cancel
preview.close = function()
    cancel()
    if activeOperation == nil then
        setUpdateInterval(IDLE_POLL_MS)
    end
end
end

local function resetLibraryVisibility()
    libraryPageStills = 1
    libraryPageVideos = 1
    libraryPageWorkshops = 1
end

local function resetPanelVisibility()
    playlistEntryPage = 1
    providerResultPages.wallhaven = 1
    providerResultPages.motionbgs = 1
    resetLibraryVisibility()
    playlistLibraryPage = 1
    playlistNavigationPage = 1
    displayPlaylistVisible = PAIRING_CARD_CHUNK
end

-- Wallhaven accepts this documented, closed color set. Keeping the picker
-- constrained prevents avoidable request errors from free-form hex values.
local WALLHAVEN_COLOR_VALUES = {
    "660000",
    "990000",
    "cc0000",
    "cc3333",
    "ea4c88",
    "993399",
    "663399",
    "333399",
    "0066cc",
    "0099cc",
    "66cccc",
    "77cc33",
    "669900",
    "336600",
    "666600",
    "999900",
    "cccc33",
    "ffff00",
    "ffcc33",
    "ff9900",
    "ff6600",
    "cc6633",
    "996633",
    "663300",
    "000000",
    "999999",
    "cccccc",
    "ffffff",
    "424153",
}

local ACTIONS = {
    { id = "native_next", label = "actions.native_next" },
    { id = "native_previous", label = "actions.native_previous" },
    { id = "native_random", label = "actions.native_random" },
    { id = "wallhaven_site", label = "actions.wallhaven_site" },
    { id = "motionbgs_open", label = "actions.motionbgs_open" },
    { id = "capture_backing", label = "actions.capture_backing" },
    { id = "capture_current", label = "actions.capture_current" },
    { id = "capture_pair", label = "actions.capture_pair" },
    { id = "video_capture", label = "actions.video_capture" },
    { id = "video_capture_pair", label = "actions.video_capture_pair" },
    { id = "video_apply_pair", label = "actions.video_apply_pair" },
    { id = "workshop_apply_pair", label = "actions.workshop_apply_pair" },
    { id = "cycle_start", label = "actions.cycle_start" },
    { id = "cycle_stop", label = "actions.cycle_stop" },
    { id = "cycle_pause", label = "actions.cycle_pause" },
    { id = "cycle_resume", label = "actions.cycle_resume" },
    { id = "cycle_next", label = "actions.cycle_next" },
    { id = "cycle_previous", label = "actions.cycle_previous" },
    { id = "cycle_random", label = "actions.cycle_random" },
    { id = "cycle_add_static", label = "actions.cycle_add_static" },
    { id = "cycle_add_video", label = "actions.cycle_add_video" },
    { id = "cycle_add_workshop", label = "actions.cycle_add_workshop" },
    { id = "cycle_remove_last", label = "actions.cycle_remove_last" },
    { id = "cycle_clear", label = "actions.cycle_clear" },
    { id = "manual_pair", label = "actions.manual_pair" },
    { id = "playback_pause", label = "actions.playback_pause" },
    { id = "playback_resume", label = "actions.playback_resume" },
    { id = "playback_toggle", label = "actions.playback_toggle" },
    { id = "playback_stop", label = "actions.playback_stop" },
    { id = "playback_stop_all", label = "actions.playback_stop_all" },
    { id = "audio_mute", label = "actions.audio_mute" },
    { id = "audio_unmute", label = "actions.audio_unmute" },
    { id = "audio_toggle", label = "actions.audio_toggle" },
    { id = "audio_volume_down", label = "actions.audio_volume_down" },
    { id = "audio_volume_up", label = "actions.audio_volume_up" },
    { id = "steam_launch", label = "actions.steam_launch" },
    { id = "steam_workshop", label = "actions.steam_workshop" },
    { id = "no_action", label = "actions.no_action" },
}

local GENERIC_RENDERER_CAPABILITIES = {
    playback_pause = "pause",
    playback_resume = "resume",
    playback_toggle = "toggle",
    playback_stop = "stop",
    audio_mute = "mute",
    audio_unmute = "unmute",
    audio_toggle = "toggle_mute",
    audio_volume_down = "set_volume",
    audio_volume_up = "set_volume",
}

local function matchingDomain(candidate)
    if type(candidate) ~= "table" or tonumber(candidate.protocol) ~= 1 then
        return nil
    end
    if type(lifecycleStatus) ~= "table" or tonumber(lifecycleStatus.protocol) ~= 4 then
        return nil
    end
    if tostring(candidate.instance_id or "") ~= tostring(lifecycleStatus.instance_id or "") then
        return nil
    end
    return candidate
end

local function composeStatus()
    if type(lifecycleStatus) ~= "table" then
        return nil
    end
    -- A rolling reload can briefly leave the panel paired with the protocol-3
    -- coordinator. Preserve its complete snapshot until protocol 4 arrives.
    if tonumber(lifecycleStatus.protocol) ~= 4 then
        return lifecycleStatus
    end

    local view = {}
    for key, value in pairs(lifecycleStatus) do
        view[key] = value
    end

    local configDomain = matchingDomain(configState)
    if type(configDomain) == "table" then
        if type(configDomain.config) == "table" then
            view.config = configDomain.config
        end
        if type(configDomain.settings) == "table" then
            view.settings = configDomain.settings
        end
    end

    local runtimeDomain = matchingDomain(runtimeState)
    local runtime = type(runtimeDomain) == "table" and type(runtimeDomain.runtime) == "table"
            and runtimeDomain.runtime
        or {}
    view.colors = type(runtime.colors) == "table" and runtime.colors or {}
    view.pairs = type(runtime.pairs) == "table" and runtime.pairs or {}
    view.runs = type(runtime.runs) == "table" and runtime.runs or {}
    view.output_states = type(runtime.output_states) == "table" and runtime.output_states or {}
    view.palette = type(runtime.palette) == "table" and runtime.palette or {}
    view.current_workshops = type(runtime.current_workshops) == "table" and runtime.current_workshops or {}
    view.last_capture = type(runtime.last_capture) == "table" and runtime.last_capture or {}

    local libraryDomain = matchingDomain(libraryState)
    view.library = type(libraryDomain) == "table" and type(libraryDomain.library) == "table"
            and libraryDomain.library
        or {}
    view.renderer = type(rendererState) == "table" and rendererState or { ready = false, outputs = {} }
    view.motionbgs = {
        status = type(motionBgsState) == "table" and motionBgsState or {},
        results = type(motionBgsResultsState) == "table"
                and motionBgsResultsState
            or { items = {}, selected = {} },
    }
    view.palettes = type(palettesState) == "table" and palettesState or {}
    view.wallhaven = {
        status = type(wallhavenState) == "table" and wallhavenState or {},
        results = type(wallhavenResultsState) == "table"
                and wallhavenResultsState
            or { items = {}, selected = {}, meta = {} },
    }
    return view
end

local function focusedOutput()
    local output = noctalia.focusedOutputName()
    return if type(output) == "string" then output else ""
end

local function providers()
    if type(status) == "table" and type(status.providers) == "table" then
        return status.providers
    end
    return {
        probing = true,
        probe_ok = false,
        noctalia_cli = false,
        native = { available = true },
        wallhaven = { allowed = true, available = false, site_available = false },
        w_engine = {
            allowed = true,
            renderer_available = false,
            available = false,
            apply_available = false,
            internal_current = {},
            steam_available = false,
            steam_workshop_available = false,
        },
        mpvpaper = { allowed = true, command_available = false, available = false, apply_available = false },
        motionbgs = {
            allowed = true,
            available = false,
            browser_available = false,
            integration_available = false,
            url = "https://motionbgs.com/",
        },
    }
end

local function entryForOutput(entry, output)
    local copied = {}
    if type(entry) == "table" then
        for key, value in pairs(entry) do
            copied[key] = value
        end
    end

    local allPairs = type(status) == "table" and type(status.pairs) == "table" and status.pairs or {}
    local pair = if output ~= "" and type(allPairs[output]) == "table" then allPairs[output] else allPairs.all
    local stillPath = if type(pair) == "table" and type(pair.still_path) == "string" then pair.still_path else ""
    local kind = tostring(copied.kind or "")
    local source = tostring(copied.source or "")
    local expectedDynamicId = if kind == "video" then "video:" .. source elseif kind == "workshop" then source else ""
    local pairMatches = expectedDynamicId ~= ""
        and type(pair) == "table"
        and tostring(pair.dynamic_id or "") == expectedDynamicId
    if
        pairMatches
        and stillPath:sub(1, 1) == "/"
        and stillPath:find("[%c]") == nil
        and noctalia.fileExists(stillPath)
    then
        copied.still_path = stillPath
    end
    return copied
end

local function settings()
    if type(status) == "table" and type(status.settings) == "table" then
        return status.settings
    end
    return {
        use_wallhaven = true,
        use_motionbgs = true,
        capture_directory = "",
        video_directory = "",
        auto_capture = true,
        sync_colors = true,
        color_scheme = "",
        palette_output = "",
        video_source = "",
        manual_pair_file = "",
        workshop_id = "",
        video_frame_second = 1,
        cycle_interval_minutes = 15,
        cycle_order = "sequential",
    }
end

local function motionBgsData()
    local value = type(status) == "table" and type(status.motionbgs) == "table" and status.motionbgs or {}
    return type(value.status) == "table" and value.status or {},
        type(value.results) == "table" and value.results or { items = {}, selected = {} }
end

local function wallhavenData()
    local value = type(status) == "table" and type(status.wallhaven) == "table" and status.wallhaven or {}
    return type(value.status) == "table" and value.status or {},
        type(value.results) == "table" and value.results or { items = {}, selected = {}, meta = {} }
end

local function storageValid()
    return type(status) == "table" and status.storage_valid == true
end

local function configSnapshot()
    return type(status) == "table" and type(status.config) == "table" and status.config or {}
end

local function playlistMap()
    local value = configSnapshot().playlists
    return type(value) == "table" and value or {}
end

local function pairingMap()
    local value = configSnapshot().pairings
    return type(value) == "table" and value or {}
end

local function outputConfig(output)
    local outputs = configSnapshot().outputs
    local value = type(outputs) == "table" and outputs[output] or nil
    return type(value) == "table" and value or { fallback_playlist = "", schedules = {} }
end

local function outputRuntime(output)
    local states = type(status) == "table" and type(status.output_states) == "table" and status.output_states or {}
    local value = states[output]
    return type(value) == "table"
            and value
        or { active_playlist = "", active_schedule = "", manual_pin = false, last_transition_at = "" }
end

local function runState(output, playlistId)
    local runs = type(status) == "table" and type(status.runs) == "table" and status.runs or {}
    local outputRuns = type(runs[output]) == "table" and runs[output] or {}
    local value = outputRuns[playlistId]
    return type(value) == "table"
            and value
        or {
            running = false,
            paused = false,
            parked = false,
            current_entry = "",
            next_due = 0,
            history = {},
            bag = {},
            last_error = "",
        }
end

local playlistIdSortCache = {}

local function sortedPlaylistIds(includeQuickChoice)
    local playlists = playlistMap()
    local cacheKey = if includeQuickChoice == true then "all" else "normal"
    local cached = playlistIdSortCache[cacheKey]
    if type(cached) == "table" and cached.source == playlists then
        return cached.ids
    end
    local ids = {}
    for id, playlist in pairs(playlists) do
        if type(playlist) == "table" and (includeQuickChoice == true or playlist.quick_choice ~= true) then
            table.insert(ids, tostring(id))
        end
    end
    table.sort(ids, function(left, right)
        local leftName = string.lower(tostring(type(playlists[left]) == "table" and playlists[left].name or left))
        local rightName = string.lower(tostring(type(playlists[right]) == "table" and playlists[right].name or right))
        if leftName == rightName then
            return left < right
        end
        return leftName < rightName
    end)
    playlistIdSortCache[cacheKey] = { source = playlists, ids = ids }
    return ids
end

local function resolveSelectedPlaylist(outputOverride)
    local playlists = playlistMap()
    if type(playlists[selectedPlaylistId]) == "table" and playlists[selectedPlaylistId].quick_choice ~= true then
        return selectedPlaylistId, playlists[selectedPlaylistId]
    end
    local output = tostring(outputOverride or "")
    if output == "" then
        output = focusedOutput()
    end
    local state = outputRuntime(output)
    local configured = outputConfig(output)
    local candidates = {
        tostring(state.active_playlist or ""),
        tostring(configured.fallback_playlist or ""),
    }
    for _, id in ipairs(candidates) do
        if id ~= "" and type(playlists[id]) == "table" and playlists[id].quick_choice ~= true then
            selectedPlaylistId = id
            return id, playlists[id]
        end
    end
    local ids = sortedPlaylistIds(false)
    selectedPlaylistId = ids[1] or ""
    return selectedPlaylistId, playlists[selectedPlaylistId]
end

local function playlistOptions(selectedId)
    local ids = sortedPlaylistIds(false)
    local labels = {}
    local selectedIndex = 0
    for index, id in ipairs(ids) do
        local playlist = playlistMap()[id]
        table.insert(labels, tostring(playlist.name or id))
        if id == selectedId then
            selectedIndex = index - 1
        end
    end
    return labels, ids, selectedIndex
end

local function paletteInventory()
    local root = type(status) == "table" and type(status.palettes) == "table" and status.palettes or {}
    local values = type(root.palettes) == "table" and root.palettes or {}
    return root, values
end

local PALETTE_INDEX_SOURCES = { "wallpaper", "builtin", "community", "custom" }
local paletteEntryIndexes = {}

local function paletteEntryIndex(source)
    source = tostring(source or "")
    local _root, inventory = paletteInventory()
    local values = type(inventory[source]) == "table" and inventory[source] or {}
    local cached = paletteEntryIndexes[source]
    if type(cached) ~= "table" then
        cached = { names = {}, nameIndex = {}, byName = {} }
    end
    if cached.source ~= values then
        cached = {
            source = values,
            sourceItems = values,
            names = cached.names,
            nameIndex = cached.nameIndex,
            byName = cached.byName,
            nextNames = {},
            nextNameIndex = {},
            nextByName = {},
            cursor = 1,
            ready = false,
        }
        paletteEntryIndexes[source] = cached
        wakeUpdate()
    end
    return cached
end

local function paletteNames(source)
    local cached = paletteEntryIndex(source)
    return cached.names, cached.ready == true, cached.nameIndex
end

local function paletteInventoryEntry(source, selection)
    return paletteEntryIndex(source).byName[tostring(selection or "")]
end

local function paletteEntryIndexWork()
    for _, source in ipairs(PALETTE_INDEX_SOURCES) do
        local cached = paletteEntryIndexes[source]
        if type(cached) == "table" and cached.ready ~= true then
            return true
        end
    end
    return false
end

local function stepPaletteEntryIndexReconciliation()
    for _, source in ipairs(PALETTE_INDEX_SOURCES) do
        local cached = paletteEntryIndexes[source]
        if type(cached) == "table" and cached.ready ~= true then
            local sourceItems = cached.sourceItems
            local first = cached.cursor
            local last = math.min(#sourceItems, first + PALETTE_INDEX_RECONCILE_BATCH - 1)
            for index = first, last do
                local entry = sourceItems[index]
                local name = if type(entry) == "table" then tostring(entry.name or "") else tostring(entry or "")
                if name ~= "" and cached.nextNameIndex[name] == nil then
                    table.insert(cached.nextNames, name)
                    cached.nextNameIndex[name] = #cached.nextNames
                    if type(entry) == "table" then
                        cached.nextByName[name] = entry
                    end
                end
            end
            cached.cursor = last + 1
            if cached.cursor > #sourceItems then
                cached.names = cached.nextNames
                cached.nameIndex = cached.nextNameIndex
                cached.byName = cached.nextByName
                cached.nextNames = {}
                cached.nextNameIndex = {}
                cached.nextByName = {}
                cached.sourceItems = {}
                cached.ready = true
                if source == entryThemeSourceDraft and entryThemeSelectionDraft == "" then
                    entryThemeSelectionDraft = cached.names[1] or ""
                end
                return true
            end
            return false
        end
    end
    return false
end

local function basename(path)
    local value = tostring(path or "")
    return value:match("([^/]+)$") or value
end

local function resetEntryDraft()
    entryLabelDraft = ""
    entryMediaKindDraft = "static"
    entryMediaSourceDraft = ""
    entryStillModeDraft = "automatic"
    entryStillPathDraft = ""
    entryThemeModeDraft = "auto"
    entryThemeSourceDraft = "wallpaper"
    entryThemeSelectionDraft = paletteNames("wallpaper")[1] or "m3-tonal-spot"
    entryAddedAtDraft = ""
end

local function loadBundleDraft(entry, defaultKind)
    resetEntryDraft()
    entryMediaKindDraft = tostring(defaultKind or "static")
    if type(entry) == "table" then
        entryLabelDraft = tostring(entry.label or "")
        local media = type(entry.media) == "table" and entry.media or nil
        local still = type(entry.still) == "table" and entry.still or {}
        local theme = type(entry.theme) == "table" and entry.theme or {}
        entryMediaKindDraft = if media == nil then "static" else tostring(media.kind or "video")
        entryMediaSourceDraft = if media == nil then tostring(still.path or "") else tostring(media.source or "")
        entryStillModeDraft = tostring(still.mode or (media == nil and "selected" or "automatic"))
        entryStillPathDraft = tostring(still.path or "")
        entryThemeModeDraft = tostring(theme.mode or "inherit")
        entryThemeSourceDraft = tostring(theme.source or "inherit")
        entryThemeSelectionDraft = tostring(theme.selection or "")
        entryAddedAtDraft = tostring(entry.added_at or "")
    end
end

local function bundleFromDraft(id)
    local source = noctalia.string.trim(entryMediaSourceDraft)
    local dynamic = entryMediaKindDraft == "video" or entryMediaKindDraft == "workshop"
    local themeMode = tostring(entryThemeModeDraft or "inherit")
    local themeSource = tostring(entryThemeSourceDraft or "inherit")
    if themeMode == "inherit" or themeSource == "inherit" then
        themeMode = "inherit"
        themeSource = "inherit"
    end
    local label = noctalia.string.trim(entryLabelDraft)
    if label == "" then
        label = basename(source)
    end
    return {
        id = tostring(id or ""),
        label = label,
        media = if dynamic then { kind = entryMediaKindDraft, source = source } else nil,
        still = if dynamic and entryStillModeDraft == "automatic"
            then { mode = "automatic" }
            else { mode = "selected", path = if dynamic then noctalia.string.trim(entryStillPathDraft) else source },
        theme = {
            mode = themeMode,
            source = themeSource,
            selection = if themeSource == "inherit" then "" else noctalia.string.trim(entryThemeSelectionDraft),
        },
        added_at = if entryAddedAtDraft ~= ""
            then entryAddedAtDraft
            else noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
    }
end

local function formatMinute(value)
    local minute = math.max(0, math.min(1439, math.floor(tonumber(value) or 0)))
    return string.format("%02d:%02d", math.floor(minute / 60), minute % 60)
end

local function parseMinute(value)
    local hour, minute = tostring(value or ""):match("^(%d%d?):(%d%d)$")
    hour = tonumber(hour)
    minute = tonumber(minute)
    if hour == nil or minute == nil or hour < 0 or hour > 23 or minute < 0 or minute > 59 then
        return nil
    end
    return hour * 60 + minute
end

local function resetScheduleDraft(playlistId)
    editingScheduleId = ""
    scheduleNameDraft = ""
    schedulePlaylistDraft = tostring(playlistId or "")
    scheduleStartDraft = "08:00"
    scheduleEndDraft = "18:00"
    scheduleEnabledDraft = true
    scheduleAllDayDraft = false
    scheduleWeekdaysDraft = { true, true, true, true, true, true, true }
    scheduleMonthsDraft = { true, true, true, true, true, true, true, true, true, true, true, true }
    scheduleDraftError = ""
    scheduleInsertBeforeDraft = ""
end

local function editScheduleDraft(schedule, defaultPlaylistId)
    scheduleEditorOpen = true
    if type(schedule) ~= "table" then
        resetScheduleDraft(if tostring(defaultPlaylistId or "") ~= "" then defaultPlaylistId else selectedPlaylistId)
        return
    end
    editingScheduleId = tostring(schedule.id or "")
    scheduleInsertBeforeDraft = ""
    scheduleNameDraft = tostring(schedule.name or "")
    schedulePlaylistDraft = tostring(schedule.playlist or selectedPlaylistId)
    scheduleStartDraft = formatMinute(schedule.start_minute)
    scheduleEndDraft = formatMinute(schedule.end_minute)
    scheduleEnabledDraft = schedule.enabled ~= false
    scheduleAllDayDraft = schedule.all_day == true
    scheduleDraftError = ""
    scheduleWeekdaysDraft = { false, false, false, false, false, false, false }
    for _, value in ipairs(type(schedule.weekdays) == "table" and schedule.weekdays or {}) do
        local day = math.floor(tonumber(value) or -1)
        if day >= 0 and day <= 6 then
            scheduleWeekdaysDraft[day + 1] = true
        end
    end
    scheduleMonthsDraft = { false, false, false, false, false, false, false, false, false, false, false, false }
    local months = type(schedule.months) == "table" and schedule.months or {}
    if #months == 0 then
        -- A missing filter is the schema-3 representation of every month.
        scheduleMonthsDraft = { true, true, true, true, true, true, true, true, true, true, true, true }
    else
        for _, value in ipairs(months) do
            local month = math.floor(tonumber(value) or -1)
            if month >= 1 and month <= 12 then
                scheduleMonthsDraft[month] = true
            end
        end
    end
end

local function rendererOutputs()
    if
        type(status) == "table"
        and type(status.renderer) == "table"
        and type(status.renderer.outputs) == "table"
    then
        return status.renderer.outputs
    end
    return {}
end

local function activeRenderer(requestedOutput)
    local output = tostring(requestedOutput or "")
    if output == "" then
        output = focusedOutput()
    end
    local outputs = rendererOutputs()
    local owned = if output ~= "" and type(outputs[output]) == "table" then outputs[output] else nil
    return owned, output
end

local function genericRendererActionAvailable(action, requestedOutput)
    if action == "playback_stop_all" then
        for _, owned in pairs(rendererOutputs()) do
            local capabilities = type(owned) == "table" and owned.capabilities or nil
            if type(capabilities) == "table" and capabilities.stop == true then
                return true
            end
        end
        return false
    end

    local capability = GENERIC_RENDERER_CAPABILITIES[action]
    local owned = activeRenderer(requestedOutput)
    local capabilities = type(owned) == "table" and owned.capabilities or nil
    if capability == nil or type(capabilities) ~= "table" or capabilities[capability] ~= true then
        return false
    end
    if action == "playback_pause" then
        return tostring(owned.state or "") ~= "paused"
    elseif action == "playback_resume" then
        return tostring(owned.state or "") == "paused"
    elseif action == "audio_mute" then
        return owned.muted ~= true
    elseif action == "audio_unmute" then
        return owned.muted == true
    end
    return true
end

local function nextSequence()
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    return commandSequence
end

local function send(request)
    request.sequence = nextSequence()
    request.producer = "hub-panel"
    noctalia.state.set(COMMAND_KEY, request)
end

local function nextDragToken(prefix)
    dragTokenSequence = dragTokenSequence + 1
    return prefix .. tostring(dragTokenSequence)
end

local function resetLibraryDragTokens()
    dragLibraryPairingByToken = {}
    dragLibraryPairingTokenBySignature = {}
end

-- A persisted configuration can hold thousands of playlist rows. Rebuild the
-- opaque drag-token index incrementally and swap it only after a complete
-- generation; neither a state callback nor one update tick walks the entire
-- project, and an interrupted tick leaves the previous valid index intact.
local function markDragTokensDirty()
    dragTokenGeneration += 1
    dragTokensDirty = true
    dragReconcile = nil
    resetLibraryDragTokens()
    if isOpen then
        preview.wake()
    end
end

local function stepDragTokenReconciliation()
    if not dragTokensDirty then
        return true
    end
    if dragReconcile == nil then
        local configuredOutputs = configSnapshot().outputs
        local configurationState = type(configState) == "table" and configState or {}
        local outputs = {}
        for rawOutput, configuredOutput in pairs(type(configuredOutputs) == "table" and configuredOutputs or {}) do
            outputs[tostring(rawOutput)] = configuredOutput
        end
        for _, descriptor in ipairs(noctalia.outputs()) do
            local output = type(descriptor) == "table" and tostring(descriptor.name or descriptor.connector or "") or ""
            if output ~= "" and outputs[output] == nil then
                outputs[output] = { schedules = {} }
            end
        end
        dragReconcile = {
            generation = dragTokenGeneration,
            phase = "pairings",
            cursor = nil,
            pairings = pairingMap(),
            playlists = playlistMap(),
            outputs = outputs,
            pairing_by_token = {},
            pairing_token_by_id = {},
            playlist_by_token = {},
            playlist_token_by_id = {},
            entry_by_token = {},
            entry_token_by_playlist = {},
            target_by_token = {},
            target_token_by_playlist = {},
            library_pairing_index = {},
            config_instance = tostring(configurationState.instance_id or ""),
            config_revision = math.floor(tonumber(configurationState.revision) or -1),
        }
    end

    local state = dragReconcile
    for _ = 1, DRAG_RECONCILE_BATCH do
        if state.generation ~= dragTokenGeneration then
            dragReconcile = nil
            return false
        end

        if state.phase == "pairings" then
            local rawId, pairing = next(state.pairings, state.cursor)
            state.cursor = rawId
            if rawId == nil then
                state.phase = "playlists"
                state.cursor = nil
            elseif type(pairing) == "table" then
                local id = tostring(rawId)
                local token = dragPairingTokenById[id] or nextDragToken("p")
                state.pairing_by_token[token] = id
                state.pairing_token_by_id[id] = token
                local media = type(pairing.media) == "table" and pairing.media or nil
                local still = type(pairing.still) == "table" and pairing.still or {}
                local kind = if media == nil then "static" else tostring(media.kind or "")
                local source = if media == nil then tostring(still.path or "") else tostring(media.source or "")
                if (kind == "static" or kind == "video" or kind == "workshop") and source ~= "" then
                    local key = kind .. "\0" .. source
                    local existing = state.library_pairing_index[key]
                    local replace = type(existing) ~= "table"
                        or (pairing.customized == true and existing.customized ~= true)
                        or ((pairing.customized == true) == (existing.customized == true)
                            and tostring(pairing.id or "") < tostring(existing.id or ""))
                    if replace then
                        state.library_pairing_index[key] = pairing
                    end
                end
            end
        elseif state.phase == "playlists" then
            local rawId, playlist = next(state.playlists, state.cursor)
            state.cursor = rawId
            if rawId == nil then
                state.phase = "entries"
                state.cursor = nil
            elseif type(playlist) == "table" and playlist.quick_choice ~= true then
                local id = tostring(rawId)
                local token = dragPlaylistTokenById[id] or nextDragToken("r")
                state.playlist_by_token[token] = id
                state.playlist_token_by_id[id] = token
            end
        elseif state.phase == "entries" then
            if state.active_id == nil then
                local rawId, playlist = next(state.playlists, state.cursor)
                state.cursor = rawId
                if rawId == nil then
                    state.phase = "schedules"
                    state.cursor = nil
                    continue
                elseif type(playlist) ~= "table" then
                    continue
                end
                local playlistId = tostring(rawId)
                state.active_id = playlistId
                state.active_entries = type(playlist.entries) == "table" and playlist.entries or {}
                state.active_index = 1
                state.active_previous_id = ""
                state.active_entry_tokens = {}
                state.active_target_tokens = {}
                state.previous_entry_tokens = type(dragEntryTokenByPlaylist[playlistId]) == "table"
                        and dragEntryTokenByPlaylist[playlistId]
                    or {}
                state.previous_target_tokens = type(dragTargetTokenByPlaylist[playlistId]) == "table"
                        and dragTargetTokenByPlaylist[playlistId]
                    or {}
            end

            local entry = state.active_entries[state.active_index]
            if entry ~= nil then
                state.active_index += 1
                local entryId = type(entry) == "table" and tostring(entry.id or "") or ""
                if entryId ~= "" and state.active_entry_tokens[entryId] == nil then
                    local entryToken = state.previous_entry_tokens[entryId] or nextDragToken("e")
                    state.active_entry_tokens[entryId] = entryToken
                    state.entry_by_token[entryToken] = {
                        playlist_id = state.active_id,
                        entry_id = entryId,
                    }
                    local targetToken = state.previous_target_tokens[entryId] or nextDragToken("d")
                    state.active_target_tokens[entryId] = targetToken
                    state.target_by_token[targetToken] = {
                        playlist_id = state.active_id,
                        pairing_before_id = entryId,
                        entry_anchor_id = if state.active_previous_id == "" then entryId else state.active_previous_id,
                        entry_placement = if state.active_previous_id == "" then "before" else "after",
                    }
                    state.active_previous_id = entryId
                end
            else
                local endToken = state.previous_target_tokens[""] or nextDragToken("d")
                state.active_target_tokens[""] = endToken
                state.target_by_token[endToken] = {
                    playlist_id = state.active_id,
                    pairing_before_id = "",
                    entry_anchor_id = "",
                    entry_placement = "end",
                }
                state.entry_token_by_playlist[state.active_id] = state.active_entry_tokens
                state.target_token_by_playlist[state.active_id] = state.active_target_tokens
                state.active_id = nil
            end
        elseif state.phase == "schedules" then
            if state.active_output == nil then
                local rawOutput, configuredOutput = next(state.outputs, state.cursor)
                state.cursor = rawOutput
                if rawOutput == nil then
                    state.phase = "commit"
                    continue
                end
                local output = tostring(rawOutput)
                local namespace = "@schedule:" .. output
                state.active_output = output
                state.active_id = namespace
                state.active_entries = type(configuredOutput) == "table"
                        and type(configuredOutput.schedules) == "table"
                        and configuredOutput.schedules
                    or {}
                state.active_index = 1
                state.active_previous_id = ""
                state.active_entry_tokens = {}
                state.active_target_tokens = {}
                state.previous_entry_tokens = type(dragEntryTokenByPlaylist[namespace]) == "table"
                        and dragEntryTokenByPlaylist[namespace]
                    or {}
                state.previous_target_tokens = type(dragTargetTokenByPlaylist[namespace]) == "table"
                        and dragTargetTokenByPlaylist[namespace]
                    or {}
            end

            local schedule = state.active_entries[state.active_index]
            if schedule ~= nil then
                state.active_index += 1
                local scheduleId = type(schedule) == "table" and tostring(schedule.id or "") or ""
                if scheduleId ~= "" and state.active_entry_tokens[scheduleId] == nil then
                    local entryToken = state.previous_entry_tokens[scheduleId] or nextDragToken("s")
                    state.active_entry_tokens[scheduleId] = entryToken
                    state.entry_by_token[entryToken] = {
                        schedule_output = state.active_output,
                        schedule_id = scheduleId,
                    }
                    local targetToken = state.previous_target_tokens[scheduleId] or nextDragToken("q")
                    state.active_target_tokens[scheduleId] = targetToken
                    state.target_by_token[targetToken] = {
                        schedule_output = state.active_output,
                        schedule_anchor_id = if state.active_previous_id == "" then scheduleId else state.active_previous_id,
                        schedule_placement = if state.active_previous_id == "" then "before" else "after",
                        schedule_before_id = scheduleId,
                    }
                    state.active_previous_id = scheduleId
                end
            else
                local endToken = state.previous_target_tokens[""] or nextDragToken("q")
                state.active_target_tokens[""] = endToken
                state.target_by_token[endToken] = {
                    schedule_output = state.active_output,
                    schedule_anchor_id = "",
                    schedule_placement = "end",
                    schedule_before_id = "",
                }
                local defaultToken = state.previous_target_tokens["@default"] or nextDragToken("f")
                state.active_target_tokens["@default"] = defaultToken
                state.target_by_token[defaultToken] = {
                    display_output = state.active_output,
                    display_role = "default",
                }
                state.entry_token_by_playlist[state.active_id] = state.active_entry_tokens
                state.target_token_by_playlist[state.active_id] = state.active_target_tokens
                state.active_output = nil
                state.active_id = nil
            end
        elseif state.phase == "commit" then
            dragPairingByToken = state.pairing_by_token
            dragPairingTokenById = state.pairing_token_by_id
            dragPlaylistByToken = state.playlist_by_token
            dragPlaylistTokenById = state.playlist_token_by_id
            dragEntryByToken = state.entry_by_token
            dragEntryTokenByPlaylist = state.entry_token_by_playlist
            dragTargetByToken = state.target_by_token
            dragTargetTokenByPlaylist = state.target_token_by_playlist
            libraryPairingCache.index = state.library_pairing_index
            libraryPairingCache.instance = state.config_instance
            libraryPairingCache.revision = state.config_revision
            libraryPairingCache.source = state.pairings
            dragTokensDirty = false
            dragReconcile = nil
            return true
        end
    end
    return false
end

-- Every insertion zone shares one callback. It validates the panel-local
-- tokens against the latest coordinator snapshot and emits exactly one
-- command; the coordinator remains the sole owner of playlist mutations.
function onPlaylistDrop(payload, value)
    local payloadToken = tostring(payload or "")
    local target = dragTargetByToken[tostring(value or "")]
    if type(target) ~= "table" or not storageValid() then
        return
    end

    local output = if selectedScreen ~= "" then selectedScreen else focusedOutput()
    local playlistId, playlist = resolveSelectedPlaylist(output)
    if playlistId == "" or target.playlist_id ~= playlistId or type(playlist) ~= "table" then
        return
    end

    local pairingId = dragPairingByToken[payloadToken]
    if pairingId == nil then
        pairingId = dragLibraryPairingByToken[payloadToken]
    end
    if type(pairingId) == "table" and type(pairingId.library_bundle) == "table" then
        if tostring(pairingId.pairing_id or "") ~= "" then
            send({
                kind = "playlist_add_pairing",
                output = output,
                playlist_id = playlistId,
                pairing_id = tostring(pairingId.pairing_id),
                before_id = if target.pairing_before_id ~= "" then target.pairing_before_id else nil,
            })
        else
            send({
                kind = "playlist_add_entry",
                output = output,
                playlist_id = playlistId,
                entry = entryForOutput(pairingId.library_bundle, output),
                before_id = if target.pairing_before_id ~= "" then target.pairing_before_id else nil,
            })
        end
        return
    end
    if pairingId ~= nil and type(pairingMap()[pairingId]) == "table" then
        send({
            kind = "playlist_add_pairing",
            output = output,
            playlist_id = playlistId,
            pairing_id = pairingId,
            before_id = if target.pairing_before_id ~= "" then target.pairing_before_id else nil,
        })
        return
    end

    local source = dragEntryByToken[payloadToken]
    if type(source) ~= "table" or source.playlist_id ~= playlistId then
        return
    end
    send({
        kind = "playlist_place_entry",
        playlist_id = playlistId,
        entry_id = source.entry_id,
        anchor_id = target.entry_anchor_id,
        placement = target.entry_placement,
    })
end

function onScheduleDrop(payload, value)
    local source = dragEntryByToken[tostring(payload or "")]
    local target = dragTargetByToken[tostring(value or "")]
    if
        type(source) ~= "table"
        or type(target) ~= "table"
        or tostring(source.schedule_output or "") == ""
        or source.schedule_output ~= target.schedule_output
        or source.schedule_output ~= selectedScreen
        or not storageValid()
    then
        return
    end
    send({
        kind = "schedule_place",
        output = source.schedule_output,
        schedule_id = tostring(source.schedule_id or ""),
        anchor_id = tostring(target.schedule_anchor_id or ""),
        placement = tostring(target.schedule_placement or "end"),
    })
end

function onDisplayPlaylistDrop(payload, value)
    local payloadToken = tostring(payload or "")
    local target = dragTargetByToken[tostring(value or "")]
    local playlistId = dragPlaylistByToken[payloadToken]
    if type(target) ~= "table" or not storageValid() then
        return
    end
    if playlistId == nil then
        onScheduleDrop(payload, value)
        return
    end
    if type(playlistMap()[playlistId]) ~= "table" then
        return
    end
    if target.display_role == "default" and target.display_output == selectedScreen then
        selectedPlaylistId = playlistId
        send({ kind = "playlist_assign", output = selectedScreen, playlist_id = playlistId })
        return
    end
    if tostring(target.schedule_output or "") ~= selectedScreen then
        return
    end
    resetScheduleDraft(playlistId)
    scheduleNameDraft = tostring(playlistMap()[playlistId].name or playlistId)
    scheduleInsertBeforeDraft = tostring(target.schedule_before_id or "")
    scheduleEditorOpen = true
    render()
end

local function adaptivePreviewSession()
    local root = paletteInventory()
    local instance = tostring(root.instance_id or "")
    if instance ~= "" and instance ~= adaptivePreviewInstance then
        adaptivePreviewInstance = instance
        adaptivePreviewKeys = {}
        adaptivePreviewStates = {}
    end
end

local function automaticRepresentativePath(kind, source)
    local root = type(status) == "table" and type(status.library) == "table" and status.library or {}
    local published = type(root.representative_stills) == "table" and root.representative_stills or nil
    if published == nil then
        -- The current coordinator always publishes this fixed lookup. During
        -- a one-snapshot upgrade gap, let the bounded preparation request hit
        -- the coordinator cache instead of scanning 1,024 rows in a click.
        return ""
    end
    local values = if kind == "video" then published.video elseif kind == "workshop" then published.workshop else nil
    local path = tostring(type(values) == "table" and values[source] or "")
    local info = preview.absolutePath(path) and noctalia.fileInfo(path) or nil
    if type(info) == "table" and info.isDir ~= true and (tonumber(info.size) or 0) > 0 then
        return path
    end
    return ""
end

local function adaptivePreviewDescriptor(bundle, pairingId)
    local theme = type(bundle) == "table" and type(bundle.theme) == "table" and bundle.theme or {}
    local scheme = tostring(theme.selection or "")
    if tostring(theme.source or "") ~= "wallpaper" or scheme == "" then
        return nil
    end
    local still = type(bundle.still) == "table" and bundle.still or {}
    local path = if tostring(still.mode or "") == "selected" then tostring(still.path or "") else ""
    if path ~= "" then
        local info = path:sub(1, 1) == "/" and path:find("[%c]") == nil and noctalia.fileInfo(path) or nil
        if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) < 1 then
            return nil
        end
        local signature = table.concat({
            "path",
            tostring(#path),
            path,
            tostring(math.floor(tonumber(info.size) or 0)),
            tostring(math.floor(tonumber(info.mtime) or 0)),
            scheme,
        }, "|")
        return {
            signature = signature,
            path = path,
            pairing_id = "",
            scheme = scheme,
        }
    end
    local media = type(bundle.media) == "table" and bundle.media or nil
    if tostring(still.mode or "") == "automatic" and media ~= nil then
        local mediaKind = tostring(media.kind or "")
        local mediaSource = tostring(media.source or "")
        if (mediaKind ~= "video" and mediaKind ~= "workshop") or mediaSource == "" then
            return nil
        end
        return {
            signature = table.concat({
                "automatic",
                mediaKind,
                tostring(#mediaSource),
                mediaSource,
                scheme,
            }, "|"),
            path = automaticRepresentativePath(mediaKind, mediaSource),
            pairing_id = tostring(pairingId or ""),
            scheme = scheme,
            media_kind = mediaKind,
            media_source = mediaSource,
        }
    end
    return nil
end

local function requestPairingAdaptivePreview(bundle, pairingId)
    if pairingEditorOpen ~= true and playlistEntryEditorOpen ~= true then
        return false
    end
    adaptivePreviewSession()
    local descriptor = adaptivePreviewDescriptor(bundle, pairingId)
    if descriptor == nil or adaptivePreviewKeys[descriptor.signature] ~= nil then
        return false
    end
    adaptivePreviewSequence = if adaptivePreviewSequence >= 2147483646 then 1 else adaptivePreviewSequence + 1
    local key = "panel-pairing-preview-" .. tostring(adaptivePreviewSequence)
    adaptivePreviewKeys[descriptor.signature] = key
    adaptivePreviewStates[descriptor.signature] = { state = "loading", error = "" }
    local request = {
        kind = "palette_preview",
        key = key,
        scheme = descriptor.scheme,
    }
    if descriptor.path ~= "" then
        request.path = descriptor.path
    elseif descriptor.media_kind ~= nil then
        request.kind = "pairing_prepare_still"
        request.media_kind = descriptor.media_kind
        request.media_source = descriptor.media_source
        request.output = if selectedScreen ~= "" then selectedScreen else focusedOutput()
    elseif descriptor.pairing_id ~= "" then
        request.pairing_id = descriptor.pairing_id
    end
    send(request)
    return true
end

local function requestAutomaticStillPreparation(kind, source)
    if
        (pairingEditorOpen ~= true and playlistEntryEditorOpen ~= true)
        or entryStillModeDraft ~= "automatic"
        or (kind ~= "video" and kind ~= "workshop")
        or source == ""
        or automaticRepresentativePath(kind, source) ~= ""
    then
        return false
    end
    local signature = "prepare\0" .. kind .. "\0" .. source
    if adaptivePreviewKeys[signature] ~= nil then
        return false
    end
    adaptivePreviewSequence = if adaptivePreviewSequence >= 2147483646 then 1 else adaptivePreviewSequence + 1
    local key = "panel-pairing-still-" .. tostring(adaptivePreviewSequence)
    adaptivePreviewKeys[signature] = key
    send({
        kind = "pairing_prepare_still",
        key = key,
        media_kind = kind,
        media_source = source,
        output = if selectedScreen ~= "" then selectedScreen else focusedOutput(),
        capture_only = true,
    })
    return true
end

local function clearAutomaticStillPreparation(kind, source)
    adaptivePreviewKeys[
        "prepare\0" .. tostring(kind or "") .. "\0" .. noctalia.string.trim(tostring(source or ""))
    ] = nil
end

local function retryPairingAdaptivePreview(bundle, pairingId)
    if pairingEditorOpen ~= true and playlistEntryEditorOpen ~= true then
        return false
    end
    adaptivePreviewSession()
    local descriptor = adaptivePreviewDescriptor(bundle, pairingId)
    if descriptor == nil then
        return false
    end
    adaptivePreviewKeys[descriptor.signature] = nil
    adaptivePreviewStates[descriptor.signature] = nil
    return requestPairingAdaptivePreview(bundle, pairingId)
end

local function adaptivePreviewForBundle(bundle, pairingId)
    adaptivePreviewSession()
    local descriptor = adaptivePreviewDescriptor(bundle, pairingId)
    if descriptor == nil then
        return nil, "unavailable", ""
    end
    local key = adaptivePreviewKeys[descriptor.signature]
    local root = paletteInventory()
    local current = type(root.preview) == "table" and root.preview or {}
    if key ~= nil and tostring(current.key or "") == key then
        local state = tostring(current.state or "unavailable")
        local snapshot = {
            state = state,
            preview = if type(current.preview) == "table" then current.preview else nil,
            error = tostring(current.error or ""),
        }
        adaptivePreviewStates[descriptor.signature] = snapshot
    end
    local cached = adaptivePreviewStates[descriptor.signature]
    if type(cached) == "table" then
        return cached.preview, tostring(cached.state or "unavailable"), tostring(cached.error or "")
    end
    return nil, "unavailable", ""
end

local function beginPairingEditor(kind, pairing)
    if closePlaylistEntryEditor ~= nil then
        closePlaylistEntryEditor()
    end
    kind = if kind == "video" or kind == "workshop" then kind else "static"
    pairingEditorRevision += 1
    pairingEditorKind = kind
    pairingEditorOpen = true
    editingPairingId = if type(pairing) == "table" then tostring(pairing.id or "") else ""
    pendingResetPairingId = ""
    pairingStillPickerPage = 1
    pairingManualStillOpen = false
    loadBundleDraft(pairing, kind)
    entryMediaKindDraft = kind
    if kind == "static" then
        entryStillModeDraft = "selected"
    end
    preview.cancel()
    activePage = "library"
    activeSubpage = if kind == "video" then "videos" elseif kind == "workshop" then "workshops" else "images"
    clearAutomaticStillPreparation(kind, entryMediaSourceDraft)
    local requestedPalette = requestPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)
    if not requestedPalette then
        requestAutomaticStillPreparation(kind, noctalia.string.trim(entryMediaSourceDraft))
    end
    render()
end

local function closePairingEditor()
    local hadEditorState = pairingEditorOpen == true or editingPairingId ~= ""
    pairingEditorOpen = false
    editingPairingId = ""
    pendingResetPairingId = ""
    pairingStillPickerPage = 1
    pairingManualStillOpen = false
    if hadEditorState then
        resetEntryDraft()
    end
end

local function beginPlaylistEntryEditor(entry, playlistId, entryIndex)
    closePairingEditor()
    local media = type(entry) == "table" and type(entry.media) == "table" and entry.media or nil
    local kind = if media == nil then "static" else tostring(media.kind or "video")
    kind = if kind == "video" or kind == "workshop" then kind else "static"
    pairingEditorRevision += 1
    playlistEntryEditorOpen = true
    editingPlaylistEntryId = tostring(type(entry) == "table" and entry.id or "")
    editingPlaylistEntryPairingId = tostring(type(entry) == "table" and entry.pairing_id or "")
    editingPlaylistEntryPlaylistId = tostring(playlistId or "")
    editingPlaylistEntryIndex = math.max(0, math.floor(tonumber(entryIndex) or 0))
    playlistEntrySourceKind = kind
    playlistEntrySourcePage = 1
    pairingStillPickerPage = 1
    pairingManualStillOpen = false
    loadBundleDraft(entry, kind)
    entryMediaKindDraft = kind
    if kind == "static" then
        entryStillModeDraft = "selected"
    end
    clearAutomaticStillPreparation(kind, entryMediaSourceDraft)
    local requestedPalette = requestPairingAdaptivePreview(
        bundleFromDraft(editingPlaylistEntryId),
        editingPlaylistEntryPairingId
    )
    if not requestedPalette then
        requestAutomaticStillPreparation(kind, noctalia.string.trim(entryMediaSourceDraft))
    end
    render()
end

closePlaylistEntryEditor = function()
    local hadEditorState = playlistEntryEditorOpen == true or editingPlaylistEntryId ~= ""
    playlistEntryEditorOpen = false
    editingPlaylistEntryId = ""
    editingPlaylistEntryPairingId = ""
    editingPlaylistEntryPlaylistId = ""
    editingPlaylistEntryIndex = 0
    playlistEntrySourceKind = "static"
    playlistEntrySourcePage = 1
    pairingStillPickerPage = 1
    pairingManualStillOpen = false
    if hadEditorState then
        resetEntryDraft()
    end
end

local function preferredPairingForLibraryEntry(existing, candidate)
    if type(candidate) ~= "table" then
        return existing
    end
    if type(existing) ~= "table" then
        return candidate
    end
    local existingCustomized = existing.customized == true
    local candidateCustomized = candidate.customized == true
    if existingCustomized ~= candidateCustomized then
        return if candidateCustomized then candidate else existing
    end
    return if tostring(candidate.id or "") < tostring(existing.id or "") then candidate else existing
end

local function libraryPairingKey(kind, source)
    kind = tostring(kind or "")
    source = tostring(source or "")
    if (kind ~= "static" and kind ~= "video" and kind ~= "workshop") or source == "" then
        return nil
    end
    return kind .. "\0" .. source
end

local function indexedLibraryPairings()
    local pairings = pairingMap()
    local state = type(configState) == "table" and configState or {}
    local instance = tostring(state.instance_id or "")
    local revision = tonumber(state.revision)
    local versioned = instance ~= "" and revision ~= nil
    local unchanged = if versioned
        then instance == libraryPairingCache.instance
            and revision == libraryPairingCache.revision
            and pairings == libraryPairingCache.source
        else pairings == libraryPairingCache.source
    if unchanged then
        return libraryPairingCache.index
    end

    -- Configuration reconciliation already builds this index incrementally on
    -- frame ticks. Keep serving the last complete snapshot until that atomic
    -- replacement commits instead of walking every pairing during a render.
    if not dragTokensDirty then
        markDragTokensDirty()
    end
    return libraryPairingCache.index
end

local function matchingPairingForLibraryEntry(entry)
    local kind = tostring(type(entry) == "table" and entry.kind or "")
    local source = tostring(type(entry) == "table" and entry.source or "")
    local key = libraryPairingKey(kind, source)
    return if key ~= nil then indexedLibraryPairings()[key] else nil
end

local panelUi = {}

panelUi.workshopIndexCache = {
    source = nil,
    sourceItems = {},
    index = {},
    nextIndex = {},
    cursor = 1,
    ready = true,
}

function panelUi.workshopIndex()
    local currentLibrary = type(status) == "table" and type(status.library) == "table" and status.library or {}
    local workshops = type(currentLibrary.workshops) == "table" and currentLibrary.workshops or {}
    local cached = panelUi.workshopIndexCache
    if cached.source ~= workshops then
        cached = {
            source = workshops,
            sourceItems = workshops,
            index = cached.index,
            nextIndex = {},
            cursor = 1,
            ready = false,
        }
        panelUi.workshopIndexCache = cached
        wakeUpdate()
    end
    return cached.index
end

function panelUi.workshopIndexWork()
    return panelUi.workshopIndexCache.ready ~= true
end

function panelUi.stepWorkshopIndexReconciliation()
    local cached = panelUi.workshopIndexCache
    if cached.ready == true then
        return false
    end
    local sourceItems = cached.sourceItems
    local first = cached.cursor
    local last = math.min(#sourceItems, first + WORKSHOP_INDEX_RECONCILE_BATCH - 1)
    for index = first, last do
        local workshop = sourceItems[index]
        if type(workshop) == "table" then
            local id = tostring(workshop.id or "")
            if id ~= "" then
                cached.nextIndex[id] = workshop
            end
        end
    end
    cached.cursor = last + 1
    if cached.cursor > #sourceItems then
        cached.index = cached.nextIndex
        cached.nextIndex = {}
        cached.sourceItems = {}
        cached.ready = true
        return true
    end
    return false
end

local function openLibraryEntryPairing(entry, libraryItem)
    local kind = tostring(type(entry) == "table" and entry.kind or "")
    kind = if kind == "video" or kind == "workshop" then kind else "static"
    local existing = matchingPairingForLibraryEntry(entry)
    if type(existing) == "table" and existing.customized == true then
        beginPairingEditor(kind, existing)
        return
    end
    local defaults = panelUi.virtualLibraryPairing(entry, libraryItem, nil)
    defaults.id = type(existing) == "table" and tostring(existing.id or "") or ""
    beginPairingEditor(kind, defaults)
end

local function actionLabel(action)
    for _, entry in ipairs(ACTIONS) do
        if entry.id == action then
            return noctalia.tr(entry.label)
        end
    end
    return tostring(action or "?")
end

local function actionAvailable(action, requestedOutput)
    if action == "motionbgs_open" then
        local current = providers()
        return type(current.motionbgs) == "table" and current.motionbgs.browser_available == true
    end
    if not storageValid() then
        return false
    end
    local current = providers()
    local wEngine = type(current.w_engine) == "table" and current.w_engine or {}
    local mpvpaper = type(current.mpvpaper) == "table" and current.mpvpaper or {}
    local output = tostring(requestedOutput or "")
    if output == "" then
        output = focusedOutput()
    end
    if action == "no_action" then
        return true
    elseif action == "native_next" or action == "native_previous" or action == "native_random" then
        return current.noctalia_cli == true
    elseif action == "wallhaven_site" then
        return type(current.wallhaven) == "table" and current.wallhaven.site_available == true
    elseif GENERIC_RENDERER_CAPABILITIES[action] ~= nil or action == "playback_stop_all" then
        return genericRendererActionAvailable(action, output)
    elseif action == "steam_launch" then
        return wEngine.steam_available == true
    elseif action == "steam_workshop" then
        return wEngine.steam_workshop_available == true
    elseif action == "capture_backing" then
        return current.noctalia_cli == true and output ~= ""
    elseif action == "capture_current" or action == "capture_pair" then
        local internalId = type(current.w_engine) == "table"
                and type(current.w_engine.internal_current) == "table"
                and output ~= ""
                and tostring(current.w_engine.internal_current[output] or "")
            or ""
        return wEngine.allowed == true
            and (
                internalId:match("^%d+$") ~= nil
                or tostring(settings().workshop_id or ""):match("^%d+$") ~= nil
            )
    elseif action == "video_capture" or action == "video_capture_pair" then
        return tostring(settings().video_source or "") ~= ""
    elseif action == "video_apply_pair" then
        return mpvpaper.apply_available == true and tostring(settings().video_source or "") ~= ""
    elseif action == "workshop_apply_pair" then
        return wEngine.apply_available == true and tostring(settings().workshop_id or ""):match("^%d+$") ~= nil
    elseif action == "cycle_add_static" then
        return current.noctalia_cli == true and output ~= ""
    elseif action == "cycle_add_video" then
        return tostring(settings().video_source or "") ~= ""
    elseif action == "cycle_add_workshop" then
        return tostring(settings().workshop_id or ""):match("^%d+$") ~= nil
    elseif
        action == "cycle_start"
        or action == "cycle_stop"
        or action == "cycle_pause"
        or action == "cycle_resume"
        or action == "cycle_next"
        or action == "cycle_previous"
        or action == "cycle_random"
        or action == "cycle_remove_last"
        or action == "cycle_clear"
    then
        local playlistId, playlist = resolveSelectedPlaylist()
        local entries = type(playlist) == "table" and type(playlist.entries) == "table" and playlist.entries or {}
        if action == "cycle_next" or action == "cycle_previous" or action == "cycle_random" then
            local state = runState(output, playlistId)
            if state.paused == true then
                return false
            end
        end
        return #entries > 0
    elseif action == "manual_pair" then
        return output ~= "" and tostring(settings().manual_pair_file or "") ~= ""
    end
    return false
end

local function runAction(action, requestedOutput)
    local output = tostring(requestedOutput or "")
    if output == "" then
        output = focusedOutput()
    end
    send({ kind = "action", action = action, output = output })
end

-- Shared presentation helpers.
function panelUi.boolText(value)
    return if value == true then noctalia.tr("common.on") else noctalia.tr("common.off")
end

function panelUi.yesNoText(value)
    return if value == true then noctalia.tr("common.yes") else noctalia.tr("common.no")
end

function panelUi.valueOr(value, fallbackKey)
    local text = tostring(value or "")
    return if text == "" then noctalia.tr(fallbackKey) else text
end

function panelUi.providerItems(value, page, pageSize)
    local source = type(value) == "table" and value or {}
    local total = math.min(#source, 48)
    local size = math.max(1, math.floor(tonumber(pageSize) or PROVIDER_RESULT_CHUNK))
    local pages = math.max(1, math.ceil(total / size))
    local current = math.min(pages, math.max(1, math.floor(tonumber(page) or 1)))
    local first = (current - 1) * size + 1
    local last = math.min(total, first + size - 1)
    local items = {}
    for index = first, last do
        if type(source[index]) == "table" then
            table.insert(items, source[index])
        end
    end
    return items, total, current, first, last
end

panelUi.providerInstallCache = {
    source = nil,
    wallhaven = {},
    motionbgs = {},
}

function panelUi.providerInstallIndex()
    local currentLibrary = type(status) == "table" and type(status.library) == "table" and status.library or {}
    local cached = panelUi.providerInstallCache
    if cached.source == currentLibrary then
        return cached
    end

    local nextIndex = {
        source = currentLibrary,
        wallhaven = {},
        motionbgs = {},
    }
    local published = type(currentLibrary.provider_installs) == "table" and currentLibrary.provider_installs or nil
    if published ~= nil then
        nextIndex.wallhaven = type(published.wallhaven) == "table" and published.wallhaven or {}
        nextIndex.motionbgs = type(published.motionbgs) == "table" and published.motionbgs or {}
    end
    panelUi.providerInstallCache = nextIndex
    return nextIndex
end

panelUi.motionQueueCache = { source = nil, index = {}, count = 0 }

function panelUi.motionQueueIndex(providerStatus)
    local queued = type(providerStatus) == "table" and providerStatus.queued_downloads or nil
    local cached = panelUi.motionQueueCache
    if cached.source == queued then
        return cached.index, cached.count
    end
    local index = {}
    local count = 0
    for _, entry in ipairs(type(queued) == "table" and queued or {}) do
        if type(entry) == "table" then
            local slug = tostring(entry.slug or ""):lower()
            local quality = tostring(entry.quality or ""):lower()
            if slug ~= "" and (quality == "hd" or quality == "4k") then
                local key = slug .. ":" .. quality
                if index[key] ~= true then
                    index[key] = true
                    count += 1
                end
            end
        end
    end
    panelUi.motionQueueCache = { source = queued, index = index, count = count }
    return index, count
end

function panelUi.downloadLabel(state, quality)
    quality = tostring(quality or ""):upper()
    if quality == "" then
        if state == "installed" then
            return noctalia.tr("panel.downloads.installed_plain")
        elseif state == "active" then
            return noctalia.tr("panel.downloads.downloading_plain")
        end
        return noctalia.tr("panel.wallhaven.download")
    end
    if state == "installed" then
        return noctalia.tr("panel.downloads.installed", { quality = quality })
    elseif state == "active" then
        return noctalia.tr("panel.downloads.downloading", { quality = quality })
    elseif state == "queued" then
        return noctalia.tr("panel.downloads.queued", { quality = quality })
    end
    return noctalia.tr("panel.downloads.download", { quality = quality })
end

function panelUi.configuredRoot(key)
    local path = tostring(settings()[key] or "")
    if path == "" or path:sub(1, 1) ~= "/" or path:find("[%c]") ~= nil then
        return "", false
    end
    local info = noctalia.fileInfo(path)
    return path, type(info) == "table" and info.isDir == true
end

function panelUi.locationReady(kind)
    local key = if kind == "video" then "video_directory" else "capture_directory"
    local path, ready = panelUi.configuredRoot(key)
    return ready, path
end

function panelUi.setupReady()
    local imageReady = panelUi.locationReady("image")
    local videoReady = panelUi.locationReady("video")
    return imageReady and videoReady
end

function panelUi.paletteResolutionText(value)
    local resolution = tostring(value or "")
    if resolution == "requested" then
        return noctalia.tr("diagnostics.palette_resolution.requested")
    elseif resolution == "assumed" then
        return noctalia.tr("diagnostics.palette_resolution.assumed")
    elseif resolution == "pending" then
        return noctalia.tr("diagnostics.palette_resolution.pending")
    elseif resolution == "degraded" then
        return noctalia.tr("diagnostics.palette_resolution.degraded")
    end
    return noctalia.tr("common.unknown")
end

function panelUi.sectionHeader(glyph, title, body)
    return ui.column({ gap = 3, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = glyph, color = "primary" }),
            ui.label({ text = title, fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
        }),
        ui.label({ text = body, fontSize = 11, color = "on_surface_variant", maxLines = 5 }),
    })
end

function panelUi.card(children)
    return ui.column({
        gap = 8,
        padding = 12,
        radius = 12,
        fill = "surface/0.8",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

function panelUi.backendSetupPointerPath()
    return backendSetupDetails().pointer_path
end

function panelUi.backendSetupCommands()
    return backendSetupDetails().commands
end

function panelUi.backendSetupCard()
    local commands = panelUi.backendSetupCommands()
    local pointerPath = panelUi.backendSetupPointerPath()
    local children = {
        panelUi.sectionHeader(
            "terminal-2",
            noctalia.tr("panel.backend_setup.title"),
            noctalia.tr("panel.backend_setup.description")
        ),
        ui.label({
            text = noctalia.tr("panel.backend_setup.pointer_label"),
            fontSize = 9,
            fontWeight = "bold",
        }),
        -- Noctalia v5 does not expose a read-only selectable-text node. A
        -- controlled input keeps the exact path selectable without accepting
        -- edits into plugin state.
        ui.input({
            key = "backend-setup-pointer",
            value = pointerPath,
            onChange = function(_value) end,
        }),
        ui.label({
            text = noctalia.tr("panel.backend_setup.command_label"),
            fontSize = 9,
            fontWeight = "bold",
        }),
        ui.input({
            key = "backend-setup-commands",
            value = commands,
            multiline = true,
            height = 210,
            onChange = function(_value) end,
        }),
        ui.row({ gap = 8, align = "center" }, {
            ui.button({
                text = noctalia.tr("panel.backend_setup.copy"),
                glyph = "copy",
                variant = "primary",
                controlSize = "sm",
                onClick = function()
                    backendSetupCopyFeedback = if noctalia.copyToClipboard(commands, "text/plain;charset=utf-8")
                        then noctalia.tr("panel.backend_setup.copied")
                        else noctalia.tr("panel.backend_setup.copy_failed")
                    render()
                end,
            }),
            ui.label({
                text = if backendSetupCopyFeedback ~= ""
                    then backendSetupCopyFeedback
                    else noctalia.tr("panel.backend_setup.waiting"),
                fontSize = 9,
                color = "on_surface_variant",
                flexGrow = 1,
                maxLines = 2,
            }),
        }),
    }
    return panelUi.card(children)
end

function panelUi.pathRow(glyph, label, path, ready)
    return ui.row({ gap = 8, align = "center", padding = 8, radius = 9, fill = "surface_variant/0.24", flexGrow = 1 }, {
        ui.glyph({ name = glyph, color = if ready then "primary" else "error" }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = label, fontSize = 10, fontWeight = "bold", maxLines = 1 }),
            ui.label({
                text = panelUi.valueOr(path, "common.unset"),
                fontSize = 8,
                color = "on_surface_variant",
                maxLines = 2,
            }),
        }),
        ui.glyph({ name = if ready then "check" else "alert-triangle", color = if ready then "primary" else "error" }),
    })
end

function panelUi.appendVisibilityControls(children, total, visible, chunkSize, setVisible)
    local itemCount = math.max(0, math.floor(tonumber(total) or 0))
    local chunk = math.max(1, math.floor(tonumber(chunkSize) or 1))
    local visibleCount = math.max(chunk, math.floor(tonumber(visible) or chunk))
    if itemCount > visibleCount then
        local revealCount = math.min(chunk, itemCount - visibleCount)
        table.insert(
            children,
            ui.button({
                text = noctalia.tr("panel.browse.show_more", { count = tostring(revealCount) }),
                glyph = "chevron-down",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    setVisible(math.min(itemCount, visibleCount + chunk))
                    render()
                end,
            })
        )
    elseif visibleCount > chunk and itemCount > chunk then
        table.insert(
            children,
            ui.button({
                text = noctalia.tr("panel.browse.show_fewer"),
                glyph = "chevron-up",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    setVisible(chunk)
                    render()
                end,
            })
        )
    end
end

function panelUi.appendPageControls(children, total, page, pageSize, setPage)
    local count = math.max(0, math.floor(tonumber(total) or 0))
    local size = math.max(1, math.floor(tonumber(pageSize) or 1))
    local pages = math.max(1, math.ceil(count / size))
    local current = math.min(pages, math.max(1, math.floor(tonumber(page) or 1)))
    if pages <= 1 then
        return current
    end
    table.insert(children, ui.row({ gap = 5, align = "center" }, {
        ui.button({
            text = noctalia.tr("panel.browse.previous"),
            glyph = "chevron-left",
            variant = "ghost",
            controlSize = "sm",
            enabled = current > 1,
            onClick = function()
                setPage(math.max(1, current - 1))
                render()
            end,
        }),
        ui.label({
            text = noctalia.tr("panel.browse.page", { page = tostring(current), pages = tostring(pages) }),
            fontSize = 9,
            color = "on_surface_variant",
            align = "center",
            flexGrow = 1,
            maxLines = 1,
        }),
        ui.button({
            text = noctalia.tr("panel.browse.next"),
            glyph = "chevron-right",
            variant = "ghost",
            controlSize = "sm",
            enabled = current < pages,
            onClick = function()
                setPage(math.min(pages, current + 1))
                render()
            end,
        }),
    }))
    return current
end

function panelUi.appendExplicitGrid(children, items, visible, columns, cardBuilder)
    local limit = math.min(#items, math.max(0, math.floor(tonumber(visible) or 0)))
    local columnCount = math.max(1, math.floor(tonumber(columns) or 1))
    local index = 1
    while index <= limit do
        local cards = {}
        for offset = 0, columnCount - 1 do
            local itemIndex = index + offset
            if itemIndex <= limit then
                table.insert(cards, cardBuilder(items[itemIndex], itemIndex))
            end
        end
        table.insert(children, ui.row({ gap = 8, align = "stretch", justify = "start" }, cards))
        index += columnCount
    end
end

function panelUi.actionButton(action, glyph, variant, grow)
    return ui.button({
        text = actionLabel(action),
        glyph = glyph,
        variant = variant or "ghost",
        controlSize = "sm",
        enabled = actionAvailable(action),
        flexGrow = grow == true and 1 or 0,
        onClick = function()
            runAction(action)
        end,
    })
end

function panelUi.iconActionButton(action, glyph, output, variant)
    return ui.button({
        glyph = glyph,
        tooltip = actionLabel(action),
        variant = variant or "ghost",
        controlSize = "sm",
        enabled = actionAvailable(action, output),
        onClick = function()
            runAction(action, output)
        end,
    })
end

function panelUi.compactRendererControls(output)
    local owned = activeRenderer(output)
    local backend = if type(owned) == "table" then tostring(owned.backend or "") else ""
    local state = if type(owned) == "table" then tostring(owned.state or "") else ""
    local muted = type(owned) == "table" and owned.muted == true
    local volume = if type(owned) == "table" and tonumber(owned.volume) ~= nil
        then tostring(math.floor(tonumber(owned.volume) or 0)) .. "%"
        else noctalia.tr("common.unknown")
    local statusText = if type(owned) == "table"
        then noctalia.tr("panel.renderer.status", {
            backend = panelUi.valueOr(backend, "common.unknown"),
            state = panelUi.valueOr(state, "common.unknown"),
        })
        else noctalia.tr("panel.renderer.inactive")

    return ui.column({ gap = 6, align = "stretch" }, {
        ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "player-play", color = if type(owned) == "table" then "primary" else "on_surface_variant" }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = noctalia.tr("panel.renderer.title"), fontSize = 11, fontWeight = "bold" }),
                ui.label({ text = statusText, fontSize = 9, color = "on_surface_variant", maxLines = 2 }),
            }),
            ui.label({
                text = tostring(output or ""),
                fontSize = 9,
                color = "primary",
                maxLines = 1,
            }),
        }),
        ui.row({ gap = 4, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.renderer.playback"),
                width = 58,
                fontSize = 8,
                color = "on_surface_variant",
                maxLines = 1,
            }),
            panelUi.iconActionButton("playback_pause", "player-pause", output),
            panelUi.iconActionButton("playback_resume", "player-play", output),
            panelUi.iconActionButton("playback_toggle", "player-track-next", output),
            panelUi.iconActionButton("playback_stop", "player-stop", output),
        }),
        ui.row({ gap = 4, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.renderer.audio"),
                width = 58,
                fontSize = 8,
                color = "on_surface_variant",
                maxLines = 1,
            }),
            panelUi.iconActionButton(if muted then "audio_unmute" else "audio_mute", if muted then "volume" else "volume-off", output),
            panelUi.iconActionButton("audio_volume_down", "volume-2", output),
            panelUi.iconActionButton("audio_volume_up", "volume-3", output),
            ui.label({ text = volume, fontSize = 8, color = "on_surface_variant", maxLines = 1 }),
        }),
    })
end

function panelUi.gestureOptions(button)
    local configured = ""
    if type(status) == "table" and type(status.config) == "table" and type(status.config.gestures) == "table" then
        configured = tostring(status.config.gestures[button] or "")
    end
    local labels = {}
    local values = {}
    local selectedIndex = 0
    for _, entry in ipairs(ACTIONS) do
        local available = actionAvailable(entry.id)
        if available or entry.id == configured then
            local label = noctalia.tr(entry.label)
            if not available and entry.id == configured then
                label = noctalia.tr("actions.configured_unavailable", { action = label })
            end
            table.insert(labels, label)
            table.insert(values, entry.id)
            if entry.id == configured then
                selectedIndex = #values - 1
            end
        end
    end
    return labels, values, selectedIndex
end

function panelUi.gestureRow(button, label)
    local labels, values, selectedIndex = panelUi.gestureOptions(button)
    return ui.row({ gap = 10, align = "center" }, {
        ui.label({ text = label, width = 92, fontSize = 12 }),
        ui.select({
            key = "gesture-" .. button,
            options = labels,
            selectedIndex = selectedIndex,
            enabled = storageValid(),
            flexGrow = 1,
            onChange = function(index)
                local action = values[math.floor(tonumber(index) or 0) + 1]
                if action ~= nil then
                    send({ kind = "set_mapping", button = button, action = action })
                end
            end,
        }),
    })
end

-- Provider status, discovery, and managed-library views.
function panelUi.shortcutsSection()
    return panelUi.card({
        panelUi.sectionHeader("mouse", noctalia.tr("panel.shortcuts.title"), noctalia.tr("panel.shortcuts.description")),
        panelUi.gestureRow("left", noctalia.tr("panel.shortcuts.left")),
        panelUi.gestureRow("middle", noctalia.tr("panel.shortcuts.middle")),
        panelUi.gestureRow("right", noctalia.tr("panel.shortcuts.right")),
        ui.label({
            text = noctalia.tr("panel.shortcuts.shortcut_limit"),
            fontSize = 10,
            color = "tertiary",
            maxLines = 3,
        }),
    })
end

local function paletteInventorySection()
    local paletteStatus = paletteInventory()
    local counts = type(paletteStatus.counts) == "table" and paletteStatus.counts or {}
    local cache = type(paletteStatus.cache) == "table" and paletteStatus.cache or {}
    local total = (tonumber(counts.wallpaper) or 0)
        + (tonumber(counts.builtin) or 0)
        + (tonumber(counts.community) or 0)
        + (tonumber(counts.custom) or 0)
    local stateText = if paletteStatus.refreshing == true
        then noctalia.tr("panel.palettes.refreshing")
        elseif paletteStatus.ready == true then noctalia.tr("panel.palettes.ready")
        else noctalia.tr("panel.palettes.starting")
    local children = {
        panelUi.sectionHeader(
            "palette",
            noctalia.tr("panel.palettes.title"),
            noctalia.tr("panel.palettes.description")
        ),
        ui.row({ gap = 7, align = "center" }, {
            ui.column({ gap = 2, flexGrow = 1 }, {
                ui.label({
                    text = stateText .. " · " .. noctalia.tr("panel.palettes.ready_count", { count = tostring(total) }),
                    fontSize = 10,
                    fontWeight = "bold",
                    color = if paletteStatus.ready == true then "primary" else "on_surface_variant",
                }),
                ui.label({
                    text = noctalia.tr("panel.palettes.counts", {
                        wallpaper = tostring(counts.wallpaper or 0),
                        builtin = tostring(counts.builtin or 0),
                        community = tostring(counts.community or 0),
                        custom = tostring(counts.custom or 0),
                    }),
                    fontSize = 9,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
            }),
            ui.button({
                text = noctalia.tr("panel.palettes.refresh"),
                glyph = "refresh",
                variant = "ghost",
                controlSize = "sm",
                enabled = storageValid() and paletteStatus.refreshing ~= true,
                onClick = function()
                    send({ kind = "palettes_refresh", force = true })
                end,
            }),
        }),
        ui.label({
            text = noctalia.tr("panel.palettes.cache", {
                source = panelUi.valueOr(cache.source, "common.none"),
                time = if tostring(cache.fetched_at_text or "") ~= ""
                    then tostring(cache.fetched_at_text)
                    else noctalia.tr("common.unknown"),
            })
                .. "\n"
                .. noctalia.tr("panel.palettes.custom_directory", {
                    path = panelUi.valueOr(paletteStatus.custom_directory, "common.unset"),
                }),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 4,
        }),
    }
    if tostring(paletteStatus.error or "") ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.palettes.degraded", { error = tostring(paletteStatus.error) }),
                fontSize = 9,
                color = "tertiary",
                maxLines = 4,
            })
        )
    end
    return panelUi.card(children)
end

local function wallhavenSection()
    local providerStatus, results = wallhavenData()
    local installedItems = panelUi.providerInstallIndex().wallhaven
    local sourceItems = type(results.items) == "table" and results.items or {}
    local items, itemCount, localPage, firstItem, lastItem = panelUi.providerItems(
        sourceItems,
        providerResultPages.wallhaven,
        PROVIDER_RESULT_CHUNK
    )
    local meta = type(results.meta) == "table" and results.meta or {}
    local activeFilters = type(results.filters) == "table" and results.filters or {}
    local ready = providerStatus.available == true and storageValid()
    local busy = providerStatus.busy == true
    preview.plan(
        "wallhaven",
        "wallhaven:"
            .. tostring(providerResultEpochs.wallhaven)
            .. ":"
            .. tostring(results.sequence or 0)
            .. ":"
            .. (if ready then "ready" else "disabled"),
        sourceItems,
        firstItem,
        lastItem,
        nil,
        ready
    )
    local sortingValues = { "date_added", "relevance", "random", "views", "favorites", "toplist", "hot" }
    local sortingLabels = {
        noctalia.tr("panel.wallhaven.sort_newest"),
        noctalia.tr("panel.wallhaven.sort_relevance"),
        noctalia.tr("panel.wallhaven.sort_random"),
        noctalia.tr("panel.wallhaven.sort_views"),
        noctalia.tr("panel.wallhaven.sort_favorites"),
        noctalia.tr("panel.wallhaven.sort_toplist"),
        noctalia.tr("panel.wallhaven.sort_hot"),
    }
    local sortingIndex = 0
    for index, value in ipairs(sortingValues) do
        if value == wallhavenSortingDraft then
            sortingIndex = index - 1
            break
        end
    end
    local colorLabels = { noctalia.tr("panel.wallhaven.color_any") }
    local colorIndex = 0
    for index, value in ipairs(WALLHAVEN_COLOR_VALUES) do
        table.insert(colorLabels, "#" .. value)
        if value == wallhavenColorDraft then
            colorIndex = index
        end
    end
    local categoryValues = { "111", "100", "010", "001", "110", "101", "011" }
    local categoryLabels = {
        noctalia.tr("panel.wallhaven.category_all"),
        noctalia.tr("panel.wallhaven.category_general"),
        noctalia.tr("panel.wallhaven.category_anime"),
        noctalia.tr("panel.wallhaven.category_people"),
        noctalia.tr("panel.wallhaven.category_general_anime"),
        noctalia.tr("panel.wallhaven.category_general_people"),
        noctalia.tr("panel.wallhaven.category_anime_people"),
    }
    local categoryIndex = 0
    for index, value in ipairs(categoryValues) do
        if value == wallhavenCategoriesDraft then
            categoryIndex = index - 1
            break
        end
    end
    local purityValues = { "100", "010", "001", "110", "101", "011", "111" }
    local purityLabels = {
        noctalia.tr("panel.wallhaven.purity_safe"),
        noctalia.tr("panel.wallhaven.purity_sketchy"),
        noctalia.tr("panel.wallhaven.purity_nsfw"),
        noctalia.tr("panel.wallhaven.purity_safe_sketchy"),
        noctalia.tr("panel.wallhaven.purity_safe_nsfw"),
        noctalia.tr("panel.wallhaven.purity_sketchy_nsfw"),
        noctalia.tr("panel.wallhaven.purity_all"),
    }
    local purityIndex = 0
    for index, value in ipairs(purityValues) do
        if value == wallhavenPurityDraft then
            purityIndex = index - 1
            break
        end
    end
    local topRangeValues = { "1d", "3d", "1w", "1M", "3M", "6M", "1y" }
    local topRangeLabels = {
        noctalia.tr("panel.wallhaven.range_1d"),
        noctalia.tr("panel.wallhaven.range_3d"),
        noctalia.tr("panel.wallhaven.range_1w"),
        noctalia.tr("panel.wallhaven.range_1m"),
        noctalia.tr("panel.wallhaven.range_3m"),
        noctalia.tr("panel.wallhaven.range_6m"),
        noctalia.tr("panel.wallhaven.range_1y"),
    }
    local topRangeIndex = 3
    for index, value in ipairs(topRangeValues) do
        if value == wallhavenResolutionDraft.top_range then
            topRangeIndex = index - 1
            break
        end
    end
    local function requestSearch(page, preserveActiveFilters)
        page = math.max(1, math.floor(tonumber(page) or 1))
        local request
        if preserveActiveFilters then
            request = {
                query = tostring(activeFilters.query or ""),
                categories = tostring(activeFilters.categories or "111"),
                purity = tostring(activeFilters.purity or "100"),
                sorting = tostring(activeFilters.sorting or "date_added"),
                order = tostring(activeFilters.order or "desc"),
                atleast = tostring(activeFilters.atleast or ""),
                resolutions = tostring(activeFilters.resolutions or ""),
                ratios = tostring(activeFilters.ratios or ""),
                colors = tostring(activeFilters.colors or ""),
                top_range = tostring(activeFilters.top_range or "1M"),
                seed = tostring(meta.seed or activeFilters.seed or ""),
            }
        else
            request = {
                query = wallhavenSearchDraft,
                categories = wallhavenCategoriesDraft,
                purity = wallhavenPurityDraft,
                sorting = wallhavenSortingDraft,
                order = wallhavenOrderDraft,
                atleast = if wallhavenResolutionDraft.mode == "atleast" then wallhavenResolutionDraft.value else "",
                resolutions = if wallhavenResolutionDraft.mode == "exact" then wallhavenResolutionDraft.value else "",
                ratios = wallhavenRatiosDraft,
                colors = wallhavenColorDraft,
                top_range = wallhavenResolutionDraft.top_range,
                seed = "",
            }
        end
        request.kind = "wallhaven_search"
        request.page = page
        wallhavenPageDraft = tostring(page)
        wallhavenPageInputRevision += 1
        providerResultPages.wallhaven = 1
        preview.cancel()
        send(request)
    end
    local children = {
        panelUi.sectionHeader(
            "world-search",
            noctalia.tr("panel.wallhaven.title"),
            noctalia.tr("panel.wallhaven.description")
        ),
        panelUi.actionButton("wallhaven_site", "external-link", "ghost", true),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "wallhaven-search-" .. tostring(wallhavenSearchInputRevision),
                value = wallhavenSearchDraft,
                placeholder = noctalia.tr("panel.wallhaven.search_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    wallhavenSearchDraft = tostring(value or "")
                end,
                onSubmit = function(value)
                    wallhavenSearchDraft = tostring(value or "")
                    requestSearch(wallhavenPageDraft, false)
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.wallhaven.search"),
                glyph = "search",
                variant = "primary",
                controlSize = "sm",
                enabled = ready and not busy,
                onClick = function()
                    requestSearch(wallhavenPageDraft, false)
                end,
            }),
            ui.button({
                glyph = "x",
                tooltip = noctalia.tr("panel.wallhaven.clear"),
                variant = "ghost",
                controlSize = "sm",
                enabled = ready and not busy,
                onClick = function()
                    wallhavenSearchDraft = ""
                    wallhavenPageDraft = "1"
                    wallhavenSearchInputRevision += 1
                    wallhavenPageInputRevision += 1
                    providerResultPages.wallhaven = 1
                    preview.cancel()
                    send({ kind = "wallhaven_clear" })
                end,
            }),
        }),
        ui.label({
            text = noctalia.tr("panel.wallhaven.query_help"),
            fontSize = 8,
            color = "on_surface_variant",
            maxLines = 3,
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "wallhaven-categories",
                options = categoryLabels,
                selectedIndex = categoryIndex,
                flexGrow = 1,
                onChange = function(index)
                    wallhavenCategoriesDraft = categoryValues[math.floor(tonumber(index) or 0) + 1] or "111"
                    render()
                end,
            }),
            ui.select({
                key = "wallhaven-purity",
                options = purityLabels,
                selectedIndex = purityIndex,
                flexGrow = 1,
                onChange = function(index)
                    wallhavenPurityDraft = purityValues[math.floor(tonumber(index) or 0) + 1] or "100"
                    render()
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "wallhaven-sort",
                options = sortingLabels,
                selectedIndex = sortingIndex,
                flexGrow = 1,
                onChange = function(index)
                    wallhavenSortingDraft = sortingValues[math.floor(tonumber(index) or 0) + 1] or "date_added"
                    render()
                end,
            }),
            ui.select({
                key = "wallhaven-order",
                options = {
                    noctalia.tr("panel.wallhaven.order_desc"),
                    noctalia.tr("panel.wallhaven.order_asc"),
                },
                selectedIndex = if wallhavenOrderDraft == "asc" then 1 else 0,
                flexGrow = 1,
                onChange = function(index)
                    wallhavenOrderDraft = if math.floor(tonumber(index) or 0) == 1 then "asc" else "desc"
                    render()
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "wallhaven-resolution-mode",
                options = {
                    noctalia.tr("panel.wallhaven.resolution_minimum"),
                    noctalia.tr("panel.wallhaven.resolution_exact"),
                },
                selectedIndex = if wallhavenResolutionDraft.mode == "exact" then 1 else 0,
                onChange = function(index)
                    wallhavenResolutionDraft.mode = if math.floor(tonumber(index) or 0) == 1 then "exact" else "atleast"
                    render()
                end,
            }),
            ui.input({
                key = "wallhaven-resolution",
                value = wallhavenResolutionDraft.value,
                placeholder = if wallhavenResolutionDraft.mode == "exact"
                    then noctalia.tr("panel.wallhaven.exact_placeholder")
                    else noctalia.tr("panel.wallhaven.minimum_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    wallhavenResolutionDraft.value = tostring(value or "")
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "wallhaven-ratios",
                value = wallhavenRatiosDraft,
                placeholder = noctalia.tr("panel.wallhaven.ratios_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    wallhavenRatiosDraft = tostring(value or "")
                end,
            }),
            ui.select({
                key = "wallhaven-color",
                options = colorLabels,
                selectedIndex = colorIndex,
                flexGrow = 1,
                onChange = function(index)
                    wallhavenColorDraft = WALLHAVEN_COLOR_VALUES[math.floor(tonumber(index) or 0)] or ""
                    render()
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "wallhaven-top-range",
                options = topRangeLabels,
                selectedIndex = topRangeIndex,
                enabled = wallhavenSortingDraft == "toplist",
                flexGrow = 1,
                onChange = function(index)
                    wallhavenResolutionDraft.top_range = topRangeValues[math.floor(tonumber(index) or 0) + 1] or "1M"
                    render()
                end,
            }),
            ui.input({
                key = "wallhaven-page-" .. tostring(wallhavenPageInputRevision),
                value = wallhavenPageDraft,
                placeholder = noctalia.tr("panel.wallhaven.page_placeholder"),
                width = 65,
                onChange = function(value)
                    wallhavenPageDraft = tostring(value or "")
                end,
            }),
        }),
        ui.label({
            text = if busy
                then noctalia.tr("panel.wallhaven.busy", {
                    action = panelUi.valueOr(providerStatus.active_action, "panel.wallhaven.request"),
                })
                elseif ready then noctalia.tr("panel.wallhaven.ready")
                else noctalia.tr("panel.wallhaven.unavailable"),
            fontSize = 9,
            color = if ready then "primary" else "tertiary",
            maxLines = 3,
        }),
    }
    if tostring(providerStatus.last_error or "") ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.wallhaven.error", { error = tostring(providerStatus.last_error) }),
                fontSize = 9,
                color = "error",
                maxLines = 4,
            })
        )
    end
    if #items == 0 then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.wallhaven.empty"),
                fontSize = 9,
                color = "on_surface_variant",
            })
        )
    else
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.wallhaven.result_meta", {
                    page = tostring(meta.current_page or wallhavenPageDraft),
                    pages = tostring(meta.last_page or "?"),
                    total = tostring(meta.total or #items),
                }),
                fontSize = 9,
                color = "on_surface_variant",
            })
        )
        local currentPage = math.max(1, math.floor(tonumber(meta.current_page) or 1))
        local lastPage = math.max(currentPage, math.floor(tonumber(meta.last_page) or currentPage))
        table.insert(
            children,
            ui.row({ gap = 6, align = "center" }, {
                ui.button({
                    text = noctalia.tr("panel.wallhaven.previous_page"),
                    glyph = "chevron-left",
                    variant = "ghost",
                    controlSize = "sm",
                    flexGrow = 1,
                    enabled = ready and not busy and currentPage > 1,
                    onClick = function()
                        requestSearch(currentPage - 1, true)
                    end,
                }),
                ui.button({
                    text = noctalia.tr("panel.wallhaven.next_page"),
                    glyph = "chevron-right",
                    variant = "ghost",
                    controlSize = "sm",
                    flexGrow = 1,
                    enabled = ready and not busy and currentPage < lastPage,
                    onClick = function()
                        requestSearch(currentPage + 1, true)
                    end,
                }),
            })
        )
        panelUi.appendExplicitGrid(
            children,
            items,
            #items,
            BROWSER_GRID_COLUMNS,
            function(item)
                local resultItem = item
                local itemId = tostring(item.id or ""):lower()
                local installed = installedItems[itemId] ~= nil
                local downloading = busy
                    and tostring(providerStatus.active_action or "") == "download"
                    and tostring(providerStatus.active_id or ""):lower() == itemId
                local downloadState = if installed then "installed" elseif downloading then "active" else "ready"
                return ui.column({
                    key = "wallhaven-result-" .. itemId,
                    width = 232,
                    gap = 5,
                    padding = 8,
                    radius = 10,
                    fill = "surface_variant/0.25",
                    border = "outline/0.25",
                    borderWidth = 1,
                    align = "stretch",
                }, {
                    preview.node("wallhaven", item, 216, 122, "photo"),
                    ui.label({
                        text = tostring(item.id or noctalia.tr("panel.wallhaven.default_name"))
                            .. " · "
                            .. tostring(item.resolution or ""),
                        fontSize = 10,
                        fontWeight = "bold",
                        maxWidth = 216,
                        maxLines = 2,
                    }),
                    ui.label({
                        text = noctalia.tr("panel.wallhaven.result_summary", {
                            category = tostring(item.category or ""),
                            purity = tostring(item.purity or ""),
                            favorites = tostring(item.favorites or 0),
                        }),
                        fontSize = 8,
                        color = "on_surface_variant",
                        maxWidth = 216,
                        maxLines = 2,
                    }),
                    ui.button({
                        text = panelUi.downloadLabel(downloadState, ""),
                        glyph = if installed then "check" elseif downloading then "loader" else "download",
                        variant = if installed then "ghost" else "primary",
                        controlSize = "sm",
                        enabled = ready and not busy and not installed,
                        onClick = function()
                            send({ kind = "wallhaven_download", id = tostring(resultItem.id or "") })
                        end,
                    }),
                })
            end
        )
        panelUi.appendPageControls(
            children,
            itemCount,
            localPage,
            PROVIDER_RESULT_CHUNK,
            function(value)
                providerResultPages.wallhaven = value
            end
        )
    end
    return panelUi.card(children)
end

local function motionBgsSection()
    local provider = type(providers().motionbgs) == "table" and providers().motionbgs or {}
    local motionStatus, results = motionBgsData()
    local installedItems = panelUi.providerInstallIndex().motionbgs
    local queuedDownloads, queuedDownloadCount = panelUi.motionQueueIndex(motionStatus)
    local sourceItems = type(results.items) == "table" and results.items or {}
    local items, itemCount, localPage, firstItem, lastItem = panelUi.providerItems(
        sourceItems,
        providerResultPages.motionbgs,
        PROVIDER_RESULT_CHUNK
    )
    local meta = type(results.meta) == "table" and results.meta or {}
    local integrationReady = provider.integration_available == true
        and motionStatus.available == true
        and storageValid()
    local motionEnabled = settings().use_motionbgs ~= false
    local helperReady = motionStatus.binary_compatible == true
    local busy = motionStatus.busy == true
    local queueDepth = math.max(0, math.floor(tonumber(motionStatus.queue_depth) or 0))
    local queueLimit = math.max(1, math.floor(tonumber(motionStatus.queue_limit) or 8))
    local recentDownload = type(motionStatus.last_download) == "table" and motionStatus.last_download or {}
    local recentDownloadPath = tostring(recentDownload.path or "")
    local recentDownloadKey = if recentDownloadPath ~= ""
            and noctalia.fileExists(recentDownloadPath)
            and noctalia.fileExists(recentDownloadPath .. ".motionbgs.json")
        then tostring(recentDownload.slug or ""):lower()
            .. ":"
            .. tostring(recentDownload.quality or ""):lower()
        else ""
    local quality = tostring(settings().motionbgs_quality or "hd")
    preview.plan(
        "motionbgs",
        "motionbgs:"
            .. tostring(providerResultEpochs.motionbgs)
            .. ":"
            .. tostring(results.sequence or 0)
            .. ":"
            .. (if integrationReady then "ready" else "disabled"),
        sourceItems,
        firstItem,
        lastItem,
        nil,
        integrationReady
    )
    local modeValues = { "search", "latest", "genre", "4k", "hd" }
    local modeLabels = {
        noctalia.tr("panel.motionbgs.mode_search"),
        noctalia.tr("panel.motionbgs.mode_latest"),
        noctalia.tr("panel.motionbgs.mode_genre"),
        noctalia.tr("panel.motionbgs.mode_4k"),
        noctalia.tr("panel.motionbgs.mode_hd"),
    }
    local modeIndex = 0
    for index, value in ipairs(modeValues) do
        if value == motionBrowseDraft.mode then
            modeIndex = index - 1
            break
        end
    end
    local requestBrowse
    local selectorNode
    if motionBrowseDraft.mode == "search" then
        selectorNode = ui.input({
            key = "motionbgs-search-" .. tostring(motionQueryInputRevision),
            value = motionBrowseDraft.query,
            placeholder = noctalia.tr("panel.motionbgs.search_placeholder"),
            flexGrow = 1,
            onChange = function(value)
                motionBrowseDraft.query = tostring(value or "")
            end,
            onSubmit = function(value)
                motionBrowseDraft.query = tostring(value or "")
                requestBrowse(motionBrowseDraft.page, false)
            end,
        })
    elseif motionBrowseDraft.mode == "genre" then
        local genreValues = {
            "",
            "anime",
            "games",
            "superhero",
            "nature",
            "car",
            "tv",
            "holiday",
            "animal",
            "fantasy",
            "space",
            "horror",
            "technology",
            "football",
            "japan",
            "hello-kitty",
        }
        local genreLabels = {
            noctalia.tr("panel.motionbgs.genre_presets.custom"),
            noctalia.tr("panel.motionbgs.genre_presets.anime"),
            noctalia.tr("panel.motionbgs.genre_presets.games"),
            noctalia.tr("panel.motionbgs.genre_presets.superhero"),
            noctalia.tr("panel.motionbgs.genre_presets.nature"),
            noctalia.tr("panel.motionbgs.genre_presets.car"),
            noctalia.tr("panel.motionbgs.genre_presets.tv"),
            noctalia.tr("panel.motionbgs.genre_presets.holiday"),
            noctalia.tr("panel.motionbgs.genre_presets.animal"),
            noctalia.tr("panel.motionbgs.genre_presets.fantasy"),
            noctalia.tr("panel.motionbgs.genre_presets.space"),
            noctalia.tr("panel.motionbgs.genre_presets.horror"),
            noctalia.tr("panel.motionbgs.genre_presets.technology"),
            noctalia.tr("panel.motionbgs.genre_presets.football"),
            noctalia.tr("panel.motionbgs.genre_presets.japan"),
            noctalia.tr("panel.motionbgs.genre_presets.hello_kitty"),
        }
        local genreIndex = 0
        for index, value in ipairs(genreValues) do
            if value ~= "" and value == motionBrowseDraft.genre then
                genreIndex = index - 1
                break
            end
        end
        selectorNode = ui.column({ gap = 4, flexGrow = 1 }, {
            ui.select({
                key = "motionbgs-genre-preset",
                options = genreLabels,
                selectedIndex = genreIndex,
                onChange = function(index)
                    local selectedGenre = genreValues[math.floor(tonumber(index) or 0) + 1] or ""
                    -- The empty option means Custom. Clear the preset draft so
                    -- the selection is visible and the adjacent input is ready.
                    motionBrowseDraft.genre = selectedGenre
                    motionGenreInputRevision += 1
                    render()
                end,
            }),
            ui.input({
                key = "motionbgs-genre-" .. tostring(motionGenreInputRevision),
                value = motionBrowseDraft.genre,
                placeholder = noctalia.tr("panel.motionbgs.genre_placeholder"),
                onChange = function(value)
                    motionBrowseDraft.genre = tostring(value or ""):lower()
                end,
                onSubmit = function(value)
                    motionBrowseDraft.genre = tostring(value or ""):lower()
                    requestBrowse(motionBrowseDraft.page, false)
                end,
            }),
        })
    else
        selectorNode = ui.label({
            text = if motionBrowseDraft.mode == "latest"
                then noctalia.tr("panel.motionbgs.latest_note")
                elseif motionBrowseDraft.mode == "4k" then noctalia.tr("panel.motionbgs.quality_4k_note")
                else noctalia.tr("panel.motionbgs.quality_hd_note"),
            fontSize = 9,
            color = "on_surface_variant",
            flexGrow = 1,
            maxLines = 3,
        })
    end
    requestBrowse = function(page, preserveActiveResult)
        local mode = if preserveActiveResult then tostring(results.mode or "search") else motionBrowseDraft.mode
        page = math.max(1, math.floor(tonumber(page) or 1))
        if mode == "search" or mode == "hd" then
            page = 1
        end
        local query = if preserveActiveResult then tostring(results.query or "") else motionBrowseDraft.query
        local genre = if preserveActiveResult then tostring(results.genre or "") else motionBrowseDraft.genre
        if not preserveActiveResult then
            if mode == "search" and noctalia.string.trim(query) == "" then
                return
            elseif mode == "genre" and noctalia.string.trim(genre) == "" then
                return
            end
        end
        motionBrowseDraft.page = tostring(page)
        motionPageInputRevision += 1
        providerResultPages.motionbgs = 1
        preview.cancel()
        send({
            kind = "motionbgs_search",
            mode = mode,
            query = query,
            genre = genre,
            page = page,
        })
    end
    local helperStatusChildren = {
        ui.label({
            text = if not motionEnabled
                then noctalia.tr("panel.motionbgs.helper_chip_disabled")
                elseif not helperReady then noctalia.tr("panel.motionbgs.helper_chip_missing")
                elseif integrationReady
                then noctalia.tr("panel.motionbgs.helper_chip_ready", {
                    version = tostring(motionStatus.binary_version or ""),
                })
                else noctalia.tr("panel.motionbgs.helper_chip_unavailable"),
            color = if integrationReady then "primary" else "tertiary",
            fontSize = 9,
            flexGrow = 1,
            maxLines = 2,
        }),
    }
    if not helperReady then
        table.insert(helperStatusChildren, ui.button({
            text = noctalia.tr("panel.motionbgs.get_helper"),
            glyph = "download",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                send({ kind = "motionbgs_helper_open" })
            end,
        }))
        table.insert(helperStatusChildren, ui.button({
            glyph = "refresh",
            tooltip = noctalia.tr("panel.motionbgs.retry_helper"),
            variant = "ghost",
            controlSize = "sm",
            enabled = motionEnabled and not busy,
            onClick = function()
                send({ kind = "motionbgs_probe" })
            end,
        }))
    end
    table.insert(helperStatusChildren, panelUi.actionButton("motionbgs_open", "external-link", "ghost", false))
    local children = {
        panelUi.sectionHeader("world-search", noctalia.tr("panel.motionbgs.title"), noctalia.tr("panel.motionbgs.description")),
        ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "motionbgs-mode",
                options = modeLabels,
                selectedIndex = modeIndex,
                flexGrow = 1,
                onChange = function(index)
                    motionBrowseDraft.mode = modeValues[math.floor(tonumber(index) or 0) + 1] or "search"
                    motionBrowseDraft.page = "1"
                    motionPageInputRevision += 1
                    render()
                end,
            }),
            selectorNode,
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "motionbgs-page-" .. tostring(motionPageInputRevision),
                value = motionBrowseDraft.page,
                placeholder = noctalia.tr("panel.motionbgs.page_placeholder"),
                width = 65,
                enabled = motionBrowseDraft.mode == "latest"
                    or motionBrowseDraft.mode == "genre"
                    or motionBrowseDraft.mode == "4k",
                onChange = function(value)
                    motionBrowseDraft.page = tostring(value or "")
                end,
                onSubmit = function(value)
                    motionBrowseDraft.page = tostring(value or "")
                    requestBrowse(motionBrowseDraft.page, false)
                end,
            }),
            ui.button({
                text = if motionBrowseDraft.mode == "search"
                    then noctalia.tr("panel.motionbgs.search")
                    else noctalia.tr("panel.motionbgs.browse"),
                glyph = "search",
                variant = "primary",
                controlSize = "sm",
                flexGrow = 1,
                enabled = integrationReady and not busy,
                onClick = function()
                    requestBrowse(motionBrowseDraft.page, false)
                end,
            }),
            ui.button({
                glyph = "x",
                tooltip = noctalia.tr("panel.motionbgs.clear"),
                variant = "ghost",
                controlSize = "sm",
                enabled = integrationReady and not busy,
                onClick = function()
                    motionBrowseDraft.query = ""
                    motionBrowseDraft.page = "1"
                    motionQueryInputRevision += 1
                    motionPageInputRevision += 1
                    providerResultPages.motionbgs = 1
                    preview.cancel()
                    send({ kind = "motionbgs_clear" })
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, helperStatusChildren),
    }

    if tostring(motionStatus.active_action or "") == "download" or queuedDownloadCount > 0 then
        table.insert(children, ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "download", color = "primary" }),
            ui.label({
                text = noctalia.tr("panel.downloads.queue_summary", {
                    active = if tostring(motionStatus.active_action or "") == "download" then "1" else "0",
                    queued = tostring(queuedDownloadCount),
                }),
                fontSize = 9,
                color = "on_surface_variant",
                flexGrow = 1,
                maxLines = 1,
            }),
        }))
    end

    local providerError = tostring(motionStatus.last_error or "")
    if providerError ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.motionbgs.error", { error = providerError }),
                fontSize = 10,
                color = "error",
                maxLines = 5,
            })
        )
    end

    if #items == 0 then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.motionbgs.empty"),
                fontSize = 10,
                color = "on_surface_variant",
            })
        )
    else
        local resultMode = tostring(results.mode or "search")
        local currentPage = math.max(1, math.floor(tonumber(meta.current_page or results.page) or 1))
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.motionbgs.results_count", { count = tostring(itemCount) }),
                fontSize = 9,
                color = "on_surface_variant",
                maxLines = 1,
            })
        )
        if meta.pageable == true then
            table.insert(
                children,
                ui.row({ gap = 6, align = "center" }, {
                    ui.button({
                        text = noctalia.tr("panel.motionbgs.previous_page"),
                        glyph = "chevron-left",
                        variant = "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        enabled = integrationReady and not busy and meta.has_previous == true,
                        onClick = function()
                            requestBrowse(currentPage - 1, true)
                        end,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.motionbgs.next_page"),
                        glyph = "chevron-right",
                        variant = "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        enabled = integrationReady and not busy and meta.has_next == true,
                        onClick = function()
                            requestBrowse(currentPage + 1, true)
                        end,
                    }),
                })
            )
        end
        panelUi.appendExplicitGrid(
            children,
            items,
            #items,
            BROWSER_GRID_COLUMNS,
            function(item)
                local slug = tostring(item.slug or "")
                local function downloadButton(requestedQuality)
                    local stateKey = slug:lower() .. ":" .. requestedQuality
                    local installed = installedItems[stateKey] ~= nil or stateKey == recentDownloadKey
                    local active = tostring(motionStatus.active_action or "") == "download"
                        and tostring(motionStatus.active_slug or ""):lower() == slug:lower()
                        and tostring(motionStatus.active_quality or ""):lower() == requestedQuality
                    local queued = queuedDownloads[stateKey] == true
                    local downloadState = if installed
                        then "installed"
                        elseif active then "active"
                        elseif queued then "queued"
                        else "ready"
                    return ui.button({
                        text = panelUi.downloadLabel(downloadState, requestedQuality),
                        glyph = if installed then "check" elseif active or queued then "loader" else "download",
                        tooltip = panelUi.downloadLabel(downloadState, requestedQuality),
                        variant = if requestedQuality == quality and downloadState == "ready" then "primary" else "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        enabled = integrationReady
                            and slug ~= ""
                            and queueDepth < queueLimit
                            and not installed
                            and not active
                            and not queued,
                        onClick = function()
                            send({ kind = "motionbgs_download", slug = slug, quality = requestedQuality })
                        end,
                    })
                end
                return ui.column({
                    key = "motionbgs-result-" .. slug,
                    width = 232,
                    gap = 5,
                    padding = 8,
                    radius = 10,
                    fill = "surface_variant/0.25",
                    border = "outline/0.25",
                    borderWidth = 1,
                    align = "stretch",
                }, {
                    preview.node("motionbgs", item, 216, 122, "movie"),
                    ui.label({
                        text = tostring(item.title or slug),
                        fontSize = 11,
                        fontWeight = "bold",
                        maxWidth = 216,
                        maxLines = 2,
                    }),
                    ui.label({
                        text = panelUi.valueOr(item.quality, "common.unknown"),
                        fontSize = 9,
                        color = "on_surface_variant",
                        maxWidth = 216,
                        maxLines = 1,
                    }),
                    ui.column({ gap = 3, align = "stretch" }, {
                        downloadButton("hd"),
                        downloadButton("4k"),
                    }),
                })
            end
        )
        panelUi.appendPageControls(
            children,
            itemCount,
            localPage,
            PROVIDER_RESULT_CHUNK,
            function(value)
                providerResultPages.motionbgs = value
            end
        )
    end

    return panelUi.card(children)
end

function panelUi.libraryTargetOutput()
    return if selectedScreen ~= "" then selectedScreen else focusedOutput()
end

function panelUi.virtualLibraryPairing(entry, libraryItem, existing)
    if type(existing) == "table" then
        local copied = {}
        for key, value in pairs(existing) do
            copied[key] = value
        end
        copied.pairing_id = tostring(existing.id or "")
        return copied
    end

    local kind = tostring(type(entry) == "table" and entry.kind or "static")
    local source = tostring(type(entry) == "table" and entry.source or "")
    local scheme = tostring(settings().color_scheme or "")
    if scheme == "" then
        scheme = paletteNames("wallpaper")[1] or "m3-tonal-spot"
    end
    local useAdaptiveColors = settings().sync_colors ~= false
    return {
        id = "library-entry",
        label = tostring(type(entry) == "table" and entry.label or basename(source)):sub(1, 160),
        media = if kind == "static" then nil else { kind = kind, source = source },
        still = if kind == "static"
            then { mode = "selected", path = source }
            else { mode = "automatic" },
        theme = if useAdaptiveColors
            then { mode = "auto", source = "wallpaper", selection = scheme }
            else { mode = "inherit", source = "inherit", selection = "" },
        added_at = tostring(type(entry) == "table" and entry.added_at or ""),
    }
end

function panelUi.libraryPreviewPath(entry, libraryItem, bundle, output)
    local kind = tostring(type(entry) == "table" and entry.kind or "")
    if kind == "static" then
        return tostring(type(entry) == "table" and entry.source or "")
    end
    local still = type(bundle) == "table" and type(bundle.still) == "table" and bundle.still or {}
    local path = if tostring(still.mode or "") == "selected" then tostring(still.path or "") else ""
    if path == "" and type(libraryItem) == "table" then
        path = tostring(libraryItem.paired_preview or "")
    end
    if path == "" and type(libraryItem) == "table" then
        path = tostring(libraryItem.preview or "")
    end
    if path == "" then
        local withOutput = entryForOutput(entry, output)
        path = tostring(withOutput.still_path or "")
    end
    return path
end

function panelUi.libraryPaletteSummary(bundle, isDefault)
    local theme = type(bundle) == "table" and type(bundle.theme) == "table" and bundle.theme or {}
    local policy = if tostring(theme.source or "") == "inherit"
        then noctalia.tr("panel.palettes.inherit")
        else panelUi.valueOr(theme.selection, "common.unknown")
    local label = (if isDefault then noctalia.tr("panel.library.default_pairing") else noctalia.tr("panel.library.saved_pairing"))
        .. " · "
        .. policy
    return ui.row({ gap = 4, align = "center" }, {
        ui.box({ width = 12, height = 12, radius = 4, fill = "primary" }),
        ui.box({ width = 12, height = 12, radius = 4, fill = "secondary" }),
        ui.box({ width = 12, height = 12, radius = 4, fill = "tertiary" }),
        ui.label({ text = label, fontSize = 8, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
    })
end

function panelUi.libraryThumbnail(kind, path, paired)
    path = tostring(path or "")
    if path:sub(1, 1) == "/" and path:find("[%c]") == nil and noctalia.fileExists(path) then
        return ui.image({
            width = 216,
            height = 122,
            path = path,
            fit = "cover",
            radius = 9,
            border = if paired then "primary/0.6" else "outline/0.3",
            borderWidth = if paired then 2 else 1,
        })
    end
    return ui.row({
        width = 216,
        height = 122,
        radius = 9,
        fill = "surface_variant/0.5",
        border = if paired then "primary/0.6" else "outline/0.3",
        borderWidth = if paired then 2 else 1,
        align = "center",
        justify = "center",
    }, {
        ui.glyph({
            name = if kind == "static" then "photo" elseif kind == "video" then "player-play" else "movie",
            color = if paired then "primary" else "on_surface_variant",
            size = 26,
        }),
    })
end

function panelUi.libraryCard(item)
    local entry = type(item) == "table" and item.entry or {}
    local metadata = type(item) == "table" and item.metadata or {}
    local kind = tostring(entry.kind or "static")
    local existing = type(item) == "table" and item.pairing or matchingPairingForLibraryEntry(entry)
    local customized = type(existing) == "table" and existing.customized == true
    local output = panelUi.libraryTargetOutput()
    local bundle = panelUi.virtualLibraryPairing(entry, metadata, if customized then existing else nil)
    local defaultBundle = panelUi.virtualLibraryPairing(entry, metadata, nil)
    local previewPath = panelUi.libraryPreviewPath(entry, metadata, bundle, output)
    local managed = metadata.managed == true and metadata.deletable == true and tostring(metadata.id or "") ~= ""
    local pairingId = if customized then tostring(existing.id or "") else ""
    local profileId = type(existing) == "table" and tostring(existing.id or "") or ""
    local itemId = tostring(metadata.id or "")
    local managedDeleteArmed = managed and pendingDeleteItemId == itemId
    local pairingResetArmed = customized and pendingResetPairingId == profileId
    local destructiveActionArmed = managedDeleteArmed
    local currentProviders = providers()
    local canApply = if kind == "static"
        then currentProviders.noctalia_cli == true
        elseif kind == "video" then type(currentProviders.mpvpaper) == "table"
            and currentProviders.mpvpaper.apply_available == true
        else type(currentProviders.w_engine) == "table" and currentProviders.w_engine.apply_available == true
    local playlistId = resolveSelectedPlaylist(output)
    local still = type(bundle.still) == "table" and bundle.still or {}
    local stillText = if kind == "static"
        then noctalia.tr("panel.library.still_source")
        elseif tostring(still.mode or "") == "selected" and tostring(metadata.preview or "") ~= ""
            then noctalia.tr("panel.library.still_preview")
        elseif tostring(still.mode or "") == "selected" then noctalia.tr("panel.library.still_selected")
        else noctalia.tr("panel.library.still_automatic")
    local sourceDetail = if kind == "workshop"
        then noctalia.tr("panel.library.workshop_id", { id = tostring(entry.source or "") })
        else basename(entry.source)
    local ownership = if metadata.managed == true
        then noctalia.tr("panel.library.managed")
        elseif tostring(metadata.ownership or "") == "steam" then noctalia.tr("panel.library.steam_owned")
        else noctalia.tr("panel.library.user_owned")
    local actions = {
        ui.button({
            glyph = "player-play",
            tooltip = noctalia.tr("panel.library.apply"),
            variant = "primary",
            controlSize = "sm",
            enabled = canApply and storageValid() and output ~= "",
            onClick = function()
                send({ kind = "apply_entry", output = output, entry = entryForOutput(bundle, output) })
            end,
        }),
        ui.button({
            glyph = "playlist-add",
            tooltip = noctalia.tr("panel.library.add"),
            variant = "ghost",
            controlSize = "sm",
            enabled = storageValid() and output ~= "",
            onClick = function()
                if pairingId ~= "" then
                    send({
                        kind = "playlist_add_pairing",
                        output = output,
                        playlist_id = playlistId,
                        pairing_id = pairingId,
                    })
                else
                    send({
                        kind = "playlist_add_entry",
                        output = output,
                        playlist_id = playlistId,
                        entry = entryForOutput(bundle, output),
                    })
                end
            end,
        }),
        ui.button({
            glyph = "edit",
            tooltip = if customized
                then noctalia.tr("panel.pairings.edit")
                else noctalia.tr("panel.pairings.new"),
            variant = "ghost",
            controlSize = "sm",
            enabled = storageValid(),
            onClick = function()
                local editableEntry = entryForOutput(entry, output)
                openLibraryEntryPairing(editableEntry, metadata)
            end,
        }),
    }
    if customized then
        table.insert(actions, ui.button({
            glyph = if pairingResetArmed then "check" else "refresh",
            tooltip = noctalia.tr("panel.pairings.reset"),
            variant = if pairingResetArmed then "primary" else "ghost",
            controlSize = "sm",
            enabled = storageValid(),
            onClick = function()
                if pendingResetPairingId == profileId then
                    pendingResetPairingId = ""
                    defaultBundle.id = profileId
                    send({ kind = "pairing_reset", pairing = defaultBundle })
                else
                    pendingResetPairingId = profileId
                    pendingDeleteItemId = ""
                    render()
                end
            end,
        }))
    end
    if managed then
        table.insert(actions, ui.button({
            glyph = if managedDeleteArmed then "alert-triangle" else "trash",
            tooltip = noctalia.tr("panel.library.delete_managed"),
            variant = if managedDeleteArmed then "destructive" else "ghost",
            controlSize = "sm",
            enabled = storageValid(),
            onClick = function()
                if pendingDeleteItemId == itemId then
                    pendingDeleteItemId = ""
                    send({ kind = "library_delete", item_id = itemId })
                else
                    pendingDeleteItemId = itemId
                    pendingResetPairingId = ""
                    render()
                end
            end,
        }))
    end

    local children = {
        panelUi.libraryThumbnail(kind, previewPath, customized),
        ui.label({
            text = tostring(entry.label or basename(entry.source)),
            fontSize = 11,
            fontWeight = "bold",
            maxWidth = 216,
            maxLines = 2,
        }),
        ui.label({
            text = sourceDetail .. " · " .. ownership,
            fontSize = 8,
            color = "on_surface_variant",
            maxWidth = 216,
            maxLines = 2,
        }),
        panelUi.libraryPaletteSummary(bundle, not customized),
        ui.label({ text = stillText, fontSize = 8, color = "tertiary", maxLines = 1 }),
    }
    if pairingResetArmed or managedDeleteArmed then
        table.insert(children, ui.label({
            text = if managedDeleteArmed
                then noctalia.tr("panel.library.delete_managed_confirm", {
                    name = tostring(entry.label or basename(entry.source)),
                })
                else noctalia.tr("panel.pairings.confirm_reset"),
            fontSize = 8,
            color = if managedDeleteArmed then "error" else "primary",
            maxLines = 3,
        }))
    end
    table.insert(children, ui.row({ gap = 4, align = "center", justify = "end" }, actions))
    local cardKey = tostring(metadata.id or "")
    if cardKey == "" then
        cardKey = if pairingId ~= "" then "pairing:" .. pairingId else tostring(entry.source or "")
    end
    return ui.column({
        key = "library-card-" .. kind .. "-" .. cardKey,
        width = 232,
        gap = 5,
        padding = 8,
        radius = 10,
        fill = "surface_variant/0.24",
        border = if destructiveActionArmed
            then "error/0.55"
            elseif pairingResetArmed then "primary/0.65"
            elseif customized then "primary/0.35"
            else "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

function panelUi.libraryItems(kind, offset, limit)
    local currentLibrary = type(status) == "table" and type(status.library) == "table" and status.library or {}
    local sourceItems = if kind == "static"
        then currentLibrary.stills
        elseif kind == "video" then currentLibrary.videos
        else currentLibrary.workshops
    sourceItems = type(sourceItems) == "table" and sourceItems or {}
    local total = #sourceItems
    local first = math.max(1, math.floor(tonumber(offset) or 0) + 1)
    local maximum = math.max(0, math.floor(tonumber(limit) or total))
    local last = math.min(total, first + maximum - 1)
    local items = {}
    local signatures = {}
    local function add(entry, metadata, pairing)
        local signature = tostring(entry.kind or "") .. "\0" .. tostring(entry.source or "")
        local existingIndex = signatures[signature]
        if existingIndex ~= nil then
            if type(pairing) == "table" and type(items[existingIndex]) == "table" then
                items[existingIndex].pairing = preferredPairingForLibraryEntry(items[existingIndex].pairing, pairing)
            end
            return
        end
        signatures[signature] = #items + 1
        table.insert(items, { entry = entry, metadata = metadata, pairing = pairing })
    end
    for index = first, last do
        local sourceItem = sourceItems[index]
        if type(sourceItem) == "table" then
            if kind == "workshop" then
                local entry = {
                    kind = "workshop",
                    source = tostring(sourceItem.id or ""),
                    label = tostring(sourceItem.title or ("Workshop " .. tostring(sourceItem.id or ""))),
                    added_at = tostring(currentLibrary.scanned_at or ""),
                }
                add(entry, sourceItem, matchingPairingForLibraryEntry(entry))
            else
                local entry = {
                    kind = kind,
                    source = tostring(sourceItem.path or ""),
                    label = tostring(sourceItem.name or basename(sourceItem.path)),
                    added_at = tostring(currentLibrary.scanned_at or ""),
                }
                add(entry, sourceItem, matchingPairingForLibraryEntry(entry))
            end
        end
    end
    return items, currentLibrary, total
end

function panelUi.libraryDragSignature(entry)
    return "library\0" .. tostring(type(entry) == "table" and entry.kind or "")
        .. "\0"
        .. tostring(type(entry) == "table" and entry.source or "")
end

function panelUi.appendLibraryGrid(children, items, visible)
    panelUi.appendExplicitGrid(children, items, visible, BROWSER_GRID_COLUMNS, function(item)
        return panelUi.libraryCard(item)
    end)
end

function panelUi.mediumSettingsSection(kind)
    local configuration = settings()
    local imageReady, imageRoot = panelUi.locationReady("image")
    local videoReady, videoRoot = panelUi.locationReady("video")
    local dataDirectory = tostring(noctalia.pluginDataDir() or ""):gsub("/+$", "")
    local rows = {}
    local title
    local summary
    local note = ""
    local function addPath(glyph, label, path, ready)
        table.insert(rows, panelUi.pathRow(glyph, label, path, ready))
    end

    if kind == "video" then
        title = noctalia.tr("panel.medium_settings.video_title")
        local managed = tostring(configuration.motionbgs_managed_directory or "")
        if managed == "" and videoRoot ~= "" then
            managed = videoRoot .. "/Wall-in-One/MotionBGS"
        end
        addPath("movie", noctalia.tr("panel.storage.video_root"), videoRoot, videoReady)
        addPath("folder", noctalia.tr("panel.medium_settings.motionbgs_library"), managed, videoReady)
        local motionStatus = motionBgsData()
        local helperPath = tostring(type(motionStatus) == "table" and motionStatus.binary_path or "")
        if helperPath == "" then
            helperPath = tostring(configuration.backend_binary_path or "")
        end
        addPath(
            "terminal-2",
            noctalia.tr("panel.medium_settings.motionbgs_helper"),
            helperPath,
            type(motionStatus) == "table" and motionStatus.binary_compatible == true
        )
        addPath(
            "database",
            noctalia.tr("panel.storage.motion_cache"),
            if dataDirectory ~= "" then dataDirectory .. "/motionbgs-bridge-v1/cache/cache-v1.json" else "",
            dataDirectory ~= ""
        )
        addPath(
            "photo-search",
            noctalia.tr("panel.storage.thumbnail_cache"),
            if dataDirectory ~= "" then dataDirectory .. "/provider-previews/v1" else "",
            dataDirectory ~= ""
        )
        summary = noctalia.tr("panel.medium_settings.video_defaults", {
            quality = tostring(configuration.motionbgs_quality or "hd"):upper(),
            second = tostring(configuration.video_frame_second or 1),
            automatic = panelUi.boolText(configuration.auto_capture),
            colors = panelUi.boolText(configuration.sync_colors),
        })
    elseif kind == "workshop" then
        title = noctalia.tr("panel.medium_settings.workshop_title")
        local override = tostring(configuration.workshop_directory or "")
        local overrideReady = false
        if override ~= "" then
            override = noctalia.expandPath(override)
            local info = noctalia.fileInfo(override)
            overrideReady = type(info) == "table" and info.isDir == true
        end
        local automaticStills = tostring(configuration.automatic_stills_directory or "")
        if automaticStills == "" and imageRoot ~= "" then
            automaticStills = imageRoot .. "/Wall-in-One/Automatic Stills"
        end
        addPath("photo", noctalia.tr("panel.storage.image_root"), imageRoot, imageReady)
        addPath(
            "steam",
            noctalia.tr("panel.medium_settings.workshop_source"),
            if override ~= "" then override else noctalia.tr("panel.medium_settings.workshop_auto_discovery"),
            if override ~= "" then overrideReady else true
        )
        addPath("photo-down", noctalia.tr("panel.medium_settings.automatic_stills"), automaticStills, imageReady)
        addPath(
            "photo-search",
            noctalia.tr("panel.storage.thumbnail_cache"),
            if dataDirectory ~= "" then dataDirectory .. "/provider-previews/v1" else "",
            dataDirectory ~= ""
        )
        summary = noctalia.tr("panel.medium_settings.workshop_defaults", {
            delay = tostring(configuration.scene_screenshot_delay or 15),
            automatic = panelUi.boolText(configuration.auto_capture),
            colors = panelUi.boolText(configuration.sync_colors),
        })
        note = noctalia.tr("panel.medium_settings.workshop_display_note")
    else
        title = noctalia.tr("panel.medium_settings.image_title")
        local wallhavenManaged = tostring(configuration.wallhaven_managed_directory or "")
        if wallhavenManaged == "" and imageRoot ~= "" then
            wallhavenManaged = imageRoot .. "/Wall-in-One/Wallhaven"
        end
        local automaticStills = tostring(configuration.automatic_stills_directory or "")
        if automaticStills == "" and imageRoot ~= "" then
            automaticStills = imageRoot .. "/Wall-in-One/Automatic Stills"
        end
        addPath("photo", noctalia.tr("panel.storage.image_root"), imageRoot, imageReady)
        addPath("folder", noctalia.tr("panel.medium_settings.wallhaven_library"), wallhavenManaged, imageReady)
        addPath("photo-down", noctalia.tr("panel.medium_settings.automatic_stills"), automaticStills, imageReady)
        addPath(
            "photo-search",
            noctalia.tr("panel.storage.thumbnail_cache"),
            if dataDirectory ~= "" then dataDirectory .. "/provider-previews/v1" else "",
            dataDirectory ~= ""
        )
        addPath(
            "palette",
            noctalia.tr("panel.storage.palette_cache"),
            if dataDirectory ~= "" then dataDirectory .. "/palettes-cache.json" else "",
            dataDirectory ~= ""
        )
        summary = noctalia.tr("panel.medium_settings.image_defaults", {
            automatic = panelUi.boolText(configuration.auto_capture),
            colors = panelUi.boolText(configuration.sync_colors),
            scheme = panelUi.valueOr(configuration.color_scheme, "common.unset"),
        })
    end

    local children = {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = "settings", color = "primary" }),
            ui.label({ text = title, fontSize = 12, fontWeight = "bold", flexGrow = 1 }),
            ui.button({
                glyph = "settings",
                tooltip = noctalia.tr("panel.medium_settings.open_settings"),
                variant = "ghost",
                controlSize = "sm",
                onClick = "onSettings",
            }),
        }),
    }
    local index = 1
    while index <= #rows do
        local rowChildren = { rows[index] }
        if rows[index + 1] ~= nil then
            table.insert(rowChildren, rows[index + 1])
        end
        table.insert(children, ui.row({ gap = 8, align = "stretch" }, rowChildren))
        index += 2
    end
    table.insert(children, ui.label({
        text = summary,
        fontSize = 9,
        color = "on_surface_variant",
        maxLines = 4,
    }))
    if note ~= "" then
        table.insert(children, ui.label({ text = note, fontSize = 9, color = "tertiary", maxLines = 4 }))
    end
    return ui.column({ gap = 7, padding = 10, radius = 10, fill = "surface_variant/0.16", align = "stretch" }, children)
end

local function librarySection(mediaFilter, editorNode)
    local kind = if mediaFilter == "videos" then "video" elseif mediaFilter == "workshops" then "workshop" else "static"
    local configuration = settings()
    local page = if kind == "video"
        then libraryPageVideos
        elseif kind == "workshop" then libraryPageWorkshops
        else libraryPageStills
    local items, currentLibrary, total = panelUi.libraryItems(
        kind,
        (page - 1) * LIBRARY_PAGE_SIZE,
        LIBRARY_PAGE_SIZE
    )
    local pages = math.max(1, math.ceil(total / LIBRARY_PAGE_SIZE))
    if page > pages then
        page = pages
        items, currentLibrary, total = panelUi.libraryItems(
            kind,
            (page - 1) * LIBRARY_PAGE_SIZE,
            LIBRARY_PAGE_SIZE
        )
    end
    local countLabel = if kind == "video"
        then noctalia.tr("panel.library.videos", { count = tostring(total) })
        elseif kind == "workshop" then noctalia.tr("panel.library.workshops", { count = tostring(total) })
        else noctalia.tr("panel.library.stills", { count = tostring(total) })
    local children = {
        panelUi.sectionHeader(
            if kind == "static" then "photo" elseif kind == "video" then "movie" else "steam",
            countLabel,
            noctalia.tr("panel.library.pairing_browser_description")
        ),
        panelUi.mediumSettingsSection(kind),
        ui.row({ gap = 5, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.library.default_pairing_note"),
                fontSize = 9,
                color = "on_surface_variant",
                maxLines = 3,
                flexGrow = 1,
            }),
            ui.button({
                glyph = "refresh",
                tooltip = noctalia.tr("panel.library.refresh"),
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    resetLibraryVisibility()
                    send({ kind = "library_refresh" })
                end,
            }),
        }),
    }
    if editorNode ~= nil then
        table.insert(children, editorNode)
    end
    if total == 0 then
        local emptyText = if kind == "video"
            then noctalia.tr("panel.library.no_videos", {
                path = panelUi.valueOr(configuration.video_directory, "common.unset"),
            })
            elseif kind == "workshop" then noctalia.tr("panel.library.no_workshops")
            else noctalia.tr("panel.library.no_stills", {
                path = panelUi.valueOr(configuration.capture_directory, "common.unset"),
            })
        table.insert(children, ui.label({ text = emptyText, fontSize = 10, color = "on_surface_variant", maxLines = 3 }))
    else
        panelUi.appendLibraryGrid(children, items, #items)
        panelUi.appendPageControls(children, total, page, LIBRARY_PAGE_SIZE, function(value)
            if kind == "video" then
                libraryPageVideos = value
            elseif kind == "workshop" then
                libraryPageWorkshops = value
            else
                libraryPageStills = value
            end
        end)
    end
    if tostring(currentLibrary.error or "") ~= "" then
        table.insert(children, ui.label({
            text = tostring(currentLibrary.error),
            fontSize = 9,
            color = "error",
            maxLines = 3,
        }))
    end
    return panelUi.card(children)
end

-- Playlist, entry, and schedule editing.
local function playlistActionButton(action, glyph, label, playlistId, output, enabled, primary)
    return ui.button({
        text = label,
        glyph = glyph,
        variant = if primary == true then "primary" else "ghost",
        controlSize = "sm",
        enabled = enabled == true and storageValid() and output ~= "" and playlistId ~= "",
        flexGrow = 1,
        onClick = function()
            send({
                kind = "playlist_action",
                output = output,
                playlist_id = playlistId,
                action = action,
                manual_pin = true,
            })
        end,
    })
end

local function playlistEntryPreview(kind, stillPath, active)
    local path = tostring(stillPath or "")
    if path:sub(1, 1) == "/" and path:find("[%c]") == nil and noctalia.fileExists(path) then
        return ui.image({
            width = 58,
            height = 42,
            path = path,
            fit = "cover",
            radius = 7,
            border = if active then "primary" else "outline/0.35",
            borderWidth = if active then 2 else 1,
        })
    end
    return ui.row({
        width = 58,
        height = 42,
        radius = 7,
        fill = "surface_variant/0.55",
        border = if active then "primary" else "outline/0.35",
        borderWidth = if active then 2 else 1,
        align = "center",
        justify = "center",
    }, {
        ui.glyph({
            name = if kind == "still" then "photo" elseif kind == "video" then "player-play" else "movie",
            color = if active then "primary" else "on_surface_variant",
        }),
    })
end

function panelUi.playlistEntryVisualState(entry, output)
    local media = type(entry) == "table" and type(entry.media) == "table" and entry.media or nil
    local still = type(entry) == "table" and type(entry.still) == "table" and entry.still or {}
    if media == nil then
        local path = tostring(still.path or "")
        return path, path:sub(1, 1) == "/" and noctalia.fileExists(path)
    end
    local kind = tostring(media.kind or "")
    local source = tostring(media.source or "")
    local sourceAvailable = false
    local previewPath = if tostring(still.mode or "") == "selected" then tostring(still.path or "") else ""
    if kind == "video" then
        sourceAvailable = source:sub(1, 1) == "/" and noctalia.fileExists(source)
    elseif kind == "workshop" then
        local workshop = panelUi.workshopIndex()[source]
        if type(workshop) == "table" then
            sourceAvailable = true
            if previewPath == "" then
                previewPath = tostring(workshop.preview or "")
            end
        end
    end
    if previewPath == "" then
        previewPath = tostring(entryForOutput({ kind = kind, source = source }, output).still_path or "")
    end
    return previewPath, sourceAvailable
end

local function validSwatchColor(value)
    local color = tostring(value or "")
    return if color:match("^#%x%x%x%x%x%x$") ~= nil then color else nil
end

local function normalizedPreviewMode(preview, modeName)
    local mode = type(preview) == "table" and type(preview[modeName]) == "table" and preview[modeName] or nil
    local surface = type(mode) == "table" and validSwatchColor(mode.surface) or nil
    local accents = {}
    for index = 1, 4 do
        local color = type(mode) == "table" and type(mode.accents) == "table"
                and validSwatchColor(mode.accents[index])
            or nil
        if color ~= nil then
            table.insert(accents, color)
        end
    end
    if surface == nil or #accents ~= 4 then
        return nil
    end
    return { surface = surface, accents = accents }
end

local function palettePreviewForBundle(bundle, pairingId)
    local theme = type(bundle) == "table" and type(bundle.theme) == "table" and bundle.theme or {}
    local source = tostring(theme.source or "inherit")
    if source == "wallpaper" then
        return adaptivePreviewForBundle(bundle, pairingId)
    elseif source == "builtin" or source == "community" or source == "custom" then
        local entry = paletteInventoryEntry(source, theme.selection)
        local preview = type(entry) == "table" and type(entry.preview) == "table" and entry.preview or nil
        return preview, if preview ~= nil then "ready" else "unavailable", ""
    end
    return nil, "unavailable", ""
end

local function paletteModeSwatch(modeName, mode)
    local colors = {
        ui.box({ width = 28, height = 15, radius = 4, fill = mode.surface, border = "outline/0.4", borderWidth = 1 }),
    }
    for _, color in ipairs(mode.accents) do
        table.insert(colors, ui.box({ width = 15, height = 15, radius = 4, fill = color }))
    end
    return ui.row({ gap = 3, align = "center" }, {
        ui.label({
            text = if modeName == "dark"
                then noctalia.tr("panel.pairings.palette_preview_dark")
                else noctalia.tr("panel.pairings.palette_preview_light"),
            width = 76,
            fontSize = 8,
            color = "on_surface_variant",
            maxLines = 1,
        }),
        ui.row({ gap = 3, align = "center" }, colors),
    })
end

local function pairingPaletteSwatch(bundle, pairingId, onRefresh)
    local theme = type(bundle) == "table" and type(bundle.theme) == "table" and bundle.theme or {}
    local preview, state, errorMessage = palettePreviewForBundle(bundle, pairingId)
    local mode = tostring(theme.mode or "inherit")
    local dark = normalizedPreviewMode(preview, "dark")
    local light = normalizedPreviewMode(preview, "light")
    local children = {
        ui.row({ gap = 5, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.pairings.palette_preview"),
                fontSize = 9,
                fontWeight = "bold",
                flexGrow = 1,
            }),
            if type(onRefresh) == "function" and tostring(theme.source or "") == "wallpaper"
                then ui.button({
                    glyph = "refresh",
                    tooltip = noctalia.tr("panel.pairings.palette_preview_wallpaper"),
                    variant = "ghost",
                    controlSize = "sm",
                    enabled = storageValid(),
                    onClick = onRefresh,
                })
                else ui.spacer({ width = 1 }),
        }),
    }
    if state == "loading" then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.palette_preview_loading"),
            fontSize = 8,
            color = "on_surface_variant",
            maxLines = 2,
        }))
    elseif state == "error" then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.palette_preview_error", {
                error = if errorMessage ~= "" then errorMessage else noctalia.tr("common.unknown"),
            }),
            fontSize = 8,
            color = "error",
            maxLines = 3,
        }))
    elseif
        state ~= "ready"
        or (mode == "dark" and dark == nil)
        or (mode == "light" and light == nil)
        or (mode == "auto" and (dark == nil or light == nil))
    then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.palette_preview_unavailable"),
            fontSize = 8,
            color = "on_surface_variant",
            maxLines = 2,
        }))
    elseif mode == "auto" then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.palette_preview_auto"),
            fontSize = 8,
            color = "on_surface_variant",
        }))
        if dark ~= nil then
            table.insert(children, paletteModeSwatch("dark", dark))
        end
        if light ~= nil then
            table.insert(children, paletteModeSwatch("light", light))
        end
    elseif mode == "dark" and dark ~= nil then
        table.insert(children, paletteModeSwatch("dark", dark))
    elseif mode == "light" and light ~= nil then
        table.insert(children, paletteModeSwatch("light", light))
    else
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.palette_preview_unavailable"),
            fontSize = 8,
            color = "on_surface_variant",
        }))
    end
    return ui.column({
        gap = 3,
        padding = 6,
        radius = 7,
        fill = "surface_variant/0.25",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

-- A compact palette cue for library and playlist cards. Fixed palettes use
-- their real inventory preview; adaptive palettes use a cached item preview.
-- An unresolved adaptive preview stays neutral instead of implying that the
-- current desktop theme is the pairing's predicted palette. Merely rendering
-- a drawer never launches palette extraction work.
function panelUi.compactPaletteSwatch(bundle, pairingId)
    local preview = palettePreviewForBundle(bundle, pairingId)
    local colors = normalizedPreviewMode(preview, "dark") or normalizedPreviewMode(preview, "light")
    local boxes = {}
    if type(colors) == "table" then
        table.insert(boxes, ui.box({ width = 20, height = 13, radius = 3, fill = colors.surface }))
        for index = 1, 3 do
            table.insert(boxes, ui.box({ width = 13, height = 13, radius = 3, fill = colors.accents[index] }))
        end
    else
        table.insert(boxes, ui.glyph({ name = "palette", size = 14, color = "on_surface_variant" }))
    end
    local theme = type(bundle) == "table" and type(bundle.theme) == "table" and bundle.theme or {}
    return ui.row({ gap = 3, align = "center" }, {
        ui.row({ gap = 3, align = "center" }, boxes),
        ui.label({
            text = if tostring(theme.source or "") == "inherit"
                then noctalia.tr("panel.palettes.inherit")
                else panelUi.valueOr(theme.selection, "common.unknown"),
            fontSize = 8,
            color = "on_surface_variant",
            maxLines = 1,
            flexGrow = 1,
        }),
    })
end

local function pairingKindLabel(kind)
    if kind == "video" then
        return noctalia.tr("panel.playlists.entry.media_video")
    elseif kind == "workshop" then
        return noctalia.tr("panel.playlists.entry.media_workshop")
    end
    return noctalia.tr("panel.playlists.entry.media_still")
end

panelUi.pairingStillChoiceCache = {
    source = nil,
    sourceItems = {},
    items = {},
    cursor = 1,
    ready = true,
}

function panelUi.ensurePairingStillChoiceReconciliation()
    local currentLibrary = type(status) == "table" and type(status.library) == "table" and status.library or {}
    local choiceCache = panelUi.pairingStillChoiceCache
    if choiceCache.source ~= currentLibrary then
        choiceCache = {
            source = currentLibrary,
            sourceItems = type(currentLibrary.stills) == "table" and currentLibrary.stills or {},
            items = {},
            cursor = 1,
            ready = false,
        }
        panelUi.pairingStillChoiceCache = choiceCache
        wakeUpdate()
    end
    return choiceCache
end

function panelUi.pairingStillChoiceWork()
    return panelUi.ensurePairingStillChoiceReconciliation().ready ~= true
end

function panelUi.stepPairingStillChoiceReconciliation()
    local choiceCache = panelUi.ensurePairingStillChoiceReconciliation()
    if choiceCache.ready == true then
        return false
    end
    local sourceItems = choiceCache.sourceItems
    local first = choiceCache.cursor
    local last = math.min(#sourceItems, first + STILL_CHOICE_RECONCILE_BATCH - 1)
    for index = first, last do
        local entry = sourceItems[index]
        if type(entry) == "table" then
            local provider = tostring(entry.provider or "")
            local ownership = tostring(entry.ownership or "")
            local path = tostring(entry.path or "")
            if
                path:sub(1, 1) == "/"
                and path:find("[%c]") == nil
                and (ownership == "user" or provider == "local" or provider == "Wallhaven")
            then
                table.insert(choiceCache.items, entry)
            end
        end
    end
    choiceCache.cursor = last + 1
    if choiceCache.cursor > #sourceItems then
        choiceCache.ready = true
        choiceCache.sourceItems = {}
        return true
    end
    return false
end

function panelUi.pairingStillChoices(page, pageSize)
    local choiceCache = panelUi.ensurePairingStillChoiceReconciliation()
    if choiceCache.ready ~= true then
        return {}, 0, 1, false
    end
    local eligible = choiceCache.items
    local size = math.max(1, math.floor(tonumber(pageSize) or 6))
    local pages = math.max(1, math.ceil(#eligible / size))
    local current = math.min(pages, math.max(1, math.floor(tonumber(page) or 1)))
    local first = (current - 1) * size + 1
    local choices = {}
    for index = first, math.min(#eligible, first + size - 1) do
        table.insert(choices, eligible[index])
    end
    return choices, #eligible, current, true
end

local function pairingEditor(kind, entryContext)
    local editingPlaylistEntry = type(entryContext) == "table"
    local draftId = if editingPlaylistEntry then editingPlaylistEntryId else editingPairingId
    local previewPairingId = if editingPlaylistEntry then editingPlaylistEntryPairingId else editingPairingId
    local function currentBundle()
        local bundle = bundleFromDraft(draftId)
        if editingPlaylistEntry and editingPlaylistEntryPairingId ~= "" then
            bundle.pairing_id = editingPlaylistEntryPairingId
        end
        return bundle
    end
    local dynamic = kind ~= "static"
    local revision = tostring(pairingEditorRevision)
    local source = noctalia.string.trim(entryMediaSourceDraft)
    local sourceValid = source:find("[%c]") == nil
        and if kind == "workshop" then source:match("^%d+$") ~= nil else source:sub(1, 1) == "/"
    local stillPath = noctalia.string.trim(entryStillPathDraft)
    local stillValid = not dynamic
        or entryStillModeDraft == "automatic"
        or (stillPath:sub(1, 1) == "/" and stillPath:find("[%c]") == nil)
    local label = noctalia.string.trim(entryLabelDraft)
    if label == "" then
        label = basename(source)
    end
    local labelValid = label ~= "" and label:find("[%c]") == nil
    local automaticStillReady = dynamic and automaticRepresentativePath(kind, source) ~= ""

    local themeModeValues = { "inherit", "auto", "dark", "light" }
    local themeModeLabels = {
        noctalia.tr("panel.palettes.mode_keep"),
        noctalia.tr("panel.palettes.mode_auto"),
        noctalia.tr("panel.palettes.mode_dark"),
        noctalia.tr("panel.palettes.mode_light"),
    }
    local themeModeIndex = if entryThemeModeDraft == "auto"
        then 1
        elseif entryThemeModeDraft == "dark" then 2
        elseif entryThemeModeDraft == "light" then 3
        else 0
    local themeSourceValues = { "inherit", "wallpaper", "builtin", "community", "custom" }
    local themeSourceLabels = {
        noctalia.tr("panel.palettes.inherit"),
        noctalia.tr("panel.palettes.wallpaper"),
        noctalia.tr("panel.palettes.builtin"),
        noctalia.tr("panel.palettes.community"),
        noctalia.tr("panel.palettes.custom"),
    }
    local themeSourceIndex = if entryThemeSourceDraft == "wallpaper"
        then 1
        elseif entryThemeSourceDraft == "builtin" then 2
        elseif entryThemeSourceDraft == "community" then 3
        elseif entryThemeSourceDraft == "custom" then 4
        else 0
    local selectionNames = {}
    local selectionNamesReady = true
    local selectionNameIndex = {}
    if entryThemeSourceDraft ~= "inherit" then
        selectionNames, selectionNamesReady, selectionNameIndex = paletteNames(entryThemeSourceDraft)
    end
    local paletteStatus = paletteInventory()
    local selectedPalettePosition = selectionNameIndex[entryThemeSelectionDraft]
    local selectionIndex = if selectedPalettePosition ~= nil then selectedPalettePosition - 1 else 0
    local selectionFound = selectedPalettePosition ~= nil

    local children = {
        ui.row({ gap = 7, align = "center" }, {
            ui.glyph({
                name = if kind == "static" then "photo" elseif kind == "video" then "movie" else "steam",
                color = "primary",
            }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({
                    text = if editingPlaylistEntry
                        then noctalia.tr("panel.playlists.entry.edit_title")
                        else noctalia.tr("panel.pairings.edit"),
                    fontSize = 12,
                    fontWeight = "bold",
                }),
                ui.label({ text = pairingKindLabel(kind), fontSize = 9, color = "on_surface_variant" }),
            }),
        }),
        ui.input({
            key = "pairing-label-" .. revision,
            value = entryLabelDraft,
            placeholder = noctalia.tr("panel.playlists.entry.label_placeholder"),
            onChange = function(value)
                entryLabelDraft = tostring(value or "")
                render()
            end,
        }),
        ui.column({ gap = 2, padding = 7, radius = 7, fill = "surface_variant/0.2" }, {
            ui.label({
                text = if editingPlaylistEntry
                    then noctalia.tr("panel.playlists.entry.selected_source")
                    else noctalia.tr("panel.pairings.source_locked"),
                fontSize = 8,
                color = "on_surface_variant",
            }),
            ui.label({ text = source, fontSize = 9, maxLines = 2 }),
        }),
    }
    if dynamic then
        table.insert(children, ui.select({
            key = "pairing-still-mode-" .. revision,
            options = {
                noctalia.tr("panel.playlists.entry.still_automatic"),
                noctalia.tr("panel.playlists.entry.still_selected"),
            },
            selectedIndex = if entryStillModeDraft == "selected" then 1 else 0,
            onChange = function(index)
                entryStillModeDraft = if math.floor(tonumber(index) or 0) == 1 then "selected" else "automatic"
                local requestedPalette = requestPairingAdaptivePreview(
                    currentBundle(),
                    previewPairingId
                )
                if entryStillModeDraft == "automatic" and not requestedPalette then
                    requestAutomaticStillPreparation(kind, source)
                end
                render()
            end,
        }))
        if entryStillModeDraft == "selected" then
            local stillChoices, stillChoiceCount, stillChoicePage, stillChoicesReady = panelUi.pairingStillChoices(
                pairingStillPickerPage,
                6
            )
            table.insert(children, ui.label({
                text = noctalia.tr("panel.pairings.still_library"),
                fontSize = 10,
                fontWeight = "bold",
            }))
            if not stillChoicesReady then
                table.insert(children, ui.label({
                    text = noctalia.tr("panel.pairings.still_library_loading"),
                    fontSize = 9,
                    color = "on_surface_variant",
                    maxLines = 2,
                }))
            elseif #stillChoices == 0 then
                table.insert(children, ui.label({
                    text = noctalia.tr("panel.pairings.still_library_empty"),
                    fontSize = 9,
                    color = "on_surface_variant",
                    maxLines = 2,
                }))
            else
                panelUi.appendExplicitGrid(children, stillChoices, #stillChoices, 3, function(choice)
                    local choicePath = tostring(choice.path or "")
                    local selectedChoice = choicePath == stillPath
                    return ui.column({
                        key = "pairing-still-choice-" .. tostring(choice.id or choicePath),
                        width = 178,
                        gap = 4,
                        padding = 6,
                        radius = 8,
                        fill = "surface_variant/0.24",
                        border = if selectedChoice then "primary/0.7" else "outline/0.25",
                        borderWidth = if selectedChoice then 2 else 1,
                        align = "stretch",
                    }, {
                        ui.image({
                            width = 164,
                            height = 92,
                            path = choicePath,
                            fit = "cover",
                            radius = 7,
                        }),
                        ui.label({
                            text = tostring(choice.name or basename(choicePath)),
                            fontSize = 9,
                            fontWeight = "bold",
                            maxWidth = 164,
                            maxLines = 1,
                        }),
                        ui.button({
                            text = if selectedChoice
                                then noctalia.tr("panel.pairings.still_selected")
                                else noctalia.tr("panel.pairings.still_use"),
                            glyph = if selectedChoice then "check" else "photo",
                            variant = if selectedChoice then "primary" else "ghost",
                            controlSize = "sm",
                            enabled = not selectedChoice,
                            onClick = function()
                                entryStillPathDraft = choicePath
                                pairingManualStillOpen = false
                                requestPairingAdaptivePreview(currentBundle(), previewPairingId)
                                render()
                            end,
                        }),
                    })
                end)
                panelUi.appendPageControls(children, stillChoiceCount, stillChoicePage, 6, function(value)
                    pairingStillPickerPage = value
                end)
            end
            table.insert(children, ui.row({ gap = 6, align = "center" }, {
                ui.label({
                    text = if stillPath == ""
                        then noctalia.tr("panel.pairings.still_none")
                        else noctalia.tr("panel.pairings.still_current", { name = basename(stillPath) }),
                    fontSize = 9,
                    color = "on_surface_variant",
                    flexGrow = 1,
                    maxLines = 1,
                }),
                ui.button({
                    text = if pairingManualStillOpen
                        then noctalia.tr("panel.pairings.still_manual_hide")
                        else noctalia.tr("panel.pairings.still_manual_show"),
                    glyph = "terminal-2",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        pairingManualStillOpen = not pairingManualStillOpen
                        render()
                    end,
                }),
            }))
            if pairingManualStillOpen then
                table.insert(children, ui.row({ gap = 6, align = "center" }, {
                    ui.input({
                        key = "pairing-still-path-" .. revision,
                        value = entryStillPathDraft,
                        placeholder = noctalia.tr("panel.playlists.entry.still_path_placeholder"),
                        flexGrow = 1,
                        onChange = function(value)
                            entryStillPathDraft = tostring(value or "")
                        end,
                        onSubmit = function(value)
                            entryStillPathDraft = tostring(value or "")
                            requestPairingAdaptivePreview(currentBundle(), previewPairingId)
                            render()
                        end,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.pairings.still_manual_use"),
                        glyph = "check",
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = function()
                            requestPairingAdaptivePreview(currentBundle(), previewPairingId)
                            render()
                        end,
                    }),
                }))
            end
        else
            local captures = type(status) == "table" and type(status.captures) == "table" and status.captures or {}
            local preparing = type(captures["pairing-preview"]) == "table"
            table.insert(children, ui.label({
                text = if preparing
                    then noctalia.tr("panel.pairings.still_preparing")
                    elseif automaticStillReady then noctalia.tr("panel.pairings.still_automatic_ready")
                    else noctalia.tr("panel.pairings.still_automatic_pending"),
                fontSize = 9,
                color = if preparing then "primary" else "on_surface_variant",
                maxLines = 2,
            }))
        end
    end
    table.insert(children, ui.separator())
    table.insert(children, ui.label({
        text = noctalia.tr("panel.palettes.title"),
        fontSize = 11,
        fontWeight = "bold",
    }))
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
        ui.select({
            key = "pairing-theme-mode-" .. revision,
            options = themeModeLabels,
            selectedIndex = themeModeIndex,
            flexGrow = 1,
            onChange = function(index)
                entryThemeModeDraft = themeModeValues[math.floor(tonumber(index) or 0) + 1] or "inherit"
                if entryThemeModeDraft == "inherit" then
                    entryThemeSourceDraft = "inherit"
                    entryThemeSelectionDraft = ""
                elseif entryThemeSourceDraft == "inherit" then
                    entryThemeSourceDraft = "wallpaper"
                    entryThemeSelectionDraft = paletteNames("wallpaper")[1] or "m3-tonal-spot"
                end
                requestPairingAdaptivePreview(currentBundle(), previewPairingId)
                render()
            end,
        }),
        ui.select({
            key = "pairing-theme-source-" .. revision,
            options = themeSourceLabels,
            selectedIndex = themeSourceIndex,
            flexGrow = 1,
            onChange = function(index)
                entryThemeSourceDraft = themeSourceValues[math.floor(tonumber(index) or 0) + 1] or "inherit"
                if entryThemeSourceDraft == "inherit" then
                    entryThemeModeDraft = "inherit"
                    entryThemeSelectionDraft = ""
                else
                    if entryThemeModeDraft == "inherit" then
                        entryThemeModeDraft = "auto"
                    end
                    local nextNames, nextNamesReady = paletteNames(entryThemeSourceDraft)
                    entryThemeSelectionDraft = if nextNamesReady then nextNames[1] or "" else ""
                end
                requestPairingAdaptivePreview(currentBundle(), previewPairingId)
                render()
            end,
        }),
    }))
    if entryThemeSourceDraft ~= "inherit" then
        local selectionOptions = if not selectionNamesReady
            then { noctalia.tr("panel.palettes.loading") }
            elseif #selectionNames > 0
            then selectionNames
            else { noctalia.tr("panel.palettes.no_results") }
        table.insert(children, ui.select({
            key = "pairing-theme-selection-" .. revision,
            options = selectionOptions,
            selectedIndex = selectionIndex,
            enabled = selectionNamesReady and #selectionNames > 0,
            onChange = function(index)
                local name = selectionNames[math.floor(tonumber(index) or 0) + 1]
                if name ~= nil then
                    entryThemeSelectionDraft = tostring(name)
                    requestPairingAdaptivePreview(currentBundle(), previewPairingId)
                    render()
                end
            end,
        }))
        if
            paletteStatus.ready == true
            and selectionNamesReady
            and entryThemeSelectionDraft ~= ""
            and not selectionFound
        then
            table.insert(children, ui.label({
                text = noctalia.tr("panel.palettes.missing"),
                fontSize = 9,
                color = "error",
                maxLines = 2,
            }))
        end
    end
    table.insert(children, pairingPaletteSwatch(
        currentBundle(),
        previewPairingId,
        function()
            retryPairingAdaptivePreview(currentBundle(), previewPairingId)
            render()
        end
    ))
    table.insert(children, ui.label({
        text = if editingPlaylistEntry
            then noctalia.tr("panel.playlists.entry.editor_notice")
            else noctalia.tr("panel.pairings.snapshot_notice"),
        fontSize = 9,
        color = "on_surface_variant",
        maxLines = 3,
    }))
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
        ui.button({
            text = if editingPlaylistEntry
                then noctalia.tr("panel.playlists.entry.edit_save")
                else noctalia.tr("panel.pairings.save"),
            glyph = "device-floppy",
            variant = "primary",
            controlSize = "sm",
            enabled = storageValid()
                and labelValid
                and sourceValid
                and stillValid
                and (entryThemeSourceDraft == "inherit"
                    or noctalia.string.trim(entryThemeSelectionDraft) ~= ""),
            flexGrow = 1,
            onClick = function()
                if editingPlaylistEntry then
                    send({
                        kind = "playlist_replace_entry",
                        playlist_id = editingPlaylistEntryPlaylistId,
                        entry_id = editingPlaylistEntryId,
                        entry = currentBundle(),
                    })
                    closePlaylistEntryEditor()
                else
                    send({ kind = "pairing_save", pairing = currentBundle() })
                    closePairingEditor()
                end
                render()
            end,
        }),
        ui.button({
            text = noctalia.tr("panel.pairings.cancel"),
            glyph = "x",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                if editingPlaylistEntry then
                    closePlaylistEntryEditor()
                else
                    closePairingEditor()
                end
                render()
            end,
        }),
    }))
    return ui.column({
        key = (if editingPlaylistEntry then "playlist-entry-editor-" else "pairing-editor-")
            .. kind
            .. "-"
            .. revision,
        gap = 7,
        padding = 10,
        radius = 10,
        fill = "primary/0.06",
        border = "primary/0.35",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

-- Playlists consume one visual view of the indexed library. A card is the
-- media item and its defaults/override together; there is no second catalog
-- that the user has to populate or clean up.
function panelUi.playlistPairingLibrary(playlistId, output)
    local items = {}
    local total = 0
    local offset = (playlistLibraryPage - 1) * LIBRARY_PAGE_SIZE
    local remaining = LIBRARY_PAGE_SIZE
    for _, kind in ipairs({ "static", "video", "workshop" }) do
        if playlistLibraryFilter == "all" or playlistLibraryFilter == kind then
            local _, _, kindTotal = panelUi.libraryItems(kind, 0, 0)
            local kindOffset = math.min(kindTotal, offset)
            local take = math.min(remaining, math.max(0, kindTotal - kindOffset))
            local kindItems = panelUi.libraryItems(kind, kindOffset, take)
            for _, item in ipairs(kindItems) do
                item.kind = kind
                table.insert(items, item)
            end
            total += kindTotal
            offset = math.max(0, offset - kindTotal)
            remaining = math.max(0, LIBRARY_PAGE_SIZE - #items)
        end
    end
    local pages = math.max(1, math.ceil(total / LIBRARY_PAGE_SIZE))
    if playlistLibraryPage > pages then
        playlistLibraryPage = pages
        return panelUi.playlistPairingLibrary(playlistId, output)
    end
    local children = {
        ui.row({ gap = 5, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.pairings.library_title"),
                fontSize = 12,
                fontWeight = "bold",
                flexGrow = 1,
            }),
            ui.button({
                glyph = "refresh",
                tooltip = noctalia.tr("panel.library.refresh"),
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    playlistLibraryPage = 1
                    send({ kind = "library_refresh" })
                end,
            }),
        }),
        ui.label({
            text = noctalia.tr("panel.pairings.drag_hint"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 3,
        }),
    }
    local filterButtons = {}
    for _, filter in ipairs({
        { id = "all", label = "panel.pairings.filter_all" },
        { id = "static", label = "panel.nav.library_images" },
        { id = "video", label = "panel.nav.library_videos" },
        { id = "workshop", label = "panel.nav.library_engine" },
    }) do
        local filterId = filter.id
        table.insert(filterButtons, ui.button({
            text = noctalia.tr(filter.label),
            variant = if playlistLibraryFilter == filterId then "primary" else "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                playlistLibraryFilter = filterId
                playlistLibraryPage = 1
                render()
            end,
        }))
    end
    table.insert(children, ui.row({ gap = 5, align = "center" }, filterButtons))
    if total == 0 then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.library_empty"),
            fontSize = 9,
            color = "on_surface_variant",
        }))
    else
        panelUi.appendExplicitGrid(children, items, #items, PLAYLIST_LIBRARY_COLUMNS, function(item)
            local kind = tostring(type(item) == "table" and item.kind or "static")
            local entry = type(item) == "table" and item.entry or {}
            local metadata = type(item) == "table" and item.metadata or {}
            local existing = type(item) == "table" and item.pairing or nil
            local customized = type(existing) == "table" and existing.customized == true
            local bundle = panelUi.virtualLibraryPairing(entry, metadata, if customized then existing else nil)
            local pairingId = if customized then tostring(existing.id or "") else ""
            local source = tostring(entry.source or "")
            local signature = panelUi.libraryDragSignature(entry)
            local dragToken = dragLibraryPairingTokenBySignature[signature]
            if dragToken == nil then
                dragToken = nextDragToken("l")
                dragLibraryPairingTokenBySignature[signature] = dragToken
            end
            dragLibraryPairingByToken[dragToken] = {
                library_entry = entry,
                library_bundle = bundle,
                pairing_id = pairingId,
            }
            local canAdd = storageValid() and playlistId ~= ""
            return ui.column({
                key = "playlist-library-card-" .. dragToken,
                width = 232,
                gap = 5,
                padding = 8,
                radius = 10,
                fill = "surface_variant/0.2",
                border = if customized then "primary/0.4" else "outline/0.25",
                borderWidth = 1,
                align = "stretch",
            }, {
                panelUi.libraryThumbnail(
                    kind,
                    panelUi.libraryPreviewPath(entry, metadata, bundle, output),
                    customized
                ),
                ui.label({
                    text = tostring(entry.label or basename(source)),
                    fontSize = 10,
                    fontWeight = "bold",
                    maxLines = 1,
                }),
                ui.label({
                    text = pairingKindLabel(kind) .. " · " .. source,
                    fontSize = 8,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
                panelUi.compactPaletteSwatch(bundle, pairingId),
                ui.row({ gap = 4, align = "center", justify = "end" }, {
                    ui.dragSource({
                        key = "library-grip-" .. dragToken,
                        dragType = "wio-library-item",
                        payload = dragToken,
                        enabled = canAdd,
                        previewAncestor = 2,
                        liftFromLayout = true,
                        width = 28,
                        height = 28,
                        align = "center",
                        justify = "center",
                        tooltip = noctalia.tr("panel.pairings.drag"),
                    }, {
                        ui.glyph({ name = "menu-2", size = 15, color = "on_surface_variant" }),
                    }),
                    ui.button({
                        glyph = "edit",
                        tooltip = noctalia.tr("panel.pairings.edit"),
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = function()
                            openLibraryEntryPairing(entry, metadata)
                        end,
                    }),
                    ui.button({
                        glyph = "playlist-add",
                        tooltip = noctalia.tr("panel.pairings.add"),
                        variant = "primary",
                        controlSize = "sm",
                        enabled = canAdd,
                        onClick = function()
                            if pairingId ~= "" then
                                send({
                                    kind = "playlist_add_pairing",
                                    output = output,
                                    playlist_id = playlistId,
                                    pairing_id = pairingId,
                                })
                            else
                                send({
                                    kind = "playlist_add_entry",
                                    output = output,
                                    playlist_id = playlistId,
                                    entry = entryForOutput(bundle, output),
                                })
                            end
                        end,
                    }),
                }),
            })
        end)
        panelUi.appendPageControls(
            children,
            total,
            playlistLibraryPage,
            LIBRARY_PAGE_SIZE,
            function(value)
                playlistLibraryPage = value
            end
        )
    end
    return ui.column({
        key = "playlist-pairing-library-" .. playlistLibraryFilter,
        gap = 7,
        padding = 9,
        radius = 10,
        fill = "surface_variant/0.1",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

function panelUi.selectPlaylistEntrySource(item)
    local entry = type(item) == "table" and item.entry or {}
    local metadata = type(item) == "table" and item.metadata or {}
    local existing = type(item) == "table" and item.pairing or nil
    local kind = tostring(type(item) == "table" and item.kind or entry.kind or "static")
    kind = if kind == "video" or kind == "workshop" then kind else "static"
    local customized = type(existing) == "table" and existing.customized == true
    local bundle = panelUi.virtualLibraryPairing(entry, metadata, if customized then existing else nil)
    local preservedAddedAt = entryAddedAtDraft
    loadBundleDraft(bundle, kind)
    entryAddedAtDraft = preservedAddedAt
    entryMediaKindDraft = kind
    editingPlaylistEntryPairingId = type(existing) == "table" and tostring(existing.id or "") or ""
    pairingStillPickerPage = 1
    pairingManualStillOpen = false
    pairingEditorRevision += 1
    clearAutomaticStillPreparation(kind, entryMediaSourceDraft)
    local requestedPalette = requestPairingAdaptivePreview(
        bundleFromDraft(editingPlaylistEntryId),
        editingPlaylistEntryPairingId
    )
    if not requestedPalette then
        requestAutomaticStillPreparation(kind, noctalia.string.trim(entryMediaSourceDraft))
    end
    render()
end

function panelUi.playlistEntrySourcePicker(output)
    local kind = playlistEntrySourceKind
    local offset = (playlistEntrySourcePage - 1) * ENTRY_SOURCE_PAGE_SIZE
    local items = {}
    local total = 0
    local sourceReady = true
    if kind == "static" then
        local choices, choiceCount, choicePage, choicesReady = panelUi.pairingStillChoices(
            playlistEntrySourcePage,
            ENTRY_SOURCE_PAGE_SIZE
        )
        total = choiceCount
        sourceReady = choicesReady
        playlistEntrySourcePage = choicePage
        local currentLibrary = type(status) == "table" and type(status.library) == "table" and status.library or {}
        for _, sourceItem in ipairs(choices) do
            local entry = {
                kind = "static",
                source = tostring(sourceItem.path or ""),
                label = tostring(sourceItem.name or basename(sourceItem.path)),
                added_at = tostring(currentLibrary.scanned_at or ""),
            }
            table.insert(items, {
                entry = entry,
                metadata = sourceItem,
                pairing = matchingPairingForLibraryEntry(entry),
            })
        end
    else
        local pageItems, _library, kindTotal = panelUi.libraryItems(kind, offset, ENTRY_SOURCE_PAGE_SIZE)
        items = pageItems
        total = kindTotal
    end
    local pages = math.max(1, math.ceil(total / ENTRY_SOURCE_PAGE_SIZE))
    if playlistEntrySourcePage > pages then
        playlistEntrySourcePage = pages
        return panelUi.playlistEntrySourcePicker(output)
    end
    local currentSource = noctalia.string.trim(entryMediaSourceDraft)
    local children = {
        ui.label({
            text = noctalia.tr("panel.playlists.entry.source_picker_title"),
            fontSize = 11,
            fontWeight = "bold",
        }),
        ui.label({
            text = noctalia.tr("panel.playlists.entry.source_picker_description"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 2,
        }),
    }
    local kindButtons = {}
    for _, option in ipairs({
        { id = "static", label = "panel.nav.library_images" },
        { id = "video", label = "panel.nav.library_videos" },
        { id = "workshop", label = "panel.nav.library_engine" },
    }) do
        local optionId = option.id
        table.insert(kindButtons, ui.button({
            text = noctalia.tr(option.label),
            variant = if kind == optionId then "primary" else "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                playlistEntrySourceKind = optionId
                playlistEntrySourcePage = 1
                render()
            end,
        }))
    end
    table.insert(children, ui.row({ gap = 5, align = "center" }, kindButtons))
    if not sourceReady then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.still_library_loading"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 2,
        }))
    elseif total == 0 then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.playlists.entry.source_picker_empty"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 2,
        }))
    else
        panelUi.appendExplicitGrid(children, items, #items, PLAYLIST_LIBRARY_COLUMNS, function(item)
            item.kind = kind
            local entry = type(item.entry) == "table" and item.entry or {}
            local metadata = type(item.metadata) == "table" and item.metadata or {}
            local existing = type(item.pairing) == "table" and item.pairing or nil
            local customized = type(existing) == "table" and existing.customized == true
            local bundle = panelUi.virtualLibraryPairing(entry, metadata, if customized then existing else nil)
            local source = tostring(entry.source or "")
            local selected = entryMediaKindDraft == kind and currentSource == source
            local cardKey = tostring(metadata.id or source)
            return ui.column({
                key = "playlist-entry-source-" .. kind .. "-" .. cardKey,
                width = 232,
                gap = 5,
                padding = 8,
                radius = 10,
                fill = "surface_variant/0.2",
                border = if selected then "primary/0.7" else "outline/0.25",
                borderWidth = if selected then 2 else 1,
                align = "stretch",
            }, {
                panelUi.libraryThumbnail(
                    kind,
                    panelUi.libraryPreviewPath(entry, metadata, bundle, output),
                    customized
                ),
                ui.label({
                    text = tostring(entry.label or basename(source)),
                    fontSize = 10,
                    fontWeight = "bold",
                    maxLines = 1,
                }),
                panelUi.compactPaletteSwatch(bundle, type(existing) == "table" and tostring(existing.id or "") or ""),
                ui.button({
                    text = if selected
                        then noctalia.tr("panel.playlists.entry.source_selected")
                        else noctalia.tr("panel.playlists.entry.source_use"),
                    glyph = if selected then "check" else "chevron-right",
                    variant = if selected then "primary" else "ghost",
                    controlSize = "sm",
                    enabled = not selected,
                    onClick = function()
                        panelUi.selectPlaylistEntrySource(item)
                    end,
                }),
            })
        end)
        panelUi.appendPageControls(
            children,
            total,
            playlistEntrySourcePage,
            ENTRY_SOURCE_PAGE_SIZE,
            function(value)
                playlistEntrySourcePage = value
            end
        )
    end
    return ui.column({
        gap = 7,
        padding = 8,
        radius = 9,
        fill = "surface_variant/0.12",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

function panelUi.playlistEntryEditor(playlistId, output)
    return ui.column({
        key = "playlist-entry-editor-shell-" .. editingPlaylistEntryId,
        gap = 8,
        padding = 8,
        radius = 10,
        fill = "primary/0.035",
        border = "primary/0.35",
        borderWidth = 1,
        align = "stretch",
    }, {
        panelUi.playlistEntrySourcePicker(output),
        pairingEditor(entryMediaKindDraft, { playlist_id = playlistId }),
    })
end

local function playlistInsertionZone(playlistId, beforeId)
    local playlistTokens = dragTargetTokenByPlaylist[playlistId]
    local token = type(playlistTokens) == "table" and playlistTokens[tostring(beforeId or "")] or nil
    if token == nil then
        return ui.box({ height = 3 })
    end
    return ui.dropZone({
        key = "playlist-gap-" .. token,
        accepts = { "wio-library-item", "wio-entry" },
        value = token,
        onDrop = "onPlaylistDrop",
        direction = "row",
        enabled = storageValid() and playlistId ~= "",
        height = 3,
        radius = 2,
        fill = "primary/0.28",
        expandOnDrag = true,
        hitSlop = 28,
    })
end

local function scheduleSelectionSummary(schedule)
    local dayNames = {
        noctalia.tr("panel.schedules.day_sun"),
        noctalia.tr("panel.schedules.day_mon"),
        noctalia.tr("panel.schedules.day_tue"),
        noctalia.tr("panel.schedules.day_wed"),
        noctalia.tr("panel.schedules.day_thu"),
        noctalia.tr("panel.schedules.day_fri"),
        noctalia.tr("panel.schedules.day_sat"),
    }
    local monthNames = {
        noctalia.tr("panel.schedules.month_jan"),
        noctalia.tr("panel.schedules.month_feb"),
        noctalia.tr("panel.schedules.month_mar"),
        noctalia.tr("panel.schedules.month_apr"),
        noctalia.tr("panel.schedules.month_may"),
        noctalia.tr("panel.schedules.month_jun"),
        noctalia.tr("panel.schedules.month_jul"),
        noctalia.tr("panel.schedules.month_aug"),
        noctalia.tr("panel.schedules.month_sep"),
        noctalia.tr("panel.schedules.month_oct"),
        noctalia.tr("panel.schedules.month_nov"),
        noctalia.tr("panel.schedules.month_dec"),
    }
    local selectedDays = {}
    local selectedMonths = {}
    local seenDays = {}
    local seenMonths = {}
    for _, value in ipairs(type(schedule.weekdays) == "table" and schedule.weekdays or {}) do
        local day = math.floor(tonumber(value) or -1)
        if day >= 0 and day <= 6 and not seenDays[day] then
            seenDays[day] = true
            table.insert(selectedDays, dayNames[day + 1])
        end
    end
    for _, value in ipairs(type(schedule.months) == "table" and schedule.months or {}) do
        local month = math.floor(tonumber(value) or -1)
        if month >= 1 and month <= 12 and not seenMonths[month] then
            seenMonths[month] = true
            table.insert(selectedMonths, monthNames[month])
        end
    end
    local months = if #selectedMonths == 0 or #selectedMonths == 12
        then noctalia.tr("panel.schedules.all_months")
        else table.concat(selectedMonths, ", ")
    return months, if #selectedDays > 0 then table.concat(selectedDays, ", ") else "—"
end

local function scheduleEditor(output, playlistId)
    local labels, ids, selectedIndex = playlistOptions(schedulePlaylistDraft)
    local days = {
        noctalia.tr("panel.schedules.day_sun"),
        noctalia.tr("panel.schedules.day_mon"),
        noctalia.tr("panel.schedules.day_tue"),
        noctalia.tr("panel.schedules.day_wed"),
        noctalia.tr("panel.schedules.day_thu"),
        noctalia.tr("panel.schedules.day_fri"),
        noctalia.tr("panel.schedules.day_sat"),
    }
    local firstWeekdays = {}
    local secondWeekdays = {}
    for index, name in ipairs(days) do
        local dayIndex = index
        local button = ui.button({
            text = name,
            variant = if scheduleWeekdaysDraft[index] then "primary" else "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                scheduleWeekdaysDraft[dayIndex] = not scheduleWeekdaysDraft[dayIndex]
                render()
            end,
        })
        table.insert(if index <= 4 then firstWeekdays else secondWeekdays, button)
    end
    local months = {
        noctalia.tr("panel.schedules.month_jan"),
        noctalia.tr("panel.schedules.month_feb"),
        noctalia.tr("panel.schedules.month_mar"),
        noctalia.tr("panel.schedules.month_apr"),
        noctalia.tr("panel.schedules.month_may"),
        noctalia.tr("panel.schedules.month_jun"),
        noctalia.tr("panel.schedules.month_jul"),
        noctalia.tr("panel.schedules.month_aug"),
        noctalia.tr("panel.schedules.month_sep"),
        noctalia.tr("panel.schedules.month_oct"),
        noctalia.tr("panel.schedules.month_nov"),
        noctalia.tr("panel.schedules.month_dec"),
    }
    local firstMonthRow = {}
    local secondMonthRow = {}
    local thirdMonthRow = {}
    local allMonthsSelected = true
    for index, name in ipairs(months) do
        local monthIndex = index
        if scheduleMonthsDraft[index] ~= true then
            allMonthsSelected = false
        end
        local button = ui.button({
            text = name,
            variant = if scheduleMonthsDraft[index] then "primary" else "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                scheduleMonthsDraft[monthIndex] = not scheduleMonthsDraft[monthIndex]
                render()
            end,
        })
        if index <= 4 then
            table.insert(firstMonthRow, button)
        elseif index <= 8 then
            table.insert(secondMonthRow, button)
        else
            table.insert(thirdMonthRow, button)
        end
    end
    local children = {
        ui.label({
            text = if editingScheduleId == ""
                then noctalia.tr("panel.schedules.new_title")
                else noctalia.tr("panel.schedules.edit_title"),
            fontSize = 11,
            fontWeight = "bold",
        }),
        ui.input({
            key = "schedule-name-" .. output .. "-" .. editingScheduleId,
            value = scheduleNameDraft,
            placeholder = noctalia.tr("panel.schedules.name_placeholder"),
            onChange = function(value)
                scheduleNameDraft = tostring(value or "")
                render()
            end,
        }),
        ui.select({
            key = "schedule-playlist-" .. output .. "-" .. editingScheduleId,
            options = labels,
            selectedIndex = selectedIndex,
            enabled = #ids > 0,
            onChange = function(index)
                schedulePlaylistDraft = ids[math.floor(tonumber(index) or 0) + 1] or playlistId
                render()
            end,
        }),
        ui.label({
            text = noctalia.tr("panel.schedules.weekdays"),
            fontSize = 9,
            color = "on_surface_variant",
        }),
        ui.row({ gap = 5, align = "center" }, firstWeekdays),
        ui.row({ gap = 5, align = "center" }, secondWeekdays),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.schedules.months"),
                fontSize = 9,
                color = "on_surface_variant",
                flexGrow = 1,
            }),
            ui.button({
                text = noctalia.tr("panel.schedules.all_months"),
                glyph = "calendar",
                variant = if allMonthsSelected then "primary" else "ghost",
                controlSize = "sm",
                onClick = function()
                    scheduleMonthsDraft = { true, true, true, true, true, true, true, true, true, true, true, true }
                    render()
                end,
            }),
        }),
        ui.row({ gap = 5, align = "center" }, firstMonthRow),
        ui.row({ gap = 5, align = "center" }, secondMonthRow),
        ui.row({ gap = 5, align = "center" }, thirdMonthRow),
        ui.row({ gap = 6, align = "center" }, {
            ui.button({
                text = if scheduleEnabledDraft
                    then noctalia.tr("panel.schedules.enabled")
                    else noctalia.tr("panel.schedules.disabled"),
                glyph = if scheduleEnabledDraft then "check" else "x",
                variant = if scheduleEnabledDraft then "primary" else "ghost",
                controlSize = "sm",
                flexGrow = 1,
                onClick = function()
                    scheduleEnabledDraft = not scheduleEnabledDraft
                    render()
                end,
            }),
            ui.button({
                text = if scheduleAllDayDraft
                    then noctalia.tr("panel.schedules.all_day")
                    else noctalia.tr("panel.schedules.time_window"),
                glyph = "clock",
                variant = if scheduleAllDayDraft then "primary" else "ghost",
                controlSize = "sm",
                flexGrow = 1,
                onClick = function()
                    scheduleAllDayDraft = not scheduleAllDayDraft
                    render()
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "schedule-start-" .. output .. "-" .. editingScheduleId,
                value = scheduleStartDraft,
                placeholder = "08:00",
                enabled = not scheduleAllDayDraft,
                flexGrow = 1,
                onChange = function(value)
                    scheduleStartDraft = tostring(value or "")
                end,
            }),
            ui.label({ text = noctalia.tr("panel.schedules.to"), color = "on_surface_variant" }),
            ui.input({
                key = "schedule-end-" .. output .. "-" .. editingScheduleId,
                value = scheduleEndDraft,
                placeholder = "18:00",
                enabled = not scheduleAllDayDraft,
                flexGrow = 1,
                onChange = function(value)
                    scheduleEndDraft = tostring(value or "")
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.button({
                text = noctalia.tr("panel.schedules.save"),
                glyph = "device-floppy",
                variant = "primary",
                controlSize = "sm",
                enabled = storageValid()
                    and output ~= ""
                    and #ids > 0
                    and noctalia.string.trim(scheduleNameDraft) ~= "",
                flexGrow = 1,
                onClick = function()
                    local weekdays = {}
                    for index, enabled in ipairs(scheduleWeekdaysDraft) do
                        if enabled then
                            table.insert(weekdays, index - 1)
                        end
                    end
                    local selectedMonths = {}
                    for index, enabled in ipairs(scheduleMonthsDraft) do
                        if enabled then
                            table.insert(selectedMonths, index)
                        end
                    end
                    local startMinute = if scheduleAllDayDraft then 0 else parseMinute(scheduleStartDraft)
                    local endMinute = if scheduleAllDayDraft then 0 else parseMinute(scheduleEndDraft)
                    if #weekdays == 0 then
                        scheduleDraftError = noctalia.tr("panel.schedules.validation_weekday")
                        render()
                    elseif #selectedMonths == 0 then
                        scheduleDraftError = noctalia.tr("panel.schedules.validation_month")
                        render()
                    elseif startMinute == nil or endMinute == nil then
                        scheduleDraftError = noctalia.tr("panel.schedules.validation_time")
                        render()
                    elseif not scheduleAllDayDraft and startMinute == endMinute then
                        scheduleDraftError = noctalia.tr("panel.schedules.validation_window")
                        render()
                    else
                        scheduleDraftError = ""
                        send({
                            kind = "schedule_save",
                            output = output,
                            before_id = if editingScheduleId == "" and scheduleInsertBeforeDraft ~= ""
                                then scheduleInsertBeforeDraft
                                else nil,
                            schedule = {
                                id = editingScheduleId,
                                name = noctalia.string.trim(scheduleNameDraft),
                                playlist = if schedulePlaylistDraft ~= "" then schedulePlaylistDraft else playlistId,
                                enabled = scheduleEnabledDraft,
                                weekdays = weekdays,
                                months = selectedMonths,
                                start_minute = startMinute,
                                end_minute = endMinute,
                                all_day = scheduleAllDayDraft,
                            },
                        })
                        scheduleEditorOpen = false
                        resetScheduleDraft(playlistId)
                        render()
                    end
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.schedules.reset"),
                glyph = "refresh",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    scheduleEditorOpen = false
                    resetScheduleDraft(playlistId)
                    render()
                end,
            }),
        }),
    }
    if scheduleDraftError ~= "" then
        table.insert(
            children,
            ui.label({ text = scheduleDraftError, fontSize = 9, color = "error", maxLines = 3 })
        )
    end
    return ui.column({ gap = 7, padding = 9, radius = 9, fill = "surface_variant/0.2", align = "stretch" }, children)
end

local function scheduleInsertionZone(output, beforeId)
    local namespace = "@schedule:" .. output
    local tokens = dragTargetTokenByPlaylist[namespace]
    local token = type(tokens) == "table" and tokens[tostring(beforeId or "")] or nil
    if token == nil then
        return ui.box({ height = 3 })
    end
    return ui.dropZone({
        key = "schedule-gap-" .. token,
        accepts = { "wio-playlist", "wio-schedule" },
        value = token,
        onDrop = "onDisplayPlaylistDrop",
        direction = "row",
        enabled = storageValid() and output ~= "",
        height = 3,
        radius = 2,
        fill = "primary/0.28",
        expandOnDrag = true,
        hitSlop = 28,
    })
end

function panelUi.defaultPlaylistDropZone(output)
    local tokens = dragTargetTokenByPlaylist["@schedule:" .. output]
    local token = type(tokens) == "table" and tokens["@default"] or nil
    if token == nil then
        return ui.box({ height = 3 })
    end
    return ui.dropZone({
        key = "display-default-drop-" .. token,
        accepts = { "wio-playlist" },
        value = token,
        onDrop = "onDisplayPlaylistDrop",
        direction = "row",
        enabled = storageValid() and output ~= "",
        height = 5,
        radius = 3,
        fill = "primary/0.35",
        expandOnDrag = true,
        hitSlop = 30,
    })
end

local function schedulesSection(output, playlistId)
    local configuredOutput = outputConfig(output)
    local schedules = type(configuredOutput.schedules) == "table" and configuredOutput.schedules or {}
    local state = outputRuntime(output)
    local fallbackId = tostring(configuredOutput.fallback_playlist or "")
    local fallback = playlistMap()[fallbackId]
    local fallbackName = if type(fallback) == "table"
        then tostring(fallback.name or fallbackId)
        else noctalia.tr("panel.screens.no_default")
    local children = {
        ui.row({ gap = 7, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.screens.priority_title"),
                fontSize = 12,
                fontWeight = "bold",
                flexGrow = 1,
            }),
            ui.button({
                text = noctalia.tr("panel.schedules.resume"),
                glyph = "calendar-time",
                variant = if state.manual_pin == true then "primary" else "ghost",
                controlSize = "sm",
                enabled = state.manual_pin == true and storageValid(),
                onClick = function()
                    send({ kind = "schedule_resume", output = output })
                end,
            }),
        }),
        ui.label({
            text = if state.manual_pin == true
                then noctalia.tr("panel.schedules.manual_notice")
                elseif tostring(state.active_schedule or "") ~= "" then noctalia.tr("panel.schedules.active", {
                    id = tostring(state.active_schedule),
                })
                else noctalia.tr("panel.schedules.no_owner"),
            fontSize = 9,
            color = if state.manual_pin == true then "tertiary" else "on_surface_variant",
            maxLines = 3,
        }),
        ui.label({
            text = noctalia.tr("panel.schedules.precedence"),
            fontSize = 9,
            fontWeight = "bold",
            color = "on_surface_variant",
            maxLines = 2,
        }),
        ui.label({
            text = noctalia.tr("panel.screens.default_drop_hint"),
            fontSize = 8,
            color = "on_surface_variant",
            maxLines = 2,
        }),
        panelUi.defaultPlaylistDropZone(output),
        ui.row({
            key = "display-default-row-" .. output .. "-" .. fallbackId,
            gap = 6,
            align = "center",
            padding = 7,
            radius = 8,
            fill = if tostring(state.active_schedule or "") == "" then "primary/0.14" else "surface_variant/0.22",
            border = "primary/0.35",
            borderWidth = 1,
        }, {
            ui.glyph({ name = "pin", size = 15, color = "primary" }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({
                    text = "1. " .. fallbackName,
                    fontSize = 10,
                    fontWeight = "bold",
                    maxLines = 1,
                }),
                ui.label({
                    text = noctalia.tr("panel.screens.default_rule_description"),
                    fontSize = 8,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
            }),
        }),
    }
    local scheduleEditorPositioned = false
    for index, schedule in ipairs(schedules) do
        local scheduleIndex = index
        local scheduleEntry = schedule
        local scheduleId = tostring(schedule.id or "")
        local scheduleTokens = dragEntryTokenByPlaylist["@schedule:" .. output]
        local dragToken = type(scheduleTokens) == "table" and scheduleTokens[scheduleId] or nil
        local scheduledPlaylist = playlistMap()[tostring(schedule.playlist or "")]
        local scheduledPlaylistName = if type(scheduledPlaylist) == "table"
            then tostring(scheduledPlaylist.name or schedule.playlist)
            else tostring(schedule.playlist or noctalia.tr("panel.playlists.no_playlists"))
        local window = if schedule.all_day == true
            then noctalia.tr("panel.schedules.all_day")
            else formatMinute(schedule.start_minute) .. "–" .. formatMinute(schedule.end_minute)
        local months, days = scheduleSelectionSummary(schedule)
        table.insert(children, scheduleInsertionZone(output, scheduleId))
        if scheduleEditorOpen and editingScheduleId == "" and scheduleInsertBeforeDraft == scheduleId then
            table.insert(children, scheduleEditor(output, playlistId))
            scheduleEditorPositioned = true
        end
        local rowChildren = {}
        if dragToken ~= nil then
            table.insert(rowChildren, ui.dragSource({
                key = "schedule-grip-" .. dragToken,
                dragType = "wio-schedule",
                payload = dragToken,
                enabled = storageValid(),
                previewAncestor = 1,
                liftFromLayout = true,
                width = 24,
                height = 24,
                align = "center",
                justify = "center",
                tooltip = noctalia.tr("panel.schedules.drag"),
            }, {
                ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
            }))
        end
        table.insert(rowChildren, ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({
                text = tostring(scheduleIndex + 1) .. ". " .. scheduledPlaylistName,
                fontSize = 10,
                fontWeight = "bold",
                maxLines = 1,
            }),
            ui.label({
                text = tostring(schedule.name or noctalia.tr("panel.schedules.default_name"))
                    .. " · "
                    .. noctalia.tr("panel.schedules.summary", {
                        months = months,
                        days = days,
                        window = window,
                        state = if schedule.enabled == false
                            then noctalia.tr("panel.schedules.disabled")
                            else noctalia.tr("panel.schedules.enabled"),
                    }),
                fontSize = 8,
                color = "on_surface_variant",
                maxLines = 3,
            }),
        }))
        table.insert(rowChildren, ui.button({
            glyph = "edit",
            tooltip = noctalia.tr("panel.schedules.edit"),
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                editScheduleDraft(scheduleEntry)
                render()
            end,
        }))
        table.insert(rowChildren, ui.button({
            glyph = "trash",
            tooltip = noctalia.tr("panel.schedules.delete"),
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                send({
                    kind = "schedule_delete",
                    output = output,
                    schedule_id = scheduleId,
                })
            end,
        }))
        table.insert(
            children,
            ui.row({ gap = 6, align = "center", padding = 7, radius = 8, fill = "surface_variant/0.22" }, rowChildren)
        )
    end
    table.insert(children, scheduleInsertionZone(output, ""))
    if scheduleEditorOpen then
        if not scheduleEditorPositioned then
            table.insert(children, scheduleEditor(output, playlistId))
        end
    else
        table.insert(
            children,
            ui.button({
                text = noctalia.tr("panel.schedules.add"),
                glyph = "calendar-plus",
                variant = "ghost",
                controlSize = "sm",
                enabled = output ~= "" and playlistId ~= "" and storageValid(),
                onClick = function()
                    editScheduleDraft(nil, playlistId)
                    render()
                end,
            })
        )
    end
    return ui.column({ gap = 7, align = "stretch" }, children)
end

function panelUi.displayPlaylistLibrary(output)
    local ids = sortedPlaylistIds(false)
    local currentFallback = tostring(outputConfig(output).fallback_playlist or "")
    local children = {
        ui.label({
            text = noctalia.tr("panel.screens.playlist_library"),
            fontSize = 12,
            fontWeight = "bold",
        }),
        ui.label({
            text = noctalia.tr("panel.screens.playlist_library_hint"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 3,
        }),
    }
    if #ids == 0 then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.playlists.no_playlists"),
            fontSize = 9,
            color = "on_surface_variant",
        }))
    else
        panelUi.appendExplicitGrid(children, ids, displayPlaylistVisible, 2, function(playlistId)
            local playlist = playlistMap()[playlistId]
            local entries = type(playlist) == "table" and type(playlist.entries) == "table" and playlist.entries or {}
            local first = entries[1]
            local previewPath = ""
            local firstKind = "still"
            if type(first) == "table" then
                previewPath = panelUi.playlistEntryVisualState(first, output)
                firstKind = if type(first.media) == "table" then tostring(first.media.kind or "video") else "still"
            end
            local dragToken = dragPlaylistTokenById[playlistId]
            return ui.column({
                key = "display-playlist-card-" .. playlistId,
                width = 350,
                gap = 5,
                padding = 8,
                radius = 9,
                fill = if currentFallback == playlistId then "primary/0.12" else "surface_variant/0.2",
                border = if currentFallback == playlistId then "primary/0.5" else "outline/0.25",
                borderWidth = 1,
                align = "stretch",
            }, {
                ui.row({ gap = 7, align = "center" }, {
                    playlistEntryPreview(firstKind, previewPath, currentFallback == playlistId),
                    ui.column({ gap = 1, flexGrow = 1 }, {
                        ui.label({
                            text = tostring(type(playlist) == "table" and playlist.name or playlistId),
                            fontSize = 10,
                            fontWeight = "bold",
                            maxLines = 1,
                        }),
                        ui.label({
                            text = noctalia.tr("panel.screens.playlist_summary", {
                                count = tostring(#entries),
                                order = tostring(type(playlist) == "table" and playlist.order or "rotate"),
                                minutes = tostring(math.max(
                                    1,
                                    math.floor((tonumber(type(playlist) == "table" and playlist.interval_seconds) or 900) / 60)
                                )),
                            }),
                            fontSize = 8,
                            color = "on_surface_variant",
                            maxLines = 2,
                        }),
                        if type(first) == "table"
                            then panelUi.compactPaletteSwatch(first, tostring(first.pairing_id or ""))
                            else ui.spacer({ height = 1 }),
                    }),
                }),
                ui.row({ gap = 4, align = "center", justify = "end" }, {
                    if dragToken ~= nil
                        then ui.dragSource({
                            key = "display-playlist-grip-" .. dragToken,
                            dragType = "wio-playlist",
                            payload = dragToken,
                            enabled = storageValid(),
                            previewAncestor = 2,
                            liftFromLayout = true,
                            width = 28,
                            height = 28,
                            align = "center",
                            justify = "center",
                            tooltip = noctalia.tr("panel.screens.drag_playlist"),
                        }, {
                            ui.glyph({ name = "menu-2", size = 15, color = "on_surface_variant" }),
                        })
                        else ui.spacer({ width = 28 }),
                    ui.button({
                        glyph = "pin",
                        tooltip = noctalia.tr("panel.screens.set_default"),
                        variant = if currentFallback == playlistId then "primary" else "ghost",
                        controlSize = "sm",
                        enabled = storageValid(),
                        onClick = function()
                            selectedPlaylistId = playlistId
                            send({ kind = "playlist_assign", output = output, playlist_id = playlistId })
                        end,
                    }),
                    ui.button({
                        glyph = "calendar-plus",
                        tooltip = noctalia.tr("panel.screens.add_schedule"),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = storageValid(),
                        onClick = function()
                            resetScheduleDraft(playlistId)
                            scheduleNameDraft = tostring(type(playlist) == "table" and playlist.name or playlistId)
                            scheduleEditorOpen = true
                            render()
                        end,
                    }),
                }),
            })
        end)
        panelUi.appendVisibilityControls(
            children,
            #ids,
            displayPlaylistVisible,
            PAIRING_CARD_CHUNK,
            function(value)
                displayPlaylistVisible = value
            end
        )
    end
    return ui.column({
        key = "display-playlist-library-" .. output,
        gap = 7,
        padding = 9,
        radius = 10,
        fill = "surface_variant/0.1",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

local function playlistsSection(outputOverride)
    local output = tostring(outputOverride or "")
    if output == "" then
        output = focusedOutput()
    end
    local playlistId, playlist = resolveSelectedPlaylist(output)
    local labels, ids, selectedIndex = playlistOptions(playlistId)
    local playlistLabels = if #labels > 0 then labels else { noctalia.tr("panel.playlists.no_playlists") }
    local entries = type(playlist) == "table" and type(playlist.entries) == "table" and playlist.entries or {}
    local state = runState(output, playlistId)
    local intervalSeconds = math.max(60, math.floor(tonumber(type(playlist) == "table" and playlist.interval_seconds) or 900))
    local intervalMinutes = math.max(1, math.floor(intervalSeconds / 60))
    local order = tostring(type(playlist) == "table" and playlist.order or "rotate")
    local stateLabel = if state.paused == true
        then noctalia.tr("common.paused")
        elseif state.running == true then noctalia.tr("common.running")
        elseif state.parked == true then noctalia.tr("common.parked")
        else noctalia.tr("common.stopped")
    local nameValue = if playlistNameDraft ~= ""
        then playlistNameDraft
        elseif type(playlist) == "table" then tostring(playlist.name or "")
        else ""
    local intervalValue = if playlistIntervalDraft ~= "" then playlistIntervalDraft else tostring(intervalMinutes)
    local children = {
        panelUi.sectionHeader(
            "playlist",
            noctalia.tr("panel.playlists.title"),
            noctalia.tr("panel.playlists.description")
        ),
        ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "playlist-select-" .. output,
                options = playlistLabels,
                selectedIndex = selectedIndex,
                enabled = #ids > 0,
                flexGrow = 1,
                onChange = function(index)
                    closePlaylistEntryEditor()
                    selectedPlaylistId = ids[math.floor(tonumber(index) or 0) + 1] or ""
                    playlistNameDraft = ""
                    playlistIntervalDraft = ""
                    playlistEntryPage = 1
                    scheduleEditorOpen = false
                    resetScheduleDraft(selectedPlaylistId)
                    render()
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "playlist-new-name-" .. output,
                value = newPlaylistNameDraft,
                placeholder = noctalia.tr("panel.playlists.new_name"),
                flexGrow = 1,
                onChange = function(value)
                    newPlaylistNameDraft = tostring(value or "")
                    render()
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.playlists.new_short"),
                glyph = "plus",
                variant = "primary",
                controlSize = "sm",
                enabled = storageValid() and noctalia.string.trim(newPlaylistNameDraft) ~= "",
                onClick = function()
                    local request = {
                        kind = "playlist_create",
                        name = noctalia.string.trim(newPlaylistNameDraft),
                    }
                    if output ~= "" then
                        request.output = output
                    end
                    send(request)
                    newPlaylistNameDraft = ""
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "playlist-name-" .. playlistId,
                value = nameValue,
                placeholder = noctalia.tr("panel.playlists.name"),
                flexGrow = 1,
                enabled = playlistId ~= "",
                onChange = function(value)
                    playlistNameDraft = tostring(value or "")
                    render()
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.playlists.rename"),
                glyph = "edit",
                variant = "ghost",
                controlSize = "sm",
                enabled = storageValid() and playlistId ~= "" and noctalia.string.trim(nameValue) ~= "",
                onClick = function()
                    send({ kind = "playlist_rename", playlist_id = playlistId, name = noctalia.string.trim(nameValue) })
                    playlistNameDraft = ""
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.button({
                text = noctalia.tr("panel.playlists.duplicate"),
                glyph = "copy",
                variant = "ghost",
                controlSize = "sm",
                enabled = storageValid() and playlistId ~= "",
                flexGrow = 1,
                onClick = function()
                    send({
                        kind = "playlist_duplicate",
                        playlist_id = playlistId,
                        name = noctalia.tr("panel.playlists.copy_name", {
                            name = tostring(
                                type(playlist) == "table"
                                    and playlist.name
                                    or noctalia.tr("panel.playlists.default_name")
                            ),
                        }),
                        output = output,
                    })
                end,
            }),
            ui.button({
                text = if pendingDeletePlaylistId == playlistId and playlistId ~= ""
                    then noctalia.tr("panel.playlists.confirm_delete")
                    else noctalia.tr("panel.playlists.delete"),
                glyph = if pendingDeletePlaylistId == playlistId and playlistId ~= "" then "alert-triangle" else "trash",
                variant = "ghost",
                controlSize = "sm",
                enabled = storageValid() and playlistId ~= "",
                flexGrow = 1,
                onClick = function()
                    if pendingDeletePlaylistId == playlistId then
                        pendingDeletePlaylistId = ""
                        send({ kind = "playlist_delete", playlist_id = playlistId })
                    else
                        pendingDeletePlaylistId = playlistId
                        render()
                    end
                end,
            }),
        }),
    }
    local coordinatorError = type(status) == "table" and tostring(status.last_action_error or "") or ""
    if coordinatorError ~= "" then
        table.insert(
            children,
            2,
            ui.label({
                text = coordinatorError,
                fontSize = 9,
                color = "error",
                maxLines = 4,
            })
        )
    end
    if playlist == nil then
        closePlaylistEntryEditor()
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.playlists.no_playlists"),
                color = "on_surface_variant",
                fontSize = 10,
            })
        )
        return panelUi.card(children)
    end

    if playlistEntryEditorOpen and editingPlaylistEntryPlaylistId ~= playlistId then
        closePlaylistEntryEditor()
    end
    local editingThisPlaylist = playlistEntryEditorOpen
        and editingPlaylistEntryPlaylistId == playlistId
        and editingPlaylistEntryId ~= ""
    if not editingThisPlaylist then
        table.insert(children, panelUi.playlistPairingLibrary(playlistId, output))
    end
    table.insert(children, ui.separator())
    table.insert(
        children,
        ui.label({
            text = noctalia.tr("panel.playlists.state", {
                state = stateLabel,
                count = tostring(#entries),
                current = if tostring(state.current_entry or "") ~= ""
                    then tostring(state.current_entry)
                    else noctalia.tr("common.none"),
            }),
            fontSize = 10,
            fontWeight = "bold",
            maxLines = 3,
        })
    )
    local runWarning = tostring(state.last_error or "")
    if runWarning ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.playlists.run_warning", { error = runWarning }),
                fontSize = 9,
                color = "tertiary",
                maxLines = 4,
            })
        )
    end
    if #entries > 1 then
        table.insert(
            children,
            ui.row({ gap = 6, align = "center" }, {
                ui.input({
                    key = "playlist-interval-" .. playlistId,
                    value = intervalValue,
                    placeholder = noctalia.tr("panel.playlists.interval_placeholder", {
                        minutes = tostring(intervalMinutes),
                    }),
                    width = 115,
                    onChange = function(value)
                        playlistIntervalDraft = tostring(value or "")
                        render()
                    end,
                }),
                ui.select({
                    key = "playlist-order-" .. playlistId,
                    options = {
                        noctalia.tr("panel.playlists.order_rotate"),
                        noctalia.tr("panel.playlists.order_shuffle"),
                    },
                    selectedIndex = if order == "shuffle" then 1 else 0,
                    flexGrow = 1,
                    onChange = function(index)
                        send({
                            kind = "playlist_options",
                            playlist_id = playlistId,
                            interval_seconds = intervalSeconds,
                            order = if math.floor(tonumber(index) or 0) == 1 then "shuffle" else "rotate",
                        })
                    end,
                }),
                ui.button({
                    text = noctalia.tr("panel.playlists.save"),
                    glyph = "device-floppy",
                    variant = "ghost",
                    controlSize = "sm",
                    onClick = function()
                        local minutes = math.max(
                            1,
                            math.min(43200, math.floor(tonumber(intervalValue) or intervalMinutes))
                        )
                        playlistIntervalDraft = tostring(minutes)
                        send({
                            kind = "playlist_options",
                            playlist_id = playlistId,
                            interval_seconds = minutes * 60,
                            order = order,
                        })
                    end,
                }),
            })
        )
    else
        table.insert(
            children,
            ui.label({
                text = if #entries == 1
                    then noctalia.tr("panel.playlists.single_entry_rotation")
                    else noctalia.tr("panel.playlists.empty_rotation"),
                fontSize = 9,
                color = "on_surface_variant",
                maxLines = 3,
            })
        )
    end
    table.insert(
        children,
        ui.row({ gap = 5, align = "center" }, {
            playlistActionButton(
                "previous",
                "player-skip-back",
                noctalia.tr("panel.playlists.previous"),
                playlistId,
                output,
                #entries > 0 and state.paused ~= true,
                false
            ),
            playlistActionButton(
                "start",
                "player-play",
                noctalia.tr("panel.playlists.start"),
                playlistId,
                output,
                #entries > 0 and state.running ~= true,
                true
            ),
            playlistActionButton(
                "pause",
                "player-pause",
                noctalia.tr("panel.playlists.pause"),
                playlistId,
                output,
                state.running == true and state.paused ~= true,
                false
            ),
        })
    )
    table.insert(
        children,
        ui.row({ gap = 5, align = "center" }, {
            playlistActionButton(
                "resume",
                "player-track-next",
                noctalia.tr("panel.playlists.resume"),
                playlistId,
                output,
                state.paused == true,
                false
            ),
            playlistActionButton(
                "stop",
                "player-stop",
                noctalia.tr("panel.playlists.stop"),
                playlistId,
                output,
                state.running == true or state.paused == true or state.parked == true,
                false
            ),
        })
    )
    table.insert(
        children,
        ui.row({ gap = 5, align = "center" }, {
            playlistActionButton(
                "random",
                "arrows-shuffle",
                noctalia.tr("panel.playlists.random"),
                playlistId,
                output,
                #entries > 0 and state.paused ~= true,
                false
            ),
            playlistActionButton(
                "next",
                "player-skip-forward",
                noctalia.tr("panel.playlists.next"),
                playlistId,
                output,
                #entries > 0 and state.paused ~= true,
                false
            ),
        })
    )
    table.insert(children, ui.separator())
    table.insert(
        children,
        ui.label({ text = noctalia.tr("panel.playlists.entries"), fontSize = 12, fontWeight = "bold" })
    )
    if #entries == 0 then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.playlists.empty"),
                fontSize = 10,
                color = "on_surface_variant",
            })
        )
    else
        if
            editingThisPlaylist
            and (
                editingPlaylistEntryIndex < 1
                or type(entries[editingPlaylistEntryIndex]) ~= "table"
                or tostring(entries[editingPlaylistEntryIndex].id or "") ~= editingPlaylistEntryId
            )
        then
            closePlaylistEntryEditor()
            editingThisPlaylist = false
        end
        local playlistPageCount = math.max(1, math.ceil(#entries / PLAYLIST_ENTRY_CHUNK))
        playlistEntryPage = math.max(1, math.min(playlistPageCount, math.floor(playlistEntryPage)))
        local playlistFirstEntry = if editingThisPlaylist
            then editingPlaylistEntryIndex
            else (playlistEntryPage - 1) * PLAYLIST_ENTRY_CHUNK + 1
        local playlistLastEntry = if editingThisPlaylist
            then editingPlaylistEntryIndex
            else math.min(#entries, playlistFirstEntry + PLAYLIST_ENTRY_CHUNK - 1)
        for index = playlistFirstEntry, playlistLastEntry do
            local entry = entries[index]
            local currentEntry = entry
            local entryId = tostring(entry.id or "")
            local media = type(entry.media) == "table" and entry.media or nil
            local still = type(entry.still) == "table" and entry.still or {}
            local theme = type(entry.theme) == "table" and entry.theme or {}
            local kind = if media == nil then "still" else tostring(media.kind or "dynamic")
            local kindLabel = if media == nil
                then noctalia.tr("panel.playlists.entry.media_still")
                elseif kind == "video" then noctalia.tr("panel.playlists.entry.media_video")
                else noctalia.tr("panel.playlists.entry.media_workshop")
            local source = if media == nil then tostring(still.path or "") else tostring(media.source or "")
            local active = tostring(state.current_entry or "") == tostring(entry.id or "")
            local previewPath, sourceAvailable = panelUi.playlistEntryVisualState(entry, output)
            local playlistEntryTokens = dragEntryTokenByPlaylist[playlistId]
            local dragToken = type(playlistEntryTokens) == "table" and playlistEntryTokens[entryId] or nil
            local cardChildren = {}
            if dragToken ~= nil and not editingThisPlaylist then
                table.insert(cardChildren, ui.dragSource({
                    key = "playlist-entry-grip-" .. dragToken,
                    dragType = "wio-entry",
                    payload = dragToken,
                    enabled = storageValid(),
                    previewAncestor = 1,
                    liftFromLayout = true,
                    width = 24,
                    height = 24,
                    align = "center",
                    justify = "center",
                    tooltip = noctalia.tr("panel.playlists.drag_reorder"),
                }, {
                    ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
                }))
            end
            table.insert(cardChildren, ui.column({ gap = 5, flexGrow = 1, align = "stretch" }, {
                ui.row({ gap = 6, align = "center" }, {
                    playlistEntryPreview(kind, previewPath, active),
                    ui.column({ gap = 1, flexGrow = 1 }, {
                        ui.label({
                            text = tostring(index) .. ". " .. tostring(entry.label or basename(source)),
                            fontSize = 10,
                            fontWeight = "bold",
                            maxLines = 1,
                        }),
                        ui.label({
                            text = kindLabel .. " · " .. source,
                            fontSize = 8,
                            color = "on_surface_variant",
                            maxLines = 2,
                        }),
                        ui.label({
                            text = noctalia.tr("panel.playlists.entry.still_summary", {
                                mode = if tostring(still.mode or "") == "automatic"
                                    then noctalia.tr("panel.playlists.entry.still_automatic")
                                    else noctalia.tr("panel.playlists.entry.still_selected"),
                                path = panelUi.valueOr(still.path, "common.unset"),
                            }),
                            fontSize = 8,
                            color = "on_surface_variant",
                            maxLines = 2,
                        }),
                        panelUi.compactPaletteSwatch(entry, tostring(entry.pairing_id or "")),
                        if not sourceAvailable
                            then ui.label({
                                text = noctalia.tr("panel.playlists.entry.missing_source"),
                                fontSize = 8,
                                color = "error",
                                maxLines = 2,
                            })
                            else ui.spacer({ height = 1 }),
                    }),
                    ui.button({
                        glyph = "player-play",
                        tooltip = noctalia.tr("panel.playlists.apply"),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = output ~= "" and storageValid(),
                        onClick = function()
                            send({
                                kind = "playlist_apply_entry",
                                output = output,
                                playlist_id = playlistId,
                                entry_id = tostring(currentEntry.id or ""),
                            })
                        end,
                    }),
                    ui.button({
                        glyph = "edit",
                        tooltip = noctalia.tr("panel.playlists.entry_edit"),
                        variant = if editingThisPlaylist and editingPlaylistEntryId == entryId
                            then "primary"
                            else "ghost",
                        controlSize = "sm",
                        enabled = storageValid(),
                        onClick = function()
                            if editingThisPlaylist and editingPlaylistEntryId == entryId then
                                closePlaylistEntryEditor()
                                render()
                            else
                                beginPlaylistEntryEditor(currentEntry, playlistId, index)
                            end
                        end,
                    }),
                    ui.button({
                        glyph = "trash",
                        tooltip = noctalia.tr("panel.playlists.entry_remove"),
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = function()
                            if editingPlaylistEntryId == tostring(currentEntry.id or "") then
                                closePlaylistEntryEditor()
                            end
                            send({
                                kind = "playlist_remove_entry",
                                playlist_id = playlistId,
                                entry_id = tostring(currentEntry.id or ""),
                            })
                        end,
                    }),
                }),
            }))
            if not editingThisPlaylist then
                table.insert(children, playlistInsertionZone(playlistId, entryId))
            end
            table.insert(children, ui.row({
                key = "playlist-entry-card-" .. entryId,
                gap = 6,
                padding = 8,
                radius = 9,
                fill = "surface_variant/0.22",
                align = "center",
            }, cardChildren))
            if editingThisPlaylist and editingPlaylistEntryId == entryId then
                table.insert(children, panelUi.playlistEntryEditor(playlistId, output))
            end
        end
        if not editingThisPlaylist then
            panelUi.appendPageControls(
                children,
                #entries,
                playlistEntryPage,
                PLAYLIST_ENTRY_CHUNK,
                function(value)
                    playlistEntryPage = value
                end
            )
        end
    end
    if not editingThisPlaylist then
        table.insert(children, playlistInsertionZone(playlistId, ""))
    end
    return panelUi.card(children)
end

local function diagnosticsSection()
    local current = providers()
    local probeText = if current.probing == true
        then noctalia.tr("diagnostics.probing")
        elseif current.probe_ok == true then noctalia.tr(
            "diagnostics.probe_ok",
            { time = tostring(current.probed_at or "") }
        )
        else noctalia.tr("diagnostics.probe_error", { error = tostring(current.probe_error or "") })
    local storageText = if storageValid()
        then noctalia.tr("diagnostics.storage_ok")
        else noctalia.tr("diagnostics.storage_error", {
            config = tostring(type(status) == "table" and status.config_error or ""),
            runtime = tostring(type(status) == "table" and status.runtime_error or ""),
        })
    local actionError = type(status) == "table" and tostring(status.last_action_error or "") or ""
    local renderer = type(status) == "table" and type(status.renderer) == "table" and status.renderer or {}
    local activeRenderers = 0
    if type(renderer.outputs) == "table" then
        for _ in pairs(renderer.outputs) do
            activeRenderers += 1
        end
    end
    local paletteState = type(status) == "table" and type(status.palette) == "table" and status.palette or {}
    local requestedPalette = type(paletteState.requested) == "table" and paletteState.requested or {}
    local appliedPalette = type(paletteState.applied) == "table" and paletteState.applied or {}
    local hasRequestedPalette = next(requestedPalette) ~= nil
    local hasAppliedPalette = next(appliedPalette) ~= nil
    local paletteError = tostring(paletteState.last_error or "")

    local children = {
        panelUi.sectionHeader(
            "stethoscope",
            noctalia.tr("panel.diagnostics.title"),
            noctalia.tr("panel.diagnostics.description")
        ),
        ui.label({
            text = storageText,
            fontSize = 10,
            color = if storageValid() then "primary" else "error",
            maxLines = 5,
        }),
        ui.label({ text = probeText, fontSize = 10, color = "on_surface_variant", maxLines = 5 }),
        ui.label({
            text = noctalia.tr("diagnostics.renderer", {
                state = if renderer.ready == true then noctalia.tr("common.running") else noctalia.tr("common.stopped"),
                count = tostring(activeRenderers),
                error = tostring(renderer.last_error or ""),
            }),
            fontSize = 10,
            color = if renderer.ready == true then "primary" else "error",
            maxLines = 5,
        }),
        ui.separator(),
        ui.label({ text = noctalia.tr("diagnostics.palette_title"), fontSize = 11, fontWeight = "bold" }),
        ui.label({
            text = noctalia.tr("diagnostics.palette_authority", {
                output = panelUi.valueOr(paletteState.authority_output, "common.none"),
            }),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 3,
        }),
    }
    if hasRequestedPalette then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("diagnostics.palette_requested", {
                    mode = panelUi.valueOr(requestedPalette.mode, "common.unknown"),
                    source = panelUi.valueOr(requestedPalette.source, "common.unknown"),
                    selection = panelUi.valueOr(requestedPalette.selection, "common.none"),
                    output = panelUi.valueOr(requestedPalette.output, "common.none"),
                    playlist = panelUi.valueOr(requestedPalette.playlist, "common.none"),
                    entry = panelUi.valueOr(requestedPalette.entry, "common.none"),
                }),
                fontSize = 9,
                color = "on_surface_variant",
                maxLines = 4,
            })
        )
    else
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("diagnostics.palette_none"),
                fontSize = 9,
                color = "on_surface_variant",
            })
        )
    end
    if hasAppliedPalette then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("diagnostics.palette_applied", {
                    mode = panelUi.valueOr(appliedPalette.mode, "common.unknown"),
                    source = panelUi.valueOr(appliedPalette.source, "common.unknown"),
                    selection = panelUi.valueOr(appliedPalette.selection, "common.none"),
                    resolution = panelUi.paletteResolutionText(appliedPalette.resolution),
                    fallback = panelUi.yesNoText(appliedPalette.fallback),
                    time = panelUi.valueOr(appliedPalette.applied_at, "common.unknown"),
                }),
                fontSize = 9,
                color = if appliedPalette.fallback == true then "tertiary" else "primary",
                maxLines = 4,
            })
        )
    end
    if paletteError ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("diagnostics.palette_error", { error = paletteError }),
                fontSize = 9,
                color = "tertiary",
                maxLines = 5,
            })
        )
    end
    table.insert(children, ui.separator())
    table.insert(
        children,
        ui.label({
            text = noctalia.tr("diagnostics.ownership"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 6,
        })
    )
    if actionError ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("diagnostics.last_action_error", { error = actionError }),
                fontSize = 10,
                color = "error",
                maxLines = 6,
            })
        )
    end
    table.insert(
        children,
        ui.button({
            text = noctalia.tr("panel.reprobe"),
            glyph = "refresh",
            variant = "ghost",
            enabled = current.probing ~= true,
            onClick = function()
                send({ kind = "probe" })
            end,
        })
    )
    return panelUi.card(children)
end

-- Panel navigation ---------------------------------------------------------
--
-- These routes only decide which existing presentation sections are visible.
-- Pairing catalogs and playlist drawers can extend the bounded page builders
-- below without changing this router.

-- Keep the late-bound page helpers behind one namespace. Luau caps a chunk at
-- 200 local registers; making every page helper a top-level local caused this
-- panel to cross that limit as the v0.5 editor grew.
local panelPages = {
    validPages = {
        main = true,
        library = true,
        shops = true,
        playlists = true,
        diagnostics = true,
    },
    validLibrarySubpages = { images = true, videos = true, workshops = true },
    validShopSubpages = { wallhaven = true, motionbgs = true, steam = true },
    engineDrafts = {},
    engineMode = "video",
}

function panelPages.screenNames()
    local seen = {}
    local names = {}
    local function add(value)
        local name = tostring(value or "")
        if name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end
    for _, output in ipairs(noctalia.outputs()) do
        if type(output) == "table" then
            add(output.name or output.connector)
        end
    end
    local configured = configSnapshot().outputs
    for output in pairs(type(configured) == "table" and configured or {}) do
        add(output)
    end
    table.sort(names)
    return names, seen
end

function panelPages.ensureSelectedScreen()
    local names, seen = panelPages.screenNames()
    if selectedScreen ~= "" and seen[selectedScreen] then
        return selectedScreen
    end
    local focused = focusedOutput()
    selectedScreen = if focused ~= "" and seen[focused] then focused else names[1] or ""
    return selectedScreen
end

function panelPages.selectPage(page)
    preview.cancel()
    activePage = if panelPages.validPages[page] then page else "main"
    if activePage == "playlists" then
        activeSubpage = ""
        resolveSelectedPlaylist(panelPages.ensureSelectedScreen())
    elseif activePage == "library" then
        activeSubpage = if panelPages.validLibrarySubpages[activeSubpage] then activeSubpage else "images"
    elseif activePage == "shops" then
        activeSubpage = if panelPages.validShopSubpages[activeSubpage] then activeSubpage else "wallhaven"
    else
        activeSubpage = ""
    end
    closePairingEditor()
    closePlaylistEntryEditor()
    scheduleEditorOpen = false
    render()
end

function panelPages.selectLibraryPage(subpage)
    if not panelPages.validLibrarySubpages[subpage] then
        return
    end
    preview.cancel()
    activePage = "library"
    activeSubpage = subpage
    closePairingEditor()
    closePlaylistEntryEditor()
    scheduleEditorOpen = false
    render()
end

function panelPages.selectShopPage(subpage)
    if not panelPages.validShopSubpages[subpage] then
        return
    end
    if activePage == "shops" and activeSubpage == subpage then
        return
    end
    preview.cancel()
    activePage = "shops"
    activeSubpage = subpage
    closePairingEditor()
    closePlaylistEntryEditor()
    scheduleEditorOpen = false
    render()
end

function panelPages.selectPlaylistPage(playlistId)
    if type(playlistMap()[playlistId]) ~= "table" or playlistMap()[playlistId].quick_choice == true then
        return
    end
    preview.cancel()
    selectedPlaylistId = playlistId
    playlistNameDraft = ""
    playlistIntervalDraft = ""
    playlistEntryPage = 1
    closePairingEditor()
    closePlaylistEntryEditor()
    scheduleEditorOpen = false
    resetScheduleDraft(playlistId)
    activePage = "playlists"
    activeSubpage = ""
    render()
end

function panelPages.selectScreenPage(output)
    local _, seen = panelPages.screenNames()
    if not seen[output] then
        return
    end
    preview.cancel()
    selectedScreen = output
    screenIntervalDraft = ""
    screenOrderDraft = ""
    closePairingEditor()
    closePlaylistEntryEditor()
    scheduleEditorOpen = false
    local configured = outputConfig(output)
    local fallback = tostring(configured.fallback_playlist or "")
    selectedPlaylistId = if type(playlistMap()[fallback]) == "table"
        and playlistMap()[fallback].quick_choice ~= true
        then fallback
        else sortedPlaylistIds(false)[1] or ""
    resetScheduleDraft(selectedPlaylistId)
    activePage = "main"
    activeSubpage = "display"
    render()
end

function panelPages.navigationButton(page, labelKey, glyph)
    return ui.button({
        key = "nav-page-" .. page,
        text = noctalia.tr(labelKey),
        glyph = glyph,
        variant = if activePage == page then "primary" else "ghost",
        controlSize = "sm",
        contentAlign = "start",
        width = 138,
        onClick = function()
            panelPages.selectPage(page)
        end,
    })
end

function panelPages.insetNavigationButton(key, text, selected, onClick, depth)
    local inset = if tonumber(depth) == 2 then 36 else 24
    local buttonWidth = if tonumber(depth) == 2 then 98 else 110
    return ui.row({ key = "nav-inset-row-" .. key, gap = 4, align = "center" }, {
        ui.box({ width = inset, height = 1, fill = "outline/0.35" }),
        ui.button({
            key = "nav-inset-" .. key,
            text = text,
            variant = if selected then "primary" else "ghost",
            controlSize = "sm",
            contentAlign = "start",
            width = buttonWidth,
            onClick = onClick,
        }),
    })
end

function panelPages.navigationColumn()
    local children = {
        panelPages.navigationButton("main", "panel.nav.main", "home"),
    }
    local outputs = panelPages.screenNames()
    for _, output in ipairs(outputs) do
        local name = output
        local selected = activePage == "main" and activeSubpage == "display" and selectedScreen == name
        table.insert(children, panelPages.insetNavigationButton(
            "screen-" .. name,
            name,
            selected,
            function()
                panelPages.selectScreenPage(name)
            end
        ))
    end
    table.insert(children, panelPages.navigationButton("library", "panel.nav.library", "library-photo"))
    for _, route in ipairs({
        { id = "images", label = "panel.nav.library_images" },
        { id = "videos", label = "panel.nav.library_videos" },
        { id = "workshops", label = "panel.nav.library_engine" },
    }) do
        local routeId = route.id
        table.insert(children, panelPages.insetNavigationButton(
            "library-" .. routeId,
            noctalia.tr(route.label),
            activePage == "library" and activeSubpage == routeId,
            function()
                panelPages.selectLibraryPage(routeId)
            end
        ))
    end
    table.insert(children, panelPages.navigationButton("shops", "panel.nav.shops", "shopping-bag"))
    for _, route in ipairs({
        { id = "wallhaven", label = "panel.nav.shop_wallhaven" },
        { id = "motionbgs", label = "panel.nav.shop_motionbgs" },
        { id = "steam", label = "panel.nav.shop_steam" },
    }) do
        local routeId = route.id
        table.insert(children, panelPages.insetNavigationButton(
            "shops-" .. routeId,
            noctalia.tr(route.label),
            activePage == "shops" and activeSubpage == routeId,
            function()
                panelPages.selectShopPage(routeId)
            end
        ))
    end
    table.insert(children, panelPages.navigationButton("playlists", "panel.nav.playlists", "playlist"))
    local playlistIds = sortedPlaylistIds(false)
    local playlistPages = math.max(1, math.ceil(#playlistIds / PLAYLIST_NAV_PAGE_SIZE))
    playlistNavigationPage = math.min(playlistPages, math.max(1, playlistNavigationPage))
    local firstPlaylist = (playlistNavigationPage - 1) * PLAYLIST_NAV_PAGE_SIZE + 1
    local lastPlaylist = math.min(#playlistIds, firstPlaylist + PLAYLIST_NAV_PAGE_SIZE - 1)
    for index = firstPlaylist, lastPlaylist do
        local playlistId = playlistIds[index]
        local id = playlistId
        local playlist = playlistMap()[id]
        table.insert(
            children,
            panelPages.insetNavigationButton(
                "playlist-" .. id,
                tostring(type(playlist) == "table" and playlist.name or id),
                activePage == "playlists" and selectedPlaylistId == id,
                function()
                    panelPages.selectPlaylistPage(id)
                end
            )
        )
    end
    if playlistPages > 1 then
        table.insert(children, ui.row({ key = "playlist-nav-pages", gap = 3, align = "center" }, {
            ui.button({
                glyph = "chevron-left",
                tooltip = noctalia.tr("panel.browse.previous"),
                variant = "ghost",
                controlSize = "sm",
                enabled = playlistNavigationPage > 1,
                onClick = function()
                    playlistNavigationPage = math.max(1, playlistNavigationPage - 1)
                    render()
                end,
            }),
            ui.label({
                text = tostring(playlistNavigationPage) .. "/" .. tostring(playlistPages),
                fontSize = 8,
                color = "on_surface_variant",
                align = "center",
                flexGrow = 1,
            }),
            ui.button({
                glyph = "chevron-right",
                tooltip = noctalia.tr("panel.browse.next"),
                variant = "ghost",
                controlSize = "sm",
                enabled = playlistNavigationPage < playlistPages,
                onClick = function()
                    playlistNavigationPage = math.min(playlistPages, playlistNavigationPage + 1)
                    render()
                end,
            }),
        }))
    end
    table.insert(children, panelPages.navigationButton("diagnostics", "panel.nav.diagnostics", "stethoscope"))
    return ui.scroll({ key = "wall-in-one-nav", width = 154, gap = 3, align = "stretch" }, children)
end

function panelPages.locationRequiredSection(kind, directAction)
    local isVideo = kind == "video"
    local _ready, path = panelUi.locationReady(kind)
    local children = {
        panelUi.sectionHeader(
            "folder-cog",
            noctalia.tr("panel.setup.title"),
            if isVideo then noctalia.tr("panel.setup.video_required") else noctalia.tr("panel.setup.image_required")
        ),
        panelUi.pathRow(
            if isVideo then "movie" else "photo",
            if isVideo then noctalia.tr("panel.storage.video_root") else noctalia.tr("panel.storage.image_root"),
            path,
            false
        ),
        ui.button({
            text = noctalia.tr("panel.setup.open_settings"),
            glyph = "settings",
            variant = "primary",
            controlSize = "sm",
            onClick = "onSettings",
        }),
    }
    if tostring(directAction or "") ~= "" then
        table.insert(children, ui.separator())
        table.insert(children, ui.label({
            text = noctalia.tr("panel.setup.direct_link_note"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 3,
        }))
        table.insert(children, panelUi.actionButton(directAction, "external-link", "ghost", true))
    end
    return panelUi.card(children)
end

function panelPages.steamShopSection()
    return panelUi.card({
        panelUi.sectionHeader("steam", noctalia.tr("panel.steam.title"), noctalia.tr("panel.steam.description")),
        panelUi.actionButton("steam_launch", "steam", "primary", true),
        panelUi.actionButton("steam_workshop", "external-link", "ghost", true),
        ui.separator(),
        ui.label({
            text = noctalia.tr("panel.steam.library_note"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 3,
        }),
        ui.button({
            text = noctalia.tr("panel.steam.open_library"),
            glyph = "library-photo",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                panelPages.selectLibraryPage("workshops")
            end,
        }),
    })
end

function panelPages.homeSection()
    local backendSetupCard = if preview.backendAvailable() then nil else panelUi.backendSetupCard()
    local imageReady, imageRoot = panelUi.locationReady("image")
    local videoReady, videoRoot = panelUi.locationReady("video")
    if not imageReady or not videoReady then
        local locationCard = panelUi.card({
            panelUi.sectionHeader("folder-cog", noctalia.tr("panel.setup.title"), noctalia.tr("panel.setup.home_required")),
            panelUi.pathRow("photo", noctalia.tr("panel.storage.image_root"), imageRoot, imageReady),
            panelUi.pathRow("movie", noctalia.tr("panel.storage.video_root"), videoRoot, videoReady),
            ui.label({
                text = noctalia.tr("panel.setup.no_hidden_work"),
                fontSize = 9,
                color = "tertiary",
                maxLines = 4,
            }),
            ui.button({
                text = noctalia.tr("panel.setup.open_settings"),
                glyph = "folder-cog",
                variant = "primary",
                controlSize = "sm",
                onClick = "onSettings",
            }),
        })
        return if backendSetupCard ~= nil
            then ui.column({ gap = 10, align = "stretch" }, { backendSetupCard, locationCard })
            else locationCard
    end

    local output = panelPages.ensureSelectedScreen()
    local names = panelPages.screenNames()
    local selectedIndex = 0
    for index, name in ipairs(names) do
        if name == output then
            selectedIndex = index - 1
            break
        end
    end
    local allPairs = type(status) == "table" and type(status.pairs) == "table" and status.pairs or {}
    local pair = type(allPairs[output]) == "table" and allPairs[output] or allPairs.all
    local stillPath = type(pair) == "table" and tostring(pair.still_path or "") or ""
    local children = {
        panelUi.sectionHeader("home", noctalia.tr("panel.home.title"), noctalia.tr("panel.home.description")),
    }
    if #names > 0 then
        table.insert(children, ui.select({
            key = "home-output",
            options = names,
            selectedIndex = selectedIndex,
            onChange = function(index)
                panelPages.selectScreenPage(names[math.floor(tonumber(index) or 0) + 1] or output)
            end,
        }))
    end
    table.insert(children, panelUi.compactRendererControls(output))
    table.insert(children, ui.separator())
    table.insert(children, ui.row({ gap = 8, align = "center" }, {
        panelUi.libraryThumbnail("static", stillPath, type(pair) == "table"),
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({
                text = if type(pair) == "table" then noctalia.tr("panel.home.current_pairing") else noctalia.tr("panel.home.no_pairing"),
                fontSize = 11,
                fontWeight = "bold",
                maxLines = 2,
            }),
            ui.label({
                text = if type(pair) == "table"
                    then tostring(pair.provider or "") .. " · " .. basename(stillPath)
                    else noctalia.tr("panel.home.choose_library"),
                fontSize = 9,
                color = "on_surface_variant",
                maxLines = 3,
            }),
        }),
    }))
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
        ui.button({
            text = noctalia.tr("panel.nav.screens"),
            glyph = "device-desktop",
            variant = "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                panelPages.selectScreenPage(output)
            end,
        }),
        ui.button({
            text = noctalia.tr("panel.nav.library"),
            glyph = "library-photo",
            variant = "primary",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                panelPages.selectLibraryPage("images")
            end,
        }),
    }))
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
        ui.button({
            text = noctalia.tr("panel.nav.shops"),
            glyph = "shopping-bag",
            variant = "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                panelPages.selectShopPage("wallhaven")
            end,
        }),
        ui.button({
            text = noctalia.tr("panel.nav.playlists"),
            glyph = "playlist",
            variant = "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                panelPages.selectPage("playlists")
            end,
        }),
    }))
    local homeCard = panelUi.card(children)
    return if backendSetupCard ~= nil
        then ui.column({ gap = 10, align = "stretch" }, { backendSetupCard, homeCard })
        else homeCard
end

function panelPages.selectedScreenPlaylist(output)
    local configured = outputConfig(output)
    local fallback = tostring(configured.fallback_playlist or "")
    if type(playlistMap()[fallback]) == "table" and playlistMap()[fallback].quick_choice ~= true then
        return fallback
    end
    if type(playlistMap()[selectedPlaylistId]) == "table" and playlistMap()[selectedPlaylistId].quick_choice ~= true then
        return selectedPlaylistId
    end
    return sortedPlaylistIds(false)[1] or ""
end

function panelPages.effectiveScreenPlayback(output, playlist)
    local configured = outputConfig(output)
    local configuredOrder = tostring(configured.order or "")
    local playlistOrder = tostring(type(playlist) == "table" and playlist.order or "")
    local globalOrder = tostring(settings().cycle_order or "")
    local order = if configuredOrder == "shuffle"
        then "shuffle"
        elseif configuredOrder == "rotate" then "rotate"
        elseif playlistOrder == "shuffle" then "shuffle"
        elseif playlistOrder == "rotate" then "rotate"
        elseif globalOrder == "shuffle" then "shuffle"
        else "rotate"

    local configuredInterval = tonumber(configured.interval_seconds)
    local playlistInterval = tonumber(type(playlist) == "table" and playlist.interval_seconds or nil)
    local globalInterval = math.floor((tonumber(settings().cycle_interval_minutes) or 15) * 60)
    local intervalSeconds = configuredInterval or playlistInterval or globalInterval
    intervalSeconds = math.max(60, math.min(30 * 24 * 60 * 60, math.floor(intervalSeconds)))
    local inherited = configured.order == nil and configured.interval_seconds == nil
    return order, intervalSeconds, inherited
end

function panelPages.screenPlaybackSection(output, playlist)
    local effectiveOrder, intervalSeconds, inherited = panelPages.effectiveScreenPlayback(output, playlist)
    local selectedOrder = if screenOrderDraft == "shuffle" or screenOrderDraft == "rotate"
        then screenOrderDraft
        else effectiveOrder
    local intervalMinutes = math.max(1, math.floor(intervalSeconds / 60))
    local intervalValue = if screenIntervalDraft ~= "" then screenIntervalDraft else tostring(intervalMinutes)
    return ui.column({ gap = 7, align = "stretch" }, {
        ui.separator(),
        ui.label({
            text = noctalia.tr("panel.screens.playback"),
            fontSize = 11,
            fontWeight = "bold",
        }),
        ui.column({ gap = 4, align = "stretch" }, {
            ui.button({
                text = noctalia.tr("panel.screens.playlist_defaults"),
                glyph = "link",
                variant = if inherited then "primary" else "ghost",
                controlSize = "sm",
                enabled = output ~= "" and storageValid(),
                onClick = function()
                    if not inherited then
                        screenIntervalDraft = ""
                        screenOrderDraft = ""
                        send({ kind = "output_options", output = output, inherit = true })
                    end
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.screens.override"),
                glyph = "settings",
                variant = if inherited then "ghost" else "primary",
                controlSize = "sm",
                enabled = output ~= "" and storageValid(),
                onClick = function()
                    if inherited then
                        screenIntervalDraft = ""
                        screenOrderDraft = ""
                        send({
                            kind = "output_options",
                            output = output,
                            interval_seconds = intervalSeconds,
                            order = effectiveOrder,
                            inherit = false,
                        })
                    end
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.column({ gap = 2, width = 115, align = "stretch" }, {
                ui.label({
                    text = noctalia.tr("panel.screens.interval"),
                    fontSize = 8,
                    color = "on_surface_variant",
                }),
                ui.input({
                    key = "screen-interval-" .. output,
                    value = intervalValue,
                    placeholder = noctalia.tr("panel.playlists.interval_placeholder", {
                        minutes = tostring(intervalMinutes),
                    }),
                    enabled = not inherited,
                    onChange = function(value)
                        screenIntervalDraft = tostring(value or "")
                        render()
                    end,
                }),
            }),
            ui.column({ gap = 2, flexGrow = 1, align = "stretch" }, {
                ui.label({
                    text = noctalia.tr("panel.screens.order"),
                    fontSize = 8,
                    color = "on_surface_variant",
                }),
                ui.select({
                    key = "screen-order-" .. output,
                    options = {
                        noctalia.tr("panel.playlists.order_rotate"),
                        noctalia.tr("panel.playlists.order_shuffle"),
                    },
                    selectedIndex = if selectedOrder == "shuffle" then 1 else 0,
                    enabled = not inherited,
                    onChange = function(index)
                        screenOrderDraft = if math.floor(tonumber(index) or 0) == 1 then "shuffle" else "rotate"
                        render()
                    end,
                }),
            }),
        }),
        ui.button({
            text = noctalia.tr("panel.screens.save_playback"),
            glyph = "device-floppy",
            variant = "ghost",
            controlSize = "sm",
            enabled = not inherited and storageValid(),
            onClick = function()
                local currentIntervalValue = if screenIntervalDraft ~= ""
                    then screenIntervalDraft
                    else intervalValue
                local minutes = math.max(
                    1,
                    math.min(43200, math.floor(tonumber(currentIntervalValue) or intervalMinutes))
                )
                screenIntervalDraft = tostring(minutes)
                screenOrderDraft = selectedOrder
                send({
                    kind = "output_options",
                    output = output,
                    interval_seconds = minutes * 60,
                    order = selectedOrder,
                    inherit = false,
                })
            end,
        }),
    })
end

function panelPages.engineDraft(output)
    local cached = panelPages.engineDrafts[output]
    if type(cached) == "table" then
        return cached
    end
    local configuration = settings()
    local engines = type(outputConfig(output).engines) == "table" and outputConfig(output).engines or {}
    local video = type(engines.video) == "table" and engines.video or {}
    local workshop = type(engines.workshop) == "table" and engines.workshop or {}
    local flags = type(workshop.flags) == "table" and workshop.flags or {}
    cached = {
        layer = tostring(engines.layer or "bottom"),
        video = {
            enabled = video.enabled ~= false,
            mute = if video.mute ~= nil then video.mute == true else configuration.mpv_mute ~= false,
            hardware_decode = if video.hardware_decode ~= nil
                then video.hardware_decode == true
                else configuration.mpv_hardware_decode ~= false,
            auto_pause = if video.auto_pause ~= nil then video.auto_pause == true else configuration.mpv_auto_pause ~= false,
            auto_pause_mode = tostring(video.auto_pause_mode or "FULL"),
            options = tostring(video.options or configuration.mpv_options or ""),
        },
        workshop = {
            enabled = workshop.enabled ~= false,
            fps = tostring(workshop.fps or configuration.w_engine_fps or 30),
            volume = tostring(workshop.volume or configuration.w_engine_volume or 0),
            silent = if workshop.silent ~= nil then workshop.silent == true else configuration.w_engine_silent ~= false,
            scaling = tostring(workshop.scaling or configuration.w_engine_scaling or "fill"),
            clamp = tostring(workshop.clamp or configuration.w_engine_clamp or "border"),
            flags = {
                noautomute = if flags.noautomute ~= nil then flags.noautomute == true else configuration.w_engine_noautomute == true,
                no_audio_processing = if flags.no_audio_processing ~= nil
                    then flags.no_audio_processing == true
                    else configuration.w_engine_no_audio_processing == true,
                disable_particles = if flags.disable_particles ~= nil
                    then flags.disable_particles == true
                    else configuration.w_engine_disable_particles == true,
                disable_mouse = if flags.disable_mouse ~= nil
                    then flags.disable_mouse == true
                    else configuration.w_engine_disable_mouse == true,
                disable_parallax = if flags.disable_parallax ~= nil
                    then flags.disable_parallax == true
                    else configuration.w_engine_disable_parallax == true,
                no_fullscreen_pause = if flags.no_fullscreen_pause ~= nil
                    then flags.no_fullscreen_pause == true
                    else configuration.w_engine_no_fullscreen_pause == true,
                fullscreen_pause_only_active = if flags.fullscreen_pause_only_active ~= nil
                    then flags.fullscreen_pause_only_active == true
                    else configuration.w_engine_fullscreen_pause_only_active == true,
            },
        },
    }
    panelPages.engineDrafts[output] = cached
    return cached
end

function panelPages.engineToggle(label, value, onClick)
    return ui.button({
        text = label,
        glyph = if value then "check" else "x",
        variant = if value then "primary" else "ghost",
        controlSize = "sm",
        flexGrow = 1,
        onClick = onClick,
    })
end

function panelPages.engineSettingsSection(output)
    local draft = panelPages.engineDraft(output)
    local video = draft.video
    local workshop = draft.workshop
    local flags = workshop.flags
    local children = {
        panelUi.sectionHeader("settings", noctalia.tr("panel.engines.title"), noctalia.tr("panel.engines.description", { output = output })),
        ui.row({ gap = 6, align = "center" }, {
            ui.button({
                text = noctalia.tr("panel.engines.video"),
                glyph = "movie",
                variant = if panelPages.engineMode == "video" then "primary" else "ghost",
                controlSize = "sm",
                flexGrow = 1,
                onClick = function()
                    panelPages.engineMode = "video"
                    render()
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.engines.workshop"),
                glyph = "steam",
                variant = if panelPages.engineMode == "workshop" then "primary" else "ghost",
                controlSize = "sm",
                flexGrow = 1,
                onClick = function()
                    panelPages.engineMode = "workshop"
                    render()
                end,
            }),
        }),
        ui.label({ text = noctalia.tr("panel.engines.layer"), fontSize = 9, color = "on_surface_variant" }),
        ui.select({
            key = "engine-layer-" .. output,
            options = { noctalia.tr("panel.engines.layer_bottom"), noctalia.tr("panel.engines.layer_background") },
            selectedIndex = if draft.layer == "background" then 1 else 0,
            onChange = function(index)
                draft.layer = if math.floor(tonumber(index) or 0) == 1 then "background" else "bottom"
                render()
            end,
        }),
        ui.separator(),
    }
    if panelPages.engineMode == "video" then
        table.insert(children, ui.row({ gap = 6, align = "center" }, {
            panelPages.engineToggle(noctalia.tr("panel.engines.enabled"), video.enabled, function()
                video.enabled = not video.enabled
                render()
            end),
            panelPages.engineToggle(noctalia.tr("panel.engines.mute"), video.mute, function()
                video.mute = not video.mute
                render()
            end),
        }))
        table.insert(children, ui.row({ gap = 6, align = "center" }, {
            panelPages.engineToggle(noctalia.tr("panel.engines.hardware_decode"), video.hardware_decode, function()
                video.hardware_decode = not video.hardware_decode
                render()
            end),
            panelPages.engineToggle(noctalia.tr("panel.engines.auto_pause"), video.auto_pause, function()
                video.auto_pause = not video.auto_pause
                render()
            end),
        }))
        table.insert(children, ui.select({
            key = "engine-video-pause-mode-" .. output,
            options = {
                noctalia.tr("panel.engines.pause_full"),
                noctalia.tr("panel.engines.pause_max"),
                noctalia.tr("panel.engines.pause_active"),
            },
            selectedIndex = if video.auto_pause_mode == "MAX" then 1 elseif video.auto_pause_mode == "ACTIVE" then 2 else 0,
            enabled = video.auto_pause,
            onChange = function(index)
                video.auto_pause_mode = ({ "FULL", "MAX", "ACTIVE" })[math.floor(tonumber(index) or 0) + 1] or "FULL"
                render()
            end,
        }))
        table.insert(children, ui.input({
            key = "engine-video-options-" .. output,
            value = video.options,
            placeholder = noctalia.tr("panel.engines.options"),
            onChange = function(value)
                video.options = tostring(value or "")
            end,
        }))
    else
        table.insert(children, ui.row({ gap = 6, align = "center" }, {
            panelPages.engineToggle(noctalia.tr("panel.engines.enabled"), workshop.enabled, function()
                workshop.enabled = not workshop.enabled
                render()
            end),
            panelPages.engineToggle(noctalia.tr("panel.engines.silent"), workshop.silent, function()
                workshop.silent = not workshop.silent
                render()
            end),
        }))
        table.insert(children, ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "engine-workshop-fps-" .. output,
                value = workshop.fps,
                placeholder = noctalia.tr("panel.engines.fps"),
                flexGrow = 1,
                onChange = function(value)
                    workshop.fps = tostring(value or "")
                end,
            }),
            ui.input({
                key = "engine-workshop-volume-" .. output,
                value = workshop.volume,
                placeholder = noctalia.tr("panel.engines.volume"),
                flexGrow = 1,
                onChange = function(value)
                    workshop.volume = tostring(value or "")
                end,
            }),
        }))
        table.insert(children, ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "engine-workshop-scaling-" .. output,
                options = {
                    noctalia.tr("panel.engines.scale_default"),
                    noctalia.tr("panel.engines.scale_stretch"),
                    noctalia.tr("panel.engines.scale_fit"),
                    noctalia.tr("panel.engines.scale_fill"),
                },
                selectedIndex = if workshop.scaling == "stretch"
                    then 1
                    elseif workshop.scaling == "fit" then 2
                    elseif workshop.scaling == "fill" then 3
                    else 0,
                flexGrow = 1,
                onChange = function(index)
                    workshop.scaling = ({ "default", "stretch", "fit", "fill" })[math.floor(tonumber(index) or 0) + 1]
                        or "fill"
                    render()
                end,
            }),
            ui.select({
                key = "engine-workshop-clamp-" .. output,
                options = {
                    noctalia.tr("panel.engines.clamp"),
                    noctalia.tr("panel.engines.border"),
                    noctalia.tr("panel.engines.repeat_texture"),
                },
                selectedIndex = if workshop.clamp == "clamp" then 0 elseif workshop.clamp == "repeat" then 2 else 1,
                flexGrow = 1,
                onChange = function(index)
                    workshop.clamp = ({ "clamp", "border", "repeat" })[math.floor(tonumber(index) or 0) + 1] or "border"
                    render()
                end,
            }),
        }))
        for _, pair in ipairs({
            { "noautomute", "panel.engines.noautomute", "no_audio_processing", "panel.engines.no_audio_processing" },
            { "disable_particles", "panel.engines.disable_particles", "disable_mouse", "panel.engines.disable_mouse" },
            { "disable_parallax", "panel.engines.disable_parallax", "no_fullscreen_pause", "panel.engines.no_fullscreen_pause" },
        }) do
            local firstKey, firstLabel, secondKey, secondLabel = pair[1], pair[2], pair[3], pair[4]
            table.insert(children, ui.row({ gap = 6, align = "center" }, {
                panelPages.engineToggle(noctalia.tr(firstLabel), flags[firstKey] == true, function()
                    flags[firstKey] = flags[firstKey] ~= true
                    render()
                end),
                panelPages.engineToggle(noctalia.tr(secondLabel), flags[secondKey] == true, function()
                    flags[secondKey] = flags[secondKey] ~= true
                    render()
                end),
            }))
        end
        table.insert(children, panelPages.engineToggle(
            noctalia.tr("panel.engines.fullscreen_pause_only_active"),
            flags.fullscreen_pause_only_active == true,
            function()
                flags.fullscreen_pause_only_active = flags.fullscreen_pause_only_active ~= true
                render()
            end
        ))
    end
    table.insert(children, ui.separator())
    table.insert(children, ui.button({
        text = noctalia.tr("panel.engines.save"),
        glyph = "device-floppy",
        variant = "primary",
        controlSize = "sm",
        enabled = storageValid() and output ~= "",
        onClick = function()
            workshop.fps = math.max(5, math.min(144, math.floor(tonumber(workshop.fps) or 30)))
            workshop.volume = math.max(0, math.min(100, math.floor(tonumber(workshop.volume) or 0)))
            if flags.no_fullscreen_pause and flags.fullscreen_pause_only_active then
                flags.fullscreen_pause_only_active = false
            end
            send({ kind = "output_engines", output = output, engines = draft })
            panelPages.engineDrafts[output] = nil
        end,
    }))
    return panelUi.card(children)
end

function panelPages.screensSection()
    local output = panelPages.ensureSelectedScreen()
    if output == "" then
        return panelUi.card({
            panelUi.sectionHeader("device-desktop", noctalia.tr("panel.nav.screens"), noctalia.tr("availability.output")),
        })
    end
    local playlistId = panelPages.selectedScreenPlaylist(output)
    local playlist = playlistMap()[playlistId]
    local children = {
        panelUi.sectionHeader("device-desktop", noctalia.tr("panel.nav.screens"), output),
        ui.label({
            text = noctalia.tr("panel.screens.description"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 3,
        }),
        panelUi.compactRendererControls(output),
        panelPages.screenPlaybackSection(output, playlist),
        ui.separator(),
        ui.label({
            text = noctalia.tr("panel.screens.automation"),
            fontSize = 12,
            fontWeight = "bold",
        }),
        ui.label({
            text = noctalia.tr("panel.screens.automation_description"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 3,
        }),
        panelUi.displayPlaylistLibrary(output),
        ui.separator(),
        schedulesSection(output, playlistId),
    }
    return panelUi.card(children)
end

function panelPages.activePageSections()
    if activePage == "library" then
        local kind = if activeSubpage == "videos" then "video" elseif activeSubpage == "workshops" then "workshop" else "static"
        local requiredRoot = if kind == "video" then "video" else "image"
        if not panelUi.locationReady(requiredRoot) then
            return { panelPages.locationRequiredSection(requiredRoot, nil) }
        end
        local editor = if pairingEditorOpen and pairingEditorKind == kind then pairingEditor(kind) else nil
        return { librarySection(if kind == "video" then "videos" elseif kind == "workshop" then "workshops" else "stills", editor) }
    elseif activePage == "shops" then
        if activeSubpage == "motionbgs" then
            if not panelUi.locationReady("video") then
                return { panelPages.locationRequiredSection("video", "motionbgs_open") }
            end
            return { motionBgsSection() }
        elseif activeSubpage == "steam" then
            return { panelPages.steamShopSection() }
        end
        if not panelUi.locationReady("image") then
            return { panelPages.locationRequiredSection("image", "wallhaven_site") }
        end
        return { wallhavenSection() }
    elseif activePage == "playlists" then
        return { playlistsSection(panelPages.ensureSelectedScreen()) }
    elseif activePage == "diagnostics" then
        return { diagnosticsSection() }
    end
    if activeSubpage == "display" then
        local output = panelPages.ensureSelectedScreen()
        return { panelPages.screensSection(), panelPages.engineSettingsSection(output) }
    end
    return { panelPages.homeSection() }
end

function panelPages.renderNow()
    if not isOpen then
        return
    end
    panel.render(ui.column({ gap = 10, padding = 14, align = "stretch", flexGrow = 1 }, {
        ui.row({ gap = 9, align = "center" }, {
            ui.glyph({ name = "library-photo", color = "primary", size = 22 }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = noctalia.tr("plugin.title"), fontSize = 16, fontWeight = "bold" }),
                ui.label({ text = noctalia.tr("panel.subtitle"), fontSize = 10, color = "on_surface_variant" }),
            }),
            ui.button({
                glyph = "settings",
                variant = "ghost",
                tooltip = noctalia.tr("panel.settings"),
                onClick = "onSettings",
            }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onClose" }),
        }),
        ui.separator(),
        ui.row({ flexGrow = 1, gap = 10, align = "stretch" }, {
            panelPages.navigationColumn(),
            ui.scroll({
                key = "wall-in-one-page-"
                    .. activePage
                    .. "-"
                    .. activeSubpage
                    .. "-"
                    .. selectedPlaylistId
                    .. "-"
                    .. selectedScreen,
                flexGrow = 1,
                align = "stretch",
                gap = 10,
            }, panelPages.activePageSections()),
        }),
    }))
end

render = function()
    if isOpen then
        preview.requestRender()
    end
end

function onOpen(_context)
    preview.cancel()
    pendingDeleteItemId = ""
    pendingDeletePlaylistId = ""
    pendingResetPairingId = ""
    pairingEditorOpen = false
    editingPairingId = ""
    playlistEntryEditorOpen = false
    editingPlaylistEntryId = ""
    editingPlaylistEntryPairingId = ""
    editingPlaylistEntryPlaylistId = ""
    editingPlaylistEntryIndex = 0
    scheduleEditorOpen = false
    screenIntervalDraft = ""
    screenOrderDraft = ""
    resetPanelVisibility()
    reloadSharedState()
    activePage = if panelPages.validPages[activePage] then activePage else "main"
    if activePage == "library" and not panelPages.validLibrarySubpages[activeSubpage] then
        activeSubpage = "images"
    elseif activePage == "shops" and not panelPages.validShopSubpages[activeSubpage] then
        activeSubpage = "wallhaven"
    end
    panelPages.ensureSelectedScreen()
    resetScheduleDraft(selectedPlaylistId)
    isOpen = true
    render()
end

function onClose()
    isOpen = false
    -- Removing the current RPC guard is deferred to update(); the async
    -- callback itself only queues its completion for bounded cleanup there.
    preview.close()
    panel.close()
end

function onSettings()
    isOpen = false
    preview.close()
    panel.close()
    noctalia.openSettings()
end

function update()
    preview.refreshClock()
    if isOpen and preview.retryDue() then
        preview.retry()
    end
    local _, redraw = preview.step()
    if redraw then
        preview.requestRender()
    end
    if preview.takeRender() then
        panelPages.renderNow()
    end
    local stillChoiceWork = isOpen
        and (
            (playlistEntryEditorOpen and playlistEntrySourceKind == "static")
            or (
                (pairingEditorOpen or playlistEntryEditorOpen)
                and entryMediaKindDraft ~= "static"
                and entryStillModeDraft == "selected"
            )
        )
        and panelUi.pairingStillChoiceWork()
    local workshopIndexWork = isOpen and panelUi.workshopIndexWork()
    local paletteIndexWork = isOpen and paletteEntryIndexWork()
    preview.settle(isOpen and (dragTokensDirty or stillChoiceWork or workshopIndexWork or paletteIndexWork))
end

function onFrameTick(_deltaMs)
    -- Frame callbacks are reserved for bounded presentation-data reconcilers.
    -- Provider RPC completion and every full UI render run only from update().
    preview.refreshClock()
    if isOpen and dragTokensDirty then
        if stepDragTokenReconciliation() then
            render()
        end
    end
    local stillChoiceWork = isOpen
        and (
            (playlistEntryEditorOpen and playlistEntrySourceKind == "static")
            or (
                (pairingEditorOpen or playlistEntryEditorOpen)
                and entryMediaKindDraft ~= "static"
                and entryStillModeDraft == "selected"
            )
        )
        and panelUi.pairingStillChoiceWork()
    if stillChoiceWork and panelUi.stepPairingStillChoiceReconciliation() then
        render()
    end
    local workshopIndexWork = isOpen and panelUi.workshopIndexWork()
    if workshopIndexWork and panelUi.stepWorkshopIndexReconciliation() then
        render()
    end
    local paletteIndexWork = isOpen and paletteEntryIndexWork()
    if paletteIndexWork and stepPaletteEntryIndexReconciliation() then
        render()
    end
    preview.settle(isOpen and (dragTokensDirty or stillChoiceWork or workshopIndexWork or paletteIndexWork))
end

function onIpc(event, payload)
    if event == "probe" then
        send({ kind = "probe" })
    elseif event == "capture-video" then
        runAction("video_capture")
    elseif event == "capture-video-pair" then
        runAction("video_capture_pair")
    elseif event == "capture-backing" then
        runAction("capture_backing")
    elseif event == "capture-w-engine" then
        runAction("capture_current")
    elseif event == "capture-w-engine-pair" then
        runAction("capture_pair")
    elseif event == "pair-manual" then
        runAction("manual_pair")
    else
        noctalia.log("wall-in-one panel: unknown IPC event '" .. tostring(event) .. "'")
    end
end

local function adoptLifecycle(nextStatus)
    if type(nextStatus) ~= "table" then
        return false
    end
    if tonumber(nextStatus.protocol) == 4 then
        local instance = tostring(nextStatus.instance_id or "")
        local sequence = tonumber(nextStatus.sequence)
        if instance == "" or sequence == nil or sequence < 0 or sequence ~= math.floor(sequence) then
            return false
        end
        if
            type(lifecycleStatus) == "table"
            and tonumber(lifecycleStatus.protocol) == 4
            and tostring(lifecycleStatus.instance_id or "") == instance
            and sequence <= (tonumber(lifecycleStatus.sequence) or -1)
        then
            return false
        end
    end
    lifecycleStatus = nextStatus
    return true
end

local function adoptDomain(current, candidate)
    if type(candidate) ~= "table" or tonumber(candidate.protocol) ~= 1 then
        return current, false
    end
    local instance = tostring(candidate.instance_id or "")
    local revision = tonumber(candidate.revision)
    if instance == "" or revision == nil or revision < 1 or revision ~= math.floor(revision) then
        return current, false
    end
    if
        type(lifecycleStatus) == "table"
        and tonumber(lifecycleStatus.protocol) == 4
        and instance ~= tostring(lifecycleStatus.instance_id or "")
    then
        return current, false
    end
    if
        type(current) == "table"
        and tostring(current.instance_id or "") == instance
        and revision <= (tonumber(current.revision) or 0)
    then
        return current, false
    end
    return candidate, true
end

refreshPanelState = function()
    status = composeStatus()
    resolveSelectedPlaylist(if selectedScreen ~= "" then selectedScreen else nil)
    if isOpen then
        render()
    end
end

reloadSharedState = function()
    preview.setBackendStatus(noctalia.state.get(preview.backendStatusKey))
    lifecycleStatus = noctalia.state.get(STATUS_KEY)
    configState = noctalia.state.get(CONFIG_STATE_KEY)
    runtimeState = noctalia.state.get(RUNTIME_STATE_KEY)
    libraryState = noctalia.state.get(LIBRARY_STATE_KEY)
    rendererState = noctalia.state.get(RENDERER_STATUS_KEY)
    motionBgsState = noctalia.state.get(MOTIONBGS_STATUS_KEY)
    motionBgsResultsState = noctalia.state.get(MOTIONBGS_RESULTS_KEY)
    providerResultEpochs.motionbgs += 1
    palettesState = noctalia.state.get(PALETTES_STATUS_KEY)
    wallhavenState = noctalia.state.get(WALLHAVEN_STATUS_KEY)
    wallhavenResultsState = noctalia.state.get(WALLHAVEN_RESULTS_KEY)
    providerResultEpochs.wallhaven += 1
    status = composeStatus()
    resolveSelectedPlaylist(if selectedScreen ~= "" then selectedScreen else nil)
    markDragTokensDirty()
end

preview.initializeScheduler()
noctalia.state.watch(STATUS_KEY, function(nextStatus)
    if adoptLifecycle(nextStatus) then
        -- A service instance change can race the domain callbacks. Re-read the
        -- persistent slots; composeStatus accepts only the matching instance.
        local previousConfigRevision = type(configState) == "table" and tonumber(configState.revision) or -1
        configState = noctalia.state.get(CONFIG_STATE_KEY)
        if type(configState) == "table" and tonumber(configState.revision) ~= previousConfigRevision then
            closePlaylistEntryEditor()
            markDragTokensDirty()
        end
        runtimeState = noctalia.state.get(RUNTIME_STATE_KEY)
        libraryState = noctalia.state.get(LIBRARY_STATE_KEY)
        refreshPanelState()
    end
end)
-- Coordinator domains are committed before their lifecycle status. Adopt
-- each revision here, then let the following STATUS_KEY event coalesce those
-- changes into one panel rebuild. Its callback also re-reads all three slots,
-- so a delayed domain callback cannot leave the rendered view behind.
noctalia.state.watch(CONFIG_STATE_KEY, function(nextState)
    local adopted, changed = adoptDomain(configState, nextState)
    configState = adopted
    if changed then
        closePlaylistEntryEditor()
        markDragTokensDirty()
    end
end)
noctalia.state.watch(RUNTIME_STATE_KEY, function(nextState)
    runtimeState = adoptDomain(runtimeState, nextState)
end)
noctalia.state.watch(LIBRARY_STATE_KEY, function(nextState)
    local adopted, changed = adoptDomain(libraryState, nextState)
    libraryState = adopted
    if changed then
        resetLibraryDragTokens()
    end
end)
noctalia.state.watch(RENDERER_STATUS_KEY, function(nextState)
    rendererState = nextState
    refreshPanelState()
end)
noctalia.state.watch(preview.backendStatusKey, function(nextState)
    if preview.setBackendStatus(nextState) and isOpen then
        render()
    end
end)
noctalia.state.watch(MOTIONBGS_STATUS_KEY, function(nextState)
    motionBgsState = nextState
    if type(nextState) ~= "table" or nextState.available ~= true then
        preview.cancel()
    end
    refreshPanelState()
end)
noctalia.state.watch(MOTIONBGS_RESULTS_KEY, function(nextState)
    preview.cancel()
    motionBgsResultsState = nextState
    providerResultEpochs.motionbgs += 1
    providerResultPages.motionbgs = 1
    refreshPanelState()
end)
noctalia.state.watch(PALETTES_STATUS_KEY, function(nextState)
    palettesState = nextState
    refreshPanelState()
end)
noctalia.state.watch(WALLHAVEN_STATUS_KEY, function(nextState)
    wallhavenState = nextState
    if type(nextState) ~= "table" or nextState.available ~= true then
        preview.cancel()
    end
    refreshPanelState()
end)
noctalia.state.watch(WALLHAVEN_RESULTS_KEY, function(nextState)
    preview.cancel()
    wallhavenResultsState = nextState
    providerResultEpochs.wallhaven += 1
    providerResultPages.wallhaven = 1
    refreshPanelState()
end)
reloadSharedState()

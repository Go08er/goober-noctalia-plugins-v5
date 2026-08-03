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
local entryEditorOpen = false
local editingEntryId = ""
local entryLabelDraft = ""
local entryMediaKindDraft = "static"
local entryMediaSourceDraft = ""
local entryStillModeDraft = "automatic"
local entryStillPathDraft = ""
local entryThemeModeDraft = "inherit"
local entryThemeSourceDraft = "inherit"
local entryThemeSelectionDraft = ""
local entryAddedAtDraft = ""
local playlistVisibleEntries = PLAYLIST_ENTRY_CHUNK
local wallhavenVisibleResults = PROVIDER_RESULT_CHUNK
local motionBgsVisibleResults = PROVIDER_RESULT_CHUNK
local libraryVisibleStills = LIBRARY_ENTRY_CHUNK
local libraryVisibleVideos = LIBRARY_ENTRY_CHUNK
local libraryVisibleWorkshops = LIBRARY_ENTRY_CHUNK

local pairingEditorOpen = false
local pairingEditorKind = "static"
local editingPairingId = ""
local pairingEditorRevision = 0
local pendingDeletePairingId = ""
local pairingVisibleStills = PAIRING_CARD_CHUNK
local pairingVisibleVideos = PAIRING_CARD_CHUNK
local pairingVisibleWorkshops = PAIRING_CARD_CHUNK
local adaptivePreviewSequence = 0
local adaptivePreviewInstance = ""
local adaptivePreviewKeys = {}
local adaptivePreviewStates = {}

-- Declarative drag payloads and drop values are deliberately short, opaque
-- panel-session tokens. Persistent pairing, playlist, and entry identifiers
-- stay in these lookup tables instead of crossing the UI drag channel.
local dragTokenSequence = 0
local dragPairingByToken = {}
local dragPairingTokenById = {}
local dragEntryByToken = {}
local dragEntryTokenByPlaylist = {}
local dragTargetByToken = {}
local dragTargetTokenByPlaylist = {}

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
local render
local refreshPanelState
local reloadSharedState

local preview = {}
do
-- Keep the implementation in a closed lexical scope. panel.luau is close to
-- Luau's 200-local register ceiling; only the small preview facade needs to
-- remain live for the rest of the entry file.
local PREVIEW_CACHE_SCHEMA = 1
local PREVIEW_MAX_CONCURRENT = 4
local PREVIEW_MAX_QUEUE = 32
local PREVIEW_MAX_FILE_BYTES = 2 * 1024 * 1024
local PREVIEW_MAX_CACHE_BYTES = 64 * 1024 * 1024
local PREVIEW_MAX_ENTRIES = 64
local PREVIEW_MAX_MANIFEST_BYTES = 64 * 1024
local PREVIEW_MAX_FAILURES = 64
local PREVIEW_RETRY_BASE_SECONDS = 15
local PREVIEW_RETRY_MAX_SECONDS = 300
local PREVIEW_RETRY_POLL_MS = 5000
local PREVIEW_PROTOCOL = "WIO-THUMB1"

-- Provider thumbnails are presentation data, so the panel owns their cache.
-- Noctalia creates one ScriptRuntime for this declared panel entry; repeated
-- widget placements do not create competing owners for this manifest.
-- Remote URLs never reach ui.image: a strict helper installs a bounded local
-- file first, and only that verified path is rendered. The manifest names
-- every file this cache may delete and keeps both entry count and bytes flat.
local previewCacheInitialized = false
local previewCacheReady = false
local previewCacheDirectory = ""
local previewManifestPath = ""
local previewHelperPath = ""
local previewCache = { schema = PREVIEW_CACHE_SCHEMA, entries = {} }
local previewPaths = {}
local previewQueue = {}
local previewQueued = {}
local previewPending = {}
local previewFailures = {}
local previewActive = 0
local previewSequence = 0
local previewFailureSequence = 0
local previewGeneration = 0
local previewInterest = 0
local previewScope = ""
local pumpPreviewQueue

local function previewNowSeconds()
    return math.max(0, math.floor(tonumber(noctalia.formatTime("%s")) or 0))
end

local function previewRetryReady(url)
    local failure = previewFailures[url]
    return type(failure) ~= "table"
        or previewNowSeconds() >= math.max(0, math.floor(tonumber(failure.retry_at) or 0))
end

local function previewRetryDue()
    local now = previewNowSeconds()
    for _, failure in pairs(previewFailures) do
        if
            type(failure) == "table"
            and tonumber(failure.generation) == previewGeneration
            and tonumber(failure.interest) == previewInterest
            and now >= math.max(0, math.floor(tonumber(failure.retry_at) or 0))
        then
            return true
        end
    end
    return false
end

local function clearPreviewFailure(url)
    previewFailures[url] = nil
end

local function recordPreviewFailure(url)
    local previous = previewFailures[url]
    local attempts = math.min(16, math.max(0, math.floor(tonumber(type(previous) == "table" and previous.attempts or 0) or 0)) + 1)
    local delay = math.min(PREVIEW_RETRY_MAX_SECONDS, PREVIEW_RETRY_BASE_SECONDS * (2 ^ math.min(5, attempts - 1)))
    previewFailureSequence += 1
    previewFailures[url] = {
        attempts = attempts,
        retry_at = previewNowSeconds() + delay,
        generation = previewGeneration,
        interest = previewInterest,
        sequence = previewFailureSequence,
    }

    local count = 0
    local oldestUrl = nil
    local oldestSequence = math.huge
    for candidateUrl, failure in pairs(previewFailures) do
        count += 1
        local sequence = math.max(0, math.floor(tonumber(type(failure) == "table" and failure.sequence or 0) or 0))
        if sequence < oldestSequence or (sequence == oldestSequence and tostring(candidateUrl) < tostring(oldestUrl or "")) then
            oldestUrl = candidateUrl
            oldestSequence = sequence
        end
    end
    if count > PREVIEW_MAX_FAILURES and oldestUrl ~= nil then
        previewFailures[oldestUrl] = nil
    end
end

local function resetPreviewQueue(scope)
    previewGeneration += 1
    previewQueue = {}
    previewQueued = {}
    if scope ~= nil then
        previewScope = tostring(scope)
    end
end

local function setPreviewScope(scope)
    local selected = tostring(scope or "")
    if selected ~= previewScope then
        resetPreviewQueue(selected)
    end
    -- This is a render-frame marker, separate from the request generation.
    -- Failures no longer represented by a visible card cannot wake retries.
    previewInterest += 1
end

local function previewAbsolutePath(value)
    return type(value) == "string"
        and #value > 1
        and #value <= 4096
        and value:sub(1, 1) == "/"
        and not value:find("[%c\\]")
        and not value:find("//", 1, true)
        and not value:find("/./", 1, true)
        and not value:find("/../", 1, true)
        and not value:match("/%.%.$")
        and not value:match("/%.$")
end

local function previewIdentifier(provider, value)
    if type(value) ~= "string" then
        return nil
    end
    local identifier = value:lower()
    if provider == "wallhaven" then
        return if #identifier == 6 and identifier:match("^[a-z0-9]+$") ~= nil then identifier else nil
    end
    if provider == "motionbgs" then
        return if #identifier >= 1
                and #identifier <= 120
                and identifier:match("^[a-z0-9][a-z0-9-]*$") ~= nil
            then identifier
            else nil
    end
    return nil
end

local function validPreviewUrl(provider, value)
    if
        type(value) ~= "string"
        or value == ""
        or #value > 2048
        or value:find("[%c\\#]") ~= nil
        or value:find("/../", 1, true) ~= nil
        or value:match("/%.%.$") ~= nil
    then
        return nil
    end
    if provider == "wallhaven" then
        local bucket, identifier, extension = value:match(
            "^https://th%.wallhaven%.cc/lg/([a-z0-9][a-z0-9])/([a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9])%.([a-z]+)$"
        )
        if
            identifier ~= nil
            and bucket == identifier:sub(1, 2)
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
            if
                width == nil
                or tonumber(width) > 4096
                or height == nil
                or tonumber(height) > 4096
            then
                return nil
            end
        end
        if
            mediaId ~= nil
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

local function previewKey(provider, identifier)
    local safe = previewIdentifier(provider, identifier)
    return if safe ~= nil then provider .. ":" .. safe else nil
end

local function previewOwnedFilename(value)
    if type(value) ~= "string" or value:find("[/\\%c]") ~= nil then
        return false
    end
    local provider, identifier, milliseconds, sequence, extension = value:match(
        "^(wallhaven)%-([a-z0-9]+)%-([0-9]+)%-([0-9]+)%.([a-z]+)$"
    )
    if provider == nil then
        provider, identifier, milliseconds, sequence, extension = value:match(
            "^(motionbgs)%-([a-z0-9][a-z0-9-]*)%-([0-9]+)%-([0-9]+)%.([a-z]+)$"
        )
    end
    return provider ~= nil
        and previewIdentifier(provider, identifier) ~= nil
        and #milliseconds <= 20
        and #sequence <= 12
        and (extension == "jpg" or extension == "png" or extension == "webp")
end

local function previewEntryPath(entry)
    local filename = type(entry) == "table" and tostring(entry.filename or "") or ""
    if not previewCacheReady or not previewOwnedFilename(filename) then
        return nil
    end
    local path = previewCacheDirectory .. "/" .. filename
    return if previewAbsolutePath(path) then path else nil
end

local function removePreviewEntry(key, removeFile)
    local entry = previewCache.entries[key]
    if type(entry) == "table" and removeFile == true then
        local path = previewEntryPath(entry)
        if path ~= nil and noctalia.fileExists(path) then
            noctalia.removeFile(path)
        end
    end
    previewCache.entries[key] = nil
    previewPaths[key] = nil
end

local function previewEntryValid(key, entry)
    if type(key) ~= "string" or type(entry) ~= "table" then
        return false
    end
    local provider, identifier = key:match("^(wallhaven):([a-z0-9]+)$")
    if provider == nil then
        provider, identifier = key:match("^(motionbgs):([a-z0-9][a-z0-9-]*)$")
    end
    local safeIdentifier = previewIdentifier(provider, identifier)
    local url = validPreviewUrl(provider, entry.url)
    local path = previewEntryPath(entry)
    local bytes = math.floor(tonumber(entry.bytes) or 0)
    local info = path ~= nil and noctalia.fileInfo(path) or nil
    return safeIdentifier ~= nil
        and key == provider .. ":" .. safeIdentifier
        and url ~= nil
        and type(info) == "table"
        and info.isDir ~= true
        and bytes >= 1
        and bytes <= PREVIEW_MAX_FILE_BYTES
        and math.floor(tonumber(info.size) or 0) == bytes
        and tonumber(entry.last_used) ~= nil
end

local function savePreviewManifest()
    if not previewCacheReady or previewManifestPath == "" then
        return false
    end
    local encoded = noctalia.json.encode(previewCache, true)
    if type(encoded) ~= "string" or #encoded + 1 > PREVIEW_MAX_MANIFEST_BYTES then
        return false
    end
    local temporary = previewManifestPath .. ".tmp"
    local wrote = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        noctalia.removeFile(temporary)
        return false
    end
    local installed = noctalia.renameFile(temporary, previewManifestPath)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false
    end
    return true
end

local function prunePreviewCache()
    local ordered = {}
    local totalBytes = 0
    for key, entry in pairs(previewCache.entries) do
        local bytes = math.max(0, math.floor(tonumber(type(entry) == "table" and entry.bytes or 0) or 0))
        totalBytes += bytes
        table.insert(ordered, {
            key = key,
            bytes = bytes,
            last_used = math.max(0, math.floor(tonumber(type(entry) == "table" and entry.last_used or 0) or 0)),
        })
    end
    table.sort(ordered, function(left, right)
        if left.last_used == right.last_used then
            return left.key < right.key
        end
        return left.last_used < right.last_used
    end)
    local removed = false
    local index = 1
    while (#ordered - index + 1) > PREVIEW_MAX_ENTRIES or totalBytes > PREVIEW_MAX_CACHE_BYTES do
        local victim = ordered[index]
        if victim == nil then
            break
        end
        removePreviewEntry(victim.key, true)
        totalBytes = math.max(0, totalBytes - victim.bytes)
        index += 1
        removed = true
    end
    return removed
end

local function initializePreviewCache()
    if previewCacheInitialized then
        return previewCacheReady
    end
    previewCacheInitialized = true
    local pluginDirectory = noctalia.pluginDir()
    local dataDirectory = noctalia.pluginDataDir()
    if not previewAbsolutePath(pluginDirectory) or not previewAbsolutePath(dataDirectory) then
        return false
    end
    previewHelperPath = pluginDirectory:gsub("/+$", "") .. "/scripts/provider-thumbnail"
    previewCacheDirectory = dataDirectory:gsub("/+$", "") .. "/provider-previews/v1"
    previewManifestPath = previewCacheDirectory .. "/manifest.json"
    if not noctalia.fileExists(previewHelperPath) or noctalia.mkdirAll(previewCacheDirectory) ~= true then
        return false
    end
    previewCacheReady = true

    local manifestInfo = noctalia.fileInfo(previewManifestPath)
    local changed = false
    if
        type(manifestInfo) == "table"
        and manifestInfo.isDir ~= true
        and tonumber(manifestInfo.size) ~= nil
        and tonumber(manifestInfo.size) >= 1
        and tonumber(manifestInfo.size) <= PREVIEW_MAX_MANIFEST_BYTES
    then
        local raw = noctalia.readFile(previewManifestPath)
        local decoded = type(raw) == "string" and #raw <= PREVIEW_MAX_MANIFEST_BYTES and noctalia.json.decode(raw) or nil
        if type(decoded) == "table" and tonumber(decoded.schema) == PREVIEW_CACHE_SCHEMA and type(decoded.entries) == "table" then
            previewCache = { schema = PREVIEW_CACHE_SCHEMA, entries = {} }
            for key, entry in pairs(decoded.entries) do
                previewCache.entries[key] = entry
            end
        else
            -- Schema mismatches and malformed JSON are discarded in place;
            -- rewrite a clean fixed-slot manifest after owned orphan cleanup.
            changed = true
        end
    elseif type(manifestInfo) == "table" then
        -- Empty, oversized, or directory-shaped manifests are never read.
        changed = true
    end

    for key, entry in pairs(previewCache.entries) do
        if not previewEntryValid(key, entry) then
            removePreviewEntry(key, true)
            changed = true
        end
    end
    changed = prunePreviewCache() or changed

    local referenced = { ["manifest.json"] = true }
    for _, entry in pairs(previewCache.entries) do
        referenced[tostring(entry.filename or "")] = true
    end
    local names = noctalia.listDir(previewCacheDirectory)
    if type(names) == "table" then
        for _, name in ipairs(names) do
            if
                type(name) == "string"
                and not referenced[name]
                and (previewOwnedFilename(name)
                    or name:match("^%.wall%-in%-one%-preview%-%d+%-%d+%.stage$") ~= nil
                    or name == "manifest.json.tmp")
            then
                noctalia.removeFile(previewCacheDirectory .. "/" .. name)
                changed = true
            end
        end
    end
    if changed then
        savePreviewManifest()
    end
    return true
end

local function previewShellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function previewHelperResult(result)
    if type(result) ~= "table" or result.timedOut == true or tonumber(result.exitCode) ~= 0 then
        return nil
    end
    local output = tostring(result.stdout or ""):match("([^\r\n]+)%s*$") or ""
    local protocol, outcome, provider, statusCode, effectiveUrl, contentType, bytes, path = output:match(
        "^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$"
    )
    if protocol ~= PREVIEW_PROTOCOL or outcome ~= "ok" then
        return nil
    end
    return {
        provider = provider,
        status = math.floor(tonumber(statusCode) or 0),
        effective_url = effectiveUrl,
        content_type = contentType,
        bytes = math.floor(tonumber(bytes) or 0),
        path = path,
    }
end

local function previewExtension(contentType)
    if contentType == "image/jpeg" then
        return "jpg"
    elseif contentType == "image/png" then
        return "png"
    elseif contentType == "image/webp" then
        return "webp"
    end
    return nil
end

local function finishPreviewTask(task, result)
    previewActive = math.max(0, previewActive - 1)
    previewPending[task.key] = nil
    if task.generation ~= previewGeneration then
        if previewAbsolutePath(task.staging_path) and noctalia.fileExists(task.staging_path) then
            noctalia.removeFile(task.staging_path)
        end
        local failure = previewFailures[task.url]
        if type(failure) == "table" and tonumber(failure.retry_at) == math.huge then
            failure.retry_at = previewNowSeconds()
            failure.generation = task.generation
        end
        if isOpen then
            -- Rebuild only the current view so a current-generation request for
            -- the same key can be queued after the stale flight releases it.
            render()
        end
        pumpPreviewQueue()
        return
    end
    local transport = previewHelperResult(result)
    local valid = transport ~= nil
        and transport.provider == task.provider
        and transport.status >= 200
        and transport.status < 300
        and transport.effective_url == task.url
        and transport.path == task.staging_path
        and transport.bytes >= 1
        and transport.bytes <= PREVIEW_MAX_FILE_BYTES
    local extension = valid and previewExtension(transport.content_type) or nil
    local info = valid and noctalia.fileInfo(task.staging_path) or nil
    valid = valid
        and extension ~= nil
        and type(info) == "table"
        and info.isDir ~= true
        and math.floor(tonumber(info.size) or 0) == transport.bytes

    if valid then
        local filename = task.provider
            .. "-"
            .. task.identifier
            .. "-"
            .. task.token
            .. "."
            .. extension
        local finalPath = previewCacheDirectory .. "/" .. filename
        local installed = noctalia.renameFile(task.staging_path, finalPath)
        if installed == true then
            local previous = previewCache.entries[task.key]
            previewCache.entries[task.key] = {
                provider = task.provider,
                id = task.identifier,
                url = task.url,
                filename = filename,
                bytes = transport.bytes,
                last_used = previewNowSeconds(),
            }
            previewPaths[task.key] = finalPath
            clearPreviewFailure(task.url)
            if type(previous) == "table" and previous.filename ~= filename then
                local previousPath = previewEntryPath(previous)
                if previousPath ~= nil and noctalia.fileExists(previousPath) then
                    noctalia.removeFile(previousPath)
                end
            end
            prunePreviewCache()
            savePreviewManifest()
        else
            noctalia.removeFile(task.staging_path)
            recordPreviewFailure(task.url)
        end
    else
        if previewAbsolutePath(task.staging_path) and noctalia.fileExists(task.staging_path) then
            noctalia.removeFile(task.staging_path)
        end
        recordPreviewFailure(task.url)
    end

    if isOpen then
        render()
    end
    pumpPreviewQueue()
end

pumpPreviewQueue = function()
    if not isOpen or not initializePreviewCache() then
        return
    end
    while previewActive < PREVIEW_MAX_CONCURRENT and #previewQueue > 0 do
        local task = table.remove(previewQueue, 1)
        previewQueued[task.key] = nil
        local currentEntry = previewCache.entries[task.key]
        if
            task.generation == previewGeneration
            and previewPending[task.key] == nil
            and previewRetryReady(task.url)
            and not (type(currentEntry) == "table" and currentEntry.url == task.url and previewEntryValid(task.key, currentEntry))
        then
            previewSequence += 1
            local token = tostring(math.floor(noctalia.nowMs())) .. "-" .. tostring(previewSequence)
            task.token = token
            task.staging_path = previewCacheDirectory .. "/.wall-in-one-preview-" .. token .. ".stage"
            previewPending[task.key] = task.url
            previewActive += 1
            local failure = previewFailures[task.url]
            if type(failure) == "table" then
                failure.retry_at = math.huge
                failure.generation = task.generation
            end
            local command = "exec bash "
                .. previewShellQuote(previewHelperPath)
                .. " fetch "
                .. previewShellQuote(task.provider)
                .. " "
                .. previewShellQuote(task.url)
                .. " "
                .. previewShellQuote(task.staging_path)
            local started = noctalia.runAsync(command, function(result)
                finishPreviewTask(task, result)
            end, 40000)
            if started ~= true then
                previewActive = math.max(0, previewActive - 1)
                previewPending[task.key] = nil
                recordPreviewFailure(task.url)
            end
        end
    end
end

local function ensureProviderPreview(provider, identifier, url)
    if not initializePreviewCache() then
        return false
    end
    local safeIdentifier = previewIdentifier(provider, identifier)
    local safeUrl = validPreviewUrl(provider, url)
    local key = previewKey(provider, safeIdentifier)
    if safeIdentifier == nil or safeUrl == nil or key == nil then
        return false
    end
    local entry = previewCache.entries[key]
    if type(entry) == "table" and entry.url == safeUrl and previewEntryValid(key, entry) then
        clearPreviewFailure(safeUrl)
        local path = previewEntryPath(entry)
        if path ~= nil then
            previewPaths[key] = path
            local now = previewNowSeconds()
            if now - math.floor(tonumber(entry.last_used) or 0) >= 60 then
                entry.last_used = now
                savePreviewManifest()
            end
        end
        return true
    end
    if type(entry) == "table" and entry.url ~= safeUrl then
        removePreviewEntry(key, true)
        savePreviewManifest()
    end
    local failure = previewFailures[safeUrl]
    if type(failure) == "table" then
        -- The periodic retry tick should wake only for a failure still visible
        -- in the current result generation.
        failure.generation = previewGeneration
        failure.interest = previewInterest
    end
    if
        previewPending[key] == nil
        and previewQueued[key] == nil
        and previewRetryReady(safeUrl)
        and #previewQueue < PREVIEW_MAX_QUEUE
    then
        previewQueued[key] = safeUrl
        table.insert(previewQueue, {
            provider = provider,
            identifier = safeIdentifier,
            key = key,
            url = safeUrl,
            generation = previewGeneration,
        })
        pumpPreviewQueue()
    end
    return previewPending[key] ~= nil or previewQueued[key] ~= nil or previewRetryReady(safeUrl)
end

local function providerPreviewNode(provider, item, width, height, glyph)
    local identifier = if provider == "wallhaven" then tostring(item.id or "") else tostring(item.slug or "")
    local key = previewKey(provider, identifier)
    local path = key ~= nil and previewPaths[key] or nil
    if previewAbsolutePath(path) and noctalia.fileExists(path) then
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
    return ui.row({
        width = width,
        height = height,
        radius = 8,
        fill = "surface_variant/0.55",
        border = "outline/0.35",
        borderWidth = 1,
        align = "center",
        justify = "center",
    }, {
        ui.glyph({ name = glyph, color = "primary" }),
    })
end

preview.ensure = ensureProviderPreview
preview.node = providerPreviewNode
preview.scope = setPreviewScope
preview.retryDue = previewRetryDue
preview.retryPollMs = PREVIEW_RETRY_POLL_MS
preview.cancel = function()
    resetPreviewQueue(previewScope)
end
preview.close = function()
    resetPreviewQueue("")
end
end

local function resetLibraryVisibility()
    libraryVisibleStills = LIBRARY_ENTRY_CHUNK
    libraryVisibleVideos = LIBRARY_ENTRY_CHUNK
    libraryVisibleWorkshops = LIBRARY_ENTRY_CHUNK
end

local function resetPairingVisibility()
    pairingVisibleStills = PAIRING_CARD_CHUNK
    pairingVisibleVideos = PAIRING_CARD_CHUNK
    pairingVisibleWorkshops = PAIRING_CARD_CHUNK
end

local function resetPanelVisibility()
    playlistVisibleEntries = PLAYLIST_ENTRY_CHUNK
    wallhavenVisibleResults = PROVIDER_RESULT_CHUNK
    motionBgsVisibleResults = PROVIDER_RESULT_CHUNK
    resetLibraryVisibility()
    resetPairingVisibility()
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
        sync_colors = false,
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

local function sortedPlaylistIds(includeQuickChoice)
    local ids = {}
    for id, playlist in pairs(playlistMap()) do
        if type(playlist) == "table" and (includeQuickChoice == true or playlist.quick_choice ~= true) then
            table.insert(ids, tostring(id))
        end
    end
    table.sort(ids, function(left, right)
        local playlists = playlistMap()
        local leftName = string.lower(tostring(type(playlists[left]) == "table" and playlists[left].name or left))
        local rightName = string.lower(tostring(type(playlists[right]) == "table" and playlists[right].name or right))
        if leftName == rightName then
            return left < right
        end
        return leftName < rightName
    end)
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

local function paletteNames(source)
    local _root, inventory = paletteInventory()
    local values = type(inventory[source]) == "table" and inventory[source] or {}
    local names = {}
    for _, entry in ipairs(values) do
        local name = if type(entry) == "table" then tostring(entry.name or "") else tostring(entry or "")
        if name ~= "" then
            table.insert(names, name)
        end
    end
    return names
end

local function paletteInventoryEntry(source, selection)
    local _root, inventory = paletteInventory()
    for _, entry in ipairs(type(inventory[source]) == "table" and inventory[source] or {}) do
        if type(entry) == "table" and tostring(entry.name or "") == tostring(selection or "") then
            return entry
        end
    end
    return nil
end

local function basename(path)
    local value = tostring(path or "")
    return value:match("([^/]+)$") or value
end

local function resetEntryDraft()
    editingEntryId = ""
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
        editingEntryId = tostring(entry.id or "")
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

local function editEntryDraft(entry)
    loadBundleDraft(entry, "static")
    entryEditorOpen = true
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

local function entryFromDraft()
    local id = if editingEntryId ~= ""
        then editingEntryId
        else "entry-panel-" .. tostring(math.max(1, math.floor(tonumber(noctalia.nowMs()) or 1)))
    return bundleFromDraft(id)
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
end

local function editScheduleDraft(schedule, defaultPlaylistId)
    scheduleEditorOpen = true
    if type(schedule) ~= "table" then
        resetScheduleDraft(if tostring(defaultPlaylistId or "") ~= "" then defaultPlaylistId else selectedPlaylistId)
        return
    end
    editingScheduleId = tostring(schedule.id or "")
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

local function pairingKind(pairing)
    local media = type(pairing) == "table" and type(pairing.media) == "table" and pairing.media or nil
    return if media == nil then "static" else tostring(media.kind or "")
end

local function sortedPairingIds(kind)
    local ids = {}
    for id, pairing in pairs(pairingMap()) do
        if type(pairing) == "table" and pairingKind(pairing) == kind then
            table.insert(ids, tostring(id))
        end
    end
    table.sort(ids, function(left, right)
        local pairings = pairingMap()
        local leftName = string.lower(tostring(type(pairings[left]) == "table" and pairings[left].label or left))
        local rightName = string.lower(tostring(type(pairings[right]) == "table" and pairings[right].label or right))
        if leftName == rightName then
            return left < right
        end
        return leftName < rightName
    end)
    return ids
end

local function nextDragToken(prefix)
    dragTokenSequence = dragTokenSequence + 1
    return prefix .. tostring(dragTokenSequence)
end

-- Reconcile tokens outside render so retained drag sources keep stable,
-- compact payloads while the corresponding config objects still exist.
local function reconcileDragTokens()
    local nextPairingByToken = {}
    local nextPairingTokenById = {}
    for rawId, pairing in pairs(pairingMap()) do
        if type(pairing) == "table" then
            local id = tostring(rawId)
            local token = dragPairingTokenById[id] or nextDragToken("p")
            nextPairingByToken[token] = id
            nextPairingTokenById[id] = token
        end
    end

    local nextEntryByToken = {}
    local nextEntryTokenByPlaylist = {}
    local nextTargetByToken = {}
    local nextTargetTokenByPlaylist = {}
    for rawPlaylistId, playlist in pairs(playlistMap()) do
        if type(playlist) == "table" then
            local playlistId = tostring(rawPlaylistId)
            local entries = type(playlist.entries) == "table" and playlist.entries or {}
            local previousEntryTokens = type(dragEntryTokenByPlaylist[playlistId]) == "table"
                    and dragEntryTokenByPlaylist[playlistId]
                or {}
            local previousTargetTokens = type(dragTargetTokenByPlaylist[playlistId]) == "table"
                    and dragTargetTokenByPlaylist[playlistId]
                or {}
            local entryTokens = {}
            local targetTokens = {}
            local previousEntryId = ""

            for _, entry in ipairs(entries) do
                local entryId = type(entry) == "table" and tostring(entry.id or "") or ""
                if entryId ~= "" and entryTokens[entryId] == nil then
                    local entryToken = previousEntryTokens[entryId] or nextDragToken("e")
                    entryTokens[entryId] = entryToken
                    nextEntryByToken[entryToken] = {
                        playlist_id = playlistId,
                        entry_id = entryId,
                    }

                    -- The visual gap is before this entry. For the first row
                    -- that is a `before` placement; subsequent gaps are also
                    -- expressible as `after` the previous row. Pairing drops
                    -- retain the exact before-id independently.
                    local targetToken = previousTargetTokens[entryId] or nextDragToken("d")
                    targetTokens[entryId] = targetToken
                    nextTargetByToken[targetToken] = {
                        playlist_id = playlistId,
                        pairing_before_id = entryId,
                        entry_anchor_id = if previousEntryId == "" then entryId else previousEntryId,
                        entry_placement = if previousEntryId == "" then "before" else "after",
                    }
                    previousEntryId = entryId
                end
            end

            local endToken = previousTargetTokens[""] or nextDragToken("d")
            targetTokens[""] = endToken
            nextTargetByToken[endToken] = {
                playlist_id = playlistId,
                pairing_before_id = "",
                entry_anchor_id = "",
                entry_placement = "end",
            }
            nextEntryTokenByPlaylist[playlistId] = entryTokens
            nextTargetTokenByPlaylist[playlistId] = targetTokens
        end
    end

    dragPairingByToken = nextPairingByToken
    dragPairingTokenById = nextPairingTokenById
    dragEntryByToken = nextEntryByToken
    dragEntryTokenByPlaylist = nextEntryTokenByPlaylist
    dragTargetByToken = nextTargetByToken
    dragTargetTokenByPlaylist = nextTargetTokenByPlaylist
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

local function pairingThemeText(theme)
    local value = type(theme) == "table" and theme or {}
    return if tostring(value.source or "inherit") == "inherit"
        then noctalia.tr("panel.playlists.entry.keep_theme")
        else table.concat({
            tostring(value.mode or "auto"),
            tostring(value.source or ""),
            tostring(value.selection or ""),
        }, " · ")
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
    local savedId = tostring(pairingId or "")
    local media = type(bundle.media) == "table" and bundle.media or nil
    if tostring(still.mode or "") == "automatic" and media ~= nil and savedId ~= "" then
        local saved = pairingMap()[savedId]
        local savedMedia = type(saved) == "table" and type(saved.media) == "table" and saved.media or nil
        if
            savedMedia == nil
            or tostring(savedMedia.kind or "") ~= tostring(media.kind or "")
            or tostring(savedMedia.source or "") ~= tostring(media.source or "")
        then
            return nil
        end
        return {
            signature = "pairing|" .. tostring(#savedId) .. "|" .. savedId .. "|" .. scheme,
            path = "",
            pairing_id = savedId,
            scheme = scheme,
        }
    end
    return nil
end

local function requestPairingAdaptivePreview(bundle, pairingId)
    if pairingEditorOpen ~= true then
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
    adaptivePreviewStates[descriptor.signature] = nil
    local request = {
        kind = "palette_preview",
        key = key,
        scheme = descriptor.scheme,
    }
    if descriptor.path ~= "" then
        request.path = descriptor.path
    end
    if descriptor.pairing_id ~= "" then
        request.pairing_id = descriptor.pairing_id
    end
    send(request)
    return true
end

local function retryPairingAdaptivePreview(bundle, pairingId)
    if pairingEditorOpen ~= true then
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
    kind = if kind == "video" or kind == "workshop" then kind else "static"
    pairingEditorRevision += 1
    pairingEditorKind = kind
    pairingEditorOpen = true
    editingPairingId = if type(pairing) == "table" then tostring(pairing.id or "") else ""
    pendingDeletePairingId = ""
    entryEditorOpen = false
    loadBundleDraft(pairing, kind)
    entryMediaKindDraft = kind
    if kind == "static" then
        entryStillModeDraft = "selected"
    end
    preview.cancel()
    activePage = "library"
    activeSubpage = if kind == "video" then "videos" elseif kind == "workshop" then "workshops" else "images"
    requestPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)
    render()
end

local function closePairingEditor()
    pairingEditorOpen = false
    editingPairingId = ""
    pendingDeletePairingId = ""
    resetEntryDraft()
end

local function matchingPairingForLibraryEntry(entry)
    local kind = tostring(type(entry) == "table" and entry.kind or "")
    local source = tostring(type(entry) == "table" and entry.source or "")
    for _, id in ipairs(sortedPairingIds(kind)) do
        local pairing = pairingMap()[id]
        local media = type(pairing) == "table" and type(pairing.media) == "table" and pairing.media or nil
        local still = type(pairing) == "table" and type(pairing.still) == "table" and pairing.still or {}
        local matches = if kind == "static"
            then media == nil and tostring(still.path or "") == source
            else media ~= nil and tostring(media.kind or "") == kind and tostring(media.source or "") == source
        if matches then
            return pairing
        end
    end
    return nil
end

local function openLibraryEntryPairing(entry, libraryItem)
    local kind = tostring(type(entry) == "table" and entry.kind or "")
    kind = if kind == "video" or kind == "workshop" then kind else "static"
    local existing = matchingPairingForLibraryEntry(entry)
    if existing ~= nil then
        beginPairingEditor(kind, existing)
        return
    end
    local source = tostring(type(entry) == "table" and entry.source or "")
    local label = tostring(type(entry) == "table" and entry.label or basename(source))
    local selectedStill = tostring(type(entry) == "table" and entry.still_path or "")
    if selectedStill == "" and type(libraryItem) == "table" then
        selectedStill = tostring(libraryItem.preview or "")
    end
    local selectedStillValid = selectedStill:sub(1, 1) == "/"
        and selectedStill:find("[%c]") == nil
        and noctalia.fileExists(selectedStill)
    beginPairingEditor(kind, {
        id = "",
        label = label,
        media = if kind == "static" then nil else { kind = kind, source = source },
        still = if kind == "static"
            then { mode = "selected", path = source }
            elseif selectedStillValid then { mode = "selected", path = selectedStill }
            else { mode = "automatic" },
        theme = {
            mode = "auto",
            source = "wallpaper",
            selection = paletteNames("wallpaper")[1] or "m3-tonal-spot",
        },
        added_at = tostring(type(entry) == "table" and entry.added_at or ""),
    })
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
local panelUi = {}

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

local function ownershipBadge(libraryItem)
    local ownership = type(libraryItem) == "table" and tostring(libraryItem.ownership or "") or ""
    local managed = type(libraryItem) == "table" and libraryItem.managed == true
    local label = if managed
        then noctalia.tr("panel.library.managed")
        elseif ownership == "steam" then noctalia.tr("panel.library.steam_owned")
        else noctalia.tr("panel.library.user_owned")
    local badgeGlyph = if managed then "shield-check" elseif ownership == "steam" then "steam" else "user"
    return ui.row({
        gap = 4,
        align = "center",
        padding = 4,
        radius = 8,
        fill = if managed then "primary/0.12" else "surface_variant/0.5",
    }, {
        ui.glyph({
            name = badgeGlyph,
            color = if managed then "primary" else "on_surface_variant",
            size = 12,
        }),
        ui.label({
            text = label,
            fontSize = 8,
            color = if managed then "primary" else "on_surface_variant",
            maxLines = 1,
        }),
    })
end

local function libraryEntryRow(glyph, title, detail, entry, canApply, libraryItem)
    local metadata = type(libraryItem) == "table" and libraryItem or nil
    local managed = type(metadata) == "table" and metadata.managed == true
    local deletable = managed and metadata.deletable == true
    local itemId = if deletable then tostring(metadata.id or "") else ""
    local deleteArmed = itemId ~= "" and pendingDeleteItemId == itemId
    local existingPairing = matchingPairingForLibraryEntry(entry)
    local detailChildren = {
        ui.label({ text = title, fontSize = 11, fontWeight = "bold", maxLines = 2 }),
        ui.label({ text = detail, fontSize = 9, color = "on_surface_variant", maxLines = 2 }),
    }
    if metadata ~= nil then
        table.insert(detailChildren, ownershipBadge(metadata))
    end
    if deleteArmed then
        table.insert(
            detailChildren,
            ui.label({
                text = noctalia.tr("panel.library.delete_managed_confirm", { name = title }),
                fontSize = 9,
                color = "error",
                maxLines = 3,
            })
        )
    end

    local children = {
        ui.glyph({ name = glyph, color = "primary" }),
        ui.column({ gap = 2, flexGrow = 1 }, detailChildren),
        ui.button({
            glyph = "layers-intersect",
            tooltip = if existingPairing ~= nil
                then noctalia.tr("panel.pairings.edit")
                else noctalia.tr("panel.pairings.new"),
            variant = "ghost",
            controlSize = "sm",
            enabled = storageValid(),
            onClick = function()
                openLibraryEntryPairing(entry)
            end,
        }),
        ui.button({
            glyph = "player-play",
            tooltip = noctalia.tr("panel.library.apply"),
            variant = "ghost",
            controlSize = "sm",
            enabled = canApply and storageValid() and focusedOutput() ~= "",
            onClick = function()
                local output = focusedOutput()
                send({ kind = "apply_entry", output = output, entry = entryForOutput(entry, output) })
            end,
        }),
        ui.button({
            glyph = "playlist-add",
            tooltip = noctalia.tr("panel.playlists.entry_add"),
            variant = "ghost",
            controlSize = "sm",
            enabled = storageValid() and focusedOutput() ~= "",
            onClick = function()
                local output = focusedOutput()
                local playlistId = resolveSelectedPlaylist()
                send({
                    kind = "playlist_add_entry",
                    output = output,
                    playlist_id = playlistId,
                    entry = entryForOutput(entry, output),
                })
            end,
        }),
    }
    if deletable and itemId ~= "" then
        table.insert(
            children,
            ui.button({
                glyph = if deleteArmed then "alert-triangle" else "trash",
                tooltip = if deleteArmed
                    then noctalia.tr("panel.library.delete_managed_confirm", { name = title })
                    else noctalia.tr("panel.library.delete_managed"),
                variant = "ghost",
                controlSize = "sm",
                enabled = storageValid(),
                onClick = function()
                    if pendingDeleteItemId == itemId then
                        pendingDeleteItemId = ""
                        send({ kind = "library_delete", item_id = itemId })
                    else
                        pendingDeleteItemId = itemId
                        render()
                    end
                end,
            })
        )
    end
    return ui.row({
        gap = 8,
        align = "center",
        padding = 8,
        radius = 9,
        fill = "surface_variant/0.25",
    }, children)
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
    local items = type(results.items) == "table" and results.items or {}
    local selected = type(results.selected) == "table" and results.selected or {}
    local meta = type(results.meta) == "table" and results.meta or {}
    local activeFilters = type(results.filters) == "table" and results.filters or {}
    local ready = providerStatus.available == true and storageValid()
    local busy = providerStatus.busy == true
    preview.scope("wallhaven:" .. tostring(results.sequence or 0) .. ":" .. (if ready then "ready" else "disabled"))
    local selectedPreviewQueued = false
    if ready then
        for index = 1, math.min(#items, wallhavenVisibleResults) do
            local item = items[index]
            local thumbs = type(item) == "table" and type(item.thumbs) == "table" and item.thumbs or {}
            local previewAccepted = preview.ensure("wallhaven", tostring(item.id or ""), tostring(thumbs.large or ""))
            if tostring(item.id or "") == tostring(selected.id or "") and previewAccepted then
                selectedPreviewQueued = true
            end
        end
        if tostring(selected.id or "") ~= "" and not selectedPreviewQueued then
            local thumbs = type(selected.thumbs) == "table" and selected.thumbs or {}
            preview.ensure("wallhaven", tostring(selected.id), tostring(thumbs.large or ""))
        end
    end
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
        wallhavenVisibleResults = PROVIDER_RESULT_CHUNK
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
                key = "wallhaven-search",
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
                    wallhavenVisibleResults = PROVIDER_RESULT_CHUNK
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
                end,
            }),
            ui.select({
                key = "wallhaven-purity",
                options = purityLabels,
                selectedIndex = purityIndex,
                flexGrow = 1,
                onChange = function(index)
                    wallhavenPurityDraft = purityValues[math.floor(tonumber(index) or 0) + 1] or "100"
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
                end,
            }),
            ui.input({
                key = "wallhaven-page",
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
    if tostring(selected.id or "") ~= "" then
        local selectedItem = selected
        table.insert(
            children,
            ui.column({ gap = 4, padding = 9, radius = 9, fill = "primary/0.08", align = "stretch" }, {
                ui.row({ justify = "center" }, {
                    preview.node("wallhaven", selected, 320, 180, "photo"),
                }),
                ui.label({
                    text = noctalia.tr("panel.wallhaven.selected", {
                        id = tostring(selected.id),
                        resolution = panelUi.valueOr(selected.resolution, "common.unknown"),
                    }),
                    fontSize = 11,
                    fontWeight = "bold",
                }),
                ui.label({
                    text = tostring(selected.url or selected.short_url or ""),
                    fontSize = 8,
                    color = "on_surface_variant",
                    maxLines = 2,
                }),
                ui.button({
                    text = noctalia.tr("panel.wallhaven.download"),
                    glyph = "download",
                    variant = "primary",
                    controlSize = "sm",
                    enabled = ready and not busy,
                    onClick = function()
                        send({ kind = "wallhaven_download", id = tostring(selectedItem.id or "") })
                    end,
                }),
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
        for index = 1, math.min(#items, wallhavenVisibleResults) do
            local item = items[index]
            local resultItem = item
            table.insert(
                children,
                ui.row({ gap = 7, align = "center", padding = 8, radius = 9, fill = "surface_variant/0.25" }, {
                    preview.node("wallhaven", item, 112, 63, "photo"),
                    ui.column({ gap = 1, flexGrow = 1 }, {
                        ui.label({
                            text = tostring(item.id or noctalia.tr("panel.wallhaven.default_name"))
                                .. " · "
                                .. tostring(item.resolution or ""),
                            fontSize = 10,
                            fontWeight = "bold",
                        }),
                        ui.label({
                            text = noctalia.tr("panel.wallhaven.result_summary", {
                                category = tostring(item.category or ""),
                                purity = tostring(item.purity or ""),
                                favorites = tostring(item.favorites or 0),
                            }),
                            fontSize = 8,
                            color = "on_surface_variant",
                            maxLines = 2,
                        }),
                    }),
                    ui.button({
                        glyph = "info-circle",
                        tooltip = noctalia.tr("panel.wallhaven.details"),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = ready and not busy,
                        onClick = function()
                            send({ kind = "wallhaven_detail", id = tostring(resultItem.id or "") })
                        end,
                    }),
                    ui.button({
                        glyph = "download",
                        tooltip = noctalia.tr("panel.wallhaven.download"),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = ready and not busy,
                        onClick = function()
                            send({ kind = "wallhaven_download", id = tostring(resultItem.id or "") })
                        end,
                    }),
                })
            )
        end
        panelUi.appendVisibilityControls(
            children,
            #items,
            wallhavenVisibleResults,
            PROVIDER_RESULT_CHUNK,
            function(value)
                if value < wallhavenVisibleResults then
                    preview.cancel()
                end
                wallhavenVisibleResults = value
            end
        )
    end
    local lastDownload = type(providerStatus.last_download) == "table" and providerStatus.last_download or {}
    local downloadedPath = tostring(lastDownload.path or "")
    if downloadedPath ~= "" then
        table.insert(children, ui.separator())
        table.insert(
            children,
            ui.label({ text = noctalia.tr("panel.wallhaven.last_download"), fontSize = 11, fontWeight = "bold" })
        )
        table.insert(
            children,
            libraryEntryRow(
                "download",
                tostring(lastDownload.id or basename(downloadedPath)),
                downloadedPath,
                {
                    kind = "static",
                    source = downloadedPath,
                    label = tostring(lastDownload.id or basename(downloadedPath)),
                    added_at = tostring(lastDownload.downloaded_at or ""),
                },
                providers().noctalia_cli == true
            )
        )
    end
    return panelUi.card(children)
end

local function motionBgsSection()
    local provider = type(providers().motionbgs) == "table" and providers().motionbgs or {}
    local motionStatus, results = motionBgsData()
    local items = type(results.items) == "table" and results.items or {}
    local selected = type(results.selected) == "table" and results.selected or {}
    local meta = type(results.meta) == "table" and results.meta or {}
    local integrationReady = provider.integration_available == true and storageValid()
    local busy = motionStatus.busy == true
    local quality = tostring(settings().motionbgs_quality or "hd")
    preview.scope("motionbgs:" .. tostring(results.sequence or 0) .. ":" .. (if integrationReady then "ready" else "disabled"))
    local selectedPreviewQueued = false
    if integrationReady then
        for index = 1, math.min(#items, motionBgsVisibleResults) do
            local item = items[index]
            local previewAccepted = preview.ensure(
                "motionbgs",
                tostring(item.slug or ""),
                tostring(item.thumbnail_url or "")
            )
            if tostring(item.slug or "") == tostring(selected.slug or "") and previewAccepted then
                selectedPreviewQueued = true
            end
        end
        if tostring(selected.slug or "") ~= "" and not selectedPreviewQueued then
            preview.ensure("motionbgs", tostring(selected.slug), tostring(selected.poster_url or ""))
        end
    end
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
            key = "motionbgs-search",
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
                    if selectedGenre ~= "" then
                        motionBrowseDraft.genre = selectedGenre
                    end
                end,
            }),
            ui.input({
                key = "motionbgs-genre",
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
        motionBgsVisibleResults = PROVIDER_RESULT_CHUNK
        preview.cancel()
        send({
            kind = "motionbgs_search",
            mode = mode,
            query = query,
            genre = genre,
            page = page,
        })
    end
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
                    render()
                end,
            }),
            selectorNode,
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "motionbgs-page",
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
                    motionBgsVisibleResults = PROVIDER_RESULT_CHUNK
                    preview.cancel()
                    send({ kind = "motionbgs_clear" })
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = if busy
                    then noctalia.tr("panel.motionbgs.busy", { action = tostring(motionStatus.active_action or "") })
                    elseif integrationReady then noctalia.tr("panel.motionbgs.ready")
                    else noctalia.tr("panel.motionbgs.unavailable"),
                color = if integrationReady then "primary" else "tertiary",
                fontSize = 10,
                flexGrow = 1,
                maxLines = 3,
            }),
            panelUi.actionButton("motionbgs_open", "external-link", "ghost", false),
        }),
        ui.label({
            text = noctalia.tr("panel.motionbgs.fallback"),
            fontSize = 9,
            color = "tertiary",
            maxLines = 5,
        }),
    }

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

    if tostring(selected.slug or "") ~= "" then
        local downloads = type(selected.downloads) == "table" and selected.downloads or {}
        local detail = tostring(selected.duration or "")
        if detail == "" then
            detail = tostring(selected.source_url or "")
        end
        table.insert(
            children,
            ui.column({ gap = 5, padding = 9, radius = 9, fill = "primary/0.08", align = "stretch" }, {
                ui.row({ justify = "center" }, {
                    preview.node("motionbgs", selected, 320, 180, "movie"),
                }),
                ui.label({
                    text = tostring(selected.title or selected.slug),
                    fontSize = 12,
                    fontWeight = "bold",
                    maxLines = 2,
                }),
                ui.label({ text = detail, fontSize = 9, color = "on_surface_variant", maxLines = 2 }),
                ui.row({ gap = 6, align = "center" }, {
                    ui.button({
                        text = noctalia.tr("panel.motionbgs.download_hd"),
                        glyph = "download",
                        variant = if quality == "hd" then "primary" else "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        enabled = integrationReady and not busy and type(downloads.hd) == "table",
                        onClick = function()
                            send({ kind = "motionbgs_download", slug = tostring(selected.slug), quality = "hd" })
                        end,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.motionbgs.download_4k"),
                        glyph = "download",
                        variant = if quality == "4k" then "primary" else "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        enabled = integrationReady and not busy and type(downloads["4k"]) == "table",
                        onClick = function()
                            send({ kind = "motionbgs_download", slug = tostring(selected.slug), quality = "4k" })
                        end,
                    }),
                }),
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
        local totalHint = math.max(0, math.floor(tonumber(meta.total_hint) or 0))
        table.insert(
            children,
            ui.label({
                text = if resultMode == "search"
                    then noctalia.tr("panel.motionbgs.search_meta", { count = tostring(#items) })
                    else noctalia.tr("panel.motionbgs.browse_meta", {
                        page = tostring(currentPage),
                        count = tostring(#items),
                        total = if totalHint > 0 then tostring(totalHint) .. "+" else "?",
                    }),
                fontSize = 9,
                color = "on_surface_variant",
                maxLines = 3,
            })
        )
        if resultMode == "search" or resultMode == "hd" then
            table.insert(
                children,
                ui.label({
                    text = if resultMode == "search"
                        then noctalia.tr("panel.motionbgs.search_unpaged")
                        else noctalia.tr("panel.motionbgs.hd_unpaged"),
                    fontSize = 9,
                    color = "tertiary",
                    maxLines = 4,
                })
            )
        end
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
        for index = 1, math.min(#items, motionBgsVisibleResults) do
            local item = items[index]
            local slug = tostring(item.slug or "")
            table.insert(
                children,
                ui.row({ gap = 7, align = "center", padding = 8, radius = 9, fill = "surface_variant/0.25" }, {
                    preview.node("motionbgs", item, 112, 63, "movie"),
                    ui.column({ gap = 1, flexGrow = 1 }, {
                        ui.label({
                            text = tostring(item.title or slug),
                            fontSize = 11,
                            fontWeight = "bold",
                            maxLines = 2,
                        }),
                        ui.label({
                            text = tostring(item.quality or "") .. " · " .. tostring(item.source_url or ""),
                            fontSize = 9,
                            color = "on_surface_variant",
                            maxLines = 2,
                        }),
                    }),
                    ui.button({
                        glyph = "info-circle",
                        tooltip = noctalia.tr("panel.motionbgs.details"),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = integrationReady and not busy and slug ~= "",
                        onClick = function()
                            send({ kind = "motionbgs_details", slug = slug })
                        end,
                    }),
                    ui.button({
                        glyph = "download",
                        tooltip = noctalia.tr("panel.motionbgs.download_default", { quality = quality:upper() }),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = integrationReady and not busy and slug ~= "",
                        onClick = function()
                            send({ kind = "motionbgs_download", slug = slug, quality = quality })
                        end,
                    }),
                })
            )
        end
        panelUi.appendVisibilityControls(
            children,
            #items,
            motionBgsVisibleResults,
            PROVIDER_RESULT_CHUNK,
            function(value)
                if value < motionBgsVisibleResults then
                    preview.cancel()
                end
                motionBgsVisibleResults = value
            end
        )
    end

    local lastDownload = type(motionStatus.last_download) == "table" and motionStatus.last_download or {}
    local downloadedPath = tostring(lastDownload.path or "")
    if downloadedPath ~= "" then
        local mpvpaper = type(providers().mpvpaper) == "table" and providers().mpvpaper or {}
        table.insert(children, ui.separator())
        table.insert(
            children,
            ui.label({ text = noctalia.tr("panel.motionbgs.last_download"), fontSize = 11, fontWeight = "bold" })
        )
        table.insert(
            children,
            libraryEntryRow(
                "download",
                tostring(lastDownload.title or downloadedPath:match("([^/]+)$") or "MotionBGS"),
                downloadedPath,
                {
                    kind = "video",
                    source = downloadedPath,
                    label = tostring(lastDownload.title or "MotionBGS"),
                    added_at = tostring(lastDownload.downloaded_at or ""),
                },
                mpvpaper.apply_available == true
            )
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
    local selectedStill = tostring(type(entry) == "table" and entry.still_path or "")
    if selectedStill == "" and type(libraryItem) == "table" then
        selectedStill = tostring(libraryItem.preview or "")
    end
    local selectedStillValid = selectedStill:sub(1, 1) == "/"
        and selectedStill:find("[%c]") == nil
        and noctalia.fileExists(selectedStill)
    local scheme = tostring(settings().color_scheme or "")
    if scheme == "" then
        scheme = paletteNames("wallpaper")[1] or "m3-tonal-spot"
    end
    return {
        id = "library-entry",
        label = tostring(type(entry) == "table" and entry.label or basename(source)):sub(1, 160),
        media = if kind == "static" then nil else { kind = kind, source = source },
        still = if kind == "static"
            then { mode = "selected", path = source }
            elseif selectedStillValid then { mode = "selected", path = selectedStill }
            else { mode = "automatic" },
        theme = { mode = "auto", source = "wallpaper", selection = scheme },
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
    local label = (if isDefault then noctalia.tr("panel.library.default_pairing") else noctalia.tr("panel.library.saved_pairing"))
        .. " · "
        .. panelUi.valueOr(theme.selection, "common.unknown")
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
    return ui.box({
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
    local output = panelUi.libraryTargetOutput()
    local bundle = panelUi.virtualLibraryPairing(entry, metadata, existing)
    local previewPath = panelUi.libraryPreviewPath(entry, metadata, bundle, output)
    local managed = metadata.managed == true and metadata.deletable == true and tostring(metadata.id or "") ~= ""
    local pairingId = type(existing) == "table" and tostring(existing.id or "") or ""
    local itemId = tostring(metadata.id or "")
    local managedDeleteArmed = managed and pendingDeleteItemId == itemId
    local pairingDeleteArmed = not managed and pairingId ~= "" and pendingDeletePairingId == pairingId
    local deleteArmed = managedDeleteArmed or pairingDeleteArmed
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
            tooltip = if pairingId ~= ""
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
    if managed or pairingId ~= "" then
        table.insert(actions, ui.button({
            glyph = if deleteArmed then "alert-triangle" else "trash",
            tooltip = if managed
                then noctalia.tr("panel.library.delete_managed")
                else noctalia.tr("panel.pairings.delete"),
            variant = if deleteArmed then "danger" else "ghost",
            controlSize = "sm",
            enabled = storageValid(),
            onClick = function()
                if managed then
                    if pendingDeleteItemId == itemId then
                        pendingDeleteItemId = ""
                        send({ kind = "library_delete", item_id = itemId })
                    else
                        pendingDeleteItemId = itemId
                        pendingDeletePairingId = ""
                        render()
                    end
                elseif pendingDeletePairingId == pairingId then
                    pendingDeletePairingId = ""
                    send({ kind = "pairing_delete", pairing_id = pairingId })
                else
                    pendingDeletePairingId = pairingId
                    pendingDeleteItemId = ""
                    render()
                end
            end,
        }))
    end

    local children = {
        panelUi.libraryThumbnail(kind, previewPath, pairingId ~= ""),
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
        panelUi.libraryPaletteSummary(bundle, pairingId == ""),
        ui.label({ text = stillText, fontSize = 8, color = "tertiary", maxLines = 1 }),
    }
    if deleteArmed then
        table.insert(children, ui.label({
            text = if managed
                then noctalia.tr("panel.library.delete_managed_confirm", {
                    name = tostring(entry.label or basename(entry.source)),
                })
                else noctalia.tr("panel.pairings.confirm_delete"),
            fontSize = 8,
            color = "error",
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
        border = if deleteArmed then "error/0.55" elseif pairingId ~= "" then "primary/0.35" else "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

function panelUi.libraryItems(kind)
    local currentLibrary = type(status) == "table" and type(status.library) == "table" and status.library or {}
    local sourceItems = if kind == "static"
        then currentLibrary.stills
        elseif kind == "video" then currentLibrary.videos
        else currentLibrary.workshops
    sourceItems = type(sourceItems) == "table" and sourceItems or {}
    local items = {}
    local signatures = {}
    local function add(entry, metadata, pairing)
        local signature = tostring(entry.kind or "") .. "\0" .. tostring(entry.source or "")
        if signatures[signature] then
            return
        end
        signatures[signature] = true
        table.insert(items, { entry = entry, metadata = metadata, pairing = pairing })
    end
    for _, sourceItem in ipairs(sourceItems) do
        if type(sourceItem) == "table" then
            if kind == "workshop" then
                add({
                    kind = "workshop",
                    source = tostring(sourceItem.id or ""),
                    label = tostring(sourceItem.title or ("Workshop " .. tostring(sourceItem.id or ""))),
                    still_path = tostring(sourceItem.preview or ""),
                    added_at = tostring(currentLibrary.scanned_at or ""),
                }, sourceItem, nil)
            else
                add({
                    kind = kind,
                    source = tostring(sourceItem.path or ""),
                    label = tostring(sourceItem.name or basename(sourceItem.path)),
                    added_at = tostring(currentLibrary.scanned_at or ""),
                }, sourceItem, nil)
            end
        end
    end
    for _, id in ipairs(sortedPairingIds(kind)) do
        local pairing = pairingMap()[id]
        local media = type(pairing) == "table" and type(pairing.media) == "table" and pairing.media or nil
        local still = type(pairing) == "table" and type(pairing.still) == "table" and pairing.still or {}
        local source = if media ~= nil then tostring(media.source or "") else tostring(still.path or "")
        add({
            kind = kind,
            source = source,
            label = tostring(pairing.label or basename(source)),
            still_path = if tostring(still.mode or "") == "selected" then tostring(still.path or "") else "",
            added_at = tostring(pairing.added_at or ""),
        }, {
            id = "pairing:" .. id,
            preview = if tostring(still.mode or "") == "selected" then tostring(still.path or "") else "",
            ownership = "user",
            managed = false,
            deletable = false,
        }, pairing)
    end
    return items, currentLibrary
end

function panelUi.appendLibraryGrid(children, items, visible)
    local index = 1
    while index <= math.min(#items, visible) do
        local cards = { panelUi.libraryCard(items[index]) }
        if index + 1 <= math.min(#items, visible) then
            table.insert(cards, panelUi.libraryCard(items[index + 1]))
        end
        table.insert(children, ui.row({ gap = 8, align = "start", justify = "center" }, cards))
        index += 2
    end
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
        addPath(
            "database",
            noctalia.tr("panel.storage.motion_cache"),
            if dataDirectory ~= "" then dataDirectory .. "/motionbgs/cache-v2.json" else "",
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
    local items, currentLibrary = panelUi.libraryItems(kind)
    local configuration = settings()
    local visible = if kind == "video"
        then libraryVisibleVideos
        elseif kind == "workshop" then libraryVisibleWorkshops
        else libraryVisibleStills
    local countLabel = if kind == "video"
        then noctalia.tr("panel.library.videos", { count = tostring(#items) })
        elseif kind == "workshop" then noctalia.tr("panel.library.workshops", { count = tostring(#items) })
        else noctalia.tr("panel.library.stills", { count = tostring(#items) })
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
                glyph = "plus",
                tooltip = noctalia.tr("panel.pairings.new"),
                variant = "primary",
                controlSize = "sm",
                enabled = storageValid(),
                onClick = function()
                    beginPairingEditor(kind, nil)
                end,
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
    if #items == 0 then
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
        panelUi.appendLibraryGrid(children, items, visible)
        panelUi.appendVisibilityControls(children, #items, visible, LIBRARY_ENTRY_CHUNK, function(value)
            if kind == "video" then
                libraryVisibleVideos = value
            elseif kind == "workshop" then
                libraryVisibleWorkshops = value
            else
                libraryVisibleStills = value
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
    return ui.box({
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

local function entryEditor(playlistId, output)
    if not entryEditorOpen then
        return ui.button({
            text = noctalia.tr("panel.playlists.entry_add"),
            glyph = "playlist-add",
            variant = "primary",
            controlSize = "sm",
            enabled = playlistId ~= "" and storageValid() and output ~= "",
            onClick = function()
                editEntryDraft(nil)
                render()
            end,
        })
    end

    local mediaValues = { "static", "video", "workshop" }
    local mediaLabels = {
        noctalia.tr("panel.playlists.entry.media_still"),
        noctalia.tr("panel.playlists.entry.media_video"),
        noctalia.tr("panel.playlists.entry.media_workshop"),
    }
    local mediaIndex = if entryMediaKindDraft == "video" then 1 elseif entryMediaKindDraft == "workshop" then 2 else 0
    local dynamic = entryMediaKindDraft ~= "static"
    local trimmedSource = noctalia.string.trim(entryMediaSourceDraft)
    local sourceValid = if entryMediaKindDraft == "workshop"
        then trimmedSource:match("^%d+$") ~= nil
        else trimmedSource:sub(1, 1) == "/"
    local stillValid = not dynamic
        or entryStillModeDraft == "automatic"
        or noctalia.string.trim(entryStillPathDraft):sub(1, 1) == "/"
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
    local selectionNames = if entryThemeSourceDraft == "inherit" then {} else paletteNames(entryThemeSourceDraft)
    local paletteStatus = paletteInventory()
    local selectionIndex = 0
    local selectionFound = false
    for index, name in ipairs(selectionNames) do
        if name == entryThemeSelectionDraft then
            selectionIndex = index - 1
            selectionFound = true
            break
        end
    end
    if entryThemeSelectionDraft ~= "" and not selectionFound then
        table.insert(selectionNames, 1, entryThemeSelectionDraft)
        selectionIndex = 0
    end

    local children = {
        ui.label({
            text = if editingEntryId == ""
                then noctalia.tr("panel.playlists.entry.new_title")
                else noctalia.tr("panel.playlists.entry.edit_title"),
            fontSize = 12,
            fontWeight = "bold",
        }),
        ui.input({
            key = "playlist-entry-label-" .. playlistId .. "-" .. editingEntryId,
            value = entryLabelDraft,
            placeholder = noctalia.tr("panel.playlists.entry.label_placeholder"),
            onChange = function(value)
                entryLabelDraft = tostring(value or "")
                render()
            end,
        }),
        ui.select({
            key = "playlist-entry-kind-" .. playlistId .. "-" .. editingEntryId,
            options = mediaLabels,
            selectedIndex = mediaIndex,
            onChange = function(index)
                entryMediaKindDraft = mediaValues[math.floor(tonumber(index) or 0) + 1] or "static"
                if entryMediaKindDraft == "static" then
                    entryStillModeDraft = "selected"
                elseif entryStillModeDraft ~= "selected" then
                    entryStillModeDraft = "automatic"
                end
                render()
            end,
        }),
        ui.input({
            key = "playlist-entry-source-" .. playlistId .. "-" .. editingEntryId,
            value = entryMediaSourceDraft,
            placeholder = if entryMediaKindDraft == "workshop"
                then noctalia.tr("panel.playlists.entry.source_workshop_placeholder")
                elseif entryMediaKindDraft == "video" then noctalia.tr(
                    "panel.playlists.entry.source_video_placeholder"
                )
                else noctalia.tr("panel.playlists.entry.source_still_placeholder"),
            onChange = function(value)
                entryMediaSourceDraft = tostring(value or "")
                render()
            end,
        }),
    }
    if dynamic then
        table.insert(
            children,
            ui.select({
                key = "playlist-entry-still-mode-" .. playlistId .. "-" .. editingEntryId,
                options = {
                    noctalia.tr("panel.playlists.entry.still_automatic"),
                    noctalia.tr("panel.playlists.entry.still_selected"),
                },
                selectedIndex = if entryStillModeDraft == "selected" then 1 else 0,
                onChange = function(index)
                    entryStillModeDraft = if math.floor(tonumber(index) or 0) == 1 then "selected" else "automatic"
                    render()
                end,
            })
        )
        if entryStillModeDraft == "selected" then
            table.insert(
                children,
                ui.input({
                    key = "playlist-entry-still-path-" .. playlistId .. "-" .. editingEntryId,
                    value = entryStillPathDraft,
                    placeholder = noctalia.tr("panel.playlists.entry.still_path_placeholder"),
                    onChange = function(value)
                        entryStillPathDraft = tostring(value or "")
                        render()
                    end,
                })
            )
        end
    end
    table.insert(children, ui.separator())
    table.insert(
        children,
        ui.label({ text = noctalia.tr("panel.palettes.title"), fontSize = 11, fontWeight = "bold" })
    )
    table.insert(
        children,
        ui.row({ gap = 6, align = "center" }, {
            ui.select({
                key = "playlist-entry-theme-mode-" .. playlistId .. "-" .. editingEntryId,
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
                    render()
                end,
            }),
            ui.select({
                key = "playlist-entry-theme-source-" .. playlistId .. "-" .. editingEntryId,
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
                        entryThemeSelectionDraft = paletteNames(entryThemeSourceDraft)[1] or ""
                    end
                    render()
                end,
            }),
        })
    )
    if entryThemeSourceDraft ~= "inherit" then
        local selectionOptions = if #selectionNames > 0
            then selectionNames
            else { noctalia.tr("panel.palettes.no_results") }
        table.insert(
            children,
            ui.select({
                key = "playlist-entry-theme-selection-" .. playlistId .. "-" .. editingEntryId,
                options = selectionOptions,
                selectedIndex = selectionIndex,
                enabled = #selectionNames > 0,
                onChange = function(index)
                    local name = selectionNames[math.floor(tonumber(index) or 0) + 1]
                    if name ~= nil then
                        entryThemeSelectionDraft = tostring(name)
                        render()
                    end
                end,
            })
        )
        if paletteStatus.ready == true and entryThemeSelectionDraft ~= "" and not selectionFound then
            table.insert(
                children,
                ui.label({
                    text = noctalia.tr("panel.palettes.missing"),
                    fontSize = 9,
                    color = "error",
                    maxLines = 2,
                })
            )
        end
    end
    table.insert(
        children,
        ui.row({ gap = 6, align = "center" }, {
            ui.button({
                text = if editingEntryId == ""
                    then noctalia.tr("panel.playlists.entry.add_save")
                    else noctalia.tr("panel.playlists.entry.edit_save"),
                glyph = "device-floppy",
                variant = "primary",
                controlSize = "sm",
                enabled = storageValid()
                    and playlistId ~= ""
                    and output ~= ""
                    and sourceValid
                    and stillValid
                    and (entryThemeSourceDraft == "inherit" or noctalia.string.trim(entryThemeSelectionDraft) ~= ""),
                flexGrow = 1,
                onClick = function()
                    local entry = entryFromDraft()
                    if editingEntryId == "" then
                        send({
                            kind = "playlist_add_entry",
                            output = output,
                            playlist_id = playlistId,
                            entry = entry,
                        })
                    else
                        send({ kind = "playlist_save_entry", playlist_id = playlistId, entry = entry })
                    end
                    entryEditorOpen = false
                    resetEntryDraft()
                    render()
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.playlists.entry.cancel"),
                glyph = "x",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    entryEditorOpen = false
                    resetEntryDraft()
                    render()
                end,
            }),
        })
    )
    return ui.column({
        gap = 7,
        padding = 10,
        radius = 10,
        fill = "surface_variant/0.25",
        border = "outline/0.3",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

local function pairingKindLabel(kind)
    if kind == "video" then
        return noctalia.tr("panel.playlists.entry.media_video")
    elseif kind == "workshop" then
        return noctalia.tr("panel.playlists.entry.media_workshop")
    end
    return noctalia.tr("panel.playlists.entry.media_still")
end

local function pairingKindDescription(kind)
    if kind == "video" then
        return noctalia.tr("panel.pairings.videos_description")
    elseif kind == "workshop" then
        return noctalia.tr("panel.pairings.engine_description")
    end
    return noctalia.tr("panel.pairings.stills_description")
end

local function pairingEditor(kind)
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
    local selectionNames = if entryThemeSourceDraft == "inherit" then {} else paletteNames(entryThemeSourceDraft)
    local paletteStatus = paletteInventory()
    local selectionIndex = 0
    local selectionFound = false
    for index, name in ipairs(selectionNames) do
        if name == entryThemeSelectionDraft then
            selectionIndex = index - 1
            selectionFound = true
            break
        end
    end
    if entryThemeSelectionDraft ~= "" and not selectionFound then
        table.insert(selectionNames, 1, entryThemeSelectionDraft)
    end

    local children = {
        ui.row({ gap = 7, align = "center" }, {
            ui.glyph({
                name = if kind == "static" then "photo" elseif kind == "video" then "movie" else "steam",
                color = "primary",
            }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({
                    text = if editingPairingId == ""
                        then noctalia.tr("panel.pairings.new")
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
        ui.input({
            key = "pairing-source-" .. revision,
            value = entryMediaSourceDraft,
            placeholder = if kind == "workshop"
                then noctalia.tr("panel.playlists.entry.source_workshop_placeholder")
                elseif kind == "video" then noctalia.tr("panel.playlists.entry.source_video_placeholder")
                else noctalia.tr("panel.playlists.entry.source_still_placeholder"),
            onChange = function(value)
                entryMediaSourceDraft = tostring(value or "")
                render()
            end,
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
                requestPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)
                render()
            end,
        }))
        if entryStillModeDraft == "selected" then
            table.insert(children, ui.input({
                key = "pairing-still-path-" .. revision,
                value = entryStillPathDraft,
                placeholder = noctalia.tr("panel.playlists.entry.still_path_placeholder"),
                onChange = function(value)
                    entryStillPathDraft = tostring(value or "")
                    render()
                end,
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
                requestPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)
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
                    entryThemeSelectionDraft = paletteNames(entryThemeSourceDraft)[1] or ""
                end
                requestPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)
                render()
            end,
        }),
    }))
    if entryThemeSourceDraft ~= "inherit" then
        local selectionOptions = if #selectionNames > 0
            then selectionNames
            else { noctalia.tr("panel.palettes.no_results") }
        table.insert(children, ui.select({
            key = "pairing-theme-selection-" .. revision,
            options = selectionOptions,
            selectedIndex = selectionIndex,
            enabled = #selectionNames > 0,
            onChange = function(index)
                local name = selectionNames[math.floor(tonumber(index) or 0) + 1]
                if name ~= nil then
                    entryThemeSelectionDraft = tostring(name)
                    requestPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)
                    render()
                end
            end,
        }))
        if paletteStatus.ready == true and entryThemeSelectionDraft ~= "" and not selectionFound then
            table.insert(children, ui.label({
                text = noctalia.tr("panel.palettes.missing"),
                fontSize = 9,
                color = "error",
                maxLines = 2,
            }))
        end
    end
    table.insert(children, pairingPaletteSwatch(
        bundleFromDraft(editingPairingId),
        editingPairingId,
        function()
            retryPairingAdaptivePreview(bundleFromDraft(editingPairingId), editingPairingId)
            render()
        end
    ))
    table.insert(children, ui.label({
        text = noctalia.tr("panel.pairings.snapshot_notice"),
        fontSize = 9,
        color = "on_surface_variant",
        maxLines = 3,
    }))
    table.insert(children, ui.row({ gap = 6, align = "center" }, {
        ui.button({
            text = noctalia.tr("panel.pairings.save"),
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
                send({ kind = "pairing_save", pairing = bundleFromDraft(editingPairingId) })
                closePairingEditor()
                render()
            end,
        }),
        ui.button({
            text = noctalia.tr("panel.pairings.cancel"),
            glyph = "x",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
                closePairingEditor()
                render()
            end,
        }),
    }))
    return ui.column({
        key = "pairing-editor-" .. kind .. "-" .. revision,
        gap = 7,
        padding = 10,
        radius = 10,
        fill = "primary/0.06",
        border = "primary/0.35",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

local function pairingCatalogSection(kind)
    local ids = sortedPairingIds(kind)
    local visible = if kind == "video"
        then pairingVisibleVideos
        elseif kind == "workshop" then pairingVisibleWorkshops
        else pairingVisibleStills
    local output = focusedOutput()
    local playlistId = resolveSelectedPlaylist(output)
    local children = {
        panelUi.sectionHeader("layers-intersect", noctalia.tr("panel.pairings.title"), pairingKindDescription(kind)),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.pairings.snapshot_notice"),
                fontSize = 9,
                color = "on_surface_variant",
                maxLines = 3,
                flexGrow = 1,
            }),
            ui.button({
                text = noctalia.tr("panel.pairings.new"),
                glyph = "plus",
                variant = "primary",
                controlSize = "sm",
                enabled = storageValid(),
                onClick = function()
                    beginPairingEditor(kind, nil)
                end,
            }),
        }),
    }
    if pairingEditorOpen and pairingEditorKind == kind then
        table.insert(children, pairingEditor(kind))
    end
    if #ids == 0 then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.empty", { kind = pairingKindLabel(kind) }),
            fontSize = 9,
            color = "on_surface_variant",
        }))
    else
        for index = 1, math.min(#ids, visible) do
            local id = ids[index]
            local pairing = pairingMap()[id]
            local media = type(pairing.media) == "table" and pairing.media or nil
            local still = type(pairing.still) == "table" and pairing.still or {}
            local theme = type(pairing.theme) == "table" and pairing.theme or {}
            local source = if media ~= nil then tostring(media.source or "") else tostring(still.path or "")
            local deleteArmed = pendingDeletePairingId == id
            local cardChildren = {
                ui.row({ gap = 7, align = "center" }, {
                    playlistEntryPreview(
                        if kind == "static" then "still" else kind,
                        if tostring(still.mode or "") == "selected" then still.path else "",
                        false
                    ),
                    ui.column({ gap = 1, flexGrow = 1 }, {
                        ui.label({
                            text = tostring(pairing.label or id),
                            fontSize = 11,
                            fontWeight = "bold",
                            maxLines = 1,
                        }),
                        ui.label({
                            text = pairingKindLabel(kind) .. " · " .. source,
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
                            })
                                .. "\n"
                                .. noctalia.tr("panel.playlists.entry.theme_summary", {
                                    theme = pairingThemeText(theme),
                                }),
                            fontSize = 8,
                            color = "on_surface_variant",
                            maxLines = 3,
                        }),
                    }),
                }),
                pairingPaletteSwatch(pairing, id, nil),
            }
            if deleteArmed then
                table.insert(cardChildren, ui.label({
                    text = noctalia.tr("panel.pairings.confirm_delete"),
                    fontSize = 9,
                    color = "error",
                    maxLines = 3,
                }))
            end
            table.insert(cardChildren, ui.row({ gap = 5, align = "center" }, {
                ui.button({
                    text = noctalia.tr("panel.pairings.add"),
                    glyph = "playlist-add",
                    variant = "primary",
                    controlSize = "sm",
                    enabled = storageValid() and (playlistId ~= "" or output ~= ""),
                    flexGrow = 1,
                    onClick = function()
                        send({
                            kind = "playlist_add_pairing",
                            output = output,
                            playlist_id = playlistId,
                            pairing_id = id,
                        })
                    end,
                }),
                ui.button({
                    text = noctalia.tr("panel.pairings.edit"),
                    glyph = "edit",
                    variant = "ghost",
                    controlSize = "sm",
                    enabled = storageValid(),
                    onClick = function()
                        beginPairingEditor(kind, pairing)
                    end,
                }),
                ui.button({
                    text = if deleteArmed
                        then noctalia.tr("panel.pairings.confirm_delete")
                        else noctalia.tr("panel.pairings.delete"),
                    glyph = "trash",
                    variant = if deleteArmed then "danger" else "ghost",
                    controlSize = "sm",
                    enabled = storageValid(),
                    onClick = function()
                        if pendingDeletePairingId == id then
                            pendingDeletePairingId = ""
                            if pairingEditorOpen and editingPairingId == id then
                                closePairingEditor()
                            end
                            send({ kind = "pairing_delete", pairing_id = id })
                        else
                            pendingDeletePairingId = id
                        end
                        render()
                    end,
                }),
            }))
            table.insert(children, ui.column({
                key = "pairing-card-" .. id,
                gap = 6,
                padding = 8,
                radius = 9,
                fill = "surface_variant/0.22",
                border = if deleteArmed then "error/0.55" else "outline/0.25",
                borderWidth = 1,
                align = "stretch",
            }, cardChildren))
        end
        panelUi.appendVisibilityControls(children, #ids, visible, PAIRING_CARD_CHUNK, function(value)
            if kind == "video" then
                pairingVisibleVideos = value
            elseif kind == "workshop" then
                pairingVisibleWorkshops = value
            else
                pairingVisibleStills = value
            end
        end)
    end
    return panelUi.card(children)
end

local function pairingDrawerTitle(kind)
    if kind == "video" then
        return noctalia.tr("panel.pairings.video_drawer")
    elseif kind == "workshop" then
        return noctalia.tr("panel.pairings.engine_drawer")
    end
    return noctalia.tr("panel.pairings.image_drawer")
end

local function pairingDrawerVisibility(kind)
    return if kind == "video"
        then pairingVisibleVideos
        elseif kind == "workshop" then pairingVisibleWorkshops
        else pairingVisibleStills
end

local function setPairingDrawerVisibility(kind, value)
    if kind == "video" then
        pairingVisibleVideos = value
    elseif kind == "workshop" then
        pairingVisibleWorkshops = value
    else
        pairingVisibleStills = value
    end
end

-- Playlist drawers intentionally show only saved snapshot metadata. In
-- particular, they never ask the adaptive palette service for a preview.
local function playlistPairingDrawer(kind, playlistId, output)
    local ids = sortedPairingIds(kind)
    local visible = pairingDrawerVisibility(kind)
    local children = {
        ui.label({
            text = pairingDrawerTitle(kind),
            fontSize = 11,
            fontWeight = "bold",
        }),
    }
    if #ids == 0 then
        table.insert(children, ui.label({
            text = noctalia.tr("panel.pairings.empty", { kind = pairingKindLabel(kind) }),
            fontSize = 9,
            color = "on_surface_variant",
        }))
    else
        for index = 1, math.min(#ids, visible) do
            local id = ids[index]
            local pairing = pairingMap()[id]
            local media = type(pairing.media) == "table" and pairing.media or nil
            local still = type(pairing.still) == "table" and pairing.still or {}
            local theme = type(pairing.theme) == "table" and pairing.theme or {}
            local source = if media ~= nil then tostring(media.source or "") else tostring(still.path or "")
            local dragToken = dragPairingTokenById[id]
            local canAdd = storageValid() and playlistId ~= ""
            local rowChildren = {}
            if dragToken ~= nil then
                table.insert(rowChildren, ui.dragSource({
                    key = "pairing-grip-" .. dragToken,
                    dragType = "wio-pairing",
                    payload = dragToken,
                    enabled = canAdd,
                    previewAncestor = 1,
                    liftFromLayout = true,
                    width = 24,
                    height = 24,
                    align = "center",
                    justify = "center",
                    tooltip = noctalia.tr("panel.pairings.drag"),
                }, {
                    ui.glyph({ name = "menu-2", size = 14, color = "on_surface_variant" }),
                }))
            end
            table.insert(rowChildren, playlistEntryPreview(
                if kind == "static" then "still" else kind,
                if tostring(still.mode or "") == "selected" then still.path else "",
                false
            ))
            table.insert(rowChildren, ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({
                    text = tostring(pairing.label or id),
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
                ui.label({
                    text = noctalia.tr("panel.playlists.entry.theme_summary", {
                        theme = pairingThemeText(theme),
                    }),
                    fontSize = 8,
                    color = "on_surface_variant",
                    maxLines = 1,
                }),
            }))
            table.insert(rowChildren, ui.button({
                text = noctalia.tr("panel.pairings.add"),
                glyph = "playlist-add",
                variant = "ghost",
                controlSize = "sm",
                enabled = canAdd,
                onClick = function()
                    send({
                        kind = "playlist_add_pairing",
                        output = output,
                        playlist_id = playlistId,
                        pairing_id = id,
                    })
                end,
            }))
            table.insert(children, ui.row({
                key = "playlist-drawer-pairing-" .. id,
                gap = 6,
                padding = 7,
                radius = 8,
                fill = "surface_variant/0.22",
                align = "center",
            }, rowChildren))
        end
        panelUi.appendVisibilityControls(children, #ids, visible, PAIRING_CARD_CHUNK, function(value)
            setPairingDrawerVisibility(kind, value)
        end)
    end
    return ui.column({
        key = "playlist-pairing-drawer-" .. kind,
        gap = 5,
        padding = 8,
        radius = 9,
        fill = "surface_variant/0.12",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

local function playlistPairingDrawers(playlistId, output)
    return ui.column({ gap = 7, align = "stretch" }, {
        ui.label({
            text = noctalia.tr("panel.pairings.drag_hint"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 3,
        }),
        ui.label({
            text = noctalia.tr("panel.playlists.drawer_hint"),
            fontSize = 9,
            color = "on_surface_variant",
            maxLines = 3,
        }),
        playlistPairingDrawer("static", playlistId, output),
        playlistPairingDrawer("video", playlistId, output),
        playlistPairingDrawer("workshop", playlistId, output),
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
        accepts = { "wio-pairing", "wio-entry" },
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
    local dayButtons = {}
    for index, name in ipairs(days) do
        local dayIndex = index
        table.insert(dayButtons, ui.button({
            text = name,
            variant = if scheduleWeekdaysDraft[index] then "primary" else "ghost",
            controlSize = "sm",
            flexGrow = 1,
            onClick = function()
                scheduleWeekdaysDraft[dayIndex] = not scheduleWeekdaysDraft[dayIndex]
                render()
            end,
        }))
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
    local firstHalfMonths = {}
    local secondHalfMonths = {}
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
        table.insert(if index <= 6 then firstHalfMonths else secondHalfMonths, button)
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
            end,
        }),
        ui.label({
            text = noctalia.tr("panel.schedules.weekdays"),
            fontSize = 9,
            color = "on_surface_variant",
        }),
        ui.row({ gap = 5, align = "center" }, dayButtons),
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
        ui.row({ gap = 5, align = "center" }, firstHalfMonths),
        ui.row({ gap = 5, align = "center" }, secondHalfMonths),
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

local function schedulesSection(output, playlistId)
    local configuredOutput = outputConfig(output)
    local schedules = type(configuredOutput.schedules) == "table" and configuredOutput.schedules or {}
    local state = outputRuntime(output)
    local children = {
        ui.separator(),
        ui.row({ gap = 7, align = "center" }, {
            ui.label({
                text = noctalia.tr("panel.schedules.title"),
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
    }
    for index, schedule in ipairs(schedules) do
        local scheduleIndex = index
        local scheduleEntry = schedule
        local previousSchedule = schedules[index - 1]
        local nextSchedule = schedules[index + 1]
        local window = if schedule.all_day == true
            then noctalia.tr("panel.schedules.all_day")
            else formatMinute(schedule.start_minute) .. "–" .. formatMinute(schedule.end_minute)
        local months, days = scheduleSelectionSummary(schedule)
        table.insert(
            children,
            ui.row({ gap = 6, align = "center", padding = 7, radius = 8, fill = "surface_variant/0.22" }, {
                ui.column({ gap = 1, flexGrow = 1 }, {
                    ui.label({
                        text = tostring(scheduleIndex)
                            .. ". "
                            .. tostring(schedule.name or noctalia.tr("panel.schedules.default_name")),
                        fontSize = 10,
                        fontWeight = "bold",
                        maxLines = 1,
                    }),
                    ui.label({
                        text = noctalia.tr("panel.schedules.summary", {
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
                }),
                ui.column({ gap = 2, align = "center" }, {
                    ui.row({ gap = 2, align = "center" }, {
                        ui.button({
                            glyph = "arrow-up",
                            tooltip = noctalia.tr("panel.schedules.move_up"),
                            variant = "ghost",
                            controlSize = "sm",
                            enabled = storageValid() and previousSchedule ~= nil,
                            onClick = function()
                                if previousSchedule ~= nil then
                                    send({
                                        kind = "schedule_place",
                                        output = output,
                                        schedule_id = tostring(scheduleEntry.id or ""),
                                        anchor_id = tostring(previousSchedule.id or ""),
                                        placement = "before",
                                    })
                                end
                            end,
                        }),
                        ui.button({
                            glyph = "arrow-down",
                            tooltip = noctalia.tr("panel.schedules.move_down"),
                            variant = "ghost",
                            controlSize = "sm",
                            enabled = storageValid() and nextSchedule ~= nil,
                            onClick = function()
                                if nextSchedule ~= nil then
                                    send({
                                        kind = "schedule_place",
                                        output = output,
                                        schedule_id = tostring(scheduleEntry.id or ""),
                                        anchor_id = tostring(nextSchedule.id or ""),
                                        placement = "after",
                                    })
                                end
                            end,
                        }),
                    }),
                    ui.row({ gap = 2, align = "center" }, {
                        ui.button({
                            glyph = "edit",
                            tooltip = noctalia.tr("panel.schedules.edit"),
                            variant = "ghost",
                            controlSize = "sm",
                            onClick = function()
                                editScheduleDraft(scheduleEntry)
                                render()
                            end,
                        }),
                        ui.button({
                            glyph = "trash",
                            tooltip = noctalia.tr("panel.schedules.delete"),
                            variant = "ghost",
                            controlSize = "sm",
                            onClick = function()
                                send({
                                    kind = "schedule_delete",
                                    output = output,
                                    schedule_id = tostring(scheduleEntry.id or ""),
                                })
                            end,
                        }),
                    }),
                }),
            })
        )
    end
    if scheduleEditorOpen then
        table.insert(children, scheduleEditor(output, playlistId))
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
    local selectedOutputConfig = outputConfig(output)
    local assigned = tostring(selectedOutputConfig.fallback_playlist or "") == playlistId
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
                    selectedPlaylistId = ids[math.floor(tonumber(index) or 0) + 1] or ""
                    playlistNameDraft = ""
                    playlistIntervalDraft = ""
                    playlistVisibleEntries = PLAYLIST_ENTRY_CHUNK
                    entryEditorOpen = false
                    resetEntryDraft()
                    scheduleEditorOpen = false
                    resetScheduleDraft(selectedPlaylistId)
                    render()
                end,
            }),
            ui.button({
                text = if assigned then noctalia.tr("panel.playlists.fallback") else noctalia.tr("panel.playlists.assign"),
                glyph = "pin",
                variant = if assigned then "primary" else "ghost",
                controlSize = "sm",
                enabled = storageValid() and playlistId ~= "" and output ~= "" and not assigned,
                onClick = function()
                    send({ kind = "playlist_assign", output = output, playlist_id = playlistId })
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

    table.insert(children, playlistPairingDrawers(playlistId, output))
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
        for index = 1, math.min(#entries, playlistVisibleEntries) do
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
            local themeText = pairingThemeText(theme)
            local playlistEntryTokens = dragEntryTokenByPlaylist[playlistId]
            local dragToken = type(playlistEntryTokens) == "table" and playlistEntryTokens[entryId] or nil
            local cardChildren = {}
            if dragToken ~= nil then
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
                    playlistEntryPreview(kind, still.path, active),
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
                            })
                                .. "\n"
                                .. noctalia.tr("panel.playlists.entry.theme_summary", { theme = themeText }),
                            fontSize = 8,
                            color = "on_surface_variant",
                            maxLines = 3,
                        }),
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
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = function()
                            editEntryDraft(currentEntry)
                            render()
                        end,
                    }),
                }),
                ui.row({ gap = 5, align = "center" }, {
                    ui.button({
                        text = noctalia.tr("panel.playlists.entry_move_up"),
                        glyph = "arrow-up",
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = index > 1,
                        flexGrow = 1,
                        onClick = function()
                            send({
                                kind = "playlist_move_entry",
                                playlist_id = playlistId,
                                entry_id = tostring(currentEntry.id or ""),
                                direction = "up",
                            })
                        end,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.playlists.entry_move_down"),
                        glyph = "arrow-down",
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = index < #entries,
                        flexGrow = 1,
                        onClick = function()
                            send({
                                kind = "playlist_move_entry",
                                playlist_id = playlistId,
                                entry_id = tostring(currentEntry.id or ""),
                                direction = "down",
                            })
                        end,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.playlists.entry_delete"),
                        glyph = "trash",
                        variant = "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        onClick = function()
                            send({
                                kind = "playlist_remove_entry",
                                playlist_id = playlistId,
                                entry_id = tostring(currentEntry.id or ""),
                            })
                        end,
                    }),
                }),
            }))
            table.insert(children, playlistInsertionZone(playlistId, entryId))
            table.insert(children, ui.row({
                key = "playlist-entry-card-" .. entryId,
                gap = 6,
                padding = 8,
                radius = 9,
                fill = "surface_variant/0.22",
                align = "center",
            }, cardChildren))
        end
        panelUi.appendVisibilityControls(
            children,
            #entries,
            playlistVisibleEntries,
            PLAYLIST_ENTRY_CHUNK,
            function(value)
                playlistVisibleEntries = value
            end
        )
    end
    table.insert(children, playlistInsertionZone(playlistId, ""))
    table.insert(children, entryEditor(playlistId, output))
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
    local daemonNames = {}
    local daemons = type(current.daemons) == "table" and current.daemons or {}
    for _, name in ipairs({ "awww", "swww", "wpaperd", "hyprpaper" }) do
        if daemons[name] == true then
            table.insert(daemonNames, name)
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
    table.insert(
        children,
        ui.label({
            text = noctalia.tr("diagnostics.daemons", {
                commands = if #daemonNames > 0 then table.concat(daemonNames, ", ") else noctalia.tr("common.none"),
            }),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 3,
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
        screens = true,
        library = true,
        shops = true,
        playlists = true,
        diagnostics = true,
    },
    validLibrarySubpages = { images = true, videos = true, workshops = true },
    validShopSubpages = { wallhaven = true, motionbgs = true, steam = true },
    validDisplaySubpages = { overview = true, engines = true, schedule = true },
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
    elseif activePage == "screens" then
        activeSubpage = if panelPages.validDisplaySubpages[activeSubpage] then activeSubpage else "overview"
        panelPages.ensureSelectedScreen()
    elseif activePage == "library" then
        activeSubpage = if panelPages.validLibrarySubpages[activeSubpage] then activeSubpage else "images"
    elseif activePage == "shops" then
        activeSubpage = if panelPages.validShopSubpages[activeSubpage] then activeSubpage else "wallhaven"
    else
        activeSubpage = ""
    end
    entryEditorOpen = false
    closePairingEditor()
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
    entryEditorOpen = false
    closePairingEditor()
    scheduleEditorOpen = false
    render()
end

function panelPages.selectShopPage(subpage)
    if not panelPages.validShopSubpages[subpage] then
        return
    end
    preview.cancel()
    activePage = "shops"
    activeSubpage = subpage
    entryEditorOpen = false
    closePairingEditor()
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
    playlistVisibleEntries = PLAYLIST_ENTRY_CHUNK
    entryEditorOpen = false
    resetEntryDraft()
    closePairingEditor()
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
    scheduleEditorOpen = false
    local configured = outputConfig(output)
    local fallback = tostring(configured.fallback_playlist or "")
    resetScheduleDraft(if playlistMap()[fallback] ~= nil then fallback else selectedPlaylistId)
    activePage = "screens"
    activeSubpage = if panelPages.validDisplaySubpages[activeSubpage] then activeSubpage else "overview"
    render()
end

function panelPages.selectDisplaySubpage(subpage)
    if not panelPages.validDisplaySubpages[subpage] then
        return
    end
    activePage = "screens"
    activeSubpage = subpage
    panelPages.ensureSelectedScreen()
    entryEditorOpen = false
    closePairingEditor()
    scheduleEditorOpen = false
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
    local inset = if tonumber(depth) == 2 then 20 else 10
    local buttonWidth = if tonumber(depth) == 2 then 114 else 124
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
        panelPages.navigationButton("screens", "panel.nav.screens", "device-desktop"),
    }
    local outputs = panelPages.screenNames()
    for _, output in ipairs(outputs) do
        local name = output
        local selected = activePage == "screens" and selectedScreen == name
        table.insert(children, panelPages.insetNavigationButton(
            "screen-" .. name,
            name,
            selected,
            function()
                panelPages.selectScreenPage(name)
            end
        ))
        if selected then
            for _, route in ipairs({
                { id = "overview", label = "panel.nav.display_overview" },
                { id = "engines", label = "panel.nav.display_engines" },
                { id = "schedule", label = "panel.nav.display_schedule" },
            }) do
                local routeId = route.id
                table.insert(children, panelPages.insetNavigationButton(
                    "screen-" .. name .. "-" .. routeId,
                    noctalia.tr(route.label),
                    activeSubpage == routeId,
                    function()
                        panelPages.selectDisplaySubpage(routeId)
                    end,
                    2
                ))
            end
        end
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
    for _, playlistId in ipairs(sortedPlaylistIds(false)) do
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
    local imageReady, imageRoot = panelUi.locationReady("image")
    local videoReady, videoRoot = panelUi.locationReady("video")
    if not imageReady or not videoReady then
        return panelUi.card({
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
                selectedScreen = names[math.floor(tonumber(index) or 0) + 1] or output
                render()
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
                panelPages.selectPage("screens")
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
    return panelUi.card(children)
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
        layer = tostring(engines.layer or configuration.internal_renderer_layer or "bottom"),
        video = {
            enabled = video.enabled ~= false,
            mute = if video.mute ~= nil then video.mute == true else configuration.mpv_mute ~= false,
            hardware_decode = if video.hardware_decode ~= nil
                then video.hardware_decode == true
                else configuration.mpv_hardware_decode ~= false,
            auto_pause = if video.auto_pause ~= nil then video.auto_pause == true else configuration.mpv_auto_pause ~= false,
            auto_pause_mode = tostring(video.auto_pause_mode or configuration.mpv_auto_pause_mode or "FULL"),
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
    local fallback = tostring(outputConfig(output).fallback_playlist or "")
    local fallbackPlaylist = playlistMap()[fallback]
    local playlistName = if type(fallbackPlaylist) == "table"
        then tostring(fallbackPlaylist.name or fallback)
        else noctalia.tr("panel.screens.no_default")
    local labels, ids, selectedIndex = playlistOptions(fallback)
    local hasPlaylists = #labels > 0
    if fallback == "" then
        table.insert(labels, 1, noctalia.tr("panel.screens.no_default"))
        table.insert(ids, 1, "")
        selectedIndex = 0
    end
    local options = if #labels > 0 then labels else { noctalia.tr("panel.playlists.no_playlists") }
    return panelUi.card({
        panelUi.sectionHeader("device-desktop", noctalia.tr("panel.nav.screens"), output),
        ui.label({
            text = noctalia.tr("panel.screens.description"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 3,
        }),
        panelUi.compactRendererControls(output),
        ui.separator(),
        ui.label({
            text = noctalia.tr("panel.screens.default_playlist") .. ": " .. playlistName,
            fontSize = 10,
            fontWeight = "bold",
            maxLines = 2,
        }),
        ui.select({
            key = "screen-default-playlist-" .. output,
            options = options,
            selectedIndex = selectedIndex,
            enabled = hasPlaylists and storageValid(),
            onChange = function(index)
                local id = ids[math.floor(tonumber(index) or 0) + 1] or ""
                if id ~= "" then
                    selectedPlaylistId = id
                    screenIntervalDraft = ""
                    screenOrderDraft = ""
                    scheduleEditorOpen = false
                    resetScheduleDraft(id)
                    send({ kind = "playlist_assign", output = output, playlist_id = id })
                end
            end,
        }),
        panelPages.screenPlaybackSection(output, playlist),
    })
end

function panelPages.screenScheduleSection()
    local output = panelPages.ensureSelectedScreen()
    if output == "" then
        return panelUi.card({
            panelUi.sectionHeader("calendar", noctalia.tr("panel.nav.display_schedule"), noctalia.tr("availability.output")),
        })
    end
    local playlistId = panelPages.selectedScreenPlaylist(output)
    return panelUi.card({
        panelUi.sectionHeader("calendar", noctalia.tr("panel.nav.display_schedule"), output),
        schedulesSection(output, playlistId),
    })
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
    elseif activePage == "screens" then
        if activeSubpage == "engines" then
            return { panelPages.engineSettingsSection(panelPages.ensureSelectedScreen()) }
        elseif activeSubpage == "schedule" then
            return { panelPages.screenScheduleSection() }
        end
        return { panelPages.screensSection() }
    elseif activePage == "diagnostics" then
        return { diagnosticsSection() }
    end
    return { panelPages.homeSection() }
end

render = function()
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

function onOpen(_context)
    preview.cancel()
    pendingDeleteItemId = ""
    pendingDeletePlaylistId = ""
    pendingDeletePairingId = ""
    entryEditorOpen = false
    pairingEditorOpen = false
    editingPairingId = ""
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
    elseif activePage == "screens" and not panelPages.validDisplaySubpages[activeSubpage] then
        activeSubpage = "overview"
    end
    panelPages.ensureSelectedScreen()
    resetScheduleDraft(selectedPlaylistId)
    isOpen = true
    render()
end

function onClose()
    isOpen = false
    -- Let the at-most-four in-flight atomic fetches finish, but do not keep
    -- draining thumbnails for rows the user can no longer see.
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
    if isOpen and preview.retryDue() then
        render()
    end
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
    reconcileDragTokens()
    if isOpen then
        render()
    end
end

reloadSharedState = function()
    lifecycleStatus = noctalia.state.get(STATUS_KEY)
    configState = noctalia.state.get(CONFIG_STATE_KEY)
    runtimeState = noctalia.state.get(RUNTIME_STATE_KEY)
    libraryState = noctalia.state.get(LIBRARY_STATE_KEY)
    rendererState = noctalia.state.get(RENDERER_STATUS_KEY)
    motionBgsState = noctalia.state.get(MOTIONBGS_STATUS_KEY)
    motionBgsResultsState = noctalia.state.get(MOTIONBGS_RESULTS_KEY)
    palettesState = noctalia.state.get(PALETTES_STATUS_KEY)
    wallhavenState = noctalia.state.get(WALLHAVEN_STATUS_KEY)
    wallhavenResultsState = noctalia.state.get(WALLHAVEN_RESULTS_KEY)
    status = composeStatus()
    resolveSelectedPlaylist(if selectedScreen ~= "" then selectedScreen else nil)
    reconcileDragTokens()
end

noctalia.setUpdateInterval(preview.retryPollMs)
noctalia.state.watch(STATUS_KEY, function(nextStatus)
    if adoptLifecycle(nextStatus) then
        -- A service instance change can race the domain callbacks. Re-read the
        -- persistent slots; composeStatus accepts only the matching instance.
        configState = noctalia.state.get(CONFIG_STATE_KEY)
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
    configState = adoptDomain(configState, nextState)
end)
noctalia.state.watch(RUNTIME_STATE_KEY, function(nextState)
    runtimeState = adoptDomain(runtimeState, nextState)
end)
noctalia.state.watch(LIBRARY_STATE_KEY, function(nextState)
    libraryState = adoptDomain(libraryState, nextState)
end)
noctalia.state.watch(RENDERER_STATUS_KEY, function(nextState)
    rendererState = nextState
    refreshPanelState()
end)
noctalia.state.watch(MOTIONBGS_STATUS_KEY, function(nextState)
    motionBgsState = nextState
    refreshPanelState()
end)
noctalia.state.watch(MOTIONBGS_RESULTS_KEY, function(nextState)
    motionBgsResultsState = nextState
    refreshPanelState()
end)
noctalia.state.watch(PALETTES_STATUS_KEY, function(nextState)
    palettesState = nextState
    refreshPanelState()
end)
noctalia.state.watch(WALLHAVEN_STATUS_KEY, function(nextState)
    wallhavenState = nextState
    refreshPanelState()
end)
noctalia.state.watch(WALLHAVEN_RESULTS_KEY, function(nextState)
    wallhavenResultsState = nextState
    refreshPanelState()
end)
reloadSharedState()

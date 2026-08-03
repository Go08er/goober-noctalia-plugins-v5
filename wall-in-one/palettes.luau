--!nonstrict
-- Wall-in-One palette inventory service.
--
-- This entry owns discovery and isolated adaptive-preview generation. It
-- never changes Noctalia's active theme. The coordinator can consume the
-- versioned snapshot below and remains the sole authority for applying an
-- entry's requested palette.
--
-- Commands are `{ schema=1, nonce, action="refresh", force? }` or
-- `{ schema=1, nonce, action="preview", key, path, scheme }`. Preview results
-- are published at `status.preview` as idle/loading/ready/error.

local STATUS_KEY = "wall_in_one_palettes_status_v1"
local COMMAND_KEY = "wall_in_one_palettes_command_v1"
local PROTOCOL = 1
local CACHE_SCHEMA = 1
local CACHE_NAME = "palettes-cache.json"
local COMMUNITY_URL = "https://api.noctalia.dev/palettes"
local FETCH_PROTOCOL = "WIO-FETCH1"

local MAX_BODY_BYTES = 2 * 1024 * 1024
local MAX_CACHE_BYTES = 2 * 1024 * 1024
local MAX_CUSTOM_FILE_BYTES = 512 * 1024
local MAX_PALETTES = 512
local MAX_CATALOG_SCAN = 4096
local MAX_CUSTOM_CANDIDATES = 1024
local MAX_NAME_BYTES = 160
local MAX_ERROR_BYTES = 640
local MAX_NONCE = 9007199254740991
local MAX_PREVIEW_KEY_BYTES = 160
local MAX_PREVIEW_SOURCE_BYTES = 512 * 1024 * 1024
local MAX_PREVIEW_OUTPUT_BYTES = 512 * 1024
local MAX_PREVIEW_CACHE_ENTRIES = 16
local MAX_PREVIEW_SWEEP_ENTRIES = 512
local COMMUNITY_TTL_SECONDS = 6 * 60 * 60
local COMMUNITY_FETCH_TIMEOUT_MS = 40 * 1000
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
local communityGeneration = 1
local transportSequence = 0
local activeCommunityOperation = nil
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

local function validName(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= MAX_NAME_BYTES
        and value:find("[%c]") == nil
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

local function modeField(candidate, field, custom)
    if type(candidate) ~= "table" then
        return ""
    end
    if custom then
        local prefixed = "m" .. field:sub(1, 1):upper() .. field:sub(2)
        local value = normalizedColor(candidate[prefixed])
        if value ~= "" then
            return value
        end
    end
    return normalizedColor(candidate[field])
end

local function normalizedPreviewMode(candidate, custom)
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
            local color = modeField(candidate, field, custom)
            if color ~= "" then
                table.insert(accents, color)
            end
        end
    end

    return {
        surface = modeField(candidate, "surface", custom),
        accents = accents,
    }
end

local function previewModePresent(mode)
    return type(mode) == "table" and type(mode.accents) == "table" and #mode.accents > 0
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
        }, false)
        if previewMode.surface == "" or #previewMode.accents ~= 4 then
            return nil, "Noctalia's " .. modeName .. " palette preview has invalid color roles"
        end
        normalized[modeName] = previewMode
    end
    return normalized, nil
end

local function normalizedCommunityEntry(candidate)
    local name = if type(candidate) == "string"
        then candidate
        elseif type(candidate) == "table" then candidate.name
        else nil
    if not validName(name) then
        return nil
    end

    local md5 = ""
    local previewRoot = {}
    if type(candidate) == "table" then
        local candidateMd5 = tostring(candidate.md5 or "")
        if candidateMd5:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
            md5 = candidateMd5:lower()
        end
        previewRoot = type(candidate.preview) == "table" and candidate.preview or candidate
    end

    return {
        name = name,
        md5 = md5,
        preview = {
            dark = normalizedPreviewMode(previewRoot.dark, false),
            light = normalizedPreviewMode(previewRoot.light, false),
        },
    }
end

local function normalizedCommunityCatalog(candidate)
    if type(candidate) ~= "table" then
        return nil, "Community palette catalog is not a JSON object or array"
    end
    local values = if type(candidate.palettes) == "table" then candidate.palettes else candidate
    if type(values) ~= "table" or #values == 0 then
        return nil, "Community palette catalog contains no palette array"
    end

    local result = {}
    local seen = {}
    for index = 1, math.min(#values, MAX_CATALOG_SCAN) do
        local entry = normalizedCommunityEntry(values[index])
        if entry ~= nil and not seen[entry.name] then
            seen[entry.name] = true
            table.insert(result, entry)
            if #result >= MAX_PALETTES then
                break
            end
        end
    end
    if #result == 0 then
        return nil, "Community palette catalog contains no valid bounded entries"
    end
    table.sort(result, function(left, right)
        return tostring(left.name) < tostring(right.name)
    end)
    return result, nil
end

local function normalizedCustomPreview(candidate)
    if type(candidate) ~= "table" then
        return nil
    end

    local dark
    local light
    if type(candidate.dark) == "table" or type(candidate.light) == "table" then
        dark = normalizedPreviewMode(candidate.dark, true)
        light = normalizedPreviewMode(candidate.light, true)
        if not previewModePresent(light) and previewModePresent(dark) then
            light = copyPreviewMode(dark)
        end
    else
        dark = normalizedPreviewMode(candidate, true)
        light = copyPreviewMode(dark)
    end
    if not previewModePresent(dark) and not previewModePresent(light) then
        return nil
    end
    return { dark = dark, light = light }
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

local function refreshCustomPalettes()
    local directory, directoryError = configPalettesDirectory()
    customDirectory = tostring(directory or "")
    customInvalidCount = 0
    lastCustomRefreshAt = nowText()

    if directory == nil then
        customPalettes = {}
        customError = bounded(directoryError, MAX_ERROR_BYTES)
        lastErrorAt = lastCustomRefreshAt
        return
    end

    local info = noctalia.fileInfo(directory)
    if type(info) ~= "table" then
        -- An absent palettes directory is Noctalia's normal empty-custom state.
        customPalettes = {}
        customError = ""
        return
    elseif info.isDir ~= true then
        customPalettes = {}
        customError = "Noctalia's palettes path is not a directory"
        lastErrorAt = lastCustomRefreshAt
        return
    end

    local names, listError = noctalia.listDir(directory)
    if type(names) ~= "table" then
        customPalettes = {}
        customError = bounded(listError or "Could not enumerate Noctalia custom palettes", MAX_ERROR_BYTES)
        lastErrorAt = lastCustomRefreshAt
        return
    end
    table.sort(names, function(left, right)
        return tostring(left) < tostring(right)
    end)

    local result = {}
    local seen = {}
    local candidateCount = 0
    local directoryTruncated = #names > MAX_CUSTOM_CANDIDATES
    for index = 1, math.min(#names, MAX_CUSTOM_CANDIDATES) do
        local filename = tostring(names[index] or "")
        if filename:sub(-5) == ".json" then
            candidateCount += 1
            local stem = filename:sub(1, -6)
            local path = directory .. "/" .. filename
            local fileInfo = validName(stem) and noctalia.fileInfo(path) or nil
            local preview = nil
            if
                type(fileInfo) == "table"
                and fileInfo.isDir ~= true
                and (tonumber(fileInfo.size) or 0) > 0
                and (tonumber(fileInfo.size) or 0) <= MAX_CUSTOM_FILE_BYTES
            then
                local raw = noctalia.readFile(path)
                local decoded = type(raw) == "string" and noctalia.json.decode(raw) or nil
                preview = normalizedCustomPreview(decoded)
            end
            if preview ~= nil and not seen[stem] and #result < MAX_PALETTES then
                seen[stem] = true
                table.insert(result, { name = stem, preview = preview })
            else
                customInvalidCount += 1
            end
        end
    end
    table.sort(result, function(left, right)
        return tostring(left.name) < tostring(right.name)
    end)
    customPalettes = result

    local problems = {}
    if directoryTruncated then
        table.insert(problems, "custom palette directory exceeded the bounded scan limit")
    end
    if candidateCount > MAX_PALETTES then
        table.insert(problems, "custom palette inventory exceeded the 512-entry limit")
    end
    if customInvalidCount > 0 then
        table.insert(problems, tostring(customInvalidCount) .. " custom palette file(s) were invalid or outside limits")
    end
    customError = bounded(table.concat(problems, "; "), MAX_ERROR_BYTES)
    if customError ~= "" then
        lastErrorAt = lastCustomRefreshAt
    end
end

local function cachePath()
    local directory, directoryError = noctalia.pluginDataDir()
    if type(directory) ~= "string" or directory == "" then
        return nil, tostring(directoryError or "Plugin data directory is unavailable")
    end
    return directory .. "/" .. CACHE_NAME, nil
end

local function readCacheCandidate(path)
    if not noctalia.fileExists(path) then
        return nil, "missing"
    end
    local info = noctalia.fileInfo(path)
    if
        type(info) ~= "table"
        or info.isDir == true
        or (tonumber(info.size) or 0) <= 0
        or (tonumber(info.size) or 0) > MAX_CACHE_BYTES
    then
        return nil, "cache file size is invalid"
    end
    local raw, readError = noctalia.readFile(path)
    if type(raw) ~= "string" then
        return nil, tostring(readError or "cache file could not be read")
    end
    local decoded = noctalia.json.decode(raw)
    if type(decoded) ~= "table" or tonumber(decoded.schema) ~= CACHE_SCHEMA then
        return nil, "cache schema is invalid"
    end
    local fetchedAt = tonumber(decoded.fetched_at)
    local now = nowSeconds()
    if
        fetchedAt == nil
        or fetchedAt % 1 ~= 0
        or fetchedAt <= 0
        or (now > 0 and fetchedAt > now + 300)
    then
        return nil, "cache timestamp is invalid"
    end
    local entries, entriesError = normalizedCommunityCatalog(decoded.entries)
    if entries == nil then
        return nil, entriesError
    end
    return {
        entries = entries,
        fetched_at = fetchedAt,
        fetched_at_text = bounded(decoded.fetched_at_text or "", 80),
    }, nil
end

local function loadCommunityCache()
    local path, pathError = cachePath()
    if path == nil then
        cacheError = bounded(pathError, MAX_ERROR_BYTES)
        lastErrorAt = nowText()
        return
    end

    local primary, primaryError = readCacheCandidate(path)
    local selected = primary
    cacheSource = if primary ~= nil then "primary" else "none"
    if selected == nil then
        local backup, backupError = readCacheCandidate(path .. ".bak")
        if backup ~= nil then
            selected = backup
            cacheSource = "backup"
            cacheError = if primaryError == "missing"
                then "Primary palette cache is missing; using the last-known-good backup"
                else "Primary palette cache is invalid; using the last-known-good backup"
            lastErrorAt = nowText()
        elseif primaryError ~= "missing" then
            cacheError = bounded("Palette cache is invalid: " .. tostring(primaryError), MAX_ERROR_BYTES)
            lastErrorAt = nowText()
        elseif backupError ~= "missing" then
            cacheError = bounded("Palette cache backup is invalid: " .. tostring(backupError), MAX_ERROR_BYTES)
            lastErrorAt = nowText()
        end
    end

    if selected ~= nil then
        communityPalettes = selected.entries
        cacheLoaded = true
        cacheFetchedAt = selected.fetched_at
        cacheFetchedAtText = selected.fetched_at_text
        lastCommunitySuccessAt = cacheFetchedAtText
    end
end

local function atomicWriteCache(entries, fetchedAt, fetchedAtText)
    local path, pathError = cachePath()
    if path == nil then
        return false, pathError
    end
    local encoded, encodeError = noctalia.json.encode({
        schema = CACHE_SCHEMA,
        fetched_at = fetchedAt,
        fetched_at_text = fetchedAtText,
        entries = entries,
    }, true)
    if type(encoded) ~= "string" then
        return false, tostring(encodeError or "Palette cache could not be encoded")
    end
    if #encoded + 1 > MAX_CACHE_BYTES then
        return false, "Palette cache exceeds the 2 MiB storage limit"
    end

    local temporary = path .. ".tmp"
    local backup = path .. ".bak"
    local backupTemporary = backup .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        return false, tostring(writeError or "Palette cache temporary write failed")
    end

    local previousCache = readCacheCandidate(path)
    if previousCache ~= nil then
        local previous, readError = noctalia.readFile(path)
        if type(previous) ~= "string" then
            noctalia.removeFile(temporary)
            return false, tostring(readError or "Existing palette cache could not be backed up")
        end
        local backupWrote, backupWriteError = noctalia.writeFile(backupTemporary, previous)
        if backupWrote ~= true then
            noctalia.removeFile(temporary)
            noctalia.removeFile(backupTemporary)
            return false, tostring(backupWriteError or "Palette cache backup write failed")
        end
        local backupInstalled, backupInstallError = noctalia.renameFile(backupTemporary, backup)
        if backupInstalled ~= true then
            noctalia.removeFile(temporary)
            noctalia.removeFile(backupTemporary)
            return false, tostring(backupInstallError or "Palette cache backup install failed")
        end
    end

    local installed, installError = noctalia.renameFile(temporary, path)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or "Palette cache install failed")
    end
    return true, nil
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

local function paletteListSignature(values)
    local parts = {}
    for _, entry in ipairs(values) do
        local preview = type(entry.preview) == "table" and entry.preview or {}
        local fields = { entry.name, entry.md5 }
        for _, modeName in ipairs({ "dark", "light" }) do
            local mode = type(preview[modeName]) == "table" and preview[modeName] or {}
            table.insert(fields, mode.surface)
            for _, color in ipairs(type(mode.accents) == "table" and mode.accents or {}) do
                table.insert(fields, color)
            end
        end
        for _, field in ipairs(fields) do
            table.insert(parts, signatureToken(field))
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
        paletteListSignature(communityPalettes),
        paletteListSignature(customPalettes),
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
    table.sort(names, function(left, right)
        return tostring(left) < tostring(right)
    end)

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

local function boundedFetchHelper()
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

local function cleanupCommunityTransport(operation, keepResponse)
    if type(operation) ~= "table" then
        return
    end
    removeTransportFile(operation.guard_path)
    if keepResponse ~= true then
        removeTransportFile(operation.response_path)
    end
end

local function allocateCommunityTransport(operation)
    local directory, directoryError = transportDirectory()
    if directory == nil then
        return false, directoryError
    end
    for _ = 1, 8 do
        transportSequence += 1
        local token = tostring(math.floor(noctalia.nowMs()))
            .. "-"
            .. tostring(lastCommandNonce)
            .. "-"
            .. tostring(transportSequence)
        local responsePath = directory .. "/palettes-" .. token .. ".json"
        local guardPath = directory .. "/.wall-in-one-guard-palettes-" .. token
        if not noctalia.fileExists(responsePath) and not noctalia.fileExists(guardPath) then
            local wrote, writeError = noctalia.writeFile(guardPath, FETCH_PROTOCOL .. "\n")
            if wrote ~= true then
                return false, tostring(writeError or "Could not create request cancellation guard")
            end
            operation.response_path = responsePath
            operation.guard_path = guardPath
            return true, nil
        end
    end
    return false, "Could not allocate unique palette transport files"
end

local function boundedFetchResult(result)
    if type(result) ~= "table" then
        return nil, "transport", "Bounded fetch returned no process result"
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
            nil
    end

    local errorProtocol, errorOutcome, kind, _errorStatus, detail =
        output:match("^([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if errorProtocol == FETCH_PROTOCOL and errorOutcome == "error" then
        return nil, bounded(kind, 80), bounded(detail, 400)
    end
    if result.timedOut == true then
        return nil, "timeout", "Bounded fetch exceeded Noctalia's process timeout"
    end
    local fallback = bounded(result.stderr or result.stdout, 400)
    if fallback == "" then
        fallback = "Bounded fetch exited without a valid protocol result"
    end
    return nil, "protocol", fallback
end

local function communityOperationIsCurrent(operation)
    return ready
        and activeCommunityOperation == operation
        and operation.generation == communityGeneration
end

local function failCommunityRefresh(message, operation)
    if type(operation) == "table" and not communityOperationIsCurrent(operation) then
        cleanupCommunityTransport(operation, false)
        return
    end
    cleanupCommunityTransport(operation, false)
    if activeCommunityOperation == operation then
        activeCommunityOperation = nil
    end
    communityInFlight = false
    communityError = bounded(message, MAX_ERROR_BYTES)
    lastErrorAt = nowText()
    lastEvent = "refresh-failed"
    publishStatus(false)
end

local function refreshCommunity(force, reason)
    if communityInFlight then
        lastEvent = "refresh-in-flight"
        publishStatus(false)
        return false
    end
    if force ~= true and cacheIsFresh() then
        lastEvent = "cache-fresh"
        publishStatus(false)
        return false
    end

    communityInFlight = true
    lastRefreshAt = nowText()
    lastEvent = bounded(reason or "refresh-started", 80)
    local operation = {
        generation = communityGeneration,
        url = COMMUNITY_URL,
    }
    activeCommunityOperation = operation
    local allocated, allocationError = allocateCommunityTransport(operation)
    if allocated ~= true then
        failCommunityRefresh(allocationError, operation)
        return false
    end
    local helper = boundedFetchHelper()
    if helper == nil or not noctalia.commandExists("curl") then
        failCommunityRefresh("The bundled bounded-fetch helper and curl are required", operation)
        return false
    end
    local command = table.concat({
        "exec bash",
        shellQuote(helper),
        "palette-catalog",
        shellQuote(COMMUNITY_URL),
        shellQuote(operation.response_path),
        shellQuote(operation.guard_path),
        shellQuote("-"),
        "0",
    }, " ")
    local accepted = noctalia.runAsync(command, function(result)
        if not communityOperationIsCurrent(operation) then
            cleanupCommunityTransport(operation, false)
            return
        end
        local transport, transportKind, transportMessage = boundedFetchResult(result)
        cleanupCommunityTransport(operation, transport ~= nil)
        if transport == nil then
            failCommunityRefresh(
                "Community palette request failed (" .. tostring(transportKind or "transport") .. "): "
                    .. tostring(transportMessage or "request failed"),
                operation
            )
            return
        end
        local info = noctalia.fileInfo(operation.response_path)
        if
            transport.profile ~= "palette-catalog"
            or transport.status ~= 200
            or transport.effective_url ~= COMMUNITY_URL
            or transport.content_type ~= "application/json"
            or transport.path ~= operation.response_path
            or transport.bytes < 1
            or transport.bytes > MAX_BODY_BYTES
            or type(info) ~= "table"
            or info.isDir == true
            or math.floor(tonumber(info.size) or 0) ~= transport.bytes
        then
            failCommunityRefresh("Community palette transport returned mismatched response metadata", operation)
            return
        end
        local body, readError = noctalia.readFile(operation.response_path)
        removeTransportFile(operation.response_path)
        if type(body) ~= "string" or #body ~= transport.bytes or #body > MAX_BODY_BYTES then
            failCommunityRefresh(readError or "Community palette response could not be read safely", operation)
            return
        end
        local decoded = noctalia.json.decode(body)
        local entries, parseError = normalizedCommunityCatalog(decoded)
        if entries == nil then
            failCommunityRefresh(parseError or "Community palette response was invalid", operation)
            return
        end

        activeCommunityOperation = nil
        communityInFlight = false
        communityPalettes = entries
        cacheLoaded = true
        cacheSource = "network"
        cacheFetchedAt = nowSeconds()
        cacheFetchedAtText = nowText()
        lastCommunitySuccessAt = cacheFetchedAtText
        communityError = ""
        lastEvent = "refresh-complete"

        local saved, saveError = atomicWriteCache(entries, cacheFetchedAt, cacheFetchedAtText)
        if saved then
            cacheSource = "primary"
            cacheError = ""
        else
            cacheError = bounded(saveError or "Community palette cache could not be saved", MAX_ERROR_BYTES)
            lastErrorAt = nowText()
        end
        publishStatus(false)
    end, COMMUNITY_FETCH_TIMEOUT_MS)
    if accepted ~= true then
        failCommunityRefresh("Noctalia could not start bounded community palette transport", operation)
        return false
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
    communityGeneration += 1
    nextPreviewGeneration()
    cleanupCommunityTransport(activeCommunityOperation, false)
    cleanupPreviewOperation(activePreviewOperation)
    activeCommunityOperation = nil
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
    loadCommunityCache()
    refreshCustomPalettes()
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
        refreshCustomPalettes()
        refreshCommunity(command.force == true, "refresh-started")
    else
        requestAdaptivePreview(command)
    end
    publishStatus(false)
    return true
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
        refreshCommunity(false, "image-directory-ready")
        publishStatus(false)
        return
    end

    -- Unrelated config changes preserve the previous service behavior: custom
    -- palette inventory is rescanned without bypassing the community TTL.
    refreshCustomPalettes()
    lastEvent = "custom-refreshed"
    publishStatus(false)
end

function onExit(_signal, _reason)
    communityGeneration += 1
    nextPreviewGeneration()
    cleanupCommunityTransport(activeCommunityOperation, false)
    cleanupPreviewOperation(activePreviewOperation)
    activeCommunityOperation = nil
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

if startupImageRoot ~= nil then
    initializeForImageRoot(startupImageRoot)
else
    deactivateForMissingImageRoot(startupImageRootError)
end

-- Watches do not replay a command that landed during service replacement.
-- Consume it once if its nonce is newer; otherwise perform one TTL-gated
-- startup refresh. There is intentionally no periodic network poller.
local consumedCurrentCommand = handleCommand(noctalia.state.get(COMMAND_KEY))
if ready and not consumedCurrentCommand then
    refreshCommunity(false, "startup-refresh")
end
publishStatus(false)

--!nonstrict
-- Wall-in-One coordinator service.
--
-- Provider processes remain provider-owned. This service discovers supported
-- providers, routes their documented controls, exports representative stills,
-- and applies those stills through Noctalia so its lock screen, backdrop, theme,
-- and wallpaper hooks see the same image as the live background.

local CONFIG_SCHEMA = 1
local RUNTIME_SCHEMA = 2
local UPDATE_INTERVAL_MS = 2000
local PROVIDER_PROBE_SECONDS = 30
local NOTIFY_COOLDOWN_SECONDS = 10
local ADAPTER_PROBE_GRACE_MS = 10000
local MAX_PROJECT_JSON_BYTES = 1024 * 1024

local SERVICE_NONCE = (tostring(noctalia.nowMs()) .. "-" .. tostring({})):gsub("[^%w-]", "")

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"
local COMMAND_ACK_KEY = "wall_in_one_command_ack"

local WALLHAVEN_ID = "noctalia/wallhaven"
local W_ENGINE_ID = "tadomika_ari/w-engine"
local W_ENGINE_SERVICE = "tadomika_ari/w-engine:start"
local MPVPAPER_ID = "noctalia/mpvpaper"
local MPVPAPER_SERVICE = "noctalia/mpvpaper:service"

local OPEN_TARGETS = {
    native_open = "wallpaper",
    wallhaven_open = "noctalia/wallhaven:browser",
    w_engine_open = "tadomika_ari/w-engine:w-engine-panel",
    mpvpaper_open = "noctalia/mpvpaper:picker",
    hub_open = "goober/wall-in-one:hub",
}

local NATIVE_SWITCH_VERBS = {
    native_next = "wallpaper-next",
    native_previous = "wallpaper-previous",
    native_random = "wallpaper-random",
}

local W_ENGINE_VERBS = {
    w_engine_next = "next",
    w_engine_cycle_stop = "cycle-stop",
    w_engine_stop = "stop",
}

local MPVPAPER_VERBS = {
    mpvpaper_pause = "pause",
    mpvpaper_resume = "resume",
    mpvpaper_toggle = "toggle",
    mpvpaper_clear = "clear",
    mpvpaper_clear_all = "clear-all",
}

local VALID_COLOR_SCHEMES = {
    ["m3-content"] = true,
    ["m3-tonal-spot"] = true,
    ["m3-fruit-salad"] = true,
    ["m3-rainbow"] = true,
    ["m3-monochrome"] = true,
    vibrant = true,
    faithful = true,
    soft = true,
    dysfunctional = true,
    muted = true,
}

local VALID_ACTIONS = {
    native_open = true,
    native_next = true,
    native_previous = true,
    native_random = true,
    wallhaven_open = true,
    w_engine_open = true,
    w_engine_next = true,
    w_engine_cycle_stop = true,
    w_engine_stop = true,
    mpvpaper_open = true,
    mpvpaper_pause = true,
    mpvpaper_resume = true,
    mpvpaper_toggle = true,
    mpvpaper_clear = true,
    mpvpaper_clear_all = true,
    capture_current = true,
    capture_pair = true,
    video_capture = true,
    video_capture_pair = true,
    manual_pair = true,
    extra_provider_open = true,
    hub_open = true,
    no_action = true,
}

local WORKSHOP_PATHS = {
    "~/.steam/steam/steamapps/workshop/content/431960/",
    "~/.local/share/Steam/steamapps/workshop/content/431960/",
    "~/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/431960/",
    "~/snap/steam/common/.local/share/Steam/steamapps/workshop/content/431960/",
    "~/snap/steam/common/.local/share/steam/steamapps/workshop/content/431960/",
}

local config = {
    schema_version = CONFIG_SCHEMA,
    gestures = {
        left = "native_open",
        middle = "wallhaven_open",
        right = "w_engine_open",
    },
}

local runtime = {
    schema_version = RUNTIME_SCHEMA,
    providers = {},
    pairs = {},
    last_capture = {},
    observed_at = "",
    last_error = "",
}

local providers = {
    probing = true,
    probe_ok = false,
    probe_error = "",
    probed_at = "",
    noctalia_cli = noctalia.commandExists("noctalia"),
    native = { available = true },
    wallhaven = { plugin_enabled = false, available = false, version = "" },
    w_engine = {
        plugin_enabled = false,
        renderer_available = noctalia.commandExists("linux-wallpaperengine"),
        available = false,
        version = "",
        adapter_version = "",
        adapter_capture = false,
        adapter_status = false,
        adapter_seen_at = "",
        adapter_seen_ms = 0,
        adapter_probe_ms = 0,
        current = {},
    },
    mpvpaper = {
        plugin_enabled = false,
        command_available = noctalia.commandExists("mpvpaper") and noctalia.commandExists("mpv"),
        available = false,
        version = "",
    },
    extra = { configured = false, plugin_enabled = false, available = false, panel = "", plugin_id = "" },
}

local colors = {
    probing = false,
    source = "",
    scheme = "",
    error = "",
}

local configValid = true
local runtimeValid = true
local configError = ""
local runtimeError = ""
local lastActionError = ""
local lastActionAt = ""
local statusSequence = 0
local providerProbeInFlight = false
local colorProbeInFlight = false
local providerSignature = ""
local lastProviderProbeAt = 0
local lastNotificationAt = {}
local lastCommandSequence = 0
local captureInFlight = {}
local captureQueued = {}
local captureSequence = 0
local pendingAdapterCaptures = {}

local runCapture

-- Clear readiness before installing the command watch. Clients retain a
-- gesture while a service hot reload is in progress.
noctalia.state.set(STATUS_KEY, { ready = false })

local function nowSeconds()
    return tonumber(noctalia.formatTime("%s")) or 0
end

local function commandFailureDetail(result)
    if type(result) ~= "table" then
        return ""
    end
    local detail = noctalia.string.trim(tostring(result.stderr or ""))
    if detail == "" then
        detail = noctalia.string.trim(tostring(result.stdout or ""))
    end
    detail = detail:gsub("[%c]", " ")
    if #detail > 320 then
        detail = detail:sub(1, 320)
    end
    return detail
end

local function boundedDetail(value)
    local detail = noctalia.string.trim(tostring(value or "")):gsub("[%c]", " ")
    if #detail > 320 then
        detail = detail:sub(1, 320)
    end
    return detail
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function knownOutputName(candidate)
    if type(candidate) ~= "string" or candidate == "" then
        return nil
    end
    for _, output in ipairs(noctalia.outputs()) do
        if output.name == candidate then
            return candidate
        end
    end
    return nil
end

local function targetOutput(candidate)
    return knownOutputName(candidate) or knownOutputName(noctalia.focusedOutputName())
end

local function settingString(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) ~= "string" or value:find("%S") == nil then
        return fallback
    end
    return value
end

local function settingBool(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) == "boolean" then
        return value
    end
    return fallback
end

local function settingInt(key, fallback, minimum, maximum)
    local value = math.floor(tonumber(noctalia.getConfig(key)) or fallback)
    return math.max(minimum, math.min(maximum, value))
end

local function configuredColorScheme()
    local scheme = settingString("color_scheme", "m3-content")
    if not VALID_COLOR_SCHEMES[scheme] then
        return "m3-content"
    end
    return scheme
end

local function captureDirectory()
    local configured = settingString("capture_directory", "")
    local directory = ""
    if configured == "" then
        local dataDirectory = noctalia.pluginDataDir()
        if type(dataDirectory) == "string" and dataDirectory ~= "" then
            directory = dataDirectory .. "/captures"
        end
    else
        directory = noctalia.expandPath(configured)
    end

    if type(directory) ~= "string" or directory == "" or directory:sub(1, 1) ~= "/" or directory:find("[%c]") then
        return ""
    end
    if directory ~= "/" then
        directory = directory:gsub("/+$", "")
    end
    return directory
end

local function configuredVideoSource()
    local value = settingString("video_source", "")
    return if value == "" then "" else noctalia.expandPath(value)
end

local function configuredManualPair()
    local value = settingString("manual_pair_file", "")
    return if value == "" then "" else noctalia.expandPath(value)
end

local function configuredWorkshopId()
    local value = settingString("workshop_id", "")
    return if value:match("^%d+$") ~= nil then value else ""
end

local function normalizedExtraPanel()
    local panelId = settingString("extra_provider_panel", "")
    if panelId == "" or panelId:match("^[%w_.-]+/[%w_.-]+:[%w_.-]+$") == nil then
        return "", ""
    end
    return panelId, panelId:match("^([^:]+):") or ""
end

local function settingsSnapshot()
    return {
        capture_directory = captureDirectory(),
        auto_capture = settingBool("auto_capture", false),
        pair_static = settingBool("pair_static", true),
        sync_colors = settingBool("sync_colors", false),
        color_scheme = configuredColorScheme(),
        palette_output = settingString("palette_output", ""),
        video_source = configuredVideoSource(),
        manual_pair_file = configuredManualPair(),
        workshop_id = configuredWorkshopId(),
        workshop_directory = settingString("workshop_directory", ""),
        video_frame_second = settingInt("video_frame_second", 1, 0, 3600),
        scene_screenshot_delay = settingInt("scene_screenshot_delay", 15, 1, 120),
        extra_provider_panel = providers.extra.panel,
    }
end

local function storagePath(name)
    local directory, errorMessage = noctalia.pluginDataDir()
    if type(directory) ~= "string" or directory == "" then
        return nil, tostring(errorMessage or noctalia.tr("errors.data_directory"))
    end
    return directory .. "/" .. name, nil
end

local function cloneGestures(source)
    local gestures = type(source) == "table" and source or {}
    return {
        left = tostring(gestures.left or ""),
        middle = tostring(gestures.middle or ""),
        right = tostring(gestures.right or ""),
    }
end

local function validateConfig(candidate)
    if type(candidate) ~= "table" then
        return nil, noctalia.tr("errors.config_not_object")
    end
    if tonumber(candidate.schema_version) ~= CONFIG_SCHEMA then
        return nil, noctalia.tr("errors.config_schema", { version = tostring(candidate.schema_version or "?") })
    end
    if type(candidate.gestures) ~= "table" then
        return nil, noctalia.tr("errors.config_gestures")
    end

    local gestures = cloneGestures(candidate.gestures)
    for _, button in ipairs({ "left", "middle", "right" }) do
        if not VALID_ACTIONS[gestures[button]] then
            return nil,
                noctalia.tr("errors.config_action", {
                    button = button,
                    action = gestures[button],
                })
        end
    end

    return { schema_version = CONFIG_SCHEMA, gestures = gestures }, nil
end

local function validateRuntime(candidate)
    if type(candidate) ~= "table" then
        return nil, noctalia.tr("errors.runtime_not_object")
    end
    local schema = tonumber(candidate.schema_version)
    if schema ~= 1 and schema ~= RUNTIME_SCHEMA then
        return nil, noctalia.tr("errors.runtime_schema", { version = tostring(candidate.schema_version or "?") })
    end
    if type(candidate.providers) ~= "table" or (schema == RUNTIME_SCHEMA and type(candidate.pairs) ~= "table") then
        return nil, noctalia.tr("errors.runtime_providers")
    end
    return {
        schema_version = RUNTIME_SCHEMA,
        providers = candidate.providers,
        pairs = type(candidate.pairs) == "table" and candidate.pairs or {},
        last_capture = type(candidate.last_capture) == "table" and candidate.last_capture or {},
        observed_at = tostring(candidate.observed_at or ""),
        last_error = tostring(candidate.last_error or ""),
    },
        nil,
        schema == 1
end

local function atomicWrite(name, value)
    local path, pathError = storagePath(name)
    if path == nil then
        return false, pathError
    end

    local encoded, encodeError = noctalia.json.encode(value, true)
    if type(encoded) ~= "string" then
        return false, tostring(encodeError or noctalia.tr("errors.encode"))
    end

    local temporary = path .. ".tmp"
    local backup = path .. ".bak"
    local backupTemporary = backup .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        return false, tostring(writeError or noctalia.tr("errors.write"))
    end

    if noctalia.fileExists(path) then
        local previous, readError = noctalia.readFile(path)
        if type(previous) ~= "string" then
            noctalia.removeFile(temporary)
            return false, tostring(readError or noctalia.tr("errors.backup"))
        end
        local backupWritten, backupWriteError = noctalia.writeFile(backupTemporary, previous)
        if backupWritten ~= true then
            noctalia.removeFile(temporary)
            noctalia.removeFile(backupTemporary)
            return false, tostring(backupWriteError or noctalia.tr("errors.backup"))
        end
        local backedUp, backupError = noctalia.renameFile(backupTemporary, backup)
        if backedUp ~= true then
            noctalia.removeFile(temporary)
            noctalia.removeFile(backupTemporary)
            return false, tostring(backupError or noctalia.tr("errors.backup"))
        end
    end

    local installed, installError = noctalia.renameFile(temporary, path)
    if installed == true then
        return true, nil
    end
    noctalia.removeFile(temporary)
    return false, tostring(installError or noctalia.tr("errors.install"))
end

local function loadJsonFile(name, validator, defaults)
    local path, pathError = storagePath(name)
    if path == nil then
        return nil, pathError
    end
    if not noctalia.fileExists(path) then
        local saved, saveError = atomicWrite(name, defaults)
        if saved then
            return defaults, nil
        end
        return nil, saveError
    end
    local raw, readError = noctalia.readFile(path)
    if type(raw) ~= "string" then
        return nil, tostring(readError or noctalia.tr("errors.read"))
    end
    local decoded, decodeError = noctalia.json.decode(raw)
    if decoded == nil then
        return nil, noctalia.tr("errors.decode", { detail = tostring(decodeError or "") })
    end
    return validator(decoded)
end

local function loadStorage()
    local loadedConfig, loadedConfigError = loadJsonFile("config.json", validateConfig, config)
    if loadedConfig == nil then
        configValid = false
        configError = tostring(loadedConfigError or noctalia.tr("errors.config_invalid"))
    else
        config = loadedConfig
    end

    local loadedRuntime, loadedRuntimeError, migratedRuntime = loadJsonFile("runtime.json", validateRuntime, runtime)
    if loadedRuntime == nil then
        runtimeValid = false
        runtimeError = tostring(loadedRuntimeError or noctalia.tr("errors.runtime_invalid"))
    else
        runtime = loadedRuntime
        if migratedRuntime then
            local migrated, migrationError = atomicWrite("runtime.json", runtime)
            if not migrated then
                runtimeValid = false
                runtimeError = tostring(migrationError or noctalia.tr("errors.runtime_save"))
            end
        end
    end
end

local function statusSnapshot()
    statusSequence += 1
    local activeCaptures = {}
    for output, capture in pairs(captureInFlight) do
        activeCaptures[output] = capture
    end
    return {
        protocol = 2,
        sequence = statusSequence,
        ready = true,
        storage_valid = configValid and runtimeValid,
        config_valid = configValid,
        runtime_valid = runtimeValid,
        config_error = configError,
        runtime_error = runtimeError,
        config = { schema_version = CONFIG_SCHEMA, gestures = cloneGestures(config.gestures) },
        settings = settingsSnapshot(),
        providers = providers,
        colors = colors,
        pairs = runtime.pairs,
        last_capture = runtime.last_capture,
        captures = activeCaptures,
        last_action_error = lastActionError,
        last_action_at = lastActionAt,
    }
end

local function publishStatus()
    noctalia.state.set(STATUS_KEY, statusSnapshot())
end

local function notifyBounded(key, message)
    local now = nowSeconds()
    local previous = tonumber(lastNotificationAt[key]) or 0
    if now == 0 or previous == 0 or now - previous >= NOTIFY_COOLDOWN_SECONDS then
        lastNotificationAt[key] = now
        noctalia.notifyError(noctalia.tr("plugin.title"), message)
    end
end

local function setActionError(message, notifyKey)
    lastActionError = tostring(message or "")
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishStatus()
    if notifyKey ~= nil and lastActionError ~= "" then
        notifyBounded(notifyKey, lastActionError)
    end
end

local function providerCurrentSignature()
    local current = {}
    for output, id in pairs(providers.w_engine.current or {}) do
        table.insert(current, tostring(output) .. "=" .. tostring(id))
    end
    table.sort(current)
    return table.concat(current, ",")
end

local function currentProviderSignature()
    return table.concat({
        tostring(providers.probe_ok),
        tostring(providers.probe_error),
        tostring(providers.wallhaven.plugin_enabled),
        tostring(providers.wallhaven.version),
        tostring(providers.w_engine.plugin_enabled),
        tostring(providers.w_engine.version),
        tostring(providers.w_engine.renderer_available),
        tostring(providers.w_engine.adapter_version),
        tostring(providers.w_engine.adapter_capture),
        tostring(providers.w_engine.adapter_status),
        providerCurrentSignature(),
        tostring(providers.mpvpaper.plugin_enabled),
        tostring(providers.mpvpaper.version),
        tostring(providers.mpvpaper.command_available),
        tostring(providers.extra.panel),
        tostring(providers.extra.plugin_enabled),
        tostring(colors.source),
        tostring(colors.scheme),
    }, "|")
end

local function persistRuntimeIfChanged(force)
    if not runtimeValid then
        return
    end
    local signature = currentProviderSignature()
    if not force and signature == providerSignature then
        return
    end
    providerSignature = signature
    runtime.providers = {
        wallhaven = {
            enabled = providers.wallhaven.plugin_enabled,
            version = providers.wallhaven.version,
        },
        w_engine = {
            enabled = providers.w_engine.plugin_enabled,
            version = providers.w_engine.version,
            renderer = providers.w_engine.renderer_available,
            adapter_version = providers.w_engine.adapter_version,
            adapter_capture = providers.w_engine.adapter_capture,
            adapter_status = providers.w_engine.adapter_status,
            current = providers.w_engine.current,
        },
        mpvpaper = {
            enabled = providers.mpvpaper.plugin_enabled,
            version = providers.mpvpaper.version,
            command_available = providers.mpvpaper.command_available,
        },
        extra = {
            panel = providers.extra.panel,
            enabled = providers.extra.plugin_enabled,
        },
        colors = { source = colors.source, scheme = colors.scheme },
    }
    runtime.observed_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    runtime.last_error = tostring(providers.probe_error or "")
    local saved, saveError = atomicWrite("runtime.json", runtime)
    if not saved then
        runtimeValid = false
        runtimeError = tostring(saveError or noctalia.tr("errors.runtime_save"))
    end
end

local function parseEnabledPlugins(output)
    local enabled = {}
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local id, source, version = line:match("^(%S+)%s+%[([^%]]+)%]%s+(%S+)")
        local framed = " " .. line .. " "
        if id ~= nil and framed:find(" enabled ", 1, true) ~= nil and framed:find(" incompatible ", 1, true) == nil then
            enabled[id] = { source = tostring(source or ""), version = tostring(version or "") }
        end
    end
    return enabled
end

local function refreshExtraProvider(enabled)
    local panelId, pluginId = normalizedExtraPanel()
    local entry = type(enabled) == "table" and enabled[pluginId] or nil
    providers.extra = {
        configured = panelId ~= "",
        plugin_enabled = entry ~= nil,
        available = panelId ~= "" and entry ~= nil,
        panel = panelId,
        plugin_id = pluginId,
        version = type(entry) == "table" and tostring(entry.version or "") or "",
    }
end

local function clearAdapterState()
    providers.w_engine.adapter_version = ""
    providers.w_engine.adapter_capture = false
    providers.w_engine.adapter_status = false
    providers.w_engine.adapter_seen_at = ""
    providers.w_engine.adapter_seen_ms = 0
    providers.w_engine.adapter_probe_ms = 0
    providers.w_engine.current = {}
end

local function requestAdapterProbe()
    if not providers.w_engine.plugin_enabled or not providers.noctalia_cli then
        return
    end
    local requestedAt = noctalia.nowMs()
    providers.w_engine.adapter_probe_ms = requestedAt
    local command = "noctalia msg plugin " .. W_ENGINE_SERVICE .. " all wall-in-one-probe-v1"
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            -- Existing W Engine versions do not implement the optional probe.
            -- Keep a spontaneous announcement valid instead of treating an
            -- unknown event as evidence that the adapter disappeared.
            if providers.w_engine.adapter_probe_ms == requestedAt then
                providers.w_engine.adapter_probe_ms = 0
            end
        end
    end, 5000)
    if not started and providers.w_engine.adapter_probe_ms == requestedAt then
        providers.w_engine.adapter_probe_ms = 0
    end
end

local function completeProviderProbe(enabled, probeError)
    providerProbeInFlight = false
    providers.probing = false
    providers.probe_ok = probeError == nil
    providers.probe_error = tostring(probeError or "")
    providers.probed_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    providers.noctalia_cli = noctalia.commandExists("noctalia")

    local pluginList = type(enabled) == "table" and enabled or {}
    local wallhaven = pluginList[WALLHAVEN_ID]
    local wEngine = pluginList[W_ENGINE_ID]
    local mpvpaper = pluginList[MPVPAPER_ID]
    providers.wallhaven = {
        plugin_enabled = wallhaven ~= nil,
        available = probeError == nil and wallhaven ~= nil,
        version = type(wallhaven) == "table" and tostring(wallhaven.version or "") or "",
    }
    local previousWEngineVersion = providers.w_engine.version
    providers.w_engine.plugin_enabled = wEngine ~= nil
    providers.w_engine.version = type(wEngine) == "table" and tostring(wEngine.version or "") or ""
    providers.w_engine.renderer_available = noctalia.commandExists("linux-wallpaperengine")
    providers.w_engine.available = probeError == nil and wEngine ~= nil
    if wEngine == nil or (previousWEngineVersion ~= "" and previousWEngineVersion ~= providers.w_engine.version) then
        clearAdapterState()
    end
    providers.mpvpaper = {
        plugin_enabled = mpvpaper ~= nil,
        available = probeError == nil and mpvpaper ~= nil,
        command_available = noctalia.commandExists("mpvpaper") and noctalia.commandExists("mpv"),
        version = type(mpvpaper) == "table" and tostring(mpvpaper.version or "") or "",
    }
    refreshExtraProvider(pluginList)
    persistRuntimeIfChanged(false)
    publishStatus()
    requestAdapterProbe()
end

local function probeColorScheme()
    if colorProbeInFlight or not noctalia.commandExists("noctalia") then
        return
    end
    colorProbeInFlight = true
    colors.probing = true
    local started = noctalia.runAsync("noctalia msg color-scheme-get", function(result)
        colorProbeInFlight = false
        colors.probing = false
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            colors.error = commandFailureDetail(result)
        else
            local source, scheme = noctalia.string.trim(result.stdout or ""):match("^(%S+)%s+(.+)$")
            colors.source = tostring(source or "")
            colors.scheme = tostring(scheme or "")
            colors.error = ""
        end
        persistRuntimeIfChanged(false)
        publishStatus()
    end, 5000)
    if not started then
        colorProbeInFlight = false
        colors.probing = false
        colors.error = noctalia.tr("errors.color_probe_start")
    end
end

local function probeProviders()
    if providerProbeInFlight then
        return
    end
    lastProviderProbeAt = nowSeconds()
    providerProbeInFlight = true
    providers.probing = true
    publishStatus()

    if not noctalia.commandExists("noctalia") then
        completeProviderProbe(nil, noctalia.tr("errors.noctalia_cli"))
        return
    end
    local started = noctalia.runAsync("noctalia msg plugins list", function(result)
        if type(result) ~= "table" then
            completeProviderProbe(nil, noctalia.tr("errors.provider_probe"))
        elseif result.timedOut then
            completeProviderProbe(nil, noctalia.tr("errors.provider_probe_timeout"))
        elseif tonumber(result.exitCode) ~= 0 then
            completeProviderProbe(
                nil,
                noctalia.tr("errors.provider_probe_detail", { detail = commandFailureDetail(result) })
            )
        else
            completeProviderProbe(parseEnabledPlugins(result.stdout), nil)
        end
        probeColorScheme()
    end, 5000)
    if not started then
        completeProviderProbe(nil, noctalia.tr("errors.provider_probe_start"))
    end
end

local function safeRelativePath(value)
    if type(value) ~= "string" or value == "" or value:sub(1, 1) == "/" or value:find("[%c]") then
        return nil
    end
    for segment in value:gmatch("[^/]+") do
        if segment == ".." then
            return nil
        end
    end
    return value
end

local function candidateWorkshopRoots()
    local roots = {}
    local seen = {}
    local custom = settingString("workshop_directory", "")
    if custom ~= "" then
        local expanded = noctalia.expandPath(custom)
        if expanded:sub(1, 1) == "/" and not expanded:find("[%c]") then
            expanded = expanded:gsub("/*$", "") .. "/"
            seen[expanded] = true
            table.insert(roots, expanded)
        end
    end
    for _, value in ipairs(WORKSHOP_PATHS) do
        local expanded = noctalia.expandPath(value):gsub("/*$", "") .. "/"
        if not seen[expanded] then
            seen[expanded] = true
            table.insert(roots, expanded)
        end
    end
    return roots
end

local function findWorkshopProject(id)
    if tostring(id):match("^%d+$") == nil then
        return nil, nil
    end
    for _, root in ipairs(candidateWorkshopRoots()) do
        local directory = root .. tostring(id) .. "/"
        local projectPath = directory .. "project.json"
        local projectInfo = noctalia.fileInfo(projectPath)
        if
            type(projectInfo) == "table"
            and projectInfo.isDir ~= true
            and tonumber(projectInfo.size) ~= nil
            and tonumber(projectInfo.size) > 0
            and tonumber(projectInfo.size) <= MAX_PROJECT_JSON_BYTES
        then
            local raw = noctalia.readFile(projectPath)
            if type(raw) == "string" then
                local decoded = noctalia.json.decode(raw)
                if type(decoded) == "table" then
                    return decoded, directory
                end
            end
        end
    end
    return nil, nil
end

local function captureHelper()
    local pluginDirectory = noctalia.pluginDir()
    if type(pluginDirectory) ~= "string" or pluginDirectory == "" then
        return nil
    end
    local path = pluginDirectory .. "/scripts/capture-still"
    return if noctalia.fileExists(path) then path else nil
end

local function sanitizedName(value)
    local cleaned = tostring(value or ""):gsub("[^%w._-]", "-"):gsub("%-+", "-")
    cleaned = cleaned:gsub("^%-", ""):gsub("%-$", "")
    if #cleaned > 64 then
        cleaned = cleaned:sub(1, 64)
    end
    return if cleaned == "" then "wallpaper" else cleaned
end

local function fileExtension(path)
    return tostring(path or ""):lower():match("(%.[%w]+)$") or ""
end

local function captureDestination(prefix, identity, output, extension)
    local directory = captureDirectory()
    if directory == "" then
        return nil, noctalia.tr("errors.capture_directory")
    end
    local ok, directoryError = noctalia.mkdirAll(directory)
    if ok ~= true then
        return nil, tostring(directoryError or noctalia.tr("errors.capture_directory"))
    end
    local separator = if directory == "/" then "" else "/"
    return directory
        .. separator
        .. "wall-in-one-"
        .. sanitizedName(prefix)
        .. "-"
        .. sanitizedName(identity)
        .. "-"
        .. sanitizedName(output or "all")
        .. extension,
        nil
end

local function adapterStagingPath(requestId)
    local dataDirectory, dataError = noctalia.pluginDataDir()
    if
        type(dataDirectory) ~= "string"
        or dataDirectory == ""
        or dataDirectory:sub(1, 1) ~= "/"
        or dataDirectory:find("[%c]")
    then
        return nil, tostring(dataError or noctalia.tr("errors.data_directory"))
    end
    local directory = dataDirectory:gsub("/+$", "") .. "/staging"
    local ok, directoryError = noctalia.mkdirAll(directory)
    if ok ~= true then
        return nil, tostring(directoryError or noctalia.tr("errors.capture_directory"))
    end
    return directory .. "/capture-" .. requestId .. ".png", nil
end

local function workshopFallbackSpec(id)
    local info, directory = findWorkshopProject(id)
    local kind = string.lower(tostring(type(info) == "table" and info.type or ""))
    local file = safeRelativePath(type(info) == "table" and info.file or nil)
    if kind == "video" and file ~= nil and noctalia.commandExists("ffmpeg") then
        local source = directory .. file
        if noctalia.fileExists(source) then
            return {
                mode = "video",
                source = source,
                extension = ".png",
                value = settingInt("video_frame_second", 1, 0, 3600),
                method = "ffmpeg-video-frame",
            }
        end
    end

    local preview = safeRelativePath(type(info) == "table" and info.preview or "preview.jpg")
    if directory ~= nil and preview ~= nil then
        local source = directory .. preview
        local extension = fileExtension(source)
        if noctalia.fileExists(source) then
            if extension == ".jpg" or extension == ".jpeg" or extension == ".png" or extension == ".webp" then
                return { mode = "copy", source = source, extension = extension, value = "", method = "workshop-preview" }
            elseif noctalia.commandExists("ffmpeg") then
                return { mode = "image", source = source, extension = ".png", value = "", method = "preview-frame" }
            end
        end
    end
    return nil, noctalia.tr("errors.capture_source", { id = tostring(id) })
end

local function videoCaptureSpec()
    local source = configuredVideoSource()
    local info = source ~= "" and noctalia.fileInfo(source) or nil
    if source == "" or type(info) ~= "table" or info.isDir == true then
        return nil, noctalia.tr("errors.video_source")
    end
    if not noctalia.commandExists("ffmpeg") then
        return nil, noctalia.tr("errors.ffmpeg")
    end
    return {
        mode = "video",
        source = source,
        extension = ".png",
        value = settingInt("video_frame_second", 1, 0, 3600),
        method = "ffmpeg-video-frame",
    }
end

local function applyPairedStill(output, dynamicId, path, method, notifySuccess)
    if output ~= nil then
        noctalia.setWallpaper(output, path)
    else
        noctalia.setWallpaper(path)
    end

    local syncColors = settingBool("sync_colors", false)
    local key = output or "all"
    local provider = "w_engine"
    if tostring(dynamicId):match("^video:") then
        provider = "video"
    elseif tostring(dynamicId):match("^manual:") then
        provider = "manual"
    end
    runtime.pairs[key] = {
        provider = provider,
        dynamic_id = dynamicId,
        still_path = path,
        capture_method = method,
        paired_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        color_source_before = colors.source,
        color_scheme_before = colors.scheme,
        color_scheme = if syncColors then configuredColorScheme() else "unchanged",
    }

    local paletteLeader = knownOutputName(settingString("palette_output", ""))
    if syncColors and paletteLeader ~= nil and paletteLeader ~= output then
        local leaderPair = runtime.pairs[paletteLeader]
        if
            type(leaderPair) == "table"
            and type(leaderPair.still_path) == "string"
            and noctalia.fileExists(leaderPair.still_path)
        then
            -- Noctalia has one global palette. Re-applying the chosen leader
            -- last makes that output's persisted still the deterministic source.
            noctalia.setWallpaper(paletteLeader, leaderPair.still_path)
        end
    end

    lastActionAt = runtime.pairs[key].paired_at
    lastActionError = ""
    persistRuntimeIfChanged(true)
    publishStatus()

    local function finishColorSync(colorError)
        if colorError ~= nil and colorError ~= "" then
            lastActionError = colorError
            notifyBounded("color-sync", colorError)
        else
            lastActionError = ""
        end
        publishStatus()
        if notifySuccess then
            noctalia.notify(noctalia.tr("plugin.title"), noctalia.tr("notifications.paired", { path = path }))
        end
    end

    -- Pairing itself never changes the theme source unless this explicit
    -- opt-in is enabled. If the user's existing source is already `wallpaper`,
    -- Noctalia may naturally regenerate its global palette from the new still.
    if not syncColors then
        finishColorSync(nil)
        return
    end
    if not noctalia.commandExists("noctalia") then
        finishColorSync(noctalia.tr("errors.color_cli"))
        return
    end
    local scheme = configuredColorScheme()
    local started = noctalia.runAsync("noctalia msg color-scheme-set wallpaper " .. shellQuote(scheme), function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            finishColorSync(noctalia.tr("errors.color_sync", { detail = commandFailureDetail(result) }))
        else
            colors.source = "wallpaper"
            colors.scheme = scheme
            colors.error = ""
            finishColorSync(nil)
        end
    end, 5000)
    if not started then
        finishColorSync(noctalia.tr("errors.color_sync_start"))
    end
end

local function releaseCaptureSlot(key)
    captureInFlight[key] = nil
    pendingAdapterCaptures[key] = nil
end

local function finishCapture(key, request, ok, errorMessage)
    releaseCaptureSlot(key)
    if
        type(request.staging_path) == "string"
        and request.staging_path ~= ""
        and noctalia.fileExists(request.staging_path)
    then
        noctalia.removeFile(request.staging_path)
    end
    if ok then
        local finalPath = tostring(request.pair_path or request.destination)
        runtime.last_capture = {
            provider = request.provider,
            dynamic_id = request.dynamic_id,
            output = request.output or "all",
            path = finalPath,
            method = request.spec.method,
            captured_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        }
        lastActionError = ""
        lastActionAt = runtime.last_capture.captured_at
        persistRuntimeIfChanged(true)
        if request.pair then
            applyPairedStill(request.output, request.dynamic_id, finalPath, request.spec.method, request.notify)
        elseif request.notify then
            noctalia.notify(noctalia.tr("plugin.title"), noctalia.tr("notifications.captured", { path = finalPath }))
        end
    else
        setActionError(tostring(errorMessage or noctalia.tr("errors.capture_failed")), "capture")
    end
    publishStatus()

    local queued = captureQueued[key]
    captureQueued[key] = nil
    if type(queued) == "table" then
        runCapture(queued)
    end
end

runCapture = function(request)
    local key = request.output or "all"
    if captureInFlight[key] ~= nil then
        local replaced = captureQueued[key]
        if
            type(replaced) == "table"
            and type(replaced.staging_path) == "string"
            and replaced.staging_path ~= ""
            and noctalia.fileExists(replaced.staging_path)
        then
            noctalia.removeFile(replaced.staging_path)
        end
        captureQueued[key] = request
        return
    end
    if not request.force and noctalia.fileExists(request.destination) then
        finishCapture(key, request, true, nil)
        return
    end
    local helper = captureHelper()
    if helper == nil then
        finishCapture(key, request, false, noctalia.tr("errors.capture_helper"))
        return
    end

    captureSequence += 1
    captureInFlight[key] = {
        sequence = captureSequence,
        provider = request.provider,
        dynamic_id = request.dynamic_id,
        output = request.output or "all",
        destination = request.destination,
        method = request.spec.method,
    }
    publishStatus()
    local command = table.concat({
        "bash",
        shellQuote(helper),
        shellQuote(request.spec.mode),
        shellQuote(request.spec.source),
        shellQuote(request.destination),
        shellQuote(tostring(request.spec.value or "")),
    }, " ")
    local started = noctalia.runAsync(command, function(result)
        local outputInfo = noctalia.fileInfo(request.destination)
        local ok = type(result) == "table"
            and not result.timedOut
            and tonumber(result.exitCode) == 0
            and type(outputInfo) == "table"
            and outputInfo.isDir ~= true
            and (tonumber(outputInfo.size) or 0) > 0
        if ok then
            finishCapture(key, request, true, nil)
        else
            finishCapture(
                key,
                request,
                false,
                noctalia.tr("errors.capture_failed_detail", { detail = commandFailureDetail(result) })
            )
        end
    end, 60000)
    if not started then
        finishCapture(key, request, false, noctalia.tr("errors.capture_start"))
    end
end

local function captureWorkshopFallback(output, id, force, pair, notifySuccess)
    output = targetOutput(output)
    id = tostring(id or "")
    if id:match("^%d+$") == nil then
        setActionError(noctalia.tr("errors.no_current_scene"), "capture-current")
        return
    end
    local spec, specError = workshopFallbackSpec(id)
    if spec == nil then
        setActionError(specError, "capture-source")
        return
    end
    local destination, destinationError = captureDestination("w-engine", id, output, spec.extension)
    if destination == nil then
        setActionError(destinationError, "capture-directory")
        return
    end
    runCapture({
        provider = "w_engine",
        output = output,
        dynamic_id = id,
        spec = spec,
        destination = destination,
        force = force == true,
        pair = pair == true,
        notify = notifySuccess == true,
    })
end

local function requestRenderedCapture(output, id, pair, notifySuccess)
    output = targetOutput(output)
    id = tostring(id or "")
    if output == nil or id:match("^%d+$") == nil then
        setActionError(noctalia.tr("errors.no_current_scene"), "capture-current")
        return
    end
    if not providers.w_engine.adapter_capture or not noctalia.commandExists("ffmpeg") then
        captureWorkshopFallback(output, id, true, pair, notifySuccess)
        return
    end

    local key = output
    if captureInFlight[key] ~= nil then
        setActionError(noctalia.tr("errors.capture_busy"), "capture-current")
        return
    end
    local destination, destinationError = captureDestination("w-engine", id, output, ".png")
    if destination == nil then
        setActionError(destinationError, "capture-directory")
        return
    end
    if destination:find("[%c]") ~= nil then
        setActionError(noctalia.tr("errors.capture_directory"), "capture-directory")
        return
    end

    captureSequence += 1
    local requestId = SERVICE_NONCE .. "-" .. tostring(noctalia.nowMs()) .. "-" .. tostring(captureSequence)
    local stagingPath, stagingError = adapterStagingPath(requestId)
    if stagingPath == nil then
        setActionError(stagingError, "capture-directory")
        return
    end
    local delay = settingInt("scene_screenshot_delay", 15, 1, 120)
    local request = {
        provider = "w_engine",
        output = output,
        dynamic_id = id,
        spec = { method = "w-engine-adapter-v1" },
        destination = destination,
        force = true,
        pair = pair == true,
        notify = notifySuccess == true,
        request_id = requestId,
        staging_path = stagingPath,
    }
    pendingAdapterCaptures[key] = request
    captureInFlight[key] = {
        sequence = captureSequence,
        provider = "w_engine",
        dynamic_id = id,
        output = output,
        destination = destination,
        method = "w-engine-adapter-v1",
        request_id = requestId,
        deadline = nowSeconds() + math.max(60, delay + 60),
    }
    publishStatus()

    local payload = table.concat({
        requestId,
        output,
        id,
        stagingPath,
        tostring(delay),
    }, "\t")
    local command = "noctalia msg plugin " .. W_ENGINE_SERVICE .. " all capture-v1 " .. shellQuote(payload)
    local started = noctalia.runAsync(command, function(result)
        if
            pendingAdapterCaptures[key] == request
            and (type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0)
        then
            finishCapture(
                key,
                request,
                false,
                noctalia.tr("errors.w_engine_adapter", { detail = commandFailureDetail(result) })
            )
        end
    end, 5000)
    if not started then
        finishCapture(key, request, false, noctalia.tr("errors.w_engine_adapter_start"))
    end
end

local function captureCurrent(output, force, pair, notifySuccess)
    output = targetOutput(output)
    local id = output ~= nil and providers.w_engine.current[output] or nil
    if id == nil or tostring(id) == "" then
        id = configuredWorkshopId()
    end
    if id == nil or tostring(id) == "" then
        setActionError(noctalia.tr("errors.no_current_scene"), "capture-current")
        return
    end
    if providers.w_engine.adapter_capture and output ~= nil and providers.w_engine.current[output] == id then
        requestRenderedCapture(output, id, pair, notifySuccess)
    else
        captureWorkshopFallback(output, id, force, pair, notifySuccess)
    end
end

local function captureConfiguredVideo(output, force, pair, notifySuccess)
    output = targetOutput(output)
    local spec, specError = videoCaptureSpec()
    if spec == nil then
        setActionError(specError, "video-capture")
        return
    end
    local sourceInfo = noctalia.fileInfo(spec.source)
    local identity = table.concat({
        tostring(type(sourceInfo) == "table" and sourceInfo.size or 0),
        tostring(type(sourceInfo) == "table" and sourceInfo.mtime or 0),
        sanitizedName(spec.source:match("([^/]+)$") or "video"),
    }, "-")
    local destination, destinationError = captureDestination("video", identity, output, spec.extension)
    if destination == nil then
        setActionError(destinationError, "capture-directory")
        return
    end
    runCapture({
        provider = "video",
        output = output,
        dynamic_id = "video:" .. spec.source,
        spec = spec,
        destination = destination,
        force = force == true,
        pair = pair == true,
        notify = notifySuccess == true,
    })
end

local function pairConfiguredStill(output, notifySuccess)
    output = targetOutput(output)
    local source = configuredManualPair()
    local info = source ~= "" and noctalia.fileInfo(source) or nil
    local extension = fileExtension(source)
    local supported = extension == ".png"
        or extension == ".jpg"
        or extension == ".jpeg"
        or extension == ".webp"
        or extension == ".avif"
        or extension == ".gif"
    if
        source == ""
        or type(info) ~= "table"
        or info.isDir == true
        or (tonumber(info.size) or 0) <= 0
        or not supported
        or (extension == ".gif" and not noctalia.commandExists("ffmpeg"))
    then
        setActionError(noctalia.tr("errors.manual_pair"), "manual-pair")
        return
    end
    captureSequence += 1
    local validationPath, validationError = adapterStagingPath(
        "manual-" .. SERVICE_NONCE .. "-" .. tostring(noctalia.nowMs()) .. "-" .. tostring(captureSequence)
    )
    if validationPath == nil then
        setActionError(validationError, "capture-directory")
        return
    end
    runCapture({
        provider = "manual",
        output = output,
        dynamic_id = "manual:" .. source,
        spec = {
            mode = if extension == ".gif" then "image" else "copy",
            source = source,
            value = "",
            method = "manual-file",
        },
        destination = validationPath,
        staging_path = validationPath,
        pair_path = source,
        force = true,
        pair = true,
        notify = notifySuccess == true,
    })
end

local function actionAvailability(action, output)
    if action == "native_open" or action == "hub_open" or action == "no_action" then
        return true, ""
    end
    if NATIVE_SWITCH_VERBS[action] ~= nil then
        return providers.noctalia_cli, noctalia.tr("availability.native_cli")
    end
    if action == "wallhaven_open" then
        return providers.wallhaven.available, noctalia.tr("availability.wallhaven")
    end
    if action == "w_engine_open" then
        return providers.w_engine.available, noctalia.tr("availability.w_engine")
    end
    if W_ENGINE_VERBS[action] ~= nil then
        return providers.w_engine.plugin_enabled and providers.noctalia_cli, noctalia.tr("availability.w_engine_ipc")
    end
    if action == "mpvpaper_open" then
        return providers.mpvpaper.available, noctalia.tr("availability.mpvpaper")
    end
    if MPVPAPER_VERBS[action] ~= nil then
        if action == "mpvpaper_clear" and targetOutput(output) == nil then
            return false, noctalia.tr("availability.output")
        end
        return providers.mpvpaper.plugin_enabled and providers.noctalia_cli, noctalia.tr("availability.mpvpaper_ipc")
    end
    if action == "capture_current" or action == "capture_pair" then
        local selected = targetOutput(output)
        local id = selected ~= nil and providers.w_engine.current[selected] or nil
        if id == nil or tostring(id) == "" then
            id = configuredWorkshopId()
        end
        return id ~= nil and tostring(id):match("^%d+$") ~= nil, noctalia.tr("availability.current_scene")
    end
    if action == "video_capture" or action == "video_capture_pair" then
        local source = configuredVideoSource()
        return source ~= "" and noctalia.fileExists(source) and noctalia.commandExists("ffmpeg"),
            noctalia.tr("availability.video")
    end
    if action == "manual_pair" then
        local source = configuredManualPair()
        local info = source ~= "" and noctalia.fileInfo(source) or nil
        local extension = fileExtension(source)
        local supported = extension == ".png"
            or extension == ".jpg"
            or extension == ".jpeg"
            or extension == ".webp"
            or extension == ".avif"
            or (extension == ".gif" and noctalia.commandExists("ffmpeg"))
        return type(info) == "table" and info.isDir ~= true and (tonumber(info.size) or 0) > 0 and supported,
            noctalia.tr("availability.manual_pair")
    end
    if action == "extra_provider_open" then
        return providers.extra.available, noctalia.tr("availability.extra")
    end
    return false, noctalia.tr("availability.unknown")
end

local function runNativeSwitch(request, action)
    local command = "noctalia msg " .. NATIVE_SWITCH_VERBS[action]
    local output = targetOutput(request.output)
    if output ~= nil then
        command ..= " " .. shellQuote(output)
    end
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            setActionError(noctalia.tr("errors.native_switch", { detail = commandFailureDetail(result) }), action)
        else
            lastActionError = ""
            lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            publishStatus()
        end
    end, 5000)
    if not started then
        setActionError(noctalia.tr("errors.native_switch_start"), action)
    end
end

local function runWEngineControl(request, action)
    local output = targetOutput(request.output)
    local command = "noctalia msg plugin " .. W_ENGINE_SERVICE .. " all " .. W_ENGINE_VERBS[action]
    if output ~= nil then
        command ..= " " .. shellQuote(output)
    end
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            setActionError(noctalia.tr("errors.w_engine_ipc", { detail = commandFailureDetail(result) }), action)
        else
            lastActionError = ""
            lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            publishStatus()
        end
    end, 5000)
    if not started then
        setActionError(noctalia.tr("errors.w_engine_ipc_start"), action)
    end
end

local function runMpvpaperControl(request, action)
    local output = targetOutput(request.output)
    local command = "noctalia msg plugin " .. MPVPAPER_SERVICE .. " all " .. MPVPAPER_VERBS[action]
    if action ~= "mpvpaper_clear_all" and output ~= nil then
        command ..= " " .. shellQuote(output)
    end
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            setActionError(noctalia.tr("errors.mpvpaper_ipc", { detail = commandFailureDetail(result) }), action)
        else
            lastActionError = ""
            lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            publishStatus()
        end
    end, 5000)
    if not started then
        setActionError(noctalia.tr("errors.mpvpaper_ipc_start"), action)
    end
end

local function actionPanelTarget(action)
    if action == "extra_provider_open" then
        return providers.extra.panel
    end
    return OPEN_TARGETS[action]
end

local function dispatchAction(request, action)
    if not configValid or not runtimeValid then
        notifyBounded("storage", noctalia.tr("errors.storage_disabled"))
        return
    end
    if not VALID_ACTIONS[action] then
        notifyBounded("unknown", noctalia.tr("availability.unknown"))
        return
    end
    local available, unavailableReason = actionAvailability(action, request.output)
    if not available then
        local message = noctalia.tr("errors.action_unavailable", { action = action, reason = unavailableReason })
        setActionError(message, action)
        return
    end
    if action == "no_action" then
        return
    elseif NATIVE_SWITCH_VERBS[action] ~= nil then
        runNativeSwitch(request, action)
        return
    elseif W_ENGINE_VERBS[action] ~= nil then
        runWEngineControl(request, action)
        return
    elseif MPVPAPER_VERBS[action] ~= nil then
        runMpvpaperControl(request, action)
        return
    elseif action == "capture_current" then
        captureCurrent(request.output, true, false, true)
        return
    elseif action == "capture_pair" then
        captureCurrent(request.output, true, true, true)
        return
    elseif action == "video_capture" then
        captureConfiguredVideo(request.output, true, false, true)
        return
    elseif action == "video_capture_pair" then
        captureConfiguredVideo(request.output, true, true, true)
        return
    elseif action == "manual_pair" then
        pairConfiguredStill(request.output, true)
        return
    end

    lastActionError = ""
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishStatus()
    if tostring(request.producer or "") == "ipc" then
        local target = actionPanelTarget(action)
        if type(target) == "string" and target ~= "" then
            noctalia.togglePanel(target)
        end
    end
end

local function setMapping(button, action)
    if not configValid or not runtimeValid then
        notifyBounded("storage", noctalia.tr("errors.storage_disabled"))
        return
    end
    if button ~= "left" and button ~= "middle" and button ~= "right" then
        return
    end
    if not VALID_ACTIONS[action] then
        notifyBounded("unknown", noctalia.tr("availability.unknown"))
        return
    end
    local nextConfig = { schema_version = CONFIG_SCHEMA, gestures = cloneGestures(config.gestures) }
    nextConfig.gestures[button] = action
    local saved, saveError = atomicWrite("config.json", nextConfig)
    if not saved then
        configError = tostring(saveError or noctalia.tr("errors.config_save"))
        configValid = false
        notifyBounded("config-save", noctalia.tr("errors.config_save"))
        publishStatus()
        return
    end
    config = nextConfig
    configError = ""
    publishStatus()
end

local function tabFields(payload)
    local fields = {}
    for value in (tostring(payload or "") .. "\t"):gmatch("([^\t]*)\t") do
        table.insert(fields, value)
    end
    return fields
end

local function receiveProviderCapabilities(payload)
    local fields = tabFields(payload)
    if fields[1] ~= "w_engine" or fields[2] ~= "1" or not providers.w_engine.plugin_enabled then
        return
    end
    local capabilities = "," .. tostring(fields[3] or "") .. ","
    providers.w_engine.adapter_version = "1"
    providers.w_engine.adapter_capture = capabilities:find(",capture,", 1, true) ~= nil
    providers.w_engine.adapter_status = capabilities:find(",status,", 1, true) ~= nil
    providers.w_engine.adapter_seen_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    providers.w_engine.adapter_seen_ms = noctalia.nowMs()
    providers.w_engine.adapter_probe_ms = 0
    persistRuntimeIfChanged(true)
    publishStatus()
end

local function receiveProviderCurrent(payload)
    local fields = tabFields(payload)
    if fields[1] ~= "w_engine" or not providers.w_engine.plugin_enabled or not providers.w_engine.adapter_status then
        return
    end
    local output = knownOutputName(fields[2])
    local id = tostring(fields[3] or "")
    if output == nil then
        return
    end
    if id == "" or id == "-" then
        providers.w_engine.current[output] = nil
    elseif id:match("^%d+$") ~= nil then
        local changed = tostring(providers.w_engine.current[output] or "") ~= id
        providers.w_engine.current[output] = id
        if changed and settingBool("auto_capture", false) then
            requestRenderedCapture(output, id, settingBool("pair_static", true), false)
        end
    else
        return
    end
    providers.w_engine.adapter_seen_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    providers.w_engine.adapter_seen_ms = noctalia.nowMs()
    providers.w_engine.adapter_probe_ms = 0
    persistRuntimeIfChanged(true)
    publishStatus()
end

local function receiveCaptureResult(payload)
    local fields = tabFields(payload)
    local requestId = tostring(fields[1] or "")
    local resultStatus = tostring(fields[2] or "")
    local value = tostring(fields[3] or "")
    local key = nil
    local request = nil
    for candidateKey, candidate in pairs(pendingAdapterCaptures) do
        if tostring(candidate.request_id or "") == requestId then
            key = candidateKey
            request = candidate
            break
        end
    end
    if key == nil or type(request) ~= "table" then
        return
    end
    if resultStatus ~= "ok" then
        finishCapture(key, request, false, noctalia.tr("errors.w_engine_adapter", { detail = boundedDetail(value) }))
        return
    end
    local stagedInfo = value ~= "" and value == request.staging_path and noctalia.fileInfo(value) or nil
    if type(stagedInfo) ~= "table" or stagedInfo.isDir == true or (tonumber(stagedInfo.size) or 0) <= 0 then
        finishCapture(key, request, false, noctalia.tr("errors.capture_failed"))
        return
    end
    -- The adapter owns only this request-specific plugin-data staging path.
    -- The helper decodes it, then atomically promotes it to the known-good
    -- destination without ever exposing a partial image in the wallpaper tree.
    releaseCaptureSlot(key)
    request.spec = { mode = "copy", source = value, value = "", method = "w-engine-adapter-v1" }
    runCapture(request)
end

local function handleCommand(request)
    if type(request) ~= "table" then
        return
    end
    local sequence = tonumber(request.sequence) or 0
    if sequence <= lastCommandSequence then
        return
    end
    lastCommandSequence = sequence
    noctalia.state.set(COMMAND_ACK_KEY, { sequence = sequence })

    local kind = tostring(request.kind or "")
    if kind == "gesture" then
        local gestures = type(config.gestures) == "table" and config.gestures or {}
        dispatchAction(request, tostring(gestures[tostring(request.button or "")] or ""))
    elseif kind == "action" then
        dispatchAction(request, tostring(request.action or ""))
    elseif kind == "set_mapping" then
        setMapping(tostring(request.button or ""), tostring(request.action or ""))
    elseif kind == "probe" then
        probeProviders()
    end
end

function update()
    noctalia.setUpdateInterval(UPDATE_INTERVAL_MS)
    local now = nowSeconds()
    if lastProviderProbeAt == 0 or now == 0 or now - lastProviderProbeAt >= PROVIDER_PROBE_SECONDS then
        probeProviders()
    end
    for key, capture in pairs(captureInFlight) do
        local deadline = tonumber(capture.deadline) or 0
        if deadline > 0 and now > deadline then
            local request = pendingAdapterCaptures[key]
            if type(request) == "table" then
                finishCapture(key, request, false, noctalia.tr("errors.w_engine_adapter_timeout"))
            end
        end
    end
    local adapterProbeMs = tonumber(providers.w_engine.adapter_probe_ms) or 0
    if
        adapterProbeMs > 0
        and noctalia.nowMs() - adapterProbeMs >= ADAPTER_PROBE_GRACE_MS
        and (tonumber(providers.w_engine.adapter_seen_ms) or 0) < adapterProbeMs
    then
        clearAdapterState()
        persistRuntimeIfChanged(true)
        publishStatus()
    end
end

function onConfigChanged()
    refreshExtraProvider({})
    providerSignature = ""
    probeProviders()
    probeColorScheme()
    publishStatus()
end

function onIpc(event, payload)
    local output = targetOutput(nil)
    if event == "status" or event == "probe" then
        probeProviders()
    elseif event == "provider-capabilities-v1" then
        receiveProviderCapabilities(payload)
    elseif event == "provider-current-v1" then
        receiveProviderCurrent(payload)
    elseif event == "capture-result-v1" then
        receiveCaptureResult(payload)
    elseif event == "gesture" then
        local gestures = type(config.gestures) == "table" and config.gestures or {}
        dispatchAction(
            { sequence = nowSeconds(), producer = "ipc", output = output },
            tostring(gestures[tostring(payload or "")] or "")
        )
    elseif event == "next" or event == "previous" or event == "random" then
        dispatchAction({ producer = "ipc", output = output }, "native_" .. event)
    elseif event == "capture" then
        captureCurrent(output, true, false, true)
    elseif event == "capture-pair" then
        captureCurrent(output, true, true, true)
    elseif event == "capture-video" then
        captureConfiguredVideo(output, true, false, true)
    elseif event == "capture-video-pair" then
        captureConfiguredVideo(output, true, true, true)
    elseif event == "pair-manual" then
        pairConfiguredStill(output, true)
    elseif event == "capture-id" or event == "capture-id-pair" then
        local id, requestedOutput = tostring(payload or ""):match("^%s*(%d+)%s*(%S*)%s*$")
        captureWorkshopFallback(
            if requestedOutput ~= nil and requestedOutput ~= "" then requestedOutput else output,
            id,
            true,
            event == "capture-id-pair",
            true
        )
    elseif event == "w-engine-next" then
        dispatchAction({ producer = "ipc", output = output }, "w_engine_next")
    elseif event == "w-engine-cycle-stop" or event == "w-engine-pause" then
        dispatchAction({ producer = "ipc", output = output }, "w_engine_cycle_stop")
    elseif event == "w-engine-stop" then
        dispatchAction({ producer = "ipc", output = output }, "w_engine_stop")
    elseif event == "mpvpaper-pause" then
        dispatchAction({ producer = "ipc", output = output }, "mpvpaper_pause")
    elseif event == "mpvpaper-resume" then
        dispatchAction({ producer = "ipc", output = output }, "mpvpaper_resume")
    elseif event == "mpvpaper-toggle" then
        dispatchAction({ producer = "ipc", output = output }, "mpvpaper_toggle")
    elseif event == "mpvpaper-clear" then
        dispatchAction({ producer = "ipc", output = output }, "mpvpaper_clear")
    elseif event == "mpvpaper-clear-all" then
        dispatchAction({ producer = "ipc", output = output }, "mpvpaper_clear_all")
    elseif event == "open-provider" then
        local aliases = {
            native = "native_open",
            wallhaven = "wallhaven_open",
            w_engine = "w_engine_open",
            mpvpaper = "mpvpaper_open",
            extra = "extra_provider_open",
            hub = "hub_open",
        }
        dispatchAction({ producer = "ipc", output = output }, aliases[tostring(payload or "")] or "")
    else
        noctalia.log("wall-in-one: unknown IPC event '" .. tostring(event) .. "'")
    end
end

loadStorage()
local previousAck = noctalia.state.get(COMMAND_ACK_KEY)
if type(previousAck) == "table" then
    lastCommandSequence = tonumber(previousAck.sequence) or 0
end
noctalia.state.watch(COMMAND_KEY, handleCommand)
handleCommand(noctalia.state.get(COMMAND_KEY))
publishStatus()
probeProviders()

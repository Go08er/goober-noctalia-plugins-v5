--!nonstrict
-- Wall-in-One coordinator service.
--
-- External provider processes remain provider-owned. Wall-in-One may also own
-- an explicitly selected internal renderer through renderer.luau. The
-- coordinator keeps Noctalia's static wallpaper surface enabled, pairs every
-- live item with a real still, and owns the one mixed static/live schedule.

local CONFIG_SCHEMA = 2
local RUNTIME_SCHEMA = 3
local UPDATE_INTERVAL_MS = 2000
local PROVIDER_PROBE_SECONDS = 30
local NOTIFY_COOLDOWN_SECONDS = 10
local ADAPTER_PROBE_GRACE_MS = 10000
local MAX_PROJECT_JSON_BYTES = 256 * 1024
local MAX_STORAGE_BYTES = 8 * 1024 * 1024
local MAX_REEL_ENTRIES = 512
local MAX_LIBRARY_CANDIDATES = 1024
local LIBRARY_SCAN_BATCH = 4
local MAX_RUNTIME_OUTPUTS = 64
local MAX_PAIR_REGISTRY_ENTRIES = 1024
local MAX_PERSISTED_PATH_BYTES = 4096
local MIN_CYCLE_SECONDS = 60
local MAX_CYCLE_SECONDS = 30 * 24 * 60 * 60

local SERVICE_NONCE = (tostring(noctalia.nowMs()) .. "-" .. tostring({})):gsub("[^%w%-]", "")

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"
local COMMAND_ACK_KEY = "wall_in_one_command_ack"
local RENDERER_COMMAND_KEY = "wall_in_one_renderer_command_v1"
local RENDERER_STATUS_KEY = "wall_in_one_renderer_status_v1"
local MOTIONBGS_COMMAND_KEY = "wall_in_one_motionbgs_command_v1"
local MOTIONBGS_STATUS_KEY = "wall_in_one_motionbgs_status_v1"
local MOTIONBGS_RESULTS_KEY = "wall_in_one_motionbgs_results_v1"
local MOTIONBGS_URL = "https://motionbgs.com/"

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

local VALID_BACKENDS = {
    auto = true,
    external = true,
    internal = true,
}

local VALID_CYCLE_ORDERS = {
    sequential = true,
    shuffle = true,
    random = true,
}

local VALID_ENTRY_KINDS = {
    static = true,
    video = true,
    workshop = true,
}

local VALID_ACTIONS = {
    native_open = true,
    native_next = true,
    native_previous = true,
    native_random = true,
    wallhaven_open = true,
    motionbgs_open = true,
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
    capture_backing = true,
    capture_current = true,
    capture_pair = true,
    video_capture = true,
    video_capture_pair = true,
    video_apply_pair = true,
    workshop_apply_pair = true,
    cycle_start = true,
    cycle_stop = true,
    cycle_pause = true,
    cycle_resume = true,
    cycle_next = true,
    cycle_previous = true,
    cycle_random = true,
    cycle_add_static = true,
    cycle_add_video = true,
    cycle_add_workshop = true,
    cycle_remove_last = true,
    cycle_clear = true,
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
    reels = {},
}

local runtime = {
    schema_version = RUNTIME_SCHEMA,
    providers = {},
    pairs = {},
    pair_registry = {},
    cycles = {},
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
    wallhaven = { allowed = true, plugin_enabled = false, available = false, version = "" },
    w_engine = {
        allowed = true,
        plugin_enabled = false,
        renderer_available = noctalia.commandExists("linux-wallpaperengine"),
        internal_available = false,
        effective_backend = "none",
        apply_available = false,
        conflict = false,
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
        allowed = true,
        plugin_enabled = false,
        command_available = noctalia.commandExists("mpvpaper") and noctalia.commandExists("mpv"),
        internal_available = false,
        effective_backend = "none",
        apply_available = false,
        conflict = false,
        available = false,
        version = "",
    },
    motionbgs = {
        allowed = true,
        available = noctalia.commandExists("xdg-open"),
        browser_available = noctalia.commandExists("xdg-open"),
        integration_available = false,
        url = MOTIONBGS_URL,
    },
    daemons = {
        awww = noctalia.commandExists("awww"),
        swww = noctalia.commandExists("swww"),
        wpaperd = noctalia.commandExists("wpaperctl"),
        hyprpaper = noctalia.commandExists("hyprctl"),
    },
    extra = {
        allowed = true,
        configured = false,
        plugin_enabled = false,
        available = false,
        panel = "",
        plugin_id = "",
    },
}

local colors = {
    probing = false,
    source = "",
    scheme = "",
    error = "",
}

local library = {
    videos = {},
    workshops = {},
    scanned_at = "",
    error = "",
    scanning = false,
}
local libraryScan = nil

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
local activeCaptureRequests = {}
local captureQueued = {}
local adapterCaptureQueued = {}
local captureSequence = 0
local pendingAdapterCaptures = {}
local rendererStatus = { ready = false, outputs = {}, last_error = "" }
local motionBgsStatus = { available = false, busy = false, last_error = "" }
local motionBgsResults = { items = {}, selected = {} }
local rendererCommandSequence = 0
local motionBgsCommandSequence = 0
local cycleApplying = {}
local cycleGeneration = {}
local applyGeneration = {}
local rendererPending = {}
local rendererStopping = {}
local lastMotionDownloadPath = ""
local backendGeneration = { w_engine = 0, mpvpaper = 0 }
local backendPolicySignature = { w_engine = "", mpvpaper = "" }

local runCapture
local requestRenderedCapture
local refreshLibrary
local reconcileRendererOwnership
local invalidateCycleIntent

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
    if candidate ~= nil and tostring(candidate) ~= "" then
        return knownOutputName(candidate)
    end
    return knownOutputName(noctalia.focusedOutputName())
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

local function configuredBackend(key)
    local value = settingString(key, "auto")
    return if VALID_BACKENDS[value] then value else "auto"
end

local function configuredCycleOrder()
    local value = settingString("cycle_order", "sequential")
    return if VALID_CYCLE_ORDERS[value] then value else "sequential"
end

local function configuredCycleSeconds()
    return settingInt("cycle_interval_minutes", 15, 1, 43200) * 60
end

local function normalizedDirectory(value)
    if
        type(value) ~= "string"
        or value == ""
        or value == "/"
        or value:sub(1, 1) ~= "/"
        or value:find("[%c]")
        or value:find("/%./")
        or value:match("/%.$")
        or value:find("/%.%./")
        or value:match("/%.%.$")
    then
        return nil
    end
    return value:gsub("/+$", "")
end

local function captureDirectory()
    local configured = settingString("capture_directory", "")
    local directory = ""
    if configured == "" then
        local wallpaperDirectory = normalizedDirectory(noctalia.wallpaperDirectory())
        if wallpaperDirectory ~= nil then
            directory = wallpaperDirectory
        else
            local dataDirectory = noctalia.pluginDataDir()
            if type(dataDirectory) == "string" and dataDirectory ~= "" then
                directory = dataDirectory .. "/captures"
            end
        end
    else
        directory = noctalia.expandPath(configured)
    end

    return normalizedDirectory(directory) or ""
end

local function videoDirectory()
    local configured = settingString("video_directory", "")
    local directory = if configured == "" then captureDirectory() else noctalia.expandPath(configured)
    return normalizedDirectory(directory) or ""
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
        use_wallhaven = settingBool("use_wallhaven", true),
        use_w_engine = settingBool("use_w_engine", true),
        use_mpvpaper = settingBool("use_mpvpaper", true),
        use_motionbgs = settingBool("use_motionbgs", true),
        use_extra_provider = settingBool("use_extra_provider", true),
        w_engine_backend = configuredBackend("w_engine_backend"),
        mpvpaper_backend = configuredBackend("mpvpaper_backend"),
        capture_directory = captureDirectory(),
        video_directory = videoDirectory(),
        motionbgs_download_directory = settingString("motionbgs_download_directory", ""),
        motionbgs_result_limit = settingInt("motionbgs_result_limit", 24, 1, 24),
        motionbgs_cache_minutes = settingInt("motionbgs_cache_minutes", 30, 5, 1440),
        motionbgs_max_download_mb = settingInt("motionbgs_max_download_mb", 256, 16, 512),
        motionbgs_quality = if settingString("motionbgs_quality", "hd") == "4k" then "4k" else "hd",
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
        w_engine_scaling = settingString("w_engine_scaling", "fill"),
        w_engine_fps = settingInt("w_engine_fps", 30, 1, 240),
        w_engine_volume = settingInt("w_engine_volume", 0, 0, 100),
        w_engine_silent = settingBool("w_engine_silent", true),
        w_engine_clamp = settingString("w_engine_clamp", "border"),
        w_engine_noautomute = settingBool("w_engine_noautomute", false),
        w_engine_no_audio_processing = settingBool("w_engine_no_audio_processing", false),
        w_engine_disable_particles = settingBool("w_engine_disable_particles", false),
        w_engine_disable_mouse = settingBool("w_engine_disable_mouse", false),
        w_engine_disable_parallax = settingBool("w_engine_disable_parallax", false),
        w_engine_no_fullscreen_pause = settingBool("w_engine_no_fullscreen_pause", false),
        w_engine_fullscreen_pause_only_active = settingBool("w_engine_fullscreen_pause_only_active", false),
        mpv_mute = settingBool("mpv_mute", true),
        mpv_hardware_decode = settingBool("mpv_hardware_decode", true),
        mpv_auto_pause = settingBool("mpv_auto_pause", true),
        mpv_auto_pause_mode = settingString("mpv_auto_pause_mode", "FULL"),
        mpv_options = settingString("mpv_options", ""),
        cycle_interval_minutes = settingInt("cycle_interval_minutes", 15, 1, 43200),
        cycle_order = configuredCycleOrder(),
        cycle_start_on_load = settingBool("cycle_start_on_load", false),
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

local function validPersistedKey(value)
    return type(value) == "string" and value ~= "" and #value <= 160 and value:find("[%c]") == nil
end

local function normalizedEntry(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local kind = tostring(candidate.kind or "")
    local source = tostring(candidate.source or "")
    if not VALID_ENTRY_KINDS[kind] or source == "" or #source > MAX_PERSISTED_PATH_BYTES or source:find("[%c]") then
        return nil
    end
    if kind == "workshop" then
        if source:match("^%d+$") == nil then
            return nil
        end
    elseif source:sub(1, 1) ~= "/" then
        return nil
    end
    local stillPath = tostring(candidate.still_path or "")
    if
        stillPath ~= ""
        and (#stillPath > MAX_PERSISTED_PATH_BYTES or stillPath:sub(1, 1) ~= "/" or stillPath:find("[%c]"))
    then
        return nil
    end
    local label = boundedDetail(candidate.label or "")
    return {
        kind = kind,
        source = source,
        still_path = stillPath,
        label = label,
        added_at = boundedDetail(candidate.added_at or ""),
    }
end

local function normalizedReels(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local reels = {}
    local outputCount = 0
    for output, value in pairs(candidate) do
        outputCount += 1
        if not validPersistedKey(output) or type(value) ~= "table" or type(value.entries) ~= "table" then
            return nil
        end
        if outputCount > MAX_RUNTIME_OUTPUTS then
            return nil
        end
        local entries = {}
        if #value.entries > MAX_REEL_ENTRIES then
            return nil
        end
        for _, rawEntry in ipairs(value.entries) do
            local entry = normalizedEntry(rawEntry)
            if entry == nil then
                return nil
            end
            table.insert(entries, entry)
        end
        local interval = math.floor(tonumber(value.interval_seconds) or configuredCycleSeconds())
        interval = math.max(MIN_CYCLE_SECONDS, math.min(MAX_CYCLE_SECONDS, interval))
        local order = tostring(value.order or configuredCycleOrder())
        reels[output] = {
            interval_seconds = interval,
            order = if VALID_CYCLE_ORDERS[order] then order else configuredCycleOrder(),
            entries = entries,
        }
    end
    return reels
end

local function validateConfig(candidate)
    if type(candidate) ~= "table" then
        return nil, noctalia.tr("errors.config_not_object")
    end
    local schema = tonumber(candidate.schema_version)
    if schema ~= 1 and schema ~= CONFIG_SCHEMA then
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

    local reels = if schema == 1 then {} else normalizedReels(candidate.reels)
    if reels == nil then
        return nil, noctalia.tr("errors.config_reels")
    end
    return { schema_version = CONFIG_SCHEMA, gestures = gestures, reels = reels }, nil, schema == 1
end

local function validRuntimeKey(value, maximum)
    return type(value) == "string" and value ~= "" and #value <= maximum and value:find("[%c]") == nil
end

local function normalizedPair(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local provider = tostring(candidate.provider or "")
    local dynamicId = tostring(candidate.dynamic_id or "")
    local stillPath = tostring(candidate.still_path or "")
    local captureMethod = tostring(candidate.capture_method or "")
    if
        not validRuntimeKey(provider, 80)
        or not validRuntimeKey(dynamicId, MAX_PERSISTED_PATH_BYTES)
        or not validRuntimeKey(captureMethod, 160)
        or not validRuntimeKey(stillPath, MAX_PERSISTED_PATH_BYTES)
        or stillPath:sub(1, 1) ~= "/"
    then
        return nil
    end
    return {
        provider = provider,
        dynamic_id = dynamicId,
        still_path = stillPath,
        capture_method = captureMethod,
        paired_at = boundedDetail(candidate.paired_at or ""),
        color_source_before = boundedDetail(candidate.color_source_before or ""),
        color_scheme_before = boundedDetail(candidate.color_scheme_before or ""),
        color_scheme = boundedDetail(candidate.color_scheme or ""),
        still_size = math.max(0, math.floor(tonumber(candidate.still_size) or 0)),
        still_mtime = math.max(0, math.floor(tonumber(candidate.still_mtime) or 0)),
    }
end

local function normalizedPairMap(candidate, maximumEntries, registry)
    if type(candidate) ~= "table" then
        return nil
    end
    local result = {}
    local count = 0
    for key, rawPair in pairs(candidate) do
        count += 1
        local keyValid = if registry then validRuntimeKey(key, MAX_PERSISTED_PATH_BYTES) else validPersistedKey(key)
        local pair = normalizedPair(rawPair)
        if not keyValid or pair == nil or count > maximumEntries then
            return nil
        end
        result[key] = pair
    end
    return result
end

local function normalizedIndexList(candidate, maximumEntries)
    if candidate == nil then
        return {}
    end
    if type(candidate) ~= "table" then
        return nil
    end
    local count = 0
    for key in pairs(candidate) do
        count += 1
        if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > maximumEntries then
            return nil
        end
    end
    if count ~= #candidate or count > maximumEntries then
        return nil
    end
    local result = {}
    for index = 1, count do
        local value = tonumber(candidate[index])
        if value == nil or value % 1 ~= 0 or value < 1 or value > MAX_REEL_ENTRIES then
            return nil
        end
        result[index] = value
    end
    return result
end

local function normalizedCycles(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local result = {}
    local count = 0
    for output, rawState in pairs(candidate) do
        count += 1
        if not validPersistedKey(output) or type(rawState) ~= "table" or count > MAX_RUNTIME_OUTPUTS then
            return nil
        end
        local history = normalizedIndexList(rawState.history, 64)
        local bag = normalizedIndexList(rawState.bag, MAX_REEL_ENTRIES)
        if history == nil or bag == nil then
            return nil
        end
        local lastEntry = nil
        if rawState.last_entry ~= nil then
            lastEntry = normalizedEntry(rawState.last_entry)
            if lastEntry == nil then
                return nil
            end
        end
        result[output] = {
            running = rawState.running == true,
            paused = rawState.paused == true,
            cursor = math.max(0, math.min(MAX_REEL_ENTRIES, math.floor(tonumber(rawState.cursor) or 0))),
            next_due = math.max(0, math.floor(tonumber(rawState.next_due) or 0)),
            history = history,
            bag = bag,
            last_entry = lastEntry,
            last_applied_at = boundedDetail(rawState.last_applied_at or ""),
            last_error = boundedDetail(rawState.last_error or ""),
        }
    end
    return result
end

local function normalizedLastCapture(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    if next(candidate) == nil then
        return {}
    end
    local provider = tostring(candidate.provider or "")
    local dynamicId = tostring(candidate.dynamic_id or "")
    local output = tostring(candidate.output or "")
    local path = tostring(candidate.path or "")
    local method = tostring(candidate.method or "")
    if
        not validRuntimeKey(provider, 80)
        or not validRuntimeKey(dynamicId, MAX_PERSISTED_PATH_BYTES)
        or not validRuntimeKey(output, 160)
        or not validRuntimeKey(path, MAX_PERSISTED_PATH_BYTES)
        or path:sub(1, 1) ~= "/"
        or not validRuntimeKey(method, 160)
    then
        return nil
    end
    return {
        provider = provider,
        dynamic_id = dynamicId,
        output = output,
        path = path,
        method = method,
        captured_at = boundedDetail(candidate.captured_at or ""),
    }
end

local function validateRuntime(candidate)
    if type(candidate) ~= "table" then
        return nil, noctalia.tr("errors.runtime_not_object")
    end
    local schema = tonumber(candidate.schema_version)
    if schema ~= 1 and schema ~= 2 and schema ~= RUNTIME_SCHEMA then
        return nil, noctalia.tr("errors.runtime_schema", { version = tostring(candidate.schema_version or "?") })
    end
    if type(candidate.providers) ~= "table" or (schema >= 2 and type(candidate.pairs) ~= "table") then
        return nil, noctalia.tr("errors.runtime_providers")
    end
    local pairsState =
        normalizedPairMap(type(candidate.pairs) == "table" and candidate.pairs or {}, MAX_RUNTIME_OUTPUTS, false)
    local pairRegistry = normalizedPairMap(
        type(candidate.pair_registry) == "table" and candidate.pair_registry or {},
        MAX_PAIR_REGISTRY_ENTRIES,
        true
    )
    local cycles = normalizedCycles(type(candidate.cycles) == "table" and candidate.cycles or {})
    local lastCapture = normalizedLastCapture(type(candidate.last_capture) == "table" and candidate.last_capture or {})
    if pairsState == nil or pairRegistry == nil or cycles == nil or lastCapture == nil then
        return nil, noctalia.tr("errors.runtime_nested")
    end
    return {
        schema_version = RUNTIME_SCHEMA,
        -- Provider observations are reconstructed from a fresh, fail-closed
        -- ownership probe before use; never republish arbitrary nested input.
        providers = {},
        pairs = pairsState,
        pair_registry = pairRegistry,
        cycles = cycles,
        last_capture = lastCapture,
        observed_at = boundedDetail(candidate.observed_at or ""),
        last_error = boundedDetail(candidate.last_error or ""),
    },
        nil,
        schema ~= RUNTIME_SCHEMA
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
    if #encoded + 1 > MAX_STORAGE_BYTES then
        return false,
            noctalia.tr("errors.storage_size", {
                name = name,
                limit = tostring(math.floor(MAX_STORAGE_BYTES / 1024)),
            })
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
    local info = noctalia.fileInfo(path)
    if
        type(info) ~= "table"
        or info.isDir == true
        or (tonumber(info.size) or 0) <= 0
        or (tonumber(info.size) or 0) > MAX_STORAGE_BYTES
    then
        return nil,
            noctalia.tr("errors.storage_size", {
                name = name,
                limit = tostring(math.floor(MAX_STORAGE_BYTES / 1024)),
            })
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
    local loadedConfig, loadedConfigError, migratedConfig = loadJsonFile("config.json", validateConfig, config)
    if loadedConfig == nil then
        configValid = false
        configError = tostring(loadedConfigError or noctalia.tr("errors.config_invalid"))
    else
        config = loadedConfig
        if migratedConfig then
            local migrated, migrationError = atomicWrite("config.json", config)
            if not migrated then
                configValid = false
                configError = tostring(migrationError or noctalia.tr("errors.config_save"))
            end
        end
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
        config = {
            schema_version = CONFIG_SCHEMA,
            gestures = cloneGestures(config.gestures),
            reels = normalizedReels(config.reels) or {},
        },
        settings = settingsSnapshot(),
        providers = providers,
        renderer = rendererStatus,
        motionbgs = {
            status = motionBgsStatus,
            results = motionBgsResults,
        },
        library = library,
        colors = colors,
        pairs = runtime.pairs,
        pair_registry = runtime.pair_registry,
        cycles = runtime.cycles,
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
        tostring(providers.wallhaven.allowed),
        tostring(providers.wallhaven.plugin_enabled),
        tostring(providers.wallhaven.available),
        tostring(providers.wallhaven.version),
        tostring(providers.w_engine.allowed),
        tostring(providers.w_engine.plugin_enabled),
        tostring(providers.w_engine.available),
        tostring(providers.w_engine.version),
        tostring(providers.w_engine.renderer_available),
        tostring(providers.w_engine.adapter_version),
        tostring(providers.w_engine.adapter_capture),
        tostring(providers.w_engine.adapter_status),
        tostring(providers.w_engine.internal_available),
        tostring(providers.w_engine.effective_backend),
        tostring(providers.w_engine.apply_available),
        tostring(providers.w_engine.conflict),
        providerCurrentSignature(),
        tostring(providers.mpvpaper.allowed),
        tostring(providers.mpvpaper.plugin_enabled),
        tostring(providers.mpvpaper.available),
        tostring(providers.mpvpaper.version),
        tostring(providers.mpvpaper.command_available),
        tostring(providers.mpvpaper.internal_available),
        tostring(providers.mpvpaper.effective_backend),
        tostring(providers.mpvpaper.apply_available),
        tostring(providers.mpvpaper.conflict),
        tostring(providers.motionbgs.allowed),
        tostring(providers.motionbgs.available),
        tostring(providers.motionbgs.browser_available),
        tostring(providers.motionbgs.integration_available),
        tostring(providers.daemons.awww),
        tostring(providers.daemons.swww),
        tostring(providers.daemons.wpaperd),
        tostring(providers.daemons.hyprpaper),
        tostring(providers.extra.panel),
        tostring(providers.extra.allowed),
        tostring(providers.extra.plugin_enabled),
        tostring(providers.extra.available),
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
            allowed = providers.wallhaven.allowed,
            enabled = providers.wallhaven.plugin_enabled,
            available = providers.wallhaven.available,
            version = providers.wallhaven.version,
        },
        w_engine = {
            allowed = providers.w_engine.allowed,
            enabled = providers.w_engine.plugin_enabled,
            available = providers.w_engine.available,
            version = providers.w_engine.version,
            renderer = providers.w_engine.renderer_available,
            adapter_version = providers.w_engine.adapter_version,
            adapter_capture = providers.w_engine.adapter_capture,
            adapter_status = providers.w_engine.adapter_status,
            internal_available = providers.w_engine.internal_available,
            effective_backend = providers.w_engine.effective_backend,
            apply_available = providers.w_engine.apply_available,
            conflict = providers.w_engine.conflict,
            current = providers.w_engine.current,
        },
        mpvpaper = {
            allowed = providers.mpvpaper.allowed,
            enabled = providers.mpvpaper.plugin_enabled,
            available = providers.mpvpaper.available,
            version = providers.mpvpaper.version,
            command_available = providers.mpvpaper.command_available,
            internal_available = providers.mpvpaper.internal_available,
            effective_backend = providers.mpvpaper.effective_backend,
            apply_available = providers.mpvpaper.apply_available,
            conflict = providers.mpvpaper.conflict,
        },
        motionbgs = providers.motionbgs,
        daemons = providers.daemons,
        extra = {
            panel = providers.extra.panel,
            allowed = providers.extra.allowed,
            enabled = providers.extra.plugin_enabled,
            available = providers.extra.available,
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
    local allowed = settingBool("use_extra_provider", true)
    providers.extra = {
        allowed = allowed,
        configured = panelId ~= "",
        plugin_enabled = entry ~= nil,
        available = panelId ~= "" and entry ~= nil and allowed,
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

local function refreshBackendPolicy()
    local rendererReady = type(rendererStatus) == "table" and rendererStatus.ready == true
    local previousWEngine = backendPolicySignature.w_engine
    local previousMpvpaper = backendPolicySignature.mpvpaper

    local function resolve(allowed, desired, pluginEnabled, commandAvailable)
        local ownershipKnown = providers.probe_ok == true
        local internalAvailable = allowed and ownershipKnown and rendererReady and commandAvailable
        local conflict = allowed and desired == "internal" and pluginEnabled
        if not allowed then
            return "none", internalAvailable, false, false
        elseif not ownershipKnown then
            -- Unknown must never be interpreted as no external owner. This
            -- covers startup and transient `plugins list` failures.
            return "none", false, false, false
        elseif desired == "external" then
            return if pluginEnabled then "external" else "none", internalAvailable, false, false
        elseif desired == "internal" then
            return if internalAvailable and not conflict then "internal" else "none",
                internalAvailable,
                internalAvailable and not conflict,
                conflict
        elseif pluginEnabled then
            return "external", internalAvailable, false, false
        elseif internalAvailable then
            return "internal", internalAvailable, true, false
        end
        return "none", internalAvailable, false, false
    end

    providers.w_engine.effective_backend, providers.w_engine.internal_available, providers.w_engine.apply_available, providers.w_engine.conflict =
        resolve(
            providers.w_engine.allowed,
            configuredBackend("w_engine_backend"),
            providers.w_engine.plugin_enabled,
            providers.w_engine.renderer_available
        )
    providers.mpvpaper.effective_backend, providers.mpvpaper.internal_available, providers.mpvpaper.apply_available, providers.mpvpaper.conflict =
        resolve(
            providers.mpvpaper.allowed,
            configuredBackend("mpvpaper_backend"),
            providers.mpvpaper.plugin_enabled,
            noctalia.commandExists("mpvpaper")
        )
    providers.motionbgs.allowed = settingBool("use_motionbgs", true)
    providers.motionbgs.browser_available = noctalia.commandExists("xdg-open")
    providers.motionbgs.integration_available = providers.motionbgs.allowed
        and type(motionBgsStatus) == "table"
        and motionBgsStatus.available == true
    -- The direct website is a permanent fallback and remains independent of
    -- the best-effort public-page adapter's health or enable switch.
    providers.motionbgs.available = providers.motionbgs.browser_available
    providers.motionbgs.url = MOTIONBGS_URL
    local nextWEngine = table.concat({
        tostring(providers.w_engine.allowed),
        tostring(providers.w_engine.effective_backend),
        tostring(providers.w_engine.apply_available),
        tostring(providers.w_engine.conflict),
    }, "|")
    local nextMpvpaper = table.concat({
        tostring(providers.mpvpaper.allowed),
        tostring(providers.mpvpaper.effective_backend),
        tostring(providers.mpvpaper.apply_available),
        tostring(providers.mpvpaper.conflict),
    }, "|")
    backendPolicySignature.w_engine = nextWEngine
    backendPolicySignature.mpvpaper = nextMpvpaper
    if previousWEngine ~= nextWEngine then
        backendGeneration.w_engine += 1
    end
    if previousMpvpaper ~= nextMpvpaper then
        backendGeneration.mpvpaper += 1
    end
end

local function applyIntegrationPolicy()
    providers.wallhaven.allowed = settingBool("use_wallhaven", true)
    providers.wallhaven.available = providers.probe_ok
        and providers.wallhaven.plugin_enabled
        and providers.wallhaven.allowed

    providers.w_engine.allowed = settingBool("use_w_engine", true)
    providers.w_engine.available = providers.probe_ok
        and providers.w_engine.plugin_enabled
        and providers.w_engine.allowed
    if not providers.w_engine.allowed then
        clearAdapterState()
    end

    providers.mpvpaper.allowed = settingBool("use_mpvpaper", true)
    providers.mpvpaper.available = providers.probe_ok
        and providers.mpvpaper.plugin_enabled
        and providers.mpvpaper.allowed
    refreshBackendPolicy()
    if type(reconcileRendererOwnership) == "function" then
        reconcileRendererOwnership()
    end
end

local function requestAdapterProbe()
    if not providers.w_engine.available or not providers.noctalia_cli then
        return
    end
    local requestedAt = noctalia.nowMs()
    providers.w_engine.adapter_probe_ms = requestedAt
    local command = "noctalia msg plugin " .. W_ENGINE_SERVICE .. " all wall-in-one-probe-v1"
    -- A command exit is not a capability response. Keep the timestamp armed;
    -- update() expires stale adapter state after the documented grace window.
    noctalia.runAsync(command, function(_result) end, 5000)
end

local function completeProviderProbe(enabled, probeError)
    providerProbeInFlight = false
    providers.probing = false
    providers.probe_ok = probeError == nil
    providers.probe_error = tostring(probeError or "")
    providers.probed_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    providers.noctalia_cli = noctalia.commandExists("noctalia")

    if probeError ~= nil then
        -- Preserve the last known ownership flags for diagnostics, but fail
        -- closed: refreshBackendPolicy gates every internal start on probe_ok.
        providers.wallhaven.allowed = settingBool("use_wallhaven", true)
        providers.wallhaven.available = false
        providers.w_engine.allowed = settingBool("use_w_engine", true)
        providers.w_engine.available = false
        providers.w_engine.renderer_available = noctalia.commandExists("linux-wallpaperengine")
        providers.mpvpaper.allowed = settingBool("use_mpvpaper", true)
        providers.mpvpaper.available = false
        providers.mpvpaper.command_available = noctalia.commandExists("mpvpaper") and noctalia.commandExists("mpv")
        providers.extra.allowed = settingBool("use_extra_provider", true)
        providers.extra.available = false
        refreshBackendPolicy()
        if type(reconcileRendererOwnership) == "function" then
            reconcileRendererOwnership()
        end
        persistRuntimeIfChanged(false)
        publishStatus()
        return
    end

    local pluginList = type(enabled) == "table" and enabled or {}
    local wallhaven = pluginList[WALLHAVEN_ID]
    local wEngine = pluginList[W_ENGINE_ID]
    local mpvpaper = pluginList[MPVPAPER_ID]
    local wallhavenAllowed = settingBool("use_wallhaven", true)
    local wEngineAllowed = settingBool("use_w_engine", true)
    local mpvpaperAllowed = settingBool("use_mpvpaper", true)
    providers.wallhaven = {
        allowed = wallhavenAllowed,
        plugin_enabled = wallhaven ~= nil,
        available = probeError == nil and wallhaven ~= nil and wallhavenAllowed,
        version = type(wallhaven) == "table" and tostring(wallhaven.version or "") or "",
    }
    local previousWEngineVersion = providers.w_engine.version
    local previousWEngineAllowed = providers.w_engine.allowed
    providers.w_engine.allowed = wEngineAllowed
    providers.w_engine.plugin_enabled = wEngine ~= nil
    providers.w_engine.version = type(wEngine) == "table" and tostring(wEngine.version or "") or ""
    providers.w_engine.renderer_available = noctalia.commandExists("linux-wallpaperengine")
    providers.w_engine.available = probeError == nil and wEngine ~= nil and wEngineAllowed
    if
        wEngine == nil
        or not wEngineAllowed
        or previousWEngineAllowed ~= wEngineAllowed
        or (previousWEngineVersion ~= "" and previousWEngineVersion ~= providers.w_engine.version)
    then
        clearAdapterState()
    end
    providers.mpvpaper = {
        allowed = mpvpaperAllowed,
        plugin_enabled = mpvpaper ~= nil,
        available = probeError == nil and mpvpaper ~= nil and mpvpaperAllowed,
        command_available = noctalia.commandExists("mpvpaper") and noctalia.commandExists("mpv"),
        internal_available = false,
        effective_backend = "none",
        apply_available = false,
        conflict = false,
        version = type(mpvpaper) == "table" and tostring(mpvpaper.version or "") or "",
    }
    providers.daemons = {
        awww = noctalia.commandExists("awww"),
        swww = noctalia.commandExists("swww"),
        wpaperd = noctalia.commandExists("wpaperctl"),
        hyprpaper = noctalia.commandExists("hyprctl"),
    }
    refreshExtraProvider(pluginList)
    refreshBackendPolicy()
    if type(reconcileRendererOwnership) == "function" then
        reconcileRendererOwnership()
    end
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
        local expanded = normalizedDirectory(noctalia.expandPath(custom))
        if expanded ~= nil then
            expanded ..= "/"
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

refreshLibrary = function()
    local videoRoot = videoDirectory()
    local videoEntries = {}
    if videoRoot ~= "" then
        local entries = noctalia.listDir(videoRoot)
        if type(entries) == "table" then
            for index = 1, math.min(#entries, MAX_LIBRARY_CANDIDATES) do
                table.insert(videoEntries, tostring(entries[index]))
            end
            table.sort(videoEntries)
        end
    end

    local workshopCandidates = {}
    local seenIds = {}
    local workshopNamesExamined = 0
    for _, root in ipairs(candidateWorkshopRoots()) do
        local ids = noctalia.listDir(root)
        if type(ids) == "table" then
            for _, candidate in ipairs(ids) do
                workshopNamesExamined += 1
                local id = tostring(candidate)
                if id:match("^%d+$") and not seenIds[id] then
                    seenIds[id] = true
                    table.insert(workshopCandidates, { id = id, directory = root .. id .. "/" })
                    if #workshopCandidates >= MAX_LIBRARY_CANDIDATES then
                        break
                    end
                end
                if workshopNamesExamined >= MAX_LIBRARY_CANDIDATES then
                    break
                end
            end
        end
        if #workshopCandidates >= MAX_LIBRARY_CANDIDATES or workshopNamesExamined >= MAX_LIBRARY_CANDIDATES then
            break
        end
    end
    table.sort(workshopCandidates, function(left, right)
        return tostring(left.id) < tostring(right.id)
    end)

    libraryScan = {
        video_root = videoRoot,
        video_entries = videoEntries,
        video_index = 1,
        workshop_candidates = workshopCandidates,
        workshop_index = 1,
        videos = {},
        workshops = {},
        phase = "videos",
    }
    library = {
        videos = type(library.videos) == "table" and library.videos or {},
        workshops = type(library.workshops) == "table" and library.workshops or {},
        scanned_at = tostring(library.scanned_at or ""),
        error = "",
        scanning = true,
    }
end

local function stepLibraryScan()
    local scan = libraryScan
    if type(scan) ~= "table" then
        return false
    end
    local supportedVideo = {
        [".mp4"] = true,
        [".mkv"] = true,
        [".webm"] = true,
        [".mov"] = true,
        [".avi"] = true,
        [".m4v"] = true,
        [".gif"] = true,
    }
    local budget = LIBRARY_SCAN_BATCH
    while budget > 0 and scan.phase == "videos" do
        local name = scan.video_entries[scan.video_index]
        if name == nil or #scan.videos >= MAX_REEL_ENTRIES then
            scan.phase = "workshops"
            break
        end
        scan.video_index += 1
        budget -= 1
        local path = scan.video_root .. (if scan.video_root == "/" then "" else "/") .. name
        local info = noctalia.fileInfo(path)
        local extension = path:lower():match("(%.[%w]+)$") or ""
        if
            type(info) == "table"
            and info.isDir ~= true
            and (tonumber(info.size) or 0) > 0
            and supportedVideo[extension]
        then
            table.insert(scan.videos, {
                path = path,
                name = name,
                size = tonumber(info.size) or 0,
                mtime = tonumber(info.mtime) or 0,
            })
        end
    end
    while budget > 0 and scan.phase == "workshops" do
        local candidate = scan.workshop_candidates[scan.workshop_index]
        if candidate == nil or #scan.workshops >= MAX_REEL_ENTRIES then
            scan.phase = "done"
            break
        end
        scan.workshop_index += 1
        budget -= 1
        local projectPath = candidate.directory .. "project.json"
        local projectInfo = noctalia.fileInfo(projectPath)
        if
            type(projectInfo) == "table"
            and projectInfo.isDir ~= true
            and (tonumber(projectInfo.size) or 0) > 0
            and (tonumber(projectInfo.size) or 0) <= MAX_PROJECT_JSON_BYTES
        then
            local raw = noctalia.readFile(projectPath)
            local project = type(raw) == "string" and noctalia.json.decode(raw) or nil
            if type(project) == "table" then
                local preview = safeRelativePath(project.preview or "preview.jpg")
                table.insert(scan.workshops, {
                    id = candidate.id,
                    title = boundedDetail(project.title or ("Workshop " .. candidate.id)),
                    kind = boundedDetail(project.type or "unknown"),
                    directory = candidate.directory,
                    preview = if preview ~= nil then candidate.directory .. preview else "",
                })
            end
        end
    end
    if scan.phase ~= "done" then
        return false
    end

    local motionDownload = type(motionBgsStatus) == "table"
            and type(motionBgsStatus.last_download) == "table"
            and tostring(motionBgsStatus.last_download.path or "")
        or ""
    if motionDownload ~= "" then
        local alreadyListed = false
        for _, entry in ipairs(scan.videos) do
            if tostring(entry.path or "") == motionDownload then
                alreadyListed = true
                break
            end
        end
        local info = noctalia.fileInfo(motionDownload)
        local extension = motionDownload:lower():match("(%.[%w]+)$") or ""
        if
            not alreadyListed
            and type(info) == "table"
            and info.isDir ~= true
            and (tonumber(info.size) or 0) > 0
            and supportedVideo[extension]
        then
            table.insert(scan.videos, 1, {
                path = motionDownload,
                name = tostring(motionBgsStatus.last_download.title or motionDownload:match("([^/]+)$") or "MotionBGS"),
                size = tonumber(info.size) or 0,
                mtime = tonumber(info.mtime) or 0,
                provider = "MotionBGS",
                source_url = tostring(motionBgsStatus.last_download.source_url or MOTIONBGS_URL),
            })
        end
    end
    table.sort(scan.workshops, function(left, right)
        return tostring(left.title):lower() < tostring(right.title):lower()
    end)
    library = {
        videos = scan.videos,
        workshops = scan.workshops,
        scanned_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        error = "",
        scanning = false,
    }
    libraryScan = nil
    return true
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

local function stablePathTag(value)
    -- A deterministic, non-cryptographic tag prevents equal basename/size/
    -- mtime files in different directories from sharing a capture filename.
    local hash = 0
    value = tostring(value or "")
    for index = 1, #value do
        hash = (hash * 131 + string.byte(value, index)) % 2147483647
    end
    return string.format("%08x", hash)
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

local function cleanupOwnedStaging()
    local dataDirectory = noctalia.pluginDataDir()
    if type(dataDirectory) ~= "string" or dataDirectory == "" or dataDirectory:find("[%c]") then
        return
    end
    local directory = dataDirectory:gsub("/+$", "") .. "/staging"
    local entries = noctalia.listDir(directory)
    if type(entries) ~= "table" then
        return
    end
    for index = 1, math.min(#entries, 512) do
        local name = tostring(entries[index] or "")
        if name:match("^capture%-%w[%w%-]*%.png$") then
            noctalia.removeFile(directory .. "/" .. name)
        end
    end
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

local function videoCaptureSpec(sourceOverride)
    local source = tostring(sourceOverride or "")
    if source == "" then
        source = configuredVideoSource()
    end
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
    local stillInfo = noctalia.fileInfo(path)
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
    elseif tostring(dynamicId):match("^static:") then
        provider = "noctalia"
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
        still_size = type(stillInfo) == "table" and (tonumber(stillInfo.size) or 0) or 0,
        still_mtime = type(stillInfo) == "table" and (tonumber(stillInfo.mtime) or 0) or 0,
    }
    runtime.pair_registry[tostring(dynamicId)] = {
        provider = provider,
        dynamic_id = dynamicId,
        still_path = path,
        capture_method = method,
        paired_at = runtime.pairs[key].paired_at,
        still_size = runtime.pairs[key].still_size,
        still_mtime = runtime.pairs[key].still_mtime,
    }
    local registryEntries = {}
    for registryKey, pair in pairs(runtime.pair_registry) do
        table.insert(registryEntries, {
            key = registryKey,
            paired_at = type(pair) == "table" and tostring(pair.paired_at or "") or "",
        })
    end
    if #registryEntries > MAX_PAIR_REGISTRY_ENTRIES then
        table.sort(registryEntries, function(left, right)
            if left.paired_at == right.paired_at then
                return tostring(left.key) < tostring(right.key)
            end
            return left.paired_at < right.paired_at
        end)
        for index = 1, #registryEntries - MAX_PAIR_REGISTRY_ENTRIES do
            runtime.pair_registry[registryEntries[index].key] = nil
        end
    end
    local outputPairs = {}
    for outputKey, pair in pairs(runtime.pairs) do
        table.insert(outputPairs, {
            key = outputKey,
            paired_at = type(pair) == "table" and tostring(pair.paired_at or "") or "",
        })
    end
    if #outputPairs > MAX_RUNTIME_OUTPUTS then
        table.sort(outputPairs, function(left, right)
            if left.paired_at == right.paired_at then
                return tostring(left.key) < tostring(right.key)
            end
            return left.paired_at < right.paired_at
        end)
        for index = 1, #outputPairs - MAX_RUNTIME_OUTPUTS do
            runtime.pairs[outputPairs[index].key] = nil
        end
    end

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
    activeCaptureRequests[key] = nil
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
        local pairIsCurrent = true
        if request.pair and type(request.output) == "string" and request.output ~= "" then
            pairIsCurrent = knownOutputName(request.output) ~= nil
        end
        if pairIsCurrent and request.pair and type(request.should_apply) == "function" then
            local checked, current = pcall(request.should_apply)
            pairIsCurrent = checked and current == true
        end
        runtime.last_capture = {
            provider = request.provider,
            dynamic_id = request.dynamic_id,
            output = request.output or "all",
            path = finalPath,
            method = request.spec.method,
            captured_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        }
        if pairIsCurrent or not request.pair then
            lastActionError = ""
            lastActionAt = runtime.last_capture.captured_at
        end
        persistRuntimeIfChanged(true)
        if request.pair and pairIsCurrent then
            applyPairedStill(request.output, request.dynamic_id, finalPath, request.spec.method, request.notify)
        elseif not request.pair and request.notify then
            noctalia.notify(noctalia.tr("plugin.title"), noctalia.tr("notifications.captured", { path = finalPath }))
        end
        if type(request.on_complete) == "function" then
            local callbackOk, callbackError = pcall(request.on_complete, not request.pair or pairIsCurrent, finalPath)
            if not callbackOk then
                setActionError(noctalia.tr("errors.capture_callback", { detail = boundedDetail(callbackError) }), nil)
            end
        end
    else
        local failure = tostring(errorMessage or noctalia.tr("errors.capture_failed"))
        setActionError(failure, "capture")
        if type(request.on_complete) == "function" then
            pcall(request.on_complete, false, nil, failure)
        end
    end
    publishStatus()

    local queued = captureQueued[key]
    captureQueued[key] = nil
    if type(queued) == "table" then
        runCapture(queued)
    end
    local queuedAdapter = adapterCaptureQueued[key]
    adapterCaptureQueued[key] = nil
    if type(queuedAdapter) == "table" and type(requestRenderedCapture) == "function" then
        requestRenderedCapture(queuedAdapter.output, queuedAdapter.id, queuedAdapter.pair, queuedAdapter.notify)
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
        if type(replaced) == "table" and type(replaced.on_complete) == "function" then
            pcall(replaced.on_complete, false, noctalia.tr("errors.capture_replaced"))
        end
        captureQueued[key] = request
        return
    end
    -- Re-run the atomic helper for a destination that already exists. Pair
    -- registry fingerprints provide the normal cache fast path; a cache miss
    -- must decode-validate/re-extract instead of trusting replaced bytes.
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
    activeCaptureRequests[key] = request
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

local function captureWorkshopFallback(output, id, force, pair, notifySuccess, onComplete, shouldApply)
    if not providers.w_engine.allowed then
        setActionError(noctalia.tr("errors.w_engine_forced_off"), "capture-current")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    output = targetOutput(output)
    id = tostring(id or "")
    if output == nil or id:match("^%d+$") == nil then
        setActionError(noctalia.tr("errors.no_current_scene"), "capture-current")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local spec, specError = workshopFallbackSpec(id)
    if spec == nil then
        setActionError(specError, "capture-source")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local destination, destinationError = captureDestination("w-engine", id, output, spec.extension)
    if destination == nil then
        setActionError(destinationError, "capture-directory")
        if type(onComplete) == "function" then
            onComplete(false)
        end
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
        on_complete = onComplete,
        should_apply = shouldApply,
    })
end

requestRenderedCapture = function(output, id, pair, notifySuccess)
    if not providers.w_engine.allowed then
        setActionError(noctalia.tr("errors.w_engine_forced_off"), "capture-current")
        return
    end
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
        adapterCaptureQueued[key] = {
            output = output,
            id = id,
            pair = pair == true,
            notify = notifySuccess == true,
        }
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
        should_apply = function()
            return providers.w_engine.allowed == true
                and providers.w_engine.adapter_capture == true
                and tostring(providers.w_engine.current[output] or "") == id
                and knownOutputName(output) ~= nil
        end,
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
    if not providers.w_engine.allowed then
        setActionError(noctalia.tr("errors.w_engine_forced_off"), "capture-current")
        return
    end
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

local function captureVideoPath(output, source, force, pair, notifySuccess, onComplete, shouldApply)
    output = targetOutput(output)
    if output == nil then
        setActionError(noctalia.tr("availability.output"), "video-capture")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local spec, specError = videoCaptureSpec(source)
    if spec == nil then
        setActionError(specError, "video-capture")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local sourceInfo = noctalia.fileInfo(spec.source)
    local identity = table.concat({
        stablePathTag(spec.source),
        tostring(type(sourceInfo) == "table" and sourceInfo.size or 0),
        tostring(type(sourceInfo) == "table" and sourceInfo.mtime or 0),
        sanitizedName(spec.source:match("([^/]+)$") or "video"),
    }, "-")
    local destination, destinationError = captureDestination("video", identity, output, spec.extension)
    if destination == nil then
        setActionError(destinationError, "capture-directory")
        if type(onComplete) == "function" then
            onComplete(false)
        end
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
        on_complete = onComplete,
        should_apply = shouldApply,
    })
end

local function captureConfiguredVideo(output, force, pair, notifySuccess, onComplete)
    captureVideoPath(output, configuredVideoSource(), force, pair, notifySuccess, onComplete)
end

local function nextRendererNonce()
    local previous = noctalia.state.get(RENDERER_COMMAND_KEY)
    local previousNonce = if type(previous) == "table" then tonumber(previous.nonce) or 0 else 0
    local statusNonce = if type(rendererStatus) == "table" then tonumber(rendererStatus.last_nonce) or 0 else 0
    rendererCommandSequence = math.max(rendererCommandSequence, previousNonce, statusNonce) + 1
    return rendererCommandSequence
end

local function sendRendererCommand(command, onAcknowledged)
    if type(rendererStatus) ~= "table" or rendererStatus.ready ~= true then
        setActionError(noctalia.tr("errors.renderer_unavailable"), "renderer")
        return false
    end
    command.schema = 1
    command.nonce = nextRendererNonce()
    if type(onAcknowledged) == "function" then
        rendererPending[command.nonce] = {
            action = tostring(command.action or ""),
            output = tostring(command.output or ""),
            deadline = nowSeconds() + 20,
            callback = onAcknowledged,
        }
    end
    noctalia.state.set(RENDERER_COMMAND_KEY, command)
    return true, command.nonce
end

local function finishRendererPending(nonce, ok, reason)
    nonce = tonumber(nonce)
    local pending = nonce ~= nil and rendererPending[nonce] or nil
    if type(pending) ~= "table" then
        return
    end
    rendererPending[nonce] = nil
    local callback = pending.callback
    if type(callback) == "function" then
        local called, callbackError = pcall(callback, ok == true, tostring(reason or ""))
        if not called then
            setActionError(
                noctalia.tr("errors.renderer_callback", { detail = boundedDetail(callbackError) }),
                "renderer"
            )
        end
    end
end

local function failAllRendererPending(reason)
    local nonces = {}
    for nonce in pairs(rendererPending) do
        table.insert(nonces, nonce)
    end
    table.sort(nonces)
    for _, nonce in ipairs(nonces) do
        finishRendererPending(nonce, false, reason)
    end
end

local function resolveRendererAcknowledgements(nextStatus)
    if type(nextStatus) ~= "table" or nextStatus.ready ~= true then
        failAllRendererPending(noctalia.tr("errors.renderer_unavailable"))
        return
    end

    local event = tostring(nextStatus.last_event or "")
    local eventNonce = tonumber(nextStatus.last_event_nonce)
    if event == "started" and type(nextStatus.outputs) == "table" then
        for output, owned in pairs(nextStatus.outputs) do
            local nonce = type(owned) == "table" and tonumber(owned.nonce) or nil
            local pending = nonce ~= nil and rendererPending[nonce] or nil
            if
                type(pending) == "table"
                and tostring(pending.action or ""):match("^start_") ~= nil
                and tostring(pending.output or "") == tostring(output)
            then
                finishRendererPending(nonce, true, "")
            end
        end
        return
    end
    if (event == "stopped" or event == "stopped-all") and eventNonce ~= nil then
        local pending = rendererPending[eventNonce]
        if type(pending) == "table" and tostring(pending.action or "") == "stop" then
            finishRendererPending(eventNonce, true, "")
        end
        return
    end

    local failures = {
        ["error"] = true,
        ["start-error"] = true,
        ["not-running"] = true,
        ["rejected"] = true,
        ["protocol-error"] = true,
        ["startup-error"] = true,
        ["write-error"] = true,
        ["queue-error"] = true,
        ["unavailable"] = true,
        ["heartbeat-timeout"] = true,
    }
    if failures[event] and eventNonce ~= nil then
        finishRendererPending(eventNonce, false, tostring(nextStatus.last_error or event))
    end
end

local function queueRendererStop(output, onAcknowledged)
    output = tostring(output or "")
    if output == "" then
        return false
    end
    if type(rendererStatus) == "table" and rendererStatus.ready == true then
        local queued = sendRendererCommand({ action = "stop", output = output }, function(ok, reason)
            -- A failed/rejected/timed-out stop must not latch ownership
            -- reconciliation forever. A later status/probe can safely retry.
            rendererStopping[output] = nil
            if type(onAcknowledged) == "function" then
                onAcknowledged(ok == true, reason)
            end
        end)
        if queued then
            rendererStopping[output] = true
        end
        return queued == true
    end
    return false
end

invalidateCycleIntent = function(output, stopRenderer)
    output = tostring(output or "")
    if output == "" then
        return
    end
    cycleGeneration[output] = (tonumber(cycleGeneration[output]) or 0) + 1
    applyGeneration[output] = (tonumber(applyGeneration[output]) or 0) + 1
    cycleApplying[output] = nil
    if stopRenderer == true then
        queueRendererStop(output)
    end
end

reconcileRendererOwnership = function()
    local ownedOutputs = type(rendererStatus) == "table"
            and type(rendererStatus.outputs) == "table"
            and rendererStatus.outputs
        or {}
    for output, owned in pairs(ownedOutputs) do
        local backend = type(owned) == "table" and tostring(owned.backend or "") or ""
        local provider = if backend == "w-engine"
            then providers.w_engine
            elseif backend == "mpvpaper" then providers.mpvpaper
            else nil
        local shouldStop = type(provider) ~= "table"
            or knownOutputName(output) == nil
            or provider.allowed ~= true
            or provider.effective_backend ~= "internal"
            or provider.apply_available ~= true
            or provider.conflict == true
        if shouldStop and rendererStopping[output] ~= true then
            invalidateCycleIntent(output, true)
        end
    end
end

local function internalBackendReady(provider)
    local state = providers[provider]
    if type(state) ~= "table" or state.allowed ~= true then
        return false, noctalia.tr("errors.provider_forced_off", { provider = provider })
    elseif state.conflict == true then
        return false, noctalia.tr("errors.internal_conflict", { provider = provider })
    elseif state.effective_backend == "external" then
        return false, noctalia.tr("errors.external_apply_boundary", { provider = provider })
    elseif state.apply_available ~= true or state.effective_backend ~= "internal" then
        return false, noctalia.tr("errors.internal_unavailable", { provider = provider })
    end
    return true, nil
end

local function cachedPair(dynamicId)
    local pair = runtime.pair_registry[tostring(dynamicId)]
    local path = type(pair) == "table" and tostring(pair.still_path or "") or ""
    local info = path ~= "" and noctalia.fileInfo(path) or nil
    if
        type(info) == "table"
        and info.isDir ~= true
        and (tonumber(info.size) or 0) > 0
        and tonumber(pair.still_size) ~= nil
        and tonumber(pair.still_mtime) ~= nil
        and tonumber(pair.still_size) == tonumber(info.size)
        and tonumber(pair.still_mtime) == tonumber(info.mtime)
    then
        return path, tostring(pair.capture_method or "cached-pair")
    end
    return nil, nil
end

local function selectedStaticPair(output, preferredPath)
    local function valid(path)
        path = tostring(path or "")
        local info = path ~= "" and path:sub(1, 1) == "/" and not path:find("[%c]") and noctalia.fileInfo(path) or nil
        if type(info) == "table" and info.isDir ~= true and (tonumber(info.size) or 0) > 0 then
            return path
        end
        return nil
    end

    local preferred = valid(preferredPath)
    if preferred ~= nil then
        return preferred, "selected-static"
    end
    local current = type(runtime.pairs[output]) == "table" and runtime.pairs[output] or nil
    local provider = type(current) == "table" and tostring(current.provider or "") or ""
    if provider == "manual" or provider == "noctalia" then
        local path = valid(current.still_path)
        if path ~= nil then
            return path, "selected-static"
        end
    end
    return nil, nil
end

local function startInternalVideo(output, source, onAcknowledged)
    local ready, reason = internalBackendReady("mpvpaper")
    if not ready then
        setActionError(reason, "mpvpaper-internal")
        return false
    end
    return sendRendererCommand({
        action = "start_mpvpaper",
        output = output,
        path = source,
        mute = settingBool("mpv_mute", true),
        hardware_decode = settingBool("mpv_hardware_decode", true),
        auto_pause = settingBool("mpv_auto_pause", true),
        auto_pause_mode = settingString("mpv_auto_pause_mode", "FULL"),
        options = settingString("mpv_options", ""),
    }, onAcknowledged)
end

local function startInternalWorkshop(output, id, onAcknowledged)
    local ready, reason = internalBackendReady("w_engine")
    if not ready then
        setActionError(reason, "w-engine-internal")
        return false
    end
    if
        settingBool("w_engine_no_fullscreen_pause", false)
        and settingBool("w_engine_fullscreen_pause_only_active", false)
    then
        local reason = noctalia.tr("errors.w_engine_pause_conflict")
        setActionError(reason, "w-engine-internal")
        return false
    end
    return sendRendererCommand({
        action = "start_w_engine",
        output = output,
        workshop_id = id,
        fps = settingInt("w_engine_fps", 30, 5, 144),
        volume = settingInt("w_engine_volume", 0, 0, 100),
        scaling = settingString("w_engine_scaling", "fill"),
        clamp = settingString("w_engine_clamp", "border"),
        silent = settingBool("w_engine_silent", true),
        noautomute = settingBool("w_engine_noautomute", false),
        no_audio_processing = settingBool("w_engine_no_audio_processing", false),
        disable_particles = settingBool("w_engine_disable_particles", false),
        disable_mouse = settingBool("w_engine_disable_mouse", false),
        disable_parallax = settingBool("w_engine_disable_parallax", false),
        no_fullscreen_pause = settingBool("w_engine_no_fullscreen_pause", false),
        fullscreen_pause_only_active = settingBool("w_engine_fullscreen_pause_only_active", false),
    }, onAcknowledged)
end

local function applyVideoWithPair(output, source, notifySuccess, onComplete, shouldStart, preferredStillPath)
    output = targetOutput(output)
    if output == nil then
        setActionError(noctalia.tr("availability.output"), "video-apply")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local ready, reason = internalBackendReady("mpvpaper")
    if not ready then
        setActionError(reason, "video-apply")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local backendToken = backendGeneration.mpvpaper
    local parentShouldStart = shouldStart
    shouldStart = function()
        return backendGeneration.mpvpaper == backendToken
            and knownOutputName(output) ~= nil
            and (type(parentShouldStart) ~= "function" or parentShouldStart() == true)
    end
    local dynamicId = "video:" .. tostring(source or "")
    local pairPath, method = selectedStaticPair(output, preferredStillPath)
    if pairPath == nil then
        pairPath, method = cachedPair(dynamicId)
    end
    local function startAfterPair(ok, path, errorMessage)
        if ok ~= true or shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, path, errorMessage)
            end
            return
        end
        local queued = startInternalVideo(output, source, function(started, startError)
            if started ~= true then
                local failure = tostring(startError or noctalia.tr("errors.renderer_unavailable"))
                setActionError(failure, if notifySuccess then "renderer" else nil)
            end
            if type(onComplete) == "function" then
                onComplete(started == true, path, startError)
            end
        end)
        if not queued and type(onComplete) == "function" then
            onComplete(false, path)
        end
    end
    if pairPath ~= nil then
        if type(shouldStart) == "function" and shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, pairPath)
            end
            return
        end
        applyPairedStill(output, dynamicId, pairPath, method, notifySuccess == true)
        startAfterPair(true, pairPath)
    else
        captureVideoPath(output, source, false, true, notifySuccess, startAfterPair, shouldStart)
    end
end

local function applyWorkshopWithPair(output, id, notifySuccess, onComplete, shouldStart, preferredStillPath)
    output = targetOutput(output)
    id = tostring(id or "")
    if output == nil or id:match("^%d+$") == nil then
        setActionError(noctalia.tr("errors.no_current_scene"), "workshop-apply")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local ready, reason = internalBackendReady("w_engine")
    if not ready then
        setActionError(reason, "workshop-apply")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local backendToken = backendGeneration.w_engine
    local parentShouldStart = shouldStart
    shouldStart = function()
        return backendGeneration.w_engine == backendToken
            and knownOutputName(output) ~= nil
            and (type(parentShouldStart) ~= "function" or parentShouldStart() == true)
    end
    local pairPath, method = selectedStaticPair(output, preferredStillPath)
    if pairPath == nil then
        pairPath, method = cachedPair(id)
    end
    local function startAfterPair(ok, path, errorMessage)
        if ok ~= true or shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, path, errorMessage)
            end
            return
        end
        local queued = startInternalWorkshop(output, id, function(started, startError)
            if started ~= true then
                local failure = tostring(startError or noctalia.tr("errors.renderer_unavailable"))
                setActionError(failure, if notifySuccess then "renderer" else nil)
            end
            if type(onComplete) == "function" then
                onComplete(started == true, path, startError)
            end
        end)
        if not queued and type(onComplete) == "function" then
            onComplete(false, path)
        end
    end
    if pairPath ~= nil then
        if type(shouldStart) == "function" and shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, pairPath)
            end
            return
        end
        applyPairedStill(output, id, pairPath, method, notifySuccess == true)
        startAfterPair(true, pairPath)
    else
        captureWorkshopFallback(output, id, false, true, notifySuccess, startAfterPair, shouldStart)
    end
end

local function saveReelConfig(reels)
    local normalized = normalizedReels(reels)
    if normalized == nil then
        setActionError(noctalia.tr("errors.config_reels"), "cycle-config")
        return false
    end
    local nextConfig = {
        schema_version = CONFIG_SCHEMA,
        gestures = cloneGestures(config.gestures),
        reels = normalized,
    }
    local saved, saveError = atomicWrite("config.json", nextConfig)
    if not saved then
        configValid = false
        configError = tostring(saveError or noctalia.tr("errors.config_save"))
        setActionError(configError, "cycle-config")
        return false
    end
    config = nextConfig
    configValid = true
    configError = ""
    publishStatus()
    return true
end

local function reelForOutput(output, create)
    output = targetOutput(output)
    if output == nil then
        return nil, nil
    end
    local reel = config.reels[output]
    if type(reel) ~= "table" and create then
        reel = {
            interval_seconds = configuredCycleSeconds(),
            order = configuredCycleOrder(),
            entries = {},
        }
        config.reels[output] = reel
    end
    return reel, output
end

local function addReelEntry(output, rawEntry)
    local entry = normalizedEntry(rawEntry)
    if entry == nil then
        setActionError(noctalia.tr("errors.cycle_entry"), "cycle-add")
        return false
    end
    local reels = normalizedReels(config.reels) or {}
    local reel, selected = reelForOutput(output, true)
    if reel == nil or selected == nil then
        setActionError(noctalia.tr("availability.output"), "cycle-add")
        return false
    end
    if (entry.kind == "video" or entry.kind == "workshop") and entry.still_path == "" then
        local currentPair = type(runtime.pairs[selected]) == "table" and runtime.pairs[selected] or runtime.pairs.all
        local currentPath = type(currentPair) == "table" and tostring(currentPair.still_path or "") or ""
        local currentInfo = currentPath ~= "" and noctalia.fileInfo(currentPath) or nil
        if
            currentPath:sub(1, 1) == "/"
            and not currentPath:find("[%c]")
            and type(currentInfo) == "table"
            and currentInfo.isDir ~= true
            and (tonumber(currentInfo.size) or 0) > 0
        then
            entry.still_path = currentPath
        end
    end
    -- reelForOutput touched config; operate on a clean clone for atomic save.
    reel = reels[selected]
    if type(reel) ~= "table" then
        reel = {
            interval_seconds = configuredCycleSeconds(),
            order = configuredCycleOrder(),
            entries = {},
        }
        reels[selected] = reel
    end
    for index, existing in ipairs(reel.entries) do
        if existing.kind == entry.kind and existing.source == entry.source then
            reel.entries[index] = entry
            return saveReelConfig(reels)
        end
    end
    if #reel.entries >= MAX_REEL_ENTRIES then
        setActionError(noctalia.tr("errors.cycle_limit", { limit = tostring(MAX_REEL_ENTRIES) }), "cycle-add")
        return false
    end
    table.insert(reel.entries, entry)
    return saveReelConfig(reels)
end

local function removeReelEntry(output, requestedIndex)
    local reels = normalizedReels(config.reels) or {}
    local _, selected = reelForOutput(output, false)
    local reel = selected ~= nil and reels[selected] or nil
    if type(reel) ~= "table" or #reel.entries == 0 then
        setActionError(noctalia.tr("errors.cycle_empty"), "cycle-remove")
        return false
    end
    local index = math.floor(tonumber(requestedIndex) or #reel.entries)
    if index < 1 or index > #reel.entries then
        setActionError(noctalia.tr("errors.cycle_index"), "cycle-remove")
        return false
    end
    invalidateCycleIntent(selected, false)
    table.remove(reel.entries, index)
    local state = runtime.cycles[selected]
    if type(state) == "table" then
        state.cursor = math.min(math.floor(tonumber(state.cursor) or 0), #reel.entries)
        state.history = {}
        state.bag = {}
        if #reel.entries == 0 then
            state.running = false
            state.paused = false
            state.next_due = 0
            invalidateCycleIntent(selected, true)
        end
    end
    local saved = saveReelConfig(reels)
    persistRuntimeIfChanged(true)
    return saved
end

local function clearReel(output)
    local reels = normalizedReels(config.reels) or {}
    local _, selected = reelForOutput(output, false)
    if selected == nil then
        setActionError(noctalia.tr("availability.output"), "cycle-clear")
        return false
    end
    invalidateCycleIntent(selected, true)
    reels[selected] = {
        interval_seconds = configuredCycleSeconds(),
        order = configuredCycleOrder(),
        entries = {},
    }
    runtime.cycles[selected] = {
        running = false,
        paused = false,
        cursor = 0,
        next_due = 0,
        history = {},
        bag = {},
        last_error = "",
    }
    local saved = saveReelConfig(reels)
    persistRuntimeIfChanged(true)
    return saved
end

local function setReelOptions(output, intervalSeconds, order)
    local reels = normalizedReels(config.reels) or {}
    local _, selected = reelForOutput(output, true)
    if selected == nil then
        setActionError(noctalia.tr("availability.output"), "cycle-options")
        return false
    end
    local reel = reels[selected]
    if type(reel) ~= "table" then
        reel = { entries = {} }
        reels[selected] = reel
    end
    local interval = math.floor(tonumber(intervalSeconds) or configuredCycleSeconds())
    reel.interval_seconds = math.max(MIN_CYCLE_SECONDS, math.min(MAX_CYCLE_SECONDS, interval))
    order = tostring(order or reel.order or configuredCycleOrder())
    reel.order = if VALID_CYCLE_ORDERS[order] then order else configuredCycleOrder()
    local state = runtime.cycles[selected]
    if type(state) == "table" and state.running == true then
        state.next_due = nowSeconds() + reel.interval_seconds
        state.bag = {}
    end
    local saved = saveReelConfig(reels)
    persistRuntimeIfChanged(true)
    return saved
end

local function cycleState(output)
    local state = runtime.cycles[output]
    if type(state) ~= "table" then
        state = {}
        runtime.cycles[output] = state
    end
    state.running = state.running == true
    state.paused = state.paused == true
    state.cursor = math.max(0, math.floor(tonumber(state.cursor) or 0))
    state.next_due = math.max(0, math.floor(tonumber(state.next_due) or 0))
    state.history = type(state.history) == "table" and state.history or {}
    state.bag = type(state.bag) == "table" and state.bag or {}
    state.last_error = tostring(state.last_error or "")
    return state
end

local function shuffledIndices(count, seed)
    local values = {}
    for index = 1, count do
        table.insert(values, index)
    end
    seed = math.max(1, math.floor(tonumber(seed) or 1) % 2147483647)
    for index = count, 2, -1 do
        seed = (seed * 48271) % 2147483647
        local selected = (seed % index) + 1
        values[index], values[selected] = values[selected], values[index]
    end
    return values
end

local function selectCycleIndex(reel, state, direction)
    local count = #reel.entries
    if count == 0 then
        return nil
    end
    if direction == "previous" then
        if #state.history > 1 then
            table.remove(state.history)
            return math.max(1, math.min(count, math.floor(tonumber(state.history[#state.history]) or 1)))
        end
        return ((math.max(1, state.cursor) - 2) % count) + 1
    elseif direction == "random" or reel.order == "random" then
        local seed = noctalia.nowMs() + (state.cursor * 7919) + #state.history
        return (math.floor(seed) % count) + 1
    elseif reel.order == "shuffle" then
        if #state.bag == 0 then
            state.bag = shuffledIndices(count, noctalia.nowMs() + state.cursor)
            if count > 1 and state.bag[1] == state.cursor then
                state.bag[1], state.bag[2] = state.bag[2], state.bag[1]
            end
        end
        return math.floor(tonumber(table.remove(state.bag, 1)) or 1)
    end
    return (state.cursor % count) + 1
end

local function applyCycleEntry(output, entry, onComplete, shouldStart, notifySuccess)
    local parentShouldStart = shouldStart
    local applyToken = (tonumber(applyGeneration[output]) or 0) + 1
    applyGeneration[output] = applyToken
    shouldStart = function()
        if tonumber(applyGeneration[output]) ~= applyToken then
            return false
        end
        return knownOutputName(output) ~= nil and (type(parentShouldStart) ~= "function" or parentShouldStart() == true)
    end
    if shouldStart() ~= true then
        onComplete(false)
        return
    end
    if entry.kind == "static" then
        local info = noctalia.fileInfo(entry.source)
        if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) <= 0 then
            setActionError(noctalia.tr("errors.cycle_static_missing", { path = entry.source }), "cycle-static")
            onComplete(false)
            return
        end
        local function applyStatic(stopped)
            if stopped ~= true or (type(shouldStart) == "function" and shouldStart() ~= true) then
                onComplete(false)
                return
            end
            applyPairedStill(output, "static:" .. entry.source, entry.source, "cycle-static", false)
            onComplete(true, entry.source)
        end
        local queued = queueRendererStop(output, function(stopped)
            applyStatic(stopped == true)
        end)
        if not queued then
            applyStatic(true)
        end
    elseif entry.kind == "video" then
        applyVideoWithPair(output, entry.source, notifySuccess == true, onComplete, shouldStart, entry.still_path)
    elseif entry.kind == "workshop" then
        applyWorkshopWithPair(output, entry.source, notifySuccess == true, onComplete, shouldStart, entry.still_path)
    else
        setActionError(noctalia.tr("errors.cycle_entry"), "cycle-entry")
        onComplete(false)
    end
end

local function applyManualEntry(output, entry, notifySuccess)
    output = targetOutput(output)
    entry = normalizedEntry(entry)
    if output == nil or entry == nil then
        setActionError(noctalia.tr("errors.cycle_entry"), "apply-entry")
        return
    end
    -- A manual selection supersedes every asynchronous cycle/static intent
    -- already in flight on this output. The next scheduler tick may take over
    -- again if the cycle remains running, but stale callbacks cannot do so.
    invalidateCycleIntent(output, false)
    applyCycleEntry(output, entry, function(_ok) end, nil, notifySuccess == true)
end

local advanceCycle

advanceCycle = function(output, direction)
    local reel, selected = reelForOutput(output, false)
    if selected == nil or type(reel) ~= "table" or #reel.entries == 0 then
        setActionError(noctalia.tr("errors.cycle_empty"), "cycle")
        return false
    end
    if cycleApplying[selected] then
        return false
    end
    local state = cycleState(selected)
    if state.paused == true then
        setActionError(noctalia.tr("errors.cycle_paused"), "cycle")
        return false
    end
    local index = selectCycleIndex(reel, state, direction or "next")
    if index == nil then
        return false
    end
    state.cursor = index
    if direction ~= "previous" then
        table.insert(state.history, index)
        while #state.history > 64 do
            table.remove(state.history, 1)
        end
    end
    state.last_entry = normalizedEntry(reel.entries[index])
    state.last_applied_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    state.last_error = ""
    local generation = (tonumber(cycleGeneration[selected]) or 0) + 1
    cycleGeneration[selected] = generation
    cycleApplying[selected] = generation
    local expectsRunning = state.running == true
    local function shouldStart()
        if tonumber(cycleGeneration[selected]) ~= generation then
            return false
        end
        local current = cycleState(selected)
        if current.paused == true then
            return false
        end
        return not expectsRunning or current.running == true
    end
    persistRuntimeIfChanged(true)
    publishStatus()
    applyCycleEntry(selected, reel.entries[index], function(ok, _path, applyError)
        if tonumber(cycleGeneration[selected]) ~= generation then
            return
        end
        cycleApplying[selected] = nil
        local current = cycleState(selected)
        current.last_error = if ok == true
            then ""
            else tostring(applyError or lastActionError or noctalia.tr("errors.cycle_apply"))
        current.next_due = nowSeconds() + math.max(MIN_CYCLE_SECONDS, tonumber(reel.interval_seconds) or 900)
        persistRuntimeIfChanged(true)
        publishStatus()
    end, shouldStart)
    return true
end

local function setCycleRunState(output, action)
    local reel, selected = reelForOutput(output, false)
    if selected == nil or type(reel) ~= "table" or #reel.entries == 0 then
        setActionError(noctalia.tr("errors.cycle_empty"), "cycle")
        return
    end
    local state = cycleState(selected)
    if action == "start" then
        invalidateCycleIntent(selected, false)
        state.running = true
        state.paused = false
        state.next_due = nowSeconds()
        persistRuntimeIfChanged(true)
        advanceCycle(selected, "next")
        return
    elseif action == "stop" then
        invalidateCycleIntent(selected, true)
        state.running = false
        state.paused = false
        state.next_due = 0
    elseif action == "pause" then
        invalidateCycleIntent(selected, false)
        state.paused = true
        local owned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs[selected] or nil
        if type(owned) == "table" and tostring(owned.state or "") == "running" then
            sendRendererCommand({ action = "pause", output = selected })
        end
    elseif action == "resume" then
        state.running = true
        state.paused = false
        local owned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs[selected] or nil
        if type(owned) == "table" and tostring(owned.state or "") == "paused" then
            sendRendererCommand({ action = "resume", output = selected })
            state.next_due = nowSeconds() + math.max(MIN_CYCLE_SECONDS, tonumber(reel.interval_seconds) or 900)
        else
            state.next_due = nowSeconds()
        end
    end
    persistRuntimeIfChanged(true)
    publishStatus()
    if action == "resume" and (tonumber(state.next_due) or 0) <= nowSeconds() then
        advanceCycle(selected, "next")
    end
end

local function addCurrentStaticToCycle(output)
    output = targetOutput(output)
    if output == nil or not providers.noctalia_cli then
        setActionError(noctalia.tr("availability.backing"), "cycle-add-static")
        return
    end
    local command = "noctalia msg wallpaper-get " .. shellQuote(output)
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            setActionError(
                noctalia.tr("errors.backing_query", { detail = commandFailureDetail(result) }),
                "cycle-add-static"
            )
            return
        end
        local source = noctalia.string.trim(tostring(result.stdout or ""))
        local info = source ~= "" and noctalia.fileInfo(source) or nil
        if source:sub(1, 1) ~= "/" or source:find("[%c]") or type(info) ~= "table" or info.isDir == true then
            setActionError(noctalia.tr("errors.backing_source"), "cycle-add-static")
            return
        end
        addReelEntry(output, {
            kind = "static",
            source = source,
            label = source:match("([^/]+)$") or source,
            added_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        })
    end, 5000)
    if not started then
        setActionError(noctalia.tr("errors.backing_query_start"), "cycle-add-static")
    end
end

local function captureCurrentBacking(output, force, notifySuccess)
    output = targetOutput(output)
    if output == nil then
        setActionError(noctalia.tr("availability.output"), "capture-backing")
        return
    end
    if not providers.noctalia_cli then
        setActionError(noctalia.tr("availability.native_cli"), "capture-backing")
        return
    end

    local command = "noctalia msg wallpaper-get " .. shellQuote(output)
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            setActionError(
                noctalia.tr("errors.backing_query", { detail = commandFailureDetail(result) }),
                "capture-backing"
            )
            return
        end

        local source = noctalia.string.trim(tostring(result.stdout or ""))
        local info = source ~= "" and noctalia.fileInfo(source) or nil
        local extension = fileExtension(source)
        local supported = extension == ".png"
            or extension == ".jpg"
            or extension == ".jpeg"
            or extension == ".webp"
            or extension == ".avif"
            or extension == ".gif"
        if
            source:sub(1, 1) ~= "/"
            or source:find("[%c]") ~= nil
            or type(info) ~= "table"
            or info.isDir == true
            or (tonumber(info.size) or 0) <= 0
            or not supported
        then
            setActionError(noctalia.tr("errors.backing_source"), "capture-backing")
            return
        end

        local mode = "copy"
        local destinationExtension = extension
        local method = "noctalia-current-backing"
        if extension == ".gif" and noctalia.commandExists("ffmpeg") then
            mode = "image"
            destinationExtension = ".png"
            method = "noctalia-current-backing-frame"
        end
        local identity = table.concat({
            sanitizedName(source:match("([^/]+)$") or "backing"),
            tostring(tonumber(info.size) or 0),
            tostring(tonumber(info.mtime) or 0),
        }, "-")
        local destination, destinationError = captureDestination("backing", identity, output, destinationExtension)
        if destination == nil then
            setActionError(destinationError, "capture-directory")
            return
        end
        runCapture({
            provider = "noctalia",
            output = output,
            dynamic_id = "backing:" .. source,
            spec = {
                mode = mode,
                source = source,
                value = "",
                method = method,
            },
            destination = destination,
            force = force == true,
            pair = false,
            notify = notifySuccess == true,
        })
    end, 5000)
    if not started then
        setActionError(noctalia.tr("errors.backing_query_start"), "capture-backing")
    end
end

local function pairConfiguredStill(output, notifySuccess)
    output = targetOutput(output)
    if output == nil then
        setActionError(noctalia.tr("availability.output"), "manual-pair")
        return
    end
    local source = configuredManualPair()
    local info = source ~= "" and noctalia.fileInfo(source) or nil
    local extension = fileExtension(source)
    local supported = extension == ".png"
        or extension == ".jpg"
        or extension == ".jpeg"
        or extension == ".webp"
        or (extension == ".avif" and noctalia.commandExists("ffmpeg"))
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
    invalidateCycleIntent(output, false)
    local pairToken = tonumber(applyGeneration[output]) or 0
    local destination
    local pairPath
    local stagingPath
    local destinationError
    if extension == ".gif" then
        local identity = table.concat({
            stablePathTag(source),
            tostring(tonumber(info.size) or 0),
            tostring(tonumber(info.mtime) or 0),
            sanitizedName(source:match("([^/]+)$") or "manual"),
        }, "-")
        destination, destinationError = captureDestination("manual", identity, output, ".png")
    else
        captureSequence += 1
        destination, destinationError = adapterStagingPath(
            "manual-" .. SERVICE_NONCE .. "-" .. tostring(noctalia.nowMs()) .. "-" .. tostring(captureSequence)
        )
        stagingPath = destination
        pairPath = source
    end
    if destination == nil then
        setActionError(destinationError, "capture-directory")
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
        destination = destination,
        staging_path = stagingPath,
        pair_path = pairPath,
        force = true,
        pair = true,
        notify = notifySuccess == true,
        should_apply = function()
            return tonumber(applyGeneration[output]) == pairToken and knownOutputName(output) ~= nil
        end,
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
    if action == "motionbgs_open" then
        return providers.motionbgs.available, noctalia.tr("availability.motionbgs")
    end
    if action == "w_engine_open" then
        return providers.w_engine.available, noctalia.tr("availability.w_engine")
    end
    if W_ENGINE_VERBS[action] ~= nil then
        return providers.w_engine.available and providers.noctalia_cli, noctalia.tr("availability.w_engine_ipc")
    end
    if action == "mpvpaper_open" then
        return providers.mpvpaper.available, noctalia.tr("availability.mpvpaper")
    end
    if MPVPAPER_VERBS[action] ~= nil then
        if action == "mpvpaper_clear" and targetOutput(output) == nil then
            return false, noctalia.tr("availability.output")
        end
        return providers.mpvpaper.available and providers.noctalia_cli, noctalia.tr("availability.mpvpaper_ipc")
    end
    if action == "capture_backing" then
        return providers.noctalia_cli and targetOutput(output) ~= nil, noctalia.tr("availability.backing")
    end
    if action == "capture_current" or action == "capture_pair" then
        if not providers.w_engine.allowed then
            return false, noctalia.tr("availability.w_engine_forced_off")
        end
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
    if action == "video_apply_pair" then
        local source = configuredVideoSource()
        return providers.mpvpaper.apply_available == true and source ~= "" and noctalia.fileExists(source),
            noctalia.tr("availability.video_apply")
    end
    if action == "workshop_apply_pair" then
        return providers.w_engine.apply_available == true and configuredWorkshopId() ~= "",
            noctalia.tr("availability.workshop_apply")
    end
    if action == "cycle_add_static" then
        return providers.noctalia_cli and targetOutput(output) ~= nil, noctalia.tr("availability.backing")
    end
    if action == "cycle_add_video" then
        local source = configuredVideoSource()
        return source ~= "" and noctalia.fileExists(source), noctalia.tr("availability.video")
    end
    if action == "cycle_add_workshop" then
        return configuredWorkshopId() ~= "", noctalia.tr("availability.current_scene")
    end
    if action == "cycle_remove_last" or action == "cycle_clear" then
        local reel = reelForOutput(output, false)
        return type(reel) == "table" and #reel.entries > 0, noctalia.tr("availability.cycle")
    end
    if
        action == "cycle_start"
        or action == "cycle_stop"
        or action == "cycle_pause"
        or action == "cycle_resume"
        or action == "cycle_next"
        or action == "cycle_previous"
        or action == "cycle_random"
    then
        local reel = reelForOutput(output, false)
        if action == "cycle_next" or action == "cycle_previous" or action == "cycle_random" then
            local selected = targetOutput(output)
            local state = selected ~= nil and runtime.cycles[selected] or nil
            if type(state) == "table" and state.paused == true then
                return false, noctalia.tr("errors.cycle_paused")
            end
        end
        return type(reel) == "table" and #reel.entries > 0, noctalia.tr("availability.cycle")
    end
    if action == "manual_pair" then
        local source = configuredManualPair()
        local info = source ~= "" and noctalia.fileInfo(source) or nil
        local extension = fileExtension(source)
        local supported = extension == ".png"
            or extension == ".jpg"
            or extension == ".jpeg"
            or extension == ".webp"
            or (extension == ".avif" and noctalia.commandExists("ffmpeg"))
            or (extension == ".gif" and noctalia.commandExists("ffmpeg"))
        return targetOutput(output) ~= nil
            and type(info) == "table"
            and info.isDir ~= true
            and (tonumber(info.size) or 0) > 0
            and supported,
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

local function openMotionBgs()
    local started = noctalia.runAsync("xdg-open " .. shellQuote(MOTIONBGS_URL), function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            setActionError(noctalia.tr("errors.motionbgs_open", { detail = commandFailureDetail(result) }), "motionbgs")
        end
    end, 5000)
    if not started then
        setActionError(noctalia.tr("errors.motionbgs_start"), "motionbgs")
    end
end

local function nextMotionBgsNonce()
    local previous = noctalia.state.get(MOTIONBGS_COMMAND_KEY)
    local previousNonce = if type(previous) == "table" then tonumber(previous.nonce) or 0 else 0
    local statusNonce = if type(motionBgsStatus) == "table" then tonumber(motionBgsStatus.last_nonce) or 0 else 0
    motionBgsCommandSequence = math.max(motionBgsCommandSequence, previousNonce, statusNonce) + 1
    return motionBgsCommandSequence
end

local function sendMotionBgsCommand(request, action)
    if not configValid or not runtimeValid then
        setActionError(noctalia.tr("errors.storage_disabled"), "storage")
        return false
    end
    if not settingBool("use_motionbgs", true) or providers.motionbgs.integration_available ~= true then
        setActionError(noctalia.tr("errors.motionbgs_unavailable"), "motionbgs")
        return false
    end
    local command = {
        schema = 1,
        nonce = nextMotionBgsNonce(),
        action = tostring(action or ""),
    }
    if action == "search" then
        command.query = tostring(request.query or "")
        command.limit = settingInt("motionbgs_result_limit", 24, 1, 24)
        command.force = request.force == true
    elseif action == "details" then
        command.slug = tostring(request.slug or "")
        command.force = request.force == true
    elseif action == "download" then
        command.slug = tostring(request.slug or "")
        command.quality = if tostring(request.quality or settingString("motionbgs_quality", "hd")) == "4k"
            then "4k"
            else "hd"
        command.force = request.force == true
    elseif action ~= "clear" then
        setActionError(noctalia.tr("errors.motionbgs_action"), "motionbgs")
        return false
    end
    noctalia.state.set(MOTIONBGS_COMMAND_KEY, command)
    lastActionError = ""
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishStatus()
    return true
end

local function runWEngineControl(request, action)
    if not providers.w_engine.available then
        setActionError(noctalia.tr("errors.w_engine_forced_off"), action)
        return
    end
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
    if not providers.mpvpaper.available then
        setActionError(noctalia.tr("errors.mpvpaper_forced_off"), action)
        return
    end
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
    -- The explicit site link is the scraper's disaster-recovery path. Keep it
    -- independent of plugin storage and the adapter enable switch.
    if action == "motionbgs_open" then
        local available, unavailableReason = actionAvailability(action, request.output)
        if available then
            openMotionBgs()
        else
            setActionError(unavailableReason, "motionbgs")
        end
        return
    end
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
    elseif action == "capture_backing" then
        captureCurrentBacking(request.output, true, true)
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
    elseif action == "video_apply_pair" then
        applyManualEntry(request.output, { kind = "video", source = configuredVideoSource() }, true)
        return
    elseif action == "workshop_apply_pair" then
        applyManualEntry(request.output, { kind = "workshop", source = configuredWorkshopId() }, true)
        return
    elseif action == "cycle_add_static" then
        addCurrentStaticToCycle(request.output)
        return
    elseif action == "cycle_add_video" then
        local source = configuredVideoSource()
        addReelEntry(request.output, {
            kind = "video",
            source = source,
            label = source:match("([^/]+)$") or source,
            added_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        })
        return
    elseif action == "cycle_add_workshop" then
        local id = configuredWorkshopId()
        addReelEntry(request.output, {
            kind = "workshop",
            source = id,
            label = "Workshop " .. id,
            added_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        })
        return
    elseif action == "cycle_remove_last" then
        removeReelEntry(request.output, nil)
        return
    elseif action == "cycle_clear" then
        clearReel(request.output)
        return
    elseif action == "cycle_start" then
        setCycleRunState(request.output, "start")
        return
    elseif action == "cycle_stop" then
        setCycleRunState(request.output, "stop")
        return
    elseif action == "cycle_pause" then
        setCycleRunState(request.output, "pause")
        return
    elseif action == "cycle_resume" then
        setCycleRunState(request.output, "resume")
        return
    elseif action == "cycle_next" or action == "cycle_previous" or action == "cycle_random" then
        local direction = action:gsub("^cycle_", "")
        advanceCycle(request.output, direction)
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
    local nextConfig = {
        schema_version = CONFIG_SCHEMA,
        gestures = cloneGestures(config.gestures),
        reels = normalizedReels(config.reels) or {},
    }
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
    if fields[1] ~= "w_engine" or fields[2] ~= "1" or not providers.w_engine.available then
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
    if fields[1] ~= "w_engine" or not providers.w_engine.available or not providers.w_engine.adapter_status then
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
    if not providers.w_engine.allowed then
        finishCapture(key, request, false, noctalia.tr("errors.w_engine_forced_off"))
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
    if (not configValid or not runtimeValid) and kind ~= "action" and kind ~= "gesture" and kind ~= "probe" then
        setActionError(noctalia.tr("errors.storage_disabled"), "storage")
        return
    end
    if kind == "gesture" then
        local gestures = type(config.gestures) == "table" and config.gestures or {}
        dispatchAction(request, tostring(gestures[tostring(request.button or "")] or ""))
    elseif kind == "action" then
        dispatchAction(request, tostring(request.action or ""))
    elseif kind == "set_mapping" then
        setMapping(tostring(request.button or ""), tostring(request.action or ""))
    elseif kind == "cycle_add_entry" then
        addReelEntry(request.output, request.entry)
    elseif kind == "cycle_remove_entry" then
        removeReelEntry(request.output, request.index)
    elseif kind == "cycle_options" then
        setReelOptions(request.output, request.interval_seconds, request.order)
    elseif kind == "apply_entry" then
        applyManualEntry(request.output, request.entry, true)
    elseif kind == "motionbgs_search" then
        sendMotionBgsCommand(request, "search")
    elseif kind == "motionbgs_details" then
        sendMotionBgsCommand(request, "details")
    elseif kind == "motionbgs_download" then
        sendMotionBgsCommand(request, "download")
    elseif kind == "motionbgs_clear" then
        sendMotionBgsCommand(request, "clear")
    elseif kind == "library_refresh" then
        refreshLibrary()
        publishStatus()
    elseif kind == "probe" then
        probeProviders()
    end
end

function update()
    noctalia.setUpdateInterval(UPDATE_INTERVAL_MS)
    local now = nowSeconds()
    if stepLibraryScan() then
        publishStatus()
    end
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
    local timedOutRendererCommands = {}
    for nonce, pending in pairs(rendererPending) do
        if (tonumber(pending.deadline) or 0) > 0 and now > tonumber(pending.deadline) then
            table.insert(timedOutRendererCommands, nonce)
        end
    end
    for _, nonce in ipairs(timedOutRendererCommands) do
        local timeoutError = noctalia.tr("errors.renderer_ack_timeout")
        setActionError(timeoutError, "renderer")
        finishRendererPending(nonce, false, timeoutError)
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
    for output, value in pairs(runtime.cycles) do
        local state = type(value) == "table" and cycleState(output) or nil
        if
            type(state) == "table"
            and state.running == true
            and state.paused ~= true
            and knownOutputName(output) ~= nil
            and not cycleApplying[output]
            and (tonumber(state.next_due) or 0) <= now
        then
            advanceCycle(output, "next")
        end
    end
end

function onConfigChanged()
    local applyingOutputs = {}
    for output in pairs(cycleApplying) do
        applyingOutputs[output] = true
    end
    for output in pairs(applyGeneration) do
        applyingOutputs[output] = true
    end
    for output in pairs(applyingOutputs) do
        invalidateCycleIntent(output, false)
    end
    applyIntegrationPolicy()
    reconcileRendererOwnership()
    refreshExtraProvider({})
    providerSignature = ""
    probeProviders()
    probeColorScheme()
    refreshLibrary()
    publishStatus()
end

function onOutputsChanged()
    local owned = type(rendererStatus) == "table" and type(rendererStatus.outputs) == "table" and rendererStatus.outputs
        or {}
    for output in pairs(owned) do
        if knownOutputName(output) == nil then
            invalidateCycleIntent(output, true)
        end
    end
    local candidates = {}
    for output in pairs(cycleApplying) do
        candidates[output] = true
    end
    for output in pairs(captureInFlight) do
        candidates[output] = true
    end
    for output in pairs(runtime.cycles) do
        candidates[output] = true
    end
    for output in pairs(applyGeneration) do
        candidates[output] = true
    end
    for output in pairs(candidates) do
        if output ~= "all" and knownOutputName(output) == nil then
            invalidateCycleIntent(output, false)
        end
    end
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
    elseif event == "capture-backing" then
        captureCurrentBacking(output, true, true)
    elseif event == "capture-pair" then
        captureCurrent(output, true, true, true)
    elseif event == "capture-video" then
        captureConfiguredVideo(output, true, false, true)
    elseif event == "capture-video-pair" then
        captureConfiguredVideo(output, true, true, true)
    elseif event == "apply-video-pair" then
        applyManualEntry(output, { kind = "video", source = configuredVideoSource() }, true)
    elseif event == "apply-workshop-pair" then
        applyManualEntry(output, { kind = "workshop", source = configuredWorkshopId() }, true)
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
    elseif event == "motionbgs-open" then
        dispatchAction({ producer = "ipc", output = output }, "motionbgs_open")
    elseif event == "cycle-start" or event == "cycle-stop" or event == "cycle-pause" or event == "cycle-resume" then
        local action = event:gsub("%-", "_")
        dispatchAction({ producer = "ipc", output = output }, action)
    elseif event == "cycle-next" or event == "cycle-previous" or event == "cycle-random" then
        local action = event:gsub("%-", "_")
        dispatchAction({ producer = "ipc", output = output }, action)
    elseif event == "open-provider" then
        local aliases = {
            native = "native_open",
            wallhaven = "wallhaven_open",
            motionbgs = "motionbgs_open",
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

cleanupOwnedStaging()
loadStorage()
local initialRendererStatus = noctalia.state.get(RENDERER_STATUS_KEY)
if type(initialRendererStatus) == "table" then
    rendererStatus = initialRendererStatus
end
local initialMotionBgsStatus = noctalia.state.get(MOTIONBGS_STATUS_KEY)
if type(initialMotionBgsStatus) == "table" then
    motionBgsStatus = initialMotionBgsStatus
    lastMotionDownloadPath = type(initialMotionBgsStatus.last_download) == "table"
            and tostring(initialMotionBgsStatus.last_download.path or "")
        or ""
end
local initialMotionBgsResults = noctalia.state.get(MOTIONBGS_RESULTS_KEY)
if type(initialMotionBgsResults) == "table" then
    motionBgsResults = initialMotionBgsResults
end
refreshBackendPolicy()
refreshLibrary()
if settingBool("cycle_start_on_load", false) then
    for output, reel in pairs(config.reels) do
        if type(reel) == "table" and type(reel.entries) == "table" and #reel.entries > 0 then
            local state = cycleState(output)
            state.running = true
            state.paused = false
            state.next_due = nowSeconds()
        end
    end
    persistRuntimeIfChanged(true)
else
    -- Persisted runtime describes the last session, not permission to resume
    -- playback. Unless explicitly opted in, every reload starts disarmed.
    for output, value in pairs(runtime.cycles) do
        if type(value) == "table" then
            local state = cycleState(output)
            state.running = false
            state.paused = false
            state.next_due = 0
        end
    end
    persistRuntimeIfChanged(true)
end
local previousAck = noctalia.state.get(COMMAND_ACK_KEY)
if type(previousAck) == "table" then
    lastCommandSequence = tonumber(previousAck.sequence) or 0
end
noctalia.state.watch(COMMAND_KEY, handleCommand)
noctalia.state.watch(RENDERER_STATUS_KEY, function(nextStatus)
    local wasReady = type(rendererStatus) == "table" and rendererStatus.ready == true
    local previousOutputs = type(rendererStatus) == "table"
            and type(rendererStatus.outputs) == "table"
            and rendererStatus.outputs
        or {}
    if type(nextStatus) == "table" then
        rendererStatus = nextStatus
    else
        rendererStatus = { ready = false, outputs = {}, last_error = noctalia.tr("errors.renderer_unavailable") }
    end
    resolveRendererAcknowledgements(rendererStatus)
    refreshBackendPolicy()
    reconcileRendererOwnership()
    local nextOutputs = type(rendererStatus.outputs) == "table" and rendererStatus.outputs or {}
    for output in pairs(rendererStopping) do
        if type(nextOutputs[output]) ~= "table" then
            rendererStopping[output] = nil
        end
    end
    if not wasReady and rendererStatus.ready == true then
        for output, value in pairs(runtime.cycles) do
            local state = type(value) == "table" and cycleState(output) or nil
            local entry = type(state) == "table" and type(state.last_entry) == "table" and state.last_entry or nil
            if
                type(state) == "table"
                and state.running == true
                and state.paused ~= true
                and type(entry) == "table"
                and (entry.kind == "video" or entry.kind == "workshop")
                and type(nextOutputs[output]) ~= "table"
            then
                state.next_due = nowSeconds()
            end
        end
    elseif tostring(rendererStatus.last_event or "") == "exited" then
        for output in pairs(previousOutputs) do
            local state = type(runtime.cycles[output]) == "table" and cycleState(output) or nil
            local entry = type(state) == "table" and type(state.last_entry) == "table" and state.last_entry or nil
            if
                type(nextOutputs[output]) ~= "table"
                and rendererStopping[output] ~= true
                and type(state) == "table"
                and state.running == true
                and state.paused ~= true
                and type(entry) == "table"
                and (entry.kind == "video" or entry.kind == "workshop")
            then
                state.next_due = nowSeconds()
            end
        end
    end
    persistRuntimeIfChanged(false)
    publishStatus()
end)
noctalia.state.watch(MOTIONBGS_STATUS_KEY, function(nextStatus)
    if type(nextStatus) == "table" then
        motionBgsStatus = nextStatus
    else
        motionBgsStatus = { available = false, busy = false, last_error = noctalia.tr("errors.motionbgs_unavailable") }
    end
    local downloadPath = type(motionBgsStatus.last_download) == "table"
            and tostring(motionBgsStatus.last_download.path or "")
        or ""
    if downloadPath ~= "" and downloadPath ~= lastMotionDownloadPath then
        lastMotionDownloadPath = downloadPath
        refreshLibrary()
    end
    refreshBackendPolicy()
    persistRuntimeIfChanged(false)
    publishStatus()
end)
noctalia.state.watch(MOTIONBGS_RESULTS_KEY, function(nextResults)
    motionBgsResults = if type(nextResults) == "table" then nextResults else { items = {}, selected = {} }
    publishStatus()
end)
handleCommand(noctalia.state.get(COMMAND_KEY))
publishStatus()
probeProviders()

function onExit(_signal, _reason)
    for _, request in pairs(pendingAdapterCaptures) do
        if
            type(request) == "table"
            and type(request.staging_path) == "string"
            and request.staging_path ~= ""
            and noctalia.fileExists(request.staging_path)
        then
            noctalia.removeFile(request.staging_path)
        end
    end
    for _, request in pairs(captureQueued) do
        if
            type(request) == "table"
            and type(request.staging_path) == "string"
            and request.staging_path ~= ""
            and noctalia.fileExists(request.staging_path)
        then
            noctalia.removeFile(request.staging_path)
        end
    end
    for _, request in pairs(activeCaptureRequests) do
        if
            type(request) == "table"
            and type(request.staging_path) == "string"
            and request.staging_path ~= ""
            and noctalia.fileExists(request.staging_path)
        then
            noctalia.removeFile(request.staging_path)
        end
    end
    noctalia.state.set(STATUS_KEY, { ready = false })
end

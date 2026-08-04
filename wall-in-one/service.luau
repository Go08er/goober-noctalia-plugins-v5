--!nonstrict
-- Wall-in-One coordinator service.
--
-- Wall-in-One owns every dynamic wallpaper child through renderer.luau. The
-- coordinator keeps Noctalia's static wallpaper surface enabled, pairs every
-- live item with a real still, and coordinates named playlists plus
-- independent per-output schedules and renderer settings.

local CONFIG_SCHEMA = 5
local RUNTIME_SCHEMA = 6
local UPDATE_INTERVAL_MS = 2000
local AVAILABILITY_REFRESH_SECONDS = 30
local NOTIFY_COOLDOWN_SECONDS = 10
local MAX_PROJECT_JSON_BYTES = 256 * 1024
local MAX_STORAGE_BYTES = 8 * 1024 * 1024
local MAX_MANAGED_MARKER_BYTES = 16 * 1024
local MAX_MANAGED_SIDECAR_BYTES = 64 * 1024
local MAX_PLAYLISTS = 128
local MAX_PAIRINGS = 1024
local MAX_PLAYLIST_ENTRIES = 512
local MAX_TOTAL_PLAYLIST_ENTRIES = 4096
local MAX_SCHEDULES_PER_OUTPUT = 32
local MAX_TOTAL_SCHEDULES = 512
local MAX_PLAYLIST_RUNS = 4096
local MAX_HISTORY_ENTRIES = 64
local MAX_LIBRARY_CANDIDATES = 1024
local LIBRARY_SCAN_BATCH = 4
local MAX_RUNTIME_OUTPUTS = 64
local MAX_PAIR_REGISTRY_ENTRIES = 1024
local MAX_PERSISTED_PATH_BYTES = 4096
local MAX_PERSISTED_NAME_BYTES = 160
local MAX_WORKSHOP_ID_BYTES = 24
local MIN_CYCLE_SECONDS = 60
local MAX_CYCLE_SECONDS = 30 * 24 * 60 * 60
local RENDERER_CRASH_BACKOFF_SECONDS = { 10, 20, 40, 80, 160, 300 }
local RENDERER_CRASH_STABLE_SECONDS = MIN_CYCLE_SECONDS
local MANAGED_PARENT_DIRECTORY = "Wall-in-One"
local MANAGED_WALLHAVEN_DIRECTORY = "Wallhaven"
local MANAGED_AUTOMATIC_STILLS_DIRECTORY = "Automatic Stills"
local MANAGED_MOTIONBGS_DIRECTORY = "MotionBGS"
local MANAGED_MARKER_NAME = ".managed-by-wall-in-one-v1.json"
local MANAGED_SIDECAR_SUFFIX = ".wall-in-one.json"
local STORAGE_TRANSACTION_NAME = ".schema-3-6-transaction.json"
local WALLPAPER_ENGINE_APP_ID = "431960"
local WALLPAPER_ENGINE_WORKSHOP_URL = "https://steamcommunity.com/app/431960/workshop/"

local SERVICE_NONCE = (tostring(noctalia.nowMs()) .. "-" .. tostring({})):gsub("[^%w%-]", ""):sub(1, 40)

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"
local COMMAND_ACK_KEY = "wall_in_one_command_ack"
local CONFIG_STATE_KEY = "wall_in_one_config_state_v1"
local RUNTIME_STATE_KEY = "wall_in_one_runtime_state_v1"
local LIBRARY_STATE_KEY = "wall_in_one_library_state_v1"
local RENDERER_COMMAND_KEY = "wall_in_one_renderer_command_v1"
local RENDERER_STATUS_KEY = "wall_in_one_renderer_status_v1"
local MOTIONBGS_COMMAND_KEY = "wall_in_one_motionbgs_command_v1"
local MOTIONBGS_STATUS_KEY = "wall_in_one_motionbgs_status_v1"
local MOTIONBGS_RESULTS_KEY = "wall_in_one_motionbgs_results_v1"
local PALETTES_COMMAND_KEY = "wall_in_one_palettes_command_v1"
local PALETTES_STATUS_KEY = "wall_in_one_palettes_status_v1"
local WALLHAVEN_COMMAND_KEY = "wall_in_one_wallhaven_command_v1"
local WALLHAVEN_STATUS_KEY = "wall_in_one_wallhaven_status_v1"
local WALLHAVEN_RESULTS_KEY = "wall_in_one_wallhaven_results_v1"
local MOTIONBGS_URL = "https://motionbgs.com/"
local MOTIONBGS_HELPER_URL = "https://github.com/Go08er/goober-noctalia-plugins-v5/tree/main/motionbgs-helper"
local WALLHAVEN_URL = "https://wallhaven.cc/"

local OPEN_TARGETS = {
    native_open = "wallpaper",
    hub_open = "goober/wall-in-one:hub",
}

local NATIVE_SWITCH_VERBS = {
    native_next = "wallpaper-next",
    native_previous = "wallpaper-previous",
    native_random = "wallpaper-random",
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

local BUILTIN_PALETTES = {
    Ayu = true,
    Catppuccin = true,
    Dracula = true,
    Eldritch = true,
    Gruvbox = true,
    Kanagawa = true,
    Noctalia = true,
    Nord = true,
    ["Rosé Pine"] = true,
    ["Tokyo-Night"] = true,
}

local VALID_THEME_MODES = {
    dark = true,
    light = true,
    auto = true,
    inherit = true,
}

local VALID_PALETTE_SOURCES = {
    wallpaper = true,
    builtin = true,
    community = true,
    custom = true,
    inherit = true,
}

local VALID_INTERNAL_LAYERS = {
    background = true,
    bottom = true,
}

local VALID_MPV_AUTO_PAUSE_MODES = {
    FULL = true,
    MAX = true,
    ACTIVE = true,
}

local VALID_W_ENGINE_SCALING = {
    default = true,
    stretch = true,
    fit = true,
    fill = true,
}

local VALID_W_ENGINE_CLAMP = {
    clamp = true,
    border = true,
    ["repeat"] = true,
}

local WORKSHOP_FLAG_NAMES = {
    "noautomute",
    "no_audio_processing",
    "disable_particles",
    "disable_mouse",
    "disable_parallax",
    "no_fullscreen_pause",
    "fullscreen_pause_only_active",
}

local VALID_PLAYLIST_ORDERS = {
    rotate = true,
    shuffle = true,
}

local VALID_ENTRY_KINDS = {
    static = true,
    video = true,
    workshop = true,
}

local SUPPORTED_IMAGE_EXTENSIONS = {
    [".png"] = true,
    [".jpg"] = true,
    [".jpeg"] = true,
    [".webp"] = true,
    [".avif"] = true,
    [".gif"] = true,
}

local SUPPORTED_VIDEO_EXTENSIONS = {
    [".mp4"] = true,
    [".mkv"] = true,
    [".webm"] = true,
    [".mov"] = true,
    [".avi"] = true,
    [".m4v"] = true,
    [".gif"] = true,
}

local VALID_ACTIONS = {
    native_open = true,
    native_next = true,
    native_previous = true,
    native_random = true,
    wallhaven_site = true,
    motionbgs_open = true,
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
    hub_open = true,
    no_action = true,
    playback_pause = true,
    playback_resume = true,
    playback_toggle = true,
    playback_stop = true,
    playback_stop_all = true,
    audio_mute = true,
    audio_unmute = true,
    audio_toggle = true,
    audio_volume_down = true,
    audio_volume_up = true,
    audio_set_volume = true,
    steam_launch = true,
    steam_workshop = true,
}

-- Schema 4 and older could store actions that delegated to other plugins.
-- Translate them to Wall-in-One-owned behavior while loading; these names are
-- intentionally not valid executable actions in schema 5.
local LEGACY_GESTURE_ACTIONS = {
    wallhaven_open = "hub_open",
    w_engine_open = "hub_open",
    w_engine_next = "cycle_next",
    w_engine_cycle_stop = "cycle_stop",
    w_engine_stop = "playback_stop",
    mpvpaper_open = "hub_open",
    mpvpaper_pause = "playback_pause",
    mpvpaper_resume = "playback_resume",
    mpvpaper_toggle = "playback_toggle",
    mpvpaper_clear = "playback_stop",
    mpvpaper_clear_all = "playback_stop_all",
    extra_provider_open = "no_action",
}

-- Parameterized IPC actions are intentionally kept out of gesture settings.
-- A click has no place to carry the requested volume, while the explicit
-- `audio-volume <0..100> [output]` IPC route does.
local VALID_GESTURE_ACTIONS = {}
for action in pairs(VALID_ACTIONS) do
    if action ~= "audio_set_volume" then
        VALID_GESTURE_ACTIONS[action] = true
    end
end

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
        left = "hub_open",
        middle = "native_open",
        right = "native_next",
    },
    pairings = {},
    playlists = {},
    outputs = {},
}

local runtime = {
    schema_version = RUNTIME_SCHEMA,
    providers = {},
    pairs = {},
    pair_registry = {},
    runs = {},
    output_states = {},
    current_workshops = {},
    last_capture = {},
    palette = {
        authority_output = "",
        requested = {},
        applied = {},
        last_error = "",
    },
    observed_at = "",
    last_error = "",
}

local providers = {
    noctalia_cli = noctalia.commandExists("noctalia"),
    native = { available = true },
    wallhaven = {
        allowed = true,
        available = false,
        site_available = noctalia.commandExists("xdg-open"),
        site_url = WALLHAVEN_URL,
    },
    w_engine = {
        command_available = noctalia.commandExists("linux-wallpaperengine"),
        renderer_ready = false,
        available = false,
        apply_available = false,
        internal_current = {},
        steam_available = noctalia.commandExists("steam") or noctalia.commandExists("xdg-open"),
        steam_workshop_available = noctalia.commandExists("xdg-open"),
        steam_app_id = WALLPAPER_ENGINE_APP_ID,
        steam_workshop_url = WALLPAPER_ENGINE_WORKSHOP_URL,
    },
    mpvpaper = {
        command_available = noctalia.commandExists("mpvpaper"),
        renderer_ready = false,
        available = false,
        apply_available = false,
    },
    motionbgs = {
        allowed = true,
        available = noctalia.commandExists("xdg-open"),
        browser_available = noctalia.commandExists("xdg-open"),
        integration_available = false,
        url = MOTIONBGS_URL,
    },
}

local colors = {
    probing = false,
    mode = "",
    source = "",
    scheme = "",
    error = "",
}

local palettesStatus = {
    ready = false,
    busy = false,
    builtin = {},
    wallpaper = {},
    community = {},
    custom = {},
    last_error = "",
}
local wallhavenStatus = { ready = false, busy = false, last_error = "" }
local wallhavenResults = { items = {}, selected = {} }

local library = {
    stills = {},
    videos = {},
    workshops = {},
    provider_installs = { wallhaven = {}, motionbgs = {} },
    representative_stills = { video = {}, workshop = {} },
    scanned_at = "",
    error = "",
    scanning = false,
}
local libraryScan = nil
local managedDirectoryError = ""
local libraryRefreshPending = false
local pairingPreviewPending = nil
local libraryRootsSignature = ""
local settingsStatusPublishPending = false

local configValid = true
local runtimeValid = true
local configError = ""
local runtimeError = ""
local lastActionError = ""
local lastActionAt = ""
local statusSequence = 0
local domainPublications = {
    config = { key = CONFIG_STATE_KEY, revision = 0, dirty = true },
    runtime = { key = RUNTIME_STATE_KEY, revision = 0, dirty = true },
    library = { key = LIBRARY_STATE_KEY, revision = 0, dirty = true },
}
local colorProbeInFlight = false
local providerSignature = ""
local lastAvailabilityRefreshAt = 0
local lastNotificationAt = {}
local lastCommandSequence = 0
local captureInFlight = {}
local activeCaptureRequests = {}
local captureQueued = {}
local internalCaptureQueued = {}
local internalCaptureIntent = {}
local captureSequence = 0
local pendingInternalCaptures = {}
local rendererStatus = { ready = false, outputs = {}, last_error = "" }
local rendererStatusInstance = ""
local rendererStatusRevision = -1
local rendererLegacySignature = ""
local motionBgsStatus = { available = false, busy = false, last_error = "" }
local motionBgsResults = { items = {}, selected = {} }
local rendererCommandSequence = 0
local motionBgsCommandSequence = 0
local palettesCommandSequence = 0
local wallhavenCommandSequence = 0
local cycleApplying = {}
local cycleGeneration = {}
local applyGeneration = {}
local scheduleClockSignature = ""
local scheduleReevaluationPending = {}
local paletteAuthorityOutput = ""
local paletteAuthorityGeneration = 0
local lastStatusSignature = ""
local settingsSnapshotCache = nil
local rendererPending = {}
local rendererStopping = {}
local rendererExitState = {}
local lastMotionDownloadFingerprint = ""
local lastWallhavenDownloadFingerprint = ""
local postApplyQueue = {}
local wallpaperApplyInFlight = nil
local wallpaperApplyQueued = {}
local scheduledBatchActive = false
local startupRestoreQueue = {}
local backendGeneration = { w_engine = 0, mpvpaper = 0 }
local backendPolicySignature = { w_engine = "", mpvpaper = "" }
local wallInOne = {}

-- Core settings, paths, and bounded value helpers ---------------------------


-- Clear readiness before installing the command watch. Clients retain a
-- gesture while a service hot reload is in progress.
noctalia.state.set(STATUS_KEY, {
    protocol = 4,
    instance_id = SERVICE_NONCE,
    sequence = 0,
    ready = false,
    domains = {
        config = { key = CONFIG_STATE_KEY, revision = 0 },
        runtime = { key = RUNTIME_STATE_KEY, revision = 0 },
        library = { key = LIBRARY_STATE_KEY, revision = 0 },
    },
})

function wallInOne.nowSeconds()
    return tonumber(noctalia.formatTime("%s")) or 0
end

function wallInOne.commandFailureDetail(result)
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

function wallInOne.boundedDetail(value)
    local detail = noctalia.string.trim(tostring(value or "")):gsub("[%c]", " ")
    if #detail > 320 then
        detail = detail:sub(1, 320)
    end
    return detail
end

function wallInOne.completedDownloadFingerprint(providerStatus)
    if
        type(providerStatus) ~= "table"
        or providerStatus.busy == true
        or tostring(providerStatus.last_action or "") ~= "download"
        or tostring(providerStatus.last_error or "") ~= ""
    then
        return "", ""
    end
    local download = providerStatus.last_download
    local path = type(download) == "table" and tostring(download.path or "") or ""
    local nonce = tonumber(providerStatus.last_completed_nonce)
    if path == "" or nonce == nil or nonce < 1 or nonce ~= math.floor(nonce) then
        return "", path
    end
    -- Completion nonce distinguishes a fresh download from the same path being
    -- reported again after its previous managed copy was deleted.
    return tostring(math.floor(nonce)) .. ":" .. tostring(#path) .. ":" .. path, path
end

function wallInOne.readBoundedRegularFile(path, maximumBytes)
    maximumBytes = math.floor(tonumber(maximumBytes) or 0)
    if type(path) ~= "string" or path == "" or maximumBytes < 1 then
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

function wallInOne.shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

function wallInOne.knownOutputName(candidate)
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

function wallInOne.targetOutput(candidate)
    if candidate ~= nil and tostring(candidate) ~= "" then
        return wallInOne.knownOutputName(candidate)
    end
    return wallInOne.knownOutputName(noctalia.focusedOutputName())
end

function wallInOne.settingString(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) ~= "string" or value:find("%S") == nil then
        return fallback
    end
    return value
end

function wallInOne.settingBool(key, fallback)
    local value = noctalia.getConfig(key)
    if type(value) == "boolean" then
        return value
    end
    return fallback
end

function wallInOne.settingInt(key, fallback, minimum, maximum)
    local value = math.floor(tonumber(noctalia.getConfig(key)) or fallback)
    return math.max(minimum, math.min(maximum, value))
end

function wallInOne.configuredColorScheme()
    local scheme = wallInOne.settingString("color_scheme", "m3-content")
    if not VALID_COLOR_SCHEMES[scheme] then
        return "m3-content"
    end
    return scheme
end

function wallInOne.defaultOutputEngines()
    return {
        layer = "bottom",
        video = {
            enabled = true,
            mute = true,
            hardware_decode = true,
            auto_pause = true,
            auto_pause_mode = "FULL",
            options = "",
        },
        workshop = {
            enabled = true,
            fps = 30,
            volume = 0,
            silent = true,
            scaling = "fill",
            clamp = "border",
            flags = {
                noautomute = false,
                no_audio_processing = false,
                disable_particles = false,
                disable_mouse = false,
                disable_parallax = false,
                no_fullscreen_pause = false,
                fullscreen_pause_only_active = false,
            },
        },
    }
end

function wallInOne.normalizedOutputEngines(candidate, fallback)
    if candidate ~= nil and type(candidate) ~= "table" then
        return nil
    end
    fallback = type(fallback) == "table" and fallback or wallInOne.defaultOutputEngines()
    candidate = type(candidate) == "table" and candidate or {}
    local rawVideo = candidate.video
    local rawWorkshop = candidate.workshop
    if rawVideo ~= nil and type(rawVideo) ~= "table" then
        return nil
    end
    if rawWorkshop ~= nil and type(rawWorkshop) ~= "table" then
        return nil
    end
    rawVideo = type(rawVideo) == "table" and rawVideo or {}
    rawWorkshop = type(rawWorkshop) == "table" and rawWorkshop or {}
    local fallbackVideo = type(fallback.video) == "table" and fallback.video or {}
    local fallbackWorkshop = type(fallback.workshop) == "table" and fallback.workshop or {}
    local rawFlags = rawWorkshop.flags
    if rawFlags ~= nil and type(rawFlags) ~= "table" then
        return nil
    end
    rawFlags = type(rawFlags) == "table" and rawFlags or {}
    local fallbackFlags = type(fallbackWorkshop.flags) == "table" and fallbackWorkshop.flags or {}

    local function booleanValue(raw, key, defaultValue)
        local value = raw[key]
        if value == nil then
            return defaultValue == true, true
        end
        return value == true, type(value) == "boolean"
    end

    local videoEnabled, videoEnabledOk = booleanValue(rawVideo, "enabled", fallbackVideo.enabled)
    local mute, muteOk = booleanValue(rawVideo, "mute", fallbackVideo.mute)
    local hardwareDecode, hardwareDecodeOk = booleanValue(
        rawVideo,
        "hardware_decode",
        fallbackVideo.hardware_decode
    )
    local autoPause, autoPauseOk = booleanValue(rawVideo, "auto_pause", fallbackVideo.auto_pause)
    local workshopEnabled, workshopEnabledOk = booleanValue(rawWorkshop, "enabled", fallbackWorkshop.enabled)
    local silent, silentOk = booleanValue(rawWorkshop, "silent", fallbackWorkshop.silent)
    if not videoEnabledOk or not muteOk or not hardwareDecodeOk or not autoPauseOk or not workshopEnabledOk or not silentOk then
        return nil
    end

    local layer = if candidate.layer == nil then tostring(fallback.layer or "bottom") else tostring(candidate.layer)
    local autoPauseMode = if rawVideo.auto_pause_mode == nil
        then tostring(fallbackVideo.auto_pause_mode or "FULL")
        else tostring(rawVideo.auto_pause_mode)
    local options = if rawVideo.options == nil then tostring(fallbackVideo.options or "") else rawVideo.options
    local scaling = if rawWorkshop.scaling == nil
        then tostring(fallbackWorkshop.scaling or "fill")
        else tostring(rawWorkshop.scaling)
    local clamp = if rawWorkshop.clamp == nil
        then tostring(fallbackWorkshop.clamp or "border")
        else tostring(rawWorkshop.clamp)
    local fps = if rawWorkshop.fps == nil then tonumber(fallbackWorkshop.fps) or 30 else tonumber(rawWorkshop.fps)
    local volume = if rawWorkshop.volume == nil
        then tonumber(fallbackWorkshop.volume) or 0
        else tonumber(rawWorkshop.volume)
    if
        not VALID_INTERNAL_LAYERS[layer]
        or not VALID_MPV_AUTO_PAUSE_MODES[autoPauseMode]
        or type(options) ~= "string"
        or #options > 1024
        or options:find("[%c]") ~= nil
        or not VALID_W_ENGINE_SCALING[scaling]
        or not VALID_W_ENGINE_CLAMP[clamp]
        or fps == nil
        or volume == nil
        or fps % 1 ~= 0
        or fps < 5
        or fps > 144
        or volume % 1 ~= 0
        or volume < 0
        or volume > 100
    then
        return nil
    end

    local flags = {}
    for _, name in ipairs(WORKSHOP_FLAG_NAMES) do
        local rawValue = rawFlags[name]
        -- Accept the schema-4 manifest spelling at the workshop level on the
        -- command boundary, but always persist the canonical flags object.
        if rawValue == nil then
            rawValue = rawWorkshop[name]
        end
        if rawValue == nil then
            rawValue = fallbackFlags[name]
        end
        if type(rawValue) ~= "boolean" then
            return nil
        end
        flags[name] = rawValue
    end
    if flags.no_fullscreen_pause and flags.fullscreen_pause_only_active then
        return nil
    end

    return {
        layer = layer,
        video = {
            enabled = videoEnabled,
            mute = mute,
            hardware_decode = hardwareDecode,
            auto_pause = autoPause,
            auto_pause_mode = autoPauseMode,
            options = options,
        },
        workshop = {
            enabled = workshopEnabled,
            fps = math.floor(fps),
            volume = math.floor(volume),
            silent = silent,
            scaling = scaling,
            clamp = clamp,
            flags = flags,
        },
    }
end

function wallInOne.outputEngineSettings(output)
    local outputConfig = type(config.outputs) == "table" and config.outputs[tostring(output or "")] or nil
    local engines = type(outputConfig) == "table" and outputConfig.engines or nil
    return wallInOne.normalizedOutputEngines(engines) or wallInOne.defaultOutputEngines()
end

function wallInOne.configuredPlaylistOrder()
    local value = wallInOne.settingString("cycle_order", "sequential")
    if value == "shuffle" then
        return "shuffle"
    end
    return "rotate"
end

function wallInOne.configuredCycleSeconds()
    return wallInOne.settingInt("cycle_interval_minutes", 15, 1, 43200) * 60
end

function wallInOne.normalizedDirectory(value)
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

function wallInOne.captureDirectory()
    local configured = wallInOne.settingString("capture_directory", "")
    if configured == "" then
        return ""
    end
    return wallInOne.normalizedDirectory(noctalia.expandPath(configured)) or ""
end

function wallInOne.videoDirectory()
    local configured = wallInOne.settingString("video_directory", "")
    if configured == "" then
        return ""
    end
    return wallInOne.normalizedDirectory(noctalia.expandPath(configured)) or ""
end

function wallInOne.existingDirectory(directory)
    directory = wallInOne.normalizedDirectory(directory)
    if directory == nil then
        return false
    end
    local info = noctalia.fileInfo(directory)
    return type(info) == "table" and info.isDir == true
end

function wallInOne.managedChildDirectory(root, child)
    root = wallInOne.normalizedDirectory(root)
    if root == nil then
        return ""
    end
    return root .. "/" .. MANAGED_PARENT_DIRECTORY .. "/" .. child
end

function wallInOne.wallhavenManagedDirectory()
    return wallInOne.managedChildDirectory(wallInOne.captureDirectory(), MANAGED_WALLHAVEN_DIRECTORY)
end

function wallInOne.automaticStillDirectory()
    return wallInOne.managedChildDirectory(wallInOne.captureDirectory(), MANAGED_AUTOMATIC_STILLS_DIRECTORY)
end

function wallInOne.motionBgsManagedDirectory()
    return wallInOne.managedChildDirectory(wallInOne.videoDirectory(), MANAGED_MOTIONBGS_DIRECTORY)
end

function wallInOne.ensureManagedDirectory(directory, kind)
    directory = wallInOne.normalizedDirectory(directory)
    if directory == nil then
        return false, noctalia.tr("errors.managed_directory")
    end
    local made, makeError = noctalia.mkdirAll(directory)
    if made ~= true then
        return false, tostring(makeError or noctalia.tr("errors.managed_directory"))
    end

    local markerPath = directory .. "/" .. MANAGED_MARKER_NAME
    if noctalia.fileExists(markerPath) then
        local raw = wallInOne.readBoundedRegularFile(markerPath, MAX_MANAGED_MARKER_BYTES)
        local marker = type(raw) == "string" and #raw <= MAX_MANAGED_MARKER_BYTES and noctalia.json.decode(raw) or nil
        if
            type(marker) ~= "table"
            or tonumber(marker.schema) ~= 1
            or marker.plugin ~= "goober/wall-in-one"
            or marker.kind ~= kind
        then
            return false, noctalia.tr("errors.managed_marker")
        end
        return true, nil
    end

    local marker = {
        schema = 1,
        plugin = "goober/wall-in-one",
        kind = kind,
        ownership = "managed",
    }
    local encoded, encodeError = noctalia.json.encode(marker, true)
    if type(encoded) ~= "string" then
        return false, tostring(encodeError or noctalia.tr("errors.encode"))
    end
    local temporary = markerPath .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        return false, tostring(writeError or noctalia.tr("errors.write"))
    end
    local installed, installError = noctalia.renameFile(temporary, markerPath)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or noctalia.tr("errors.install"))
    end
    return true, nil
end

function wallInOne.ensureImageManagedDirectories()
    local imageRoot = wallInOne.captureDirectory()
    if imageRoot == "" then
        return true, nil
    end
    if not wallInOne.existingDirectory(imageRoot) then
        return false, noctalia.tr("errors.managed_directory")
    end
    local errors = {}
    for _, entry in ipairs({
        { path = wallInOne.wallhavenManagedDirectory(), kind = "wallhaven" },
        { path = wallInOne.automaticStillDirectory(), kind = "automatic-stills" },
    }) do
        local ok, errorMessage = wallInOne.ensureManagedDirectory(entry.path, entry.kind)
        if not ok then
            table.insert(errors, tostring(errorMessage or entry.path))
        end
    end
    return #errors == 0, table.concat(errors, "; ")
end

function wallInOne.configuredVideoSource()
    local value = wallInOne.settingString("video_source", "")
    return if value == "" then "" else noctalia.expandPath(value)
end

function wallInOne.configuredManualPair()
    local value = wallInOne.settingString("manual_pair_file", "")
    return if value == "" then "" else noctalia.expandPath(value)
end

function wallInOne.validWorkshopId(value)
    local id = tostring(value or "")
    return id:match("^%d+$") ~= nil and #id <= MAX_WORKSHOP_ID_BYTES
end

function wallInOne.configuredWorkshopId()
    local value = wallInOne.settingString("workshop_id", "")
    return if wallInOne.validWorkshopId(value) then value else ""
end

function wallInOne.settingsSnapshot()
    if type(settingsSnapshotCache) == "table" then
        return settingsSnapshotCache
    end
    local snapshot = {
        use_wallhaven = wallInOne.settingBool("use_wallhaven", true),
        use_motionbgs = wallInOne.settingBool("use_motionbgs", true),
        capture_directory = wallInOne.captureDirectory(),
        video_directory = wallInOne.videoDirectory(),
        motionbgs_result_limit = wallInOne.settingInt("motionbgs_result_limit", 48, 1, 48),
        motionbgs_cache_minutes = wallInOne.settingInt("motionbgs_cache_minutes", 30, 5, 1440),
        motionbgs_max_download_mb = wallInOne.settingInt("motionbgs_max_download_mb", 256, 16, 512),
        motionbgs_quality = if wallInOne.settingString("motionbgs_quality", "hd") == "4k" then "4k" else "hd",
        motionbgs_binary_path = wallInOne.settingString("motionbgs_binary_path", ""),
        image_directory = wallInOne.captureDirectory(),
        wallhaven_managed_directory = wallInOne.wallhavenManagedDirectory(),
        automatic_stills_directory = wallInOne.automaticStillDirectory(),
        motionbgs_managed_directory = wallInOne.motionBgsManagedDirectory(),
        auto_capture = wallInOne.settingBool("auto_capture", true),
        sync_colors = wallInOne.settingBool("sync_colors", true),
        color_scheme = wallInOne.configuredColorScheme(),
        palette_output = wallInOne.settingString("palette_output", ""),
        video_source = wallInOne.configuredVideoSource(),
        manual_pair_file = wallInOne.configuredManualPair(),
        workshop_id = wallInOne.configuredWorkshopId(),
        workshop_directory = wallInOne.settingString("workshop_directory", ""),
        video_frame_second = wallInOne.settingInt("video_frame_second", 1, 0, 3600),
        scene_screenshot_delay = wallInOne.settingInt("scene_screenshot_delay", 15, 1, 120),
        cycle_interval_minutes = wallInOne.settingInt("cycle_interval_minutes", 15, 1, 43200),
        cycle_order = wallInOne.configuredPlaylistOrder(),
        cycle_start_on_load = wallInOne.settingBool("cycle_start_on_load", false),
    }
    settingsSnapshotCache = snapshot
    return snapshot
end

function wallInOne.storagePath(name)
    local directory, errorMessage = noctalia.pluginDataDir()
    if type(directory) ~= "string" or directory == "" then
        return nil, tostring(errorMessage or noctalia.tr("errors.data_directory"))
    end
    return directory .. "/" .. name, nil
end

function wallInOne.cloneGestures(source)
    local gestures = type(source) == "table" and source or {}
    return {
        left = tostring(gestures.left or ""),
        middle = tostring(gestures.middle or ""),
        right = tostring(gestures.right or ""),
    }
end

function wallInOne.validPersistedKey(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= MAX_PERSISTED_NAME_BYTES
        and value:find("[%c]") == nil
end

function wallInOne.validAbsolutePath(value)
    return type(value) == "string"
        and value:sub(1, 1) == "/"
        and #value <= MAX_PERSISTED_PATH_BYTES
        and value:find("[%c]") == nil
end

function wallInOne.stableIdentifier(prefix, seed, ordinal)
    local raw = tostring(seed or "")
    local slug = raw:lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if slug == "" then
        slug = "item"
    end
    slug = slug:sub(1, 48)
    local hash = 2166136261
    for index = 1, #raw do
        hash = (hash * 16777619 + raw:byte(index)) % 2147483647
    end
    return table.concat({ prefix, slug, tostring(math.floor(tonumber(ordinal) or 0)), tostring(hash) }, "-"):sub(
        1,
        MAX_PERSISTED_NAME_BYTES
    )
end

-- Persisted playlist/runtime schemas and migration --------------------------

function wallInOne.uniqueIdentifier(used, preferred)
    local base = tostring(preferred or ""):sub(1, MAX_PERSISTED_NAME_BYTES)
    if not wallInOne.validPersistedKey(base) then
        return nil
    end
    local candidate = base
    local suffix = 2
    while used[candidate] == true do
        local tail = "-" .. tostring(suffix)
        candidate = base:sub(1, MAX_PERSISTED_NAME_BYTES - #tail) .. tail
        suffix += 1
    end
    used[candidate] = true
    return candidate
end

function wallInOne.normalizedLegacyEntry(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local kind = tostring(candidate.kind or "")
    local source = tostring(candidate.source or "")
    if not VALID_ENTRY_KINDS[kind] or source == "" or #source > MAX_PERSISTED_PATH_BYTES or source:find("[%c]") then
        return nil
    end
    if kind == "workshop" then
        if not wallInOne.validWorkshopId(source) then
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
    local label = wallInOne.boundedDetail(candidate.label or "")
    return {
        kind = kind,
        source = source,
        still_path = stillPath,
        label = label,
        added_at = wallInOne.boundedDetail(candidate.added_at or ""),
    }
end

function wallInOne.legacyThemePolicy()
    if wallInOne.settingBool("sync_colors", true) then
        return { mode = "auto", source = "wallpaper", selection = wallInOne.configuredColorScheme() }
    end
    return { mode = "inherit", source = "inherit", selection = "" }
end

function wallInOne.normalizedTheme(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local mode = tostring(candidate.mode or "")
    local source = tostring(candidate.source or "")
    local selection = tostring(candidate.selection or "")
    if not VALID_THEME_MODES[mode] or not VALID_PALETTE_SOURCES[source] then
        return nil
    end
    if mode == "inherit" or source == "inherit" then
        if mode ~= "inherit" or source ~= "inherit" then
            return nil
        end
        return { mode = "inherit", source = "inherit", selection = "" }
    end
    if not wallInOne.validPersistedKey(selection) then
        return nil
    end
    if source == "wallpaper" and not VALID_COLOR_SCHEMES[selection] then
        return nil
    elseif source == "builtin" and not BUILTIN_PALETTES[selection] then
        return nil
    end
    return { mode = mode, source = source, selection = selection }
end

function wallInOne.normalizedMedia(candidate)
    if candidate == nil then
        return nil, true
    end
    if type(candidate) ~= "table" then
        return nil, false
    end
    local kind = tostring(candidate.kind or "")
    local source = tostring(candidate.source or "")
    if kind == "video" and wallInOne.validAbsolutePath(source) then
        return { kind = "video", source = source }, true
    elseif kind == "workshop" and wallInOne.validWorkshopId(source) then
        return { kind = "workshop", source = source }, true
    end
    return nil, false
end

function wallInOne.normalizedStill(candidate, hasDynamicMedia)
    if type(candidate) ~= "table" then
        return nil
    end
    local mode = tostring(candidate.mode or "")
    if mode == "automatic" and hasDynamicMedia then
        return { mode = "automatic" }
    elseif mode == "selected" and wallInOne.validAbsolutePath(tostring(candidate.path or "")) then
        return { mode = "selected", path = tostring(candidate.path) }
    end
    return nil
end

function wallInOne.normalizedEntryBundle(candidate)
    if type(candidate) ~= "table" or not wallInOne.validPersistedKey(candidate.id) then
        return nil
    end
    local label = noctalia.string.trim(tostring(candidate.label or ""))
    if not wallInOne.validPersistedKey(label) then
        return nil
    end
    local media, mediaValid = wallInOne.normalizedMedia(candidate.media)
    if not mediaValid then
        return nil
    end
    local still = wallInOne.normalizedStill(candidate.still, media ~= nil)
    local theme = wallInOne.normalizedTheme(candidate.theme)
    if still == nil or theme == nil then
        return nil
    end
    local normalized = {
        id = tostring(candidate.id),
        label = label,
        media = media,
        still = still,
        theme = theme,
        added_at = wallInOne.boundedDetail(candidate.added_at or ""),
        customized = candidate.customized == true,
    }
    if candidate.pairing_id ~= nil and tostring(candidate.pairing_id or "") ~= "" then
        if not wallInOne.validPersistedKey(candidate.pairing_id) then
            return nil
        end
        normalized.pairing_id = tostring(candidate.pairing_id)
    end
    return normalized
end

function wallInOne.bundleSignature(candidate)
    local media = type(candidate.media) == "table" and candidate.media or {}
    local still = type(candidate.still) == "table" and candidate.still or {}
    local theme = type(candidate.theme) == "table" and candidate.theme or {}
    local function field(value)
        local text = tostring(value or "")
        return tostring(#text) .. ":" .. text
    end
    return table.concat({
        field(candidate.label),
        field(media.kind),
        field(media.source),
        field(still.mode),
        field(still.path),
        field(theme.mode),
        field(theme.source),
        field(theme.selection),
    }, "|")
end

-- Pairing profiles are keyed by the medium they describe, independently of
-- their still/palette choices. This keeps one library identity for each file
-- or Workshop scene while allowing that identity's profile to be customized.
function wallInOne.bundleIdentity(candidate)
    local media = type(candidate) == "table" and type(candidate.media) == "table" and candidate.media or nil
    local still = type(candidate) == "table" and type(candidate.still) == "table" and candidate.still or {}
    local function field(value)
        local text = tostring(value or "")
        return tostring(#text) .. ":" .. text
    end
    if media ~= nil and tostring(media.kind or "") ~= "" and tostring(media.source or "") ~= "" then
        return "dynamic|" .. field(media.kind) .. "|" .. field(media.source)
    end
    if media == nil and tostring(still.mode or "") == "selected" and tostring(still.path or "") ~= "" then
        return "static|" .. field(still.path)
    end
    return ""
end

function wallInOne.pairingFromEntry(entry, pairingId)
    return {
        id = pairingId,
        label = entry.label,
        media = type(entry.media) == "table" and {
            kind = entry.media.kind,
            source = entry.media.source,
        } or nil,
        still = if entry.still.mode == "selected"
            then { mode = "selected", path = entry.still.path }
            else { mode = "automatic" },
        theme = {
            mode = entry.theme.mode,
            source = entry.theme.source,
            selection = entry.theme.selection,
        },
        added_at = entry.added_at,
        customized = entry.customized == true,
    }
end

function wallInOne.normalizedPairings(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local pairings = {}
    local count = 0
    for id, rawPairing in pairs(candidate) do
        count += 1
        local pairing = wallInOne.normalizedEntryBundle(rawPairing)
        if
            count > MAX_PAIRINGS
            or not wallInOne.validPersistedKey(id)
            or pairing == nil
            or pairing.id ~= id
        then
            return nil
        end
        pairing.pairing_id = nil
        -- Pairings written before provenance existed came from the old,
        -- explicitly-created pairing UI. Preserve them as custom overrides;
        -- newly synthesized library defaults always persist an explicit false.
        pairing.customized = if rawPairing.customized == nil then true else rawPairing.customized == true
        pairings[id] = pairing
    end
    return pairings
end

function wallInOne.reconcilePlaylistPairings(playlists, pairings, createMissing)
    local usedIds = {}
    local signatureIds = {}
    local pairingIds = {}
    for id in pairs(pairings) do
        usedIds[id] = true
        table.insert(pairingIds, id)
    end
    table.sort(pairingIds)
    for _, id in ipairs(pairingIds) do
        local signature = wallInOne.bundleSignature(pairings[id])
        if signatureIds[signature] == nil then
            signatureIds[signature] = id
        end
    end

    local playlistIds = {}
    for id in pairs(playlists) do
        table.insert(playlistIds, id)
    end
    table.sort(playlistIds)
    local pairingCount = wallInOne.countMap(pairings)
    local ordinal = pairingCount
    for _, playlistId in ipairs(playlistIds) do
        local playlist = playlists[playlistId]
        for _, entry in ipairs(playlist.entries) do
            local pairingId = tostring(entry.pairing_id or "")
            if pairingId ~= "" and pairings[pairingId] == nil then
                entry.pairing_id = nil
                pairingId = ""
            end
            if pairingId == "" and createMissing == true then
                local signature = wallInOne.bundleSignature(entry)
                pairingId = tostring(signatureIds[signature] or "")
                if pairingId == "" and pairingCount < MAX_PAIRINGS then
                    ordinal += 1
                    pairingId = wallInOne.uniqueIdentifier(
                        usedIds,
                        wallInOne.stableIdentifier("pairing", signature, ordinal)
                    ) or ""
                    if pairingId ~= "" then
                        pairings[pairingId] = wallInOne.pairingFromEntry(entry, pairingId)
                        signatureIds[signature] = pairingId
                        pairingCount += 1
                    end
                end
                if pairingId ~= "" then
                    entry.pairing_id = pairingId
                end
            end
        end
    end
    return pairings
end

function wallInOne.legacyEntryBundle(candidate, output, index, usedIds)
    local legacy = wallInOne.normalizedLegacyEntry(candidate)
    if legacy == nil then
        return nil
    end
    local id = wallInOne.uniqueIdentifier(usedIds, wallInOne.stableIdentifier("entry", output .. ":" .. legacy.kind .. ":" .. legacy.source, index))
    if id == nil then
        return nil
    end
    local media = nil
    local still = nil
    if legacy.kind == "static" then
        still = { mode = "selected", path = legacy.source }
    else
        media = { kind = legacy.kind, source = legacy.source }
        still = if legacy.still_path == ""
            then { mode = "automatic" }
            else { mode = "selected", path = legacy.still_path }
    end
    return {
        id = id,
        label = if wallInOne.validPersistedKey(legacy.label) then legacy.label else legacy.source:match("([^/]+)$") or legacy.source,
        media = media,
        still = still,
        theme = wallInOne.legacyThemePolicy(),
        added_at = legacy.added_at,
    }
end

function wallInOne.normalizedPlaylist(candidate)
    if type(candidate) ~= "table" or type(candidate.entries) ~= "table" then
        return nil
    end
    local name = noctalia.string.trim(tostring(candidate.name or ""))
    if not wallInOne.validPersistedKey(name) or #candidate.entries > MAX_PLAYLIST_ENTRIES then
        return nil
    end
    local entries = {}
    local usedIds = {}
    for _, rawEntry in ipairs(candidate.entries) do
        local entry = wallInOne.normalizedEntryBundle(rawEntry)
        if entry == nil or usedIds[entry.id] == true then
            return nil
        end
        usedIds[entry.id] = true
        table.insert(entries, entry)
    end
    local interval = math.floor(tonumber(candidate.interval_seconds) or wallInOne.configuredCycleSeconds())
    interval = math.max(MIN_CYCLE_SECONDS, math.min(MAX_CYCLE_SECONDS, interval))
    local order = tostring(candidate.order or wallInOne.configuredPlaylistOrder())
    return {
        name = name,
        order = if VALID_PLAYLIST_ORDERS[order] then order else wallInOne.configuredPlaylistOrder(),
        interval_seconds = interval,
        entries = entries,
        quick_choice = candidate.quick_choice == true,
    }
end

function wallInOne.normalizedPlaylists(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local playlists = {}
    local playlistCount = 0
    local totalEntries = 0
    for id, value in pairs(candidate) do
        playlistCount += 1
        local playlist = wallInOne.normalizedPlaylist(value)
        if not wallInOne.validPersistedKey(id) or playlist == nil then
            return nil
        end
        if playlistCount > MAX_PLAYLISTS then
            return nil
        end
        totalEntries += #playlist.entries
        if totalEntries > MAX_TOTAL_PLAYLIST_ENTRIES then
            return nil
        end
        playlists[id] = playlist
    end
    return playlists
end

function wallInOne.normalizedWeekdays(candidate)
    if type(candidate) ~= "table" or #candidate < 1 or #candidate > 7 then
        return nil
    end
    local seen = {}
    local weekdays = {}
    for _, rawDay in ipairs(candidate) do
        local day = tonumber(rawDay)
        if day == nil or day % 1 ~= 0 or day < 0 or day > 6 or seen[day] then
            return nil
        end
        seen[day] = true
        table.insert(weekdays, day)
    end
    table.sort(weekdays)
    return weekdays
end

function wallInOne.allMonths()
    return { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }
end

function wallInOne.normalizedMonths(candidate)
    if type(candidate) ~= "table" or #candidate < 1 or #candidate > 12 then
        return nil
    end
    local seen = {}
    local months = {}
    for _, rawMonth in ipairs(candidate) do
        local month = tonumber(rawMonth)
        if month == nil or month % 1 ~= 0 or month < 1 or month > 12 or seen[month] then
            return nil
        end
        seen[month] = true
        table.insert(months, month)
    end
    table.sort(months)
    return months
end

function wallInOne.normalizedSchedule(candidate, playlists, allowMissingMonths)
    if type(candidate) ~= "table" or not wallInOne.validPersistedKey(candidate.id) then
        return nil
    end
    local name = noctalia.string.trim(tostring(candidate.name or ""))
    local playlist = tostring(candidate.playlist or "")
    local weekdays = wallInOne.normalizedWeekdays(candidate.weekdays)
    local rawMonths = candidate.months
    if rawMonths == nil and allowMissingMonths == true then
        rawMonths = wallInOne.allMonths()
    end
    local months = wallInOne.normalizedMonths(rawMonths)
    local startMinute = tonumber(candidate.start_minute)
    local endMinute = tonumber(candidate.end_minute)
    if
        not wallInOne.validPersistedKey(name)
        or playlists[playlist] == nil
        or weekdays == nil
        or months == nil
        or startMinute == nil
        or startMinute % 1 ~= 0
        or startMinute < 0
        or startMinute > 1439
        or endMinute == nil
        or endMinute % 1 ~= 0
        or endMinute < 0
        or endMinute > 1439
        or (startMinute == endMinute and candidate.all_day ~= true)
    then
        return nil
    end
    return {
        id = tostring(candidate.id),
        name = name,
        playlist = playlist,
        enabled = candidate.enabled ~= false,
        weekdays = weekdays,
        months = months,
        start_minute = math.floor(startMinute),
        end_minute = math.floor(endMinute),
        all_day = candidate.all_day == true,
    }
end

function wallInOne.normalizedOutputs(candidate, playlists, allowMissingScheduleMonths, defaultEngines)
    if type(candidate) ~= "table" then
        return nil
    end
    local outputs = {}
    local outputCount = 0
    local scheduleCount = 0
    for output, rawOutput in pairs(candidate) do
        outputCount += 1
        if not wallInOne.validPersistedKey(output) or type(rawOutput) ~= "table" or outputCount > MAX_RUNTIME_OUTPUTS then
            return nil
        end
        local fallback = tostring(rawOutput.fallback_playlist or "")
        local quickChoice = tostring(rawOutput.quick_choice_playlist or "")
        if (fallback ~= "" and playlists[fallback] == nil) or (quickChoice ~= "" and playlists[quickChoice] == nil) then
            return nil
        end
        local outputOrder = nil
        if rawOutput.order ~= nil then
            outputOrder = tostring(rawOutput.order)
            if not VALID_PLAYLIST_ORDERS[outputOrder] then
                return nil
            end
        end
        local outputInterval = nil
        if rawOutput.interval_seconds ~= nil then
            outputInterval = tonumber(rawOutput.interval_seconds)
            if
                outputInterval == nil
                or outputInterval % 1 ~= 0
                or outputInterval < MIN_CYCLE_SECONDS
                or outputInterval > MAX_CYCLE_SECONDS
            then
                return nil
            end
            outputInterval = math.floor(outputInterval)
        end
        local rawSchedules = type(rawOutput.schedules) == "table" and rawOutput.schedules or nil
        if rawSchedules == nil or #rawSchedules > MAX_SCHEDULES_PER_OUTPUT then
            return nil
        end
        local schedules = {}
        local scheduleIds = {}
        for _, rawSchedule in ipairs(rawSchedules) do
            local schedule = wallInOne.normalizedSchedule(rawSchedule, playlists, allowMissingScheduleMonths == true)
            if schedule == nil or scheduleIds[schedule.id] then
                return nil
            end
            scheduleIds[schedule.id] = true
            table.insert(schedules, schedule)
            scheduleCount += 1
            if scheduleCount > MAX_TOTAL_SCHEDULES then
                return nil
            end
        end
        local normalizedOutput = {
            fallback_playlist = fallback,
            quick_choice_playlist = quickChoice,
            schedules = schedules,
            engines = wallInOne.normalizedOutputEngines(rawOutput.engines, defaultEngines),
        }
        if normalizedOutput.engines == nil then
            return nil
        end
        if outputOrder ~= nil then
            normalizedOutput.order = outputOrder
        end
        if outputInterval ~= nil then
            normalizedOutput.interval_seconds = outputInterval
        end
        outputs[output] = normalizedOutput
    end
    return outputs
end

function wallInOne.migrateLegacyReels(candidate)
    if type(candidate) ~= "table" then
        return nil, nil
    end
    local playlists = {}
    local outputs = {}
    local usedPlaylistIds = {}
    local outputCount = 0
    local totalEntries = 0
    for output, rawReel in pairs(candidate) do
        outputCount += 1
        if
            not wallInOne.validPersistedKey(output)
            or type(rawReel) ~= "table"
            or type(rawReel.entries) ~= "table"
            or outputCount > MAX_RUNTIME_OUTPUTS
            or #rawReel.entries > MAX_PLAYLIST_ENTRIES
        then
            return nil, nil
        end
        local playlistId = wallInOne.uniqueIdentifier(usedPlaylistIds, wallInOne.stableIdentifier("migrated", output, outputCount))
        if playlistId == nil then
            return nil, nil
        end
        local entries = {}
        local usedEntryIds = {}
        for index, rawEntry in ipairs(rawReel.entries) do
            local entry = wallInOne.legacyEntryBundle(rawEntry, output, index, usedEntryIds)
            if entry == nil then
                return nil, nil
            end
            table.insert(entries, entry)
            totalEntries += 1
            if totalEntries > MAX_TOTAL_PLAYLIST_ENTRIES then
                return nil, nil
            end
        end
        local legacyOrder = tostring(rawReel.order or wallInOne.configuredPlaylistOrder())
        playlists[playlistId] = {
            name = "Migrated · " .. output,
            order = if legacyOrder == "shuffle" or legacyOrder == "random" then "shuffle" else "rotate",
            interval_seconds = math.max(
                MIN_CYCLE_SECONDS,
                math.min(MAX_CYCLE_SECONDS, math.floor(tonumber(rawReel.interval_seconds) or wallInOne.configuredCycleSeconds()))
            ),
            entries = entries,
            quick_choice = false,
        }
        outputs[output] = {
            fallback_playlist = playlistId,
            quick_choice_playlist = "",
            schedules = {},
        }
    end
    return playlists, outputs
end

function wallInOne.validateConfig(candidate)
    if type(candidate) ~= "table" then
        return nil, noctalia.tr("errors.config_not_object")
    end
    local schema = tonumber(candidate.schema_version)
    if schema ~= 1 and schema ~= 2 and schema ~= 3 and schema ~= 4 and schema ~= CONFIG_SCHEMA then
        return nil, noctalia.tr("errors.config_schema", { version = tostring(candidate.schema_version or "?") })
    end
    if type(candidate.gestures) ~= "table" then
        return nil, noctalia.tr("errors.config_gestures")
    end

    local gestures = wallInOne.cloneGestures(candidate.gestures)
    for _, button in ipairs({ "left", "middle", "right" }) do
        gestures[button] = LEGACY_GESTURE_ACTIONS[gestures[button]] or gestures[button]
        if not VALID_GESTURE_ACTIONS[gestures[button]] then
            return nil,
                noctalia.tr("errors.config_action", {
                    button = button,
                    action = gestures[button],
                })
        end
    end

    local pairings
    local playlists
    local outputs
    local migratedPairings = false
    -- Engine controls moved from global manifest settings to per-output
    -- schema-5 state. Removed manifest keys cannot be read through getConfig,
    -- so older configs receive the direct-renderer defaults and can then be
    -- tailored per display.
    local migratedEngines = if schema < CONFIG_SCHEMA then wallInOne.defaultOutputEngines() else nil
    if schema == CONFIG_SCHEMA then
        playlists = wallInOne.normalizedPlaylists(candidate.playlists)
        pairings = wallInOne.normalizedPairings(candidate.pairings or {})
        outputs = playlists ~= nil and wallInOne.normalizedOutputs(candidate.outputs, playlists) or nil
        migratedPairings = candidate.pairings == nil
    elseif schema == 4 then
        playlists = wallInOne.normalizedPlaylists(candidate.playlists)
        pairings = wallInOne.normalizedPairings(candidate.pairings or {})
        outputs = playlists ~= nil and wallInOne.normalizedOutputs(candidate.outputs, playlists, false, migratedEngines) or nil
        migratedPairings = candidate.pairings == nil
    elseif schema == 3 then
        -- Schema 3 already has the named playlist/output model. Preserve it
        -- exactly while making every old schedule valid in all calendar months;
        -- explicit numeric priority is intentionally retired in schema 4.
        playlists = wallInOne.normalizedPlaylists(candidate.playlists)
        pairings = {}
        outputs = playlists ~= nil and wallInOne.normalizedOutputs(candidate.outputs, playlists, true, migratedEngines) or nil
    elseif schema == 2 then
        playlists, outputs = wallInOne.migrateLegacyReels(candidate.reels)
        pairings = {}
        outputs = playlists ~= nil and outputs ~= nil
                and wallInOne.normalizedOutputs(outputs, playlists, true, migratedEngines)
            or nil
    else
        pairings, playlists, outputs = {}, {}, {}
    end
    if pairings == nil or playlists == nil or outputs == nil then
        return nil, noctalia.tr("errors.config_playlists")
    end
    wallInOne.reconcilePlaylistPairings(playlists, pairings, schema ~= CONFIG_SCHEMA or migratedPairings)
    return {
        schema_version = CONFIG_SCHEMA,
        gestures = gestures,
        pairings = pairings,
        playlists = playlists,
        outputs = outputs,
    }, nil, if schema == CONFIG_SCHEMA and not migratedPairings then nil else { source_schema = schema }
end

function wallInOne.validRuntimeKey(value, maximum)
    return type(value) == "string" and value ~= "" and #value <= maximum and value:find("[%c]") == nil
end

function wallInOne.normalizedPair(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local provider = tostring(candidate.provider or "")
    local dynamicId = tostring(candidate.dynamic_id or "")
    local stillPath = tostring(candidate.still_path or "")
    local captureMethod = tostring(candidate.capture_method or "")
    local stillOrigin = tostring(candidate.still_origin or (candidate.still_managed == true and "managed-auto" or "user"))
    local sidecarPath = tostring(candidate.sidecar_path or "")
    if
        not wallInOne.validRuntimeKey(provider, 80)
        or not wallInOne.validRuntimeKey(dynamicId, MAX_PERSISTED_PATH_BYTES)
        or not wallInOne.validRuntimeKey(captureMethod, 160)
        or not wallInOne.validRuntimeKey(stillPath, MAX_PERSISTED_PATH_BYTES)
        or stillPath:sub(1, 1) ~= "/"
        or (sidecarPath ~= "" and (sidecarPath:sub(1, 1) ~= "/" or #sidecarPath > MAX_PERSISTED_PATH_BYTES or sidecarPath:find("[%c]")))
        or (stillOrigin ~= "user" and stillOrigin ~= "managed-auto" and stillOrigin ~= "managed-wallhaven")
    then
        return nil
    end
    return {
        provider = provider,
        dynamic_id = dynamicId,
        still_path = stillPath,
        capture_method = captureMethod,
        paired_at = wallInOne.boundedDetail(candidate.paired_at or ""),
        color_source_before = wallInOne.boundedDetail(candidate.color_source_before or ""),
        color_scheme_before = wallInOne.boundedDetail(candidate.color_scheme_before or ""),
        color_scheme = wallInOne.boundedDetail(candidate.color_scheme or ""),
        still_size = math.max(0, math.floor(tonumber(candidate.still_size) or 0)),
        still_mtime = math.max(0, math.floor(tonumber(candidate.still_mtime) or 0)),
        source_size = math.max(0, math.floor(tonumber(candidate.source_size) or 0)),
        source_mtime = math.max(0, math.floor(tonumber(candidate.source_mtime) or 0)),
        still_managed = candidate.still_managed == true,
        still_origin = stillOrigin,
        sidecar_path = sidecarPath,
    }
end

function wallInOne.normalizedPairMap(candidate, maximumEntries, registry)
    if type(candidate) ~= "table" then
        return nil
    end
    local result = {}
    local count = 0
    for key, rawPair in pairs(candidate) do
        count += 1
        local keyValid = if registry then wallInOne.validRuntimeKey(key, MAX_PERSISTED_PATH_BYTES) else wallInOne.validPersistedKey(key)
        local pair = wallInOne.normalizedPair(rawPair)
        if not keyValid or pair == nil or count > maximumEntries then
            return nil
        end
        result[key] = pair
    end
    return result
end

function wallInOne.normalizedCurrentWorkshops(candidate)
    if candidate == nil then
        return {}
    end
    if type(candidate) ~= "table" then
        return nil
    end
    local result = {}
    local count = 0
    for output, rawId in pairs(candidate) do
        count += 1
        local id = tostring(rawId or "")
        if
            count > MAX_RUNTIME_OUTPUTS
            or not wallInOne.validPersistedKey(output)
            or not wallInOne.validWorkshopId(id)
        then
            return nil
        end
        result[output] = id
    end
    return result
end

function wallInOne.playlistEntryIds(playlist)
    local ids = {}
    if type(playlist) == "table" and type(playlist.entries) == "table" then
        for _, entry in ipairs(playlist.entries) do
            ids[tostring(entry.id or "")] = true
        end
    end
    return ids
end

function wallInOne.normalizedIdList(candidate, maximumEntries, validIds)
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
        local value = tostring(candidate[index] or "")
        if not wallInOne.validPersistedKey(value) or validIds[value] ~= true then
            return nil
        end
        result[index] = value
    end
    return result
end

function wallInOne.normalizedRun(candidate, playlist)
    if type(candidate) ~= "table" or type(playlist) ~= "table" then
        return nil
    end
    local validIds = wallInOne.playlistEntryIds(playlist)
    local history = wallInOne.normalizedIdList(candidate.history, MAX_HISTORY_ENTRIES, validIds)
    local bag = wallInOne.normalizedIdList(candidate.bag, MAX_PLAYLIST_ENTRIES, validIds)
    if history == nil or bag == nil then
        return nil
    end
    local currentEntry = tostring(candidate.current_entry or candidate.last_entry_id or "")
    if currentEntry ~= "" and validIds[currentEntry] ~= true then
        return nil
    end
    return {
        running = candidate.running == true,
        paused = candidate.paused == true,
        parked = candidate.parked == true,
        current_entry = currentEntry,
        next_due = math.max(0, math.floor(tonumber(candidate.next_due) or 0)),
        history = history,
        bag = bag,
        last_applied_at = wallInOne.boundedDetail(candidate.last_applied_at or ""),
        last_error = wallInOne.boundedDetail(candidate.last_error or ""),
    }
end

function wallInOne.normalizedRuns(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local result = {}
    local outputCount = 0
    local runCount = 0
    for output, rawRuns in pairs(candidate) do
        outputCount += 1
        if not wallInOne.validPersistedKey(output) or type(rawRuns) ~= "table" or outputCount > MAX_RUNTIME_OUTPUTS then
            return nil
        end
        local outputRuns = {}
        for playlistId, rawRun in pairs(rawRuns) do
            runCount += 1
            local playlist = config.playlists[playlistId]
            local run = wallInOne.normalizedRun(rawRun, playlist)
            if not wallInOne.validPersistedKey(playlistId) or run == nil or runCount > MAX_PLAYLIST_RUNS then
                return nil
            end
            outputRuns[playlistId] = run
        end
        result[output] = outputRuns
    end
    return result
end

function wallInOne.legacyIndexToEntryId(playlist, rawIndex)
    local index = tonumber(rawIndex)
    if index == nil or index % 1 ~= 0 or index < 1 or type(playlist) ~= "table" then
        return nil
    end
    local entry = type(playlist.entries) == "table" and playlist.entries[index] or nil
    return type(entry) == "table" and tostring(entry.id or "") or nil
end

function wallInOne.migrateLegacyCycles(candidate)
    if type(candidate) ~= "table" then
        return nil, nil
    end
    local runs = {}
    local outputStates = {}
    local count = 0
    for output, rawState in pairs(candidate) do
        count += 1
        local outputConfig = config.outputs[output]
        local playlistId = type(outputConfig) == "table" and tostring(outputConfig.fallback_playlist or "") or ""
        local playlist = config.playlists[playlistId]
        if not wallInOne.validPersistedKey(output) or type(rawState) ~= "table" or playlist == nil or count > MAX_RUNTIME_OUTPUTS then
            return nil, nil
        end
        local history = {}
        local rawHistory = type(rawState.history) == "table" and rawState.history or {}
        if #rawHistory > MAX_HISTORY_ENTRIES then
            return nil, nil
        end
        for _, rawIndex in ipairs(rawHistory) do
            local id = wallInOne.legacyIndexToEntryId(playlist, rawIndex)
            if id == nil then
                return nil, nil
            end
            table.insert(history, id)
        end
        local bag = {}
        local rawBag = type(rawState.bag) == "table" and rawState.bag or {}
        if #rawBag > MAX_PLAYLIST_ENTRIES then
            return nil, nil
        end
        for _, rawIndex in ipairs(rawBag) do
            local id = wallInOne.legacyIndexToEntryId(playlist, rawIndex)
            if id == nil then
                return nil, nil
            end
            table.insert(bag, id)
        end
        local currentEntry = wallInOne.legacyIndexToEntryId(playlist, rawState.cursor) or ""
        local parked = #playlist.entries == 1 and currentEntry ~= ""
        runs[output] = {
            [playlistId] = {
                running = rawState.running == true and not parked,
                paused = rawState.paused == true and not parked,
                parked = parked,
                current_entry = currentEntry,
                next_due = if parked then 0 else math.max(0, math.floor(tonumber(rawState.next_due) or 0)),
                history = history,
                bag = bag,
                last_applied_at = wallInOne.boundedDetail(rawState.last_applied_at or ""),
                last_error = wallInOne.boundedDetail(rawState.last_error or ""),
            },
        }
        outputStates[output] = {
            active_playlist = playlistId,
            manual_pin = false,
            active_schedule = "",
            last_transition_at = wallInOne.boundedDetail(rawState.last_applied_at or ""),
        }
    end
    return runs, outputStates
end

function wallInOne.normalizedOutputStates(candidate)
    if type(candidate) ~= "table" then
        return nil
    end
    local result = {}
    local count = 0
    for output, rawState in pairs(candidate) do
        count += 1
        local activePlaylist = type(rawState) == "table" and tostring(rawState.active_playlist or "") or ""
        local activeSchedule = type(rawState) == "table" and tostring(rawState.active_schedule or "") or ""
        if
            not wallInOne.validPersistedKey(output)
            or type(rawState) ~= "table"
            or count > MAX_RUNTIME_OUTPUTS
            or (activePlaylist ~= "" and config.playlists[activePlaylist] == nil)
            or (activeSchedule ~= "" and not wallInOne.validPersistedKey(activeSchedule))
        then
            return nil
        end
        result[output] = {
            active_playlist = activePlaylist,
            manual_pin = rawState.manual_pin == true,
            active_schedule = activeSchedule,
            last_transition_at = wallInOne.boundedDetail(rawState.last_transition_at or ""),
        }
    end
    return result
end

function wallInOne.normalizedPaletteRuntime(candidate)
    if candidate == nil then
        return { authority_output = "", requested = {}, applied = {}, last_error = "" }
    end
    if type(candidate) ~= "table" then
        return nil
    end
    local authority = tostring(candidate.authority_output or "")
    if authority ~= "" and not wallInOne.validPersistedKey(authority) then
        return nil
    end
    local function normalizedTuple(value)
        if type(value) ~= "table" or next(value) == nil then
            return {}
        end
        local mode = tostring(value.mode or "")
        local source = tostring(value.source or "")
        local selection = tostring(value.selection or "")
        if not VALID_THEME_MODES[mode] or not VALID_PALETTE_SOURCES[source] then
            return nil
        end
        if source ~= "inherit" and not wallInOne.validPersistedKey(selection) then
            return nil
        end
        return {
            mode = mode,
            source = source,
            selection = if source == "inherit" then "" else selection,
            output = wallInOne.boundedDetail(value.output or ""),
            playlist = wallInOne.boundedDetail(value.playlist or ""),
            entry = wallInOne.boundedDetail(value.entry or ""),
            fallback = value.fallback == true,
            resolution = if tostring(value.resolution or "") == "degraded"
                then "degraded"
                elseif tostring(value.resolution or "") == "assumed" then "assumed"
                elseif tostring(value.resolution or "") == "pending" then "pending"
                else "requested",
            applied_at = wallInOne.boundedDetail(value.applied_at or ""),
        }
    end
    local requested = normalizedTuple(candidate.requested)
    local applied = normalizedTuple(candidate.applied)
    if requested == nil or applied == nil then
        return nil
    end
    return {
        authority_output = authority,
        requested = requested,
        applied = applied,
        last_error = wallInOne.boundedDetail(candidate.last_error or ""),
    }
end

function wallInOne.normalizedLastCapture(candidate)
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
        not wallInOne.validRuntimeKey(provider, 80)
        or not wallInOne.validRuntimeKey(dynamicId, MAX_PERSISTED_PATH_BYTES)
        or not wallInOne.validRuntimeKey(output, 160)
        or not wallInOne.validRuntimeKey(path, MAX_PERSISTED_PATH_BYTES)
        or path:sub(1, 1) ~= "/"
        or not wallInOne.validRuntimeKey(method, 160)
    then
        return nil
    end
    return {
        provider = provider,
        dynamic_id = dynamicId,
        output = output,
        path = path,
        method = method,
        captured_at = wallInOne.boundedDetail(candidate.captured_at or ""),
    }
end

function wallInOne.validateRuntime(candidate)
    if type(candidate) ~= "table" then
        return nil, noctalia.tr("errors.runtime_not_object")
    end
    local schema = tonumber(candidate.schema_version)
    if schema ~= 1 and schema ~= 2 and schema ~= 3 and schema ~= 4 and schema ~= 5 and schema ~= RUNTIME_SCHEMA then
        return nil, noctalia.tr("errors.runtime_schema", { version = tostring(candidate.schema_version or "?") })
    end
    if type(candidate.providers) ~= "table" or (schema >= 2 and type(candidate.pairs) ~= "table") then
        return nil, noctalia.tr("errors.runtime_providers")
    end
    local pairsState =
        wallInOne.normalizedPairMap(type(candidate.pairs) == "table" and candidate.pairs or {}, MAX_RUNTIME_OUTPUTS, false)
    local pairRegistry = wallInOne.normalizedPairMap(
        type(candidate.pair_registry) == "table" and candidate.pair_registry or {},
        MAX_PAIR_REGISTRY_ENTRIES,
        true
    )
    local runs
    local outputStates
    if schema == RUNTIME_SCHEMA then
        runs = wallInOne.normalizedRuns(candidate.runs)
        outputStates = wallInOne.normalizedOutputStates(candidate.output_states)
    else
        runs, outputStates = wallInOne.migrateLegacyCycles(type(candidate.cycles) == "table" and candidate.cycles or {})
    end
    local currentWorkshops = wallInOne.normalizedCurrentWorkshops(candidate.current_workshops)
    local lastCapture = wallInOne.normalizedLastCapture(type(candidate.last_capture) == "table" and candidate.last_capture or {})
    local palette = wallInOne.normalizedPaletteRuntime(candidate.palette)
    if
        pairsState == nil
        or pairRegistry == nil
        or runs == nil
        or outputStates == nil
        or currentWorkshops == nil
        or lastCapture == nil
        or palette == nil
    then
        return nil, noctalia.tr("errors.runtime_nested")
    end
    return {
        schema_version = RUNTIME_SCHEMA,
        -- Provider observations are reconstructed from a fresh, fail-closed
        -- ownership probe before use; never republish arbitrary nested input.
        providers = {},
        pairs = pairsState,
        pair_registry = pairRegistry,
        runs = runs,
        output_states = outputStates,
        current_workshops = currentWorkshops,
        last_capture = lastCapture,
        palette = palette,
        observed_at = wallInOne.boundedDetail(candidate.observed_at or ""),
        last_error = wallInOne.boundedDetail(candidate.last_error or ""),
    },
        nil,
        if schema == RUNTIME_SCHEMA then nil else { source_schema = schema }
end

-- Atomic storage and crash recovery ----------------------------------------

function wallInOne.atomicWrite(name, value)
    local path, pathError = wallInOne.storagePath(name)
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
        local previous = wallInOne.readBoundedRegularFile(path, MAX_STORAGE_BYTES)
        if type(previous) ~= "string" then
            noctalia.removeFile(temporary)
            return false, noctalia.tr("errors.backup")
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

function wallInOne.stageDocument(name, value)
    local path, pathError = wallInOne.storagePath(name)
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
    local staged = path .. ".next"
    local temporary = staged .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(writeError or noctalia.tr("errors.write"))
    end
    local installed, installError = noctalia.renameFile(temporary, staged)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or noctalia.tr("errors.install"))
    end
    return true, nil
end

function wallInOne.backupDocument(name)
    local path, pathError = wallInOne.storagePath(name)
    if path == nil then
        return false, pathError
    end
    if not noctalia.fileExists(path) then
        return true, nil
    end
    local raw = wallInOne.readBoundedRegularFile(path, MAX_STORAGE_BYTES)
    if type(raw) ~= "string" then
        return false, noctalia.tr("errors.backup")
    end
    local backup = path .. ".bak"
    local temporary = backup .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, raw)
    if wrote ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(writeError or noctalia.tr("errors.backup"))
    end
    local installed, installError = noctalia.renameFile(temporary, backup)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or noctalia.tr("errors.backup"))
    end
    return true, nil
end

function wallInOne.recoverDocumentTransaction()
    local marker, markerError = wallInOne.storagePath(STORAGE_TRANSACTION_NAME)
    if marker == nil then
        return false, markerError
    end
    if not noctalia.fileExists(marker) then
        for _, name in ipairs({ "config.json", "runtime.json" }) do
            local path = wallInOne.storagePath(name)
            if path ~= nil then
                noctalia.removeFile(path .. ".next.tmp")
            end
        end
        return true, nil
    end

    for _, name in ipairs({ "config.json", "runtime.json" }) do
        local path, pathError = wallInOne.storagePath(name)
        if path == nil then
            return false, pathError
        end
        local staged = path .. ".next"
        if noctalia.fileExists(staged) then
            local installed, installError = noctalia.renameFile(staged, path)
            if installed ~= true then
                return false, tostring(installError or noctalia.tr("errors.transaction_recovery"))
            end
        elseif not noctalia.fileExists(path) then
            local backup = path .. ".bak"
            local previous = if noctalia.fileExists(backup)
                then wallInOne.readBoundedRegularFile(backup, MAX_STORAGE_BYTES)
                else nil
            if type(previous) ~= "string" then
                return false, noctalia.tr("errors.transaction_recovery")
            end
            local restored, restoreError = noctalia.writeFile(path .. ".tmp", previous)
            if restored ~= true then
                return false, tostring(restoreError or noctalia.tr("errors.transaction_recovery"))
            end
            local promoted, promoteError = noctalia.renameFile(path .. ".tmp", path)
            if promoted ~= true then
                return false, tostring(promoteError or noctalia.tr("errors.transaction_recovery"))
            end
        end
    end
    local removed, removeError = noctalia.removeFile(marker)
    if removed ~= true and noctalia.fileExists(marker) then
        return false, tostring(removeError or noctalia.tr("errors.transaction_recovery"))
    end
    return true, nil
end

function wallInOne.installDocumentPair(nextConfig, nextRuntime)
    local configStaged, configStageError = wallInOne.stageDocument("config.json", nextConfig)
    if not configStaged then
        return false, configStageError
    end
    local runtimeStaged, runtimeStageError = wallInOne.stageDocument("runtime.json", nextRuntime)
    if not runtimeStaged then
        return false, runtimeStageError
    end
    local configBackedUp, configBackupError = wallInOne.backupDocument("config.json")
    if not configBackedUp then
        return false, configBackupError
    end
    local runtimeBackedUp, runtimeBackupError = wallInOne.backupDocument("runtime.json")
    if not runtimeBackedUp then
        return false, runtimeBackupError
    end
    local markerWritten, markerError = wallInOne.atomicWrite(STORAGE_TRANSACTION_NAME, {
        schema_version = 1,
        config_schema = CONFIG_SCHEMA,
        runtime_schema = RUNTIME_SCHEMA,
        created_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S %z"),
    })
    if not markerWritten then
        return false, markerError
    end
    return wallInOne.recoverDocumentTransaction()
end

function wallInOne.loadJsonFile(name, validator, defaults)
    local path, pathError = wallInOne.storagePath(name)
    if path == nil then
        return nil, pathError
    end
    if not noctalia.fileExists(path) then
        return defaults, nil, { created = true }
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
    local raw = wallInOne.readBoundedRegularFile(path, MAX_STORAGE_BYTES)
    if type(raw) ~= "string" then
        return nil, noctalia.tr("errors.read")
    end
    local decoded, decodeError = noctalia.json.decode(raw)
    if decoded == nil then
        return nil, noctalia.tr("errors.decode", { detail = tostring(decodeError or "") })
    end
    return validator(decoded)
end

function wallInOne.countMap(candidate)
    local count = 0
    for _ in pairs(type(candidate) == "table" and candidate or {}) do
        count += 1
    end
    return count
end

function wallInOne.refineLegacyEntryPairing()
    local changedPairings = {}
    for _output, outputConfig in pairs(config.outputs) do
        local playlistId = type(outputConfig) == "table" and tostring(outputConfig.fallback_playlist or "") or ""
        local playlist = config.playlists[playlistId]
        if type(playlist) == "table" then
            for _, entry in ipairs(playlist.entries) do
                local media = type(entry.media) == "table" and entry.media or nil
                local still = type(entry.still) == "table" and entry.still or nil
                if media ~= nil and type(still) == "table" and still.mode == "selected" then
                    local dynamicId = if media.kind == "video" then "video:" .. media.source else media.source
                    local pair = runtime.pair_registry[dynamicId]
                    if
                        type(pair) == "table"
                        and pair.still_managed == true
                        and tostring(pair.still_path or "") == tostring(still.path or "")
                        and type(wallInOne.readManagedStillSidecar) == "function"
                        and wallInOne.readManagedStillSidecar(still.path) ~= nil
                    then
                        entry.still = { mode = "automatic" }
                        local pairingId = tostring(entry.pairing_id or "")
                        if pairingId ~= "" and type(config.pairings[pairingId]) == "table" then
                            config.pairings[pairingId] = wallInOne.pairingFromEntry(entry, pairingId)
                            changedPairings[pairingId] = true
                        end
                    end
                end
            end
        end
    end
    for pairingId in pairs(changedPairings) do
        wallInOne.syncPairingSnapshots(config, pairingId)
    end
end

function wallInOne.legacyPairEntry(pair, output, usedIds)
    if type(pair) ~= "table" or not wallInOne.validAbsolutePath(tostring(pair.still_path or "")) then
        return nil
    end
    local dynamicId = tostring(pair.dynamic_id or "")
    local media = nil
    if dynamicId:sub(1, 6) == "video:" and wallInOne.validAbsolutePath(dynamicId:sub(7)) then
        media = { kind = "video", source = dynamicId:sub(7) }
    elseif wallInOne.validWorkshopId(dynamicId) then
        media = { kind = "workshop", source = dynamicId }
    end
    local still = if media ~= nil and pair.still_managed == true
        then { mode = "automatic" }
        else { mode = "selected", path = tostring(pair.still_path) }
    local id = wallInOne.uniqueIdentifier(usedIds, wallInOne.stableIdentifier("entry", output .. ":" .. dynamicId, 1))
    if id == nil then
        return nil
    end
    return {
        id = id,
        label = if media == nil then "Migrated wallpaper" else "Migrated " .. tostring(media.kind),
        media = media,
        still = still,
        theme = wallInOne.legacyThemePolicy(),
        added_at = wallInOne.boundedDetail(pair.paired_at or ""),
    }
end

function wallInOne.preserveLegacyCurrentPairs()
    local candidates = {}
    for output, pair in pairs(runtime.pairs) do
        if output ~= "all" then
            candidates[output] = pair
        end
    end
    local allPair = runtime.pairs.all
    if type(allPair) == "table" then
        local outputNames = {}
        for _, output in ipairs(noctalia.outputs()) do
            local name = type(output) == "table" and tostring(output.name or output.connector or "") or ""
            if wallInOne.validPersistedKey(name) and candidates[name] == nil then
                table.insert(outputNames, name)
            end
        end
        table.sort(outputNames)
        for _, output in ipairs(outputNames) do
            candidates[output] = allPair
        end
    end

    local usedPlaylistIds = {}
    for id in pairs(config.playlists) do
        usedPlaylistIds[id] = true
    end
    local ordinal = wallInOne.countMap(config.playlists)
    local outputNames = {}
    for output in pairs(candidates) do
        table.insert(outputNames, output)
    end
    table.sort(outputNames)
    for _, output in ipairs(outputNames) do
        local outputConfig = config.outputs[output]
        local hasFallback = type(outputConfig) == "table"
            and tostring(outputConfig.fallback_playlist or "") ~= ""
            and config.playlists[tostring(outputConfig.fallback_playlist)] ~= nil
        if not hasFallback and wallInOne.countMap(config.playlists) < MAX_PLAYLISTS then
            ordinal += 1
            local playlistId = wallInOne.uniqueIdentifier(usedPlaylistIds, wallInOne.stableIdentifier("migrated-current", output, ordinal))
            local entry = wallInOne.legacyPairEntry(candidates[output], output, {})
            if playlistId ~= nil and entry ~= nil then
                config.playlists[playlistId] = {
                    name = "Migrated current · " .. output,
                    order = "rotate",
                    interval_seconds = wallInOne.configuredCycleSeconds(),
                    entries = { entry },
                    quick_choice = false,
                }
                config.outputs[output] = {
                    fallback_playlist = playlistId,
                    quick_choice_playlist = "",
                    schedules = {},
                }
                runtime.runs[output] = runtime.runs[output] or {}
                runtime.runs[output][playlistId] = {
                    running = false,
                    paused = false,
                    parked = true,
                    current_entry = entry.id,
                    next_due = 0,
                    history = { entry.id },
                    bag = {},
                    last_applied_at = wallInOne.boundedDetail(candidates[output].paired_at or ""),
                    last_error = "",
                }
                runtime.output_states[output] = {
                    active_playlist = playlistId,
                    manual_pin = false,
                    active_schedule = "",
                    last_transition_at = wallInOne.boundedDetail(candidates[output].paired_at or ""),
                }
            end
        end
    end
end

function wallInOne.loadStorage()
    local recovered, recoveryError = wallInOne.recoverDocumentTransaction()
    if not recovered then
        configValid = false
        runtimeValid = false
        configError = tostring(recoveryError or noctalia.tr("errors.transaction_recovery"))
        runtimeError = configError
        return
    end
    local loadedConfig, loadedConfigError, migratedConfig = wallInOne.loadJsonFile("config.json", wallInOne.validateConfig, config)
    if loadedConfig == nil then
        configValid = false
        configError = tostring(loadedConfigError or noctalia.tr("errors.config_invalid"))
    else
        config = loadedConfig
    end

    local loadedRuntime, loadedRuntimeError, migratedRuntime = wallInOne.loadJsonFile("runtime.json", wallInOne.validateRuntime, runtime)
    if loadedRuntime == nil then
        runtimeValid = false
        runtimeError = tostring(loadedRuntimeError or noctalia.tr("errors.runtime_invalid"))
    else
        runtime = loadedRuntime
    end

    if configValid and runtimeValid and (migratedConfig ~= nil or migratedRuntime ~= nil) then
        local sourceConfigSchema = type(migratedConfig) == "table" and tonumber(migratedConfig.source_schema) or nil
        -- Pair/reel refinement belongs only to the pre-playlist schemas. A
        -- schema-3 document already contains authoritative named playlists and
        -- outputs, so its schema-4 migration must not synthesize or rewrite them.
        if sourceConfigSchema ~= nil and sourceConfigSchema <= 2 then
            wallInOne.refineLegacyEntryPairing()
            wallInOne.preserveLegacyCurrentPairs()
            wallInOne.reconcilePlaylistPairings(config.playlists, config.pairings, true)
        end
        local normalizedConfig, normalizedConfigError = wallInOne.validateConfig(config)
        local normalizedRuntime, normalizedRuntimeError = wallInOne.validateRuntime(runtime)
        if normalizedConfig == nil or normalizedRuntime == nil then
            configValid = false
            runtimeValid = false
            configError = tostring(normalizedConfigError or noctalia.tr("errors.config_invalid"))
            runtimeError = tostring(normalizedRuntimeError or noctalia.tr("errors.runtime_invalid"))
            return
        end
        config = normalizedConfig
        runtime = normalizedRuntime
        local migrated, migrationError = wallInOne.installDocumentPair(config, runtime)
        if not migrated then
            configValid = false
            runtimeValid = false
            configError = tostring(migrationError or noctalia.tr("errors.transaction_install"))
            runtimeError = configError
        end
    end
end

-- Public status, provider discovery, and integration policy ----------------

function wallInOne.activeCapturesSnapshot()
    local activeCaptures = {}
    for output, capture in pairs(captureInFlight) do
        activeCaptures[output] = capture
    end
    return activeCaptures
end

function wallInOne.configDomainSnapshot()
    return {
        config = {
            schema_version = CONFIG_SCHEMA,
            gestures = wallInOne.cloneGestures(config.gestures),
            -- `config` is replaced only with a fully normalized document. State
            -- transport serializes immediately, so a second deep normalize here
            -- only burns the host's bounded callback budget.
            pairings = config.pairings,
            playlists = config.playlists,
            outputs = config.outputs,
        },
    }
end

function wallInOne.runtimeDomainSnapshot()
    return {
        schema_version = RUNTIME_SCHEMA,
        runtime = {
            colors = colors,
            pairs = runtime.pairs,
            runs = runtime.runs,
            output_states = runtime.output_states,
            palette = runtime.palette,
            current_workshops = runtime.current_workshops,
            last_capture = runtime.last_capture,
        },
    }
end

function wallInOne.libraryDomainSnapshot()
    return { library = library }
end

function wallInOne.widgetSettingsSnapshot()
    return {
        video_source = wallInOne.configuredVideoSource(),
        manual_pair_file = wallInOne.configuredManualPair(),
        workshop_id = wallInOne.configuredWorkshopId(),
    }
end

function wallInOne.statusSnapshot()
    return {
        protocol = 4,
        instance_id = SERVICE_NONCE,
        sequence = 0,
        ready = true,
        storage_valid = configValid and runtimeValid,
        config_valid = configValid,
        runtime_valid = runtimeValid,
        config_error = configError,
        runtime_error = runtimeError,
        config = {
            gestures = wallInOne.cloneGestures(config.gestures),
        },
        -- Settings are bounded and change independently from the persisted
        -- pairing/playlist document. Keeping them on the lifecycle object
        -- avoids serializing the heavy config domain for every settings edit.
        settings = wallInOne.settingsSnapshot(),
        providers = providers,
        domains = {
            config = { key = CONFIG_STATE_KEY, revision = domainPublications.config.revision },
            runtime = { key = RUNTIME_STATE_KEY, revision = domainPublications.runtime.revision },
            library = { key = LIBRARY_STATE_KEY, revision = domainPublications.library.revision },
        },
        captures = wallInOne.activeCapturesSnapshot(),
        last_action_error = lastActionError,
        last_action_at = lastActionAt,
    }
end

function wallInOne.markStateDomain(name)
    local publication = domainPublications[name]
    if type(publication) == "table" then
        publication.dirty = true
    end
end

function wallInOne.publishStateDomain(name, payload)
    local publication = domainPublications[name]
    if type(publication) ~= "table" or publication.dirty ~= true or type(payload) ~= "table" then
        return false
    end

    -- Mutation sites are the authority for heavy-domain dirtiness. Rewalking a
    -- bounded-but-large playlist/library document merely to rediscover that it
    -- changed duplicates the JSON traversal performed by state.set().
    publication.revision += 1

    local snapshot = {
        protocol = 1,
        instance_id = SERVICE_NONCE,
        revision = publication.revision,
    }
    for key, value in pairs(payload) do
        snapshot[key] = value
    end
    noctalia.state.set(publication.key, snapshot)
    publication.dirty = false
    return true
end

function wallInOne.flushStateDomains()
    if domainPublications.config.dirty == true then
        wallInOne.publishStateDomain("config", wallInOne.configDomainSnapshot())
    end
    if domainPublications.runtime.dirty == true then
        wallInOne.publishStateDomain("runtime", wallInOne.runtimeDomainSnapshot())
    end
    if domainPublications.library.dirty == true then
        wallInOne.publishStateDomain("library", wallInOne.libraryDomainSnapshot())
    end
end

function wallInOne.publishStatus()
    wallInOne.flushStateDomains()
    local snapshot = wallInOne.statusSnapshot()
    -- The lifecycle object is deliberately small. Native JSON encoding matches
    -- the state bus's own semantics and avoids a second recursive Luau walk.
    local signature = noctalia.json.encode(snapshot)
    if signature == lastStatusSignature then
        return false
    end
    lastStatusSignature = signature
    statusSequence += 1
    snapshot.sequence = statusSequence
    noctalia.state.set(STATUS_KEY, snapshot)
    return true
end

function wallInOne.notifyBounded(key, message)
    local now = wallInOne.nowSeconds()
    local previous = tonumber(lastNotificationAt[key]) or 0
    if now == 0 or previous == 0 or now - previous >= NOTIFY_COOLDOWN_SECONDS then
        lastNotificationAt[key] = now
        noctalia.notifyError(noctalia.tr("plugin.title"), message)
    end
end

function wallInOne.setActionError(message, notifyKey)
    lastActionError = tostring(message or "")
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    wallInOne.publishStatus()
    if notifyKey ~= nil and lastActionError ~= "" then
        wallInOne.notifyBounded(notifyKey, lastActionError)
    end
end

function wallInOne.deferUntilNextUpdate(callback)
    if type(callback) ~= "function" or #postApplyQueue >= MAX_RUNTIME_OUTPUTS then
        return false
    end
    table.insert(postApplyQueue, callback)
    return true
end

function wallInOne.drainPostApplyQueue()
    local queued = postApplyQueue
    postApplyQueue = {}
    for _, callback in ipairs(queued) do
        local ok, errorMessage = pcall(callback)
        if not ok then
            wallInOne.setActionError(noctalia.tr("errors.apply_callback", { detail = wallInOne.boundedDetail(errorMessage) }), nil)
        end
    end
end

function wallInOne.synchronizeInternalWorkshops(nextRendererStatus)
    local current = {}
    local outputs = type(nextRendererStatus) == "table"
            and type(nextRendererStatus.outputs) == "table"
            and nextRendererStatus.outputs
        or {}
    for output, owned in pairs(outputs) do
        local id = type(owned) == "table" and tostring(owned.workshop_id or "") or ""
        local state = type(owned) == "table" and tostring(owned.state or "") or ""
        if
            wallInOne.validPersistedKey(output)
            and type(owned) == "table"
            and owned.backend == "w-engine"
            and (state == "running" or state == "paused")
            and wallInOne.validWorkshopId(id)
        then
            current[output] = id
        end
    end
    providers.w_engine.internal_current = current
    runtime.current_workshops = current
end

function wallInOne.providerCurrentSignature()
    local current = {}
    for output, id in pairs(providers.w_engine.internal_current or {}) do
        table.insert(current, tostring(output) .. "=" .. tostring(id))
    end
    table.sort(current)
    return table.concat(current, ",")
end

function wallInOne.currentProviderSignature()
    return table.concat({
        tostring(providers.wallhaven.allowed),
        tostring(providers.wallhaven.available),
        tostring(providers.w_engine.command_available),
        tostring(providers.w_engine.renderer_ready),
        tostring(providers.w_engine.available),
        tostring(providers.w_engine.apply_available),
        wallInOne.providerCurrentSignature(),
        tostring(providers.mpvpaper.command_available),
        tostring(providers.mpvpaper.renderer_ready),
        tostring(providers.mpvpaper.available),
        tostring(providers.mpvpaper.apply_available),
        tostring(providers.motionbgs.allowed),
        tostring(providers.motionbgs.available),
        tostring(providers.motionbgs.browser_available),
        tostring(providers.motionbgs.integration_available),
        tostring(providers.motionbgs.binary_available),
        tostring(providers.motionbgs.binary_compatible),
        tostring(providers.motionbgs.binary_path),
        tostring(providers.motionbgs.binary_version),
        tostring(providers.motionbgs.probe_state),
        tostring(providers.motionbgs.availability_reason),
        tostring(colors.source),
        tostring(colors.scheme),
    }, "|")
end

function wallInOne.persistRuntimeIfChanged(force)
    if not runtimeValid then
        return false
    end
    local signature = wallInOne.currentProviderSignature()
    if not force and signature == providerSignature then
        return true
    end
    wallInOne.markStateDomain("runtime")
    providerSignature = signature
    runtime.providers = {
        wallhaven = {
            allowed = providers.wallhaven.allowed,
            available = providers.wallhaven.available,
        },
        w_engine = {
            command_available = providers.w_engine.command_available,
            renderer_ready = providers.w_engine.renderer_ready,
            available = providers.w_engine.available,
            apply_available = providers.w_engine.apply_available,
            internal_current = providers.w_engine.internal_current,
        },
        mpvpaper = {
            command_available = providers.mpvpaper.command_available,
            renderer_ready = providers.mpvpaper.renderer_ready,
            available = providers.mpvpaper.available,
            apply_available = providers.mpvpaper.apply_available,
        },
        motionbgs = providers.motionbgs,
        colors = { source = colors.source, scheme = colors.scheme },
    }
    runtime.observed_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    runtime.last_error = ""
    local saved, saveError = wallInOne.atomicWrite("runtime.json", runtime)
    if not saved then
        runtimeValid = false
        runtimeError = tostring(saveError or noctalia.tr("errors.runtime_save"))
        return false
    end
    return true
end

function wallInOne.anyOutputEngineEnabled(engine)
    local names = {}
    for output in pairs(type(config.outputs) == "table" and config.outputs or {}) do
        names[output] = true
    end
    for _, descriptor in ipairs(noctalia.outputs()) do
        local output = type(descriptor) == "table" and tostring(descriptor.name or descriptor.connector or "") or ""
        if output ~= "" then
            names[output] = true
        end
    end
    if next(names) == nil then
        return true
    end
    for output in pairs(names) do
        local engines = wallInOne.outputEngineSettings(output)
        local settings = if engine == "w_engine" then engines.workshop else engines.video
        if type(settings) == "table" and settings.enabled == true then
            return true
        end
    end
    return false
end

function wallInOne.refreshBackendPolicy()
    local rendererReady = type(rendererStatus) == "table" and rendererStatus.ready == true
    local previousWEngine = backendPolicySignature.w_engine
    local previousMpvpaper = backendPolicySignature.mpvpaper

    providers.w_engine.command_available = noctalia.commandExists("linux-wallpaperengine")
    providers.w_engine.renderer_ready = rendererReady
    providers.w_engine.available = providers.w_engine.command_available
    providers.w_engine.apply_available = rendererReady
        and providers.w_engine.command_available
        and wallInOne.anyOutputEngineEnabled("w_engine")
    providers.mpvpaper.command_available = noctalia.commandExists("mpvpaper")
    providers.mpvpaper.renderer_ready = rendererReady
    providers.mpvpaper.available = providers.mpvpaper.command_available
    providers.mpvpaper.apply_available = rendererReady
        and providers.mpvpaper.command_available
        and wallInOne.anyOutputEngineEnabled("mpvpaper")
    providers.motionbgs.allowed = wallInOne.settingBool("use_motionbgs", true)
    providers.motionbgs.browser_available = noctalia.commandExists("xdg-open")
    providers.motionbgs.integration_available = providers.motionbgs.allowed
        and type(motionBgsStatus) == "table"
        and motionBgsStatus.available == true
    providers.motionbgs.binary_available = type(motionBgsStatus) == "table"
        and motionBgsStatus.binary_available == true
    providers.motionbgs.binary_compatible = type(motionBgsStatus) == "table"
        and motionBgsStatus.binary_compatible == true
    providers.motionbgs.binary_path = if type(motionBgsStatus) == "table"
        then tostring(motionBgsStatus.binary_path or "")
        else ""
    providers.motionbgs.binary_version = if type(motionBgsStatus) == "table"
        then tostring(motionBgsStatus.binary_version or "")
        else ""
    providers.motionbgs.probe_state = if type(motionBgsStatus) == "table"
        then tostring(motionBgsStatus.probe_state or "")
        else ""
    providers.motionbgs.availability_reason = if type(motionBgsStatus) == "table"
        then tostring(motionBgsStatus.availability_reason or "")
        else ""
    providers.motionbgs.install_url = MOTIONBGS_HELPER_URL
    -- The direct website remains available independently from the optional
    -- external provider program.
    providers.motionbgs.available = providers.motionbgs.browser_available
    providers.motionbgs.url = MOTIONBGS_URL
    local nextWEngine = table.concat({
        tostring(rendererReady),
        tostring(providers.w_engine.command_available),
        tostring(providers.w_engine.apply_available),
    }, "|")
    local nextMpvpaper = table.concat({
        tostring(rendererReady),
        tostring(providers.mpvpaper.command_available),
        tostring(providers.mpvpaper.apply_available),
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

function wallInOne.applyIntegrationPolicy()
    providers.wallhaven.allowed = wallInOne.settingBool("use_wallhaven", true)
    providers.wallhaven.site_available = noctalia.commandExists("xdg-open")
    providers.wallhaven.site_url = WALLHAVEN_URL
    providers.wallhaven.available = providers.wallhaven.allowed and wallhavenStatus.available == true
    wallInOne.refreshBackendPolicy()
    if type(wallInOne.reconcileRendererOwnership) == "function" then
        wallInOne.reconcileRendererOwnership()
    end
end

function wallInOne.refreshAvailability()
    lastAvailabilityRefreshAt = wallInOne.nowSeconds()
    providers.noctalia_cli = noctalia.commandExists("noctalia")
    providers.w_engine.steam_available = noctalia.commandExists("steam") or noctalia.commandExists("xdg-open")
    providers.w_engine.steam_workshop_available = noctalia.commandExists("xdg-open")
    wallInOne.applyIntegrationPolicy()
    wallInOne.persistRuntimeIfChanged(false)
    wallInOne.publishStatus()
end

function wallInOne.probeColorScheme()
    if colorProbeInFlight or not noctalia.commandExists("noctalia") then
        return
    end
    colorProbeInFlight = true
    colors.probing = true
    local function finishProbe(errorMessage)
        colorProbeInFlight = false
        colors.probing = false
        colors.error = tostring(errorMessage or "")
        -- Theme mode/error are live observations but are intentionally absent
        -- from the persistence signature. Publish their runtime-domain delta
        -- even when source and scheme did not change.
        wallInOne.markStateDomain("runtime")
        wallInOne.persistRuntimeIfChanged(false)
        wallInOne.publishStatus()
    end
    local started = noctalia.runAsync("noctalia msg color-scheme-get", function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            finishProbe(wallInOne.commandFailureDetail(result))
            return
        end
        local source, scheme = noctalia.string.trim(result.stdout or ""):match("^(%S+)%s+(.+)$")
        colors.source = tostring(source or "")
        colors.scheme = tostring(scheme or "")
        local modeStarted = noctalia.runAsync("noctalia msg theme-mode-get", function(modeResult)
            if type(modeResult) ~= "table" or modeResult.timedOut or tonumber(modeResult.exitCode) ~= 0 then
                finishProbe(wallInOne.commandFailureDetail(modeResult))
                return
            end
            local mode = noctalia.string.trim(tostring(modeResult.stdout or ""))
            colors.mode = if mode == "dark" or mode == "light" then mode else ""
            finishProbe("")
        end, 5000)
        if not modeStarted then
            finishProbe(noctalia.tr("errors.color_probe_start"))
        end
    end, 5000)
    if not started then
        finishProbe(noctalia.tr("errors.color_probe_start"))
    end
end

-- Local media and Steam Workshop discovery ---------------------------------

function wallInOne.safeRelativePath(value)
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

function wallInOne.candidateWorkshopRoots()
    local roots = {}
    local seen = {}
    local custom = wallInOne.settingString("workshop_directory", "")
    if custom ~= "" then
        local expanded = wallInOne.normalizedDirectory(noctalia.expandPath(custom))
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

function wallInOne.currentLibraryRootsSignature()
    -- Only path changes require rebuilding the library candidates. Provider,
    -- playback, palette, and gesture settings do not alter the inventory.
    return table.concat({
        wallInOne.captureDirectory(),
        wallInOne.videoDirectory(),
        wallInOne.settingString("workshop_directory", ""),
    }, "\0")
end

function wallInOne.findWorkshopProject(id)
    if not wallInOne.validWorkshopId(id) then
        return nil, nil
    end
    for _, root in ipairs(wallInOne.candidateWorkshopRoots()) do
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

function wallInOne.libraryPathToken(path)
    local hashA = 0
    local hashB = 0
    path = tostring(path or "")
    for index = 1, #path do
        local byte = string.byte(path, index)
        hashA = (hashA * 131 + byte) % 2147483647
        hashB = (hashB * 65599 + byte + index) % 2147483629
    end
    return string.format("%08x%08x%08x", hashA, hashB, #path)
end

function wallInOne.readProviderSidecar(path, suffix, provider)
    local sidecarPath = tostring(path or "") .. suffix
    local raw = wallInOne.readBoundedRegularFile(sidecarPath, MAX_MANAGED_SIDECAR_BYTES)
    local record = type(raw) == "string" and #raw <= MAX_MANAGED_SIDECAR_BYTES and noctalia.json.decode(raw) or nil
    if
        type(record) ~= "table"
        or tonumber(record.schema) ~= 1
        or tostring(record.provider or "") ~= provider
        or tostring(record.plugin or "") ~= "goober/wall-in-one"
        or tostring(record.path or "") ~= tostring(path or "")
    then
        return nil
    end
    return record, sidecarPath
end

function wallInOne.appendLibraryDirectory(target, root, mediaType, ownership, provider, seen)
    root = wallInOne.normalizedDirectory(root)
    if root == nil then
        return
    end
    local entries = noctalia.listDir(root)
    if type(entries) ~= "table" then
        return
    end
    for index = 1, math.min(#entries, MAX_LIBRARY_CANDIDATES) do
        local name = tostring(entries[index] or "")
        if name ~= "" and not name:find("/", 1, true) and not name:find("[%c]") then
            local path = root .. "/" .. name
            local key = mediaType .. "\0" .. path
            if not seen[key] then
                seen[key] = true
                table.insert(target, {
                    path = path,
                    name = name,
                    media_type = mediaType,
                    ownership = ownership,
                    provider = provider,
                })
            end
        end
    end
end

wallInOne.refreshLibrary = function()
    local imageRoot = wallInOne.captureDirectory()
    local videoRoot = wallInOne.videoDirectory()
    local imageRootReady = wallInOne.existingDirectory(imageRoot)
    local videoRootReady = wallInOne.existingDirectory(videoRoot)
    local mediaEntries = {}
    local seenMedia = {}
    -- Managed roots must claim an overlapping explicit user root first. The
    -- incremental scan still verifies each sidecar and downgrades unproven
    -- files to user-owned entries.
    if imageRootReady then
        wallInOne.appendLibraryDirectory(
            mediaEntries,
            wallInOne.wallhavenManagedDirectory(),
            "image",
            "managed-wallhaven",
            "Wallhaven",
            seenMedia
        )
        wallInOne.appendLibraryDirectory(
            mediaEntries,
            wallInOne.automaticStillDirectory(),
            "image",
            "managed-auto",
            "Wall-in-One",
            seenMedia
        )
        wallInOne.appendLibraryDirectory(mediaEntries, imageRoot, "image", "user", "local", seenMedia)
    end
    if videoRootReady then
        wallInOne.appendLibraryDirectory(
            mediaEntries,
            wallInOne.motionBgsManagedDirectory(),
            "video",
            "managed-motionbgs",
            "MotionBGS",
            seenMedia
        )
        wallInOne.appendLibraryDirectory(mediaEntries, videoRoot, "video", "user", "local", seenMedia)
    end
    table.sort(mediaEntries, function(left, right)
        return tostring(left.path) < tostring(right.path)
    end)

    local workshopCandidates = {}
    local seenIds = {}
    local workshopNamesExamined = 0
    if imageRootReady then
        for _, root in ipairs(wallInOne.candidateWorkshopRoots()) do
            local ids = noctalia.listDir(root)
            if type(ids) == "table" then
                for _, candidate in ipairs(ids) do
                    workshopNamesExamined += 1
                    local id = tostring(candidate)
                    if wallInOne.validWorkshopId(id) and not seenIds[id] then
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
    end
    table.sort(workshopCandidates, function(left, right)
        return tostring(left.id) < tostring(right.id)
    end)

    libraryScan = {
        image_root = imageRoot,
        video_root = videoRoot,
        media_entries = mediaEntries,
        media_index = 1,
        workshop_candidates = workshopCandidates,
        workshop_index = 1,
        stills = {},
        videos = {},
        workshops = {},
        provider_installs = { wallhaven = {}, motionbgs = {} },
        representative_stills = { video = {}, workshop = {} },
        phase = "media",
    }
    library = {
        stills = type(library.stills) == "table" and library.stills or {},
        videos = type(library.videos) == "table" and library.videos or {},
        workshops = type(library.workshops) == "table" and library.workshops or {},
        provider_installs = type(library.provider_installs) == "table"
                and library.provider_installs
            or { wallhaven = {}, motionbgs = {} },
        representative_stills = type(library.representative_stills) == "table"
                and library.representative_stills
            or { video = {}, workshop = {} },
        scanned_at = tostring(library.scanned_at or ""),
        error = managedDirectoryError,
        scanning = true,
    }
    wallInOne.markStateDomain("library")
end

function wallInOne.stepLibraryScan()
    local scan = libraryScan
    if type(scan) ~= "table" then
        return false
    end
    local budget = LIBRARY_SCAN_BATCH
    while budget > 0 and scan.phase == "media" do
        local candidate = scan.media_entries[scan.media_index]
        if candidate == nil or (#scan.videos >= MAX_PLAYLIST_ENTRIES and #scan.stills >= MAX_PLAYLIST_ENTRIES) then
            scan.phase = "workshops"
            break
        end
        scan.media_index += 1
        budget -= 1
        local path = tostring(candidate.path or "")
        local name = tostring(candidate.name or path:match("([^/]+)$") or path)
        local info = noctalia.fileInfo(path)
        local extension = path:lower():match("(%.[%w]+)$") or ""
        local expectedMedia = tostring(candidate.media_type or "")
        local supported = if expectedMedia == "image"
            then SUPPORTED_IMAGE_EXTENSIONS[extension] == true
            else SUPPORTED_VIDEO_EXTENSIONS[extension] == true
        -- When both user roots are the same, classify animated GIF as video
        -- instead of showing the identical file in both sections.
        if expectedMedia == "image" and extension == ".gif" and scan.image_root == scan.video_root then
            supported = false
        end
        if type(info) == "table" and info.isDir ~= true and (tonumber(info.size) or 0) > 0 and supported then
            local entry = {
                id = expectedMedia .. ":" .. SERVICE_NONCE .. ":" .. wallInOne.libraryPathToken(path),
                path = path,
                name = name,
                size = tonumber(info.size) or 0,
                mtime = tonumber(info.mtime) or 0,
                media_type = expectedMedia,
                -- A path under a managed root is still ordinary user media
                -- until its exact provider sidecar validates below.
                provider = "local",
                ownership = "user",
                managed = false,
                deletable = false,
                sidecar = "",
            }
            if candidate.ownership == "managed-auto" then
                local record, sidecarPath = wallInOne.readManagedStillSidecar(path)
                if record ~= nil then
                    entry.ownership = "managed"
                    entry.managed = true
                    entry.deletable = true
                    entry.sidecar = sidecarPath
                    entry.dynamic_id = tostring(record.dynamic_id or "")
                    entry.provider = tostring(record.provider or "Wall-in-One")
                end
            elseif candidate.ownership == "managed-motionbgs" then
                local record, sidecarPath = wallInOne.readProviderSidecar(path, ".motionbgs.json", "MotionBGS")
                if record ~= nil then
                    entry.ownership = "managed"
                    entry.managed = true
                    entry.deletable = true
                    entry.sidecar = sidecarPath
                    entry.source_url = tostring(record.source_page or "")
                    entry.provider = "MotionBGS"
                    entry.provider_id = entry.source_url:match("^https://motionbgs%.com/([a-z0-9][a-z0-9%-]*)$") or ""
                    entry.quality = tostring(record.quality or ""):lower()
                    if entry.provider_id ~= "" and (entry.quality == "hd" or entry.quality == "4k") then
                        scan.provider_installs.motionbgs[entry.provider_id .. ":" .. entry.quality] = path
                    end
                end
            elseif candidate.ownership == "managed-wallhaven" then
                local record, sidecarPath = wallInOne.readProviderSidecar(path, ".wallhaven.json", "Wallhaven")
                if record ~= nil then
                    entry.ownership = "managed"
                    entry.managed = true
                    entry.deletable = true
                    entry.sidecar = sidecarPath
                    entry.source_url = tostring(record.source_page or "")
                    entry.provider = "Wallhaven"
                    entry.provider_id = tostring(record.id or "")
                    if entry.provider_id ~= "" then
                        scan.provider_installs.wallhaven[entry.provider_id:lower()] = path
                    end
                end
            end
            if expectedMedia == "video" then
                local pairedPreview = wallInOne.cachedPair("video:" .. path)
                entry.paired_preview = tostring(pairedPreview or "")
                if entry.paired_preview ~= "" then
                    scan.representative_stills.video[path] = entry.paired_preview
                end
            end
            if expectedMedia == "image" and #scan.stills < MAX_PLAYLIST_ENTRIES then
                table.insert(scan.stills, entry)
            elseif expectedMedia == "video" and #scan.videos < MAX_PLAYLIST_ENTRIES then
                table.insert(scan.videos, entry)
            end
        end
    end
    while budget > 0 and scan.phase == "workshops" do
        local candidate = scan.workshop_candidates[scan.workshop_index]
        if candidate == nil or #scan.workshops >= MAX_PLAYLIST_ENTRIES then
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
                local preview = wallInOne.safeRelativePath(project.preview or "preview.jpg")
                local pairedPreview = wallInOne.cachedPair(tostring(candidate.id or ""))
                local pairedPreviewPath = tostring(pairedPreview or "")
                if pairedPreviewPath ~= "" then
                    scan.representative_stills.workshop[tostring(candidate.id or "")] = pairedPreviewPath
                end
                table.insert(scan.workshops, {
                    id = candidate.id,
                    title = wallInOne.boundedDetail(project.title or ("Workshop " .. candidate.id)),
                    kind = wallInOne.boundedDetail(project.type or "unknown"),
                    directory = candidate.directory,
                    preview = if preview ~= nil then candidate.directory .. preview else "",
                    paired_preview = pairedPreviewPath,
                    ownership = "steam",
                    managed = false,
                    deletable = false,
                })
            end
        end
    end
    if scan.phase ~= "done" then
        return false
    end

    table.sort(scan.stills, function(left, right)
        return tostring(left.name):lower() < tostring(right.name):lower()
    end)
    table.sort(scan.videos, function(left, right)
        return tostring(left.name):lower() < tostring(right.name):lower()
    end)
    table.sort(scan.workshops, function(left, right)
        return tostring(left.title):lower() < tostring(right.title):lower()
    end)
    library = {
        stills = scan.stills,
        videos = scan.videos,
        workshops = scan.workshops,
        provider_installs = scan.provider_installs,
        representative_stills = scan.representative_stills,
        scanned_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        error = managedDirectoryError,
        scanning = false,
    }
    libraryScan = nil
    wallInOne.markStateDomain("library")
    return true
end

-- Still capture, pairing, palettes, and serialized wallpaper application ---

function wallInOne.captureHelper()
    local pluginDirectory = noctalia.pluginDir()
    if type(pluginDirectory) ~= "string" or pluginDirectory == "" then
        return nil
    end
    local path = pluginDirectory .. "/scripts/capture-still"
    return if noctalia.fileExists(path) then path else nil
end

function wallInOne.sanitizedName(value)
    local cleaned = tostring(value or ""):gsub("[^%w._-]", "-"):gsub("%-+", "-")
    cleaned = cleaned:gsub("^%-", ""):gsub("%-$", "")
    if #cleaned > 64 then
        cleaned = cleaned:sub(1, 64)
    end
    return if cleaned == "" then "wallpaper" else cleaned
end

function wallInOne.stablePathTag(value)
    -- A deterministic, non-cryptographic tag prevents equal basename/size/
    -- mtime files in different directories from sharing a capture filename.
    local hash = 0
    value = tostring(value or "")
    for index = 1, #value do
        hash = (hash * 131 + string.byte(value, index)) % 2147483647
    end
    return string.format("%08x", hash)
end

function wallInOne.fileExtension(path)
    return tostring(path or ""):lower():match("(%.[%w]+)$") or ""
end

function wallInOne.captureDestination(prefix, identity, output, extension, managedAutomatic)
    local directory = if managedAutomatic == true then wallInOne.automaticStillDirectory() else wallInOne.captureDirectory()
    local imageRoot = wallInOne.captureDirectory()
    if directory == "" or not wallInOne.existingDirectory(imageRoot) then
        return nil, noctalia.tr("errors.capture_directory")
    end
    local ok = true
    local directoryError = nil
    if managedAutomatic == true then
        ok, directoryError = wallInOne.ensureManagedDirectory(directory, "automatic-stills")
    end
    if ok ~= true then
        return nil, tostring(directoryError or noctalia.tr("errors.capture_directory"))
    end
    local separator = if directory == "/" then "" else "/"
    return directory
        .. separator
        .. "wall-in-one-"
        .. wallInOne.sanitizedName(prefix)
        .. "-"
        .. wallInOne.sanitizedName(identity)
        .. "-"
        .. wallInOne.sanitizedName(output or "all")
        .. extension,
        nil
end

function wallInOne.directChildOf(path, directory)
    path = tostring(path or "")
    directory = wallInOne.normalizedDirectory(directory)
    if directory == nil or path:sub(1, #directory + 1) ~= directory .. "/" then
        return false
    end
    local name = path:sub(#directory + 2)
    return name ~= "" and not name:find("/", 1, true) and not name:find("[%c]")
end

function wallInOne.managedStillSidecar(path)
    return tostring(path or "") .. MANAGED_SIDECAR_SUFFIX
end

wallInOne.readManagedStillSidecar = function(path)
    if not wallInOne.directChildOf(path, wallInOne.automaticStillDirectory()) then
        return nil
    end
    local sidecarPath = wallInOne.managedStillSidecar(path)
    local raw = wallInOne.readBoundedRegularFile(sidecarPath, MAX_MANAGED_SIDECAR_BYTES)
    local record = type(raw) == "string" and #raw <= MAX_MANAGED_SIDECAR_BYTES and noctalia.json.decode(raw) or nil
    if
        type(record) ~= "table"
        or tonumber(record.schema) ~= 1
        or record.plugin ~= "goober/wall-in-one"
        or record.kind ~= "automatic-still"
        or record.path ~= path
        or type(record.dynamic_id) ~= "string"
        or record.dynamic_id == ""
    then
        return nil
    end
    return record, sidecarPath
end

function wallInOne.writeManagedStillSidecar(request, path)
    if type(request) ~= "table" or request.managed_auto ~= true then
        return true, nil
    end
    local directory = wallInOne.automaticStillDirectory()
    if not wallInOne.directChildOf(path, directory) then
        return false, noctalia.tr("errors.managed_path")
    end
    local markerOk, markerError = wallInOne.ensureManagedDirectory(directory, "automatic-stills")
    if not markerOk then
        return false, markerError
    end
    local sidecarPath = wallInOne.managedStillSidecar(path)
    local encoded, encodeError = noctalia.json.encode({
        schema = 1,
        plugin = "goober/wall-in-one",
        kind = "automatic-still",
        path = path,
        provider = tostring(request.provider or ""),
        dynamic_id = tostring(request.dynamic_id or ""),
        source = tostring(type(request.spec) == "table" and request.spec.source or ""),
        created_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
    }, true)
    if type(encoded) ~= "string" then
        return false, tostring(encodeError or noctalia.tr("errors.encode"))
    end
    local temporary = sidecarPath .. ".tmp"
    local wrote, writeError = noctalia.writeFile(temporary, encoded .. "\n")
    if wrote ~= true then
        return false, tostring(writeError or noctalia.tr("errors.write"))
    end
    local installed, installError = noctalia.renameFile(temporary, sidecarPath)
    if installed ~= true then
        noctalia.removeFile(temporary)
        return false, tostring(installError or noctalia.tr("errors.install"))
    end
    request.sidecar_path = sidecarPath
    return true, nil
end

function wallInOne.captureStagingPath(requestId)
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

function wallInOne.cleanupOwnedStaging()
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

function wallInOne.workshopFallbackSpec(id)
    local info, directory = wallInOne.findWorkshopProject(id)
    local kind = string.lower(tostring(type(info) == "table" and info.type or ""))
    local file = wallInOne.safeRelativePath(type(info) == "table" and info.file or nil)
    if kind == "video" and file ~= nil and noctalia.commandExists("ffmpeg") then
        local source = directory .. file
        if noctalia.fileExists(source) then
            return {
                mode = "video",
                source = source,
                extension = ".png",
                value = wallInOne.settingInt("video_frame_second", 1, 0, 3600),
                method = "ffmpeg-video-frame",
            }
        end
    end

    local preview = wallInOne.safeRelativePath(type(info) == "table" and info.preview or "preview.jpg")
    if directory ~= nil and preview ~= nil then
        local source = directory .. preview
        local extension = wallInOne.fileExtension(source)
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

function wallInOne.videoCaptureSpec(sourceOverride)
    local source = tostring(sourceOverride or "")
    if source == "" then
        source = wallInOne.configuredVideoSource()
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
        value = wallInOne.settingInt("video_frame_second", 1, 0, 3600),
        method = "ffmpeg-video-frame",
    }
end

function wallInOne.paletteInventoryContains(source, selection)
    local palettes = type(palettesStatus.palettes) == "table" and palettesStatus.palettes or palettesStatus
    for _, item in ipairs(type(palettes[source]) == "table" and palettes[source] or {}) do
        if type(item) == "table" and tostring(item.name or "") == selection then
            return true
        end
    end
    return false
end

function wallInOne.resolvedPalettePolicy(candidate)
    local requested = wallInOne.normalizedTheme(candidate) or wallInOne.legacyThemePolicy()
    if requested.source == "inherit" then
        return requested, requested, false, ""
    end
    local inventoryPending = (requested.source == "community" or requested.source == "custom")
        and palettesStatus.ready ~= true
    local available = inventoryPending
        or (requested.source == "wallpaper" and VALID_COLOR_SCHEMES[requested.selection] == true)
        or (requested.source == "builtin" and BUILTIN_PALETTES[requested.selection] == true)
        or (
            (requested.source == "community" or requested.source == "custom")
            and wallInOne.paletteInventoryContains(requested.source, requested.selection)
        )
    if available then
        return requested, requested, false, ""
    end
    return requested,
        { mode = requested.mode, source = "builtin", selection = "Noctalia" },
        true,
        noctalia.tr("errors.palette_missing", { source = requested.source, selection = requested.selection })
end

function wallInOne.connectedOutputNames()
    local names = {}
    for _, outputInfo in ipairs(noctalia.outputs()) do
        local name = tostring(outputInfo.name or "")
        if name ~= "" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

function wallInOne.resolvedPaletteAuthority(preferred)
    local configured = wallInOne.settingString("palette_output", "")
    if configured ~= "" and wallInOne.knownOutputName(configured) ~= nil then
        return configured
    end
    if configured == "" and wallInOne.knownOutputName(preferred) ~= nil then
        return preferred
    end
    return wallInOne.connectedOutputNames()[1] or ""
end

function wallInOne.pairProvider(dynamicId)
    if tostring(dynamicId):match("^video:") then
        return "video"
    elseif tostring(dynamicId):match("^manual:") then
        return "manual"
    elseif tostring(dynamicId):match("^static:") then
        return "noctalia"
    end
    return "w_engine"
end

function wallInOne.dynamicSourceFingerprint(dynamicId)
    dynamicId = tostring(dynamicId or "")
    local info = nil
    if dynamicId:sub(1, 6) == "video:" then
        info = noctalia.fileInfo(dynamicId:sub(7))
    elseif wallInOne.validWorkshopId(dynamicId) then
        local _project, directory = wallInOne.findWorkshopProject(dynamicId)
        if directory ~= nil then
            info = noctalia.fileInfo(directory .. "project.json")
        end
    end
    if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) <= 0 then
        return nil, nil
    end
    return math.floor(tonumber(info.size) or 0), math.floor(tonumber(info.mtime) or 0)
end

function wallInOne.recordPairRegistry(dynamicId, path, method, managedStill, sidecarPath, pairedAt)
    local stillInfo = noctalia.fileInfo(path)
    local sourceSize, sourceMtime = wallInOne.dynamicSourceFingerprint(dynamicId)
    local provider = wallInOne.pairProvider(dynamicId)
    local record = {
        provider = provider,
        dynamic_id = dynamicId,
        still_path = path,
        capture_method = method,
        paired_at = tostring(pairedAt or noctalia.formatTime("%Y-%m-%d %H:%M:%S")),
        still_size = type(stillInfo) == "table" and (tonumber(stillInfo.size) or 0) or 0,
        still_mtime = type(stillInfo) == "table" and (tonumber(stillInfo.mtime) or 0) or 0,
        source_size = tonumber(sourceSize) or 0,
        source_mtime = tonumber(sourceMtime) or 0,
        still_managed = managedStill == true,
        still_origin = if managedStill == true then "managed-auto" else "user",
        sidecar_path = if managedStill == true then tostring(sidecarPath or wallInOne.managedStillSidecar(path)) else "",
    }
    runtime.pair_registry[tostring(dynamicId)] = record
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
    return record
end

function wallInOne.recordAppliedPair(output, dynamicId, path, method, managedStill, sidecarPath, theme)
    local key = output or "all"
    local pairedAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    local registry = wallInOne.recordPairRegistry(
        dynamicId,
        path,
        method,
        managedStill,
        sidecarPath,
        pairedAt
    )
    runtime.pairs[key] = {
        provider = registry.provider,
        dynamic_id = registry.dynamic_id,
        still_path = registry.still_path,
        capture_method = registry.capture_method,
        paired_at = registry.paired_at,
        color_source_before = colors.source,
        color_scheme_before = colors.scheme,
        color_scheme = if type(theme) == "table" and theme.source ~= "inherit" then theme.selection else "unchanged",
        still_size = registry.still_size,
        still_mtime = registry.still_mtime,
        source_size = registry.source_size,
        source_mtime = registry.source_mtime,
        still_managed = registry.still_managed,
        still_origin = registry.still_origin,
        sidecar_path = registry.sidecar_path,
    }
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

    lastActionAt = runtime.pairs[key].paired_at
    lastActionError = ""
    wallInOne.persistRuntimeIfChanged(true)
end

function wallInOne.applyThemePolicy(request, onComplete)
    local requested, applied, usedFallback, fallbackReason = wallInOne.resolvedPalettePolicy(request.theme)
    local requestedRecord = {
        mode = requested.mode,
        source = requested.source,
        selection = requested.selection,
        output = request.output,
        playlist = tostring(request.playlist_id or ""),
        entry = tostring(request.entry_id or ""),
        fallback = false,
        resolution = "requested",
        applied_at = "",
    }
    runtime.palette.authority_output = tostring(request.authority_output or "")
    runtime.palette.requested = requestedRecord

    if requested.source == "inherit" then
        runtime.palette.last_error = ""
        wallInOne.persistRuntimeIfChanged(true)
        onComplete(true, "")
        return
    end
    if not noctalia.commandExists("noctalia") then
        local failure = noctalia.tr("errors.color_cli")
        runtime.palette.last_error = failure
        wallInOne.persistRuntimeIfChanged(true)
        onComplete(false, failure)
        return
    end

    local function stillCurrent()
        if type(request.should_apply) ~= "function" then
            return true
        end
        local checked, current = pcall(request.should_apply)
        return checked and current == true
    end
    local function fail(message)
        message = tostring(message or noctalia.tr("errors.color_sync_start"))
        runtime.palette.last_error = message
        wallInOne.persistRuntimeIfChanged(true)
        onComplete(false, message)
    end
    local function applyPalette()
        if not stillCurrent() then
            fail(noctalia.tr("errors.capture_replaced"))
            return
        end
        local command = "noctalia msg color-scheme-set "
            .. wallInOne.shellQuote(applied.source)
            .. " "
            .. wallInOne.shellQuote(applied.selection)
        local started = noctalia.runAsync(command, function(result)
            if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
                fail(noctalia.tr("errors.color_sync", { detail = wallInOne.commandFailureDetail(result) }))
                return
            end
            colors.source = applied.source
            colors.scheme = applied.selection
            colors.mode = applied.mode
            colors.error = ""
            runtime.palette.applied = {
                mode = applied.mode,
                source = applied.source,
                selection = applied.selection,
                output = request.output,
                playlist = tostring(request.playlist_id or ""),
                entry = tostring(request.entry_id or ""),
                fallback = usedFallback,
                resolution = if usedFallback
                    then "degraded"
                    elseif applied.source == "community" then "pending"
                    else "assumed",
                applied_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
            }
            runtime.palette.last_error = fallbackReason
            wallInOne.persistRuntimeIfChanged(true)
            onComplete(true, fallbackReason)
        end, 5000)
        if not started then
            fail(noctalia.tr("errors.color_sync_start"))
        end
    end

    if applied.mode == "inherit" then
        applyPalette()
        return
    end
    local started = noctalia.runAsync("noctalia msg theme-mode-set " .. wallInOne.shellQuote(applied.mode), function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            fail(noctalia.tr("errors.theme_mode", { detail = wallInOne.commandFailureDetail(result) }))
            return
        end
        applyPalette()
    end, 5000)
    if not started then
        fail(noctalia.tr("errors.theme_mode_start"))
    end
end

function wallInOne.runPairedStill(request, onComplete)
    local output = request.output
    local dynamicId = tostring(request.dynamic_id or "")
    local path = tostring(request.path or "")
    local method = tostring(request.method or "")
    local notifySuccess = request.notify == true
    local managedStill = request.managed == true
    local sidecarPath = tostring(request.sidecar_path or "")
    local themePolicy = request.theme
    local shouldApply = request.should_apply
    local paletteAllowed = request.palette_allowed
    local playlistId = tostring(request.playlist_id or "")
    local entryId = tostring(request.entry_id or "")
    local recordPair = request.record_pair ~= false
    local completed = false
    local function finish(ok, errorMessage)
        if completed then
            return
        end
        completed = true
        if ok ~= true and tostring(errorMessage or "") ~= "" then
            wallInOne.setActionError(tostring(errorMessage), "apply-still")
        end
        -- Queue the dynamic renderer continuation before any observational
        -- publication. Noctalia callbacks have a finite CPU budget, so status
        -- work must never strand a successfully applied backing still.
        if type(onComplete) == "function" then
            onComplete(ok == true, path, errorMessage)
        end
        if ok == true and notifySuccess then
            noctalia.notify(noctalia.tr("plugin.title"), noctalia.tr("notifications.paired", { path = path }))
        end
        wallInOne.publishStatus()
    end
    local function stillCurrent()
        if output ~= nil and wallInOne.knownOutputName(output) == nil then
            return false
        end
        if type(shouldApply) ~= "function" then
            return true
        end
        local checked, current = pcall(shouldApply)
        return checked and current == true
    end
    local info = noctalia.fileInfo(path)
    if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) <= 0 then
        finish(false, noctalia.tr("errors.playlist_still_missing", { path = tostring(path or "") }))
        return false
    end
    if not stillCurrent() then
        finish(false, noctalia.tr("errors.capture_replaced"))
        return false
    end
    if not noctalia.commandExists("noctalia") then
        finish(false, noctalia.tr("errors.noctalia_cli"))
        return false
    end

    local command = "noctalia msg wallpaper-set "
    if output ~= nil then
        command ..= wallInOne.shellQuote(output) .. " "
    end
    command ..= wallInOne.shellQuote(path)
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            finish(false, noctalia.tr("errors.wallpaper_apply", { detail = wallInOne.commandFailureDetail(result) }))
            return
        end
        if not stillCurrent() then
            finish(false, noctalia.tr("errors.capture_replaced"))
            return
        end
        local requestedTheme = wallInOne.normalizedTheme(themePolicy) or wallInOne.legacyThemePolicy()
        if recordPair then
            wallInOne.recordAppliedPair(output, dynamicId, path, method, managedStill, sidecarPath, requestedTheme)
        end

        local authority = wallInOne.resolvedPaletteAuthority(output)
        local configuredAuthority = wallInOne.settingString("palette_output", "")
        local mayApplyPalette = paletteAllowed ~= false and (configuredAuthority == "" or output == authority)
        if not mayApplyPalette or requestedTheme.source == "inherit" then
            -- During a coordinated multi-output switch the selected authority
            -- is applied last. An isolated non-authority switch restores the
            -- authority's persisted still so wallpaper-derived global colors
            -- do not drift to the wrong display.
            if paletteAllowed == nil and configuredAuthority ~= "" and authority ~= "" and authority ~= output then
                local authorityPair = runtime.pairs[authority]
                local authorityPath = type(authorityPair) == "table" and tostring(authorityPair.still_path or "") or ""
                if authorityPath ~= "" and noctalia.fileExists(authorityPath) then
                    local restoreStarted = noctalia.runAsync(
                        "noctalia msg wallpaper-set " .. wallInOne.shellQuote(authority) .. " " .. wallInOne.shellQuote(authorityPath),
                        function(restoreResult)
                            if
                                type(restoreResult) ~= "table"
                                or restoreResult.timedOut
                                or tonumber(restoreResult.exitCode) ~= 0
                            then
                                finish(false, noctalia.tr("errors.palette_authority_restore"))
                            else
                                local authorityTheme = wallInOne.normalizedTheme(runtime.palette.requested)
                                if authorityTheme == nil or authorityTheme.source == "inherit" then
                                    finish(true, nil)
                                else
                                    wallInOne.applyThemePolicy({
                                        output = authority,
                                        authority_output = authority,
                                        playlist_id = runtime.palette.requested.playlist,
                                        entry_id = runtime.palette.requested.entry,
                                        theme = authorityTheme,
                                    }, function(themeOk, themeError)
                                        finish(themeOk, if themeOk == true then nil else themeError)
                                    end)
                                end
                            end
                        end,
                        5000
                    )
                    if not restoreStarted then
                        finish(false, noctalia.tr("errors.palette_authority_restore"))
                    end
                    return
                end
                local failure = noctalia.tr("errors.palette_authority_restore")
                runtime.palette.authority_output = authority
                runtime.palette.last_error = failure
                wallInOne.persistRuntimeIfChanged(true)
                wallInOne.notifyBounded("palette-authority-restore", failure)
            end
            finish(true, nil)
            return
        end
        wallInOne.applyThemePolicy({
            output = output,
            authority_output = authority,
            playlist_id = playlistId,
            entry_id = entryId,
            theme = requestedTheme,
            should_apply = shouldApply,
        }, function(ok, paletteMessage)
            if ok == true and paletteMessage ~= "" then
                wallInOne.notifyBounded("palette-fallback", paletteMessage)
            end
            finish(ok, if ok == true then nil else paletteMessage)
        end)
    end, 7000)
    if not started then
        finish(false, noctalia.tr("errors.wallpaper_apply_start"))
        return false
    end
    return true
end

function wallInOne.applyPairedStill(request)
    if type(request) ~= "table" then
        return false
    end
    local outputKey = tostring(request.output or "all")
    if wallpaperApplyInFlight ~= nil then
        for index = #wallpaperApplyQueued, 1, -1 do
            local queued = wallpaperApplyQueued[index]
            if type(queued) == "table" and tostring(queued.output or "all") == outputKey then
                table.remove(wallpaperApplyQueued, index)
                if type(queued.on_complete) == "function" then
                    pcall(queued.on_complete, false, nil, noctalia.tr("errors.capture_replaced"))
                end
                break
            end
        end
        if #wallpaperApplyQueued >= 64 then
            if type(request.on_complete) == "function" then
                pcall(request.on_complete, false, nil, noctalia.tr("errors.apply_queue_full"))
            end
            return false
        end
        table.insert(wallpaperApplyQueued, request)
        return true
    end

    local function start(current)
        wallpaperApplyInFlight = current
        return wallInOne.runPairedStill(current, function(ok, path, errorMessage)
            if wallpaperApplyInFlight == current then
                wallpaperApplyInFlight = nil
            end
            local nextRequest = table.remove(wallpaperApplyQueued, 1)
            if type(nextRequest) == "table" then
                start(nextRequest)
            end
            if type(current.on_complete) == "function" then
                local callbackOk, callbackError = pcall(current.on_complete, ok, path, errorMessage)
                if not callbackOk then
                    wallInOne.setActionError(
                        noctalia.tr("errors.capture_callback", { detail = wallInOne.boundedDetail(callbackError) }),
                        nil
                    )
                end
            end
        end)
    end
    return start(request)
end

function wallInOne.reassertPaletteAuthority(onComplete)
    paletteAuthorityGeneration += 1
    local generation = paletteAuthorityGeneration
    local authority = wallInOne.resolvedPaletteAuthority(nil)
    local pair = authority ~= "" and runtime.pairs[authority] or nil
    local path = type(pair) == "table" and tostring(pair.still_path or "") or ""
    if authority == "" or path == "" or not noctalia.fileExists(path) then
        onComplete(false, noctalia.tr("errors.palette_authority_restore"))
        return
    end
    local requested = type(runtime.palette.requested) == "table" and runtime.palette.requested or {}
    local theme = wallInOne.normalizedTheme(requested) or { mode = "inherit", source = "inherit", selection = "" }
    wallInOne.applyPairedStill({
        output = authority,
        dynamic_id = tostring(pair.dynamic_id or ""),
        path = path,
        method = tostring(pair.capture_method or "palette-authority-restore"),
        notify = false,
        managed = pair.still_managed == true,
        sidecar_path = tostring(pair.sidecar_path or ""),
        theme = theme,
        playlist_id = tostring(requested.playlist or ""),
        entry_id = tostring(requested.entry or ""),
        palette_allowed = true,
        record_pair = false,
        should_apply = function()
            return paletteAuthorityGeneration == generation
                and wallInOne.resolvedPaletteAuthority(nil) == authority
                and wallInOne.knownOutputName(authority) ~= nil
        end,
        on_complete = function(ok, _path, errorMessage)
            onComplete(ok == true, if ok == true then "" else tostring(errorMessage or ""))
        end,
    })
end

function wallInOne.reconcilePaletteAuthority(reapply)
    local nextAuthority = wallInOne.resolvedPaletteAuthority(nil)
    local changed = nextAuthority ~= paletteAuthorityOutput
    paletteAuthorityOutput = nextAuthority
    runtime.palette.authority_output = nextAuthority
    wallInOne.persistRuntimeIfChanged(changed)
    if
        reapply == true
        and changed
        and nextAuthority ~= ""
        and type(runtime.palette.requested) == "table"
        and next(runtime.palette.requested) ~= nil
    then
        wallInOne.reassertPaletteAuthority(function(ok, errorMessage)
            if ok ~= true then
                runtime.palette.last_error = tostring(errorMessage or noctalia.tr("errors.palette_authority_restore"))
                wallInOne.persistRuntimeIfChanged(true)
                wallInOne.publishStatus()
            end
        end)
    end
    return changed
end

function wallInOne.releaseCaptureSlot(key)
    captureInFlight[key] = nil
    activeCaptureRequests[key] = nil
    pendingInternalCaptures[key] = nil
end

function wallInOne.drainInternalCapture(key)
    local queuedInternal = internalCaptureQueued[key]
    internalCaptureQueued[key] = nil
    if type(queuedInternal) == "table" and type(wallInOne.requestInternalCapture) == "function" then
        wallInOne.requestInternalCapture(queuedInternal)
    end
end

function wallInOne.drainCaptureQueues(key)
    local queued = captureQueued[key]
    captureQueued[key] = nil
    if type(queued) == "table" then
        wallInOne.runCapture(queued)
    end
    wallInOne.drainInternalCapture(key)
end

function wallInOne.finishCapture(key, request, ok, errorMessage)
    local slot = captureInFlight[key]
    if type(slot) == "table" then
        slot.deadline = 0
        slot.phase = if ok == true and request.pair == true then "applying" else "finishing"
    end
    pendingInternalCaptures[key] = nil
    if
        type(request.staging_path) == "string"
        and request.staging_path ~= ""
        and noctalia.fileExists(request.staging_path)
    then
        noctalia.removeFile(request.staging_path)
    end
    if ok then
        local finalPath = tostring(request.pair_path or request.destination)
        local sidecarOk, sidecarError = wallInOne.writeManagedStillSidecar(request, finalPath)
        if sidecarOk ~= true then
            if request.managed_auto == true and noctalia.fileExists(finalPath) then
                noctalia.removeFile(finalPath)
            end
            local failure = tostring(sidecarError or noctalia.tr("errors.managed_sidecar"))
            wallInOne.setActionError(failure, "capture")
            if type(request.on_complete) == "function" then
                pcall(request.on_complete, false, nil, failure)
            end
            wallInOne.releaseCaptureSlot(key)
            wallInOne.publishStatus()
            wallInOne.drainCaptureQueues(key)
            return
        end
        local pairIsCurrent = true
        if request.pair and type(request.output) == "string" and request.output ~= "" then
            pairIsCurrent = wallInOne.knownOutputName(request.output) ~= nil
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
        if request.cache_pair == true then
            wallInOne.recordPairRegistry(
                tostring(request.dynamic_id or ""),
                finalPath,
                tostring(type(request.spec) == "table" and request.spec.method or "prepared-still"),
                request.managed_auto == true,
                request.sidecar_path,
                runtime.last_capture.captured_at
            )
        end
        if request.managed_auto == true then
            -- The library scan hydrates paired_preview for its owning dynamic
            -- item. Coalesce that enumeration onto update(); never enumerate
            -- directories from this async completion callback.
            libraryRefreshPending = true
        end
        if pairIsCurrent or not request.pair then
            lastActionError = ""
            lastActionAt = runtime.last_capture.captured_at
        end
        wallInOne.persistRuntimeIfChanged(true)
        if request.pair and pairIsCurrent then
            wallInOne.applyPairedStill({
                output = request.output,
                dynamic_id = request.dynamic_id,
                path = finalPath,
                method = request.spec.method,
                notify = request.notify,
                managed = request.managed_auto == true,
                sidecar_path = request.sidecar_path,
                theme = request.theme,
                should_apply = request.should_apply,
                palette_allowed = request.palette_allowed,
                playlist_id = request.playlist_id,
                entry_id = request.entry_id,
                on_complete = function(applied, appliedPath, applyError)
                    wallInOne.releaseCaptureSlot(key)
                    if type(request.on_complete) == "function" then
                        local callbackOk, callbackError = pcall(
                            request.on_complete,
                            applied == true,
                            appliedPath,
                            applyError
                        )
                        if not callbackOk then
                            wallInOne.setActionError(
                                noctalia.tr("errors.capture_callback", { detail = wallInOne.boundedDetail(callbackError) }),
                                nil
                            )
                        end
                    end
                    wallInOne.publishStatus()
                    wallInOne.drainCaptureQueues(key)
                end,
            })
            return
        elseif not request.pair and request.notify then
            noctalia.notify(noctalia.tr("plugin.title"), noctalia.tr("notifications.captured", { path = finalPath }))
        end
        if type(request.on_complete) == "function" then
            local callbackOk, callbackError = pcall(request.on_complete, not request.pair or pairIsCurrent, finalPath)
            if not callbackOk then
                wallInOne.setActionError(noctalia.tr("errors.capture_callback", { detail = wallInOne.boundedDetail(callbackError) }), nil)
            end
        end
    else
        local failure = tostring(errorMessage or noctalia.tr("errors.capture_failed"))
        wallInOne.setActionError(failure, "capture")
        if type(request.on_complete) == "function" then
            pcall(request.on_complete, false, nil, failure)
        end
    end
    wallInOne.publishStatus()

    wallInOne.releaseCaptureSlot(key)
    wallInOne.drainCaptureQueues(key)
end

wallInOne.runCapture = function(request)
    local key = tostring(request.capture_key or request.output or "all")
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
            pcall(replaced.on_complete, false, nil, noctalia.tr("errors.capture_replaced"))
        end
        captureQueued[key] = request
        return
    end
    if request.cache_pair == true then
        local cachedPath = wallInOne.cachedPair(tostring(request.dynamic_id or ""))
        if cachedPath ~= nil then
            if type(request.on_complete) == "function" then
                pcall(request.on_complete, true, cachedPath)
            end
            return
        end
    end
    -- Re-run the atomic helper for a destination that already exists. Pair
    -- registry fingerprints provide the normal cache fast path; a cache miss
    -- must decode-validate/re-extract instead of trusting replaced bytes.
    local helper = wallInOne.captureHelper()
    if helper == nil then
        wallInOne.finishCapture(key, request, false, noctalia.tr("errors.capture_helper"))
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
    wallInOne.publishStatus()
    local command = table.concat({
        "bash",
        wallInOne.shellQuote(helper),
        wallInOne.shellQuote(request.spec.mode),
        wallInOne.shellQuote(request.spec.source),
        wallInOne.shellQuote(request.destination),
        wallInOne.shellQuote(tostring(request.spec.value or "")),
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
            wallInOne.finishCapture(key, request, true, nil)
        else
            wallInOne.finishCapture(
                key,
                request,
                false,
                noctalia.tr("errors.capture_failed_detail", { detail = wallInOne.commandFailureDetail(result) })
            )
        end
    end, 60000)
    if not started then
        wallInOne.finishCapture(key, request, false, noctalia.tr("errors.capture_start"))
    end
end

function wallInOne.captureWorkshopFallback(options)
    options = type(options) == "table" and options or {}
    local output = options.output
    local id = options.id
    local force = options.force == true
    local pair = options.pair == true
    local notifySuccess = options.notify == true
    local onComplete = options.on_complete
    local shouldApply = options.should_apply
    local managedAutomatic = options.managed_auto == true
    local themePolicy = options.theme
    local paletteAllowed = options.palette_allowed
    local playlistId = options.playlist_id
    local entryId = options.entry_id
    local cachePair = options.cache_pair == true
    local captureKey = options.capture_key
    output = wallInOne.targetOutput(output)
    id = tostring(id or "")
    if output == nil or not wallInOne.validWorkshopId(id) then
        wallInOne.setActionError(noctalia.tr("errors.no_current_scene"), "capture-current")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return false
    end
    local spec, specError = wallInOne.workshopFallbackSpec(id)
    if spec == nil then
        wallInOne.setActionError(specError, "capture-source")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return false
    end
    local destination, destinationError = wallInOne.captureDestination(
        "w-engine",
        id,
        output,
        spec.extension,
        managedAutomatic == true
    )
    if destination == nil then
        wallInOne.setActionError(destinationError, "capture-directory")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return false
    end
    wallInOne.runCapture({
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
        managed_auto = managedAutomatic == true,
        theme = themePolicy,
        palette_allowed = paletteAllowed,
        playlist_id = playlistId,
        entry_id = entryId,
        cache_pair = cachePair,
        capture_key = captureKey,
    })
    return true
end

function wallInOne.captureCurrent(output, force, pair, notifySuccess)
    output = wallInOne.targetOutput(output)
    local owned = output ~= nil and type(rendererStatus.outputs) == "table" and rendererStatus.outputs[output] or nil
    local internalId = type(owned) == "table" and tostring(owned.workshop_id or "") or ""
    local id = if wallInOne.validWorkshopId(internalId) then internalId else nil
    if id == nil or tostring(id) == "" then
        id = wallInOne.configuredWorkshopId()
    end
    if id == nil or tostring(id) == "" then
        wallInOne.setActionError(noctalia.tr("errors.no_current_scene"), "capture-current")
        return
    end
    local applyToken = output ~= nil and (tonumber(applyGeneration[output]) or 0) or 0
    if output ~= nil then
        applyGeneration[output] = applyToken
    end
    local observedInternal = wallInOne.validWorkshopId(internalId) and internalId == tostring(id)
    local function captureStillCurrent()
        if
            output == nil
            or tonumber(applyGeneration[output]) ~= applyToken
            or wallInOne.knownOutputName(output) == nil
        then
            return false
        end
        if observedInternal then
            local currentOwned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs[output] or nil
            return type(currentOwned) == "table"
                and currentOwned.backend == "w-engine"
                and tostring(currentOwned.workshop_id or "") == tostring(id)
        end
        return true
    end
    local ready = output ~= nil and wallInOne.internalBackendReady("w_engine", output) == true
    if ready then
        local backendToken = backendGeneration.w_engine
        local sameCapturing = type(owned) == "table"
            and owned.backend == "w-engine"
            and owned.state == "capturing"
            and internalId == tostring(id)
        if sameCapturing then
            return
        end
        local wasRunning = type(owned) == "table"
            and owned.backend == "w-engine"
            and (owned.state == "running" or owned.state == "paused")
            and internalId == tostring(id)
        if type(owned) == "table" and not wasRunning then
            wallInOne.captureWorkshopFallback({
                output = output,
                id = id,
                force = force,
                pair = pair,
                notify = notifySuccess,
                should_apply = captureStillCurrent,
            })
            return
        end
        wallInOne.requestInternalCapture({
            output = output,
            id = id,
            pair = pair,
            notify = notifySuccess,
            should_apply = function()
                return backendGeneration.w_engine == backendToken
                    and wallInOne.internalBackendReady("w_engine", output) == true
                    and captureStillCurrent()
            end,
            start_after = wasRunning,
            restore_on_failure = wasRunning,
            restore_paused = wasRunning and owned.state == "paused",
            managed_auto = false,
        })
    else
        wallInOne.captureWorkshopFallback({
            output = output,
            id = id,
            force = force,
            pair = pair,
            notify = notifySuccess,
            should_apply = captureStillCurrent,
        })
    end
end

function wallInOne.captureVideoPath(options)
    options = type(options) == "table" and options or {}
    local output = options.output
    local source = options.source
    local force = options.force == true
    local pair = options.pair == true
    local notifySuccess = options.notify == true
    local onComplete = options.on_complete
    local shouldApply = options.should_apply
    local managedAutomatic = options.managed_auto == true
    local themePolicy = options.theme
    local paletteAllowed = options.palette_allowed
    local playlistId = options.playlist_id
    local entryId = options.entry_id
    local cachePair = options.cache_pair == true
    local captureKey = options.capture_key
    output = wallInOne.targetOutput(output)
    if output == nil then
        wallInOne.setActionError(noctalia.tr("availability.output"), "video-capture")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local spec, specError = wallInOne.videoCaptureSpec(source)
    if spec == nil then
        wallInOne.setActionError(specError, "video-capture")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local sourceInfo = noctalia.fileInfo(spec.source)
    local identity = table.concat({
        wallInOne.stablePathTag(spec.source),
        tostring(type(sourceInfo) == "table" and sourceInfo.size or 0),
        tostring(type(sourceInfo) == "table" and sourceInfo.mtime or 0),
        wallInOne.sanitizedName(spec.source:match("([^/]+)$") or "video"),
    }, "-")
    local destination, destinationError = wallInOne.captureDestination(
        "video",
        identity,
        output,
        spec.extension,
        managedAutomatic == true
    )
    if destination == nil then
        wallInOne.setActionError(destinationError, "capture-directory")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    wallInOne.runCapture({
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
        managed_auto = managedAutomatic == true,
        theme = themePolicy,
        palette_allowed = paletteAllowed,
        playlist_id = playlistId,
        entry_id = entryId,
        cache_pair = cachePair,
        capture_key = captureKey,
    })
end

function wallInOne.captureConfiguredVideo(output, force, pair, notifySuccess, onComplete)
    wallInOne.captureVideoPath({
        output = output,
        source = wallInOne.configuredVideoSource(),
        force = force,
        pair = pair,
        notify = notifySuccess,
        on_complete = onComplete,
    })
end

-- Owned renderer command transport and acknowledgement handling ------------

function wallInOne.nextRendererNonce()
    local previous = noctalia.state.get(RENDERER_COMMAND_KEY)
    local previousNonce = if type(previous) == "table" then tonumber(previous.nonce) or 0 else 0
    local statusNonce = if type(rendererStatus) == "table" then tonumber(rendererStatus.last_nonce) or 0 else 0
    rendererCommandSequence = math.max(rendererCommandSequence, previousNonce, statusNonce) + 1
    return rendererCommandSequence
end

function wallInOne.sendRendererCommand(command, onAcknowledged)
    if type(rendererStatus) ~= "table" or rendererStatus.ready ~= true then
        wallInOne.setActionError(noctalia.tr("errors.renderer_unavailable"), "renderer")
        return false
    end
    command.schema = 1
    command.nonce = wallInOne.nextRendererNonce()
    if type(onAcknowledged) == "function" then
        local acknowledgementSeconds =
            math.max(5, math.min(120, math.floor(tonumber(command.ack_timeout_seconds) or 20)))
        rendererPending[command.nonce] = {
            action = tostring(command.action or ""),
            output = tostring(command.output or ""),
            deadline = wallInOne.nowSeconds() + acknowledgementSeconds,
            callback = onAcknowledged,
        }
    end
    noctalia.state.set(RENDERER_COMMAND_KEY, command)
    return true, command.nonce
end

function wallInOne.finishRendererPending(nonce, ok, reason)
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
            wallInOne.setActionError(
                noctalia.tr("errors.renderer_callback", { detail = wallInOne.boundedDetail(callbackError) }),
                "renderer"
            )
        end
    end
end

function wallInOne.failAllRendererPending(reason)
    local nonces = {}
    for nonce in pairs(rendererPending) do
        table.insert(nonces, nonce)
    end
    table.sort(nonces)
    for _, nonce in ipairs(nonces) do
        wallInOne.finishRendererPending(nonce, false, reason)
    end
end

function wallInOne.resolveRendererAcknowledgements(nextStatus)
    if type(nextStatus) ~= "table" then
        wallInOne.failAllRendererPending(noctalia.tr("errors.renderer_unavailable"))
        return
    end

    local event = tostring(nextStatus.last_event or "")
    local eventNonce = tonumber(nextStatus.last_event_nonce)
    local failures = {
        ["error"] = true,
        ["ignored"] = true,
        ["start-error"] = true,
        ["not-running"] = true,
        ["rejected"] = true,
        ["protocol-error"] = true,
        ["startup-error"] = true,
        ["write-error"] = true,
        ["write-timeout"] = true,
        ["queue-error"] = true,
        ["unavailable"] = true,
        ["heartbeat-timeout"] = true,
        ["capture-error"] = true,
        ["cancelled"] = true,
        ["unsupported"] = true,
        ["control-error"] = true,
    }
    if nextStatus.ready ~= true then
        local reason = if failures[event]
            then tostring(nextStatus.last_error or event)
            else noctalia.tr("errors.renderer_unavailable")
        wallInOne.failAllRendererPending(reason)
        return
    end

    -- Output ownership is the durable acknowledgement for a start. The
    -- versioned state slot can advance to a later event before this service
    -- observes the transient `started` label, but an exact output + nonce
    -- match still proves that the requested child became the owned renderer.
    if type(nextStatus.outputs) == "table" then
        for output, owned in pairs(nextStatus.outputs) do
            local nonce = type(owned) == "table" and tonumber(owned.nonce) or nil
            local pending = nonce ~= nil and rendererPending[nonce] or nil
            if
                type(pending) == "table"
                and tostring(pending.action or ""):match("^start_") ~= nil
                and tostring(pending.output or "") == tostring(output)
                and tostring(owned.state or "") ~= "capturing"
            then
                wallInOne.finishRendererPending(nonce, true, "")
            end
        end
    end
    if event == "started" then
        return
    end
    if event == "captured" and eventNonce ~= nil then
        local pending = rendererPending[eventNonce]
        if type(pending) == "table" and tostring(pending.action or "") == "capture_w_engine" then
            wallInOne.finishRendererPending(eventNonce, true, "")
        end
        return
    end
    if (event == "stopped" or event == "stopped-all") and eventNonce ~= nil then
        local pending = rendererPending[eventNonce]
        local pendingAction = type(pending) == "table" and tostring(pending.action or "") or ""
        if pendingAction == "stop" or pendingAction == "stop_all" then
            wallInOne.finishRendererPending(eventNonce, true, "")
        end
        return
    end
    if
        (event == "paused" or event == "resumed" or event == "muted" or event == "unmuted" or event == "volume-set")
        and eventNonce ~= nil
    then
        local pending = rendererPending[eventNonce]
        local action = type(pending) == "table" and tostring(pending.action or "") or ""
        local accepted = {
            paused = { pause = true, toggle = true },
            resumed = { resume = true, toggle = true },
            muted = { mute = true, toggle_mute = true },
            unmuted = { unmute = true, toggle_mute = true },
            ["volume-set"] = { set_volume = true },
        }
        if type(accepted[event]) == "table" and accepted[event][action] == true then
            wallInOne.finishRendererPending(eventNonce, true, "")
        end
        return
    end

    if failures[event] and eventNonce ~= nil then
        wallInOne.finishRendererPending(eventNonce, false, tostring(nextStatus.last_error or event))
    end
end

function wallInOne.queueRendererStop(output, onAcknowledged)
    output = tostring(output or "")
    if output == "" then
        return false
    end
    if type(rendererStatus) == "table" and rendererStatus.ready == true then
        local queued = wallInOne.sendRendererCommand({ action = "stop", output = output }, function(ok, reason)
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

wallInOne.invalidateCycleIntent = function(output, stopRenderer)
    output = tostring(output or "")
    if output == "" then
        return
    end
    wallInOne.resetRendererExitState(output)
    cycleGeneration[output] = (tonumber(cycleGeneration[output]) or 0) + 1
    applyGeneration[output] = (tonumber(applyGeneration[output]) or 0) + 1
    cycleApplying[output] = nil
    if stopRenderer == true then
        wallInOne.queueRendererStop(output)
    end
end

function wallInOne.resetRendererExitState(output)
    output = tostring(output or "")
    if output ~= "" then
        rendererExitState[output] = nil
    end
end

function wallInOne.noteRendererStarted(output, nonce, observedAt)
    output = tostring(output or "")
    local now = math.max(0, math.floor(tonumber(observedAt) or wallInOne.nowSeconds()))
    local state = rendererExitState[output]
    if type(state) ~= "table" then
        state = { failures = 0 }
    end
    state.started_at = now
    state.start_nonce = tostring(nonce or "")
    -- Retain the current floor until the renderer proves stable or an
    -- explicit user transition resets the policy. This matters if renderer
    -- readiness itself disappears again immediately after a recovered start.
    state.retry_at = math.max(0, math.floor(tonumber(state.retry_at) or 0))
    rendererExitState[output] = state
end

function wallInOne.noteUnexpectedRendererExit(output, nonce, observedAt)
    output = tostring(output or "")
    local now = math.max(0, math.floor(tonumber(observedAt) or wallInOne.nowSeconds()))
    local state = rendererExitState[output]
    if type(state) ~= "table" then
        state = { failures = 0 }
    end
    local failures = math.max(0, math.floor(tonumber(state.failures) or 0))
    local startedAt = tonumber(state.started_at)
    local sameStart = tostring(state.start_nonce or "") ~= ""
        and tostring(state.start_nonce) == tostring(nonce or "")
    if
        sameStart
        and startedAt ~= nil
        and startedAt > 0
        and now >= startedAt
        and now - startedAt >= RENDERER_CRASH_STABLE_SECONDS
    then
        failures = 0
    end
    failures = math.min(#RENDERER_CRASH_BACKOFF_SECONDS, failures + 1)
    local retryAt = now + RENDERER_CRASH_BACKOFF_SECONDS[failures]
    rendererExitState[output] = {
        failures = failures,
        started_at = 0,
        start_nonce = "",
        retry_at = retryAt,
    }
    return retryAt
end

function wallInOne.rendererRetryFloor(output)
    local state = rendererExitState[tostring(output or "")]
    return math.max(0, math.floor(tonumber(type(state) == "table" and state.retry_at) or 0))
end

wallInOne.reconcileRendererOwnership = function()
    local ownedOutputs = type(rendererStatus) == "table"
            and type(rendererStatus.outputs) == "table"
            and rendererStatus.outputs
        or {}
    for output, owned in pairs(ownedOutputs) do
        local backend = type(owned) == "table" and tostring(owned.backend or "") or ""
        local provider = if backend == "w-engine"
            then "w_engine"
            elseif backend == "mpvpaper" then "mpvpaper"
            else nil
        local ready = provider ~= nil and wallInOne.internalBackendReady(provider, output) == true
        local shouldStop = provider == nil or wallInOne.knownOutputName(output) == nil or not ready
        if shouldStop and rendererStopping[output] ~= true then
            wallInOne.invalidateCycleIntent(output, true)
        end
    end
end

function wallInOne.internalBackendReady(provider, output)
    local engines = wallInOne.outputEngineSettings(output)
    local settings = if provider == "w_engine"
        then engines.workshop
        elseif provider == "mpvpaper" then engines.video
        else nil
    if type(settings) ~= "table" or settings.enabled ~= true then
        return false, noctalia.tr("errors.provider_forced_off", { provider = provider })
    elseif type(rendererStatus) ~= "table" or rendererStatus.ready ~= true then
        return false, noctalia.tr("errors.internal_unavailable", { provider = provider })
    elseif provider == "w_engine" and not noctalia.commandExists("linux-wallpaperengine") then
        return false, noctalia.tr("errors.internal_unavailable", { provider = provider })
    elseif provider == "mpvpaper" and not noctalia.commandExists("mpvpaper") then
        return false, noctalia.tr("errors.internal_unavailable", { provider = provider })
    end
    return true, nil
end

function wallInOne.cachedPair(dynamicId)
    local pair = runtime.pair_registry[tostring(dynamicId)]
    local path = type(pair) == "table" and tostring(pair.still_path or "") or ""
    local info = path ~= "" and noctalia.fileInfo(path) or nil
    local sourceSize, sourceMtime = wallInOne.dynamicSourceFingerprint(dynamicId)
    local sourceMatches = sourceSize == nil
        or (
            type(pair) == "table"
            and
            tonumber(pair.source_size) ~= nil
            and tonumber(pair.source_mtime) ~= nil
            and tonumber(pair.source_size) == sourceSize
            and tonumber(pair.source_mtime) == sourceMtime
        )
    if
        type(info) == "table"
        and info.isDir ~= true
        and (tonumber(info.size) or 0) > 0
        and tonumber(pair.still_size) ~= nil
        and tonumber(pair.still_mtime) ~= nil
        and tonumber(pair.still_size) == tonumber(info.size)
        and tonumber(pair.still_mtime) == tonumber(info.mtime)
        and sourceMatches
    then
        local managed = pair.still_managed == true and wallInOne.readManagedStillSidecar(path) ~= nil
        return path, tostring(pair.capture_method or "cached-pair"), managed, tostring(pair.sidecar_path or "")
    end
    return nil, nil
end

function wallInOne.selectedStaticPair(_output, preferredPath)
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
    return nil, nil
end

function wallInOne.startInternalVideo(output, source, onAcknowledged)
    local ready, reason = wallInOne.internalBackendReady("mpvpaper", output)
    if not ready then
        wallInOne.setActionError(reason, "mpvpaper-internal")
        return false
    end
    local engines = wallInOne.outputEngineSettings(output)
    local video = engines.video
    return wallInOne.sendRendererCommand({
        action = "start_mpvpaper",
        output = output,
        path = source,
        layer = engines.layer,
        mute = video.mute,
        hardware_decode = video.hardware_decode,
        auto_pause = video.auto_pause,
        auto_pause_mode = video.auto_pause_mode,
        options = video.options,
    }, onAcknowledged)
end

function wallInOne.buildWorkshopRendererCommand(base)
    local command = {}
    for key, value in pairs(type(base) == "table" and base or {}) do
        command[key] = value
    end
    local engines = wallInOne.outputEngineSettings(command.output)
    local workshop = engines.workshop
    command.layer = engines.layer
    command.fps = workshop.fps
    command.volume = workshop.volume
    command.scaling = workshop.scaling
    command.clamp = workshop.clamp
    command.silent = workshop.silent
    for _, name in ipairs(WORKSHOP_FLAG_NAMES) do
        command[name] = workshop.flags[name]
    end
    return command
end

function wallInOne.startInternalWorkshop(output, id, onAcknowledged)
    local ready, reason = wallInOne.internalBackendReady("w_engine", output)
    if not ready then
        wallInOne.setActionError(reason, "w-engine-internal")
        return false
    end
    if not wallInOne.validWorkshopId(id) then
        wallInOne.setActionError(noctalia.tr("errors.no_current_scene"), "w-engine-internal")
        return false
    end
    local _project, projectDirectory = wallInOne.findWorkshopProject(id)
    return wallInOne.sendRendererCommand(wallInOne.buildWorkshopRendererCommand({
        action = "start_w_engine",
        output = output,
        workshop_id = id,
        project_directory = projectDirectory,
        project_path = if projectDirectory ~= nil then projectDirectory .. "project.json" else nil,
    }), onAcknowledged)
end

wallInOne.requestInternalCapture = function(options)
    options = type(options) == "table" and options or {}
    local output = options.output
    local id = options.id
    local pair = options.pair == true
    local notifySuccess = options.notify == true
    local onComplete = options.on_complete
    local shouldApply = options.should_apply
    local startAfterCapture = options.start_after == true
    local restoreOnFailure = options.restore_on_failure == true
    local restorePaused = options.restore_paused == true
    local managedAutomatic = options.managed_auto == true
    local themePolicy = options.theme
    local paletteAllowed = options.palette_allowed
    local playlistId = options.playlist_id
    local entryId = options.entry_id
    output = wallInOne.targetOutput(output)
    local ready, reason = wallInOne.internalBackendReady("w_engine", output)
    id = tostring(id or "")
    if not ready or output == nil or not wallInOne.validWorkshopId(id) then
        local failure = tostring(reason or noctalia.tr("errors.no_current_scene"))
        wallInOne.setActionError(failure, "w-engine-capture")
        if type(onComplete) == "function" then
            onComplete(false, nil, failure)
        end
        return false
    end

    local key = output
    local function parentStillCurrent()
        if wallInOne.knownOutputName(output) == nil then
            return false
        end
        if type(shouldApply) == "function" then
            local checked, current = pcall(shouldApply)
            return checked and current == true
        end
        return wallInOne.internalBackendReady("w_engine", output) == true
    end

    -- Reject a stale dequeued request before assigning a new intent token; it
    -- must not invalidate playback restoration already started by the request
    -- that just released this output's capture slot.
    if not parentStillCurrent() then
        local failure = noctalia.tr("errors.capture_replaced")
        if type(onComplete) == "function" then
            onComplete(false, nil, failure)
        end
        return false
    end

    internalCaptureIntent[key] = (tonumber(internalCaptureIntent[key]) or 0) + 1
    local intentToken = internalCaptureIntent[key]
    local function stillCurrent()
        return tonumber(internalCaptureIntent[key]) == intentToken and parentStillCurrent()
    end

    if captureInFlight[key] ~= nil then
        local active = pendingInternalCaptures[key]
        local inheritRestore = type(active) == "table" and tostring(active.dynamic_id or "") == id
        local replaced = internalCaptureQueued[key]
        if type(replaced) == "table" and type(replaced.on_complete) == "function" then
            pcall(replaced.on_complete, false, nil, noctalia.tr("errors.capture_replaced"))
        end
        internalCaptureQueued[key] = {
            output = output,
            id = id,
            pair = pair == true,
            notify = notifySuccess == true,
            on_complete = onComplete,
            should_apply = shouldApply,
            start_after = startAfterCapture == true or (inheritRestore and active.start_after == true),
            restore_on_failure = restoreOnFailure == true or (inheritRestore and active.restore_on_failure == true),
            restore_paused = restorePaused == true or (inheritRestore and active.restore_paused == true),
            managed_auto = managedAutomatic == true or (inheritRestore and active.managed_auto == true),
            theme = themePolicy,
            palette_allowed = paletteAllowed,
            playlist_id = playlistId,
            entry_id = entryId,
        }
        return true
    end

    local destination, destinationError = wallInOne.captureDestination("w-engine", id, output, ".png", managedAutomatic == true)
    if destination == nil then
        wallInOne.setActionError(destinationError, "capture-directory")
        if type(onComplete) == "function" then
            onComplete(false, nil, destinationError)
        end
        return false
    end
    captureSequence += 1
    local requestId = SERVICE_NONCE .. "-internal-" .. tostring(noctalia.nowMs()) .. "-" .. tostring(captureSequence)
    local stagingPath, stagingError = wallInOne.captureStagingPath(requestId)
    if stagingPath == nil then
        wallInOne.setActionError(stagingError, "capture-directory")
        if type(onComplete) == "function" then
            onComplete(false, nil, stagingError)
        end
        return false
    end

    local function report(ok, path, errorMessage)
        if type(onComplete) == "function" then
            onComplete(ok == true, path, errorMessage)
        end
    end

    local function finishWithPlayback(ok, path, errorMessage)
        local current = stillCurrent()
        local shouldStart = ok == true and startAfterCapture == true and current
        local shouldRestore = restoreOnFailure == true and current
        if not shouldStart and not shouldRestore then
            report(ok, path, errorMessage)
            return
        end
        local deferred = wallInOne.deferUntilNextUpdate(function()
            if not stillCurrent() then
                report(false, path, noctalia.tr("errors.capture_replaced"))
                return
            end
            local queued = wallInOne.startInternalWorkshop(output, id, function(started, startError)
                if ok == true and started ~= true then
                    wallInOne.setActionError(tostring(startError or noctalia.tr("errors.renderer_unavailable")), "renderer")
                    report(false, path, startError)
                else
                    if started == true and shouldRestore and restorePaused == true and stillCurrent() then
                        wallInOne.sendRendererCommand({ action = "pause", output = output })
                    end
                    report(ok, path, errorMessage)
                end
            end)
            if not queued then
                report(false, path, errorMessage)
            end
        end)
        if not deferred then
            report(false, path, noctalia.tr("errors.apply_queue_full"))
        end
    end

    local function useFallback(errorMessage)
        if not stillCurrent() then
            local failure = tostring(errorMessage or noctalia.tr("errors.capture_failed"))
            wallInOne.setActionError(failure, "capture")
            report(false, nil, failure)
            wallInOne.drainCaptureQueues(key)
            return
        end
        local fallbackStarted = false
        fallbackStarted = wallInOne.captureWorkshopFallback({
            output = output,
            id = id,
            force = true,
            pair = pair,
            notify = notifySuccess,
            on_complete = function(ok, path, fallbackError)
                finishWithPlayback(ok == true, path, fallbackError or errorMessage)
                -- A normally queued fallback drains through wallInOne.finishCapture.
                -- Only synchronous preflight failures need a direct drain.
                if fallbackStarted ~= true then
                    wallInOne.drainCaptureQueues(key)
                end
            end,
            should_apply = stillCurrent,
            managed_auto = managedAutomatic,
            theme = themePolicy,
            palette_allowed = paletteAllowed,
            playlist_id = playlistId,
            entry_id = entryId,
        })
    end

    local request = {
        provider = "w_engine",
        output = output,
        dynamic_id = id,
        spec = { method = "linux-wallpaperengine-fbo-v1" },
        destination = destination,
        force = true,
        pair = pair == true,
        notify = notifySuccess == true,
        request_id = requestId,
        staging_path = stagingPath,
        start_after = startAfterCapture == true,
        restore_on_failure = restoreOnFailure == true,
        restore_paused = restorePaused == true,
        managed_auto = managedAutomatic == true,
        theme = themePolicy,
        palette_allowed = paletteAllowed,
        playlist_id = playlistId,
        entry_id = entryId,
        should_apply = stillCurrent,
        on_complete = function(ok, path, errorMessage)
            if ok == true then
                finishWithPlayback(true, path, nil)
            elseif path ~= nil and tostring(path) ~= "" and errorMessage == nil then
                -- The renderer produced and validated a durable export, but a
                -- newer per-output intent superseded pairing/playback.
                report(false, path, nil)
            else
                useFallback(errorMessage)
            end
        end,
    }
    pendingInternalCaptures[key] = request
    captureInFlight[key] = {
        sequence = captureSequence,
        provider = "w_engine",
        dynamic_id = id,
        output = output,
        destination = destination,
        method = "linux-wallpaperengine-fbo-v1",
        request_id = requestId,
        deadline = wallInOne.nowSeconds() + 60,
    }
    wallInOne.publishStatus()

    local _project, projectDirectory = wallInOne.findWorkshopProject(id)
    local queued, _nonce = wallInOne.sendRendererCommand(wallInOne.buildWorkshopRendererCommand({
        action = "capture_w_engine",
        output = output,
        workshop_id = id,
        project_directory = projectDirectory,
        project_path = if projectDirectory ~= nil then projectDirectory .. "project.json" else nil,
        destination = stagingPath,
        screenshot_delay = math.min(5, wallInOne.settingInt("scene_screenshot_delay", 15, 1, 120)),
        ack_timeout_seconds = 45,
    }), function(captured, captureError)
        if pendingInternalCaptures[key] ~= request then
            return
        end
        wallInOne.releaseCaptureSlot(key)
        if captured ~= true then
            if noctalia.fileExists(stagingPath) then
                noctalia.removeFile(stagingPath)
            end
            useFallback(captureError)
            return
        end
        request.spec = {
            mode = "copy",
            source = stagingPath,
            value = "",
            method = "linux-wallpaperengine-fbo-v1",
        }
        wallInOne.runCapture(request)
    end)
    if not queued then
        wallInOne.releaseCaptureSlot(key)
        if noctalia.fileExists(stagingPath) then
            noctalia.removeFile(stagingPath)
        end
        useFallback(noctalia.tr("errors.renderer_unavailable"))
        return false
    end
    return true
end

function wallInOne.applyVideoWithPair(request)
    request = type(request) == "table" and request or {}
    local output = request.output
    local source = request.source
    local notifySuccess = request.notify == true
    local onComplete = request.on_complete
    local shouldStart = request.should_start
    local preferredStillPath = request.still_path
    local themePolicy = request.theme
    local paletteAllowed = request.palette_allowed
    local playlistId = request.playlist_id
    local entryId = request.entry_id
    output = wallInOne.targetOutput(output)
    if output == nil then
        wallInOne.setActionError(noctalia.tr("availability.output"), "video-apply")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local ready, reason = wallInOne.internalBackendReady("mpvpaper", output)
    local backendToken = backendGeneration.mpvpaper
    local parentShouldStart = shouldStart
    shouldStart = function()
        return backendGeneration.mpvpaper == backendToken
            and wallInOne.knownOutputName(output) ~= nil
            and (type(parentShouldStart) ~= "function" or parentShouldStart() == true)
    end
    local dynamicId = "video:" .. tostring(source or "")
    local pairPath, method = wallInOne.selectedStaticPair(output, preferredStillPath)
    local pairManaged = false
    local pairSidecar = ""
    if pairPath == nil then
        pairPath, method, pairManaged, pairSidecar = wallInOne.cachedPair(dynamicId)
    end
    local function startAfterPair(ok, path, errorMessage)
        if ok ~= true or shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, path, errorMessage)
            end
            return
        end
        if not ready then
            wallInOne.setActionError(reason, if notifySuccess then "renderer" else nil)
            if type(onComplete) == "function" then
                -- The representative still and palette are already valid. A
                -- missing renderer degrades motion without leaving the output
                -- blank or rolling back a successful playlist transition.
                onComplete(path ~= nil, path, reason)
            end
            return
        end
        local deferred = wallInOne.deferUntilNextUpdate(function()
            if shouldStart() ~= true then
                if type(onComplete) == "function" then
                    onComplete(false, path, noctalia.tr("errors.capture_replaced"))
                end
                return
            end
            local queued = wallInOne.startInternalVideo(output, source, function(started, startError)
                if started ~= true then
                    local failure = tostring(startError or noctalia.tr("errors.renderer_unavailable"))
                    wallInOne.setActionError(failure, if notifySuccess then "renderer" else nil)
                end
                if type(onComplete) == "function" then
                    onComplete(started == true, path, startError)
                end
            end)
            if not queued and type(onComplete) == "function" then
                onComplete(false, path, noctalia.tr("errors.renderer_unavailable"))
            end
        end)
        if not deferred and type(onComplete) == "function" then
            onComplete(false, path, noctalia.tr("errors.apply_queue_full"))
        end
    end
    if pairPath ~= nil then
        if type(shouldStart) == "function" and shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, pairPath)
            end
            return
        end
        wallInOne.applyPairedStill({
            output = output,
            dynamic_id = dynamicId,
            path = pairPath,
            method = method,
            notify = notifySuccess == true,
            managed = pairManaged,
            sidecar_path = pairSidecar,
            theme = themePolicy,
            on_complete = startAfterPair,
            should_apply = shouldStart,
            palette_allowed = paletteAllowed,
            playlist_id = playlistId,
            entry_id = entryId,
        })
    elseif not wallInOne.settingBool("auto_capture", true) then
        local failure = noctalia.tr("errors.playlist_still_required")
        wallInOne.setActionError(failure, if notifySuccess then "playlist-still" else nil)
        if type(onComplete) == "function" then
            onComplete(false, nil, failure)
        end
    else
        wallInOne.captureVideoPath({
            output = output,
            source = source,
            pair = true,
            notify = notifySuccess,
            on_complete = startAfterPair,
            should_apply = shouldStart,
            managed_auto = true,
            theme = themePolicy,
            palette_allowed = paletteAllowed,
            playlist_id = playlistId,
            entry_id = entryId,
        })
    end
end

function wallInOne.applyWorkshopWithPair(request)
    request = type(request) == "table" and request or {}
    local output = request.output
    local id = request.id
    local notifySuccess = request.notify == true
    local onComplete = request.on_complete
    local shouldStart = request.should_start
    local preferredStillPath = request.still_path
    local themePolicy = request.theme
    local paletteAllowed = request.palette_allowed
    local playlistId = request.playlist_id
    local entryId = request.entry_id
    output = wallInOne.targetOutput(output)
    id = tostring(id or "")
    if output == nil or not wallInOne.validWorkshopId(id) then
        wallInOne.setActionError(noctalia.tr("errors.no_current_scene"), "workshop-apply")
        if type(onComplete) == "function" then
            onComplete(false)
        end
        return
    end
    local ready, reason = wallInOne.internalBackendReady("w_engine", output)
    local backendToken = backendGeneration.w_engine
    local parentShouldStart = shouldStart
    shouldStart = function()
        return backendGeneration.w_engine == backendToken
            and wallInOne.knownOutputName(output) ~= nil
            and (type(parentShouldStart) ~= "function" or parentShouldStart() == true)
    end
    local pairPath, method = wallInOne.selectedStaticPair(output, preferredStillPath)
    local pairManaged = false
    local pairSidecar = ""
    if pairPath == nil then
        pairPath, method, pairManaged, pairSidecar = wallInOne.cachedPair(id)
    end
    local function startAfterPair(ok, path, errorMessage)
        if ok ~= true or shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, path, errorMessage)
            end
            return
        end
        if not ready then
            wallInOne.setActionError(reason, if notifySuccess then "renderer" else nil)
            if type(onComplete) == "function" then
                onComplete(path ~= nil, path, reason)
            end
            return
        end
        local deferred = wallInOne.deferUntilNextUpdate(function()
            if shouldStart() ~= true then
                if type(onComplete) == "function" then
                    onComplete(false, path, noctalia.tr("errors.capture_replaced"))
                end
                return
            end
            local queued = wallInOne.startInternalWorkshop(output, id, function(started, startError)
                if started ~= true then
                    local failure = tostring(startError or noctalia.tr("errors.renderer_unavailable"))
                    wallInOne.setActionError(failure, if notifySuccess then "renderer" else nil)
                end
                if type(onComplete) == "function" then
                    onComplete(started == true, path, startError)
                end
            end)
            if not queued and type(onComplete) == "function" then
                onComplete(false, path, noctalia.tr("errors.renderer_unavailable"))
            end
        end)
        if not deferred and type(onComplete) == "function" then
            onComplete(false, path, noctalia.tr("errors.apply_queue_full"))
        end
    end
    if pairPath ~= nil then
        if type(shouldStart) == "function" and shouldStart() ~= true then
            if type(onComplete) == "function" then
                onComplete(false, pairPath)
            end
            return
        end
        wallInOne.applyPairedStill({
            output = output,
            dynamic_id = id,
            path = pairPath,
            method = method,
            notify = notifySuccess == true,
            managed = pairManaged,
            sidecar_path = pairSidecar,
            theme = themePolicy,
            on_complete = startAfterPair,
            should_apply = shouldStart,
            palette_allowed = paletteAllowed,
            playlist_id = playlistId,
            entry_id = entryId,
        })
    elseif not wallInOne.settingBool("auto_capture", true) then
        local failure = noctalia.tr("errors.playlist_still_required")
        wallInOne.setActionError(failure, if notifySuccess then "playlist-still" else nil)
        if type(onComplete) == "function" then
            onComplete(false, nil, failure)
        end
    else
        local owned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs[output] or nil
        local sameActive = type(owned) == "table"
            and owned.backend == "w-engine"
            and (owned.state == "running" or owned.state == "paused")
            and tostring(owned.workshop_id or "") == id
        if not ready or (type(owned) == "table" and not sameActive) then
            -- A new project must not destroy unrelated playback merely to make
            -- its still. Extract its Workshop source/preview first; only a
            -- successful pair is allowed to replace the existing renderer.
            wallInOne.captureWorkshopFallback({
                output = output,
                id = id,
                pair = true,
                notify = notifySuccess,
                on_complete = startAfterPair,
                should_apply = shouldStart,
                managed_auto = true,
                theme = themePolicy,
                palette_allowed = paletteAllowed,
                playlist_id = playlistId,
                entry_id = entryId,
            })
        else
            wallInOne.requestInternalCapture({
                output = output,
                id = id,
                pair = true,
                notify = notifySuccess,
                on_complete = onComplete,
                should_apply = shouldStart,
                start_after = true,
                restore_on_failure = sameActive,
                restore_paused = sameActive and owned.state == "paused",
                managed_auto = true,
                theme = themePolicy,
                palette_allowed = paletteAllowed,
                playlist_id = playlistId,
                entry_id = entryId,
            })
        end
    end
end

-- Named playlists, entries, schedules, and managed-library mutation --------

function wallInOne.editableConfig()
    local pairings = wallInOne.normalizedPairings(config.pairings)
    local playlists = wallInOne.normalizedPlaylists(config.playlists)
    local outputs = playlists ~= nil and wallInOne.normalizedOutputs(config.outputs, playlists) or nil
    if pairings == nil or playlists == nil or outputs == nil then
        return nil
    end
    return {
        schema_version = CONFIG_SCHEMA,
        gestures = wallInOne.cloneGestures(config.gestures),
        pairings = pairings,
        playlists = playlists,
        outputs = outputs,
    }
end

function wallInOne.saveConfig(nextConfig, errorKey)
    local normalized, validationError = wallInOne.validateConfig(nextConfig)
    if normalized == nil then
        wallInOne.setActionError(validationError or noctalia.tr("errors.config_playlists"), errorKey or "playlist-config")
        return false
    end
    local saved, saveError = wallInOne.atomicWrite("config.json", normalized)
    if not saved then
        configValid = false
        configError = tostring(saveError or noctalia.tr("errors.config_save"))
        wallInOne.setActionError(configError, errorKey or "playlist-config")
        return false
    end
    config = normalized
    configValid = true
    configError = ""
    wallInOne.markStateDomain("config")
    wallInOne.publishStatus()
    return true
end

function wallInOne.saveOutputEngines(output, candidate)
    output = wallInOne.knownOutputName(tostring(output or ""))
    if output == nil or type(candidate) ~= "table" then
        wallInOne.setActionError(noctalia.tr("availability.output"), "output-engines")
        return false
    end
    local nextConfig = wallInOne.editableConfig()
    if nextConfig == nil then
        wallInOne.setActionError(noctalia.tr("errors.config_playlists"), "output-engines")
        return false
    end
    local current = wallInOne.outputEngineSettings(output)
    local engines = wallInOne.normalizedOutputEngines(candidate, current)
    if engines == nil then
        wallInOne.setActionError(noctalia.tr("errors.config_playlists"), "output-engines")
        return false
    end
    local outputConfig = nextConfig.outputs[output]
    if type(outputConfig) ~= "table" then
        outputConfig = {
            fallback_playlist = "",
            quick_choice_playlist = "",
            schedules = {},
        }
        nextConfig.outputs[output] = outputConfig
    end
    outputConfig.engines = engines
    if not wallInOne.saveConfig(nextConfig, "output-engines") then
        return false
    end
    wallInOne.refreshBackendPolicy()
    wallInOne.reconcileRendererOwnership()
    wallInOne.persistRuntimeIfChanged(false)
    wallInOne.publishStatus()
    return true
end

function wallInOne.outputState(output)
    local state = runtime.output_states[output]
    if type(state) ~= "table" then
        state = {
            active_playlist = "",
            manual_pin = false,
            active_schedule = "",
            last_transition_at = "",
        }
        runtime.output_states[output] = state
    end
    state.active_playlist = tostring(state.active_playlist or "")
    state.manual_pin = state.manual_pin == true
    state.active_schedule = tostring(state.active_schedule or "")
    state.last_transition_at = tostring(state.last_transition_at or "")
    return state
end

function wallInOne.playlistRunState(output, playlistId)
    local outputRuns = runtime.runs[output]
    if type(outputRuns) ~= "table" then
        outputRuns = {}
        runtime.runs[output] = outputRuns
    end
    local state = outputRuns[playlistId]
    if type(state) ~= "table" then
        state = {
            running = false,
            paused = false,
            parked = false,
            current_entry = "",
            next_due = 0,
            history = {},
            bag = {},
            last_applied_at = "",
            last_error = "",
        }
        outputRuns[playlistId] = state
    end
    state.running = state.running == true
    state.paused = state.paused == true
    state.parked = state.parked == true
    state.current_entry = tostring(state.current_entry or "")
    state.next_due = math.max(0, math.floor(tonumber(state.next_due) or 0))
    state.history = type(state.history) == "table" and state.history or {}
    state.bag = type(state.bag) == "table" and state.bag or {}
    state.last_error = tostring(state.last_error or "")
    return state
end

function wallInOne.disarmOtherPlaylistRuns(output, activePlaylistId)
    local outputRuns = runtime.runs[output]
    if type(outputRuns) ~= "table" then
        return
    end
    for playlistId, run in pairs(outputRuns) do
        if playlistId ~= activePlaylistId and type(run) == "table" then
            run.running = false
            run.paused = false
            run.next_due = 0
        end
    end
end

function wallInOne.playlistForOutput(output, requestedId)
    output = wallInOne.targetOutput(output)
    if output == nil then
        return nil, nil, nil
    end
    local requested = tostring(requestedId or "")
    if requested ~= "" and config.playlists[requested] ~= nil then
        return config.playlists[requested], requested, output
    end
    local state = wallInOne.outputState(output)
    if state.active_playlist ~= "" and config.playlists[state.active_playlist] ~= nil then
        return config.playlists[state.active_playlist], state.active_playlist, output
    end
    local outputConfig = config.outputs[output]
    local fallback = type(outputConfig) == "table" and tostring(outputConfig.fallback_playlist or "") or ""
    if fallback ~= "" and config.playlists[fallback] ~= nil then
        return config.playlists[fallback], fallback, output
    end
    return nil, nil, output
end

function wallInOne.currentThemePolicy()
    -- `theme-mode-get` reports only the resolved light/dark value, so copying
    -- it would silently turn a user's automatic mode into a fixed mode. Legacy
    -- Quick Choice requests therefore inherit unless the compatibility color
    -- sync toggle explicitly asks for wallpaper-derived colors.
    return wallInOne.legacyThemePolicy()
end

function wallInOne.entryBundleFromRequest(rawEntry, output, usedIds)
    local bundle = wallInOne.normalizedEntryBundle(rawEntry)
    if bundle ~= nil then
        local id = wallInOne.uniqueIdentifier(usedIds, bundle.id)
        if id == nil then
            return nil
        end
        bundle.id = id
        return bundle
    end
    local legacy = wallInOne.normalizedLegacyEntry(rawEntry)
    if legacy == nil then
        return nil
    end
    local id = wallInOne.uniqueIdentifier(
        usedIds,
        wallInOne.stableIdentifier("entry", output .. ":" .. legacy.kind .. ":" .. legacy.source, noctalia.nowMs())
    )
    if id == nil then
        return nil
    end
    local media = nil
    local still
    if legacy.kind == "static" then
        still = { mode = "selected", path = legacy.source }
    else
        media = { kind = legacy.kind, source = legacy.source }
        still = if legacy.still_path ~= ""
            then { mode = "selected", path = legacy.still_path }
            else { mode = "automatic" }
    end
    return {
        id = id,
        label = if wallInOne.validPersistedKey(legacy.label) then legacy.label else legacy.source:match("([^/]+)$") or legacy.source,
        media = media,
        still = still,
        theme = wallInOne.currentThemePolicy(),
        added_at = if legacy.added_at ~= "" then legacy.added_at else noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
    }
end

function wallInOne.materializedPlaylistEntry(entry, pairings)
    if type(entry) ~= "table" then
        return nil
    end
    local pairingId = tostring(entry.pairing_id or "")
    local pairing = type(pairings) == "table" and pairings[pairingId] or nil
    if type(pairing) ~= "table" then
        return entry
    end
    local materialized = wallInOne.pairingFromEntry(pairing, entry.id)
    materialized.pairing_id = pairingId
    materialized.added_at = if tostring(entry.added_at or "") ~= "" then entry.added_at else pairing.added_at
    return materialized
end

function wallInOne.syncPairingSnapshots(nextConfig, pairingId)
    local pairing = type(nextConfig.pairings) == "table" and nextConfig.pairings[pairingId] or nil
    if type(pairing) ~= "table" then
        return
    end
    for _, playlist in pairs(nextConfig.playlists) do
        for index, entry in ipairs(playlist.entries) do
            if tostring(entry.pairing_id or "") == pairingId then
                local snapshot = wallInOne.pairingFromEntry(pairing, entry.id)
                snapshot.pairing_id = pairingId
                snapshot.added_at = if tostring(entry.added_at or "") ~= "" then entry.added_at else pairing.added_at
                playlist.entries[index] = snapshot
            end
        end
    end
end

function wallInOne.pairingIdentitySelection(nextConfig, candidate)
    local identity = wallInOne.bundleIdentity(candidate)
    if identity == "" then
        return nil, false, false
    end
    local signature = wallInOne.bundleSignature(candidate)
    local matchingIds = {}
    local customizedIds = {}
    local exactIds = {}
    for id, pairing in pairs(nextConfig.pairings) do
        if type(pairing) == "table" and wallInOne.bundleIdentity(pairing) == identity then
            table.insert(matchingIds, id)
            if pairing.customized == true then
                table.insert(customizedIds, id)
            end
            if wallInOne.bundleSignature(pairing) == signature then
                table.insert(exactIds, id)
            end
        end
    end
    table.sort(matchingIds)
    table.sort(customizedIds)
    table.sort(exactIds)
    if #matchingIds == 0 then
        return nil, false, false
    end

    -- A sole customized record is the unambiguous owner of this medium. If
    -- several legacy custom records disagree, an exact match is safe to reuse
    -- but the conflicting records must remain until one is explicitly edited.
    if #customizedIds == 1 then
        return customizedIds[1], true, false
    elseif #customizedIds > 1 then
        for _, exactId in ipairs(exactIds) do
            if nextConfig.pairings[exactId].customized == true then
                return exactId, false, false
            end
        end
        return customizedIds[1], false, true
    end
    return if #exactIds > 0 then exactIds[1] else matchingIds[1], true, false
end

function wallInOne.collapsePairingIdentity(nextConfig, canonicalId, includeCustomized)
    local canonical = type(nextConfig.pairings) == "table" and nextConfig.pairings[canonicalId] or nil
    local identity = wallInOne.bundleIdentity(canonical)
    if type(canonical) ~= "table" or identity == "" then
        return
    end
    local duplicateIds = {}
    for id, pairing in pairs(nextConfig.pairings) do
        if
            id ~= canonicalId
            and type(pairing) == "table"
            and wallInOne.bundleIdentity(pairing) == identity
            and (includeCustomized == true or pairing.customized ~= true)
        then
            table.insert(duplicateIds, id)
        end
    end
    table.sort(duplicateIds)
    for _, duplicateId in ipairs(duplicateIds) do
        for _, playlist in pairs(nextConfig.playlists) do
            for _, occurrence in ipairs(playlist.entries) do
                if tostring(occurrence.pairing_id or "") == duplicateId then
                    occurrence.pairing_id = canonicalId
                end
            end
        end
        nextConfig.pairings[duplicateId] = nil
    end
    wallInOne.syncPairingSnapshots(nextConfig, canonicalId)
end

function wallInOne.catalogPairingForEntry(nextConfig, entry)
    local requestedId = tostring(entry.pairing_id or "")
    if requestedId ~= "" and type(nextConfig.pairings[requestedId]) == "table" then
        local canonicalId, canCollapse = wallInOne.pairingIdentitySelection(
            nextConfig,
            nextConfig.pairings[requestedId]
        )
        if canCollapse then
            wallInOne.collapsePairingIdentity(nextConfig, canonicalId, false)
            entry.pairing_id = canonicalId
            return canonicalId
        end
        return requestedId
    end
    local signature = wallInOne.bundleSignature(entry)
    local ids = {}
    for id in pairs(nextConfig.pairings) do
        table.insert(ids, id)
    end
    table.sort(ids)

    local canonicalId, canCollapse = wallInOne.pairingIdentitySelection(nextConfig, entry)
    if canonicalId ~= nil then
        local previous = nextConfig.pairings[canonicalId]
        if type(previous) == "table" and previous.customized ~= true and entry.customized ~= true then
            local replacement = wallInOne.pairingFromEntry(entry, canonicalId)
            if tostring(previous.added_at or "") ~= "" then
                replacement.added_at = previous.added_at
            end
            nextConfig.pairings[canonicalId] = replacement
        end
        if canCollapse then
            wallInOne.collapsePairingIdentity(nextConfig, canonicalId, false)
        end
        entry.pairing_id = canonicalId
        return canonicalId
    end

    for _, id in ipairs(ids) do
        if wallInOne.bundleSignature(nextConfig.pairings[id]) == signature then
            entry.pairing_id = id
            return id
        end
    end
    if #ids >= MAX_PAIRINGS then
        return nil
    end
    local used = {}
    for _, id in ipairs(ids) do
        used[id] = true
    end
    local id = wallInOne.uniqueIdentifier(
        used,
        wallInOne.stableIdentifier("pairing", signature, noctalia.nowMs())
    )
    if id == nil then
        return nil
    end
    nextConfig.pairings[id] = wallInOne.pairingFromEntry(entry, id)
    entry.pairing_id = id
    return id
end

function wallInOne.savePairing(rawPairing, customized)
    if type(rawPairing) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "pairing-save")
        return nil
    end
    local nextConfig = wallInOne.editableConfig()
    if nextConfig == nil then
        wallInOne.setActionError(noctalia.tr("errors.config_playlists"), "pairing-save")
        return nil
    end
    local id = tostring(rawPairing.id or "")
    local existing = nextConfig.pairings[id]
    local explicitlyEdited = type(existing) == "table"
    local canCollapseDiscoveredIdentity = false
    if id == "" then
        local used = {}
        for candidateId in pairs(nextConfig.pairings) do
            used[candidateId] = true
        end
        id = wallInOne.uniqueIdentifier(
            used,
            wallInOne.stableIdentifier("pairing", tostring(rawPairing.label or "pairing"), noctalia.nowMs())
        ) or ""
    end
    local candidate = {
        id = id,
        label = rawPairing.label,
        media = rawPairing.media,
        still = rawPairing.still,
        theme = rawPairing.theme,
        customized = customized ~= false,
        added_at = if tostring(rawPairing.added_at or "") ~= ""
            then rawPairing.added_at
            elseif type(existing) == "table" and tostring(existing.added_at or "") ~= ""
            then existing.added_at
            else noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
    }
    local pairing = wallInOne.normalizedEntryBundle(candidate)
    if pairing == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "pairing-save")
        return nil
    end
    pairing.pairing_id = nil
    if type(existing) ~= "table" then
        local matchingId, canCollapse, ambiguous = wallInOne.pairingIdentitySelection(nextConfig, pairing)
        if ambiguous then
            wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "pairing-save")
            return nil
        elseif matchingId ~= nil then
            id = matchingId
            existing = nextConfig.pairings[id]
            canCollapseDiscoveredIdentity = canCollapse
            pairing.id = id
            if tostring(existing.added_at or "") ~= "" then
                pairing.added_at = existing.added_at
            end
        elseif wallInOne.countMap(nextConfig.pairings) >= MAX_PAIRINGS then
            wallInOne.setActionError(noctalia.tr("errors.pairing_limit", { limit = tostring(MAX_PAIRINGS) }), "pairing-save")
            return nil
        end
    end
    nextConfig.pairings[id] = pairing
    -- An existing id names the record the user explicitly edited, so it wins
    -- over every older record for the same media identity. A new save reuses
    -- an existing owner instead of allocating a clone; conflicting legacy
    -- custom records remain separate unless an explicit edit resolves them.
    if explicitlyEdited then
        wallInOne.collapsePairingIdentity(nextConfig, id, true)
    elseif canCollapseDiscoveredIdentity then
        wallInOne.collapsePairingIdentity(nextConfig, id, false)
    else
        wallInOne.syncPairingSnapshots(nextConfig, id)
    end
    if not wallInOne.saveConfig(nextConfig, "pairing-save") then
        return nil
    end
    return id
end

function wallInOne.resetPairing(rawPairing)
    local pairingId = type(rawPairing) == "table" and tostring(rawPairing.id or "") or ""
    if pairingId == "" or type(config.pairings[pairingId]) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry_missing"), "pairing-reset")
        return false
    end
    return wallInOne.savePairing(rawPairing, false) ~= nil
end

function wallInOne.addPairingToPlaylist(output, playlistId, pairingId, beforeId)
    local selectedId = tostring(playlistId or "")
    local selectedOutput = tostring(output or "")
    if type(config.playlists[selectedId]) ~= "table" then
        local _playlist
        _playlist, selectedId, selectedOutput = wallInOne.ensureEditablePlaylist(output, playlistId)
        if selectedId == nil or selectedOutput == nil then
            return false
        end
    end
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[selectedId] or nil
    local pairing = nextConfig ~= nil and nextConfig.pairings[tostring(pairingId or "")] or nil
    if type(playlist) ~= "table" or type(pairing) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry_missing"), "playlist-add-pairing")
        return false
    end
    if #playlist.entries >= MAX_PLAYLIST_ENTRIES then
        wallInOne.setActionError(
            noctalia.tr("errors.playlist_entry_limit", { limit = tostring(MAX_PLAYLIST_ENTRIES) }),
            "playlist-add-pairing"
        )
        return false
    end
    local used = {}
    for _, entry in ipairs(playlist.entries) do
        used[entry.id] = true
    end
    local entryId = wallInOne.uniqueIdentifier(
        used,
        wallInOne.stableIdentifier("entry", selectedId .. ":" .. pairing.id, noctalia.nowMs())
    )
    if entryId == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "playlist-add-pairing")
        return false
    end
    local entry = wallInOne.pairingFromEntry(pairing, entryId)
    entry.pairing_id = pairing.id
    entry.added_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    local anchor = wallInOne.entryIndexById(playlist, tostring(beforeId or ""))
    if anchor == nil then
        table.insert(playlist.entries, entry)
    else
        table.insert(playlist.entries, anchor, entry)
    end
    return wallInOne.saveConfig(nextConfig, "playlist-add-pairing")
end

function wallInOne.createPlaylist(name, output, quickChoice)
    local nextConfig = wallInOne.editableConfig()
    if nextConfig == nil or wallInOne.countMap(nextConfig.playlists) >= MAX_PLAYLISTS then
        wallInOne.setActionError(noctalia.tr("errors.playlist_limit", { limit = tostring(MAX_PLAYLISTS) }), "playlist-create")
        return nil
    end
    name = noctalia.string.trim(tostring(name or ""))
    if not wallInOne.validPersistedKey(name) then
        wallInOne.setActionError(noctalia.tr("errors.playlist_name"), "playlist-create")
        return nil
    end
    local used = {}
    for id in pairs(nextConfig.playlists) do
        used[id] = true
    end
    local id = wallInOne.uniqueIdentifier(used, wallInOne.stableIdentifier(if quickChoice then "quick" else "playlist", name, noctalia.nowMs()))
    if id == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_name"), "playlist-create")
        return nil
    end
    nextConfig.playlists[id] = {
        name = name,
        order = wallInOne.configuredPlaylistOrder(),
        interval_seconds = wallInOne.configuredCycleSeconds(),
        entries = {},
        quick_choice = quickChoice == true,
    }
    if output ~= nil then
        nextConfig.outputs[output] = nextConfig.outputs[output] or {
            fallback_playlist = "",
            quick_choice_playlist = "",
            schedules = {},
        }
        if quickChoice then
            nextConfig.outputs[output].quick_choice_playlist = id
        elseif nextConfig.outputs[output].fallback_playlist == "" then
            nextConfig.outputs[output].fallback_playlist = id
        end
    end
    if not wallInOne.saveConfig(nextConfig, "playlist-create") then
        return nil
    end
    return id
end

function wallInOne.ensureEditablePlaylist(output, requestedId)
    local playlist, playlistId, selectedOutput = wallInOne.playlistForOutput(output, requestedId)
    if selectedOutput == nil then
        wallInOne.setActionError(noctalia.tr("availability.output"), "playlist")
        return nil, nil, nil
    end
    if playlist ~= nil then
        return playlist, playlistId, selectedOutput
    end
    local id = wallInOne.createPlaylist("Playlist · " .. selectedOutput, selectedOutput, false)
    return if id ~= nil then config.playlists[id] else nil, id, selectedOutput
end

function wallInOne.addPlaylistEntry(output, playlistId, rawEntry, beforeId)
    local selectedId = tostring(playlistId or "")
    local selectedOutput = tostring(output or "")
    if type(config.playlists[selectedId]) ~= "table" then
        local _playlist
        _playlist, selectedId, selectedOutput = wallInOne.ensureEditablePlaylist(output, playlistId)
        if selectedId == nil or selectedOutput == nil then
            return false
        end
    end
    local nextConfig = wallInOne.editableConfig()
    local nextPlaylist = nextConfig ~= nil and nextConfig.playlists[selectedId] or nil
    if type(nextPlaylist) ~= "table" or #nextPlaylist.entries >= MAX_PLAYLIST_ENTRIES then
        wallInOne.setActionError(
            noctalia.tr("errors.playlist_entry_limit", { limit = tostring(MAX_PLAYLIST_ENTRIES) }),
            "playlist-add"
        )
        return false
    end
    local used = {}
    for _, entry in ipairs(nextPlaylist.entries) do
        used[entry.id] = true
    end
    local entry = wallInOne.entryBundleFromRequest(
        rawEntry,
        if selectedOutput ~= "" then selectedOutput else selectedId,
        used
    )
    if entry == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "playlist-add")
        return false
    end
    local pairingId = wallInOne.catalogPairingForEntry(nextConfig, entry)
    if pairingId == nil then
        wallInOne.setActionError(noctalia.tr("errors.pairing_limit", { limit = tostring(MAX_PAIRINGS) }), "playlist-add")
        return false
    end
    entry = wallInOne.materializedPlaylistEntry(entry, nextConfig.pairings)
    local anchor = wallInOne.entryIndexById(nextPlaylist, tostring(beforeId or ""))
    if anchor == nil then
        table.insert(nextPlaylist.entries, entry)
    else
        table.insert(nextPlaylist.entries, anchor, entry)
    end
    return wallInOne.saveConfig(nextConfig, "playlist-add")
end

function wallInOne.effectivePlaylistOrder(output, playlist)
    local outputConfig = config.outputs[tostring(output or "")]
    local outputOrder = type(outputConfig) == "table" and tostring(outputConfig.order or "") or ""
    if VALID_PLAYLIST_ORDERS[outputOrder] then
        return outputOrder
    end
    local playlistOrder = type(playlist) == "table" and tostring(playlist.order or "") or ""
    return if VALID_PLAYLIST_ORDERS[playlistOrder] then playlistOrder else wallInOne.configuredPlaylistOrder()
end

function wallInOne.effectivePlaylistInterval(output, playlist)
    local outputConfig = config.outputs[tostring(output or "")]
    local outputInterval = type(outputConfig) == "table" and tonumber(outputConfig.interval_seconds) or nil
    if
        outputInterval ~= nil
        and outputInterval % 1 == 0
        and outputInterval >= MIN_CYCLE_SECONDS
        and outputInterval <= MAX_CYCLE_SECONDS
    then
        return math.floor(outputInterval)
    end
    local playlistInterval = type(playlist) == "table" and tonumber(playlist.interval_seconds) or nil
    if
        playlistInterval ~= nil
        and playlistInterval % 1 == 0
        and playlistInterval >= MIN_CYCLE_SECONDS
        and playlistInterval <= MAX_CYCLE_SECONDS
    then
        return math.floor(playlistInterval)
    end
    return wallInOne.configuredCycleSeconds()
end

function wallInOne.setPlaylistOptions(playlistId, intervalSeconds, order)
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[tostring(playlistId or "")] or nil
    if type(playlist) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.playlist_missing"), "playlist-options")
        return false
    end
    playlist.interval_seconds = math.max(
        MIN_CYCLE_SECONDS,
        math.min(MAX_CYCLE_SECONDS, math.floor(tonumber(intervalSeconds) or playlist.interval_seconds))
    )
    order = tostring(order or playlist.order)
    if order == "sequential" or order == "loop" then
        order = "rotate"
    end
    playlist.order = if VALID_PLAYLIST_ORDERS[order] then order else playlist.order
    local saved = wallInOne.saveConfig(nextConfig, "playlist-options")
    if not saved then
        return false
    end
    for output, outputRuns in pairs(runtime.runs) do
        local run = type(outputRuns) == "table" and outputRuns[tostring(playlistId)] or nil
        if type(run) == "table" and run.running == true then
            run.next_due = wallInOne.nowSeconds()
                + wallInOne.effectivePlaylistInterval(output, config.playlists[tostring(playlistId)])
            run.bag = {}
        end
    end
    wallInOne.persistRuntimeIfChanged(true)
    return true
end

function wallInOne.setOutputPlaylistOptions(output, intervalSeconds, order, inherit)
    output = wallInOne.targetOutput(output)
    local nextConfig = wallInOne.editableConfig()
    if output == nil or nextConfig == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_assignment"), "output-options")
        return false
    end
    local outputConfig = nextConfig.outputs[output]
    if type(outputConfig) ~= "table" then
        outputConfig = { fallback_playlist = "", quick_choice_playlist = "", schedules = {} }
        nextConfig.outputs[output] = outputConfig
    end
    if inherit == true then
        outputConfig.order = nil
        outputConfig.interval_seconds = nil
    else
        order = tostring(order or "")
        if order == "sequential" or order == "loop" then
            order = "rotate"
        end
        local interval = tonumber(intervalSeconds)
        if not VALID_PLAYLIST_ORDERS[order] or interval == nil or interval % 1 ~= 0 then
            wallInOne.setActionError(noctalia.tr("errors.config_playlists"), "output-options")
            return false
        end
        outputConfig.order = order
        outputConfig.interval_seconds = math.max(
            MIN_CYCLE_SECONDS,
            math.min(MAX_CYCLE_SECONDS, math.floor(interval))
        )
    end
    if not wallInOne.saveConfig(nextConfig, "output-options") then
        return false
    end
    local outputRuns = runtime.runs[output]
    if type(outputRuns) == "table" then
        local now = wallInOne.nowSeconds()
        for playlistId, run in pairs(outputRuns) do
            if type(run) == "table" then
                run.bag = {}
                if run.running == true and run.paused ~= true then
                    run.next_due = now + wallInOne.effectivePlaylistInterval(output, config.playlists[playlistId])
                end
            end
        end
    end
    wallInOne.persistRuntimeIfChanged(true)
    return true
end

function wallInOne.shuffledEntryIds(entries, seed)
    local values = {}
    for _, entry in ipairs(entries) do
        table.insert(values, entry.id)
    end
    seed = math.max(1, math.floor(tonumber(seed) or 1) % 2147483647)
    for index = #values, 2, -1 do
        seed = (seed * 48271) % 2147483647
        local selected = (seed % index) + 1
        values[index], values[selected] = values[selected], values[index]
    end
    return values
end

function wallInOne.entryIndexById(playlist, entryId)
    for index, entry in ipairs(playlist.entries) do
        if entry.id == entryId then
            return index
        end
    end
    return nil
end

function wallInOne.selectPlaylistEntryId(playlist, state, direction, order)
    local count = #playlist.entries
    if count < 1 then
        return nil
    end
    if direction == "previous" then
        if #state.history > 1 then
            table.remove(state.history)
            local previous = tostring(state.history[#state.history] or "")
            if wallInOne.entryIndexById(playlist, previous) ~= nil then
                return previous
            end
        end
        local currentIndex = wallInOne.entryIndexById(playlist, state.current_entry) or 1
        return playlist.entries[((currentIndex - 2) % count) + 1].id
    elseif direction == "random" then
        local seed = noctalia.nowMs() + #state.history * 7919
        return playlist.entries[(math.floor(seed) % count) + 1].id
    elseif order == "shuffle" then
        if #state.bag == 0 then
            state.bag = wallInOne.shuffledEntryIds(playlist.entries, noctalia.nowMs() + #state.history)
            if count > 1 and state.bag[1] == state.current_entry then
                state.bag[1], state.bag[2] = state.bag[2], state.bag[1]
            end
        end
        return tostring(table.remove(state.bag, 1) or "")
    end
    local currentIndex = wallInOne.entryIndexById(playlist, state.current_entry) or 0
    return playlist.entries[(currentIndex % count) + 1].id
end

function wallInOne.applyPlaylistEntry(request)
    local output = request.output
    local entry = request.entry
    local onComplete = if type(request.on_complete) == "function" then request.on_complete else function() end
    local parentShouldStart = request.should_start
    local applyToken = (tonumber(applyGeneration[output]) or 0) + 1
    applyGeneration[output] = applyToken
    local function shouldStart()
        if tonumber(applyGeneration[output]) ~= applyToken then
            return false
        end
        return wallInOne.knownOutputName(output) ~= nil and (type(parentShouldStart) ~= "function" or parentShouldStart() == true)
    end
    if shouldStart() ~= true then
        onComplete(false)
        return
    end
    local media = type(entry.media) == "table" and entry.media or nil
    local still = type(entry.still) == "table" and entry.still or nil
    local selectedStill = type(still) == "table" and still.mode == "selected" and tostring(still.path or "") or ""
    local degradedDynamicId = ""
    local degradedWarning = ""
    local degradedManaged = false
    local degradedSidecar = ""
    if selectedStill ~= "" then
        local info = noctalia.fileInfo(selectedStill)
        if type(info) ~= "table" or info.isDir == true or (tonumber(info.size) or 0) <= 0 then
            local failure = noctalia.tr("errors.playlist_still_missing", { path = selectedStill })
            wallInOne.setActionError(failure, "playlist-still")
            onComplete(false, nil, failure)
            return
        end
    end
    if media ~= nil and media.kind == "video" then
        local mediaInfo = noctalia.fileInfo(tostring(media.source or ""))
        if type(mediaInfo) ~= "table" or mediaInfo.isDir == true or (tonumber(mediaInfo.size) or 0) <= 0 then
            local dynamicId = "video:" .. tostring(media.source or "")
            if selectedStill == "" then
                selectedStill = wallInOne.cachedPair(dynamicId) or ""
                if selectedStill == "" then
                    local failure = noctalia.tr("errors.video_source")
                    wallInOne.setActionError(failure, "playlist-video")
                    onComplete(false, nil, failure)
                    return
                end
                local cached = runtime.pair_registry[dynamicId]
                degradedManaged = type(cached) == "table" and cached.still_managed == true
                degradedSidecar = degradedManaged and tostring(cached.sidecar_path or "") or ""
            end
            degradedDynamicId = dynamicId
            degradedWarning = noctalia.tr("errors.video_source_degraded", { path = tostring(media.source or "") })
            media = nil
            wallInOne.notifyBounded("video-static-fallback", degradedWarning)
        end
    end
    if media == nil then
        local function applyStatic(stopped)
            if stopped ~= true or (type(shouldStart) == "function" and shouldStart() ~= true) then
                onComplete(false)
                return
            end
            wallInOne.applyPairedStill({
                output = output,
                dynamic_id = if degradedDynamicId ~= "" then degradedDynamicId else "static:" .. selectedStill,
                path = selectedStill,
                method = if degradedDynamicId ~= "" then "playlist-video-static-fallback" else "playlist-static",
                notify = request.notify == true,
                managed = degradedManaged,
                sidecar_path = degradedSidecar,
                theme = entry.theme,
                on_complete = function(ok, appliedPath, errorMessage)
                    onComplete(
                        ok,
                        appliedPath,
                        if ok == true and degradedWarning ~= "" then degradedWarning else errorMessage
                    )
                end,
                should_apply = shouldStart,
                palette_allowed = request.palette_allowed,
                playlist_id = request.playlist_id,
                entry_id = entry.id,
            })
        end
        local queued = wallInOne.queueRendererStop(output, function(stopped)
            applyStatic(stopped == true)
        end)
        if not queued then
            applyStatic(true)
        end
    elseif media.kind == "video" then
        wallInOne.applyVideoWithPair({
            output = output,
            source = media.source,
            notify = request.notify == true,
            on_complete = onComplete,
            should_start = shouldStart,
            still_path = selectedStill,
            theme = entry.theme,
            palette_allowed = request.palette_allowed,
            playlist_id = request.playlist_id,
            entry_id = entry.id,
        })
    elseif media.kind == "workshop" then
        wallInOne.applyWorkshopWithPair({
            output = output,
            id = media.source,
            notify = request.notify == true,
            on_complete = onComplete,
            should_start = shouldStart,
            still_path = selectedStill,
            theme = entry.theme,
            palette_allowed = request.palette_allowed,
            playlist_id = request.playlist_id,
            entry_id = entry.id,
        })
    else
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "playlist-entry")
        onComplete(false)
    end
end

function wallInOne.applyManualEntry(output, entry, notifySuccess)
    output = wallInOne.targetOutput(output)
    if output == nil then
        wallInOne.setActionError(noctalia.tr("availability.output"), "apply-entry")
        return false
    end
    local nextConfig = wallInOne.editableConfig()
    if nextConfig == nil then
        wallInOne.setActionError(noctalia.tr("errors.config_playlists"), "quick-choice")
        return false
    end
    local outputConfig = nextConfig.outputs[output]
    if type(outputConfig) ~= "table" then
        outputConfig = { fallback_playlist = "", quick_choice_playlist = "", schedules = {} }
        nextConfig.outputs[output] = outputConfig
    end
    local quickId = tostring(outputConfig.quick_choice_playlist or "")
    local quick = nextConfig.playlists[quickId]
    if type(quick) ~= "table" then
        if wallInOne.countMap(nextConfig.playlists) >= MAX_PLAYLISTS then
            wallInOne.setActionError(noctalia.tr("errors.playlist_limit", { limit = tostring(MAX_PLAYLISTS) }), "quick-choice")
            return false
        end
        local used = {}
        for id in pairs(nextConfig.playlists) do
            used[id] = true
        end
        quickId = wallInOne.uniqueIdentifier(used, wallInOne.stableIdentifier("quick", output, 1)) or ""
        if quickId == "" then
            wallInOne.setActionError(noctalia.tr("errors.playlist_name"), "quick-choice")
            return false
        end
        quick = {
            name = "Quick Choice · " .. output,
            order = "rotate",
            interval_seconds = wallInOne.configuredCycleSeconds(),
            entries = {},
            quick_choice = true,
        }
        nextConfig.playlists[quickId] = quick
        outputConfig.quick_choice_playlist = quickId
    end
    local bundle = wallInOne.entryBundleFromRequest(entry, output, {})
    if bundle == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "quick-choice")
        return false
    end
    bundle = wallInOne.materializedPlaylistEntry(bundle, nextConfig.pairings)
    quick.entries = { bundle }
    if not wallInOne.saveConfig(nextConfig, "quick-choice") then
        return false
    end
    wallInOne.invalidateCycleIntent(output, false)
    local state = wallInOne.outputState(output)
    wallInOne.disarmOtherPlaylistRuns(output, quickId)
    state.active_playlist = quickId
    state.manual_pin = true
    state.active_schedule = ""
    state.last_transition_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    local run = wallInOne.playlistRunState(output, quickId)
    run.running = false
    run.paused = false
    run.parked = false
    run.current_entry = bundle.id
    run.next_due = 0
    run.history = { bundle.id }
    run.bag = {}
    wallInOne.persistRuntimeIfChanged(true)
    wallInOne.applyPlaylistEntry({
        output = output,
        playlist_id = quickId,
        entry = bundle,
        notify = notifySuccess == true,
        on_complete = function(ok, _path, applyError)
            run.parked = ok == true
            run.last_applied_at = if ok == true
                then noctalia.formatTime("%Y-%m-%d %H:%M:%S")
                else run.last_applied_at
            run.last_error = if ok == true then tostring(applyError or "") else tostring(applyError or lastActionError)
            wallInOne.persistRuntimeIfChanged(true)
            wallInOne.publishStatus()
        end,
    })
    return true
end

function wallInOne.managedLibraryEntry(itemId)
    itemId = tostring(itemId or "")
    if itemId == "" or #itemId > 80 or itemId:find("[%c]") then
        return nil
    end
    for _, entries in ipairs({ library.stills, library.videos }) do
        if type(entries) == "table" then
            for _, entry in ipairs(entries) do
                if type(entry) == "table" and entry.id == itemId and entry.managed == true and entry.deletable == true then
                    return entry
                end
            end
        end
    end
    return nil
end

function wallInOne.removeManagedPayload(path, sidecarPath)
    local pathInfo = noctalia.fileInfo(path)
    local sidecarInfo = noctalia.fileInfo(sidecarPath)
    if
        type(pathInfo) ~= "table"
        or pathInfo.isDir == true
        or (tonumber(pathInfo.size) or 0) <= 0
        or type(sidecarInfo) ~= "table"
        or sidecarInfo.isDir == true
        or (tonumber(sidecarInfo.size) or 0) <= 0
    then
        return false, noctalia.tr("errors.managed_missing")
    end

    local suffix = ".wall-in-one-deleting-" .. SERVICE_NONCE .. "-" .. tostring(noctalia.nowMs())
    local stagedPath = path .. suffix
    local stagedSidecar = sidecarPath .. suffix
    local sidecarStaged, sidecarStageError = noctalia.renameFile(sidecarPath, stagedSidecar)
    if sidecarStaged ~= true then
        return false, tostring(sidecarStageError or noctalia.tr("errors.managed_delete"))
    end
    local pathStaged, pathStageError = noctalia.renameFile(path, stagedPath)
    if pathStaged ~= true then
        noctalia.renameFile(stagedSidecar, sidecarPath)
        return false, tostring(pathStageError or noctalia.tr("errors.managed_delete"))
    end

    local removed, removeError = noctalia.removeFile(stagedPath)
    if removed ~= true then
        noctalia.renameFile(stagedPath, path)
        noctalia.renameFile(stagedSidecar, sidecarPath)
        return false, tostring(removeError or noctalia.tr("errors.managed_delete"))
    end
    local sidecarRemoved, sidecarError = noctalia.removeFile(stagedSidecar)
    if sidecarRemoved ~= true then
        -- The payload removal is the commit point. A failure to unlink the
        -- already-detached sidecar must not report that the media survived or
        -- prevent playlist/reference cleanup after the payload is gone.
        wallInOne.notifyBounded(
            "managed-sidecar-cleanup",
            tostring(sidecarError or noctalia.tr("errors.managed_sidecar_delete"))
        )
    end
    return true, nil
end

function wallInOne.removeManagedStill(path)
    local record, sidecarPath = wallInOne.readManagedStillSidecar(path)
    if record == nil then
        return false, noctalia.tr("errors.managed_sidecar")
    end
    local removed, removeError = wallInOne.removeManagedPayload(path, sidecarPath)
    if not removed then
        return false, removeError
    end
    return true, nil, tostring(record.dynamic_id or "")
end

function wallInOne.removeDeletedPathFromPlaylists(path, mediaType)
    local nextConfig = wallInOne.editableConfig()
    if nextConfig == nil then
        return false
    end
    local changed = false
    local removedByPlaylist = {}
    local removedPairings = {}
    for pairingId, pairing in pairs(nextConfig.pairings) do
        local media = type(pairing) == "table" and type(pairing.media) == "table" and pairing.media or nil
        local still = type(pairing) == "table" and type(pairing.still) == "table" and pairing.still or nil
        local sourceMatches = (mediaType == "image" and media == nil and still ~= nil and still.path == path)
            or (mediaType == "video" and media ~= nil and media.kind == "video" and media.source == path)
        local selectedStillMatches = still ~= nil and still.mode == "selected" and still.path == path
        if sourceMatches or selectedStillMatches then
            removedPairings[pairingId] = true
            nextConfig.pairings[pairingId] = nil
            changed = true
        end
    end
    for playlistId, playlist in pairs(nextConfig.playlists) do
        local removed = {}
        if type(playlist) == "table" and type(playlist.entries) == "table" then
            for index = #playlist.entries, 1, -1 do
                local entry = playlist.entries[index]
                local media = type(entry) == "table" and type(entry.media) == "table" and entry.media or nil
                local still = type(entry) == "table" and type(entry.still) == "table" and entry.still or nil
                local sourceMatches = (mediaType == "image" and media == nil and still ~= nil and still.path == path)
                    or (mediaType == "video" and media ~= nil and media.kind == "video" and media.source == path)
                if removedPairings[tostring(entry.pairing_id or "")] or sourceMatches then
                    removed[entry.id] = true
                    table.remove(playlist.entries, index)
                    changed = true
                elseif still ~= nil and still.mode == "selected" and still.path == path then
                    -- A selected still is required and may not silently become
                    -- automatic. Remove the now-invalid bundle instead.
                    removed[entry.id] = true
                    table.remove(playlist.entries, index)
                    changed = true
                end
            end
        end
        if next(removed) ~= nil then
            removedByPlaylist[playlistId] = removed
        end
    end
    if changed and not wallInOne.saveConfig(nextConfig, "managed-delete") then
        return false
    end
    for output, outputRuns in pairs(runtime.runs) do
        if type(outputRuns) == "table" then
            for playlistId, removed in pairs(removedByPlaylist) do
                local run = outputRuns[playlistId]
                if type(run) == "table" then
                    if removed[run.current_entry] then
                        run.current_entry = ""
                    end
                    local function retain(values)
                        local retained = {}
                        for _, id in ipairs(type(values) == "table" and values or {}) do
                            if not removed[id] then
                                table.insert(retained, id)
                            end
                        end
                        return retained
                    end
                    run.history = retain(run.history)
                    run.bag = retain(run.bag)
                    local playlist = nextConfig.playlists[playlistId]
                    if type(playlist) == "table" and #playlist.entries == 0 then
                        run.running = false
                        run.paused = false
                        run.parked = false
                        run.next_due = 0
                        local state = runtime.output_states[output]
                        if type(state) == "table" and state.active_playlist == playlistId then
                            wallInOne.invalidateCycleIntent(output, true)
                        end
                    end
                end
            end
        end
    end
    if changed and not wallInOne.persistRuntimeIfChanged(true) then
        return false
    end
    return true
end

function wallInOne.clearDeletedPairState(path, dynamicId)
    dynamicId = tostring(dynamicId or "")
    local stopOutputs = {}
    for output, pair in pairs(runtime.pairs) do
        if
            type(pair) == "table"
            and (pair.still_path == path or (dynamicId ~= "" and pair.dynamic_id == dynamicId))
        then
            if output ~= "all" and wallInOne.knownOutputName(output) ~= nil then
                stopOutputs[output] = true
            end
            runtime.pairs[output] = nil
        end
    end
    for key, pair in pairs(runtime.pair_registry) do
        if
            type(pair) == "table"
            and (pair.still_path == path or (dynamicId ~= "" and (key == dynamicId or pair.dynamic_id == dynamicId)))
        then
            runtime.pair_registry[key] = nil
        end
    end
    local ownedOutputs = type(rendererStatus.outputs) == "table" and rendererStatus.outputs or {}
    for output, owned in pairs(ownedOutputs) do
        if
            type(owned) == "table"
            and (
                stopOutputs[output]
                or (path ~= "" and owned.source == path)
                or (dynamicId:match("^video:") and owned.source == dynamicId:sub(7))
            )
        then
            stopOutputs[output] = true
        end
    end
    for output in pairs(stopOutputs) do
        wallInOne.invalidateCycleIntent(output, true)
    end
end

function wallInOne.managedStillsForDynamic(dynamicId)
    dynamicId = tostring(dynamicId or "")
    local candidates = {}
    local seen = {}
    local function consider(pair)
        if
            type(pair) ~= "table"
            or pair.still_managed ~= true
            or tostring(pair.dynamic_id or "") ~= dynamicId
        then
            return
        end
        local path = tostring(pair.still_path or "")
        if path == "" or seen[path] then
            return
        end
        local record, sidecarPath = wallInOne.readManagedStillSidecar(path)
        if type(record) ~= "table" or tostring(record.dynamic_id or "") ~= dynamicId then
            return
        end
        seen[path] = true
        table.insert(candidates, { path = path, sidecar = sidecarPath })
    end
    for _, pair in pairs(runtime.pairs) do
        consider(pair)
    end
    consider(runtime.pair_registry[dynamicId])
    table.sort(candidates, function(left, right)
        return left.path < right.path
    end)
    return candidates
end

function wallInOne.deleteManagedLibraryItem(itemId)
    local entry = wallInOne.managedLibraryEntry(itemId)
    if entry == nil then
        wallInOne.setActionError(noctalia.tr("errors.managed_item"), "managed-delete")
        return false
    end

    local path = tostring(entry.path or "")
    local sidecarPath = tostring(entry.sidecar or "")
    local dynamicId = tostring(entry.dynamic_id or "")
    local sidecarRecord = nil
    if entry.media_type == "image" and wallInOne.directChildOf(path, wallInOne.automaticStillDirectory()) then
        sidecarRecord, sidecarPath = wallInOne.readManagedStillSidecar(path)
        dynamicId = type(sidecarRecord) == "table" and tostring(sidecarRecord.dynamic_id or "") or ""
    elseif entry.media_type == "video" and wallInOne.directChildOf(path, wallInOne.motionBgsManagedDirectory()) then
        sidecarRecord, sidecarPath = wallInOne.readProviderSidecar(path, ".motionbgs.json", "MotionBGS")
        local info = noctalia.fileInfo(path)
        if
            type(sidecarRecord) ~= "table"
            or sidecarRecord.plugin ~= "goober/wall-in-one"
            or sidecarRecord.path ~= path
            or tostring(sidecarRecord.source_page or ""):sub(1, #MOTIONBGS_URL) ~= MOTIONBGS_URL
            or type(info) ~= "table"
            or tonumber(sidecarRecord.bytes) ~= tonumber(info.size)
        then
            sidecarRecord = nil
        end
        dynamicId = "video:" .. path
    elseif entry.media_type == "image" and wallInOne.directChildOf(path, wallInOne.wallhavenManagedDirectory()) then
        sidecarRecord, sidecarPath = wallInOne.readProviderSidecar(path, ".wallhaven.json", "Wallhaven")
        local info = noctalia.fileInfo(path)
        if
            type(sidecarRecord) ~= "table"
            or sidecarRecord.plugin ~= "goober/wall-in-one"
            or sidecarRecord.path ~= path
            or tostring(sidecarRecord.source_page or ""):sub(1, #"https://wallhaven.cc/")
                ~= "https://wallhaven.cc/"
            or type(info) ~= "table"
            or tonumber(sidecarRecord.bytes) ~= tonumber(info.size)
        then
            sidecarRecord = nil
        end
    end
    if sidecarRecord == nil or sidecarPath == "" or tostring(entry.sidecar or "") ~= sidecarPath then
        wallInOne.setActionError(noctalia.tr("errors.managed_sidecar"), "managed-delete")
        return false
    end

    lastActionError = ""

    -- Resolve every output-specific generated still before mutating metadata.
    -- pair_registry is intentionally only a last-used cache and cannot by
    -- itself represent the same dynamic source paired on multiple outputs.
    local pairedStills = if entry.media_type == "video"
        then wallInOne.managedStillsForDynamic(dynamicId)
        else {}

    -- Metadata commits before payload removal. A storage failure therefore
    -- leaves recoverable files in place instead of deleting media while stale
    -- playlist references remain on disk.
    if not wallInOne.removeDeletedPathFromPlaylists(path, entry.media_type) then
        return false
    end
    for _, still in ipairs(pairedStills) do
        if not wallInOne.removeDeletedPathFromPlaylists(still.path, "image") then
            return false
        end
    end
    wallInOne.clearDeletedPairState(path, dynamicId)
    if not wallInOne.persistRuntimeIfChanged(true) then
        return false
    end

    local removed, removeError = wallInOne.removeManagedPayload(path, sidecarPath)
    if not removed then
        wallInOne.setActionError(removeError, "managed-delete")
        libraryRefreshPending = true
        wallInOne.publishStatus()
        return false
    end

    local cleanupOk = true
    for _, still in ipairs(pairedStills) do
        local stillRemoved, stillError = wallInOne.removeManagedStill(still.path)
        if not stillRemoved then
            cleanupOk = false
            wallInOne.setActionError(stillError, "managed-delete")
        end
    end
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    libraryRefreshPending = true
    wallInOne.publishStatus()
    return cleanupOk
end

wallInOne.advancePlaylist = function(output, playlistId, direction, options)
    options = type(options) == "table" and options or {}
    local playlist, selectedId, selectedOutput = wallInOne.playlistForOutput(output, playlistId)
    if selectedOutput == nil or selectedId == nil or type(playlist) ~= "table" or #playlist.entries == 0 then
        wallInOne.setActionError(noctalia.tr("errors.playlist_empty"), "playlist")
        return false
    end
    if cycleApplying[selectedOutput] then
        return false
    end
    local state = wallInOne.playlistRunState(selectedOutput, selectedId)
    if state.paused == true and options.allow_paused ~= true then
        wallInOne.setActionError(noctalia.tr("errors.playlist_paused"), "playlist")
        return false
    end
    local restoreCurrent = options.restore_current == true
    local restoredNextDue = math.max(0, math.floor(tonumber(state.next_due) or 0))
    local entryId = if restoreCurrent
        then tostring(state.current_entry or "")
        else wallInOne.selectPlaylistEntryId(
            playlist,
            state,
            direction or "next",
            wallInOne.effectivePlaylistOrder(selectedOutput, playlist)
        )
    local entryIndex = entryId ~= nil and wallInOne.entryIndexById(playlist, entryId) or nil
    local entry = entryIndex ~= nil
            and wallInOne.materializedPlaylistEntry(playlist.entries[entryIndex], config.pairings)
        or nil
    if entry == nil then
        return false
    end
    if not restoreCurrent and direction ~= "previous" then
        table.insert(state.history, entryId)
        while #state.history > MAX_HISTORY_ENTRIES do
            table.remove(state.history, 1)
        end
    end
    if not restoreCurrent then
        state.current_entry = entryId
    end
    state.parked = false
    state.last_error = ""
    local generation = (tonumber(cycleGeneration[selectedOutput]) or 0) + 1
    cycleGeneration[selectedOutput] = generation
    cycleApplying[selectedOutput] = generation
    local expectsRunning = state.running == true
    local function shouldStart()
        if tonumber(cycleGeneration[selectedOutput]) ~= generation then
            return false
        end
        local currentOutputState = wallInOne.outputState(selectedOutput)
        local current = wallInOne.playlistRunState(selectedOutput, selectedId)
        if current.paused == true then
            return false
        end
        return currentOutputState.active_playlist == selectedId and (not expectsRunning or current.running == true)
    end
    wallInOne.persistRuntimeIfChanged(true)
    wallInOne.publishStatus()
    wallInOne.applyPlaylistEntry({
        output = selectedOutput,
        playlist_id = selectedId,
        entry = entry,
        notify = options.notify == true,
        palette_allowed = options.palette_allowed,
        should_start = shouldStart,
        on_complete = function(ok, _path, applyError)
            if tonumber(cycleGeneration[selectedOutput]) ~= generation then
                if cycleApplying[selectedOutput] == generation then
                    cycleApplying[selectedOutput] = nil
                end
                if type(options.on_complete) == "function" then
                    options.on_complete(false, noctalia.tr("errors.capture_replaced"))
                end
                return
            end
            if cycleApplying[selectedOutput] == generation then
                cycleApplying[selectedOutput] = nil
            end
            local current = wallInOne.playlistRunState(selectedOutput, selectedId)
            current.last_error = if ok == true
                then tostring(applyError or "")
                else tostring(applyError or lastActionError or noctalia.tr("errors.playlist_apply"))
            if ok == true then
                current.last_applied_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            end
            local appliedMedia = type(entry.media) == "table" and entry.media or nil
            if ok == true and (#playlist.entries == 1 or appliedMedia == nil) then
                wallInOne.resetRendererExitState(selectedOutput)
            end
            if restoreCurrent then
                -- Service/host teardown removes internally owned renderers.
                -- Recreate the saved current entry without consuming another
                -- rotate/shuffle choice or moving its already-saved deadline.
                current.next_due = if current.running == true and current.paused ~= true
                    then restoredNextDue
                    else 0
            elseif ok == true and #playlist.entries == 1 then
                current.running = false
                current.paused = false
                current.parked = true
                current.next_due = 0
            elseif current.running == true and current.paused ~= true then
                current.next_due = wallInOne.nowSeconds()
                    + wallInOne.effectivePlaylistInterval(selectedOutput, playlist)
            else
                current.next_due = 0
            end
            wallInOne.persistRuntimeIfChanged(true)
            wallInOne.publishStatus()
            if type(options.on_complete) == "function" then
                options.on_complete(ok == true, applyError)
            end
        end,
    })
    return true
end

function wallInOne.setPlaylistRunState(output, playlistId, action, manualPin, deferApply)
    local playlist, selectedId, selectedOutput = wallInOne.playlistForOutput(output, playlistId)
    if selectedOutput == nil or selectedId == nil or type(playlist) ~= "table" or #playlist.entries == 0 then
        wallInOne.setActionError(noctalia.tr("errors.playlist_empty"), "playlist")
        return false
    end
    local outputRuntime = wallInOne.outputState(selectedOutput)
    wallInOne.disarmOtherPlaylistRuns(selectedOutput, selectedId)
    outputRuntime.active_playlist = selectedId
    if manualPin ~= nil then
        outputRuntime.manual_pin = manualPin == true
        if manualPin == true then
            outputRuntime.active_schedule = ""
        end
    end
    outputRuntime.last_transition_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    local state = wallInOne.playlistRunState(selectedOutput, selectedId)
    if action == "start" then
        wallInOne.invalidateCycleIntent(selectedOutput, false)
        state.running = #playlist.entries > 1
        state.paused = false
        state.parked = false
        state.next_due = wallInOne.nowSeconds()
        wallInOne.persistRuntimeIfChanged(true)
        if deferApply == true then
            return true
        end
        return wallInOne.advancePlaylist(selectedOutput, selectedId, "next", { notify = true })
    elseif action == "stop" then
        wallInOne.invalidateCycleIntent(selectedOutput, true)
        state.running = false
        state.paused = false
        state.parked = false
        state.next_due = 0
    elseif action == "pause" then
        wallInOne.invalidateCycleIntent(selectedOutput, false)
        state.paused = true
        local owned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs[selectedOutput] or nil
        local ownedState = type(owned) == "table" and tostring(owned.state or "") or ""
        if type(owned) == "table" and (ownedState == "running" or ownedState == "paused") then
            -- Coordinator status can trail the renderer by one shared-state
            -- observation. The supervisor's playback commands are idempotent,
            -- so always deliver the requested intent to an owned playback
            -- child instead of dropping it because this snapshot is stale.
            wallInOne.sendRendererCommand({ action = "pause", output = selectedOutput })
        end
    elseif action == "resume" then
        if #playlist.entries == 1 and state.parked == true then
            state.running = false
            state.paused = false
            state.next_due = 0
            wallInOne.persistRuntimeIfChanged(true)
            wallInOne.publishStatus()
            return true
        end
        state.running = #playlist.entries > 1
        state.paused = false
        state.parked = false
        local owned = type(rendererStatus.outputs) == "table" and rendererStatus.outputs[selectedOutput] or nil
        local ownedState = type(owned) == "table" and tostring(owned.state or "") or ""
        if type(owned) == "table" and (ownedState == "running" or ownedState == "paused") then
            wallInOne.sendRendererCommand({ action = "resume", output = selectedOutput })
            state.next_due = wallInOne.nowSeconds()
                + wallInOne.effectivePlaylistInterval(selectedOutput, playlist)
        else
            state.next_due = wallInOne.nowSeconds()
        end
    else
        return false
    end
    wallInOne.persistRuntimeIfChanged(true)
    wallInOne.publishStatus()
    if action == "resume" and (tonumber(state.next_due) or 0) <= wallInOne.nowSeconds() then
        return wallInOne.advancePlaylist(selectedOutput, selectedId, "next", { notify = true })
    end
    return true
end

function wallInOne.addCurrentStaticToPlaylist(output, playlistId)
    output = wallInOne.targetOutput(output)
    if output == nil or not providers.noctalia_cli then
        wallInOne.setActionError(noctalia.tr("availability.backing"), "playlist-add-static")
        return
    end
    local command = "noctalia msg wallpaper-get " .. wallInOne.shellQuote(output)
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            wallInOne.setActionError(
                noctalia.tr("errors.backing_query", { detail = wallInOne.commandFailureDetail(result) }),
                "playlist-add-static"
            )
            return
        end
        local source = noctalia.string.trim(tostring(result.stdout or ""))
        local info = source ~= "" and noctalia.fileInfo(source) or nil
        if source:sub(1, 1) ~= "/" or source:find("[%c]") or type(info) ~= "table" or info.isDir == true then
            wallInOne.setActionError(noctalia.tr("errors.backing_source"), "playlist-add-static")
            return
        end
        wallInOne.addPlaylistEntry(output, playlistId, {
            kind = "static",
            source = source,
            label = source:match("([^/]+)$") or source,
            added_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        })
    end, 5000)
    if not started then
        wallInOne.setActionError(noctalia.tr("errors.backing_query_start"), "playlist-add-static")
    end
end

function wallInOne.renamePlaylist(playlistId, name)
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[tostring(playlistId or "")] or nil
    name = noctalia.string.trim(tostring(name or ""))
    if type(playlist) ~= "table" or not wallInOne.validPersistedKey(name) then
        wallInOne.setActionError(noctalia.tr("errors.playlist_name"), "playlist-rename")
        return false
    end
    playlist.name = name
    return wallInOne.saveConfig(nextConfig, "playlist-rename")
end

function wallInOne.duplicatePlaylist(playlistId, name, output)
    local source = config.playlists[tostring(playlistId or "")]
    if type(source) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.playlist_missing"), "playlist-duplicate")
        return nil
    end
    local nextConfig = wallInOne.editableConfig()
    if nextConfig == nil or wallInOne.countMap(nextConfig.playlists) >= MAX_PLAYLISTS then
        wallInOne.setActionError(noctalia.tr("errors.playlist_limit", { limit = tostring(MAX_PLAYLISTS) }), "playlist-duplicate")
        return nil
    end
    name = noctalia.string.trim(tostring(name or (source.name .. " copy")))
    if not wallInOne.validPersistedKey(name) then
        wallInOne.setActionError(noctalia.tr("errors.playlist_name"), "playlist-duplicate")
        return nil
    end
    local usedPlaylists = {}
    for id in pairs(nextConfig.playlists) do
        usedPlaylists[id] = true
    end
    local newId = wallInOne.uniqueIdentifier(usedPlaylists, wallInOne.stableIdentifier("playlist", name, noctalia.nowMs()))
    if newId == nil then
        return nil
    end
    local copy = wallInOne.normalizedPlaylist(source)
    copy.name = name
    copy.quick_choice = false
    local usedEntries = {}
    for index, entry in ipairs(copy.entries) do
        entry.id = wallInOne.uniqueIdentifier(
            usedEntries,
            wallInOne.stableIdentifier("entry", newId .. ":" .. entry.id, index)
        )
    end
    nextConfig.playlists[newId] = copy
    output = wallInOne.targetOutput(output)
    if output ~= nil then
        nextConfig.outputs[output] = nextConfig.outputs[output]
            or { fallback_playlist = "", quick_choice_playlist = "", schedules = {} }
        nextConfig.outputs[output].fallback_playlist = newId
    end
    if not wallInOne.saveConfig(nextConfig, "playlist-duplicate") then
        return nil
    end
    if output ~= nil then
        local state = wallInOne.outputState(output)
        wallInOne.disarmOtherPlaylistRuns(output, newId)
        state.active_playlist = newId
        state.manual_pin = true
        state.active_schedule = ""
        wallInOne.persistRuntimeIfChanged(true)
    end
    return newId
end

function wallInOne.fallbackPlaylistId(playlists, excludedId)
    local ids = {}
    for id, playlist in pairs(playlists) do
        if id ~= excludedId and type(playlist) == "table" and playlist.quick_choice ~= true then
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    return ids[1] or ""
end

function wallInOne.deletePlaylist(playlistId)
    playlistId = tostring(playlistId or "")
    local current = config.playlists[playlistId]
    if type(current) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.playlist_missing"), "playlist-delete")
        return false
    end
    if current.quick_choice == true then
        wallInOne.setActionError(noctalia.tr("errors.quick_choice_protected"), "playlist-delete")
        return false
    end
    local nextConfig = wallInOne.editableConfig()
    nextConfig.playlists[playlistId] = nil
    local replacement = wallInOne.fallbackPlaylistId(nextConfig.playlists, playlistId)
    for output, outputConfig in pairs(nextConfig.outputs) do
        if outputConfig.fallback_playlist == playlistId then
            outputConfig.fallback_playlist = replacement
        end
        for index = #outputConfig.schedules, 1, -1 do
            if outputConfig.schedules[index].playlist == playlistId then
                table.remove(outputConfig.schedules, index)
            end
        end
    end
    local saved = wallInOne.saveConfig(nextConfig, "playlist-delete")
    if not saved then
        return false
    end
    for output, state in pairs(runtime.output_states) do
        if type(state) == "table" and state.active_playlist == playlistId then
            wallInOne.invalidateCycleIntent(output, true)
            state.active_playlist = replacement
            state.active_schedule = ""
            state.manual_pin = false
        end
    end
    for _, outputRuns in pairs(runtime.runs) do
        if type(outputRuns) == "table" then
            outputRuns[playlistId] = nil
        end
    end
    wallInOne.persistRuntimeIfChanged(true)
    return true
end

function wallInOne.setOutputFallback(output, playlistId)
    output = wallInOne.targetOutput(output)
    playlistId = tostring(playlistId or "")
    if output == nil or config.playlists[playlistId] == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_assignment"), "playlist-assign")
        return false
    end
    local nextConfig = wallInOne.editableConfig()
    nextConfig.outputs[output] = nextConfig.outputs[output]
        or { fallback_playlist = "", quick_choice_playlist = "", schedules = {} }
    nextConfig.outputs[output].fallback_playlist = playlistId
    if not wallInOne.saveConfig(nextConfig, "playlist-assign") then
        return false
    end
    local state = wallInOne.outputState(output)
    if state.manual_pin ~= true and state.active_schedule == "" then
        wallInOne.disarmOtherPlaylistRuns(output, playlistId)
        state.active_playlist = playlistId
    end
    wallInOne.persistRuntimeIfChanged(true)
    return true
end

function wallInOne.removePlaylistEntry(playlistId, entryId)
    playlistId = tostring(playlistId or "")
    entryId = tostring(entryId or "")
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[playlistId] or nil
    local index = type(playlist) == "table" and wallInOne.entryIndexById(playlist, entryId) or nil
    if index == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry_missing"), "playlist-entry-remove")
        return false
    end
    table.remove(playlist.entries, index)
    if not wallInOne.saveConfig(nextConfig, "playlist-entry-remove") then
        return false
    end
    for output, outputRuns in pairs(runtime.runs) do
        local run = type(outputRuns) == "table" and outputRuns[playlistId] or nil
        if type(run) == "table" then
            if run.current_entry == entryId then
                wallInOne.invalidateCycleIntent(output, #playlist.entries == 0)
                run.current_entry = ""
            end
            local function without(values)
                local result = {}
                for _, id in ipairs(type(values) == "table" and values or {}) do
                    if id ~= entryId then
                        table.insert(result, id)
                    end
                end
                return result
            end
            run.history = without(run.history)
            run.bag = without(run.bag)
            if #playlist.entries == 0 then
                run.running = false
                run.paused = false
                run.parked = false
                run.next_due = 0
            end
        end
    end
    wallInOne.persistRuntimeIfChanged(true)
    return true
end

function wallInOne.clearPlaylist(playlistId)
    playlistId = tostring(playlistId or "")
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[playlistId] or nil
    if type(playlist) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.playlist_missing"), "playlist-clear")
        return false
    end
    playlist.entries = {}
    if not wallInOne.saveConfig(nextConfig, "playlist-clear") then
        return false
    end
    for output, outputRuns in pairs(runtime.runs) do
        local run = type(outputRuns) == "table" and outputRuns[playlistId] or nil
        if type(run) == "table" then
            wallInOne.invalidateCycleIntent(output, true)
            run.running = false
            run.paused = false
            run.parked = false
            run.current_entry = ""
            run.next_due = 0
            run.history = {}
            run.bag = {}
        end
    end
    wallInOne.persistRuntimeIfChanged(true)
    return true
end

function wallInOne.savePlaylistEntry(playlistId, rawEntry)
    playlistId = tostring(playlistId or "")
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[playlistId] or nil
    local entry = wallInOne.normalizedEntryBundle(rawEntry)
    local index = entry ~= nil and type(playlist) == "table" and wallInOne.entryIndexById(playlist, entry.id) or nil
    if index == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "playlist-entry-save")
        return false
    end
    local pairingId = tostring(entry.pairing_id or "")
    if pairingId ~= "" and type(nextConfig.pairings[pairingId]) == "table" then
        entry.customized = true
        nextConfig.pairings[pairingId] = wallInOne.pairingFromEntry(entry, pairingId)
        wallInOne.syncPairingSnapshots(nextConfig, pairingId)
    else
        entry.pairing_id = nil
        playlist.entries[index] = entry
    end
    return wallInOne.saveConfig(nextConfig, "playlist-entry-save")
end

function wallInOne.movePlaylistEntry(playlistId, entryId, direction)
    playlistId = tostring(playlistId or "")
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[playlistId] or nil
    local index = type(playlist) == "table" and wallInOne.entryIndexById(playlist, tostring(entryId or "")) or nil
    if index == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry_missing"), "playlist-entry-move")
        return false
    end
    local target = if tostring(direction) == "up" then index - 1 elseif tostring(direction) == "down" then index + 1 else 0
    if target < 1 or target > #playlist.entries then
        return true
    end
    playlist.entries[index], playlist.entries[target] = playlist.entries[target], playlist.entries[index]
    return wallInOne.saveConfig(nextConfig, "playlist-entry-move")
end

function wallInOne.placePlaylistEntry(playlistId, entryId, anchorId, placement)
    playlistId = tostring(playlistId or "")
    entryId = tostring(entryId or "")
    anchorId = tostring(anchorId or "")
    placement = tostring(placement or "")
    local nextConfig = wallInOne.editableConfig()
    local playlist = nextConfig ~= nil and nextConfig.playlists[playlistId] or nil
    local source = type(playlist) == "table" and wallInOne.entryIndexById(playlist, entryId) or nil
    if source == nil or (placement ~= "before" and placement ~= "after" and placement ~= "end") then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry_missing"), "playlist-entry-place")
        return false
    end
    if entryId == anchorId then
        return true
    end
    local entry = table.remove(playlist.entries, source)
    if placement == "end" then
        table.insert(playlist.entries, entry)
    else
        local anchor = wallInOne.entryIndexById(playlist, anchorId)
        if anchor == nil then
            wallInOne.setActionError(noctalia.tr("errors.playlist_entry_missing"), "playlist-entry-place")
            return false
        end
        table.insert(playlist.entries, if placement == "after" then anchor + 1 else anchor, entry)
    end
    return wallInOne.saveConfig(nextConfig, "playlist-entry-place")
end

function wallInOne.applyPlaylistEntryById(output, playlistId, entryId)
    local playlist, selectedId, selectedOutput = wallInOne.playlistForOutput(output, playlistId)
    local index = type(playlist) == "table" and wallInOne.entryIndexById(playlist, tostring(entryId or "")) or nil
    if selectedOutput == nil or selectedId == nil or index == nil then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry_missing"), "playlist-entry-apply")
        return false
    end
    wallInOne.invalidateCycleIntent(selectedOutput, false)
    local outputRuntime = wallInOne.outputState(selectedOutput)
    wallInOne.disarmOtherPlaylistRuns(selectedOutput, selectedId)
    outputRuntime.active_playlist = selectedId
    outputRuntime.manual_pin = true
    outputRuntime.active_schedule = ""
    outputRuntime.last_transition_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    local run = wallInOne.playlistRunState(selectedOutput, selectedId)
    run.running = false
    run.paused = false
    run.parked = false
    run.current_entry = tostring(entryId)
    run.next_due = 0
    table.insert(run.history, tostring(entryId))
    while #run.history > MAX_HISTORY_ENTRIES do
        table.remove(run.history, 1)
    end
    wallInOne.applyPlaylistEntry({
        output = selectedOutput,
        playlist_id = selectedId,
        entry = wallInOne.materializedPlaylistEntry(playlist.entries[index], config.pairings),
        notify = true,
        on_complete = function(ok, _path, applyError)
            run.parked = ok == true
            run.last_applied_at = if ok == true
                then noctalia.formatTime("%Y-%m-%d %H:%M:%S")
                else run.last_applied_at
            run.last_error = if ok == true then tostring(applyError or "") else tostring(applyError or lastActionError)
            wallInOne.persistRuntimeIfChanged(true)
            wallInOne.publishStatus()
        end,
    })
    wallInOne.persistRuntimeIfChanged(true)
    return true
end

function wallInOne.upsertSchedule(output, rawSchedule, beforeId)
    output = wallInOne.targetOutput(output)
    if output == nil or type(rawSchedule) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.schedule_invalid"), "schedule-save")
        return false
    end
    local nextConfig = wallInOne.editableConfig()
    local outputConfig = nextConfig.outputs[output]
    if type(outputConfig) ~= "table" then
        outputConfig = { fallback_playlist = "", quick_choice_playlist = "", schedules = {} }
        nextConfig.outputs[output] = outputConfig
    end
    local id = tostring(rawSchedule.id or "")
    if id == "" then
        local used = {}
        for _, schedule in ipairs(outputConfig.schedules) do
            used[schedule.id] = true
        end
        id = wallInOne.uniqueIdentifier(
            used,
            wallInOne.stableIdentifier("schedule", output .. ":" .. tostring(rawSchedule.name or "schedule"), noctalia.nowMs())
        ) or ""
    end
    local candidate = {
        id = id,
        name = rawSchedule.name,
        playlist = rawSchedule.playlist,
        enabled = rawSchedule.enabled,
        weekdays = rawSchedule.weekdays,
        -- Commands from the schema-3 panel remain safe during a rolling plugin
        -- reload: an omitted month filter means every month, never no month.
        months = if rawSchedule.months ~= nil then rawSchedule.months else wallInOne.allMonths(),
        start_minute = rawSchedule.start_minute,
        end_minute = rawSchedule.end_minute,
        all_day = rawSchedule.all_day,
    }
    local normalized = wallInOne.normalizedSchedule(candidate, nextConfig.playlists)
    if normalized == nil then
        wallInOne.setActionError(noctalia.tr("errors.schedule_invalid"), "schedule-save")
        return false
    end
    local replaced = false
    for index, schedule in ipairs(outputConfig.schedules) do
        if schedule.id == id then
            outputConfig.schedules[index] = normalized
            replaced = true
            break
        end
    end
    if not replaced then
        if #outputConfig.schedules >= MAX_SCHEDULES_PER_OUTPUT then
            wallInOne.setActionError(
                noctalia.tr("errors.schedule_limit", { limit = tostring(MAX_SCHEDULES_PER_OUTPUT) }),
                "schedule-save"
            )
            return false
        end
        local anchor = nil
        local requestedAnchor = tostring(beforeId or "")
        if requestedAnchor ~= "" then
            for index, schedule in ipairs(outputConfig.schedules) do
                if tostring(schedule.id or "") == requestedAnchor then
                    anchor = index
                    break
                end
            end
        end
        if anchor == nil then
            table.insert(outputConfig.schedules, normalized)
        else
            table.insert(outputConfig.schedules, anchor, normalized)
        end
    end
    if not wallInOne.saveConfig(nextConfig, "schedule-save") then
        return false
    end
    scheduleReevaluationPending[output] = true
    return true
end

function wallInOne.deleteSchedule(output, scheduleId)
    output = wallInOne.targetOutput(output)
    local nextConfig = wallInOne.editableConfig()
    local outputConfig = output ~= nil and nextConfig ~= nil and nextConfig.outputs[output] or nil
    if type(outputConfig) ~= "table" then
        return false
    end
    for index, schedule in ipairs(outputConfig.schedules) do
        if schedule.id == tostring(scheduleId or "") then
            table.remove(outputConfig.schedules, index)
            local saved = wallInOne.saveConfig(nextConfig, "schedule-delete")
            if not saved then
                return false
            end
            scheduleReevaluationPending[output] = true
            return true
        end
    end
    return false
end

function wallInOne.placeSchedule(output, scheduleId, anchorId, placement)
    output = wallInOne.targetOutput(output)
    scheduleId = tostring(scheduleId or "")
    anchorId = tostring(anchorId or "")
    placement = tostring(placement or "")
    if
        output == nil
        or scheduleId == ""
        or (placement ~= "before" and placement ~= "after" and placement ~= "end")
        or (placement ~= "end" and anchorId == "")
    then
        wallInOne.setActionError(noctalia.tr("errors.schedule_invalid"), "schedule-place")
        return false
    end
    if placement ~= "end" and scheduleId == anchorId then
        return true
    end
    local nextConfig = wallInOne.editableConfig()
    local outputConfig = nextConfig ~= nil and nextConfig.outputs[output] or nil
    local schedules = type(outputConfig) == "table" and outputConfig.schedules or nil
    if type(schedules) ~= "table" then
        wallInOne.setActionError(noctalia.tr("errors.schedule_invalid"), "schedule-place")
        return false
    end
    local sourceIndex = nil
    local anchorIndex = nil
    for index, schedule in ipairs(schedules) do
        if schedule.id == scheduleId then
            sourceIndex = index
        end
        if schedule.id == anchorId then
            anchorIndex = index
        end
    end
    if sourceIndex == nil or (placement ~= "end" and anchorIndex == nil) then
        wallInOne.setActionError(noctalia.tr("errors.schedule_invalid"), "schedule-place")
        return false
    end

    -- Work only on the normalized editable copy, then persist once. Recompute
    -- the anchor after removal so moves across either side cannot drift by one.
    local moving = table.remove(schedules, sourceIndex)
    if placement == "end" then
        table.insert(schedules, moving)
        if not wallInOne.saveConfig(nextConfig, "schedule-place") then
            return false
        end
        scheduleReevaluationPending[output] = true
        return true
    end
    anchorIndex = nil
    for index, schedule in ipairs(schedules) do
        if schedule.id == anchorId then
            anchorIndex = index
            break
        end
    end
    if anchorIndex == nil then
        wallInOne.setActionError(noctalia.tr("errors.schedule_invalid"), "schedule-place")
        return false
    end
    table.insert(schedules, if placement == "before" then anchorIndex else anchorIndex + 1, moving)
    if not wallInOne.saveConfig(nextConfig, "schedule-place") then
        return false
    end
    scheduleReevaluationPending[output] = true
    return true
end

function wallInOne.weekdayEnabled(schedule, weekday)
    for _, value in ipairs(type(schedule.weekdays) == "table" and schedule.weekdays or {}) do
        if tonumber(value) == weekday then
            return true
        end
    end
    return false
end

function wallInOne.monthEnabled(schedule, month)
    for _, value in ipairs(type(schedule.months) == "table" and schedule.months or {}) do
        if tonumber(value) == month then
            return true
        end
    end
    return false
end

function wallInOne.scheduleMatches(schedule, weekday, month, dayOfMonth, minute)
    if schedule.enabled ~= true then
        return false
    end
    weekday = math.floor(tonumber(weekday) or -1)
    month = math.floor(tonumber(month) or -1)
    dayOfMonth = math.floor(tonumber(dayOfMonth) or -1)
    minute = math.floor(tonumber(minute) or -1)
    if
        weekday < 0
        or weekday > 6
        or month < 1
        or month > 12
        or dayOfMonth < 1
        or dayOfMonth > 31
        or minute < 0
        or minute > 1439
    then
        return false
    end
    if schedule.all_day == true then
        return wallInOne.weekdayEnabled(schedule, weekday) and wallInOne.monthEnabled(schedule, month)
    end
    local startMinute = tonumber(schedule.start_minute) or 0
    local endMinute = tonumber(schedule.end_minute) or 0
    if startMinute < endMinute then
        return wallInOne.weekdayEnabled(schedule, weekday)
            and wallInOne.monthEnabled(schedule, month)
            and minute >= startMinute
            and minute < endMinute
    end
    if minute >= startMinute then
        return wallInOne.weekdayEnabled(schedule, weekday) and wallInOne.monthEnabled(schedule, month)
    end
    if minute >= endMinute then
        return false
    end
    local previousWeekday = (weekday + 6) % 7
    local previousMonth = if dayOfMonth == 1 then ((month + 10) % 12) + 1 else month
    return wallInOne.weekdayEnabled(schedule, previousWeekday) and wallInOne.monthEnabled(schedule, previousMonth)
end

function wallInOne.winningScheduleAt(outputConfig, weekday, month, dayOfMonth, minute)
    local winner = nil
    for _, schedule in ipairs(outputConfig.schedules) do
        if wallInOne.scheduleMatches(schedule, weekday, month, dayOfMonth, minute) then
            -- Rules are rendered and persisted top-to-bottom. Replacing the
            -- candidate makes the lowest matching rule the deterministic winner.
            winner = schedule
        end
    end
    return winner
end

function wallInOne.winningSchedule(outputConfig)
    local weekday = tonumber(noctalia.formatTime("%w")) or 0
    local month = tonumber(noctalia.formatTime("%m")) or 1
    local dayOfMonth = tonumber(noctalia.formatTime("%d")) or 1
    local hour = tonumber(noctalia.formatTime("%H")) or 0
    local minute = hour * 60 + (tonumber(noctalia.formatTime("%M")) or 0)
    return wallInOne.winningScheduleAt(outputConfig, weekday, month, dayOfMonth, minute)
end

function wallInOne.reevaluateOutputSchedule(output, force, deferApply)
    local outputConfig = config.outputs[output]
    if type(outputConfig) ~= "table" or wallInOne.knownOutputName(output) == nil then
        return false
    end
    local state = wallInOne.outputState(output)
    if state.manual_pin == true then
        return false
    end
    local winner = wallInOne.winningSchedule(outputConfig)
    local desired = if winner ~= nil then winner.playlist else tostring(outputConfig.fallback_playlist or "")
    local scheduleId = if winner ~= nil then winner.id else ""
    if desired == "" or config.playlists[desired] == nil then
        return false
    end
    local changed = state.active_playlist ~= desired or state.active_schedule ~= scheduleId
    if changed then
        wallInOne.disarmOtherPlaylistRuns(output, desired)
    end
    state.active_playlist = desired
    state.active_schedule = scheduleId
    if changed then
        state.last_transition_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    end
    local run = wallInOne.playlistRunState(output, desired)
    if changed or (force == true and run.current_entry == "") then
        local started = wallInOne.setPlaylistRunState(output, desired, "start", false, deferApply == true)
        return started, if started == true and deferApply == true then desired else nil
    end
    wallInOne.persistRuntimeIfChanged(changed)
    if changed then
        wallInOne.publishStatus()
    end
    return changed, nil
end

function wallInOne.resumeOutputSchedule(output)
    output = wallInOne.targetOutput(output)
    if output == nil then
        return false
    end
    local state = wallInOne.outputState(output)
    state.manual_pin = false
    state.active_schedule = ""
    wallInOne.persistRuntimeIfChanged(true)
    return wallInOne.reevaluateOutputSchedule(output, true)
end

function wallInOne.captureCurrentBacking(output, force, notifySuccess)
    output = wallInOne.targetOutput(output)
    if output == nil then
        wallInOne.setActionError(noctalia.tr("availability.output"), "capture-backing")
        return
    end
    if not providers.noctalia_cli then
        wallInOne.setActionError(noctalia.tr("availability.native_cli"), "capture-backing")
        return
    end

    local command = "noctalia msg wallpaper-get " .. wallInOne.shellQuote(output)
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            wallInOne.setActionError(
                noctalia.tr("errors.backing_query", { detail = wallInOne.commandFailureDetail(result) }),
                "capture-backing"
            )
            return
        end

        local source = noctalia.string.trim(tostring(result.stdout or ""))
        local info = source ~= "" and noctalia.fileInfo(source) or nil
        local extension = wallInOne.fileExtension(source)
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
            wallInOne.setActionError(noctalia.tr("errors.backing_source"), "capture-backing")
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
            wallInOne.sanitizedName(source:match("([^/]+)$") or "backing"),
            tostring(tonumber(info.size) or 0),
            tostring(tonumber(info.mtime) or 0),
        }, "-")
        local destination, destinationError = wallInOne.captureDestination("backing", identity, output, destinationExtension)
        if destination == nil then
            wallInOne.setActionError(destinationError, "capture-directory")
            return
        end
        wallInOne.runCapture({
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
        wallInOne.setActionError(noctalia.tr("errors.backing_query_start"), "capture-backing")
    end
end

function wallInOne.pairConfiguredStill(output, notifySuccess)
    output = wallInOne.targetOutput(output)
    if output == nil then
        wallInOne.setActionError(noctalia.tr("availability.output"), "manual-pair")
        return
    end
    local source = wallInOne.configuredManualPair()
    local info = source ~= "" and noctalia.fileInfo(source) or nil
    local extension = wallInOne.fileExtension(source)
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
        wallInOne.setActionError(noctalia.tr("errors.manual_pair"), "manual-pair")
        return
    end
    wallInOne.invalidateCycleIntent(output, false)
    local pairToken = tonumber(applyGeneration[output]) or 0
    local destination
    local pairPath
    local stagingPath
    local destinationError
    if extension == ".gif" then
        local identity = table.concat({
            wallInOne.stablePathTag(source),
            tostring(tonumber(info.size) or 0),
            tostring(tonumber(info.mtime) or 0),
            wallInOne.sanitizedName(source:match("([^/]+)$") or "manual"),
        }, "-")
        destination, destinationError = wallInOne.captureDestination("manual", identity, output, ".png")
    else
        captureSequence += 1
        destination, destinationError = wallInOne.captureStagingPath(
            "manual-" .. SERVICE_NONCE .. "-" .. tostring(noctalia.nowMs()) .. "-" .. tostring(captureSequence)
        )
        stagingPath = destination
        pairPath = source
    end
    if destination == nil then
        wallInOne.setActionError(destinationError, "capture-directory")
        return
    end
    wallInOne.runCapture({
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
            return tonumber(applyGeneration[output]) == pairToken and wallInOne.knownOutputName(output) ~= nil
        end,
    })
end

wallInOne.ownedRendererActions = {
    playback_pause = { command = "pause", capability = "pause" },
    playback_resume = { command = "resume", capability = "resume" },
    playback_toggle = { command = "toggle", capability = "toggle" },
    playback_stop = { command = "stop", capability = "stop" },
    audio_mute = { command = "mute", capability = "mute" },
    audio_unmute = { command = "unmute", capability = "unmute" },
    audio_toggle = { command = "toggle_mute", capability = "toggle_mute" },
    audio_volume_down = { command = "set_volume", capability = "set_volume" },
    audio_volume_up = { command = "set_volume", capability = "set_volume" },
    audio_set_volume = { command = "set_volume", capability = "set_volume" },
}

function wallInOne.ownedRenderer(output)
    output = wallInOne.targetOutput(output)
    local outputs = type(rendererStatus.outputs) == "table" and rendererStatus.outputs or {}
    local owned = output ~= nil and outputs[output] or nil
    if type(owned) == "table" then
        return owned, output
    end
    return nil, output
end

-- User actions, provider commands, and IPC ----------------------------------

function wallInOne.actionAvailability(action, output)
    if action == "native_open" or action == "hub_open" or action == "no_action" then
        return true, ""
    end
    if NATIVE_SWITCH_VERBS[action] ~= nil then
        return providers.noctalia_cli, noctalia.tr("availability.native_cli")
    end
    if action == "wallhaven_site" then
        return providers.wallhaven.site_available == true, noctalia.tr("availability.wallhaven_site")
    end
    if action == "motionbgs_open" then
        return providers.motionbgs.available, noctalia.tr("availability.motionbgs")
    end
    if action == "steam_launch" then
        return providers.w_engine.steam_available == true, noctalia.tr("availability.steam")
    end
    if action == "steam_workshop" then
        return providers.w_engine.steam_workshop_available == true, noctalia.tr("availability.steam_workshop")
    end
    if action == "playback_stop_all" then
        local outputs = type(rendererStatus.outputs) == "table" and rendererStatus.outputs or {}
        return rendererStatus.ready == true and next(outputs) ~= nil, noctalia.tr("availability.renderer_control")
    end
    if wallInOne.ownedRendererActions[action] ~= nil then
        local owned = wallInOne.ownedRenderer(output)
        local capabilities = type(owned) == "table" and owned.capabilities or nil
        local capability = wallInOne.ownedRendererActions[action].capability
        return type(capabilities) == "table" and capabilities[capability] == true,
            noctalia.tr("availability.renderer_control")
    end
    if action == "capture_backing" then
        return providers.noctalia_cli and wallInOne.targetOutput(output) ~= nil, noctalia.tr("availability.backing")
    end
    if action == "capture_current" or action == "capture_pair" then
        local selected = wallInOne.targetOutput(output)
        local id = selected ~= nil and providers.w_engine.internal_current[selected] or nil
        if id == nil or tostring(id) == "" then
            id = wallInOne.configuredWorkshopId()
        end
        return wallInOne.validWorkshopId(id), noctalia.tr("availability.current_scene")
    end
    if action == "video_capture" or action == "video_capture_pair" then
        local source = wallInOne.configuredVideoSource()
        return source ~= "" and noctalia.fileExists(source) and noctalia.commandExists("ffmpeg"),
            noctalia.tr("availability.video")
    end
    if action == "video_apply_pair" then
        local source = wallInOne.configuredVideoSource()
        local selected = wallInOne.targetOutput(output)
        return selected ~= nil
                and wallInOne.internalBackendReady("mpvpaper", selected) == true
                and source ~= ""
                and noctalia.fileExists(source),
            noctalia.tr("availability.video_apply")
    end
    if action == "workshop_apply_pair" then
        local selected = wallInOne.targetOutput(output)
        return selected ~= nil
                and wallInOne.internalBackendReady("w_engine", selected) == true
                and wallInOne.configuredWorkshopId() ~= "",
            noctalia.tr("availability.workshop_apply")
    end
    if action == "cycle_add_static" then
        return providers.noctalia_cli and wallInOne.targetOutput(output) ~= nil, noctalia.tr("availability.backing")
    end
    if action == "cycle_add_video" then
        local source = wallInOne.configuredVideoSource()
        return source ~= "" and noctalia.fileExists(source), noctalia.tr("availability.video")
    end
    if action == "cycle_add_workshop" then
        return wallInOne.configuredWorkshopId() ~= "", noctalia.tr("availability.current_scene")
    end
    if action == "cycle_remove_last" or action == "cycle_clear" then
        local playlist = wallInOne.playlistForOutput(output, nil)
        return type(playlist) == "table" and #playlist.entries > 0, noctalia.tr("availability.cycle")
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
        local playlist, playlistId, selected = wallInOne.playlistForOutput(output, nil)
        if action == "cycle_next" or action == "cycle_previous" or action == "cycle_random" then
            local state = selected ~= nil and playlistId ~= nil and wallInOne.playlistRunState(selected, playlistId) or nil
            if type(state) == "table" and state.paused == true then
                return false, noctalia.tr("errors.playlist_paused")
            end
        end
        return type(playlist) == "table" and #playlist.entries > 0, noctalia.tr("availability.cycle")
    end
    if action == "manual_pair" then
        local source = wallInOne.configuredManualPair()
        local info = source ~= "" and noctalia.fileInfo(source) or nil
        local extension = wallInOne.fileExtension(source)
        local supported = extension == ".png"
            or extension == ".jpg"
            or extension == ".jpeg"
            or extension == ".webp"
            or (extension == ".avif" and noctalia.commandExists("ffmpeg"))
            or (extension == ".gif" and noctalia.commandExists("ffmpeg"))
        return wallInOne.targetOutput(output) ~= nil
            and type(info) == "table"
            and info.isDir ~= true
            and (tonumber(info.size) or 0) > 0
            and supported,
            noctalia.tr("availability.manual_pair")
    end
    return false, noctalia.tr("availability.unknown")
end

function wallInOne.runNativeSwitch(request, action)
    local command = "noctalia msg " .. NATIVE_SWITCH_VERBS[action]
    local output = wallInOne.targetOutput(request.output)
    if output ~= nil then
        command ..= " " .. wallInOne.shellQuote(output)
    end
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            wallInOne.setActionError(noctalia.tr("errors.native_switch", { detail = wallInOne.commandFailureDetail(result) }), action)
        else
            lastActionError = ""
            lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            wallInOne.publishStatus()
        end
    end, 5000)
    if not started then
        wallInOne.setActionError(noctalia.tr("errors.native_switch_start"), action)
    end
end

function wallInOne.openMotionBgs()
    local started = noctalia.runAsync("xdg-open " .. wallInOne.shellQuote(MOTIONBGS_URL), function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            wallInOne.setActionError(noctalia.tr("errors.motionbgs_open", { detail = wallInOne.commandFailureDetail(result) }), "motionbgs")
        end
    end, 5000)
    if not started then
        wallInOne.setActionError(noctalia.tr("errors.motionbgs_start"), "motionbgs")
    end
end

function wallInOne.openMotionBgsHelper()
    local started = noctalia.runAsync("xdg-open " .. wallInOne.shellQuote(MOTIONBGS_HELPER_URL), function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            wallInOne.setActionError(
                noctalia.tr("errors.motionbgs_helper_open", { detail = wallInOne.commandFailureDetail(result) }),
                "motionbgs-helper"
            )
        end
    end, 5000)
    if not started then
        wallInOne.setActionError(noctalia.tr("errors.motionbgs_helper_start"), "motionbgs-helper")
    end
end

function wallInOne.openWallhavenSite()
    local started = noctalia.runAsync("xdg-open " .. wallInOne.shellQuote(WALLHAVEN_URL), function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            wallInOne.setActionError(
                noctalia.tr("errors.wallhaven_open", { detail = wallInOne.commandFailureDetail(result) }),
                "wallhaven-site"
            )
        end
    end, 5000)
    if not started then
        wallInOne.setActionError(noctalia.tr("errors.wallhaven_start"), "wallhaven-site")
    end
end

function wallInOne.openSteamTarget(action)
    local command
    if action == "steam_launch" and noctalia.commandExists("steam") then
        command = "steam -applaunch " .. WALLPAPER_ENGINE_APP_ID
    elseif action == "steam_launch" then
        command = "xdg-open " .. wallInOne.shellQuote("steam://run/" .. WALLPAPER_ENGINE_APP_ID)
    else
        command = "xdg-open " .. wallInOne.shellQuote(WALLPAPER_ENGINE_WORKSHOP_URL)
    end
    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            wallInOne.setActionError(noctalia.tr("errors.steam_open", { detail = wallInOne.commandFailureDetail(result) }), action)
        else
            lastActionError = ""
            lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            wallInOne.publishStatus()
        end
    end, 10000)
    if not started then
        wallInOne.setActionError(noctalia.tr("errors.steam_start"), action)
    end
end

function wallInOne.runOwnedRendererControl(request, action)
    if action == "playback_stop_all" then
        wallInOne.sendRendererCommand({ action = "stop_all" })
        return
    end
    local owned, output = wallInOne.ownedRenderer(request.output)
    local mapping = wallInOne.ownedRendererActions[action]
    if type(owned) ~= "table" or output == nil or type(mapping) ~= "table" then
        wallInOne.setActionError(noctalia.tr("availability.renderer_control"), "renderer-control")
        return
    end
    local command = { action = mapping.command, output = output }
    if mapping.command == "set_volume" then
        local current = math.max(0, math.min(100, math.floor(tonumber(owned.volume) or 100)))
        local requested = tonumber(request.volume)
        if action == "audio_volume_down" then
            requested = current - 5
        elseif action == "audio_volume_up" then
            requested = current + 5
        end
        command.volume = math.max(0, math.min(100, math.floor(requested or current)))
    end
    if wallInOne.sendRendererCommand(command) then
        lastActionError = ""
        lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
        wallInOne.publishStatus()
    end
end

function wallInOne.nextMotionBgsNonce()
    local previous = noctalia.state.get(MOTIONBGS_COMMAND_KEY)
    local previousNonce = if type(previous) == "table" then tonumber(previous.nonce) or 0 else 0
    local statusNonce = if type(motionBgsStatus) == "table" then tonumber(motionBgsStatus.last_nonce) or 0 else 0
    motionBgsCommandSequence = math.max(motionBgsCommandSequence, previousNonce, statusNonce) + 1
    return motionBgsCommandSequence
end

function wallInOne.motionBgsInstalledPath(slug, quality)
    slug = tostring(slug or "")
    quality = tostring(quality or ""):lower()
    local recent = type(motionBgsStatus) == "table" and motionBgsStatus.last_download or nil
    if type(recent) == "table"
        and tostring(recent.slug or ""):lower() == slug:lower()
        and tostring(recent.quality or ""):lower() == quality
    then
        local recentPath = tostring(recent.path or "")
        local recentSidecar = tostring(recent.sidecar or "")
        if recentPath ~= ""
            and recentSidecar == recentPath .. ".motionbgs.json"
            and noctalia.fileExists(recentPath)
            and noctalia.fileExists(recentSidecar)
        then
            return recentPath
        end
    end
    for _, entry in ipairs(type(library.videos) == "table" and library.videos or {}) do
        if
            type(entry) == "table"
            and entry.managed == true
            and tostring(entry.provider or "") == "MotionBGS"
            and tostring(entry.provider_id or "") == slug
            and tostring(entry.quality or ""):lower() == quality
            and noctalia.fileExists(tostring(entry.path or ""))
        then
            return tostring(entry.path)
        end
    end
    return nil
end

function wallInOne.sendMotionBgsCommand(request, action)
    if not configValid or not runtimeValid then
        wallInOne.setActionError(noctalia.tr("errors.storage_disabled"), "storage")
        return false
    end
    if not wallInOne.settingBool("use_motionbgs", true)
        or (action ~= "probe" and providers.motionbgs.integration_available ~= true)
    then
        wallInOne.setActionError(noctalia.tr("errors.motionbgs_unavailable"), "motionbgs")
        return false
    end
    local command = {
        schema = 1,
        nonce = wallInOne.nextMotionBgsNonce(),
        action = tostring(action or ""),
    }
    if action == "search" then
        command.query = tostring(request.query or "")
        command.mode = tostring(request.mode or "search")
        command.genre = tostring(request.genre or "")
        command.quality = tostring(request.quality or "")
        command.page = tonumber(request.page) or 1
        command.limit = wallInOne.settingInt("motionbgs_result_limit", 48, 1, 48)
        command.force = request.force == true
    elseif action == "details" then
        command.slug = tostring(request.slug or "")
        command.force = request.force == true
    elseif action == "download" then
        command.slug = tostring(request.slug or "")
        command.quality = if tostring(request.quality or wallInOne.settingString("motionbgs_quality", "hd")) == "4k"
            then "4k"
            else "hd"
        if wallInOne.motionBgsInstalledPath(command.slug, command.quality) ~= nil then
            lastActionError = ""
            lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            wallInOne.publishStatus()
            return true
        end
        command.force = request.force == true
    elseif action ~= "clear" and action ~= "probe" then
        wallInOne.setActionError(noctalia.tr("errors.motionbgs_action"), "motionbgs")
        return false
    end
    noctalia.state.set(MOTIONBGS_COMMAND_KEY, command)
    lastActionError = ""
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    wallInOne.publishStatus()
    return true
end

function wallInOne.nextPalettesNonce()
    local previous = noctalia.state.get(PALETTES_COMMAND_KEY)
    local previousNonce = if type(previous) == "table" then tonumber(previous.nonce) or 0 else 0
    local statusNonce = if type(palettesStatus) == "table" then tonumber(palettesStatus.last_nonce) or 0 else 0
    palettesCommandSequence = math.max(palettesCommandSequence, previousNonce, statusNonce) + 1
    return palettesCommandSequence
end

function wallInOne.refreshPaletteInventory(force)
    noctalia.state.set(PALETTES_COMMAND_KEY, {
        schema = 1,
        nonce = wallInOne.nextPalettesNonce(),
        action = "refresh",
        force = force == true,
    })
    return true
end

function wallInOne.requestPalettePreview(request)
    local key = tostring(request.key or "")
    local path = tostring(request.path or "")
    local scheme = tostring(request.scheme or "")
    local pairingId = tostring(request.pairing_id or "")
    local pairing = type(config.pairings) == "table" and config.pairings[pairingId] or nil
    if type(pairing) == "table" then
        local still = type(pairing.still) == "table" and pairing.still or nil
        local media = type(pairing.media) == "table" and pairing.media or nil
        if path == "" and type(still) == "table" and still.mode == "selected" then
            path = tostring(still.path or "")
        elseif path == "" and type(still) == "table" and still.mode == "automatic" and type(media) == "table" then
            local dynamicId = if media.kind == "video" then "video:" .. tostring(media.source or "") else tostring(media.source or "")
            path = wallInOne.cachedPair(dynamicId) or ""
        end
        if scheme == "" and type(pairing.theme) == "table" and pairing.theme.source == "wallpaper" then
            scheme = tostring(pairing.theme.selection or "")
        end
    end
    if not wallInOne.validPersistedKey(key) or not VALID_COLOR_SCHEMES[scheme] then
        wallInOne.setActionError(noctalia.tr("errors.playlist_still_missing", { path = path }), "palette-preview")
        return false
    end
    -- Forward a bounded empty path when an automatic representative is not
    -- ready yet. The palette worker owns final source validation and publishes
    -- a keyed error, so the panel can correlate the rejection and retry after
    -- a capture or explicit refresh instead of latching an unanswered key.
    path = if wallInOne.validAbsolutePath(path) then path else ""
    noctalia.state.set(PALETTES_COMMAND_KEY, {
        schema = 1,
        nonce = wallInOne.nextPalettesNonce(),
        action = "preview",
        key = key,
        path = path,
        scheme = scheme,
    })
    return true
end

function wallInOne.queuePairingPreview(request)
    local key = tostring(request.key or "")
    local kind = tostring(request.media_kind or "")
    local source = tostring(request.media_source or "")
    local scheme = tostring(request.scheme or "")
    local captureOnly = request.capture_only == true
    local sourceValid = if kind == "video"
        then wallInOne.validAbsolutePath(source)
        elseif kind == "workshop" then wallInOne.validWorkshopId(source)
        else false
    if
        not wallInOne.validPersistedKey(key)
        or not sourceValid
        or (not captureOnly and not VALID_COLOR_SCHEMES[scheme])
    then
        wallInOne.setActionError(noctalia.tr("errors.playlist_entry"), "pairing-preview")
        return false
    end
    -- The editor is latest-intent UI. Coalescing here keeps rapid A -> B
    -- navigation from starting work in this strict state-watch callback.
    pairingPreviewPending = {
        key = key,
        media_kind = kind,
        media_source = source,
        scheme = scheme,
        capture_only = captureOnly,
        output = tostring(request.output or ""),
    }
    return true
end

function wallInOne.startPendingPairingPreview()
    local request = pairingPreviewPending
    pairingPreviewPending = nil
    if type(request) ~= "table" then
        return false
    end
    local kind = tostring(request.media_kind or "")
    local source = tostring(request.media_source or "")
    local dynamicId = if kind == "video" then "video:" .. source else source
    local cachedPath = wallInOne.cachedPair(dynamicId)
    if cachedPath ~= nil then
        if request.capture_only ~= true then
            wallInOne.requestPalettePreview({
                key = request.key,
                path = cachedPath,
                scheme = request.scheme,
            })
        end
        return true
    end

    local output = wallInOne.targetOutput(request.output)
    if
        output == nil
        or not wallInOne.settingBool("auto_capture", true)
        or wallInOne.captureDirectory() == ""
    then
        if request.capture_only ~= true then
            wallInOne.requestPalettePreview({ key = request.key, path = "", scheme = request.scheme })
        end
        return true
    end

    local function completed(ok, path, _errorMessage)
        if request.capture_only ~= true then
            wallInOne.requestPalettePreview({
                key = request.key,
                path = if ok == true then tostring(path or "") else "",
                scheme = request.scheme,
            })
        end
    end
    local options = {
        output = output,
        pair = false,
        notify = false,
        managed_auto = true,
        cache_pair = true,
        capture_key = "pairing-preview",
        on_complete = completed,
    }
    if kind == "video" then
        options.source = source
        wallInOne.captureVideoPath(options)
    else
        options.id = source
        wallInOne.captureWorkshopFallback(options)
    end
    return true
end

function wallInOne.nextWallhavenNonce()
    local previous = noctalia.state.get(WALLHAVEN_COMMAND_KEY)
    local previousNonce = if type(previous) == "table" then tonumber(previous.nonce) or 0 else 0
    local statusNonce = if type(wallhavenStatus) == "table" then tonumber(wallhavenStatus.last_nonce) or 0 else 0
    wallhavenCommandSequence = math.max(wallhavenCommandSequence, previousNonce, statusNonce) + 1
    return wallhavenCommandSequence
end

function wallInOne.currentWallhavenItem(id)
    id = tostring(id or "")
    local selected = type(wallhavenResults.selected) == "table" and wallhavenResults.selected or nil
    if type(selected) == "table" and tostring(selected.id or "") == id then
        return selected
    end
    for _, item in ipairs(type(wallhavenResults.items) == "table" and wallhavenResults.items or {}) do
        if type(item) == "table" and tostring(item.id or "") == id then
            return item
        end
    end
    return nil
end

function wallInOne.wallhavenInstalledPath(id)
    id = tostring(id or ""):lower()
    for _, entry in ipairs(type(library.stills) == "table" and library.stills or {}) do
        if
            type(entry) == "table"
            and entry.managed == true
            and tostring(entry.provider or "") == "Wallhaven"
            and tostring(entry.provider_id or ""):lower() == id
            and noctalia.fileExists(tostring(entry.path or ""))
        then
            return tostring(entry.path)
        end
    end
    return nil
end

function wallInOne.sendWallhavenCommand(request, action)
    if not wallInOne.settingBool("use_wallhaven", true) or wallhavenStatus.available ~= true then
        wallInOne.setActionError(noctalia.tr("errors.wallhaven_unavailable"), "wallhaven")
        return false
    end
    local nonce = wallInOne.nextWallhavenNonce()
    local command = {
        schema = 1,
        nonce = nonce,
        action = action,
    }
    if action == "search" then
        command.filters = {
            query = tostring(request.query or ""),
            categories = tostring(request.categories or "111"),
            purity = tostring(request.purity or "100"),
            sorting = tostring(request.sorting or "date_added"),
            order = tostring(request.order or "desc"),
            atleast = tostring(request.atleast or ""),
            resolutions = tostring(request.resolutions or ""),
            ratios = tostring(request.ratios or ""),
            colors = tostring(request.colors or ""),
            top_range = tostring(request.top_range or "1M"),
            seed = tostring(request.seed or ""),
            page = tonumber(request.page) or 1,
        }
    elseif action == "detail" then
        command.id = tostring(request.id or "")
    elseif action == "download" then
        local item = wallInOne.currentWallhavenItem(request.id)
        if type(item) ~= "table" then
            wallInOne.setActionError(noctalia.tr("errors.wallhaven_result"), "wallhaven")
            return false
        end
        if wallInOne.wallhavenInstalledPath(item.id) ~= nil then
            lastActionError = ""
            lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
            wallInOne.publishStatus()
            return true
        end
        local imageRoot = wallInOne.captureDirectory()
        if not wallInOne.existingDirectory(imageRoot) then
            wallInOne.setActionError(noctalia.tr("errors.capture_directory"), "wallhaven")
            return false
        end
        local directory = wallInOne.wallhavenManagedDirectory()
        local ready, directoryError = wallInOne.ensureManagedDirectory(directory, "wallhaven")
        if ready ~= true then
            wallInOne.setActionError(tostring(directoryError or noctalia.tr("errors.managed_directory")), "wallhaven")
            return false
        end
        local extension = tostring(item.extension or ""):lower()
        if extension ~= "jpg" and extension ~= "png" then
            wallInOne.setActionError(noctalia.tr("errors.wallhaven_result"), "wallhaven")
            return false
        end
        local target = directory .. "/wallhaven-" .. tostring(item.id or "") .. "." .. extension
        command.id = tostring(item.id or "")
        command.url = tostring(item.path or item.short_url or "")
        command.target_path = target
        command.staging_path = target .. ".wallhaven-" .. tostring(nonce) .. ".stage"
    elseif action ~= "clear" then
        wallInOne.setActionError(noctalia.tr("errors.wallhaven_action"), "wallhaven")
        return false
    end
    noctalia.state.set(WALLHAVEN_COMMAND_KEY, command)
    lastActionError = ""
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    wallInOne.publishStatus()
    return true
end

function wallInOne.actionPanelTarget(action)
    return OPEN_TARGETS[action]
end

function wallInOne.dispatchAction(request, action)
    -- The explicit site link is the scraper's disaster-recovery path and is
    -- independent of plugin storage or bundled-service health.
    if action == "motionbgs_open" or action == "wallhaven_site" then
        local available, unavailableReason = wallInOne.actionAvailability(action, request.output)
        if available then
            if action == "wallhaven_site" then
                wallInOne.openWallhavenSite()
            else
                wallInOne.openMotionBgs()
            end
        else
            wallInOne.setActionError(unavailableReason, if action == "wallhaven_site" then "wallhaven-site" else "motionbgs")
        end
        return
    end
    if not configValid or not runtimeValid then
        wallInOne.notifyBounded("storage", noctalia.tr("errors.storage_disabled"))
        return
    end
    if not VALID_ACTIONS[action] then
        wallInOne.notifyBounded("unknown", noctalia.tr("availability.unknown"))
        return
    end
    local available, unavailableReason = wallInOne.actionAvailability(action, request.output)
    if not available then
        local message = noctalia.tr("errors.action_unavailable", { action = action, reason = unavailableReason })
        wallInOne.setActionError(message, action)
        return
    end
    if action == "no_action" then
        return
    elseif action == "steam_launch" or action == "steam_workshop" then
        wallInOne.openSteamTarget(action)
        return
    elseif action == "playback_stop_all" or wallInOne.ownedRendererActions[action] ~= nil then
        wallInOne.runOwnedRendererControl(request, action)
        return
    elseif NATIVE_SWITCH_VERBS[action] ~= nil then
        wallInOne.runNativeSwitch(request, action)
        return
    elseif action == "capture_backing" then
        wallInOne.captureCurrentBacking(request.output, true, true)
        return
    elseif action == "capture_current" then
        wallInOne.captureCurrent(request.output, true, false, true)
        return
    elseif action == "capture_pair" then
        wallInOne.captureCurrent(request.output, true, true, true)
        return
    elseif action == "video_capture" then
        wallInOne.captureConfiguredVideo(request.output, true, false, true)
        return
    elseif action == "video_capture_pair" then
        wallInOne.captureConfiguredVideo(request.output, true, true, true)
        return
    elseif action == "video_apply_pair" then
        wallInOne.applyManualEntry(request.output, { kind = "video", source = wallInOne.configuredVideoSource() }, true)
        return
    elseif action == "workshop_apply_pair" then
        wallInOne.applyManualEntry(request.output, { kind = "workshop", source = wallInOne.configuredWorkshopId() }, true)
        return
    elseif action == "cycle_add_static" then
        wallInOne.addCurrentStaticToPlaylist(request.output, nil)
        return
    elseif action == "cycle_add_video" then
        local source = wallInOne.configuredVideoSource()
        wallInOne.addPlaylistEntry(request.output, nil, {
            kind = "video",
            source = source,
            label = source:match("([^/]+)$") or source,
            added_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        })
        return
    elseif action == "cycle_add_workshop" then
        local id = wallInOne.configuredWorkshopId()
        wallInOne.addPlaylistEntry(request.output, nil, {
            kind = "workshop",
            source = id,
            label = "Workshop " .. id,
            added_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
        })
        return
    elseif action == "cycle_remove_last" then
        local playlist, playlistId = wallInOne.playlistForOutput(request.output, nil)
        local lastEntry = type(playlist) == "table" and playlist.entries[#playlist.entries] or nil
        if playlistId ~= nil and type(lastEntry) == "table" then
            wallInOne.removePlaylistEntry(playlistId, lastEntry.id)
        end
        return
    elseif action == "cycle_clear" then
        local _playlist, playlistId = wallInOne.playlistForOutput(request.output, nil)
        if playlistId ~= nil then
            wallInOne.clearPlaylist(playlistId)
        end
        return
    elseif action == "cycle_start" then
        wallInOne.setPlaylistRunState(request.output, nil, "start", true)
        return
    elseif action == "cycle_stop" then
        wallInOne.setPlaylistRunState(request.output, nil, "stop", true)
        return
    elseif action == "cycle_pause" then
        wallInOne.setPlaylistRunState(request.output, nil, "pause", true)
        return
    elseif action == "cycle_resume" then
        wallInOne.setPlaylistRunState(request.output, nil, "resume", true)
        return
    elseif action == "cycle_next" or action == "cycle_previous" or action == "cycle_random" then
        local direction = action:gsub("^cycle_", "")
        wallInOne.advancePlaylist(request.output, nil, direction, { notify = true })
        return
    elseif action == "manual_pair" then
        wallInOne.pairConfiguredStill(request.output, true)
        return
    end

    lastActionError = ""
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    wallInOne.publishStatus()
    if tostring(request.producer or "") == "ipc" then
        local target = wallInOne.actionPanelTarget(action)
        if type(target) == "string" and target ~= "" then
            noctalia.togglePanel(target)
        end
    end
end

function wallInOne.setMapping(button, action)
    if not configValid or not runtimeValid then
        wallInOne.notifyBounded("storage", noctalia.tr("errors.storage_disabled"))
        return
    end
    if button ~= "left" and button ~= "middle" and button ~= "right" then
        return
    end
    if not VALID_GESTURE_ACTIONS[action] then
        wallInOne.notifyBounded("unknown", noctalia.tr("availability.unknown"))
        return
    end
    local nextConfig = wallInOne.editableConfig()
    if nextConfig == nil then
        wallInOne.setActionError(noctalia.tr("errors.config_playlists"), "set-mapping")
        return
    end
    nextConfig.gestures[button] = action
    wallInOne.saveConfig(nextConfig, "set-mapping")
end

function wallInOne.handleCommand(request)
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
        wallInOne.setActionError(noctalia.tr("errors.storage_disabled"), "storage")
        return
    end
    if kind == "gesture" then
        local gestures = type(config.gestures) == "table" and config.gestures or {}
        wallInOne.dispatchAction(request, tostring(gestures[tostring(request.button or "")] or ""))
    elseif kind == "action" then
        wallInOne.dispatchAction(request, tostring(request.action or ""))
    elseif kind == "set_mapping" then
        wallInOne.setMapping(tostring(request.button or ""), tostring(request.action or ""))
    elseif kind == "playlist_create" then
        wallInOne.createPlaylist(request.name, request.output, false)
    elseif kind == "playlist_rename" then
        wallInOne.renamePlaylist(request.playlist_id, request.name)
    elseif kind == "playlist_duplicate" then
        wallInOne.duplicatePlaylist(request.playlist_id, request.name, request.output)
    elseif kind == "playlist_delete" then
        wallInOne.deletePlaylist(request.playlist_id)
    elseif kind == "playlist_assign" then
        wallInOne.setOutputFallback(request.output, request.playlist_id)
    elseif kind == "playlist_options" then
        wallInOne.setPlaylistOptions(request.playlist_id, request.interval_seconds, request.order)
    elseif kind == "output_options" then
        wallInOne.setOutputPlaylistOptions(
            request.output,
            request.interval_seconds,
            request.order,
            request.inherit == true
        )
    elseif kind == "output_engines" then
        local engines = request.engines
        if type(engines) ~= "table" then
            engines = {
                layer = request.layer,
                video = request.video,
                workshop = request.workshop,
            }
        end
        wallInOne.saveOutputEngines(request.output, engines)
    elseif kind == "pairing_save" then
        wallInOne.savePairing(request.pairing)
    elseif kind == "pairing_reset" then
        wallInOne.resetPairing(request.pairing)
    elseif kind == "pairing_prepare_still" then
        wallInOne.queuePairingPreview(request)
    elseif kind == "playlist_add_pairing" then
        wallInOne.addPairingToPlaylist(
            request.output,
            request.playlist_id,
            request.pairing_id,
            request.before_id
        )
    elseif kind == "playlist_add_entry" then
        wallInOne.addPlaylistEntry(request.output, request.playlist_id, request.entry, request.before_id)
    elseif kind == "playlist_save_entry" then
        wallInOne.savePlaylistEntry(request.playlist_id, request.entry)
    elseif kind == "playlist_remove_entry" then
        wallInOne.removePlaylistEntry(request.playlist_id, request.entry_id)
    elseif kind == "playlist_move_entry" then
        wallInOne.movePlaylistEntry(request.playlist_id, request.entry_id, request.direction)
    elseif kind == "playlist_place_entry" then
        wallInOne.placePlaylistEntry(
            request.playlist_id,
            request.entry_id,
            request.anchor_id,
            request.placement
        )
    elseif kind == "playlist_apply_entry" then
        wallInOne.applyPlaylistEntryById(request.output, request.playlist_id, request.entry_id)
    elseif kind == "playlist_action" then
        local action = tostring(request.action or "")
        if action == "next" or action == "previous" or action == "random" then
            wallInOne.advancePlaylist(request.output, request.playlist_id, action, { notify = true })
        else
            wallInOne.setPlaylistRunState(request.output, request.playlist_id, action, request.manual_pin ~= false)
        end
    elseif kind == "schedule_save" then
        wallInOne.upsertSchedule(request.output, request.schedule, request.before_id)
    elseif kind == "schedule_delete" then
        wallInOne.deleteSchedule(request.output, request.schedule_id)
    elseif kind == "schedule_place" then
        wallInOne.placeSchedule(
            request.output,
            request.schedule_id,
            request.anchor_id,
            request.placement
        )
    elseif kind == "schedule_resume" then
        wallInOne.resumeOutputSchedule(request.output)
    elseif kind == "cycle_add_entry" then
        wallInOne.addPlaylistEntry(request.output, nil, request.entry)
    elseif kind == "cycle_remove_entry" then
        local playlist, playlistId = wallInOne.playlistForOutput(request.output, nil)
        local index = math.floor(tonumber(request.index) or (type(playlist) == "table" and #playlist.entries or 0))
        local entry = type(playlist) == "table" and playlist.entries[index] or nil
        if playlistId ~= nil and type(entry) == "table" then
            wallInOne.removePlaylistEntry(playlistId, entry.id)
        end
    elseif kind == "cycle_options" then
        local _playlist, playlistId = wallInOne.playlistForOutput(request.output, nil)
        if playlistId ~= nil then
            local order = if tostring(request.order or "") == "sequential" then "rotate" else request.order
            wallInOne.setPlaylistOptions(playlistId, request.interval_seconds, order)
        end
    elseif kind == "apply_entry" then
        wallInOne.applyManualEntry(request.output, request.entry, true)
    elseif kind == "palettes_refresh" then
        wallInOne.refreshPaletteInventory(request.force == true)
    elseif kind == "palette_preview" then
        wallInOne.requestPalettePreview(request)
    elseif kind == "wallhaven_search" then
        wallInOne.sendWallhavenCommand(request, "search")
    elseif kind == "wallhaven_detail" then
        wallInOne.sendWallhavenCommand(request, "detail")
    elseif kind == "wallhaven_download" then
        wallInOne.sendWallhavenCommand(request, "download")
    elseif kind == "wallhaven_clear" then
        wallInOne.sendWallhavenCommand(request, "clear")
    elseif kind == "motionbgs_search" then
        wallInOne.sendMotionBgsCommand(request, "search")
    elseif kind == "motionbgs_details" then
        wallInOne.sendMotionBgsCommand(request, "details")
    elseif kind == "motionbgs_download" then
        wallInOne.sendMotionBgsCommand(request, "download")
    elseif kind == "motionbgs_clear" then
        wallInOne.sendMotionBgsCommand(request, "clear")
    elseif kind == "motionbgs_probe" then
        wallInOne.sendMotionBgsCommand(request, "probe")
    elseif kind == "motionbgs_helper_open" then
        wallInOne.openMotionBgsHelper()
    elseif kind == "library_refresh" then
        libraryRefreshPending = true
        wallInOne.publishStatus()
    elseif kind == "library_delete" then
        wallInOne.deleteManagedLibraryItem(request.item_id)
    elseif kind == "probe" then
        wallInOne.refreshAvailability()
        wallInOne.probeColorScheme()
        if wallInOne.settingBool("use_motionbgs", true) then
            wallInOne.sendMotionBgsCommand(request, "probe")
        end
    end
end

-- Noctalia lifecycle --------------------------------------------------------

function update()
    noctalia.setUpdateInterval(UPDATE_INTERVAL_MS)
    wallInOne.drainPostApplyQueue()
    if pairingPreviewPending ~= nil then
        wallInOne.startPendingPairingPreview()
        wallInOne.publishStatus()
        return
    end
    if libraryRefreshPending then
        -- Directory enumeration is deliberately isolated from
        -- onConfigChanged(), whose VM has a strict callback CPU budget.
        libraryRefreshPending = false
        local managedReady, managedError = wallInOne.ensureImageManagedDirectories()
        managedDirectoryError = if managedReady then "" else tostring(managedError or "")
        wallInOne.refreshLibrary()
        settingsStatusPublishPending = false
        wallInOne.publishStatus()
        return
    end
    if settingsStatusPublishPending then
        -- A settings callback already performs provider-policy reconciliation.
        -- Publish its settings snapshot on a clean tick so the accumulated
        -- callback work cannot exhaust Noctalia's per-callback CPU budget.
        settingsStatusPublishPending = false
        wallInOne.publishStatus()
        return
    end
    -- Renderer commands are never retried. A modest read-only reconciliation
    -- against the versioned snapshot keeps lifecycle ordering convergent
    -- without adding state-bus writes or regressing to an older revision.
    wallInOne.adoptRendererStatus(noctalia.state.get(RENDERER_STATUS_KEY))
    local now = wallInOne.nowSeconds()
    if wallInOne.stepLibraryScan() then
        wallInOne.publishStatus()
    end
    if lastAvailabilityRefreshAt == 0 or now == 0 or now - lastAvailabilityRefreshAt >= AVAILABILITY_REFRESH_SECONDS then
        wallInOne.refreshAvailability()
    end
    local timedOutRendererCommands = {}
    for nonce, pending in pairs(rendererPending) do
        if (tonumber(pending.deadline) or 0) > 0 and now > tonumber(pending.deadline) then
            table.insert(timedOutRendererCommands, nonce)
        end
    end
    for _, nonce in ipairs(timedOutRendererCommands) do
        local timeoutError = noctalia.tr("errors.renderer_ack_timeout")
        wallInOne.setActionError(timeoutError, "renderer")
        wallInOne.finishRendererPending(nonce, false, timeoutError)
    end
    local clockSignature = noctalia.formatTime("%Y-%m-%d %H:%M")
    local minuteChanged = clockSignature ~= scheduleClockSignature
    local scheduledStarts = {}
    if (minuteChanged or next(scheduleReevaluationPending) ~= nil) and not scheduledBatchActive then
        scheduleClockSignature = clockSignature
        local scheduledOutputs = {}
        for output in pairs(config.outputs) do
            if minuteChanged or scheduleReevaluationPending[output] == true then
                table.insert(scheduledOutputs, output)
            end
        end
        -- A minute transition reevaluates every output; a configuration
        -- mutation reevaluates only its output on the next coordinator tick.
        table.sort(scheduledOutputs)
        for _, output in ipairs(scheduledOutputs) do
            scheduleReevaluationPending[output] = nil
            local _changed, playlistId = wallInOne.reevaluateOutputSchedule(output, false, true)
            if playlistId ~= nil then
                table.insert(scheduledStarts, { output = output, playlist_id = playlistId })
            end
        end
    end
    local dueOutputs = {}
    local dueByOutput = {}
    for _, due in ipairs(scheduledStarts) do
        table.insert(dueOutputs, due)
        dueByOutput[due.output] = true
    end
    for _, restore in ipairs(startupRestoreQueue) do
        if dueByOutput[restore.output] ~= true then
            table.insert(dueOutputs, restore)
            dueByOutput[restore.output] = true
        end
    end
    startupRestoreQueue = {}
    for output, state in pairs(runtime.output_states) do
        local playlistId = type(state) == "table" and tostring(state.active_playlist or "") or ""
        local outputRuns = runtime.runs[output]
        local run = type(outputRuns) == "table" and outputRuns[playlistId] or nil
        if
            playlistId ~= ""
            and config.playlists[playlistId] ~= nil
            and type(run) == "table"
            and run.running == true
            and run.paused ~= true
            and wallInOne.knownOutputName(output) ~= nil
            and not cycleApplying[output]
            and dueByOutput[output] ~= true
            and (tonumber(run.next_due) or 0) <= now
        then
            table.insert(dueOutputs, { output = output, playlist_id = playlistId })
            dueByOutput[output] = true
        end
    end
    if #dueOutputs > 0 and not scheduledBatchActive then
        local authority = wallInOne.resolvedPaletteAuthority(nil)
        local configuredAuthority = wallInOne.settingString("palette_output", "")
        local paletteWinner = nil
        for _, due in ipairs(dueOutputs) do
            if due.output == authority then
                paletteWinner = authority
                break
            end
        end
        if configuredAuthority == "" and paletteWinner == nil then
            table.sort(dueOutputs, function(left, right)
                return left.output < right.output
            end)
            paletteWinner = dueOutputs[#dueOutputs].output
        end
        table.sort(dueOutputs, function(left, right)
            if left.output == paletteWinner then
                return false
            elseif right.output == paletteWinner then
                return true
            end
            return left.output < right.output
        end)

        scheduledBatchActive = true
        local index = 0
        local function finishBatch()
            if paletteWinner == nil and configuredAuthority ~= "" then
                wallInOne.reassertPaletteAuthority(function(ok, errorMessage)
                    if ok ~= true then
                        wallInOne.setActionError(errorMessage, "palette-authority")
                    end
                    scheduledBatchActive = false
                end)
            else
                scheduledBatchActive = false
            end
        end
        local function applyNext()
            index += 1
            local due = dueOutputs[index]
            if due == nil then
                finishBatch()
                return
            end
            local started = wallInOne.advancePlaylist(due.output, due.playlist_id, "next", {
                palette_allowed = due.output == paletteWinner,
                restore_current = due.restore_current == true,
                on_complete = applyNext,
            })
            if not started then
                applyNext()
            end
        end
        applyNext()
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
        wallInOne.invalidateCycleIntent(output, false)
    end
    wallInOne.applyIntegrationPolicy()
    local nextLibraryRootsSignature = wallInOne.currentLibraryRootsSignature()
    if nextLibraryRootsSignature ~= libraryRootsSignature then
        libraryRootsSignature = nextLibraryRootsSignature
        libraryRefreshPending = true
    end
    wallInOne.refreshAvailability()
    wallInOne.reconcilePaletteAuthority(true)
    -- Plugin settings live on the bounded lifecycle snapshot. The persisted
    -- config domain is dirtied only by saveConfig(), when its document changes.
    -- Defer the snapshot build because this callback has already reconciled
    -- provider policy and carries a strict Noctalia CPU budget.
    settingsSnapshotCache = nil
    settingsStatusPublishPending = true
end

function onOutputsChanged()
    local owned = type(rendererStatus) == "table" and type(rendererStatus.outputs) == "table" and rendererStatus.outputs
        or {}
    for output in pairs(owned) do
        if wallInOne.knownOutputName(output) == nil then
            wallInOne.invalidateCycleIntent(output, true)
        end
    end
    local candidates = {}
    for output in pairs(cycleApplying) do
        candidates[output] = true
    end
    for output in pairs(captureInFlight) do
        candidates[output] = true
    end
    for output in pairs(runtime.runs) do
        candidates[output] = true
    end
    for output in pairs(applyGeneration) do
        candidates[output] = true
    end
    for output in pairs(candidates) do
        if output ~= "all" and wallInOne.knownOutputName(output) == nil then
            wallInOne.invalidateCycleIntent(output, false)
        end
    end
    wallInOne.reconcilePaletteAuthority(true)
    wallInOne.publishStatus()
end

function onIpc(event, payload)
    local output = wallInOne.targetOutput(nil)
    if event == "status" or event == "probe" then
        wallInOne.refreshAvailability()
        wallInOne.probeColorScheme()
    elseif event == "gesture" then
        local gestures = type(config.gestures) == "table" and config.gestures or {}
        wallInOne.dispatchAction(
            { sequence = wallInOne.nowSeconds(), producer = "ipc", output = output },
            tostring(gestures[tostring(payload or "")] or "")
        )
    elseif event == "next" or event == "previous" or event == "random" then
        wallInOne.dispatchAction({ producer = "ipc", output = output }, "native_" .. event)
    elseif event == "capture" then
        wallInOne.captureCurrent(output, true, false, true)
    elseif event == "capture-backing" then
        wallInOne.captureCurrentBacking(output, true, true)
    elseif event == "capture-pair" then
        wallInOne.captureCurrent(output, true, true, true)
    elseif event == "capture-video" then
        wallInOne.captureConfiguredVideo(output, true, false, true)
    elseif event == "capture-video-pair" then
        wallInOne.captureConfiguredVideo(output, true, true, true)
    elseif event == "apply-video-pair" then
        wallInOne.applyManualEntry(output, { kind = "video", source = wallInOne.configuredVideoSource() }, true)
    elseif event == "apply-workshop-pair" then
        wallInOne.applyManualEntry(output, { kind = "workshop", source = wallInOne.configuredWorkshopId() }, true)
    elseif event == "pair-manual" then
        wallInOne.pairConfiguredStill(output, true)
    elseif event == "capture-id" or event == "capture-id-pair" then
        local id, requestedOutput = tostring(payload or ""):match("^%s*(%d+)%s*(%S*)%s*$")
        local selectedOutput = if requestedOutput ~= nil and requestedOutput ~= "" then requestedOutput else output
        selectedOutput = wallInOne.targetOutput(selectedOutput)
        if selectedOutput ~= nil and wallInOne.internalBackendReady("w_engine", selectedOutput) == true then
            local owned = selectedOutput ~= nil
                    and type(rendererStatus.outputs) == "table"
                    and rendererStatus.outputs[selectedOutput]
                or nil
            local sameActive = type(owned) == "table"
                and owned.backend == "w-engine"
                and (owned.state == "running" or owned.state == "paused")
                and tostring(owned.workshop_id or "") == tostring(id or "")
            local sameCapturing = type(owned) == "table"
                and owned.backend == "w-engine"
                and owned.state == "capturing"
                and tostring(owned.workshop_id or "") == tostring(id or "")
            if sameCapturing then
                return
            else
                local backendToken = backendGeneration.w_engine
                local applyToken = selectedOutput ~= nil and (tonumber(applyGeneration[selectedOutput]) or 0) or 0
                if selectedOutput ~= nil then
                    applyGeneration[selectedOutput] = applyToken
                end
                local function captureStillCurrent()
                    return selectedOutput ~= nil
                        and backendGeneration.w_engine == backendToken
                        and tonumber(applyGeneration[selectedOutput]) == applyToken
                        and wallInOne.internalBackendReady("w_engine", selectedOutput) == true
                        and wallInOne.knownOutputName(selectedOutput) ~= nil
                end
                if type(owned) == "table" and not sameActive then
                    wallInOne.captureWorkshopFallback({
                        output = selectedOutput,
                        id = id,
                        force = true,
                        pair = event == "capture-id-pair",
                        notify = true,
                        should_apply = captureStillCurrent,
                    })
                    return
                end
                wallInOne.requestInternalCapture({
                    output = selectedOutput,
                    id = id,
                    pair = event == "capture-id-pair",
                    notify = true,
                    should_apply = captureStillCurrent,
                    start_after = sameActive,
                    restore_on_failure = sameActive,
                    restore_paused = sameActive and owned.state == "paused",
                    managed_auto = false,
                })
            end
        else
            wallInOne.captureWorkshopFallback({
                output = selectedOutput,
                id = id,
                force = true,
                pair = event == "capture-id-pair",
                notify = true,
            })
        end
    elseif
        event == "playback-pause"
        or event == "playback-resume"
        or event == "playback-toggle"
        or event == "playback-stop"
        or event == "playback-stop-all"
        or event == "audio-mute"
        or event == "audio-unmute"
        or event == "audio-toggle"
        or event == "audio-volume-up"
        or event == "audio-volume-down"
    then
        local selectedOutput = wallInOne.knownOutputName(noctalia.string.trim(tostring(payload or ""))) or output
        wallInOne.dispatchAction({ producer = "ipc", output = selectedOutput }, event:gsub("%-", "_"))
    elseif event == "audio-volume" then
        local volume, requestedOutput = tostring(payload or ""):match("^%s*(%d+)%s*(%S*)%s*$")
        local numericVolume = tonumber(volume)
        if numericVolume == nil or numericVolume < 0 or numericVolume > 100 then
            wallInOne.setActionError(noctalia.tr("errors.audio_volume"), "renderer-control")
        else
            local selectedOutput = wallInOne.knownOutputName(requestedOutput) or output
            wallInOne.dispatchAction(
                { producer = "ipc", output = selectedOutput, volume = numericVolume },
                "audio_set_volume"
            )
        end
    elseif event == "motionbgs-open" then
        wallInOne.dispatchAction({ producer = "ipc", output = output }, "motionbgs_open")
    elseif event == "cycle-start" or event == "cycle-stop" or event == "cycle-pause" or event == "cycle-resume" then
        local action = event:gsub("%-", "_")
        wallInOne.dispatchAction({ producer = "ipc", output = output }, action)
    elseif event == "cycle-next" or event == "cycle-previous" or event == "cycle-random" then
        local action = event:gsub("%-", "_")
        wallInOne.dispatchAction({ producer = "ipc", output = output }, action)
    elseif event == "open-provider" then
        local aliases = {
            native = "native_open",
            motionbgs = "motionbgs_open",
            hub = "hub_open",
        }
        wallInOne.dispatchAction({ producer = "ipc", output = output }, aliases[tostring(payload or "")] or "")
    else
        noctalia.log("wall-in-one: unknown IPC event '" .. tostring(event) .. "'")
    end
end

function wallInOne.rendererSnapshotSignature(candidate)
    local outputTokens = {}
    local outputs = type(candidate.outputs) == "table" and candidate.outputs or {}
    for output, owned in pairs(outputs) do
        if type(owned) == "table" then
            table.insert(
                outputTokens,
                table.concat({
                    tostring(output),
                    tostring(owned.backend or ""),
                    tostring(owned.state or ""),
                    tostring(owned.nonce or ""),
                    tostring(owned.workshop_id or ""),
                    tostring(owned.layer or ""),
                }, ":")
            )
        end
    end
    table.sort(outputTokens)
    return table.concat({
        tostring(candidate.ready == true),
        tostring(candidate.last_nonce or ""),
        tostring(candidate.last_event_nonce or ""),
        tostring(candidate.last_event or ""),
        tostring(candidate.last_error or ""),
        table.concat(outputTokens, ","),
    }, "|")
end

function wallInOne.activePlaylistRunAndEntry(output)
    local outputRuntime = runtime.output_states[output]
    local playlistId = type(outputRuntime) == "table" and tostring(outputRuntime.active_playlist or "") or ""
    local playlist = config.playlists[playlistId]
    local outputRuns = runtime.runs[output]
    local run = type(outputRuns) == "table" and outputRuns[playlistId] or nil
    local entryIndex = type(run) == "table" and type(playlist) == "table"
            and wallInOne.entryIndexById(playlist, tostring(run.current_entry or ""))
        or nil
    local entry = entryIndex ~= nil
            and wallInOne.materializedPlaylistEntry(playlist.entries[entryIndex], config.pairings)
        or nil
    return run, entry
end

wallInOne.adoptRendererStatus = function(nextStatus, initializing)
    -- Always prefer the persistent bus value. A queued watch callback can be
    -- older than a snapshot already observed by update().
    local sharedStatus = noctalia.state.get(RENDERER_STATUS_KEY)
    if type(sharedStatus) == "table" then
        nextStatus = sharedStatus
    end
    local candidate = if type(nextStatus) == "table"
        then nextStatus
        else { ready = false, outputs = {}, last_error = noctalia.tr("errors.renderer_unavailable") }

    local instance = tostring(candidate.instance_id or "")
    local revision = tonumber(candidate.status_revision)
    local versioned = instance ~= "" and revision ~= nil and revision >= 0 and revision == math.floor(revision)
    local instanceChanged = false

    if versioned then
        if instance == rendererStatusInstance and revision <= rendererStatusRevision then
            return false
        end
        instanceChanged = rendererStatusInstance ~= "" and instance ~= rendererStatusInstance
        rendererStatusInstance = instance
        rendererStatusRevision = revision
        rendererLegacySignature = ""
    else
        local signature = wallInOne.rendererSnapshotSignature(candidate)
        if rendererStatusInstance == "" and signature == rendererLegacySignature then
            return false
        end
        instanceChanged = rendererStatusInstance ~= ""
        rendererStatusInstance = ""
        rendererStatusRevision = -1
        rendererLegacySignature = signature
    end

    local wasReady = type(rendererStatus) == "table" and rendererStatus.ready == true
    local previousOutputs = type(rendererStatus) == "table"
            and type(rendererStatus.outputs) == "table"
            and rendererStatus.outputs
        or {}
    rendererStatus = candidate
    if initializing == true then
        return true
    end

    if instanceChanged then
        wallInOne.failAllRendererPending(noctalia.tr("errors.renderer_unavailable"))
        wasReady = false
        previousOutputs = {}
    end
    local nextOutputs = type(rendererStatus.outputs) == "table" and rendererStatus.outputs or {}
    if tostring(rendererStatus.last_event or "") == "started" then
        local eventNonce = tostring(rendererStatus.last_event_nonce or "")
        for output, owned in pairs(nextOutputs) do
            if
                type(owned) == "table"
                and tostring(owned.state or "") ~= "capturing"
                and tostring(owned.nonce or "") == eventNonce
            then
                wallInOne.noteRendererStarted(output, eventNonce)
            end
        end
    end
    wallInOne.synchronizeInternalWorkshops(rendererStatus)
    wallInOne.resolveRendererAcknowledgements(rendererStatus)
    wallInOne.refreshBackendPolicy()
    wallInOne.reconcileRendererOwnership()
    local runtimeChanged = false
    for output in pairs(rendererStopping) do
        if type(nextOutputs[output]) ~= "table" then
            rendererStopping[output] = nil
        end
    end
    if not wasReady and rendererStatus.ready == true then
        local now = wallInOne.nowSeconds()
        for output in pairs(runtime.output_states) do
            local state, entry = wallInOne.activePlaylistRunAndEntry(output)
            local media = type(entry) == "table" and type(entry.media) == "table" and entry.media or nil
            if
                type(state) == "table"
                and state.running == true
                and state.paused ~= true
                and type(media) == "table"
                and (media.kind == "video" or media.kind == "workshop")
                and type(nextOutputs[output]) ~= "table"
            then
                state.next_due = math.max(now, wallInOne.rendererRetryFloor(output))
                runtimeChanged = true
            end
        end
    elseif tostring(rendererStatus.last_event or "") == "exited" then
        local now = wallInOne.nowSeconds()
        local eventNonce = tostring(rendererStatus.last_event_nonce or "")
        for output in pairs(previousOutputs) do
            local state, entry = wallInOne.activePlaylistRunAndEntry(output)
            local media = type(entry) == "table" and type(entry.media) == "table" and entry.media or nil
            if
                type(nextOutputs[output]) ~= "table"
                and rendererStopping[output] ~= true
                and type(state) == "table"
                and state.running == true
                and state.paused ~= true
                and type(media) == "table"
                and (media.kind == "video" or media.kind == "workshop")
            then
                state.next_due = wallInOne.noteUnexpectedRendererExit(output, eventNonce, now)
                local rendererError = wallInOne.boundedDetail(rendererStatus.last_error)
                state.last_error = if rendererError ~= ""
                    then rendererError
                    else noctalia.tr("errors.renderer_unavailable")
                runtimeChanged = true
            end
        end
    end
    wallInOne.persistRuntimeIfChanged(runtimeChanged)
    wallInOne.publishStatus()
    return true
end

wallInOne.cleanupOwnedStaging()
wallInOne.loadStorage()
wallInOne.reconcilePaletteAuthority(false)
do
    local initialRendererStatus = noctalia.state.get(RENDERER_STATUS_KEY)
    wallInOne.adoptRendererStatus(initialRendererStatus, true)
end
wallInOne.synchronizeInternalWorkshops(rendererStatus)
do
    local initialMotionBgsStatus = noctalia.state.get(MOTIONBGS_STATUS_KEY)
    if type(initialMotionBgsStatus) == "table" then
        motionBgsStatus = initialMotionBgsStatus
        lastMotionDownloadFingerprint = wallInOne.completedDownloadFingerprint(initialMotionBgsStatus)
    end
end
do
    local initialMotionBgsResults = noctalia.state.get(MOTIONBGS_RESULTS_KEY)
    if type(initialMotionBgsResults) == "table" then
        motionBgsResults = initialMotionBgsResults
    end
end
do
    local initialPalettesStatus = noctalia.state.get(PALETTES_STATUS_KEY)
    if type(initialPalettesStatus) == "table" then
        palettesStatus = initialPalettesStatus
    end
end
do
    local initialWallhavenStatus = noctalia.state.get(WALLHAVEN_STATUS_KEY)
    if type(initialWallhavenStatus) == "table" then
        wallhavenStatus = initialWallhavenStatus
        lastWallhavenDownloadFingerprint = wallInOne.completedDownloadFingerprint(initialWallhavenStatus)
    end
    local initialWallhavenResults = noctalia.state.get(WALLHAVEN_RESULTS_KEY)
    if type(initialWallhavenResults) == "table" then
        wallhavenResults = initialWallhavenResults
    end
end
wallInOne.refreshBackendPolicy()
libraryRootsSignature = wallInOne.currentLibraryRootsSignature()
do
    local managedReady, managedError = wallInOne.ensureImageManagedDirectories()
    managedDirectoryError = if managedReady then "" else tostring(managedError or "")
end
wallInOne.refreshLibrary()
if wallInOne.settingBool("cycle_start_on_load", false) then
    local resumedAt = wallInOne.nowSeconds()
    for output, outputConfig in pairs(config.outputs) do
        local outputRuntime = wallInOne.outputState(output)
        local playlistId = tostring(outputRuntime.active_playlist or "")
        local playlist = config.playlists[playlistId]
        local outputRuns = runtime.runs[output]
        local run = type(outputRuns) == "table" and outputRuns[playlistId] or nil
        if type(playlist) ~= "table" or #playlist.entries == 0 or type(run) ~= "table" then
            playlistId = type(outputConfig) == "table" and tostring(outputConfig.fallback_playlist or "") or ""
            playlist = config.playlists[playlistId]
            run = type(playlist) == "table" and wallInOne.playlistRunState(output, playlistId) or nil
        end
        if wallInOne.knownOutputName(output) ~= nil and type(playlist) == "table" and #playlist.entries > 0 then
            wallInOne.disarmOtherPlaylistRuns(output, playlistId)
            outputRuntime.active_playlist = playlistId
            run = wallInOne.playlistRunState(output, playlistId)
            -- A one-entry run is armed only long enough for update() to apply
            -- it once; advancePlaylist parks it after the successful switch.
            run.running = true
            run.paused = false
            run.parked = false
            local savedDue = math.max(0, math.floor(tonumber(run.next_due) or 0))
            local currentIndex = wallInOne.entryIndexById(playlist, tostring(run.current_entry or ""))
            if #playlist.entries > 1 and currentIndex ~= nil and savedDue > resumedAt then
                run.next_due = savedDue
                table.insert(startupRestoreQueue, {
                    output = output,
                    playlist_id = playlistId,
                    restore_current = true,
                })
            else
                run.next_due = resumedAt
            end
        end
    end
    wallInOne.persistRuntimeIfChanged(true)
else
    -- Persisted runtime describes the last session, not permission to resume
    -- playback. Unless explicitly opted in, every reload starts disarmed.
    for _, outputRuns in pairs(runtime.runs) do
        if type(outputRuns) == "table" then
            for _, run in pairs(outputRuns) do
                if type(run) == "table" then
                    run.running = false
                    run.paused = false
                    run.next_due = 0
                end
            end
        end
    end
    wallInOne.persistRuntimeIfChanged(true)
end
-- The first update performs the initial schedule evaluation through the same
-- sorted, palette-aware batch used for minute boundaries. Avoid launching one
-- asynchronous global-theme writer per output during service construction.
do
    local previousAck = noctalia.state.get(COMMAND_ACK_KEY)
    if type(previousAck) == "table" then
        lastCommandSequence = tonumber(previousAck.sequence) or 0
    end
end
noctalia.state.watch(COMMAND_KEY, wallInOne.handleCommand)
noctalia.state.watch(RENDERER_STATUS_KEY, wallInOne.adoptRendererStatus)
noctalia.state.watch(MOTIONBGS_STATUS_KEY, function(nextStatus)
    local previousDownloadDirectory = if type(motionBgsStatus) == "table"
        then tostring(motionBgsStatus.download_directory or "")
        else ""
    if type(nextStatus) == "table" then
        motionBgsStatus = nextStatus
    else
        motionBgsStatus = { available = false, busy = false, last_error = noctalia.tr("errors.motionbgs_unavailable") }
    end
    local nextDownloadDirectory = tostring(motionBgsStatus.download_directory or "")
    if nextDownloadDirectory ~= previousDownloadDirectory then
        settingsSnapshotCache = nil
    end
    local downloadFingerprint, downloadPath = wallInOne.completedDownloadFingerprint(motionBgsStatus)
    if downloadPath ~= "" and downloadFingerprint ~= lastMotionDownloadFingerprint then
        lastMotionDownloadFingerprint = downloadFingerprint
        libraryRefreshPending = true
    end
    wallInOne.refreshBackendPolicy()
    wallInOne.persistRuntimeIfChanged(false)
    wallInOne.publishStatus()
end)
noctalia.state.watch(MOTIONBGS_RESULTS_KEY, function(nextResults)
    motionBgsResults = if type(nextResults) == "table" then nextResults else { items = {}, selected = {} }
end)
noctalia.state.watch(PALETTES_STATUS_KEY, function(nextStatus)
    palettesStatus = if type(nextStatus) == "table" then nextStatus else {
        ready = false,
        busy = false,
        builtin = {},
        wallpaper = {},
        community = {},
        custom = {},
        last_error = noctalia.tr("errors.palettes_unavailable"),
    }
end)
noctalia.state.watch(WALLHAVEN_STATUS_KEY, function(nextStatus)
    wallhavenStatus = if type(nextStatus) == "table"
        then nextStatus
        else { ready = false, available = false, busy = false, last_error = noctalia.tr("errors.wallhaven_unavailable") }
    local downloadFingerprint, downloadPath = wallInOne.completedDownloadFingerprint(wallhavenStatus)
    if downloadPath ~= "" and downloadFingerprint ~= lastWallhavenDownloadFingerprint then
        lastWallhavenDownloadFingerprint = downloadFingerprint
        libraryRefreshPending = true
        wallInOne.publishStatus()
    end
end)
noctalia.state.watch(WALLHAVEN_RESULTS_KEY, function(nextResults)
    wallhavenResults = if type(nextResults) == "table" then nextResults else { items = {}, selected = {} }
end)
wallInOne.handleCommand(noctalia.state.get(COMMAND_KEY))
wallInOne.refreshAvailability()

function onExit(_signal, _reason)
    for _, request in pairs(pendingInternalCaptures) do
        if
            type(request) == "table"
            and type(request.staging_path) == "string"
            and request.staging_path ~= ""
            and noctalia.fileExists(request.staging_path)
        then
            noctalia.removeFile(request.staging_path)
        end
    end
    for _, request in pairs(internalCaptureQueued) do
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
    statusSequence += 1
    noctalia.state.set(STATUS_KEY, {
        protocol = 4,
        instance_id = SERVICE_NONCE,
        sequence = statusSequence,
        ready = false,
        domains = {
            config = { key = CONFIG_STATE_KEY, revision = domainPublications.config.revision },
            runtime = { key = RUNTIME_STATE_KEY, revision = domainPublications.runtime.revision },
            library = { key = LIBRARY_STATE_KEY, revision = domainPublications.library.revision },
        },
    })
end

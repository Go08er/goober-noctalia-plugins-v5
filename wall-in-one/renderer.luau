--!nonstrict
-- Wall-in-One internal renderer owner.
--
-- One cancellable runStream owns the Bash supervisor and every renderer in its
-- process group. No renderer detaches itself. Consequently Noctalia tears the
-- complete process tree down when this service reloads or stops.
--
-- Internally owned renderers use the validated background/bottom layer selected
-- by the user and never suppress Noctalia's wallpaper surface. That keeps
-- teardown safe on plugin API 17, where an onExit wallpaper-surface restoration
-- cannot yet be relied upon.

local SCHEMA = 1
local COMMAND_KEY = "wall_in_one_renderer_command_v1"
local STATUS_KEY = "wall_in_one_renderer_status_v1"
local MAX_NONCE = 9007199254740991
local MAX_QUEUE = 64
local MAX_COMMAND_BYTES = 4096
local FIFO_WRITE_TIMEOUT_MS = 5000
local SUPERVISOR_HEARTBEAT_TIMEOUT_MS = 15000
local EMPTY_OPTION_SENTINEL = "E"
local VALUE_OPTION_PREFIX = "V"
local INSTANCE_ID = (tostring(noctalia.nowMs()) .. "-" .. tostring({})):gsub("[^%w%-]", ""):sub(1, 80)

local W_ENGINE_SCALING = {
    default = true,
    stretch = true,
    fit = true,
    fill = true,
}

local W_ENGINE_CLAMP = {
    clamp = true,
    border = true,
    ["repeat"] = true,
}

local INTERNAL_LAYERS = {
    background = true,
    bottom = true,
}

local status = {
    schema = SCHEMA,
    instance_id = INSTANCE_ID,
    status_revision = 0,
    ready = false,
    last_nonce = 0,
    last_event_nonce = 0,
    last_event = "loading",
    last_error = "",
    outputs = {},
    updated_at = "",
}

local previousStatus = noctalia.state.get(STATUS_KEY)
if type(previousStatus) == "table" then
    local previousNonce = tonumber(previousStatus.last_nonce)
    if previousNonce ~= nil and previousNonce >= 0 and previousNonce <= MAX_NONCE then
        status.last_nonce = math.floor(previousNonce)
    end
end

local supervisorReady = false
local supervisorFailed = false
local supervisorStarting = false
local supervisorRecoveryAllowed = false
local activeWrite = nil
local pendingLines = {}
local pendingCommandMetadata = {}
local fifoPath = ""
local lastHeartbeatMs = 0

local function bounded(value, limit)
    local text = tostring(value or ""):gsub("[%c]", " ")
    limit = tonumber(limit) or 240
    if #text > limit then
        text = text:sub(1, limit)
    end
    return text
end

local function publishStatus()
    local revision = tonumber(status.status_revision) or 0
    status.status_revision = if revision >= MAX_NONCE then 1 else math.floor(revision) + 1
    status.queue_depth = #pendingLines
    status.write_in_flight = activeWrite ~= nil
    status.write_nonce = if type(activeWrite) == "table" then tonumber(activeWrite.nonce) or 0 else 0
    status.updated_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    noctalia.state.set(STATUS_KEY, status)
end

local function setError(message, event, nonce)
    status.last_event = tostring(event or "error")
    status.last_error = bounded(message, 320)
    local eventNonce = tonumber(nonce)
    if eventNonce ~= nil and eventNonce >= 0 and eventNonce <= MAX_NONCE then
        status.last_event_nonce = math.floor(eventNonce)
    end
    publishStatus()
end

local function markSupervisorUnavailable(message, event, nonce, recoveryAllowed)
    supervisorReady = false
    supervisorStarting = false
    supervisorFailed = true
    supervisorRecoveryAllowed = recoveryAllowed == true
    status.ready = false
    pendingLines = {}
    pendingCommandMetadata = {}
    activeWrite = nil
    setError(message, event, nonce)
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function validAbsolutePath(value)
    return type(value) == "string" and value:sub(1, 1) == "/" and value:find("[%c]") == nil
end

local function validatedProjectDirectory(value)
    if value == nil or value == "" then
        return "", nil
    end
    if not validAbsolutePath(value) or #value > 2048 then
        return nil, "Wallpaper Engine project directory is unsafe"
    end
    for segment in tostring(value):gmatch("[^/]+") do
        if segment == ".." then
            return nil, "Wallpaper Engine project directory contains traversal"
        end
    end
    local directory = tostring(value):gsub("/+$", "")
    if directory == "" then
        directory = "/"
    end
    local directoryInfo = noctalia.fileInfo(directory)
    local projectInfo = noctalia.fileInfo(directory .. "/project.json")
    if
        type(directoryInfo) ~= "table"
        or directoryInfo.isDir ~= true
        or type(projectInfo) ~= "table"
        or projectInfo.isDir == true
        or (tonumber(projectInfo.size) or 0) <= 0
    then
        return nil, "Wallpaper Engine project directory has no readable project.json"
    end
    return directory, nil
end

local function knownOutput(candidate)
    if type(candidate) ~= "string" or candidate == "" or candidate:find("[%c]") then
        return nil
    end
    -- The supervisor has a deliberately narrow parser and accepts ordinary
    -- connector identifiers only. Validate against the host snapshot as well.
    if candidate:match("^[%w_.:-]+$") == nil then
        return nil
    end
    for _, output in ipairs(noctalia.outputs()) do
        if output.name == candidate then
            return candidate
        end
    end
    return nil
end

local function integerOption(value, fallback, minimum, maximum)
    if value == nil then
        return fallback
    end
    local number = tonumber(value)
    if number == nil or number ~= math.floor(number) or number < minimum or number > maximum then
        return nil
    end
    return number
end

local function boolOption(value, fallback)
    if value == nil then
        return fallback
    end
    if type(value) ~= "boolean" then
        return nil
    end
    return value
end

local function boolField(value)
    return if value then "1" else "0"
end

local function nonceValue(value)
    local nonce = tonumber(value)
    if nonce == nil or nonce ~= math.floor(nonce) or nonce <= 0 or nonce > MAX_NONCE then
        return nil
    end
    return nonce
end

local function runtimeDirectory()
    local runtime = noctalia.getenv("XDG_RUNTIME_DIR")
    if validAbsolutePath(runtime) then
        local directory = runtime:gsub("/+$", "") .. "/noctalia-wall-in-one"
        local ok = noctalia.mkdirAll(directory)
        if ok == true then
            return directory
        end
    end

    local dataDirectory, dataError = noctalia.pluginDataDir()
    if not validAbsolutePath(dataDirectory) then
        return nil, tostring(dataError or "plugin data directory is unavailable")
    end
    local directory = dataDirectory:gsub("/+$", "") .. "/runtime"
    local ok, mkdirError = noctalia.mkdirAll(directory)
    if ok ~= true then
        return nil, tostring(mkdirError or "could not create renderer runtime directory")
    end
    return directory, nil
end

local function queueLine(line, nonce)
    if type(line) ~= "string" or #line == 0 or #line > MAX_COMMAND_BYTES or line:find("[\r\n]") then
        return false, "renderer command exceeds its safe wire format"
    end
    if #pendingLines >= MAX_QUEUE then
        return false, "renderer command queue is full"
    end
    table.insert(pendingLines, {
        line = line,
        nonce = nonce,
    })
    return true, nil
end

local pumpQueue

local function releaseActiveWrite(item)
    if activeWrite ~= item then
        return false
    end

    activeWrite = nil
    if pendingLines[1] == item then
        table.remove(pendingLines, 1)
    else
        -- Identity, rather than just nonce, keeps a late async callback from
        -- removing a newer queue head after a supervisor event advanced it.
        for index, queued in ipairs(pendingLines) do
            if queued == item then
                table.remove(pendingLines, index)
                break
            end
        end
    end
    return true
end

local function acknowledgeWriteThrough(nonce)
    local item = activeWrite
    local acknowledgedNonce = tonumber(nonce)
    if
        type(item) == "table"
        and acknowledgedNonce ~= nil
        and acknowledgedNonce >= (tonumber(item.nonce) or MAX_NONCE)
        and releaseActiveWrite(item)
    then
        pumpQueue()
        return true
    end
    return false
end

pumpQueue = function()
    if not supervisorReady or activeWrite ~= nil or fifoPath == "" or #pendingLines == 0 then
        return
    end

    local item = pendingLines[1]
    local line = item.line
    item.started_at_ms = noctalia.nowMs()
    activeWrite = item
    local command = table.concat({
        "if test -p",
        shellQuote(fifoPath),
        "; then printf '%s\\n'",
        shellQuote(line),
        "| dd conv=nocreat,notrunc oflag=nofollow status=none of=" .. shellQuote(fifoPath),
        "; else exit 74; fi",
    }, " ")
    local accepted = noctalia.runAsync(command, function(result)
        -- A supervisor event may acknowledge this write before Noctalia
        -- delivers the async result. Ignore that late callback by identity.
        if not releaseActiveWrite(item) then
            return
        end
        if type(result) ~= "table" or result.timedOut == true or tonumber(result.exitCode) ~= 0 then
            local detail = type(result) == "table" and (result.stderr or result.stdout) or ""
            markSupervisorUnavailable(
                "renderer FIFO write failed: " .. bounded(detail, 240),
                "write-error",
                item.nonce,
                true
            )
            return
        end
        pumpQueue()
        publishStatus()
    end, 3000)

    if not accepted and releaseActiveWrite(item) then
        markSupervisorUnavailable("Noctalia refused the renderer FIFO write", "write-error", item.nonce, true)
    end
end

local function eventFields(line)
    local protocol, nonce, event, output, backend, code, detail =
        tostring(line or ""):match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]+)\t(.*)$")
    if protocol ~= "WIO1" then
        return nil
    end
    local parsedNonce = tonumber(nonce)
    local parsedCode = tonumber(code)
    if parsedNonce == nil or parsedCode == nil then
        return nil
    end
    return {
        nonce = parsedNonce,
        event = tostring(event or ""),
        output = tostring(output or ""),
        backend = tostring(backend or ""),
        code = parsedCode,
        detail = bounded(detail, 240),
    }
end

local function noteSupervisorLiveness()
    lastHeartbeatMs = noctalia.nowMs()
end

local function copyOutputState(previous)
    local copied = {}
    if type(previous) == "table" then
        for key, value in pairs(previous) do
            copied[key] = value
        end
    end
    return copied
end

local function rendererCapabilities(backend, detail, capturing)
    local controls = tostring(detail or ""):match("controls=([%w%-]+)")
    if controls == nil then
        controls = if capturing then "stop-only" elseif backend == "w-engine" then "signals" else "pause-only"
    end
    local playback = controls ~= "stop-only"
    local audio = backend == "mpvpaper" and controls == "mpv-ipc"
    return controls, {
        stop = true,
        pause = playback,
        resume = playback,
        toggle = playback,
        mute = audio,
        unmute = audio,
        toggle_mute = audio,
        set_volume = audio,
    }
end

local function handleSupervisorLine(line)
    local event = eventFields(line)
    if event == nil then
        markSupervisorUnavailable("renderer supervisor returned an invalid status line", "protocol-error", 0)
        return
    end
    if event.nonce < 0 or event.nonce > MAX_NONCE or event.nonce ~= math.floor(event.nonce) then
        markSupervisorUnavailable("renderer supervisor returned an invalid event nonce", "protocol-error", 0)
        return
    end

    if event.nonce > status.last_nonce and event.nonce <= MAX_NONCE then
        status.last_nonce = math.floor(event.nonce)
    end

    if event.event == "ready" then
        supervisorReady = true
        supervisorFailed = false
        supervisorStarting = false
        supervisorRecoveryAllowed = false
        noteSupervisorLiveness()
        status.ready = true
        status.last_event_nonce = event.nonce
        status.last_event = "ready"
        status.last_error = ""
        publishStatus()
        pumpQueue()
        return
    elseif event.event == "heartbeat" then
        -- Heartbeats keep the stdout ownership pipe live. Avoid publishing a
        -- state update every five seconds when nothing else changed.
        noteSupervisorLiveness()
        local acknowledgedWrite = acknowledgeWriteThrough(event.nonce)
        if supervisorFailed and supervisorRecoveryAllowed then
            supervisorFailed = false
            supervisorRecoveryAllowed = false
            supervisorReady = true
            supervisorStarting = false
            status.ready = true
            status.last_event = "recovered"
            status.last_error = ""
            publishStatus()
            pumpQueue()
        elseif acknowledgedWrite then
            publishStatus()
        end
        return
    end

    -- The supervisor reads its FIFO in order. Any command event at or beyond
    -- the active nonce proves that exact queued write reached the reader, even
    -- when the separate runAsync completion arrives later or is coalesced.
    acknowledgeWriteThrough(event.nonce)

    local output = event.output
    local metadata = pendingCommandMetadata[event.nonce]
    if output ~= "-" and output ~= "" then
        if event.event == "started" then
            local capturing = type(metadata) == "table" and metadata.action == "capture_w_engine"
            local controls, capabilities = rendererCapabilities(event.backend, event.detail, capturing)
            status.outputs[output] = {
                backend = event.backend,
                state = if capturing then "capturing" else "running",
                nonce = event.nonce,
                workshop_id = type(metadata) == "table" and metadata.workshop_id or nil,
                project_directory = type(metadata) == "table" and metadata.project_directory or nil,
                source = type(metadata) == "table" and metadata.source or nil,
                source_kind = type(metadata) == "table" and metadata.source_kind or nil,
                muted = type(metadata) == "table" and metadata.muted or nil,
                volume = type(metadata) == "table" and metadata.volume or nil,
                layer = type(metadata) == "table" and metadata.layer or nil,
                controls = controls,
                capabilities = capabilities,
            }
        elseif event.event == "capture-started" then
            local nextOutput = copyOutputState(status.outputs[output])
            local controls, capabilities = rendererCapabilities("w-engine", "controls=stop-only", true)
            nextOutput.backend = "w-engine"
            nextOutput.state = "capturing"
            nextOutput.nonce = event.nonce
            nextOutput.workshop_id = type(metadata) == "table" and metadata.workshop_id or nextOutput.workshop_id
            nextOutput.project_directory = type(metadata) == "table" and metadata.project_directory
                or nextOutput.project_directory
            nextOutput.source = type(metadata) == "table" and metadata.source or nextOutput.source
            nextOutput.source_kind = "workshop"
            nextOutput.muted = type(metadata) == "table" and metadata.muted or nextOutput.muted
            nextOutput.volume = type(metadata) == "table" and metadata.volume or nextOutput.volume
            nextOutput.layer = type(metadata) == "table" and metadata.layer or nextOutput.layer
            nextOutput.controls = controls
            nextOutput.capabilities = capabilities
            status.outputs[output] = nextOutput
        elseif event.event == "paused" then
            local nextOutput = copyOutputState(status.outputs[output])
            nextOutput.backend = event.backend
            nextOutput.state = "paused"
            nextOutput.nonce = event.nonce
            status.outputs[output] = nextOutput
        elseif event.event == "resumed" then
            local nextOutput = copyOutputState(status.outputs[output])
            nextOutput.backend = event.backend
            nextOutput.state = "running"
            nextOutput.nonce = event.nonce
            status.outputs[output] = nextOutput
        elseif event.event == "muted" or event.event == "unmuted" then
            local nextOutput = copyOutputState(status.outputs[output])
            nextOutput.backend = event.backend
            nextOutput.muted = event.event == "muted"
            nextOutput.nonce = event.nonce
            status.outputs[output] = nextOutput
        elseif event.event == "volume-set" then
            local nextOutput = copyOutputState(status.outputs[output])
            local volume = tonumber(event.detail:match("volume=(%d+)"))
            nextOutput.backend = event.backend
            nextOutput.volume = volume or nextOutput.volume
            nextOutput.nonce = event.nonce
            status.outputs[output] = nextOutput
        elseif
            event.event == "stopped"
            or event.event == "exited"
            or event.event == "start-error"
            or event.event == "not-running"
            or event.event == "captured"
            or event.event == "capture-error"
            or event.event == "cancelled"
        then
            status.outputs[output] = nil
        end
    elseif event.event == "stopped-all" then
        status.outputs = {}
    end

    status.last_event_nonce = event.nonce
    status.last_event = event.event
    if
        event.event == "error"
        or event.event == "ignored"
        or event.event == "unsupported"
        or event.event == "control-error"
        or event.event == "start-error"
        or event.event == "not-running"
        or event.event == "capture-error"
        or event.event == "cancelled"
        or (event.event == "exited" and event.code ~= 0)
    then
        status.last_error = event.detail ~= "" and event.detail or ("renderer exited with code " .. event.code)
    elseif event.code == 0 then
        status.last_error = ""
    end
    if
        event.event == "captured"
        or event.event == "capture-error"
        or event.event == "cancelled"
        or event.event == "error"
        or event.event == "ignored"
        or event.event == "not-running"
        or event.event == "start-error"
        or (event.event == "started" and (type(metadata) ~= "table" or metadata.action ~= "capture_w_engine"))
    then
        pendingCommandMetadata[event.nonce] = nil
    end
    publishStatus()
end

local function startSupervisor()
    local runtime, runtimeError = runtimeDirectory()
    if runtime == nil then
        markSupervisorUnavailable(runtimeError, "startup-error", 0, false)
        return
    end

    local pluginDirectory = noctalia.pluginDir()
    if not validAbsolutePath(pluginDirectory) then
        markSupervisorUnavailable("plugin directory is unavailable", "startup-error", 0, false)
        return
    end
    local helper = pluginDirectory:gsub("/+$", "") .. "/scripts/renderer-supervisor"
    if not noctalia.fileExists(helper) then
        markSupervisorUnavailable("renderer supervisor helper is missing", "startup-error", 0, false)
        return
    end

    local token = (tostring(noctalia.nowMs()) .. "-" .. tostring({})):gsub("[^%w%-]", "")
    if #token > 80 then
        token = token:sub(1, 80)
    end
    fifoPath = runtime .. "/renderer-" .. token .. ".fifo"
    local command = "exec bash " .. shellQuote(helper) .. " " .. shellQuote(fifoPath)
    supervisorStarting = true
    lastHeartbeatMs = noctalia.nowMs()
    local accepted = noctalia.runStream(command, handleSupervisorLine)
    if not accepted then
        fifoPath = ""
        markSupervisorUnavailable("Noctalia refused the renderer supervisor stream", "startup-error", 0, false)
    end
end

local function validatedWEngineOptions(command)
    if not noctalia.commandExists("linux-wallpaperengine") then
        return nil, "linux-wallpaperengine is not installed"
    end

    local id = tostring(command.id or command.workshop_id or "")
    if id:match("^%d+$") == nil or #id > 24 then
        return nil, "Wallpaper Engine requires a numeric Workshop ID"
    end
    local projectDirectory, projectError = validatedProjectDirectory(
        command.project_directory or command.project_path or ""
    )
    if projectDirectory == nil then
        return nil, projectError
    end

    local fps = integerOption(command.fps, 30, 5, 144)
    local volume = integerOption(command.volume, 15, 0, 100)
    local scaling = tostring(command.scaling or "fill")
    local clamp = tostring(command.clamp or "border")
    local layer = tostring(command.layer or "bottom")
    if
        fps == nil
        or volume == nil
        or not W_ENGINE_SCALING[scaling]
        or not W_ENGINE_CLAMP[clamp]
        or not INTERNAL_LAYERS[layer]
    then
        return nil, "Wallpaper Engine options are invalid"
    end

    local silent = boolOption(command.silent, false)
    local noautomute = boolOption(command.noautomute, false)
    local noAudioProcessing = boolOption(command.no_audio_processing, false)
    local disableParticles = boolOption(command.disable_particles, false)
    local disableMouse = boolOption(command.disable_mouse, false)
    local disableParallax = boolOption(command.disable_parallax, false)
    local noFullscreenPause = boolOption(command.no_fullscreen_pause, false)
    local fullscreenPauseOnlyActive = boolOption(command.fullscreen_pause_only_active, false)
    if
        silent == nil
        or noautomute == nil
        or noAudioProcessing == nil
        or disableParticles == nil
        or disableMouse == nil
        or disableParallax == nil
        or noFullscreenPause == nil
        or fullscreenPauseOnlyActive == nil
    then
        return nil, "Wallpaper Engine flags must be booleans"
    end
    if noFullscreenPause and fullscreenPauseOnlyActive then
        return nil, "fullscreen pause flags are mutually exclusive"
    end

    return {
        id = id,
        source = if projectDirectory ~= "" then projectDirectory else id,
        project_directory = projectDirectory,
        fps = fps,
        volume = volume,
        scaling = scaling,
        clamp = clamp,
        layer = layer,
        silent = silent,
        noautomute = noautomute,
        no_audio_processing = noAudioProcessing,
        disable_particles = disableParticles,
        disable_mouse = disableMouse,
        disable_parallax = disableParallax,
        no_fullscreen_pause = noFullscreenPause,
        fullscreen_pause_only_active = fullscreenPauseOnlyActive,
    },
        nil
end

local function encodeWEngine(command, nonce, output)
    local options, optionsError = validatedWEngineOptions(command)
    if options == nil then
        return nil, optionsError
    end
    return table.concat({
        "WIO1",
        tostring(nonce),
        "start_w_engine",
        output,
        options.source,
        tostring(options.fps),
        tostring(options.volume),
        options.scaling,
        options.clamp,
        options.layer,
        boolField(options.silent),
        boolField(options.noautomute),
        boolField(options.no_audio_processing),
        boolField(options.disable_particles),
        boolField(options.disable_mouse),
        boolField(options.disable_parallax),
        boolField(options.no_fullscreen_pause),
        boolField(options.fullscreen_pause_only_active),
    }, "\t"),
        nil
end

local function encodeWEngineCapture(command, nonce, output)
    local options, optionsError = validatedWEngineOptions(command)
    if options == nil then
        return nil, optionsError
    end
    local destination = tostring(command.destination or command.screenshot_path or "")
    local delay = integerOption(command.screenshot_delay, 5, 1, 5)
    local dataDirectory = noctalia.pluginDataDir()
    local stagingPrefix = if validAbsolutePath(dataDirectory)
        then tostring(dataDirectory):gsub("/+$", "") .. "/staging/"
        else ""
    local stagingName = if stagingPrefix ~= "" and destination:sub(1, #stagingPrefix) == stagingPrefix
        then destination:sub(#stagingPrefix + 1)
        else ""
    if
        not validAbsolutePath(destination)
        or #destination > 2048
        or delay == nil
        or stagingName:match("^capture%-%w[%w%-]*%.png$") == nil
    then
        return nil, "Wallpaper Engine screenshot options are invalid"
    end
    return table.concat({
        "WIO1",
        tostring(nonce),
        "capture_w_engine",
        output,
        options.source,
        destination,
        tostring(delay),
        tostring(options.fps),
        tostring(options.volume),
        options.scaling,
        options.clamp,
        options.layer,
        boolField(options.silent),
        boolField(options.noautomute),
        boolField(options.no_audio_processing),
        boolField(options.disable_particles),
        boolField(options.disable_mouse),
        boolField(options.disable_parallax),
        boolField(options.no_fullscreen_pause),
        boolField(options.fullscreen_pause_only_active),
    }, "\t"),
        nil
end

local function encodeMpvpaper(command, nonce, output)
    if not noctalia.commandExists("mpvpaper") then
        return nil, "mpvpaper is not installed"
    end

    local video = command.video or command.path
    if not validAbsolutePath(video) or #video > 2048 then
        return nil, "mpvpaper requires an absolute video path"
    end
    local info = noctalia.fileInfo(video)
    if type(info) ~= "table" or info.isDir == true then
        return nil, "mpvpaper video does not exist or is not a regular file"
    end

    local mute = boolOption(command.mute, true)
    local volume = integerOption(command.volume, 100, 0, 100)
    local hardwareDecode = boolOption(command.hardware_decode, true)
    local autoPause = boolOption(command.auto_pause, true)
    local autoPauseMode = tostring(command.auto_pause_mode or "FULL")
    local layer = tostring(command.layer or "bottom")
    if mute == nil or hardwareDecode == nil or autoPause == nil then
        return nil, "mpvpaper options must be booleans"
    end
    if volume == nil then
        return nil, "mpvpaper volume must be an integer from 0 to 100"
    end
    if
        (autoPauseMode ~= "FULL" and autoPauseMode ~= "MAX" and autoPauseMode ~= "ACTIVE")
        or not INTERNAL_LAYERS[layer]
    then
        return nil, "mpvpaper layer or auto-pause mode is invalid"
    end
    local options = tostring(command.options or "")
    if #options > 1024 or options:find("[%c]") then
        return nil, "additional mpv options are too long or contain control characters"
    end
    for token in options:gmatch("%S+") do
        local key = token:match("^([^=]+)") or token
        key = key:gsub("^%-%-", ""):lower()
        if
            key == "input-ipc-server"
            or key == "no-input-ipc-server"
            or key == "audio"
            or key == "no-audio"
            or key == "aid"
            or key == "mute"
            or key == "volume"
        then
            return nil, "additional mpv options cannot override owned IPC or audio state"
        end
    end
    local encodedOptions = if options == "" then EMPTY_OPTION_SENTINEL else VALUE_OPTION_PREFIX .. options

    return table.concat({
        "WIO1",
        tostring(nonce),
        "start_mpvpaper",
        output,
        video,
        layer,
        boolField(mute),
        tostring(volume),
        boolField(hardwareDecode),
        boolField(autoPause),
        autoPauseMode,
        encodedOptions,
    }, "\t"),
        nil
end

local SIMPLE_ACTIONS = {
    stop = true,
    pause = true,
    resume = true,
    toggle = true,
    mute = true,
    unmute = true,
    toggle_mute = true,
}

local function handleCommand(command)
    if type(command) ~= "table" or tonumber(command.schema or SCHEMA) ~= SCHEMA then
        return
    end

    local nonce = nonceValue(command.nonce)
    if nonce == nil or nonce <= status.last_nonce then
        return
    end

    -- Consume malformed commands too, so a stale bad state value is never
    -- replayed after a hot reload.
    status.last_nonce = nonce
    status.last_event_nonce = nonce
    local action = tostring(command.action or "")
    local line
    local errorMessage

    if action == "stop_all" then
        line = table.concat({ "WIO1", tostring(nonce), action, "-" }, "\t")
    else
        local requestedOutput = tostring(command.output or "")
        local output = knownOutput(requestedOutput)
        if
            output == nil
            and (SIMPLE_ACTIONS[action] or action == "set_volume")
            and requestedOutput:match("^[%w_.:-]+$") ~= nil
            and type(status.outputs[requestedOutput]) == "table"
        then
            -- A disconnected output is no longer in noctalia.outputs(), but an
            -- exact owned child still needs to remain stoppable during hotplug.
            output = requestedOutput
        end
        if output == nil then
            setError("renderer command names an unknown or unsafe output", "rejected", nonce)
            return
        end

        if action == "start_w_engine" then
            line, errorMessage = encodeWEngine(command, nonce, output)
        elseif action == "capture_w_engine" then
            line, errorMessage = encodeWEngineCapture(command, nonce, output)
        elseif action == "start_mpvpaper" then
            line, errorMessage = encodeMpvpaper(command, nonce, output)
        elseif action == "set_volume" then
            local volume = integerOption(command.volume, nil, 0, 100)
            if volume == nil then
                errorMessage = "renderer volume must be an integer from 0 to 100"
            else
                line = table.concat({ "WIO1", tostring(nonce), action, output, tostring(volume) }, "\t")
            end
        elseif SIMPLE_ACTIONS[action] then
            line = table.concat({ "WIO1", tostring(nonce), action, output }, "\t")
        else
            errorMessage = "unsupported renderer action: " .. bounded(action, 80)
        end
    end

    if line == nil then
        setError(errorMessage or "renderer command is invalid", "rejected", nonce)
        return
    end
    if supervisorFailed then
        setError("renderer supervisor is unavailable; reload the plugin to retry", "unavailable", nonce)
        return
    end
    local queued, queueError = queueLine(line, nonce)
    if not queued then
        setError(queueError, "queue-error", nonce)
        return
    end
    if action == "start_w_engine" or action == "capture_w_engine" then
        local projectDirectory = tostring(command.project_directory or command.project_path or ""):gsub("/+$", "")
        local workshopId = tostring(command.id or command.workshop_id or "")
        pendingCommandMetadata[nonce] = {
            action = action,
            output = tostring(command.output or ""),
            workshop_id = workshopId,
            project_directory = if projectDirectory ~= "" then projectDirectory else nil,
            source = if projectDirectory ~= "" then projectDirectory else workshopId,
            source_kind = "workshop",
            muted = boolOption(command.silent, false),
            volume = integerOption(command.volume, 15, 0, 100),
            layer = tostring(command.layer or "bottom"),
        }
    elseif action == "start_mpvpaper" then
        pendingCommandMetadata[nonce] = {
            action = action,
            output = tostring(command.output or ""),
            source = tostring(command.video or command.path or ""),
            source_kind = "video",
            muted = boolOption(command.mute, true),
            volume = integerOption(command.volume, 100, 0, 100),
            layer = tostring(command.layer or "bottom"),
        }
    end
    status.last_event = "queued"
    status.last_error = ""
    pumpQueue()
    publishStatus()
end

function update()
    -- Commands are sent once, matching ordinary v5 plugin practice. This
    -- modest shared-slot read is lifecycle/status reconciliation rather than a
    -- retransmission loop; the monotonic nonce makes the read idempotent.
    handleCommand(noctalia.state.get(COMMAND_KEY))

    local item = activeWrite
    if
        type(item) == "table"
        and tonumber(item.started_at_ms) ~= nil
        and noctalia.nowMs() - tonumber(item.started_at_ms) > FIFO_WRITE_TIMEOUT_MS
        and releaseActiveWrite(item)
    then
        markSupervisorUnavailable("renderer FIFO write acknowledgement timed out", "write-timeout", item.nonce, true)
        return
    end

    if
        (supervisorReady or supervisorStarting)
        and lastHeartbeatMs > 0
        and noctalia.nowMs() - lastHeartbeatMs > SUPERVISOR_HEARTBEAT_TIMEOUT_MS
    then
        markSupervisorUnavailable(
            "renderer supervisor heartbeat timed out; reload the plugin to retry",
            "heartbeat-timeout",
            status.last_nonce,
            true
        )
    end
end

function onConfigChanged()
    -- Renderer-affecting settings are copied into each command by the
    -- coordinator. Keep this host, supervisor, and its owned children alive
    -- when unrelated plugin settings change.
end

function onExit(_signal, _reason)
    -- Do not launch cleanup commands here. Destroying this host cancels the
    -- runStream, and Noctalia terminates its complete process group directly.
    status.ready = false
    status.last_event = "stopping"
    status.outputs = {}
    publishStatus()
end

noctalia.state.watch(COMMAND_KEY, handleCommand)
noctalia.setUpdateInterval(2000)
publishStatus()
startSupervisor()
handleCommand(noctalia.state.get(COMMAND_KEY))

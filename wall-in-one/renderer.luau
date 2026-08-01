--!nonstrict
-- Wall-in-One internal renderer owner.
--
-- One cancellable runStream owns the Bash supervisor and every renderer in its
-- process group. No renderer detaches itself. Consequently Noctalia tears the
-- complete process tree down when this service reloads or stops.
--
-- This first internal backend deliberately uses linux-wallpaperengine's bottom
-- layer and never suppresses Noctalia's wallpaper surface. That keeps teardown
-- safe on plugin API 17, where an onExit wallpaper-surface restoration cannot
-- yet be relied upon.

local SCHEMA = 1
local COMMAND_KEY = "wall_in_one_renderer_command_v1"
local STATUS_KEY = "wall_in_one_renderer_status_v1"
local MAX_NONCE = 9007199254740991
local MAX_QUEUE = 64
local MAX_COMMAND_BYTES = 4096
local SUPERVISOR_HEARTBEAT_TIMEOUT_MS = 15000
local EMPTY_OPTION_SENTINEL = "E"
local VALUE_OPTION_PREFIX = "V"

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

local status = {
    schema = SCHEMA,
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
local writeInFlight = false
local pendingLines = {}
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
    setError(message, event, nonce)
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function validAbsolutePath(value)
    return type(value) == "string" and value:sub(1, 1) == "/" and value:find("[%c]") == nil
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

pumpQueue = function()
    if not supervisorReady or writeInFlight or fifoPath == "" or #pendingLines == 0 then
        return
    end

    local item = pendingLines[1]
    local line = item.line
    writeInFlight = true
    local command = table.concat({
        "if test -p",
        shellQuote(fifoPath),
        "; then printf '%s\\n'",
        shellQuote(line),
        "| dd conv=nocreat,notrunc oflag=nofollow status=none of=" .. shellQuote(fifoPath),
        "; else exit 74; fi",
    }, " ")
    local accepted = noctalia.runAsync(command, function(result)
        writeInFlight = false
        table.remove(pendingLines, 1)
        if type(result) ~= "table" or result.timedOut == true or tonumber(result.exitCode) ~= 0 then
            local detail = type(result) == "table" and (result.stderr or result.stdout) or ""
            markSupervisorUnavailable(
                "renderer FIFO write failed: " .. bounded(detail, 240),
                "write-error",
                item.nonce,
                true
            )
        end
        pumpQueue()
    end, 3000)

    if not accepted then
        writeInFlight = false
        table.remove(pendingLines, 1)
        markSupervisorUnavailable("Noctalia refused the renderer FIFO write", "write-error", item.nonce, true)
        pumpQueue()
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
        end
        return
    end

    local output = event.output
    if output ~= "-" and output ~= "" then
        if event.event == "started" then
            status.outputs[output] = {
                backend = event.backend,
                state = "running",
                nonce = event.nonce,
            }
        elseif event.event == "paused" then
            status.outputs[output] = {
                backend = event.backend,
                state = "paused",
                nonce = event.nonce,
            }
        elseif event.event == "resumed" then
            status.outputs[output] = {
                backend = event.backend,
                state = "running",
                nonce = event.nonce,
            }
        elseif
            event.event == "stopped"
            or event.event == "exited"
            or event.event == "start-error"
            or event.event == "not-running"
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
        or event.event == "start-error"
        or event.event == "not-running"
        or (event.event == "exited" and event.code ~= 0)
    then
        status.last_error = event.detail ~= "" and event.detail or ("renderer exited with code " .. event.code)
    elseif event.code == 0 then
        status.last_error = ""
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

local function encodeWEngine(command, nonce, output)
    if not noctalia.commandExists("linux-wallpaperengine") then
        return nil, "linux-wallpaperengine is not installed"
    end

    local id = tostring(command.id or command.workshop_id or "")
    if id:match("^%d+$") == nil or #id > 24 then
        return nil, "Wallpaper Engine requires a numeric Workshop ID"
    end

    local fps = integerOption(command.fps, 30, 5, 144)
    local volume = integerOption(command.volume, 15, 0, 100)
    local scaling = tostring(command.scaling or "fill")
    local clamp = tostring(command.clamp or "border")
    if fps == nil or volume == nil or not W_ENGINE_SCALING[scaling] or not W_ENGINE_CLAMP[clamp] then
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

    return table.concat({
        "WIO1",
        tostring(nonce),
        "start_w_engine",
        output,
        id,
        tostring(fps),
        tostring(volume),
        scaling,
        clamp,
        boolField(silent),
        boolField(noautomute),
        boolField(noAudioProcessing),
        boolField(disableParticles),
        boolField(disableMouse),
        boolField(disableParallax),
        boolField(noFullscreenPause),
        boolField(fullscreenPauseOnlyActive),
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
    local hardwareDecode = boolOption(command.hardware_decode, true)
    local autoPause = boolOption(command.auto_pause, true)
    local autoPauseMode = tostring(command.auto_pause_mode or "FULL")
    if mute == nil or hardwareDecode == nil or autoPause == nil then
        return nil, "mpvpaper options must be booleans"
    end
    if autoPauseMode ~= "FULL" and autoPauseMode ~= "MAX" then
        return nil, "mpvpaper auto-pause mode must be FULL or MAX"
    end
    local options = tostring(command.options or "")
    if #options > 1024 or options:find("[%c]") then
        return nil, "additional mpv options are too long or contain control characters"
    end
    local encodedOptions = if options == "" then EMPTY_OPTION_SENTINEL else VALUE_OPTION_PREFIX .. options

    return table.concat({
        "WIO1",
        tostring(nonce),
        "start_mpvpaper",
        output,
        video,
        boolField(mute),
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
            and SIMPLE_ACTIONS[action]
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
        elseif action == "start_mpvpaper" then
            line, errorMessage = encodeMpvpaper(command, nonce, output)
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
    status.last_event = "queued"
    status.last_error = ""
    publishStatus()
    pumpQueue()
end

function update()
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

function onExit(_signal, _reason)
    -- Do not launch cleanup commands here. Destroying this host cancels the
    -- runStream, and Noctalia terminates its complete process group directly.
    status.ready = false
    status.last_event = "stopping"
    status.outputs = {}
    noctalia.state.set(STATUS_KEY, status)
end

noctalia.state.watch(COMMAND_KEY, handleCommand)
noctalia.setUpdateInterval(2000)
publishStatus()
startSupervisor()
handleCommand(noctalia.state.get(COMMAND_KEY))

--!nonstrict
-- NocVox's singleton listener/control service.
--
-- This entry is a companion to an independently managed VoxType daemon. It
-- owns one read-only status follower and launches only `voxtype record ...`
-- controls plus on-demand version/variant diagnostics. It never starts, stops,
-- supervises, configures, updates, or installs the daemon.

local STATUS_KEY = "voxtype_status"
local COMMAND_KEY = "voxtype_command"
local COMMAND_ACK_KEY = "voxtype_command_ack"
local READY_KEY = "voxtype_service_ready"
local DIAGNOSTICS_KEY = "voxtype_diagnostics"
local STATUS_PROTOCOL = 1
local FOLLOW_COMMAND = "voxtype status --follow --format json --extended --icon-theme text"

local RECORDING_STATES = { recording = true, streaming = true }
local PROCESSING_STATES = { transcribing = true, processing = true }
local KNOWN_STATES = {
    stopped = true,
    idle = true,
    recording = true,
    streaming = true,
    transcribing = true,
    processing = true,
    error = true,
}

local sequence = 0
local lastCommandSequence = 0
local actionPending = false
local diagnosticsPending = false
local hasGoodStatus = false
local activeStopFlag = ""
local lastNotifiedError = ""

local current = {
    protocol = STATUS_PROTOCOL,
    sequence = 0,
    state = "unknown",
    raw_state = "",
    available = false,
    follower_active = false,
    model = "",
    device = "",
    backend = "",
    observed_at = "",
    recording_started_at = 0,
    elapsed_approximate = false,
    action_pending = false,
    pending_action = "",
    last_action = "",
    last_error = "",
    malformed_count = 0,
    override_active = false,
    override_output = "inherit",
    override_file = "",
    override_model = "",
    override_profile = "",
}

local function cfg(key)
    return noctalia.getConfig(key)
end

local function nowSeconds()
    return tonumber(noctalia.formatTime("%s")) or 0
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function cleanText(value, maximum)
    local text = tostring(value or ""):gsub("[%c]", " ")
    text = noctalia.string.trim(text)
    if #text > maximum then
        text = text:sub(1, maximum)
    end
    return text
end

local function publish()
    sequence += 1
    current.protocol = STATUS_PROTOCOL
    current.sequence = sequence
    current.action_pending = actionPending
    noctalia.state.set(STATUS_KEY, current)
end

local function notifyFailure(message)
    if cfg("notify_failures") ~= true then
        return
    end

    if message == lastNotifiedError then
        return
    end

    lastNotifiedError = message
    noctalia.notifyError(noctalia.tr("plugin.name"), message)
end

local function setFailure(message, shouldNotify)
    local detail = cleanText(message, 320)
    if detail == "" then
        detail = noctalia.tr("errors.action_failed")
    end
    current.last_error = detail
    noctalia.log("nocvox: " .. detail)
    publish()
    if shouldNotify then
        notifyFailure(detail)
    end
end

local function clearOverride()
    current.override_active = false
    current.override_output = "inherit"
    current.override_file = ""
    current.override_model = ""
    current.override_profile = ""
    activeStopFlag = ""
end

local function notifyTransition(state)
    if cfg("notify_transitions") ~= true then
        return
    end
    if
        state ~= "idle"
        and state ~= "recording"
        and state ~= "streaming"
        and state ~= "transcribing"
        and state ~= "stopped"
    then
        return
    end
    local message = ""
    if state == "stopped" then
        message = noctalia.tr("notifications.state.stopped")
    elseif state == "idle" then
        message = noctalia.tr("notifications.state.idle")
    elseif state == "recording" then
        message = noctalia.tr("notifications.state.recording")
    elseif state == "streaming" then
        message = noctalia.tr("notifications.state.streaming")
    elseif state == "transcribing" then
        message = noctalia.tr("notifications.state.transcribing")
    end
    noctalia.notify(noctalia.tr("plugin.name"), message)
end

local function applyStatusLine(line)
    local decoded, decodeError = noctalia.json.decode(line)
    if type(decoded) ~= "table" then
        current.malformed_count += 1
        if not hasGoodStatus then
            current.state = "unknown"
            current.raw_state = "malformed"
        end
        setFailure(noctalia.tr("errors.malformed_status", { error = cleanText(decodeError, 160) }), true)
        return
    end

    local rawState = cleanText(decoded.alt, 48):lower()
    local normalized = if KNOWN_STATES[rawState] then rawState else "unknown"
    local previousState = current.state
    local wasGood = hasGoodStatus
    local now = nowSeconds()

    if RECORDING_STATES[normalized] then
        if not RECORDING_STATES[previousState] then
            current.recording_started_at = now
            current.elapsed_approximate = not wasGood
        end
    elseif normalized == "idle" or normalized == "stopped" then
        current.recording_started_at = 0
        current.elapsed_approximate = false
        if RECORDING_STATES[previousState] or PROCESSING_STATES[previousState] then
            clearOverride()
        end
    end

    current.state = normalized
    current.raw_state = rawState
    current.available = true
    current.follower_active = true
    current.model = cleanText(decoded.model, 200)
    current.device = cleanText(decoded.device, 200)
    current.backend = cleanText(decoded.backend, 120)
    current.observed_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    current.last_error = ""
    lastNotifiedError = ""
    hasGoodStatus = true
    publish()

    if wasGood and normalized ~= previousState then
        if normalized == "error" then
            notifyFailure(noctalia.tr("notifications.state.error"))
        else
            notifyTransition(normalized)
        end
    end
end

local function stateAllows(action)
    local state = current.state
    if not current.available then
        return false, noctalia.tr("errors.missing_voxtype")
    end
    if state == "stopped" then
        return false, noctalia.tr("errors.daemon_stopped")
    end
    if action == "start" then
        return state == "idle", noctalia.tr("errors.start_unavailable")
    elseif action == "stop" then
        return RECORDING_STATES[state] == true, noctalia.tr("errors.stop_unavailable")
    elseif action == "cancel" then
        return RECORDING_STATES[state] == true or PROCESSING_STATES[state] == true,
            noctalia.tr("errors.cancel_unavailable")
    end
    return false, noctalia.tr("errors.unknown_action", { action = tostring(action) })
end

local function validateSimpleOverride(value, kind)
    local text = noctalia.string.trim(tostring(value or ""))
    if text == "" then
        return ""
    end

    local maximum = if kind == "model" then 200 else 128
    local pattern = if kind == "model" then "^[%w%._%+%-%/]+$" else "^[%w%._%-]+$"
    if #text > maximum or text:match(pattern) == nil then
        return nil
    end
    return text
end

local function triStateFlag(value, enabledFlag, disabledFlag)
    if value == nil or value == "" or value == "inherit" then
        return "", true
    elseif value == "on" then
        return enabledFlag, true
    elseif value == "off" then
        return disabledFlag, true
    end
    return "", false
end

local function buildStartOverrides(payload)
    local supplied = type(payload) == "table" and type(payload.overrides) == "table"
    if not supplied then
        return {}, {
            active = false,
            output = "inherit",
            file = "",
            model = "",
            profile = "",
            stop_flag = "",
        }
    end
    if cfg("enable_one_shot_overrides") ~= true then
        return nil, noctalia.tr("errors.overrides_disabled")
    end

    local overrides = payload.overrides
    local output = tostring(overrides.output or "inherit")
    local outputFlags = {
        inherit = "",
        type = "--type",
        clipboard = "--clipboard",
        paste = "--paste",
        file = "--file",
    }
    if outputFlags[output] == nil then
        return nil, noctalia.tr("errors.invalid_output")
    end

    local flags = {}
    local filePath = ""
    local stopFlag = ""
    if output == "file" then
        local configuredPath = noctalia.string.trim(tostring(overrides.file_path or ""))
        if configuredPath == "" or #configuredPath > 4096 or configuredPath:find("[%c]") ~= nil then
            return nil, noctalia.tr("errors.invalid_file")
        end
        if configuredPath:sub(1, 1) ~= "/" and configuredPath:sub(1, 2) ~= "~/" then
            return nil, noctalia.tr("errors.absolute_file")
        end
        filePath = noctalia.expandPath(configuredPath)
        if filePath:sub(1, 1) ~= "/" then
            return nil, noctalia.tr("errors.absolute_file")
        end
        table.insert(flags, shellQuote("--file=" .. filePath))
    elseif output ~= "inherit" then
        table.insert(flags, outputFlags[output])
        stopFlag = outputFlags[output]
    end

    local model = validateSimpleOverride(overrides.model, "model")
    if model == nil then
        return nil, noctalia.tr("errors.invalid_model")
    elseif model ~= "" then
        table.insert(flags, "--model")
        table.insert(flags, shellQuote(model))
    end

    local profile = validateSimpleOverride(overrides.profile, "profile")
    if profile == nil then
        return nil, noctalia.tr("errors.invalid_profile")
    elseif profile ~= "" then
        table.insert(flags, "--profile")
        table.insert(flags, shellQuote(profile))
    end

    local triStates = {
        { overrides.auto_submit, "--auto-submit", "--no-auto-submit" },
        { overrides.shift_enter_newlines, "--shift-enter-newlines", "--no-shift-enter-newlines" },
        { overrides.smart_auto_submit, "--smart-auto-submit", "--no-smart-auto-submit" },
    }
    for _, item in ipairs(triStates) do
        local flag, valid = triStateFlag(item[1], item[2], item[3])
        if not valid then
            return nil, noctalia.tr("errors.invalid_tristate")
        end
        if flag ~= "" then
            table.insert(flags, flag)
        end
    end

    return flags,
        {
            active = #flags > 0,
            output = output,
            file = filePath,
            model = model,
            profile = profile,
            stop_flag = stopFlag,
        }
end

local function applyStartedOverride(override)
    current.override_active = override.active == true
    current.override_output = tostring(override.output or "inherit")
    current.override_file = tostring(override.file or "")
    current.override_model = tostring(override.model or "")
    current.override_profile = tostring(override.profile or "")
    activeStopFlag = tostring(override.stop_flag or "")
end

local function runControl(command, action, startedOverride)
    actionPending = true
    current.pending_action = action
    current.last_error = ""
    publish()

    local accepted = noctalia.runAsync(command, function(result)
        actionPending = false
        current.pending_action = ""
        current.last_action = action

        if result.timedOut then
            setFailure(noctalia.tr("errors.action_timeout"), true)
            return
        end
        if result.exitCode ~= 0 then
            local detail = cleanText(result.stderr, 240)
            if detail == "" then
                detail = noctalia.tr("errors.action_exit", { code = result.exitCode })
            end
            setFailure(detail, true)
            return
        end

        current.last_error = ""
        if action == "start" and type(startedOverride) == "table" then
            applyStartedOverride(startedOverride)
        end
        publish()
    end, 15000)

    if not accepted then
        actionPending = false
        current.pending_action = ""
        setFailure(noctalia.tr("errors.action_not_launched"), true)
    end
end

local function startRecording(payload)
    local allowed, reason = stateAllows("start")
    if not allowed then
        setFailure(reason, true)
        return
    end

    local flags, overrideOrError = buildStartOverrides(payload)
    if flags == nil then
        setFailure(overrideOrError, true)
        return
    end
    local command = "voxtype record start"
    if #flags > 0 then
        command ..= " " .. table.concat(flags, " ")
    end
    runControl(command, "start", overrideOrError)
end

local function stopRecording()
    local allowed, reason = stateAllows("stop")
    if not allowed then
        setFailure(reason, true)
        return
    end
    local command = "voxtype record stop"
    if activeStopFlag ~= "" then
        command ..= " " .. activeStopFlag
    end
    runControl(command, "stop", nil)
end

local function cancelRecording()
    local allowed, reason = stateAllows("cancel")
    if not allowed then
        setFailure(reason, true)
        return
    end
    runControl("voxtype record cancel", "cancel", nil)
end

local function joinStringArray(value)
    if type(value) ~= "table" then
        return ""
    end
    local items = {}
    for _, item in ipairs(value) do
        table.insert(items, cleanText(item, 100))
    end
    return table.concat(items, ", ")
end

local function runDiagnostics()
    if diagnosticsPending then
        return
    end
    if not current.available then
        setFailure(noctalia.tr("errors.missing_voxtype"), true)
        return
    end

    diagnosticsPending = true
    local remaining = 2
    local versionResult = nil
    local variantsResult = nil
    noctalia.state.set(DIAGNOSTICS_KEY, { pending = true, error = "" })

    local function finish()
        remaining -= 1
        if remaining > 0 then
            return
        end

        diagnosticsPending = false
        local errorMessage = ""
        local version = ""
        local variants = nil
        if type(versionResult) ~= "table" or versionResult.timedOut or versionResult.exitCode ~= 0 then
            errorMessage = noctalia.tr("errors.version_diagnostics")
        else
            version = cleanText(versionResult.stdout, 120)
        end
        if type(variantsResult) ~= "table" or variantsResult.timedOut or variantsResult.exitCode ~= 0 then
            errorMessage = noctalia.tr("errors.variant_diagnostics")
        else
            variants = noctalia.json.decode(variantsResult.stdout)
            if type(variants) ~= "table" then
                errorMessage = noctalia.tr("errors.variant_diagnostics")
            end
        end

        if errorMessage ~= "" then
            noctalia.state.set(DIAGNOSTICS_KEY, { pending = false, error = errorMessage })
            notifyFailure(errorMessage)
            return
        end

        local cpu = if type(variants.cpu) == "table" then variants.cpu else {}
        local gpus = if type(variants.gpus) == "table" then variants.gpus else {}
        local recommendation = if type(variants.recommendation) == "table" then variants.recommendation else {}
        noctalia.state.set(DIAGNOSTICS_KEY, {
            pending = false,
            error = "",
            collected_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S"),
            version = version,
            install_kind = cleanText(variants.install_kind, 80),
            active_variant = cleanText(variants.active_variant, 120),
            compiled_features = joinStringArray(variants.compiled_features),
            cpu_avx2 = cpu.avx2 == true,
            cpu_avx512 = cpu.avx512 == true,
            gpu_nvidia = gpus.nvidia == true,
            gpu_amd = gpus.amd == true,
            recommendation_primary = cleanText(recommendation.primary, 120),
            recommendation_whisper = cleanText(recommendation.whisper, 120),
            recommendation_onnx = cleanText(recommendation.onnx, 120),
        })
    end

    if
        not noctalia.runAsync("voxtype --version", function(result)
            versionResult = result
            finish()
        end, 15000)
    then
        versionResult = { exitCode = 1, timedOut = false }
        finish()
    end

    if
        not noctalia.runAsync("voxtype info variants --json", function(result)
            variantsResult = result
            finish()
        end, 30000)
    then
        variantsResult = { exitCode = 1, timedOut = false }
        finish()
    end
end

local function dispatchCommand(command)
    local action = tostring(command.action or "")
    if action == "diagnose" then
        runDiagnostics()
        return
    end
    if actionPending then
        setFailure(noctalia.tr("errors.action_pending"), true)
        return
    end

    if action == "toggle" then
        if current.state == "idle" then
            startRecording(nil)
        elseif RECORDING_STATES[current.state] then
            stopRecording()
        else
            setFailure(noctalia.tr("errors.toggle_unavailable"), true)
        end
    elseif action == "start" then
        startRecording(command)
    elseif action == "stop" then
        stopRecording()
    elseif action == "cancel" then
        cancelRecording()
    else
        setFailure(noctalia.tr("errors.unknown_action", { action = action }), true)
    end
end

local function handleCommand(command)
    if type(command) ~= "table" then
        return
    end
    local commandSequence = tonumber(command.sequence) or 0
    if commandSequence <= lastCommandSequence then
        return
    end
    lastCommandSequence = commandSequence
    noctalia.state.set(COMMAND_ACK_KEY, { sequence = commandSequence })
    dispatchCommand(command)
end

local function startFollower()
    if not noctalia.commandExists("voxtype") then
        current.state = "stopped"
        current.raw_state = "missing"
        current.available = false
        current.follower_active = false
        setFailure(noctalia.tr("errors.missing_voxtype"), false)
        return
    end

    current.available = true
    local accepted = noctalia.runStream(FOLLOW_COMMAND, applyStatusLine)
    current.follower_active = accepted
    if not accepted then
        current.state = "unknown"
        current.raw_state = "listener-failed"
        setFailure(noctalia.tr("errors.listener_not_started"), true)
        return
    end
    publish()
end

-- A hot reload cancels this entry's async subprocesses, so callbacks from an
-- in-flight diagnostic pair may never clear their shared pending marker. Keep
-- completed results, but turn that stale marker into an explicit retryable
-- outcome before the replacement service advertises readiness.
local previousDiagnostics = noctalia.state.get(DIAGNOSTICS_KEY)
if type(previousDiagnostics) ~= "table" then
    noctalia.state.set(DIAGNOSTICS_KEY, { pending = false, error = "" })
elseif previousDiagnostics.pending == true then
    noctalia.state.set(DIAGNOSTICS_KEY, {
        pending = false,
        error = noctalia.tr("errors.diagnostics_interrupted"),
    })
end

-- Reset the handshake before installing the command watch so clients never race
-- a command into an unowned channel during a service reload.
noctalia.state.set(READY_KEY, false)
local previousAck = noctalia.state.get(COMMAND_ACK_KEY)
if type(previousAck) == "table" then
    lastCommandSequence = tonumber(previousAck.sequence) or 0
end
noctalia.state.watch(COMMAND_KEY, handleCommand)
-- State watches do not replay a value that landed while the previous service
-- watcher was being torn down. Read the channel after registration and handle
-- only a sequence the persistent in-memory acknowledgement has not consumed.
handleCommand(noctalia.state.get(COMMAND_KEY))
noctalia.setUpdateInterval(1000)
startFollower()
noctalia.state.set(READY_KEY, true)

function update()
    -- This tick only republishes the local elapsed-time anchor. VoxType state is
    -- event-driven by the single follower above; it is never polled here.
    if RECORDING_STATES[current.state] then
        publish()
    end
end

function onConfigChanged()
    -- No settings change requires replacing the follower; republish so every
    -- client immediately re-evaluates its presentation/notification policy.
    publish()
end

function onExit(_signal, _reason)
    -- The host terminates this entry's runStream process on reload/disable. Do
    -- not touch the independently managed VoxType daemon during teardown.
    noctalia.state.set(READY_KEY, false)
end

function onIpc(event, _payload)
    if event == "status" then
        publish()
        return
    end
    if event ~= "toggle" and event ~= "start" and event ~= "stop" and event ~= "cancel" and event ~= "diagnose" then
        noctalia.log("nocvox service: unknown command '" .. tostring(event) .. "'")
        return
    end
    -- Direct plugin IPC is not a producer on the shared state channel. Keep it
    -- out of channel acknowledgement accounting so the next widget/panel
    -- sequence cannot be mistaken for an already-consumed command.
    dispatchCommand({
        action = event,
        producer = "ipc",
    })
end

--!nonstrict
-- Wallpaper Director Hub service.
--
-- This phase routes native and provider panel actions. It deliberately does
-- not own wallpaper processes, read provider-private state, suppress Noctalia's
-- wallpaper surface, capture live scenes, or schedule reels.

local CONFIG_SCHEMA = 1
local RUNTIME_SCHEMA = 1
local PROBE_INTERVAL_MS = 30000
local NOTIFY_COOLDOWN_SECONDS = 10

local STATUS_KEY = "director_status"
local COMMAND_KEY = "director_command"
local COMMAND_ACK_KEY = "director_command_ack"

local WALLHAVEN_ID = "noctalia/wallhaven"
local W_ENGINE_ID = "tadomika_ari/w-engine"

local OPEN_TARGETS = {
    native_open = "wallpaper",
    wallhaven_open = "noctalia/wallhaven:browser",
    w_engine_open = "tadomika_ari/w-engine:w-engine-panel",
    director_open = "goober/wallpaper-director:director",
}

local NATIVE_SWITCH_VERBS = {
    native_next = "wallpaper-next",
    native_previous = "wallpaper-previous",
    native_random = "wallpaper-random",
}

local VALID_ACTIONS = {
    native_open = true,
    native_next = true,
    native_previous = true,
    native_random = true,
    wallhaven_open = true,
    w_engine_open = true,
    director_open = true,
    no_action = true,
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
    observed_at = "",
    last_error = "",
}

local configValid = true
local runtimeValid = true
local configError = ""
local runtimeError = ""
local lastActionError = ""
local lastActionAt = ""
local statusSequence = 0
local probeInFlight = false
local providerSignature = ""
local providers = {
    probing = true,
    probe_ok = false,
    probe_error = "",
    probed_at = "",
    noctalia_cli = noctalia.commandExists("noctalia"),
    native = { available = true },
    wallhaven = { plugin_enabled = false, available = false },
    w_engine = {
        plugin_enabled = false,
        command_available = noctalia.commandExists("linux-wallpaperengine"),
        available = false,
    },
}
local lastNotificationAt = {}
local lastCommandSequence = 0

-- Clear readiness before installing the command watch. Clients queue their
-- gesture locally while a service hot reload is in progress.
noctalia.state.set(STATUS_KEY, { ready = false })

local function nowSeconds()
    return tonumber(noctalia.formatTime("%s")) or 0
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

    return {
        schema_version = CONFIG_SCHEMA,
        gestures = gestures,
    }, nil
end

local function validateRuntime(candidate)
    if type(candidate) ~= "table" then
        return nil, noctalia.tr("errors.runtime_not_object")
    end
    if tonumber(candidate.schema_version) ~= RUNTIME_SCHEMA then
        return nil, noctalia.tr("errors.runtime_schema", { version = tostring(candidate.schema_version or "?") })
    end
    if type(candidate.providers) ~= "table" then
        return nil, noctalia.tr("errors.runtime_providers")
    end
    return {
        schema_version = RUNTIME_SCHEMA,
        providers = candidate.providers,
        observed_at = tostring(candidate.observed_at or ""),
        last_error = tostring(candidate.last_error or ""),
    },
        nil
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

    local hadCurrent = noctalia.fileExists(path)
    if hadCurrent then
        -- Copy the last-known-good primary into a temporary backup, then
        -- atomically replace the old backup. The primary remains in place until
        -- the final temporary-to-primary rename, so a crash never leaves only
        -- defaults eligible to be recreated on the next load.
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
        if not saved then
            return nil, saveError
        end
        return defaults, nil
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

    local loadedRuntime, loadedRuntimeError = loadJsonFile("runtime.json", validateRuntime, runtime)
    if loadedRuntime == nil then
        runtimeValid = false
        runtimeError = tostring(loadedRuntimeError or noctalia.tr("errors.runtime_invalid"))
    else
        runtime = loadedRuntime
    end
end

local function statusSnapshot()
    statusSequence += 1
    return {
        protocol = 1,
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
        },
        providers = providers,
        last_action_error = lastActionError,
        last_action_at = lastActionAt,
    }
end

local function publishStatus()
    noctalia.state.set(STATUS_KEY, statusSnapshot())
end

local function setActionError(message)
    lastActionError = tostring(message or "")
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishStatus()
end

local function notifyBounded(key, message)
    local now = nowSeconds()
    local previous = tonumber(lastNotificationAt[key]) or 0
    if now == 0 or previous == 0 or now - previous >= NOTIFY_COOLDOWN_SECONDS then
        lastNotificationAt[key] = now
        noctalia.notifyError(noctalia.tr("plugin.title"), message)
    end
end

local function parseEnabledPlugins(output)
    local enabled = {}
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local id = line:match("^(%S+)")
        local framed = " " .. line .. " "
        if id ~= nil and framed:find(" enabled ", 1, true) ~= nil and framed:find(" incompatible ", 1, true) == nil then
            enabled[id] = true
        end
    end
    return enabled
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

local function currentProviderSignature()
    return table.concat({
        tostring(providers.probe_ok),
        tostring(providers.probe_error),
        tostring(providers.noctalia_cli),
        tostring(providers.wallhaven.plugin_enabled),
        tostring(providers.w_engine.plugin_enabled),
        tostring(providers.w_engine.command_available),
    }, "|")
end

local function persistRuntimeIfChanged()
    -- A corrupt file is evidence, not permission to replace it. Leave it and
    -- its backup untouched until the user deliberately repairs/removes it.
    if not runtimeValid then
        return
    end
    local signature = currentProviderSignature()
    if signature == providerSignature then
        return
    end
    providerSignature = signature

    local nextRuntime = {
        schema_version = RUNTIME_SCHEMA,
        providers = {
            probe_ok = providers.probe_ok,
            probe_error = providers.probe_error,
            noctalia_cli = providers.noctalia_cli,
            wallhaven_enabled = providers.wallhaven.plugin_enabled,
            w_engine_enabled = providers.w_engine.plugin_enabled,
            linux_wallpaperengine = providers.w_engine.command_available,
        },
        observed_at = providers.probed_at,
        last_error = providers.probe_error,
    }
    local saved, saveError = atomicWrite("runtime.json", nextRuntime)
    if saved then
        runtime = nextRuntime
    else
        runtimeValid = false
        runtimeError = tostring(saveError or noctalia.tr("errors.runtime_save"))
    end
end

local function completeProbe(enabled, probeError)
    probeInFlight = false
    providers.probing = false
    providers.probe_ok = probeError == nil
    providers.probe_error = tostring(probeError or "")
    providers.probed_at = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    providers.noctalia_cli = noctalia.commandExists("noctalia")
    providers.native = { available = true }

    local pluginList = type(enabled) == "table" and enabled or {}
    local wallhavenEnabled = pluginList[WALLHAVEN_ID] == true
    local wEngineEnabled = pluginList[W_ENGINE_ID] == true
    local rendererAvailable = noctalia.commandExists("linux-wallpaperengine")
    providers.wallhaven = {
        plugin_enabled = wallhavenEnabled,
        available = probeError == nil and wallhavenEnabled,
    }
    providers.w_engine = {
        plugin_enabled = wEngineEnabled,
        command_available = rendererAvailable,
        available = probeError == nil and wEngineEnabled and rendererAvailable,
    }

    persistRuntimeIfChanged()
    publishStatus()
end

local function probeProviders()
    if probeInFlight then
        return
    end
    probeInFlight = true
    providers.probing = true
    publishStatus()

    if not noctalia.commandExists("noctalia") then
        completeProbe(nil, noctalia.tr("errors.noctalia_cli"))
        return
    end

    local started = noctalia.runAsync("noctalia msg plugins list", function(result)
        if type(result) ~= "table" then
            completeProbe(nil, noctalia.tr("errors.provider_probe"))
            return
        end
        if result.timedOut then
            completeProbe(nil, noctalia.tr("errors.provider_probe_timeout"))
            return
        end
        if tonumber(result.exitCode) ~= 0 then
            local detail = commandFailureDetail(result)
            completeProbe(nil, noctalia.tr("errors.provider_probe_detail", { detail = detail }))
            return
        end
        completeProbe(parseEnabledPlugins(result.stdout), nil)
    end, 5000)

    if not started then
        completeProbe(nil, noctalia.tr("errors.provider_probe_start"))
    end
end

local function actionAvailability(action)
    if action == "native_open" or action == "director_open" or action == "no_action" then
        return true, ""
    end
    if NATIVE_SWITCH_VERBS[action] ~= nil then
        if providers.noctalia_cli then
            return true, ""
        end
        return false, noctalia.tr("availability.native_cli")
    end
    if action == "wallhaven_open" then
        if providers.wallhaven.available then
            return true, ""
        end
        if not providers.probe_ok then
            return false, noctalia.tr("availability.probe_failed")
        end
        return false, noctalia.tr("availability.wallhaven")
    end
    if action == "w_engine_open" then
        if providers.w_engine.available then
            return true, ""
        end
        if not providers.probe_ok then
            return false, noctalia.tr("availability.probe_failed")
        end
        if not providers.w_engine.plugin_enabled then
            return false, noctalia.tr("availability.w_engine_plugin")
        end
        return false, noctalia.tr("availability.w_engine_command")
    end
    return false, noctalia.tr("availability.unknown")
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

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function runNativeSwitch(request, action)
    local verb = NATIVE_SWITCH_VERBS[action]
    local output = knownOutputName(request.output)
    local command = "noctalia msg " .. verb
    if output ~= nil then
        command ..= " " .. shellQuote(output)
    end

    local started = noctalia.runAsync(command, function(result)
        if type(result) ~= "table" or result.timedOut or tonumber(result.exitCode) ~= 0 then
            local detail = commandFailureDetail(result)
            local message = noctalia.tr("errors.native_switch", { detail = detail })
            setActionError(message)
            notifyBounded(action, message)
            return
        end
        lastActionError = ""
        lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
        publishStatus()
    end, 5000)

    if not started then
        local message = noctalia.tr("errors.native_switch_start")
        setActionError(message)
        notifyBounded(action, message)
    end
end

local function dispatchAction(request, action)
    if not configValid or not runtimeValid then
        local message = noctalia.tr("errors.storage_disabled")
        notifyBounded("storage", message)
        return
    end
    if not VALID_ACTIONS[action] then
        local message = noctalia.tr("availability.unknown")
        notifyBounded("unknown", message)
        return
    end

    local available, unavailableReason = actionAvailability(action)
    if not available then
        local message = noctalia.tr("errors.action_unavailable", {
            action = action,
            reason = unavailableReason,
        })
        setActionError(message)
        notifyBounded(action, message)
        return
    end

    if action == "no_action" then
        return
    end
    if NATIVE_SWITCH_VERBS[action] ~= nil then
        runNativeSwitch(request, action)
        return
    end

    lastActionError = ""
    lastActionAt = noctalia.formatTime("%Y-%m-%d %H:%M:%S")
    publishStatus()
    -- Bar/shortcut clients execute available panel opens directly so Noctalia
    -- retains their caller geometry. External IPC has no widget caller and is
    -- therefore safely dispatched by the service itself.
    if tostring(request.producer or "") == "ipc" then
        local target = OPEN_TARGETS[action]
        if target ~= nil then
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
        local button = tostring(request.button or "")
        local gestures = type(config.gestures) == "table" and config.gestures or {}
        dispatchAction(request, tostring(gestures[button] or ""))
    elseif kind == "action" then
        dispatchAction(request, tostring(request.action or ""))
    elseif kind == "set_mapping" then
        setMapping(tostring(request.button or ""), tostring(request.action or ""))
    elseif kind == "probe" then
        probeProviders()
    end
end

function update()
    noctalia.setUpdateInterval(PROBE_INTERVAL_MS)
    probeProviders()
end

function onIpc(event, payload)
    if event == "status" or event == "probe" then
        probeProviders()
    elseif event == "gesture" then
        local button = tostring(payload or "")
        local gestures = type(config.gestures) == "table" and config.gestures or {}
        dispatchAction(
            { sequence = nowSeconds(), producer = "ipc", output = noctalia.focusedOutputName() },
            tostring(gestures[button] or "")
        )
    elseif event == "next" or event == "previous" or event == "random" then
        dispatchAction(
            { sequence = nowSeconds(), producer = "ipc", output = noctalia.focusedOutputName() },
            "native_" .. event
        )
    elseif event == "open-provider" then
        local requested = tostring(payload or "")
        local aliases = {
            native = "native_open",
            wallhaven = "wallhaven_open",
            w_engine = "w_engine_open",
            director = "director_open",
        }
        dispatchAction({ sequence = nowSeconds(), producer = "ipc" }, aliases[requested] or "")
    else
        noctalia.log("wallpaper-director: unknown IPC event '" .. tostring(event) .. "'")
    end
end

loadStorage()
local previousAck = noctalia.state.get(COMMAND_ACK_KEY)
if type(previousAck) == "table" then
    lastCommandSequence = tonumber(previousAck.sequence) or 0
end
noctalia.state.watch(COMMAND_KEY, handleCommand)
-- A command can land after the old watcher is torn down but before this one is
-- installed. Replaying the current channel after registration closes that gap;
-- the acknowledged sequence prevents an already handled command from running
-- twice.
handleCommand(noctalia.state.get(COMMAND_KEY))
publishStatus()
probeProviders()

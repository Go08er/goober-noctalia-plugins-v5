--!nonstrict
-- Singleton, bounded control client for the standalone Wall-in-One app.
--
-- The app owns the Unix socket and all wallpaper policy. This entry only
-- starts the long-lived service, invokes its short-lived `ctl` client, and
-- publishes compact state for the widget and panel.

local STATE_KEY = "wall_in_one_state"
local MENU_KEY = "wall_in_one_menu"
local COMMAND_KEY = "wall_in_one_command"
local READY_KEY = "wall_in_one_ready"
local PROTOCOL = 3
local STATUS_VERSION = 2
-- wall_in_one.control.client.EXIT_NOT_RUNNING
local EXIT_NOT_RUNNING = 3
-- Runtime actions reply only after all bounded desktop helpers and renderer
-- handovers finish. Three-display operations can legitimately exceed 8s;
-- Noctalia clamps callback timeouts at 60s and the app's ctl client uses 45s.
local CALL_TIMEOUT_MS = 55000
local STARTUP_CALL_TIMEOUT_MS = 1500
local SYSTEMD_QUERY_TIMEOUT_MS = 3000
local STARTUP_PREPARE_TIMEOUT_MS = 55000
local STARTUP_POLL_MS = 250
local STARTUP_TIMEOUT_SECONDS = 60
local QUEUE_LIMIT = 8
local SYSTEMD_LOAD_STATE = "systemctl --user show wall-in-one.service --property=LoadState --value"
local SYSTEMD_START = "systemctl --user start wall-in-one.service"
local VERBS = {
    launch = true,
    ["open-app"] = true,
    status = true,
    ["playlist-use"] = true,
    ["schedule-follow"] = true,
    play = true,
    pause = true,
    stop = true,
    toggle = true,
    shuffle = true,
    cycle = true,
    next = true,
    previous = true,
    random = true,
    ["health-sync"] = true,
}

local queue = {}
local busy = false
local sequence = 0
local menuSequence = 0
local lastLogged = ""
local launching = false
local startupDeadline = 0
local pendingAfterLaunch = nil
local invoke, pump, applyInterval, launchDirect, enqueue

-- A widget can load before this service does. Clear the handshake so early
-- clicks queue instead of vanishing.
noctalia.state.set(READY_KEY, false)

local function cfg(key)
    return noctalia.getConfig(key)
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function configuredOverride()
    return noctalia.string.trim(tostring(cfg("binary_path") or ""))
end

local function binary()
    local override = configuredOverride()
    if override ~= "" then
        local expanded = tostring(noctalia.expandPath(override) or override)
        return if noctalia.fileExists(expanded) then expanded else nil
    end
    return if noctalia.commandExists("wall-in-one") then "wall-in-one" else nil
end

local function publish(state)
    sequence += 1
    noctalia.state.set(STATE_KEY, {
        protocol = PROTOCOL,
        sequence = sequence,
        running = state.running == true,
        launching = state.launching == true,
        showing = tostring(state.showing or ""),
        playlist = tostring(state.playlist or ""),
        source = tostring(state.source or ""),
        entryId = tostring(state.entryId or ""),
        kind = tostring(state.kind or ""),
        still = tostring(state.still or ""),
        playbackState = tostring(state.playbackState or ""),
        paused = state.paused == true,
        stopped = state.stopped == true,
        shuffle = state.shuffle == true,
        cycleEnabled = state.cycleEnabled == true,
        cycleDefault = state.cycleDefault == true,
        cycleSource = tostring(state.cycleSource or ""),
        motionActive = state.motionActive == true,
        powerSource = tostring(state.powerSource or "unknown"),
        powerAvailable = state.powerAvailable == true,
        stopAnimationsOnBattery = state.stopAnimationsOnBattery == true,
        animationsInhibited = state.animationsInhibited == true,
        animationInhibitionReason = tostring(state.animationInhibitionReason or ""),
        runtimeError = tostring(state.runtimeError or ""),
        error = tostring(state.error or ""),
    })
end

local function publishMenu(snapshot, errorMessage)
    menuSequence += 1
    local source = if type(snapshot) == "table" then snapshot else {}
    noctalia.state.set(MENU_KEY, {
        protocol = PROTOCOL,
        sequence = menuSequence,
        playlists = if type(source.playlists) == "table" then source.playlists else {},
        schedule = if type(source.schedule) == "table" then source.schedule else {},
        schedules = if type(source.schedules) == "table" then source.schedules else {},
        displays = if type(source.displays) == "table" then source.displays else {},
        error = tostring(errorMessage or ""),
    })
end

-- Not-running is the expected resting state, not a fault, so it is published
-- with an empty error and never logged.
local function publishStopped(message)
    local detail = tostring(message or "")
    if detail ~= "" and detail ~= lastLogged then
        lastLogged = detail
        noctalia.log("wall-in-one: " .. detail)
    elseif detail == "" then
        lastLogged = ""
    end
    publish({ error = detail })
    -- Inventory is usable only alongside a successful status snapshot. Clear
    -- it for every stopped/error path, including preflight and timeout errors.
    publishMenu(nil, detail)
end

-- Rust returns one fully self-consistent JSON snapshot. Publishing its
-- inventory as part of this same operation means the panel never combines a
-- playlist list, schedule, and display state observed at different instants.
local function publishStatus(line)
    local snapshot, decodeError = noctalia.json.decode(line)
    if type(snapshot) ~= "table" then
        local detail = noctalia.tr("state.invalid_status", {
            error = tostring(decodeError or "unknown JSON error"),
        })
        publishStopped(detail)
        return false
    end
    if snapshot.status_version ~= STATUS_VERSION then
        local detail = noctalia.tr("state.invalid_status", {
            error = "unsupported status version " .. tostring(snapshot.status_version),
        })
        publishStopped(detail)
        return false
    end

    local playlist = tostring(snapshot.playlist or "")
    lastLogged = ""
    publish({
        running = true,
        launching = false,
        showing = playlist,
        playlist = playlist,
        source = tostring(snapshot.source or ""),
        entryId = tostring(snapshot.entry_id or ""),
        kind = tostring(snapshot.kind or ""),
        still = tostring(snapshot.still or ""),
        playbackState = tostring(snapshot.playback_state or ""),
        paused = snapshot.paused == true,
        stopped = snapshot.stopped == true,
        shuffle = snapshot.shuffle == true,
        cycleEnabled = snapshot.cycle_enabled == true,
        cycleDefault = snapshot.cycle_default == true,
        cycleSource = tostring(snapshot.cycle_source or ""),
        motionActive = snapshot.motion_active == true,
        powerSource = tostring(snapshot.power_source or "unknown"),
        powerAvailable = snapshot.power_available == true,
        stopAnimationsOnBattery = snapshot.stop_animations_on_battery == true,
        animationsInhibited = snapshot.animations_inhibited == true,
        animationInhibitionReason = tostring(snapshot.animation_inhibition_reason or ""),
        runtimeError = tostring(snapshot.last_error or ""),
        error = "",
    })
    publishMenu(snapshot, "")

    -- The packaged systemd timer owns this hand-off normally. Direct runtime
    -- fallback installations have no timer, so consume only visible
    -- session-only findings here. Durable entries must not trigger a loop.
    if type(snapshot.taboo_entries) == "table" then
        for _, report in ipairs(snapshot.taboo_entries) do
            if type(report) == "table" and report.durable ~= true then
                enqueue("health-sync", nil, false)
                break
            end
        end
    end
    return true
end

enqueue = function(verb, argument, allowLaunch)
    if VERBS[verb] ~= true then
        noctalia.log("wall-in-one: unknown control verb '" .. tostring(verb) .. "'")
        return
    end
    -- Opening the configuration window must work even while startup is
    -- awaiting migration/root selection or a slow user-unit preflight.
    if verb == "open-app" then
        invoke({ verb = verb, argument = argument, allowLaunch = false })
        return
    end
    if verb == "status" or verb == "health-sync" then
        for _, job in ipairs(queue) do
            if job.verb == verb then
                return
            end
        end
    end
    if #queue >= QUEUE_LIMIT then
        return
    end
    table.insert(queue, {
        verb = verb,
        argument = argument,
        allowLaunch = if allowLaunch == nil
            then verb ~= "status" and verb ~= "open-app" and verb ~= "launch"
            else allowLaunch == true,
    })
    pump()
end

local function configuredIntervalMs()
    local seconds = math.max(5, math.min(300, tonumber(cfg("refresh_interval_seconds")) or 15))
    return seconds * 1000
end

applyInterval = function()
    noctalia.setUpdateInterval(if launching then STARTUP_POLL_MS else configuredIntervalMs())
end

local function clearLaunch()
    launching = false
    startupDeadline = 0
    pendingAfterLaunch = nil
    applyInterval()
end

local function stopLaunch(message)
    table.clear(queue)
    clearLaunch()
    publishStopped(message)
end

-- The standalone Rust runtime is what should be started when there is no user
-- unit to own the lifetime. The Python compatibility service cannot provide
-- the atomic inventory this panel requires, so this plugin does not start it.
local function runtimeBinary(command)
    -- An override names the application; the runtime sits beside it in the
    -- same bin directory, so derive rather than search a PATH the override
    -- was chosen precisely to bypass.
    local sibling = string.gsub(command, "wall%-in%-one$", "wall-in-one-service")
    if sibling ~= command and noctalia.fileExists(sibling) then
        return sibling
    end
    if noctalia.commandExists("wall-in-one-service") then
        return "wall-in-one-service"
    end
    return nil
end

local function startupStep(command, timeout, nextStep, timeoutKey)
    busy = true
    local accepted = noctalia.runAsync(command, function(result)
        busy = false
        if result.timedOut then
            stopLaunch(noctalia.tr(timeoutKey or "state.startup_timed_out"))
        elseif result.exitCode ~= 0 then
            local detail = noctalia.string.trim(tostring(result.stderr or ""))
            stopLaunch(if detail ~= "" then detail else noctalia.tr("state.launch_failed"))
        else
            nextStep(result)
        end
        pump()
    end, timeout)
    if not accepted then
        busy = false
        stopLaunch(noctalia.tr("state.failed"))
    end
end

launchDirect = function(command)
    local runtime = runtimeBinary(command)
    if runtime == nil then
        stopLaunch(noctalia.tr("state.missing_runtime"))
        return
    end
    -- Match the packaged unit's migration and validation boundary before
    -- launching a detached runtime. --wait-for-config alone cannot migrate an
    -- existing runtime document and must never bypass a rejected preflight.
    startupStep(shellQuote(command) .. " --service-startup-prepare", STARTUP_PREPARE_TIMEOUT_MS, function()
        startupStep(shellQuote(runtime) .. " --check-config", SYSTEMD_QUERY_TIMEOUT_MS, function()
            if not noctalia.runAsync(shellQuote(runtime) .. " --wait-for-config") then
                stopLaunch(noctalia.tr("state.failed"))
                return
            end
            startupDeadline = os.time() + STARTUP_TIMEOUT_SECONDS
            enqueue("status", nil, false)
        end)
    end)
end

local function beginLaunch(replay)
    if launching then
        if pendingAfterLaunch == nil and replay ~= nil then
            pendingAfterLaunch = replay
        end
        return
    end

    local command = binary()
    if command == nil then
        table.clear(queue)
        publishStopped(noctalia.tr("state.missing_binary"))
        return
    end

    launching = true
    startupDeadline = os.time() + STARTUP_TIMEOUT_SECONDS
    pendingAfterLaunch = replay
    applyInterval()
    publish({ launching = true })

    -- Only an absent unit permits a direct fallback. A loaded/masked/broken
    -- unit or an unanswered query may represent an intentional migration or
    -- administrative boundary; never start a competing detached process.
    if configuredOverride() == "" and noctalia.commandExists("systemctl") then
        startupStep(SYSTEMD_LOAD_STATE, SYSTEMD_QUERY_TIMEOUT_MS, function(result)
            local loadState = noctalia.string.trim(tostring(result.stdout or ""))
            if loadState == "not-found" then
                launchDirect(command)
            elseif loadState == "loaded" then
                startupStep(SYSTEMD_START, STARTUP_PREPARE_TIMEOUT_MS, function()
                    startupDeadline = os.time() + STARTUP_TIMEOUT_SECONDS
                    enqueue("status", nil, false)
                end, "state.unit_start_timed_out")
            else
                stopLaunch(noctalia.tr("state.unit_unavailable", { state = loadState }))
            end
        end, "state.unit_query_timed_out")
        return
    end
    launchDirect(command)
end

local function finish(job, result)
    if result.timedOut then
        if launching then
            stopLaunch(noctalia.tr("state.launch_failed"))
        else
            publishStopped(noctalia.tr("state.timed_out"))
        end
    elseif result.exitCode == EXIT_NOT_RUNNING then
        if job.verb == "status" and launching then
            if os.time() >= startupDeadline then
                stopLaunch(noctalia.tr("state.launch_failed"))
            else
                publish({ launching = true })
            end
        elseif job.verb == "status" and job.allowLaunch then
            beginLaunch(nil)
        elseif job.allowLaunch then
            beginLaunch({ verb = job.verb, argument = job.argument })
        else
            publishStopped("")
        end
    elseif result.exitCode ~= 0 then
        local stderr = noctalia.string.trim(tostring(result.stderr or ""))
        local detail = if stderr ~= "" then stderr else noctalia.tr("state.failed")
        if launching then
            stopLaunch(detail)
        else
            publishStopped(detail)
        end
    elseif job.verb == "status" then
        local replay = pendingAfterLaunch
        clearLaunch()
        local accepted = publishStatus(noctalia.string.trim(tostring(result.stdout or "")))
        if accepted and replay ~= nil then
            enqueue(replay.verb, replay.argument, false)
        end
    else
        enqueue("status", nil, false)
    end
end

invoke = function(job)
    if job.verb == "launch" then
        beginLaunch(nil)
        return
    end

    local command = binary()
    if command == nil then
        table.clear(queue)
        publishStopped(noctalia.tr("state.missing_binary"))
        return
    end

    if job.verb == "open-app" then
        local parts = { shellQuote(command) }
        if job.argument ~= nil and job.argument ~= "" then
            table.insert(parts, "ctl")
            table.insert(parts, "open")
            table.insert(parts, shellQuote(job.argument))
        end
        if not noctalia.runAsync(table.concat(parts, " ")) then
            publishStopped(noctalia.tr("state.failed"))
        end
        return
    end

    local parts = { shellQuote(command) }
    if job.verb == "health-sync" then
        table.insert(parts, "--sync-runtime-health")
    else
        table.insert(parts, "ctl")
        table.insert(parts, job.verb)
        if job.argument ~= nil and job.argument ~= "" then
            table.insert(parts, shellQuote(job.argument))
        end
    end

    busy = true
    local started = noctalia.runAsync(table.concat(parts, " "), function(result)
        busy = false
        finish(job, result)
        pump()
    end, if launching and job.verb == "status" then STARTUP_CALL_TIMEOUT_MS else CALL_TIMEOUT_MS)
    if not started then
        busy = false
        publishStopped(noctalia.tr("state.failed"))
    end
end

pump = function()
    if busy or #queue == 0 then
        return
    end
    local job = table.remove(queue, 1)
    invoke(job)
end

function update()
    applyInterval()
    enqueue("status", nil, false)
end

function onConfigChanged()
    applyInterval()
    enqueue("status", nil, false)
end

function onIpc(event, payload)
    local verb = if event == "refresh" then "status" else tostring(event)
    local argument = if type(payload) == "table" then payload.argument else payload
    enqueue(verb, if argument ~= nil then tostring(argument) else nil)
end

function onExit(_signal)
    noctalia.state.set(READY_KEY, false)
end

noctalia.state.watch(COMMAND_KEY, function(command)
    if type(command) == "table" and type(command.verb) == "string" then
        enqueue(command.verb, if command.argument ~= nil then tostring(command.argument) else nil)
    end
end)

applyInterval()
publishStopped("")
noctalia.state.set(READY_KEY, true)
-- First ask the existing socket. Only a genuinely absent service is started;
-- the packaged systemd unit is preferred, with a detached Rust runtime
-- fallback for non-systemd installs.
enqueue("status", nil, true)

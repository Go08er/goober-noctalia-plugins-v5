--!nonstrict
-- Singleton control client for the Wall-in-One app.
--
-- The app owns a Unix socket at $XDG_RUNTIME_DIR/wall-in-one.sock speaking one
-- JSON object per line in each direction. `wall-in-one ctl <verb>` is the
-- app's own client for it, so no socket code lives here. The sole exception is
-- a detached plain-binary launch that starts or presents the GTK application.
--
-- The app is absent most of the time. `ctl` fails its connect immediately and
-- exits 3 in that case, so a poll against a dead socket is cheap and cannot
-- block. Every call also carries a host callback timeout as a second bound.

local STATE_KEY = "wall_in_one_state"
local COMMAND_KEY = "wall_in_one_command"
local READY_KEY = "wall_in_one_ready"
local PROTOCOL = 1
-- wall_in_one.control.client.EXIT_NOT_RUNNING
local EXIT_NOT_RUNNING = 3
local CALL_TIMEOUT_MS = 8000
local STARTUP_CALL_TIMEOUT_MS = 1500
local STARTUP_POLL_MS = 250
local STARTUP_TIMEOUT_SECONDS = 10
local QUEUE_LIMIT = 8
local VERBS = {
    launch = true,
    next = true,
    prev = true,
    random = true,
    shuffle = true,
    cycle = true,
    ["cycle-interval"] = true,
    dynamics = true,
    ["reload-palette"] = true,
    status = true,
}

local queue = {}
local busy = false
local sequence = 0
local lastLogged = ""
local launching = false
local startupDeadline = 0
local pendingAfterLaunch = nil
local invoke, pump, applyInterval

-- A widget can load before this service does. Clear the handshake so early
-- clicks queue instead of vanishing.
noctalia.state.set(READY_KEY, false)

local function cfg(key)
    return noctalia.getConfig(key)
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function binary()
    local override = noctalia.string.trim(tostring(cfg("binary_path") or ""))
    if override ~= "" then
        local expanded = tostring(noctalia.expandPath(override) or override)
        return if noctalia.fileExists(expanded) then expanded else nil
    end
    return if noctalia.commandExists("wall-in-one") then "wall-in-one" else nil
end

-- The one place the published shape is defined, so a caller only has to supply
-- what it actually knows. Everything else falls back to the stopped state.
local function publish(state)
    sequence += 1
    noctalia.state.set(STATE_KEY, {
        protocol = PROTOCOL,
        sequence = sequence,
        running = state.running == true,
        launching = state.launching == true,
        showing = tostring(state.showing or ""),
        playable = tonumber(state.playable) or 0,
        library = tonumber(state.library) or 0,
        shuffle = state.shuffle == true,
        cycle = state.cycle == true,
        interval = tonumber(state.interval) or 0,
        dynamics = state.dynamics == true,
        error = tostring(state.error or ""),
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
end

-- `status` answers with one line from Session.describe():
--   set foo.jpg; 3 of 5 playable; shuffle=on cycle=off cycle-interval=900 dynamics=on
local function publishStatus(line)
    local playable, library = line:match("(%d+) of (%d+) playable")
    lastLogged = ""
    publish({
        running = true,
        launching = false,
        showing = noctalia.string.trim(line:match("^(.-); %d+ of %d+ playable") or line),
        playable = tonumber(playable) or 0,
        library = tonumber(library) or 0,
        shuffle = line:match("shuffle=(%a+)") == "on",
        cycle = line:match("cycle=(%a+)") == "on",
        interval = tonumber(line:match("cycle%-interval=(%d+)")) or 0,
        dynamics = line:match("dynamics=(%a+)") == "on",
        error = "",
    })
end

local function enqueue(verb, argument, allowLaunch)
    if VERBS[verb] ~= true then
        noctalia.log("wall-in-one: unknown control verb '" .. tostring(verb) .. "'")
        return
    end
    if verb == "status" then
        -- Several placements can ask at once; one answer serves all of them.
        for _, job in ipairs(queue) do
            if job.verb == "status" then
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
        allowLaunch = if allowLaunch == nil then verb ~= "status" and verb ~= "launch" else allowLaunch == true,
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

    -- The no-callback runAsync overload is intentionally detached. The plain
    -- command starts (or presents) the long-lived GTK application; ctl calls
    -- below remain short-lived, captured subprocesses.
    if not noctalia.runAsync(shellQuote(command)) then
        table.clear(queue)
        publishStopped(noctalia.tr("state.failed"))
        return
    end

    launching = true
    startupDeadline = os.time() + STARTUP_TIMEOUT_SECONDS
    pendingAfterLaunch = replay
    applyInterval()
    publish({ launching = true })
    enqueue("status", nil, false)
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
        publishStatus(noctalia.string.trim(tostring(result.stdout or "")))
        if replay ~= nil then
            enqueue(replay.verb, replay.argument, false)
        end
    else
        -- Every other verb changes something the widget shows.
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
        -- Nothing queued behind this can run either; dropping it now stops a
        -- stale burst from firing minutes later when the binary reappears.
        table.clear(queue)
        publishStopped(noctalia.tr("state.missing_binary"))
        return
    end

    local parts = { shellQuote(command), "ctl", job.verb }
    if job.argument ~= nil and job.argument ~= "" then
        table.insert(parts, shellQuote(job.argument))
    end

    busy = true
    local launched = noctalia.runAsync(table.concat(parts, " "), function(result)
        busy = false
        finish(job, result)
        pump()
    end, if launching and job.verb == "status" then STARTUP_CALL_TIMEOUT_MS else CALL_TIMEOUT_MS)
    if not launched then
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
enqueue("status")

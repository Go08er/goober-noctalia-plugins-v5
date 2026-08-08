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
local PROTOCOL = 2
-- wall_in_one.control.client.EXIT_NOT_RUNNING
local EXIT_NOT_RUNNING = 3
local CALL_TIMEOUT_MS = 8000
local STARTUP_CALL_TIMEOUT_MS = 1500
local SYSTEMD_CALL_TIMEOUT_MS = 3000
local STARTUP_POLL_MS = 250
local STARTUP_TIMEOUT_SECONDS = 10
local QUEUE_LIMIT = 8
local SYSTEMD_START = "systemctl --user start wall-in-one.service"
local VERBS = {
    launch = true,
    ["open-app"] = true,
    status = true,
    playlists = true,
    ["playlist-use"] = true,
    schedule = true,
    displays = true,
    ["display-assign"] = true,
    ["display-clear"] = true,
}

local queue = {}
local busy = false
local sequence = 0
local menuSequence = 0
local lastLogged = ""
local launching = false
local startupDeadline = 0
local pendingAfterLaunch = nil
local playlistRows = {}
local scheduleState = { count = 0, default = "", rule = "", when = "" }
local displayRows = {}
local invoke, pump, applyInterval, launchDirect

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
        playable = tonumber(state.playable) or 0,
        library = tonumber(state.library) or 0,
        error = tostring(state.error or ""),
    })
end

local function publishMenu(errorMessage)
    menuSequence += 1
    local copiedPlaylists = {}
    for _, row in ipairs(playlistRows) do
        table.insert(copiedPlaylists, {
            name = row.name,
            entries = row.entries,
            active = row.active,
        })
    end
    local copiedDisplays = {}
    for _, row in ipairs(displayRows) do
        table.insert(copiedDisplays, {
            connector = row.connector,
            label = row.label,
            playlist = row.playlist,
        })
    end
    noctalia.state.set(MENU_KEY, {
        protocol = PROTOCOL,
        sequence = menuSequence,
        playlists = copiedPlaylists,
        schedule = {
            count = scheduleState.count,
            default = scheduleState.default,
            rule = scheduleState.rule,
            when = scheduleState.when,
        },
        displays = copiedDisplays,
        error = tostring(errorMessage or ""),
    })
end

local function clearMenu()
    playlistRows = {}
    scheduleState = { count = 0, default = "", rule = "", when = "" }
    displayRows = {}
    publishMenu("")
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

-- `status` answers with one line from Session.describe().
local function publishStatus(line)
    local playable, library = line:match("(%d+) of (%d+) playable")
    lastLogged = ""
    publish({
        running = true,
        launching = false,
        showing = noctalia.string.trim(line:match("^(.-); %d+ of %d+ playable") or line),
        playable = tonumber(playable) or 0,
        library = tonumber(library) or 0,
        error = "",
    })
end

local function eachLine(text, callback)
    for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
        callback(line)
    end
end

local function publishPlaylists(text)
    local rows = {}
    eachLine(text, function(line)
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local name, entries, active = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
            if name ~= nil and name ~= "" then
                table.insert(rows, {
                    name = name,
                    entries = tonumber(entries) or 0,
                    active = active == "yes",
                })
            end
        end
    end)
    playlistRows = rows
    publishMenu("")
end

local function publishSchedule(text)
    local nextState = { count = 0, default = "", rule = "", when = "" }
    eachLine(text, function(line)
        local count, defaultName = line:match("^# schedule: (%d+) rules, default (.*)$")
        if count ~= nil then
            nextState.count = tonumber(count) or 0
            nextState.default = tostring(defaultName or "")
        elseif line:sub(1, 1) ~= "#" and line ~= "" then
            local _id, playlist, when, _enabled, inForce =
                line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
            if inForce == "yes" then
                nextState.rule = tostring(playlist or "")
                nextState.when = tostring(when or "")
            end
        end
    end)
    scheduleState = nextState
    publishMenu("")
end

local function publishDisplays(text)
    local rows = {}
    eachLine(text, function(line)
        if line:sub(1, 1) ~= "#" and line ~= "" then
            local label, assigned = line:match("^([^\t]*)\t([^\t]*)")
            local connector = if label ~= nil then label:match("^([^%s%(]+)") else nil
            if connector ~= nil and connector ~= "" then
                table.insert(rows, {
                    connector = connector,
                    label = label,
                    playlist = tostring(assigned or ""),
                })
            end
        end
    end)
    displayRows = rows
    publishMenu("")
end

local function enqueue(verb, argument, allowLaunch)
    if VERBS[verb] ~= true then
        noctalia.log("wall-in-one: unknown control verb '" .. tostring(verb) .. "'")
        return
    end
    if verb == "status" or verb == "playlists" or verb == "schedule" or verb == "displays" then
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

launchDirect = function(command)
    if not noctalia.runAsync(shellQuote(command) .. " --service") then
        stopLaunch(noctalia.tr("state.failed"))
        return
    end
    enqueue("status", nil, false)
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

    -- A packaged user unit owns the lifetime when available. An explicit
    -- binary override deliberately bypasses it, and a missing/broken unit
    -- falls back to the same detached service launch used outside systemd.
    if configuredOverride() == "" and noctalia.commandExists("systemctl") then
        busy = true
        local started = noctalia.runAsync(SYSTEMD_START, function(result)
            busy = false
            if not result.timedOut and result.exitCode == 0 then
                enqueue("status", nil, false)
            else
                launchDirect(command)
            end
            pump()
        end, SYSTEMD_CALL_TIMEOUT_MS)
        if started then
            return
        end
        busy = false
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
            clearMenu()
            publishStopped("")
        end
    elseif result.exitCode ~= 0 then
        local stderr = noctalia.string.trim(tostring(result.stderr or ""))
        local detail = if stderr ~= "" then stderr else noctalia.tr("state.failed")
        if launching then
            stopLaunch(detail)
        else
            publishStopped(detail)
            publishMenu(detail)
        end
    elseif job.verb == "status" then
        local replay = pendingAfterLaunch
        clearLaunch()
        publishStatus(noctalia.string.trim(tostring(result.stdout or "")))
        if replay ~= nil then
            enqueue(replay.verb, replay.argument, false)
        end
    elseif job.verb == "playlists" then
        publishPlaylists(result.stdout)
        enqueue("schedule", nil, false)
    elseif job.verb == "schedule" then
        publishSchedule(result.stdout)
        enqueue("displays", nil, false)
    elseif job.verb == "displays" then
        publishDisplays(result.stdout)
    else
        enqueue("status", nil, false)
        if job.verb == "playlist-use" then
            enqueue("playlists", nil, false)
        elseif job.verb == "display-assign" or job.verb == "display-clear" then
            enqueue("displays", nil, false)
        end
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
        if not noctalia.runAsync(shellQuote(command)) then
            publishStopped(noctalia.tr("state.failed"))
        end
        return
    end

    local parts = { shellQuote(command), "ctl", job.verb }
    if job.argument ~= nil and job.argument ~= "" then
        table.insert(parts, shellQuote(job.argument))
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
clearMenu()
noctalia.state.set(READY_KEY, true)
-- First ask the existing socket. Only a genuinely absent service is started;
-- the packaged systemd unit is preferred, with a detached `--service`
-- fallback for non-systemd installs.
enqueue("status", nil, true)

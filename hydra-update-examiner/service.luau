--!nonstrict
-- Singleton Hydra polling service for Noctalia v5.
--
-- The proven v4 shell helper remains the backend for this first port. This
-- service owns process lifecycle, settings, cooldowns, stale-result handling,
-- and the state channel consumed by every widget placement.

local STATUS_KEY = "hydra_status"
local COMMAND_KEY = "hydra_command"
local READY_KEY = "hydra_service_ready"
local STATUS_PROTOCOL = 2
local MINIMUM_REFRESH_SECONDS = 30
local REQUIRED_COMMANDS = {
    "bash",
    "curl",
    "jq",
    "perl",
    "grep",
    "awk",
    "sed",
    "head",
    "tr",
    "cut",
    "date",
    "cat",
    "timeout",
}
local SUCCESS_STATES = { running = true, close = true, stalled = true, launched = true }

local inFlight = false
local pendingRefresh = false
local configGeneration = 0
local lastStartedAt = 0
local sequence = 0
local lastStatus = nil
local lastGoodStatus = nil
local activeConfigKey = ""
local refresh

-- A widget can load concurrently with this service. Clear the process-lifetime
-- ready flag immediately so clicks are queued until the command watch exists.
noctalia.state.set(READY_KEY, false)

local function cfg(key)
    return noctalia.getConfig(key)
end

local function nowSeconds()
    return tonumber(noctalia.formatTime("%s")) or 0
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function copyStatus(source)
    if type(source) ~= "table" then
        return nil
    end

    return {
        protocol = source.protocol,
        config_key = source.config_key,
        sequence = source.sequence,
        state = source.state,
        text = source.text,
        tooltip = source.tooltip,
        url = source.url,
        channel = source.channel,
        loading = source.loading,
        stale = source.stale,
        error = source.error,
        updated_at = source.updated_at,
        last_good_state = source.last_good_state,
        last_good_tooltip = source.last_good_tooltip,
    }
end

local function publishStatus(status)
    sequence = sequence + 1
    status.protocol = STATUS_PROTOCOL
    status.config_key = activeConfigKey
    status.sequence = sequence
    lastStatus = status
    noctalia.state.set(STATUS_KEY, status)
end

local function initialStatus()
    return {
        protocol = STATUS_PROTOCOL,
        config_key = activeConfigKey,
        state = "idle",
        text = "HYD",
        tooltip = noctalia.tr("widget.not_fetched"),
        url = "",
        channel = "",
        loading = false,
        stale = false,
        error = "",
        updated_at = "",
        last_good_state = "",
        last_good_tooltip = "",
    }
end

local function publishLoading()
    local status = copyStatus(lastStatus) or initialStatus()
    status.loading = true
    status.error = ""
    publishStatus(status)
end

local function publishError(message)
    local detail = tostring(message or noctalia.tr("widget.unavailable"))
    noctalia.log("hydra-update-examiner: " .. detail)

    if lastGoodStatus ~= nil then
        local status = copyStatus(lastGoodStatus)
        status.state = "stale"
        status.loading = false
        status.stale = true
        status.error = detail
        status.last_good_state = tostring(lastGoodStatus.state or "")
        status.last_good_tooltip = tostring(lastGoodStatus.tooltip or "")
        status.tooltip = tostring(lastGoodStatus.tooltip or noctalia.tr("widget.unavailable"))
            .. "\n\n"
            .. noctalia.tr("widget.refresh_failed")
            .. "\n"
            .. detail
        publishStatus(status)
        return
    end

    publishStatus({
        state = "error",
        text = "ERR",
        tooltip = detail,
        url = "",
        channel = "",
        loading = false,
        stale = false,
        error = detail,
        updated_at = "",
        last_good_state = "",
        last_good_tooltip = "",
    })
end

local function applyRefreshInterval()
    local minutes = tonumber(cfg("refresh_interval_minutes")) or 60
    minutes = math.max(1, math.min(1440, minutes))
    noctalia.setUpdateInterval(minutes * 60 * 1000)
end

local function selectedChannel()
    local preset = tostring(cfg("channel_preset") or "nixos-unstable")
    if preset ~= "custom" then
        return preset
    end

    local custom = noctalia.string.trim(tostring(cfg("custom_channel") or ""))
    if custom == "" then
        return nil
    end
    return custom
end

local function closeThreshold()
    local threshold = tonumber(cfg("close_threshold")) or 90
    return math.max(1, math.min(100, threshold))
end

local function resultConfigKey()
    return tostring(selectedChannel() or "<unset>") .. "|" .. tostring(closeThreshold())
end

local function missingCommand()
    for _, command in ipairs(REQUIRED_COMMANDS) do
        if not noctalia.commandExists(command) then
            return command
        end
    end
    return nil
end

local function inferState(data)
    local declared = tostring(data.state or "")
    if
        declared == "running"
        or declared == "close"
        or declared == "stalled"
        or declared == "launched"
        or declared == "error"
    then
        return declared
    end

    local text = tostring(data.text or "")
    if text == "Launched" then
        return "launched"
    end
    if text == "ERR" or text == "HYD" then
        return "error"
    end

    local tooltip = tostring(data.tooltip or "")
    if tooltip:find("blocked:", 1, true) ~= nil then
        return "stalled"
    end

    local readiness = tonumber(text:match("^(%d+)%%$"))
    local threshold = closeThreshold()
    if readiness ~= nil and readiness >= threshold then
        return "close"
    end
    return "running"
end

local function normalizeResult(data)
    local text = tostring(data.text or "HYD")
    local tooltip = tostring(data.tooltip or noctalia.tr("widget.unavailable"))
    return {
        state = inferState(data),
        text = text,
        tooltip = tooltip,
        url = tostring(data.url or ""),
        channel = tostring(data.channel or selectedChannel() or ""),
        loading = false,
        stale = false,
        error = "",
        updated_at = noctalia.formatTime("%H:%M:%S"),
        last_good_state = "",
        last_good_tooltip = "",
    }
end

local function runPendingRefresh()
    if not pendingRefresh then
        return
    end
    pendingRefresh = false
    refresh(true)
end

refresh = function(force)
    if inFlight then
        if force then
            pendingRefresh = true
        end
        return
    end

    local now = nowSeconds()
    if not force and lastStartedAt > 0 and now > 0 and now - lastStartedAt < MINIMUM_REFRESH_SECONDS then
        return
    end

    local channel = selectedChannel()
    if channel == nil then
        publishError(noctalia.tr("widget.empty_custom_channel"))
        return
    end

    local command = missingCommand()
    if command ~= nil then
        publishError(noctalia.tr("widget.missing_dependency", { command = command }))
        return
    end

    local pluginDirectory = noctalia.pluginDir()
    if pluginDirectory == nil or pluginDirectory == "" then
        publishError(noctalia.tr("widget.missing_backend"))
        return
    end

    local helper = pluginDirectory .. "/scripts/hydra-channel-progress"
    if not noctalia.fileExists(helper) then
        publishError(noctalia.tr("widget.missing_backend"))
        return
    end

    local threshold = closeThreshold()
    local shellCommand = table.concat({
        "timeout",
        "55s",
        "bash",
        shellQuote(helper),
        "--channel",
        shellQuote(channel),
        "--close-threshold",
        shellQuote(tostring(threshold)),
    }, " ")

    inFlight = true
    lastStartedAt = now
    local generation = configGeneration
    publishLoading()

    -- The current v5 beta host accepts a third callback timeout (clamped to 60s).
    -- Keep the inner 55s GNU timeout as the backend's deterministic deadline.
    local launched = noctalia.runAsync(shellCommand, function(result)
        inFlight = false

        if generation ~= configGeneration then
            pendingRefresh = false
            refresh(true)
            return
        end

        if result.timedOut or result.exitCode == 124 then
            publishError(noctalia.tr("widget.command_timed_out"))
            runPendingRefresh()
            return
        end

        if result.stdoutTruncated or result.stderrTruncated then
            publishError(noctalia.tr("widget.output_truncated"))
            runPendingRefresh()
            return
        end

        if result.exitCode ~= 0 then
            local stderr = noctalia.string.trim(tostring(result.stderr or ""))
            if #stderr > 1000 then
                stderr = stderr:sub(1, 1000) .. "..."
            end
            publishError(if stderr ~= "" then stderr else noctalia.tr("widget.command_failed"))
            runPendingRefresh()
            return
        end

        local raw = noctalia.string.trim(tostring(result.stdout or ""))
        local data, decodeError = noctalia.json.decode(raw)
        if type(data) ~= "table" then
            local detail = noctalia.tr("widget.invalid_json")
            if decodeError ~= nil and tostring(decodeError) ~= "" then
                detail = detail .. " " .. tostring(decodeError)
            end
            publishError(detail)
            runPendingRefresh()
            return
        end

        local status = normalizeResult(data)
        if status.state == "error" and lastGoodStatus ~= nil then
            publishError(status.tooltip)
        else
            publishStatus(status)
            if status.state ~= "error" then
                lastGoodStatus = copyStatus(status)
            end
        end
        runPendingRefresh()
    end, 60000)

    if not launched then
        inFlight = false
        publishError(noctalia.tr("widget.command_failed"))
    end
end

local function openHydra()
    local url = if type(lastStatus) == "table" then tostring(lastStatus.url or "") else ""
    if url == "" or url:match("^https://hydra%.nixos%.org/") == nil then
        noctalia.notifyError(noctalia.tr("widget.title"), noctalia.tr("widget.open_failed"))
        return
    end
    if not noctalia.commandExists("xdg-open") then
        noctalia.notifyError(
            noctalia.tr("widget.title"),
            noctalia.tr("widget.missing_dependency", { command = "xdg-open" })
        )
        return
    end

    local launched = noctalia.runAsync("xdg-open " .. shellQuote(url), function(result)
        if result.exitCode ~= 0 then
            noctalia.notifyError(noctalia.tr("widget.title"), noctalia.tr("widget.open_failed"))
        end
    end)
    if not launched then
        noctalia.notifyError(noctalia.tr("widget.title"), noctalia.tr("widget.open_failed"))
    end
end

function update()
    refresh(false)
end

function onConfigChanged()
    configGeneration = configGeneration + 1
    applyRefreshInterval()
    local nextConfigKey = resultConfigKey()
    if nextConfigKey ~= activeConfigKey then
        activeConfigKey = nextConfigKey
        lastStatus = nil
        lastGoodStatus = nil
        publishStatus(initialStatus())
    end
    if inFlight then
        pendingRefresh = true
    else
        refresh(true)
    end
end

function onIpc(event, _payload)
    if event == "refresh" then
        refresh(false)
    elseif event == "force-refresh" then
        refresh(true)
    elseif event == "open" then
        openHydra()
    elseif event == "status" and lastStatus ~= nil then
        publishStatus(copyStatus(lastStatus))
    else
        noctalia.log("hydra-update-examiner: unknown command '" .. tostring(event) .. "'")
    end
end

function onExit(_signal)
    -- Noctalia calls onExit before unloading an entry. Clear the handshake so
    -- a surviving widget queues clicks until the replacement service is ready.
    noctalia.state.set(READY_KEY, false)
end

applyRefreshInterval()
activeConfigKey = resultConfigKey()

local existing = noctalia.state.get(STATUS_KEY)
if type(existing) == "table" and existing.protocol == STATUS_PROTOCOL and existing.config_key == activeConfigKey then
    sequence = tonumber(existing.sequence) or 0
    lastStatus = copyStatus(existing)
    if SUCCESS_STATES[existing.state] and tostring(existing.updated_at or "") ~= "" then
        lastGoodStatus = copyStatus(existing)
    elseif
        existing.state == "stale"
        and SUCCESS_STATES[existing.last_good_state]
        and tostring(existing.updated_at or "") ~= ""
    then
        lastGoodStatus = copyStatus(existing)
        lastGoodStatus.state = existing.last_good_state
        lastGoodStatus.tooltip = existing.last_good_tooltip or existing.tooltip
        lastGoodStatus.stale = false
        lastGoodStatus.error = ""
    end
else
    publishStatus(initialStatus())
end

noctalia.state.watch(COMMAND_KEY, function(command)
    local action = if type(command) == "table" then command.action else command
    if type(action) == "string" then
        onIpc(action, command)
    end
end)
noctalia.state.set(READY_KEY, true)

refresh(true)

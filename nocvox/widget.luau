--!nonstrict
-- Thin VoxType bar client. The singleton service owns status and commands.

local STATUS_KEY = "voxtype_status"
local COMMAND_KEY = "voxtype_command"
local READY_KEY = "voxtype_service_ready"
local PANEL_ID = "goober/nocvox:details"

local RECORDING_STATES = { recording = true, streaming = true }
local PROCESSING_STATES = { transcribing = true, processing = true }

local status = nil
local serviceReady = false
local pendingAction = nil
local commandSequence = 0

local function cfg(key)
    return noctalia.getConfig(key)
end

local function glyphCfg(key, fallback)
    local value = cfg(key)
    if type(value) == "string" and value:find("%S") ~= nil then
        return value
    end
    return fallback
end

local function nowSeconds()
    return tonumber(noctalia.formatTime("%s")) or 0
end

local function stateLabel(state)
    if state == "stopped" then
        return noctalia.tr("states.stopped")
    elseif state == "idle" then
        return noctalia.tr("states.idle")
    elseif state == "recording" then
        return noctalia.tr("states.recording")
    elseif state == "streaming" then
        return noctalia.tr("states.streaming")
    elseif state == "transcribing" then
        return noctalia.tr("states.transcribing")
    elseif state == "processing" then
        return noctalia.tr("states.processing")
    elseif state == "error" then
        return noctalia.tr("states.error")
    end
    return noctalia.tr("states.unknown")
end

local function elapsedText(current)
    local startedAt = tonumber(current.recording_started_at) or 0
    if startedAt <= 0 then
        return noctalia.tr("widget.elapsed_unknown")
    end
    local elapsed = math.max(0, nowSeconds() - startedAt)
    local prefix = if current.elapsed_approximate == true then "~" else ""
    local minutes = math.floor(elapsed / 60)
    local seconds = elapsed % 60
    if minutes > 0 then
        return string.format("%s%d:%02d", prefix, minutes, seconds)
    end
    return string.format("%s%ds", prefix, seconds)
end

local function presentation(current)
    local state = tostring(current.state or "unknown")
    local widthMode = tostring(cfg("width_mode") or "compact")
    local text = ""
    local glyph = glyphCfg("unknown_glyph", "microphone")
    local color = tostring(cfg("unknown_color") or "tertiary")
    local visible = true

    if current.available ~= true or state == "stopped" then
        glyph = glyphCfg("stopped_glyph", "microphone-off")
        color = tostring(cfg("stopped_color") or "on_surface_variant")
        text = if widthMode == "expanded" then stateLabel("stopped") else "OFF"
    elseif state == "idle" then
        glyph = glyphCfg("idle_glyph", "microphone")
        color = tostring(cfg("idle_color") or "on_surface")
        local idleDisplay = tostring(cfg("idle_display") or "glyph_only")
        if idleDisplay == "hidden" then
            visible = false
        elseif idleDisplay == "glyph_text" then
            text = "IDLE"
        end
    elseif RECORDING_STATES[state] then
        glyph = glyphCfg("active_glyph", "microphone")
        color = tostring(cfg("recording_color") or "error")
        local activeLabel = tostring(cfg("active_label") or "rec")
        if widthMode == "expanded" then
            if activeLabel == "elapsed" then
                text = elapsedText(current) .. " · " .. stateLabel(state)
            else
                text = stateLabel(state)
            end
        elseif activeLabel == "rec" then
            text = "REC"
        elseif activeLabel == "elapsed" then
            text = elapsedText(current)
        end
    elseif PROCESSING_STATES[state] then
        glyph = glyphCfg("active_glyph", "microphone")
        color = tostring(cfg("transcribing_color") or "tertiary")
        text = if widthMode == "expanded" then stateLabel(state) else "..."
    elseif state == "error" then
        glyph = glyphCfg("stopped_glyph", "microphone-off")
        color = tostring(cfg("recording_color") or "error")
        text = "ERR"
    else
        text = if widthMode == "expanded" then stateLabel("unknown") else "?"
    end

    return glyph, color, text, visible
end

local function tooltipFor(current)
    local state = tostring(current.state or "unknown")
    local lines = {
        noctalia.tr("widget.state", { state = stateLabel(state) }),
    }
    if RECORDING_STATES[state] then
        table.insert(lines, noctalia.tr("widget.elapsed", { value = elapsedText(current) }))
    elseif state == "idle" then
        table.insert(lines, noctalia.tr("widget.keybind_hint"))
    elseif state == "stopped" then
        table.insert(lines, noctalia.tr("widget.daemon_external"))
    end

    if cfg("tooltip_show_model") == true and tostring(current.model or "") ~= "" then
        table.insert(lines, noctalia.tr("widget.model", { value = tostring(current.model) }))
    end
    if cfg("tooltip_show_device") == true and tostring(current.device or "") ~= "" then
        table.insert(lines, noctalia.tr("widget.device", { value = tostring(current.device) }))
    end
    if cfg("tooltip_show_backend") == true and tostring(current.backend or "") ~= "" then
        table.insert(lines, noctalia.tr("widget.backend", { value = tostring(current.backend) }))
    end

    table.insert(lines, "")
    table.insert(lines, noctalia.tr("widget.actions_hint"))

    local lastError = tostring(current.last_error or "")
    if lastError ~= "" then
        table.insert(lines, "")
        table.insert(lines, noctalia.tr("widget.last_error", { error = lastError }))
    end
    return table.concat(lines, "\n")
end

local function render(nextStatus)
    if type(nextStatus) == "table" then
        status = nextStatus
    end
    local current = if type(status) == "table"
        then status
        else {
            state = "unknown",
            available = false,
            last_error = noctalia.tr("widget.waiting"),
        }

    local glyph, color, text, visible = presentation(current)
    barWidget.setGlyph(glyph)
    barWidget.setText(text)
    barWidget.setGlyphColor(color)
    barWidget.setColor(color)
    barWidget.setTooltip(tooltipFor(current))
    barWidget.setVisible(visible)
end

local function sendNow(action)
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    noctalia.state.set(COMMAND_KEY, {
        action = action,
        producer = "widget",
        sequence = commandSequence,
    })
end

local function send(action)
    if not serviceReady then
        pendingAction = action
        return
    end
    sendNow(action)
end

noctalia.state.watch(STATUS_KEY, render)
status = noctalia.state.get(STATUS_KEY)

noctalia.state.watch(READY_KEY, function(ready)
    serviceReady = ready == true
    if serviceReady and pendingAction ~= nil then
        local action = pendingAction
        pendingAction = nil
        sendNow(action)
    end
end)
serviceReady = noctalia.state.get(READY_KEY) == true

noctalia.setUpdateInterval(1000)
render(status)

function update()
    render(noctalia.state.get(STATUS_KEY))
end

function onConfigChanged()
    render(noctalia.state.get(STATUS_KEY))
end

function onIpc(event, _payload)
    if event == "panel" or event == "open" then
        noctalia.togglePanel(PANEL_ID)
    elseif event == "toggle" or event == "start" or event == "stop" or event == "cancel" then
        send(event)
    else
        noctalia.log("nocvox widget: unknown command '" .. tostring(event) .. "'")
    end
end

--!nonstrict
-- Thin Noctalia v5 bar client. The singleton service owns polling and publishes
-- a presentation-neutral status through noctalia.state.

local STATUS_KEY = "hydra_status"
local COMMAND_KEY = "hydra_command"
local READY_KEY = "hydra_service_ready"
local commandSequence = 0
local status = nil
local serviceReady = false
local pendingAction = nil

local function widgetCfg(key)
    return noctalia.getConfig(key)
end

local function acceptsStatus(nextStatus)
    if type(nextStatus) ~= "table" or type(status) ~= "table" then
        return true
    end

    local nextConfigKey = tostring(nextStatus.config_key or "")
    local currentConfigKey = tostring(status.config_key or "")
    if nextConfigKey ~= currentConfigKey then
        return true
    end

    local nextProtocol = tonumber(nextStatus.protocol)
    local currentProtocol = tonumber(status.protocol)
    if nextProtocol ~= currentProtocol then
        return true
    end

    local nextSequence = tonumber(nextStatus.sequence)
    local currentSequence = tonumber(status.sequence)
    if nextSequence == nil or currentSequence == nil then
        return true
    end
    return nextSequence > currentSequence
end

local function presentationFor(state)
    if state == "launched" then
        return widgetCfg("launched_glyph"), widgetCfg("launched_color")
    elseif state == "close" then
        return widgetCfg("close_glyph"), widgetCfg("close_color")
    elseif state == "stalled" or state == "stale" or state == "error" then
        return widgetCfg("stalled_glyph"), widgetCfg("stalled_color")
    end
    return widgetCfg("running_glyph"), widgetCfg("running_color")
end

local function render(nextStatus, force)
    if type(nextStatus) == "table" then
        if not force and not acceptsStatus(nextStatus) then
            return
        end
        status = nextStatus
    end

    local current = if type(status) == "table"
        then status
        else {
            state = "idle",
            text = "HYD",
            tooltip = noctalia.tr("widget.not_fetched"),
            loading = false,
        }

    local glyph, color = presentationFor(tostring(current.state or "idle"))
    if current.loading then
        glyph = "refresh"
    end

    local text = tostring(current.text or "HYD")
    if widgetCfg("display_mode") == "icon_only" then
        text = ""
    end

    local tooltip = tostring(current.tooltip or noctalia.tr("widget.unavailable"))
    if current.loading then
        tooltip = tooltip .. "\n\n" .. noctalia.tr("widget.loading")
    elseif current.updated_at ~= nil and tostring(current.updated_at) ~= "" then
        tooltip = tooltip .. "\n\n" .. noctalia.tr("widget.updated", { time = tostring(current.updated_at) })
    end

    barWidget.setGlyph(tostring(glyph or "server-bolt"))
    barWidget.setText(text)
    barWidget.setTooltip(tooltip)
    barWidget.setGlyphColor(tostring(color or "on_surface"))
    barWidget.setColor(tostring(color or "on_surface"))
end

local function sendNow(action)
    commandSequence = commandSequence + 1
    noctalia.state.set(COMMAND_KEY, {
        action = action,
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
render(noctalia.state.get(STATUS_KEY), true)

noctalia.state.watch(READY_KEY, function(ready)
    serviceReady = ready == true
    if serviceReady and pendingAction ~= nil then
        local action = pendingAction
        pendingAction = nil
        sendNow(action)
    end
end)
serviceReady = noctalia.state.get(READY_KEY) == true

function update()
    noctalia.setUpdateInterval(60 * 60 * 1000)
    render(noctalia.state.get(STATUS_KEY), true)
end

function onClick()
    send("refresh")
end

function onRightClick()
    send("open")
end

function onIpc(event, _payload)
    if event == "refresh" or event == "force-refresh" or event == "open" then
        send(event)
    else
        noctalia.log("hydra-update-examiner widget: unknown command '" .. tostring(event) .. "'")
    end
end

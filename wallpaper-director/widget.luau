--!nonstrict
-- Thin three-button bar client for the Wallpaper Director singleton service.

local STATUS_KEY = "director_status"
local COMMAND_KEY = "director_command"

local status = nil
local commandSequence = 0
local pendingGesture = nil

local ACTION_LABEL_KEYS = {
    native_open = "actions.native_open",
    native_next = "actions.native_next",
    native_previous = "actions.native_previous",
    native_random = "actions.native_random",
    wallhaven_open = "actions.wallhaven_open",
    w_engine_open = "actions.w_engine_open",
    director_open = "actions.director_open",
    no_action = "actions.no_action",
}

local OPEN_TARGETS = {
    native_open = "wallpaper",
    wallhaven_open = "noctalia/wallhaven:browser",
    w_engine_open = "tadomika_ari/w-engine:w-engine-panel",
    director_open = "goober/wallpaper-director:director",
}

local function cfg(key)
    return noctalia.getConfig(key)
end

local function actionLabel(action)
    local key = ACTION_LABEL_KEYS[action]
    if key == nil then
        return tostring(action or "?")
    end
    return noctalia.tr(key)
end

local function gestureAction(button)
    if type(status) ~= "table" or type(status.config) ~= "table" or type(status.config.gestures) ~= "table" then
        return "?"
    end
    return tostring(status.config.gestures[button] or "?")
end

local function render()
    local glyph = tostring(cfg("glyph") or "library-photo")
    if glyph:find("%S") == nil then
        glyph = "library-photo"
    end
    local label = if cfg("show_label") == false then "" else tostring(cfg("label") or "Wallpapers")
    local color = tostring(cfg("color") or "on_surface")
    if color:find("%S") == nil then
        color = "on_surface"
    end

    local storageValid = type(status) == "table" and status.storage_valid == true
    if type(status) == "table" and status.ready == false then
        glyph = "refresh"
    elseif type(status) == "table" and not storageValid then
        glyph = "photo-x"
        color = "error"
    end

    local tooltip
    if type(status) ~= "table" or status.ready ~= true then
        tooltip = noctalia.tr("widget.starting")
    elseif not storageValid then
        tooltip = noctalia.tr("widget.storage_error")
    else
        tooltip = table.concat({
            noctalia.tr("widget.tooltip_left", { action = actionLabel(gestureAction("left")) }),
            noctalia.tr("widget.tooltip_middle", { action = actionLabel(gestureAction("middle")) }),
            noctalia.tr("widget.tooltip_right", { action = actionLabel(gestureAction("right")) }),
        }, "\n")
    end

    barWidget.setGlyph(glyph)
    barWidget.setText(label)
    barWidget.setTooltip(tooltip)
    barWidget.setGlyphColor(color)
    barWidget.setColor(color)
end

local function nextSequence()
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    return commandSequence
end

local function actionAvailable(action)
    if type(status) ~= "table" or status.storage_valid ~= true then
        return false
    end
    if action == "native_open" or action == "director_open" or action == "no_action" then
        return true
    end
    local providers = type(status.providers) == "table" and status.providers or {}
    if action == "wallhaven_open" then
        return type(providers.wallhaven) == "table" and providers.wallhaven.available == true
    end
    if action == "w_engine_open" then
        return type(providers.w_engine) == "table" and providers.w_engine.available == true
    end
    return false
end

local function sendAction(action)
    noctalia.state.set(COMMAND_KEY, {
        kind = "action",
        action = action,
        output = barWidget.outputName(),
        producer = "widget",
        sequence = nextSequence(),
    })
end

local function executeGesture(button)
    if type(status) ~= "table" or status.ready ~= true then
        pendingGesture = button
        return
    end

    local action = gestureAction(button)
    local target = OPEN_TARGETS[action]
    if target ~= nil and actionAvailable(action) then
        -- This call stays inside the invoking widget callback. Noctalia can
        -- therefore attach/follow the widget instead of centering the panel.
        noctalia.togglePanel(target)
    elseif action ~= "no_action" then
        -- Native switch actions and unavailable-action diagnostics remain
        -- centralized in the singleton service.
        sendAction(action)
    end
end

noctalia.state.watch(STATUS_KEY, function(nextStatus)
    status = nextStatus
    render()
    if type(status) == "table" and status.ready == true and pendingGesture ~= nil then
        local button = pendingGesture
        pendingGesture = nil
        executeGesture(button)
    end
end)
status = noctalia.state.get(STATUS_KEY)
render()

function update()
    noctalia.setUpdateInterval(60 * 60 * 1000)
    status = noctalia.state.get(STATUS_KEY)
    render()
end

function onClick()
    executeGesture("left")
end

function onMiddleClick()
    executeGesture("middle")
end

function onRightClick()
    executeGesture("right")
end

function onIpc(event, _payload)
    if event == "left" or event == "middle" or event == "right" then
        executeGesture(event)
    else
        noctalia.log("wallpaper-director widget: unknown IPC event '" .. tostring(event) .. "'")
    end
end

--!nonstrict
-- Control Center client. Noctalia beta.7 exposes left and right callbacks for
-- plugin shortcuts; middle click intentionally remains absent until the core
-- shortcut API gains it.

local STATUS_KEY = "director_status"
local COMMAND_KEY = "director_command"

local status = nil
local commandSequence = 0
local pendingGesture = nil

local OPEN_TARGETS = {
    native_open = "wallpaper",
    wallhaven_open = "noctalia/wallhaven:browser",
    w_engine_open = "tadomika_ari/w-engine:w-engine-panel",
    director_open = "goober/wallpaper-director:director",
}

local function render()
    local valid = type(status) == "table" and status.storage_valid == true
    shortcut.setLabel(if valid then noctalia.tr("shortcut.label") else noctalia.tr("shortcut.config_error"))
    shortcut.setIcon("library-photo", "library-photo")
    shortcut.setActive(false)
    shortcut.setEnabled(true)
end

local function nextSequence()
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    return commandSequence
end

local function gestureAction(button)
    if type(status) ~= "table" or type(status.config) ~= "table" or type(status.config.gestures) ~= "table" then
        return ""
    end
    return tostring(status.config.gestures[button] or "")
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
        output = noctalia.focusedOutputName(),
        producer = "shortcut",
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
        noctalia.togglePanel(target)
    elseif action ~= "no_action" then
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

function onClick()
    executeGesture("left")
end

function onRightClick()
    executeGesture("right")
end

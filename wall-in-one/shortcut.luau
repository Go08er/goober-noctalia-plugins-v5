--!nonstrict
-- Control Center client. Plugin shortcuts currently expose left and right
-- callbacks; the bar widget retains the full three-button mapping.

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"

local status = nil
local commandSequence = 0
local pendingGesture = nil

local OPEN_TARGETS = {
    native_open = "wallpaper",
    hub_open = "goober/wall-in-one:hub",
}

local function focusedOutput()
    local output = noctalia.focusedOutputName()
    return if type(output) == "string" then output else ""
end

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
    local current = type(status.providers) == "table" and status.providers or {}
    if action == "native_open" or action == "hub_open" or action == "no_action" then
        return true
    elseif action == "native_next" or action == "native_previous" or action == "native_random" then
        return current.noctalia_cli == true
    elseif action == "motionbgs_open" then
        return type(current.motionbgs) == "table" and current.motionbgs.browser_available == true
    elseif action:match("^playback_") or action:match("^audio_") then
        return focusedOutput() ~= "" or action == "playback_stop_all"
    elseif action == "capture_backing" then
        return current.noctalia_cli == true and focusedOutput() ~= ""
    elseif action == "capture_current" or action == "capture_pair" then
        local wEngine = type(current.w_engine) == "table" and current.w_engine or {}
        local activeId = type(wEngine.internal_current) == "table"
                and tostring(wEngine.internal_current[focusedOutput()] or "")
            or ""
        local configuredId = type(status.settings) == "table" and tostring(status.settings.workshop_id or "") or ""
        return wEngine.allowed == true and (activeId:match("^%d+$") ~= nil or configuredId:match("^%d+$") ~= nil)
    elseif action == "video_capture" or action == "video_capture_pair" then
        return type(status.settings) == "table" and tostring(status.settings.video_source or "") ~= ""
    elseif action == "manual_pair" then
        return type(status.settings) == "table" and tostring(status.settings.manual_pair_file or "") ~= ""
    end
    return false
end

local function panelTarget(action)
    return OPEN_TARGETS[action] or ""
end

local function sendAction(action)
    noctalia.state.set(COMMAND_KEY, {
        kind = "action",
        action = action,
        output = focusedOutput(),
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
    local target = panelTarget(action)
    if target ~= "" and actionAvailable(action) then
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

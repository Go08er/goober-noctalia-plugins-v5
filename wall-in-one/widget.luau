--!nonstrict
-- Thin three-button bar client for the Wall-in-One singleton coordinator.

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"

local status = nil
local commandSequence = 0
local pendingGesture = nil

local ACTION_LABEL_KEYS = {
    native_open = "actions.native_open",
    native_next = "actions.native_next",
    native_previous = "actions.native_previous",
    native_random = "actions.native_random",
    motionbgs_open = "actions.motionbgs_open",
    capture_backing = "actions.capture_backing",
    capture_current = "actions.capture_current",
    capture_pair = "actions.capture_pair",
    video_capture = "actions.video_capture",
    video_capture_pair = "actions.video_capture_pair",
    video_apply_pair = "actions.video_apply_pair",
    workshop_apply_pair = "actions.workshop_apply_pair",
    cycle_start = "actions.cycle_start",
    cycle_stop = "actions.cycle_stop",
    cycle_pause = "actions.cycle_pause",
    cycle_resume = "actions.cycle_resume",
    cycle_next = "actions.cycle_next",
    cycle_previous = "actions.cycle_previous",
    cycle_random = "actions.cycle_random",
    cycle_add_static = "actions.cycle_add_static",
    cycle_add_video = "actions.cycle_add_video",
    cycle_add_workshop = "actions.cycle_add_workshop",
    cycle_remove_last = "actions.cycle_remove_last",
    cycle_clear = "actions.cycle_clear",
    manual_pair = "actions.manual_pair",
    playback_pause = "actions.playback_pause",
    playback_resume = "actions.playback_resume",
    playback_toggle = "actions.playback_toggle",
    playback_stop = "actions.playback_stop",
    playback_stop_all = "actions.playback_stop_all",
    audio_mute = "actions.audio_mute",
    audio_unmute = "actions.audio_unmute",
    audio_toggle = "actions.audio_toggle",
    audio_volume_down = "actions.audio_volume_down",
    audio_volume_up = "actions.audio_volume_up",
    steam_launch = "actions.steam_launch",
    steam_workshop = "actions.steam_workshop",
    hub_open = "actions.hub_open",
    no_action = "actions.no_action",
}

local OPEN_TARGETS = {
    native_open = "wallpaper",
    hub_open = "goober/wall-in-one:hub",
}

local function cfg(key)
    return noctalia.getConfig(key)
end

local function actionLabel(action)
    local key = ACTION_LABEL_KEYS[action]
    return if key == nil then tostring(action or "?") else noctalia.tr(key)
end

local function gestureAction(button)
    if type(status) ~= "table" or type(status.config) ~= "table" or type(status.config.gestures) ~= "table" then
        return "?"
    end
    return tostring(status.config.gestures[button] or "?")
end

local function outputName()
    local output = barWidget.outputName()
    return if type(output) == "string" then output else ""
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
        -- The coordinator performs the authoritative per-output capability
        -- check against Wall-in-One's own renderer snapshot.
        return outputName() ~= "" or action == "playback_stop_all"
    elseif action == "capture_backing" then
        return current.noctalia_cli == true and outputName() ~= ""
    elseif action == "capture_current" or action == "capture_pair" then
        local wEngine = type(current.w_engine) == "table" and current.w_engine or {}
        local activeId = type(wEngine.internal_current) == "table"
                and tostring(wEngine.internal_current[outputName()] or "")
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

local function render()
    local glyph = tostring(cfg("glyph") or "library-photo")
    if glyph:find("%S") == nil then
        glyph = "library-photo"
    end
    local label = if cfg("show_label") == false then "" else tostring(cfg("label") or "Wall-in-One")
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

local function sendAction(action)
    noctalia.state.set(COMMAND_KEY, {
        kind = "action",
        action = action,
        output = outputName(),
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
    local target = panelTarget(action)
    if target ~= "" and actionAvailable(action) then
        -- Keeping this inside the widget callback lets attached panels follow
        -- the invoking placement.
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
        noctalia.log("wall-in-one widget: unknown IPC event '" .. tostring(event) .. "'")
    end
end

--!nonstrict
-- Attached Hub panel: gesture mapping, provider availability, staged feature
-- boundaries, and diagnostics. All writes go through the singleton service.

local STATUS_KEY = "director_status"
local COMMAND_KEY = "director_command"

local status = nil
local commandSequence = 0

local ACTIONS = {
    { id = "native_open", label = "actions.native_open", glyph = "photo" },
    { id = "native_next", label = "actions.native_next", glyph = "arrow-right" },
    { id = "native_previous", label = "actions.native_previous", glyph = "arrow-left" },
    { id = "native_random", label = "actions.native_random", glyph = "arrows-shuffle" },
    { id = "wallhaven_open", label = "actions.wallhaven_open", glyph = "world-search" },
    { id = "w_engine_open", label = "actions.w_engine_open", glyph = "movie" },
    { id = "director_open", label = "actions.director_open", glyph = "adjustments" },
    { id = "no_action", label = "actions.no_action", glyph = "ban" },
}

local OPEN_TARGETS = {
    native_open = "wallpaper",
    wallhaven_open = "noctalia/wallhaven:browser",
    w_engine_open = "tadomika_ari/w-engine:w-engine-panel",
    director_open = "goober/wallpaper-director:director",
}

local function nextSequence()
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    return commandSequence
end

local function send(request)
    local sequence = nextSequence()
    request.sequence = sequence
    request.producer = "panel"
    noctalia.state.set(COMMAND_KEY, request)
end

local function providers()
    if type(status) == "table" and type(status.providers) == "table" then
        return status.providers
    end
    return {
        probing = true,
        probe_ok = false,
        native = { available = true },
        wallhaven = { plugin_enabled = false, available = false },
        w_engine = { plugin_enabled = false, command_available = false, available = false },
    }
end

local function actionAvailable(action)
    if type(status) ~= "table" or status.storage_valid ~= true then
        return false
    end
    local current = providers()
    if action == "native_open" or action == "director_open" or action == "no_action" then
        return true
    end
    if action == "native_next" or action == "native_previous" or action == "native_random" then
        return current.noctalia_cli == true
    end
    if action == "wallhaven_open" then
        return type(current.wallhaven) == "table" and current.wallhaven.available == true
    end
    if action == "w_engine_open" then
        return type(current.w_engine) == "table" and current.w_engine.available == true
    end
    return false
end

local function actionLabel(action)
    for _, entry in ipairs(ACTIONS) do
        if entry.id == action then
            return noctalia.tr(entry.label)
        end
    end
    return tostring(action or "?")
end

local function pickerOptions(button)
    local configured = ""
    if type(status) == "table" and type(status.config) == "table" and type(status.config.gestures) == "table" then
        configured = tostring(status.config.gestures[button] or "")
    end

    local labels = {}
    local values = {}
    local selectedIndex = 0
    for _, entry in ipairs(ACTIONS) do
        local available = actionAvailable(entry.id)
        if available or entry.id == configured then
            local label = noctalia.tr(entry.label)
            if not available and entry.id == configured then
                label = noctalia.tr("actions.configured_unavailable", { action = label })
            end
            table.insert(labels, label)
            table.insert(values, entry.id)
            if entry.id == configured then
                selectedIndex = #values - 1
            end
        end
    end
    return labels, values, selectedIndex
end

local function sectionHeader(glyph, title, body)
    return ui.column({ gap = 3, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = glyph, color = "primary" }),
            ui.label({ text = title, fontSize = 14, fontWeight = "bold" }),
        }),
        ui.label({ text = body, fontSize = 11, color = "on_surface_variant", maxLines = 4 }),
    })
end

local function gestureRow(button, label)
    local labels, values, selectedIndex = pickerOptions(button)
    return ui.row({ gap = 10, align = "center" }, {
        ui.label({ text = label, fontSize = 12, color = "on_surface", width = 92 }),
        ui.select({
            key = "gesture-" .. button,
            options = labels,
            selectedIndex = selectedIndex,
            enabled = type(status) == "table" and status.storage_valid == true,
            flexGrow = 1,
            onChange = function(index)
                local action = values[(math.floor(tonumber(index) or 0)) + 1]
                if action ~= nil then
                    send({ kind = "set_mapping", button = button, action = action })
                end
            end,
        }),
    })
end

local function providerCard(glyph, name, available, detail, action)
    local enabled = available and type(status) == "table" and status.storage_valid == true
    return ui.row({
        gap = 10,
        align = "center",
        padding = 10,
        radius = 10,
        fill = "surface_variant/0.35",
        border = if available then "primary/0.45" else "outline/0.35",
        borderWidth = 1,
    }, {
        ui.glyph({ name = glyph, color = if available then "primary" else "on_surface_variant" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = name, fontSize = 12, fontWeight = "bold" }),
            ui.label({ text = detail, fontSize = 10, color = "on_surface_variant", maxLines = 3 }),
        }),
        ui.button({
            text = noctalia.tr("panel.open"),
            glyph = "external-link",
            variant = "ghost",
            controlSize = "sm",
            enabled = enabled,
            onClick = function()
                local target = OPEN_TARGETS[action]
                if target ~= nil then
                    panel.close()
                    noctalia.togglePanel(target)
                end
            end,
        }),
    })
end

local function shortcutsSection()
    return ui.column({
        gap = 10,
        padding = 12,
        radius = 12,
        fill = "surface/0.8",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, {
        sectionHeader("mouse", noctalia.tr("panel.shortcuts.title"), noctalia.tr("panel.shortcuts.description")),
        gestureRow("left", noctalia.tr("panel.shortcuts.left")),
        gestureRow("middle", noctalia.tr("panel.shortcuts.middle")),
        gestureRow("right", noctalia.tr("panel.shortcuts.right")),
        ui.label({
            text = noctalia.tr("panel.shortcuts.shortcut_limit"),
            fontSize = 10,
            color = "tertiary",
            maxLines = 3,
        }),
    })
end

local function providersSection()
    local current = providers()
    local storageValid = type(status) == "table" and status.storage_valid == true
    local wallhaven = type(current.wallhaven) == "table" and current.wallhaven or {}
    local wEngine = type(current.w_engine) == "table" and current.w_engine or {}

    local wallhavenDetail = if wallhaven.available
        then noctalia.tr("providers.wallhaven.available")
        elseif current.probe_ok == false then noctalia.tr("providers.probe_failed")
        else noctalia.tr("providers.wallhaven.disabled")

    local wEngineDetail
    if wEngine.available then
        wEngineDetail = noctalia.tr("providers.w_engine.available")
    elseif current.probe_ok == false then
        wEngineDetail = noctalia.tr("providers.probe_failed")
    elseif not wEngine.plugin_enabled then
        wEngineDetail = noctalia.tr("providers.w_engine.disabled")
    else
        wEngineDetail = noctalia.tr("providers.w_engine.missing_command")
    end

    return ui.column({
        gap = 8,
        padding = 12,
        radius = 12,
        fill = "surface/0.8",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, {
        sectionHeader("affiliate", noctalia.tr("panel.providers.title"), noctalia.tr("panel.providers.description")),
        providerCard(
            "photo",
            noctalia.tr("providers.native.name"),
            true,
            noctalia.tr("providers.native.available"),
            "native_open"
        ),
        providerCard(
            "world-search",
            noctalia.tr("providers.wallhaven.name"),
            wallhaven.available == true,
            wallhavenDetail,
            "wallhaven_open"
        ),
        providerCard(
            "movie",
            noctalia.tr("providers.w_engine.name"),
            wEngine.available == true,
            wEngineDetail,
            "w_engine_open"
        ),
        ui.row({ gap = 8, align = "center" }, {
            ui.button({
                text = noctalia.tr("actions.native_previous"),
                glyph = "arrow-left",
                variant = "ghost",
                enabled = current.noctalia_cli == true and storageValid,
                onClick = function()
                    send({ kind = "action", action = "native_previous", output = noctalia.focusedOutputName() })
                end,
            }),
            ui.button({
                text = noctalia.tr("actions.native_random"),
                glyph = "arrows-shuffle",
                variant = "ghost",
                enabled = current.noctalia_cli == true and storageValid,
                onClick = function()
                    send({ kind = "action", action = "native_random", output = noctalia.focusedOutputName() })
                end,
            }),
            ui.button({
                text = noctalia.tr("actions.native_next"),
                glyph = "arrow-right",
                variant = "ghost",
                enabled = current.noctalia_cli == true and storageValid,
                onClick = function()
                    send({ kind = "action", action = "native_next", output = noctalia.focusedOutputName() })
                end,
            }),
        }),
    })
end

local function deferredSection(glyph, title, description, reason)
    return ui.column({
        gap = 6,
        padding = 12,
        radius = 12,
        fill = "surface_variant/0.25",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, {
        sectionHeader(glyph, title, description),
        ui.row({ gap = 7, align = "center" }, {
            ui.glyph({ name = "lock", color = "tertiary", size = 15 }),
            ui.label({ text = reason, fontSize = 10, color = "tertiary", maxLines = 4, flexGrow = 1 }),
        }),
    })
end

local function diagnosticsSection()
    local current = providers()
    local storageValid = type(status) == "table" and status.storage_valid == true
    local probeText = if current.probing
        then noctalia.tr("diagnostics.probing")
        elseif current.probe_ok then noctalia.tr(
            "diagnostics.probe_ok",
            { time = tostring(current.probed_at or "") }
        )
        else noctalia.tr("diagnostics.probe_error", { error = tostring(current.probe_error or "") })

    local storageText = if storageValid
        then noctalia.tr("diagnostics.storage_ok")
        else noctalia.tr("diagnostics.storage_error", {
            config = tostring(type(status) == "table" and status.config_error or ""),
            runtime = tostring(type(status) == "table" and status.runtime_error or ""),
        })

    return ui.column({
        gap = 8,
        padding = 12,
        radius = 12,
        fill = "surface/0.8",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, {
        sectionHeader(
            "stethoscope",
            noctalia.tr("panel.diagnostics.title"),
            noctalia.tr("panel.diagnostics.description")
        ),
        ui.label({
            text = storageText,
            fontSize = 10,
            color = if storageValid then "primary" else "error",
            maxLines = 5,
        }),
        ui.label({ text = probeText, fontSize = 10, color = "on_surface_variant", maxLines = 5 }),
        ui.label({
            text = noctalia.tr("diagnostics.ownership"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 5,
        }),
        ui.button({
            text = noctalia.tr("panel.reprobe"),
            glyph = "refresh",
            variant = "ghost",
            enabled = not current.probing,
            onClick = function()
                send({ kind = "probe" })
            end,
        }),
    })
end

local function render()
    panel.render(ui.column({ gap = 10, padding = 14, align = "stretch" }, {
        ui.row({ gap = 9, align = "center" }, {
            ui.glyph({ name = "library-photo", color = "primary", size = 22 }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = noctalia.tr("plugin.title"), fontSize = 16, fontWeight = "bold" }),
                ui.label({ text = noctalia.tr("panel.subtitle"), fontSize = 10, color = "on_surface_variant" }),
            }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onClose" }),
        }),
        ui.separator(),
        ui.scroll({ flexGrow = 1, align = "stretch", gap = 10 }, {
            shortcutsSection(),
            providersSection(),
            deferredSection(
                "layers-subtract",
                noctalia.tr("panel.pairing.title"),
                noctalia.tr("panel.pairing.description"),
                noctalia.tr("panel.pairing.deferred")
            ),
            deferredSection(
                "playlist",
                noctalia.tr("panel.reels.title"),
                noctalia.tr("panel.reels.description"),
                noctalia.tr("panel.reels.deferred")
            ),
            diagnosticsSection(),
        }),
    }))
end

function onOpen(_context)
    status = noctalia.state.get(STATUS_KEY)
    render()
    send({ kind = "probe" })
end

function onClose()
    panel.close()
end

function onIpc(event, payload)
    if event == "probe" then
        send({ kind = "probe" })
    elseif event == "open-provider" then
        local aliases = {
            native = "native_open",
            wallhaven = "wallhaven_open",
            w_engine = "w_engine_open",
        }
        local action = aliases[tostring(payload or "")]
        if action ~= nil then
            local target = OPEN_TARGETS[action]
            if target ~= nil and actionAvailable(action) then
                panel.close()
                noctalia.togglePanel(target)
            else
                send({ kind = "action", action = action, output = noctalia.focusedOutputName() })
            end
        end
    else
        noctalia.log("wallpaper-director panel: unknown IPC event '" .. tostring(event) .. "'")
    end
end

noctalia.state.watch(STATUS_KEY, function(nextStatus)
    status = nextStatus
    render()
end)
status = noctalia.state.get(STATUS_KEY)
render()

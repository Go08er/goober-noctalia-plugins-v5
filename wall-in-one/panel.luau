--!nonstrict
-- Wall-in-One attached hub. Provider processes stay provider-owned; this panel
-- only sends commands to the singleton coordinator service or opens a public
-- provider panel from the user's click callback.

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"

local status = nil
local commandSequence = 0

local ACTIONS = {
    { id = "native_open", label = "actions.native_open" },
    { id = "native_next", label = "actions.native_next" },
    { id = "native_previous", label = "actions.native_previous" },
    { id = "native_random", label = "actions.native_random" },
    { id = "wallhaven_open", label = "actions.wallhaven_open" },
    { id = "w_engine_open", label = "actions.w_engine_open" },
    { id = "w_engine_next", label = "actions.w_engine_next" },
    { id = "w_engine_cycle_stop", label = "actions.w_engine_cycle_stop" },
    { id = "w_engine_stop", label = "actions.w_engine_stop" },
    { id = "mpvpaper_open", label = "actions.mpvpaper_open" },
    { id = "mpvpaper_pause", label = "actions.mpvpaper_pause" },
    { id = "mpvpaper_resume", label = "actions.mpvpaper_resume" },
    { id = "mpvpaper_toggle", label = "actions.mpvpaper_toggle" },
    { id = "mpvpaper_clear", label = "actions.mpvpaper_clear" },
    { id = "mpvpaper_clear_all", label = "actions.mpvpaper_clear_all" },
    { id = "capture_current", label = "actions.capture_current" },
    { id = "capture_pair", label = "actions.capture_pair" },
    { id = "video_capture", label = "actions.video_capture" },
    { id = "video_capture_pair", label = "actions.video_capture_pair" },
    { id = "manual_pair", label = "actions.manual_pair" },
    { id = "extra_provider_open", label = "actions.extra_provider_open" },
    { id = "hub_open", label = "actions.hub_open" },
    { id = "no_action", label = "actions.no_action" },
}

local OPEN_TARGETS = {
    native_open = "wallpaper",
    wallhaven_open = "noctalia/wallhaven:browser",
    w_engine_open = "tadomika_ari/w-engine:w-engine-panel",
    mpvpaper_open = "noctalia/mpvpaper:picker",
    hub_open = "goober/wall-in-one:hub",
}

local function focusedOutput()
    local output = noctalia.focusedOutputName()
    return if type(output) == "string" then output else ""
end

local function providers()
    if type(status) == "table" and type(status.providers) == "table" then
        return status.providers
    end
    return {
        probing = true,
        probe_ok = false,
        noctalia_cli = false,
        native = { available = true },
        wallhaven = { plugin_enabled = false, available = false },
        w_engine = {
            plugin_enabled = false,
            renderer_available = false,
            available = false,
            adapter_version = "",
            adapter_capture = false,
            adapter_status = false,
            current = {},
        },
        mpvpaper = { plugin_enabled = false, command_available = false, available = false },
        extra = { configured = false, plugin_enabled = false, available = false, panel = "" },
    }
end

local function settings()
    if type(status) == "table" and type(status.settings) == "table" then
        return status.settings
    end
    return {
        capture_directory = "",
        auto_capture = false,
        pair_static = false,
        sync_colors = false,
        color_scheme = "",
        palette_output = "",
        video_source = "",
        manual_pair_file = "",
        workshop_id = "",
        video_frame_second = 1,
        extra_provider_panel = "",
    }
end

local function storageValid()
    return type(status) == "table" and status.storage_valid == true
end

local function nextSequence()
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    return commandSequence
end

local function send(request)
    request.sequence = nextSequence()
    request.producer = "hub-panel"
    noctalia.state.set(COMMAND_KEY, request)
end

local function actionLabel(action)
    for _, entry in ipairs(ACTIONS) do
        if entry.id == action then
            return noctalia.tr(entry.label)
        end
    end
    return tostring(action or "?")
end

local function actionAvailable(action)
    if not storageValid() then
        return false
    end
    local current = providers()
    local output = focusedOutput()
    if action == "native_open" or action == "hub_open" or action == "no_action" then
        return true
    elseif action == "native_next" or action == "native_previous" or action == "native_random" then
        return current.noctalia_cli == true
    elseif action == "wallhaven_open" then
        return type(current.wallhaven) == "table" and current.wallhaven.available == true
    elseif action == "w_engine_open" then
        return type(current.w_engine) == "table" and current.w_engine.available == true
    elseif action == "w_engine_next" or action == "w_engine_cycle_stop" or action == "w_engine_stop" then
        return type(current.w_engine) == "table"
            and current.w_engine.plugin_enabled == true
            and current.noctalia_cli == true
    elseif action == "mpvpaper_open" then
        return type(current.mpvpaper) == "table" and current.mpvpaper.available == true
    elseif
        action == "mpvpaper_pause"
        or action == "mpvpaper_resume"
        or action == "mpvpaper_toggle"
        or action == "mpvpaper_clear"
        or action == "mpvpaper_clear_all"
    then
        return type(current.mpvpaper) == "table"
            and current.mpvpaper.plugin_enabled == true
            and current.noctalia_cli == true
    elseif action == "capture_current" or action == "capture_pair" then
        local adapterId = type(current.w_engine) == "table"
                and type(current.w_engine.current) == "table"
                and output ~= ""
                and tostring(current.w_engine.current[output] or "")
            or ""
        return adapterId:match("^%d+$") ~= nil or tostring(settings().workshop_id or ""):match("^%d+$") ~= nil
    elseif action == "video_capture" or action == "video_capture_pair" then
        return tostring(settings().video_source or "") ~= ""
    elseif action == "manual_pair" then
        return tostring(settings().manual_pair_file or "") ~= ""
    elseif action == "extra_provider_open" then
        return type(current.extra) == "table" and current.extra.available == true
    end
    return false
end

local function panelTarget(action)
    if action == "extra_provider_open" then
        local extra = providers().extra
        return if type(extra) == "table" then tostring(extra.panel or "") else ""
    end
    return OPEN_TARGETS[action] or ""
end

local function openProvider(action)
    local target = panelTarget(action)
    if target ~= "" and actionAvailable(action) then
        panel.close()
        noctalia.togglePanel(target)
    else
        send({ kind = "action", action = action, output = focusedOutput() })
    end
end

local function runAction(action)
    send({ kind = "action", action = action, output = focusedOutput() })
end

local function boolText(value)
    return if value == true then noctalia.tr("common.on") else noctalia.tr("common.off")
end

local function valueOr(value, fallbackKey)
    local text = tostring(value or "")
    return if text == "" then noctalia.tr(fallbackKey) else text
end

local function sectionHeader(glyph, title, body)
    return ui.column({ gap = 3, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = glyph, color = "primary" }),
            ui.label({ text = title, fontSize = 14, fontWeight = "bold", flexGrow = 1 }),
        }),
        ui.label({ text = body, fontSize = 11, color = "on_surface_variant", maxLines = 5 }),
    })
end

local function card(children)
    return ui.column({
        gap = 8,
        padding = 12,
        radius = 12,
        fill = "surface/0.8",
        border = "outline/0.25",
        borderWidth = 1,
        align = "stretch",
    }, children)
end

local function actionButton(action, glyph, variant, grow)
    return ui.button({
        text = actionLabel(action),
        glyph = glyph,
        variant = variant or "ghost",
        controlSize = "sm",
        enabled = actionAvailable(action),
        flexGrow = grow == true and 1 or 0,
        onClick = function()
            runAction(action)
        end,
    })
end

local function gestureOptions(button)
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

local function gestureRow(button, label)
    local labels, values, selectedIndex = gestureOptions(button)
    return ui.row({ gap = 10, align = "center" }, {
        ui.label({ text = label, width = 92, fontSize = 12 }),
        ui.select({
            key = "gesture-" .. button,
            options = labels,
            selectedIndex = selectedIndex,
            enabled = storageValid(),
            flexGrow = 1,
            onChange = function(index)
                local action = values[math.floor(tonumber(index) or 0) + 1]
                if action ~= nil then
                    send({ kind = "set_mapping", button = button, action = action })
                end
            end,
        }),
    })
end

local function shortcutsSection()
    return card({
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

local function providerRow(glyph, title, available, detail, action)
    return ui.row({
        gap = 10,
        align = "center",
        padding = 10,
        radius = 10,
        fill = "surface_variant/0.3",
        border = if available then "primary/0.45" else "outline/0.3",
        borderWidth = 1,
    }, {
        ui.glyph({ name = glyph, color = if available then "primary" else "on_surface_variant" }),
        ui.column({ gap = 2, flexGrow = 1 }, {
            ui.label({ text = title, fontSize = 12, fontWeight = "bold" }),
            ui.label({ text = detail, fontSize = 10, color = "on_surface_variant", maxLines = 4 }),
        }),
        ui.button({
            text = noctalia.tr("panel.open"),
            glyph = "external-link",
            variant = "ghost",
            controlSize = "sm",
            enabled = available and storageValid(),
            onClick = function()
                openProvider(action)
            end,
        }),
    })
end

local function providersSection()
    local current = providers()
    local wallhaven = type(current.wallhaven) == "table" and current.wallhaven or {}
    local wEngine = type(current.w_engine) == "table" and current.w_engine or {}
    local mpvpaper = type(current.mpvpaper) == "table" and current.mpvpaper or {}
    local extra = type(current.extra) == "table" and current.extra or {}

    local wallhavenDetail = if wallhaven.available == true
        then noctalia.tr("providers.wallhaven.available")
        elseif current.probe_ok == false then noctalia.tr("providers.probe_failed")
        else noctalia.tr("providers.wallhaven.disabled")
    local wEngineDetail
    if wEngine.available == true and wEngine.adapter_capture == true and wEngine.adapter_status == true then
        wEngineDetail =
            noctalia.tr("providers.w_engine.adapter_full", { version = tostring(wEngine.adapter_version or "") })
    elseif wEngine.available == true and wEngine.adapter_status == true then
        wEngineDetail =
            noctalia.tr("providers.w_engine.adapter_status", { version = tostring(wEngine.adapter_version or "") })
    elseif wEngine.available == true and wEngine.renderer_available == true then
        wEngineDetail = noctalia.tr("providers.w_engine.no_adapter")
    elseif wEngine.available == true then
        wEngineDetail = noctalia.tr("providers.w_engine.missing_renderer")
    elseif current.probe_ok == false then
        wEngineDetail = noctalia.tr("providers.probe_failed")
    elseif wEngine.plugin_enabled ~= true then
        wEngineDetail = noctalia.tr("providers.w_engine.disabled")
    else
        wEngineDetail = noctalia.tr("providers.w_engine.disabled")
    end
    local mpvpaperDetail = if mpvpaper.available == true and mpvpaper.command_available == true
        then noctalia.tr("providers.mpvpaper.available")
        elseif mpvpaper.available == true then noctalia.tr("providers.mpvpaper.missing_commands")
        elseif current.probe_ok == false then noctalia.tr("providers.probe_failed")
        else noctalia.tr("providers.mpvpaper.disabled")
    local extraDetail
    if extra.available == true then
        extraDetail = noctalia.tr("providers.extra.available", { panel = tostring(extra.panel or "") })
    elseif extra.configured ~= true then
        extraDetail = noctalia.tr("providers.extra.unconfigured")
    elseif current.probe_ok == false then
        extraDetail = noctalia.tr("providers.probe_failed")
    else
        extraDetail = noctalia.tr("providers.extra.disabled", { id = tostring(extra.plugin_id or "") })
    end

    return card({
        sectionHeader("affiliate", noctalia.tr("panel.providers.title"), noctalia.tr("panel.providers.description")),
        providerRow(
            "photo",
            noctalia.tr("providers.native.name"),
            true,
            noctalia.tr("providers.native.available"),
            "native_open"
        ),
        providerRow(
            "world-search",
            noctalia.tr("providers.wallhaven.name"),
            wallhaven.available == true,
            wallhavenDetail,
            "wallhaven_open"
        ),
        providerRow(
            "movie",
            noctalia.tr("providers.w_engine.name"),
            wEngine.available == true,
            wEngineDetail,
            "w_engine_open"
        ),
        providerRow(
            "player-play",
            noctalia.tr("providers.mpvpaper.name"),
            mpvpaper.available == true,
            mpvpaperDetail,
            "mpvpaper_open"
        ),
        providerRow(
            "plug-connected",
            noctalia.tr("providers.extra.name"),
            extra.available == true,
            extraDetail,
            "extra_provider_open"
        ),
        ui.label({ text = noctalia.tr("panel.providers.native_controls"), fontSize = 11, fontWeight = "bold" }),
        ui.row({ gap = 6, align = "center" }, {
            actionButton("native_previous", "arrow-left", "ghost", true),
            actionButton("native_random", "arrows-shuffle", "ghost", true),
            actionButton("native_next", "arrow-right", "ghost", true),
        }),
        ui.label({ text = noctalia.tr("panel.providers.w_engine_controls"), fontSize = 11, fontWeight = "bold" }),
        ui.row({ gap = 6, align = "center" }, {
            actionButton("w_engine_next", "player-skip-forward", "ghost", true),
            actionButton("w_engine_cycle_stop", "player-pause", "ghost", true),
            actionButton("w_engine_stop", "player-stop", "ghost", true),
        }),
        ui.label({ text = noctalia.tr("panel.providers.mpvpaper_controls"), fontSize = 11, fontWeight = "bold" }),
        ui.row({ gap = 6, align = "center" }, {
            actionButton("mpvpaper_pause", "player-pause", "ghost", true),
            actionButton("mpvpaper_resume", "player-play", "ghost", true),
            actionButton("mpvpaper_toggle", "player-track-next", "ghost", true),
        }),
        ui.row({ gap = 6, align = "center" }, {
            actionButton("mpvpaper_clear", "eraser", "ghost", true),
            actionButton("mpvpaper_clear_all", "trash", "ghost", true),
        }),
        ui.label({
            text = noctalia.tr("panel.providers.control_boundary"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 4,
        }),
    })
end

local function captureSection()
    local current = providers()
    local wEngine = type(current.w_engine) == "table" and current.w_engine or {}
    local output = focusedOutput()
    local adapterId = if type(wEngine.current) == "table" then tostring(wEngine.current[output] or "") else ""
    local configuration = settings()
    local configuredId = tostring(configuration.workshop_id or "")
    local capture = type(status) == "table" and type(status.last_capture) == "table" and status.last_capture or {}
    local active = type(status) == "table" and type(status.captures) == "table" and status.captures[output] or nil

    local workshopText
    if adapterId ~= "" and wEngine.adapter_capture == true then
        workshopText = noctalia.tr("capture.w_engine_adapter_capture", {
            output = valueOr(output, "common.unknown"),
            id = adapterId,
        })
    elseif adapterId ~= "" then
        workshopText = noctalia.tr("capture.w_engine_adapter_status", {
            output = valueOr(output, "common.unknown"),
            id = adapterId,
        })
    elseif configuredId ~= "" then
        workshopText = noctalia.tr("capture.w_engine_configured", { id = configuredId })
    else
        workshopText = noctalia.tr("capture.w_engine_unavailable")
    end
    local captureText = if type(active) == "table"
        then noctalia.tr("capture.in_progress", { path = tostring(active.destination or "") })
        elseif tostring(capture.path or "") ~= "" then noctalia.tr("capture.last", {
            provider = tostring(capture.provider or ""),
            time = tostring(capture.captured_at or ""),
            path = tostring(capture.path or ""),
        })
        else noctalia.tr("capture.none")

    return card({
        sectionHeader("photo-down", noctalia.tr("panel.capture.title"), noctalia.tr("panel.capture.description")),
        ui.label({
            text = noctalia.tr(
                "capture.directory",
                { path = valueOr(configuration.capture_directory, "common.unset") }
            ),
            maxLines = 3,
        }),
        ui.label({
            text = noctalia.tr("capture.video_source", {
                path = valueOr(configuration.video_source, "common.unset"),
                second = tostring(configuration.video_frame_second or 1),
            }),
            color = "on_surface_variant",
            maxLines = 4,
        }),
        ui.row({ gap = 6, align = "center" }, {
            actionButton("video_capture", "photo-down", "ghost", true),
            actionButton("video_capture_pair", "layers-intersect", "primary", true),
        }),
        ui.label({
            text = noctalia.tr("capture.video_requirement"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 4,
        }),
        ui.separator(),
        ui.label({
            text = noctalia.tr("capture.manual_source", {
                path = valueOr(configuration.manual_pair_file, "common.unset"),
            }),
            fontSize = 11,
            fontWeight = "bold",
            maxLines = 3,
        }),
        actionButton("manual_pair", "photo-check", "primary", true),
        ui.label({
            text = noctalia.tr("capture.manual_behavior"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 4,
        }),
        ui.separator(),
        ui.label({ text = workshopText, fontSize = 11, fontWeight = "bold", maxLines = 4 }),
        ui.row({ gap = 6, align = "center" }, {
            actionButton("capture_current", "photo-down", "ghost", true),
            actionButton("capture_pair", "layers-intersect", "primary", true),
        }),
        ui.label({
            text = if wEngine.adapter_capture == true and adapterId ~= ""
                then noctalia.tr("capture.w_engine_adapter_boundary")
                else noctalia.tr("capture.w_engine_fallback_boundary"),
            fontSize = 10,
            color = "tertiary",
            maxLines = 6,
        }),
        ui.separator(),
        ui.label({ text = captureText, fontSize = 10, color = "on_surface_variant", maxLines = 5 }),
    })
end

local function pairingSection()
    local configuration = settings()
    local output = focusedOutput()
    local allPairs = type(status) == "table" and type(status.pairs) == "table" and status.pairs or {}
    local pair = type(allPairs[output]) == "table" and allPairs[output] or allPairs.all
    local pairText = if type(pair) == "table"
        then noctalia.tr("pairing.current", {
            output = valueOr(output, "common.all_outputs"),
            provider = tostring(pair.provider or ""),
            path = tostring(pair.still_path or ""),
        })
        else noctalia.tr("pairing.none", { output = valueOr(output, "common.all_outputs") })

    local colors = type(status) == "table" and type(status.colors) == "table" and status.colors or {}
    local activeColor = if tostring(colors.source or "") == ""
        then noctalia.tr("common.unknown")
        else tostring(colors.source) .. " / " .. tostring(colors.scheme or "")
    return card({
        sectionHeader("layers-intersect", noctalia.tr("panel.pairing.title"), noctalia.tr("panel.pairing.description")),
        ui.label({ text = pairText, maxLines = 5 }),
        ui.label({
            text = noctalia.tr("pairing.settings", {
                automatic = boolText(configuration.auto_capture),
                pair = boolText(configuration.pair_static),
                colors = boolText(configuration.sync_colors),
            }),
            color = "on_surface_variant",
            maxLines = 3,
        }),
        ui.label({
            text = noctalia.tr("pairing.palette", {
                configured = tostring(configuration.color_scheme or ""),
                leader = valueOr(configuration.palette_output, "pairing.last_applied"),
                active = activeColor,
            }),
            color = "on_surface_variant",
            maxLines = 5,
        }),
        ui.label({
            text = noctalia.tr("pairing.behavior"),
            fontSize = 10,
            color = "primary",
            maxLines = 5,
        }),
        ui.label({
            text = noctalia.tr("pairing.global_palette"),
            fontSize = 10,
            color = "tertiary",
            maxLines = 5,
        }),
        ui.label({
            text = noctalia.tr("pairing.lockscreen_override"),
            fontSize = 10,
            color = "tertiary",
            maxLines = 5,
        }),
        ui.button({
            text = noctalia.tr("panel.settings"),
            glyph = "settings",
            variant = "ghost",
            onClick = "onSettings",
        }),
    })
end

local function diagnosticsSection()
    local current = providers()
    local probeText = if current.probing == true
        then noctalia.tr("diagnostics.probing")
        elseif current.probe_ok == true then noctalia.tr(
            "diagnostics.probe_ok",
            { time = tostring(current.probed_at or "") }
        )
        else noctalia.tr("diagnostics.probe_error", { error = tostring(current.probe_error or "") })
    local storageText = if storageValid()
        then noctalia.tr("diagnostics.storage_ok")
        else noctalia.tr("diagnostics.storage_error", {
            config = tostring(type(status) == "table" and status.config_error or ""),
            runtime = tostring(type(status) == "table" and status.runtime_error or ""),
        })
    local actionError = type(status) == "table" and tostring(status.last_action_error or "") or ""

    local children = {
        sectionHeader(
            "stethoscope",
            noctalia.tr("panel.diagnostics.title"),
            noctalia.tr("panel.diagnostics.description")
        ),
        ui.label({
            text = storageText,
            fontSize = 10,
            color = if storageValid() then "primary" else "error",
            maxLines = 5,
        }),
        ui.label({ text = probeText, fontSize = 10, color = "on_surface_variant", maxLines = 5 }),
        ui.label({
            text = noctalia.tr("diagnostics.ownership"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 6,
        }),
    }
    if actionError ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("diagnostics.last_action_error", { error = actionError }),
                fontSize = 10,
                color = "error",
                maxLines = 6,
            })
        )
    end
    table.insert(
        children,
        ui.button({
            text = noctalia.tr("panel.reprobe"),
            glyph = "refresh",
            variant = "ghost",
            enabled = current.probing ~= true,
            onClick = function()
                send({ kind = "probe" })
            end,
        })
    )
    return card(children)
end

local function render()
    panel.render(ui.column({ gap = 10, padding = 14, align = "stretch" }, {
        ui.row({ gap = 9, align = "center" }, {
            ui.glyph({ name = "library-photo", color = "primary", size = 22 }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = noctalia.tr("plugin.title"), fontSize = 16, fontWeight = "bold" }),
                ui.label({ text = noctalia.tr("panel.subtitle"), fontSize = 10, color = "on_surface_variant" }),
            }),
            ui.button({
                glyph = "settings",
                variant = "ghost",
                tooltip = noctalia.tr("panel.settings"),
                onClick = "onSettings",
            }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onClose" }),
        }),
        ui.separator(),
        ui.scroll({ flexGrow = 1, align = "stretch", gap = 10 }, {
            shortcutsSection(),
            providersSection(),
            captureSection(),
            pairingSection(),
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

function onSettings()
    noctalia.openSettings()
end

function onIpc(event, payload)
    local aliases = {
        native = "native_open",
        wallhaven = "wallhaven_open",
        w_engine = "w_engine_open",
        mpvpaper = "mpvpaper_open",
        extra = "extra_provider_open",
    }
    if event == "probe" then
        send({ kind = "probe" })
    elseif event == "open-provider" then
        local action = aliases[tostring(payload or "")]
        if action ~= nil then
            openProvider(action)
        end
    elseif event == "capture-video" then
        runAction("video_capture")
    elseif event == "capture-video-pair" then
        runAction("video_capture_pair")
    elseif event == "capture-w-engine" then
        runAction("capture_current")
    elseif event == "capture-w-engine-pair" then
        runAction("capture_pair")
    elseif event == "pair-manual" then
        runAction("manual_pair")
    else
        noctalia.log("wall-in-one panel: unknown IPC event '" .. tostring(event) .. "'")
    end
end

noctalia.state.watch(STATUS_KEY, function(nextStatus)
    status = nextStatus
    render()
end)
status = noctalia.state.get(STATUS_KEY)
render()

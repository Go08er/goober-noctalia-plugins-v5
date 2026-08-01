--!nonstrict
-- Wall-in-One attached hub. It controls the coordinator and the renderer owner
-- only through versioned shared state, and opens external providers explicitly.

local STATUS_KEY = "wall_in_one_status"
local COMMAND_KEY = "wall_in_one_command"

local status = nil
local commandSequence = 0
local cycleIntervalDraft = ""
local motionSearchDraft = ""

local ACTIONS = {
    { id = "native_open", label = "actions.native_open" },
    { id = "native_next", label = "actions.native_next" },
    { id = "native_previous", label = "actions.native_previous" },
    { id = "native_random", label = "actions.native_random" },
    { id = "wallhaven_open", label = "actions.wallhaven_open" },
    { id = "motionbgs_open", label = "actions.motionbgs_open" },
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
    { id = "capture_backing", label = "actions.capture_backing" },
    { id = "capture_current", label = "actions.capture_current" },
    { id = "capture_pair", label = "actions.capture_pair" },
    { id = "video_capture", label = "actions.video_capture" },
    { id = "video_capture_pair", label = "actions.video_capture_pair" },
    { id = "video_apply_pair", label = "actions.video_apply_pair" },
    { id = "workshop_apply_pair", label = "actions.workshop_apply_pair" },
    { id = "cycle_start", label = "actions.cycle_start" },
    { id = "cycle_stop", label = "actions.cycle_stop" },
    { id = "cycle_pause", label = "actions.cycle_pause" },
    { id = "cycle_resume", label = "actions.cycle_resume" },
    { id = "cycle_next", label = "actions.cycle_next" },
    { id = "cycle_previous", label = "actions.cycle_previous" },
    { id = "cycle_random", label = "actions.cycle_random" },
    { id = "cycle_add_static", label = "actions.cycle_add_static" },
    { id = "cycle_add_video", label = "actions.cycle_add_video" },
    { id = "cycle_add_workshop", label = "actions.cycle_add_workshop" },
    { id = "cycle_remove_last", label = "actions.cycle_remove_last" },
    { id = "cycle_clear", label = "actions.cycle_clear" },
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
        wallhaven = { allowed = true, plugin_enabled = false, available = false },
        w_engine = {
            allowed = true,
            plugin_enabled = false,
            renderer_available = false,
            available = false,
            adapter_version = "",
            adapter_capture = false,
            adapter_status = false,
            current = {},
        },
        mpvpaper = { allowed = true, plugin_enabled = false, command_available = false, available = false },
        motionbgs = {
            allowed = true,
            available = false,
            browser_available = false,
            integration_available = false,
            url = "https://motionbgs.com/",
        },
        extra = { allowed = true, configured = false, plugin_enabled = false, available = false, panel = "" },
    }
end

local function entryForOutput(entry, output)
    local copied = {}
    if type(entry) == "table" then
        for key, value in pairs(entry) do
            copied[key] = value
        end
    end

    local allPairs = type(status) == "table" and type(status.pairs) == "table" and status.pairs or {}
    local pair = if output ~= "" and type(allPairs[output]) == "table" then allPairs[output] else allPairs.all
    local stillPath = if type(pair) == "table" and type(pair.still_path) == "string" then pair.still_path else ""
    if stillPath:sub(1, 1) == "/" and stillPath:find("[%c]") == nil and noctalia.fileExists(stillPath) then
        copied.still_path = stillPath
    end
    return copied
end

local function settings()
    if type(status) == "table" and type(status.settings) == "table" then
        return status.settings
    end
    return {
        use_wallhaven = true,
        use_w_engine = true,
        use_mpvpaper = true,
        use_motionbgs = true,
        use_extra_provider = true,
        w_engine_backend = "auto",
        mpvpaper_backend = "auto",
        capture_directory = "",
        video_directory = "",
        auto_capture = false,
        pair_static = false,
        sync_colors = false,
        color_scheme = "",
        palette_output = "",
        video_source = "",
        manual_pair_file = "",
        workshop_id = "",
        video_frame_second = 1,
        cycle_interval_minutes = 15,
        cycle_order = "sequential",
        extra_provider_panel = "",
    }
end

local function motionBgsData()
    local value = type(status) == "table" and type(status.motionbgs) == "table" and status.motionbgs or {}
    return type(value.status) == "table" and value.status or {},
        type(value.results) == "table" and value.results or { items = {}, selected = {} }
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
    if action == "motionbgs_open" then
        local current = providers()
        return type(current.motionbgs) == "table" and current.motionbgs.browser_available == true
    end
    if not storageValid() then
        return false
    end
    local current = providers()
    local wEngine = type(current.w_engine) == "table" and current.w_engine or {}
    local mpvpaper = type(current.mpvpaper) == "table" and current.mpvpaper or {}
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
        return type(current.w_engine) == "table" and current.w_engine.available == true and current.noctalia_cli == true
    elseif action == "mpvpaper_open" then
        return type(current.mpvpaper) == "table" and current.mpvpaper.available == true
    elseif
        action == "mpvpaper_pause"
        or action == "mpvpaper_resume"
        or action == "mpvpaper_toggle"
        or action == "mpvpaper_clear"
        or action == "mpvpaper_clear_all"
    then
        return type(current.mpvpaper) == "table" and current.mpvpaper.available == true and current.noctalia_cli == true
    elseif action == "capture_backing" then
        return current.noctalia_cli == true and output ~= ""
    elseif action == "capture_current" or action == "capture_pair" then
        local adapterId = type(current.w_engine) == "table"
                and type(current.w_engine.current) == "table"
                and output ~= ""
                and tostring(current.w_engine.current[output] or "")
            or ""
        return wEngine.allowed == true
            and (adapterId:match("^%d+$") ~= nil or tostring(settings().workshop_id or ""):match("^%d+$") ~= nil)
    elseif action == "video_capture" or action == "video_capture_pair" then
        return tostring(settings().video_source or "") ~= ""
    elseif action == "video_apply_pair" then
        return mpvpaper.apply_available == true and tostring(settings().video_source or "") ~= ""
    elseif action == "workshop_apply_pair" then
        return wEngine.apply_available == true and tostring(settings().workshop_id or ""):match("^%d+$") ~= nil
    elseif action == "cycle_add_static" then
        return current.noctalia_cli == true and output ~= ""
    elseif action == "cycle_add_video" then
        return tostring(settings().video_source or "") ~= ""
    elseif action == "cycle_add_workshop" then
        return tostring(settings().workshop_id or ""):match("^%d+$") ~= nil
    elseif
        action == "cycle_start"
        or action == "cycle_stop"
        or action == "cycle_pause"
        or action == "cycle_resume"
        or action == "cycle_next"
        or action == "cycle_previous"
        or action == "cycle_random"
        or action == "cycle_remove_last"
        or action == "cycle_clear"
    then
        local reels = type(status) == "table"
                and type(status.config) == "table"
                and type(status.config.reels) == "table"
                and status.config.reels
            or {}
        local reel = type(reels[output]) == "table" and reels[output] or {}
        if action == "cycle_next" or action == "cycle_previous" or action == "cycle_random" then
            local cycles = type(status) == "table" and type(status.cycles) == "table" and status.cycles or {}
            local state = type(cycles[output]) == "table" and cycles[output] or {}
            if state.paused == true then
                return false
            end
        end
        return type(reel.entries) == "table" and #reel.entries > 0
    elseif action == "manual_pair" then
        return output ~= "" and tostring(settings().manual_pair_file or "") ~= ""
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
            enabled = available and (storageValid() or action == "motionbgs_open"),
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
    local motionbgs = type(current.motionbgs) == "table" and current.motionbgs or {}
    local extra = type(current.extra) == "table" and current.extra or {}

    local wallhavenDetail = if wallhaven.available == true
        then noctalia.tr("providers.wallhaven.available")
        elseif wallhaven.plugin_enabled == true and wallhaven.allowed == false then noctalia.tr(
            "providers.wallhaven.forced_off"
        )
        elseif current.probe_ok == false then noctalia.tr("providers.probe_failed")
        else noctalia.tr("providers.wallhaven.disabled")
    local wEngineDetail
    if wEngine.plugin_enabled == true and wEngine.allowed == false then
        wEngineDetail = noctalia.tr("providers.w_engine.forced_off")
    elseif wEngine.available == true and wEngine.adapter_capture == true and wEngine.adapter_status == true then
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
        elseif mpvpaper.plugin_enabled == true and mpvpaper.allowed == false then noctalia.tr(
            "providers.mpvpaper.forced_off"
        )
        elseif current.probe_ok == false then noctalia.tr("providers.probe_failed")
        else noctalia.tr("providers.mpvpaper.disabled")
    local motionStatus = motionBgsData()
    local motionDetail
    if motionbgs.integration_available == true then
        motionDetail = noctalia.tr("providers.motionbgs.integrated")
    elseif motionbgs.allowed ~= true then
        motionDetail = noctalia.tr("providers.motionbgs.disabled")
    elseif motionStatus.site_changed == true then
        motionDetail = noctalia.tr("providers.motionbgs.site_changed")
    else
        motionDetail = noctalia.tr("providers.motionbgs.fallback")
    end
    local extraDetail
    if extra.available == true then
        extraDetail = noctalia.tr("providers.extra.available", { panel = tostring(extra.panel or "") })
    elseif extra.plugin_enabled == true and extra.allowed == false then
        extraDetail = noctalia.tr("providers.extra.forced_off")
    elseif extra.configured ~= true then
        extraDetail = noctalia.tr("providers.extra.unconfigured")
    elseif current.probe_ok == false then
        extraDetail = noctalia.tr("providers.probe_failed")
    else
        extraDetail = noctalia.tr("providers.extra.disabled", { id = tostring(extra.plugin_id or "") })
    end
    local function backendDetail(provider)
        if provider.conflict == true then
            return noctalia.tr("providers.backend.conflict")
        elseif tostring(provider.effective_backend or "") == "internal" then
            return noctalia.tr("providers.backend.internal")
        elseif tostring(provider.effective_backend or "") == "external" then
            return noctalia.tr("providers.backend.external")
        end
        return noctalia.tr("providers.backend.missing")
    end
    wEngineDetail ..= "\n" .. backendDetail(wEngine)
    mpvpaperDetail ..= "\n" .. backendDetail(mpvpaper)

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
            noctalia.tr("providers.motionbgs.name"),
            motionbgs.browser_available == true,
            motionDetail,
            "motionbgs_open"
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

local function libraryEntryRow(glyph, title, detail, entry, canApply)
    return ui.row({
        gap = 8,
        align = "center",
        padding = 8,
        radius = 9,
        fill = "surface_variant/0.25",
    }, {
        ui.glyph({ name = glyph, color = "primary" }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = title, fontSize = 11, fontWeight = "bold", maxLines = 2 }),
            ui.label({ text = detail, fontSize = 9, color = "on_surface_variant", maxLines = 2 }),
        }),
        ui.button({
            glyph = "player-play",
            tooltip = noctalia.tr("panel.library.apply"),
            variant = "ghost",
            controlSize = "sm",
            enabled = canApply and storageValid(),
            onClick = function()
                local output = focusedOutput()
                send({ kind = "apply_entry", output = output, entry = entryForOutput(entry, output) })
            end,
        }),
        ui.button({
            glyph = "playlist-add",
            tooltip = noctalia.tr("panel.library.add"),
            variant = "ghost",
            controlSize = "sm",
            enabled = storageValid() and focusedOutput() ~= "",
            onClick = function()
                local output = focusedOutput()
                send({ kind = "cycle_add_entry", output = output, entry = entryForOutput(entry, output) })
            end,
        }),
    })
end

local function motionBgsSection()
    local provider = type(providers().motionbgs) == "table" and providers().motionbgs or {}
    local motionStatus, results = motionBgsData()
    local items = type(results.items) == "table" and results.items or {}
    local selected = type(results.selected) == "table" and results.selected or {}
    local integrationReady = provider.integration_available == true and storageValid()
    local busy = motionStatus.busy == true
    local quality = tostring(settings().motionbgs_quality or "hd")
    local children = {
        sectionHeader("world-search", noctalia.tr("panel.motionbgs.title"), noctalia.tr("panel.motionbgs.description")),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "motionbgs-search",
                value = motionSearchDraft,
                placeholder = noctalia.tr("panel.motionbgs.search_placeholder"),
                flexGrow = 1,
                onChange = function(value)
                    motionSearchDraft = tostring(value or "")
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.motionbgs.search"),
                glyph = "search",
                variant = "primary",
                controlSize = "sm",
                enabled = integrationReady and not busy and noctalia.string.trim(motionSearchDraft) ~= "",
                onClick = function()
                    send({ kind = "motionbgs_search", query = motionSearchDraft })
                end,
            }),
            ui.button({
                glyph = "x",
                tooltip = noctalia.tr("panel.motionbgs.clear"),
                variant = "ghost",
                controlSize = "sm",
                enabled = integrationReady and not busy,
                onClick = function()
                    motionSearchDraft = ""
                    send({ kind = "motionbgs_clear" })
                end,
            }),
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.label({
                text = if busy
                    then noctalia.tr("panel.motionbgs.busy", { action = tostring(motionStatus.active_action or "") })
                    elseif integrationReady then noctalia.tr("panel.motionbgs.ready")
                    else noctalia.tr("panel.motionbgs.unavailable"),
                color = if integrationReady then "primary" else "tertiary",
                fontSize = 10,
                flexGrow = 1,
                maxLines = 3,
            }),
            actionButton("motionbgs_open", "external-link", "ghost", false),
        }),
        ui.label({
            text = noctalia.tr("panel.motionbgs.fallback"),
            fontSize = 9,
            color = "tertiary",
            maxLines = 5,
        }),
    }

    local providerError = tostring(motionStatus.last_error or "")
    if providerError ~= "" then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.motionbgs.error", { error = providerError }),
                fontSize = 10,
                color = "error",
                maxLines = 5,
            })
        )
    end

    if tostring(selected.slug or "") ~= "" then
        local downloads = type(selected.downloads) == "table" and selected.downloads or {}
        local detail = tostring(selected.duration or "")
        if detail == "" then
            detail = tostring(selected.source_url or "")
        end
        table.insert(
            children,
            ui.column({ gap = 5, padding = 9, radius = 9, fill = "primary/0.08", align = "stretch" }, {
                ui.label({
                    text = tostring(selected.title or selected.slug),
                    fontSize = 12,
                    fontWeight = "bold",
                    maxLines = 2,
                }),
                ui.label({ text = detail, fontSize = 9, color = "on_surface_variant", maxLines = 2 }),
                ui.row({ gap = 6, align = "center" }, {
                    ui.button({
                        text = noctalia.tr("panel.motionbgs.download_hd"),
                        glyph = "download",
                        variant = if quality == "hd" then "primary" else "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        enabled = integrationReady and not busy and type(downloads.hd) == "table",
                        onClick = function()
                            send({ kind = "motionbgs_download", slug = tostring(selected.slug), quality = "hd" })
                        end,
                    }),
                    ui.button({
                        text = noctalia.tr("panel.motionbgs.download_4k"),
                        glyph = "download",
                        variant = if quality == "4k" then "primary" else "ghost",
                        controlSize = "sm",
                        flexGrow = 1,
                        enabled = integrationReady and not busy and type(downloads["4k"]) == "table",
                        onClick = function()
                            send({ kind = "motionbgs_download", slug = tostring(selected.slug), quality = "4k" })
                        end,
                    }),
                }),
            })
        )
    end

    if #items == 0 then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.motionbgs.empty"),
                fontSize = 10,
                color = "on_surface_variant",
            })
        )
    else
        for index = 1, math.min(#items, 12) do
            local item = items[index]
            local slug = tostring(item.slug or "")
            table.insert(
                children,
                ui.row({ gap = 7, align = "center", padding = 8, radius = 9, fill = "surface_variant/0.25" }, {
                    ui.glyph({ name = "movie", color = "primary" }),
                    ui.column({ gap = 1, flexGrow = 1 }, {
                        ui.label({
                            text = tostring(item.title or slug),
                            fontSize = 11,
                            fontWeight = "bold",
                            maxLines = 2,
                        }),
                        ui.label({
                            text = tostring(item.quality or "") .. " · " .. tostring(item.source_url or ""),
                            fontSize = 9,
                            color = "on_surface_variant",
                            maxLines = 2,
                        }),
                    }),
                    ui.button({
                        glyph = "info-circle",
                        tooltip = noctalia.tr("panel.motionbgs.details"),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = integrationReady and not busy and slug ~= "",
                        onClick = function()
                            send({ kind = "motionbgs_details", slug = slug })
                        end,
                    }),
                    ui.button({
                        glyph = "download",
                        tooltip = noctalia.tr("panel.motionbgs.download_default", { quality = quality:upper() }),
                        variant = "ghost",
                        controlSize = "sm",
                        enabled = integrationReady and not busy and slug ~= "",
                        onClick = function()
                            send({ kind = "motionbgs_download", slug = slug, quality = quality })
                        end,
                    }),
                })
            )
        end
    end

    local lastDownload = type(motionStatus.last_download) == "table" and motionStatus.last_download or {}
    local downloadedPath = tostring(lastDownload.path or "")
    if downloadedPath ~= "" then
        local mpvpaper = type(providers().mpvpaper) == "table" and providers().mpvpaper or {}
        table.insert(children, ui.separator())
        table.insert(
            children,
            ui.label({ text = noctalia.tr("panel.motionbgs.last_download"), fontSize = 11, fontWeight = "bold" })
        )
        table.insert(
            children,
            libraryEntryRow(
                "download",
                tostring(lastDownload.title or downloadedPath:match("([^/]+)$") or "MotionBGS"),
                downloadedPath,
                {
                    kind = "video",
                    source = downloadedPath,
                    label = tostring(lastDownload.title or "MotionBGS"),
                    added_at = tostring(lastDownload.downloaded_at or ""),
                },
                mpvpaper.apply_available == true
            )
        )
    end
    return card(children)
end

local function librarySection()
    local currentLibrary = type(status) == "table" and type(status.library) == "table" and status.library or {}
    local videos = type(currentLibrary.videos) == "table" and currentLibrary.videos or {}
    local workshops = type(currentLibrary.workshops) == "table" and currentLibrary.workshops or {}
    local currentProviders = providers()
    local mpvpaper = type(currentProviders.mpvpaper) == "table" and currentProviders.mpvpaper or {}
    local wEngine = type(currentProviders.w_engine) == "table" and currentProviders.w_engine or {}
    local configuration = settings()
    local children = {
        sectionHeader("books", noctalia.tr("panel.library.title"), noctalia.tr("panel.library.description")),
        ui.row({ gap = 6, align = "center" }, {
            actionButton("motionbgs_open", "world-www", "ghost", true),
            ui.button({
                text = noctalia.tr("panel.library.refresh"),
                glyph = "refresh",
                variant = "ghost",
                controlSize = "sm",
                flexGrow = 1,
                onClick = function()
                    send({ kind = "library_refresh" })
                end,
            }),
        }),
        ui.label({
            text = noctalia.tr("panel.library.motionbgs_boundary"),
            fontSize = 9,
            color = "tertiary",
            maxLines = 5,
        }),
        ui.label({
            text = noctalia.tr("panel.library.videos", { count = tostring(#videos) }),
            fontSize = 11,
            fontWeight = "bold",
        }),
    }
    if #videos == 0 then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.library.no_videos", {
                    path = valueOr(configuration.video_directory, "common.unset"),
                }),
                fontSize = 10,
                color = "on_surface_variant",
                maxLines = 3,
            })
        )
    else
        for index = 1, math.min(#videos, 8) do
            local video = videos[index]
            table.insert(
                children,
                libraryEntryRow("player-play", tostring(video.name or "video"), tostring(video.path or ""), {
                    kind = "video",
                    source = tostring(video.path or ""),
                    label = tostring(video.name or "video"),
                    added_at = tostring(currentLibrary.scanned_at or ""),
                }, mpvpaper.apply_available == true)
            )
        end
    end
    table.insert(
        children,
        ui.label({
            text = noctalia.tr("panel.library.workshops", { count = tostring(#workshops) }),
            fontSize = 11,
            fontWeight = "bold",
        })
    )
    if #workshops == 0 then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.library.no_workshops"),
                fontSize = 10,
                color = "on_surface_variant",
            })
        )
    else
        for index = 1, math.min(#workshops, 8) do
            local workshop = workshops[index]
            table.insert(
                children,
                libraryEntryRow(
                    "movie",
                    tostring(workshop.title or ("Workshop " .. tostring(workshop.id or ""))),
                    tostring(workshop.kind or "") .. " · " .. tostring(workshop.id or ""),
                    {
                        kind = "workshop",
                        source = tostring(workshop.id or ""),
                        label = tostring(workshop.title or "Workshop"),
                        added_at = tostring(currentLibrary.scanned_at or ""),
                    },
                    wEngine.apply_available == true
                )
            )
        end
    end
    return card(children)
end

local function cycleSection()
    local output = focusedOutput()
    local reels = type(status) == "table"
            and type(status.config) == "table"
            and type(status.config.reels) == "table"
            and status.config.reels
        or {}
    local reel = type(reels[output]) == "table" and reels[output] or {}
    local entries = type(reel.entries) == "table" and reel.entries or {}
    local cycles = type(status) == "table" and type(status.cycles) == "table" and status.cycles or {}
    local state = type(cycles[output]) == "table" and cycles[output] or {}
    local intervalSeconds =
        math.max(60, tonumber(reel.interval_seconds) or ((tonumber(settings().cycle_interval_minutes) or 15) * 60))
    local intervalMinutes = math.max(1, math.floor(intervalSeconds / 60))
    local order = tostring(reel.order or settings().cycle_order or "sequential")
    local stateLabel = if state.running == true and state.paused == true
        then noctalia.tr("common.paused")
        elseif state.running == true then noctalia.tr("common.running")
        else noctalia.tr("common.stopped")
    local orderValues = { "sequential", "shuffle", "random" }
    local orderLabels = {
        noctalia.tr("settings.cycle_order.options.sequential"),
        noctalia.tr("settings.cycle_order.options.shuffle"),
        noctalia.tr("settings.cycle_order.options.random"),
    }
    local orderIndex = if order == "shuffle" then 1 elseif order == "random" then 2 else 0
    local children = {
        sectionHeader("repeat", noctalia.tr("panel.cycle.title"), noctalia.tr("panel.cycle.description")),
        ui.label({
            text = noctalia.tr("panel.cycle.state", {
                state = stateLabel,
                cursor = tostring(state.cursor or 0),
                count = tostring(#entries),
            }),
            fontWeight = "bold",
        }),
        ui.label({
            text = noctalia.tr("panel.cycle.interval", { minutes = tostring(intervalMinutes), order = order }),
            color = "on_surface_variant",
            fontSize = 10,
        }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "cycle-interval-" .. output,
                value = if cycleIntervalDraft ~= "" then cycleIntervalDraft else tostring(intervalMinutes),
                placeholder = tostring(intervalMinutes),
                width = 110,
                onChange = function(value)
                    cycleIntervalDraft = tostring(value or "")
                end,
            }),
            ui.select({
                key = "cycle-order-" .. output,
                options = orderLabels,
                selectedIndex = orderIndex,
                flexGrow = 1,
                onChange = function(index)
                    local selectedOrder = orderValues[math.floor(tonumber(index) or 0) + 1] or "sequential"
                    send({
                        kind = "cycle_options",
                        output = output,
                        interval_seconds = intervalSeconds,
                        order = selectedOrder,
                    })
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.cycle.save"),
                glyph = "device-floppy",
                variant = "ghost",
                controlSize = "sm",
                onClick = function()
                    local minutes =
                        math.max(1, math.min(43200, math.floor(tonumber(cycleIntervalDraft) or intervalMinutes)))
                    cycleIntervalDraft = tostring(minutes)
                    send({ kind = "cycle_options", output = output, interval_seconds = minutes * 60, order = order })
                end,
            }),
        }),
        ui.row({ gap = 5, align = "center" }, {
            actionButton("cycle_previous", "player-skip-back", "ghost", true),
            actionButton("cycle_start", "player-play", "primary", true),
            actionButton("cycle_pause", "player-pause", "ghost", true),
            actionButton("cycle_resume", "player-track-next", "ghost", true),
            actionButton("cycle_stop", "player-stop", "ghost", true),
            actionButton("cycle_next", "player-skip-forward", "ghost", true),
        }),
        ui.row({ gap = 5, align = "center" }, {
            actionButton("cycle_add_static", "photo-plus", "ghost", true),
            actionButton("cycle_add_video", "video-plus", "ghost", true),
            actionButton("cycle_add_workshop", "playlist-add", "ghost", true),
        }),
    }
    if #entries == 0 then
        table.insert(children, ui.label({ text = noctalia.tr("panel.cycle.empty"), color = "on_surface_variant" }))
    else
        for index = 1, math.min(#entries, 20) do
            local entry = entries[index]
            local entryIndex = index
            table.insert(
                children,
                ui.row({ gap = 6, align = "center" }, {
                    ui.label({
                        text = noctalia.tr("panel.cycle.entry", {
                            index = tostring(index),
                            kind = tostring(entry.kind or ""),
                            label = valueOr(entry.label, "common.unknown"),
                        }),
                        fontSize = 10,
                        flexGrow = 1,
                        maxLines = 2,
                    }),
                    ui.button({
                        glyph = "x",
                        tooltip = noctalia.tr("panel.cycle.remove"),
                        variant = "ghost",
                        controlSize = "sm",
                        onClick = function()
                            send({ kind = "cycle_remove_entry", output = output, index = entryIndex })
                        end,
                    }),
                })
            )
        end
        table.insert(children, actionButton("cycle_clear", "trash", "ghost", true))
    end
    if tostring(state.next_due or "") ~= "" and tonumber(state.next_due) ~= 0 then
        table.insert(
            children,
            ui.label({
                text = noctalia.tr("panel.cycle.next_due", { time = tostring(state.next_due) }),
                fontSize = 9,
                color = "on_surface_variant",
            })
        )
    end
    return card(children)
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
        actionButton("capture_backing", "photo-down", "primary", true),
        ui.label({
            text = noctalia.tr("capture.backing_behavior"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 5,
        }),
        ui.separator(),
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
            actionButton("video_apply_pair", "player-play", "primary", true),
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
            actionButton("workshop_apply_pair", "player-play", "primary", true),
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
    local renderer = type(status) == "table" and type(status.renderer) == "table" and status.renderer or {}
    local activeRenderers = 0
    if type(renderer.outputs) == "table" then
        for _ in pairs(renderer.outputs) do
            activeRenderers += 1
        end
    end
    local daemonNames = {}
    local daemons = type(current.daemons) == "table" and current.daemons or {}
    for _, name in ipairs({ "awww", "swww", "wpaperd", "hyprpaper" }) do
        if daemons[name] == true then
            table.insert(daemonNames, name)
        end
    end

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
            text = noctalia.tr("diagnostics.renderer", {
                state = if renderer.ready == true then noctalia.tr("common.running") else noctalia.tr("common.stopped"),
                count = tostring(activeRenderers),
                error = tostring(renderer.last_error or ""),
            }),
            fontSize = 10,
            color = if renderer.ready == true then "primary" else "error",
            maxLines = 5,
        }),
        ui.label({
            text = noctalia.tr("diagnostics.ownership"),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 6,
        }),
        ui.label({
            text = noctalia.tr("diagnostics.daemons", {
                commands = if #daemonNames > 0 then table.concat(daemonNames, ", ") else noctalia.tr("common.none"),
            }),
            fontSize = 10,
            color = "on_surface_variant",
            maxLines = 3,
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
            motionBgsSection(),
            librarySection(),
            cycleSection(),
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
    elseif event == "capture-backing" then
        runAction("capture_backing")
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

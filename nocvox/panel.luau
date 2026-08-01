--!nonstrict
-- VoxType details and diagnostics panel. All recording actions are forwarded to
-- the singleton service; this entry never launches VoxType itself.

local STATUS_KEY = "voxtype_status"
local COMMAND_KEY = "voxtype_command"
local DIAGNOSTICS_KEY = "voxtype_diagnostics"

local RECORDING_STATES = { recording = true, streaming = true }
local PROCESSING_STATES = { transcribing = true, processing = true }

local status = nil
local diagnostics = nil
local commandSequence = 0

-- One-shot selections intentionally live only in this panel runtime. They are
-- not daemon configuration and reset when the plugin reloads.
local outputValues = { "inherit", "type", "clipboard", "paste", "file" }
local outputIndex = 0
local filePath = ""
local modelOverride = ""
local profileOverride = ""
local triStateValues = { "inherit", "on", "off" }
local autoSubmitIndex = 0
local shiftEnterIndex = 0
local smartSubmitIndex = 0

local function cfg(key)
    return noctalia.getConfig(key)
end

local function displayValue(value)
    local text = tostring(value or "")
    return if text == "" then noctalia.tr("common.unknown") else text
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
    return string.format("%s%d:%02d", prefix, math.floor(elapsed / 60), elapsed % 60)
end

local function statePresentation(current)
    local state = tostring(current.state or "unknown")
    if current.available ~= true or state == "stopped" then
        return "microphone-off", tostring(cfg("stopped_color") or "on_surface_variant")
    elseif RECORDING_STATES[state] then
        return "microphone", tostring(cfg("recording_color") or "error")
    elseif PROCESSING_STATES[state] then
        return "microphone", tostring(cfg("transcribing_color") or "tertiary")
    elseif state == "idle" then
        return "microphone", tostring(cfg("idle_color") or "on_surface")
    elseif state == "error" then
        return "microphone-off", tostring(cfg("recording_color") or "error")
    end
    return "microphone", tostring(cfg("unknown_color") or "tertiary")
end

local function send(action, overrides)
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    local command = {
        action = action,
        producer = "details-panel",
        sequence = commandSequence,
    }
    if type(overrides) == "table" then
        command.overrides = overrides
    end
    noctalia.state.set(COMMAND_KEY, command)
end

local function section(title, children)
    return ui.column({ gap = 8 }, {
        ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
        ui.column({ gap = 8 }, children),
    })
end

local function outputOptions()
    return {
        noctalia.tr("panel.overrides.output.inherit"),
        noctalia.tr("panel.overrides.output.type"),
        noctalia.tr("panel.overrides.output.clipboard"),
        noctalia.tr("panel.overrides.output.paste"),
        noctalia.tr("panel.overrides.output.file"),
    }
end

local function triStateOptions()
    return {
        noctalia.tr("panel.overrides.tristate.inherit"),
        noctalia.tr("panel.overrides.tristate.on"),
        noctalia.tr("panel.overrides.tristate.off"),
    }
end

local function outputLabel(output)
    if output == "type" then
        return noctalia.tr("overrides.output.type")
    elseif output == "clipboard" then
        return noctalia.tr("overrides.output.clipboard")
    elseif output == "paste" then
        return noctalia.tr("overrides.output.paste")
    elseif output == "file" then
        return noctalia.tr("overrides.output.file")
    end
    return ""
end

local function overrideSummary(current)
    if current.override_active ~= true then
        return noctalia.tr("panel.overrides.none_active")
    end
    local parts = {}
    local output = tostring(current.override_output or "inherit")
    if output ~= "inherit" then
        local label = outputLabel(output)
        if label ~= "" then
            table.insert(parts, label)
        end
    end
    if tostring(current.override_model or "") ~= "" then
        table.insert(parts, noctalia.tr("overrides.model", { value = tostring(current.override_model) }))
    end
    if tostring(current.override_profile or "") ~= "" then
        table.insert(parts, noctalia.tr("overrides.profile", { value = tostring(current.override_profile) }))
    end
    if #parts == 0 then
        table.insert(parts, noctalia.tr("overrides.text_actions"))
    end
    return table.concat(parts, " · ")
end

local function diagnosticsLines(value)
    if type(value) ~= "table" then
        return { noctalia.tr("panel.diagnostics.not_collected") }
    elseif value.pending == true then
        return { noctalia.tr("panel.diagnostics.running") }
    elseif tostring(value.error or "") ~= "" then
        return { noctalia.tr("panel.diagnostics.failed", { error = tostring(value.error) }) }
    end

    local yes = noctalia.tr("common.yes")
    local no = noctalia.tr("common.no")
    return {
        noctalia.tr("panel.diagnostics.version", { value = tostring(value.version or "") }),
        noctalia.tr("panel.diagnostics.install_kind", { value = tostring(value.install_kind or "") }),
        noctalia.tr("panel.diagnostics.active_variant", {
            value = if tostring(value.active_variant or "") == ""
                then noctalia.tr("common.none")
                else tostring(value.active_variant),
        }),
        noctalia.tr("panel.diagnostics.cpu", {
            avx2 = if value.cpu_avx2 == true then yes else no,
            avx512 = if value.cpu_avx512 == true then yes else no,
        }),
        noctalia.tr("panel.diagnostics.gpu", {
            amd = if value.gpu_amd == true then yes else no,
            nvidia = if value.gpu_nvidia == true then yes else no,
        }),
        noctalia.tr("panel.diagnostics.features", { value = tostring(value.compiled_features or "") }),
        noctalia.tr("panel.diagnostics.recommendation", {
            value = tostring(value.recommendation_primary or ""),
        }),
        noctalia.tr("panel.diagnostics.collected", { value = tostring(value.collected_at or "") }),
    }
end

local function diagnosticSummary(current, value)
    local lines = {
        "NocVox diagnostic summary",
        "State: " .. stateLabel(tostring(current.state or "unknown")),
        "Executable available: " .. tostring(current.available == true),
        "Follower active: " .. tostring(current.follower_active == true),
        "Configured model: " .. tostring(current.model or ""),
        "Configured device: " .. tostring(current.device or ""),
        "Reported backend: " .. tostring(current.backend or ""),
        "Last status: " .. tostring(current.observed_at or ""),
        "Last error: " .. tostring(current.last_error or ""),
        "Malformed status lines: " .. tostring(current.malformed_count or 0),
    }
    for _, line in ipairs(diagnosticsLines(value)) do
        table.insert(lines, line)
    end
    table.insert(lines, "Privacy: no transcript, audio, log, or clipboard content is collected.")
    return table.concat(lines, "\n")
end

local function render()
    local current = if type(status) == "table"
        then status
        else {
            state = "unknown",
            available = false,
            follower_active = false,
            last_error = noctalia.tr("widget.waiting"),
        }
    local state = tostring(current.state or "unknown")
    local glyph, color = statePresentation(current)
    local idle = current.available == true and state == "idle" and current.action_pending ~= true
    local recording = RECORDING_STATES[state] == true and current.action_pending ~= true
    local cancelable = (RECORDING_STATES[state] == true or PROCESSING_STATES[state] == true)
        and current.action_pending ~= true

    local statusDetails = { stateLabel(state) }
    if RECORDING_STATES[state] then
        table.insert(statusDetails, noctalia.tr("widget.elapsed", { value = elapsedText(current) }))
    end
    if current.action_pending == true then
        table.insert(statusDetails, noctalia.tr("panel.action_pending"))
    end

    local body = {
        ui.row({ align = "center", justify = "space_between", gap = 8 }, {
            ui.row({ align = "center", gap = 10, flexGrow = 1 }, {
                ui.glyph({ name = glyph, color = color, size = 22 }),
                ui.column({ gap = 2, flexGrow = 1 }, {
                    ui.label({ text = noctalia.tr("plugin.name"), fontSize = 16, fontWeight = "bold" }),
                    ui.label({ text = table.concat(statusDetails, " · "), color = color, fontSize = 12 }),
                }),
            }),
            ui.button({
                glyph = "settings",
                variant = "ghost",
                tooltip = noctalia.tr("panel.settings"),
                onClick = "onSettings",
            }),
            ui.button({ glyph = "close", variant = "ghost", tooltip = noctalia.tr("panel.close"), onClick = "onClose" }),
        }),
    }

    local blockedMessage = ""
    if current.available ~= true then
        blockedMessage = if tostring(current.raw_state or "") == "missing"
            then noctalia.tr("panel.missing_voxtype")
            else noctalia.tr("panel.listener_unavailable")
    elseif state == "stopped" then
        blockedMessage = noctalia.tr("panel.daemon_stopped")
    end
    if blockedMessage ~= "" then
        table.insert(body, ui.label({ text = blockedMessage, color = "error", maxLines = 4 }))
        table.insert(
            body,
            ui.label({
                text = noctalia.tr("panel.external_ownership"),
                color = "on_surface_variant",
                maxLines = 4,
            })
        )
        panel.render(ui.column({ flexGrow = 1, gap = 14 }, body))
        return
    end

    local controls = {
        ui.row({ gap = 8, align = "center" }, {
            ui.button({
                text = noctalia.tr("actions.start"),
                glyph = "player-play",
                variant = "primary",
                enabled = idle,
                flexGrow = 1,
                onClick = "onStart",
            }),
            ui.button({
                text = noctalia.tr("actions.stop"),
                glyph = "player-stop",
                enabled = recording,
                flexGrow = 1,
                onClick = "onStop",
            }),
            ui.button({
                text = noctalia.tr("actions.cancel"),
                glyph = "x",
                variant = "destructive",
                enabled = cancelable,
                flexGrow = 1,
                onClick = "onCancel",
            }),
        }),
        ui.label({ text = noctalia.tr("panel.external_ownership"), color = "on_surface_variant", maxLines = 3 }),
    }
    table.insert(body, section(noctalia.tr("panel.controls"), controls))

    local details = {
        ui.label({ text = noctalia.tr("widget.model", { value = displayValue(current.model) }) }),
        ui.label({ text = noctalia.tr("widget.device", { value = displayValue(current.device) }) }),
        ui.label({ text = noctalia.tr("widget.backend", { value = displayValue(current.backend) }) }),
        ui.label({
            text = noctalia.tr("panel.last_status", { value = tostring(current.observed_at or "") }),
            color = "on_surface_variant",
        }),
        ui.label({
            text = noctalia.tr("panel.active_override", { value = overrideSummary(current) }),
            color = "on_surface_variant",
            maxLines = 3,
        }),
    }
    table.insert(body, section(noctalia.tr("panel.status"), details))

    if cfg("enable_one_shot_overrides") == true then
        local overrideControls = {
            ui.label({ text = noctalia.tr("panel.overrides.explanation"), color = "on_surface_variant", maxLines = 4 }),
            ui.label({ text = noctalia.tr("panel.overrides.output_label"), fontWeight = "medium" }),
            ui.select({
                options = outputOptions(),
                selectedIndex = outputIndex,
                enabled = idle,
                onChange = "onOutputChanged",
            }),
        }
        if outputValues[outputIndex + 1] == "file" then
            table.insert(
                overrideControls,
                ui.label({
                    text = noctalia.tr("panel.overrides.file_exclusive"),
                    color = "error",
                    maxLines = 3,
                })
            )
            table.insert(
                overrideControls,
                ui.input({
                    key = "override-file",
                    value = filePath,
                    placeholder = noctalia.tr("panel.overrides.file_placeholder"),
                    enabled = idle,
                    onChange = "onFilePathChanged",
                })
            )
        end
        table.insert(
            overrideControls,
            ui.label({ text = noctalia.tr("panel.overrides.model_label"), fontWeight = "medium" })
        )
        table.insert(
            overrideControls,
            ui.input({
                key = "override-model",
                value = modelOverride,
                placeholder = noctalia.tr("panel.overrides.model_placeholder"),
                enabled = idle,
                onChange = "onModelChanged",
            })
        )
        table.insert(
            overrideControls,
            ui.label({ text = noctalia.tr("panel.overrides.profile_label"), fontWeight = "medium" })
        )
        table.insert(
            overrideControls,
            ui.input({
                key = "override-profile",
                value = profileOverride,
                placeholder = noctalia.tr("panel.overrides.profile_placeholder"),
                enabled = idle,
                onChange = "onProfileChanged",
            })
        )
        table.insert(
            overrideControls,
            ui.label({ text = noctalia.tr("panel.overrides.auto_submit"), fontWeight = "medium" })
        )
        table.insert(
            overrideControls,
            ui.select({
                options = triStateOptions(),
                selectedIndex = autoSubmitIndex,
                enabled = idle,
                onChange = "onAutoSubmitChanged",
            })
        )
        table.insert(
            overrideControls,
            ui.label({ text = noctalia.tr("panel.overrides.shift_enter"), fontWeight = "medium" })
        )
        table.insert(
            overrideControls,
            ui.select({
                options = triStateOptions(),
                selectedIndex = shiftEnterIndex,
                enabled = idle,
                onChange = "onShiftEnterChanged",
            })
        )
        table.insert(
            overrideControls,
            ui.label({ text = noctalia.tr("panel.overrides.smart_submit"), fontWeight = "medium" })
        )
        table.insert(
            overrideControls,
            ui.select({
                options = triStateOptions(),
                selectedIndex = smartSubmitIndex,
                enabled = idle,
                onChange = "onSmartSubmitChanged",
            })
        )
        table.insert(
            overrideControls,
            ui.label({
                text = noctalia.tr("panel.overrides.clipboard_privacy"),
                color = "on_surface_variant",
                maxLines = 5,
            })
        )
        table.insert(body, section(noctalia.tr("panel.overrides.title"), overrideControls))
    else
        table.insert(
            body,
            section(noctalia.tr("panel.overrides.title"), {
                ui.label({ text = noctalia.tr("panel.overrides.disabled"), color = "on_surface_variant", maxLines = 3 }),
            })
        )
    end

    local diagnosticControls = {}
    for _, line in ipairs(diagnosticsLines(diagnostics)) do
        table.insert(diagnosticControls, ui.label({ text = line, color = "on_surface_variant", maxLines = 3 }))
    end
    table.insert(
        diagnosticControls,
        ui.row({ gap = 8 }, {
            ui.button({
                text = noctalia.tr("panel.diagnostics.run"),
                glyph = "refresh",
                enabled = current.available == true
                    and not (type(diagnostics) == "table" and diagnostics.pending == true),
                flexGrow = 1,
                onClick = "onRunDiagnostics",
            }),
            ui.button({
                text = noctalia.tr("panel.diagnostics.copy"),
                glyph = "copy",
                enabled = type(diagnostics) == "table" and diagnostics.pending ~= true,
                flexGrow = 1,
                onClick = "onCopyDiagnostics",
            }),
        })
    )
    table.insert(
        diagnosticControls,
        ui.label({
            text = noctalia.tr("panel.diagnostics.privacy"),
            color = "on_surface_variant",
            maxLines = 4,
        })
    )
    table.insert(body, section(noctalia.tr("panel.diagnostics.title"), diagnosticControls))

    local errorMessage = tostring(current.last_error or "")
    if errorMessage ~= "" then
        table.insert(
            body,
            ui.label({
                text = noctalia.tr("widget.last_error", { error = errorMessage }),
                color = "error",
                maxLines = 4,
            })
        )
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
        body[1],
        ui.scroll({ flexGrow = 1, gap = 14 }, { table.unpack(body, 2) }),
    }))
end

function onStart()
    if cfg("enable_one_shot_overrides") == true then
        send("start", {
            output = outputValues[outputIndex + 1],
            file_path = filePath,
            model = modelOverride,
            profile = profileOverride,
            auto_submit = triStateValues[autoSubmitIndex + 1],
            shift_enter_newlines = triStateValues[shiftEnterIndex + 1],
            smart_auto_submit = triStateValues[smartSubmitIndex + 1],
        })
    else
        send("start", nil)
    end
end

function onStop()
    send("stop", nil)
end

function onCancel()
    send("cancel", nil)
end

function onRunDiagnostics()
    send("diagnose", nil)
end

function onCopyDiagnostics()
    local current = if type(status) == "table" then status else {}
    local summary = diagnosticSummary(current, diagnostics)
    if noctalia.copyToClipboard(summary, "text/plain") then
        noctalia.notify(noctalia.tr("plugin.name"), noctalia.tr("panel.diagnostics.copied"))
    else
        noctalia.notifyError(noctalia.tr("plugin.name"), noctalia.tr("panel.diagnostics.copy_failed"))
    end
end

function onOutputChanged(index, _text)
    outputIndex = math.max(0, math.min(#outputValues - 1, tonumber(index) or 0))
    render()
end

function onFilePathChanged(value)
    filePath = tostring(value or "")
end

function onModelChanged(value)
    modelOverride = tostring(value or "")
end

function onProfileChanged(value)
    profileOverride = tostring(value or "")
end

function onAutoSubmitChanged(index, _text)
    autoSubmitIndex = math.max(0, math.min(#triStateValues - 1, tonumber(index) or 0))
end

function onShiftEnterChanged(index, _text)
    shiftEnterIndex = math.max(0, math.min(#triStateValues - 1, tonumber(index) or 0))
end

function onSmartSubmitChanged(index, _text)
    smartSubmitIndex = math.max(0, math.min(#triStateValues - 1, tonumber(index) or 0))
end

function onSettings()
    panel.close()
    noctalia.openSettings()
end

function onClose()
    panel.close()
end

function onOpen(_context)
    status = noctalia.state.get(STATUS_KEY)
    diagnostics = noctalia.state.get(DIAGNOSTICS_KEY)
    render()
end

function onConfigChanged()
    render()
end

function onIpc(event, _payload)
    if event == "start" then
        onStart()
    elseif event == "stop" then
        onStop()
    elseif event == "cancel" then
        onCancel()
    elseif event == "diagnose" then
        onRunDiagnostics()
    else
        noctalia.log("nocvox details panel: unknown command '" .. tostring(event) .. "'")
    end
end

noctalia.state.watch(STATUS_KEY, function(nextStatus)
    status = nextStatus
    render()
end)
noctalia.state.watch(DIAGNOSTICS_KEY, function(nextDiagnostics)
    diagnostics = nextDiagnostics
    render()
end)
status = noctalia.state.get(STATUS_KEY)
diagnostics = noctalia.state.get(DIAGNOSTICS_KEY)
render()

--!nonstrict
-- Native v5 replacement for the v4 widget's right-click context menu.

local STATUS_KEY = "hydra_status"
local COMMAND_KEY = "hydra_command"
local DOCUMENTATION_URL = "https://github.com/Go08er/goober-noctalia-plugins-v5/tree/main/hydra-update-examiner#readme"

local commandSequence = 0
local status = nil

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\"'\"'") .. "'"
end

local function send(action)
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    noctalia.state.set(COMMAND_KEY, {
        action = action,
        producer = "actions-panel",
        sequence = commandSequence,
    })
end

local function presentationFor(state)
    if state == "launched" then
        return noctalia.getConfig("shared_launched_glyph"), noctalia.getConfig("shared_launched_color")
    elseif state == "close" then
        return noctalia.getConfig("shared_close_glyph"), noctalia.getConfig("shared_close_color")
    elseif state == "stalled" or state == "stale" or state == "error" then
        return noctalia.getConfig("shared_stalled_glyph"), noctalia.getConfig("shared_stalled_color")
    end
    return noctalia.getConfig("shared_running_glyph"), noctalia.getConfig("shared_running_color")
end

local function render()
    local current = if type(status) == "table"
        then status
        else {
            state = "idle",
            text = "HYD",
        }
    local glyph, color = presentationFor(tostring(current.state or "idle"))
    if current.loading then
        glyph = "refresh"
    end

    panel.render(ui.column({ gap = 8, padding = 12, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({ name = tostring(glyph or "server-bolt"), color = tostring(color or "on_surface") }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = noctalia.tr("actions.title"), fontSize = 15, fontWeight = "bold" }),
                ui.label({
                    text = tostring(current.text or "HYD"),
                    color = tostring(color or "on_surface_variant"),
                    fontSize = 12,
                }),
            }),
            ui.button({ glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
        }),
        ui.separator(),
        ui.button({ text = noctalia.tr("actions.refresh"), glyph = "refresh", onClick = "onRefresh" }),
        ui.button({ text = noctalia.tr("actions.open_hydra"), glyph = "external-link", onClick = "onOpenHydra" }),
        ui.button({ text = noctalia.tr("actions.settings"), glyph = "settings", onClick = "onOpenSettings" }),
        ui.button({
            text = noctalia.tr("actions.documentation"),
            glyph = "book-2",
            onClick = "onOpenDocumentation",
        }),
    }))
end

function onClosePanel()
    panel.close()
end

function onRefresh()
    panel.close()
    send("refresh")
end

function onOpenHydra()
    panel.close()
    send("open")
end

function onOpenSettings()
    panel.close()
    noctalia.openSettings()
end

function onDocumentationResult(result)
    if type(result) ~= "table" or result.timedOut or result.exitCode ~= 0 then
        noctalia.notifyError(noctalia.tr("widget.title"), noctalia.tr("widget.documentation_failed"))
    end
end

function onOpenDocumentation()
    panel.close()
    if not noctalia.commandExists("xdg-open") then
        noctalia.notifyError(
            noctalia.tr("widget.title"),
            noctalia.tr("widget.missing_dependency", { command = "xdg-open" })
        )
        return
    end
    if not noctalia.runAsync("xdg-open " .. shellQuote(DOCUMENTATION_URL), onDocumentationResult, 15000) then
        noctalia.notifyError(noctalia.tr("widget.title"), noctalia.tr("widget.documentation_failed"))
    end
end

function onOpen(_context)
    status = noctalia.state.get(STATUS_KEY)
    render()
end

function onIpc(event, _payload)
    if event == "refresh" then
        onRefresh()
    elseif event == "open" then
        onOpenHydra()
    elseif event == "settings" then
        onOpenSettings()
    elseif event == "documentation" then
        onOpenDocumentation()
    else
        noctalia.log("hydra-update-examiner actions panel: unknown command '" .. tostring(event) .. "'")
    end
end

noctalia.state.watch(STATUS_KEY, function(nextStatus)
    status = nextStatus
    render()
end)
status = noctalia.state.get(STATUS_KEY)
render()

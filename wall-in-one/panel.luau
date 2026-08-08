--!nonstrict
-- The stateful half of the control surface: shuffle, cycling, the cycle
-- interval, the dynamics pause, and a palette reload. Commands go onto the
-- shared command channel; the singleton service is the only thing that talks
-- to the app.

local STATE_KEY = "wall_in_one_state"
local COMMAND_KEY = "wall_in_one_command"

local state = nil
local intervalDraft = ""
local commandSequence = 0

local function running()
    return type(state) == "table" and state.running == true
end

local function starting()
    return type(state) == "table" and state.launching == true
end

local function flag(name)
    return running() and state[name] == true
end

local function send(verb, argument)
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    noctalia.state.set(COMMAND_KEY, {
        verb = verb,
        argument = argument,
        producer = "controls-panel",
        sequence = commandSequence,
    })
end

-- Nothing is drawn optimistically: the service republishes the app's own
-- answer, and the state watch below repaints from that.
local function toggle(verb, labelKey, glyph, active)
    return ui.button({
        text = noctalia.tr(labelKey),
        glyph = glyph,
        variant = if active then "primary" else "ghost",
        enabled = running(),
        onClick = function()
            send(verb, "toggle")
        end,
    })
end

local function render()
    local summary = if running()
        then noctalia.tr("panel.summary", {
            showing = if tostring(state.showing or "") ~= ""
                then tostring(state.showing)
                else noctalia.tr("panel.nothing_applied"),
            playable = tostring(state.playable),
            total = tostring(state.library),
        })
        elseif starting()
        then noctalia.tr("panel.starting")
        else noctalia.tr("panel.not_running")

    panel.render(ui.column({ gap = 8, padding = 12, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.glyph({
                name = if running() then "library-photo" else "photo-off",
                color = if running() then "primary" else "on_surface_variant",
            }),
            ui.column({ gap = 1, flexGrow = 1 }, {
                ui.label({ text = noctalia.tr("panel.title"), fontSize = 15, fontWeight = "bold" }),
                ui.label({ text = summary, color = "on_surface_variant", fontSize = 12 }),
            }),
            ui.button({ glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
        }),
        ui.separator(),
        ui.button({
            text = noctalia.tr(if starting() then "panel.starting" else "panel.open_app"),
            glyph = if starting() then "loader" else "external-link",
            variant = if running() then "ghost" else "primary",
            enabled = not starting(),
            onClick = function()
                send("launch", nil)
            end,
        }),
        toggle("shuffle", "panel.shuffle", "arrows-shuffle", flag("shuffle")),
        toggle("cycle", "panel.cycle", "rotate-clockwise", flag("cycle")),
        toggle("dynamics", "panel.dynamics", "player-play", flag("dynamics")),
        ui.separator(),
        ui.label({ text = noctalia.tr("panel.interval"), fontSize = 11, fontWeight = "bold" }),
        ui.row({ gap = 8, align = "center" }, {
            ui.input({
                key = "cycle-interval",
                value = intervalDraft,
                placeholder = noctalia.tr("panel.interval_placeholder"),
                enabled = running(),
                flexGrow = 1,
                onChange = function(value)
                    intervalDraft = noctalia.string.trim(tostring(value or ""))
                end,
                onSubmit = function(value)
                    intervalDraft = noctalia.string.trim(tostring(value or ""))
                    onApplyInterval()
                end,
            }),
            ui.button({
                text = noctalia.tr("panel.apply"),
                glyph = "check",
                controlSize = "sm",
                enabled = running(),
                onClick = "onApplyInterval",
            }),
        }),
        ui.separator(),
        ui.button({
            text = noctalia.tr("panel.reload_palette"),
            glyph = "palette",
            variant = "ghost",
            enabled = running(),
            onClick = function()
                send("reload-palette", nil)
                panel.close()
            end,
        }),
        ui.button({
            text = noctalia.tr("panel.settings"),
            glyph = "settings",
            variant = "ghost",
            onClick = "onOpenSettings",
        }),
    }))
end

function onClosePanel()
    panel.close()
end

function onOpenSettings()
    panel.close()
    noctalia.openSettings()
end

function onApplyInterval()
    local seconds = tonumber(intervalDraft)
    if seconds == nil or seconds < 1 then
        noctalia.notifyError(noctalia.tr("panel.title"), noctalia.tr("panel.interval_invalid"))
        return
    end
    send("cycle-interval", tostring(math.floor(seconds)))
    render()
end

function onOpen(_context)
    state = noctalia.state.get(STATE_KEY)
    intervalDraft = if running() then tostring(state.interval or "") else ""
    send("status", nil)
    render()
end

noctalia.state.watch(STATE_KEY, function(nextState)
    state = nextState
    if intervalDraft == "" and running() then
        intervalDraft = tostring(state.interval or "")
    end
    render()
end)
state = noctalia.state.get(STATE_KEY)
render()

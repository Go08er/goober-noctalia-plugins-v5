--!nonstrict
-- Compact runtime controls. Authoring stays in the standalone GTK app; this
-- panel reads one atomic Rust status snapshot and sends runtime-only verbs.

local STATE_KEY = "wall_in_one_state"
local MENU_KEY = "wall_in_one_menu"
local COMMAND_KEY = "wall_in_one_command"

local state = nil
local menu = nil
local commandSequence = 0

local function running()
    return type(state) == "table" and state.running == true
end

local function starting()
    return type(state) == "table" and state.launching == true
end

local function playlists()
    return if type(menu) == "table" and type(menu.playlists) == "table" then menu.playlists else {}
end

local function displays()
    return if type(menu) == "table" and type(menu.displays) == "table" then menu.displays else {}
end

local function schedules()
    return if type(menu) == "table" and type(menu.schedules) == "table" then menu.schedules else {}
end

local function schedule()
    return if type(menu) == "table" and type(menu.schedule) == "table" then menu.schedule else {}
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

local function header(title, subtitle)
    return ui.row({ gap = 8, align = "center", padding = 12 }, {
        ui.glyph({
            name = if running() then "library-photo" else "photo-off",
            color = if running() then "primary" else "on_surface_variant",
        }),
        ui.column({ gap = 1, flexGrow = 1 }, {
            ui.label({ text = title, fontSize = 15, fontWeight = "bold" }),
            ui.label({ text = subtitle, color = "on_surface_variant", fontSize = 11, maxLines = 2 }),
        }),
        ui.button({ glyph = "close", variant = "ghost", onClick = "onClosePanel" }),
    })
end

local function activeRule()
    local wanted = tostring(schedule().rule_id or "")
    if wanted == "" then
        return nil
    end
    for _, rule in ipairs(schedules()) do
        if tostring(rule.id or "") == wanted then
            return rule
        end
    end
    return nil
end

local function ruleWindow(rule)
    if type(rule) ~= "table" then
        return noctalia.tr("panel.schedule.all_day")
    end
    local startTime = tostring(rule.start or "")
    local endTime = tostring(rule["end"] or "")
    if startTime == "" and endTime == "" then
        return noctalia.tr("panel.schedule.all_day")
    end
    return startTime .. "–" .. endTime
end

local function runtimeSummary()
    if starting() then
        return noctalia.tr("panel.starting")
    end
    if not running() then
        return noctalia.tr("panel.not_running")
    end
    local playlist = tostring(state.playlist or "")
    if playlist == "" then
        playlist = noctalia.tr("panel.nothing_applied")
    end
    return noctalia.tr("panel.summary", {
        playlist = playlist,
        playback = noctalia.tr(if state.paused == true then "panel.playback.paused" else "panel.playback.playing"),
        source = noctalia.tr(if tostring(state.source or "") == "manual"
            then "panel.schedule.manual"
            else "panel.schedule.following"),
    })
end

function render()
    local body = {
        header(noctalia.tr("panel.title"), runtimeSummary()),
        ui.separator(),
        ui.row({ gap = 8 }, {
            ui.button({
                text = noctalia.tr("panel.open_app"),
                glyph = "external-link",
                variant = "primary",
                flexGrow = 1,
                onClick = "onOpenApp",
            }),
            ui.button({ glyph = "refresh", variant = "ghost", onClick = "onRefresh" }),
        }),
        ui.label({ text = noctalia.tr("panel.playback.title"), fontSize = 12, fontWeight = "bold" }),
        ui.row({ gap = 6 }, {
            ui.button({
                text = noctalia.tr("panel.playback.previous"),
                glyph = "player-skip-back",
                enabled = running(),
                flexGrow = 1,
                onClick = "onPrevious",
            }),
            ui.button({
                text = noctalia.tr(if type(state) == "table" and state.paused == true
                    then "panel.playback.play"
                    else "panel.playback.pause"),
                glyph = if type(state) == "table" and state.paused == true then "player-play" else "player-pause",
                enabled = running(),
                flexGrow = 1,
                onClick = "onToggle",
            }),
            ui.button({
                text = noctalia.tr("panel.playback.next"),
                glyph = "player-skip-forward",
                enabled = running(),
                flexGrow = 1,
                onClick = "onNext",
            }),
        }),
        ui.row({ gap = 6 }, {
            ui.button({
                text = noctalia.tr("panel.playback.random"),
                glyph = "arrows-shuffle",
                enabled = running(),
                flexGrow = 1,
                onClick = "onRandom",
            }),
            ui.button({
                text = noctalia.tr(if type(state) == "table" and state.shuffle == true
                    then "panel.playback.shuffle_on"
                    else "panel.playback.shuffle_off"),
                glyph = "playlist",
                variant = if type(state) == "table" and state.shuffle == true then "primary" else "ghost",
                enabled = running(),
                flexGrow = 1,
                onClick = "onShuffle",
            }),
        }),
        ui.separator(),
        ui.label({ text = noctalia.tr("panel.schedule.title"), fontSize = 12, fontWeight = "bold" }),
    }

    local scheduleInfo = schedule()
    local scheduledPlaylist = tostring(scheduleInfo.playlist or "")
    table.insert(body, ui.label({
        text = if scheduleInfo.following == true
            then noctalia.tr("panel.schedule.active", { playlist = scheduledPlaylist })
            else noctalia.tr("panel.schedule.override", { playlist = tostring(state and state.playlist or "") }),
        color = "on_surface_variant",
        maxLines = 2,
    }))
    local rule = activeRule()
    if rule ~= nil then
        table.insert(body, ui.label({
            text = noctalia.tr("panel.schedule.rule", {
                playlist = scheduledPlaylist,
                when = ruleWindow(rule),
            }),
            color = "on_surface_variant",
            fontSize = 11,
            maxLines = 2,
        }))
    elseif scheduledPlaylist ~= "" then
        table.insert(body, ui.label({
            text = noctalia.tr("panel.schedule.default", { playlist = scheduledPlaylist }),
            color = "on_surface_variant",
            fontSize = 11,
            maxLines = 2,
        }))
    end
    table.insert(body, ui.row({ gap = 8 }, {
        ui.button({
            text = noctalia.tr("panel.schedule.resume"),
            glyph = "calendar-clock",
            enabled = running() and scheduleInfo.following ~= true,
            flexGrow = 1,
            onClick = "onResumeSchedule",
        }),
        ui.button({
            text = noctalia.tr("panel.schedule.edit"),
            glyph = "edit",
            flexGrow = 1,
            onClick = "onOpenSchedules",
        }),
    }))

    table.insert(body, ui.separator())
    table.insert(body, ui.label({ text = noctalia.tr("panel.playlists.title"), fontSize = 12, fontWeight = "bold" }))
    if #playlists() == 0 then
        table.insert(body, ui.label({
            text = noctalia.tr(if running() then "panel.playlists.empty" else "panel.playlists.unavailable"),
            color = "on_surface_variant",
        }))
    else
        for _, row in ipairs(playlists()) do
            local playlistName = tostring(row.name or "")
            table.insert(body, ui.button({
                text = noctalia.tr("panel.playlists.row", {
                    name = playlistName,
                    count = tostring(row.entries or 0),
                }),
                glyph = if row.active == true then "player-play" else "playlist",
                variant = if row.active == true then "primary" else "ghost",
                enabled = running(),
                onClick = function()
                    send("playlist-use", playlistName)
                end,
            }))
        end
    end

    if #displays() > 0 then
        table.insert(body, ui.separator())
        table.insert(body, ui.label({ text = noctalia.tr("panel.displays.title"), fontSize = 12, fontWeight = "bold" }))
        for _, row in ipairs(displays()) do
            local assigned = tostring(row.assigned_playlist or "")
            local effective = tostring(row.playlist or "")
            table.insert(body, ui.row({ gap = 8, align = "center" }, {
                ui.glyph({ name = "device-desktop", color = "on_surface_variant" }),
                ui.label({
                    text = if assigned == effective
                        then noctalia.tr("panel.displays.row", {
                            display = tostring(row.connector or ""),
                            playlist = assigned,
                        })
                        else noctalia.tr("panel.displays.overridden", {
                            display = tostring(row.connector or ""),
                            assigned = assigned,
                            effective = effective,
                        }),
                    flexGrow = 1,
                    maxLines = 2,
                }),
            }))
        end
        table.insert(body, ui.button({
            text = noctalia.tr("panel.displays.edit"),
            glyph = "external-link",
            variant = "ghost",
            onClick = "onOpenDisplays",
        }))
    end

    local runtimeError = if type(state) == "table" then tostring(state.runtimeError or "") else ""
    local menuError = if type(menu) == "table" then tostring(menu.error or "") else ""
    if runtimeError ~= "" then
        table.insert(body, ui.label({ text = runtimeError, color = "error", maxLines = 3 }))
    elseif menuError ~= "" then
        table.insert(body, ui.label({ text = menuError, color = "error", maxLines = 3 }))
    end
    table.insert(body, ui.separator())
    table.insert(body, ui.button({
        text = noctalia.tr("panel.settings"),
        glyph = "settings",
        variant = "ghost",
        onClick = "onOpenSettings",
    }))

    panel.render(ui.column({ flexGrow = 1, gap = 8 }, {
        body[1],
        ui.scroll({ flexGrow = 1, gap = 8, padding = 12 }, { table.unpack(body, 2) }),
    }))
end

function onClosePanel()
    panel.close()
end

function onOpenApp()
    send("open-app", nil)
    panel.close()
end

function onOpenSchedules()
    send("open-app", "schedules")
    panel.close()
end

function onOpenDisplays()
    send("open-app", "displays")
    panel.close()
end

function onOpenSettings()
    panel.close()
    noctalia.openSettings()
end

function onRefresh()
    send("status", nil)
end

function onResumeSchedule()
    send("schedule-follow", nil)
end

function onPrevious()
    send("previous", nil)
end

function onToggle()
    send("toggle", nil)
end

function onNext()
    send("next", nil)
end

function onRandom()
    send("random", nil)
end

function onShuffle()
    send("shuffle", if type(state) == "table" and state.shuffle == true then "off" else "on")
end

function onOpen(_context)
    state = noctalia.state.get(STATE_KEY)
    menu = noctalia.state.get(MENU_KEY)
    send(if running() then "status" else "launch", nil)
    render()
end

noctalia.state.watch(STATE_KEY, function(nextState)
    state = nextState
    -- Every successful runtime status publishes MENU_KEY immediately after
    -- STATE_KEY. Let that second watcher render the complete atomic snapshot
    -- once instead of rebuilding the full playlist list twice.
    if not running() then
        render()
    end
end)
noctalia.state.watch(MENU_KEY, function(nextMenu)
    menu = nextMenu
    render()
end)

state = noctalia.state.get(STATE_KEY)
menu = noctalia.state.get(MENU_KEY)
render()

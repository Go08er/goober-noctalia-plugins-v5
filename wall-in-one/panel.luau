--!nonstrict
-- A small playlist switcher. Editing stays in the standalone GTK app; this
-- panel covers only the decisions that are useful from a bar.

local STATE_KEY = "wall_in_one_state"
local MENU_KEY = "wall_in_one_menu"
local COMMAND_KEY = "wall_in_one_command"

local state = nil
local menu = nil
local commandSequence = 0
local page = "main"
local selectedDisplay = ""

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

local function schedule()
    return if type(menu) == "table" and type(menu.schedule) == "table"
        then menu.schedule
        else { count = 0, default = "", rule = "", when = "" }
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

local function header(title, subtitle, showBack)
    return ui.row({ gap = 8, align = "center", padding = 12 }, {
        if showBack
            then ui.button({ glyph = "arrow-left", variant = "ghost", onClick = "onBack" })
            else ui.glyph({
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

local function activePlaylistName()
    for _, row in ipairs(playlists()) do
        if row.active == true then
            return tostring(row.name or "")
        end
    end
    return ""
end

local function renderDisplay()
    local wanted = nil
    for _, row in ipairs(displays()) do
        if tostring(row.connector or "") == selectedDisplay then
            wanted = row
            break
        end
    end
    if wanted == nil then
        page = "main"
        render()
        return
    end

    local body = {
        header(
            tostring(wanted.label or wanted.connector),
            noctalia.tr("panel.displays.current", { playlist = tostring(wanted.playlist or "") }),
            true
        ),
        ui.separator(),
        ui.label({
            text = noctalia.tr("panel.displays.choose"),
            fontSize = 12,
            fontWeight = "bold",
        }),
        ui.button({
            text = noctalia.tr("panel.displays.follow_default"),
            glyph = "calendar-clock",
            variant = if tostring(wanted.playlist or "") == "(default)" then "primary" else "ghost",
            enabled = running() and tostring(wanted.playlist or "") ~= "(default)",
            onClick = function()
                send("display-clear", selectedDisplay)
                onBack()
            end,
        }),
    }
    for _, row in ipairs(playlists()) do
        local playlistName = tostring(row.name or "")
        table.insert(body, ui.button({
            text = playlistName,
            glyph = "playlist",
            variant = if tostring(wanted.playlist or "") == playlistName then "primary" else "ghost",
            enabled = running() and tostring(wanted.playlist or "") ~= playlistName,
            onClick = function()
                send("display-assign", selectedDisplay .. " " .. playlistName)
                onBack()
            end,
        }))
    end
    panel.render(ui.column({ flexGrow = 1, gap = 8 }, {
        body[1],
        ui.scroll({ flexGrow = 1, gap = 8, padding = 12 }, { table.unpack(body, 2) }),
    }))
end

function render()
    if page == "display" then
        renderDisplay()
        return
    end

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

    local body = {
        header(noctalia.tr("panel.title"), summary, false),
        ui.separator(),
        ui.row({ gap = 8 }, {
            ui.button({
                text = noctalia.tr("panel.open_app"),
                glyph = "external-link",
                variant = "primary",
                flexGrow = 1,
                onClick = "onOpenApp",
            }),
            ui.button({
                glyph = "refresh",
                variant = "ghost",
                enabled = running(),
                onClick = "onRefresh",
            }),
        }),
        ui.label({ text = noctalia.tr("panel.schedule.title"), fontSize = 12, fontWeight = "bold" }),
    }

    local scheduleInfo = schedule()
    local active = activePlaylistName()
    table.insert(body, ui.label({
        text = if active ~= ""
            then noctalia.tr("panel.schedule.active", { playlist = active })
            else noctalia.tr("panel.schedule.no_playlist"),
        color = "on_surface_variant",
        maxLines = 2,
    }))
    if tostring(scheduleInfo.rule or "") ~= "" then
        table.insert(body, ui.label({
            text = noctalia.tr("panel.schedule.rule", {
                playlist = tostring(scheduleInfo.rule),
                when = tostring(scheduleInfo.when),
            }),
            color = "on_surface_variant",
            fontSize = 11,
            maxLines = 3,
        }))
    elseif tostring(scheduleInfo.default or "") ~= "" then
        table.insert(body, ui.label({
            text = noctalia.tr("panel.schedule.default", { playlist = tostring(scheduleInfo.default) }),
            color = "on_surface_variant",
            fontSize = 11,
            maxLines = 2,
        }))
    end
    table.insert(body, ui.row({ gap = 8 }, {
        ui.button({
            text = noctalia.tr("panel.schedule.resume"),
            glyph = "calendar-clock",
            enabled = running(),
            flexGrow = 1,
            onClick = "onResumeSchedule",
        }),
        ui.button({
            text = noctalia.tr("panel.schedule.edit"),
            glyph = "edit",
            flexGrow = 1,
            onClick = "onOpenApp",
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
            local connector = tostring(row.connector or "")
            table.insert(body, ui.button({
                text = noctalia.tr("panel.displays.row", {
                    display = tostring(row.label or connector),
                    playlist = tostring(row.playlist or ""),
                }),
                glyph = "device-desktop",
                variant = "ghost",
                enabled = running(),
                onClick = function()
                    selectedDisplay = connector
                    page = "display"
                    render()
                end,
            }))
        end
    end

    local menuError = if type(menu) == "table" then tostring(menu.error or "") else ""
    if menuError ~= "" then
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

function onBack()
    page = "main"
    selectedDisplay = ""
    render()
end

function onOpenApp()
    send("open-app", nil)
    panel.close()
end

function onOpenSettings()
    panel.close()
    noctalia.openSettings()
end

function onRefresh()
    send("playlists", nil)
end

function onResumeSchedule()
    send("playlist-use", "none")
end

function onOpen(_context)
    page = "main"
    selectedDisplay = ""
    state = noctalia.state.get(STATE_KEY)
    menu = noctalia.state.get(MENU_KEY)
    if running() then
        send("playlists", nil)
    else
        send("launch", nil)
    end
    render()
end

noctalia.state.watch(STATE_KEY, function(nextState)
    local wasRunning = running()
    state = nextState
    if running() and not wasRunning then
        send("playlists", nil)
    end
    render()
end)
noctalia.state.watch(MENU_KEY, function(nextMenu)
    menu = nextMenu
    render()
end)

state = noctalia.state.get(STATE_KEY)
menu = noctalia.state.get(MENU_KEY)
render()

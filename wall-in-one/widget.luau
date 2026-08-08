--!nonstrict
-- Bar client. Presentation only: every configured click opens the same small
-- playlist menu, and the singleton service owns every call to the app.

local STATE_KEY = "wall_in_one_state"
local MAX_TEXT = 22

local state = nil
local hovered = false

local function widgetCfg(key)
    return noctalia.getConfig(key)
end

local function glyphCfg(key, fallback)
    local value = widgetCfg(key)
    if type(value) == "string" and string.find(value, "%S") ~= nil then
        return value
    end
    return fallback
end

local function running()
    return type(state) == "table" and state.running == true
end

local function starting()
    return type(state) == "table" and state.launching == true
end

local function shorten(value)
    local length = utf8.len(value)
    if length == nil or length <= MAX_TEXT then
        return value
    end
    -- Cut on a codepoint boundary; a filename is arbitrary UTF-8.
    local cut = utf8.offset(value, MAX_TEXT + 1)
    return if cut == nil then value else string.sub(value, 1, cut - 1) .. "…"
end

local function presentation()
    if not running() then
        return glyphCfg("stopped_glyph", "photo-off"), widgetCfg("stopped_color")
    end
    return glyphCfg("glyph", "library-photo"), widgetCfg("color")
end

local function tooltip()
    if not running() then
        if starting() then
            return noctalia.tr("widget.title") .. "\n" .. noctalia.tr("widget.starting")
        end
        local detail = if type(state) == "table" then tostring(state.error or "") else ""
        if detail ~= "" then
            return noctalia.tr("widget.title") .. "\n" .. detail
        end
        return noctalia.tr("widget.title") .. "\n" .. noctalia.tr("widget.stopped_hint")
    end

    local showing = tostring(state.showing or "")
    return table.concat({
        noctalia.tr("widget.title"),
        if showing ~= "" then showing else noctalia.tr("widget.nothing_applied"),
        noctalia.tr("widget.playable", { playable = tostring(state.playable), total = tostring(state.library) }),
        "",
        noctalia.tr("widget.gestures"),
    }, "\n")
end

local function render()
    local glyph, color = presentation()

    local text = if running()
        then shorten(tostring(state.showing or ""))
        elseif starting()
        then noctalia.tr("widget.starting")
        else noctalia.tr("widget.stopped")
    local mode = tostring(widgetCfg("display_mode") or "always")
    if mode == "icon_only" or (mode == "on_hover" and not hovered) then
        text = ""
    end

    barWidget.setGlyph(tostring(glyph))
    barWidget.setText(text)
    barWidget.setTooltip(tooltip())
    barWidget.setGlyphColor(tostring(color or "on_surface"))
    barWidget.setColor(tostring(color or "on_surface"))
end

noctalia.state.watch(STATE_KEY, function(nextState)
    state = nextState
    render()
end)
state = noctalia.state.get(STATE_KEY)
render()

function update()
    -- The service polls; this callback only repaints on host-driven ticks.
    noctalia.setUpdateInterval(60 * 60 * 1000)
    render()
end

function onHover(entered)
    hovered = entered == true
    render()
end

--!nonstrict
-- Control Center shortcut. Plugin shortcuts expose a left and a right
-- callback, so this is the keyboard-reachable half of the transport: advance
-- on the left, pick at random on the right.

local STATE_KEY = "wall_in_one_state"
local COMMAND_KEY = "wall_in_one_command"
local READY_KEY = "wall_in_one_ready"

local state = nil
local commandSequence = 0
local pending = nil

local function running()
    return type(state) == "table" and state.running == true
end

local function render()
    shortcut.setLabel(if running() then noctalia.tr("shortcut.label") else noctalia.tr("shortcut.open"))
    shortcut.setIcon("library-photo", "photo-off")
    shortcut.setActive(false)
    shortcut.setEnabled(true)
end

local function send(verb)
    if noctalia.state.get(READY_KEY) ~= true then
        -- The service may still be loading; replay once it announces itself.
        pending = verb
        return
    end
    local previous = noctalia.state.get(COMMAND_KEY)
    local previousSequence = if type(previous) == "table" then tonumber(previous.sequence) or 0 else 0
    commandSequence = math.max(commandSequence, previousSequence) + 1
    noctalia.state.set(COMMAND_KEY, {
        verb = verb,
        producer = "shortcut",
        sequence = commandSequence,
    })
end

noctalia.state.watch(STATE_KEY, function(nextState)
    state = nextState
    render()
end)
noctalia.state.watch(READY_KEY, function(ready)
    if ready == true and pending ~= nil then
        local verb = pending
        pending = nil
        send(verb)
    end
end)

state = noctalia.state.get(STATE_KEY)
render()

function onClick()
    send(if running() then "next" else "launch")
end

function onRightClick()
    send(if running() then "random" else "launch")
end

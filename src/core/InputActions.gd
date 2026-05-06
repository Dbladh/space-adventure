extends RefCounted

# InputActions.gd — central registry of remappable game actions.
#
# Static registry called once at startup (Main._ready) to register each
# action with the InputMap and add the default bindings.  RebindUI lists
# only actions in REBINDABLE; "press a button to set" replaces the
# joypad-button event for the chosen action.
#
# Player.gd uses Input.is_action_pressed("name") for these instead of
# the previous hard-coded JOY_BUTTON_X / KEY_X polling, so a rebind
# takes effect on the next frame without restart.
#
# The keyboard fallbacks stay in place so desktop play without a
# controller still works, and rebinding only edits the joypad-button
# event in the action's events list (the keyboard fallback is preserved).

const FIRE       := "fire"
const WARP       := "warp"
const ROLL_LEFT  := "roll_left"
const ROLL_RIGHT := "roll_right"
const PAUSE      := "pause"

# label, action_name, default joy button, default key
const REBINDABLE: Array = [
	{"label": "Fire",       "action": FIRE,       "joy": JOY_BUTTON_Y,              "key": KEY_F},
	{"label": "Warp / Boost","action": WARP,      "joy": JOY_BUTTON_A,              "key": KEY_SHIFT},
	{"label": "Roll Left",  "action": ROLL_LEFT,  "joy": JOY_BUTTON_LEFT_SHOULDER,  "key": KEY_Q},
	{"label": "Roll Right", "action": ROLL_RIGHT, "joy": JOY_BUTTON_RIGHT_SHOULDER, "key": KEY_E},
	{"label": "Pause",      "action": PAUSE,      "joy": JOY_BUTTON_START,          "key": KEY_ESCAPE},
]


static func register_all() -> void:
	for entry in REBINDABLE:
		_register_action(entry["action"], entry["joy"], entry["key"])


static func _register_action(action: String, joy: int, key: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	# Don't double-register — register_all may be called twice in editor restarts.
	if not _has_joy_button(action, joy):
		var ev := InputEventJoypadButton.new()
		ev.button_index = joy
		InputMap.action_add_event(action, ev)
	if not _has_keycode(action, key):
		var ek := InputEventKey.new()
		ek.keycode = key
		InputMap.action_add_event(action, ek)


# Replace the joypad-button event in an action's binding list.  Used by
# RebindUI when the user presses a new button while the row is in
# "listening" mode.  Keyboard / axis events are left untouched.
static func rebind_joy_button(action: String, new_joy: int) -> void:
	if not InputMap.has_action(action): return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			InputMap.action_erase_event(action, ev)
	var nev := InputEventJoypadButton.new()
	nev.button_index = new_joy
	InputMap.action_add_event(action, nev)


# Look up the current joypad button for an action — used by the rebind
# UI to render "Current: A" labels.  Returns -1 if no joy button bound.
static func joy_button_for(action: String) -> int:
	if not InputMap.has_action(action): return -1
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton:
			return (ev as InputEventJoypadButton).button_index
	return -1


static func joy_button_name(button: int) -> String:
	match button:
		JOY_BUTTON_A: return "A"
		JOY_BUTTON_B: return "B"
		JOY_BUTTON_X: return "X"
		JOY_BUTTON_Y: return "Y"
		JOY_BUTTON_LEFT_SHOULDER: return "LB"
		JOY_BUTTON_RIGHT_SHOULDER: return "RB"
		JOY_BUTTON_LEFT_STICK: return "L3"
		JOY_BUTTON_RIGHT_STICK: return "R3"
		JOY_BUTTON_BACK: return "BACK"
		JOY_BUTTON_START: return "START"
		JOY_BUTTON_GUIDE: return "GUIDE"
		JOY_BUTTON_DPAD_UP: return "D-Up"
		JOY_BUTTON_DPAD_DOWN: return "D-Down"
		JOY_BUTTON_DPAD_LEFT: return "D-Left"
		JOY_BUTTON_DPAD_RIGHT: return "D-Right"
		_: return "Btn " + str(button)


static func _has_joy_button(action: String, joy: int) -> bool:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and (ev as InputEventJoypadButton).button_index == joy:
			return true
	return false


static func _has_keycode(action: String, key: int) -> bool:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey and (ev as InputEventKey).keycode == key:
			return true
	return false

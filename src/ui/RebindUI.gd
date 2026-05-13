extends Control

# RebindUI.gd
#
# Rebind submenu launched from PauseMenuUI.  Lists every entry in
# InputActions.REBINDABLE.  Selecting a row's [SET] button (mouse click,
# keyboard Enter, or gamepad A) puts that row into "listening" mode —
# the next gamepad button press becomes the new binding.
#
# process_mode = ALWAYS so it runs while the tree is paused.

signal closed()

const InputActions := preload("res://src/core/InputActions.gd")
const HUDStyle := preload("res://src/ui/HUDStyle.gd")

var _listening_action: String = ""    # empty when no row is listening
var _listening_label: Label = null    # the row's "Current: X" label, updated after capture
var _rows: Array = []                 # each entry: {action, label, set_btn}


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.color = Color(HUDStyle.BG_DEEP_PURPLE.r, HUDStyle.BG_DEEP_PURPLE.g, HUDStyle.BG_DEEP_PURPLE.b, 0.92)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Outer beveled plate, then a CRT-green list panel inside for the action rows.
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	plate.set_anchors_preset(Control.PRESET_CENTER)
	plate.offset_left = -300; plate.offset_right = 300
	plate.offset_top = -280; plate.offset_bottom = 280
	add_child(plate)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)
	plate.add_child(vb)

	var title := Label.new()
	title.text = "REBIND CONTROLS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HUDStyle.style_label(title, HUDStyle.HUD_FONT_XL, HUDStyle.CRT_GREEN_BG)
	vb.add_child(title)

	var hint := Label.new()
	hint.text = "PICK AN ACTION,\nTHEN PRESS A GAMEPAD BUTTON"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HUDStyle.style_label(hint, HUDStyle.HUD_FONT_TINY, Color(0.85, 0.85, 0.95))
	vb.add_child(hint)

	var pad := Control.new(); pad.custom_minimum_size = Vector2(0, 8); vb.add_child(pad)

	# CRT-green data screen housing the action rows.
	var rows_panel := PanelContainer.new()
	rows_panel.add_theme_stylebox_override("panel", HUDStyle.crt_screen_panel())
	rows_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(rows_panel)

	var rows_box := VBoxContainer.new()
	rows_box.add_theme_constant_override("separation", 6)
	rows_panel.add_child(rows_box)

	# One row per remappable action.
	var first_set: Button = null
	for entry in InputActions.REBINDABLE:
		var row := _build_row(entry["label"], entry["action"])
		rows_box.add_child(row)
		if first_set == null:
			first_set = row.get_meta("set_btn") as Button

	var pad2 := Control.new(); pad2.custom_minimum_size = Vector2(0, 8); vb.add_child(pad2)

	var back_btn := Button.new()
	back_btn.text = "BACK"
	HUDStyle.style_button(back_btn, HUDStyle.BTN_RED, HUDStyle.HUD_FONT_LRG)
	back_btn.custom_minimum_size = Vector2(240, 50)
	back_btn.pressed.connect(_on_back)
	vb.add_child(back_btn)

	if first_set: first_set.call_deferred("grab_focus")


func _build_row(label_text: String, action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)

	var name_lbl := Label.new()
	name_lbl.text = label_text.to_upper()
	name_lbl.custom_minimum_size = Vector2(200, 40)
	HUDStyle.style_label(name_lbl, HUDStyle.HUD_FONT_SMALL, HUDStyle.CRT_GREEN_INK)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_lbl)

	var current_lbl := Label.new()
	current_lbl.text = _current_binding_text(action)
	current_lbl.custom_minimum_size = Vector2(130, 40)
	HUDStyle.style_label(current_lbl, HUDStyle.HUD_FONT_SMALL, HUDStyle.CRT_GREEN_INK)
	current_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(current_lbl)

	var set_btn := Button.new()
	set_btn.text = "SET"
	HUDStyle.style_button(set_btn, HUDStyle.BTN_BLUE, HUDStyle.HUD_FONT_SMALL)
	set_btn.custom_minimum_size = Vector2(96, 40)
	set_btn.pressed.connect(func() -> void: _on_set(action, set_btn, current_lbl))
	row.add_child(set_btn)

	row.set_meta("action", action)
	row.set_meta("current_lbl", current_lbl)
	row.set_meta("set_btn", set_btn)
	return row


func _current_binding_text(action: String) -> String:
	var btn := InputActions.joy_button_for(action)
	if btn < 0: return "(unbound)"
	return InputActions.joy_button_name(btn)


func _on_set(action: String, set_btn: Button, current_lbl: Label) -> void:
	# Enter listening mode for this action — next joypad-button press
	# captured by _input replaces the binding.  The SET button is restyled
	# in yellow with the bevel inverted so it visibly sinks into the row,
	# matching the EASY-style "selected" look from the reference image.
	_listening_action = action
	_listening_label = current_lbl
	set_btn.text = "..."
	# Lock into the recessed yellow look by overriding ALL state styleboxes.
	var rec := HUDStyle.bevel_stylebox(HUDStyle.BTN_YELLOW, true, false)
	set_btn.add_theme_stylebox_override("normal",   rec)
	set_btn.add_theme_stylebox_override("hover",    rec)
	set_btn.add_theme_stylebox_override("pressed",  rec)
	set_btn.add_theme_stylebox_override("focus",    rec)
	current_lbl.text = "PRESS A BUTTON"
	current_lbl.add_theme_color_override("font_color", HUDStyle.BTN_YELLOW.darkened(0.3))


func _on_back() -> void:
	closed.emit()


func _input(event: InputEvent) -> void:
	# Capture the next joypad-button press to complete a rebind.  We
	# intentionally do NOT capture key presses here — keyboard bindings
	# are left untouched so desktop fallback still works.
	if _listening_action != "":
		if event is InputEventJoypadButton and event.pressed:
			var jb: InputEventJoypadButton = event
			InputActions.rebind_joy_button(_listening_action, jb.button_index)
			# Refresh the row labels and clear listening state.
			if _listening_label:
				_listening_label.text = InputActions.joy_button_name(jb.button_index)
				_listening_label.add_theme_color_override("font_color", HUDStyle.CRT_GREEN_INK)
			# Restore SET button styleboxes on whichever row was listening.
			for child in _find_set_buttons():
				var btn: Button = child
				if btn.text == "...":
					btn.text = "SET"
					HUDStyle.style_button(btn, HUDStyle.BTN_BLUE, HUDStyle.HUD_FONT_SMALL)
			_listening_action = ""
			_listening_label = null
			get_viewport().set_input_as_handled()
		return

	# When NOT listening, Escape / B / START backs out of the rebind UI.
	var back_pressed := false
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		back_pressed = true
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_B:
			back_pressed = true
	if back_pressed:
		closed.emit()
		get_viewport().set_input_as_handled()


func _find_set_buttons() -> Array:
	var out: Array = []
	_collect_set_btns(self, out)
	return out


func _collect_set_btns(n: Node, out: Array) -> void:
	if n is Button and (n as Button).text in ["SET", "..."]:
		out.append(n)
	for c in n.get_children():
		_collect_set_btns(c, out)

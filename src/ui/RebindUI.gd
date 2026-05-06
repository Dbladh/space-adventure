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

var _listening_action: String = ""    # empty when no row is listening
var _listening_label: Label = null    # the row's "Current: X" label, updated after capture
var _rows: Array = []                 # each entry: {action, label, set_btn}


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	var bg := ColorRect.new()
	bg.color = Color(0.03, 0.03, 0.06, 0.95)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.offset_left = -260; vb.offset_right = 260
	vb.offset_top = -260; vb.offset_bottom = 260
	add_child(vb)

	var title := Label.new()
	title.text = "REBIND CONTROLS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 36)
	title.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))
	vb.add_child(title)

	var hint := Label.new()
	hint.text = "Select an action and press the gamepad button you want to bind."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 14)
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	vb.add_child(hint)

	var pad := Control.new(); pad.custom_minimum_size = Vector2(0, 12); vb.add_child(pad)

	# One row per remappable action.
	var first_set: Button = null
	for entry in InputActions.REBINDABLE:
		var row := _build_row(entry["label"], entry["action"])
		vb.add_child(row)
		if first_set == null:
			first_set = row.get_meta("set_btn") as Button

	var pad2 := Control.new(); pad2.custom_minimum_size = Vector2(0, 12); vb.add_child(pad2)

	var back_btn := Button.new()
	back_btn.text = "BACK"
	back_btn.add_theme_font_size_override("font_size", 22)
	back_btn.custom_minimum_size = Vector2(220, 44)
	back_btn.pressed.connect(_on_back)
	vb.add_child(back_btn)

	if first_set: first_set.call_deferred("grab_focus")


func _build_row(label_text: String, action: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.custom_minimum_size = Vector2(180, 36)
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_lbl)

	var current_lbl := Label.new()
	current_lbl.text = _current_binding_text(action)
	current_lbl.custom_minimum_size = Vector2(110, 36)
	current_lbl.add_theme_font_size_override("font_size", 16)
	current_lbl.add_theme_color_override("font_color", Color(0.95, 0.85, 0.3))
	current_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	current_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(current_lbl)

	var set_btn := Button.new()
	set_btn.text = "SET"
	set_btn.custom_minimum_size = Vector2(90, 36)
	set_btn.add_theme_font_size_override("font_size", 16)
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
	# captured by _input replaces the binding.
	_listening_action = action
	_listening_label = current_lbl
	set_btn.text = "..."
	current_lbl.text = "press a button"
	current_lbl.add_theme_color_override("font_color", Color(0.4, 0.85, 1.0))


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
				_listening_label.add_theme_color_override("font_color", Color(0.95, 0.85, 0.3))
			# Restore SET button label on whichever row was listening.
			for child in _find_set_buttons():
				var btn: Button = child
				if btn.text == "...":
					btn.text = "SET"
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

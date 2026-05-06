extends Control

# PauseMenuUI.gd
#
# Full-screen pause overlay with Resume / Rebind Controls / Quit buttons.
# process_mode = ALWAYS so its _input runs while the scene tree is paused —
# Main's own _unhandled_input is gated by Main's INHERIT process_mode and
# never fires during pause, which is why the previous overlay (a plain
# ColorRect with no input handler) had no way to be dismissed by gamepad.
#
# Emits high-level intents back to Main so this widget stays purely UI.

signal resume_requested()
signal rebind_requested()
signal quit_requested()

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Translucent dim
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.65)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Centred VBox
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	vb.set_anchors_preset(Control.PRESET_CENTER)
	vb.offset_left = -180; vb.offset_right = 180
	vb.offset_top = -180;  vb.offset_bottom = 180
	add_child(vb)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(0.95, 0.95, 1.0))
	vb.add_child(title)

	var pad := Control.new(); pad.custom_minimum_size = Vector2(0, 12); vb.add_child(pad)

	var resume_btn := _make_btn("RESUME")
	resume_btn.pressed.connect(func() -> void: resume_requested.emit())
	vb.add_child(resume_btn)

	var rebind_btn := _make_btn("REBIND CONTROLS")
	rebind_btn.pressed.connect(func() -> void: rebind_requested.emit())
	vb.add_child(rebind_btn)

	var quit_btn := _make_btn("QUIT TO DESKTOP")
	quit_btn.pressed.connect(func() -> void: quit_requested.emit())
	vb.add_child(quit_btn)

	resume_btn.call_deferred("grab_focus")


func _make_btn(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 22)
	b.custom_minimum_size = Vector2(300, 48)
	return b


func _input(event: InputEvent) -> void:
	if not visible: return
	# Either Escape, gamepad B, or gamepad START closes the pause menu —
	# matches the symmetric "press pause again to leave a menu" rule used
	# by SpaceStation and PlanetPlacementUI.
	var close_pressed := false
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_pressed = true
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_START or event.button_index == JOY_BUTTON_B:
			close_pressed = true
	if close_pressed:
		resume_requested.emit()
		get_viewport().set_input_as_handled()

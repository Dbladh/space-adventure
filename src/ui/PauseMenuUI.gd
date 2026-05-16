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

const HUDStyle = preload("res://src/ui/HUDStyle.gd")

var _resume_btn: Button = null
var _is_mobile_ui: bool = MobilePerf.is_mobile()

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Saturated arcade-purple dim — picks up the Designercize reference's
	# canvas colour so the menu reads as a "screen" rather than a faded fade.
	var bg := ColorRect.new()
	bg.color = Color(HUDStyle.BG_DEEP_PURPLE.r, HUDStyle.BG_DEEP_PURPLE.g, HUDStyle.BG_DEEP_PURPLE.b, 0.86)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# Centred beveled panel — the menu plate.  Uses PANEL_BEVEL (medium
	# navy) so the chunky highlight + drop shadow reads clearly.
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	plate.set_anchors_preset(Control.PRESET_CENTER)
	var plate_half_w: int = 320 if _is_mobile_ui else 220
	var plate_half_h: int = 280 if _is_mobile_ui else 220
	plate.offset_left = -plate_half_w; plate.offset_right = plate_half_w
	plate.offset_top  = -plate_half_h; plate.offset_bottom = plate_half_h
	add_child(plate)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	plate.add_child(vb)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HUDStyle.style_label(title, HUDStyle.HUD_FONT_TITLE, HUDStyle.CRT_GREEN_BG)
	vb.add_child(title)

	var pad := Control.new(); pad.custom_minimum_size = Vector2(0, 12); vb.add_child(pad)

	_resume_btn = _make_btn("RESUME", HUDStyle.BTN_GREEN)
	_resume_btn.pressed.connect(func() -> void: resume_requested.emit())
	vb.add_child(_resume_btn)

	var rebind_btn := _make_btn("REBIND CONTROLS", HUDStyle.BTN_BLUE)
	rebind_btn.pressed.connect(func() -> void: rebind_requested.emit())
	vb.add_child(rebind_btn)

	var quit_btn := _make_btn("QUIT TO DESKTOP", HUDStyle.BTN_RED)
	quit_btn.pressed.connect(func() -> void: quit_requested.emit())
	vb.add_child(quit_btn)

	# Re-grab focus every time the menu becomes visible.  _ready only
	# fires once, but we hide/show this node across the session, so a
	# one-time grab_focus left the controller stranded after the first
	# unpause.
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _on_visibility_changed() -> void:
	if visible and is_instance_valid(_resume_btn):
		_resume_btn.call_deferred("grab_focus")


func _make_btn(text: String, color: Color = HUDStyle.BTN_BLUE) -> Button:
	var b := Button.new()
	b.text = text
	HUDStyle.style_button(b, color, HUDStyle.HUD_FONT_LRG)
	b.custom_minimum_size = Vector2(520, 76) if _is_mobile_ui else Vector2(340, 56)
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

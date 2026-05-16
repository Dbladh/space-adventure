extends Control

# PauseMenuUI.gd
#
# Unified pause overlay split into two screens that share a plate:
#   1. PAUSE — primary actions (RESUME / SETTINGS / SAVE / NEW GAME / (desktop) QUIT).
#   2. SETTINGS — audio + control prefs + (desktop) rebind, reached via the
#      SETTINGS button on screen 1.  BACK / ESC / B / START returns to PAUSE.
#
# process_mode = ALWAYS so _input runs while the scene tree is paused.
# Emits high-level intents back to Main; menu owns its layout, Main owns the actions.

signal resume_requested()
signal rebind_requested()
signal quit_requested()
signal music_volume_changed(level: int)      # 0..4
signal sfx_volume_changed(level: int)
signal gyro_toggled(paused: bool)
signal sens_changed(idx: int)
signal dead_changed(idx: int)
signal save_requested()
signal new_game_confirmed()

const HUDStyle = preload("res://src/ui/HUDStyle.gd")

const VOLUME_STEPS: int = 5  # 0 mute, 4 full

var _is_mobile_ui: bool = MobilePerf.is_mobile()

# Two screens that share the centered plate.  Only one visible at a time.
var _pause_screen:    VBoxContainer = null
var _settings_screen: VBoxContainer = null

# Primary-pause widgets we keep references to
var _resume_btn: Button = null
var _save_btn:   Button = null

# Settings widgets we keep references to so cycler labels can refresh
var _music_btn: Button = null
var _sfx_btn:   Button = null
var _gyro_btn:  Button = null
var _sens_btn:  Button = null
var _dead_btn:  Button = null

# Persisted-state mirror (kept in-memory so cycler labels stay correct without
# round-tripping through SettingsManager every tap).
var _music_level: int = 4
var _sfx_level:   int = 4
var _gyro_paused: bool = false
var _sens_idx:    int = 1
var _dead_idx:    int = 1

# Destructive confirm modal — lazy-built on first NEW GAME tap.
var _confirm_dim:   ColorRect = null
var _confirm_plate: PanelContainer = null

const _SENS_LABELS := ["LOW", "MED", "HIGH"]
const _DEAD_LABELS := ["NARROW", "MED", "WIDE"]


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Mirror persisted state so cyclers display the saved level on first open.
	if Engine.has_meta("SettingsManager"):
		var sm = Engine.get_meta("SettingsManager")
		_music_level = int(sm.music_level)
		_sfx_level   = int(sm.sfx_level)
		_gyro_paused = bool(sm.gyro_paused)
		_sens_idx    = int(sm.sens_idx)
		_dead_idx    = int(sm.dead_idx)

	# ── DIM BACKDROP ──────────────────────────────────────────────────────
	var bg := ColorRect.new()
	bg.color = Color(HUDStyle.BG_DEEP_PURPLE.r, HUDStyle.BG_DEEP_PURPLE.g, HUDStyle.BG_DEEP_PURPLE.b, 0.86)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# ── CENTERED PLATE ────────────────────────────────────────────────────
	# Sized to fit the LARGER of the two screens (settings has ~7 rows on
	# mobile), so when pause screen is showing it just looks generously padded.
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	plate.set_anchors_preset(Control.PRESET_CENTER)
	var plate_half_w: int = 320 if _is_mobile_ui else 220
	var plate_half_h: int = 360 if _is_mobile_ui else 290
	plate.offset_left = -plate_half_w; plate.offset_right = plate_half_w
	plate.offset_top  = -plate_half_h; plate.offset_bottom = plate_half_h
	add_child(plate)

	# Stack both screens in the same slot — only one is `visible` at a time.
	# Wrap in a MarginContainer-less Control so both screens get the plate's
	# full content rect.
	var screen_host := Control.new()
	screen_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	screen_host.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	plate.add_child(screen_host)

	_pause_screen = _build_pause_screen()
	_pause_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_host.add_child(_pause_screen)

	_settings_screen = _build_settings_screen()
	_settings_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_screen.visible = false
	screen_host.add_child(_settings_screen)

	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()


func _on_visibility_changed() -> void:
	# Reset to pause screen each time the menu becomes visible; focus RESUME.
	if not visible: return
	_show_pause_screen()
	if is_instance_valid(_resume_btn):
		_resume_btn.call_deferred("grab_focus")


# ─── Screen builders ──────────────────────────────────────────────────────

func _build_pause_screen() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 12)

	var title := Label.new()
	title.text = "PAUSED"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HUDStyle.style_label(title, HUDStyle.HUD_FONT_TITLE, HUDStyle.CRT_GREEN_BG)
	vb.add_child(title)

	_resume_btn = _make_btn("RESUME", HUDStyle.BTN_GREEN, HUDStyle.HUD_FONT_LRG)
	_resume_btn.pressed.connect(func() -> void: resume_requested.emit())
	vb.add_child(_resume_btn)

	var settings_btn := _make_btn("SETTINGS", HUDStyle.BTN_BLUE)
	settings_btn.pressed.connect(_show_settings_screen)
	vb.add_child(settings_btn)

	_save_btn = _make_btn("SAVE GAME", HUDStyle.BTN_GREEN)
	_save_btn.pressed.connect(_on_save_pressed)
	vb.add_child(_save_btn)

	var new_btn := _make_btn("NEW GAME", HUDStyle.BTN_RED)
	new_btn.pressed.connect(_on_new_game_pressed)
	vb.add_child(new_btn)

	if not _is_mobile_ui:
		var quit_btn := _make_btn("QUIT TO DESKTOP", HUDStyle.BTN_RED)
		quit_btn.pressed.connect(func() -> void: quit_requested.emit())
		vb.add_child(quit_btn)

	return vb


func _build_settings_screen() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 10)

	# BACK row — labeled button at top-left, plus screen title centered.
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 12)
	top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_child(top_row)

	var back_btn := Button.new()
	back_btn.text = "← BACK"
	HUDStyle.style_button(back_btn, HUDStyle.BTN_BLUE, HUDStyle.HUD_FONT_MED)
	back_btn.custom_minimum_size = Vector2(140, 56) if _is_mobile_ui else Vector2(110, 40)
	back_btn.pressed.connect(_show_pause_screen)
	top_row.add_child(back_btn)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	HUDStyle.style_label(title, HUDStyle.HUD_FONT_LRG, HUDStyle.CRT_GREEN_BG)
	top_row.add_child(title)

	# Spacer to balance the BACK button width so title stays centered.
	var balance := Control.new()
	balance.custom_minimum_size = Vector2(140 if _is_mobile_ui else 110, 0)
	balance.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.add_child(balance)

	# Audio
	_music_btn = _make_cycler_btn(_format_volume("MUSIC", _music_level), HUDStyle.BTN_BLUE)
	_music_btn.pressed.connect(_on_music_pressed)
	vb.add_child(_music_btn)
	_sfx_btn = _make_cycler_btn(_format_volume("SFX  ", _sfx_level), HUDStyle.BTN_BLUE)
	_sfx_btn.pressed.connect(_on_sfx_pressed)
	vb.add_child(_sfx_btn)

	# Mobile controls
	if _is_mobile_ui:
		_gyro_btn = _make_cycler_btn(_format_gyro(_gyro_paused), HUDStyle.BTN_BLUE)
		_gyro_btn.pressed.connect(_on_gyro_pressed)
		vb.add_child(_gyro_btn)
		_sens_btn = _make_cycler_btn("SENS: " + _SENS_LABELS[_sens_idx], HUDStyle.BTN_BLUE)
		_sens_btn.pressed.connect(_on_sens_pressed)
		vb.add_child(_sens_btn)
		_dead_btn = _make_cycler_btn("DEAD: " + _DEAD_LABELS[_dead_idx], HUDStyle.BTN_BLUE)
		_dead_btn.pressed.connect(_on_dead_pressed)
		vb.add_child(_dead_btn)

	# Desktop rebind
	if not _is_mobile_ui:
		var rebind_btn := _make_btn("REBIND CONTROLS", HUDStyle.BTN_BLUE)
		rebind_btn.pressed.connect(func() -> void: rebind_requested.emit())
		vb.add_child(rebind_btn)

	return vb


# ─── Screen navigation ────────────────────────────────────────────────────

func _show_pause_screen() -> void:
	if _pause_screen: _pause_screen.visible = true
	if _settings_screen: _settings_screen.visible = false
	if is_instance_valid(_resume_btn):
		_resume_btn.call_deferred("grab_focus")

func _show_settings_screen() -> void:
	if _pause_screen: _pause_screen.visible = false
	if _settings_screen: _settings_screen.visible = true
	if is_instance_valid(_music_btn):
		_music_btn.call_deferred("grab_focus")


# ─── Button factories ────────────────────────────────────────────────────

func _make_btn(text: String, color: Color = HUDStyle.BTN_BLUE, font_size: int = HUDStyle.HUD_FONT_MED) -> Button:
	var b := Button.new()
	b.text = text
	HUDStyle.style_button(b, color, font_size)
	b.custom_minimum_size = Vector2(520, 76) if _is_mobile_ui else Vector2(340, 56)
	return b

func _make_cycler_btn(text: String, color: Color) -> Button:
	var b := Button.new()
	b.text = text
	HUDStyle.style_button(b, color, HUDStyle.HUD_FONT_MED)
	b.custom_minimum_size = Vector2(520, 64) if _is_mobile_ui else Vector2(340, 48)
	return b


# ─── Label formatters ────────────────────────────────────────────────────

func _format_volume(label: String, level: int) -> String:
	var pips := ""
	for i in range(VOLUME_STEPS - 1):
		pips += "▶" if i < level else "▷"
	return label + ": " + pips

func _format_gyro(paused: bool) -> String:
	return "GYRO: " + ("OFF" if paused else "ON")


# ─── Cycler handlers ─────────────────────────────────────────────────────

func _on_music_pressed() -> void:
	_music_level = (_music_level + 1) % VOLUME_STEPS
	_music_btn.text = _format_volume("MUSIC", _music_level)
	music_volume_changed.emit(_music_level)

func _on_sfx_pressed() -> void:
	_sfx_level = (_sfx_level + 1) % VOLUME_STEPS
	_sfx_btn.text = _format_volume("SFX  ", _sfx_level)
	sfx_volume_changed.emit(_sfx_level)

func _on_gyro_pressed() -> void:
	_gyro_paused = not _gyro_paused
	_gyro_btn.text = _format_gyro(_gyro_paused)
	gyro_toggled.emit(_gyro_paused)

func _on_sens_pressed() -> void:
	_sens_idx = (_sens_idx + 1) % _SENS_LABELS.size()
	_sens_btn.text = "SENS: " + _SENS_LABELS[_sens_idx]
	sens_changed.emit(_sens_idx)

func _on_dead_pressed() -> void:
	_dead_idx = (_dead_idx + 1) % _DEAD_LABELS.size()
	_dead_btn.text = "DEAD: " + _DEAD_LABELS[_dead_idx]
	dead_changed.emit(_dead_idx)

func _on_save_pressed() -> void:
	save_requested.emit()
	if _save_btn:
		var original_text := "SAVE GAME"
		_save_btn.text = "SAVED ✓"
		var t := get_tree().create_timer(1.2, true, false, true)
		t.timeout.connect(func() -> void:
			if is_instance_valid(_save_btn): _save_btn.text = original_text)


# ─── NEW GAME confirm modal ──────────────────────────────────────────────

func _on_new_game_pressed() -> void:
	if _confirm_dim == null:
		_build_confirm_modal()
	_confirm_dim.show()
	_confirm_plate.show()

func _build_confirm_modal() -> void:
	_confirm_dim = ColorRect.new()
	_confirm_dim.color = Color(0, 0, 0, 0.55)
	_confirm_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirm_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_confirm_dim)

	_confirm_plate = PanelContainer.new()
	_confirm_plate.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	_confirm_plate.set_anchors_preset(Control.PRESET_CENTER)
	var cw: int = 280 if _is_mobile_ui else 220
	var ch: int = 200 if _is_mobile_ui else 170
	_confirm_plate.offset_left = -cw; _confirm_plate.offset_right = cw
	_confirm_plate.offset_top  = -ch; _confirm_plate.offset_bottom = ch
	add_child(_confirm_plate)

	var cvb := VBoxContainer.new()
	cvb.alignment = BoxContainer.ALIGNMENT_CENTER
	cvb.add_theme_constant_override("separation", 14)
	_confirm_plate.add_child(cvb)

	var hdr := Label.new()
	hdr.text = "START NEW GAME?"
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HUDStyle.style_label(hdr, HUDStyle.HUD_FONT_LRG, HUDStyle.CRT_GREEN_BG)
	cvb.add_child(hdr)

	var msg := Label.new()
	msg.text = "All current progress will be permanently lost.\nThis cannot be undone."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	HUDStyle.style_label(msg, HUDStyle.HUD_FONT_SMALL, Color(0.9, 0.85, 0.85))
	cvb.add_child(msg)

	var pad := Control.new(); pad.custom_minimum_size = Vector2(0, 6); cvb.add_child(pad)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	cvb.add_child(row)

	var cancel := _make_btn("CANCEL", HUDStyle.BTN_BLUE)
	cancel.custom_minimum_size = Vector2(220, 64) if _is_mobile_ui else Vector2(140, 48)
	cancel.pressed.connect(_hide_confirm)
	row.add_child(cancel)

	var go := _make_btn("START NEW", HUDStyle.BTN_RED)
	go.custom_minimum_size = Vector2(220, 64) if _is_mobile_ui else Vector2(140, 48)
	go.pressed.connect(func() -> void:
		_hide_confirm()
		new_game_confirmed.emit())
	row.add_child(go)

func _hide_confirm() -> void:
	if _confirm_dim: _confirm_dim.hide()
	if _confirm_plate: _confirm_plate.hide()


# ─── Input (Escape / B / START) ──────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not visible: return
	if not _is_close_event(event): return

	# Priority: confirm modal → settings sub-screen → close pause entirely.
	if _confirm_plate != null and _confirm_plate.visible:
		_hide_confirm()
		get_viewport().set_input_as_handled()
		return
	if _settings_screen != null and _settings_screen.visible:
		_show_pause_screen()
		get_viewport().set_input_as_handled()
		return
	resume_requested.emit()
	get_viewport().set_input_as_handled()

func _is_close_event(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		return true
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_START or event.button_index == JOY_BUTTON_B:
			return true
	return false

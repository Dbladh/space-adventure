extends VBoxContainer
class_name SettingsPanel

# SettingsPanel.gd
# Reusable settings UI shared by the in-game PauseMenuUI and the StartScreen
# main-menu. Builds the audio + control prefs + (desktop) rebind row, reads
# initial values from SettingsManager, and emits the same intent signals the
# old inline pause-menu settings emitted — so consumers only have to wire
# these once.

const HUDStyle = preload("res://src/ui/HUDStyle.gd")

signal music_volume_changed(level: int)      # 0..4
signal sfx_volume_changed(level: int)
signal gyro_toggled(paused: bool)
signal sens_changed(idx: int)
signal dead_changed(idx: int)
signal hud_visibility_toggled(hidden: bool)
signal rebind_requested()
signal back_requested()

const VOLUME_STEPS: int = 5
const _SENS_LABELS := ["LOW", "MED", "HIGH"]
const _DEAD_LABELS := ["NARROW", "MED", "WIDE"]

@export var show_back_button: bool = true
@export var show_hud_toggle: bool = true

var _is_mobile_ui: bool = MobilePerf.is_mobile()
var _music_btn: Button = null
var _sfx_btn:   Button = null
var _gyro_btn:  Button = null
var _sens_btn:  Button = null
var _dead_btn:  Button = null
var _hud_btn:   Button = null
var _back_btn:  Button = null

var _music_level: int = 4
var _sfx_level:   int = 4
var _gyro_paused: bool = false
var _sens_idx:    int = 1
var _dead_idx:    int = 1
var _hud_hidden:  bool = false


func _ready() -> void:
	# Pull persisted values so cyclers reflect saved settings on first open.
	if Engine.has_meta("SettingsManager"):
		var sm = Engine.get_meta("SettingsManager")
		_music_level = int(sm.music_level)
		_sfx_level   = int(sm.sfx_level)
		_gyro_paused = bool(sm.gyro_paused)
		_sens_idx    = int(sm.sens_idx)
		_dead_idx    = int(sm.dead_idx)

	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 10)

	# Top row: BACK + title.
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 12)
	top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(top_row)

	if show_back_button:
		_back_btn = Button.new()
		_back_btn.text = "← BACK"
		HUDStyle.style_button(_back_btn, HUDStyle.BTN_BLUE, HUDStyle.HUD_FONT_MED)
		_back_btn.custom_minimum_size = Vector2(140, 56) if _is_mobile_ui else Vector2(110, 40)
		_back_btn.pressed.connect(func() -> void: back_requested.emit())
		top_row.add_child(_back_btn)

	var title := Label.new()
	title.text = "SETTINGS"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	HUDStyle.style_label(title, HUDStyle.HUD_FONT_LRG, HUDStyle.CRT_GREEN_BG)
	top_row.add_child(title)

	if show_back_button:
		# Balance the BACK button so the title stays centred.
		var balance := Control.new()
		balance.custom_minimum_size = Vector2(140 if _is_mobile_ui else 110, 0)
		balance.mouse_filter = Control.MOUSE_FILTER_IGNORE
		top_row.add_child(balance)

	# Audio cyclers.
	_music_btn = _make_cycler_btn(_format_volume("MUSIC", _music_level), HUDStyle.BTN_BLUE)
	_music_btn.pressed.connect(_on_music_pressed)
	add_child(_music_btn)
	_sfx_btn = _make_cycler_btn(_format_volume("SFX  ", _sfx_level), HUDStyle.BTN_BLUE)
	_sfx_btn.pressed.connect(_on_sfx_pressed)
	add_child(_sfx_btn)

	# Mobile-only controls (gyro / sens / dead-zone).
	if _is_mobile_ui:
		_gyro_btn = _make_cycler_btn(_format_gyro(_gyro_paused), HUDStyle.BTN_BLUE)
		_gyro_btn.pressed.connect(_on_gyro_pressed)
		add_child(_gyro_btn)
		_sens_btn = _make_cycler_btn("SENS: " + _SENS_LABELS[_sens_idx], HUDStyle.BTN_BLUE)
		_sens_btn.pressed.connect(_on_sens_pressed)
		add_child(_sens_btn)
		_dead_btn = _make_cycler_btn("DEAD: " + _DEAD_LABELS[_dead_idx], HUDStyle.BTN_BLUE)
		_dead_btn.pressed.connect(_on_dead_pressed)
		add_child(_dead_btn)
	else:
		var rebind_btn := _make_btn("REBIND CONTROLS", HUDStyle.BTN_BLUE)
		rebind_btn.pressed.connect(func() -> void: rebind_requested.emit())
		add_child(rebind_btn)

	# HUD-hidden toggle — only meaningful while a gameplay scene is loaded.
	if show_hud_toggle:
		_hud_btn = _make_cycler_btn(_format_hud(_hud_hidden), HUDStyle.BTN_BLUE)
		_hud_btn.pressed.connect(_on_hud_pressed)
		add_child(_hud_btn)


# ── Button factories ─────────────────────────────────────────────────────

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


# ── Label formatters ─────────────────────────────────────────────────────

func _format_volume(label: String, level: int) -> String:
	var pips := ""
	for i in range(VOLUME_STEPS - 1):
		pips += "▶" if i < level else "▷"
	return label + ": " + pips

func _format_gyro(paused: bool) -> String:
	return "GYRO: " + ("OFF" if paused else "ON")

func _format_hud(is_hidden: bool) -> String:
	return "HUD: " + ("HIDDEN" if is_hidden else "SHOWN")


# ── Cycler handlers ──────────────────────────────────────────────────────

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

func _on_hud_pressed() -> void:
	_hud_hidden = not _hud_hidden
	if is_instance_valid(_hud_btn):
		_hud_btn.text = _format_hud(_hud_hidden)
	hud_visibility_toggled.emit(_hud_hidden)


# ── Public focus helper for menu hosts ───────────────────────────────────

func focus_first_control() -> void:
	if is_instance_valid(_music_btn):
		_music_btn.call_deferred("grab_focus")

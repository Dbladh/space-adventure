extends Control

# MobileControlsUI.gd (Pilot-Touch Edition)
# Managed by THE ARCHITECT.
#
# LAYOUT (landscape):
#   TOP-LEFT:    [RECENTER]  [GYRO LOCK]  [SENS: LOW/MED/HIGH]
#   TOP-RIGHT:   [MOTION STATUS]  [MENU]
#   LEFT-SIDE:   Latching vertical throttle (no auto-reset). Tap handle to snap neutral.
#   BOTTOM-RIGHT CLUSTER (right thumb):
#                   [ROLL L]       [ROLL R]
#                         [ BOOST ]
#                   [     FIRE     ]     <- large primary
#                         [ BRAKE ]
#   TOP-CENTER:  SPD / ALT telemetry readout (set by Player.gd)

signal throttle_changed(value: float)
signal throttle_dragging_changed(active: bool)
signal fire_pressed(pressed: bool)
signal boost_pressed(pressed: bool)
signal brake_pressed(pressed: bool)
signal roll_triggered(direction: float) # +1 = left, -1 = right
signal sensitivity_changed(value: float) # 0.6 / 1.0 / 1.6
signal gyro_paused_changed(paused: bool)
signal recalibrate_pressed()
signal menu_pressed()

# ---- THROTTLE ----
var throttle: float = 0.5
var l_touch_idx: int = -1
var l_dragging: bool = false

# ---- BUTTON TOUCH STATE (one per interactive region) ----
var fire_touch: int = -1
var boost_touch: int = -1
var brake_touch: int = -1
var rolll_touch: int = -1
var rollr_touch: int = -1

# ---- OPTIONS ----
var gyro_paused: bool = false
var sens_idx: int = 1        # 0=LOW 1=MED 2=HIGH
const SENS_VALUES = [0.6, 1.0, 1.6]
const SENS_LABELS = ["LOW", "MED", "HIGH"]

# ---- TELEMETRY (set by Player.gd each frame) ----
var hud_speed: float = 0.0
var hud_alt: float = 0.0
var hud_warp: bool = false

# ---- CACHED RECTS (recomputed on redraw) ----
var _rect_recenter: Rect2
var _rect_gyrolock: Rect2
var _rect_sens: Rect2
var _rect_menu: Rect2
var _rect_fire: Rect2
var _rect_boost: Rect2
var _rect_brake: Rect2
var _rect_rolll: Rect2
var _rect_rollr: Rect2
var _rect_throttle_bar: Rect2

func _ready() -> void:
	self.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	queue_redraw()

func set_telemetry(speed: float, alt: float, warping: bool) -> void:
	# Player.gd calls this once per frame so the HUD readout can update.
	hud_speed = speed
	hud_alt = alt
	hud_warp = warping
	queue_redraw()

func _process(_delta: float) -> void:
	# Re-render so button highlights/telemetry stay fresh.
	queue_redraw()

# -----------------------------------------------------------------
#  DRAW
# -----------------------------------------------------------------

func _draw() -> void:
	var v_size = get_viewport_rect().size
	var font = ThemeDB.fallback_font
	var sx = v_size.x
	var sy = v_size.y

	# --- THROTTLE BAR (left, latching) ---
	var bar_x = 110.0
	var bar_h = sy * 0.62
	var bar_y_center = sy * 0.52
	var bar_top = bar_y_center - bar_h * 0.5
	var bar_bot = bar_y_center + bar_h * 0.5
	_rect_throttle_bar = Rect2(bar_x - 60.0, bar_top - 40.0, 160.0, bar_h + 80.0)

	# Neutral gutter (wider so thumb knows where stop-point is)
	var neutral_y = lerp(bar_bot, bar_top, 0.5)
	draw_rect(Rect2(bar_x - 30, neutral_y - 2, 60, 4), Color(1, 1, 1, 0.35))
	draw_line(Vector2(bar_x, bar_top), Vector2(bar_x, bar_bot), Color(1, 1, 1, 0.22), 8.0)

	# Tick marks at 25/50/75/100
	for i in range(1, 5):
		var ty = lerp(bar_bot, bar_top, i / 4.0)
		draw_line(Vector2(bar_x - 14, ty), Vector2(bar_x + 14, ty), Color(1, 1, 1, 0.15), 2.0)

	# Handle
	var handle_y = lerp(bar_bot, bar_top, throttle)
	var handle_size = 84.0
	var sb = StyleBoxFlat.new()
	var handle_col = Color.SPRING_GREEN
	if throttle < 0.48: handle_col = Color(1.0, 0.55, 0.2) # reverse = orange
	elif throttle > 0.95: handle_col = Color(0.4, 0.9, 1.0) # near max = cyan hint
	sb.bg_color = handle_col
	sb.set_corner_radius_all(18)
	sb.set_shadow_size(5)
	sb.set_shadow_color(Color(0, 0, 0, 0.65))
	draw_style_box(sb, Rect2(bar_x - handle_size * 0.5, handle_y - handle_size * 0.5, handle_size, handle_size))

	# Throttle label
	var tlbl := "NEUTRAL"
	if throttle > 0.52: tlbl = "FWD %d%%" % int((throttle - 0.5) * 200.0)
	elif throttle < 0.48: tlbl = "REV %d%%" % int((0.5 - throttle) * 200.0)
	draw_string(font, Vector2(bar_x + 58, handle_y + 8), tlbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
	draw_string(font, Vector2(bar_x - 46, bar_top - 16), "THROTTLE", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.6))

	# --- TOP-LEFT PANEL ---
	_rect_recenter = Rect2(36, 36, 180, 54)
	_draw_button(_rect_recenter, "RECENTER GYRO", Color(1, 1, 1, 0.12), false)

	_rect_gyrolock = Rect2(36, 100, 180, 54)
	var glbl = "GYRO: ON" if not gyro_paused else "GYRO: OFF"
	_draw_button(_rect_gyrolock, glbl, Color(0.2, 0.5, 1.0, 0.25) if not gyro_paused else Color(0.4, 0.4, 0.4, 0.25), gyro_paused)

	_rect_sens = Rect2(36, 164, 180, 54)
	_draw_button(_rect_sens, "SENS: %s" % SENS_LABELS[sens_idx], Color(0.15, 0.8, 0.5, 0.22), false)

	# --- TOP-RIGHT PANEL ---
	_rect_menu = Rect2(sx - 180 - 36, 36, 180, 54)
	_draw_button(_rect_menu, "MENU", Color(0, 0, 0, 0.5), false)

	var grav = Input.get_gravity()
	var motion_ok = grav.length() > 1.0
	var motion_c = Color.SPRING_GREEN if motion_ok else Color(1, 0.7, 0.2)
	draw_string(font, Vector2(sx - 180 - 36, 114), "MOTION: " + ("OK" if motion_ok else "WAIT"), HORIZONTAL_ALIGNMENT_LEFT, 180, 14, motion_c)

	# --- TOP-CENTER TELEMETRY ---
	var hud_box = Rect2(sx * 0.5 - 170, 36, 340, 54)
	draw_rect(hud_box, Color(0, 0, 0, 0.45))
	draw_rect(hud_box, Color(0, 0.9, 1.0, 0.45), false, 2.0)
	var speed_str = "SPD %4d m/s" % int(hud_speed)
	var alt_str = _format_alt(hud_alt)
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 22), speed_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.6, 1, 1))
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 44), "ALT " + alt_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.6, 1, 1))
	if hud_warp:
		draw_string(font, Vector2(hud_box.position.x + 200, hud_box.position.y + 34), "WARP", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 0.9, 0.2))

	# --- BOTTOM-RIGHT CONTROL CLUSTER ---
	# Anchor point
	var pad = 36.0
	var col_x = sx - pad
	var base_y = sy - pad

	# FIRE (primary, big, bottom-most-wide)
	var fire_w = 210.0
	var fire_h = 110.0
	_rect_fire = Rect2(col_x - fire_w, base_y - fire_h, fire_w, fire_h)
	var fire_col = Color(0.95, 0.12, 0.12, 0.9) if fire_touch == -1 else Color(1, 0.35, 0.35, 1.0)
	_draw_button(_rect_fire, "FIRE", fire_col, fire_touch != -1, 34)

	# BRAKE (below? no, above fire to free bottom — but user said big FIRE at bottom-right)
	var brake_h = 70.0
	_rect_brake = Rect2(col_x - fire_w, base_y - fire_h - 10 - brake_h, fire_w * 0.52, brake_h)
	var brake_col = Color(1.0, 0.55, 0.0, 0.75) if brake_touch == -1 else Color(1.0, 0.75, 0.25, 1.0)
	_draw_button(_rect_brake, "BRAKE", brake_col, brake_touch != -1, 22)

	# BOOST (same row as brake, to the right)
	var boost_w = fire_w * 0.48 - 10
	_rect_boost = Rect2(col_x - boost_w, base_y - fire_h - 10 - brake_h, boost_w, brake_h)
	var boost_col = Color(0.95, 0.85, 0.1, 0.8) if boost_touch == -1 else Color(1, 1, 0.4, 1.0)
	_draw_button(_rect_boost, "BOOST", boost_col, boost_touch != -1, 22)

	# ROLL LEFT / ROLL RIGHT (row above brake/boost)
	var roll_h = 64.0
	var roll_w = fire_w * 0.48 - 10
	_rect_rolll = Rect2(col_x - fire_w, base_y - fire_h - 10 - brake_h - 10 - roll_h, roll_w, roll_h)
	_rect_rollr = Rect2(col_x - roll_w, base_y - fire_h - 10 - brake_h - 10 - roll_h, roll_w, roll_h)
	_draw_button(_rect_rolll, "◀ ROLL", Color(0.3, 0.5, 1.0, 0.75) if rolll_touch == -1 else Color(0.6, 0.8, 1.0, 1.0), rolll_touch != -1, 20)
	_draw_button(_rect_rollr, "ROLL ▶", Color(0.3, 0.5, 1.0, 0.75) if rollr_touch == -1 else Color(0.6, 0.8, 1.0, 1.0), rollr_touch != -1, 20)


# -----------------------------------------------------------------
#  BUTTON DRAW HELPER
# -----------------------------------------------------------------

func _draw_button(r: Rect2, label: String, fill: Color, pressed: bool, font_size: int = 16) -> void:
	var sb = StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(14)
	if pressed:
		sb.set_border_width_all(3)
		sb.border_color = Color(1, 1, 1, 0.9)
	else:
		sb.set_border_width_all(2)
		sb.border_color = Color(1, 1, 1, 0.35)
	sb.set_shadow_size(3)
	sb.set_shadow_color(Color(0, 0, 0, 0.5))
	draw_style_box(sb, r)
	var font = ThemeDB.fallback_font
	var text_size = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	draw_string(font, r.position + Vector2(r.size.x * 0.5 - text_size.x * 0.5, r.size.y * 0.5 + font_size * 0.35),
		label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)

func _format_alt(alt: float) -> String:
	if alt > 1000.0:
		return "%.1f km" % (alt / 1000.0)
	if alt < -50.0:
		return "--- subsurf"
	return "%d m" % int(max(alt, 0.0))

# -----------------------------------------------------------------
#  INPUT
# -----------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		var pressed := false
		var pos := Vector2.ZERO
		var index := 0
		if event is InputEventScreenTouch:
			pressed = event.pressed
			pos = event.position
			index = event.index
		else:
			pressed = event.button_index == MOUSE_BUTTON_LEFT and event.pressed
			pos = event.position
			index = 0

		if pressed:
			_on_press(pos, index)
		else:
			_on_release(index)

	elif event is InputEventScreenDrag:
		if event.index == l_touch_idx:
			_update_throttle_from_pos(event.position.y)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if l_dragging:
			_update_throttle_from_pos(event.position.y)
			get_viewport().set_input_as_handled()


func _on_press(pos: Vector2, index: int) -> void:
	# Order matters: check top-panel buttons first so they don't get eaten by the
	# throttle area. Then the fire cluster. Throttle last.
	if _rect_recenter.has_point(pos):
		recalibrate_pressed.emit()
		get_viewport().set_input_as_handled(); return
	if _rect_gyrolock.has_point(pos):
		gyro_paused = not gyro_paused
		gyro_paused_changed.emit(gyro_paused)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_sens.has_point(pos):
		sens_idx = (sens_idx + 1) % SENS_VALUES.size()
		sensitivity_changed.emit(SENS_VALUES[sens_idx])
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_menu.has_point(pos):
		menu_pressed.emit()
		get_viewport().set_input_as_handled(); return

	if _rect_fire.has_point(pos) and fire_touch == -1:
		fire_touch = index
		fire_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_boost.has_point(pos) and boost_touch == -1:
		boost_touch = index
		boost_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_brake.has_point(pos) and brake_touch == -1:
		brake_touch = index
		brake_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_rolll.has_point(pos) and rolll_touch == -1:
		rolll_touch = index
		roll_triggered.emit(1.0)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_rollr.has_point(pos) and rollr_touch == -1:
		rollr_touch = index
		roll_triggered.emit(-1.0)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	# Throttle drag region (left slab)
	if _rect_throttle_bar.has_point(pos) or pos.x < get_viewport_rect().size.x * 0.28:
		l_touch_idx = index
		_set_throttle_dragging(true)
		_update_throttle_from_pos(pos.y)
		get_viewport().set_input_as_handled()


func _on_release(index: int) -> void:
	if index == l_touch_idx:
		l_touch_idx = -1
		_set_throttle_dragging(false)
		# LATCHING: don't auto-reset. Throttle stays where the pilot left it.
		get_viewport().set_input_as_handled()
		return
	if index == fire_touch:
		fire_touch = -1
		fire_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if index == boost_touch:
		boost_touch = -1
		boost_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if index == brake_touch:
		brake_touch = -1
		brake_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if index == rolll_touch:
		rolll_touch = -1
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if index == rollr_touch:
		rollr_touch = -1
		queue_redraw(); get_viewport().set_input_as_handled(); return


func _set_throttle_dragging(active: bool) -> void:
	if l_dragging == active: return
	l_dragging = active
	throttle_dragging_changed.emit(active)

func _update_throttle_from_pos(y: float) -> void:
	var v_size = get_viewport_rect().size
	var bar_h = v_size.y * 0.62
	var bar_y_center = v_size.y * 0.52
	var bar_top = bar_y_center - bar_h * 0.5
	var bar_bot = bar_y_center + bar_h * 0.5
	var raw_p = clamp((bar_bot - y) / bar_h, 0.0, 1.0)
	# NEUTRAL MAGNET: snap near-neutral for finger precision
	if abs(raw_p - 0.5) < 0.035:
		raw_p = 0.5
	throttle = raw_p
	throttle_changed.emit(throttle)
	queue_redraw()

# Called by Player.gd when BRAKE is held, so the UI handle visually tracks the reset.
func force_throttle(val: float) -> void:
	throttle = clamp(val, 0.0, 1.0)
	throttle_changed.emit(throttle)
	queue_redraw()

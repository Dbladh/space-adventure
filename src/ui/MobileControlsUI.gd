extends Control

# MobileControlsUI.gd (Retro-Space Edition)
# Managed by THE ARCHITECT.
# Visual language: Warm cream + deep navy + orange/teal accents — matches game's
# purple nebulae, orange-red ship thrusters, and teal planet surfaces.
#
# LAYOUT (landscape):
#   TOP-LEFT:    [RECENTER]  [GYRO LOCK]  [SENS: LOW/MED/HIGH]
#   TOP-RIGHT:   [MOTION STATUS]  [MENU]
#   LEFT-SIDE:   Latching vertical throttle (inset from notches)
#   BOTTOM-LEFT: [◀ ROLL] [ROLL ▶]  hold = continuous roll, double-tap = barrel roll
#   BOTTOM-RIGHT CLUSTER (right thumb):
#                         [ BRAKE ]
#                   [     BOOST    ]
#                   [     FIRE     ]     <- large primary
#   TOP-CENTER:  SPD / ALT telemetry readout (set by Player.gd)

signal throttle_changed(value: float)
signal throttle_dragging_changed(active: bool)
signal fire_pressed(pressed: bool)
signal boost_pressed(pressed: bool)
signal brake_pressed(pressed: bool)
signal roll_triggered(direction: float)
signal roll_held(direction: float, pressed: bool)
signal sensitivity_changed(value: float)
signal gyro_paused_changed(paused: bool)
signal recalibrate_pressed()
signal menu_pressed()

const _DOUBLE_TAP_WINDOW := 0.22
var _rolll_last_tap: float = -1.0
var _rollr_last_tap: float = -1.0

# ---- COLOR PALETTE (retro-space: navy + cream + orange + teal) ----
const C_BG         := Color(0.08, 0.09, 0.16, 0.96)  # deep space navy (panel bg)
const C_PANEL_BDR  := Color(0.35, 0.68, 0.78, 0.55)  # teal outline for panels
const C_CREAM      := Color(0.88, 0.82, 0.60, 1.00)  # warm cream (labels / text)
const C_ORANGE     := Color(0.96, 0.62, 0.12, 1.00)  # thruster orange (BOOST/active)
const C_ORANGE_DIM := Color(0.96, 0.62, 0.12, 0.25)  # dim orange for glow rims
const C_TEAL       := Color(0.35, 0.68, 0.78, 1.00)  # planet teal (BRAKE/info)
const C_TEAL_DIM   := Color(0.35, 0.68, 0.78, 0.25)
const C_RED        := Color(0.88, 0.18, 0.18, 1.00)  # weapon red (FIRE)
const C_RED_DIM    := Color(0.88, 0.18, 0.18, 0.25)
const C_NAVY_TEXT  := Color(0.10, 0.10, 0.18, 1.00)  # text on cream bg
const C_GREEN      := Color(0.25, 0.85, 0.45, 1.00)  # forward throttle
const C_GYRO_ON    := Color(0.35, 0.68, 0.78, 1.00)
const C_GYRO_OFF   := Color(0.45, 0.45, 0.52, 1.00)

# ---- SAFE AREA (phone notch / Dynamic Island insets) ----
var _safe_left: float = 0.0
var _safe_right: float = 0.0
var _safe_top: float = 0.0
var _safe_bottom: float = 0.0

# ---- THROTTLE GEOMETRY ----
var _throttle_bar_x: float = 144.0
const _THROTTLE_BAR_H_RATIO    := 0.40
const _THROTTLE_BAR_Y_CENTER_RATIO := 0.55
const _THROTTLE_HIT_WIDTH      := 120.0
const _THROTTLE_HIT_HEIGHT_PAD := 30.0

# ---- THROTTLE STATE ----
var throttle: float = 0.5
var l_touch_idx: int = -1
var l_dragging: bool = false

# ---- BUTTON TOUCH STATE ----
var fire_touch: int = -1
var boost_touch: int = -1
var brake_touch: int = -1
var rolll_touch: int = -1
var rollr_touch: int = -1

# ---- OPTIONS ----
var gyro_paused: bool = false
var sens_idx: int = 1
const SENS_VALUES = [0.6, 1.0, 1.6]
const SENS_LABELS = ["LOW", "MED", "HIGH"]

# ---- TELEMETRY ----
var hud_speed: float = 0.0
var hud_alt: float = 0.0
var hud_warp: bool = false
var _last_hud_speed: float = -1.0
var _last_hud_alt: float = -1.0
var _last_hud_warp: bool = false

# ---- CACHED RECTS ----
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
var _rect_throttle_hit: Rect2
var _last_viewport_size: Vector2 = Vector2.ZERO

# =====================================================================
#  INIT
# =====================================================================

func _ready() -> void:
	self.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_calculate_safe_area()
	set_process(true)
	queue_redraw()

func _calculate_safe_area() -> void:
	var safe_rect  = DisplayServer.screen_get_usable_rect()
	var screen_sz  = Vector2(DisplayServer.screen_get_size())
	_safe_left   = max(0.0, float(safe_rect.position.x))
	_safe_top    = max(0.0, float(safe_rect.position.y))
	_safe_right  = max(0.0, screen_sz.x - float(safe_rect.position.x + safe_rect.size.x))
	_safe_bottom = max(0.0, screen_sz.y - float(safe_rect.position.y + safe_rect.size.y))
	_throttle_bar_x = 144.0 + _safe_left

func _update_layout() -> void:
	var v_size = get_viewport_rect().size
	if v_size == _last_viewport_size: return
	_last_viewport_size = v_size
	var sx = v_size.x
	var sy = v_size.y

	var bar_x       = _throttle_bar_x
	var bar_h       = sy * _THROTTLE_BAR_H_RATIO
	var bar_y_cen   = sy * _THROTTLE_BAR_Y_CENTER_RATIO
	var bar_top     = bar_y_cen - bar_h * 0.5
	_rect_throttle_bar = Rect2(bar_x - 26, bar_top - 12, 52, bar_h + 24)
	_rect_throttle_hit = Rect2(bar_x - _THROTTLE_HIT_WIDTH * 0.5,
		bar_top - _THROTTLE_HIT_HEIGHT_PAD,
		_THROTTLE_HIT_WIDTH,
		bar_h + _THROTTLE_HIT_HEIGHT_PAD * 2.0)

	var tp = 36.0 + _safe_top
	_rect_recenter = Rect2(36 + _safe_left, tp,       180, 50)
	_rect_gyrolock = Rect2(36 + _safe_left, tp + 60,  180, 50)
	_rect_sens     = Rect2(36 + _safe_left, tp + 120, 180, 50)
	_rect_menu     = Rect2(sx - 180 - 36 - _safe_right, tp, 180, 50)

	var pad    = 36.0 + _safe_bottom
	var col_x  = sx - pad - _safe_right
	var base_y = sy - pad
	var btn_w  := 220.0
	var btn_h  := 104.0
	var gap    := 10.0
	var brk_h  := 60.0

	_rect_fire  = Rect2(col_x - btn_w, base_y - btn_h, btn_w, btn_h)
	_rect_boost = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h, btn_w, btn_h)
	_rect_brake = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h - gap - brk_h, btn_w, brk_h)

	var roll_h   := 80.0
	var roll_w   := 138.0
	var roll_pad  = 36.0 + _safe_left
	_rect_rolll  = Rect2(roll_pad,               base_y - roll_h - _safe_bottom, roll_w, roll_h)
	_rect_rollr  = Rect2(roll_pad + roll_w + 12, base_y - roll_h - _safe_bottom, roll_w, roll_h)

func set_telemetry(speed: float, alt: float, warping: bool) -> void:
	hud_speed = speed
	hud_alt   = alt
	hud_warp  = warping
	if abs(speed - _last_hud_speed) > 5.0 or abs(alt - _last_hud_alt) > 50.0 or warping != _last_hud_warp:
		_last_hud_speed = speed
		_last_hud_alt   = alt
		_last_hud_warp  = warping
		queue_redraw()

func _process(_delta: float) -> void:
	_update_layout()

# =====================================================================
#  DRAW
# =====================================================================

func _draw() -> void:
	var v_size = get_viewport_rect().size
	var font   = ThemeDB.fallback_font
	var sx     = v_size.x
	var sy     = v_size.y

	# ----- THROTTLE BAR -----
	var bar_x     = _throttle_bar_x
	var bar_h     = sy * _THROTTLE_BAR_H_RATIO
	var bar_y_cen = sy * _THROTTLE_BAR_Y_CENTER_RATIO
	var bar_top   = bar_y_cen - bar_h * 0.5
	var bar_bot   = bar_y_cen + bar_h * 0.5

	# Track capsule background
	var track_r = Rect2(bar_x - 14, bar_top, 28, bar_h)
	_draw_rounded_rect(track_r, C_BG, 10.0)
	_draw_rounded_rect(track_r, C_PANEL_BDR, 10.0, false, 1.5)

	# Fill strip (teal = forward, orange = reverse)
	var neutral_y = lerp(bar_bot, bar_top, 0.5)
	var handle_y  = lerp(bar_bot, bar_top, throttle)
	if throttle > 0.52:
		var fill_r = Rect2(bar_x - 10, handle_y, 20, neutral_y - handle_y)
		_draw_rounded_rect(fill_r, C_TEAL.darkened(0.2), 4.0)
	elif throttle < 0.48:
		var fill_r = Rect2(bar_x - 10, neutral_y, 20, handle_y - neutral_y)
		_draw_rounded_rect(fill_r, C_ORANGE.darkened(0.2), 4.0)

	# Neutral notch
	draw_rect(Rect2(bar_x - 14, neutral_y - 3, 28, 6), C_ORANGE)
	draw_rect(Rect2(bar_x - 16, neutral_y - 5, 32, 10), C_ORANGE_DIM, false, 1.5)

	# Handle
	var h_col = C_GREEN
	if throttle < 0.48:   h_col = C_ORANGE
	elif throttle > 0.95: h_col = C_TEAL
	var hs = 72.0
	var handle_rect = Rect2(bar_x - hs * 0.5, handle_y - hs * 0.5, hs, hs)
	_draw_space_button(handle_rect, "", h_col, Color.TRANSPARENT, false, 0)

	# Label beside handle
	var tlbl = "NEUTRAL"
	if   throttle > 0.52: tlbl = "FWD %d%%" % int((throttle - 0.5) * 200.0)
	elif throttle < 0.48: tlbl = "REV %d%%" % int((0.5 - throttle) * 200.0)
	draw_string(font, Vector2(bar_x + 48, handle_y + 8),  tlbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, C_CREAM)
	draw_string(font, Vector2(bar_x - 40, bar_top - 18), "THROTTLE", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, C_TEAL)

	# ----- TOP-LEFT BUTTONS -----
	_draw_space_button(_rect_recenter, "RECENTER GYRO", C_BG, C_TEAL, false, 14)
	var glbl = "GYRO: ON" if not gyro_paused else "GYRO: OFF"
	_draw_space_button(_rect_gyrolock, glbl, C_BG, C_GYRO_ON if not gyro_paused else C_GYRO_OFF, gyro_paused, 15)
	_draw_space_button(_rect_sens, "SENS: %s" % SENS_LABELS[sens_idx], C_BG, C_TEAL, false, 15)

	# ----- TOP-RIGHT BUTTONS -----
	_draw_space_button(_rect_menu, "MENU", C_BG, C_PANEL_BDR, false, 16)
	var grav      = Input.get_gravity()
	var motion_ok = grav.length() > 1.0
	draw_string(font, Vector2(sx - 180 - 36 - _safe_right, 112 + _safe_top),
		"MOTION: " + ("OK" if motion_ok else "WAIT"), HORIZONTAL_ALIGNMENT_LEFT, 180, 13,
		Color.SPRING_GREEN if motion_ok else Color(1.0, 0.7, 0.2))

	# ----- TELEMETRY HUD -----
	var hud_box = Rect2(sx * 0.5 - 174, 36.0 + _safe_top, 348, 58)
	_draw_rounded_rect(hud_box, C_BG, 8.0)
	_draw_rounded_rect(hud_box, C_PANEL_BDR, 8.0, false, 1.5)
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 22),
		"SPD %4d m/s" % int(hud_speed), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, C_CREAM)
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 44),
		"ALT " + _format_alt(hud_alt), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, C_TEAL)
	if hud_warp:
		draw_string(font, Vector2(hud_box.position.x + 210, hud_box.position.y + 36),
			"WARP", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, C_ORANGE)

	# ----- RIGHT CONTROL CLUSTER -----
	# FIRE — cream fill, red border, dark text (large primary action)
	_draw_space_button(_rect_fire,  "FIRE",  C_RED  if fire_touch  != -1 else Color(0.20, 0.04, 0.04, 0.95), C_RED,  fire_touch  != -1, 34)
	# BOOST — orange fill, orange border (matches PLAY button in reference)
	_draw_space_button(_rect_boost, "BOOST", C_ORANGE.darkened(0.15) if boost_touch != -1 else Color(0.22, 0.14, 0.04, 0.95), C_ORANGE, boost_touch != -1, 28)
	# BRAKE — teal, smaller
	_draw_space_button(_rect_brake, "BRAKE", C_TEAL.darkened(0.15) if brake_touch != -1 else Color(0.05, 0.14, 0.18, 0.95), C_TEAL, brake_touch != -1, 20)

	# ----- LEFT ROLL BUTTONS -----
	_draw_space_button(_rect_rolll, "◀ ROLL", C_BG, C_TEAL, rolll_touch != -1, 22)
	_draw_space_button(_rect_rollr, "ROLL ▶", C_BG, C_TEAL, rollr_touch != -1, 22)

# =====================================================================
#  DRAW HELPERS
# =====================================================================

func _draw_rounded_rect(r: Rect2, color: Color, radius: float, filled: bool = true, width: float = 1.5) -> void:
	# Clamp radius so it doesn't exceed half the shorter dimension
	radius = min(radius, min(r.size.x * 0.5, r.size.y * 0.5))
	if filled:
		# Three overlapping rects cover the rounded rectangle area
		draw_rect(Rect2(r.position.x + radius, r.position.y,        r.size.x - radius * 2, r.size.y), color)
		draw_rect(Rect2(r.position.x,          r.position.y + radius, r.size.x,            r.size.y - radius * 2), color)
		# Filled quarter-circles at corners
		draw_circle(Vector2(r.position.x + radius,            r.position.y + radius),            radius, color)
		draw_circle(Vector2(r.position.x + r.size.x - radius, r.position.y + radius),            radius, color)
		draw_circle(Vector2(r.position.x + radius,            r.position.y + r.size.y - radius), radius, color)
		draw_circle(Vector2(r.position.x + r.size.x - radius, r.position.y + r.size.y - radius), radius, color)
	else:
		# Outline: four arc segments + four connecting lines
		const ARC_POINTS := 8
		# Corners (arcs)
		draw_arc(Vector2(r.position.x + radius,            r.position.y + radius),            radius, PI,        1.5 * PI, ARC_POINTS, color, width)
		draw_arc(Vector2(r.position.x + r.size.x - radius, r.position.y + radius),            radius, 1.5 * PI, TAU,      ARC_POINTS, color, width)
		draw_arc(Vector2(r.position.x + r.size.x - radius, r.position.y + r.size.y - radius), radius, 0.0,      0.5 * PI, ARC_POINTS, color, width)
		draw_arc(Vector2(r.position.x + radius,            r.position.y + r.size.y - radius), radius, 0.5 * PI, PI,       ARC_POINTS, color, width)
		# Edges
		draw_line(Vector2(r.position.x + radius,            r.position.y),           Vector2(r.position.x + r.size.x - radius, r.position.y),           color, width)
		draw_line(Vector2(r.position.x + r.size.x,          r.position.y + radius),  Vector2(r.position.x + r.size.x,          r.position.y + r.size.y - radius), color, width)
		draw_line(Vector2(r.position.x + r.size.x - radius, r.position.y + r.size.y), Vector2(r.position.x + radius,           r.position.y + r.size.y),           color, width)
		draw_line(Vector2(r.position.x,                      r.position.y + r.size.y - radius), Vector2(r.position.x, r.position.y + radius), color, width)

func _draw_space_button(r: Rect2, label: String, fill: Color, accent: Color, pressed: bool, font_size: int = 16) -> void:
	# --- Background ---
	var bg = fill.darkened(0.15) if pressed else fill
	_draw_rounded_rect(r, bg, 12.0)

	# --- Horizontal stripe texture (retro scan-line inside button) ---
	if fill.a > 0.5:
		var stripe_a = 0.07 if not pressed else 0.12
		var sy_s := r.position.y + 5.0
		while sy_s < r.position.y + r.size.y - 4.0:
			var sc = Color(accent.r, accent.g, accent.b, stripe_a)
			draw_line(Vector2(r.position.x + 12, sy_s), Vector2(r.position.x + r.size.x - 12, sy_s), sc, 1.0)
			sy_s += 5.0

	# --- Outer border (accent color, rounded) ---
	var border_col = accent if not pressed else accent.lightened(0.2)
	_draw_rounded_rect(r, border_col, 12.0, false, 2.0)

	# --- Pressed state: inner shadow strip at top ---
	if pressed:
		var inner = Rect2(r.position.x + 4, r.position.y + 4, r.size.x - 8, 6)
		_draw_rounded_rect(inner, Color(0, 0, 0, 0.35), 3.0)

	# --- Label ---
	if label.is_empty(): return
	var font = ThemeDB.fallback_font
	var text_size = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	var lx = r.position.x + (r.size.x - text_size.x) * 0.5
	var ly = r.position.y + r.size.y * 0.5 + font_size * 0.36
	# Shadow
	draw_string(font, Vector2(lx + 1, ly + 1), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(0, 0, 0, 0.55))
	# Text — cream on dark bg, dark on bright bg
	var text_col = C_CREAM if fill.get_luminance() < 0.45 else C_NAVY_TEXT
	if pressed: text_col = text_col.lightened(0.1)
	draw_string(font, Vector2(lx, ly), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, text_col)

func _format_alt(alt: float) -> String:
	if alt > 1000.0: return "%.1f km" % (alt / 1000.0)
	if alt < -50.0:  return "--- subsurf"
	return "%d m" % int(max(alt, 0.0))

# =====================================================================
#  INPUT
# =====================================================================

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		var pressed := false
		var pos     := Vector2.ZERO
		var index   := 0
		if event is InputEventScreenTouch:
			pressed = event.pressed; pos = event.position; index = event.index
		else:
			pressed = event.button_index == MOUSE_BUTTON_LEFT and event.pressed
			pos = event.position; index = 0
		if pressed: _on_press(pos, index)
		else:       _on_release(index)
	elif event is InputEventScreenDrag:
		if event.index == l_touch_idx:
			_update_throttle_from_pos(event.position.y)
			get_viewport().set_input_as_handled()
		elif event.index == fire_touch or event.index == boost_touch \
				or event.index == brake_touch or event.index == rolll_touch \
				or event.index == rollr_touch:
			get_viewport().set_input_as_handled()
		else:
			_on_press(event.position, event.index)
	elif event is InputEventMouseMotion:
		if l_dragging:
			_update_throttle_from_pos(event.position.y)
			get_viewport().set_input_as_handled()

func _on_press(pos: Vector2, index: int) -> void:
	# Top panel — highest priority
	if _rect_recenter.has_point(pos):
		recalibrate_pressed.emit(); get_viewport().set_input_as_handled(); return
	if _rect_gyrolock.has_point(pos):
		gyro_paused = not gyro_paused
		gyro_paused_changed.emit(gyro_paused)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_sens.has_point(pos):
		sens_idx = (sens_idx + 1) % SENS_VALUES.size()
		sensitivity_changed.emit(SENS_VALUES[sens_idx])
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_menu.has_point(pos):
		menu_pressed.emit(); get_viewport().set_input_as_handled(); return

	# Right cluster
	if _rect_fire.has_point(pos) and fire_touch == -1:
		fire_touch = index; fire_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_boost.has_point(pos) and boost_touch == -1 and fire_touch != index:
		boost_touch = index; boost_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_brake.has_point(pos) and brake_touch == -1:
		brake_touch = index; brake_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	# Roll buttons (fully claimed before throttle check)
	if _rect_rolll.has_point(pos) and rolll_touch == -1:
		rolll_touch = index
		var now_l := Time.get_ticks_msec() / 1000.0
		if now_l - _rolll_last_tap < _DOUBLE_TAP_WINDOW:
			roll_triggered.emit(1.0); _rolll_last_tap = -1.0
		else:
			_rolll_last_tap = now_l
		roll_held.emit(1.0, true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_rollr.has_point(pos) and rollr_touch == -1:
		rollr_touch = index
		var now_r := Time.get_ticks_msec() / 1000.0
		if now_r - _rollr_last_tap < _DOUBLE_TAP_WINDOW:
			roll_triggered.emit(-1.0); _rollr_last_tap = -1.0
		else:
			_rollr_last_tap = now_r
		roll_held.emit(-1.0, true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	# Throttle — separate smaller hit area, last priority
	if _rect_throttle_hit.has_point(pos):
		l_touch_idx = index
		_set_throttle_dragging(true)
		_update_throttle_from_pos(pos.y)
		get_viewport().set_input_as_handled()

func _on_release(index: int) -> void:
	if index == l_touch_idx:
		l_touch_idx = -1; _set_throttle_dragging(false)
		get_viewport().set_input_as_handled(); return
	if index == fire_touch:
		fire_touch = -1; fire_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == boost_touch:
		boost_touch = -1; boost_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == brake_touch:
		brake_touch = -1; brake_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == rolll_touch:
		rolll_touch = -1; roll_held.emit(1.0, false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == rollr_touch:
		rollr_touch = -1; roll_held.emit(-1.0, false)
		queue_redraw(); get_viewport().set_input_as_handled()

func _set_throttle_dragging(active: bool) -> void:
	if l_dragging == active: return
	l_dragging = active
	throttle_dragging_changed.emit(active)

func _update_throttle_from_pos(y: float) -> void:
	var v_size    = get_viewport_rect().size
	var bar_h     = v_size.y * _THROTTLE_BAR_H_RATIO
	var bar_y_cen = v_size.y * _THROTTLE_BAR_Y_CENTER_RATIO
	var bar_top   = bar_y_cen - bar_h * 0.5
	var bar_bot   = bar_y_cen + bar_h * 0.5
	var raw_p     = clamp((bar_bot - y) / bar_h, 0.0, 1.0)
	if abs(raw_p - 0.5) < 0.035: raw_p = 0.5
	throttle = raw_p
	throttle_changed.emit(throttle)
	queue_redraw()

func force_throttle(val: float) -> void:
	throttle = clamp(val, 0.0, 1.0)
	throttle_changed.emit(throttle)
	queue_redraw()

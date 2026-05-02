extends Control

# MobileControlsUI.gd (Premium Edition)
# Managed by THE ARCHITECT.
# Complete overhaul: Safe area support, performance optimization, modern visual design
#
# LAYOUT (landscape):
#   TOP-LEFT:    [RECENTER]  [GYRO LOCK]  [SENS: LOW/MED/HIGH]
#   TOP-RIGHT:   [MOTION STATUS]  [MENU]
#   LEFT-SIDE:   Latching vertical throttle (inset from notches). Tap handle to snap neutral.
#   BOTTOM-LEFT: [◀ ROLL] [ROLL ▶]  hold = continuous roll, double-tap = barrel roll
#   BOTTOM-RIGHT CLUSTER (right thumb):
#                         [ BOOST ]
#                   [     FIRE     ]     <- large primary
#                         [ BRAKE ]
#   TOP-CENTER:  SPD / ALT telemetry readout (set by Player.gd)

signal throttle_changed(value: float)
signal throttle_dragging_changed(active: bool)
signal fire_pressed(pressed: bool)
signal boost_pressed(pressed: bool)
signal brake_pressed(pressed: bool)
signal roll_triggered(direction: float)            # double-tap → barrel roll (+1 = left, -1 = right)
signal roll_held(direction: float, pressed: bool)  # single hold → continuous roll
signal sensitivity_changed(value: float) # 0.6 / 1.0 / 1.6
signal gyro_paused_changed(paused: bool)
signal recalibrate_pressed()
signal menu_pressed()

# Double-tap detection for barrel-roll shortcut on the rotate buttons.
const _DOUBLE_TAP_WINDOW := 0.22
var _rolll_last_tap: float = -1.0
var _rollr_last_tap: float = -1.0

# PERFORMANCE: Cache previous telemetry values to avoid redundant redraws
var _last_hud_speed: float = -1.0
var _last_hud_alt: float = -1.0
var _last_hud_warp: bool = false
const _SPEED_CHANGE_THRESHOLD := 5.0  # Only redraw if speed changes >5 m/s

# SAFE AREA: Phone notch / Dynamic Island insets (calculated in _ready)
var _safe_left: float = 0.0
var _safe_right: float = 0.0
var _safe_top: float = 0.0
var _safe_bottom: float = 0.0

# Throttle geometry (moved right to avoid left notches, adjusted based on safe area)
var _throttle_bar_x: float = 140.0  # Base position, adjusted by safe area
const _THROTTLE_BAR_H_RATIO := 0.40
const _THROTTLE_BAR_Y_CENTER_RATIO := 0.55
const _THROTTLE_HIT_WIDTH := 120.0  # Width of throttle hit area (reduced from 160)
const _THROTTLE_HIT_HEIGHT_PAD := 30.0  # Vertical padding (reduced from 40)

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

# ---- CACHED RECTS (computed once, updated on layout changes) ----
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
var _rect_throttle_hit: Rect2  # Separate smaller hit area to prevent roll overlap

# Layout state (for detecting viewport changes)
var _last_viewport_size: Vector2 = Vector2.ZERO
var _layout_dirty: bool = true

func _ready() -> void:
	self.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_calculate_safe_area()
	set_process(true)
	queue_redraw()

func _calculate_safe_area() -> void:
	# Get usable screen rect accounting for notches and safe areas
	var safe_rect = DisplayServer.screen_get_usable_rect()
	var full_rect = DisplayServer.screen_get_rect()

	# Calculate insets from edges
	_safe_left = safe_rect.position.x - full_rect.position.x
	_safe_top = safe_rect.position.y - full_rect.position.y
	_safe_right = (full_rect.position.x + full_rect.size.x) - (safe_rect.position.x + safe_rect.size.x)
	_safe_bottom = (full_rect.position.y + full_rect.size.y) - (safe_rect.position.y + safe_rect.size.y)

	# Adjust throttle position based on safe left inset
	_throttle_bar_x = 140.0 + _safe_left

func _update_layout() -> void:
	# Recalculate button positions when viewport changes
	var v_size = get_viewport_rect().size
	if v_size == _last_viewport_size:
		return
	_last_viewport_size = v_size
	_layout_dirty = true

	var sx = v_size.x
	var sy = v_size.y

	# --- THROTTLE BAR (left, latching) ---
	var bar_x = _throttle_bar_x
	var bar_h = sy * _THROTTLE_BAR_H_RATIO
	var bar_y_center = sy * _THROTTLE_BAR_Y_CENTER_RATIO
	var bar_top = bar_y_center - bar_h * 0.5
	var bar_bot = bar_y_center + bar_h * 0.5
	_rect_throttle_bar = Rect2(bar_x - 26, bar_top - 12, 52, bar_h + 24)

	# Separate, smaller hit area to prevent overlap with roll buttons
	_rect_throttle_hit = Rect2(bar_x - _THROTTLE_HIT_WIDTH * 0.5, bar_top - _THROTTLE_HIT_HEIGHT_PAD, _THROTTLE_HIT_WIDTH, bar_h + _THROTTLE_HIT_HEIGHT_PAD * 2)

	# --- TOP-LEFT PANEL ---
	var top_pad = 36.0 + _safe_top
	_rect_recenter = Rect2(36 + _safe_left, top_pad, 180, 54)
	_rect_gyrolock = Rect2(36 + _safe_left, top_pad + 64, 180, 54)
	_rect_sens = Rect2(36 + _safe_left, top_pad + 128, 180, 54)

	# --- TOP-RIGHT PANEL ---
	_rect_menu = Rect2(sx - 180 - 36 - _safe_right, top_pad, 180, 54)

	# --- BOTTOM-RIGHT CONTROL CLUSTER ---
	var pad = 36.0 + _safe_bottom
	var col_x = sx - pad - _safe_right
	var base_y = sy - pad
	var btn_w := 216.0
	var btn_h := 100.0
	var gap := 8.0

	_rect_fire = Rect2(col_x - btn_w, base_y - btn_h, btn_w, btn_h)
	_rect_boost = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h, btn_w, btn_h)
	var brake_h := 58.0
	_rect_brake = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h - gap - brake_h, btn_w, brake_h)

	# --- BOTTOM-LEFT ROTATE PAIR ---
	var roll_h := 80.0
	var roll_w := 136.0
	var roll_pad = 36.0 + _safe_left
	_rect_rolll = Rect2(roll_pad, base_y - roll_h - _safe_bottom, roll_w, roll_h)
	_rect_rollr = Rect2(roll_pad + roll_w + 10, base_y - roll_h - _safe_bottom, roll_w, roll_h)

func set_telemetry(speed: float, alt: float, warping: bool) -> void:
	# Player.gd calls this once per frame. Only redraw if values changed significantly.
	var speed_delta = abs(speed - _last_hud_speed)
	var alt_delta = abs(alt - _last_hud_alt)
	var warp_changed = warping != _last_hud_warp

	# Update internal state
	hud_speed = speed
	hud_alt = alt
	hud_warp = warping

	# Only redraw if telemetry changed meaningfully
	if speed_delta > _SPEED_CHANGE_THRESHOLD or alt_delta > 50.0 or warp_changed:
		_last_hud_speed = speed
		_last_hud_alt = alt
		_last_hud_warp = warping
		queue_redraw()

func _process(_delta: float) -> void:
	# Update layout if viewport changed, but DON'T unconditionally redraw
	# (set_telemetry handles redraw on actual changes)
	_update_layout()

# -----------------------------------------------------------------
#  DRAW
# -----------------------------------------------------------------

func _draw() -> void:
	var v_size = get_viewport_rect().size
	var font = ThemeDB.fallback_font
	var sx = v_size.x
	var sy = v_size.y

	# --- THROTTLE BAR (left, latching, modern design) ---
	var bar_x = _throttle_bar_x
	var bar_h = sy * _THROTTLE_BAR_H_RATIO
	var bar_y_center = sy * _THROTTLE_BAR_Y_CENTER_RATIO
	var bar_top = bar_y_center - bar_h * 0.5
	var bar_bot = bar_y_center + bar_h * 0.5

	# Throttle background — modern gradient panel
	var bar_bg = Rect2(bar_x - 26, bar_top - 12, 52, bar_h + 24)
	_draw_modern_panel(bar_bg, Color(0.08, 0.10, 0.18, 0.95), Color(0.0, 0.6, 0.9, 0.4))

	# Gradient track (vertical)
	var track_top = bar_top + 10
	var track_bot = bar_bot - 10
	var track_h = track_bot - track_top
	for i in range(int(track_h)):
		var ratio = float(i) / track_h
		var col = Color(0.0, 0.4, 0.8, 0.2).lerp(Color(0.0, 0.7, 1.0, 0.5), sin(ratio * PI) * 0.5 + 0.5)
		draw_line(Vector2(bar_x - 14, track_top + i), Vector2(bar_x + 14, track_top + i), col, 1.0)

	# Neutral notch — glowing accent
	var neutral_y = lerp(bar_bot, bar_top, 0.5)
	draw_rect(Rect2(bar_x - 24, neutral_y - 4, 48, 8), Color(0.95, 0.92, 0.30, 0.95))
	draw_rect(Rect2(bar_x - 26, neutral_y - 6, 52, 12), Color(0.95, 0.92, 0.30, 0.25), false, 2.0)

	# Handle — smooth modern style with instant press feedback
	var handle_y = lerp(bar_bot, bar_top, throttle)
	var handle_size = 84.0
	var handle_col := Color(0.10, 0.85, 0.30) # forward = solid green
	if throttle < 0.48: handle_col = Color(0.95, 0.45, 0.10) # reverse = orange
	elif throttle > 0.95: handle_col = Color(0.20, 0.85, 1.00) # near max = cyan
	_draw_smooth_handle(Rect2(bar_x - handle_size * 0.5, handle_y - handle_size * 0.5, handle_size, handle_size), handle_col)

	# Throttle labels
	var tlbl := "NEUTRAL"
	if throttle > 0.52: tlbl = "FWD %d%%" % int((throttle - 0.5) * 200.0)
	elif throttle < 0.48: tlbl = "REV %d%%" % int((0.5 - throttle) * 200.0)
	var tlbl_pos := Vector2(bar_x + 58, handle_y + 8)
	draw_string(font, tlbl_pos + Vector2(1, 1), tlbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0, 0, 0, 0.6))
	draw_string(font, tlbl_pos, tlbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
	var thd_pos := Vector2(bar_x - 46, bar_top - 16)
	draw_string(font, thd_pos + Vector2(1, 1), "THROTTLE", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0, 0, 0, 0.5))
	draw_string(font, thd_pos, "THROTTLE", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.85, 0.95, 1.0, 1.0))

	# --- TOP-LEFT PANEL --- (config buttons: modern style)
	_draw_modern_button(_rect_recenter, "RECENTER GYRO", Color(0.18, 0.42, 0.78, 1.0), false, 16)
	var glbl = "GYRO: ON" if not gyro_paused else "GYRO: OFF"
	_draw_modern_button(_rect_gyrolock, glbl, Color(0.18, 0.42, 0.78, 1.0) if not gyro_paused else Color(0.32, 0.32, 0.36, 1.0), gyro_paused, 16)
	_draw_modern_button(_rect_sens, "SENS: %s" % SENS_LABELS[sens_idx], Color(0.12, 0.55, 0.42, 1.0), false, 16)

	# --- TOP-RIGHT PANEL ---
	_draw_modern_button(_rect_menu, "MENU", Color(0.18, 0.18, 0.22, 1.0), false, 18)

	var grav = Input.get_gravity()
	var motion_ok = grav.length() > 1.0
	var motion_c = Color.SPRING_GREEN if motion_ok else Color(1, 0.7, 0.2)
	draw_string(font, Vector2(sx - 180 - 36 - _safe_right, 114 + _safe_top), "MOTION: " + ("OK" if motion_ok else "WAIT"), HORIZONTAL_ALIGNMENT_LEFT, 180, 14, motion_c)

	# --- TOP-CENTER TELEMETRY (modern design) ---
	var hud_box: Rect2 = Rect2(sx * 0.5 - 170, 36 + _safe_top, 340, 54)
	_draw_modern_panel(hud_box, Color(0.02, 0.06, 0.10, 0.92), Color(0.0, 0.7, 1.0, 0.5))

	var speed_str = "SPD %4d m/s" % int(hud_speed)
	var alt_str = _format_alt(hud_alt)
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 22), speed_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.7, 1, 1))
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 44), "ALT " + alt_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 1, 1))
	if hud_warp:
		draw_string(font, Vector2(hud_box.position.x + 200, hud_box.position.y + 34), "WARP", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 0.92, 0.25))

	# --- BOTTOM-RIGHT CONTROL CLUSTER (modern buttons with smooth corners) ---
	_draw_modern_button(_rect_fire, "FIRE", Color(0.85, 0.08, 0.08, 1.0), fire_touch != -1, 36)
	_draw_modern_button(_rect_boost, "BOOST", Color(0.95, 0.78, 0.05, 1.0), boost_touch != -1, 30)
	_draw_modern_button(_rect_brake, "BRAKE", Color(0.88, 0.42, 0.05, 1.0), brake_touch != -1, 22)

	# --- BOTTOM-LEFT ROTATE PAIR (modern buttons) ---
	var roll_col := Color(0.20, 0.38, 0.85, 1.0)
	_draw_modern_button(_rect_rolll, "◀ ROLL", roll_col, rolll_touch != -1, 24)
	_draw_modern_button(_rect_rollr, "ROLL ▶", roll_col, rollr_touch != -1, 24)

# -----------------------------------------------------------------
#  MODERN BUTTON DRAWING HELPERS
# -----------------------------------------------------------------

func _draw_modern_panel(r: Rect2, bg_color: Color, border_color: Color) -> void:
	# Modern flat design with subtle border
	draw_rect(r, bg_color)
	draw_rect(r, border_color, false, 1.5)

func _draw_smooth_handle(r: Rect2, fill: Color) -> void:
	# Modern rounded handle with gradient and shadow
	var rx0 = r.position.x
	var ry0 = r.position.y
	var rx1 = r.position.x + r.size.x
	var ry1 = r.position.y + r.size.y
	var radius = 12.0

	# Solid fill
	draw_rect(r, fill)

	# Subtle inner shadow on press (instant feedback)
	draw_rect(r, Color(0, 0, 0, 0.15), false, 2.0)

	# Outer glow for depth
	draw_rect(r.grow(2.0), fill.lightened(0.3), false, 1.0)

func _draw_modern_button(r: Rect2, label: String, fill: Color, pressed: bool, font_size: int = 16) -> void:
	# Modern flat button with rounded corners, instant press feedback
	var face = fill
	if pressed:
		# Pressed state: darker with subtle inset shadow
		face = fill.darkened(0.25)
		draw_rect(r, Color(0, 0, 0, 0.2))

	# Rounded corners via subtle border gradient
	draw_rect(r, face)
	var border_color = fill.lightened(0.2) if not pressed else fill.darkened(0.4)
	draw_rect(r, border_color, false, 1.5)

	# Text label with shadow
	var font = ThemeDB.fallback_font
	var text_size = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	var label_pos = r.position + Vector2(r.size.x * 0.5 - text_size.x * 0.5, r.size.y * 0.5 + font_size * 0.35)

	# Shadow for readability
	var text_col = Color.WHITE if not pressed else Color(0.85, 0.85, 0.85)
	draw_string(font, label_pos + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(0, 0, 0, 0.5))
	draw_string(font, label_pos, label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, text_col)

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
		elif event.index == fire_touch or event.index == boost_touch \
				or event.index == brake_touch or event.index == rolll_touch \
				or event.index == rollr_touch:
			# Already claimed by a button
			get_viewport().set_input_as_handled()
		else:
			_on_press(event.position, event.index)
	elif event is InputEventMouseMotion:
		if l_dragging:
			_update_throttle_from_pos(event.position.y)
			get_viewport().set_input_as_handled()

func _on_press(pos: Vector2, index: int) -> void:
	# INPUT PRIORITY (strict order to prevent cross-talk):
	# 1. Top panel buttons (recenter, gyro lock, sensitivity, menu)
	# 2. Right-side buttons (fire, boost, brake)
	# 3. Bottom-left roll buttons
	# 4. Throttle (last, with explicit bounds check)

	# --- TOP PANEL (highest priority) ---
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

	# --- RIGHT-SIDE BUTTONS ---
	if _rect_fire.has_point(pos) and fire_touch == -1:
		fire_touch = index
		fire_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	# BOOST: Add explicit validation to prevent overlap with FIRE
	if _rect_boost.has_point(pos) and boost_touch == -1 and fire_touch != index:
		boost_touch = index
		boost_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	if _rect_brake.has_point(pos) and brake_touch == -1:
		brake_touch = index
		brake_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	# --- ROLL BUTTONS (with proper bounds checking) ---
	if _rect_rolll.has_point(pos) and rolll_touch == -1:
		rolll_touch = index
		var now_l := Time.get_ticks_msec() / 1000.0
		if now_l - _rolll_last_tap < _DOUBLE_TAP_WINDOW:
			roll_triggered.emit(1.0)  # double-tap → barrel roll
			_rolll_last_tap = -1.0
		else:
			_rolll_last_tap = now_l
		roll_held.emit(1.0, true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	if _rect_rollr.has_point(pos) and rollr_touch == -1:
		rollr_touch = index
		var now_r := Time.get_ticks_msec() / 1000.0
		if now_r - _rollr_last_tap < _DOUBLE_TAP_WINDOW:
			roll_triggered.emit(-1.0)
			_rollr_last_tap = -1.0
		else:
			_rollr_last_tap = now_r
		roll_held.emit(-1.0, true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

	# --- THROTTLE (last priority, with explicit hit area check) ---
	# FIXED: Use separate smaller hit area (_rect_throttle_hit) to prevent roll overlap
	if _rect_throttle_hit.has_point(pos):
		l_touch_idx = index
		_set_throttle_dragging(true)
		_update_throttle_from_pos(pos.y)
		get_viewport().set_input_as_handled()

func _on_release(index: int) -> void:
	if index == l_touch_idx:
		l_touch_idx = -1
		_set_throttle_dragging(false)
		# LATCHING: throttle stays where pilot left it
		get_viewport().set_input_as_handled()
		return

	if index == fire_touch:
		fire_touch = -1
		fire_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == boost_touch:
		boost_touch = -1
		boost_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == brake_touch:
		brake_touch = -1
		brake_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == rolll_touch:
		rolll_touch = -1
		roll_held.emit(1.0, false)
		queue_redraw(); get_viewport().set_input_as_handled()
	elif index == rollr_touch:
		rollr_touch = -1
		roll_held.emit(-1.0, false)
		queue_redraw(); get_viewport().set_input_as_handled()

func _set_throttle_dragging(active: bool) -> void:
	if l_dragging == active: return
	l_dragging = active
	throttle_dragging_changed.emit(active)

func _update_throttle_from_pos(y: float) -> void:
	var v_size = get_viewport_rect().size
	var bar_h = v_size.y * _THROTTLE_BAR_H_RATIO
	var bar_y_center = v_size.y * _THROTTLE_BAR_Y_CENTER_RATIO
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

extends Control

# MobileControlsUI.gd (Pilot-Touch Edition)
# Managed by THE ARCHITECT.
#
# LAYOUT (landscape):
#   TOP-LEFT:    [RECENTER]  [GYRO LOCK]  [SENS: LOW/MED/HIGH]
#   TOP-RIGHT:   [MOTION STATUS]  [MENU]
#   LEFT-SIDE:   Latching vertical throttle (no auto-reset). Tap handle to snap neutral.
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

# Throttle geometry (kept compact so the bar's hit rect doesn't reach the
# bottom-left roll buttons).
const _THROTTLE_BAR_X := 80.0
const _THROTTLE_BAR_H_RATIO := 0.40
const _THROTTLE_BAR_Y_CENTER_RATIO := 0.55

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
	var bar_x = _THROTTLE_BAR_X
	var bar_h = sy * _THROTTLE_BAR_H_RATIO
	var bar_y_center = sy * _THROTTLE_BAR_Y_CENTER_RATIO
	var bar_top = bar_y_center - bar_h * 0.5
	var bar_bot = bar_y_center + bar_h * 0.5
	_rect_throttle_bar = Rect2(bar_x - 60.0, bar_top - 40.0, 160.0, bar_h + 80.0)

	# Throttle backplate — solid dark panel with a hard cyan border (Star Fox HUD vibe)
	var bar_bg = Rect2(bar_x - 26, bar_top - 12, 52, bar_h + 24)
	draw_rect(bar_bg, Color(0.04, 0.06, 0.12, 0.92))
	draw_rect(bar_bg, Color(0.30, 0.75, 1.0, 0.95), false, 2.0)

	# Center track (chunky, hard line)
	draw_line(Vector2(bar_x, bar_top), Vector2(bar_x, bar_bot), Color(0.55, 0.85, 1.0, 0.45), 6.0)

	# Tick marks — thicker, evenly spaced 0/25/50/75/100
	for i in range(0, 5):
		var ty = lerp(bar_bot, bar_top, i / 4.0)
		draw_rect(Rect2(bar_x - 18, ty - 1, 36, 3), Color(1, 1, 1, 0.55))

	# Neutral notch — pixel-art yellow band straddling center
	var neutral_y = lerp(bar_bot, bar_top, 0.5)
	draw_rect(Rect2(bar_x - 22, neutral_y - 3, 44, 6), Color(0.95, 0.92, 0.30, 0.95))

	# Handle — hard square plate with bezel (uses the same retro plate helper)
	var handle_y = lerp(bar_bot, bar_top, throttle)
	var handle_size = 84.0
	var handle_col := Color(0.10, 0.85, 0.30) # forward = solid green
	if throttle < 0.48: handle_col = Color(0.95, 0.45, 0.10) # reverse = orange
	elif throttle > 0.95: handle_col = Color(0.20, 0.85, 1.00) # near max = cyan
	_draw_retro_plate(Rect2(bar_x - handle_size * 0.5, handle_y - handle_size * 0.5, handle_size, handle_size), handle_col, false)

	# Throttle label — hard 1px offset shadow for the stamped/retro look.
	var tlbl := "NEUTRAL"
	if throttle > 0.52: tlbl = "FWD %d%%" % int((throttle - 0.5) * 200.0)
	elif throttle < 0.48: tlbl = "REV %d%%" % int((0.5 - throttle) * 200.0)
	var tlbl_pos := Vector2(bar_x + 58, handle_y + 8)
	draw_string(font, tlbl_pos + Vector2(1, 1), tlbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0, 0, 0, 0.8))
	draw_string(font, tlbl_pos, tlbl, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
	var thd_pos := Vector2(bar_x - 46, bar_top - 16)
	draw_string(font, thd_pos + Vector2(1, 1), "THROTTLE", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0, 0, 0, 0.7))
	draw_string(font, thd_pos, "THROTTLE", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.85, 0.95, 1.0, 1.0))

	# --- TOP-LEFT PANEL --- (config buttons: muted steel-blue retro plates)
	_rect_recenter = Rect2(36, 36, 180, 54)
	_draw_button(_rect_recenter, "RECENTER GYRO", Color(0.22, 0.28, 0.40, 1.0), false)

	_rect_gyrolock = Rect2(36, 100, 180, 54)
	var glbl = "GYRO: ON" if not gyro_paused else "GYRO: OFF"
	_draw_button(_rect_gyrolock, glbl, Color(0.18, 0.42, 0.78, 1.0) if not gyro_paused else Color(0.32, 0.32, 0.36, 1.0), gyro_paused)

	_rect_sens = Rect2(36, 164, 180, 54)
	_draw_button(_rect_sens, "SENS: %s" % SENS_LABELS[sens_idx], Color(0.12, 0.55, 0.42, 1.0), false)

	# --- TOP-RIGHT PANEL ---
	_rect_menu = Rect2(sx - 180 - 36, 36, 180, 54)
	_draw_button(_rect_menu, "MENU", Color(0.18, 0.18, 0.22, 1.0), false)

	var grav = Input.get_gravity()
	var motion_ok = grav.length() > 1.0
	var motion_c = Color.SPRING_GREEN if motion_ok else Color(1, 0.7, 0.2)
	draw_string(font, Vector2(sx - 180 - 36, 114), "MOTION: " + ("OK" if motion_ok else "WAIT"), HORIZONTAL_ALIGNMENT_LEFT, 180, 14, motion_c)

	# --- TOP-CENTER TELEMETRY (Star Fox 64 style: solid dark panel + corner brackets) ---
	var hud_box: Rect2 = Rect2(sx * 0.5 - 170, 36, 340, 54)
	draw_rect(hud_box, Color(0.02, 0.06, 0.10, 0.92))
	draw_rect(hud_box, Color(0.0, 0.85, 1.0, 1.0), false, 2.0)
	# Corner brackets — 14px L-shapes at each corner, pure white pixel art.
	var bk := 14.0
	var hb_x0 := hud_box.position.x
	var hb_y0 := hud_box.position.y
	var hb_x1 := hud_box.position.x + hud_box.size.x
	var hb_y1 := hud_box.position.y + hud_box.size.y
	var hb_c := Color(1, 1, 1, 1)
	draw_line(Vector2(hb_x0, hb_y0), Vector2(hb_x0 + bk, hb_y0), hb_c, 3.0)
	draw_line(Vector2(hb_x0, hb_y0), Vector2(hb_x0, hb_y0 + bk), hb_c, 3.0)
	draw_line(Vector2(hb_x1, hb_y0), Vector2(hb_x1 - bk, hb_y0), hb_c, 3.0)
	draw_line(Vector2(hb_x1, hb_y0), Vector2(hb_x1, hb_y0 + bk), hb_c, 3.0)
	draw_line(Vector2(hb_x0, hb_y1), Vector2(hb_x0 + bk, hb_y1), hb_c, 3.0)
	draw_line(Vector2(hb_x0, hb_y1), Vector2(hb_x0, hb_y1 - bk), hb_c, 3.0)
	draw_line(Vector2(hb_x1, hb_y1), Vector2(hb_x1 - bk, hb_y1), hb_c, 3.0)
	draw_line(Vector2(hb_x1, hb_y1), Vector2(hb_x1, hb_y1 - bk), hb_c, 3.0)
	var speed_str = "SPD %4d m/s" % int(hud_speed)
	var alt_str = _format_alt(hud_alt)
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 22), speed_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.7, 1, 1))
	draw_string(font, Vector2(hud_box.position.x + 14, hud_box.position.y + 44), "ALT " + alt_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.7, 1, 1))
	if hud_warp:
		draw_string(font, Vector2(hud_box.position.x + 200, hud_box.position.y + 34), "WARP", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(1, 0.92, 0.25))

	# --- BOTTOM-RIGHT CONTROL CLUSTER ---
	# Three vertically-stacked buttons, all the same width. No overlaps.
	var pad = 36.0
	var col_x = sx - pad
	var base_y = sy - pad
	var btn_w := 216.0  # all three share this width
	var btn_h := 100.0  # FIRE and BOOST are the same height
	var gap := 8.0

	# FIRE — primary, bottom
	_rect_fire = Rect2(col_x - btn_w, base_y - btn_h, btn_w, btn_h)
	_draw_button(_rect_fire, "FIRE", Color(0.85, 0.08, 0.08, 1.0), fire_touch != -1, 36)

	# BOOST — same size as FIRE, directly above
	_rect_boost = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h, btn_w, btn_h)
	_draw_button(_rect_boost, "BOOST", Color(0.95, 0.78, 0.05, 1.0), boost_touch != -1, 30)

	# BRAKE — full width, shorter accent above BOOST
	var brake_h := 58.0
	_rect_brake = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h - gap - brake_h, btn_w, brake_h)
	_draw_button(_rect_brake, "BRAKE", Color(0.88, 0.42, 0.05, 1.0), brake_touch != -1, 22)

	# --- BOTTOM-LEFT ROTATE PAIR ---
	# Hold = continuous roll. Double-tap (within _DOUBLE_TAP_WINDOW) = barrel roll.
	var roll_h := 80.0
	var roll_w := 136.0
	_rect_rolll = Rect2(pad, base_y - roll_h, roll_w, roll_h)
	_rect_rollr = Rect2(pad + roll_w + 10, base_y - roll_h, roll_w, roll_h)
	var roll_col := Color(0.20, 0.38, 0.85, 1.0)
	_draw_button(_rect_rolll, "◀ ROLL", roll_col, rolll_touch != -1, 24)
	_draw_button(_rect_rollr, "ROLL ▶", roll_col, rollr_touch != -1, 24)


# -----------------------------------------------------------------
#  BUTTON DRAW HELPER
# -----------------------------------------------------------------

func _draw_retro_plate(r: Rect2, fill: Color, pressed: bool) -> void:
	# PS1/N64-style raised plate. Sharp corners, double-bezel, no shadow.
	# Pressed inverts the bezel so the face looks pushed in.
	var face: Color = fill
	face.a = max(face.a, 0.92)
	var bevel_light: Color = face.lightened(0.35)
	var bevel_dark: Color = face.darkened(0.45)
	if pressed:
		face = face.darkened(0.20)
		var t := bevel_light; bevel_light = bevel_dark; bevel_dark = t
	# Pixel-snap all coords so edges land on whole pixels.
	var rx0: float = floor(r.position.x)
	var ry0: float = floor(r.position.y)
	var rx1: float = floor(r.position.x + r.size.x)
	var ry1: float = floor(r.position.y + r.size.y)
	var rsnap: Rect2 = Rect2(rx0, ry0, rx1 - rx0, ry1 - ry0)
	# Solid face fill.
	draw_rect(rsnap, face)
	# CRT / PS1 scanlines — horizontal stripe every 4px at low opacity.
	var scan_c: Color = Color(0.0, 0.0, 0.0, 0.11)
	var sy_scan: float = ry0 + 3.5
	while sy_scan < ry1 - 1.0:
		draw_line(Vector2(rx0 + 1.0, sy_scan), Vector2(rx1 - 1.0, sy_scan), scan_c, 1.0)
		sy_scan += 4.0
	# 3px bezel: light on top + left, dark on bottom + right.
	draw_line(Vector2(rx0, ry0 + 1.5), Vector2(rx1, ry0 + 1.5), bevel_light, 3.0)
	draw_line(Vector2(rx0 + 1.5, ry0), Vector2(rx0 + 1.5, ry1), bevel_light, 3.0)
	draw_line(Vector2(rx1 - 1.5, ry0), Vector2(rx1 - 1.5, ry1), bevel_dark, 3.0)
	draw_line(Vector2(rx0, ry1 - 1.5), Vector2(rx1, ry1 - 1.5), bevel_dark, 3.0)
	# 2px hard outer outline — cyan when pressed for arcade-press feedback.
	var outline: Color = Color(0.55, 1.0, 1.0, 1.0) if pressed else Color(1, 1, 1, 0.95)
	draw_rect(rsnap, outline, false, 2.0)

func _draw_button(r: Rect2, label: String, fill: Color, pressed: bool, font_size: int = 16) -> void:
	_draw_retro_plate(r, fill, pressed)
	var font = ThemeDB.fallback_font
	var text_size = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	# 1px hard offset shadow on the label for readability against the bevel.
	var label_pos = r.position + Vector2(r.size.x * 0.5 - text_size.x * 0.5, r.size.y * 0.5 + font_size * 0.35)
	draw_string(font, label_pos + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(0, 0, 0, 0.75))
	draw_string(font, label_pos, label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)

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
			# Already claimed by a button — swallow the drag so finger drift
			# doesn't re-enter _on_press and steal the index for an adjacent button.
			get_viewport().set_input_as_handled()
		else:
			_on_press(event.position, event.index)
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
		var now_l := Time.get_ticks_msec() / 1000.0
		if now_l - _rolll_last_tap < _DOUBLE_TAP_WINDOW:
			roll_triggered.emit(1.0)  # double-tap → barrel roll
			_rolll_last_tap = -1.0     # consume so a third tap starts fresh
		else:
			_rolll_last_tap = now_l
		roll_held.emit(1.0, true)      # always engage continuous roll on press
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_rollr.has_point(pos) and rollr_touch == -1:
		rollr_touch = index
		var now_r := Time.get_ticks_msec() / 1000.0
		if now_r - _rollr_last_tap < _DOUBLE_TAP_WINDOW:
			roll_triggered.emit(-1.0) # double-tap → barrel roll
			_rollr_last_tap = -1.0
		else:
			_rollr_last_tap = now_r
		roll_held.emit(-1.0, true)
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
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == boost_touch:
		boost_touch = -1
		boost_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == brake_touch:
		brake_touch = -1
		brake_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == rolll_touch:
		rolll_touch = -1
		roll_held.emit(1.0, false)
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == rollr_touch:
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

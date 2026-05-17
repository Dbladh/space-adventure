extends Control

# MobileControlsUI.gd (Retro-Space Edition)
# Managed by THE ARCHITECT.
# Two-state layout:
#   PLAYING : RECENTER top-left | combat cluster bottom-right | roll buttons bottom-left
#   PAUSED  : RECENTER top-left | pause menu bottom-right (RESUME + GYRO + SENS)
#             Combat buttons are hidden so the player can't accidentally fire while
#             browsing settings.  Roll buttons are also hidden.
#
# All buttons render via HUDStyle.draw_beveled_rect — chunky 80s-arcade depth
# (top/left highlight + drop shadow when raised, bottom/right highlight + no
# shadow + content nudged down/right when held), so a held FIRE/BOOST/BRAKE
# visibly recesses into the screen and toggles like GYRO stay recessed while
# active.
#
# process_mode = ALWAYS so the overlay keeps drawing while get_tree().paused == true.

const HUDStyle := preload("res://src/ui/HUDStyle.gd")

signal throttle_changed(value: float)
signal throttle_dragging_changed(active: bool)
signal fire_pressed(pressed: bool)
signal boost_pressed(pressed: bool)
signal brake_pressed(pressed: bool)
signal roll_triggered(direction: float)
signal roll_held(direction: float, pressed: bool)
signal sensitivity_changed(value: float)
signal gyro_paused_changed(paused: bool)
signal deadzone_changed(value: float)
signal recalibrate_pressed()
signal menu_pressed()   # still emitted on PAUSE button press

const _DOUBLE_TAP_WINDOW := 0.22
var _rolll_last_tap: float = -1.0
var _rollr_last_tap: float = -1.0

# ---- COLOR PALETTE ----
const C_BG         := Color(0.08, 0.09, 0.16, 0.96)
const C_PANEL_BDR  := Color(0.35, 0.68, 0.78, 0.55)
const C_CREAM      := Color(0.88, 0.82, 0.60, 1.00)
const C_ORANGE     := Color(0.96, 0.62, 0.12, 1.00)
const C_ORANGE_DIM := Color(0.96, 0.62, 0.12, 0.25)
const C_TEAL       := Color(0.35, 0.68, 0.78, 1.00)
const C_TEAL_DIM   := Color(0.35, 0.68, 0.78, 0.25)
const C_RED        := Color(0.88, 0.18, 0.18, 1.00)
const C_RED_DIM    := Color(0.88, 0.18, 0.18, 0.25)
const C_NAVY_TEXT  := Color(0.10, 0.10, 0.18, 1.00)
const C_GREEN      := Color(0.25, 0.85, 0.45, 1.00)
const C_GYRO_ON    := Color(0.35, 0.68, 0.78, 1.00)
const C_GYRO_OFF   := Color(0.45, 0.45, 0.52, 1.00)
const C_RESUME     := Color(0.20, 0.72, 0.35, 1.00)

# ---- SAFE AREA ----
var _safe_left: float = 0.0
var _safe_right: float = 0.0
var _safe_top: float = 0.0
var _safe_bottom: float = 0.0

# ---- MODAL SUPPRESSION ----
# Set true by any full-screen menu (station, planet placement, galaxy map) so
# this overlay stops swallowing swipes and stops drawing its play / pause
# columns over the modal plate.  Toggled via the "mobile_controls_ui" group.
var modal_ui_open: bool = false

# Cinematic mode — hides ALL controls except the corner PAUSE button so
# the player can take a clean screenshot or just enjoy the view.  Toggled
# from the pause-menu Settings tab.  Pause stays reachable so they can
# always toggle back without learning a hidden gesture.
var cinematic_mode: bool = false

func set_modal_ui_open(open: bool) -> void:
	modal_ui_open = open
	# Drop mouse filter so swipes pass through to the modal's ScrollContainer.
	mouse_filter = Control.MOUSE_FILTER_IGNORE if open else Control.MOUSE_FILTER_STOP
	queue_redraw()

func set_cinematic_mode(on: bool) -> void:
	cinematic_mode = on
	queue_redraw()

# ---- THROTTLE ----
var _throttle_bar_x: float = 144.0
const _THROTTLE_BAR_H_RATIO         := 0.40
const _THROTTLE_BAR_Y_CENTER_RATIO  := 0.55
const _THROTTLE_HIT_WIDTH           := 120.0
const _THROTTLE_HIT_HEIGHT_PAD      := 30.0
var throttle: float = 0.5
var l_touch_idx: int = -1
var l_dragging: bool = false

# ---- BUTTON TOUCH STATE ----
var fire_touch: int  = -1
var boost_touch: int = -1
var brake_touch: int = -1
var rolll_touch: int = -1
var rollr_touch: int = -1
# Pause-menu button touch tracking
var _resume_touch: int  = -1
var _pgyro_touch: int   = -1
var _psens_touch: int   = -1
var _pdead_touch: int   = -1
var _pdbg_touch: int    = -1

# ---- GYRO DEBUG OVERLAY ----
# Toggled via the DBG button in the pause menu.  Shows the live gyro
# pipeline values on-screen so the bug can be diagnosed on iPhone without
# needing Xcode console access.
var _gyro_dbg_visible: bool   = false
var _gyro_dbg_grav: Vector3   = Vector3.ZERO
var _gyro_dbg_nx: float       = 0.0
var _gyro_dbg_ny: float       = 0.0
var _gyro_dbg_nz: float       = 0.0
var _gyro_dbg_tx: float       = 0.0
var _gyro_dbg_ty: float       = 0.0
var _gyro_dbg_tz: float       = 0.0
var _gyro_dbg_yaw: float      = 0.0
var _gyro_dbg_pitch: float    = 0.0
var _gyro_dbg_calib: bool     = false
var _gyro_dbg_calib_n: int    = 0
var _gyro_dbg_redraw_acc: float = 0.0

# ---- OPTIONS ----
var gyro_paused: bool = false
var sens_idx: int = 1
const SENS_VALUES = [0.6, 1.0, 1.6]
const SENS_LABELS = ["LOW", "MED", "HIGH"]
var dead_idx: int = 1
const DEAD_VALUES = [0.8, 1.4, 2.4]
const DEAD_LABELS = ["NARROW", "MED", "WIDE"]

# ---- TELEMETRY ----
var hud_speed: float = 0.0
var hud_alt: float   = 0.0
var hud_warp: bool   = false
var _last_hud_speed: float = -1.0
var _last_hud_alt:   float = -1.0
var _last_hud_warp:  bool  = false

# ---- CACHED RECTS ----
var _rect_recenter:     Rect2
var _rect_menu:         Rect2
var _rect_fire:         Rect2
var _rect_boost:        Rect2
var _rect_brake:        Rect2
var _rect_rolll:        Rect2
var _rect_rollr:        Rect2
var _rect_throttle_bar: Rect2
var _rect_throttle_hit: Rect2
# Pause-menu rects (built in _update_layout too)
var _rect_resume:       Rect2
var _rect_pgyro:        Rect2
var _rect_psens:        Rect2
var _rect_pdead:        Rect2
var _rect_pdbg:         Rect2
var _last_viewport_size: Vector2 = Vector2.ZERO

# =====================================================================
#  INIT
# =====================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS   # keep drawing while tree is paused
	add_to_group("mobile_controls_ui")        # so menus can call set_modal_ui_open
	self.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	# Slight global transparency so the chrome doesn't fully block the game
	# behind it.  Applied via Control.modulate so every draw call inherits it.
	modulate.a = 0.85
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

	# Throttle
	var bar_x     = _throttle_bar_x
	var bar_h     = sy * _THROTTLE_BAR_H_RATIO
	var bar_y_cen = sy * _THROTTLE_BAR_Y_CENTER_RATIO
	var bar_top   = bar_y_cen - bar_h * 0.5
	_rect_throttle_bar = Rect2(bar_x - 26, bar_top - 12, 52, bar_h + 24)
	_rect_throttle_hit = Rect2(bar_x - _THROTTLE_HIT_WIDTH * 0.5,
		bar_top - _THROTTLE_HIT_HEIGHT_PAD,
		_THROTTLE_HIT_WIDTH, bar_h + _THROTTLE_HIT_HEIGHT_PAD * 2.0)

	# Top buttons (RECENTER only in play mode; pause menu has gyro/sens)
	# 50px height was below Apple's 44pt minimum once safe-area scaling kicks
	# in — bumped to 66, then again to 88 because the touch rect at the very
	# screen edge is unreliable on iOS once safe-area / scale conspire (user
	# reported the PAUSE button was only hittable in its right corner).  Wider
	# rect + slight inset gives the OS some margin and makes the button a
	# generous thumb target.
	var top_btn_w := 260.0
	var top_btn_h := 88.0
	var top_inset := 24.0   # nudged inward from the screen edge for reliability
	var tp = 24.0 + _safe_top
	_rect_recenter = Rect2(top_inset + _safe_left, tp, top_btn_w, top_btn_h)
	_rect_menu     = Rect2(sx - top_btn_w - top_inset - _safe_right, tp, top_btn_w, top_btn_h)

	# Combat cluster (bottom-right). BRAKE bumped 60 → 76 px so it clears
	# 44pt; FIRE/BOOST already comfortably above the floor.
	var pad    = 36.0 + _safe_bottom
	var col_x  = sx - pad - _safe_right
	var base_y = sy - pad
	var btn_w  := 220.0
	var btn_h  := 104.0
	var gap    := 10.0
	var brk_h  := 76.0
	_rect_fire  = Rect2(col_x - btn_w, base_y - btn_h, btn_w, btn_h)
	_rect_boost = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h, btn_w, btn_h)
	_rect_brake = Rect2(col_x - btn_w, base_y - btn_h - gap - btn_h - gap - brk_h, btn_w, brk_h)

	# Roll buttons (bottom-left). Wider gap (12 → 18 px) for thumb separation,
	# and bumped to 88 px tall. roll_w stays at 138 since both are paired.
	var roll_h   := 88.0
	var roll_w   := 138.0
	var roll_pad  = 36.0 + _safe_left
	_rect_rolll  = Rect2(roll_pad,               base_y - roll_h - _safe_bottom, roll_w, roll_h)
	_rect_rollr  = Rect2(roll_pad + roll_w + 18, base_y - roll_h - _safe_bottom, roll_w, roll_h)

	# Pause menu buttons (bottom-right, same position as combat cluster)
	# Stacked bottom-up: RESUME (large) → GYRO → SENS → DEAD (small).
	var pm_btn_h := 100.0
	var pm_sml_h := 70.0   # bumped from 58 for 44pt+ touch targets
	_rect_resume = Rect2(col_x - btn_w, base_y - pm_btn_h, btn_w, pm_btn_h)
	_rect_pgyro  = Rect2(col_x - btn_w, base_y - pm_btn_h - gap - pm_sml_h, btn_w, pm_sml_h)
	_rect_psens  = Rect2(col_x - btn_w, base_y - pm_btn_h - gap - pm_sml_h - gap - pm_sml_h, btn_w, pm_sml_h)
	_rect_pdead  = Rect2(col_x - btn_w, base_y - pm_btn_h - gap - pm_sml_h - gap - pm_sml_h - gap - pm_sml_h, btn_w, pm_sml_h)
	_rect_pdbg   = Rect2(col_x - btn_w, base_y - pm_btn_h - gap - pm_sml_h - gap - pm_sml_h - gap - pm_sml_h - gap - pm_sml_h, btn_w, pm_sml_h)

func set_telemetry(speed: float, alt: float, warping: bool) -> void:
	hud_speed = speed; hud_alt = alt; hud_warp = warping
	if abs(speed - _last_hud_speed) > 5.0 or abs(alt - _last_hud_alt) > 50.0 or warping != _last_hud_warp:
		_last_hud_speed = speed; _last_hud_alt = alt; _last_hud_warp = warping
		queue_redraw()

# Player pushes its gyro pipeline values here once per frame so they can be
# rendered on-screen.  Redraw is throttled to ~10 Hz via _process so this is
# cheap to call every frame.
func set_gyro_debug(grav: Vector3, nx: float, ny: float, nz: float,
		tx: float, ty: float, tz: float,
		yaw_s: float, pitch_s: float, is_calib: bool, calib_n: int) -> void:
	_gyro_dbg_grav = grav
	_gyro_dbg_nx = nx; _gyro_dbg_ny = ny; _gyro_dbg_nz = nz
	_gyro_dbg_tx = tx; _gyro_dbg_ty = ty; _gyro_dbg_tz = tz
	_gyro_dbg_yaw = yaw_s; _gyro_dbg_pitch = pitch_s
	_gyro_dbg_calib = is_calib
	_gyro_dbg_calib_n = calib_n

func _process(delta: float) -> void:
	_update_layout()
	# Keep redrawing while paused so the pause menu stays fresh
	if get_tree().paused:
		queue_redraw()
	# When the gyro debug overlay is on, refresh at ~10 Hz so the values are
	# readable but we're not redrawing every frame.
	elif _gyro_dbg_visible:
		_gyro_dbg_redraw_acc += delta
		if _gyro_dbg_redraw_acc >= 0.1:
			_gyro_dbg_redraw_acc = 0.0
			queue_redraw()

# =====================================================================
#  DRAW
# =====================================================================

func _draw() -> void:
	if modal_ui_open: return  # menu plate sits above us; don't render any controls
	var v_size = get_viewport_rect().size
	var font   = HUDStyle.PIXEL_FONT
	var sx     = v_size.x
	var sy     = v_size.y
	var paused = get_tree().paused

	# Cinematic mode: skip every control except the corner PAUSE button.
	# Pause stays visible so the player can always toggle back via Settings.
	if cinematic_mode and not paused:
		var pause_label_c: String = "PAUSE"
		var pause_col_c: Color = C_TEAL.darkened(0.45)
		_draw_space_button(_rect_menu, pause_label_c, pause_col_c, C_TEAL, false, 13)
		return

	# ----- THROTTLE BAR (hidden during pause — controls are deactivated) -----
	if not paused:
		var bar_x     = _throttle_bar_x
		var bar_h     = sy * _THROTTLE_BAR_H_RATIO
		var bar_y_cen = sy * _THROTTLE_BAR_Y_CENTER_RATIO
		var bar_top   = bar_y_cen - bar_h * 0.5
		var bar_bot   = bar_y_cen + bar_h * 0.5

		var track_r = Rect2(bar_x - 14, bar_top, 28, bar_h)
		_draw_rounded_rect(track_r, C_BG, 10.0)
		_draw_rounded_rect(track_r, C_PANEL_BDR, 10.0, false, 1.5)

		var neutral_y = lerp(bar_bot, bar_top, 0.5)
		var handle_y  = lerp(bar_bot, bar_top, throttle)
		if throttle > 0.52:
			_draw_rounded_rect(Rect2(bar_x - 10, handle_y, 20, neutral_y - handle_y), C_TEAL.darkened(0.2), 4.0)
		elif throttle < 0.48:
			_draw_rounded_rect(Rect2(bar_x - 10, neutral_y, 20, handle_y - neutral_y), C_ORANGE.darkened(0.2), 4.0)

		draw_rect(Rect2(bar_x - 14, neutral_y - 3, 28, 6), C_ORANGE)
		draw_rect(Rect2(bar_x - 16, neutral_y - 5, 32, 10), C_ORANGE_DIM, false, 1.5)

		var h_col = C_GREEN
		if throttle < 0.48:   h_col = C_ORANGE
		elif throttle > 0.95: h_col = C_TEAL
		var hs = 72.0
		_draw_space_button(Rect2(bar_x - hs * 0.5, handle_y - hs * 0.5, hs, hs), "", h_col, Color.TRANSPARENT, false, 0)

		var tlbl = "NEUTRAL"
		if   throttle > 0.52: tlbl = "FWD %d%%" % int((throttle - 0.5) * 200.0)
		elif throttle < 0.48: tlbl = "REV %d%%" % int((0.5 - throttle) * 200.0)
		draw_string(font, Vector2(bar_x + 48, handle_y + 6), tlbl, HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, C_CREAM)
		draw_string(font, Vector2(bar_x - 40, bar_top - 14), "THROTTLE", HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, C_TEAL)

	# ----- TOP-LEFT: RECENTER only (always visible) -----
	_draw_space_button(_rect_recenter, "RECENTER", C_TEAL.darkened(0.45), C_TEAL, false, 11)

	# ----- TOP-RIGHT: PAUSE button (always visible) -----
	# When paused the button switches to RESUME with the green fill so it
	# reads as the next action.  The bevel always renders raised — pressing
	# triggers a one-shot signal, no held state.
	var pause_label = "RESUME" if paused else "PAUSE"
	var pause_col   = C_RESUME if paused else C_TEAL.darkened(0.45)
	_draw_space_button(_rect_menu, pause_label, pause_col, C_TEAL, false, 13)

	# Motion indicator (only in play mode — not needed during pause)
	if not paused:
		var grav      = Input.get_gravity()
		var motion_ok = grav.length() > 1.0
		draw_string(font, Vector2(sx - 180 - 36 - _safe_right, 116 + _safe_top),
			"MOTION " + ("OK" if motion_ok else "WAIT"), HORIZONTAL_ALIGNMENT_LEFT, 180, HUDStyle.HUD_FONT_TINY,
			Color.SPRING_GREEN if motion_ok else Color(1.0, 0.7, 0.2))

	# ----- TELEMETRY HUD -----
	# Hidden on mobile for now: the SPD/ALT chip was crowding the centred
	# health bar above it and covering the chip from above.  Speed and warp
	# state are already implied by the throttle slider and BOOST button; the
	# alt readout can come back later as a smaller chip if needed.

	if paused:
		# Pause-mode now owned entirely by PauseMenuUI (centered modal).
		# MobileControlsUI stops rendering everything except the corner
		# RECENTER + PAUSE/RESUME toggle button (drawn above).
		pass
	else:
		# ============================================================
		#  PLAY MODE — combat buttons + roll buttons
		# ============================================================
		# Held = recessed: button visibly sinks into the surface, mirroring
		# the EASY/MEDIUM/HARD reference.  Fill stays the bright button
		# colour so it remains identifiable; the bevel/nudge does the work.
		_draw_space_button(_rect_fire,  "FIRE",  C_RED,    C_RED,    fire_touch  != -1, 24)
		_draw_space_button(_rect_boost, "BOOST", C_ORANGE, C_ORANGE, boost_touch != -1, 20)
		_draw_space_button(_rect_brake, "BRAKE", C_TEAL,   C_TEAL,   brake_touch != -1, 16)

		_draw_space_button(_rect_rolll, "ROLL L", C_TEAL.darkened(0.35), C_TEAL, rolll_touch != -1, 14)
		_draw_space_button(_rect_rollr, "ROLL R", C_TEAL.darkened(0.35), C_TEAL, rollr_touch != -1, 14)

	# ----- GYRO DEBUG OVERLAY (visible in both play + pause modes) -----
	# Anchored below the RECENTER button on the top-left.  Renders a small
	# beveled chip with the raw gravity vector, calibration neutral, post-
	# neutral deltas, final virtual-stick values, and calibration progress.
	# This is the diagnostic surface for the iOS right-turn bug.
	if _gyro_dbg_visible:
		var dbg_x = _rect_recenter.position.x
		var dbg_y = _rect_recenter.position.y + _rect_recenter.size.y + 10.0
		var dbg_w = 360.0
		var dbg_h = 168.0
		var dbg_box = Rect2(dbg_x, dbg_y, dbg_w, dbg_h)
		HUDStyle.draw_beveled_rect(self, dbg_box, HUDStyle.BG_DEEP_NAVY, false)
		var tx_x = dbg_x + 12.0
		var line_y = dbg_y + 18.0
		var line_h = 18.0
		draw_string(font, Vector2(tx_x, line_y), "GYRO DEBUG",
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, C_TEAL)
		line_y += line_h
		draw_string(font, Vector2(tx_x, line_y),
			"GRAV %+.2f %+.2f %+.2f" % [_gyro_dbg_grav.x, _gyro_dbg_grav.y, _gyro_dbg_grav.z],
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, C_CREAM)
		line_y += line_h
		draw_string(font, Vector2(tx_x, line_y),
			"NEUT %+.2f %+.2f %+.2f" % [_gyro_dbg_nx, _gyro_dbg_ny, _gyro_dbg_nz],
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, C_CREAM)
		line_y += line_h
		# TY (yaw signal) coloured bright orange so it stands out from
		# TX/TZ — it's the actual control input after the X→Y axis fix.
		draw_string(font, Vector2(tx_x, line_y),
			"DLT %+.2f %+.2f %+.2f" % [_gyro_dbg_tx, _gyro_dbg_ty, _gyro_dbg_tz],
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, C_ORANGE)
		line_y += line_h
		draw_string(font, Vector2(tx_x, line_y),
			"STK  YAW %+.2f  PIT %+.2f" % [_gyro_dbg_yaw, _gyro_dbg_pitch],
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, C_GREEN)
		line_y += line_h
		var calib_str = "OK" if _gyro_dbg_calib else ("%d/30" % _gyro_dbg_calib_n)
		draw_string(font, Vector2(tx_x, line_y), "CALIB " + calib_str,
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY,
			C_GREEN if _gyro_dbg_calib else C_ORANGE)

# =====================================================================
#  DRAW HELPERS
# =====================================================================

func _draw_rounded_rect(r: Rect2, color: Color, radius: float, filled: bool = true, width: float = 1.5) -> void:
	radius = min(radius, min(r.size.x * 0.5, r.size.y * 0.5))
	if filled:
		draw_rect(Rect2(r.position.x + radius, r.position.y, r.size.x - radius * 2, r.size.y), color)
		draw_rect(Rect2(r.position.x, r.position.y + radius, r.size.x, r.size.y - radius * 2), color)
		draw_circle(Vector2(r.position.x + radius,            r.position.y + radius),            radius, color)
		draw_circle(Vector2(r.position.x + r.size.x - radius, r.position.y + radius),            radius, color)
		draw_circle(Vector2(r.position.x + radius,            r.position.y + r.size.y - radius), radius, color)
		draw_circle(Vector2(r.position.x + r.size.x - radius, r.position.y + r.size.y - radius), radius, color)
	else:
		const ARC_PTS := 8
		draw_arc(Vector2(r.position.x + radius,            r.position.y + radius),            radius, PI,        1.5 * PI, ARC_PTS, color, width)
		draw_arc(Vector2(r.position.x + r.size.x - radius, r.position.y + radius),            radius, 1.5 * PI, TAU,      ARC_PTS, color, width)
		draw_arc(Vector2(r.position.x + r.size.x - radius, r.position.y + r.size.y - radius), radius, 0.0,      0.5 * PI, ARC_PTS, color, width)
		draw_arc(Vector2(r.position.x + radius,            r.position.y + r.size.y - radius), radius, 0.5 * PI, PI,       ARC_PTS, color, width)
		draw_line(Vector2(r.position.x + radius, r.position.y),           Vector2(r.position.x + r.size.x - radius, r.position.y),           color, width)
		draw_line(Vector2(r.position.x + r.size.x, r.position.y + radius), Vector2(r.position.x + r.size.x, r.position.y + r.size.y - radius), color, width)
		draw_line(Vector2(r.position.x + r.size.x - radius, r.position.y + r.size.y), Vector2(r.position.x + radius, r.position.y + r.size.y), color, width)
		draw_line(Vector2(r.position.x, r.position.y + r.size.y - radius), Vector2(r.position.x, r.position.y + radius), color, width)

func _draw_space_button(r: Rect2, label: String, fill: Color, _accent: Color, pressed: bool, font_size: int = 14) -> void:
	# Draw the chunky beveled rectangle.  When pressed, the helper handles
	# the inverted highlight/shadow + darker fill, so the button visibly
	# sinks into the surface (matches the EASY-style selected look).
	HUDStyle.draw_beveled_rect(self, r, fill, pressed)

	if label.is_empty(): return
	var font := HUDStyle.PIXEL_FONT
	var text_size = font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	# When pressed, nudge the label 2px down-right so it visibly pushes in.
	var nudge: Vector2 = Vector2(2.0, 2.0) if pressed else Vector2.ZERO
	var lx = r.position.x + (r.size.x - text_size.x) * 0.5 + nudge.x
	var ly = r.position.y + r.size.y * 0.5 + font_size * 0.36 + nudge.y
	# Pixel-art readable text colour — white on dark fills, dark on bright.
	var text_col: Color = C_CREAM if fill.get_luminance() < 0.5 else C_NAVY_TEXT
	if pressed: text_col = text_col.lightened(0.05)
	# Tiny black drop-shadow on the text so labels stay legible over both
	# bright and dark fills.
	draw_string(font, Vector2(lx + 1, ly + 1), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(0, 0, 0, 0.55))
	draw_string(font, Vector2(lx, ly), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, text_col)

func _format_alt(alt: float) -> String:
	if alt > 1000.0: return "%.1f km" % (alt / 1000.0)
	if alt < -50.0:  return "--- subsurf"
	return "%d m" % int(max(alt, 0.0))

# =====================================================================
#  INPUT
# =====================================================================

func _input(event: InputEvent) -> void:
	if not visible: return
	if modal_ui_open: return   # any open menu owns input; don't fight its ScrollContainer
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
	var paused = get_tree().paused

	# Cinematic mode: only the PAUSE button responds; everything else is
	# both hidden AND non-interactive.  Bail before checking any other rect.
	if cinematic_mode and not paused:
		if _rect_menu.has_point(pos):
			menu_pressed.emit(); get_viewport().set_input_as_handled()
		return

	# RECENTER — always available
	if _rect_recenter.has_point(pos):
		recalibrate_pressed.emit(); get_viewport().set_input_as_handled(); return

	# PAUSE / RESUME button — always available
	if _rect_menu.has_point(pos):
		menu_pressed.emit(); get_viewport().set_input_as_handled(); return

	if paused:
		# Pause-mode settings now owned entirely by PauseMenuUI's centered
		# modal (GYRO / SENS / DEAD / volume / save / new-game).  Don't
		# consume here — let touches fall through to the modal (which is
		# PROCESS_MODE_ALWAYS and receives input while the tree is paused).
		return

	# ---- Combat buttons (play mode only) ----
	if _rect_fire.has_point(pos) and fire_touch == -1:
		fire_touch = index; fire_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_boost.has_point(pos) and boost_touch == -1 and fire_touch != index:
		boost_touch = index; boost_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return
	if _rect_brake.has_point(pos) and brake_touch == -1:
		brake_touch = index; brake_pressed.emit(true)
		queue_redraw(); get_viewport().set_input_as_handled(); return

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

	# Throttle (last priority, own hit area)
	if _rect_throttle_hit.has_point(pos):
		l_touch_idx = index; _set_throttle_dragging(true)
		_update_throttle_from_pos(pos.y)
		get_viewport().set_input_as_handled()

func _on_release(index: int) -> void:
	if index == l_touch_idx:
		l_touch_idx = -1; _set_throttle_dragging(false)
		get_viewport().set_input_as_handled(); return

	# Pause-mode releases are no longer handled here — PauseMenuUI owns the
	# modal and its buttons.  The corner PAUSE/RESUME toggle is still handled
	# by _rect_menu in _on_press (synchronous toggle, no release tracking).

	if index == fire_touch:
		fire_touch = -1; fire_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == boost_touch:
		boost_touch = -1; boost_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == brake_touch:
		brake_touch = -1; brake_pressed.emit(false)
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == rolll_touch:
		rolll_touch = -1; roll_held.emit(1.0, false)
		queue_redraw(); get_viewport().set_input_as_handled()
	if index == rollr_touch:
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

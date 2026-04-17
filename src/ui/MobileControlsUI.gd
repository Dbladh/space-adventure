extends Control

# MobileControlsUI.gd (Simplified Star Fox Edition)
# Managed by THE ARCHITECT.

signal throttle_changed(value: float)
signal fire_pressed(pressed: bool)
signal recalibrate_pressed()
signal menu_pressed()

var throttle: float = 0.5 # Start in the middle
var l_touch_idx: int = -1
var l_start_y: float = 0.0

func _ready() -> void:
	self.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# DRAW HINT: Vertical throttle bar on the left
	queue_redraw()

func _draw() -> void:
	var v_size = get_viewport_rect().size
	# Throttle Bar (Minimalist Line)
	var bar_x = 120.0 # Shift slightly more right for iPhone bezels
	var bar_h = v_size.y * 0.6
	var bar_y_center = v_size.y * 0.5
	var bar_top = bar_y_center - bar_h/2.0
	var bar_bot = bar_y_center + bar_h/2.0
	
	# Background
	draw_line(Vector2(bar_x, bar_top), Vector2(bar_x, bar_bot), Color(1,1,1,0.2), 6.0)
	
	# Active Handle: INDUSTRIAL ROUNDED SQUARE
	var handle_y = lerp(bar_bot, bar_top, throttle)
	var handle_size = 76.0
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color.SPRING_GREEN
	sb.set_corner_radius_all(15) # ACE: Pro rounded edges
	sb.set_shadow_size(4)
	sb.set_shadow_color(Color(0,0,0,0.6))
	draw_style_box(sb, Rect2(bar_x - handle_size*0.5, handle_y - handle_size*0.5, handle_size, handle_size))
	var speed_label = "NEUTRAL"
	if throttle > 0.52: speed_label = "FWD: %d%%" % ((throttle - 0.5) * 200.0)
	elif throttle < 0.48: speed_label = "REV: %d%%" % ((0.5 - throttle) * 200.0)
	draw_string(ThemeDB.fallback_font, Vector2(bar_x + 60, handle_y + 10), speed_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18)

	# Firing Area Hint (Right Side)
	draw_string(ThemeDB.fallback_font, Vector2(v_size.x - 250, v_size.y - 120), "TAP RIGHT TO FIRE", HORIZONTAL_ALIGNMENT_CENTER, -1, 20, Color(1,0,0,0.5))
	
	# RE-CENTER BUTTON (Top Left, near Throttle)
	var btn_rect = Rect2(40, 40, 160, 60)
	draw_rect(btn_rect, Color(1,1,1,0.1), true)
	draw_rect(btn_rect, Color(1,1,1,0.3), false, 2.0)
	draw_string(ThemeDB.fallback_font, Vector2(55, 80), "RE-CENTER GYRO", HORIZONTAL_ALIGNMENT_LEFT, -1, 14)

	# MOTION DEBUG (Safe Area Top Right)
	var grav = Input.get_gravity()
	var debug_str = "MOTION SENSORS: " + ("OK" if grav.length() > 1.0 else "WAITING...")
	draw_string(ThemeDB.fallback_font, Vector2(v_size.x - 300, 80), debug_str, HORIZONTAL_ALIGNMENT_RIGHT, -1, 14, Color.CHARTREUSE)
	
	# MENU BUTTON (Top Right)
	var menu_rect = Rect2(v_size.x - 200, 40, 160, 60)
	draw_rect(menu_rect, Color(0,0,0,0.4), true)
	draw_rect(menu_rect, Color(1,1,1,0.3), false, 2.0)
	draw_string(ThemeDB.fallback_font, Vector2(v_size.x - 150, 80), "MENU", HORIZONTAL_ALIGNMENT_LEFT, -1, 14)

func _input(event: InputEvent) -> void:
	var v_size = get_viewport_rect().size
	if event is InputEventScreenTouch:
		if event.pressed:
			# ACE: Check RE-CENTER button
			if event.position.x < 240 and event.position.y < 120:
				recalibrate_pressed.emit()
				get_viewport().set_input_as_handled()
				return
				
			# ACE: Check MENU button
			if event.position.x > v_size.x - 240 and event.position.y < 120:
				menu_pressed.emit()
				get_viewport().set_input_as_handled()
				return

			if event.position.x < v_size.x * 0.4:
				# Throttle Interaction
				l_touch_idx = event.index
				_update_throttle_from_pos(event.position.y)
				get_viewport().set_input_as_handled()
			else:
				# Firing Action
				fire_pressed.emit(true)
				get_viewport().set_input_as_handled()
		else:
			if event.index == l_touch_idx:
				l_touch_idx = -1
				_auto_reset_throttle()
				get_viewport().set_input_as_handled()
			else:
				fire_pressed.emit(false)
				get_viewport().set_input_as_handled()
				
	if event is InputEventScreenDrag:
		if event.index == l_touch_idx:
			_update_throttle_from_pos(event.position.y)
			get_viewport().set_input_as_handled()

func _auto_reset_throttle() -> void:
	# ACE: Smoothly return to Neutral (50%) when released
	throttle = 0.5
	throttle_changed.emit(throttle)
	queue_redraw()

func _update_throttle_from_pos(y: float) -> void:
	var v_size = get_viewport_rect().size
	var bar_h = v_size.y * 0.6
	var bar_y_center = v_size.y * 0.5
	var bar_top = bar_y_center - bar_h/2.0
	var bar_bot = bar_y_center + bar_h/2.0
	
	var raw_p = clamp((bar_bot - y) / bar_h, 0.0, 1.0)
	throttle = raw_p
	throttle_changed.emit(throttle)
	queue_redraw()

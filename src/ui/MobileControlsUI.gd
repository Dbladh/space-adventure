extends Control

# MobileControlsUI.gd (Simplified Star Fox Edition)
# Managed by THE ARCHITECT.

signal throttle_changed(value: float)
signal fire_pressed(pressed: bool)

var throttle: float = 0.0
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
	
	# Active Handle
	var handle_y = lerp(bar_bot, bar_top, throttle)
	draw_circle(Vector2(bar_x, handle_y), 35.0, Color.SPRING_GREEN)
	draw_string(ThemeDB.fallback_font, Vector2(bar_x + 60, handle_y + 10), "THRUST: %d%%" % (throttle * 100), HORIZONTAL_ALIGNMENT_LEFT, -1, 18)

	# Firing Area Hint (Right Side)
	draw_string(ThemeDB.fallback_font, Vector2(v_size.x - 250, v_size.y - 120), "TAP RIGHT TO FIRE", HORIZONTAL_ALIGNMENT_CENTER, -1, 20, Color(1,0,0,0.5))
	
	# MOTION DEBUG (Safe Area Top Right)
	var grav = Input.get_gravity()
	var debug_str = "MOTION SENSORS: " + ("OK" if grav.length() > 1.0 else "WAITING...")
	debug_str += "\nG-FORCE X: %.2f | Z: %.2f" % [grav.x, grav.z]
	debug_str += "\nTOUCH STATUS: " + ("THROTTLE ACTIVE" if l_touch_idx != -1 else "IDLE")
	draw_string(ThemeDB.fallback_font, Vector2(v_size.x - 350, 60), debug_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.CHARTREUSE)

func _input(event: InputEvent) -> void:
	var v_size = get_viewport_rect().size
	if event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x < v_size.x * 0.4:
				# Throttle Interaction
				l_touch_idx = event.index
				_update_throttle_from_pos(event.position.y)
			else:
				# Firing Action
				fire_pressed.emit(true)
		else:
			if event.index == l_touch_idx:
				l_touch_idx = -1
			else:
				fire_pressed.emit(false)
				
	if event is InputEventScreenDrag:
		if event.index == l_touch_idx:
			_update_throttle_from_pos(event.position.y)

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

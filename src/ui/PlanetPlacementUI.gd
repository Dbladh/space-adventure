extends Control

signal placement_confirmed(world_pos: Vector3, planet_name: String)
signal placement_canceled()

var max_range: float = 6250000.0
var placement_target: Vector2 = Vector2.ZERO
var is_valid_placement: bool = false
var name_input: LineEdit
var map_display: Control

# Minimum-distance tuning for the placement validator.  Old constants
# (1500 km between planets, 500 km from stations, 2000 km from player)
# were sized for a previous era of much larger planets and didn't read
# any actual radii — they were both too loose against stations (a
# scaled station model is ~500 km across, so 500 km from centre still
# clipped) and far too conservative against tiny planets (60-140 km
# now, so the old 1500 km guard reserved ~10× the actual contact
# distance).  All three checks are now (existing_radius +
# new_planet_radius + safety_margin) using whatever radius data the
# nodes expose.
const NEW_PLANET_RADIUS_ASSUMED: float = 150000.0  # 150 km — generous for the about-to-spawn planet
const PLANET_SAFETY_MARGIN: float = 50000.0        # 50 km buffer between planet surfaces
const STATION_SAFETY_MARGIN: float = 100000.0      # 100 km buffer around station extent
const STATION_RADIUS_ASSUMED: float = 500000.0     # 500 km — visual extent of the scaled station model
const PLAYER_SAFETY_MARGIN: float = 100000.0       # 100 km buffer around player ship

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	# 1. Dark Background
	var bg = ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.05, 0.98)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	
	# 2. Map Display (dedicated node for drawing)
	map_display = Control.new()
	map_display.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	map_display.custom_minimum_size = Vector2(600, 600)
	map_display.offset_left = -300
	map_display.offset_top = -300
	map_display.offset_right = 300
	map_display.offset_bottom = 300
	map_display.mouse_filter = Control.MOUSE_FILTER_STOP
	map_display.draw.connect(_on_map_draw)
	map_display.gui_input.connect(_on_map_input)
	add_child(map_display)
	
	# Title
	var lbl = Label.new()
	lbl.text = "SELECT PLANET ORBIT"
	lbl.add_theme_font_size_override("font_size", 42)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	lbl.offset_top = 60
	add_child(lbl)
	
	# Name Input
	name_input = LineEdit.new()
	name_input.placeholder_text = "Enter Planet Name..."
	name_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_input.add_theme_font_size_override("font_size", 24)
	name_input.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	name_input.custom_minimum_size = Vector2(400, 60)
	name_input.offset_left = -200
	name_input.offset_top = -180
	name_input.offset_right = 200
	name_input.offset_bottom = -120
	name_input.text = "Nova Prime"
	add_child(name_input)
	
	# Buttons HBox
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 30)
	hbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hbox.offset_top = -100
	hbox.offset_bottom = -40
	hbox.offset_left = -300
	hbox.offset_right = 300
	add_child(hbox)
	
	var confirm_btn = Button.new()
	confirm_btn.text = "  FORGE PLANET  "
	confirm_btn.add_theme_font_size_override("font_size", 28)
	confirm_btn.pressed.connect(_on_confirm)
	hbox.add_child(confirm_btn)
	
	var cancel_btn = Button.new()
	cancel_btn.text = "  CANCEL  "
	cancel_btn.add_theme_font_size_override("font_size", 28)
	cancel_btn.pressed.connect(func(): placement_canceled.emit(); queue_free())
	hbox.add_child(cancel_btn)

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		placement_canceled.emit()
		queue_free()
		get_viewport().set_input_as_handled()

func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		placement_target = event.position
		is_valid_placement = _check_placement_valid(placement_target)
		map_display.queue_redraw()

func _check_placement_valid(ui_pos: Vector2) -> bool:
	var w_pos = _map_to_world(ui_pos)
	var planets = get_tree().get_nodes_in_group("Planet")
	var stations = get_tree().get_nodes_in_group("SpaceStation")

	# Each minimum is (existing_radius + new_planet_radius + margin) so
	# planets can sit close to one another / to stations / to the player
	# while still leaving a buffer that prevents surface clipping.
	for p in planets:
		var pr: float = float(p.get("planet_radius")) if "planet_radius" in p else 100000.0
		var min_d: float = pr + NEW_PLANET_RADIUS_ASSUMED + PLANET_SAFETY_MARGIN
		if p.global_position.distance_to(w_pos) < min_d:
			return false

	for s in stations:
		# SpaceStations don't currently expose a radius — fall back to a
		# conservative footprint matching the scaled model's visible
		# extent, with an extra margin so the docking ring stays clear.
		var sr: float = float(s.get("station_radius")) if "station_radius" in s else STATION_RADIUS_ASSUMED
		var min_d: float = sr + NEW_PLANET_RADIUS_ASSUMED + STATION_SAFETY_MARGIN
		if s.global_position.distance_to(w_pos) < min_d:
			return false

	var players = get_tree().get_nodes_in_group("Player")
	if players.size() > 0:
		var min_d: float = NEW_PLANET_RADIUS_ASSUMED + PLAYER_SAFETY_MARGIN
		if players[0].global_position.distance_to(w_pos) < min_d:
			return false

	return true

func _on_confirm() -> void:
	if placement_target == Vector2.ZERO: return
	if not is_valid_placement: return
	var p_name = name_input.text.strip_edges()
	if p_name == "": p_name = "Nova Prime"
	
	placement_confirmed.emit(_map_to_world(placement_target), p_name)
	queue_free()

func _on_map_draw() -> void:
	var map_cen = map_display.size / 2.0
	var map_r = map_display.size.x / 2.0
	
	# Draw background grid
	for i in range(1, 6):
		map_display.draw_arc(map_cen, map_r * (float(i) / 5.0), 0, TAU, 64, Color(1, 1, 1, 0.12), 1.5)
	
	map_display.draw_line(Vector2(0, map_cen.y), Vector2(map_display.size.x, map_cen.y), Color(1, 1, 1, 0.2), 1.0)
	map_display.draw_line(Vector2(map_cen.x, 0), Vector2(map_cen.x, map_display.size.y), Color(1, 1, 1, 0.2), 1.0)
	
	var planets = get_tree().get_nodes_in_group("Planet")
	var stations = get_tree().get_nodes_in_group("SpaceStation")
	var player = get_tree().get_nodes_in_group("Player")
	var font = ThemeDB.get_fallback_font()
	
	# Draw Player
	if player.size() > 0:
		var p_node = player[0]
		var p_ui = _world_to_map(p_node.global_position)
		var p_col = Color(0.2, 1.0, 0.5)
		map_display.draw_circle(map_cen + p_ui, 6.0, p_col)
		map_display.draw_arc(map_cen + p_ui, 12.0, 0, TAU, 16, p_col, 2.0)
	
	# Draw Planets
	for p in planets:
		if not is_instance_valid(p): continue
		var p_ui = _world_to_map(p.global_position)
		map_display.draw_circle(map_cen + p_ui, 10.0, Color(0.4, 0.7, 1.0))
		map_display.draw_string(font, map_cen + p_ui + Vector2(14, 6), p.name.replace("Planet_", ""), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)
		
	# Draw Stations
	for s in stations:
		if not is_instance_valid(s): continue
		var s_ui = _world_to_map(s.global_position)
		var s_pts = PackedVector2Array([
			map_cen + s_ui + Vector2(0, -9),
			map_cen + s_ui + Vector2(9, 0),
			map_cen + s_ui + Vector2(0, 9),
			map_cen + s_ui + Vector2(-9, 0)
		])
		map_display.draw_colored_polygon(s_pts, Color(0.95, 0.85, 0.2))
		var s_name = s.name.replace("SpaceStation_", "").replace("OrbitalStation", "Orbital")
		map_display.draw_string(font, map_cen + s_ui + Vector2(14, 6), s_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.95, 0.85, 0.2))
		
	# Draw Placement Marker
	if placement_target != Vector2.ZERO:
		var col = Color.GREEN if is_valid_placement else Color.RED
		var pulse = (sin(Time.get_ticks_msec() * 0.012) + 1.0) * 0.5
		map_display.draw_arc(placement_target, 20.0 + pulse * 10.0, 0, TAU, 32, col, 3.0)
		map_display.draw_circle(placement_target, 5.0, col)
		map_display.draw_line(placement_target - Vector2(30, 0), placement_target + Vector2(30, 0), col, 2.0)
		map_display.draw_line(placement_target - Vector2(0, 30), placement_target + Vector2(0, 30), col, 2.0)
		
		if not is_valid_placement:
			map_display.draw_string(font, placement_target + Vector2(-100, -45), "ORBIT OCCUPIED", HORIZONTAL_ALIGNMENT_CENTER, -1, 20, Color.RED)

func _world_to_map(w_pos: Vector3) -> Vector2:
	var rel = Vector2(w_pos.x, w_pos.z)
	var scaled = rel / max_range * 300.0
	return scaled

func _map_to_world(ui_pos: Vector2) -> Vector3:
	var centered = ui_pos - Vector2(300, 300)
	var w_x = (centered.x / 300.0) * max_range
	var w_z = (centered.y / 300.0) * max_range
	return Vector3(w_x, 0.0, w_z)

func _process(_delta: float) -> void:
	map_display.queue_redraw()

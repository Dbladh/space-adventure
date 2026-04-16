extends Control

# GalaxyMapUI.gd
# Managed by THE ARCHITECT.
# Provides a real-time tactical overview of the procedural galaxy.

var is_fullscreen: bool = false
var base_map_size: Vector2 = Vector2(480, 480) # ACE: 2x HUD Scale (480 vs 240)
var max_range: float = 25000000.0 # 25,000 km view range

func _ready() -> void:
	custom_minimum_size = base_map_size
	set_process(true)
	
	# Initial fetch of all planets in the galaxy
	planets = get_tree().get_nodes_in_group("Planet")

func _draw() -> void:
	# ACE: Sync map_size to the actual Control size
	var cur_map_size = size
	
	# 1. BACKGROUND: Deep charcoal disc with subtle grid
	var center = cur_map_size / 2.0
	draw_circle(center, cur_map_size.x / 2.0, Color(0.05, 0.05, 0.05, 0.9 if is_fullscreen else 0.8))
	draw_arc(center, cur_map_size.x / 2.0, 0, TAU, 64, Color(0.4, 1.0, 0.2, 0.5), 3.0)
	
	# Grid Lines
	for i in range(1, 5):
		var r = (cur_map_size.x / 2.0) * (float(i) / 4.0)
		draw_arc(center, r, 0, TAU, 48, Color(1, 1, 1, 0.08), 1.0)

	# 2. PLANET PROJECTIONS: XZ plane top-down
	for p in planets:
		if not is_instance_valid(p): continue
		
		var raw_pos = p.global_position
		# Map to UI space: Scale world meters to map pixels
		var ui_pos = _world_to_map(raw_pos, cur_map_size)
		
		# Draw planet dot with its approximate color
		var col = p.get("sky_horizon_color") if "sky_horizon_color" in p else Color.AQUA
		# ACE: Larger, better-defined planet markers
		draw_circle(ui_pos, 10.0 if is_fullscreen else 7.0, col)
		draw_arc(ui_pos, 12.0 if is_fullscreen else 9.0, 0, TAU, 16, Color(1,1,1,0.3), 1.0)
		
		# Planet Name (ONLY in Fullscreen Strategic Mode)
		if is_fullscreen:
			var font = ThemeDB.get_fallback_font()
			var p_name = p.name.replace("Planet_", "")
			draw_string(font, ui_pos + Vector2(16, 6), p_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)

	# 3. PLAYER SYNC
	if not player_node:
		var players = get_tree().get_nodes_in_group("Player")
		if players.size() > 0: player_node = players[0]
	
	if player_node:
		var p_ui = _world_to_map(player_node.global_position, cur_map_size)
		
		# ACE: Pulsing Player Indicator
		var pulse = (sin(Time.get_ticks_msec() * 0.008) + 1.0) * 0.5
		var p_col = Color.CHARTREUSE.lerp(Color.WHITE, pulse * 0.4)
		
		# Player Target Ring
		var ring_r = 24.0 if is_fullscreen else 16.0
		draw_arc(p_ui, ring_r + pulse * 6.0, 0, TAU, 32, p_col, 3.0)
		
		# Draw player as a LARGE bright triangle
		var p_size = 18.0 if is_fullscreen else 12.0
		var pts = PackedVector2Array([
			p_ui + Vector2(0, -p_size),
			p_ui + Vector2(p_size * 0.7, p_size * 0.7),
			p_ui + Vector2(-p_size * 0.7, p_size * 0.7)
		])
		# Rotate based on player look dir (XZ only)
		var ang = -player_node.rotation.y
		for i in range(pts.size()):
			pts[i] = (pts[i] - p_ui).rotated(ang) + p_ui
			
		draw_colored_polygon(pts, p_col)
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color.BLACK, 2.0)

func _world_to_map(world_pos: Vector3, cur_map_size: Vector2) -> Vector2:
	var center = cur_map_size / 2.0
	# Top-down projection: Z is deep, X is lateral
	var rel = Vector2(world_pos.x, world_pos.z)
	var scaled = rel / max_range * (cur_map_size.x / 2.0)
	# Clamp to map bounds
	if scaled.length() > cur_map_size.x / 2.0:
		scaled = scaled.normalized() * (cur_map_size.x / 2.0)
	return center + scaled

func _process(_delta: float) -> void:
	# Keep planets list updated if new ones spawn
	if Engine.get_frames_drawn() % 60 == 0:
		planets = get_tree().get_nodes_in_group("Planet")
	
	queue_redraw()

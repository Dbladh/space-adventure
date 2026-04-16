extends Control

# GalaxyMapUI.gd
# Managed by THE ARCHITECT.
# Provides a real-time tactical overview of the procedural galaxy.

var is_fullscreen: bool = false
var player_node: Node3D = null
var planets: Array = []
var enemies: Array = []
var base_map_size: Vector2 = Vector2(480, 480)
var max_range: float = 6250000.0 # ACE: 4x Total Zoom (6,250 km tactical range)

func _ready() -> void:
	custom_minimum_size = base_map_size
	size = base_map_size
	set_process(true)
	
	# Initial fetch of all planets in the galaxy
	planets = get_tree().get_nodes_in_group("Planet")
	enemies = get_tree().get_nodes_in_group("Enemy")

func _draw() -> void:
	# ACE: Sync map_size to the actual Control size, fallback to base if not yet layouted
	var cur_map_size = size if size.x > 1.0 else base_map_size
	
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
		# ACE: Extreme Scale Upgrade for planet visibility (4x)
		var p_r = 30.0 if is_fullscreen else 22.0
		var col = Color.SKY_BLUE # ACE: Standardized tactical blue for all celestial bodies
		draw_circle(ui_pos, p_r, col)
		draw_arc(ui_pos, p_r + 4.0, 0, TAU, 16, Color(1,1,1,0.3), 2.0)
		
		# Planet Name (ONLY in Fullscreen Strategic Mode)
		if is_fullscreen:
			var font = ThemeDB.get_fallback_font()
			var p_name = p.name.replace("Planet_", "")
			draw_string(font, ui_pos + Vector2(p_r + 15, 12), p_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 48, Color.WHITE)

	# 3. PLAYER SYNC
	if not player_node:
		var players = get_tree().get_nodes_in_group("Player")
		if players.size() > 0: player_node = players[0]
	
	if player_node:
		var p_ui = cur_map_size / 2.0 # ACE: Player is ALWAYS centered in the strategic display
		
		# ACE: Pulsing Player Indicator
		var pulse = (sin(Time.get_ticks_msec() * 0.008) + 1.0) * 0.5
		var p_col = Color.CHARTREUSE.lerp(Color.WHITE, pulse * 0.4)
		
		# Player Target Ring
		var ring_r = 40.0 if is_fullscreen else 28.0
		draw_arc(p_ui, ring_r + pulse * 10.0, 0, TAU, 32, p_col, 4.0)
		
		# Draw player as a MASSIVE bright triangle (2x Scale Upgrade)
		var p_size = 40.0 if is_fullscreen else 28.0
		var pts = PackedVector2Array([
			p_ui + Vector2(0, -p_size * 1.2),
			p_ui + Vector2(p_size, p_size),
			p_ui + Vector2(-p_size, p_size)
		])
		# Rotate based on player look dir (XZ only)
		# ACE: We rotate the player marker relative to the map's UP (North)
		# But since the map is top-down (XZ), we use the player's world rotation.
		var ang = -player_node.rotation.y
		for i in range(pts.size()):
			pts[i] = (pts[i] - p_ui).rotated(ang) + p_ui
			
		draw_colored_polygon(pts, p_col)
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color.BLACK, 2.0)

	# 4. ENEMY TRACKING (Tactical Diamond Markers)
	for e in enemies:
		if is_instance_valid(e):
			var e_ui = _world_to_map(e.global_position, cur_map_size)
			# Draw small red diamonds for bogeys
			var d_size = 10.0
			var d_pts = PackedVector2Array([
				e_ui + Vector2(0, -d_size),
				e_ui + Vector2(d_size, 0),
				e_ui + Vector2(0, d_size),
				e_ui + Vector2(-d_size, 0)
			])
			draw_colored_polygon(d_pts, Color.CRIMSON)
			draw_polyline(d_pts + PackedVector2Array([d_pts[0]]), Color.BLACK, 1.0)

func _world_to_map(world_pos: Vector3, cur_map_size: Vector2) -> Vector2:
	var center = cur_map_size / 2.0
	
	# ACE: PLAYER-CENTRIC PROJECTION
	# All points are relative to the player's current position
	var p_pos = player_node.global_position if player_node else Vector3.ZERO
	var rel_3d = world_pos - p_pos
	
	# Top-down projection: Z is deep, X is lateral
	var rel = Vector2(rel_3d.x, rel_3d.z)
	var scaled = rel / max_range * (cur_map_size.x / 2.0)
	
	# CLAMPING: Distant planets stay at the edge to show direction
	if scaled.length() > cur_map_size.x * 0.45: # Pinned slightly inside the border
		scaled = scaled.normalized() * (cur_map_size.x * 0.45)
		
	return center + scaled

func _process(_delta: float) -> void:
	# Keep planets list updated if new ones spawn
	if Engine.get_frames_drawn() % 60 == 0:
		planets = get_tree().get_nodes_in_group("Planet")
	
	queue_redraw()

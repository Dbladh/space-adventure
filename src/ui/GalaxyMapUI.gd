extends Control

# GalaxyMapUI.gd
# Managed by THE ARCHITECT.
# Tactical galaxy overview — compact icons, high contrast player marker.
# process_mode = ALWAYS so the map stays live while the tree is paused.

var is_fullscreen: bool = false
var player_node: Node3D = null
var planets: Array = []
var enemies: Array = []
var stations: Array = []
var base_map_size: Vector2 = Vector2(480, 480)
var max_range: float = 6250000.0  # 6,250 km tactical range

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	custom_minimum_size = base_map_size
	size = base_map_size
	set_process(true)
	planets = get_tree().get_nodes_in_group("Planet")
	enemies = get_tree().get_nodes_in_group("Enemy")
	stations = get_tree().get_nodes_in_group("SpaceStation")

func _draw() -> void:
	var ms   = size if size.x > 1.0 else base_map_size
	var cen  = ms / 2.0
	var rad  = ms.x / 2.0

	# ── Background disc ──────────────────────────────────────────────
	draw_circle(cen, rad, Color(0.05, 0.06, 0.10, 0.92))

	# Subtle grid rings
	for i in range(1, 5):
		draw_arc(cen, rad * (float(i) / 4.0), 0, TAU, 48, Color(1, 1, 1, 0.06), 1.0)

	# Outer border
	draw_arc(cen, rad - 1.5, 0, TAU, 64, Color(0.35, 0.68, 0.78, 0.55), 2.5)

	# ── Planet dots ──────────────────────────────────────────────────
	for p in planets:
		if not is_instance_valid(p): continue
		var ui_pos = _world_to_map(p.global_position, ms)

		# Compact dot: 10px in pause map, 8px in mini-map corner
		var p_r   = 10.0 if is_fullscreen else 8.0
		var p_col = Color(0.45, 0.75, 0.95, 0.85)   # soft sky-blue
		draw_circle(ui_pos, p_r, p_col)
		draw_arc(ui_pos, p_r + 2.5, 0, TAU, 16, Color(1, 1, 1, 0.20), 1.5)

		# Planet name: only in pause/fullscreen map, smaller font
		if is_fullscreen:
			var font = ThemeDB.get_fallback_font()
			var p_name = p.name.replace("Planet_", "")
			draw_string(font, ui_pos + Vector2(p_r + 6, 8),
				p_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color.WHITE)

	# ── Space Stations (star markers) ──────────────────────────────────
	for s in stations:
		if not is_instance_valid(s): continue
		var ui_pos = _world_to_map(s.global_position, ms)

		# Render as a 6-pointed star in gold
		var s_r = 12.0 if is_fullscreen else 9.0
		var s_col = Color(0.95, 0.85, 0.2, 0.9)  # gold
		_draw_star(ui_pos, s_r, s_col)

		# Station name: only in pause/fullscreen map
		if is_fullscreen:
			var font = ThemeDB.get_fallback_font()
			var s_name = s.name.replace("SpaceStation_", "")
			draw_string(font, ui_pos + Vector2(s_r + 6, 8),
				s_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 22, Color(0.95, 0.85, 0.2))

	# ── Player ───────────────────────────────────────────────────────
	if not player_node:
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: player_node = found[0]

	if player_node:
		var p_ui = cen   # player always at centre of its own map

		# Bright pulsing ring so the player is easy to spot
		var pulse = (sin(Time.get_ticks_msec() * 0.008) + 1.0) * 0.5
		var ring_r = 18.0 if is_fullscreen else 14.0
		draw_arc(p_ui, ring_r + pulse * 4.0, 0, TAU, 32,
			Color(0.25, 1.0, 0.5, 0.9), 2.5)

		# Compact bright triangle for heading direction
		var p_size = 16.0 if is_fullscreen else 12.0
		var pts    = PackedVector2Array([
			p_ui + Vector2(0,       -p_size * 1.3),
			p_ui + Vector2( p_size,  p_size * 0.7),
			p_ui + Vector2(-p_size,  p_size * 0.7)
		])
		var ang = -player_node.rotation.y
		for i in range(pts.size()):
			pts[i] = (pts[i] - p_ui).rotated(ang) + p_ui

		draw_colored_polygon(pts, Color(0.25, 1.0, 0.5, 1.0))
		draw_polyline(pts + PackedVector2Array([pts[0]]), Color(0, 0, 0, 0.6), 1.5)

	# ── Enemy diamonds ───────────────────────────────────────────────
	for e in enemies:
		if not is_instance_valid(e): continue
		var e_ui   = _world_to_map(e.global_position, ms)
		var d_size = 7.0
		var d_pts  = PackedVector2Array([
			e_ui + Vector2(0, -d_size),
			e_ui + Vector2(d_size, 0),
			e_ui + Vector2(0, d_size),
			e_ui + Vector2(-d_size, 0)
		])
		draw_colored_polygon(d_pts, Color(0.9, 0.2, 0.2, 0.85))
		draw_polyline(d_pts + PackedVector2Array([d_pts[0]]), Color.BLACK, 1.0)

func _world_to_map(world_pos: Vector3, ms: Vector2) -> Vector2:
	var cen   = ms / 2.0
	var p_pos = player_node.global_position if player_node else Vector3.ZERO
	var rel   = Vector2(world_pos.x - p_pos.x, world_pos.z - p_pos.z)
	var scaled = rel / max_range * (ms.x / 2.0)
	if scaled.length() > ms.x * 0.44:
		scaled = scaled.normalized() * (ms.x * 0.44)
	return cen + scaled

func _draw_star(center: Vector2, radius: float, color: Color) -> void:
	var points = PackedVector2Array()
	for i in range(12):
		var angle = (i * TAU / 12.0) - TAU / 4.0
		var dist = radius if i % 2 == 0 else radius * 0.5
		points.append(center + Vector2(cos(angle), sin(angle)) * dist)
	draw_colored_polygon(points, color)
	draw_polyline(points + PackedVector2Array([points[0]]), Color.BLACK, 1.0)

func _process(_delta: float) -> void:
	if Engine.get_frames_drawn() % 60 == 0:
		planets = get_tree().get_nodes_in_group("Planet")
		enemies = get_tree().get_nodes_in_group("Enemy")
		stations = get_tree().get_nodes_in_group("SpaceStation")
	queue_redraw()

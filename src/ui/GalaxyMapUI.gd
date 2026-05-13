extends Control

# GalaxyMapUI.gd
# Managed by THE ARCHITECT.
# Tactical galaxy overview — compact icons, high contrast player marker.
# process_mode = ALWAYS so the map stays live while the tree is paused.

const HUDStyle := preload("res://src/ui/HUDStyle.gd")

# Bezel ring (in pixels) painted around the radar disc — gives the map a
# chunky beveled frame in the same arcade style as the rest of the chrome.
const BEZEL_PAD: float = 14.0

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
	var rad  = ms.x / 2.0 - BEZEL_PAD

	# ── Beveled bezel — chunky deep-navy frame around the CRT-green disc.
	#    Top-left highlight + bottom-right shadow gives it the same raised
	#    look as the menu buttons.
	draw_circle(cen, rad + BEZEL_PAD, HUDStyle.BG_DEEP_NAVY)
	# Top-left highlight arc
	draw_arc(cen, rad + BEZEL_PAD - 2.0, PI * 0.75, PI * 1.75, 32,
		HUDStyle.BG_DEEP_NAVY.lightened(0.45), 4.0)
	# Bottom-right shadow arc
	draw_arc(cen, rad + BEZEL_PAD - 2.0, -PI * 0.25, PI * 0.75, 32,
		HUDStyle.BG_DEEP_NAVY.darkened(0.45), 4.0)

	# ── CRT-green tactical disc ──────────────────────────────────────
	draw_circle(cen, rad, HUDStyle.CRT_GREEN_BG)
	var ink: Color = HUDStyle.CRT_GREEN_INK
	var faint: Color = Color(ink.r, ink.g, ink.b, 0.30)

	# Grid rings drawn in dark CRT ink so they read as engraved on the
	# bright-green screen surface.
	for i in range(1, 5):
		draw_arc(cen, rad * (float(i) / 4.0), 0, TAU, 48, faint, 1.0)

	# Inner border at the edge of the screen surface.
	draw_arc(cen, rad - 1.5, 0, TAU, 64, HUDStyle.CRT_GREEN_BORDER, 2.5)

	# ── Planet dots — solid CRT-ink so they pop against the green ────
	for p in planets:
		if not is_instance_valid(p): continue
		var ui_pos = _world_to_map(p.global_position, ms)

		var p_r   = 10.0 if is_fullscreen else 8.0
		draw_circle(ui_pos, p_r, ink)
		draw_arc(ui_pos, p_r + 2.5, 0, TAU, 16, faint, 1.5)

		if is_fullscreen:
			var p_name = p.name.replace("Planet_", "").to_upper()
			draw_string(HUDStyle.PIXEL_FONT, ui_pos + Vector2(p_r + 6, 6),
				p_name, HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_SMALL, ink)

	# ── Space Stations — orange-gold star (tier-4 colour) ───────────────
	for s in stations:
		if not is_instance_valid(s): continue
		var ui_pos = _world_to_map(s.global_position, ms)

		var s_r = 12.0 if is_fullscreen else 9.0
		var s_col: Color = HUDStyle.TIER_COLOR_4
		_draw_star(ui_pos, s_r, s_col)

		if is_fullscreen:
			var s_name = s.name.replace("SpaceStation_", "").to_upper()
			draw_string(HUDStyle.PIXEL_FONT, ui_pos + Vector2(s_r + 6, 6),
				s_name, HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_SMALL, s_col.darkened(0.25))

	# ── Player ───────────────────────────────────────────────────────
	if not player_node:
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: player_node = found[0]

	if player_node:
		var p_ui = cen   # player always at centre of its own map

		# Bright pink pulsing ring — stands out on the CRT green.
		var pulse = (sin(Time.get_ticks_msec() * 0.008) + 1.0) * 0.5
		var ring_r = 18.0 if is_fullscreen else 14.0
		draw_arc(p_ui, ring_r + pulse * 4.0, 0, TAU, 32, HUDStyle.BTN_PINK, 2.5)

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

		draw_colored_polygon(pts, HUDStyle.BTN_PINK)
		draw_polyline(pts + PackedVector2Array([pts[0]]), ink, 1.5)

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
		draw_colored_polygon(d_pts, HUDStyle.BTN_RED)
		draw_polyline(d_pts + PackedVector2Array([d_pts[0]]), ink, 1.0)

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

extends Control

# ScreenPOIHUD.gd
# NMS-style screen-space POI markers for space stations and planets.
#   • On-screen target  → icon at projected world position (fixed pixel size)
#   • Off-screen target → icon clamped to screen edge + arrow pointing inward
#   • Occluded by planet → dimmed icon with dashed border and "(behind)" tag
# Added to the HUD CanvasLayer in Main.gd.

const ICON_R    = 16.0   # hexagon / circle icon radius (px) — was 22, slimmed
const MARGIN    = 64.0   # screen-edge margin for clamped icons
const FONT_SZ   = 11     # was 13 — keeps the POI bar from dominating the top
const FONT_SM   = 9      # was 10
const LABEL_BG_PAD_X = 4.0
const LABEL_BG_PAD_Y = 1.0

var _camera: Camera3D = null
var _player: Node3D   = null
var _font: Font        = null
var _pois: Array       = []   # Array[{node, label, color, type}]
var _tick: int         = 0

func _ready() -> void:
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_preset(PRESET_FULL_RECT)
	_font = ThemeDB.get_fallback_font()
	set_process(true)
	_refresh_pois()

func _process(_delta: float) -> void:
	_tick = (_tick + 1) % 90
	if _tick == 0:
		_refresh_pois()
	if not _camera:
		_camera = get_viewport().get_camera_3d()
		if not _camera:
			# Fallback: walk the tree for any active Camera3D
			var cams = get_tree().get_nodes_in_group("Player")
			for c in cams:
				var cam = _find_camera(c)
				if cam: _camera = cam; break
	if not _player:
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: _player = found[0]
	queue_redraw()

func _find_camera(node: Node) -> Camera3D:
	if node is Camera3D: return node
	for child in node.get_children():
		var result = _find_camera(child)
		if result: return result
	return null

func _refresh_pois() -> void:
	_pois.clear()
	for s in get_tree().get_nodes_in_group("SpaceStation"):
		if is_instance_valid(s):
			_pois.append({
				node = s,
				label = s.name.replace("SpaceStation_", ""),
				color = Color(0.3, 0.82, 1.0),
				type = "station"
			})
	for p in get_tree().get_nodes_in_group("Planet"):
		if is_instance_valid(p):
			_pois.append({
				node = p,
				label = p.name.replace("Planet_", ""),
				color = Color(0.55, 0.88, 0.55),
				type = "planet"
			})

# ---------------------------------------------------------------------------
func _draw() -> void:
	if not _camera or not _player: return
	# Use viewport rect — get_rect().size is (0,0) when Control has no explicit size
	var vp = get_viewport_rect().size
	if vp.x < 2.0: return

	var planets = get_tree().get_nodes_in_group("Planet")
	var pulse   = (sin(Time.get_ticks_msec() * 0.0022) + 1.0) * 0.5

	for poi in _pois:
		if not is_instance_valid(poi.node): continue

		var wpos: Vector3  = poi.node.global_position
		var dist: float    = _player.global_position.distance_to(wpos)

		# ── Occlusion: ray-sphere test against every planet ──────────────
		var occluded := false
		if poi.type != "planet":
			var to_poi   = wpos - _player.global_position
			var to_dist  = to_poi.length()
			var to_dir   = to_poi / max(to_dist, 1.0)
			for planet in planets:
				if not is_instance_valid(planet) or planet == poi.node: continue
				var pr: float = float(planet.get("planet_radius")) if planet.get("planet_radius") != null else 1_000_000.0
				var to_p = planet.global_position - _player.global_position
				var proj = to_dir.dot(to_p)
				if proj > 0.0 and proj < to_dist:
					if (to_p - to_dir * proj).length() < pr:
						occluded = true
						break

		# ── Project world position to screen ─────────────────────────────
		var behind    := _camera.is_position_behind(wpos)
		var spos: Vector2
		var on_screen := false
		if not behind:
			spos      = _camera.unproject_position(wpos)
			on_screen = spos.x > MARGIN and spos.x < vp.x - MARGIN \
					and spos.y > MARGIN and spos.y < vp.y - MARGIN

		var at_edge := not on_screen
		if at_edge:
			spos = _clamp_to_edge(wpos, vp, behind)

		# ── Draw ─────────────────────────────────────────────────────────
		var alpha: float = 0.5 if occluded else 1.0
		var col := Color(poi.color.r, poi.color.g, poi.color.b, alpha)

		_draw_icon(spos, col, poi.type, at_edge, occluded, pulse)

		if at_edge:
			_draw_edge_arrow(spos, (spos - vp * 0.5).normalized(), col)

		# Labels — wrapped in a slim dark backing so each POI reads as its
		# own small chip rather than as bright text floating in the sky.
		var label_text: String = poi.label.to_upper()
		var dist_text: String = _fmt_dist(dist)
		var ly: float = spos.y + ICON_R + 4.0
		var label_size: Vector2 = _font.get_string_size(label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SZ)
		var dist_size: Vector2 = _font.get_string_size(dist_text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SM)
		var chip_w: float = max(label_size.x, dist_size.x) + LABEL_BG_PAD_X * 2.0
		var chip_h: float = FONT_SZ + FONT_SM + LABEL_BG_PAD_Y * 3.0 + 3.0
		var chip_pos: Vector2 = Vector2(spos.x - chip_w * 0.5, ly)
		draw_rect(Rect2(chip_pos, Vector2(chip_w, chip_h)), Color(0.0, 0.0, 0.0, 0.55 * alpha))
		draw_rect(Rect2(chip_pos, Vector2(chip_w, chip_h)), Color(col.r, col.g, col.b, 0.6 * alpha), false, 1.0)
		var text_x: float = chip_pos.x + LABEL_BG_PAD_X
		var text_y: float = chip_pos.y + LABEL_BG_PAD_Y + FONT_SZ
		draw_string(_font, Vector2(text_x, text_y),
			label_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SZ,
			Color(1.0, 1.0, 1.0, alpha))
		draw_string(_font, Vector2(text_x, text_y + FONT_SM + 2.0),
			dist_text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SM,
			Color(col.r, col.g, col.b, alpha * 0.9))
		if occluded:
			draw_string(_font, Vector2(text_x, text_y + FONT_SM * 2 + 4.0),
				"(behind planet)",
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SM - 1,
				Color(0.75, 0.75, 0.75, 0.6))

# ---------------------------------------------------------------------------
func _clamp_to_edge(wpos: Vector3, vp: Vector2, behind: bool) -> Vector2:
	# vp is already get_viewport_rect().size passed in from _draw()
	var cen  = vp * 0.5
	var raw: Vector2
	if behind:
		raw = vp - _camera.unproject_position(wpos)
	else:
		raw = _camera.unproject_position(wpos)
	var dir = raw - cen
	if dir.length_squared() < 1.0: dir = Vector2(0.0, -1.0)
	dir = dir.normalized()
	var mx = (vp.x * 0.5 - MARGIN) / max(abs(dir.x), 0.0001)
	var my = (vp.y * 0.5 - MARGIN) / max(abs(dir.y), 0.0001)
	return cen + dir * min(mx, my)

func _draw_icon(center: Vector2, color: Color, type: String, at_edge: bool, occluded: bool, pulse: float) -> void:
	if type == "station":
		# Hexagonal station icon (filled on-screen, outline at edge/occluded)
		var pts := PackedVector2Array()
		for i in range(6):
			var a = i * TAU / 6.0 - TAU / 12.0
			pts.append(center + Vector2(cos(a), sin(a)) * ICON_R)
		var poly_pts = pts + PackedVector2Array([pts[0]])
		if not at_edge and not occluded:
			draw_colored_polygon(pts, Color(color.r, color.g, color.b, 0.22))
		if occluded:
			# Dashed border: alternate gap every segment
			for i in range(6):
				if i % 2 == 0:
					draw_line(pts[i], pts[(i + 1) % 6], color, 2.0)
		else:
			draw_polyline(poly_pts, color, 2.5)
		# Inner "S" symbol
		draw_string(_font, center + Vector2(-5.0, 5.5), "S",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)
	else:
		# Circular planet icon with orbit arc hints
		var inner_alpha := 0.28 if (at_edge or occluded) else 0.55
		draw_circle(center, ICON_R * 0.62, Color(color.r, color.g, color.b, inner_alpha))
		draw_arc(center, ICON_R, 0.0, TAU, 36, color, 2.5)
		if not at_edge and not occluded:
			# Animated orbit ring
			var ring_a := pulse * TAU
			draw_arc(center, ICON_R + 6.0, ring_a - 0.55, ring_a + 0.55, 10,
				Color(color.r, color.g, color.b, 0.55), 1.5)
			draw_arc(center, ICON_R + 6.0, ring_a + PI - 0.55, ring_a + PI + 0.55, 10,
				Color(color.r, color.g, color.b, 0.55), 1.5)

func _draw_edge_arrow(pos: Vector2, dir: Vector2, color: Color) -> void:
	var perp   = Vector2(-dir.y, dir.x)
	var sz     = 10.0
	var tip    = pos + dir * (ICON_R + sz + 2.0)
	var base_l = pos + dir * ICON_R + perp * sz * 0.65
	var base_r = pos + dir * ICON_R - perp * sz * 0.65
	draw_colored_polygon(PackedVector2Array([tip, base_l, base_r]), color)

func _fmt_dist(dist: float) -> String:
	if dist > 1_000_000.0: return "%.1f Mm" % (dist / 1_000_000.0)
	if dist > 1_000.0:     return "%.1f km" % (dist / 1_000.0)
	return "%.0f m" % dist

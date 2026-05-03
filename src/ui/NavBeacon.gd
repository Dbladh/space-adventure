extends Control

# NavBeacon.gd
# Tactical navigation overlay showing nearest friendly facility (space station)
# Displays bearing, distance, and station name in a compact corner widget

var player_node: Node3D = null
var nearest_station: Node3D = null
var font: Font = null

func _ready() -> void:
	set_process(true)
	font = ThemeDB.get_fallback_font()

func _process(_delta: float) -> void:
	var stations = get_tree().get_nodes_in_group("SpaceStation")

	if not player_node and get_tree().get_nodes_in_group("Player").size() > 0:
		player_node = get_tree().get_nodes_in_group("Player")[0]

	# Find nearest station
	if player_node:
		nearest_station = null
		var min_dist = 1e10
		for s in stations:
			if is_instance_valid(s):
				var dist = player_node.global_position.distance_to(s.global_position)
				if dist < min_dist:
					min_dist = dist
					nearest_station = s

	queue_redraw()

func _draw() -> void:
	if not player_node or not nearest_station:
		return

	var size = get_rect().size
	var center = size / 2.0

	# Calculate bearing and distance
	var to_station = nearest_station.global_position - player_node.global_position
	var dist = to_station.length()
	var bearing = atan2(to_station.x, to_station.z) - player_node.rotation.y

	# Background panel
	var panel_rect = Rect2(0, 0, 195, 78)
	var panel = StyleBoxFlat.new()
	panel.bg_color = Color(0.04, 0.04, 0.10, 0.82)
	panel.set_border_width_all(1)
	panel.border_color = Color(0.95, 0.85, 0.2, 0.55)
	panel.set_corner_radius_all(4)
	draw_style_box(panel, panel_rect)

	# Station name (gold header)
	var s_name = nearest_station.name.replace("SpaceStation_", "")
	draw_string(font, Vector2(10, 18), s_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.95, 0.85, 0.2))

	# Distance
	var dist_str = ""
	if dist > 1000000.0:
		dist_str = "%.1f Mm" % (dist / 1000000.0)
	elif dist > 1000.0:
		dist_str = "%.1f km" % (dist / 1000.0)
	else:
		dist_str = "%.0f m" % dist
	draw_string(font, Vector2(10, 36), dist_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.90, 1.0))

	# Bearing text
	var bearing_deg = rad_to_deg(bearing)
	while bearing_deg < 0: bearing_deg += 360.0
	while bearing_deg >= 360.0: bearing_deg -= 360.0
	draw_string(font, Vector2(10, 52), "%.0f°" % bearing_deg, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)

	# Directional arrow (right side of panel)
	var arrow_center = Vector2(168, 38)
	var arrow_angle = bearing
	var arrow_pts = PackedVector2Array([
		arrow_center + Vector2(0, -10).rotated(arrow_angle),
		arrow_center + Vector2(-6, 6).rotated(arrow_angle),
		arrow_center + Vector2(6, 6).rotated(arrow_angle)
	])
	draw_colored_polygon(arrow_pts, Color(0.95, 0.85, 0.2))
	draw_arc(arrow_center, 13, 0, TAU, 20, Color(0.95, 0.85, 0.2, 0.3), 1.0)

	# "STA" label under arrow
	draw_string(font, Vector2(156, 66), "STA", HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(0.95, 0.85, 0.2, 0.7))

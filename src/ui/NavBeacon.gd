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
	var panel_rect = Rect2(5, 5, 180, 80)
	var panel = StyleBoxFlat.new()
	panel.bg_color = Color(0.05, 0.05, 0.1, 0.8)
	panel.set_border_width_all(1)
	panel.border_color = Color(0.95, 0.85, 0.2, 0.6)
	draw_style_box(panel, panel_rect)

	# Station name
	var s_name = nearest_station.name.replace("SpaceStation_", "")
	draw_string(font, Vector2(15, 22), s_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.95, 0.85, 0.2))

	# Distance display
	var dist_str = ""
	if dist > 1000000.0:
		dist_str = "%.1f Mm" % (dist / 1000000.0)
	elif dist > 1000.0:
		dist_str = "%.1f km" % (dist / 1000.0)
	else:
		dist_str = "%.0f m" % dist
	draw_string(font, Vector2(15, 40), "Distance: " + dist_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)

	# Bearing indicator (compass-like)
	var bearing_deg = rad_to_deg(bearing)
	while bearing_deg < 0: bearing_deg += 360.0
	while bearing_deg >= 360.0: bearing_deg -= 360.0

	draw_string(font, Vector2(15, 56), "Bearing: %.0f°" % bearing_deg, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)

	# Small directional arrow
	var arrow_center = Vector2(150, 35)
	var arrow_angle = bearing
	var arrow_pts = PackedVector2Array([
		arrow_center + Vector2(0, -8).rotated(arrow_angle),
		arrow_center + Vector2(-5, 5).rotated(arrow_angle),
		arrow_center + Vector2(5, 5).rotated(arrow_angle)
	])
	draw_colored_polygon(arrow_pts, Color(0.95, 0.85, 0.2))

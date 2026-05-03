extends Node3D

# POIMarker.gd
# Floating billboard label + visual beacon for points of interest.
# Attach as a child of any world node (SpaceStation, Planet, etc.)
# and call setup() to configure it.

var poi_name: String = ""
var poi_type: String = "station"   # "station" | "planet"
var label_height: float = 200000.0  # local Y offset above the parent origin
var beacon_color: Color = Color(0.95, 0.85, 0.2)

var _label: Label3D = null
var _beacon_ring: MeshInstance3D = null
var _beacon_light: OmniLight3D = null
var _player: Node3D = null
var _pulse_t: float = 0.0

func setup(p_name: String, p_type: String, height: float, color: Color) -> void:
	poi_name = p_name
	poi_type = p_type
	label_height = height
	beacon_color = color

func _ready() -> void:
	_build_label()
	_build_beacon()
	set_process(true)

func _build_label() -> void:
	_label = Label3D.new()
	_label.text = poi_name
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.pixel_size = 350.0        # visible from millions of units away
	_label.font_size = 32
	_label.modulate = beacon_color
	_label.outline_size = 8
	_label.outline_modulate = Color.BLACK
	_label.position = Vector3(0, label_height, 0)
	_label.visibility_range_end = 0.0   # always visible (no cutoff)
	_label.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_label)

func _build_beacon() -> void:
	# Vertical glowing column — a thin tall cylinder in the beacon color
	var col_mesh = CylinderMesh.new()
	col_mesh.top_radius    = 800.0
	col_mesh.bottom_radius = 800.0
	col_mesh.height        = label_height
	col_mesh.radial_segments = 6

	var col_mat = StandardMaterial3D.new()
	col_mat.albedo_color = beacon_color
	col_mat.emission_enabled = true
	col_mat.emission = beacon_color
	col_mat.emission_energy_multiplier = 2.0
	col_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	col_mat.albedo_color.a = 0.35
	col_mesh.material = col_mat

	_beacon_ring = MeshInstance3D.new()
	_beacon_ring.mesh = col_mesh
	_beacon_ring.position = Vector3(0, label_height * 0.5, 0)
	_beacon_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beacon_ring)

	# Point light at label height so the beacon tip glows
	_beacon_light = OmniLight3D.new()
	_beacon_light.light_color = beacon_color
	_beacon_light.light_energy = 3.0
	_beacon_light.omni_range = label_height * 0.8
	_beacon_light.position = Vector3(0, label_height, 0)
	add_child(_beacon_light)

func _process(delta: float) -> void:
	_pulse_t += delta

	# Resolve player lazily
	if not _player:
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0:
			_player = found[0]

	# Update label with distance
	if _player and _label:
		var dist = global_position.distance_to(_player.global_position)
		var dist_str: String
		if dist > 1_000_000.0:
			dist_str = "%.1f Mm" % (dist / 1_000_000.0)
		elif dist > 1_000.0:
			dist_str = "%.1f km" % (dist / 1_000.0)
		else:
			dist_str = "%.0f m" % dist
		_label.text = poi_name + "\n" + dist_str

	# Pulse the beacon column alpha and light energy
	var pulse = (sin(_pulse_t * 1.8) + 1.0) * 0.5   # 0..1
	if _beacon_ring and _beacon_ring.mesh:
		var mat = _beacon_ring.mesh.material as StandardMaterial3D
		if mat:
			var c = beacon_color
			c.a = 0.15 + pulse * 0.35
			mat.albedo_color = c
			mat.emission_energy_multiplier = 1.2 + pulse * 2.5
	if _beacon_light:
		_beacon_light.light_energy = 2.0 + pulse * 4.0

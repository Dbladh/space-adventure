extends Node3D

# POIMarker.gd
# Floating billboard label + visual beacon for points of interest.
# Attach as a child of any world node (SpaceStation, Planet, etc.)
# and call setup() to configure it.

var poi_name: String = ""
var poi_type: String = "station"   # "station" | "planet"
var label_height: float = 200000.0  # total height of marker (planet_radius * 1.4)
var planet_radius: float = 0.0      # surface radius — cylinder sits *above* this
var beacon_color: Color = Color(0.95, 0.85, 0.2)

var _beacon_ring: MeshInstance3D = null
var _beacon_light: OmniLight3D = null
var _pulse_t: float = 0.0

func setup(p_name: String, p_type: String, height: float, color: Color, p_radius: float = 0.0) -> void:
	poi_name = p_name
	poi_type = p_type
	label_height = height
	beacon_color = color
	# Backward-compat: callers that don't pass p_radius get the old behaviour
	# of `radius = height / 1.4` (PlanetGen sets height = planet_radius * 1.4).
	planet_radius = p_radius if p_radius > 0.0 else height / 1.4

func _ready() -> void:
	_build_beacon()
	set_process(true)

func _build_beacon() -> void:
	# The cylinder must sit ENTIRELY above the planet's surface — if it
	# extends from the planet center (the old behaviour), the inside-planet
	# portion renders through transparent water/lava as hex-shaped artifacts
	# (the cylinder is a 6-sided prism; cross-sections look like circles or
	# diamonds depending on viewing angle).
	var visible_height: float = max(label_height - planet_radius, label_height * 0.25)

	var col_mesh = CylinderMesh.new()
	col_mesh.top_radius    = 800.0
	col_mesh.bottom_radius = 800.0
	col_mesh.height        = visible_height
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
	# Center the cylinder above the surface so its bottom edge meets the
	# planet at +Y pole and the top reaches label_height.
	_beacon_ring.position = Vector3(0, planet_radius + visible_height * 0.5, 0)
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

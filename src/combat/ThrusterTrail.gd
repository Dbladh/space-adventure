extends MeshInstance3D

# THOU SHALL BEND: World-Space Ribbon Generator
# maintains a buffer of points in world space to create a curving flight trail.

@export var max_points: int = 40
@export var trail_width: float = 2.0
@export var trail_color: Color = Color(1, 1, 1, 0.4)

var points: Array[Vector3] = []
var _v_tick: int = 0
var _last_v_update: bool = false
var mesh_gen: ImmediateMesh
var pulse_time: float = 0.0

func _ready() -> void:
	mesh_gen = ImmediateMesh.new()
	mesh = mesh_gen
	
	# Low-Poly Unshaded Emissive Material
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	material_override = mat
	
	# Important: Trails are world-space, so set top-level
	set_as_top_level(true)
	add_to_group("Trails")

# ARCHITECT SYNC: Called by FloatingOrigin to snap world points
func shift_points(offset: Vector3) -> void:
	for i in range(points.size()):
		points[i] -= offset

func update_trail(port_pos: Vector3, vel: Vector3, is_warping: bool, thrust: float, delta: float) -> void:
	# SHADOWGLASS 30FPS SYNC
	var v_t = int(Time.get_ticks_msec() / 33.33)
	var v_update = v_t != _v_tick
	if v_update: _v_tick = v_t
	_last_v_update = v_update
	
	pulse_time += delta
	# 1. DYNAMIC LENGTH: Stretch based on Warp/Speed
	var speed_ratio = clamp(vel.length() / 8000.0, 0.0, 1.0)
	var dynamic_max = 25 + int(speed_ratio * 85.0)
	if is_warping: dynamic_max = 120
	
	# 2. MOMENTUM INHERITANCE: Makes the trail 'float' and curve naturally
	# We move existing points with the ship's current frame of reference.
	var inherit_factor = 0.98 # high inheritance for stiff, directed look
	for i in range(points.size()):
		points[i] += vel * delta * inherit_factor
	
	points.push_front(port_pos)
	while points.size() > dynamic_max:
		points.pop_back()
	
	if points.size() < 2:
		mesh_gen.clear_surfaces()
		return
		
	if not _last_v_update: return
	mesh_gen.clear_surfaces()
	mesh_gen.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	
	var cam = get_viewport().get_camera_3d()
	if not cam: return
	
	# 3. IONIZED COLOR SHIFTING:
	# Transition from Ghostly White to High-Energy Cyan in Warp
	var base_c = trail_color
	if is_warping:
		base_c = Color(0.2, 0.9, 1.0, 0.7) # Ionized Cyan
	elif speed_ratio > 0.5:
		base_c = base_c.lerp(Color(0.8, 0.9, 1.0), speed_ratio)
	
	for i in range(points.size()):
		var ratio = float(i) / float(points.size())
		
		# IONIZED PULSE: Waves traveling down the ribbon
		var pulse = 1.0 + 0.2 * sin(pulse_time * 15.0 - ratio * 12.0)
		
		# Tapered Origin: ribbon emerges from the red light orb
		var alpha = (1.0 - ratio) * clamp(ratio * 4.0, 0.0, 1.0) * pulse
		
		# Taper width and alpha toward the end
		var w = trail_width * alpha * (1.0 + speed_ratio * 0.5)
		var c = base_c
		c.a *= alpha * thrust
		
		var p1 = points[i]
		var p2 = points[min(i + 1, points.size() - 1)]
		var segment_dir = (p1 - p2).normalized()
		if segment_dir.length() < 0.01: segment_dir = Vector3.FORWARD
		
		var to_cam = (p1 - cam.global_position).normalized()
		var side = segment_dir.cross(to_cam).normalized() * w
		
		# WARP JITTER: Violent vibration during high-speed travel
		if is_warping:
			var jitter = Vector3(randf()-0.5, randf()-0.5, randf()-0.5) * 0.4
			p1 += jitter
		
		mesh_gen.surface_set_color(c)
		mesh_gen.surface_add_vertex(p1 + side)
		mesh_gen.surface_add_vertex(p1 - side)
		
	mesh_gen.surface_end()

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
# MOBILE PERF: sampled in _ready so update_trail can clamp ribbon length/jitter.
var _mobile_perf: bool = false

func _ready() -> void:
	_mobile_perf = OS.get_name() == "iOS" or OS.has_feature("mobile")
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

func prewarm(port_pos: Vector3, fwd: Vector3) -> void:
	# Force the mesh generator path once during loading so the first real thrust
	# doesn't pay the ImmediateMesh / strip setup cost.
	if not mesh_gen:
		mesh_gen = ImmediateMesh.new()
		mesh = mesh_gen
	points.clear()
	points.push_back(port_pos)
	points.push_back(port_pos + fwd.normalized() * 12.0)
	update_trail(port_pos, fwd, Vector3.ZERO, false, 0.01, 0.0)
	points.clear()
	mesh_gen.clear_surfaces()

# ARCHITECT SYNC: Called by FloatingOrigin to snap world points
func shift_points(offset: Vector3) -> void:
	for i in range(points.size()):
		points[i] -= offset

func update_trail(port_pos: Vector3, fwd: Vector3, vel: Vector3, is_warping: bool, thrust: float, delta: float) -> void:
	# UNLOCKED RIBBONS: Update every frame for silky smoothness
	var v_update = true
	_last_v_update = v_update
	
	pulse_time += delta
	# 1. DYNAMIC LENGTH: Stretch based on Warp/Speed
	# MOBILE: Cap ribbon length — each point becomes 2 verts in a TRIANGLE_STRIP
	# and there are 5 trail ports. Desktop caps at 120 verts; mobile at 40.
	var speed_ratio = clamp(vel.length() / 8000.0, 0.0, 1.0)
	var dynamic_max: int
	if _mobile_perf:
		dynamic_max = 8 + int(speed_ratio * 12.0)   # 8-20 pts every frame ≈ same cost as 16-40 every other frame
		if is_warping: dynamic_max = 22
	else:
		dynamic_max = 25 + int(speed_ratio * 85.0)
		if is_warping: dynamic_max = 120
	
	# 2. MOMENTUM INHERITANCE: Makes the trail 'float' and curve naturally
	var inherit_factor = 0.98 
	for i in range(points.size()):
		points[i] += vel * delta * inherit_factor
	
	# 3. STIFF ORIGIN: Ensures the plume is straight at the source (12m plume depth)
	# This represents high-velocity ionized exhaust before it disperses.
	points.push_front(port_pos)
	if points.size() > 1:
		points[1] = port_pos + fwd * 12.0
	
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
		
		# WARP JITTER: Violent vibration during high-speed travel.
		# MOBILE: Skip jitter — keeps the warp ribbon stable and drops 3 randf()
		# calls per vertex (ribbon can hit 40 points × 5 trails while warping).
		if is_warping and not _mobile_perf:
			var jitter = Vector3(randf()-0.5, randf()-0.5, randf()-0.5) * 0.4
			p1 += jitter
		
		mesh_gen.surface_set_color(c)
		mesh_gen.surface_add_vertex(p1 + side)
		mesh_gen.surface_add_vertex(p1 - side)
		
	mesh_gen.surface_end()


extends Node3D

# AsteroidBelt.gd (LOD Optimization Edition)
# Managed by THE PROCEDURALIST.

@export var belt_seed: int = 9999
@export var mmi_count: int = 14000 
@export var phys_count: int = 500  
@export var inner_radius: float = 1400000.0
@export var outer_radius: float = 2000000.0
@export var thickness: float = 20000.0 

var rock_mesh_low: ArrayMesh
var rock_mesh_med: ArrayMesh
var rock_mesh_high: ArrayMesh

var asteroids: Array[StaticBody3D] = []
var coll_nodes: Array[CollisionShape3D] = []

var mmi_back: MultiMeshInstance3D # Distant Background (14k, Low Detail)
var mmi_phys_med: MultiMeshInstance3D # Intermediate Hazards (1.5k, Med Detail)
var mmi_phys_high: MultiMeshInstance3D # Near-Field 'Hero' Rocks (1.5k, High Detail)
var player: Node3D
var _health_component_script: Script = null
var mobile_perf: bool = false

# LOD CONSTANTS
const PHYSICS_LOD_DIST: float = 80000.0 # 80km - asteroids beyond this lose collision
const HIDE_LOD_DIST: float = 800000.0  # 800km - individual rocks hide and let MMI take over
const STELLAR_CUTOFF: float = 4000000.0 # 4,000km - Transition to deep space hibernation

var _spawn_idx: int = 0
var _is_spawning_phys: bool = true
var _rng: RandomNumberGenerator

func _ready() -> void:
	if mobile_perf:
		# MOBILE: Tighter caps for iPhone 12-class hardware. Each MMI instance
		# still costs per-frame transform I/O, and every phys rock is a
		# StaticBody3D with its own CollisionShape3D.
		mmi_count = min(mmi_count, 5000)
		phys_count = min(phys_count, 150)
	rock_mesh_low = _build_faceted_rock_mesh(4) # Pyramid / Minimal
	rock_mesh_med = _build_faceted_rock_mesh(8) # Standard
	rock_mesh_high = _build_faceted_rock_mesh(12) # High-Fidelity
	_health_component_script = load("res://src/combat/HealthComponent.gd")
	_spawn_deterministic_belt()
	set_process(true)
	
	var players = get_tree().get_nodes_in_group("Player")
	if players.size() > 0: player = players[0]

func _spawn_deterministic_belt() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = belt_seed
	
	# SHARED MATERIALS
	var mmi_mat = ShaderMaterial.new(); mmi_mat.shader = load("res://src/shaders/hatch_toon.gdshader")
	var phys_mat = ShaderMaterial.new(); phys_mat.shader = load("res://src/shaders/hatch_toon.gdshader")
	var outline_mat = ShaderMaterial.new(); outline_mat.shader = load("res://src/shaders/outline.gdshader")
	outline_mat.set_shader_parameter("outline_width", 1.5)
	outline_mat.set_shader_parameter("outline_color", Color.BLACK)
	mmi_mat.next_pass = outline_mat; phys_mat.next_pass = outline_mat
	
	# TIER 1: DISTANT IMPOSTOR RING (Low Poly, 14k)
	mmi_back = MultiMeshInstance3D.new()
	mmi_back.multimesh = MultiMesh.new()
	mmi_back.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi_back.multimesh.use_colors = true
	mmi_back.multimesh.instance_count = mmi_count
	mmi_back.multimesh.mesh = rock_mesh_low
	mmi_back.material_override = mmi_mat
	mmi_back.visibility_range_begin = 400000.0 # Only far
	add_child(mmi_back)
	
	# TIER 2 & 3: HAZARD SYSTEM (Med / High LOD)
	mmi_phys_med = MultiMeshInstance3D.new()
	mmi_phys_med.multimesh = MultiMesh.new(); mmi_phys_med.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi_phys_med.multimesh.instance_count = phys_count; mmi_phys_med.multimesh.mesh = rock_mesh_med
	mmi_phys_med.material_override = phys_mat
	# ACE: We disable engine culling/ranges for the hero pool to allow our manual LOD to take priority
	mmi_phys_med.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi_phys_med)
	
	mmi_phys_high = MultiMeshInstance3D.new()
	mmi_phys_high.multimesh = MultiMesh.new(); mmi_phys_high.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi_phys_high.multimesh.instance_count = phys_count; mmi_phys_high.multimesh.mesh = rock_mesh_high
	mmi_phys_high.material_override = phys_mat
	add_child(mmi_phys_high)

	# ACE: Set massive custom AABBs to prevent Godot from culling the MMIs when the 
	# player is millions of kilometers from the belt origin.
	var big_aabb = AABB(Vector3(-2e6, -5e4, -2e6), Vector3(4e6, 1e5, 4e6))
	mmi_back.custom_aabb = big_aabb
	mmi_phys_med.custom_aabb = big_aabb
	mmi_phys_high.custom_aabb = big_aabb

	# POPULATE SEEDS (Tier 1: Background Only)
	for i in range(mmi_count):
		var angle = _rng.randf() * TAU
		var dist = _rng.randf_range(inner_radius, outer_radius)
		var h = pow(_rng.randf_range(-1.0, 1.0), 3.0) * thickness 
		var xform = Transform3D().rotated(Vector3(_rng.randf(), _rng.randf(), _rng.randf()).normalized(), _rng.randf() * TAU)
		xform = xform.scaled(Vector3.ONE * (5.0 + pow(_rng.randf(), 2.0) * 120.0))
		xform.origin = Vector3(cos(angle) * dist, h, sin(angle) * dist)
		mmi_back.multimesh.set_instance_transform(i, xform)
		var inst_col = Color.from_hsv(0, 0, _rng.randf_range(0.2, 0.4))
		if _rng.randf() > 0.45: inst_col = Color.from_hsv(_rng.randf_range(0.04, 0.08), 0.4, _rng.randf_range(0.3, 0.5))
		mmi_back.multimesh.set_instance_color(i, inst_col)
	
	# ACE: We defer the Tiers 2 & 3 (1,500 physical rocks) to _process
	# to prevent the multi-second 'Spawn Freeze' reported by THE ARCHITECT.
	

var proc_idx: int = 0
const BATCH_SIZE: int = 32

func _process(delta: float) -> void:
	if _is_spawning_phys:
		_process_physical_spawning()
		return

	if not player: 
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: player = found[0]
		return

	var p_pos = player.global_position
	var dist_to_planet = p_pos.distance_to(global_position)
	
	# STELLAR HIBERNATION: Beyond 4,000km, we disable the individual rock loop.
	# Also, HIDE BELT if we are deep in the atmosphere (sub-250km altitude)
	if dist_to_planet < 1375000.0:
		if visible: hide()
		return
	elif not visible:
		show()
		
	if dist_to_planet > STELLAR_CUTOFF:
		return
	
	# PERFORMANCE: Update a smaller slice each frame so the belt LOD stays smooth
	# without turning per-frame visibility bookkeeping into a spike.
	# MOBILE: Tighter batch (16) — with a 30fps cap we have twice as much wall
	# time per frame but half as many frames per LOD sweep. 16/frame still
	# sweeps all 150 rocks in <10 frames.
	var final_batch = 16 if mobile_perf else (64 if dist_to_planet < 2200000.0 else 32)
	for k in range(final_batch):
		proc_idx = (proc_idx + 1) % asteroids.size()
		var a = asteroids[proc_idx]
		if not is_instance_valid(a): continue 
		
		var dist_sq = a.global_position.distance_squared_to(p_pos)
		var coll = coll_nodes[proc_idx]
		
		# MANUAL LOD STATE MACHINE
		if dist_sq < HIDE_LOD_DIST * HIDE_LOD_DIST:
			# SHOW LOGIC: Swapping between Med/High based on 12km threshold
			var use_high = dist_sq < 12000.0 * 12000.0
			
			mmi_phys_high.multimesh.set_instance_transform(proc_idx, a.transform if use_high else Transform3D().scaled(Vector3.ZERO))
			mmi_phys_med.multimesh.set_instance_transform(proc_idx, a.transform if not use_high else Transform3D().scaled(Vector3.ZERO))
			
			# PHYSICS LOD: Enable collision only within 80km
			coll.disabled = dist_sq > PHYSICS_LOD_DIST * PHYSICS_LOD_DIST
		else:
			# HIDE LOGIC: Too far to matter
			mmi_phys_med.multimesh.set_instance_transform(proc_idx, Transform3D().scaled(Vector3.ZERO))
			mmi_phys_high.multimesh.set_instance_transform(proc_idx, Transform3D().scaled(Vector3.ZERO))
			coll.disabled = true

func _process_physical_spawning() -> void:
	# ACE: Spawn 50 rocks per frame to eliminate the startup freeze
	var batch = 24 if mobile_perf else 50
	for i in range(batch):
		if _spawn_idx >= phys_count:
			_is_spawning_phys = false
			return
		
		var angle = _rng.randf() * TAU
		var dist = _rng.randf_range(inner_radius, outer_radius)
		var h = pow(_rng.randf_range(-1.0, 1.0), 2.0) * (thickness * 0.8)
		var asteroid = StaticBody3D.new()
		asteroid.position = Vector3(cos(angle) * dist, h, sin(angle) * dist)
		asteroid.rotation = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU)
		var s_roll = _rng.randf()
		var scale_val = 25.0 + pow(s_roll, 4.0) * 1600.0
		asteroid.scale = Vector3(scale_val, scale_val, scale_val)
		
		# INITIAL HIDE (Zero scale)
		mmi_phys_med.multimesh.set_instance_transform(_spawn_idx, Transform3D().scaled(Vector3.ZERO))
		mmi_phys_high.multimesh.set_instance_transform(_spawn_idx, Transform3D().scaled(Vector3.ZERO))

		var collision = CollisionShape3D.new()
		var shape = SphereShape3D.new(); shape.radius = 6.0; collision.shape = shape
		asteroid.add_child(collision)
		
		if _health_component_script:
			var hc = Node.new(); hc.set_script(_health_component_script); hc.name = "HealthComponent"; hc.set("max_health", 100.0); asteroid.add_child(hc)
		
		add_child(asteroid); asteroid.add_to_group("Targets"); asteroid.add_to_group("Destructible"); asteroids.append(asteroid); coll_nodes.append(collision)
		_spawn_idx += 1

func _build_faceted_rock_mesh(sides: int) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r1 = 8.0; var y1 = 4.0; var r2 = 5.0; var y2 = 7.0
	var top = Vector3(2.0, 9.0, -1.0); var center_bot = Vector3(0, -4.5, 0); var center_top = top - Vector3(0, 4.5, 0)
	var c_bot = Color("#2D1B1B"); var c_mid1 = Color("#3E2723"); var c_mid2 = Color("#4E342E"); var c_top = Color("#5D4037")
	for i in range(sides):
		var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides
		var b1 = Vector3(cos(a1)*r1, -4.5, sin(a1)*r1); var b2 = Vector3(cos(a2)*r1, -4.5, sin(a2)*r1)
		var j1 = sin(a1 * 4.0) * 1.5 if sides > 4 else 0.0
		var j2 = sin(a2 * 4.0) * 1.5 if sides > 4 else 0.0
		var m1 = Vector3(cos(a1)*(r1+j1), y1-4.5+j1, sin(a1)*(r1+j1)); var m2 = Vector3(cos(a2)*(r1+j2), y1-4.5+j2, sin(a2)*(r1+j2))
		var t1 = Vector3(cos(a1)*r2, y2-4.5+j1*0.5, sin(a1)*r2); var t2 = Vector3(cos(a2)*r2, y2-4.5+j2*0.5, sin(a2)*r2)
		st.set_color(c_bot); st.add_vertex(b2); st.set_color(c_mid1); st.add_vertex(m1); st.set_color(c_bot); st.add_vertex(b1)
		st.set_color(c_mid1); st.add_vertex(m2); st.add_vertex(m1); st.set_color(c_bot); st.add_vertex(b2)
		st.set_color(c_mid1); st.add_vertex(m2); st.set_color(c_mid2); st.add_vertex(t1); st.set_color(c_mid1); st.add_vertex(m1)
		st.set_color(c_mid2); st.add_vertex(t2); st.add_vertex(t1); st.set_color(c_mid1); st.add_vertex(m2)
		st.set_color(c_mid2); st.add_vertex(t2); st.set_color(c_top); st.add_vertex(center_top); st.set_color(c_mid2); st.add_vertex(t1)
		st.set_color(c_bot); st.add_vertex(b1); st.add_vertex(center_bot); st.add_vertex(b2)
	st.generate_normals(false); return st.commit()

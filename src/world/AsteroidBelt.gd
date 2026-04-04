
extends Node3D

# AsteroidBelt.gd (LOD Optimization Edition)
# Managed by THE PROCEDURALIST.

@export var belt_seed: int = 9999
@export var mmi_count: int = 14000 
@export var phys_count: int = 1500  
@export var inner_radius: float = 1400000.0
@export var outer_radius: float = 2000000.0
@export var thickness: float = 20000.0 

var rock_mesh: ArrayMesh
var asteroids: Array[StaticBody3D] = []
var mesh_nodes: Array[MeshInstance3D] = []
var coll_nodes: Array[CollisionShape3D] = []
var rot_speeds: Array[Vector3] = []
var mmi: MultiMeshInstance3D
var player: Node3D

# LOD CONSTANTS
const PHYSICS_LOD_DIST: float = 80000.0 # 80km - asteroids beyond this lose collision
const HIDE_LOD_DIST: float = 800000.0  # 800km - individual rocks hide and let MMI take over
const STELLAR_CUTOFF: float = 4000000.0 # 4,000km - Transition to deep space hibernation

func _ready() -> void:
	rock_mesh = _build_faceted_rock_mesh()
	_spawn_deterministic_belt()
	set_process(true)
	
	# Cache player reference for the LOD loop
	var players = get_tree().get_nodes_in_group("Player")
	if players.size() > 0: player = players[0]

func _spawn_deterministic_belt() -> void:
	var rng = RandomNumberGenerator.new()
	rng.seed = belt_seed
	
	# OPTIMIZATION 1: MULTIMESH (MMI)
	# This is our primary LOD strategy. 14k asteroids in 1 draw call.
	# OPTIMIZATION 1: MULTIMESH (MMI) - ACE ILLUSTRATOR HATCHING
	mmi = MultiMeshInstance3D.new()
	mmi.multimesh = MultiMesh.new()
	mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi.multimesh.use_colors = true
	mmi.multimesh.instance_count = mmi_count
	mmi.multimesh.mesh = rock_mesh
	
	var mmi_mat = ShaderMaterial.new()
	mmi_mat.shader = load("res://src/shaders/hatch_toon.gdshader")
	mmi.material_override = mmi_mat
	add_child(mmi)
	
	# SHARED TOON MATERIAL (Physical Rocks) - ACE ILLUSTRATOR HATCHING
	var phys_mat = ShaderMaterial.new()
	phys_mat.shader = load("res://src/shaders/hatch_toon.gdshader")
	
	# SCREEN-SPACE OUTLINE (Global Consistency)
	var outline_mat = ShaderMaterial.new()
	outline_mat.shader = load("res://src/shaders/outline.gdshader")
	outline_mat.set_shader_parameter("outline_width", 1.5)
	outline_mat.set_shader_parameter("outline_color", Color.BLACK)
	
	mmi_mat.next_pass = outline_mat
	phys_mat.next_pass = outline_mat
	
	for i in range(mmi_count):
		# (Loop body for MMI initialization...)
		var angle = rng.randf() * TAU
		var dist = rng.randf_range(inner_radius, outer_radius)
		var h = pow(rng.randf_range(-1.0, 1.0), 3.0) * thickness 
		var xform = Transform3D().rotated(Vector3(rng.randf(), rng.randf(), rng.randf()).normalized(), rng.randf() * TAU)
		xform = xform.scaled(Vector3.ONE * (5.0 + pow(rng.randf(), 2.0) * 120.0))
		xform.origin = Vector3(cos(angle) * dist, h, sin(angle) * dist)
		mmi.multimesh.set_instance_transform(i, xform)
		
		# COLOR MIX
		var mix_r = rng.randf()
		var inst_col = Color.from_hsv(0, 0, rng.randf_range(0.2, 0.5))
		if mix_r > 0.45: inst_col = Color.from_hsv(rng.randf_range(0.04, 0.08), 0.4, rng.randf_range(0.3, 0.5))
		mmi.multimesh.set_instance_color(i, inst_col)
	
	# OPTIMIZATION 2: SHARED RESOURCE ALLOCATION
	# All 1.5k physical asteroids share the same ArrayMesh and Material instances.
	for i in range(phys_count):
		var angle = rng.randf() * TAU
		var dist = rng.randf_range(inner_radius, outer_radius)
		var h = pow(rng.randf_range(-1.0, 1.0), 2.0) * (thickness * 0.8)
		
		var asteroid = StaticBody3D.new()
		asteroid.position = Vector3(cos(angle) * dist, h, sin(angle) * dist)
		asteroid.rotation = Vector3(rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU)
		
		var s_roll = rng.randf()
		var scale_val = 25.0 + pow(s_roll, 4.0) * 1600.0
		asteroid.scale = Vector3(scale_val, scale_val, scale_val)
		
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = rock_mesh
		mesh_instance.material_override = phys_mat
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		asteroid.add_child(mesh_instance)
		
		var collision = CollisionShape3D.new()
		var shape = SphereShape3D.new(); shape.radius = 8.5 
		collision.shape = shape
		asteroid.add_child(collision)
		
		add_child(asteroid)
		asteroids.append(asteroid)
		mesh_nodes.append(mesh_instance)
		coll_nodes.append(collision)
		
		var rot_factor = 25.0 / scale_val 
		rot_speeds.append(Vector3(rng.randf_range(-rot_factor, rot_factor), rng.randf_range(-rot_factor, rot_factor), rng.randf_range(-rot_factor, rot_factor)))

func _process(delta: float) -> void:
	if not player: 
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: player = found[0]
		return

	var p_pos = player.global_position
	var dist_to_planet = p_pos.distance_to(global_position)
	
	# STELLAR HIBERNATION: Beyond 4,000km, we disable the individual rock loop.
	# The MultiMeshInstance (MMI) is still visible, but we stop checking 
	# 3,000 asteroids for LOD/Collision every frame.
	if dist_to_planet > STELLAR_CUTOFF:
		return
	
	# OPTIMIZATION 3: DYNAMIC DISTANCE-BASED LOD
	# We iterate through the hazard list and deprioritize distant objects.
	for i in range(asteroids.size()):
		var a = asteroids[i]
		if not is_instance_valid(a): continue 
		var dist_sq = a.global_position.distance_squared_to(p_pos)
		
		# If asteroid is beyond 800km, we disable it entirely. 
		# The MMI background ring is enough for distant visuals.
		if dist_sq > HIDE_LOD_DIST * HIDE_LOD_DIST:
			if a.visible:
				a.hide()
				coll_nodes[i].disabled = true
			continue
		
		if not a.visible: 
			a.show()
			
		# PHYSICS LOD: Disable collisions for rocks beyond 80km.
		# This saves 95% of physics processing during high-speed transit.
		var should_collide = dist_sq < PHYSICS_LOD_DIST * PHYSICS_LOD_DIST
		if coll_nodes[i].disabled == should_collide:
			coll_nodes[i].disabled = !should_collide
		
		# TUMBLE KINEMATICS
		var rs = rot_speeds[i]
		a.rotate_x(rs.x * delta)
		a.rotate_y(rs.y * delta)
		a.rotate_z(rs.z * delta)

func _build_faceted_rock_mesh() -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides = 9; var r1 = 8.0; var y1 = 4.0; var r2 = 5.0; var y2 = 7.0
	var top = Vector3(2.0, 9.0, -1.0); var center_bot = Vector3(0, -4.5, 0); var center_top = top - Vector3(0, 4.5, 0)
	var c_bot = Color("#2D1B1B"); var c_mid1 = Color("#3E2723"); var c_mid2 = Color("#4E342E"); var c_top = Color("#5D4037")
	for i in range(sides):
		var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides
		var b1 = Vector3(cos(a1)*r1, -4.5, sin(a1)*r1); var b2 = Vector3(cos(a2)*r1, -4.5, sin(a2)*r1)
		var jag1 = sin(a1 * 4.0) * 2.2; var jag2 = sin(a2 * 4.0) * 2.2
		var m1 = Vector3(cos(a1)*(r1+jag1), y1-4.5+jag1, sin(a1)*(r1+jag1)); var m2 = Vector3(cos(a2)*(r1+jag2), y1-4.5+jag2, sin(a2)*(r1+jag2))
		var t1 = Vector3(cos(a1)*r2, y2-4.5+jag1*0.6, sin(a1)*r2); var t2 = Vector3(cos(a2)*r2, y2-4.5+jag2*0.6, sin(a2)*r2)
		st.set_color(c_bot); st.add_vertex(b2); st.set_color(c_mid1); st.add_vertex(m1); st.set_color(c_bot); st.add_vertex(b1)
		st.set_color(c_mid1); st.add_vertex(m2); st.add_vertex(m1); st.set_color(c_bot); st.add_vertex(b2)
		st.set_color(c_mid1); st.add_vertex(m2); st.set_color(c_mid2); st.add_vertex(t1); st.set_color(c_mid1); st.add_vertex(m1)
		st.set_color(c_mid2); st.add_vertex(t2); st.add_vertex(t1); st.set_color(c_mid1); st.add_vertex(m2)
		st.set_color(c_mid2); st.add_vertex(t2); st.set_color(c_top); st.add_vertex(center_top); st.set_color(c_mid2); st.add_vertex(t1)
		st.set_color(c_bot); st.add_vertex(b1); st.add_vertex(center_bot); st.add_vertex(b2)
	st.generate_normals(false); return st.commit()

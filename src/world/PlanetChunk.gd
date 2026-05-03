@tool
extends MeshInstance3D

# PlanetChunk.gd (Botanical Horizon Edition)
# Managed by THE PROCEDURALIST.

var noise: FastNoiseLite
var radius: float = 18000.0 
var terrain_strength: float = 1200.0 
var resolution: int = 48 
var face_normal: Vector3 
var x_axis: Vector3 
var y_axis: Vector3 
var offset: Vector2 = Vector2.ZERO
var scale_factor: float = 1.0
var planet_seed: int = 0  
var scatter_grass: bool = false
var archetype: String = "LUSH"
var continent_pole: Vector3 = Vector3.UP # ACE: Synchronized continent anchor
var face: Node3D
var planet: Node

func setup(p_planet: Node) -> void:
	self.planet = p_planet

# DYNAMIC PROCEDURAL PLANET PALETTE
static var _res_cache := {}
static func _get_res(path: String) -> Resource:
	if not _res_cache.has(path): _res_cache[path] = load(path)
	return _res_cache[path]

static func _get_tex(path: String) -> Texture2D:
	return _get_res(path) as Texture2D

static var _mat_cache := {}
static var _mesh_cache := {}

static func _get_box_mesh(size: Vector3) -> BoxMesh:
	var key = "box_%s" % size
	if not _mesh_cache.has(key):
		var b = BoxMesh.new(); b.size = size
		_mesh_cache[key] = b
	return _mesh_cache[key]
var pal_forest_h: float = 0.3
var pal_forest_col: Color = Color("#33AA33")
var pal_grass_col: Color = Color("#44BB44")
var pal_grass_secondary: Color = Color("#228822") # High-contrast variant
var pal_beach_col: Color = Color("#C2B280")
var pal_mount_col: Color = Color("#888888")
var pal_water_base: Color = Color(0.0, 0.35, 0.95)
var pal_water_light: Color = Color(0.0, 0.65, 1.0)
var pal_water_shore: Color = Color(0.3, 0.85, 1.0)
var SEA_LEVEL = -120.0

var _flora_nodes: Array[Node] = []
var _is_generating: bool = false
var _mesh_data_land: Array = []
var _mesh_data_water: Array = []
var _collision_shape: ConcavePolygonShape3D
var _t_pts: Array[Transform3D] = []
var _r_pts: Array[Transform3D] = []
var _g_pts: Array[Transform3D] = []
var _c_pts: Array[Transform3D] = []
var _m_pts: Array = [] # Pairs: [Transform3D, String (Type)]

signal generation_completed()
var _task_id: int = -1

# STELLAR VISIBILITY POLICY: Unified across all planetary props
const PROP_LOD_HIGH_END: float = 1200.0  # Tightened High-Detail radius
const PROP_LOD_PROXY_END: float = 6500.0  # Aggressive absolute cutoff for retro performance
const PROP_LOD_FADE: float = 300.0       

func start_generation() -> void:
	self.visible = false
	_is_generating = false # ACE: Reset state before starting new thread to avoid pool deadlocks
	DebugSettings.connect_rebuild(self, "_on_rebuild_req")
	_start_async_generation()

func _start_async_generation() -> void:
	if _is_generating: return
	_is_generating = true
	_task_id = WorkerThreadPool.add_task(_threaded_generation_task)

func _threaded_generation_task() -> void:
	_calculate_multi_surface_mesh_thread_safe()
	if face and face.planet:
		# ACE: Thread-safe handover via deferred call to the main thread
		face.planet.call_deferred("queue_chunk_for_finalization", self)

func _exit_tree() -> void:
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id) 

func sleep_and_reset() -> void:
	# ACE MEMORY POOLING: Safely suspend thread and purge visual data without freeing the object
	# We no longer block the main thread here. PlanetGen will handle 'zombie' chunks.
	_is_generating = false
	visible = false
	mesh = null
	
	# Full data wipe to prevent Memory Leaks when retained in pool
	_mesh_data_land.clear()
	_mesh_data_water.clear()
	_t_pts.clear(); _r_pts.clear(); _g_pts.clear(); _c_pts.clear()
	_is_generating = false # FORCE RESET
	
	# Purge all botanical MultiMesh instances and collisions ASYNCHRONOUSLY
	# Moving them to death_row prevents the main thread from locking up 
	# when thousands of nodes are freed at once during a transit exit.
	for n in get_children():
		remove_child(n)
		if face and face.planet:
			face.planet.death_row.append(n)
		else:
			n.free()

func is_busy() -> bool:
	if _task_id == -1: return false
	if WorkerThreadPool.is_task_completed(_task_id):
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
		return false
	return true

func _on_rebuild_req() -> void:
	# ACE CACHE FLUSHING: Invalidate static LOD meshes to force re-generation with new geometry
	c_t_l = null; c_t_m = null; c_t_h = null; c_g = null; c_r = null
	for n in _flora_nodes: if is_instance_valid(n): n.queue_free()
	_flora_nodes.clear()
	# Update local complexity before mesh recalc
	terrain_strength = 1200.0 * DebugSettings.terrain_complexity
	_start_async_generation()


func _v3s(c: Color) -> String:
	return "vec3(%.3f, %.3f, %.3f)" % [c.r, c.g, c.b]

func _get_sn(x: int, y: int) -> Vector3:
	var per: Vector2 = Vector2(x, y) / float(resolution); var lu: Vector2 = (per - Vector2(0.5, 0.5)) * 2.0 * scale_factor
	var cp: Vector3 = face_normal + (offset.x + lu.x) * x_axis + (offset.y + lu.y) * y_axis
	return cp.normalized()

func get_terrain_elevation(sn: Vector3) -> float:
	var macro_h: float = noise.get_noise_3dv(sn * 600.0)
	var micro_crag: float = noise.get_noise_3dv(sn * 15000.0) * 0.1
	var local_geo: float = 0.0

	match archetype:
		"DESERT":
			# MESAS: Sharp vertical stepped canyons
			var mesa = smoothstep(-0.1, 0.1, macro_h) * 2.0 - 1.0 
			local_geo = (mesa * 0.6 + micro_crag) * terrain_strength * 0.7
		"VOLCANIC", "ABYSS":
			# JAGGED: Extreme sharp ridge peaks using inverted absolute noise
			var jagged = 1.0 - abs(macro_h * 1.5) 
			local_geo = (jagged * 2.0 - 0.8 + micro_crag * 2.5) * terrain_strength * 1.4
		"FROZEN":
			# PLAINS: Ice flats with harsh vertical spikes
			var plains = macro_h * 0.4
			var spikes = max(0.0, noise.get_noise_3dv(sn * 2500.0) - 0.65) * 6.0
			local_geo = (plains + spikes + micro_crag * 0.4) * terrain_strength
		"TOXIC", "RADIATED":
			# CRATERS: inverted bubbles and craters
			var craters = abs(noise.get_noise_3dv(sn * 1200.0))
			var bubbling = noise.get_noise_3dv(sn * 3000.0) * 0.5
			local_geo = (macro_h - craters * 1.8 + bubbling + micro_crag) * terrain_strength * 0.6
		"ALPINE":
			# CRAGGY PEAKS: High-frequency ridge noise for dramatic vertical scale
			var ridge = 1.0 - abs(macro_h)
			local_geo = (ridge * 2.5 - 0.8 + micro_crag * 1.5) * terrain_strength * 1.5
		_:
			# LUSH / CANDY: Standard Smooth Terraces
			local_geo = (macro_h + micro_crag) * terrain_strength
			var volcanic: float = noise.get_noise_3dv(sn * 25000.0)
			if volcanic > 0.45: local_geo -= 1000.0
			var terrace_height = 80.0
			var h_frac = fposmod(local_geo, terrace_height) / terrace_height
			var layer_step = floor(local_geo / terrace_height) + smoothstep(0.15, 0.85, h_frac)
			local_geo = layer_step * terrace_height
	
	# CONTINENTS VS OCEANS: Large-scale landmasses with varied islands
	var c_n: float = noise.get_noise_3dv(sn * 2.2)
	c_n += noise.get_noise_3dv(sn * 6.5) * 0.5
	c_n += noise.get_noise_3dv(sn * 15.0) * 0.25
	var cont_mask: float = smoothstep(-0.2, 0.2, c_n + 0.3)
	var abyss_depth: float = SEA_LEVEL - 400.0
	
	# Calculate natural terrain height (Continental Land vs Oceanic Abyss)
	var elev = lerp(abyss_depth, local_geo + (SEA_LEVEL + 50.0), cont_mask)
	return elev

func get_water_point(sn: Vector3) -> Vector3:
	return sn * (radius + SEA_LEVEL)

func _calculate_multi_surface_mesh_thread_safe() -> void:
	# ACE VERTEX REUSE: Pre-generate the elevated grid to avoid redundant noise calls.
	# This reduction (75% on average) is the single biggest win for background CPU budget.
	var grid_res = resolution + 1
	var points: PackedVector3Array = PackedVector3Array()
	var heights: PackedFloat32Array = PackedFloat32Array()
	points.resize(grid_res * grid_res)
	heights.resize(grid_res * grid_res)
	
	for gy in range(grid_res):
		for gx in range(grid_res):
			var sn = _get_sn(gx, gy)
			var h = get_terrain_elevation(sn)
			var idx = gy * grid_res + gx
			points[idx] = sn * (radius + max(h, SEA_LEVEL - 50.0))
			heights[idx] = h
			
	var l_verts: PackedVector3Array = PackedVector3Array()
	var l_norms: PackedVector3Array = PackedVector3Array()
	l_verts.resize(resolution * resolution * 6)
	l_norms.resize(resolution * resolution * 6)
	var l_idx: int = 0
	
	var w_verts: PackedVector3Array = PackedVector3Array()
	var w_cols: PackedColorArray = PackedColorArray()
	var w_norms: PackedVector3Array = PackedVector3Array()
	var has_water = false
	
	for y in range(resolution):
		for x in range(resolution):
			# Index the pre-calculated grid
			var i1 = y * grid_res + x;         var i2 = y * grid_res + (x + 1)
			var i3 = (y + 1) * grid_res + x;   var i4 = (y + 1) * grid_res + (x + 1)
			
			var p1 = points[i1]; var p2 = points[i2]
			var p3 = points[i3]; var p4 = points[i4]
			var h1 = heights[i1]; var h2 = heights[i2]
			var h3 = heights[i3]; var h4 = heights[i4]
			
			# ACE FACETED NORMALS: Calculate the cross-product per triangle to maintain the retro aesthetic
			var n1 = (p3 - p1).cross(p2 - p1).normalized()
			l_verts[l_idx] = p1; l_norms[l_idx] = n1; l_idx += 1
			l_verts[l_idx] = p3; l_norms[l_idx] = n1; l_idx += 1
			l_verts[l_idx] = p2; l_norms[l_idx] = n1; l_idx += 1
			
			var n2 = (p4 - p3).cross(p2 - p3).normalized()
			l_verts[l_idx] = p3; l_norms[l_idx] = n2; l_idx += 1
			l_verts[l_idx] = p4; l_norms[l_idx] = n2; l_idx += 1
			l_verts[l_idx] = p2; l_norms[l_idx] = n2; l_idx += 1
			
			if min(min(h1, h2), min(h3, h4)) <= SEA_LEVEL + 30.0:
				has_water = true
				var sn1 = _get_sn(x, y); var sn2 = _get_sn(x + 1, y)
				var sn3 = _get_sn(x, y + 1); var sn4 = _get_sn(x + 1, y + 1)
				var w1 = get_water_point(sn1); var w2 = get_water_point(sn2)
				var w3 = get_water_point(sn3); var w4 = get_water_point(sn4)
				var sp = [1.0 - clamp((SEA_LEVEL - h1) / 150.0, 0.0, 1.0), 1.0 - clamp((SEA_LEVEL - h2) / 150.0, 0.0, 1.0), 1.0 - clamp((SEA_LEVEL - h3) / 150.0, 0.0, 1.0), 1.0 - clamp((SEA_LEVEL - h4) / 150.0, 0.0, 1.0)]
				
				w_verts.push_back(w1); w_cols.push_back(Color(sp[0], 0, 0, 1))
				w_verts.push_back(w3); w_cols.push_back(Color(sp[2], 0, 0, 1))
				w_verts.push_back(w2); w_cols.push_back(Color(sp[1], 0, 0, 1))
				var wn1 = (w3 - w1).cross(w2 - w1).normalized()
				w_norms.push_back(wn1); w_norms.push_back(wn1); w_norms.push_back(wn1)
				
				w_verts.push_back(w3); w_cols.push_back(Color(sp[2], 0, 0, 1))
				w_verts.push_back(w4); w_cols.push_back(Color(sp[3], 0, 0, 1))
				w_verts.push_back(w2); w_cols.push_back(Color(sp[1], 0, 0, 1))
				var wn2 = (w4 - w3).cross(w2 - w3).normalized()
				w_norms.push_back(wn2); w_norms.push_back(wn2); w_norms.push_back(wn2)
			
	# ACE PERFORMANCE: Bake ConcavePolygonShape on Worker Thread!
	# This avoids the 'Main-Thread Choke' of create_trimesh_collision()
	if l_verts.size() > 0:
		var shape = ConcavePolygonShape3D.new()
		shape.set_faces(l_verts)
		_collision_shape = shape
			
	_mesh_data_land = []; _mesh_data_land.resize(Mesh.ARRAY_MAX)
	_mesh_data_land[Mesh.ARRAY_VERTEX] = l_verts
	_mesh_data_land[Mesh.ARRAY_NORMAL] = l_norms # ACE: Missing Normals fixed
	
	if has_water:
		_mesh_data_water = []; _mesh_data_water.resize(Mesh.ARRAY_MAX)
		_mesh_data_water[Mesh.ARRAY_VERTEX] = w_verts
		_mesh_data_water[Mesh.ARRAY_COLOR] = w_cols
		_mesh_data_water[Mesh.ARRAY_NORMAL] = w_norms
	else:
		_mesh_data_water = []
	
	_scatter_deterministic_stellar_layers_thread_safe(has_water)

func _finalize_generation_on_main() -> void:
	# ACE LIFECYCLE HARDENING: Prevent 'Zombie Chunks' from returning from the pool
	if not _is_generating: return 
	
	var final_mesh: ArrayMesh = ArrayMesh.new()
	final_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _mesh_data_land)
	if _mesh_data_water.size() > 0:
		final_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _mesh_data_water)
	
	_finalize_dual_materials(final_mesh, _mesh_data_water.size() > 0)
	
	# ACE: Prop Spawning Throttle
	# Instead of synchronous instantiation (which freezes the main thread),
	# we push spawn tasks to the PlanetGen queue.
	var planet = get_parent().get_parent()
	if is_instance_valid(planet) and "prop_spawn_queue" in planet:
		if not _t_pts.is_empty(): planet.prop_spawn_queue.append([self, "_spawn_tree_lods", _t_pts.duplicate()])
		if not _r_pts.is_empty(): planet.prop_spawn_queue.append([self, "_spawn_rock", _r_pts.duplicate()])
		if not _g_pts.is_empty(): planet.prop_spawn_queue.append([self, "_spawn_grass", _g_pts.duplicate()])
		if not _c_pts.is_empty(): planet.prop_spawn_queue.append([self, "_spawn_city_buildings", _c_pts.duplicate()])
		if not _m_pts.is_empty(): planet.prop_spawn_queue.append([self, "_spawn_minerals", _m_pts.duplicate()])
	
	_t_pts.clear(); _r_pts.clear(); _g_pts.clear(); _c_pts.clear(); _m_pts.clear()
	_is_generating = false
	_task_id = -1
	
	# VISIBILITY HANDSHAKE: Only reveal the chunk now that everything is pixel-ready
	self.visible = true
	generation_completed.emit()

func _add_faceted_tri(st: SurfaceTool, v1: Vector3, v2: Vector3, v3: Vector3, h1: float, h2: float, h3: float) -> void:
	st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v3)

func _finalize_dual_materials(a_mesh: ArrayMesh, has_water: bool) -> void:
	self.mesh = a_mesh
	
	# LAND SURFACE: Shared Shader with per-planet uniforms
	# ACE CACHE: We create unique materials ONLY when uniforms change (radius/archetype)
	var m_land = ShaderMaterial.new()
	m_land.shader = _get_shared_land_shader()
	m_land.set_shader_parameter("radius", radius)
	m_land.set_shader_parameter("sea_level", SEA_LEVEL)
	m_land.set_shader_parameter("col_beach", pal_beach_col)
	m_land.set_shader_parameter("col_grass", pal_grass_col)
	m_land.set_shader_parameter("col_forest", pal_grass_secondary)
	m_land.set_shader_parameter("col_rock", pal_mount_col)
	m_land.set_shader_parameter("continent_pole", continent_pole)
	
	# Tri-Planar Micro-Detail
	m_land.set_shader_parameter("ground_tex", _get_tex("res://assets/textures/ground_texture.png"))
	m_land.set_shader_parameter("mountain_tex", _get_tex("res://assets/textures/mountain_texture.png"))
	m_land.set_shader_parameter("snow_tex", _get_tex("res://assets/textures/snow_texture.png"))
	
	# ACE PHYSICAL HARDENING: Load the new high-fidelity normal maps
	m_land.set_shader_parameter("ground_norm", _get_tex("res://assets/textures/ground_texture_normal.png"))
	m_land.set_shader_parameter("mountain_norm", _get_tex("res://assets/textures/mountain_texture_normal.png"))
	m_land.set_shader_parameter("snow_norm", _get_tex("res://assets/textures/snow_texture_normal.png"))
	
	# ACE STELLAR DEPTH: Load the new displacement maps for Parallax Occlusion
	m_land.set_shader_parameter("ground_disp", _get_tex("res://assets/textures/ground_texture_displacement.png"))
	m_land.set_shader_parameter("mountain_disp", _get_tex("res://assets/textures/mountain_texture_displacement.png"))
	m_land.set_shader_parameter("snow_disp", _get_tex("res://assets/textures/snow_texture_displacement.png"))
	
	# DISTANCE-PHASE HARDENING: Only enable Outlines for detailed surface chunks
	if scale_factor < 0.013:
		var outline = ShaderMaterial.new()
		outline.shader = load("res://src/shaders/outline.gdshader")
		outline.set_shader_parameter("outline_width", 1.5)
		outline.set_shader_parameter("outline_color", Color.BLACK)
		m_land.next_pass = outline
	self.set_surface_override_material(0, m_land)
	
	if has_water:
		# Use a shared material for water where possible to reduce draw calls
		var m_water = ShaderMaterial.new()
		m_water.shader = _get_shared_water_shader()
		m_water.set_shader_parameter("pal_water_base", pal_water_base)
		m_water.set_shader_parameter("pal_water_light", pal_water_light)
		m_water.set_shader_parameter("pal_water_shore", pal_water_shore)
		if archetype == "VOLCANIC":
			m_water.set_shader_parameter("is_lava", true)
			m_water.set_shader_parameter("pal_water_base", Color(0.8, 0.2, 0.0))
			m_water.set_shader_parameter("pal_water_light", Color(1.0, 0.6, 0.1))
		self.set_surface_override_material(1, m_water)
	# ONLY CAST SHADOWS for the immediate high-detail terrain
	if scale_factor <= 0.005:
		self.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		self.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
	# DECOUPLED COLLISION: High-detail chunks (under 2km across) get collision.
	# ACE PERFORMANCE: Only materialize physics if the player is in 'Hazard Proximity' (< 3km alt)
	# This eliminates main-thread stalls when searching for targets from safe altitudes.
	if scale_factor <= 0.0015:
		var p_ref = get_tree().get_first_node_in_group("Player")
		var is_near = false
		if p_ref:
			var d = p_ref.global_position.distance_to(global_position)
			if d < 10000.0: is_near = true # Within 10km of chunk center
		
		if is_near:
			var planet = get_parent().get_parent()
			if planet and "collision_queue" in planet:
				planet.collision_queue.append(self)
			else:
				create_trimesh_collision()

func _scatter_deterministic_stellar_layers_thread_safe(has_water: bool) -> void:
	# CPU HARDENING: Infrastructure (Metropolis) visible from ORBIT (<= 2000km).
	# Nature remains restricted to approach zones (<= 20km).
	if scale_factor > 2.0: return
	var radius_ratio: float = clamp(radius / 1000000.0, 0.3, 1.5)
	var t_pts: Array[Transform3D] = []; var r_pts: Array[Transform3D] = []; var g_pts: Array[Transform3D] = []; var c_pts: Array[Transform3D] = []
	var m_pts: Array = []

	# Cache the planet's mineable resource list locally — safe to read once from the
	# background thread since planet_resources is set before chunk generation begins.
	var _mineable: Array[String] = []
	if is_instance_valid(planet) and "planet_resources" in planet:
		for r in planet.get("planet_resources"):
			if r != "Stone" and r != "Wood":
				_mineable.append(r)
	if _mineable.is_empty():
		_mineable = ["Copper"]
	
	# ACE MESH HARDENING: Use tiered cell sizes to prevent 3.5M+ loop iterations.
	var base_cell: float = 0.00008
	if scale_factor > 0.15: base_cell = 0.008 # ORBITAL TIER (Upgraded for Multi-City)
	elif scale_factor > 0.06: base_cell = 0.0006 # ACE DENSITY: (Improved for 1/20th scale)
	elif scale_factor > 0.015: base_cell = 0.0003 # ACE PRECISION: (Fine-tuned for localized city hubs)
	
	var t_cell: float = base_cell / radius_ratio
	var ts_x = int(floor((offset.x - scale_factor) / t_cell)); var te_x = int(ceil((offset.x + scale_factor) / t_cell))
	var ts_y = int(floor((offset.y - scale_factor) / t_cell)); var te_y = int(ceil((offset.y + scale_factor) / t_cell))
	# ACE STABILITY HARDENING: Broad-phase scanning must be 100% deterministic.
	# We remove the center-point macro-culling which was causing 'Vanishing Groves'
	# during Quadtree splits (where children would skip evaluation that parents performed).
	var end_y = te_y
	var end_x = te_x
	for y_idx in range(ts_y, end_y):
		for x_idx in range(ts_x, end_x):
			# Use bit-stable hashing based on absolute world grid coordinates
			var h_v = hash(Vector3(float(x_idx), float(y_idx), float(planet_seed) + face_normal.x*13.0))
			
			var j_x = (float(h_v % 100) / 100.0 - 0.5) * 1.5
			var j_y = (float((h_v >> 6) % 100) / 100.0 - 0.5) * 1.5
			var cp = (face_normal + x_axis * (float(x_idx) + j_x) * t_cell + y_axis * (float(y_idx) + j_y) * t_cell).normalized()
						
			var cluster_n = noise.get_noise_3dv(cp * 18000.0) 
			var detail_n = noise.get_noise_3dv(cp * 65000.0)
			
			# NATURE THROTTLE: Trees/Rocks only spawn on high-detail chunks with fine grid
			var nature_ok = scale_factor <= 0.02 and base_cell < 0.0002
			
			# ACE STRUCTURAL HIERARCHY: Natural Wilderness only
			# WILDERNESS ZONE: Minerals & Nature
			# -----------------------------------
			# 1. MINERAL PRIORITY: Colossal Rarity (Copper scattered throughout planet)
			if (h_v % 25000) < 3:
				var h = get_terrain_elevation(cp)
				if h > -100.0:
					# Pick deterministically from this planet's resource pool
					var type: String = _mineable[int(abs(float(h_v >> 7))) % _mineable.size()]
					
					# ACE: Small offset (5.0) since octahedron is now tip-anchored
					var xf = _get_object_xform(cp * (radius + h + 5.0), cp, detail_n, 1.0)
					m_pts.append([xf, type])
			else:
				# 2. NATURE FALLBACK: Standard Biome Scattering
				# MOBILE: Halve scatter density; tree get_terrain_elevation calls
				# are the long-tail cost here and count directly inflates MMI size.
				var _mob_on: bool = planet and "mobile_perf" in planet and planet.mobile_perf
				var _nat_scale: float = 0.5 if _mob_on else 1.0
				if cluster_n > 0.22:
					var grove_strength = clamp((cluster_n - 0.22) * 8.0, 0.0, 1.0)
					if (h_v % 1000) < int(960 * grove_strength * DebugSettings.tree_mult * _nat_scale):
						var h_t = get_terrain_elevation(cp)
						if h_t > -150.0 and (h_t + sin(cp.x * 12000.0)*300.0) < 1450.0:
							var xform = _get_object_xform(cp * (radius + max(h_t, SEA_LEVEL - 50.0)), cp, detail_n, 12.0)
							t_pts.append(xform.rotated_local(Vector3.UP, float(h_v % 360)))
				elif cluster_n < -0.20:
					if (h_v % 1000) < int(200 * DebugSettings.rock_mult * _nat_scale):
						var h_r = get_terrain_elevation(cp)
						if h_r > -150.0:
							r_pts.append(_get_rock_xform(cp * (radius + max(h_r, SEA_LEVEL - 50.0)), cp, detail_n, 5.0))

	
	# MOBILE: Grass is the single biggest CPU win on iOS (15-25ms in the worst
	# chunk). Skip the grass grid entirely — the hatch-toon shader + scattered
	# rocks/trees already give a dense visual ground cover.
	var _mobile_perf_chunk: bool = false
	if planet and "mobile_perf" in planet:
		_mobile_perf_chunk = planet.mobile_perf
	if scale_factor <= 0.00055 and not _mobile_perf_chunk:
		var g_cell: float = 0.0000045 / radius_ratio
		var gs_x = int(floor((offset.x - scale_factor) / g_cell)); var ge_x = int(ceil((offset.x + scale_factor) / g_cell))
		var gs_y = int(floor((offset.y - scale_factor) / g_cell)); var ge_y = int(ceil((offset.y + scale_factor) / g_cell))
		if (ge_x - gs_x) <= 300:
			for y_idx in range(gs_y, ge_y):
				for x_idx in range(gs_x, ge_x):
					var h_v = hash(Vector3(float(x_idx), float(y_idx), float(planet_seed) + face_normal.x*7.0 + face_normal.z*3.0))
					if h_v % 100 < 85:
						# ACE ORGANIC GRASS: Aggressive jitter (1.8) actively breaks the rigid grid system
						# Grass clusters now unpredictably drift and clump, forming natural rolling fields
						var j_x = (float(h_v % 50)/50.0 - 0.5) * 1.8
						var j_y = (float((h_v >> 4) % 50)/50.0 - 0.5) * 1.8
						var cp = (face_normal + x_axis * (float(x_idx) + j_x) * g_cell + y_axis * (float(y_idx) + j_y) * g_cell).normalized()
						# ACE TECTONIC GATING: Prevent grass from spawning on the urban continent
						var g_cn = noise.get_noise_3dv(cp * 2.2)
						var g_w_cp = (cp + Vector3(noise.get_noise_3dv(cp * 0.5), noise.get_noise_3dv(cp * 0.6 + Vector3(7,7,7)), noise.get_noise_3dv(cp * 0.7 - Vector3(3,3,3))) * 0.35).normalized()
						var g_dist = g_w_cp.distance_to(continent_pole)
						var g_prox = 1.0 - smoothstep(0.0, 1.1, g_dist)
						var g_mask = smoothstep(0.32, 0.48, g_cn + g_prox * 0.85)
						
						if g_mask < 0.1 and noise.get_noise_3dv(cp * 3000.0) > 0.35:
							var h = get_terrain_elevation(cp)
							if h > -150.0 and (h + sin(cp.x * 12000.0)*300.0) < 1300.0:
								g_pts.append(_get_grass_xform(cp * (radius + max(h, SEA_LEVEL - 50.0)), cp, fmod(float(h_v), 10.0)/10.0))
	
	# BUFFER DATA FOR MAIN THREAD COMMIT
	_t_pts = t_pts; _r_pts = r_pts; _g_pts = g_pts; _c_pts = c_pts; _m_pts = m_pts

func _get_object_xform(pos: Vector3, up: Vector3, noise_val: float, b_scale: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	var xf = Transform3D(t_bas, pos); var sv = 1.0 + (abs(noise_val) * 7.0)
	return xf.scaled_local(Vector3(b_scale, b_scale * sv, b_scale))

func _spawn_rock(points: Array[Transform3D]) -> void:
	var mmi_h = MultiMeshInstance3D.new()
	var mm_h = MultiMesh.new(); mm_h.transform_format = MultiMesh.TRANSFORM_3D; mm_h.use_colors = true
	mm_h.mesh = _build_faceted_rock_mesh(12); mm_h.instance_count = points.size()
	
	var mmi_l = MultiMeshInstance3D.new()
	var mm_l = MultiMesh.new(); mm_l.transform_format = MultiMesh.TRANSFORM_3D; mm_l.use_colors = true
	mm_l.mesh = _build_faceted_rock_mesh(4); mm_l.instance_count = points.size()
	
	for i in range(points.size()):
		var h_v = hash(points[i].origin)
		var g = 0.4 + fposmod(float(h_v % 100)/100.0, 0.45)
		var r_col = Color(g, g, g, 1.0)
		mm_h.set_instance_transform(i, points[i]); mm_h.set_instance_color(i, r_col)
		mm_l.set_instance_transform(i, points[i]); mm_l.set_instance_color(i, r_col)
	
	var mat = ShaderMaterial.new(); mat.shader = load("res://src/shaders/hatch_toon.gdshader"); mat.set_shader_parameter("shadow_strength", 0.9)
	
	_apply_planetary_lod_policy(mmi_h, true)
	mmi_h.multimesh = mm_h; mmi_h.material_override = mat; add_child(mmi_h)
	
	_apply_planetary_lod_policy(mmi_l, false)
	mmi_l.multimesh = mm_l; mmi_l.material_override = mat; add_child(mmi_l)

	_spawn_prop_proxies(points, [mmi_h, mmi_l], "Stone", 120, 8.0)

func _spawn_prop_proxies(points: Array[Transform3D], mmis: Array, res_type: String, max_count: int, sphere_r: float) -> void:
	var proxy_script = load("res://src/world/SurfacePropProxy.gd")
	if not proxy_script: return

	var player_pos := Vector3.ZERO
	if is_instance_valid(planet):
		var pl = planet.get("player")
		if is_instance_valid(pl):
			player_pos = pl.global_position

	# Mobile: Reduce proxy count to 50% to avoid performance issues
	var effective_max = max_count
	if _is_mobile_perf():
		effective_max = max(1, max_count / 2)

	var sphere := SphereShape3D.new()
	sphere.radius = sphere_r

	var spawned := 0
	for i in range(points.size()):
		if spawned >= effective_max: break
		var world_pos: Vector3 = global_transform * points[i].origin
		if world_pos.distance_to(player_pos) > PROP_LOD_HIGH_END * 1.5:
			continue
		var col := CollisionShape3D.new()
		col.shape = sphere
		var proxy := StaticBody3D.new()
		proxy.set_script(proxy_script)
		proxy.add_child(col)
		add_child(proxy)
		# Lift center above terrain so the sphere top clears coarse mobile mesh triangles.
		# Sphere still overlaps the visual prop position (lift < radius), so manual aim works.
		var surface_normal: Vector3 = points[i].origin.normalized()
		proxy.position = points[i].origin + surface_normal * (sphere_r * 0.65)
		proxy.call("setup", mmis, i, res_type)
		spawned += 1

func _is_mobile_perf() -> bool:
	return is_instance_valid(planet) and bool(planet.get("mobile_perf"))

func _apply_planetary_lod_policy(mmi: MultiMeshInstance3D, is_high_detail: bool) -> void:
	var mobile_perf: bool = _is_mobile_perf()
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	
	if is_high_detail:
		mmi.visibility_range_end = 800.0 if mobile_perf else PROP_LOD_HIGH_END
		mmi.visibility_range_end_margin = 180.0 if mobile_perf else PROP_LOD_FADE
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF # OPTIMIZATION: Foliage shadows are too expensive
	else:
		mmi.visibility_range_begin = 800.0 if mobile_perf else PROP_LOD_HIGH_END
		mmi.visibility_range_begin_margin = 180.0 if mobile_perf else PROP_LOD_FADE
		mmi.visibility_range_end = 4200.0 if mobile_perf else PROP_LOD_PROXY_END
		mmi.visibility_range_end_margin = 280.0 if mobile_perf else PROP_LOD_FADE * 2.5
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _spawn_tree_lods(points: Array[Transform3D]) -> void:
	# ============================================================
	# BOTW-STYLE TREE SYSTEM — Complete architectural rewrite.
	# The fundamental fix: SEPARATE trunk and foliage into TWO
	# independent MultiMesh stacks with completely different materials.
	#
	# TRUNK STACK: Fixed-color StandardMaterial3D (warm brown).
	#   No vertex colors. No instance colors. Always warm wood brown.
	#
	# FOLIAGE STACK: Unshaded StandardMaterial3D.
	#   vertex_color_use_as_albedo=true + per-instance biome colors.
	#   CULL_DISABLED so both sides of 2D cross-quads are visible.
	#   This CANNOT go black — unshaded always shows full albedo.
	# ============================================================
	
	# 2. FOLIAGE MATERIAL — Specialized Toon + Wind Shader
	var mobile_perf: bool = _is_mobile_perf()
	var foliage_mat: ShaderMaterial = ShaderMaterial.new()
	foliage_mat.shader = _get_res("res://src/shaders/foliage_toon.gdshader")
	foliage_mat.set_shader_parameter("shadow_strength", 0.6)
	foliage_mat.set_shader_parameter("wind_speed", 0.7)
	foliage_mat.set_shader_parameter("wind_strength", 0.4)
	foliage_mat.set_shader_parameter("leaf_texture", _get_tex("res://assets/textures/tree_leaves_texture.png"))
	foliage_mat.set_shader_parameter("normal_map", _get_tex("res://assets/textures/tree_leaves_texture_normal.png"))
	
	# 1. TRUNK MATERIAL — custom BoTW Toon Shader with hatching
	var trunk_mat: ShaderMaterial = ShaderMaterial.new()
	trunk_mat.shader = _get_res("res://src/shaders/trunk_toon.gdshader")
	trunk_mat.set_shader_parameter("albedo", Color(0.35, 0.25, 0.15))
	trunk_mat.set_shader_parameter("bark_texture", _get_tex("res://assets/textures/tree_trunk_texture.png"))
	trunk_mat.set_shader_parameter("normal_map", _get_tex("res://assets/textures/tree_trunk_texture_normal.png"))
	trunk_mat.set_shader_parameter("disp_map", _get_tex("res://assets/textures/tree_trunk_texture_displacement.png"))
	trunk_mat.set_shader_parameter("hatching_strength", 0.45)


	
	var n: int = points.size()
	# High-Detail chunks (sf <= 0.00055) now manage two simultaneous LOD models.
	if scale_factor <= 0.00055:
		var fol_h = _build_varied_foliage(true, 4); var mm_h = MultiMesh.new(); mm_h.transform_format = MultiMesh.TRANSFORM_3D; mm_h.use_colors = true; mm_h.mesh = fol_h; mm_h.instance_count = n
		var fol_m = _build_varied_foliage(false, 2); var mm_m = MultiMesh.new(); mm_m.transform_format = MultiMesh.TRANSFORM_3D; mm_m.use_colors = true; mm_m.mesh = fol_m; mm_m.instance_count = n
		var trk_h = _build_botw_trunk(true); var mt_th = MultiMesh.new(); mt_th.transform_format = MultiMesh.TRANSFORM_3D; mt_th.use_colors = true; mt_th.mesh = trk_h; mt_th.instance_count = n
		
		var aabb: AABB = _calculate_forest_aabb(points)
		mm_h.custom_aabb = aabb; mm_m.custom_aabb = aabb; mt_th.custom_aabb = aabb

		for i in range(n):
			var pos: Vector3 = points[i].origin
			var t_hue: float = fposmod(pal_forest_h + 0.5 + fposmod(pos.x * 0.012, 0.3) - 0.15, 1.0); var t_col: Color = Color.from_hsv(t_hue, 0.85, 1.1) 
			mm_h.set_instance_transform(i, points[i]); mm_h.set_instance_color(i, t_col)
			mm_m.set_instance_transform(i, points[i]); mm_m.set_instance_color(i, t_col)
			
			# ACE TRUNK VARIATION: Brown, Tan, and Birch-White
			var trk_seed = int(abs(pos.x * 133.0 + pos.z * 77.0)) % 3
			var tr_c = Color(0.35, 0.25, 0.15) # Default Brown
			if trk_seed == 1: tr_c = Color(0.55, 0.45, 0.35) # Light Tan
			elif trk_seed == 2: tr_c = Color(0.85, 0.85, 0.8) # Birch White
			mt_th.set_instance_transform(i, points[i]); mt_th.set_instance_color(i, tr_c)
			
			# AMBIENT LEAF DRIFT: Throttled to only spawn for the immediate local neighborhood (Optimization)
			if not mobile_perf and i % 15 == 0:
				var cam_p = Vector3.ZERO
				if is_instance_valid(get_viewport().get_camera_3d()):
					cam_p = get_viewport().get_camera_3d().global_position
				
				if pos.distance_to(cam_p) < 150.0:
					_spawn_leaf_emitter(points[i].origin, t_col)
		
		var mti_h = MultiMeshInstance3D.new(); mti_h.multimesh = mm_h; mti_h.material_override = foliage_mat; add_child(mti_h)
		var mti_m = MultiMeshInstance3D.new(); mti_m.multimesh = mm_m; mti_m.material_override = foliage_mat; add_child(mti_m)
		var mti_t = MultiMeshInstance3D.new(); mti_t.multimesh = mt_th; mti_t.material_override = trunk_mat; add_child(mti_t)
		
		# Unified LOD Policy Stacks
		_apply_planetary_lod_policy(mti_h, true)
		_apply_planetary_lod_policy(mti_m, false)
		_apply_planetary_lod_policy(mti_t, true) # Trunks only visible in High-Detail zone

		_spawn_prop_proxies(points, [mti_h, mti_m, mti_t], "Wood", 60, 15.0)
	else:
		# Mid/Far Chunk: Single simplified MultiMesh
		var mm = MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.use_colors = true; mm.instance_count = n
		mm.mesh = _build_varied_foliage(false, 2 if scale_factor < 0.003 else 1)
		var trk = _build_botw_trunk(false); var mm_t = MultiMesh.new(); mm_t.transform_format = MultiMesh.TRANSFORM_3D; mm_t.mesh = trk; mm_t.instance_count = n
		
		var aabb = _calculate_forest_aabb(points); mm.custom_aabb = aabb; mm_t.custom_aabb = aabb
		for i in range(n):
			var pos: Vector3 = points[i].origin; var t_hue: float = fposmod(pal_forest_h + 0.5 + fposmod(pos.x * 0.012, 0.3) - 0.15, 1.0); var t_col: Color = Color.from_hsv(t_hue, 0.85, 1.1) 
			mm.set_instance_transform(i, points[i]); mm.set_instance_color(i, t_col)
			mm_t.set_instance_transform(i, points[i])
		
		var mti = MultiMeshInstance3D.new(); mti.multimesh = mm; mti.material_override = foliage_mat; add_child(mti)
		var mti_tr = MultiMeshInstance3D.new(); mti_tr.multimesh = mm_t; mti_tr.material_override = trunk_mat; add_child(mti_tr)
		
		# Far-Distance LOD Policy
		_apply_planetary_lod_policy(mti, false)
		_apply_planetary_lod_policy(mti_tr, false)

func _calculate_forest_aabb(points: Array[Transform3D]) -> AABB:
	if points.is_empty(): return AABB()
	var min_v = points[0].origin; var max_v = points[0].origin
	for p in points: min_v = min_v.min(p.origin); max_v = max_v.max(p.origin)
	return AABB(min_v - Vector3(15,15,15), (max_v - min_v) + Vector3(30, 200, 30))

func _build_botw_trunk(is_high: bool) -> ArrayMesh:
	# 3D TRUNK: High-fidelity branch skeleton with fractal forking.
	var st: SurfaceTool = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color.WHITE)
	var sides: int = 8 if is_high else 4
	var h: float = 6.0; var rb: float = 0.8; var rt: float = 0.4
	
	# LEVEL 0: Main Trunk
	_add_tapered_cylinder(st, Vector3.ZERO, Vector3(0, h, 0), rb, rt, sides)
	
	if is_high:
		# LEVEL 1: Primary Limbs (4 main forks)
		var limbs: Array[Vector3] = [
			Vector3(2.5, h + 1.5, 1.5), Vector3(-2.2, h + 2.0, -1.2),
			Vector3(-1.5, h - 0.2, 3.2), Vector3(1.8, h + 3.0, -2.2)
		]
		var limb_starts: Array[Vector3] = [
			Vector3(0, h*0.6, 0), Vector3(0, h*0.75, 0),
			Vector3(0, h*0.5, 0), Vector3(0, h*0.8, 0)
		]
		
		for i in range(4):
			_add_tapered_cylinder(st, limb_starts[i], limbs[i], 0.35, 0.2, 5)
			
			# LEVEL 2: Secondary Twigs (2 forks per limb = 8 total twigs)
			var twig_1 = limbs[i] + (limbs[i] - limb_starts[i]).normalized() * 2.5 + Vector3(1.2, 1.5, 0.5)
			var twig_2 = limbs[i] + (limbs[i] - limb_starts[i]).normalized() * 2.0 + Vector3(-1.0, 1.2, -0.8)
			_add_tapered_cylinder(st, limbs[i], twig_1, 0.2, 0.05, 3)
			_add_tapered_cylinder(st, limbs[i], twig_2, 0.18, 0.05, 3)
	
	st.generate_normals(false)
	st.generate_tangents()
	return st.commit()

func _build_botw_foliage(is_high: bool, complexity: int) -> ArrayMesh:
	# ============================================================
	# DISTRIBUTED PATCHY CANOPY - SYNC'D TO FRACTAL LIMBS
	# ============================================================
	var st: SurfaceTool = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color.WHITE)
	
	var h: float = 6.0
	var clump_centers: Array[Vector3] = [Vector3(0, h + 1.5, 0)] # Crown
	
	if is_high:
		# Match the Level 2 twig endpoints for precise coverage
		var limbs: Array[Vector3] = [Vector3(2.5, h + 1.5, 1.5), Vector3(-2.2, h + 2.0, -1.2), Vector3(-1.5, h - 0.2, 3.2), Vector3(1.8, h + 3.0, -2.2)]
		var limb_starts: Array[Vector3] = [Vector3(0, h*0.6, 0), Vector3(0, h*0.75, 0), Vector3(0, h*0.5, 0), Vector3(0, h*0.8, 0)]
		for i in range(4):
			clump_centers.append(limbs[i] + (limbs[i] - limb_starts[i]).normalized() * 2.5 + Vector3(1.2, 1.5, 0.5))
			clump_centers.append(limbs[i] + (limbs[i] - limb_starts[i]).normalized() * 2.0 + Vector3(-1.0, 1.2, -0.8))
	else:
		clump_centers.append_array([Vector3(2, h, 2), Vector3(-2, h+1, -2)]) # Simplified
	
	for c_idx in range(clump_centers.size()):
		var canopy_center: Vector3 = clump_centers[c_idx]
		# GENEROUS RADIUS: Pure clumpy volume
		var canopy_radius: float = 1.8 if c_idx == 0 else 1.5
		
		# ORGANIC CLUMP COUNT: Increase count for rounder 'Pom-Pom' volume
		var n_cards: int = 12 if is_high else 4
		if complexity > 3: n_cards = 24
		
		for i in range(n_cards):
			var seed_idx: int = i + c_idx * 31
			var f: float = float(i) / float(n_cards)
			var phi: float = acos(1.0 - 2.0 * f)
			var theta: float = PI * (1.0 + sqrt(5.0)) * float(seed_idx)
			
			var radial_dir = Vector3(cos(theta)*sin(phi), sin(theta)*sin(phi), cos(phi))
			var bpos: Vector3 = radial_dir * (canopy_radius * (0.6 + fposmod(float(seed_idx)*1.618, 0.4))) + canopy_center
			
			# SMALLER, SCALLOPED CARDS (Focus on clumping)
			var sz: float = 0.6 + fposmod(float(i) * 0.44, 0.5)
			
			var up_vec = Vector3.UP
			if abs(radial_dir.dot(up_vec)) > 0.9: up_vec = Vector3.RIGHT
			var look_basis = Basis.looking_at(radial_dir, up_vec)
			look_basis = look_basis.rotated(radial_dir, fposmod(float(seed_idx)*0.77, TAU))
			
			# 3-PLANE CLUMP (Procedural orientations)
			var norm = radial_dir.normalized()
			for k in range(3):
				var plane_phi = (float(k) * PI / 3.0) + fposmod(float(seed_idx+k)*2.2, 0.4) - 0.2
				var plane_basis = look_basis.rotated(radial_dir, plane_phi)
				
				# SOFT SCALLOPED GEOM (8-point rounded burst)
				var pts: Array[Vector3] = []
				var uvs: Array[Vector2] = []
				var cols: Array[Color] = []
				for j in range(8):
					var ang = j * TAU / 8.0
					# Scalloped radius: Very subtle indentation (0.85) for soft leaf feel
					var dist: float = 1.0 if j % 2 == 0 else 0.85
					var jitter: float = dist * (1.0 + (fposmod(float(seed_idx + j)*1.414, 0.1) - 0.05))
					
					var local_p = Vector3(cos(ang), sin(ang), 0) * sz * jitter
					pts.append(bpos + plane_basis * local_p)
					uvs.append(Vector2(0.5 + cos(ang)*0.5, 0.5 + sin(ang)*0.5))
					cols.append(Color(0.9, 0.9, 0.9, 1.0))
				
				# Build triangles with CENTRIC HIGHLIGHT and BRANCH-SPECIFIC HUE OFFSET
				# We store a unique variation seed in the Blue channel for the shader to interpret
				var branch_var = fposmod(float(c_idx) * 0.618, 1.0) 
				var center_color = Color(1.1, 1.1, 0.5 + branch_var * 0.5, 1.0) 
				var edge_color = Color(0.9, 0.9, branch_var, 1.0)
				
				for j in range(8):
					var j2 = (j + 1) % 8
					st.set_normal(norm); st.set_color(center_color); st.set_uv(Vector2(0.5, 0.5)); st.add_vertex(bpos)
					st.set_normal(norm); st.set_color(edge_color); st.set_uv(uvs[j]); st.add_vertex(pts[j])
					st.set_normal(norm); st.set_color(edge_color); st.set_uv(uvs[j2]); st.add_vertex(pts[j2])

	st.generate_tangents()
	return st.commit()

func _spawn_leaf_emitter(center: Vector3, col: Color) -> void:
	# ACE OPTIMIZATION: Zero-cost instantiation via static resource caching
	var p = CPUParticles3D.new()
	p.fixed_fps = 0; p.fract_delta = true 
	
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(18, 15, 18)
	p.direction = Vector3(0, -1, 0); p.gravity = Vector3(0, -0.01, 0)
	p.initial_velocity_min = 0.05; p.initial_velocity_max = 0.2
	p.damping_min = 0.05; p.damping_max = 0.1
	
	p.scale_amount_curve = _get_leaf_scale_curve()
	p.speed_scale = 0.02
	p.angle_max = 360.0; p.angle_min = -360.0
	p.angular_velocity_min = 40.0; p.angular_velocity_max = 180.0
	p.amount = 20; p.lifetime = 60.0 
	p.local_coords = false 
	p.color_ramp = _get_leaf_gradient()
	p.color = col
	
	p.mesh = _get_leaf_mesh()
	p.position = center + Vector3(0, 25, 0)
	p.visibility_aabb = AABB(Vector3(-50,-150,-50), Vector3(100,300,100))
	p.visibility_range_end = 250.0; p.visibility_range_end_margin = 80.0
	p.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	
	add_child(p)
	
	# ACE MEMORY HARDENING: Ensure ephemeral botanical emitters are purged!
	# Without this, high-density forest flight causes a massive 'Node Leak' that kills framerate.
	var t = get_tree().create_timer(p.lifetime + 1.0)
	t.timeout.connect(func(): if is_instance_valid(p): p.queue_free())

static var _leaf_mesh: QuadMesh = null
static func _get_leaf_mesh() -> QuadMesh:
	if _leaf_mesh: return _leaf_mesh
	_leaf_mesh = QuadMesh.new(); _leaf_mesh.size = Vector2(3.0, 5.5)
	var sm = StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.albedo_texture = _get_tex("res://assets/textures/falling_leaf_texture_1775970377159.png")
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sm.vertex_color_use_as_albedo = true
	sm.backlight_enabled = true; sm.backlight = Color(0.2, 0.4, 0.1)
	_leaf_mesh.surface_set_material(0, sm)
	return _leaf_mesh

static var _leaf_scale_curve: Curve = null
static func _get_leaf_scale_curve() -> Curve:
	if _leaf_scale_curve: return _leaf_scale_curve
	_leaf_scale_curve = Curve.new()
	_leaf_scale_curve.add_point(Vector2(0, 0)); _leaf_scale_curve.add_point(Vector2(0.1, 1))
	_leaf_scale_curve.add_point(Vector2(0.8, 1)); _leaf_scale_curve.add_point(Vector2(1, 0))
	return _leaf_scale_curve

static var _leaf_gradient: Gradient = null
static func _get_leaf_gradient() -> Gradient:
	if _leaf_gradient: return _leaf_gradient
	_leaf_gradient = Gradient.new()
	_leaf_gradient.set_color(0, Color(1, 1, 1, 1)); _leaf_gradient.set_color(1, Color(1, 1, 1, 0))
	return _leaf_gradient

static var _leaf_p_shader: Shader = null
static func _get_leaf_p_shader() -> Shader:
	if _leaf_p_shader: return _leaf_p_shader
	_leaf_p_shader = Shader.new()
	_leaf_p_shader.code = """shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D leaf_tex;
varying float v_life;
void vertex() {
	v_life = INSTANCE_CUSTOM.y;
	float t = floor((TIME + float(INSTANCE_ID) * 0.45) * 8.0) / 8.0;
	float sway = sin(t * 1.5 + float(INSTANCE_ID)) * 2.5;
	VERTEX.x += sway * (1.0 - v_life);
	VERTEX.z += cos(t * 1.2) * 1.5 * (1.0 - v_life);
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(INV_VIEW_MATRIX[2].xyz, 0.0), vec4(VERTEX.xyz, 1.0));
}
void fragment() {
	vec4 tex = texture(leaf_tex, UV);
	float luma = (tex.r + tex.g + tex.b) / 3.0;
	if (luma > 0.95) discard;
	ALBEDO = COLOR.rgb * tex.rgb;
	ALPHA = (1.0 - smoothstep(0.8, 1.0, v_life)) * (1.0 - smoothstep(0.9, 1.0, luma));
}"""
	return _leaf_p_shader

static var _grass_shader: Shader = null
static func _get_grass_shader() -> Shader:
	if _grass_shader: return _grass_shader
	_grass_shader = Shader.new()
	_grass_shader.code = """shader_type spatial; render_mode diffuse_toon, specular_toon, cull_disabled;
varying vec3 v_world_pos;
varying float v_h_jitter;
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_h_jitter = INSTANCE_CUSTOM.x;
	if (VERTEX.y > 0.05) {
		float d = distance(v_world_pos, CAMERA_POSITION_WORLD);
		float proximity = 1.0 - smoothstep(12.0, 120.0, d);
		float t = floor(TIME * 8.0) / 8.0;
		VERTEX.x += sin(t * 2.1 + v_world_pos.x * 0.15) * 2.5 * VERTEX.y * (1.1 + proximity * 4.0);
		VERTEX.z += cos(t * 1.8 + v_world_pos.z * 0.15) * 2.0 * VERTEX.y * (1.1 + proximity * 4.0);
	}
}
void fragment() {
	ALBEDO = mix(vec3(0.1, 0.4, 0.1), vec3(0.3, 0.8, 0.2), v_h_jitter);
	ROUGHNESS = 0.8;
}"""
	return _grass_shader

func _spawn_grass(points: Array[Transform3D]) -> void:
	if points.is_empty(): return
	var mm = MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = _build_grass_mesh()
	mm.use_custom_data = true 
	mm.instance_count = points.size()
	for i in range(points.size()): 
		mm.set_instance_transform(i, points[i])
		var j = fmod(float(hash(points[i].origin)), 10.0)/10.0
		mm.set_instance_custom_data(i, Color(j, 0, 0, 0))
	
	var mmi_h = MultiMeshInstance3D.new()
	mmi_h.multimesh = mm
	var mat = ShaderMaterial.new()
	mat.shader = _get_grass_shader()
	mmi_h.material_override = mat
	
	mmi_h.visibility_range_end = 800.0; mmi_h.visibility_range_end_margin = 200.0; mmi_h.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(mmi_h); _flora_nodes.append(mmi_h)
	
func _spawn_city_buildings(points: Array[Transform3D]) -> void:
	if points.is_empty(): return
	
	# ACE ASSET CACHE: Pre-load all metropolitan logic once per session
	if _skyscraper_shader == null: _init_skyscraper_assets()
	
	var roof_t = _roof_assets["t"]; var roof_n = _roof_assets["n"]
	var roof_s = _roof_assets["s"]; var roof_d = _roof_assets["d"]; var roof_a = _roof_assets["a"]
	
	# ACE METROPOLITAN SLAB
	var f_mm = MultiMesh.new(); f_mm.transform_format = MultiMesh.TRANSFORM_3D
	f_mm.mesh = _get_box_mesh(Vector3(6000, 60.0, 6000))
	f_mm.instance_count = points.size()
	var f_mat = StandardMaterial3D.new(); f_mat.albedo_color = Color(0.08, 0.08, 0.09); f_mat.roughness = 0.95
	for i in range(points.size()): f_mm.set_instance_transform(i, points[i].translated_local(Vector3(0, -32, 0)))
	var f_mmi = MultiMeshInstance3D.new(); f_mmi.multimesh = f_mm; f_mmi.material_override = f_mat; add_child(f_mmi); _flora_nodes.append(f_mmi)
	f_mmi.visibility_range_end = 2000000.0; f_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	
	# ACE DISTRICT SHADER: 4-Lane Highways + Sidewalks
	var road_shader = Shader.new()
	road_shader.code = """shader_type spatial;
	uniform vec3 neon_col : source_color = vec3(0.0, 1.0, 1.0);
	varying vec3 v_local_pos;
	void vertex() { v_local_pos = VERTEX; }
	void fragment() {
		float x_abs = abs(v_local_pos.x);
		float is_sw = step(120.0, x_abs); // 40m sidewalks on each side of 320m road
		ALBEDO = mix(vec3(0.05, 0.05, 0.06), vec3(0.18, 0.18, 0.20), is_sw);
		float lanes = 0.0;
		for(int i=-2; i<=1; i++) {
			float lx = float(i) * 45.0 + 22.5;
			lanes += step(0.95, 1.0 - abs(v_local_pos.x - lx) * 0.2);
		}
		lanes *= (1.0 - is_sw);
		float pulse = step(0.6, fract(v_local_pos.z * 0.03 - TIME * 3.0));
		EMISSION = neon_col * lanes * pulse * 15.0;
		ROUGHNESS = 0.8;
	}"""
	var r_mat = ShaderMaterial.new(); r_mat.shader = road_shader
	
	# CITY GENERATION DEACTIVATED BY ARCHITECT
	pass
	
	# ACE SPACE-IMPOSTOR LOGIC: Faking the city from orbit
	if scale_factor > 0.1:
		var i_mm = MultiMesh.new(); i_mm.transform_format = MultiMesh.TRANSFORM_3D
		i_mm.mesh = _get_box_mesh(Vector3(4500, 10, 4500))
		i_mm.instance_count = points.size()
		for i in points.size(): i_mm.set_instance_transform(i, points[i].translated_local(Vector3(0, -5, 0)))
		var i_mmi = MultiMeshInstance3D.new(); i_mmi.multimesh = i_mm; i_mmi.material_override = _get_impostor_mat()
		i_mmi.visibility_range_end = 2000000.0; i_mmi.visibility_range_begin = 33000.0; i_mmi.visibility_range_begin_margin = 10000.0; i_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(i_mmi); _flora_nodes.append(i_mmi)
	
	# CITY GENERATION DEACTIVATED BY ARCHITECT
	pass
  

func _get_rock_xform(pos: Vector3, up: Vector3, noise_val: float, b_scale: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	# TITANIC SCALE VARIANCE: 0.2x Pebbles to 5.0x Monoliths
	var r_rand = abs(fmod(noise_val * 4123.0, 1.0))
	var s_mult = 0.2 + (pow(r_rand, 3.2) * 4.8) # Non-linear distribution: Many small, few massive
	return Transform3D(t_bas, pos).scaled_local(Vector3(b_scale*s_mult, b_scale*s_mult*(0.8+r_rand*0.4), b_scale*s_mult)).rotated_local(Vector3.UP, abs(fmod(noise_val*9999.0,PI*2.0)))

func _get_grass_xform(pos: Vector3, up: Vector3, rand_val: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	# GHIBLI GRASS TUNED: A perfect middle-ground scale so fields don't overwhelm the geometry
	var s = 2.5 + (rand_val * 2.0)
	return Transform3D(t_bas, pos).scaled_local(Vector3(s, s*(0.8+rand_val*0.6), s)).rotated_local(Vector3.UP, rand_val*PI*2.0)

func _build_faceted_rock_mesh(sides: int) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var r1 = 8.0
	var y1 = 4.0
	var r2 = 5.5
	var y2 = 7.5
	var top = Vector3(2.0, 9.5, -1.0)
	
	# ROCK GEOMETRY: Explicitly CCW winding for manifold solidity
	# This ensures we never see 'inside' the rocks by providing a full shell.
	for i in range(sides):
		var a1 = i * TAU / sides
		var a2 = (i + 1) * TAU / sides
		
		# Base Circle (Rooted -2m to prevent gaps)
		var b1 = Vector3(cos(a1) * r1, -2.0, sin(a1) * r1)
		var b2 = Vector3(cos(a2) * r1, -2.0, sin(a2) * r1)
		
		# Mid Tier (with jitter for jagged look)
		var j1 = sin(a1 * 3.5) * 1.5
		var j2 = sin(a2 * 3.5) * 1.5
		var m1 = Vector3(cos(a1) * (r1 + j1), y1 + j1, sin(a1) * (r1 + j1))
		var m2 = Vector3(cos(a2) * (r1 + j2), y1 + j2, sin(a2) * (r1 + j2))
		
		# Top Tier
		var t1 = Vector3(cos(a1) * r2, y2 + j1 * 0.5, sin(a1) * r2)
		var t2 = Vector3(cos(a2) * r2, y2 + j2 * 0.5, sin(a2) * r2)
		
		# COLOR SCHEME: Varied greys for faceted look
		var c_side = Color(0.35, 0.35, 0.35)
		var c_mid = Color(0.45, 0.45, 0.45)
		var c_top = Color(0.55, 0.55, 0.55)
		
		# 1. LOWER SIDES (CCW: b1, m2, m1 and b2, m2, b1)
		st.set_color(c_side)
		st.set_uv(Vector2(float(i)/sides, 0)); st.add_vertex(b1)
		st.set_uv(Vector2(float(i+1)/sides, 0.4)); st.add_vertex(m2)
		st.set_uv(Vector2(float(i)/sides, 0.4)); st.add_vertex(m1)
		
		st.set_uv(Vector2(float(i+1)/sides, 0)); st.add_vertex(b2)
		st.set_uv(Vector2(float(i+1)/sides, 0.4)); st.add_vertex(m2)
		st.set_uv(Vector2(float(i)/sides, 0)); st.add_vertex(b1)
		
		# 2. UPPER SIDES (CCW: m1, t2, t1 and m2, t2, m1)
		st.set_color(c_mid)
		st.set_uv(Vector2(float(i)/sides, 0.4)); st.add_vertex(m1)
		st.set_uv(Vector2(float(i+1)/sides, 0.8)); st.add_vertex(t2)
		st.set_uv(Vector2(float(i)/sides, 0.8)); st.add_vertex(t1)
		
		st.set_uv(Vector2(float(i+1)/sides, 0.4)); st.add_vertex(m2)
		st.set_uv(Vector2(float(i+1)/sides, 0.8)); st.add_vertex(t2)
		st.set_uv(Vector2(float(i)/sides, 0.4)); st.add_vertex(m1)
		
		# 3. CAP (CCW: t1, t2, top)
		st.set_color(c_top)
		st.set_uv(Vector2(float(i)/sides, 0.8)); st.add_vertex(t1)
		st.set_uv(Vector2(float(i+1)/sides, 0.8)); st.add_vertex(t2)
		st.set_uv(Vector2(0.5, 1.0)); st.add_vertex(top)
		
		# 4. BOTTOM CAP (CCW: 0, b1, b2)
		st.set_color(c_side * 0.8)
		st.set_uv(Vector2(0.5, 0.0)); st.add_vertex(Vector3.ZERO)
		st.set_uv(Vector2(float(i)/sides, 0)); st.add_vertex(b1)
		st.set_uv(Vector2(float(i+1)/sides, 0)); st.add_vertex(b2)
		
	st.generate_normals(false)
	st.generate_tangents()
	return st.commit()

func _build_lush_tree(is_high: bool, complexity: int) -> ArrayMesh:
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# ===== TRUNK =====
	# Alpha=0.0 so the foliage shader renders this as fixed wood-brown, never affected by biome.
	var trunk_sides: int = 6 if is_high else 4
	var trunk_h: float = 5.5
	var trunk_r: float = 1.3
	st.set_color(Color(1.0, 1.0, 1.0, 1.0)) 
	_add_tapered_cylinder(st, Vector3.ZERO, Vector3(0, trunk_h, 0), trunk_r, trunk_r * 0.28, trunk_sides)
	
	# ===== CANOPY (OVAL ENVELOPE) =====
	# Alpha=1.0 so the foliage shader uses the per-instance biome color.
	# Shape: sin(t*PI) envelope creates a wide middle, narrow top/bottom — exactly like the reference.
	st.set_color(Color(1.0, 1.0, 1.0, 1.0))
	var canopy_base: float = trunk_h * 0.5  # Canopy starts halfway up the trunk
	var canopy_top: float  = trunk_h + 8.0  # Canopy extends 8 units above trunk tip
	var canopy_span: float = canopy_top - canopy_base
	var max_canopy_r: float = 4.5  # Max half-width of the oval canopy
	
	var rings: int = clamp(complexity, 2, 5)
	for ring_i in range(rings):
		# t goes 0→1 over the canopy height
		var t: float = float(ring_i) / float(rings - 1) if rings > 1 else 0.5
		var ry: float = canopy_base + t * canopy_span
		
		# OVAL ENVELOPE: sin(t*PI) gives 0..1..0 symmetrical bullet shape
		var envelope: float = sin(t * PI)
		var ring_r: float = max_canopy_r * envelope
		var blob_sz: float = 2.8 + envelope * 1.5  # Bigger blobs in the fat middle
		
		# Ring of blobs around this height
		var n_ring: int = int(envelope * 5.0 + 1.0)
		for b in range(n_ring):
			var ang: float = float(b) / float(n_ring) * TAU + float(ring_i) * 0.44  # Stagger per ring
			var bpos = Vector3(cos(ang) * ring_r * 0.75, ry, sin(ang) * ring_r * 0.75)
			_add_lush_blob(st, bpos, blob_sz, is_high)
		
		# Center blob fills the middle so canopy looks dense, not hollow
		_add_lush_blob(st, Vector3(0.0, ry + 0.4, 0.0), 2.4 + envelope * 2.0, is_high)
	
	st.generate_normals(false)
	st.generate_tangents()
	return st.commit()

func _add_tapered_cylinder(st: SurfaceTool, start: Vector3, end: Vector3, r1: float, r2: float, sides: int) -> void:
	var fwd = (end - start).normalized()
	var right = fwd.cross(Vector3.UP if abs(fwd.y) < 0.9 else Vector3.RIGHT).normalized()
	var up = right.cross(fwd).normalized()
	
	for i in range(sides):
		var a1 = i * TAU / sides; var a2 = (i + 1) * TAU / sides
		var p1 = start + (right * cos(a1) + up * sin(a1)) * r1
		var p2 = start + (right * cos(a2) + up * sin(a2)) * r1
		var p3 = end + (right * cos(a1) + up * sin(a1)) * r2
		var p4 = end + (right * cos(a2) + up * sin(a2)) * r2
		
		var u1 = float(i) / sides; var u2 = float(i + 1) / sides
		st.set_uv(Vector2(u1, 1)); st.add_vertex(p1)
		st.set_uv(Vector2(u2, 1)); st.add_vertex(p2)
		st.set_uv(Vector2(u2, 0)); st.add_vertex(p4)
		
		st.set_uv(Vector2(u1, 1)); st.add_vertex(p1)
		st.set_uv(Vector2(u2, 0)); st.add_vertex(p4)
		st.set_uv(Vector2(u1, 0)); st.add_vertex(p3)

func _add_lush_blob(st: SurfaceTool, center: Vector3, size: float, is_high: bool) -> void:
	# Add a faceted sphere-like blob for the canopy
	var rings = 3 if is_high else 2
	var segments = 5 if is_high else 4
	for r in range(rings):
		var lat1 = PI * r / rings
		var lat2 = PI * (r + 1) / rings
		for s in range(segments):
			var lon1 = TAU * s / segments
			var lon2 = TAU * (s + 1) / segments
			
			var v1 = center + Vector3(sin(lat1)*cos(lon1), cos(lat1), sin(lat1)*sin(lon1)) * size
			var v2 = center + Vector3(sin(lat1)*cos(lon2), cos(lat1), sin(lat1)*sin(lon2)) * size
			var v3 = center + Vector3(sin(lat2)*cos(lon1), cos(lat2), sin(lat2)*sin(lon1)) * size
			var v4 = center + Vector3(sin(lat2)*cos(lon2), cos(lat2), sin(lat2)*sin(lon2)) * size
			
			var u1 = float(s) / segments
			var u2 = float(s + 1) / segments
			var v1_uv = float(r) / rings
			var v2_uv = float(r + 1) / rings
			
			st.set_uv(Vector2(u1, v1_uv)); st.add_vertex(v1)
			st.set_uv(Vector2(u2, v1_uv)); st.add_vertex(v2)
			st.set_uv(Vector2(u2, v2_uv)); st.add_vertex(v4)
			
			st.set_uv(Vector2(u1, v1_uv)); st.add_vertex(v1)
			st.set_uv(Vector2(u2, v2_uv)); st.add_vertex(v4)
			st.set_uv(Vector2(u1, v2_uv)); st.add_vertex(v3)

func _build_low_tree() -> ArrayMesh:
	if c_t_l: return c_t_l
	c_t_l = _build_botw_foliage(false, 1)
	return c_t_l

func _build_med_tree() -> ArrayMesh:
	if c_t_m: return c_t_m
	c_t_m = _build_botw_foliage(false, 2)
	return c_t_m

func _build_high_tree() -> ArrayMesh:
	if c_t_h: return c_t_h
	c_t_h = _build_botw_foliage(true, 4)
	return c_t_h

func _build_varied_foliage(is_high: bool, complexity: int) -> ArrayMesh:
	match archetype:
		"DESERT": return _build_cactus_mesh(is_high)
		"VOLCANIC", "ABYSS": return _build_crystal_spire(is_high)
		"FROZEN": return _build_ice_fan(is_high)
		"TOXIC", "CANDY", "RADIATED", "LUSH", _: 
			return _build_botw_foliage(is_high, complexity)

func _build_cactus_mesh(is_high: bool) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color(1, 1, 1, 1)) # Alpha=0 -> stem uses fixed desert green in shader
	_add_tapered_cylinder(st, Vector3.ZERO, Vector3(0, 9, 0), 1.3, 1.0, 5 if is_high else 4)
	for i in range(2):
		var side = 1.0 if i == 0 else -1.0
		var arm_y = 3.5 + i * 2.0
		_add_tapered_cylinder(st, Vector3(0, arm_y, 0), Vector3(side*2.2, arm_y, 0), 0.7, 0.5, 3)
		_add_tapered_cylinder(st, Vector3(side*2.2, arm_y, 0), Vector3(side*2.2, arm_y+2.8, 0), 0.5, 0.4, 3)
	st.set_color(Color(1, 1, 1, 1)) # flower crown takes biome color
	for i in range(6):
		var ang = i * TAU / 6.0
		_add_tapered_cylinder(st, Vector3(0, 9.2, 0), Vector3(cos(ang)*1.5, 10.5, sin(ang)*1.5), 0.3, 0.05, 3)
	st.generate_normals(false); st.generate_tangents()
	return st.commit()

func _build_fungal_mesh(is_high: bool) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color(1, 1, 1, 1)) # Alpha=0 → fixed purple stalk
	_add_tapered_cylinder(st, Vector3.ZERO, Vector3(0, 5, 0), 0.9, 0.5, 4)
	st.set_color(Color(1, 1, 1, 1)) # Alpha=1 → caps take biome color
	_add_lush_blob(st, Vector3(0, 5.5, 0), 4.5, is_high)
	if is_high:
		_add_lush_blob(st, Vector3(1.5, 3.8, 0.5), 2.5, false)
		_add_lush_blob(st, Vector3(-1.2, 3.0, 1.0), 2.0, false)
	st.generate_normals(false); st.generate_tangents()
	return st.commit()

func _build_crystal_spire(is_high: bool) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Alpha=0 → shader uses fixed dark crystal base (the old near-black Color caused black trees!)
	st.set_color(Color(1, 1, 1, 1))
	_add_tapered_cylinder(st, Vector3.ZERO, Vector3(0, 10, 0), 1.5, 0.05, 4)
	var count = 4 if is_high else 2
	for i in range(count):
		var ang = i * TAU / float(count)
		var off = Vector3(cos(ang)*1.8, 0, sin(ang)*1.8)
		var h = 5.0 + sin(float(i)*1.3) * 2.0
		_add_tapered_cylinder(st, off * 0.5 + Vector3(0,1,0), off * 0.2 + Vector3(0, h, 0), 0.7, 0.02, 3)
	_add_lush_blob(st, Vector3(0, 10.5, 0), 1.8, false)
	st.generate_normals(false); st.generate_tangents()
	return st.commit()

func _build_ice_fan(is_high: bool) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color(1, 1, 1, 1)) # fixed white base
	_add_tapered_cylinder(st, Vector3.ZERO, Vector3(0, 2, 0), 0.6, 0.4, 4)
	st.set_color(Color(1, 1, 1, 1)) # fans take frost biome color
	var fans = 5 if is_high else 3
	for i in range(fans):
		var ang = i * TAU / float(fans) + 0.3
		var dir = Vector3(cos(ang)*0.65, 1.0, sin(ang)*0.65).normalized() * 7.0
		_add_tapered_cylinder(st, Vector3(0, 2, 0), dir + Vector3(0, 2, 0), 0.4, 0.03, 3)
	st.generate_normals(false); st.generate_tangents()
	return st.commit()

func _build_glow_bulb(is_high: bool) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_color(Color(1, 1, 1, 1)) # fixed dark stalk
	_add_tapered_cylinder(st, Vector3.ZERO, Vector3(0, 7, 0), 0.35, 0.2, 3)
	st.set_color(Color(1, 1, 1, 1)) # glowing bulbs use biome radiation color
	_add_lush_blob(st, Vector3(0, 7.5, 0), 2.5, is_high)
	if is_high:
		for i in range(3):
			var ang = i * TAU / 3.0
			_add_lush_blob(st, Vector3(cos(ang)*1.2, 6.5, sin(ang)*1.2), 1.5, false)
	st.generate_normals(false); st.generate_tangents()
	return st.commit()

func _build_grass_mesh() -> ArrayMesh:
	if c_g: return c_g
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# ACE BOTW/NMS GRASS: Dense, tall, swooping grassy thickets scattered lushly
	var rng = RandomNumberGenerator.new(); rng.seed = 1337
	var blades = 12
	for i in range(blades):
		var ang = rng.randf() * TAU; var dist = rng.randf() * 1.0
		# Mid-range thick toon foliage
		var h = 1.2 + rng.randf() * 1.6; var w = 0.35 + rng.randf() * 0.25
		var dir = Vector3(cos(ang), 0.0, sin(ang)) * dist
		var side = Vector3(cos(ang + PI/2.0), 0.0, sin(ang + PI/2.0)) * w
		# Add a tilt pointing outward so it fans beautifully like real brush
		var top_offset = Vector3(cos(ang), 0.0, sin(ang)) * (0.4 + rng.randf() * 0.7)
		st.add_vertex(dir - side)
		st.add_vertex(dir + side)
		st.add_vertex(dir + Vector3(0.0, h, 0.0) + top_offset)
	st.generate_normals(false); st.generate_tangents()
	c_g = st.commit(); return c_g

static var _shared_land_shader: Shader = null
static func _get_shared_land_shader() -> Shader:
	if _shared_land_shader: return _shared_land_shader
	_shared_land_shader = Shader.new()
	_shared_land_shader.code = """shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
varying float v_height;
varying vec3 v_world_pos;
varying vec3 v_normal;

uniform sampler2D ground_tex : source_color;
uniform sampler2D mountain_tex : source_color;
uniform sampler2D snow_tex : source_color;

uniform sampler2D ground_norm : hint_normal;
uniform sampler2D mountain_norm : hint_normal;
uniform sampler2D snow_norm : hint_normal;

uniform sampler2D ground_disp;
uniform sampler2D mountain_disp;
uniform sampler2D snow_disp;
uniform float radius;
uniform float sea_level;
uniform vec3 col_beach;   // Sandy shores just above sea level
uniform vec3 col_grass;   // Main low-altitude biome color
uniform vec3 col_forest;  // Mid-altitude transition / secondary tone
uniform vec3 col_rock;    // High altitude and steep cliff color
uniform vec3 continent_pole;

float aa_step(float edge, float val) {
	float delta = fwidth(val) * 1.5; 
	return smoothstep(edge - delta, edge + delta, val);
}

varying vec3 v_local_norm;
varying float v_steepness;

void vertex() {
	v_height = length(VERTEX) - radius;
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_local_norm = normalize(VERTEX);
	
	// ACE SPHERICAL SLOPE: Dot product of Face Normal and Planet-Core Vector
	// 1.0 indicates ground perfectly parallel to the horizon.
	v_steepness = dot(normalize(VERTEX), NORMAL);
}
void fragment() {
	vec3 col_snow = vec3(0.97, 0.97, 1.0); // Slightly blue-white snow caps
	vec3 blending = abs(v_normal);
	blending /= (blending.x + blending.y + blending.z);
	float tex_scale = 0.005;
	vec3 tex_x = texture(ground_tex, v_world_pos.zy * tex_scale).rgb;
	vec3 tex_y = texture(ground_tex, v_world_pos.xz * tex_scale).rgb;
	vec3 tex_z = texture(ground_tex, v_world_pos.xy * tex_scale).rgb;
	vec3 detail_tex = tex_x * blending.x + tex_y * blending.y + tex_z * blending.z;
	vec3 m_tex_x = texture(mountain_tex, v_world_pos.zy * tex_scale).rgb;
	vec3 m_tex_y = texture(mountain_tex, v_world_pos.xz * tex_scale).rgb;
	vec3 m_tex_z = texture(mountain_tex, v_world_pos.xy * tex_scale).rgb;
	vec3 m_detail = m_tex_x * blending.x + m_tex_y * blending.y + m_tex_z * blending.z;
	float detail_level = mix(0.88, 1.12, detail_tex.r); // Tighter range = less muddying
	float m_detail_level = mix(0.90, 1.10, m_detail.r);
	vec3 s_tex_x = texture(snow_tex, v_world_pos.zy * tex_scale).rgb;
	vec3 s_tex_y = texture(snow_tex, v_world_pos.xz * tex_scale).rgb;
	vec3 s_tex_z = texture(snow_tex, v_world_pos.xy * tex_scale).rgb;
	vec3 s_detail = s_tex_x * blending.x + s_tex_y * blending.y + s_tex_z * blending.z;
	float s_detail_level = mix(0.92, 1.08, s_detail.r);
	
	// LUSH PATCHES: 2D noise mask to create distinct light-green meadows
	float grass_patch = smoothstep(0.1, 0.4, texture(ground_tex, v_world_pos.xz * 0.0015).r + sin(v_world_pos.x * 0.05)*0.1);
	vec3 base_grass = mix(col_forest, col_grass, grass_patch);
	
	// MULTI-TONE HEIGHT ZONES: 5 distinct color bands driven by terrain elevation
	// Each zone has a slight noise warp on its edge for organic variation
	float b_warp = sin(v_world_pos.x * 0.0015) * 300.0 + cos(v_world_pos.z * 0.002) * 200.0;
	float warped_h = v_height + b_warp;
	
	// ACE METROPOLITAN DECENTRALIZATION: Hyper-Localized Multi-city distribution
	float raw_global = max(0.0, sin(v_local_norm.x * 1.5) * cos(v_local_norm.y * 1.4 + v_local_norm.z * 1.2));
	float global_mask = pow(raw_global, 3.0);
	float n_base = pow(max(0.0, sin(v_local_norm.x * 12.0) * cos(v_local_norm.y * 11.0) * sin(v_local_norm.z * 13.0)), 2.0);
	float city_shore_mask = smoothstep(sea_level, sea_level + 150.0, v_height);
	float city_mask = smoothstep(0.4, 0.6, n_base * global_mask) * city_shore_mask;
	
	// Zone boundaries (above sea level)
	float beach_warp = sin(v_world_pos.x * 0.008) * 15.0 + cos(v_world_pos.z * 0.01) * 10.0;
	float t_beach_end  = aa_step(sea_level + 120.0 + beach_warp, v_height);   // Beach -> Grass
	float t_midland    = aa_step(800.0, warped_h);                             // Grass -> Forest/Mid
	float t_rock_start = aa_step(1800.0, warped_h);                            // Mid -> Rock
	float t_snow       = aa_step(3200.0, warped_h);                            // Rock -> Snow
	
	// SLOPE-BASED CLIFF DETECTION: Faces pointing sideways are cliff walls regardless of height
	// v_steepness: 1.0=flat ground relative to gravity, 0.0=sheer vertical cliff
	float slope = abs(v_steepness); 
	float cliff_mask = 1.0 - smoothstep(0.3, 0.65, slope); // Steep faces become rock
	
	// Build up from bottom to top
	vec3 albedo = col_beach;
	albedo = mix(albedo, base_grass, t_beach_end);          // Sandy shore -> lush patchy grass
	albedo = mix(albedo, col_rock * m_detail_level, t_rock_start); // Mid -> high-alt rock
	albedo = mix(albedo, col_snow * s_detail_level, t_snow); // Rock -> snow caps

	// POLAR SNOW CAP: Overlays snow regardless of altitude at the North/South poles
	float polar_snow = smoothstep(0.78, 0.94, abs(v_local_norm.y));
	albedo = mix(albedo, col_snow * s_detail_level, polar_snow);
	
	// Override steep cliff faces with rock color regardless of their altitude
	vec3 cliff_col = mix(col_rock, col_forest, smoothstep(0.3, 0.65, slope)) * m_detail_level;
	albedo = mix(albedo, cliff_col, cliff_mask * (1.0 - t_snow));
	
	albedo *= detail_level;
	
	// Urban Bedrock Deactivated
	city_mask = 0.0;
	
	ALBEDO = albedo;
	
	// ACE ORGANIC ROAD WARPING: Streets wind naturally over the topography
	float w_n = sin(v_world_pos.x * 0.003 + v_world_pos.y * 0.002) * 0.15 + cos(v_world_pos.z * 0.0025) * 0.15;
	vec2 g_uv = (v_world_pos.xz * 0.004) + vec2(w_n);
	float r_grid = step(0.96, fract(g_uv.x)) + step(0.96, fract(g_uv.y));
	float r_threads = step(0.992, fract(v_world_pos.x * 0.012 + sin(v_world_pos.z*0.015)*0.3)) + step(0.992, fract(v_world_pos.z * 0.012));
	float r_dots = step(0.9992, fract(sin(dot(v_world_pos.xz ,vec2(12.9898,78.233))) * 43758.5453));
	
	// ACE CHROMATIC DISPERSION: 3-tone color selection (Amber, Yellow, Cyan)
	float c_idx = fract(sin(dot(floor(v_world_pos.xz * 0.0005) ,vec2(12.9898,78.233))) * 43758.5453);
	vec3 l_col = vec3(1.0, 0.45, 0.1); // Amber
	if (c_idx > 0.7) l_col = vec3(1.0, 0.85, 0.3); // Yellow/Gold
	else if (c_idx > 0.4) l_col = vec3(0.2, 0.8, 1.0); // Cyan
	
	vec3 city_glow = l_col * (r_grid * 6.0 + r_threads * 12.0 + r_dots * 65.0);
	EMISSION = vec3(0.0);
	
	// ACE TRI-PLANAR NORMAL MAPPING: Projecting physical surface grit across all axes
	// We blend the actual Normal Map textures provided by THE GUNSMITH
	vec3 n_x = texture(ground_norm, v_world_pos.zy * tex_scale).rgb * 2.0 - 1.0;
	vec3 n_y = texture(ground_norm, v_world_pos.xz * tex_scale).rgb * 2.0 - 1.0;
	vec3 n_z = texture(ground_norm, v_world_pos.xy * tex_scale).rgb * 2.0 - 1.0;
	
	// Orient normals to their respective planes
	n_x = vec3(n_x.xy, n_x.z); // ZY plane
	n_y = vec3(n_y.x, n_y.y, n_y.z); // XZ plane
	n_z = vec3(n_z.x, n_z.y, n_z.z); // XY plane
	
	vec3 combined_n = n_x * blending.x + n_y * blending.y + n_z * blending.z;
	
	// ACE PARALLAX OCCLUSION: Injects actual 3D depth into the ground tiles
	float h_x = texture(ground_disp, v_world_pos.zy * tex_scale).r;
	float h_y = texture(ground_disp, v_world_pos.xz * tex_scale).r;
	float h_z = texture(ground_disp, v_world_pos.xy * tex_scale).r;
	float combined_h = h_x * blending.x + h_y * blending.y + h_z * blending.z;
	
	// Simple depth-shift: offsets the texture coordinate look based on height data (Fake 3D relief)
	NORMAL = normalize(NORMAL + (TANGENT * combined_n.x + BINORMAL * combined_n.y) * 0.75);
	NORMAL = mix(NORMAL, normalize(NORMAL + vec3(0, combined_h * 0.5, 0)), 0.2);
	
	METALLIC = 0.0;
	ROUGHNESS = 0.82; 
	SPECULAR = 0.2;
}
void light() {
	float l_level = dot(NORMAL, LIGHT);
	// SOFTER TOON BANDS: Shadow min lifted from 0.35 to 0.55 to prevent pitch-black terrain
	float t2 = aa_step(0.20, l_level); // Shadow -> mid transition
	float t1 = aa_step(0.60, l_level); // Mid -> lit transition
	vec3 shadow_col = ALBEDO * 0.55;   // Was 0.35 — much softer shadow minimum
	vec3 mid_col    = ALBEDO * 0.78;   // Was 0.65 — richer midtone
	vec3 final_col  = mix(shadow_col, mid_col, t2);
	final_col = mix(final_col, ALBEDO, t1);
	DIFFUSE_LIGHT += final_col * LIGHT_COLOR * ATTENUATION;
}
"""
	return _shared_land_shader

static var _skyscraper_shader: Shader = null
static var _sky_mats: Array[ShaderMaterial] = []
static var _facade_texs: Array[Texture2D] = []
static var _roof_assets: Dictionary = {}

static func _init_skyscraper_assets() -> void:
	if _skyscraper_shader: return
	
	# SHADER CACHE
	_skyscraper_shader = Shader.new()
	_skyscraper_shader.code = """shader_type spatial;
	uniform sampler2D albedo_tex : source_color, filter_nearest;
	uniform sampler2D normal_tex : hint_normal, filter_nearest;
	uniform sampler2D spec_tex : source_color, filter_nearest;
	uniform sampler2D disp_tex : source_color, filter_nearest;
	uniform sampler2D ao_tex : source_color, filter_nearest;
	uniform sampler2D roof_tex : source_color, filter_nearest;
	uniform sampler2D roof_norm : hint_normal, filter_nearest;
	uniform sampler2D roof_spec : source_color, filter_nearest;
	uniform sampler2D roof_disp : source_color, filter_nearest;
	uniform sampler2D roof_ao : source_color, filter_nearest;
	varying vec3 v_normal;
	varying vec3 v_local_pos;
	varying vec3 v_view_dir;
	varying float v_seed;
	void vertex() {
		v_normal = NORMAL; v_local_pos = VERTEX;
		v_seed = COLOR.r;
		v_view_dir = normalize(VERTEX - (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz);
	}
	vec3 room_trace(vec2 uv, vec3 view_dir, vec3 grid_size, float s_seed) {
		vec2 room_uv = fract(uv * grid_size.xy); vec2 room_idx = floor(uv * grid_size.xy);
		vec3 r_origin = vec3(room_uv * 2.0 - 1.0, 1.0); vec3 inv_dir = 1.0 / view_dir;
		vec3 t_bot = inv_dir * (vec3(-1.0, -1.0, -1.0) - r_origin);
		vec3 t_top = inv_dir * (vec3(1.0, 1.0, 1.0) - r_origin);
		vec3 t_max = max(t_bot, t_top); float t = min(t_max.x, min(t_max.y, t_max.z));
		vec3 hit = r_origin + view_dir * t;
		float wall_m = step(0.95, max(abs(hit.x), abs(hit.y)));
		float light_v = step(0.4, sin(room_idx.x * 17.0 + room_idx.y * 31.0 + s_seed * 100.0));
		
		float c_id = fract(sin(room_idx.x * 13.0 + room_idx.y * 47.0 + s_seed * 43.1) * 43758.5453);
		vec3 win_col = vec3(1.0, 0.65, 0.1); // Amber
		if (c_id > 0.85) win_col = vec3(1.0, 0.9, 0.4); // Bright Yellow
		else if (c_id > 0.75) win_col = vec3(0.3, 0.7, 1.0); // Cyan/Blue
		else if (c_id > 0.72) win_col = vec3(1.0, 0.1, 0.1); // Red
		else if (c_id > 0.69) win_col = vec3(0.1, 1.0, 0.3); // Green
		
		return vec3(0.04, 0.06, 0.12) + (hit.z < -0.9 ? win_col * wall_m * light_v : vec3(0.0));
	}
	void fragment() {
		float roof_mask = clamp(v_normal.y * 10.0 - 5.0, 0.0, 1.0);
		float t_scale = 0.035; vec2 s_uv;
		if (abs(v_normal.x) > 0.5) { s_uv = vec2((v_local_pos.z + 140.0) / 280.0, v_local_pos.y * t_scale); }
		else { s_uv = vec2((v_local_pos.x + 140.0) / 280.0, v_local_pos.y * t_scale); }
		vec2 r_uv = (v_local_pos.xz + 140.0) / 280.0;
		float s_h = texture(disp_tex, s_uv).r; vec2 p_s_uv = s_uv - v_view_dir.xy * (s_h * 0.015);
		float r_h = texture(roof_disp, r_uv).r; vec2 p_r_uv = r_uv - v_view_dir.xz * (r_h * 0.015);
		vec3 side_alb = texture(albedo_tex, p_s_uv).rgb; vec3 roof_alb = texture(roof_tex, p_r_uv).rgb;
		vec3 base_alb = mix(side_alb, roof_alb, roof_mask); float luma = dot(base_alb, vec3(0.299, 0.587, 0.114));
		float is_win = step(0.45, luma) * (1.0 - roof_mask);
		
		float dist = length(VERTEX); // Fragment VERTEX is in view-space
		vec3 interior = vec3(0.04, 0.06, 0.12);
		if (dist < 4500.0) {
			interior = room_trace(s_uv, v_view_dir, vec3(20.0, 40.0, 1.0), v_seed);
		}
		float b_ao = mix(texture(ao_tex, p_s_uv).r, texture(roof_ao, p_r_uv).r, roof_mask);
		float h_grad = mix(0.2, 1.0, smoothstep(-240.0, 100.0, v_local_pos.y));
		ALBEDO = mix(base_alb, base_alb * interior * 2.5, is_win) * h_grad * b_ao;
		float s_spec = texture(spec_tex, p_s_uv).r;
		SPECULAR = mix(s_spec, texture(roof_spec, p_r_uv).r, roof_mask);
		METALLIC = mix(s_spec * 0.8, 0.1, roof_mask); ROUGHNESS = mix(0.7 - s_spec * 0.5, 0.8, roof_mask);
		EMISSION = mix(vec3(0.0), base_alb * 10.0 + interior * is_win * 6.0, is_win);
		NORMAL_MAP = mix(texture(normal_tex, p_s_uv).rgb, texture(roof_norm, p_r_uv).rgb, roof_mask);
		NORMAL_MAP_DEPTH = 1.35;
	}
	"""
	# ACE ASSET HARDENING: Bulk-loading textures to prevent I/O micro-stutters
	_roof_assets = {
		"t": load("res://assets/textures/building_roof_texture.png"),
		"n": load("res://assets/textures/building_roof_texture_normal.png"),
		"s": load("res://assets/textures/building_roof_texture_specular.png"),
		"d": load("res://assets/textures/building_roof_texture_displacement.png"),
		"a": load("res://assets/textures/building_roof_texture_ambient.png")
	}

	for i in range(1, 7):
		var p = "res://assets/textures/building_texture_%d.png" % i
		var m = ShaderMaterial.new(); m.shader = _skyscraper_shader
		m.set_shader_parameter("albedo_tex", load(p))
		m.set_shader_parameter("normal_tex", load(p.replace(".png", "_normal.png")))
		m.set_shader_parameter("spec_tex", load(p.replace(".png", "_specular.png")))
		m.set_shader_parameter("disp_tex", load(p.replace(".png", "_displacement.png")))
		m.set_shader_parameter("ao_tex", load(p.replace(".png", "_ambient.png")))
		m.set_shader_parameter("roof_tex", _roof_assets["t"])
		m.set_shader_parameter("roof_norm", _roof_assets["n"])
		m.set_shader_parameter("roof_spec", _roof_assets["s"])
		m.set_shader_parameter("roof_disp", _roof_assets["d"])
		m.set_shader_parameter("roof_ao", _roof_assets["a"])
		_sky_mats.append(m)

static var _road_shader: Shader = null
static func _get_road_shader() -> Shader:
	if _road_shader: return _road_shader
	_road_shader = Shader.new()
	_road_shader.code = """shader_type spatial;
	uniform vec3 neon_col : source_color = vec3(1.0, 0.45, 0.1);
	varying vec3 v_local_pos;
	void vertex() { v_local_pos = VERTEX; }
	void fragment() {
		float x_abs = abs(v_local_pos.x);
		float is_sw = step(120.0, x_abs); // 40m sidewalks on each side of 320m road
		ALBEDO = mix(vec3(0.05, 0.05, 0.06), vec3(0.18, 0.18, 0.20), is_sw);
		float lanes = 0.0;
		for(int i=-2; i<=1; i++) {
			float lx = float(i) * 45.0 + 22.5;
			lanes += step(0.95, 1.0 - abs(v_local_pos.x - lx) * 0.2);
		}
		lanes *= (1.0 - is_sw);
		float pulse = step(0.95, fract(v_local_pos.z * 0.002 - TIME * 0.8)) * 0.7 + 0.3;
		EMISSION = mix(vec3(0.0), neon_col * 8.0 * pulse, lanes);
		ROUGHNESS = 0.4; METALLIC = 0.1;
	}
	"""
	return _road_shader

static var _impostor_mat: ShaderMaterial = null
static func _get_impostor_mat() -> ShaderMaterial:
	if _impostor_mat: return _impostor_mat
	_impostor_mat = ShaderMaterial.new(); var s = Shader.new()
	s.code = """shader_type spatial;
	void fragment() {
		ALBEDO = vec3(0.04);
		float grid = step(0.96, fract(UV.x * 12.0)) + step(0.96, fract(UV.y * 12.0));
		float dots = step(0.99, fract(sin(dot(UV ,vec2(12.9898,78.233))) * 43758.5453));
		// Chromatic variance on impostors
		float c_idx = fract(sin(dot(floor(UV * 2.5) ,vec2(12.9898,78.233))) * 43758.5453);
		vec3 l_col = vec3(1.0, 0.45, 0.1); 
		if (c_idx > 0.7) l_col = vec3(1.0, 0.85, 0.3);
		else if (c_idx > 0.4) l_col = vec3(0.2, 0.8, 1.0);
		EMISSION = l_col * (grid * 8.0 + dots * 45.0);
	}"""
	_impostor_mat.shader = s; return _impostor_mat

static var _shared_water_shader: Shader = null
static func _get_shared_water_shader() -> Shader:
	if _shared_water_shader: return _shared_water_shader
	_shared_water_shader = Shader.new()
	_shared_water_shader.code = """shader_type spatial;
render_mode diffuse_lambert, blend_mix;

varying vec3 v_local_pos;    // Local-space position (immune to origin-shift drift)
varying float v_shore;       // 0=deep ocean, 1=shoreline (baked into vertex color)
varying vec3 v_world_normal; // World-space normal for lighting

uniform vec3 pal_water_base;   // Deep ocean color
uniform vec3 pal_water_light;  // Wave crest / mid-water highlight
uniform vec3 pal_water_shore;  // Shallow / beach-edge water color
uniform bool is_lava = false;

// -------------------------------------------------------
// HASH-BASED 2D VALUE NOISE
// Uses a mathematical hash to avoid any axis-aligned repetition.
// Returns a smooth [0,1] value with no visible grid structure.
// -------------------------------------------------------
vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	// Quintic interpolation curve — smoother than cubic, no visible grid seams
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	// Sample 4 corner hashes and bilinearly interpolate
	float a = hash2(i).x;
	float b = hash2(i + vec2(1.0, 0.0)).x;
	float c = hash2(i + vec2(0.0, 1.0)).x;
	float d = hash2(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 2-octave FBM: breaks up single-scale repetition and adds turbulence
float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.6;
	float freq = 1.0;
	// Octave 1: large scale structure
	v += value_noise(p * freq) * amp;
	// Octave 2: rotated 45 degrees to avoid doubling grid axes
	freq *= 2.1; amp *= 0.45;
	v += value_noise(vec2(p.y - p.x, p.x + p.y) * freq * 0.7) * amp;
	return v;
}

void vertex() {
	v_shore = COLOR.r;
	v_local_pos = VERTEX;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);

	// ACE PROXIMITY GATING: Waves only animate when ship is within 4km
	float d_to_cam = distance((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD);
	float wave_mask = 1.0 - smoothstep(1500.0, 4000.0, d_to_cam);

	if (wave_mask > 0.01) {
		float wt = floor(TIME * 8.0) / 8.0 * 0.9;
		float disp = sin(dot(VERTEX.xz, vec2(0.047,  0.031)) + wt * 1.2) * 2.2
				   + sin(dot(VERTEX.xz, vec2(-0.039, 0.052)) + wt * 0.9) * 1.8
				   + sin(dot(VERTEX.xz, vec2(0.028,  -0.061)) + wt * 1.5) * 1.4
				   + sin(dot(VERTEX.xz, vec2(0.057,   0.023)) + wt * 0.7) * 1.0;
		VERTEX += normalize(VERTEX) * disp * wave_mask;
	}
}

void fragment() {
	float d_to_cam = distance((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD);
	float wave_mask = 1.0 - smoothstep(2000.0, 5000.0, d_to_cam);
	
	float wt = floor(TIME * 8.0) / 8.0;
	float shore = v_shore;
	vec3 base_col = mix(pal_water_base, pal_water_shore, smoothstep(0.0, 0.80, shore));

	float SCALE = 0.0018; 
	vec2 ocean_uv = v_local_pos.xz * SCALE;

	float wave_cel = 0.0;
	float crest_cel = 0.0;
	float shore_rings = 0.0;

	// ACE PERFORMANCE BYPASS: Only run heavy FBM and Shore Loops when near surface
	if (wave_mask > 0.01) {
		float warp_speed = 0.07;
		vec2 warp = vec2(fbm(ocean_uv + vec2(wt * warp_speed, 1.7)), fbm(ocean_uv + vec2(3.4, wt * warp_speed * 0.8))) * 0.8 - 0.4;
		float shoal_freq = mix(1.0, 1.8, smoothstep(0.2, 0.8, shore));
		float ocean_n = fbm((ocean_uv + warp) * shoal_freq + vec2(wt * 0.06, wt * 0.04));

		if (ocean_n > 0.72) crest_cel = 1.0;
		else if (ocean_n > 0.52) wave_cel = 1.0;

		float deep_mask = smoothstep(0.75, 0.25, shore);
		wave_cel *= (deep_mask * wave_mask);
		crest_cel *= (deep_mask * wave_mask);

		if (shore > 0.02 && shore < 0.97) {
			float s_warped = shore + (ocean_n - 0.5) * 0.12;
			float ring_a = sin(s_warped * 32.0 - wt * 3.2);
			float ring_b = sin(s_warped * 18.0 - wt * 2.0);
			shore_rings = clamp(pow(max(0.0, ring_a * ring_b), 3.5) * 12.0, 0.0, 1.0) * wave_mask;
		}
	}

	// -------------------------------------------------------
	// 5. SUN SHIMMER — irregular dapple on open water
	// -------------------------------------------------------
	float shimmer_n = fbm(v_local_pos.xz * 0.009 + vec2(wt * 0.4, -wt * 0.35));
	float shimmer = step(0.78, shimmer_n) * step(0.4, dot(v_world_normal, vec3(0.0, 1.0, 0.0)));
	shimmer *= smoothstep(0.45, 0.0, shore); // Only on open deep water

	// -------------------------------------------------------
	// 6. ASSEMBLE: base → mid highlight → crest → shore foam → sparkle
	// -------------------------------------------------------
	float fresnel = pow(1.0 - dot(NORMAL, VIEW), 3.0);
	vec3 col = pal_water_base;
	col = mix(col, pal_water_light, wave_cel * 0.55);
	col = mix(col, vec3(1.0), crest_cel * 0.45);
	col = mix(col, vec3(1.0), shore_rings);
	col = mix(col, vec3(1.0, 1.0, 0.93), shimmer * 0.85);

	ALBEDO = col;
	if (is_lava) {
		EMISSION = col * (fresnel + 0.5) * 2.5;
	}
	METALLIC = 0.0;
	ROUGHNESS = 0.08;
}

void light() {
	float l_level = dot(NORMAL, LIGHT);
	float t_shadow = step(0.15, l_level);
	float t_bright  = step(0.65, l_level);
	vec3 shadow_col = ALBEDO * 0.60;
	vec3 lit_col    = ALBEDO * 0.90;
	vec3 bright_col = ALBEDO * 1.05;
	vec3 final_col  = mix(shadow_col, lit_col, t_shadow);
	final_col       = mix(final_col, bright_col, t_bright);
	DIFFUSE_LIGHT  += final_col * LIGHT_COLOR * ATTENUATION;
	
	// SUN SPECULAR REFLECTION: Blinn-Phong half-vector gives the sun glint angle
	// Only visible when the light reflects directly toward the viewer (like real water)
	vec3 H = normalize(LIGHT + VIEW); // Half-vector between sun direction and camera
	float NdotH = max(dot(NORMAL, H), 0.0);
	
	// Two cel-shaded rings: a broad warm halo and a tight bright core
	float spec_mid  = step(0.965, NdotH); // Wide outer glow
	float spec_core = step(0.990, NdotH); // Tight bright center
	
	// Warm golden sun color for the halo, pure white for the core
	vec3 sun_halo = LIGHT_COLOR * vec3(1.0, 0.92, 0.70) * 1.8;
	vec3 sun_core = vec3(1.0, 0.98, 0.90) * 3.5;
	
	// Only reflect when surface is lit (not in shadow)
	float lit_mask = t_shadow * ATTENUATION;
	SPECULAR_LIGHT += (sun_halo * spec_mid + sun_core * spec_core) * lit_mask;
}
"""
	return _shared_water_shader

func _spawn_minerals(data: Array) -> void:
	# ASYNC PERF: Spread instantiation across multiple frames so a chunk with
	# 10-20 minerals never spawns them all in a single frame.  Combined with
	# the shared-mesh cache in MineableResource.gd, mineral spawn time per
	# frame drops from ~10ms (10-20 SurfaceTool.commit() calls) to ~1.5ms
	# (3-6 cheap StaticBody3D allocations + cached mesh assignment).
	var m_script = _get_res("res://src/world/MineableResource.gd")
	if not m_script: return

	var mobile := OS.has_feature("mobile") or OS.get_name() == "iOS"
	var per_frame: int = 3 if mobile else 6
	var counter: int = 0

	for item in data:
		# Defensive: chunk may have been freed between awaits when the player
		# moves out of range.  Bail out early to avoid touching freed memory.
		if not is_inside_tree(): return

		var xf: Transform3D = item[0]
		var type: String = item[1]

		# DESTRUCTION PERSISTENCE: Skip any mineral that's been destroyed
		# previously (even if the chunk is being reloaded). The destroyed
		# minerals registry uses position hash for O(1) lookup.
		var global_xf = self.global_transform * xf
		var pos_hash = hash(global_xf.origin.round())
		if m_script.get("_destroyed_positions").has(pos_hash):
			continue

		var res = StaticBody3D.new()
		res.set_script(m_script)
		res.set("resource_type", type)
		add_child(res)
		# ACE: Use local transform relative to the chunk node
		res.transform = xf

		counter += 1
		if counter >= per_frame:
			counter = 0
			# Yield to the engine so this frame's other work (rendering,
			# physics, input, prop tasks) can run before we spawn more.
			await get_tree().process_frame

static var c_r: ArrayMesh
static var c_t_l: ArrayMesh
static var c_t_m: ArrayMesh
static var c_t_h: ArrayMesh
static var c_g: ArrayMesh

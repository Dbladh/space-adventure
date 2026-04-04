@tool
extends Node3D

# PlanetGen.gd (Aggressive Horizon Edition)
# Managed by THE ARCHITECT.

const PlanetChunkScript := preload("res://src/world/PlanetChunk.gd")

@export var planet_radius: float = 1000000.0 
@export var terrain_strength: float = 5000.0 
@export var max_lod: int = 18 
@export var subdivision_bias: float = 0.9
# Each planet must get a unique seed so terrain is distinct per celestial body!
@export var planet_seed: int = 1234

# ATMOSPHERIC IDENTITY
var sky_horizon_color: Color
var sky_zenith_color: Color

var noise: FastNoiseLite
var faces: Array[QuadTreeFace] = []
var player: Node3D

# NMS OPTIMIZATION: Throttle chunk streaming to prevent CPU micro-stutters!
# One split per frame keeps mesh generation within frame budget.
var split_queue: Array[QuadTreeNode] = []
const MAX_SPLITS_PER_FRAME: int = 1
# SCATTER QUEUE: Process exactly one chunk's flora per frame, after its mesh
# was committed on a prior frame. This is the true frame-budget isolation.
var scatter_queue: Array = []  # Array of PlanetChunk nodes awaiting flora
const PROXIMITY_CUTOFF: float = 3000000.0 # 3,000km - Transition to Impostor
var impostor: Node3D = null
var faces_hidden: bool = false

const FACE_NORMALS: Array[Vector3] = [
	Vector3.FORWARD, Vector3.BACK,
	Vector3.LEFT, Vector3.RIGHT,
	Vector3.UP, Vector3.DOWN
]

func _ready() -> void:
	noise = FastNoiseLite.new()
	# Always use the explicit planet_seed for terrain noise.
	# Main.gd sets unique values (1001, 2002...) before add_child() is called,
	# so _ready() always receives the correct distinct seed per body.
	noise.seed = planet_seed
	noise.noise_type = FastNoiseLite.TYPE_PERLIN
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 0.05 
	
	# PROCEDURAL ATMOSPHERE: Unique Sky per Planet!
	# The user requested specific vivid colors: Blue, Red, Orange, Yellow, Green.
	var rng = RandomNumberGenerator.new()
	rng.seed = (int(planet_radius) ^ int(terrain_strength * 100.0) ^ (planet_seed * 2654435761)) & 0x7FFFFFFF
	
	# Replicate the exact math used by PlanetChunk to determine the planet's grass color
	# Because we use the exact same formula and PRNG seed, this is 100% accurate per planet.
	var pal_forest_h = rng.randf()
	var grass_hue_offset = 0.5 + rng.randf_range(-0.15, 0.15)
	var grass_hue = fposmod(pal_forest_h + grass_hue_offset, 1.0)
	
	# Mapping allowed colors to hues: Red (0.0/1.0), Orange (0.08), Yellow (0.15), Green (0.33), Blue (0.6)
	var allowed_hues = [0.0, 0.08, 0.15, 0.33, 0.6]
	
	# DYNAMIC COLOR THEORY: Select the sky color that contrasts the MOST against the ground
	var base_hue = 0.0
	var max_diff = -1.0
	for h in allowed_hues:
		var diff = abs(h - grass_hue)
		if diff > 0.5: diff = 1.0 - diff # Shortest distance around the 360-degree color wheel
		if diff > max_diff:
			max_diff = diff
			base_hue = h
	
	# Shift the hue slightly per-planet to avoid identical clones
	var hue_drift = rng.randf_range(-0.03, 0.03)
	var final_hue = fposmod(base_hue + hue_drift, 1.0)
	
	# Horizon uses the dynamic, high-contrast planetary hue (e.g. Red, Orange, Green)
	var horizon_hue = fposmod(final_hue - 0.05, 1.0) # Shift slightly warmer for sunset feel
	sky_horizon_color = Color.from_hsv(horizon_hue, rng.randf_range(0.6, 0.9), rng.randf_range(0.8, 1.0))
	
	# Zenith ALWAYS forces a deep blue to ensure every sky is a stunning sunset!
	# We randomize the blue slightly (0.58 cyan-blue to 0.65 deep-blue) so it's a unique blue per planet.
	var blue_zenith_hue = rng.randf_range(0.58, 0.65)
	sky_zenith_color = Color.from_hsv(blue_zenith_hue, rng.randf_range(0.6, 0.8), rng.randf_range(0.2, 0.5))
	
	for normal in FACE_NORMALS:
		var face = QuadTreeFace.new(self, normal)
		faces.append(face)
		add_child(face)
	self.add_to_group("Planet")
	self.add_to_group("World")
	print("--- ARCHITECT: PLANET [%s] SYNCHRONIZED (terrain_seed=%d) ---" % [name, noise.seed])

func get_terrain_height_at(pos: Vector3) -> float:
	var sphere_norm: Vector3 = (pos - global_position).normalized()
	var macro_h: float = noise.get_noise_3dv(sphere_norm * 500.0)
	var micro_crag: float = noise.get_noise_3dv(sphere_norm * 15000.0) * 0.1
	var total_h: float = (macro_h + micro_crag) * terrain_strength
	var volcanic: float = noise.get_noise_3dv(sphere_norm * 25000.0)
	if volcanic > 0.45: total_h -= 1000.0
	return planet_radius + total_h

func _process(_delta: float) -> void:
	if not player:
		var players = get_tree().get_nodes_in_group("Player")
		if players.size() > 0: player = players[0]
		return
	
	# CELESTIAL DISTANCE LOD: Hibernation Mode
	# We switch off the entire QuadTree generator if the planet is too far.
	var dist_to_player = player.global_position.distance_to(global_position)
	if dist_to_player > PROXIMITY_CUTOFF:
		if not faces_hidden:
			for face in faces: face.visible = false
			_ensure_impostor_active(true)
			faces_hidden = true
		return # Hibernating!
	else:
		if faces_hidden:
			for face in faces: face.visible = true
			_ensure_impostor_active(false)
			faces_hidden = false
	
	for face in faces:
		face.update_lod(player.global_position)
	
	# High-performance splitting: one mesh commit per frame
	for i in range(min(split_queue.size(), MAX_SPLITS_PER_FRAME)):
		var node = split_queue.pop_front()
		if node: node.execute_split()
	
	# SCATTER QUEUE: one flora scatter per frame, always on a separate frame
	# from mesh generation so the two heavy operations never stack.
	if scatter_queue.size() > 0:
		var chunk = scatter_queue.pop_front()
		if is_instance_valid(chunk):
			chunk._scatter_deterministic_stellar_layers()

func _ensure_impostor_active(active: bool) -> void:
	if active:
		if not impostor:
			var script = load("res://src/world/PlanetImpostor.gd")
			impostor = Node3D.new(); impostor.set_script(script)
			impostor.set("planet_radius", planet_radius)
			# Derive a representative color from the sky colors
			impostor.set("planet_color", sky_horizon_color)
			add_child(impostor); impostor.global_position = global_position
		impostor.visible = true
	elif impostor:
		impostor.visible = false

class QuadTreeFace extends Node3D:
	var planet: Node3D
	var normal: Vector3
	var root_node: QuadTreeNode
	var x_axis: Vector3
	var y_axis: Vector3
	func _init(p_planet: Node3D, p_normal: Vector3) -> void:
		planet = p_planet
		normal = p_normal
		if abs(normal.y) > 0.999: x_axis = Vector3.RIGHT
		else: x_axis = Vector3.UP.cross(normal).normalized()
		y_axis = normal.cross(x_axis).normalized()
	func _ready() -> void:
		root_node = QuadTreeNode.new(self, null, Vector2.ZERO, 1.0, 0)
		root_node.ensure_chunk()
	func update_lod(player_pos: Vector3) -> void:
		root_node.update(player_pos)

class QuadTreeNode:
	var face: QuadTreeFace
	var parent: QuadTreeNode
	var local_offset: Vector2
	var scale: float
	var lod: int
	var children: Array[QuadTreeNode] = []
	var chunk: MeshInstance3D = null
	
	func _init(p_face: QuadTreeFace, p_parent: QuadTreeNode, p_offset: Vector2, p_scale: float, p_lod: int) -> void:
		face = p_face
		parent = p_parent
		local_offset = p_offset
		scale = p_scale
		lod = p_lod
		
	func update(player_pos: Vector3) -> void:
		var face_pos: Vector3 = face.normal + (local_offset.x * face.x_axis) + (local_offset.y * face.y_axis)
		var center_norm: Vector3 = face_pos.normalized()
		var center_pos: Vector3 = face.planet.global_position + center_norm * face.planet.planet_radius
		var dist: float = player_pos.distance_to(center_pos)
		
		# AGGRESSIVE HORIZON: Subdivide at 3.5x the scale distance
		var threshold: float = face.planet.planet_radius * (scale * 3.5) * face.planet.subdivision_bias
		if dist < threshold and lod < face.planet.max_lod:
			if children.is_empty():
				if not face.planet.split_queue.has(self): face.planet.split_queue.append(self)
			else:
				for child in children: child.update(player_pos)
		else:
			if not children.is_empty(): merge()
			else: ensure_chunk()
			
	func execute_split() -> void:
		if not children.is_empty(): return
		var step: float = scale * 0.5 
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(-step, -step), step, lod + 1))
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(step, -step), step, lod + 1))
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(-step, step), step, lod + 1))
		children.append(QuadTreeNode.new(face, self, local_offset + Vector2(step, step), step, lod + 1))
		# CRITICAL: Spawn children FIRST, then remove parent!
		# Removing parent before children generates creates a 1-frame gap where nothing
		# exists — this is the visual "phase popping" the player sees during LOD transitions.
		for child in children: child.ensure_chunk()
		remove_chunk() # Parent removed AFTER children are ready
		
	func merge() -> void:
		# CRITICAL: Create the parent chunk BEFORE disposing children!
		# Disposing children first causes a 1-frame rendering gap (the visible pop).
		# By generating the coarser parent first, there is always something on screen.
		ensure_chunk()
		for child in children: child.dispose()
		children.clear()
		
	func ensure_chunk() -> void:
		if chunk: return
		if not children.is_empty(): return 
		chunk = face.planet.PlanetChunkScript.new()
		chunk.noise = face.planet.noise
		chunk.radius = face.planet.planet_radius
		chunk.terrain_strength = face.planet.terrain_strength
		chunk.face_normal = face.normal
		chunk.x_axis = face.x_axis
		chunk.y_axis = face.y_axis
		chunk.offset = local_offset
		chunk.scale_factor = scale
		# LOD-ADAPTIVE RESOLUTION: Distant chunks use fewer vertices.
		# scale=1.0 = root face, scale=0.001 = very close tile.
		# Halving resolution cuts vertex/triangle count by 4x.
		if scale > 0.05:   chunk.resolution = 16   # Far: 16x16 = 256 quads
		elif scale > 0.01: chunk.resolution = 24   # Mid: 24x24 = 576 quads
		else:             chunk.resolution = 32   # Near: 32x32 = 1024 quads (full detail)
		chunk.planet_seed = face.planet.planet_seed
		# Grass only spawns when the player is on foot — skip during flight for big perf gains.
		var p = face.planet.player
		chunk.scatter_grass = (p != null and not p.get("in_ship"))
		face.add_child(chunk)
		chunk.start_generation()
		# Queue this chunk for flora scatter on a future frame.
		face.planet.scatter_queue.append(chunk)
		
	func remove_chunk() -> void:
		if chunk: chunk.queue_free(); chunk = null
	func dispose() -> void:
		remove_chunk()
		for child in children: child.dispose()
		children.clear()

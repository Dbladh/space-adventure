@tool
extends Node3D

# PlanetGen.gd (Aggressive Horizon Edition)
# Managed by THE ARCHITECT.

const PlanetChunkScript := preload("res://src/world/PlanetChunk.gd")

@export var planet_radius: float = 1000000.0 
@export var terrain_strength: float = 5000.0 
@export var max_lod: int = 18 
@export var subdivision_bias: float = 1.15
# Each planet must get a unique seed so terrain is distinct per celestial body!
@export var planet_seed: int = 1234
var mobile_perf: bool = false
# Resources available to mine on this planet. Set externally before chunks generate.
# Stone and Wood are always present; extras are tier-gated by how the planet was forged.
var planet_resources: Array[String] = ["Stone", "Wood", "Copper"]

# ATMOSPHERIC IDENTITY
var sky_horizon_color: Color
var sky_zenith_color: Color

# PROCEDURAL PALETTE
var pal_grass_col: Color
var pal_mount_col: Color
var pal_forest_col: Color
var pal_forest_h: float
var pal_grass_secondary: Color
var pal_beach_col: Color
var pal_water_base: Color
var pal_water_light: Color
var pal_water_shore: Color
var archetype: String

var noise: FastNoiseLite
var faces: Array[QuadTreeFace] = []
var player: Node3D

# ACE MEMORY POOLING: Hibernation buffer for QuadTree nodes to prevent GC stutters
var chunk_pool: Array[MeshInstance3D] = []
var continent_pole: Vector3 = Vector3.UP # ACE: Deterministic anchor for the major island

# NMS OPTIMIZATION: Throttle chunk streaming to prevent CPU micro-stutters!
# One split per frame keeps mesh generation within frame budget.
var split_queue: Array[QuadTreeNode] = []
const MAX_SPLITS_PER_FRAME: int = 1
const PROXIMITY_CUTOFF: float = 8000000.0 # ACE: Increased for mission-critical persistence
var impostor: Node3D = null
var faces_hidden: bool = false
var _lod_face_idx: int = 0 # ACE PERFORMANCE: Load-balanced face updates

# ACE POOLING: Chunks that are still generating in the background go here
# instead of the main pool to avoid blocking the main thread.
var zombie_pool: Array[MeshInstance3D] = []
var finalize_queue: Array = []
var death_row: Array[Node] = []
var prop_spawn_queue: Array = [] # ACE: Throttled Prop batches
# ACE PHYSICS: Queue for trimesh collision generation to prevent spikes
var collision_queue: Array[MeshInstance3D] = []
const MAX_COLLISIONS_PER_FRAME: int = 1
var MAX_FINALIZE_PER_FRAME: int = 1
const MAX_DEATHS_PER_FRAME: int = 24
var _prewarm_count: int = 0
var _prewarm_target: int = 20

func _prewarm_one_chunk() -> void:
	var pc = PlanetChunkScript.new()
	pc.setup(self)
	pc.hide()
	zombie_pool.append(pc)
	add_child(pc)



const FACE_NORMALS: Array[Vector3] = [
	Vector3.FORWARD, Vector3.BACK,
	Vector3.LEFT, Vector3.RIGHT,
	Vector3.UP, Vector3.DOWN
]

func _ready() -> void:
	noise = FastNoiseLite.new()
	if mobile_perf:
		max_lod = min(max_lod, 15)
		subdivision_bias = min(subdivision_bias, 0.95)
		terrain_strength *= 0.8
		_prewarm_target = 12
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
	
	# DYNAMIC CHROMA SYNC: Force sky hue to be complementary (180deg shift) from the forest floor
	# This ensures the exosphere definitively contrasts against the dominant ground color.
	var complementary_hue = fposmod(pal_forest_h + 0.5, 1.0)
	
	# Select the closest allowed hue to the complementary target
	var base_hue = allowed_hues[0]
	var min_diff = 1.0
	for h in allowed_hues:
		var diff = abs(h - complementary_hue)
		if diff > 0.5: diff = 1.0 - diff
		if diff < min_diff:
			min_diff = diff
			base_hue = h
			
	# Horizon uses the dynamic, complementary planetary hue (e.g. Aqua, Yellow, Orange)
	# Increased saturation for a more vivid atmospheric look
	sky_horizon_color = Color.from_hsv(base_hue, 0.85, 1.0)
	
	# Zenith ALWAYS forces a deep blue to ensure every sky is a stunning sunset!
	sky_zenith_color = Color.from_hsv(0.62, 0.75, 0.35)
	
	# ARCHETYPE SYSTEM — THE COSMOLOGIST
	# Sync with PlanetChunk: 8 thematic archetypes with procedural hue jitter.
	var archetypes = ["LUSH", "DESERT", "FROZEN", "ALPINE", "VOLCANIC", "CANDY", "RADIATED", "ABYSS"]
	var pal_rng = RandomNumberGenerator.new()
	pal_rng.seed = hash(str(name) + str(planet_radius) + str(planet_seed)) & 0x7FFFFFFF
	var theme = archetypes[pal_rng.randi() % archetypes.size()]
	self.archetype = theme
	
	match theme:
		"LUSH":
			var h = pal_rng.randf_range(0.28, 0.42)
			pal_grass_col = Color.from_hsv(h, 0.65, 0.85)
			pal_mount_col = Color.from_hsv(pal_rng.randf_range(0.05, 0.15), 0.3, 0.5)
			pal_water_base = Color.from_hsv(0.55, 0.75, 0.8)
		"DESERT":
			var h = pal_rng.randf_range(0.02, 0.15)
			pal_grass_col = Color.from_hsv(h, 0.7, 0.9)
			pal_mount_col = Color.from_hsv(h, 0.4, 0.6)
			pal_water_base = Color.from_hsv(0.05, 0.9, 0.4) 
		"FROZEN":
			var h = pal_rng.randf_range(0.5, 0.65)
			pal_grass_col = Color.from_hsv(h, 0.15, 0.95)
			pal_mount_col = Color.from_hsv(h+0.1, 0.4, 0.6)
			pal_water_base = Color.from_hsv(0.6, 0.5, 0.9)
		"TOXIC":
			var h = pal_rng.randf_range(0.18, 0.28)
			pal_grass_col = Color.from_hsv(h, 0.85, 0.9)
			pal_mount_col = Color.from_hsv(0.8, 0.5, 0.4)
			pal_water_base = Color.from_hsv(h+0.2, 0.85, 0.7)
		"ALPINE":
			var h = pal_rng.randf_range(0.58, 0.62)
			pal_grass_col = Color.from_hsv(h, 0.15, 0.98) # Snow
			pal_mount_col = Color.from_hsv(h, 0.4, 0.45)  # Blue Grey Stone
			pal_water_base = Color.from_hsv(0.6, 0.8, 0.9) # Clear Blue Ice-Water
		"VOLCANIC":
			pal_grass_col = Color.from_hsv(0.0, 0.9, 0.5)
			pal_mount_col = Color.from_hsv(0, 0.0, 0.15)
			pal_water_base = Color.from_hsv(0.0, 1.0, 0.45) 
		"CANDY":
			var h = pal_rng.randf_range(0.85, 0.98)
			pal_grass_col = Color.from_hsv(h, 0.45, 0.95)
			pal_mount_col = Color.from_hsv(h, 0.25, 0.7)
			pal_water_base = Color.from_hsv(0.5, 0.4, 0.9)
		"RADIATED":
			var h = pal_rng.randf_range(0.65, 0.8)
			pal_grass_col = Color.from_hsv(h, 0.8, 0.9)
			pal_mount_col = Color.from_hsv(h, 0.3, 0.4)
			pal_water_base = Color.from_hsv(0.75, 1.0, 1.0)
		"ABYSS":
			pal_grass_col = Color.from_hsv(0.65, 0.8, 0.25)
			pal_mount_col = Color.from_hsv(0.7, 0.5, 0.1)
			pal_water_base = Color.from_hsv(0.65, 0.95, 0.2)
	
	# GENERATE SECONDARY COLOR PALETTE
	# Using explicit derivations to ensure complementary colors 
	pal_forest_col = pal_grass_col.darkened(0.2)
	pal_grass_secondary = pal_grass_col.lightened(0.12)
	pal_beach_col = pal_grass_col.lightened(0.25).lerp(pal_mount_col, 0.4) 
	pal_water_light = pal_water_base.lightened(0.15) 
	pal_water_shore = pal_water_base.lightened(0.3).lerp(pal_grass_col, 0.2)
	
	base_hue = pal_grass_col.h
	self.pal_forest_h = base_hue # Seed for tree variety
	
	# MAJOR CONTINENT ARCHITECT: Every planet gets one iconic, massive landmass
	var c_rng = RandomNumberGenerator.new(); c_rng.seed = planet_seed + 999
	continent_pole = Vector3(c_rng.randf_range(-1,1), c_rng.randf_range(-1,1), c_rng.randf_range(-1,1)).normalized()
	
	for normal in FACE_NORMALS:
		var face = QuadTreeFace.new(self, normal)
		faces.append(face)
		add_child(face)
	# ACE: Inject majestic cloud belts and celestial rings — visible against the charcoal void
	self.add_to_group("Planet")
	self.add_to_group("World")
	_spawn_majestic_clouds_and_rings(rng, base_hue)
	# ACE: Scatter colossal Hero Landmarks as navigation anchors across the planet surface
	_spawn_hero_landmarks(rng)
	_spawn_poi_marker()
	print("--- ARCHITECT: PLANET [%s] SYNCHRONIZED (terrain_seed=%d) ---" % [name, noise.seed])

func get_terrain_height_at(pos: Vector3) -> float:
	var sphere_norm: Vector3 = (pos - global_position).normalized()
	var macro_h: float = noise.get_noise_3dv(sphere_norm * 500.0)
	var micro_crag: float = noise.get_noise_3dv(sphere_norm * 15000.0) * 0.1
	var total_h: float = 0.0

	match archetype:
		"DESERT":
			# MESAS & CANYONS: Sharp transitions between flat high-ground and flat low-ground
			var mesa = smoothstep(-0.1, 0.1, macro_h) * 2.0 - 1.0 
			total_h = (mesa * 0.6 + micro_crag) * terrain_strength * 0.7
		"VOLCANIC", "ABYSS":
			# JAGGED RIDGES: Extreme peaks and deep, sharp ravines using 'Ridge Noise' (1.0 - abs(noise))
			var jagged = 1.0 - abs(macro_h * 1.5) 
			total_h = (jagged * 2.0 - 0.8 + micro_crag * 2.5) * terrain_strength * 1.4
		"FROZEN":
			# GLACIAL PLAINS: Smooth, sweeping drifts punctuated by sudden, violent ice spikes
			var plains = macro_h * 0.4
			var spikes = max(0.0, noise.get_noise_3dv(sphere_norm * 2500.0) - 0.65) * 6.0
			total_h = (plains + spikes + micro_crag * 0.4) * terrain_strength
		"TOXIC", "RADIATED":
			# POCKMARKED WASTELAND: Heavily cratered and unnatural, chaotic frequency
			var craters = abs(noise.get_noise_3dv(sphere_norm * 1200.0))
			var bubbling = noise.get_noise_3dv(sphere_norm * 3000.0) * 0.5
			total_h = (macro_h - craters * 1.8 + bubbling + micro_crag) * terrain_strength * 0.6
		"ALPINE":
			# CRAGGY PEAKS: High-frequency ridge noise for dramatic vertical scale
			var ridge = 1.0 - abs(macro_h)
			total_h = (ridge * 2.5 - 0.8 + micro_crag * 1.5) * terrain_strength * 1.5
		_:
			# LUSH / CANDY / DEFAULT: The classic 'No Man's Sky' smooth terraced hills
			total_h = (macro_h + micro_crag) * terrain_strength
			var volcanic: float = noise.get_noise_3dv(sphere_norm * 25000.0)
			if volcanic > 0.45: total_h -= 1000.0
			# Stepped Terracing
			var h_frac = fposmod(total_h, 80.0) / 80.0
			total_h = (floor(total_h / 80.0) + smoothstep(0.15, 0.85, h_frac)) * 80.0

	return planet_radius + total_h

func _spawn_majestic_clouds_and_rings(rng: RandomNumberGenerator, base_hue: float) -> void:
	# 1. PUFFY CLOUD BELTS: Massive celestial sphere at 35km altitude
	# MOBILE: Drop tessellation ~4x (64/32 → 32/16) — the fluid shader over a
	# sphere-scale mesh is one of the biggest vertex shader costs per frame.
	var c_mesh = SphereMesh.new(); c_mesh.radius = planet_radius + 35000.0; c_mesh.height = c_mesh.radius * 2.0
	if mobile_perf:
		c_mesh.radial_segments = 32; c_mesh.rings = 16
	else:
		c_mesh.radial_segments = 64; c_mesh.rings = 32
	var c_shader = Shader.new(); c_shader.code = """shader_type spatial; render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;
	uniform vec3 sun_dir;
	uniform vec3 horizon_color;
	varying vec3 v_local_pos;
	varying vec3 v_world_pos;
	varying vec3 v_normal;
	
	void vertex() {
		v_local_pos = VERTEX;
		v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		v_normal = normalize(VERTEX);
	}
	
	float fluid_noise(vec3 p) {
		float n = sin(p.x)*cos(p.y) + sin(p.y)*cos(p.z) + sin(p.z)*cos(p.x);
		p = vec3(p.y - p.z, p.z - p.x, p.x - p.y) * 2.3 + p * 1.5;
		n += 0.5 * (sin(p.x)*cos(p.y) + sin(p.y)*cos(p.z) + sin(p.z)*cos(p.x));
		return n * 0.57;
	}
	
	void fragment() {
		float t = floor(TIME * 8.0) / 8.0 * 1500.0;
		vec3 lp = v_local_pos * 0.00003 + vec3(t*0.00001, 0.0, t*0.00001);
		float macro = fluid_noise(lp);
		float puff = fluid_noise(lp * 4.0 + vec3(100.0));
		float cloud_mask = smoothstep(0.1, 0.8, macro * 1.5 + puff * 0.4);
		
		float cam_dist = length(CAMERA_POSITION_WORLD - v_world_pos);
		float proximity = smoothstep(50.0, 12000.0, cam_dist);
		// Wispy clouds: threshold is higher, so only peaks of noise become clouds
		float active_threshold = mix(0.1, 0.65, proximity);

		float dot_nl = dot(v_normal, sun_dir);
		float terminator = smoothstep(-0.2, 0.2, dot_nl); 
		
		// Tint clouds slightly with the planet's atmospheric color for variety
		vec3 cloud_base = mix(vec3(1.0), horizon_color, 0.3);
		
		if (cloud_mask > active_threshold) {
			ALBEDO = cloud_base;
			// Softer, more transparent clouds (max 0.7 instead of 0.95)
			ALPHA = 0.7 * smoothstep(active_threshold, active_threshold + 0.1, cloud_mask) * mix(0.2, 1.0, terminator);
		} else { 
			discard;
		}
		
		// CELESTIAL HIBERNATION: Fully transparent if extremely distant
		if (cam_dist > 4000000.0) ALPHA = 0.0;
	}"""
	var c_inst = MeshInstance3D.new(); c_inst.mesh = c_mesh; c_inst.material_override = ShaderMaterial.new(); c_inst.material_override.shader = c_shader
	c_inst.material_override.render_priority = 5
	var sun_dir = Vector3(0.5, 0.5, 0.707).normalized()
	c_inst.material_override.set_shader_parameter("sun_dir", sun_dir)
	c_inst.material_override.set_shader_parameter("horizon_color", Vector3(sky_horizon_color.r, sky_horizon_color.g, sky_horizon_color.b))
	c_inst.visibility_range_end = PROXIMITY_CUTOFF; c_inst.visibility_range_end_margin = 100000.0; c_inst.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(c_inst)
	
	# 2. PLANETARY RINGS (50% chance per planet; 25% on mobile to save fragment cost)
	var ring_chance: float = 0.75 if mobile_perf else 0.5
	if rng.randf() > ring_chance:
		var r_mesh = TorusMesh.new(); r_mesh.inner_radius = planet_radius + 150000.0; r_mesh.outer_radius = planet_radius + 400000.0
		if mobile_perf:
			r_mesh.rings = 64; r_mesh.ring_segments = 4
		else:
			r_mesh.rings = 128; r_mesh.ring_segments = 4
		var r_shader = Shader.new(); r_shader.code = """shader_type spatial; render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;
		uniform vec3 ring_col_a;
		varying vec3 v_local_pos;
		void vertex() { v_local_pos = VERTEX; }
		float hash(float n) { return fract(sin(n) * 43758.5453123); }
		void fragment() {
			float d = length(v_local_pos.xz);
			float radial_idx = floor(d * 0.0002);
			float noise_val = hash(radial_idx);
			
			// Multi-frequency bands
			float mask = mix(0.2, 0.8, noise_val);
			mask *= 0.7 + 0.3 * sin(d * 0.0015); // Fine grooves
			mask *= 0.8 + 0.2 * sin(d * 0.00004); // Broad variation
			
			// Cassini-style gaps for realism
			float gaps = step(0.15, abs(sin(d * 0.000025 + noise_val)));
			mask *= gaps;
			
			// Procedural tone shifting per band
			vec3 final_col = ring_col_a * (0.85 + noise_val * 0.25);
			ALBEDO = final_col;
			ALPHA = clamp(mask * 0.6, 0.0, 0.85);
		}"""
		var r_inst = MeshInstance3D.new(); r_inst.mesh = r_mesh; r_inst.material_override = ShaderMaterial.new(); r_inst.material_override.shader = r_shader
		
		# Procedural Ring Palette: Derived from planet hue but desaturated and bright (ice/dust)
		var r_col = Color.from_hsv(base_hue, 0.25, 1.0).lerp(Color.WHITE, 0.3)
		r_inst.material_override.set_shader_parameter("ring_col_a", r_col)
		r_inst.rotation_degrees = Vector3(rng.randf_range(10.0, 35.0), rng.randf_range(0, 360), 0.0)
		r_inst.scale = Vector3(1.0, 0.015, 1.0)
		r_inst.visibility_range_end = PROXIMITY_CUTOFF; add_child(r_inst)

	# 3. POLAR AURORAS — Skipped on mobile (additive-blend full-sphere shader is costly)
	if not mobile_perf:
		_spawn_polar_auroras(pal_grass_col)

func _spawn_polar_auroras(base_color: Color) -> void:
	var a_mesh = SphereMesh.new(); a_mesh.radius = planet_radius + 45000.0; a_mesh.height = a_mesh.radius * 2.0; a_mesh.radial_segments = 48; a_mesh.rings = 24
	var a_shader = Shader.new(); a_shader.code = """shader_type spatial; render_mode unshaded, blend_add, depth_draw_always, cull_disabled;
	uniform vec3 aura_col;
	varying vec3 v_local_pos;
	void vertex() { v_local_pos = VERTEX; }
	void fragment() {
		float polar = smoothstep(0.68, 0.92, abs(normalize(v_local_pos).y));
		if (polar <= 0.01) { discard; }
		ALBEDO = aura_col; ALPHA = polar * 0.65;
	}"""
	var a_inst = MeshInstance3D.new(); a_inst.mesh = a_mesh; a_inst.material_override = ShaderMaterial.new(); a_inst.material_override.shader = a_shader
	a_inst.material_override.set_shader_parameter("aura_col", base_color.lightened(0.5))
	a_inst.visibility_range_end = PROXIMITY_CUTOFF; add_child(a_inst)

# ===========================================================================
# HERO LANDMARK SYSTEM — THE PROCEDURALIST
# ===========================================================================
# Scatters 4-6 colossal navigation anchors per planet. Each landmark type is
# built from raw triangle geometry using SurfaceTool with flat shading,
# making them look like they grew organically from the planet's geology.
# ALL positions are deterministic from the planet_seed for full reproducibility.
# ===========================================================================
func _spawn_hero_landmarks(rng: RandomNumberGenerator) -> void:
	# MOBILE: Cut landmark count 4-6 → 2-3. Each landmark is a SurfaceTool mesh
	# built on the main thread at load time — fewer = faster first-frame paint.
	var num = rng.randi_range(2, 3) if mobile_perf else rng.randi_range(4, 6)
	# Rock color derived from the planet palette — dark, slightly desaturated
	var rock_col: Color = pal_mount_col.darkened(0.15)
	var accent_col: Color = pal_grass_col.lightened(0.1)

	for i in range(num):
		# SPHERICAL PLACEMENT: Random lat/lon, avoiding poles (lat ±70°)
		var lat: float = rng.randf_range(-1.2, 1.2)        # radians, equatorial band
		var lon: float = rng.randf_range(0.0, TAU)
		var sphere_dir := Vector3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon)).normalized()

		# Place base just above the estimated terrain so landmarks root on the ground
		var approx_terrain_h: float = get_terrain_height_at(sphere_dir * planet_radius)
		var base_radius: float = max(approx_terrain_h, planet_radius + 80.0)
		var base_pos: Vector3 = sphere_dir * base_radius

		# Orientation: Y-axis points outward from the planet centre (gravity up)
		var up: Vector3 = sphere_dir
		var fwd: Vector3 = up.cross(Vector3.RIGHT).normalized()
		if fwd.length_squared() < 0.01:
			fwd = up.cross(Vector3.FORWARD).normalized()
		var basis := Basis(fwd.cross(up).normalized(), up, -fwd)

		var landmark_type: int = rng.randi() % 3
		match landmark_type:
			0: _build_spire(base_pos, basis, rng, rock_col, accent_col)
			1: _build_arch(base_pos, basis, rng, rock_col)
			2: _build_floating_island(base_pos, basis, rng, rock_col, accent_col)

# ---------------------------------------------------------------------------
# SPIRE — a tapered hexagonal monolith, stacked in 8 rings that narrow toward
# the peak, giving natural "geological column" silhouette from any angle.
# ---------------------------------------------------------------------------
func _build_spire(base: Vector3, basis: Basis, rng: RandomNumberGenerator, col: Color, accent: Color) -> void:
	var height: float = rng.randf_range(600.0, 1500.0)
	var base_r: float = rng.randf_range(80.0, 180.0)
	var sides: int = 6  # Hexagonal — looks natural and low-poly simultaneously
	var rings: int = 8

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var prev_verts: PackedVector3Array = PackedVector3Array()
	for ring in range(rings + 1):
		var t: float = float(ring) / float(rings)
		# Taper: starts wide, narrows aggressively toward tip (power curve)
		var ring_r: float = base_r * pow(1.0 - t, 1.6)
		var ring_h: float = height * t
		# Slight twist as it rises — organic irregular look
		var twist: float = t * 0.4

		var ring_verts := PackedVector3Array()
		for s in range(sides):
			var angle: float = (float(s) / float(sides)) * TAU + twist
			var local_v := Vector3(cos(angle) * ring_r, ring_h, sin(angle) * ring_r)
			ring_verts.append(base + basis * local_v)
		prev_verts = ring_verts

		if ring == 0:
			continue

		# Get previous ring — rebuild it the same way
		var t_prev: float = float(ring - 1) / float(rings)
		var pr: float = base_r * pow(1.0 - t_prev, 1.6)
		var ph: float = height * t_prev
		var pt: float = t_prev * 0.4
		var prev_ring := PackedVector3Array()
		for s in range(sides):
			var angle: float = (float(s) / float(sides)) * TAU + pt
			prev_ring.append(base + basis * Vector3(cos(angle) * pr, ph, sin(angle) * pr))

		# Stitch quad strip between this ring and the previous ring
		var use_col: Color = accent if ring % 2 == 0 else col
		for s in range(sides):
			var ns: int = (s + 1) % sides
			_add_tri_flat(st, prev_ring[s],  ring_verts[s],   prev_ring[ns],  use_col)
			_add_tri_flat(st, ring_verts[s], ring_verts[ns],  prev_ring[ns],  use_col)

	# Cap the tip with a single triangle fan
	var tip: Vector3 = base + basis * Vector3(0, height, 0)
	var t_last: float = float(rings - 1) / float(rings)
	var lr: float = base_r * pow(1.0 - t_last, 1.6)
	var lh: float = height * t_last
	var lt: float = t_last * 0.4
	for s in range(sides):
		var ns: int = (s + 1) % sides
		var a0: float = (float(s)  / float(sides)) * TAU + lt
		var a1: float = (float(ns) / float(sides)) * TAU + lt
		_add_tri_flat(st, base + basis * Vector3(cos(a0)*lr, lh, sin(a0)*lr),
					  tip, base + basis * Vector3(cos(a1)*lr, lh, sin(a1)*lr), accent)

	st.generate_normals(false)  # MANDATORY flat shading per project rules
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _landmark_material(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.custom_aabb = AABB(Vector3(-2000,-100,-2000), Vector3(4000,2000,4000))
	add_child(mi)

# ---------------------------------------------------------------------------
# ARCH — two rectangular columns bridged by a curved 8-segment stone span.
# Creates the classic "natural arch" navigation landmark silhouette.
# ---------------------------------------------------------------------------
func _build_arch(base: Vector3, basis: Basis, rng: RandomNumberGenerator, col: Color) -> void:
	var pillar_h: float = rng.randf_range(350.0, 650.0)
	var pillar_w: float = rng.randf_range(50.0, 90.0)
	var span: float = rng.randf_range(280.0, 480.0)  # Gap between pillar centers
	var arch_segs: int = 8

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Helper: build a simple tapered box pillar
	var _add_pillar := func(offset_x: float) -> void:
		var corners := [
			Vector3(-pillar_w*0.5, 0, -pillar_w*0.5),
			Vector3( pillar_w*0.5, 0, -pillar_w*0.5),
			Vector3( pillar_w*0.5, 0,  pillar_w*0.5),
			Vector3(-pillar_w*0.5, 0,  pillar_w*0.5),
		]
		var top_scale: float = 0.75  # Pillar narrows slightly at top
		var top_corners := [
			Vector3(-pillar_w*0.5*top_scale, pillar_h, -pillar_w*0.5*top_scale),
			Vector3( pillar_w*0.5*top_scale, pillar_h, -pillar_w*0.5*top_scale),
			Vector3( pillar_w*0.5*top_scale, pillar_h,  pillar_w*0.5*top_scale),
			Vector3(-pillar_w*0.5*top_scale, pillar_h,  pillar_w*0.5*top_scale),
		]
		for f in range(4):
			var fn: int = (f + 1) % 4
			var b0: Vector3 = base + basis * (corners[f]  + Vector3(offset_x, 0, 0))
			var b1: Vector3 = base + basis * (corners[fn] + Vector3(offset_x, 0, 0))
			var t0: Vector3 = base + basis * (top_corners[f]  + Vector3(offset_x, 0, 0))
			var t1: Vector3 = base + basis * (top_corners[fn] + Vector3(offset_x, 0, 0))
			_add_tri_flat(st, b0, t0, b1, col)
			_add_tri_flat(st, t0, t1, b1, col)
	_add_pillar.call(-span * 0.5)
	_add_pillar.call( span * 0.5)

	# Build the curved arch span as a series of quad segments
	var arch_r: float = span * 0.55  # Radius of curvature
	var arch_w: float = pillar_w * 0.7
	for seg in range(arch_segs):
		var t0: float = float(seg)       / float(arch_segs)
		var t1: float = float(seg + 1)   / float(arch_segs)
		var a0: float = PI * t0  # 0 = left foot, PI = right foot
		var a1: float = PI * t1
		# Arch inner and outer radius
		var inner := arch_r - arch_w * 0.5
		var outer := arch_r + arch_w * 0.5
		# Arch lives in the XY plane of the basis, centered above the gap
		var c0i := base + basis * Vector3(-cos(a0) * inner, pillar_h + sin(a0) * inner, 0)
		var c0o := base + basis * Vector3(-cos(a0) * outer, pillar_h + sin(a0) * outer, 0)
		var c1i := base + basis * Vector3(-cos(a1) * inner, pillar_h + sin(a1) * inner, 0)
		var c1o := base + basis * Vector3(-cos(a1) * outer, pillar_h + sin(a1) * outer, 0)
		# Face: front (towards -Z in local space)
		var depth_v := basis * Vector3(0, 0, arch_w * 0.5)
		_add_tri_flat(st, c0i,           c1i,           c0o,           col)
		_add_tri_flat(st, c1i,           c1o,           c0o,           col)
		_add_tri_flat(st, c0i + depth_v, c0o + depth_v, c1i + depth_v, col)
		_add_tri_flat(st, c1i + depth_v, c0o + depth_v, c1o + depth_v, col)

	st.generate_normals(false)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _landmark_material(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.custom_aabb = AABB(Vector3(-800, -100, -800), Vector3(1600, 1200, 1600))
	add_child(mi)

# ---------------------------------------------------------------------------
# FLOATING ISLAND — a lozenge-shaped rock mass hovering above the terrain,
# suspended by one narrow stalactite column. Iconic NMS visual signature.
# ---------------------------------------------------------------------------
func _build_floating_island(base: Vector3, basis: Basis, rng: RandomNumberGenerator, col: Color, accent: Color) -> void:
	var island_r: float = rng.randf_range(200.0, 400.0)
	var island_h: float = island_r * rng.randf_range(0.25, 0.45)  # Flat disc shape
	var float_alt: float = rng.randf_range(350.0, 650.0)         # Float height above terrain
	var sides: int = 8  # Octagonal island

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Island centre
	var centre: Vector3 = base + basis * Vector3(0, float_alt, 0)

	# Build top cap: fan from centre-top to edge ring
	var top_y: float = island_h * 0.5
	var bot_y: float = -island_h * 0.6  # Slightly deeper bottom gives cliff-like underside
	for s in range(sides):
		var a0: float = float(s)       / float(sides) * TAU
		var a1: float = float(s + 1)   / float(sides) * TAU
		var t0 := centre + basis * Vector3(cos(a0) * island_r, top_y, sin(a0) * island_r)
		var t1 := centre + basis * Vector3(cos(a1) * island_r, top_y, sin(a1) * island_r)
		var b0 := centre + basis * Vector3(cos(a0) * island_r * 0.7, bot_y, sin(a0) * island_r * 0.7)
		var b1 := centre + basis * Vector3(cos(a1) * island_r * 0.7, bot_y, sin(a1) * island_r * 0.7)
		var apex_top := centre + basis * Vector3(0, top_y, 0)
		var apex_bot := centre + basis * Vector3(0, bot_y * 1.3, 0)
		# Top face
		_add_tri_flat(st, apex_top, t0, t1, accent)
		# Sides (quad)
		_add_tri_flat(st, t0, b0, t1, col)
		_add_tri_flat(st, t1, b0, b1, col)
		# Bottom face
		_add_tri_flat(st, apex_bot, b1, b0, col.darkened(0.2))

	# Stalactite column hanging below the island toward the ground
	var col_r: float = island_r * 0.08
	var col_sides: int = 5
	var col_top: Vector3 = centre + basis * Vector3(0, bot_y * 1.5, 0)
	var col_bot: Vector3 = base + basis * Vector3(0, 30.0, 0)  # Near ground level
	for s in range(col_sides):
		var a0: float = float(s)       / float(col_sides) * TAU
		var a1: float = float(s + 1)   / float(col_sides) * TAU
		var t0 := col_top + basis * Vector3(cos(a0) * col_r, 0, sin(a0) * col_r)
		var t1 := col_top + basis * Vector3(cos(a1) * col_r, 0, sin(a1) * col_r)
		# Taper to a point at the bottom
		_add_tri_flat(st, t0, col_bot, t1, col.darkened(0.3))

	st.generate_normals(false)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _landmark_material(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.custom_aabb = AABB(Vector3(-600, -100, -600), Vector3(1200, 1400, 1200))
	add_child(mi)

# Shared unshaded-style material for all landmarks — uses the terrain rock colour
func _spawn_poi_marker() -> void:
	var marker_script = load("res://src/ui/POIMarker.gd")
	if not marker_script: return
	var display_name = name.replace("Planet_", "")
	# Place label well above the atmosphere (planet_radius + 40% headroom)
	var height = planet_radius * 1.4
	# Tint the beacon using the planet's grass/surface palette color
	var col = pal_grass_col.lerp(Color.WHITE, 0.5)
	var marker := Node3D.new()
	marker.set_script(marker_script)
	marker.call_deferred("setup", display_name, "planet", height, col)
	add_child(marker)

func _landmark_material(col: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX  # Flat per-face shading
	mat.roughness = 0.92
	mat.metallic = 0.0
	return mat

# Flat-shaded triangle helper: all 3 verts share same face normal (computed from geometry)
func _add_tri_flat(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
	# Per-project rules: flat shading via manual face-normal on every triangle
	var face_n: Vector3 = (b - a).cross(c - a).normalized()
	st.set_color(col)
	st.set_normal(face_n); st.add_vertex(a)
	st.set_normal(face_n); st.add_vertex(b)
	st.set_normal(face_n); st.add_vertex(c)

func _process(_delta: float) -> void:
	# ACE: Staggered Pool Pre-warm logic — must run at TOP to bypass hibernation returns
	if _prewarm_count < _prewarm_target:
		_prewarm_one_chunk()
		_prewarm_count += 1

	if not player:
		var players = get_tree().get_nodes_in_group("Player")
		if players.size() > 0: player = players[0]
		return
	
	# CELESTIAL DISTANCE LOD: Hibernation Mode
	var dist_to_player = player.global_position.distance_to(global_position)
	
	# FRUSTUM HIBERNATION: Disabled if inside the planetary sphere of influence
	var cam = get_viewport().get_camera_3d()
	var should_hibernate = false
	var safety_dist = planet_radius * 3.5
	if cam and dist_to_player > safety_dist: 
		var to_planet = (global_position - cam.global_position).normalized()
		var cam_fwd = -cam.global_transform.basis.z
		var dot = cam_fwd.dot(to_planet)
		
		# ACE HYSTERESIS: Wider margins to ensure horizons don't pop
		if faces_hidden: should_hibernate = dot < -0.3 # Show earlier
		else: should_hibernate = dot < -0.8 # Hide later
	
	var should_hide_faces = should_hibernate
	if faces_hidden != should_hide_faces:
		for face in faces: face.visible = !should_hide_faces
		_ensure_impostor_active(should_hide_faces)
		faces_hidden = should_hide_faces
	
	# MEMORY RECLAMATION (Reaper): Push nodes to Death Row only when strictly out of range.
	if dist_to_player > PROXIMITY_CUTOFF:
		if not faces_hidden:
			for face in faces: 
				if face.root_node: face.root_node.dispose()
			_ensure_impostor_active(true)
			faces_hidden = true
			split_queue.clear()
		return # Hibernating!
	else:
		if faces_hidden:
			for face in faces: 
				face.visible = true
				# ACE RECONSTRUCTION: Re-init root nodes upon re-entry.
				if face.root_node: face.root_node.ensure_chunk()
			_ensure_impostor_active(false)
			faces_hidden = false
			# ACE SEAMLESS HANDOVER: Trigger immediate regeneration to minimize pop
			for face in faces: if face.root_node: face.root_node.ensure_chunk()
	
	# ACE PERFORMANCE HARDENING: Frame-Slice the QuadTree update
	# Instead of checking all 6 faces every frame, we cycle through them.
	_lod_face_idx = (_lod_face_idx + 1) % faces.size()
	
	var face_to_update = faces[_lod_face_idx]
	if face_to_update.visible and dist_to_player < planet_radius * 2.5:
		face_to_update.update_lod(player.global_position)
	
	# High-performance splitting: one mesh commit per frame
	for i in range(min(split_queue.size(), MAX_SPLITS_PER_FRAME)):
		var node = split_queue.pop_back()
		if node: node.execute_split()
	
	# ACE RECLAMATION: Process Zombie Pool
	var z_batch = min(zombie_pool.size(), 6 if mobile_perf else 10) # ACE: Limit zombie checks per frame
	for i in range(z_batch):
		var z = zombie_pool.pop_back()
		if z.is_busy():
			zombie_pool.append(z)
		else:
			chunk_pool.append(z)
	
	# ACE FINALIZATION: Predictable Generation Cycles
	# STRICT BUDGET: Spaced out to prevent frame spikes on mobile
	MAX_FINALIZE_PER_FRAME = 1 if (OS.get_name() == "iOS" or OS.get_name() == "Android") else 2
	for i in range(min(finalize_queue.size(), MAX_FINALIZE_PER_FRAME)):
		var chunk = finalize_queue.pop_back()
		if is_instance_valid(chunk):
			chunk._finalize_generation_on_main()
			
	# ACE PROP THROTTLE: Spread node instantiation across multiple frames
	for i in range(min(prop_spawn_queue.size(), 1 if mobile_perf else 2)):
		var task = prop_spawn_queue.pop_back()
		var node = task[0]
		var method = task[1]
		var data = task[2]
		if is_instance_valid(node) and node.has_method(method):
			node.call(method, data)

	# ACE REAPER: Asynchronous destruction of urban nodes
	var death_budget = 12 if mobile_perf else MAX_DEATHS_PER_FRAME
	for i in range(min(death_row.size(), death_budget)):
		var d = death_row.pop_back()
		if is_instance_valid(d): d.free()
	
	for i in range(min(collision_queue.size(), MAX_COLLISIONS_PER_FRAME)):
		var c = collision_queue.pop_back()
		if is_instance_valid(c):
			# ACE PERMANENT FIX: Use the background-baked Collision Shape
			# Instead of create_trimesh_collision() (which is a sync main-thread choke)
			if "_collision_shape" in c and c._collision_shape:
				var body = StaticBody3D.new()
				c.add_child(body)
				var shape_node = CollisionShape3D.new()
				shape_node.shape = c._collision_shape
				body.add_child(shape_node)
				
func _prewarm_procedural_pool(count: int) -> void:
	for i in range(count):
		var c = PlanetChunkScript.new()
		chunk_pool.append(c)

func queue_chunk_for_finalization(chunk: Node) -> void:
	# ACE: Thread-safe handover to the main finalization queue
	if not finalize_queue.has(chunk):
		finalize_queue.append(chunk)

func get_terrain_elevation(sn: Vector3) -> float:
	if not noise: return 0.0
	# ACE: Master Elevation Formula (STRICT SYNC with PlanetChunk)
	var macro_h: float = noise.get_noise_3dv(sn * 600.0)
	var micro_crag: float = noise.get_noise_3dv(sn * 15000.0) * 0.1
	var local_geo: float = 0.0

	match archetype:
		"DESERT":
			var mesa = smoothstep(-0.1, 0.1, macro_h) * 2.0 - 1.0 
			local_geo = (mesa * 0.6 + micro_crag) * terrain_strength * 0.7
		"VOLCANIC", "ABYSS":
			var jagged = 1.0 - abs(macro_h * 1.5) 
			local_geo = (jagged * 2.0 - 0.8 + micro_crag * 2.5) * terrain_strength * 1.4
		"FROZEN":
			var plains = macro_h * 0.4
			var spikes = max(0.0, noise.get_noise_3dv(sn * 2500.0) - 0.65) * 6.0
			local_geo = (plains + spikes + micro_crag * 0.4) * terrain_strength
		"TOXIC", "RADIATED":
			var craters = abs(noise.get_noise_3dv(sn * 1200.0))
			var bubbling = noise.get_noise_3dv(sn * 3000.0) * 0.5
			local_geo = (macro_h - craters * 1.8 + bubbling + micro_crag) * terrain_strength * 0.6
		"ALPINE":
			var ridge = 1.0 - abs(macro_h)
			local_geo = (ridge * 2.5 - 0.8 + micro_crag * 1.5) * terrain_strength * 1.5
		_:
			local_geo = (macro_h + micro_crag) * terrain_strength
			var volcanic: float = noise.get_noise_3dv(sn * 25000.0)
			if volcanic > 0.45: local_geo -= 1000.0
			var terrace_height = 80.0
			var h_frac = fposmod(local_geo, terrace_height) / terrace_height
			var layer_step = floor(local_geo / terrace_height) + smoothstep(0.15, 0.85, h_frac)
			local_geo = layer_step * terrace_height
	
	var c_n: float = noise.get_noise_3dv(sn * 2.2)
	c_n += noise.get_noise_3dv(sn * 6.5) * 0.5
	c_n += noise.get_noise_3dv(sn * 15.0) * 0.25
	var cont_mask: float = smoothstep(-0.2, 0.2, c_n + 0.3)
	var S_LVL: float = -120.0
	var abyss_depth: float = S_LVL - 400.0
	
	var elev = lerp(abyss_depth, local_geo + (S_LVL + 50.0), cont_mask)
	return elev

func _ensure_impostor_active(active: bool) -> void:
	if active:
		if not impostor:
			var script = load("res://src/world/PlanetImpostor.gd")
			impostor = Node3D.new(); impostor.set_script(script)
			impostor.set("planet_radius", planet_radius)
			# Pass the ACTUAL terrain palette colors (not sky!) so impostor matches what you see up close
			impostor.set("planet_color", pal_grass_col)
			impostor.set("planet_color_b", pal_mount_col)
			impostor.set("water_col", pal_water_base) # ACE ATMOSPHERIC SYNC
			impostor.set("horizon_col", sky_horizon_color) # ACE: Atmospheric Sync
			impostor.set("continent_pole", continent_pole) # ACE SYNC
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
		# CRITICAL: We wait for ALL 4 children to be Ready before removing parent!
		# This eliminates the 'black squares' holes during subdivision.
		_ready_children = 0
		for child in children:
			child.ensure_chunk()
			if child.chunk and child.chunk.has_signal("generation_completed"):
				if not child.chunk.generation_completed.is_connected(_on_child_gen_done):
					child.chunk.generation_completed.connect(_on_child_gen_done, CONNECT_ONE_SHOT)
	
	func _on_child_gen_done() -> void:
		_ready_children += 1
		if _ready_children >= 4:
			remove_chunk() # Now safe to remove parent as children are visible

	func merge() -> void:
		if children.is_empty(): return
		# CRITICAL: Wait for the parent to be ready before killing high-detail children!
		ensure_chunk()
		if chunk and chunk.has_signal("generation_completed"):
			if not chunk.generation_completed.is_connected(_on_parent_ready_for_merge):
				chunk.generation_completed.connect(_on_parent_ready_for_merge, CONNECT_ONE_SHOT)

	func _on_parent_ready_for_merge() -> void:
		if children.is_empty(): return
		for child in children: child.dispose()
		children.clear()

	var _ready_children: int = 0
	
	func ensure_chunk() -> void:
		if chunk: return
		
		# ACE MEMORY LEAK FIX: Removed the 'not children.is_empty' abort.
		if face.planet.chunk_pool.is_empty():
			chunk = face.planet.PlanetChunkScript.new()
			face.add_child(chunk)
		else:
			chunk = face.planet.chunk_pool.pop_back()
			if chunk.get_parent():
				if chunk.get_parent() != face:
					chunk.reparent(face)
			else:
				face.add_child(chunk)
			
		chunk.face = face
		chunk.planet = face.planet
		chunk.noise = face.planet.noise
		chunk.radius = face.planet.planet_radius
		chunk.terrain_strength = face.planet.terrain_strength
		chunk.face_normal = face.normal
		chunk.x_axis = face.x_axis
		chunk.y_axis = face.y_axis
		chunk.offset = local_offset
		chunk.scale_factor = scale
		if scale > 0.05:   chunk.resolution = 16
		elif scale > 0.01: chunk.resolution = 24
		else:              chunk.resolution = 32
		var planet_mobile_perf: bool = bool(face.planet.get("mobile_perf")) if face.planet else false
		if planet_mobile_perf:
			if scale > 0.05:   chunk.resolution = 12
			elif scale > 0.01: chunk.resolution = 18
			else:              chunk.resolution = 24
		chunk.planet_seed = face.planet.planet_seed
		chunk.archetype = face.planet.archetype
		
		# PALETTE INJECTION
		chunk.pal_grass_col = face.planet.pal_grass_col
		chunk.pal_mount_col = face.planet.pal_mount_col
		chunk.pal_forest_col = face.planet.pal_forest_col
		chunk.pal_forest_h = face.planet.pal_forest_h
		chunk.pal_grass_secondary = face.planet.pal_grass_secondary
		chunk.pal_beach_col = face.planet.pal_beach_col
		chunk.pal_water_base = face.planet.pal_water_base
		chunk.pal_water_light = face.planet.pal_water_light
		chunk.pal_water_shore = face.planet.pal_water_shore
		chunk.continent_pole = face.planet.continent_pole
		
		var p = face.planet.player
		chunk.scatter_grass = (p != null and not p.get("in_ship"))
		chunk.start_generation()
		
	func remove_chunk() -> void:
		if chunk: 
			# Push back to pool instead of destroying memory
			chunk.sleep_and_reset()
			if chunk.is_busy():
				face.planet.zombie_pool.append(chunk)
			else:
				face.planet.chunk_pool.append(chunk)
			chunk = null
			
	func dispose() -> void:
		if lod == 0: return # ACE: Base chunks never die
		remove_chunk()
		for child in children: child.dispose()
		children.clear()

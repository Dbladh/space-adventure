extends Node3D

# PlanetGen.gd (Aggressive Horizon Edition)
# Managed by THE ARCHITECT.

var PlanetChunkScript = load("res://src/world/PlanetChunk.gd")

@export var planet_radius: float = 100000.0 
@export var terrain_strength: float = 5000.0 
@export var max_lod: int = 18 
@export var subdivision_bias: float = 1.8
# Each planet must get a unique seed so terrain is distinct per celestial body!
@export var planet_seed: int = 1234
# Resources available to mine on this planet. Set externally before chunks generate.
# Stone and Wood are always present; extras are tier-gated by how the planet was forged.
var planet_resources: Array[String] = ["Stone", "Wood", "Copper"]
# Forge-rank label (F / D / C / B / A / S / SS / ★ LEGENDARY). Set by
# SpaceStation after spawning so chunks/props can vary visuals (e.g. only rare
# A+ planets get glowing flora). Empty = unranked (default starter look).
var planet_rank: String = ""
var sea_level: float = -120.0

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
var mobile_perf: bool = false
var faces: Array[QuadTreeFace] = []
var player: Node3D

# TOPOGRAPHY VARIETY: Deterministic terrain style per planet
var terrain_mode: String = "VARIED" # FLAT, HILLY, MOUNTAINOUS, EXTREME
var noise_frequency: float = 600.0
var terrain_multiplier: float = 1.0
var has_bioluminescence: bool = false

# SHARED MATERIALS: Cached per planet to reduce Draw Calls and State Changes
var land_material: ShaderMaterial
var water_material: ShaderMaterial
var foliage_material: ShaderMaterial
var trunk_material: ShaderMaterial
var rock_material: ShaderMaterial
var grass_material: ShaderMaterial

# ACE MEMORY POOLING: Hibernation buffer for QuadTree nodes to prevent GC stutters
var chunk_pool: Array[MeshInstance3D] = []
var continent_pole: Vector3 = Vector3.UP # ACE: Deterministic anchor for the major island

# NMS OPTIMIZATION: Throttle chunk streaming to prevent CPU micro-stutters!
# One split per frame keeps mesh generation within frame budget.
var split_queue: Array[QuadTreeNode] = []
const MAX_SPLITS_PER_FRAME: int = 3
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
const MAX_COLLISIONS_PER_FRAME: int = 4
var MAX_FINALIZE_PER_FRAME: int = 4
const MAX_DEATHS_PER_FRAME: int = 48
var _prewarm_count: int = 0
var _prewarm_target: int = 32

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
	self.add_to_group("Planet")
	self.add_to_group("World")
	print("--- ARCHITECT: Planet [%s] _ready. Parent: %s, Global Pos: %s ---" % [name, get_parent().name if get_parent() else "NONE", str(global_position)])
	mobile_perf = OS.get_name() == "iOS" or OS.get_name() == "Android" or OS.has_feature("mobile")
	# Mobile QuadTree caps: stop subdividing four levels short of desktop and
	# pull the subdivide-trigger radius in. Cuts worst-case chunk count
	# dramatically during atmosphere entry — the dominant freeze on iPhone 15.
	if mobile_perf:
		max_lod = 14
		subdivision_bias = 1.2
	noise = FastNoiseLite.new()
	_prewarm_target = 32
	# Always use the explicit planet_seed for terrain noise.
	# Main.gd sets unique values (1001, 2002...) before add_child() is called,
	# so _ready() always receives the correct distinct seed per body.
	# NOISE VARIETY: The Geologist
	var geo_rng = RandomNumberGenerator.new()
	geo_rng.seed = planet_seed + 555
	noise.seed = planet_seed
	
	# Randomize noise type for high variety
	var n_types = [FastNoiseLite.TYPE_PERLIN, FastNoiseLite.TYPE_SIMPLEX, FastNoiseLite.TYPE_VALUE]
	noise.noise_type = n_types[geo_rng.randi() % n_types.size()]
	
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.frequency = 0.01 
	noise.fractal_octaves = geo_rng.randi_range(3, 6)
	noise.fractal_lacunarity = geo_rng.randf_range(1.8, 2.4)
	noise.fractal_gain = geo_rng.randf_range(0.3, 0.6)
	
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
	
	# SEA LEVEL RANDOMIZATION: The Hydrologist
	var hydro_rng = RandomNumberGenerator.new()
	hydro_rng.seed = planet_seed + 123
	# Range from -250 (shallow/scattered) to -50 (deep/continental)
	sea_level = hydro_rng.randf_range(-250.0, -50.0)
	
	# TOPOGRAPHY DIVERSIFICATION: The Cartographer
	# We randomize how 'aggressive' the terrain is based on a separate roll.
	var topo_rng = RandomNumberGenerator.new()
	topo_rng.seed = hash(str(planet_seed) + "topo") & 0x7FFFFFFF
	var topo_roll = topo_rng.randf()
	
	if topo_roll > 0.9:
		terrain_mode = "EXTREME"
		terrain_multiplier = 1.8
		noise_frequency = 800.0
	elif topo_roll > 0.65:
		terrain_mode = "MOUNTAINOUS"
		terrain_multiplier = 1.2
		noise_frequency = 600.0
	elif topo_roll > 0.3:
		terrain_mode = "HILLY"
		terrain_multiplier = 0.6
		noise_frequency = 400.0
	else:
		terrain_mode = "FLAT"
		terrain_multiplier = 0.25
		noise_frequency = 300.0
	
	# ACE: Global scale correction for small planets (100km range)
	# We scale strength linearly with radius to prevent the 'spikey' look.
	var scale_fix = planet_radius / 180000.0
	terrain_strength = 2800.0 * scale_fix * terrain_multiplier
	
	# BIOLUMINESCENCE ROLL: The Exobiologist
	# Only 12% of planets exhibit natural glowing flora (S-Tier rarity)
	# CANDY and RADIATED archetypes have a 2.5x higher chance.
	var bio_chance = 0.12
	if archetype == "CANDY" or archetype == "RADIATED": bio_chance = 0.30
	has_bioluminescence = hydro_rng.randf() < bio_chance
	
	print("--- CARTOGRAPHER: Planet [%s] Type: [%s] Topo: [%s] Bio: [%s] ---" % [name, archetype, terrain_mode, str(has_bioluminescence)])
	
	# INITIALIZE SHARED MATERIALS: Now at the end so trait rolls (Bio/Archetype) are baked in
	_init_shared_materials()
	
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
	print("--- ARCHITECT: Planet [%s] Initialized. Theme: %s (Radius: %d) ---" % [name, theme, planet_radius])
	
	# MAJOR CONTINENT ARCHITECT: Every planet gets one iconic, massive landmass
	var c_rng = RandomNumberGenerator.new(); c_rng.seed = planet_seed + 999
	continent_pole = Vector3(c_rng.randf_range(-1,1), c_rng.randf_range(-1,1), c_rng.randf_range(-1,1)).normalized()
	
	for i in range(6):
		var face = QuadTreeFace.new(self, FACE_NORMALS[i])
		faces.append(face)
		add_child(face)
	# ACE: Inject majestic cloud belts and celestial rings — visible against the charcoal void
	_spawn_majestic_clouds_and_rings(rng, base_hue)
	# ACE: Scatter colossal Hero Landmarks as navigation anchors across the planet surface
	_spawn_hero_landmarks(rng)
	# Per-planet POI beacon disabled — the off-axis pillar wasn't useful as a
	# navigation aid (it pointed at +Y pole, not the player) and rendered as
	# stray geometry through transparent water/lava surfaces. Stations keep
	# their POIMarker (spawned from Main.gd) since those are real landmarks
	# the player can dock at.
	# _spawn_poi_marker()
	# print("--- ARCHITECT: PLANET [%s] SYNCHRONIZED (terrain_seed=%d) ---" % [name, noise.seed])

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
	# 1. PUFFY CLOUD BELTS: Massive celestial sphere at 2.5km altitude (Hugging closer)
	var c_mesh = SphereMesh.new(); c_mesh.radius = planet_radius + 2500.0; c_mesh.height = c_mesh.radius * 2.0
	c_mesh.radial_segments = 64; c_mesh.rings = 32
	var c_shader = Shader.new(); c_shader.code = """shader_type spatial; render_mode unshaded, blend_mix, cull_disabled;
	// depth_draw_always removed: previously the cloud layer wrote depth even
	// for partially-transparent fragments, which caused alpha-blended cloud
	// pixels to occlude the terrain & ship behind them in the same frame.
	uniform vec3 sun_dir;
	uniform vec3 horizon_color;
	uniform float planet_r;
	// Per-planet variation knobs:
	//   cell_scale  — drives blob size. Smaller = more cells per planet
	//                 (small dense puffs); larger = fewer big blobs.
	//   thresh_lo   — smoothstep lower edge for coverage. Lower value
	//                 means more density passes the gate (overcast).
	//   thresh_hi   — smoothstep upper edge. We keep a 0.20 band width
	//                 so feather softness stays consistent across planets.
	//   alpha_max   — peak per-fragment alpha; thicker for very dense
	//                 worlds, thinner for hazy ones.
	uniform float cell_scale = 0.005;
	uniform float thresh_lo  = 0.55;
	uniform float thresh_hi  = 0.78;
	uniform float alpha_max  = 0.70;
	// Unique 3D offset per cloud layer so stacked shells don't sample the
	// same noise pattern. Without this, every shell renders identical clouds
	// and the stack reads as one slab instead of multiple altitudes.
	uniform vec3  layer_offset = vec3(0.0);
	varying vec3 v_local_pos;
	varying vec3 v_world_pos;
	varying vec3 v_normal;

	// Hash-based value noise. Old form was `fract(p.x*p.y*p.z*(p.x+p.y+p.z))`
	// — symmetric in (x,y,z) and near-zero along the x+y+z=0 plane, so cloud
	// cells aligned to octahedral diagonals and read as rhombuses on the
	// surface. Use IQ-style sin-dot hash with asymmetric coefficients.
	float hash3(vec3 p) {
		return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
	}
	float vnoise(vec3 p) {
		vec3 i = floor(p); vec3 f = fract(p);
		f = f * f * (3.0 - 2.0 * f);
		return mix(mix(mix(hash3(i + vec3(0,0,0)), hash3(i + vec3(1,0,0)), f.x),
		               mix(hash3(i + vec3(0,1,0)), hash3(i + vec3(1,1,0)), f.x), f.y),
		           mix(mix(hash3(i + vec3(0,0,1)), hash3(i + vec3(1,0,1)), f.x),
		               mix(hash3(i + vec3(0,1,1)), hash3(i + vec3(1,1,1)), f.x), f.y), f.z);
	}
	float fbm(vec3 p) {
		float v = 0.0; float a = 0.5;
		for (int i = 0; i < 5; i++) {
			v += a * vnoise(p);
			p = p * 2.13 + vec3(13.7, 5.1, 19.3);
			a *= 0.5;
		}
		return v; // 0..~1
	}

	// Multi-scale density combiner — produces small + medium + large puffs
	// in the same field. WEIGHTED SUM rather than MAX so peaks aren't
	// sharpened (MAX produces triangular spike-like silhouettes; weighted
	// sum stays soft and cotton-like). The layer_offset uniform shifts the
	// noise position per stacked shell so the layers aren't identical.
	float cloud_density(vec3 dir, float t, float c_scale) {
		vec3 base = dir * planet_r * c_scale + layer_offset;
		vec3 lp_large = base * 0.35 + vec3(t * 0.6, t * 0.3, -t * 0.2);
		vec3 lp_med   = base * 1.0  + vec3(t, t * 0.5, -t * 0.3) + vec3(50.0);
		vec3 lp_small = base * 2.8  + vec3(-t * 0.4, t * 0.6, t * 0.2) + vec3(100.0);
		float d_large = fbm(lp_large);
		float d_med   = fbm(lp_med);
		float d_small = fbm(lp_small);
		return d_large * 0.50 + d_med * 0.35 + d_small * 0.15;
	}

	void vertex() {
		v_local_pos = VERTEX;
		v_normal = normalize(VERTEX);
		// VERTEX DISPLACEMENT: subtle bumps for parallax depth, NOT towers.
		// The previous bump_height (planet_r * cell_scale * 1200) worked out
		// to ~120km of displacement on small planets — that's why clouds
		// looked like triangular mountains. Cap at a fixed fraction (~12%)
		// of one cell's lateral surface size so bumps stay rounded and
		// proportional rather than dwarfing the puff.
		float vt = TIME * 0.015;
		float v_dens = cloud_density(v_normal, vt, cell_scale);
		float v_bump = smoothstep(thresh_lo - 0.05, thresh_hi + 0.05, v_dens);
		float lateral_cell_metres = 1.0 / max(cell_scale, 0.00001);
		float bump_height = lateral_cell_metres * 0.12;
		VERTEX += v_normal * v_bump * bump_height;
		v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}

	void fragment() {
		float t = TIME * 0.015;
		vec3 dir = normalize(v_local_pos);

		// Surface density at this fragment.
		float density = cloud_density(dir, t, cell_scale);
		// Edge fluff via micro-detail noise — pure variation (mean-centred).
		vec3 lp_micro = dir * planet_r * cell_scale * 8.0 + layer_offset
			+ vec3(t * 0.8, -t * 0.5, t * 0.3);
		density += fbm(lp_micro) * 0.08 - 0.04;

		// VOLUMETRIC RAYMARCHING: sample density at 4 points along the view
		// ray, going INTO the cloud sphere, and accumulate coverage. This
		// approximates flying through a volumetric cloud rather than a 2D
		// shell — fragments where view ray pierces deep cloud get higher
		// total coverage than fragments where it just grazes the silhouette.
		// The local-space camera position lets us march in local coords so
		// the noise sampling stays consistent with the rest of the shader.
		vec3 cam_local = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
		vec3 view_local = normalize(v_local_pos - cam_local);
		float march_step = max(planet_r * 0.0015, 200.0);
		float volumetric_density = density;
		for (int i = 1; i <= 3; i++) {
			vec3 sample_pos = v_local_pos + view_local * march_step * float(i);
			vec3 sample_dir = normalize(sample_pos);
			volumetric_density += cloud_density(sample_dir, t, cell_scale);
		}
		volumetric_density *= 0.25;  // average across 4 samples
		// Blend surface density with marched density — surface gives sharp
		// silhouette, marched gives interior thickness.
		density = mix(density, volumetric_density, 0.55);

		// Coverage smoothstep — slight lower-edge softening for wispy edges
		// without flooding the whole sphere with low-density haze. The
		// previous 0.50 lower-edge expansion was letting nearly every
		// fragment pass with some coverage, which is what painted the
		// planet white-on-everything.
		float thresh_feather = max(thresh_hi - thresh_lo, 0.001);
		float coverage = smoothstep(thresh_lo - thresh_feather * 0.15, thresh_hi, density);

		float cam_dist = length(CAMERA_POSITION_WORLD - v_world_pos);
		float proximity = smoothstep(50.0, 30000.0, cam_dist);
		coverage *= mix(1.0, 0.6, proximity);

		if (coverage < 0.01) discard;

		// SOFT self-shadow — much weaker than before. Heavy self-shadow
		// produces hard interior lines that look like geometric facets,
		// not cotton. We keep just enough to prevent total flatness.
		vec3 lp_shadow = dir * planet_r * cell_scale + sun_dir * (cell_scale * planet_r * 0.04);
		float shadow_density = fbm(lp_shadow + vec3(t, t * 0.5, -t * 0.3));
		float self_shadow = smoothstep(0.40, 0.80, shadow_density);

		float dot_nl = dot(v_normal, sun_dir);
		float terminator = smoothstep(-0.2, 0.25, dot_nl);

		// Gentle density-driven brightness — kept close to white throughout
		// so opaque clouds read as bright cumulus, not muddy/brown blobs.
		// Horizon tint capped at 8% even on shadow_color to prevent strongly
		// coloured atmospheres from turning the clouds orange/brown.
		float core = smoothstep(thresh_lo, thresh_hi + 0.20, density);
		vec3 lit_color    = mix(vec3(1.00), horizon_color, 0.05);
		vec3 edge_color   = mix(vec3(0.94, 0.95, 0.97), horizon_color, 0.10);
		vec3 shadow_color = mix(vec3(0.78, 0.80, 0.85), horizon_color, 0.08);
		vec3 cloud_color = mix(edge_color, lit_color, core);
		cloud_color = mix(cloud_color, shadow_color, self_shadow * 0.40);
		// Night-side darkening — only halve, not 70%, so the "shadow side"
		// reads as dim grey rather than near-black brown.
		cloud_color = mix(cloud_color * 0.50, cloud_color, terminator);

		ALBEDO = cloud_color;
		// Edge alpha pulled close to 1.0 so silhouettes are nearly as opaque
		// as the cloud cores — wispy silhouette comes from the noise field
		// itself, not from per-fragment alpha falloff.
		float edge_alpha = mix(0.85, 1.0, core);
		ALPHA = coverage * alpha_max * edge_alpha * mix(0.55, 1.0, terminator);

		// CELESTIAL HIBERNATION: Fully transparent if extremely distant
		if (cam_dist > 4000000.0) ALPHA = 0.0;
	}"""
	var c_inst = MeshInstance3D.new(); c_inst.mesh = c_mesh; c_inst.material_override = ShaderMaterial.new(); c_inst.material_override.shader = c_shader
	c_inst.material_override.render_priority = 5
	var sun_dir = Vector3(0.5, 0.5, 0.707).normalized()
	c_inst.material_override.set_shader_parameter("sun_dir", sun_dir)
	c_inst.material_override.set_shader_parameter("horizon_color", Vector3(sky_horizon_color.r, sky_horizon_color.g, sky_horizon_color.b))
	c_inst.material_override.set_shader_parameter("planet_r", planet_radius)

	# ── Per-planet cloud profile ─────────────────────────────────────
	# Pick blob size and coverage independently from the planet's RNG so
	# every world feels distinct. Cell scale tuned for ~3–5× larger puffs
	# than the original range. Lower values mean fewer/larger puffs (since
	# lp = dir * planet_r * cell_scale samples a smaller noise range across
	# the sphere). The previous 0.00020 floor produced so few cells per
	# planet that fbm output stayed near 0.5 and rarely crossed thresh_lo,
	# so worlds appeared cloudless. 0.0004 keeps ~40 cells per planet —
	# enough variation to consistently produce visible cloud masses.
	# Threshold ceiling lowered so even the sparsest worlds show some clouds.
	var cell_scale: float = rng.randf_range(0.00040, 0.00150)
	var thresh_lo: float  = rng.randf_range(0.42, 0.62)
	var thresh_hi: float  = thresh_lo + 0.20
	# Alpha range tuned for "almost no transparency" — clouds read clearly as
	# their own layer over the planet surface. Sparse worlds get the higher
	# end (0.95, near-solid puffs); overcast worlds get the lower end (0.85)
	# so the layer doesn't completely paint over the silhouette when many
	# puffs overlap. Edge translucency in the shader handles the wispy
	# silhouette feel — these uniforms control the core opacity.
	var alpha_max: float  = lerpf(0.95, 0.85, smoothstep(0.42, 0.62, thresh_lo))

	# CLOUD SHADOWS ON LAND — push the cloud-noise parameters onto the
	# shared land_material so triplanar_local.gdshader can sample the same
	# density field this planet's clouds use, and darken the surface
	# accordingly. Strength uniform is also conveyed so the cloud spawn
	# can dial it down per planet (e.g. 0 for cloudless worlds later).
	if land_material:
		land_material.set_shader_parameter("cloud_cell_scale", cell_scale)
		land_material.set_shader_parameter("cloud_thresh_lo", thresh_lo)
		land_material.set_shader_parameter("cloud_thresh_hi", thresh_hi)
		land_material.set_shader_parameter("cloud_strength", 0.40)
	c_inst.queue_free()  # discard initial layer; the stack below replaces it

	# Multi-shell stack — N cloud spheres at different altitudes, each
	# sampling the same cloud_density() but with a per-layer offset so the
	# layers aren't identical. Stacked together they read as cloud volume
	# rather than a single shell — flying past, the player sees clouds
	# at different heights cross at different angles and densities, which
	# is what produces the "thickness" feel.
	var sun_dir_local: Vector3 = sun_dir
	var horizon_vec: Vector3 = Vector3(sky_horizon_color.r, sky_horizon_color.g, sky_horizon_color.b)
	# Layer altitudes in metres above planet surface. Spread across ~7km
	# of vertical range so the cloud band has real thickness.
	var layer_altitudes: Array = [1500.0, 2800.0, 4200.0, 5800.0, 7500.0]
	# Per-layer relative cell scale and alpha — middle layers are densest,
	# outer layers (top/bottom) thin out so the band has soft edges in
	# altitude as well.
	var layer_scale_mul: Array = [1.10, 1.00, 0.95, 1.30, 2.20]
	var layer_alpha_mul: Array = [0.55, 0.85, 1.00, 0.75, 0.45]
	# DEBUG: cloud shell stack disabled while diagnosing rectangular missing-
	# chunk artifacts. The 5 cull_disabled blend_mix spheres at varying
	# altitudes may be interfering with chunk depth/alpha rendering — testing
	# without them isolates whether the cloud stack is responsible.
	for layer_idx in range(0):
		var alt: float = layer_altitudes[layer_idx]
		var scale_mul: float = layer_scale_mul[layer_idx]
		var alpha_mul: float = layer_alpha_mul[layer_idx]
		var lm = SphereMesh.new()
		lm.radius = planet_radius + alt
		lm.height = lm.radius * 2.0
		lm.radial_segments = 64; lm.rings = 32
		var li = MeshInstance3D.new()
		li.mesh = lm
		li.material_override = ShaderMaterial.new()
		li.material_override.shader = c_shader
		li.material_override.render_priority = 5 + layer_idx
		li.material_override.set_shader_parameter("sun_dir", sun_dir_local)
		li.material_override.set_shader_parameter("horizon_color", horizon_vec)
		li.material_override.set_shader_parameter("planet_r", planet_radius)
		li.material_override.set_shader_parameter("cell_scale", cell_scale * scale_mul)
		li.material_override.set_shader_parameter("thresh_lo", thresh_lo)
		li.material_override.set_shader_parameter("thresh_hi", thresh_hi)
		li.material_override.set_shader_parameter("alpha_max", alpha_max * alpha_mul)
		# Each layer gets a unique 3D offset so the noise sampled across
		# layers isn't identical — without this, all 5 shells would render
		# the exact same cloud pattern and the stack would look like one
		# thick shell instead of distinct vertical layers.
		var layer_seed_offset := Vector3(
			float(layer_idx) * 51.13,
			float(layer_idx) * 27.71 + 11.0,
			float(layer_idx) * 73.91 - 5.0
		)
		li.material_override.set_shader_parameter("layer_offset", layer_seed_offset)
		li.visibility_range_end = PROXIMITY_CUTOFF
		li.visibility_range_end_margin = 100000.0
		li.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(li)
	
	# 2. PLANETARY RINGS (50% chance per planet)
	var ring_chance: float = 0.5
	if rng.randf() > ring_chance:
		var r_mesh = TorusMesh.new()
		r_mesh.inner_radius = planet_radius * 1.5
		r_mesh.outer_radius = planet_radius * 2.8
		r_mesh.rings = 128; r_mesh.ring_segments = 4
		var r_shader = Shader.new(); r_shader.code = """shader_type spatial; render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;
		uniform vec3 ring_col_a;
		varying vec3 v_local_pos;
		void vertex() { v_local_pos = VERTEX; }
		float hash(float n) { return fract(sin(n) * 43758.5453123); }
		void fragment() {
			float d = length(v_local_pos.xz);
			float radial_idx = floor(d * 0.0006); // ACE: Increased frequency for tighter rings
			float noise_val = hash(radial_idx);
			
			// Multi-frequency bands
			float mask = mix(0.2, 0.8, noise_val);
			mask *= 0.7 + 0.3 * sin(d * 0.0045); // Fine grooves (Scaled up)
			mask *= 0.8 + 0.2 * sin(d * 0.0001); // Broad variation (Scaled up)
			
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

	# 3. POLAR AURORAS — disabled. The transparent sphere shader's smoothstep
	# gradient quantized into ~8 visible latitude rings under the halftone
	# post-process no matter how low we pushed the alpha. Snowy poles are
	# now driven entirely by the surface shader's polar_snow band.
	# _spawn_polar_auroras(pal_grass_col)

func _spawn_polar_auroras(base_color: Color) -> void:
	var a_mesh = SphereMesh.new(); a_mesh.radius = planet_radius + 4500.0; a_mesh.height = a_mesh.radius * 2.0; a_mesh.radial_segments = 48; a_mesh.rings = 24
	# Toned down: narrower polar band (0.85→0.97 instead of 0.68→0.92) so the
	# aura only kisses the poles, plus much lower alpha so the halftone
	# post-process quantization isn't visible as concentric rings.
	var a_shader = Shader.new(); a_shader.code = """shader_type spatial; render_mode unshaded, blend_add, depth_draw_always, cull_disabled;
	uniform vec3 aura_col;
	varying vec3 v_local_pos;
	void vertex() { v_local_pos = VERTEX; }
	void fragment() {
		float polar = smoothstep(0.85, 0.97, abs(normalize(v_local_pos).y));
		if (polar <= 0.01) { discard; }
		ALBEDO = aura_col; ALPHA = polar * 0.22;
	}"""
	var a_inst = MeshInstance3D.new(); a_inst.mesh = a_mesh; a_inst.material_override = ShaderMaterial.new(); a_inst.material_override.shader = a_shader
	a_inst.material_override.set_shader_parameter("aura_col", base_color.lightened(0.25))
	a_inst.visibility_range_end = PROXIMITY_CUTOFF; add_child(a_inst)

func _spawn_hero_landmarks(rng: RandomNumberGenerator) -> void:
	# 4-6 colossal navigation anchors per planet.
	var num = rng.randi_range(4, 6)
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

		# Three landmark archetypes: tapered spire, stone arch, and a
		# Hallelujah-Mountain style floating island with stalactite tip.
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
# FLOATING ISLAND — Hallelujah-Mountain style: dome-topped grass plateau atop
# a tapered rocky stalactite that hangs deep below.  Multi-ring revolution
# geometry with per-vertex jitter + a slight off-axis tilt so the silhouette
# reads as a real 3D landmass from every viewing angle (orbit included),
# not a flat disc.
# ---------------------------------------------------------------------------
func _build_floating_island(base: Vector3, basis: Basis, rng: RandomNumberGenerator, col: Color, accent: Color) -> void:
	var r: float = rng.randf_range(220.0, 380.0)
	var float_alt: float = rng.randf_range(1200.0, 2400.0)  # well above clouds @ 35 km? no — clouds at planet_radius+35 km, we're metres above terrain. Comfortably below cloud sphere.
	var sides: int = 12

	# Random off-axis tilt (±15°) so the top isn't always perfectly aligned
	# with the surface normal — eliminates the "flat octagon from above" look.
	var tilt_axis_angle := rng.randf() * TAU
	var horizontal_axis: Vector3 = (basis.x * cos(tilt_axis_angle) + basis.z * sin(tilt_axis_angle)).normalized()
	var tilt_amount: float = rng.randf_range(-0.26, 0.26)  # ±15°
	var tb: Basis = basis.rotated(horizontal_axis, tilt_amount)

	var centre: Vector3 = base + basis * Vector3(0, float_alt, 0)

	# Latitude rings: y / radius / colour.  Each ring is built per-side with
	# small radius/y jitter for organic irregularity.  Top apex is a slight
	# bump above the plateau; bottom apex is a deep stalactite point.
	var rock_dark: Color = col.darkened(0.25)
	var rock_deep: Color = col.darkened(0.45)
	var rings: Array = [
		# y_factor (× r), radius_factor (× r), colour
		[ 0.18, 0.00, accent],                          # top apex (dome bump)
		[ 0.14, 0.45, accent],                          # plateau ring
		[ 0.04, 0.85, accent.lerp(col, 0.55)],          # transition (grass → rock)
		[-0.12, 1.00, col],                             # widest middle (rock)
		[-0.45, 0.65, col],                             # tapering rock
		[-0.85, 0.30, rock_dark],                       # narrow rock
		[-1.30, 0.00, rock_deep],                       # bottom apex (deep stalactite)
	]

	# Build vertex grid: rings × sides.  Per-vertex jitter for organic look.
	var verts := []
	verts.resize(rings.size())
	for ring_i in range(rings.size()):
		var ring_y: float = rings[ring_i][0] * r
		var ring_r: float = rings[ring_i][1] * r
		var per_side := PackedVector3Array()
		for s in range(sides):
			var ang := float(s) / float(sides) * TAU
			# Jitter — radius ±10%, y ±3% — only on intermediate rings (not apex).
			var rj: float = 1.0
			var yj: float = 0.0
			if ring_r > 0.001:
				rj = 1.0 + sin(ang * 2.7 + float(ring_i) * 1.3) * 0.10 \
						+ rng.randf_range(-0.05, 0.05)
				yj = sin(ang * 3.1 + float(ring_i) * 0.7) * 0.03 * r
			var lp := Vector3(cos(ang) * ring_r * rj, ring_y + yj, sin(ang) * ring_r * rj)
			per_side.append(centre + tb * lp)
		verts[ring_i] = per_side

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Top apex fan: triangle from apex0 (which is at radius=0 so single point)
	# down to the ring below.
	var top_apex: Vector3 = (verts[0] as PackedVector3Array)[0]  # all sides collapse to the same point at r=0
	var ring_1 := verts[1] as PackedVector3Array
	for s in range(sides):
		var ns := (s + 1) % sides
		_add_tri_flat(st, top_apex, ring_1[s], ring_1[ns], rings[1][2])

	# Quad strips between consecutive non-apex rings.  Colour blends across
	# the seam so the grass→rock transition feels continuous.
	for ring_i in range(1, rings.size() - 2):
		var rl := verts[ring_i] as PackedVector3Array
		var rh := verts[ring_i + 1] as PackedVector3Array
		var c_top: Color = rings[ring_i][2]
		var c_bot: Color = rings[ring_i + 1][2]
		var c_mid: Color = c_top.lerp(c_bot, 0.5)
		for s in range(sides):
			var ns := (s + 1) % sides
			_add_tri_flat(st, rl[s], rh[s], rl[ns], c_mid)
			_add_tri_flat(st, rl[ns], rh[s], rh[ns], c_mid)

	# Bottom apex fan from last non-apex ring down to the stalactite tip.
	var last_ring_i := rings.size() - 2  # second-to-last (just above the apex)
	var last_ring := verts[last_ring_i] as PackedVector3Array
	var bot_apex: Vector3 = (verts[rings.size() - 1] as PackedVector3Array)[0]
	for s in range(sides):
		var ns := (s + 1) % sides
		_add_tri_flat(st, last_ring[ns], last_ring[s], bot_apex, rings[rings.size() - 1][2])

	st.generate_normals(false)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _landmark_material(col)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# AABB sized to encompass tilted island + deep stalactite; ~2× radius
	# horizontally, full vertical span from top bump to deep apex.
	var ext: float = r * 1.4
	mi.custom_aabb = AABB(Vector3(-ext, -r * 1.5, -ext), Vector3(ext * 2.0, r * 2.0, ext * 2.0))
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
	# Pass planet_radius so the marker can position its cylinder above the
	# surface (preventing the hex-prism cylinder from poking through water/
	# lava at the surface intersection).
	marker.call_deferred("setup", display_name, "planet", height, col, planet_radius)
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
	# Reference: ship position/forward (not camera) so SpringArm jitter and
	# rapid camera swings don't flip planet faces in/out of view.
	var should_hibernate = false
	var safety_dist = planet_radius * 12.0 # ACE: Drastically increased to prevent 'White Sphere' syndrome
	if dist_to_player > safety_dist:
		var to_planet = (global_position - player.global_position).normalized()
		var ship_fwd = -player.global_transform.basis.z
		var dot = ship_fwd.dot(to_planet)

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
	MAX_FINALIZE_PER_FRAME = 1 if (OS.get_name() == "iOS" or OS.get_name() == "Android") else 8
	for i in range(min(finalize_queue.size(), MAX_FINALIZE_PER_FRAME)):
		var chunk = finalize_queue.pop_front()
		if is_instance_valid(chunk):
			chunk._finalize_generation_on_main()
			
	# ACE PROP THROTTLE: Spread node instantiation across multiple frames
	# Tightened for M1 — 2 tasks per frame to ensure buttery flight.
	var prop_batch = 1 if mobile_perf else 2
	for i in range(min(prop_spawn_queue.size(), prop_batch)):
		var task = prop_spawn_queue.pop_front()
		var node = task[0]
		var method = task[1]
		var data = task[2]
		if is_instance_valid(node) and node.has_method(method):
			node.call(method, data)

	# ACE REAPER: Asynchronous destruction of nodes
	var death_budget = 2 if mobile_perf else 6 
	for i in range(min(death_row.size(), death_budget)):
		var d = death_row.pop_back()
		if is_instance_valid(d): d.queue_free() # ACE: Always queue_free() for main-thread safety
	
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
		collision_queue.append(chunk) # ACE: Ensure collision is baked after mesh is ready

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
	
	# STRICT SYNC with PlanetChunk's continent mask (noise.frequency = 0.01,
	# so multipliers ~200-1100 produce continent-scale variation across faces).
	var c_n: float = noise.get_noise_3dv(sn * 220.0)
	c_n += noise.get_noise_3dv(sn * 520.0) * 0.55
	c_n += noise.get_noise_3dv(sn * 1100.0) * 0.25
	var cont_mask: float = smoothstep(-0.18, 0.18, c_n + 0.05)
	var S_LVL: float = sea_level
	var abyss_depth: float = S_LVL - 400.0
	
	var elev = lerp(abyss_depth, local_geo + (S_LVL + 50.0), cont_mask)
	return elev

func _ensure_impostor_active(active: bool) -> void:
	# DEBUG: impostor permanently hidden — testing whether the visible repeating
	# circle/diamond pattern across planet surfaces is the impostor's noise()
	# level-set rendering (which uses unit-direction-space frequencies and
	# would produce distinct cell patterns regardless of planet size). The
	# impostor is normally only meant to render at very far distances, but
	# at small planet radii the QuadTree may rarely subdivide chunks and the
	# impostor could be the dominant visible layer. Restore by removing the
	# `active = false` line below once confirmed.
	active = false
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
		# (Per-prop spawn hysteresis is handled in PlanetChunk.gd; the QuadTree
		# itself stays on the original threshold since subdividing has paired
		# split/merge handshakes that already prevent visible gaps when timing
		# is correct — adding chunk-level hysteresis introduced rectangular
		# holes at LOD transitions and is not needed for prop stability.)
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
			# Halved from 12/18/24. ~55% fewer verts per chunk; collision
			# baking shrinks the same fraction so the queue drains faster.
			if scale > 0.05:   chunk.resolution = 8
			elif scale > 0.01: chunk.resolution = 12
			else:              chunk.resolution = 16
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

func _init_shared_materials() -> void:
	land_material = ShaderMaterial.new()
	land_material.shader = load("res://src/world/triplanar_local.gdshader")
	land_material.set_shader_parameter("planet_radius", planet_radius)
	land_material.set_shader_parameter("texture_scale", 1.0)
	# Wire the procedurally-rolled palette into the biome-aware land shader so
	# every chunk renders with the planet's actual archetype colour.
	land_material.set_shader_parameter("sea_level", sea_level)
	land_material.set_shader_parameter("col_beach",  pal_beach_col)
	land_material.set_shader_parameter("col_grass",  pal_grass_col)
	land_material.set_shader_parameter("col_forest", pal_grass_secondary)
	land_material.set_shader_parameter("col_rock",   pal_mount_col)
	# Tint snow slightly toward the rock colour so ice caps don't bleach pure
	# white (and so they read distinctly between archetypes).
	land_material.set_shader_parameter("col_snow",
		Color(0.92, 0.94, 0.98).lerp(pal_mount_col, 0.15))
	
	water_material = ShaderMaterial.new()
	var w_shader = load("res://src/world/water.gdshader")
	if w_shader:
		water_material.shader = w_shader
		water_material.set_shader_parameter("radius", planet_radius)
		# Mobile: skip the high-frequency detail FBM in waves and the
		# shimmer FBM (single value_noise instead). ~6 hash() ops saved
		# per ocean fragment.
		water_material.set_shader_parameter("mobile_simple", mobile_perf)
	
	# FOLIAGE MATERIALS
	foliage_material = ShaderMaterial.new()
	foliage_material.shader = load("res://src/shaders/foliage_toon.gdshader")
	foliage_material.set_shader_parameter("shadow_strength", 0.6)
	foliage_material.set_shader_parameter("wind_speed", 0.7)
	foliage_material.set_shader_parameter("wind_strength", 0.4)
	foliage_material.set_shader_parameter("leaf_texture", load("res://assets/textures/tree_leaves_texture.png"))
	foliage_material.set_shader_parameter("normal_map", load("res://assets/textures/tree_leaves_texture_normal.png"))
	foliage_material.set_shader_parameter("biolum_intensity", 1.0 if has_bioluminescence else 0.0)
	# Mobile cheap path: simpler light(), shorter dither fade range.
	foliage_material.set_shader_parameter("mobile_simple", mobile_perf)
	
	trunk_material = ShaderMaterial.new()
	trunk_material.shader = load("res://src/shaders/trunk_toon.gdshader")
	trunk_material.set_shader_parameter("albedo", Color(0.35, 0.25, 0.15))
	trunk_material.set_shader_parameter("bark_texture", load("res://assets/textures/tree_trunk_texture.png"))
	trunk_material.set_shader_parameter("normal_map", load("res://assets/textures/tree_trunk_texture_normal.png"))
	
	rock_material = ShaderMaterial.new()
	rock_material.shader = load("res://src/shaders/hatch_toon.gdshader")
	rock_material.set_shader_parameter("shadow_strength", 0.9)
	rock_material.set_shader_parameter("biolum_intensity", 1.0 if has_bioluminescence else 0.0)
	
	grass_material = ShaderMaterial.new()
	grass_material.shader = PlanetChunkScript._get_grass_shader()

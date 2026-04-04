@tool
extends MeshInstance3D

# PlanetChunk.gd (Smooth Coastline Edition)
# Managed by THE PROCEDURALIST.

var noise: FastNoiseLite
var radius: float = 300000.0 
var terrain_strength: float = 6000.0 
var resolution: int = 48 
var face_normal: Vector3 
var x_axis: Vector3 
var y_axis: Vector3 
var offset: Vector2 = Vector2.ZERO
var scale_factor: float = 1.0
var planet_seed: int = 0  # Unique per celestial body, passed from PlanetGen
var scatter_grass: bool = false  # Only true when player is on foot

# DYNAMIC PROCEDURAL PLANET PALETTE
var pal_forest_h: float = 0.3
var pal_forest_col: Color = Color("#33AA33")
var pal_grass_col: Color = Color("#44BB44")
var pal_beach_col: Color = Color("#C2B280")
var pal_mount_col: Color = Color("#888888")
var pal_water_base: Color = Color(0.0, 0.35, 0.95)
var pal_water_light: Color = Color(0.0, 0.65, 1.0)
var pal_water_shore: Color = Color(0.3, 0.85, 1.0)
var SEA_LEVEL = -400.0

func start_generation() -> void:
	_generate_planetary_palette()
	_calculate_multi_surface_mesh()
	# Flora scatter is queued in PlanetGen._process() after this frame completes.

func _generate_planetary_palette() -> void:
	# XOR the planet_seed with radius and terrain_strength using a Knuth multiplicative hash.
	# This guarantees that even two planets with equal radii but different seeds
	# produce completely different palettes with strong bit distribution!
	var rng = RandomNumberGenerator.new()
	rng.seed = (int(radius) ^ int(terrain_strength * 100.0) ^ (planet_seed * 2654435761)) & 0x7FFFFFFF 
	
	# Flora (Trees): Pick a vivid, saturated primary hue for the canopy
	pal_forest_h = rng.randf()
	pal_forest_col = Color.from_hsv(pal_forest_h, rng.randf_range(0.65, 0.95), rng.randf_range(0.55, 0.85))
	
	# Grass is the COMPLEMENTARY color — directly opposite on the color wheel (+0.5 hue).
	# A small ±0.15 drift makes it feel organic rather than mechanically exact, but it
	# always stays in the 120°-240° arc away from the tree hue for strong contrast.
	var grass_hue_offset = 0.5 + rng.randf_range(-0.15, 0.15)
	var grass_hue = fposmod(pal_forest_h + grass_hue_offset, 1.0)
	# High value (brightness) so the ground reads clearly against tree shadows
	pal_grass_col = Color.from_hsv(grass_hue, rng.randf_range(0.55, 0.85), rng.randf_range(0.65, 0.90))
	
	# Beaches are mathematically complimentary or analogous 
	var beach_hue = fposmod(pal_forest_h + 0.1, 1.0) if rng.randf() > 0.5 else fposmod(pal_forest_h - 0.1, 1.0)
	pal_beach_col = Color.from_hsv(beach_hue, rng.randf_range(0.3, 0.6), rng.randf_range(0.8, 0.95))
	
	# Mountains are Earthy: Grey, Brown, Red, or Orange (Hue 0.0 to 0.15)
	var mount_hue = rng.randf_range(0.0, 0.15)
	pal_mount_col = Color.from_hsv(mount_hue, rng.randf_range(0.1, 0.6), rng.randf_range(0.3, 0.65))
	
	# Oceans are Aquatic: Blue or Green (Hue 0.35 to 0.65)
	var water_hue = rng.randf_range(0.35, 0.65)
	pal_water_base = Color.from_hsv(water_hue, 0.95, 0.35)
	pal_water_light = Color.from_hsv(water_hue, 0.85, 0.65)
	pal_water_shore = Color.from_hsv(water_hue, 0.70, 0.95)

func _v3s(c: Color) -> String:
	return "vec3(%.3f, %.3f, %.3f)" % [c.r, c.g, c.b]

func _get_sn(x: int, y: int) -> Vector3:
	var per: Vector2 = Vector2(x, y) / float(resolution); var lu: Vector2 = (per - Vector2(0.5, 0.5)) * 2.0 * scale_factor
	var cp: Vector3 = face_normal + (offset.x + lu.x) * x_axis + (offset.y + lu.y) * y_axis
	return cp.normalized()

func get_terrain_elevation(sn: Vector3) -> float:
	var r_mask: float = noise.get_noise_3dv(sn * 600.0); var t_n: float = noise.get_noise_3dv(sn * 150.0)
	var t_boost: float = pow(abs(t_n - 0.3) * 1.5, 4.0) * 8.0 if t_n > 0.3 else 0.0
	var h_n: float = noise.get_noise_3dv(sn * 1800.0) * clamp(r_mask + 0.5, 0.2, 1.0)
	var ridge_n: float = pow(1.0 - abs(noise.get_noise_3dv(sn * 3600.0)), 4.0)
	var ridges: float = ridge_n * clamp(r_mask * 2.0, 0.0, 1.0) * (1.0 + t_boost)
	var v_n: float = noise.get_noise_3dv(sn * 3600.0); var valley: float = 0.0
	if v_n < -0.1: valley = pow(abs(v_n + 0.1) * 1.5, 2.5) * -1.2 * (1.0 if r_mask > 0.0 else 2.5)
	return (h_n + (ridges * 1.5) + valley) * terrain_strength

func get_water_point(sn: Vector3) -> Vector3:
	# GPU Shader will handle dynamic wave displacement seamlessly
	return sn * (radius + SEA_LEVEL)

func _calculate_multi_surface_mesh() -> void:
	var st_land: SurfaceTool = SurfaceTool.new(); st_land.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_water: SurfaceTool = SurfaceTool.new(); st_water.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_water = false
	
	for y in range(resolution):
		for x in range(resolution):
			var sn1 = _get_sn(x, y); var sn2 = _get_sn(x + 1, y)
			var sn3 = _get_sn(x, y + 1); var sn4 = _get_sn(x + 1, y + 1)
			
			var h1 = get_terrain_elevation(sn1); var h2 = get_terrain_elevation(sn2)
			var h3 = get_terrain_elevation(sn3); var h4 = get_terrain_elevation(sn4)
			
			# Floor constraint to save deep-water polygon stretch
			var floor_depth = SEA_LEVEL - 50.0
			var p1 = sn1 * (radius + max(h1, floor_depth)); var p2 = sn2 * (radius + max(h2, floor_depth))
			var p3 = sn3 * (radius + max(h3, floor_depth)); var p4 = sn4 * (radius + max(h4, floor_depth))
			
			_add_faceted_tri(st_land, p1, p3, p2, h1, h3, h2)
			_add_faceted_tri(st_land, p3, p4, p2, h3, h4, h2)
			
			# Sub-Surface Water Mesh: Render if ANY point is near or below sea level
			if min(min(h1, h2), min(h3, h4)) <= SEA_LEVEL + 30.0:
				has_water = true
				var w1 = get_water_point(sn1); var w2 = get_water_point(sn2)
				var w3 = get_water_point(sn3); var w4 = get_water_point(sn4)
				
				# SHORE PROXIMITY BAKING: 1.0 = Touching Land, 0.0 = 150m Deep
				var sp1 = 1.0 - clamp((SEA_LEVEL - h1) / 150.0, 0.0, 1.0)
				var sp2 = 1.0 - clamp((SEA_LEVEL - h2) / 150.0, 0.0, 1.0)
				var sp3 = 1.0 - clamp((SEA_LEVEL - h3) / 150.0, 0.0, 1.0)
				var sp4 = 1.0 - clamp((SEA_LEVEL - h4) / 150.0, 0.0, 1.0)
				
				st_water.set_color(Color(sp1, 0, 0, 1)); st_water.add_vertex(w1)
				st_water.set_color(Color(sp3, 0, 0, 1)); st_water.add_vertex(w3)
				st_water.set_color(Color(sp2, 0, 0, 1)); st_water.add_vertex(w2)
				
				st_water.set_color(Color(sp3, 0, 0, 1)); st_water.add_vertex(w3)
				st_water.set_color(Color(sp4, 0, 0, 1)); st_water.add_vertex(w4)
				st_water.set_color(Color(sp2, 0, 0, 1)); st_water.add_vertex(w2)
			
	st_land.generate_normals(false)
	var final_mesh: ArrayMesh = st_land.commit()
	
	if has_water:
		st_water.generate_normals(false)
		final_mesh = st_water.commit(final_mesh) 
		
	_finalize_dual_materials(final_mesh, has_water)
	_scatter_deterministic_stellar_layers()

func _add_faceted_tri(st: SurfaceTool, v1: Vector3, v2: Vector3, v3: Vector3, h1: float, h2: float, h3: float) -> void:
	st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v3)

func _finalize_dual_materials(a_mesh: ArrayMesh, has_water: bool) -> void:
	self.mesh = a_mesh
	var shader_land = Shader.new()
	shader_land.code = """shader_type spatial;
render_mode diffuse_toon, specular_toon;
varying float v_height;
varying vec3 v_world_pos;
void vertex() {
	v_height = length(VERTEX) - (%f);
	v_world_pos = VERTEX;
}
void fragment() {
	// HIGH-SATURATION PROCEDURAL COLORS
	vec3 col_beach = %s; 
	vec3 col_forest = %s; 
	vec3 col_rock = %s; 
	vec3 col_snow = vec3(1.0, 1.0, 1.0);
	// FRACTAL BIOME DISPLACEMENT (Breaks up straight altitude lines)
	float b_warp = sin(v_world_pos.x * 0.0015) * 300.0 
				 + cos(v_world_pos.z * 0.002) * 200.0 
				 + sin((v_world_pos.x + v_world_pos.y) * 0.004) * 150.0;
	float b_h = v_height + b_warp;
	
	vec3 albedo = col_beach;
	if (b_h > 3500.0) { albedo = col_snow; }
	else if (b_h > 1500.0) { albedo = col_rock; }
	else if (v_height > -200.0) { albedo = col_forest; }
	
	// DYNAMIC SHORELINE FOAM (Crashing waves stroke)
	float wave_time = TIME * 2.2;
	float w1 = sin(v_world_pos.x * 0.01 + wave_time) * 1.8;
	float w2 = cos(v_world_pos.y * 0.008 - wave_time * 0.8) * 1.5;
	float w3 = sin(v_world_pos.z * 0.012 + wave_time * 1.1) * 1.6;
	float r1 = sin((v_world_pos.x - v_world_pos.z) * 0.04 + wave_time * 3.0) * 0.5;
	float water_h = (%f) + (w1 + w2 + w3 + r1);
	
	// Draw a solid white stroke hugging the dynamic wave intersection
	if (v_height > water_h - 1.0 && v_height < water_h + 3.0) {
		albedo = vec3(1.0, 1.0, 1.0);
	}
	
	ALBEDO = albedo;
	METALLIC = 0.0;
	ROUGHNESS = 0.95;
}""" % [radius, _v3s(pal_beach_col), _v3s(pal_grass_col), _v3s(pal_mount_col), SEA_LEVEL]
	var m_land = ShaderMaterial.new()
	m_land.shader = shader_land
	self.set_surface_override_material(0, m_land)
	
	if has_water:
		var shader = Shader.new()
		shader.code = """shader_type spatial;
render_mode diffuse_toon, specular_toon;
varying vec3 v_world_pos;
varying float v_shore;

void vertex() {
	v_shore = COLOR.r; // Receive pre-baked shore depth gradient
	
	float wave_time = TIME * 2.2;
	float w1 = sin(VERTEX.x * 0.01 + wave_time) * 1.8;
	float w2 = cos(VERTEX.y * 0.008 - wave_time * 0.8) * 1.5;
	float w3 = sin(VERTEX.z * 0.012 + wave_time * 1.1) * 1.6;
	float r1 = sin((VERTEX.x - VERTEX.z) * 0.04 + wave_time * 3.0) * 0.5;
	vec3 sphere_normal = normalize(VERTEX);
	VERTEX += sphere_normal * (w1 + w2 + w3 + r1);
	v_world_pos = VERTEX;
}

vec3 random3(vec3 p) {
    return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)),
                          dot(p, vec3(269.5, 183.3, 246.1)),
                          dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
}

float voronoi3D(vec3 x, float time) {
    vec3 n = floor(x);
    vec3 f = fract(x);
    float F1 = 8.0;
    float F2 = 8.0;

    for (int k = -1; k <= 1; k++) {
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                vec3 g = vec3(float(i), float(j), float(k));
                vec3 o = random3(n + g);
                o = 0.5 + 0.5 * sin(time + 6.2831 * o);
                vec3 r = g + o - f;
                float d = dot(r, r);
                
                if (d < F1) {
                    F2 = F1;
                    F1 = d;
                } else if (d < F2) {
                    F2 = d;
                }
            }
        }
    }
    return sqrt(F2) - sqrt(F1); // F2-F1 creates perfectly thin boundary webs
}

void fragment() {
	// PROCEDURALLY MATERIAlIZED OCEAN HUES
	vec3 base_blue = %s;  
	vec3 light_blue = %s; 
	vec3 shore_blue = %s; 
	vec3 foam_color = vec3(1.0, 1.0, 1.0);
	
	// SINE WARP: Pushes the coordinates around, physically curving the straight Voronoi boundaries!
	vec3 warp = vec3(sin(v_world_pos.z * 0.005 + TIME*0.2), sin(v_world_pos.x * 0.005 + TIME*0.2), sin(v_world_pos.y * 0.005 + TIME*0.2)) * 150.0;
	
	// v is exactly the distance to the boundary edge
	float v = voronoi3D((v_world_pos + warp) * 0.0008, TIME * 0.2);
	
	vec3 final_color = base_blue;
	
	// Small v means we are right on the warped boundary line (Thin Foam!)
	if (v < 0.04) {
		final_color = foam_color;
	} else if (v < 0.15) {
		final_color = light_blue; 
	}
	
	// RIPPLE ALTITUDE FADE: Fade out the busy ocean Voronoi at long distances
	float dist_to_cam = length(VERTEX); // Distance to camera in view space
	float altitude_fade = smoothstep(25000.0, 6000.0, dist_to_cam); // Fades in between 25km and 6km
	
	// COASTLINE BUFFER: Fade out the busy ocean Voronoi as it approaches the tropical shores!
	// v_shore is 1.0 precisely at the land clip, and 0.0 in deep water.
	float shore_fade = 1.0 - smoothstep(0.02, 0.15, v_shore);
	
	// Multiply fades (ripples require both low altitude AND deep water to exist)
	float total_ripple_alpha = altitude_fade * shore_fade;
	
	// Revert to solid pristine blue where faded out
	final_color = mix(base_blue, final_color, total_ripple_alpha);
	
	// WIND WAKER CONCENTRIC SHORE RINGS
	// (Processed AFTER the distance fade so shorelines are always visible from space!)
	// If we are near the land (v_shore approaches 1.0)
	if (v_shore > 0.0) {
		// 1. Tropical gradient: Ocean turns bright vivid cyan near the beaches!
		final_color = mix(final_color, shore_blue, v_shore * 0.8);
		
		// 2. Wobble the numerical distance to shore organically using our Voronoi warp
		float warped_shore = v_shore + (warp.x * 0.0005) + (warp.z * 0.0005);
		
		// 3. HARMONIC SWELL: Breaks the "conveyor belt loop" by creating incoming sets of waves
		// A slower swell moves towards the shore, breaking up laterally across the coast
		float lateral_breakup = sin(v_world_pos.x * 0.008 + TIME * 0.4) * sin(v_world_pos.z * 0.008) * 0.5 + 0.5;
		float swell = sin(warped_shore * 6.0 - TIME * 1.2 + lateral_breakup * 2.0) * 0.5 + 0.6; // Ranges 0.1 to 1.1
		
		// 4. Multiply the fast foam contours against the slow swell! 
		// The foam perfectly materializes, rides the swell, and dissolves away organically!
		float rings = sin(warped_shore * 32.0 - TIME * 3.2) * swell;
		
		// 5. Threshold the sine wave to draw crisp white lines! 
		if (rings > 0.85 && warped_shore > 0.02 && warped_shore < 0.95) {
			final_color = foam_color;
		}
	}
	ALBEDO = final_color;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
}""" % [_v3s(pal_water_base), _v3s(pal_water_light), _v3s(pal_water_shore)]
		var m_water = ShaderMaterial.new()
		m_water.shader = shader
		self.set_surface_override_material(1, m_water)
		
	# PERFORMANCE HARDEN: Only create collisions and shadow maps for nearby terrain chunks
	if scale_factor < 0.04:
		create_trimesh_collision()
		self.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		self.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _scatter_deterministic_stellar_layers() -> void:
	# Tightened early bail: skip chunks beyond ~8km (was 0.02, now 0.015)
	if scale_factor > 0.015: return 
	
	# RADIUS-AWARE DENSITY: Scale cell spacing inversely with planet size.
	# A small moon (r=450k) needs sparser forests than a large titan (r=1.1M).
	# Normalize against a reference radius of 1,000,000 units.
	var radius_ratio: float = clamp(radius / 1000000.0, 0.3, 1.5)
	
	var t_pts: Array[Transform3D] = []; var r_pts: Array[Transform3D] = []
	var g_pts: Array[Transform3D] = []
	
	# TREES & ROCKS — Spaced by radius_ratio so smaller planets are less dense
	if scale_factor <= 0.005:
		# Larger base cell = fewer objects per chunk. Scaled so small planets are sparse.
		var t_cell: float = 0.00025 / radius_ratio  # ~75m on titan, ~200m on small moon
		var ts_x = int(floor((offset.x - scale_factor) / t_cell)); var te_x = int(ceil((offset.x + scale_factor) / t_cell))
		var ts_y = int(floor((offset.y - scale_factor) / t_cell)); var te_y = int(ceil((offset.y + scale_factor) / t_cell))
		
		# CPU HARDEN: Hard cap at 80x80 iterations (was 100)
		if (te_x - ts_x) <= 80:
			for y_idx in range(ts_y, te_y):
				for x_idx in range(ts_x, te_x):
					var hash_val = hash(Vector3(float(x_idx), float(y_idx), face_normal.z * 1337.0))
					var t_val = hash_val % 1000
					
					if t_val < 800:
						var lu_x = (float(x_idx) + 0.5) * t_cell
						var lu_y = (float(y_idx) + 0.5) * t_cell
						var cp = (face_normal + lu_x * x_axis + lu_y * y_axis).normalized()
						var m_d = noise.get_noise_3dv(cp * 1500.0) 
						var is_forest = (m_d > 0.05)
						
						# Tree density: reduced from 65% -> 20% for open, breathable forests.
						# Rock density: reduced from 1.2% -> 0.4% for rare landmark boulders.
						var tree_threshold = int(200 * radius_ratio)  # 20% on titan, ~6% on small moon
						var rock_threshold = int(4 * radius_ratio)    # 0.4% on titan, ~0.12% on small moon
						
						if (is_forest and t_val < tree_threshold) or (not is_forest and t_val < rock_threshold):
							var h = get_terrain_elevation(cp)
							if h > -380.0:
								var pos = cp * (radius + max(h, SEA_LEVEL - 50.0))
								
								# B_WARP: Sync with GPU shader biome displacement!
								var b_warp = sin(pos.x * 0.0015) * 300.0 + cos(pos.z * 0.002) * 200.0 + sin((pos.x + pos.y) * 0.004) * 150.0
								var h_bio = h + b_warp
								
								if is_forest:
									if h > -150.0 and h_bio < 1450.0:
										var dr = noise.get_noise_3dv(cp * 36000.0)
										t_pts.append(_get_object_xform(pos, cp, dr, 13.0))
								else:
									if h_bio <= 1500.0 and t_val < rock_threshold:
										var dr = noise.get_noise_3dv(cp * 45000.0)
										r_pts.append(_get_rock_xform(pos, cp, dr, 18.0))
								
	# GRASS — Dense flowing fields, only spawned when player is on foot.
	# During ship flight, this block is entirely skipped — zero MMI instances created,
	# zero vertex buffers allocated, zero GPU draw calls for grass.
	if scatter_grass and scale_factor <= 0.0005:
		# Half the cell vs previous = 4x more grid points in 2D = ~300% more grass
		var g_cell: float = 0.000006 / radius_ratio  # ~1.8m on titan-scale
		var gs_x = int(floor((offset.x - scale_factor) / g_cell)); var ge_x = int(ceil((offset.x + scale_factor) / g_cell))
		var gs_y = int(floor((offset.y - scale_factor) / g_cell)); var ge_y = int(ceil((offset.y + scale_factor) / g_cell))
		
		# CPU HARDEN: Wider cap to handle the denser grid without freezing
		if (ge_x - gs_x) <= 300:
			for y_idx in range(gs_y, ge_y):
				for x_idx in range(gs_x, ge_x):
					var h_v = hash(Vector3(float(x_idx), float(y_idx), face_normal.y * 313.0))
					if h_v % 100 < 90: # 90% coverage — dense, flowing sea of grass
						# SUB-CELL JITTER: derive two independent offsets to shatter the grid pattern!
						# Each blade scatters within ±45% of its cell, making placement look natural.
						var jit_x = (float(hash(Vector2i(x_idx * 7, y_idx * 3))) / 4294967295.0 - 0.5) * 0.9
						var jit_y = (float(hash(Vector2i(y_idx * 11, x_idx * 5))) / 4294967295.0 - 0.5) * 0.9
						var lu_x = (float(x_idx) + 0.5 + jit_x) * g_cell
						var lu_y = (float(y_idx) + 0.5 + jit_y) * g_cell
						var cp = (face_normal + lu_x * x_axis + lu_y * y_axis).normalized()
						
						var m_d = noise.get_noise_3dv(cp * 1500.0)
						if m_d > 0.0: # Keep grass locked to forest biomes
							var h = get_terrain_elevation(cp)
							var pos = cp * (radius + max(h, SEA_LEVEL - 50.0))
							
							# B_WARP: Sync with GPU shader biome displacement!
							var b_warp = sin(pos.x * 0.0015) * 300.0 + cos(pos.z * 0.002) * 200.0 + sin((pos.x + pos.y) * 0.004) * 150.0
							var h_bio = h + b_warp
							
							if h > -150.0 and h_bio < 1300.0:
								var rand_f = fmod(float(h_v), 10.0) / 10.0
								g_pts.append(_get_grass_xform(pos, cp, rand_f))
								
	if not t_pts.is_empty(): _spawn_tree_lods(t_pts)
	if not r_pts.is_empty(): _spawn_rock(r_pts)
	if not g_pts.is_empty(): _spawn_grass(g_pts)

func _get_object_xform(pos: Vector3, up: Vector3, noise_val: float, b_scale: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	var xf = Transform3D(t_bas, pos); var sv = 1.0 + (abs(noise_val) * 7.0)
	return xf.scaled_local(Vector3(b_scale, b_scale * sv, b_scale))

func _spawn_rock(points: Array[Transform3D]) -> void:
	var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new(); var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = _build_titan_faceted_rock_mesh(); mm.instance_count = points.size()
	for i in range(points.size()): mm.set_instance_transform(i, points[i])
	mmi.multimesh = mm; var mat = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true; mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL;
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED;
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON; mat.specular_mode = BaseMaterial3D.SPECULAR_TOON; mat.roughness = 1.0
	mat.albedo_color = pal_mount_col # Dye the grey vertex ambient-occlusion mathematically into the planetary tone!
	mat.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_DITHER
	mat.distance_fade_min_distance = 60000.0; mat.distance_fade_max_distance = 25000.0
	mmi.material_override = mat; mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if scale_factor < 0.05 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

func _spawn_tree_lods(points: Array[Transform3D]) -> void:
	var mat = StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true; mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL;
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED;
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON; mat.specular_mode = BaseMaterial3D.SPECULAR_TOON; mat.roughness = 1.0
	
	var mm_l = MultiMesh.new(); mm_l.transform_format = MultiMesh.TRANSFORM_3D; mm_l.use_colors = true; mm_l.mesh = _build_low_tree(); mm_l.instance_count = points.size()
	var mm_m = MultiMesh.new(); mm_m.transform_format = MultiMesh.TRANSFORM_3D; mm_m.use_colors = true; mm_m.mesh = _build_med_tree(); mm_m.instance_count = points.size()
	var mm_h = MultiMesh.new(); mm_h.transform_format = MultiMesh.TRANSFORM_3D; mm_h.use_colors = true; mm_h.mesh = _build_high_tree(); mm_h.instance_count = points.size()
	
	# PROCEDURALLY SCATTERED DYNAMIC FOREST CANOPIES
	for i in range(points.size()): 
		var pos = points[i].origin
		var rand_f = fposmod(pos.x * 0.015 + pos.z * 0.023, 1.0)
		
		# Generate a mathematically analogous canopy clustering around the planet's primary Flora Hue!
		var t_hue = fposmod(pal_forest_h + (rand_f * 0.2 - 0.1), 1.0)
		var t_col = Color.from_hsv(t_hue, 0.85, 0.8)
		
		var d = fposmod(pos.x * pos.z * 0.001, 0.15) # Organic darkening variance
		t_col = t_col.darkened(d)

		mm_l.set_instance_transform(i, points[i]); mm_l.set_instance_color(i, t_col)
		mm_m.set_instance_transform(i, points[i]); mm_m.set_instance_color(i, t_col)
		mm_h.set_instance_transform(i, points[i]); mm_h.set_instance_color(i, t_col)

	var m_l = MultiMeshInstance3D.new(); m_l.multimesh = mm_l; m_l.material_override = mat; m_l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m_l.visibility_range_begin = 12000.0; m_l.visibility_range_begin_margin = 1000.0
	m_l.visibility_range_end = 60000.0; m_l.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF; add_child(m_l)
	
	var m_m = MultiMeshInstance3D.new(); m_m.multimesh = mm_m; m_m.material_override = mat; m_m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if scale_factor < 0.05 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m_m.visibility_range_begin = 3500.0; m_m.visibility_range_begin_margin = 500.0
	m_m.visibility_range_end = 12000.0; m_m.visibility_range_end_margin = 1000.0; m_m.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF; add_child(m_m)
	
	var m_h = MultiMeshInstance3D.new(); m_h.multimesh = mm_h; m_h.material_override = mat; m_h.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if scale_factor < 0.05 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	m_h.visibility_range_end = 3500.0; m_h.visibility_range_end_margin = 500.0; m_h.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF; add_child(m_h)

func _spawn_grass(points: Array[Transform3D]) -> void:
	var mm = MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _build_grass_mesh(); mm.instance_count = points.size()
	for i in range(points.size()): mm.set_instance_transform(i, points[i])
	
	var shader = Shader.new()
	shader.code = """shader_type spatial;
render_mode diffuse_toon, specular_toon, cull_disabled;

varying vec3 v_world_pos;

void vertex() {
	// Extract the absolute World Position of the Individual Grass Tuft!
	v_world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	
	// If it's a top vertex (Y > 0.5 local), sway it!
	if (VERTEX.y > 0.5) {
		float wave_time = TIME * 2.5;
		// Rolling global wind matrix across the Earth based on world coordinates
		float wind_x = sin(v_world_pos.x * 0.12 + wave_time) * 0.5 + 0.5;
		float wind_z = cos(v_world_pos.z * 0.10 + wave_time * 1.2) * 0.5 + 0.5;
		
		VERTEX.x += wind_x * 1.8 * (VERTEX.y * 0.5);
		VERTEX.z += wind_z * 1.8 * (VERTEX.y * 0.5);
	}
}

void fragment() {
	// Dynamically shade to perfectly match the planet's calculated Grass Hue!
	ALBEDO = %s; 
	ROUGHNESS = 1.0;
}""" % [_v3s(pal_grass_col)]
	var mat = ShaderMaterial.new(); mat.shader = shader
	var mmi = MultiMeshInstance3D.new()
	mmi.multimesh = mm; mmi.material_override = mat; mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	
	# Grass renders up to 2500m — wide enough to see fields from low flight
	mmi.visibility_range_end = 2500.0; mmi.visibility_range_end_margin = 400.0
	add_child(mmi)

# BUILDERS (CACHED)
static var c_r: ArrayMesh
static var c_t_l: ArrayMesh
static var c_t_m: ArrayMesh
static var c_t_h: ArrayMesh
static var c_g: ArrayMesh

func _get_rock_xform(pos: Vector3, up: Vector3, noise_val: float, b_scale: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	
	# Massive randomized variance in X, Y, and Z independently to create huge blocky variations
	var sx = b_scale * (0.8 + abs(fmod(noise_val * 1337.0, 1.5)))
	var sy = b_scale * (0.8 + abs(fmod(noise_val * 4123.0, 1.8))) # Vertical bulk restores chunky boulder shapes!
	var sz = b_scale * (0.8 + abs(fmod(noise_val * 7777.0, 1.5)))
	var rot = abs(fmod(noise_val * 9999.0, PI * 2.0))
	
	return Transform3D(t_bas, pos).scaled_local(Vector3(sx, sy, sz)).rotated_local(Vector3.UP, rot)

func _get_grass_xform(pos: Vector3, up: Vector3, rand_val: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	
	var xf = Transform3D(t_bas, pos)
	var s = 1.5 + (rand_val * 1.2)
	return xf.scaled_local(Vector3(s, s * (0.8 + rand_val*0.6), s)).rotated_local(Vector3.UP, rand_val * PI * 2.0)

func _build_titan_faceted_rock_mesh() -> ArrayMesh:
	if c_r: return c_r
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES); st.set_color(Color("#666666"))
	
	# Generate a chunky 3-tier asymmetrical low-poly boulder!
	var sides = 8; var r1 = 8.0; var y1 = 4.0; var r2 = 5.0; var y2 = 7.0
	var top = Vector3(2.0, 9.0, -1.0) # Break symmetric cones with a shifted peak
	
	# BAKE AMBIENT OCCLUSION GRADIENTS INTO THE MESH ITSELF!
	var c_bot = Color("#333333")
	var c_mid1 = Color("#555555")
	var c_mid2 = Color("#777777")
	var c_top = Color("#999999")
	
	for i in range(sides):
		var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides
		var b1 = Vector3(cos(a1)*r1, 0, sin(a1)*r1); var b2 = Vector3(cos(a2)*r1, 0, sin(a2)*r1)
		
		# Adding pseudo-random mathematical offsets guarantees the rock looks organic and craggy
		var jag1 = sin(a1 * 3.0) * 1.8; var jag2 = sin(a2 * 3.0) * 1.8
		
		var m1 = Vector3(cos(a1)*(r1+jag1), y1+jag1, sin(a1)*(r1+jag1))
		var m2 = Vector3(cos(a2)*(r1+jag2), y1+jag2, sin(a2)*(r1+jag2))
		var t1 = Vector3(cos(a1)*r2, y2+jag1*0.5, sin(a1)*r2)
		var t2 = Vector3(cos(a2)*r2, y2+jag2*0.5, sin(a2)*r2)
		
		# Map CCW with Vertex Shadows mapped to each relative Tier level
		st.set_color(c_bot); st.add_vertex(b1); st.set_color(c_mid1); st.add_vertex(m1); st.set_color(c_bot); st.add_vertex(b2)
		st.set_color(c_mid1); st.add_vertex(m1); st.add_vertex(m2); st.set_color(c_bot); st.add_vertex(b2)
		
		st.set_color(c_mid1); st.add_vertex(m1); st.set_color(c_mid2); st.add_vertex(t1); st.set_color(c_mid1); st.add_vertex(m2)
		st.set_color(c_mid2); st.add_vertex(t1); st.add_vertex(t2); st.set_color(c_mid1); st.add_vertex(m2)
		
		st.set_color(c_mid2); st.add_vertex(t1); st.add_vertex(t2); st.set_color(c_top); st.add_vertex(top)
		st.set_color(c_bot); st.add_vertex(Vector3.ZERO); st.add_vertex(b1); st.add_vertex(b2)
		
	st.generate_normals(false); c_r = st.commit(); return c_r

func _build_pine_tree(tiers: int, sides: int, is_high: bool) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES); 
	
	st.set_color(Color(0.20, 0.14, 0.10)) # Dark desaturated wood (resists heavy instance tinting)
	var th = 7.0; var tr_b = 3.0; var tr_t = 0.8
	for i in range(sides):
		var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides
		var v1 = Vector3(cos(a1)*tr_b, 0, sin(a1)*tr_b); var v2 = Vector3(cos(a2)*tr_b, 0, sin(a2)*tr_b)
		var v3 = Vector3(cos(a1)*tr_t, th, sin(a1)*tr_t); var v4 = Vector3(cos(a2)*tr_t, th, sin(a2)*tr_t)
		st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v4); st.add_vertex(v1); st.add_vertex(v4); st.add_vertex(v3)
		
	# LEAVES: Colored pure white to perfectly inherit the Instance Colors from the MultiMesh!
	st.set_color(Color(1.0, 1.0, 1.0)) 
	
	for j in range(tiers):
		var is_last = (j == tiers - 1)
		var tier_ratio = float(j) / float(tiers)
		
		# Tiers aggressively overlap each other and droop down!
		var bh = th + (j * 4.5) 
		var ec = bh - 2.5 # Pine needles droop downwards toward the edges
		var th_c = bh + 8.5
		var cr = 14.0 * (1.0 - tier_ratio * 0.7) 
		
		var jag_scale = 0.25 if is_high else 0.0
		var top_offset = Vector3.ZERO
		
		# Quirky bent point on the high fidelity tree
		if is_last and is_high: top_offset = Vector3(2.5, 0, 1.0); th_c += 3.0 
			
		for i in range(sides):
			var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides
			# Alternating jagged scale produces zig-zagging canopy perimeters
			var cr1 = cr * (1.0 + (float(i % 2) - 0.5) * 2.0 * jag_scale)
			var cr2 = cr * (1.0 + (float((i+1) % 2) - 0.5) * 2.0 * jag_scale)
			
			var e1 = Vector3(cos(a1)*cr1, ec, sin(a1)*cr1); var e2 = Vector3(cos(a2)*cr2, ec, sin(a2)*cr2)
			var bot = Vector3(0, bh, 0); var top = Vector3(0, th_c, 0) + top_offset
			
			st.add_vertex(bot); st.add_vertex(e2); st.add_vertex(e1) # Inside faces
			st.add_vertex(top); st.add_vertex(e1); st.add_vertex(e2)  # Outside faces
			
	st.generate_normals(false); return st.commit()

func _build_low_tree() -> ArrayMesh:
	if c_t_l: return c_t_l
	c_t_l = _build_pine_tree(2, 4, false); return c_t_l

func _build_med_tree() -> ArrayMesh:
	if c_t_m: return c_t_m
	c_t_m = _build_pine_tree(4, 6, false); return c_t_m

func _build_high_tree() -> ArrayMesh:
	if c_t_h: return c_t_h
	c_t_h = _build_pine_tree(6, 10, true); return c_t_h

func _build_grass_mesh() -> ArrayMesh:
	if c_g: return c_g
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	# Stripped down to a single asymmetric blade of grass to optimize vertex draw-calls
	var bl = Vector3(-1.0, 0.0, 0.0); var br = Vector3(1.0, 0.0, 0.0)
	var top = Vector3(0.5, 3.5, 0.3) # Slightly bent peak 
	
	st.add_vertex(bl); st.add_vertex(br); st.add_vertex(top) 
		
	st.generate_normals(false); c_g = st.commit(); return c_g

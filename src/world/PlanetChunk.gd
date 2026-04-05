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
var planet_seed: int = 0  # Unique per celestial body, passed from PlanetGen
var scatter_grass: bool = false  # Only true when player is on foot

# DYNAMIC PROCEDURAL PLANET PALETTE
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

func start_generation() -> void:
	_generate_planetary_palette()
	_calculate_multi_surface_mesh()

func _generate_planetary_palette() -> void:
	var rng = RandomNumberGenerator.new()
	rng.seed = (int(radius) ^ int(terrain_strength * 100.0) ^ (planet_seed * 2654435761)) & 0x7FFFFFFF 
	
	pal_forest_h = rng.randf()
	pal_forest_col = Color.from_hsv(pal_forest_h, rng.randf_range(0.65, 0.95), rng.randf_range(0.55, 0.85))
	
	var grass_hue_offset = 0.5 + rng.randf_range(-0.15, 0.15)
	var grass_hue = fposmod(pal_forest_h + grass_hue_offset, 1.0)
	pal_grass_col = Color.from_hsv(grass_hue, rng.randf_range(0.55, 0.85), rng.randf_range(0.65, 0.90))
	pal_grass_secondary = Color.from_hsv(grass_hue, rng.randf_range(0.7, 0.95), rng.randf_range(0.3, 0.55)) # Darker contrast
	
	# BEACH HARDENING: Fixed Gold/Tan hue prevents 'pink sand' leaks
	var beach_hue = 0.13 + rng.randf_range(-0.02, 0.02)
	pal_beach_col = Color.from_hsv(beach_hue, rng.randf_range(0.3, 0.5), rng.randf_range(0.85, 0.95))
	
	var mount_hue = rng.randf_range(0.0, 0.15)
	pal_mount_col = Color.from_hsv(mount_hue, rng.randf_range(0.1, 0.6), rng.randf_range(0.3, 0.65))
	
	var water_hue = rng.randf_range(0.50, 0.65)
	pal_water_base = Color.from_hsv(water_hue, 0.85, 0.45) # Deep vivid blue
	pal_water_light = Color.from_hsv(water_hue, 0.75, 0.75) # Shimmering cyan
	pal_water_shore = Color.from_hsv(water_hue, 0.60, 0.95) # Tropical shore

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
			
			var floor_depth = SEA_LEVEL - 50.0
			var p1 = sn1 * (radius + max(h1, floor_depth)); var p2 = sn2 * (radius + max(h2, floor_depth))
			var p3 = sn3 * (radius + max(h3, floor_depth)); var p4 = sn4 * (radius + max(h4, floor_depth))
			
			_add_faceted_tri(st_land, p1, p3, p2, h1, h3, h2)
			_add_faceted_tri(st_land, p3, p4, p2, h3, h4, h2)
			
			if min(min(h1, h2), min(h3, h4)) <= SEA_LEVEL + 30.0:
				has_water = true
				var w1 = get_water_point(sn1); var w2 = get_water_point(sn2)
				var w3 = get_water_point(sn3); var w4 = get_water_point(sn4)
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
render_mode diffuse_lambert, specular_disabled;
varying float v_height;
varying vec3 v_world_pos;
varying vec3 v_normal;

uniform sampler2D ground_tex : source_color;

float aa_step(float edge, float val) {
	float delta = fwidth(val) * 1.5; 
	return smoothstep(edge - delta, edge + delta, val);
}

void vertex() {
	v_height = length(VERTEX) - (%f);
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	vec3 col_beach = %s; 
	vec3 col_forest = %s; 
	vec3 col_rock = %s; 
	vec3 col_snow = vec3(1.0, 1.0, 1.0);
	
	vec3 blending = abs(v_normal);
	blending /= (blending.x + blending.y + blending.z);
	float tex_scale = 0.005;
	vec3 tex_x = texture(ground_tex, v_world_pos.zy * tex_scale).rgb;
	vec3 tex_y = texture(ground_tex, v_world_pos.xz * tex_scale).rgb;
	vec3 tex_z = texture(ground_tex, v_world_pos.xy * tex_scale).rgb;
	vec3 detail_tex = tex_x * blending.x + tex_y * blending.y + tex_z * blending.z;
	float detail_level = mix(0.6, 1.4, detail_tex.r);
	
	float b_warp = sin(v_world_pos.x * 0.0015) * 300.0 + cos(v_world_pos.z * 0.002) * 200.0;
	float b_h = v_height + b_warp;
	
	float t_snow = aa_step(3500.0, b_h);
	float t_rock = aa_step(1500.0, b_h);
	float t_forest = aa_step(-200.0, v_height);
	
	vec3 albedo = col_beach;
	albedo = mix(albedo, col_forest, t_forest);
	albedo = mix(albedo, col_rock, t_rock);
	albedo = mix(albedo, col_snow, t_snow);
	albedo *= detail_level;
	
	float wave_time = TIME * 2.2;
	float w1 = sin(v_world_pos.x * 0.01 + wave_time) * 1.8;
	float water_h = (%f) + w1;
	float t_foam = aa_step(water_h - 1.0, v_height) * (1.0 - aa_step(water_h + 3.0, v_height));
	albedo = mix(albedo, vec3(1.0, 1.0, 1.0), t_foam);
	
	ALBEDO = albedo;
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
}

void light() {
	float l_level = dot(NORMAL, LIGHT);
	float t2 = aa_step(0.25, l_level);
	float t1 = aa_step(0.65, l_level);
	vec3 shadow_col = ALBEDO * 0.15;
	vec3 mid_col = ALBEDO * 0.55;
	vec3 final_col = mix(shadow_col, mid_col, t2);
	final_col = mix(final_col, ALBEDO, t1);
	DIFFUSE_LIGHT += final_col * LIGHT_COLOR * ATTENUATION;
}
""" % [radius, _v3s(pal_beach_col), _v3s(pal_forest_col), _v3s(pal_mount_col), SEA_LEVEL]
	var m_land = ShaderMaterial.new()
	m_land.shader = shader_land
	var g_tex = load("res://assets/textures/ground_texture.png")
	if g_tex: m_land.set_shader_parameter("ground_tex", g_tex)
	
	# DISTANCE-PHASE HARDENING: Only enable Outlines for detailed surface chunks
	if scale_factor < 0.013:
		var outline = ShaderMaterial.new()
		outline.shader = load("res://src/shaders/outline.gdshader")
		outline.set_shader_parameter("outline_width", 1.5)
		outline.set_shader_parameter("outline_color", Color.BLACK)
		m_land.next_pass = outline
	self.set_surface_override_material(0, m_land)
	
	if has_water:
		var shader = Shader.new()
		shader.code = """shader_type spatial;
render_mode diffuse_lambert, specular_toon;
varying vec3 v_world_pos;
varying float v_shore;

void vertex() {
	v_shore = COLOR.r;
	float wave_time = TIME * 2.2;
	float w1 = sin(VERTEX.x * 0.01 + wave_time) * 1.8;
	float w2 = cos(VERTEX.y * 0.008 - wave_time * 0.8) * 1.5;
	float w3 = sin(VERTEX.z * 0.012 + wave_time * 1.1) * 1.6;
	float r1 = sin((VERTEX.x - VERTEX.z) * 0.04 + wave_time * 3.0) * 0.5;
	VERTEX += normalize(VERTEX) * (w1 + w2 + w3 + r1);
	v_world_pos = VERTEX;
}

vec3 random3(vec3 p) {
    return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)),
                          dot(p, vec3(269.5, 183.3, 246.1)),
                          dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
}

float voronoi3D(vec3 x, float time) {
    vec3 n = floor(x); vec3 f = fract(x); float F1 = 8.0; float F2 = 8.0;
    for (int k = -1; k <= 1; k++) {
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                vec3 g = vec3(float(i), float(j), float(k));
                vec3 o = random3(n + g); o = 0.5 + 0.5 * sin(time + 6.2831 * o);
                vec3 r = g + o - f; float d = dot(r, r);
                if (d < F1) { F2 = F1; F1 = d; } else if (d < F2) { F2 = d; }
            }
        }
    }
    return sqrt(F2) - sqrt(F1);
}

void fragment() {
	vec3 base_blue = %s; vec3 light_blue = %s; vec3 shore_blue = %s; vec3 foam_color = vec3(1.0, 1.0, 1.0);
	vec3 warp = vec3(sin(v_world_pos.z * 0.005 + TIME*0.2), sin(v_world_pos.x * 0.005 + TIME*0.2), sin(v_world_pos.y * 0.005 + TIME*0.2)) * 150.0;
	float v = voronoi3D((v_world_pos + warp) * 0.0016, TIME * 0.1);
	vec3 final_color = base_blue;
	if (v < 0.04) final_color = foam_color;
	else if (v < 0.15) final_color = light_blue; 
	float dist_to_cam = length(VERTEX); 
	float altitude_fade = smoothstep(100000.0, 15000.0, dist_to_cam);
	float shore_fade = 1.0 - smoothstep(0.02, 0.15, v_shore);
	float total_ripple_alpha = altitude_fade * shore_fade;
	final_color = mix(base_blue, final_color, total_ripple_alpha);
	if (v_shore > 0.0) {
		final_color = mix(final_color, shore_blue, v_shore * 0.8);
		float warped_shore = v_shore + (warp.x * 0.0005) + (warp.z * 0.0005);
		float lat = sin(v_world_pos.x * 0.008 + TIME * 0.4) * sin(v_world_pos.z * 0.008) * 0.5 + 0.5;
		float swell = sin(warped_shore * 6.0 - TIME * 1.2 + lat * 2.0) * 0.5 + 0.6;
		float rings = sin(warped_shore * 32.0 - TIME * 3.2) * swell;
		if (rings > 0.85 && warped_shore > 0.02 && warped_shore < 0.95) final_color = foam_color;
	}
	ALBEDO = final_color; METALLIC = 0.0; ROUGHNESS = 1.0;
}

void light() {
	float atten = ATTENUATION; float sharp_atten = smoothstep(0.4, 0.6, atten); 
	float l_level = dot(NORMAL, LIGHT) * sharp_atten;
	float t1 = smoothstep(0.2, 0.25, l_level);
	vec3 shadow_col = ALBEDO * 0.5; 
	DIFFUSE_LIGHT += mix(shadow_col, ALBEDO, t1) * LIGHT_COLOR;
}
""" % [_v3s(pal_water_base), _v3s(pal_water_light), _v3s(pal_water_shore)]
		var m_water = ShaderMaterial.new()
		m_water.shader = shader
		self.set_surface_override_material(1, m_water)
	# ONLY CAST SHADOWS for the immediate high-detail terrain
	if scale_factor <= 0.005:
		create_trimesh_collision()
		self.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	else:
		self.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _scatter_deterministic_stellar_layers() -> void:
	# CPU HARDENING: Only populate vegetation for chunks visible during atmospheric approach (<= 20km)
	if scale_factor > 0.02: return 
	var radius_ratio: float = clamp(radius / 1000000.0, 0.3, 1.5)
	var t_pts: Array[Transform3D] = []; var r_pts: Array[Transform3D] = []
	var g_pts: Array[Transform3D] = []
	
	var t_cell: float = 0.00025 / radius_ratio
	var ts_x = int(floor((offset.x - scale_factor) / t_cell)); var te_x = int(ceil((offset.x + scale_factor) / t_cell))
	var ts_y = int(floor((offset.y - scale_factor) / t_cell)); var te_y = int(ceil((offset.y + scale_factor) / t_cell))
	# Stable 256 performance window ensures zero-latency CPU processing
	if (te_x - ts_x) <= 256:
		for y_idx in range(ts_y, te_y):
			for x_idx in range(ts_x, te_x):
				# ACE BOTANICAL DETERMINISM: Unique seed for every planet face
				var h_v = hash(Vector3(float(x_idx), float(y_idx), float(planet_seed) + face_normal.x*13.0 + face_normal.y*17.0 + face_normal.z*19.0))
				var t_val = h_v % 1000
				if t_val < 950:
					# DETERMINISTIC JITTER: Breaches the pattern grid (±45% organic variance)
					var j_x = (float(h_v % 50)/50.0 - 0.5) * 0.9
					var j_y = (float((h_v >> 4) % 50)/50.0 - 0.5) * 0.9
					
					var lu = Vector2((float(x_idx) + j_x) * t_cell, (float(y_idx) + j_y) * t_cell)
					var cp = (face_normal + x_axis * lu.x + y_axis * lu.y).normalized()
					
					var m_d = noise.get_noise_3dv(cp * 65000.0) # HIGH FREQ: Clustered Groves
					var is_forest = (m_d > 0.08)
					# CLUSTER SYNC: Density is 8x higher in the center of forest noise blobs
					var f_mult = clamp((m_d - 0.08) * 15.0, 0.0, 1.0)
					var f_density = int(950 * f_mult * radius_ratio) 
					var g_density = int(45 * radius_ratio) # Sparse solo trees
					var rock_threshold = int(25 * radius_ratio)
					
					var spawn_tree = (is_forest and (h_v % 1000) < f_density) or (not is_forest and (h_v % 1000) < g_density)
					if spawn_tree or (not is_forest and (h_v % 1000) < rock_threshold):
						var h = get_terrain_elevation(cp)
						if h > -150.0:
							var pos = cp * (radius + max(h, SEA_LEVEL - 50.0))
							var b_warp = sin(pos.x * 0.0015) * 300.0 + cos(pos.z * 0.002) * 200.0
							if spawn_tree:
								if h > -150.0 and (h + b_warp) < 1450.0:
									t_pts.append(_get_object_xform(pos, cp, noise.get_noise_3dv(cp * 36000.0), 13.0))
							else:
								if (h + b_warp) <= 1500.0 and t_val < rock_threshold:
									r_pts.append(_get_rock_xform(pos, cp, noise.get_noise_3dv(cp * 45000.0), 18.0))
	# GRASS HARDENING: Absolute-Grid jitter ensures lush, non-patterned swaying blades
	if scale_factor <= 0.00055:
		var g_cell: float = 0.0000045 / radius_ratio
		var gs_x = int(floor((offset.x - scale_factor) / g_cell)); var ge_x = int(ceil((offset.x + scale_factor) / g_cell))
		var gs_y = int(floor((offset.y - scale_factor) / g_cell)); var ge_y = int(ceil((offset.y + scale_factor) / g_cell))
		if (ge_x - gs_x) <= 300:
			for y_idx in range(gs_y, ge_y):
				for x_idx in range(gs_x, ge_x):
					var h_v = hash(Vector3(float(x_idx), float(y_idx), float(planet_seed) + face_normal.x*7.0 + face_normal.z*3.0))
					if h_v % 100 < 80:
						# DETERMINISTIC JITTER: Breaches the pattern grid (±60% variance)
						var j_x = (float(h_v % 50)/50.0 - 0.5) * 0.6
						var j_y = (float((h_v >> 4) % 50)/50.0 - 0.5) * 0.6
						var lu = Vector2((float(x_idx) + j_x) * g_cell, (float(y_idx) + j_y) * g_cell)
						var cp = (face_normal + x_axis * lu.x + y_axis * lu.y).normalized()
						var m_d = noise.get_noise_3dv(cp * 1500.0)
						if m_d > 0.1:
							var h = get_terrain_elevation(cp)
							var pos = cp * (radius + max(h, SEA_LEVEL - 50.0))
							if h > -150.0 and (h + sin(pos.x * 0.0015)*300.0) < 1300.0:
								g_pts.append(_get_grass_xform(pos, cp, fmod(float(h_v), 10.0)/10.0))
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
	var mmi = MultiMeshInstance3D.new(); var mm = MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _build_titan_faceted_rock_mesh(); mm.instance_count = points.size()
	for i in range(points.size()): mm.set_instance_transform(i, points[i])
	var mat = ShaderMaterial.new(); mat.shader = load("res://src/shaders/hatch_toon.gdshader"); mat.set_shader_parameter("shadow_strength", 0.9)
	var out = ShaderMaterial.new(); out.shader = load("res://src/shaders/outline.gdshader"); out.set_shader_parameter("outline_width", 1.5); out.set_shader_parameter("outline_color", Color.BLACK)
	mat.next_pass = out; mmi.multimesh = mm; mmi.material_override = mat; mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if scale_factor < 0.05 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

func _spawn_tree_lods(points: Array[Transform3D]) -> void:
	var mat = ShaderMaterial.new(); mat.shader = load("res://src/shaders/hatch_toon.gdshader")
	var out = ShaderMaterial.new(); out.shader = load("res://src/shaders/outline.gdshader"); out.set_shader_parameter("outline_width", 1.5); out.set_shader_parameter("outline_color", Color.BLACK); mat.next_pass = out
	var mm_l = MultiMesh.new(); mm_l.transform_format = MultiMesh.TRANSFORM_3D; mm_l.use_colors = true; mm_l.mesh = _build_low_tree(); mm_l.instance_count = points.size()
	var mm_m = MultiMesh.new(); mm_m.transform_format = MultiMesh.TRANSFORM_3D; mm_m.use_colors = true; mm_m.mesh = _build_med_tree(); mm_m.instance_count = points.size()
	var mm_h = MultiMesh.new(); mm_h.transform_format = MultiMesh.TRANSFORM_3D; mm_h.use_colors = true; mm_h.mesh = _build_high_tree(); mm_h.instance_count = points.size()
	for i in range(points.size()): 
		var pos = points[i].origin
		# CELESTIAL CONTRAST HARDENING: 0.5 Hue Offset ensures trees contrast with the ground (no more pink on pink!)
		var t_hue = fposmod(pal_forest_h + 0.5 + fposmod(pos.x*0.012, 0.3) - 0.15, 1.0)
		var t_col = Color.from_hsv(t_hue, 0.85, 0.8).darkened(fposmod(pos.x*pos.z*0.001, 0.15))
		mm_l.set_instance_transform(i, points[i]); mm_l.set_instance_color(i, t_col)
		mm_m.set_instance_transform(i, points[i]); mm_m.set_instance_color(i, t_col)
		mm_h.set_instance_transform(i, points[i]); mm_h.set_instance_color(i, t_col)
	var m_l = MultiMeshInstance3D.new(); m_l.multimesh = mm_l; m_l.material_override = mat; m_l.visibility_range_begin = 30000.0; m_l.visibility_range_end = 60000.0; add_child(m_l)
	var m_m = MultiMeshInstance3D.new(); m_m.multimesh = mm_m; m_m.material_override = mat; m_m.visibility_range_begin = 15000.0; m_m.visibility_range_end = 30000.0; add_child(m_m)
	var m_h = MultiMeshInstance3D.new(); m_h.multimesh = mm_h; m_h.material_override = mat; m_h.visibility_range_end = 15000.0; add_child(m_h)

func _spawn_grass(points: Array[Transform3D]) -> void:
	var mm = MultiMesh.new(); mm.transform_format = MultiMesh.TRANSFORM_3D; mm.mesh = _build_grass_mesh()
	mm.use_custom_data = true # ACE DUO-TONE SYNC
	mm.instance_count = points.size()
	for i in range(points.size()): 
		mm.set_instance_transform(i, points[i])
		var j = fmod(float(hash(points[i].origin)), 10.0)/10.0
		mm.set_instance_custom_data(i, Color(j, 0, 0, 0))
	var shader = Shader.new(); shader.code = """shader_type spatial; render_mode diffuse_toon, specular_toon, cull_disabled;
varying vec3 v_world_pos;
varying float v_h_jitter;
void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_h_jitter = INSTANCE_CUSTOM.x; // Pass hash-jitter for color variation
	if (VERTEX.y > 0.5) {
		float wt = TIME * 2.5;
		VERTEX.x += sin(v_world_pos.x * 0.12 + wt) * 0.9 * VERTEX.z;
		VERTEX.z += cos(v_world_pos.z * 0.10 + wt) * 0.9 * VERTEX.x;
	}
}
void fragment() {
	vec3 base = %s; vec3 contrast = %s;
	ALBEDO = mix(base, contrast, v_h_jitter);
	ROUGHNESS = 1.0;
}""" % [_v3s(pal_grass_col), _v3s(pal_grass_secondary)]
	var mmi = MultiMeshInstance3D.new(); mmi.multimesh = mm; mmi.material_override = ShaderMaterial.new(); mmi.material_override.shader = shader; 
	mmi.visibility_range_end = 1200.0; # ACE DISCOVERY PERFORMANCE: 1.2km Visibility cutoff
	mmi.visibility_range_begin = 5.0; # Zero-fighting safety
	mmi.visibility_range_end_margin = 150.0; # Smooth pop-in
	add_child(mmi)

func _get_rock_xform(pos: Vector3, up: Vector3, noise_val: float, b_scale: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	return Transform3D(t_bas, pos).scaled_local(Vector3(b_scale*(0.8+abs(fmod(noise_val*1337.0,1.5))), b_scale*(0.8+abs(fmod(noise_val*4123.0,1.8))), b_scale*(0.8+abs(fmod(noise_val*7777.0,1.5))))).rotated_local(Vector3.UP, abs(fmod(noise_val*9999.0,PI*2.0)))

func _get_grass_xform(pos: Vector3, up: Vector3, rand_val: float) -> Transform3D:
	var t_bas = Basis(); t_bas.y = up; t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1: t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	var s = 1.5 + (rand_val * 1.2); return Transform3D(t_bas, pos).scaled_local(Vector3(s, s*(0.8+rand_val*0.6), s)).rotated_local(Vector3.UP, rand_val*PI*2.0)

func _build_titan_faceted_rock_mesh() -> ArrayMesh:
	if c_r: return c_r
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES); var s_c = 8; var r1 = 8.0; var y1 = 4.0; var r2 = 5.0; var y2 = 7.0; var top = Vector3(2.0, 9.0, -1.0)
	for i in range(s_c):
		var a1 = i * TAU/s_c; var a2 = (i+1) * TAU/s_c; var b1 = Vector3(cos(a1)*r1, 0, sin(a1)*r1); var b2 = Vector3(cos(a2)*r1, 0, sin(a2)*r1)
		var j1 = sin(a1*3.0)*1.8; var j2 = sin(a2*3.0)*1.8; var m1 = Vector3(cos(a1)*(r1+j1), y1+j1, sin(a1)*(r1+j1)); var m2 = Vector3(cos(a2)*(r1+j2), y1+j2, sin(a2)*(r1+j2))
		var t1 = Vector3(cos(a1)*r2, y2+j1*0.5, sin(a1)*r2); var t2 = Vector3(cos(a2)*r2, y2+j2*0.5, sin(a2)*r2)
		st.set_color(Color("#333333")); st.add_vertex(b1); st.set_color(Color("#555555")); st.add_vertex(m1); st.set_color(Color("#333333")); st.add_vertex(b2)
		st.set_color(Color("#555555")); st.add_vertex(m1); st.add_vertex(m2); st.set_color(Color("#333333")); st.add_vertex(b2)
		st.set_color(Color("#555555")); st.add_vertex(m1); st.set_color(Color("#777777")); st.add_vertex(t1); st.set_color(Color("#555555")); st.add_vertex(m2)
		st.set_color(Color("#777777")); st.add_vertex(t1); st.add_vertex(t2); st.set_color(Color("#555555")); st.add_vertex(m2)
		st.set_color(Color("#777777")); st.add_vertex(t1); st.add_vertex(t2); st.set_color(Color("#999999")); st.add_vertex(top)
		st.set_color(Color("#333333")); st.add_vertex(Vector3.ZERO); st.add_vertex(b1); st.add_vertex(b2)
	st.generate_normals(false); c_r = st.commit(); return c_r

func _build_pine_tree(tiers: int, sides: int, is_high: bool) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES); st.set_color(Color(0.2, 0.14, 0.1))
	var th = 1.25; var tr_b = 0.65; var tr_t = 0.25
	for i in range(sides):
		var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides; var v1 = Vector3(cos(a1)*tr_b, 0, sin(a1)*tr_b); var v2 = Vector3(cos(a2)*tr_b, 0, sin(a2)*tr_b)
		var v3 = Vector3(cos(a1)*tr_t, th, sin(a1)*tr_t); var v4 = Vector3(cos(a2)*tr_t, th, sin(a2)*tr_t)
		st.add_vertex(v1); st.add_vertex(v2); st.add_vertex(v4); st.add_vertex(v1); st.add_vertex(v4); st.add_vertex(v3)
	st.set_color(Color(1, 1, 1)) 
	for j in range(tiers):
		var bh = th + (j * 1.5); var ec = bh - 0.75; var th_c = bh + 2.5; var cr = 3.5 * (1.0 - (float(j)/tiers)*0.7); var js = 0.25 if is_high else 0.0
		var to = Vector3(0.5, 0, 0.2) if (j == tiers - 1 and is_high) else Vector3.ZERO
		for i in range(sides):
			var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides; var cr1 = cr * (1.0 + (float(i%2)-0.5)*2.0*js); var cr2 = cr * (1.0 + (float((i+1)%2)-0.5)*2.0*js)
			var e1 = Vector3(cos(a1)*cr1, ec, sin(a1)*cr1); var e2 = Vector3(cos(a2)*cr2, ec, sin(a2)*cr2); var bot = Vector3(0, bh, 0); var top = Vector3(0, th_c, 0) + to
			st.add_vertex(bot); st.add_vertex(e2); st.add_vertex(e1); st.add_vertex(top); st.add_vertex(e1); st.add_vertex(e2)
	st.generate_normals(false); return st.commit()

func _build_low_tree() -> ArrayMesh:
	if c_t_l: return c_t_l
	c_t_l = _build_pine_tree(2, 4, false)
	return c_t_l

func _build_med_tree() -> ArrayMesh:
	if c_t_m: return c_t_m
	c_t_m = _build_pine_tree(4, 6, false)
	return c_t_m

func _build_high_tree() -> ArrayMesh:
	if c_t_h: return c_t_h
	c_t_h = _build_pine_tree(6, 10, true)
	return c_t_h

func _build_grass_mesh() -> ArrayMesh:
	if c_g: return c_g
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# SCULPTURAL CLUSTER HARDENING: Prince-Scale blades
	var blades = 3
	for i in range(blades):
		var ang = (float(i) / blades) * TAU; var h = 1.0 + randf()*1.2; var w = 0.35
		var dir = Vector3(cos(ang), 0.0, sin(ang)) * 0.4; var side = dir.cross(Vector3.UP).normalized() * w
		st.add_vertex(dir - side); st.add_vertex(dir + side); st.add_vertex(dir + Vector3(0, h, 0))
	st.generate_normals(false); c_g = st.commit(); return c_g

static var c_r: ArrayMesh
static var c_t_l: ArrayMesh
static var c_t_m: ArrayMesh
static var c_t_h: ArrayMesh
static var c_g: ArrayMesh

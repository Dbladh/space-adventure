@tool
extends Node3D

# PlanetImpostor.gd
# Managed by THE ARCHITECT. A low-poly astronomical proxy class.
# COMPOSITION OVER INHERITANCE: Node3D container for the celestial proxy mesh.

@export var planet_radius: float = 1.0:
	set(new_r):
		planet_radius = new_r
		if is_inside_tree(): _generate_stellar_proxy()
@export var planet_color: Color = Color(0.4, 0.7, 0.3):
	set(new_c):
		planet_color = new_c
		if is_inside_tree(): _generate_stellar_proxy()
@export var planet_color_b: Color = Color(0.5, 0.45, 0.35):
	set(new_c):
		planet_color_b = new_c
		if is_inside_tree(): _generate_stellar_proxy()
@export var continent_pole: Vector3 = Vector3.UP:
	set(new_p):
		continent_pole = new_p
		if is_inside_tree(): _generate_stellar_proxy()
@export var horizon_col: Color = Color(0.4, 0.7, 1.0):
	set(new_c):
		horizon_col = new_c
		if is_inside_tree(): _generate_stellar_proxy()
@export var water_col: Color = Color(0.1, 0.3, 0.6):
	set(new_c):
		water_col = new_c
		if is_inside_tree(): _generate_stellar_proxy()

func _ready() -> void:
	_generate_stellar_proxy()

func _generate_stellar_proxy() -> void:
	# Clear existing proxies
	for child in get_children():
		child.queue_free()

	# LOW-POLY STELLAR PROXY: 48x24 sphere — efficient but round enough from orbit
	var mi = MeshInstance3D.new()
	var s_mesh = SphereMesh.new()
	s_mesh.radius = planet_radius
	s_mesh.height = planet_radius * 2.0
	s_mesh.radial_segments = 48
	s_mesh.rings = 24
	mi.mesh = s_mesh

	# 2-TONE SHADER: Blends grass color (equator) into mountain color (poles)
	# so the impostor visually matches the real planet terrain palette from orbit.
	# Using NORMAL.y as a latitude proxy: 0 at equator, 1 at poles.
	var mat = ShaderMaterial.new()
	var sh = Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, fog_disabled;
uniform vec3 col_a; // Equator
uniform vec3 col_b; // Poles
uniform vec3 c_pole; // Mega-Continent Pole
uniform vec3 h_col; // Atmosphere (Horizon)
uniform vec3 w_col; // Water

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 p) {
	vec3 i = floor(p); vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i + vec3(0,0,0)), hash(i + vec3(1,0,0)), f.x),
	               mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
	           mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x),
	               mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}

void fragment() {
	float lat = abs(NORMAL.y);
	
	// ACE SURFACE NOISE: Re-implementing the orbital landmass generator
	float n = noise(NORMAL * 5.0) * 0.4 + noise(NORMAL * 12.0) * 0.1;
	float warp_n = noise(NORMAL * 1.2) * 2.0 - 1.0;
	vec3 warped_sn = normalize(NORMAL + vec3(warp_n, warp_n, warp_n) * 0.35);
	float dist_to_pole = length(warped_sn - c_pole);
	float proximity = smoothstep(1.0, 0.4, dist_to_pole);
	float c_noise = noise(NORMAL * 2.2) * 1.5; 
	float major_mask = smoothstep(0.48, 0.52, c_noise + proximity * 0.9);

	# ACE CONTINENTAL HANDOVER: Map landmasses and oceans to the orbital proxy
	vec3 land_base = mix(col_a, col_b, smoothstep(0.4, 0.9, lat));
	vec3 base_col = mix(w_col, land_base, major_mask);
	
	# POLAR ICE CAPS: Mandatory snow overlay at the high latitudes
	float pole_mask = smoothstep(0.82, 0.92, lat);
	base_col = mix(base_col, vec3(0.95, 0.98, 1.0), pole_mask);
	
	// ACE MANUAL TERMINATOR
	vec3 light_dir = normalize(-NODE_POSITION_WORLD);
	// ACE SPACE SYNC: Transform world-space light direction to view-space for accurate fragment shading
	vec3 v_light_dir = (VIEW_MATRIX * vec4(light_dir, 0.0)).xyz;
	float d = dot(NORMAL, v_light_dir);
	
	# MINIMALIST GLOW: Core metropolitan grid only
	float darkness = 1.0 - smoothstep(-0.2, 0.2, d);
	vec2 grid_uv = fract(NORMAL.xz * 60.0);
	float grid_noise = step(0.4, grid_uv.x) * step(0.4, grid_uv.y);
	vec3 lights = vec3(0.0);
	
	// High-fidelity planetary lighting
	float l = smoothstep(-0.4, 0.5, d) * 0.3 + 0.7;
	
	// ACE ATMOSPHERIC HALO: Vibrant rim glow keyed to the planet's unique sky palette
	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	vec3 atmosphere = h_col * fresnel * smoothstep(-0.4, 1.0, d) * 1.5;
	
	ALBEDO = base_col * l + lights;
	EMISSION = atmosphere + lights;
}"""
	mat.shader = sh
	mat.set_shader_parameter("col_a", planet_color)
	mat.set_shader_parameter("col_b", planet_color_b)
	mat.set_shader_parameter("c_pole", continent_pole)
	mat.set_shader_parameter("h_col", horizon_col)
	mat.set_shader_parameter("w_col", water_col)
	mi.material_override = mat

	# Celestial Sync: Ensure the impostor is visible from millions of kilometers
	var a_size = planet_radius * 2.0
	mi.custom_aabb = AABB(Vector3(-planet_radius, -planet_radius, -planet_radius), Vector3(a_size, a_size, a_size))

	add_child(mi)
	print("--- ARCHITECT: Celestial Proxy Online (", planet_radius, "m) ---")

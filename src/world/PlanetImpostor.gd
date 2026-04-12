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
	vec3 base_col = mix(col_a, col_b, smoothstep(0.3, 0.85, lat));
	
	// ACE SURFACE DETAIL: Low-freq noise pattern to simulate continents
	float n = noise(NORMAL * 5.0) * 0.4 + noise(NORMAL * 12.0) * 0.1;
	base_col = mix(base_col, base_col * 0.6, smoothstep(0.4, 0.6, n));
	
	// ACE MANUAL TERMINATOR: Calculate light direction based on world-origin (The Sun at 0,0,0)
	vec3 light_dir = normalize(-NODE_POSITION_WORLD);
	float d = dot(NORMAL, light_dir);
	
	// High-fidelity planetary lighting: 70% min luminosity to cut through sky glare
	float l = smoothstep(-0.4, 0.5, d) * 0.3 + 0.7;
	ALBEDO = base_col * l;
}"""
	mat.shader = sh
	mat.set_shader_parameter("col_a", planet_color)
	mat.set_shader_parameter("col_b", planet_color_b)
	mi.material_override = mat

	# Celestial Sync: Ensure the impostor is visible from millions of kilometers
	var a_size = planet_radius * 2.0
	mi.custom_aabb = AABB(Vector3(-planet_radius, -planet_radius, -planet_radius), Vector3(a_size, a_size, a_size))

	add_child(mi)
	print("--- ARCHITECT: Celestial Proxy Online (", planet_radius, "m) ---")

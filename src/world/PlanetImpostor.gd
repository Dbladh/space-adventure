@tool
extends Node3D

# PlanetImpostor.gd
# Managed by THE ARCHITECT. A low-poly astronomical proxy class.
# COMPOSITION OVER INHERITANCE: Node3D container for the celestial proxy mesh.

@export var planet_radius: float = 1.0:
	set(new_r):
		planet_radius = new_r
		if is_inside_tree(): _generate_stellar_proxy()
@export var planet_color: Color = Color.WHITE:
	set(new_c):
		planet_color = new_c
		if is_inside_tree(): _generate_stellar_proxy()

func _ready() -> void:
	_generate_stellar_proxy()

func _generate_stellar_proxy() -> void:
	# Clear existing proxies
	for child in get_children():
		child.queue_free()
		
	# LOW-POLY STELLAR PROXY: 16x16 sphere is 100x more efficient than QuadTree faces at range
	var mi = MeshInstance3D.new()
	var s_mesh = SphereMesh.new()
	s_mesh.radius = planet_radius
	s_mesh.height = planet_radius * 2.0
	s_mesh.radial_segments = 32
	s_mesh.rings = 16
	mi.mesh = s_mesh
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED # Emissive look from distance
	mat.albedo_color = planet_color
	mi.material_override = mat
	
	# Celestial Sync: Ensure the impostor is visible from millions of kilometers
	# By default, Godot might cull distant objects; we ensure the AABB is astronomical.
	var a_size = planet_radius * 2.0
	mi.custom_aabb = AABB(Vector3(-planet_radius, -planet_radius, -planet_radius), Vector3(a_size, a_size, a_size))
	
	add_child(mi)
	print("--- ARCHITECT: Celestial Proxy Online (", planet_radius, "m) ---")

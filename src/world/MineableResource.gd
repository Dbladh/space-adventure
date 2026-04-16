extends StaticBody3D

# MineableResource.gd
# Managed by THE PROCEDURALIST.
# A deterministic, low-poly mineral deposit that responds to projectile impacts.

@export var resource_type: String = "Copper"
var health: float = 1.0 # 1 hit for Copper/Silver, more for rare types

func _ready() -> void:
	# ACE SCALING: Adjust health based on rarity
	match resource_type:
		"Platinum": health = 3.0
		"Diamond": health = 5.0
		_: health = 1.0
	
	_generate_low_poly_node()

func _generate_low_poly_node() -> void:
	# ACE GEOMETRY: Procedural jagged crystal using SurfaceTool
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(global_position) + resource_type)
	
	var col = _get_resource_color()
	var size = rng.randf_range(3.5, 7.5) # ACE: 2x Size Upgrade for visibility
	if resource_type == "Diamond": size *= 0.8
	
	# Create a jagged dodecahedron-ish shape
	var verts: Array[Vector3] = []
	for i in range(8):
		var v = Vector3(rng.randf_range(-1,1), rng.randf_range(-1,1), rng.randf_range(-1,1)).normalized() * size
		verts.append(v)
		
	# Simple convex hull-ish triangulation
	for i in range(verts.size()):
		for j in range(i + 1, verts.size()):
			for k in range(j + 1, verts.size()):
				# ACE: Every face must be flat-shaded per project rules
				var a = verts[i]; var b = verts[j]; var c = verts[k]
				var n = (b-a).cross(c-a).normalized()
				st.set_color(col)
				st.set_normal(n); st.add_vertex(a)
				st.set_normal(n); st.add_vertex(b)
				st.set_normal(n); st.add_vertex(c)

	var mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = st.commit()
	
	# ACE EMISSION: High-intensity neon glow for the looter-shooter pilot
	var mat = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
	if resource_type in ["Gold", "Platinum", "Diamond"]:
		mat.emission_enabled = true
		mat.emission = col * 4.5 # Pumping energy to cut through darkness
		
		# ACE: Add a physical light source for 'Night Discovery'
		var light = OmniLight3D.new()
		light.light_color = col
		light.light_energy = 2.5
		light.omni_range = size * 4.0
		add_child(light)
		
	mesh_inst.material_override = mat
	add_child(mesh_inst)
	
	# ADD COLLIDER
	var shape = CollisionShape3D.new()
	var box = BoxShape3D.new(); box.size = Vector3(size, size, size) * 2.0
	shape.shape = box
	add_child(shape)

func _get_resource_color() -> Color:
	match resource_type:
		"Copper": return Color(0.72, 0.45, 0.2)
		"Silver": return Color(0.75, 0.75, 0.75)
		"Gold": return Color(1.0, 0.84, 0.0)
		"Platinum": return Color(0.9, 0.9, 1.0)
		"Diamond": return Color(0.4, 0.8, 1.0)
	return Color.GRAY

func take_damage(_amount: float) -> void:
	health -= 1.0
	# ACE FEEDBACK: Subtle vibration on hit?
	if health <= 0:
		_on_mined()
	else:
		# Flash or recoil
		pass

func _on_mined() -> void:
	# NOTIFY ECONOMY
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.add_resource(resource_type, 1)
	elif get_tree().root.has_node("EconomyManager"):
		get_tree().root.get_node("EconomyManager").add_resource(resource_type, 1)
		
	# SPAWN FX (Explosion bits)
	# ... implementation omitted for brevity ...
	
	queue_free()

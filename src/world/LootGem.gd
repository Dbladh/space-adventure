// (c) On the Side LLC. and affiliates. Confidential and proprietary.
// THE GUNSMITH: High-fidelity loot fragments that explode from shattered monoliths.
// Designed with a 'Magnetic Homing' state machine to ensure satisfying collection.

extends Node3D

# Shared geometry: one ArrayMesh built on first instantiation, reused by every gem.
# Prevents the ~50× synchronous SurfaceTool.commit() freeze on bulk asteroid loot drops.
static var _shared_mesh: ArrayMesh = null

var target_player: Node3D = null
var velocity: Vector3 = Vector3.ZERO
var gravity: float = 8.0 # Local gravity for the 'shatter' effect
var state: String = "EXPLODING"
var timer: float = 0.0
var value: int = 250
var col: Color = Color.WHITE

static func _build_shared_mesh() -> ArrayMesh:
	# ACE GEOMETRY: Mini-Rupee (Emerald cut). Vertex colors omitted so per-gem
	# tint is driven entirely by the material's albedo/emission.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := 8.0
	var v_top := Vector3(0, size, 0)
	var v_bot := Vector3(0, -size, 0)
	var v_mid := [Vector3(size, 0, 0), Vector3(0, 0, size), Vector3(-size, 0, 0), Vector3(0, 0, -size)]
	for i in range(4):
		var m1: Vector3 = v_mid[i]
		var m2: Vector3 = v_mid[(i + 1) % 4]
		var n_up := (m1 - v_top).cross(m2 - v_top).normalized()
		st.set_normal(n_up); st.add_vertex(v_top)
		st.set_normal(n_up); st.add_vertex(m1)
		st.set_normal(n_up); st.add_vertex(m2)
		var n_down := (m2 - v_bot).cross(m1 - v_bot).normalized()
		st.set_normal(n_down); st.add_vertex(v_bot)
		st.set_normal(n_down); st.add_vertex(m2)
		st.set_normal(n_down); st.add_vertex(m1)
	return st.commit()

func _ready() -> void:
	if _shared_mesh == null:
		_shared_mesh = _build_shared_mesh()
	var mi = MeshInstance3D.new()
	mi.mesh = _shared_mesh
	var mat = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)
	
	# ACE: Initial explosion velocity
	var rng = RandomNumberGenerator.new(); rng.randomize()
	velocity = Vector3(rng.randf_range(-1,1), rng.randf_range(0.5, 2.0), rng.randf_range(-1,1)).normalized() * 600.0

func _process(delta: float) -> void:
	timer += delta
	match state:
		"EXPLODING":
			global_position += velocity * delta
			velocity.y -= gravity * delta * 10.0 # Heavy shatter arc
			if timer > 1.2: state = "HOMING"
		"HOMING":
			if not target_player:
				var p = get_tree().get_nodes_in_group("Player")
				if p.size() > 0: target_player = p[0]
				else: return
			
			var dir = (target_player.global_position - global_position).normalized()
			var dist = global_position.distance_to(target_player.global_position)
			
			# Accelerate toward ship
			var speed = clamp(4000.0 / (dist + 10.0), 800.0, 15000.0)
			global_position += dir * speed * delta
			
			# ACE: Smooth rotation during flight
			rotate_y(delta * 10.0); rotate_x(delta * 5.0)
			
			if dist < 50.0:
				_on_collected()

func _on_collected() -> void:
	# Add to economy
	var economy = get_node_or_null("/root/EconomyManager")
	if economy: economy.call("add_credits", value)
	queue_free()

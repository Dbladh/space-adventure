
extends Area3D

# LaserBolt.gd
# THE GUNSMITH: A single fired projectile from the Starhawk's twin cannons.
# Uses Area3D so it can detect overlapping physics bodies without needing a full collision body.
# Destroys itself on impact and triggers the explosion VFX on the target.

const SPEED: float = 900000.0  # Fast enough to feel instant at orbital scales
const LIFETIME: float = 2.5    # Auto-despawn so we never leak stray bolts

var direction: Vector3 = Vector3.FORWARD
var elapsed: float = 0.0
var mesh_node: MeshInstance3D

func _ready() -> void:
	# BUILD THE LASER ROD GEOMETRY PROCEDURALLY
	# A low-poly elongated capsule using CapsuleMesh for a sleek energy bolt look
	mesh_node = MeshInstance3D.new()
	var rod = CapsuleMesh.new()
	rod.radius = 1.8
	rod.height = 80.0
	mesh_node.mesh = rod
	mesh_node.rotation_degrees.x = 90.0 # Align the rod along the forward axis (Z)
	
	# GLOWING NEON MATERIAL — unshaded so it ignores world lighting and glows independently
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 1.0)
	mat.emission_energy_multiplier = 8.0
	rod.surface_set_material(0, mat)
	add_child(mesh_node)
	
	# COLLISION SPHERE: Wide enough to register hits on all asteroid and tree scales
	var col = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = 30.0
	col.shape = sphere
	add_child(col)
	
	# CRITICAL: Area3D must have monitoring=true and a collision_mask that
	# matches the target's physics layer. StaticBody3D defaults to layer 1.
	monitoring = true
	monitorable = false  # Bolts don't need to be detectable by others
	collision_layer = 0  # The bolt itself occupies no layer
	collision_mask = 1   # Watch layer 1: StaticBody3D asteroids/rocks/trees
	
	# SIGNAL: Fire when we overlap a physics body
	body_entered.connect(_on_body_entered)
	set_process(true)

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed > LIFETIME:
		queue_free()
		return
	
	# ADVANCE: Move the bolt forward along the direction it was fired
	global_position += direction * SPEED * delta

func _on_body_entered(body: Node) -> void:
	# Try to find a destroyable target. Allow asteroids and any tagged Destructible
	var destructible = false
	if body is StaticBody3D: destructible = true
	if body.is_in_group("Destructible"): destructible = true
	if body.is_in_group("Player"): return # NEVER destroy the player
	
	if destructible:
		_trigger_explosion(body)
		body.queue_free()
	
	queue_free()

func _trigger_explosion(at_node: Node) -> void:
	var explosion_script = load("res://src/combat/ExplosionFX.gd")
	if not explosion_script: return
	
	var fx = Node3D.new()
	fx.set_script(explosion_script)
	
	# Spawn explosion at the impact position in the scene root
	get_tree().root.add_child(fx)
	fx.global_position = at_node.global_position
	
	# Scale explosion relative to the target's size for proportional destruction!
	var size_hint = at_node.scale.length()
	fx.set("explosion_scale", clamp(size_hint, 1.0, 80.0))

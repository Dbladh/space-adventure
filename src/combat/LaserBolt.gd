
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

# SHARED MATERIAL — first laser fired after launch was paying a Metal pipeline
# compile (unshaded + emission variant), which compounded with the thruster
# stalls on iOS.  Cache it across all bolts so the GPU PSO stays hot.
static var _shared_bolt_mat: StandardMaterial3D = null

func _ready() -> void:
	# BUILD THE LASER ROD GEOMETRY PROCEDURALLY
	# ACE: Increased thickness (3.5) for high-frequency retro-visibility
	mesh_node = MeshInstance3D.new()
	var rod = CapsuleMesh.new()
	rod.radius = 3.5
	rod.height = 120.0
	mesh_node.mesh = rod
	mesh_node.rotation_degrees.x = 90.0 # Align the rod along the forward axis (Z)

	# GLOWING NEON MATERIAL — shared across all bolts to keep the pipeline hot.
	if _shared_bolt_mat == null:
		_shared_bolt_mat = StandardMaterial3D.new()
		_shared_bolt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_shared_bolt_mat.emission_enabled = true
		_shared_bolt_mat.emission = Color(1.0, 0.4, 0.1) # FIERY ORANGE-RED
		_shared_bolt_mat.emission_energy_multiplier = 14.0 # CRANKED for Retro clarity
	mesh_node.material_override = _shared_bolt_mat
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

func _process(_delta: float) -> void:
	elapsed += _delta
	if elapsed > LIFETIME:
		queue_free()
		return
	
	# ACE: AUTONOMOUS MOVEMENT DISABLED
	# Movement is now managed by the ship's projectile pool to support 
	# relativistic physics and homing logic without competing vectors.

func _on_body_entered(body: Node) -> void:
	# Try to find a destroyable target. Allow asteroids and any tagged Destructible
	var destructible = false
	if body is StaticBody3D: destructible = true
	if body.is_in_group("Destructible"): destructible = true
	if body.is_in_group("Player"): return # NEVER destroy the player
	
	# ACE PROJECTILE LOGIC: Priority on group 'Mineable' for absolute loot collection
	var target = body
	if not (target.is_in_group("Mineable") or target.has_method("take_damage")):
		if target.get_parent() and (target.get_parent().is_in_group("Mineable") or target.get_parent().has_method("take_damage")):
			target = target.get_parent()
	
	if target.is_in_group("Mineable") or target.has_method("take_damage"):
		target.take_damage(1.0)
		_trigger_explosion(body)
		queue_free()
		return
		
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

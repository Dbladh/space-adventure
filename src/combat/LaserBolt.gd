
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
	# Layer 1 = WORLD/asteroids, Layer 6 = SurfacePropProxy combat bodies (legacy),
	# Layer 3 = MineableResource. Without these bits the bolt's body_entered path
	# is dead for scatter; only Player.gd's auxiliary raycast registered hits.
	collision_mask = (1 << 0) | (1 << 2) | (1 << 5)
	
	# SIGNAL: Fire when we overlap a physics body.
	# body_shape_entered carries the body_shape_index, which the new
	# PlanetSurfaceStreamer cell bodies use to route damage to the right
	# prop slot (one CollisionShape3D per scatter prop).  body_entered is
	# still connected for legacy mineable nodes (asteroids, MineableResource)
	# that own a single shape and a take_damage method — body_shape_entered
	# would fire for those too, but body_entered keeps the existing path
	# unchanged during the migration.
	body_shape_entered.connect(_on_body_shape_entered)
	body_entered.connect(_on_body_entered)
	# Track bodies whose damage we already routed via body_shape_entered so
	# the body_entered path doesn't double-hit them (body_shape_entered
	# always fires before body_entered for the same overlap).
	set_meta("_handled_bodies", {})
	set_process(true)

func _process(_delta: float) -> void:
	elapsed += _delta
	if elapsed > LIFETIME:
		queue_free()
		return
	
	# ACE: AUTONOMOUS MOVEMENT DISABLED
	# Movement is now managed by the ship's projectile pool to support 
	# relativistic physics and homing logic without competing vectors.

func _on_body_shape_entered(_body_rid: RID, body: Node, body_shape_index: int, _local_shape_index: int) -> void:
	# Streamer-owned cell bodies route damage per-shape so a single big body
	# can hold many destructible props.  apply_damage_to_shape returns 0=miss
	# (bolt passes through), 1=wounded, 2=killed.  Either non-zero result
	# explodes + despawns the bolt and marks this body as handled to
	# suppress the body_entered signal that always fires alongside.
	if body == null or not is_instance_valid(body):
		return
	if not body.has_method("apply_damage_to_shape"):
		return
	if body.is_in_group("Player"):
		return
	var result: int = int(body.call("apply_damage_to_shape", body_shape_index, 1.0))
	if result == 0:
		return
	var handled: Dictionary = get_meta("_handled_bodies", {})
	handled[body.get_instance_id()] = true
	set_meta("_handled_bodies", handled)
	_trigger_explosion(body)
	queue_free()

func _on_body_entered(body: Node) -> void:
	if body == null or not is_instance_valid(body):
		return
	# If body_shape_entered already routed this hit, don't double-fire.
	var handled: Dictionary = get_meta("_handled_bodies", {})
	if handled.has(body.get_instance_id()):
		return
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
		var atk_mul: float = 1.0
		if Engine.has_meta("UpgradeManager"):
			atk_mul = Engine.get_meta("UpgradeManager").get_attack_multiplier()
		target.take_damage(1.0 * atk_mul)
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

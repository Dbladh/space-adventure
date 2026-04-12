extends CharacterBody3D

# NPCEnemy.gd
# PILOT ADVERSARY: Crimson Starhawk Interceptor
# Managed by THE ARCHITECT (Physics) and THE GUNSMITH (Armaments).

@onready var health = $HealthComponent
var player: Node3D = null
var hp_bar: MeshInstance3D

# SHIP SPECS: Advanced Accessibility Mode (Dampened)
var max_speed: float = 1200.0
var rotation_speed: float = 0.20
var roll_speed: float = 0.15
var acceleration: float = 0.10

# WEAPONRY: Pilot-Tier Cannons
var fire_cooldown: float = 0.0
var bolt_script: Script = null
var live_bolts: Array = []

# AI DYNAMICS
var current_yaw: float = 0.0
var current_pitch: float = 0.0
var current_thrust: float = 0.0
var _v_tick: int = 0

func _ready():
	add_to_group("Targets")
	add_to_group("Enemies")
	
	# PRELOAD ARMAMENTS
	bolt_script = load("res://src/combat/LaserBolt.gd")
	
	# WORLD-SPACE SYNC: Starhawk High-Fidelity Geometry
	var path = "res://assets/models/player/ship/Meshy_AI_Starhawk_01_0331051011_texture.glb"
	if FileAccess.file_exists(path):
		var scene = load(path)
		if scene:
			var model = scene.instantiate()
			add_child(model)
			model.scale = Vector3(100, 100, 100) # Match Player Scale
			model.rotate_object_local(Vector3.UP, deg_to_rad(-90))
			
			# Health Component Hook
	health.health_changed.connect(_on_health_changed)
	health.health_depleted.connect(_die)
	
	# PHYSICAL BOUNDARIES: Provision a hull for raycast impacts
	var coll = CollisionShape3D.new()
	var ss = SphereShape3D.new(); ss.radius = 80.0
	coll.shape = ss
	add_child(coll)
	
	# HP BAR (Billboard)
	_setup_hp_bar()
	
	# FIND PLAYER: Cache for intercept vectors
	var p_nodes = get_tree().get_nodes_in_group("Player")
	if p_nodes: player = p_nodes[0]

func _setup_hp_bar():
	hp_bar = MeshInstance3D.new()
	var qm = QuadMesh.new(); qm.size = Vector2(100, 15)
	hp_bar.mesh = qm
	hp_bar.position = Vector3(0, 80, 0)
	var hp_mat = StandardMaterial3D.new()
	hp_mat.billboard_mode = StandardMaterial3D.BILLBOARD_ENABLED; hp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hp_mat.albedo_color = Color(1, 0, 0); hp_bar.material_override = hp_mat
	add_child(hp_bar)

func _physics_process(delta):
	if not player or not is_instance_valid(player): return
	
	# AI PILOT: Calculate Intercept Vectors
	var rel_to_player = player.global_position - global_position
	var dist = rel_to_player.length()
	var dir = rel_to_player.normalized()
	
	# ACE PERFORMANCE: Celestial Hibernation (Beyond 150km)
	# Distant AI stops processing but remains visible for Radar/DOT
	if dist > 150000.0: return 
	
	# ACE STEERING: Converge on target
	var fwd = -global_transform.basis.z
	var dot_fwd = fwd.dot(dir)
	var right = global_transform.basis.x
	var dot_right = right.dot(dir)
	var up = global_transform.basis.y
	var dot_up = up.dot(dir)
	
	# Simulated Inputs (Yaw/Pitch)
	current_yaw = lerp(current_yaw, dot_right * 2.0, 4.0 * delta)
	current_pitch = lerp(current_pitch, dot_up * 2.0, 4.0 * delta)
	
	# Apply Physical Rotation
	rotate(basis.x.normalized(), current_pitch * rotation_speed * delta)
	rotate(basis.y.normalized(), -current_yaw * rotation_speed * delta)
	
	# THRUST LOGIC
	if dist > 3000.0:
		current_thrust = lerp(current_thrust, 1.0, 0.5 * delta)
	elif dist < 1200.0:
		current_thrust = lerp(current_thrust, 0.0, 2.0 * delta) # Braking for orbit
	else:
		current_thrust = lerp(current_thrust, 0.5, 0.5 * delta)
	
	# ACE KINEMATICS: Vector Sync (Snappier weight for 30FPS stability)
	var target_vel = -global_transform.basis.z * max_speed * current_thrust
	velocity = velocity.lerp(target_vel, 6.0 * delta)
	
	# SHADOWGLASS 8FPS SYNC: Snap visuals for NPCs
	var v_t = int(Time.get_ticks_msec() / 125.0)
	var v_update = v_t != _v_tick
	if v_update:
		_v_tick = v_t
		# Only update model transform on 8Hz ticks
		for child in get_children():
			if child is Node3D and not child is CollisionShape3D:
				child.global_transform = global_transform
				if "Starhawk" in child.name:
					child.rotate_object_local(Vector3.UP, deg_to_rad(-90))
	
	move_and_slide()
	
	# GUNFIRE SYNC: Engage player if in sights
	if fire_cooldown > 0: fire_cooldown -= delta
	elif dot_fwd > 0.95 and dist < 15000.0:
		_enemy_fire()
		fire_cooldown = 0.5 # 2 shots per second (Balanced for accessible combat)
	
	# BOLT POOL SYNC
	_process_enemy_bolts(delta)
	
	# VISUAL HP SYNC
	var hp_perc = health.current_health / health.max_health
	if hp_bar:
		hp_bar.scale.x = hp_perc
		hp_bar.material_override.albedo_color = Color(1-hp_perc, hp_perc, 0)

func _enemy_fire():
	if not bolt_script: return
	var bolt = Area3D.new(); bolt.set_script(bolt_script)
	get_parent().add_child(bolt)
	bolt.global_position = global_position - global_transform.basis.z * 100.0
	bolt.global_rotation = global_rotation
	bolt.set("bolt_color", Color(1, 0, 0))
	
	# ACE POOL: Synchronize with high-fidelity physical profile
	var data = {
		"node": bolt,
		"dir": -global_transform.basis.z.normalized(),
		"ship_v": velocity, # Inherit physical momentum
		"life": 0.0
	}
	live_bolts.append(data)

func _process_enemy_bolts(delta):
	var space_state = get_world_3d().direct_space_state
	var i = live_bolts.size() - 1
	while i >= 0:
		var b = live_bolts[i]
		var node = b["node"]
		b["life"] += delta
		
		if b["life"] > 1.5 or not is_instance_valid(node):
			if is_instance_valid(node): node.queue_free()
			live_bolts.remove_at(i)
			i -= 1; continue
			
		# KINEMATICS: Match Player velocity ramp (9k to 35k)
		var accel_t = clamp(b["life"] / 0.6, 0.0, 1.0)
		var speed = lerp(9000.0, 35000.0, accel_t * accel_t)
		var move_dist = (b["dir"] * speed + b["ship_v"]) * delta
		var next_pos = node.global_position + move_dist
		
		# IMPACT PHYSICS
		var query = PhysicsRayQueryParameters3D.create(node.global_position, next_pos)
		query.collision_mask = 1 | 2; query.exclude = [self]
		var result = space_state.intersect_ray(query)
		
		if result:
			_apply_bolt_impact(result.collider, result.position)
			node.queue_free(); live_bolts.remove_at(i)
		else:
			node.global_position = next_pos
		i -= 1

func _apply_bolt_impact(target, pos):
	var hp = target.get_node_or_null("HealthComponent")
	var is_dying = false
	if hp:
		is_dying = (hp.current_health <= 25.0)
		hp.take_damage(25.0)

	# ACE: VISUAL FEEDBACK SYNC (Hit Spark vs Destruction Nova)
	var fx_script = load("res://src/combat/ExplosionFX.gd")
	if fx_script:
		var fx = Node3D.new(); fx.set_script(fx_script)
		
		# HULL WELDING: sparks follow the target
		if not is_dying and is_instance_valid(target):
			target.add_child(fx)
			fx.global_position = pos
		else:
			get_tree().root.add_child(fx)
			fx.global_position = pos

		var sz = 8.0
		if is_dying: 
			sz = target.scale.x * 16.0 # Match Asteroid Body Size
			if target.is_in_group("Enemies") or target.is_in_group("Player"): sz = 600.0
		fx.set("explosion_scale", sz)

	# Damage Sync
	if target.is_in_group("Player"):
		if target.has_method("take_damage"): target.take_damage(5.0)
	elif not hp and target is CollisionObject3D:
		target.queue_free()

func _on_health_changed(new_hp):
	# DYNAMIC HP REACTION (Visual feedback)
	var hp_perc = new_hp / health.max_health
	if hp_bar:
		hp_bar.scale.x = hp_perc
		hp_bar.material_override.albedo_color = Color(1-hp_perc, hp_perc, 0)

func _die():
	# ACE: TITANIC NOVA - 6x Bigger Destruction Payload
	var fx_script = load("res://src/combat/ExplosionFX.gd")
	if fx_script:
		var fx = Node3D.new()
		fx.set_script(fx_script)
		get_tree().root.add_child(fx)
		fx.global_position = global_position
		fx.set("explosion_scale", 600.0) # Massive cinematic Nova
	
	queue_free()

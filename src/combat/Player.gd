
extends CharacterBody3D

# Player.gd (Celestial Final-Sync Edition)
# Managed by THE ARCHITECT.

@export var max_space_speed: float = 12000.0 
@export var max_warp_speed: float = 65000.0 
@export var rotation_speed: float = 2.8 
@export var roll_speed: float = 2.0 
@export var acceleration: float = 0.9 

var camera: Camera3D
var ship_model: Node3D
var target_planet: Node3D
var true_altitude: float = 300000.0
var mouse_locked: bool = true

var in_ship: bool = true
var parked_ship: Node3D = null
var coll_node: CollisionShape3D
var walk_yaw: float = 0.0
var jetpack_fuel: float = 100.0

# WEAPONS
var fire_cooldown: float = 0.0
const FIRE_RATE: float = 0.14
var bolt_script: GDScript = null
var _prev_fire_key: bool = false 
var _hb_tick: int = 0             
var live_bolts: Array = []  
var fire_side: int = 1      
var recoil_v: Vector3 = Vector3.ZERO
var turb_v: Vector3 = Vector3.ZERO
var reentry_v: Vector3 = Vector3.ZERO
var last_alt: float = 100000.0     # Atmospheric barrier detection
var reentry_timer: float = 0.0     # Sustained transition shake timer
var reentry_intensity: float = 0.0 
var heat_glow_mat: StandardMaterial3D = null
var reentry_vignette: ColorRect = null

# CAMERA PARAMS
var cam_base_offset := Vector3(0, 18.0, 85.0)
var cam_orbit := Vector2.ZERO 
var cam_orbit_sensitivity := 2.5
var cam_pivot: Node3D
var cam_spring: SpringArm3D
var thruster_trails: Array = []
var heat_soak: float = 0.0      # Engine thermal saturation
var shard_timer: float = 0.0    # Plasma debris ejection interval

func _ready() -> void:
	self.add_to_group("Player")
	lock_mouse()
	
	# 0. PRELOAD WEAPONS SCRIPT
	# Load once at startup, not every fire event
	bolt_script = load("res://src/combat/LaserBolt.gd")
	if bolt_script: print("--- GUNSMITH: LaserBolt loaded OK ---")
	else: print("!!! GUNSMITH ERROR: Cannot find res://src/combat/LaserBolt.gd !!!")
	
	# 0. PHYSICAL BOUNDARIES: X-Wing Class Hardening (64m Radius)
	coll_node = CollisionShape3D.new()
	var shape = SphereShape3D.new()
	shape.radius = 64.0 
	coll_node.shape = shape
	add_child(coll_node)
	self.collision_layer = 2 # THE SHIP
	self.collision_mask = 1 | 4 # World + Sun/Others
	coll_node.shape = shape
	add_child(coll_node)
	
	# 1. ACE CAMERA PIPELINE
	_setup_ace_camera()
	
	# 2. MOUNT STARHAWK
	_setup_starhawk_hull()

func _setup_ace_camera() -> void:
	# 360 ORBIT CAMERA STACK
	cam_pivot = Node3D.new()
	add_child(cam_pivot)
	
	cam_spring = SpringArm3D.new()
	cam_pivot.add_child(cam_spring)
	cam_spring.spring_length = 250.0
	cam_spring.position.y = 10.0 # Vertical lift for better ship profile
	cam_spring.collision_mask = 1 # ACE COCKPIT HARDENING: Ignores ship hull (Layer 2)
	cam_spring.margin = 3.5 # Huge buffer against external terrain
	
	camera = Camera3D.new()
	cam_spring.add_child(camera)
	camera.position = Vector3.ZERO # Parented to SpringArm, stays at pivot
	camera.near = 12.0 # ACE COCKPIT HARDENING: Provides clearance for upscaled Starhawk hull
	camera.far = 3500000.0 # 3,500km Baseline
	camera.make_current()
	
	# INITIALIZE 5 THRUSTER TRAILS (Aft-Docked Cluster: Perfect Depth 0.75)
	var trail_script = load("res://src/combat/ThrusterTrail.gd")
	var ports = [
		Vector3(0.85, -0.16, 0.0),       # Center Hub (Stern Axis +Docked)
		Vector3(0.83, -0.08, -0.3),     # Upper Left
		Vector3(0.83, -0.08, 0.3),      # Upper Right
		Vector3(0.80, -0.25, -0.28),    # Lower Left
		Vector3(0.80, -0.25, 0.28)      # Lower Right
	]
	for p in ports:
		# 1. THE TRAIL
		var t = MeshInstance3D.new()
		t.set_script(trail_script)
		t.set("trail_width", 9.5 if p.z == 0 else 6.0) # Scaled 3x for X-Wing Proportions
		add_child(t)
		thruster_trails.append({"node": t, "offset": p})
		
		# 2. THE NOZZLE ORB (Ace Volumetric 3D Orb)
		var glow = MeshInstance3D.new()
		var sm = SphereMesh.new(); sm.radius = 1.0; sm.height = 2.0
		# Increase subdivisions to purge the 'Lego-block' cluster noise
		sm.radial_segments = 32; sm.rings = 16 
		glow.mesh = sm; glow.name = "EngineGlow"
		
		# FRESNEL PLASMA SHADER: Crisp, Illustrated volumetric orb
		var glow_mat = ShaderMaterial.new()
		glow_mat.shader = load("res://src/shaders/thruster_nozzle.gdshader")
		glow.material_override = glow_mat
		add_child(glow)
		
		# 3. THE LIGHT SOURCE (Physical OmniLight)
		var light = OmniLight3D.new()
		light.name = "EngineLight"
		light.light_color = Color.RED
		light.light_energy = 0.0 # Dynamics handled in _process
		light.omni_range = 25.0
		light.light_specular = 0.0 # ACE CLUSTER PURGE: Prevents blocky specular squares on ground
		light.omni_attenuation = 2.4 # Steeper falloff hides cluster-grid boundaries
		add_child(light)
		
		t.set_meta("glow_node", glow)
		t.set_meta("light_node", light)

func _setup_starhawk_hull() -> void:
	var path = "res://assets/models/player/ship/Meshy_AI_Starhawk_01_0331051011_texture.glb"
	if FileAccess.file_exists(path):
		var scene = load(path)
		if scene:
			ship_model = scene.instantiate()
			add_child(ship_model)
			_apply_toon_shading(ship_model) # ACE UNIVERSAL SYNC
			ship_model.scale = Vector3(100.0, 100.0, 100.0) 
			ship_model.rotation_degrees = Vector3(0, -90, 0)
			
			# REENTRY HUD VFX: Create the screen-space heat vignette
			var hud = CanvasLayer.new(); hud.layer = 50; add_child(hud)
			reentry_vignette = ColorRect.new(); reentry_vignette.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			var mat = ShaderMaterial.new(); mat.shader = load("res://src/world/reentry_vignette.gdshader")
			reentry_vignette.material = mat
			hud.add_child(reentry_vignette)
			
			print("--- PILOT: CELESTIAL SYNC COMPLETE (Hull Ready) ---")

func _apply_toon_shading(node: Node) -> void:
	# EXCLUSION: Skip engine glows and VFX to prevent black square outlines on plasma
	if "Glow" in node.name or "VFX" in node.name: return
	
	if node is MeshInstance3D:
		var mat = node.mesh.surface_get_material(0)
		if mat is StandardMaterial3D:
			# ACE UNIVERSAL SYNC: 3-Tier Cel-Shading across all hull surfaces
			var cel_mat = ShaderMaterial.new()
			cel_mat.shader = load("res://src/shaders/hatch_toon.gdshader")
			
			# Pass through original texture if present
			if mat.albedo_texture:
				cel_mat.set_shader_parameter("albedo_tex", mat.albedo_texture)
				
			# SCREEN-SPACE OUTLINE: Add outline pass
			var outline = ShaderMaterial.new()
			outline.shader = load("res://src/shaders/outline.gdshader")
			outline.set_shader_parameter("outline_width", 1.2) # High-Fidelity silhouette
			outline.set_shader_parameter("outline_color", Color.BLACK)
			
			cel_mat.next_pass = outline
			node.set_surface_override_material(0, cel_mat)
	for child in node.get_children():
		_apply_toon_shading(child)

func _physics_process(delta: float) -> void:
	# HEARTBEAT: Prints every 120 physics frames (~4s) to confirm script is alive
	_hb_tick += 1
	if _hb_tick >= 120:
		_hb_tick = 0
		print("[PLAYER HB] in_ship:", in_ship, " fire_cd:", fire_cooldown)
	
	# FIRE INPUT: Rising-edge poll — fires once per key-press, immune to event routing
	fire_cooldown -= delta
	var cur_fire = Input.is_key_pressed(KEY_F)
	if cur_fire and not _prev_fire_key and in_ship and fire_cooldown <= 0.0:
		_fire_alternating_cannon()
	_prev_fire_key = cur_fire
	
	# CONTROLLER: Poll Y button with same rising-edge approach
	var cur_joy_fire = Input.is_joy_button_pressed(0, JOY_BUTTON_Y)
	if cur_joy_fire and in_ship and fire_cooldown <= 0.0:
		_fire_alternating_cannon()
	
	# Continuously evaluate multi-planetary proximity to lock onto the closest orbit!
	var planets = get_tree().get_nodes_in_group("Planet")
	if planets.size() > 0:
		var closest = planets[0]
		var shortest = global_position.distance_to(closest.global_position) - closest.get("planet_radius")
		for i in range(1, planets.size()):
			var p = planets[i]
			var dist = global_position.distance_to(p.global_position) - p.get("planet_radius")
			if dist < shortest:
				shortest = dist
				closest = p
		target_planet = closest
	
	if in_ship:
		_process_ace_flight(delta)
	else:
		_process_on_foot(delta)

func _process_on_foot(delta: float) -> void:
	if not target_planet: return
	
	# Gravity! Since planet is a sphere, gravity pulls us directly to target_planet.global_position
	var grav_dir = (target_planet.global_position - global_position).normalized()
	velocity += grav_dir * 115.0 * delta
	
	# Align basis Y dynamically to the procedural curve of the surface!
	var current_z = global_transform.basis.z
	var target_y = -grav_dir
	var target_x = target_y.cross(current_z).normalized()
	if target_x.length() < 0.1: target_x = target_y.cross(Vector3.FORWARD).normalized()
	var target_z = target_x.cross(target_y).normalized()
	
	global_transform.basis = global_transform.basis.slerp(Basis(target_x, target_y, target_z), 25.0 * delta)
	
	# CITIZEN-PILOT: Full Orbit Camera Sync (Joy & Mouse)
	# Applies both Yaw/Pitch to allow looking up/down while on-foot
	var rs_x = Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	var rs_y = Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if abs(rs_x) > 0.1: cam_orbit.x -= rs_x * cam_orbit_sensitivity * delta * 2.5
	if abs(rs_y) > 0.1: cam_orbit.y -= rs_y * cam_orbit_sensitivity * delta * 2.5
	cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2)
	
	if cam_pivot:
		cam_pivot.rotation.y = lerp_angle(cam_pivot.rotation.y, cam_orbit.x, 25.0 * delta)
		cam_pivot.rotation.x = lerp_angle(cam_pivot.rotation.x, cam_orbit.y, 25.0 * delta)
	
	# Close-Up 3rd Person follow (5m) vs Space-Epic (250m)
	cam_spring.spring_length = lerp(cam_spring.spring_length, 5.0, 5.0 * delta)
	# 1.85m human eye-level height while walking planet-side
	cam_spring.position.y = lerp(cam_spring.position.y, 1.85, 5.0 * delta)
	
	# Move WASD/Gamepad — apply deadzone before use!
	# Raw joystick axes report tiny non-zero values even at rest (stick drift).
	# Without a deadzone, normalized() turns any drift into full-speed movement.
	const JOY_DEAD: float = 0.15
	var move_x = Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	var move_z = Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	if abs(move_x) < JOY_DEAD: move_x = 0.0
	if abs(move_z) < JOY_DEAD: move_z = 0.0
	if Input.is_key_pressed(KEY_A): move_x = -1.0
	if Input.is_key_pressed(KEY_D): move_x = 1.0
	if Input.is_key_pressed(KEY_W): move_z = -1.0
	if Input.is_key_pressed(KEY_S): move_z = 1.0
	
	up_direction = -grav_dir
	var trigger_jump = Input.is_key_pressed(KEY_SPACE) or Input.is_joy_button_pressed(0, JOY_BUTTON_A)
	if is_on_floor():
		jetpack_fuel = min(jetpack_fuel + 80.0 * delta, 100.0) # Fast recharge on ground
		if trigger_jump: velocity -= grav_dir * 60.0 # Vertical jump against heavy gravity!
	else:
		if trigger_jump and jetpack_fuel > 0.0:
			jetpack_fuel -= 45.0 * delta
			# Jetpack thrust completely nullifies heavy gravity AND pushes up!
			var jet_accel = 210.0 # Overcomes the 115.0 procedural gravity pull
			velocity -= grav_dir * jet_accel * delta
		
	# ACE CONTROL ALIGNMENT: Movement is now relative to the camera view
	# Pushing 'W' moves us toward whatever we are looking at!
	var cam_forward = cam_pivot.global_transform.basis.z
	var cam_right = cam_pivot.global_transform.basis.x
	
	# Project onto the local tangent plane (orthogonal to gravity)
	var walk_dir = (cam_right * move_x) + (cam_forward * move_z)
	var tangent_dir = walk_dir.slide(grav_dir).normalized()
	
	# Scale speed by actual input length
	var input_mag = clamp(Vector2(move_x, move_z).length(), 0.0, 1.0)
	var sideway_vel = (tangent_dir if input_mag > 0.01 else Vector3.ZERO) * input_mag * 110.0
	
	var vertical_vel = velocity.project(grav_dir)
	
	# PHYSICS CLAMP: Terminal Velocity
	# Actively prevents the player from falling fast enough to tunnel entirely through 
	# single-sided procedural terrain chunks during high-framerate engine dips!
	var fall_speed = vertical_vel.length() * sign(vertical_vel.dot(grav_dir))
	if fall_speed > 250.0:
		vertical_vel = grav_dir * 250.0
		
	velocity = vertical_vel + sideway_vel
	
	move_and_slide()

func _process_ace_flight(delta: float) -> void:
	var yaw = -Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	var pitch = Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	
	if Input.is_key_pressed(KEY_A): yaw = 1.0
	if Input.is_key_pressed(KEY_D): yaw = -1.0
	if Input.is_key_pressed(KEY_W): pitch = 1.0 
	if Input.is_key_pressed(KEY_S): pitch = -1.0
	
	rotate(basis.x.normalized(), pitch * rotation_speed * delta)
	rotate(basis.y.normalized(), yaw * rotation_speed * delta)
	
	var roll_input: float = 0.0
	if Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_SHOULDER): roll_input += 1.0
	if Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER): roll_input -= 1.0
	rotate(basis.z.normalized(), roll_input * roll_speed * delta)
	
	# ADAPTIVE ANALOG INPUT: Proportional control for precise docking/maneuvering
	var raw_thrust = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) # R2 = Gas
	var raw_reverse = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT) # L2 = Brake
	
	# Apply deadzone and precision curve (more control at low speeds)
	raw_thrust = pow(clamp((raw_thrust - 0.05) / 0.95, 0.0, 1.0), 1.8)
	raw_reverse = pow(clamp((raw_reverse - 0.05) / 0.95, 0.0, 1.0), 1.8)
	var is_warping = Input.is_joy_button_pressed(0, JOY_BUTTON_A) or Input.is_key_pressed(KEY_SHIFT)
	
	var thrust_mapped = max(raw_thrust, 1.0 if Input.is_key_pressed(KEY_SPACE) else 0.0)
	var reverse_mapped = max(raw_reverse, 1.0 if Input.is_key_pressed(KEY_Q) else 0.0)

	if target_planet:
		var raw_dist = global_position.distance_to(target_planet.global_position)
		true_altitude = raw_dist - target_planet.get("planet_radius") 
	
	# ATMOSPHERIC BARRIER CROSSING: Sync with 26km Exosphere Boundary
	const BARRIER_ALT: float = 26000.0
	if (last_alt > BARRIER_ALT and true_altitude <= BARRIER_ALT) or (last_alt < BARRIER_ALT and true_altitude >= BARRIER_ALT):
		reentry_timer = 3.0 # Duration
		reentry_intensity = 4.5
	last_alt = true_altitude
	
	# FLIGHT PHYSICS RATIO: Optimized for reentry braking (10km-26km)
	var altitude_ratio = smoothstep(10000.0, 26000.0, true_altitude)
	
	# TURBULENCE RATIO: Grass-skimming ONLY (peaks at 150m, clears at 800m)
	var turb_altitude_ratio = smoothstep(150.0, 800.0, true_altitude)
	
	var dynamic_max_speed = lerp(800.0, max_space_speed, altitude_ratio)
	var dynamic_warp_speed = lerp(3500.0, max_warp_speed, altitude_ratio)
	
	var s_val = dynamic_warp_speed if is_warping else dynamic_max_speed
	var target_vel = -global_transform.basis.z * s_val * thrust_mapped
	
	if reverse_mapped > 0.1:
		target_vel = global_transform.basis.z * dynamic_max_speed * 0.4 * reverse_mapped
		
	# ATMOSPHERIC DRAG: Aggressive deceleration during exosphere penetration (26km cutoff)
	if is_warping and true_altitude < 26000.0:
		var drag = 1.0 - altitude_ratio
		velocity = velocity.lerp(target_vel, (2.8 + drag * 8.0) * delta)
	else:
		velocity = velocity.lerp(target_vel, 2.8 * delta)
	
	# DYNAMIC FOV
	if camera:
		var speed_perc = velocity.length() / max_warp_speed
		var target_fov = 75.0 + (speed_perc * 30.0) 
		camera.fov = lerp(camera.fov, target_fov, 4.0 * delta)
		
	# ATMOSPHERIC TURBULENCE: Extremely subtle jitter, grass-skimming ONLY
	var turb_intensity = (1.0 - turb_altitude_ratio) * (velocity.length() / 2500.0)
	if turb_intensity > 0.05:
		turb_v = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * turb_intensity * 0.08
	else:
		turb_v = turb_v.lerp(Vector3.ZERO, 3.0 * delta)
	
	# ORBIT CAMERA ROTATION (Right Stick)
	var rs_x = Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
	var rs_y = Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if abs(rs_x) > 0.1: cam_orbit.x -= rs_x * cam_orbit_sensitivity * delta * 2.0
	if abs(rs_y) > 0.1: cam_orbit.y -= rs_y * cam_orbit_sensitivity * delta * 2.0
	cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2) # Limit pitch to avoid gimbal lock flip
	
	if cam_pivot:
		cam_pivot.rotation.y = lerp_angle(cam_pivot.rotation.y, cam_orbit.x, 15.0 * delta)
		cam_pivot.rotation.x = lerp_angle(cam_pivot.rotation.x, cam_orbit.y, 15.0 * delta)
	
	move_and_slide()
	
	# UPDATE THRUSTER TRAILS (Sync after physical move to prevent high-velocity lag)
	# At 64km/s, even a single frame of lag causes a 1km visual gap.
	# Using the ship_model.global_transform ensures we catch the 25x model-space offsets.
	if ship_model:
		for t in thruster_trails:
			var world_pos = ship_model.global_transform * t.offset
			t.node.update_trail(world_pos, velocity, is_warping, thrust_mapped, delta)
			
			# SYNC DYNAMIC NOZZLE ORB (Sphere core + Physical OmniLight)
			if t.node.has_meta("glow_node"):
				var glow = t.node.get_meta("glow_node")
				var light = t.node.get_meta("light_node")
				var power = clamp(thrust_mapped + reverse_mapped, 0.0, 1.0)
				
				# Local-Space Welding: Prevents 'teleporting' during origin shifts
				# We transform the model-space offset into ship-local space (handling scale)
				var local_pos = ship_model.transform * t.offset
				glow.position = local_pos
				light.position = local_pos
				
				# Engine Heat Soak: Sustained thrust shifts red -> white-hot
				heat_soak = lerp(heat_soak, thrust_mapped, delta * 0.1) # Slow buildup
				var heat_c = Color.RED.lerp(Color(1.0, 0.8, 0.6), heat_soak * 0.8)
				
				glow.visible = power > 0.03
				light.visible = power > 0.03
				
				# CINEMATIC IGNITION: Narrowed-radius isolation purges distant asteroid tinting
				var flicker = 1.0 + (randf() * 0.15)
				glow.scale = Vector3.ONE * (power * 7.2 * flicker)
				light.omni_range = 60.0 # Narrowed to isolate to ship and ground
				light.omni_attenuation = 2.5 # Steepened to ensure zero-reach to distant debris
				light.light_energy = power * 2.5 * flicker # Balanced for cinematic radiance
				light.light_color = heat_c
				
				# Update Shader parameter for high-fidelity radial pulse
				glow.material_override.set_shader_parameter("glow_color", heat_c)
				glow.material_override.set_shader_parameter("power", power * flicker)
				
				# PLASMA SHARD EJECTION: Pop tiny debris during heavy thrust
				if thrust_mapped > 0.75 and shard_timer <= 0:
					_spawn_plasma_shard(world_pos)
		
		# Pulse timing logic
		if shard_timer > 0:
			shard_timer -= delta
			
		if thrust_mapped > 0.75 and shard_timer <= 0:
			shard_timer = 0.15 # 150ms pulse
	
	# REFLECTIVE BOUNCE PHYSICS: Prevent ground clipping
	if get_slide_collision_count() > 0:
		var coll = get_last_slide_collision()
		if coll:
			var n = coll.get_normal()
			if n.dot(velocity.normalized()) < -0.1: # Significant impact
				var impact_force = velocity.length()
				velocity = velocity.bounce(n) * 0.6 # 60% energy retention
				reentry_intensity += impact_force * 0.05
	
	# 5. VISUAL HULL DYNAMICS
	# Simulates physical G-Forces forcing the Starhawk to bank and pitch violently during maneuvers
	if ship_model:
		var target_bank = yaw * 18.0 # Biting into the turn (Roll left/right)
		var target_pitch_visual = (thrust_mapped * 6.0) - (reverse_mapped * 6.0) # Nose shifts up/down
		
		# Because the model is baseline-rotated -90.0 on Y, X becomes local Roll and Z becomes local Pitch!
		var target_hull_euler = Vector3(target_bank, -90.0, target_pitch_visual)
		
		# KINEMATIC BANKING: Re-synchronized for -90.0 Y Euler system
		var raw_yaw = -Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
		var raw_pitch = Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
		if Input.is_key_pressed(KEY_A): raw_yaw = 1.0
		if Input.is_key_pressed(KEY_D): raw_yaw = -1.0
		if Input.is_key_pressed(KEY_W): raw_pitch = 1.0
		if Input.is_key_pressed(KEY_S): raw_pitch = -1.0
		
		var bank_deg = raw_yaw * 28.0
		var dip_deg = -raw_pitch * 8.0
		
		# Combine with baseline -90 Y rotation
		var t_rot = Vector3(bank_deg, -90.0, dip_deg)
		ship_model.rotation_degrees = ship_model.rotation_degrees.lerp(t_rot, 4.0 * delta)
		
		# HOVER IDLE ANIMATION
		var speed_ratio = clamp(velocity.length() / 200.0, 0.0, 1.0)
		var hover_bob = sin(Time.get_ticks_msec() * 0.0015) * 1.5 * (1.0 - speed_ratio)
		ship_model.position.y = lerp(ship_model.position.y, hover_bob, 5.0 * delta)

func _fire_alternating_cannon() -> void:
	fire_cooldown = FIRE_RATE
	
	var fire_dir = -global_transform.basis.z.normalized()
	var wing_r = global_transform.basis.y.normalized() # Relative to ship rotated -90
	var wing_up = global_transform.basis.x.normalized()
	var main_scene = get_parent()
	if not main_scene: return
	
	var side = float(fire_side)
	fire_side *= -1
	
	# Turret Offset relative to ship orientation: Focused Central Fire
	# Turret Offset relative to ship orientation: X-Wing Wing-Tip Spread
	var local_x_off = 32.0 * side
	var turret_pos = global_position + (fire_dir * 60.0) + (wing_up * local_x_off)
	
	# RECOIL & MUZZLE FLASH: Tick-feedback
	recoil_v += (global_transform.basis.z * 0.45) + (global_transform.basis.x * -side * 0.15)
	_spawn_muzzle_flash(turret_pos, fire_dir)
	
	# BUILD BOLT: Lean 1.8m energy spear
	var bolt = MeshInstance3D.new()
	var capsule = CapsuleMesh.new()
	capsule.radius = 1.8   # Refined Bolt
	capsule.height = 200.0 # Long Streak
	bolt.mesh = capsule
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.2, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.9, 1.0)
	mat.emission_energy_multiplier = 14.0
	mat.disable_fog = true
	bolt.material_override = mat
	
	bolt.rotation = global_transform.basis.get_rotation_quaternion().get_euler()
	bolt.rotate_object_local(Vector3.RIGHT, PI / 2.0)
	
	main_scene.add_child(bolt)
	# SPAN OFFSET: Now 60m ahead
	bolt.global_position = turret_pos + (fire_dir * 45.0)
	
	# Projectile Momentum Inheritance: Ensures bolts don't spawn behind at high ship speeds
	live_bolts.append({"node": bolt, "dir": fire_dir, "life": 0.0, "ship_v": velocity})

func _spawn_muzzle_flash(pos: Vector3, _dir: Vector3) -> void:
	# POINT LIGHT FLASH: Replaced mesh with high-energy point light for true "light flash" look
	var flash = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.95, 0.7) # Bright Warm Flash
	flash.omni_range = 45.0 # Illuminates ship wings/hull
	flash.light_energy = 15.0 # Intense blink
	flash.light_specular = 2.0
	get_parent().add_child(flash)
	flash.global_position = pos
	
	var t = get_tree().create_timer(0.04)
	t.timeout.connect(func(): if is_instance_valid(flash): flash.queue_free())

# LEGACY CAMERA SYSTEM DELETED FOR ALPHA-ORBIT STABILITY

func _input(event: InputEvent) -> void:
	# ESC: Toggle mouse lock
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		if mouse_locked: unlock_mouse()
		else: lock_mouse()
	
	# KEYBOARD FIRE: F key (single press, no hold repeat)
	if event is InputEventKey and event.keycode == KEY_F and event.pressed and not event.echo:
		print("--- GUNSMITH: F KEY DETECTED --- in_ship:", in_ship, " cooldown:", fire_cooldown)
		if in_ship and fire_cooldown <= 0.0:
			_fire_alternating_cannon()
	
	# ORBIT CAMERA: Mouse Look
	if event is InputEventMouseMotion and mouse_locked and in_ship:
		cam_orbit.x -= event.relative.x * 0.005
		cam_orbit.y -= event.relative.y * 0.005
		cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2)
	
	# CONTROLLER FIRE: Triangle (PS) / Y (Xbox)
	if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_Y and event.pressed:
		print("--- GUNSMITH: Y BUTTON DETECTED --- in_ship:", in_ship)
		if in_ship and fire_cooldown <= 0.0:
			_fire_alternating_cannon()
		
	# E: Embark / Disembark
	if event is InputEventKey and event.keycode == KEY_E and event.pressed:
		if in_ship and true_altitude < 500.0: _disembark()
		elif not in_ship and parked_ship and global_position.distance_to(parked_ship.global_position) < 80.0: _embark()
		
	# MOUSE LOOK
	if event is InputEventMouseMotion and mouse_locked:
		if in_ship:
			cam_orbit.x -= event.relative.x * 0.005
			cam_orbit.y -= event.relative.y * 0.005
		else:
			walk_yaw -= event.relative.x * 0.005
			cam_orbit.y -= event.relative.y * 0.005

func _process(delta: float) -> void:
	# RECOIL & TURBULENCE & REENTRY SHAKE
	recoil_v = recoil_v.lerp(Vector3.ZERO, 12.0 * delta)
	
	reentry_v = Vector3.ZERO
	if reentry_timer > 0.0:
		reentry_timer -= delta
		var intensity = (reentry_timer / 3.0) * reentry_intensity
		reentry_v = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * intensity
		
		# VISUAL HEAT GLOW: Animate hull emission based on shake/speed
		if heat_glow_mat:
			var speed_mod = clamp(velocity.length() / 8000.0, 0.5, 2.0)
			var heat = (reentry_timer / 3.0) * speed_mod
			heat_glow_mat.emission_enabled = heat > 0.05
			heat_glow_mat.emission = Color(1.0, 0.3 * heat, 0.0) # From Bright Orange to Deep Red
			heat_glow_mat.emission_energy_multiplier = heat * 12.0
		
		# RED HEAT VIGNETTE: Sync screen filter with exosphere friction (18km-26km window)
		if reentry_vignette:
			var reentry_heat = (reentry_timer / 3.0)
			
			# BELL CURVE: Heat peaks at the transition midpoint and clears at surface/space
			var raw_dist = clamp((true_altitude - 18000.0) / (26000.0 - 18000.0), 0.0, 1.0)
			var alt_heat = 1.0 - abs(raw_dist - 0.5) * 2.0 
			alt_heat = clamp(alt_heat, 0.0, 1.0)
			
			reentry_vignette.material.set_shader_parameter("intensity", max(reentry_heat, alt_heat))
			
		# AERO-VORTEX TRAILS: Spawn condensation streaks during reentry
		if _hb_tick % 2 == 0: 
			var wing_up = global_transform.basis.x.normalized()
			var fire_dir = -global_transform.basis.z.normalized()
			var heat_val = (reentry_timer / 3.0)
			var s_length = clamp(velocity.length() * 0.02, 40.0, 200.0)
			for side in [-1.0, 1.0]:
				var jitter = Vector3(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5), randf_range(-0.5, 0.5)) * reentry_intensity
				_spawn_vortex_trail(global_position + (wing_up * 14.0 * side) + jitter, fire_dir, heat_val, s_length)
	
	# CAMERA DYNAMICS: Recoil & Reentry Shake (Ship-only Visual Sync)
	# Snap the camera pivot in _process to align with visual 'leaning' and 'banking'
	var cam_base_y = 10.0 if in_ship else 1.85
	if cam_spring: cam_spring.position = Vector3(0, cam_base_y, 0) + recoil_v + turb_v + reentry_v
	
	# BOLT POOL UPDATE: High-Velocity Physics (Direct-Space intersect_ray)
	const BOLT_SPEED: float = 2500.0
	const BOLT_LIFETIME: float = 3.0
	var space_state = get_world_3d().direct_space_state
	
	var i = live_bolts.size() - 1
	while i >= 0:
		var b = live_bolts[i]
		b["life"] += delta
		if b["life"] > BOLT_LIFETIME:
			b["node"].queue_free(); live_bolts.remove_at(i); i -= 1; continue
		
		var node = b["node"]
		var old_pos = node.global_position
		var move_dist = (b["dir"] * BOLT_SPEED + b["ship_v"]) * delta
		var next_pos = old_pos + move_dist
		
		# SWEPT-FRAME PHYSICS: Direct raycast from old to new position
		var query = PhysicsRayQueryParameters3D.create(old_pos, next_pos)
		query.collision_mask = 1 | 2 # Rocks and Ships
		query.exclude = [self] # Hardened: Prevents self-collision at high-recoil fire
		var result = space_state.intersect_ray(query)
		
		if result and is_instance_valid(result.collider):
			var target = result.collider
			# CENTRIC TRIGGER: Spawn at the target center rather than the surface hit point
			_trigger_explosion_inline(target.global_position, target, result.normal)
			
			if target is CollisionObject3D:
				target.set_deferred("collision_layer", 0); target.set_deferred("collision_mask", 0)
				for child in target.get_children(): if child is VisualInstance3D: child.hide()
				get_tree().create_timer(0.12).timeout.connect(func(): if is_instance_valid(target): target.queue_free())
			
			node.queue_free(); live_bolts.remove_at(i)
		else:
			node.global_position = next_pos
		i -= 1

func _trigger_explosion_inline(pos: Vector3, target: Node, normal: Vector3) -> void:
	_spawn_impact_flash(pos, normal)
	_spawn_scorch_mark(pos, target, normal)
	
	var explosion_script = load("res://src/combat/ExplosionFX.gd")
	if not explosion_script: return
	var fx = Node3D.new()
	fx.set_script(explosion_script)
	get_parent().add_child(fx)
	fx.global_position = pos
	var sz = 15.0 # High-Floor for combat tactile feedback
	if target is Node3D:
		# RADIAL MASS MULTIPLIER: Account for the asteroid's 17.0m base diameter
		# Multiplier set to 2.2x to ensure the fireball mass 'envelops' the rock
		sz = target.scale.x * 17.0 * 2.2
	# VOLUMETRIC CAP: Boosted to 1600.0m for titan-class planetary bodies.
	fx.set("explosion_scale", clamp(sz, 15.0, 1600.0))

func _spawn_scorch_mark(pos: Vector3, target: Node, normal: Vector3) -> void:
	# BORDERLINE: If the asteroid is deleted, the mark is useless. 
	# However, for ships/planets, this provides the 'stellar history' requested.
	if not is_instance_valid(target) or target.is_queued_for_deletion(): return
	
	var decal = Decal.new()
	decal.size = Vector3(25.0, 25.0, 25.0) # Variable footprint
	decal.set_modulate(Color(0.1, 0.1, 0.1, 0.8)) # Deep Charcoal #1A1A1A
	decal.albedo_mix = 0.9
	target.add_child(decal)
	decal.global_position = pos
	
	# Align with surface normal
	if normal.length() > 0.1:
		var target_vec = pos + normal
		if pos.is_equal_approx(target_vec): target_vec = pos + Vector3.UP
		decal.look_at(target_vec)
		decal.rotate_object_local(Vector3.RIGHT, PI/2.0)
	
	# Procedural Fade: Melt into the hull/rock
	var t = get_tree().create_tween()
	t.tween_interval(1.5)
	t.tween_property(decal, "modulate:a", 0.0, 0.5)
	t.tween_callback(decal.queue_free)

func _spawn_impact_flash(pos: Vector3, normal: Vector3) -> void:
	# Offset away from surface to prevent Z-Fighting occlusion
	var spawn_pos = pos + (normal * 2.5)
	
	# 1. OPTICAL BLOOM: Pure white geosphere that only lasts 0.08s
	var mi = MeshInstance3D.new()
	var sm = SphereMesh.new(); sm.radius = 12.0; sm.height = 24.0 # Increased size for visibility
	sm.radial_segments = 8; sm.rings = 4 # Faceted Retro
	mi.mesh = sm
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.WHITE
	mi.material_override = mat
	get_parent().add_child(mi)
	mi.global_position = spawn_pos
	
	# 2. LOCAL ILLUMINATION: OmniLight to light up nearby asteroids
	var light = OmniLight3D.new()
	light.light_color = Color.WHITE
	light.light_energy = 45.0 # Doubled intensity
	light.omni_range = 150.0
	mi.add_child(light)
	
	# 3. KINETIC ANIMATION: Quick pop and vanish
	var t = get_tree().create_tween()
	t.tween_property(mi, "scale", Vector3.ONE * 6.0, 0.03)
	t.parallel().tween_property(light, "light_energy", 0.0, 0.06)
	t.tween_property(mi, "scale", Vector3.ZERO, 0.03)
	t.tween_callback(mi.queue_free)

func _spawn_vortex_trail(pos: Vector3, dir: Vector3, heat: float, s_len: float) -> void:
	if s_len < 0.1 or dir.length() < 0.01: return
	
	var trail = MeshInstance3D.new()
	var cap = CapsuleMesh.new()
	cap.radius = 0.3 + (clamp(heat, 0.0, 1.0) * 0.4)
	cap.height = s_len
	cap.radial_segments = 8; cap.rings = 2 # Low-poly optimization
	trail.mesh = cap
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = StandardMaterial3D.BLEND_MODE_ADD
	
	# Ionized Tint: Shifts from white to orange as heat increases (clamped to prevent pink NaN errors)
	var h = clamp(heat, 0.0, 1.0)
	var c_r = 1.0; var c_g = clamp(1.0 - (h * 0.4), 0.0, 1.0); var c_b = clamp(1.0 - (h * 0.8), 0.0, 1.0)
	mat.albedo_color = Color(c_r, c_g, c_b, clamp(0.3 + (h * 0.2), 0.0, 1.0))
	
	trail.material_override = mat
	get_parent().add_child(trail)
	
	# Position and orient correctly (Safe look_at)
	trail.global_position = pos - (dir * (s_len * 0.5))
	if (pos - trail.global_position).length() > 0.1:
		trail.look_at(pos)
	
	var t = get_tree().create_timer(0.12)
	t.timeout.connect(func(): if is_instance_valid(trail): trail.queue_free())
			
func _disembark() -> void:
	in_ship = false
	velocity = Vector3.ZERO
	cam_orbit.x = 0; cam_orbit.y = 0
	if ship_model: ship_model.hide()
	
	# Manifest an empty decoy hull exactly where we step out!
	var path = "res://assets/models/player/ship/Meshy_AI_Starhawk_01_0331051011_texture.glb"
	if FileAccess.file_exists(path):
		var scene = load(path)
		if scene:
			parked_ship = scene.instantiate()
			get_parent().add_child(parked_ship)
			parked_ship.global_transform = global_transform
			parked_ship.scale = Vector3(25.0, 25.0, 25.0)
			parked_ship.rotation_degrees.y -= 90.0
			
	if coll_node: coll_node.shape.radius = 8.0

func _embark() -> void:
	in_ship = true
	cam_orbit.x = 0; cam_orbit.y = 0
	velocity = Vector3.ZERO
	if ship_model: ship_model.show()
	if parked_ship: 
		# We must restore POSITION and ROTATION, but absolutely strip the SCALE! 
		# If the 25x scale leaks to the parent body, movement vectors become 25x faster!
		var st_tf = parked_ship.global_transform
		st_tf = st_tf.rotated_local(Vector3.UP, deg_to_rad(90.0)) # Un-rotate visual offset
		global_position = st_tf.origin
		global_transform.basis = st_tf.basis.orthonormalized() # Strip the scale matrix!
		parked_ship.queue_free(); parked_ship = null
	if coll_node: coll_node.shape.radius = 16.0

func lock_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	mouse_locked = true

func unlock_mouse() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	mouse_locked = false

func _spawn_plasma_shard(pos: Vector3) -> void:
	var shard = MeshInstance3D.new()
	var bm = BoxMesh.new()
	var s = randf_range(0.1, 0.4)
	bm.size = Vector3(s, s, s)
	shard.mesh = bm
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.RED
	mat.emission_enabled = true
	mat.emission = Color.RED
	mat.emission_energy_multiplier = 4.0
	shard.material_override = mat
	
	# Add to world-space and sync with Floating Origin
	get_parent().add_child(shard)
	shard.add_to_group("World")
	shard.global_position = pos
	
	# Debris lifetime: fly back and vanish (Local-Space Stable)
	var tween = create_tween()
	var local_fly_target = shard.position - global_transform.basis.z * 15.0 + Vector3(randf()-0.5, randf()-0.5, randf()-0.5) * 5.0
	tween.tween_property(shard, "position", local_fly_target, 0.4)
	tween.parallel().tween_property(shard, "scale", Vector3.ZERO, 0.4)
	tween.tween_callback(shard.queue_free)

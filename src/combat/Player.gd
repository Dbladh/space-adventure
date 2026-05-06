extends CharacterBody3D

# Player.gd (Celestial Final-Sync Edition)
# Managed by THE ARCHITECT.

@export var max_space_speed: float = 35000.0
@export var max_warp_speed: float = 250000.0
@export var max_hyperdrive_speed: float = 1000000.0 # L1+R1 — Hyperdrive tier, ~4× warp
@export var surface_max_speed: float = 280.0
@export var surface_warp_speed: float = 1800.0
@export var max_deep_space_warp_speed: float = 4000000.0
# DEEP-SPACE CRUISE: when true_altitude is well past the gravity-brake boundary the
# warp cap auto-scales up so inter-planet hops take seconds instead of minutes.
# 600 km/s peak → 8M-unit hop ≈ 13 s, 16M ≈ 27 s. Tune via _deep_space_warp_lerp().
@export var rotation_speed: float = 2.8
@export var roll_speed: float = 2.0
@export var acceleration: float = 0.9

var camera: Camera3D
var ship_model: Node3D
var _cached_cel_mat: ShaderMaterial = null
var target_planet: Node3D
var true_altitude: float = 300000.0
var mouse_locked: bool = true

# MOBILE SIMPLIFIED INPUT
var mobile_throttle: float = 0.5 # ACE: 0.5 is Neutral (Stopped)
var mobile_fire: bool = false
var mobile_boost: bool = false   # ACE: Mobile warp/pulse-drive button
var mobile_brake: bool = false   # ACE: Mobile brake — hard deceleration + throttle → neutral
var mobile_interact: bool = false
var mobile_throttle_dragging: bool = false
var _mobile_roll_l: bool = false # ◀ ROLL held (continuous +1 roll while down)
var _mobile_roll_r: bool = false # ROLL ▶ held (continuous -1 roll while down)
var mobile_gyro_paused: bool = false # ACE: UI toggle — pauses gyro steering entirely
var mobile_sens_mult: float = 1.0    # ACE: UI-driven sensitivity multiplier on top of gyro_sensitivity
var mobile_ui_ref: Control = null    # ACE: back-reference so Player can push telemetry to the HUD
var _mobile_look_touch_idx: int = -1
var _mobile_look_last_pos: Vector2 = Vector2.ZERO

# GYRO STEERING (Star Fox Style)
@export var gyro_enabled: bool = true
@export var gyro_sensitivity: float = 1.9 # ACE: Lowered for absolute gravity stability
var _gyro_neutral_z: float = 0.0 # ACE Calibration
var _is_calibrated: bool = false

var in_ship: bool = true
var parked_ship: Node3D = null
var coll_node: CollisionShape3D
var walk_yaw: float = 0.0
var jetpack_fuel: float = 100.0
var health_component: HealthComponent = null
var flash_tween: Tween = null
var is_dead: bool = false
var health_bar_bg: ColorRect = null
var health_bar_fill: ColorRect = null

# WEAPONS
var fire_cooldown: float = 0.0
const FIRE_RATE: float = 0.09 # ACE STARFOX CADENCE: Faster, snappier pulse
var bolt_script: GDScript = null
var _prev_fire_key: bool = false 
var _hb_tick: int = 0             
var live_bolts: Array = []  
var fire_side: int = 1      
var recoil_v: Vector3 = Vector3.ZERO
var turb_v: Vector3 = Vector3.ZERO
var reentry_v: Vector3 = Vector3.ZERO
var shake_v: Vector3 = Vector3.ZERO
var shake_intensity: float = 0.0
var last_alt: float = 100000.0     # Atmospheric barrier detection
var reentry_timer: float = 0.0     # Sustained transition shake timer
var reentry_intensity: float = 0.0 
var _last_trail_pos: Vector3 = Vector3.ZERO
var heat_glow_mat: StandardMaterial3D = null
var reentry_vignette: ColorRect = null
var _v_tick_30_p: int = 0 # 30Hz ticker for physics-based visuals
var _v_tick_30_v: int = 0 # 30Hz ticker for process-based visuals
var _radar_tick: int = 0 # ACE RADAR THROTTLE
var _v_tick_8: int = 0  # 8Hz visual ticker for stop-motion environment sync

# CAMERA PARAMS
var cam_base_offset := Vector3(0, 18.0, 85.0)
var cam_orbit := Vector2.ZERO 
var cam_orbit_sensitivity := 1.2
var cam_pivot: Node3D
var cam_spring: SpringArm3D
var thruster_trails: Array = []
var heat_soak: float = 0.0      # Engine thermal saturation
var shard_timer: float = 0.0    # Plasma debris ejection interval

# SHARED VFX MATERIAL — created once on first plasma-shard spawn so subsequent
# spawns don't pay a Metal pipeline-compile stall on mobile.  LaserBolt.gd has
# its own static cache for the same reason.
static var _shared_shard_mat: StandardMaterial3D = null
var _atmo_heading: Vector3 = Vector3.FORWARD
var _was_in_atmo: bool = false

var last_tap_l: float = 0.0
var last_tap_r: float = 0.0
var barrel_roll_t: float = 0.0  # Animation progress 0.0 to 1.0
var barrel_roll_dir: float = 0.0 # 1.0 = CCW (Left), -1.0 = CW (Right)
var ship_marker: MeshInstance3D = null
var hud_reticle: Control = null
var ship_nose_offset: float = -0.05
var lock_on_target: Node3D = null
var pinned_target: Node3D = null
var hud_scan_lock: Control = null
var hud_hard_lock: Control = null
var hud_target_lead: Control = null
var hud_threat_arrows: Array = []
var snow_particles: CPUParticles3D = null
var _cur_aim_point: Vector3 = Vector3.ZERO
var auto_lock_enabled: bool = true # Auto-lock targets on mobile/when firing

# MOBILE PERF: cached once at _ready so hot paths don't call OS.get_name() every frame.
var _mobile_perf: bool = false
# POOLED RAY QUERY: create() allocates + sets defaults every call. Reuse one
# query object per frame and just reassign its fields.
var _ray_q: PhysicsRayQueryParameters3D = null
var _proxy_ray_q: PhysicsRayQueryParameters3D = null  # proxy-only, ignores terrain
# THROTTLE COUNTERS for mobile budget pacing
var _thruster_tick: int = 0
var _terrain_floor_tick: int = 0
var _terrain_floor_cached: float = 0.0
var _last_flash_ms: int = 0


func _ready() -> void:
	self.add_to_group("Player")
	_mobile_perf = OS.get_name() == "iOS" or OS.get_name() == "Android" or OS.has_feature("mobile")
	_ray_q = PhysicsRayQueryParameters3D.new()
	_ray_q.collision_mask = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 5) # Layer 1,2,3,4,6
	_ray_q.exclude = [self]
	_proxy_ray_q = PhysicsRayQueryParameters3D.new()
	_proxy_ray_q.collision_mask = (1 << 2) | (1 << 5) # ACE: Prioritize Minerals (Layer 3) and Proxies (Layer 6)
	_proxy_ray_q.exclude = [self]
	lock_mouse()
	
	# COMPASS HARDENING: 3D arrow pointing back to ship
	ship_marker = MeshInstance3D.new()
	var pm = PrismMesh.new(); pm.size = Vector3(2.5, 5.0, 1.0); ship_marker.mesh = pm
	var m_c = StandardMaterial3D.new(); m_c.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED; m_c.albedo_color = Color.RED; ship_marker.material_override = m_c
	add_child(ship_marker); ship_marker.hide()
	ship_marker.position = Vector3(0, 22.0, -10.0) # Floating ahead of player
	
	
	# 0. PRELOAD WEAPONS SCRIPT
	# Load once at startup, not every fire event
	bolt_script = load("res://src/combat/LaserBolt.gd")
	if bolt_script: print("--- GUNSMITH: LaserBolt loaded OK ---")
	# ACE TITAN SYNC: Block player until Universe is Ready
	set_physics_process(false)
	set_process(false)
	
	# 0. PHYSICAL BOUNDARIES: Starhawk-Class (6m Hull Radius)
	coll_node = CollisionShape3D.new()
	var shape = SphereShape3D.new(); shape.radius = 6.0 
	coll_node.shape = shape
	add_child(coll_node)
	self.collision_layer = 2 # THE SHIP
	# Layer 1: World, 4: Mineable, 8: Space Station
	self.collision_mask = 1 | 4 | 8 
	
	# COMBAT HARDENING: Player Health Tracking
	health_component = HealthComponent.new(); health_component.max_health = 1000.0
	add_child(health_component)
	health_component.damaged.connect(func(amt): _trigger_hit_flash(0.85))
	health_component.health_depleted.connect(_on_player_death)
	
	_setup_player_hud() # Vitality Visuals
	
	# 1. ACE CAMERA PIPELINE
	_setup_ace_camera()
	_setup_polar_weather()
	
	# 2. MOUNT STARHAWK
	_setup_starhawk_hull()
	
	# TEST: SPAWN NPC ENEMY FOR ENGAGEMENT
	get_tree().create_timer(1.0).timeout.connect(func():
		var enemy_scene = load("res://src/combat/NPCEnemy.gd")
		var health_scene = load("res://src/combat/HealthComponent.gd")
		if enemy_scene:
			var npc = CharacterBody3D.new()
			npc.set_script(enemy_scene)
			var hc = Node.new()
			hc.set_script(health_scene)
			hc.set("max_health", 400.0) # ACE DURABILITY: 400 HP
			hc.name = "HealthComponent"
			npc.add_child(hc)
			# WORLD-SPACE SYNC: Parent to WorldRoot for stable Floating Origin shifts
			var wr = get_tree().get_first_node_in_group("WorldRoot")
			if wr: wr.add_child(npc)
			else: get_parent().add_child(npc)
			
			npc.global_position = global_position - global_transform.basis.z * 1500.0 # Just ahead
	)


func _setup_ace_camera() -> void:
	# 360 ORBIT CAMERA STACK
	cam_pivot = Node3D.new()
	add_child(cam_pivot)
	cam_pivot.top_level = true # DECOUPLE: Prevents ship-rotation 'Jerking'
	
	cam_spring = SpringArm3D.new()
	cam_pivot.add_child(cam_spring)
	cam_spring.spring_length = 250.0
	cam_spring.position.y = 10.0 # Vertical lift for better ship profile
	cam_spring.collision_mask = 1 # Hits World Terrain (1)
	cam_spring.margin = 3.5 
	
	camera = Camera3D.new()
	cam_spring.add_child(camera)
	camera.position = Vector3.ZERO 
	camera.near = 12.0 
	camera.far = 150000000.0 # ASTROMETRY: 150,000,000m far-clip to safely encompass the 90Mkm galaxy scale.
	camera.make_current()
	
	_setup_combat_hud()
	_setup_thruster_trails()

func _setup_combat_hud() -> void:
	var hud = CanvasLayer.new(); hud.name = "CombatHUD"; hud.layer = 125
	hud.add_to_group("GameHUD")
	add_child(hud)
	
	# ACE VISOR: Create a high-fidelity dynamic targeting circle
	hud_reticle = Control.new()
	hud_reticle.name = "Reticle"
	hud_reticle.custom_minimum_size = Vector2(128, 128) # Larger canvas for anti-aliased arcs
	hud_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_reticle.set_script(load("res://src/combat/ReticleUI.gd"))
	hud.add_child(hud_reticle)
	
	# ACE LOCK-ON: HUD target tracking diamond
	# ACE LOCK-ON: Dual-Stage visors
	hud_scan_lock = Control.new()
	hud_scan_lock.custom_minimum_size = Vector2(80, 80)
	hud_scan_lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_scan_lock.set_script(load("res://src/combat/TargetLockUI.gd"))
	hud.add_child(hud_scan_lock); hud_scan_lock.hide()
	
	hud_hard_lock = Control.new()
	hud_hard_lock.custom_minimum_size = Vector2(100, 100)
	hud_hard_lock.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_hard_lock.set_script(load("res://src/combat/TargetLockUI.gd"))
	hud.add_child(hud_hard_lock); hud_hard_lock.hide()
	hud_hard_lock.modulate = Color(1.0, 0.8, 0.1) # GOLD (Locked)
	
	# ACE: INTERCEPT LEAD RETICLE (Predictive solution)
	hud_target_lead = Control.new()
	hud_target_lead.custom_minimum_size = Vector2(40, 40)
	hud_target_lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud_target_lead.set_script(load("res://src/combat/TargetLockUI.gd"))
	hud.add_child(hud_target_lead); hud_target_lead.hide()
	hud_target_lead.modulate = Color(1.0, 0.5, 0.1) # ORANGE Lead
	
	# ACE: FLEET THREAT TRACKER (Pooled Arrows)
	for i in range(8):
		var arrow = Control.new()
		arrow.custom_minimum_size = Vector2(40, 40)
		arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
		arrow.set_script(load("res://src/combat/TargetLockUI.gd"))
		hud.add_child(arrow); arrow.hide()
	# ACE: MOBILE CONTROLS OVERLAY
	var mobile_ui_script = load("res://src/ui/MobileControlsUI.gd")
	if mobile_ui_script:
		var mc = Control.new()
		mc.set_script(mobile_ui_script)
		mc.mouse_filter = Control.MOUSE_FILTER_STOP
		hud.add_child(mc)
		mobile_ui_ref = mc
		mc.throttle_changed.connect(func(val): mobile_throttle = val)
		mc.throttle_dragging_changed.connect(func(active): mobile_throttle_dragging = active)
		mc.fire_pressed.connect(func(p): mobile_fire = p)
		mc.boost_pressed.connect(func(p): mobile_boost = p)
		mc.brake_pressed.connect(_on_mobile_brake)
		mc.roll_triggered.connect(func(dir): _trigger_barrel_roll(dir))
		mc.roll_held.connect(_on_mobile_roll_held)
		mc.sensitivity_changed.connect(func(v): mobile_sens_mult = v)
		mc.gyro_paused_changed.connect(func(paused): mobile_gyro_paused = paused)
		mc.recalibrate_pressed.connect(func(): _is_calibrated = false)
		mc.menu_pressed.connect(func(): if Main.instance: Main.instance.toggle_pause())

func _on_mobile_brake(pressed: bool) -> void:
	# BRAKE hold: zero out forward intent and request a rapid slow-down.
	# Also snap the mobile throttle UI back to neutral so release feels clean.
	mobile_brake = pressed
	if pressed:
		mobile_throttle = 0.5
		if mobile_ui_ref and mobile_ui_ref.has_method("force_throttle"):
			mobile_ui_ref.force_throttle(0.5)

func _on_mobile_roll_held(direction: float, pressed: bool) -> void:
	# Tracks each rotate button independently so simultaneous holds cancel cleanly.
	if direction > 0.5:
		_mobile_roll_l = pressed
	elif direction < -0.5:
		_mobile_roll_r = pressed





func _setup_thruster_trails() -> void:
	var trail_script = load("res://src/combat/ThrusterTrail.gd")
	var ports = [
		Vector3(0.85, -0.16, 0.0),       # Center Hub
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
		light.omni_range = 12.0 # Tight range - engine glow only, doesn't reach terrain/water
		light.light_specular = 0.0
		light.omni_attenuation = 3.0 # Very steep falloff - dies out before cluster tile boundaries
		light.shadow_enabled = false # No shadows needed - prevents square shadow map artifacts
		light.distance_fade_enabled = true
		light.distance_fade_begin = 30.0
		light.distance_fade_length = 10.0
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
			
			# ACE SHADER WARM-UP: Prevent 'First-Use' freeze during atmospheric entry
			mat.set_shader_parameter("intensity", 0.001)
			get_tree().create_timer(0.1).timeout.connect(func(): if is_instance_valid(mat): mat.set_shader_parameter("intensity", 0.0))
			
			# ACE HULL ANALYSIS: Dynamic nose detection
			var model_aabb = AABB()
			var aabb_init = false
			var nodes = [ship_model]
			while nodes.size() > 0:
				var n = nodes.pop_back()
				if n is MeshInstance3D:
					var a = n.get_mesh().get_aabb()
					if not aabb_init: model_aabb = a; aabb_init = true
					else: model_aabb = model_aabb.merge(a)
				nodes.append_array(n.get_children())
			
			# Identify which local axis of the upscaled model points FORWARD (-Z in parent space)
			var f_local = (ship_model.transform.basis.inverse() * Vector3(0, 0, -1)).normalized()
			if abs(f_local.x) > 0.8:
				ship_nose_offset = model_aabb.position.x if f_local.x < 0 else model_aabb.end.x
			elif abs(f_local.z) > 0.8:
				ship_nose_offset = model_aabb.position.z if f_local.z < 0 else model_aabb.end.z
			
			print("--- PILOT: HULL SCAN COMPLETE (Nose Axis: ", f_local, " Offset: ", ship_nose_offset, ") ---")



func _apply_toon_shading(node: Node) -> void:
	# EXCLUSION: Skip engine glows and VFX to prevent black square outlines on plasma
	if "Glow" in node.name or "VFX" in node.name: return
	
	if node is MeshInstance3D:
		var mat = node.mesh.surface_get_material(0)
		if mat is StandardMaterial3D:
			# ACE UNIVERSAL SYNC: Reuse cached materials to reduce draw-state changes
			if not _cached_cel_mat:
				_cached_cel_mat = ShaderMaterial.new()
				_cached_cel_mat.shader = load("res://src/shaders/hatch_toon.gdshader")
				
				# SCREEN-SPACE OUTLINE: Shared outline pass
				var outline = ShaderMaterial.new()
				outline.shader = load("res://src/shaders/outline.gdshader")
				outline.set_shader_parameter("outline_width", 1.2)
				outline.set_shader_parameter("outline_color", Color.BLACK)
				_cached_cel_mat.next_pass = outline
			
			var cel_mat = _cached_cel_mat.duplicate() # Duplicate for unique textures if needed
			# Pass through original texture
			if mat.albedo_texture:
				cel_mat.set_shader_parameter("albedo_tex", mat.albedo_texture)
			else:
				# ACE FALLBACK: Assign a procedural white texture so vertex colors shine through
				var white_tex = GradientTexture2D.new(); white_tex.width = 1; white_tex.height = 1
				cel_mat.set_shader_parameter("albedo_tex", white_tex)
				
			# SCREEN-SPACE OUTLINE: Add outline pass
			var outline = ShaderMaterial.new()
			outline.shader = load("res://src/shaders/outline.gdshader")
			outline.set_shader_parameter("outline_width", 1.2) # High-Fidelity silhouette
			outline.set_shader_parameter("outline_color", Color.BLACK)
			
			cel_mat.next_pass = outline
			node.set_surface_override_material(0, cel_mat)
	for child in node.get_children():
		_apply_toon_shading(child)

func _process_ace_camera(delta: float) -> void:
	if not cam_pivot or not camera: return
	
	# ACE: Master Camera Sync (Post-Physics)
	# This avoids frame-latency and ensures zero-separation at high velocities.
	cam_pivot.global_position = global_position
	var world_up = (global_position - target_planet.global_position).normalized() if target_planet else Vector3.UP
	var surface_assist: float = 0.0
	if target_planet:
		surface_assist = clamp(1.0 - (true_altitude / 9000.0), 0.0, 1.0)
	if cam_spring and surface_assist > 0.0:
		# On planet surface push the camera FURTHER back (250 → 420 m) and
		# slightly up, so the player can see the terrain + nearby mineable
		# resources properly instead of having the ship fill the screen.
		var target_spring_y: float = lerp(10.0, 16.0, surface_assist)
		var target_spring_len: float = lerp(250.0, 420.0, surface_assist)
		cam_spring.position.y = lerp(cam_spring.position.y, target_spring_y, 8.0 * delta)
		cam_spring.spring_length = lerp(cam_spring.spring_length, target_spring_len, 6.0 * delta)
	elif cam_spring:
		cam_spring.position.y = lerp(cam_spring.position.y, 10.0, 8.0 * delta)
		cam_spring.spring_length = lerp(cam_spring.spring_length, 250.0, 6.0 * delta)
	
	if is_instance_valid(pinned_target):
		var t_dir = (pinned_target.global_position - global_position).normalized()
		var s_fwd = -global_transform.basis.z
		var look_dir = s_fwd.lerp(t_dir, 0.35).normalized()
		var cam_q = Basis.looking_at(look_dir, world_up).get_rotation_quaternion()
		var orbit_q = Quaternion(Vector3.UP, cam_orbit.x) * Quaternion(Vector3.RIGHT, cam_orbit.y)
		cam_pivot.global_transform.basis = Basis(cam_q * orbit_q)
	else:
		var ship_q = global_transform.basis.get_rotation_quaternion()
		var orbit_q = Quaternion(Vector3.UP, cam_orbit.x) * Quaternion(Vector3.RIGHT, cam_orbit.y)
		var target_q = (ship_q * orbit_q).normalized()
		var current_q = cam_pivot.global_transform.basis.get_rotation_quaternion()
		cam_pivot.global_transform.basis = Basis(current_q.slerp(target_q, 15.0 * delta))

	# FOV SYNC
	var speed_val = velocity.length()
	var fov_scale = 70.0 # Baseline
	if speed_val > max_warp_speed:
		var t = clamp((speed_val - max_warp_speed) / (max_hyperdrive_speed - max_warp_speed), 0.0, 1.0)
		fov_scale = 92.0 + (t * 8.0)
	elif speed_val > max_space_speed:
		var t = clamp((speed_val - max_space_speed) / (max_warp_speed - max_space_speed), 0.0, 1.0)
		fov_scale = 82.0 + (t * 10.0)
	else:
		var t = clamp(speed_val / max_space_speed, 0.0, 1.0)
		fov_scale = 70.0 + (t * 12.0)
	camera.fov = lerp(camera.fov, fov_scale, 4.0 * delta)

	# HUD SYNC
	if health_bar_fill and health_component:
		var hp_p = health_component.current_health / health_component.max_health
		health_bar_fill.scale.x = hp_p
		health_bar_fill.color = Color.CRIMSON.lerp(Color.SPRING_GREEN, hp_p)

	# ACE KINETIC SHAKE: High-frequency jitter
	if shake_intensity > 0.01:
		shake_v = Vector3(randf_range(-1,1), randf_range(-1,1), randf_range(-1,1)) * shake_intensity * 0.5
		shake_intensity = lerp(shake_intensity, 0.0, 5.0 * delta)
	else:
		shake_v = Vector3.ZERO

func take_damage(amount: float) -> void:
	if is_dead: return
	if health_component: health_component.take_damage(amount)

func _setup_player_hud() -> void:
	var hud = CanvasLayer.new(); hud.layer = 125; add_child(hud)
	
	# ACE: Master Vitality Bar (Top Center)
	var bar_w = 400.0; var bar_h = 24.0
	health_bar_bg = ColorRect.new()
	health_bar_bg.color = Color(0.1, 0.1, 0.1, 0.8)
	health_bar_bg.custom_minimum_size = Vector2(bar_w, bar_h)
	health_bar_bg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	health_bar_bg.position.y = 96.0; health_bar_bg.position.x -= bar_w/2.0
	hud.add_child(health_bar_bg)
	
	health_bar_fill = ColorRect.new()
	health_bar_fill.color = Color.SPRING_GREEN
	health_bar_fill.custom_minimum_size = Vector2(bar_w - 4.0, bar_h - 4.0)
	health_bar_fill.position = Vector2(2, 2)
	health_bar_bg.add_child(health_bar_fill)

func _on_player_death() -> void:
	if is_dead: return
	is_dead = true
	print("!!! PILOT TERMINATED: SHIP K.I.A. !!!")
	
	if ship_model: ship_model.hide()
	
	# ACE: TITANIC EXPLOSION (1600m Radius)
	var fx_script = load("res://src/combat/ExplosionFX.gd")
	if fx_script:
		var fx = Node3D.new(); fx.set_script(fx_script)
		get_parent().add_child(fx)
		fx.global_position = global_position
		fx.set("explosion_scale", 1600.0)
	
	# CINEMATIC RESTART: 3s Orbital Orbit
	var t = get_tree().create_timer(4.0)
	t.timeout.connect(func(): get_tree().reload_current_scene())

func _trigger_hit_flash(intensity: float, color: Color = Color.CRIMSON, shake: bool = true) -> void:
	if not ship_model: return
	if flash_tween: flash_tween.kill()
	flash_tween = create_tween()
	
	# ACE: Get all materials that support the flash_intensity uniform
	var mats = []
	var nodes = [ship_model]
	while nodes.size() > 0:
		var n = nodes.pop_back()
		if n is MeshInstance3D:
			for i in range(n.get_mesh().get_surface_count()):
				var m = n.get_surface_override_material(i)
				if m is ShaderMaterial: mats.append(m)
		nodes.append_array(n.get_children())
	
	for m in mats: 
		m.set_shader_parameter("flash_intensity", intensity)
		m.set_shader_parameter("flash_color", color)
		
	if shake:
		shake_intensity += intensity * 12.0 # Impact Jitter
		
	flash_tween.tween_method(func(v): 
		for m in mats: m.set_shader_parameter("flash_intensity", v)
	, intensity, 0.0, 0.35).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)

func _physics_process(delta: float) -> void:
	if is_dead:
		# DEAD CAMERA: Slow cinematic orbit around the death spot
		cam_orbit.x += delta * 0.4
		_process_ace_camera(delta)
		return
		
	# HEARTBEAT: Prints every 120 physics frames (~4s) to confirm script is alive
	_hb_tick += 1
	if _hb_tick >= 120:
		_hb_tick = 0
		print("[PLAYER HB] in_ship:", in_ship, " fire_cd:", fire_cooldown)
	
	# FIRE HEARTBEAT: Tick-down combat timers
	fire_cooldown -= delta
	var cur_fire = Input.is_key_pressed(KEY_F) or mobile_fire
	var cur_joy_fire = Input.is_joy_button_pressed(0, JOY_BUTTON_Y)
	
	# PLANETARY PROXIMITY THROTTLE: Only scan for planets every 15 frames
	if _hb_tick % 15 == 0:
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
	if not _mobile_perf:
		var rs_x = Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
		var rs_y = Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		if abs(rs_x) > 0.1: cam_orbit.x -= rs_x * cam_orbit_sensitivity * delta * 2.5
		if abs(rs_y) > 0.1: cam_orbit.y -= rs_y * cam_orbit_sensitivity * delta * 2.5
	cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2)
	
	if cam_pivot:
		cam_pivot.rotation.y = lerp_angle(cam_pivot.rotation.y, cam_orbit.x, 25.0 * delta)
		cam_pivot.rotation.x = lerp_angle(cam_pivot.rotation.x, cam_orbit.y, 25.0 * delta)
	
	# COMPASS SYNC: Point Red Arrow back toward Starhawk
	if ship_marker and parked_ship:
		ship_marker.show()
		var dir_to_ship = (parked_ship.global_position - global_position).normalized()
		var t_xf = global_transform.looking_at(parked_ship.global_position, -grav_dir)
		ship_marker.global_transform.basis = t_xf.basis
		ship_marker.rotate_object_local(Vector3.RIGHT, -PI/2.0) # Align prism tip to forward
		# Local Bobbing
		ship_marker.position.y = 22.0 + sin(Time.get_ticks_msec() * 0.005) * 2.5
	
	# ACE SPRINT ENGINE: Right Trigger (R2) or Shift provides a 3.0x Titanic Burst
	var sprint_mapped = max(Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT), 1.0 if Input.is_key_pressed(KEY_SHIFT) else 0.0)
	var speed_mult = 1.0 + (sprint_mapped * 2.0)
	
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
	
	# Scale speed by actual input length (Titanic Speed Base: 450.0)
	var input_mag = clamp(Vector2(move_x, move_z).length(), 0.0, 1.0)
	var sideway_vel = (tangent_dir if input_mag > 0.01 else Vector3.ZERO) * input_mag * 450.0 * speed_mult
	
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
	# ACE DEADZONE HARDENING: Purges phantom rotation drift from stick-wear
	const FLY_DEAD = 0.15
	var yaw_stick = -Input.get_joy_axis(0, JOY_AXIS_LEFT_X)
	var pitch_stick = Input.get_joy_axis(0, JOY_AXIS_LEFT_Y)
	if abs(yaw_stick) < FLY_DEAD: yaw_stick = 0.0
	if abs(pitch_stick) < FLY_DEAD: pitch_stick = 0.0
	
	var yaw = yaw_stick
	var pitch = pitch_stick
	
	# MOTION STEERING: High-Authority Gravity Vector
	# ACE MOBILE V2: supports UI "GYRO OFF" pause and a sensitivity multiplier.
	# Curve: deadzone → normalized → pow(x, 1.6) so small tilts give fine trim
	# and larger tilts ramp up quickly (No Man's Sky-style joystick response).
	if gyro_enabled and not mobile_gyro_paused:
		var grav = Input.get_gravity()

		# ACE AUTO-CALIBRATION: Capture first stable reading as Neutral
		if not _is_calibrated and grav.length() > 1.0:
			_gyro_neutral_z = grav.z
			_is_calibrated = true

		# Deadzone (degrees of tilt that do nothing — now slightly wider)
		const TILT_DEAD = 1.4
		const TILT_FULL = 6.0 # Tilt magnitude at which we hit saturation
		var tx = grav.x if abs(grav.x) > TILT_DEAD else 0.0
		var tz_raw = grav.z - _gyro_neutral_z
		var tz = tz_raw if abs(tz_raw) > TILT_DEAD else 0.0

		# Map tilt magnitude to [-1, 1] with a power curve for finer control
		var nx = clamp(tx / TILT_FULL, -1.0, 1.0)
		var nz = clamp(-tz / TILT_FULL, -1.0, 1.0)
		var t_yaw = sign(nx) * pow(abs(nx), 1.6) * gyro_sensitivity * mobile_sens_mult
		var t_pitch = sign(nz) * pow(abs(nz), 1.6) * gyro_sensitivity * mobile_sens_mult

		yaw -= t_yaw
		pitch -= t_pitch

		# ACE: Force tilt as primary steering on ALL mobile devices when stick is idle
		if abs(yaw_stick) < 0.1 and abs(pitch_stick) < 0.1:
			yaw = clamp(-t_yaw, -1.5, 1.5)
			pitch = clamp(-t_pitch, -1.5, 1.5)

	if Input.is_key_pressed(KEY_A): yaw = 1.0
	if Input.is_key_pressed(KEY_D): yaw = -1.0
	if Input.is_key_pressed(KEY_W): pitch = 1.0 
	if Input.is_key_pressed(KEY_S): pitch = -1.0
	

	var roll_input: float = 0.0
	if Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_SHOULDER): roll_input += 1.0
	if Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER): roll_input -= 1.0
	# Mobile bottom-left rotate buttons: held → continuous roll, double-tap → barrel roll.
	if _mobile_roll_l: roll_input += 1.0
	if _mobile_roll_r: roll_input -= 1.0
	# CELESTIAL ROTATION TIERING (NMS-STYLE HORIZON LOCK)
	if target_planet:
		var raw_dist = global_position.distance_to(target_planet.global_position)
		true_altitude = raw_dist - target_planet.get("planet_radius")
	var is_in_atmo = target_planet and true_altitude < 26000.0
	var world_up = (global_position - target_planet.global_position).normalized() if target_planet else Vector3.UP
	var surface_assist: float = 0.0
	if target_planet:
		surface_assist = clamp(1.0 - (true_altitude / 9000.0), 0.0, 1.0)
	var is_surface_flight: bool = surface_assist > 0.0
	# ACE NMS FLIGHT: Full input authority in atmosphere. The old code damped pitch/yaw
	# and rebuilt the basis from a decoupled heading vector, which caused the ship to
	# visually lag its heading and enter sideways. We now steer the actual body basis
	# directly and let a roll-correction torque keep the horizon level.
	var steer_scale: float = lerp(1.0, 0.9, surface_assist)
	yaw *= steer_scale
	pitch *= lerp(1.0, 0.95, surface_assist)
	# ROLL AUTHORITY: L1/R1 should visibly tilt the ship in atmosphere. Scaling down
	# to 0.15 (old value) made the buttons feel broken — the auto-level torque snapped
	# the hull upright before the roll was visible. 0.65 gives clear banking input,
	# and the "user-active suppression" below keeps auto-level from fighting it.
	roll_input *= lerp(1.0, 0.65, surface_assist)

	# ATMOSPHERE MODE: Pitch/yaw/roll with full manual authority.
	# No entry snap, no auto-level — ship keeps whatever orientation it had in space.
	if is_in_atmo and barrel_roll_t <= 0.0:
		# 1. PITCH — around the ship's LOCAL right axis
		if abs(pitch) > 0.001:
			rotate(global_transform.basis.x.normalized(), pitch * rotation_speed * delta)

		# 2. YAW — around PLANET up so turns don't roll the ship
		if abs(yaw) > 0.001:
			rotate(world_up, yaw * rotation_speed * delta * 0.9)

		# 3. ROLL — manual only, no auto-level torque
		# Use +Z axis (same as space branch) so L/R buttons have consistent
		# chirality in and out of atmosphere.  The old -Z was a sign error that
		# reversed the roll direction whenever the ship entered an atmosphere.
		if abs(roll_input) > 0.001:
			rotate(global_transform.basis.z, roll_input * roll_speed * delta)

		# Cache forward for any downstream consumers that still read _atmo_heading
		_atmo_heading = (-global_transform.basis.z).normalized()
	elif not is_in_atmo:
		# SPACE: full three-axis Newtonian flight, no gravity alignment
		rotate(basis.x.normalized(), pitch * rotation_speed * delta)
		rotate(basis.y.normalized(), yaw * rotation_speed * delta)
		rotate(basis.z.normalized(), roll_input * roll_speed * delta)
	
	# PHYSICS HARDENING: Orthonormalize basis to prevent floating-point stretching
	# At massive scales, tiny precision errors in rotation accumulate into a 'Flipped Hull'.
	global_transform.basis = global_transform.basis.orthonormalized()
	
	# ADAPTIVE ANALOG INPUT: Proportional control for precise docking/maneuvering
	var raw_thrust = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_RIGHT) # R2 = Gas
	var raw_reverse = Input.get_joy_axis(0, JOY_AXIS_TRIGGER_LEFT) # L2 = Brake
	
	# Apply deadzone and precision curve (more control at low speeds)
	raw_thrust = pow(clamp((raw_thrust - 0.05) / 0.95, 0.0, 1.0), 1.8)
	raw_reverse = pow(clamp((raw_reverse - 0.05) / 0.95, 0.0, 1.0), 1.8)
	# BOOST/WARP: gamepad A, keyboard Shift, OR mobile BOOST button
	var is_warping: bool = Input.is_joy_button_pressed(0, JOY_BUTTON_A) or Input.is_key_pressed(KEY_SHIFT) or mobile_boost

	# HYPERDRIVE: L1 + R1 held together = 3rd thrust tier (5× warp)
	# L1 = JOY_BUTTON_LEFT_SHOULDER, R1 = JOY_BUTTON_RIGHT_SHOULDER
	var is_hyperdrive: bool = is_warping \
		and Input.is_joy_button_pressed(0, JOY_BUTTON_LEFT_SHOULDER) \
		and Input.is_joy_button_pressed(0, JOY_BUTTON_RIGHT_SHOULDER)
	
	var thrust_mapped = max(raw_thrust, 1.0 if Input.is_key_pressed(KEY_SPACE) else 0.0)
	var reverse_mapped = max(raw_reverse, 1.0 if Input.is_key_pressed(KEY_Q) else 0.0)

	# ACE: BI-DIRECTIONAL MOBILE THROTTLE (LATCHING)
	# 0.5 is Neutral. >0.5 is Forward. <0.5 is Reverse.
	# The throttle no longer auto-resets, so the pilot can cruise hands-free and
	# trim via gyro. BRAKE button forces the slider back to neutral on release.
	if mobile_throttle > 0.52:
		thrust_mapped = (mobile_throttle - 0.5) * 2.0
	elif mobile_throttle < 0.48:
		reverse_mapped = (0.5 - mobile_throttle) * 2.0

	# ACE MOBILE BRAKE: hold to override throttle with hard reverse assist.
	# This gives pilots a panic-stop that also disengages warp.
	if mobile_brake:
		thrust_mapped = 0.0
		reverse_mapped = max(reverse_mapped, 1.0)
		is_warping = false

	# BOOST AS PROPULSION: holding boost on mobile drives full-forward thrust even
	# if the latching throttle is sitting at neutral or reverse. Brake still wins.
	if mobile_boost and not mobile_brake:
		thrust_mapped = 1.0
		reverse_mapped = 0.0
	
	# ATMOSPHERIC BARRIER CROSSING: Sync with 26km Exosphere Boundary
	const BARRIER_ALT: float = 26000.0
	if (last_alt > BARRIER_ALT and true_altitude <= BARRIER_ALT) or (last_alt < BARRIER_ALT and true_altitude >= BARRIER_ALT):
		reentry_timer = 3.0 # Duration
		reentry_intensity = 4.5
	last_alt = true_altitude
	
	# FLIGHT PHYSICS RATIO: Optimized for reentry braking (Exosphere Transition)
	var altitude_ratio = smoothstep(12000.0, 35000.0, true_altitude)
	
	# SURFACE-DETAIL RATIO: Aggressive throttling for low-altitude cinematic stability (0m to 3500m)
	var surface_ratio = smoothstep(0.0, 3500.0, true_altitude)
	var turb_altitude_ratio = smoothstep(150.0, 800.0, true_altitude)
	
	# ORBITAL SAFETY OVERRIDE: Prioritize performance by throttling speed near planets
	# At 80km, the 'Gravity Brake' engages, forcing a bleed-off down to safe levels.
	var safety_ratio = smoothstep(26000.0, 80000.0, true_altitude)
	var gravity_brake_max = lerp(600.0, max_space_speed, safety_ratio)
	
	# ATMOSPHERIC SPEED DECELERATION: Tiered throttling for planetary exploration
	# Surface: ~180m/s | Exosphere: 480m/s | Space: gravity_brake_max
	var surface_max = lerp(180.0, 480.0, surface_ratio)
	var dynamic_max_speed = lerp(surface_max, gravity_brake_max, altitude_ratio)
	
	# Warp Thresholds: 450m/s (Surface) -> 2100m/s (Atmo) -> gravity_brake_max (Space)
	var surface_warp = lerp(450.0, 2100.0, surface_ratio)
	var dynamic_warp_speed = lerp(surface_warp, min(max_warp_speed, gravity_brake_max * 2.5), altitude_ratio)

	# DEEP-SPACE CRUISE: once we're well clear of the gravity well, ramp the warp
	# cap from max_warp_speed up to max_deep_space_warp_speed. Keeps planet-side
	# pacing identical (altitude_ratio dominates below ~80 km) while making
	# planet-to-planet travel a few-second hop instead of minutes.
	var deep_space_ratio = smoothstep(200000.0, 2500000.0, true_altitude)
	dynamic_warp_speed = lerp(dynamic_warp_speed, max_deep_space_warp_speed, deep_space_ratio)
	if is_surface_flight:
		# NMS PULSE DRIVE: cruise stays "controlled taxi," but warp/boost should still
		# feel like a genuine pulse drive over a planet. Previous caps (180-380 m/s)
		# were below the G-Lock bleeder threshold, so holding boost did nothing visible.
		#   Cruise: 260 -> 180 m/s  (was 220 -> 120)
		#   Warp:   1800 -> 900 m/s (was 380 -> 180) -- true surface pulse drive
		#   Brake:  2400 m/s ceiling (was 320) so the bleeder doesn't fight warp
		dynamic_max_speed = min(dynamic_max_speed, lerp(260.0, 180.0, surface_assist))
		dynamic_warp_speed = min(dynamic_warp_speed, lerp(1800.0, 900.0, surface_assist))
		gravity_brake_max = min(gravity_brake_max, 2400.0)
	
	# ACE: Force-bleed velocity if exceeding the safety threshold (G-Lock)
	if velocity.length() > gravity_brake_max * 1.5:
		velocity = velocity.lerp(velocity.normalized() * (gravity_brake_max * 1.5), delta * 2.0)
	
	# THREE-TIER SPEED SELECTION
	# Normal: R2 analog → dynamic_max_speed
	# Warp:   A + R2   → dynamic_warp_speed  
	# Hyper:  A + L1 + R1 + R2 → dynamic_hyperdrive_speed (only in space, blocked in atmo)
	var dynamic_hyperdrive_speed: float = lerp(dynamic_warp_speed, max_hyperdrive_speed, altitude_ratio)
	var s_val: float
	if is_hyperdrive:
		s_val = dynamic_hyperdrive_speed
	elif is_warping:
		s_val = dynamic_warp_speed
	else:
		s_val = dynamic_max_speed
	# NMS MODEL: thrust always follows the ship's actual forward. In atmosphere the
	# auto-level torque keeps the hull upright around the roll axis, but pitch is
	# entirely pilot-controlled — pitching the nose up MUST translate into climbing,
	# and pitching down MUST translate into a dive. The old code sliced the vertical
	# component off target_vel on the surface, so the ship was effectively locked to
	# a single altitude. That's now gone; terrain safety + auto-level keep it from
	# pancaking into the ground.
	var thrust_dir: Vector3 = -global_transform.basis.z
	if not is_in_atmo and is_surface_flight:
		# Space-above-surface edge case: we're in "surface flight" but above the atmo
		# boundary (shouldn't happen with current thresholds, but keep the guard).
		thrust_dir = thrust_dir.slide(world_up)
		if thrust_dir.length_squared() < 0.0001:
			thrust_dir = _get_surface_forward_hint(world_up)
		else:
			thrust_dir = thrust_dir.normalized()
	var target_vel = thrust_dir * s_val * thrust_mapped

	if reverse_mapped > 0.1:
		target_vel = -thrust_dir * dynamic_max_speed * 0.4 * reverse_mapped
	# (Removed the forced slide(world_up) for surface flight — the pilot now has
	# full vertical freedom via pitch input, just like No Man's Sky.)
		
	# ACE DIVERGENT FLIGHT DYNAMICS: Modulate drag and inertia based on atmospheric density
	# Space (Ratio 1.0) = Newtonian Inertia (Low Drag, Floating)
	# Planet (Ratio 0.0) = Atmospheric Authority (High Drag, Grounded)
	var dynamic_inertia = lerp(4.5, 1.2, altitude_ratio)
	
	if target_vel.length_squared() < 0.01:
		var brake_power = lerp(12.0, 0.4, altitude_ratio) # Space drift takes ages to stop
		if is_surface_flight:
			brake_power += 8.0 * surface_assist
		velocity = velocity.lerp(Vector3.ZERO, brake_power * delta)
		if velocity.length_squared() < 0.25:
			velocity = Vector3.ZERO
	else:
		# ATMOSPHERIC DRAG & SPACE INERTIA SYNC
		var follow_weight = dynamic_inertia
		if is_warping and true_altitude < 26000.0:
			var drag = 1.0 - altitude_ratio
			follow_weight = (dynamic_inertia + drag * 6.0)
			
		velocity = velocity.lerp(target_vel, follow_weight * delta)
	
	self.motion_mode = CharacterBody3D.MOTION_MODE_FLOATING # ACE DRIFT PURGE
	
	# DYNAMIC FOV: Calibrated to prevent edge-warping (Capped at 100°)
	# High FOVs (>110°) cause extreme 'fisheye' distortion at astronomical speeds.
	if camera:
		var speed_val = velocity.length()
		var fov_scale = 0.0
		if speed_val > max_warp_speed:
			# Hyperdrive Epoch: 92 -> 100
			var t = clamp((speed_val - max_warp_speed) / (max_hyperdrive_speed - max_warp_speed), 0.0, 1.0)
			fov_scale = 92.0 + (t * 8.0)
		elif speed_val > max_space_speed:
			# Warp Epoch: 82 -> 92
			var t = clamp((speed_val - max_space_speed) / (max_warp_speed - max_space_speed), 0.0, 1.0)
			fov_scale = 82.0 + (t * 10.0)
		else:
			# Normal Flight: 70 -> 82
			var t = clamp(speed_val / max_space_speed, 0.0, 1.0)
			fov_scale = 70.0 + (t * 12.0)
		
		camera.fov = lerp(camera.fov, fov_scale, 4.0 * delta)
		
	# SYNC HUD: Dynamic Color Scaling (Green -> Crimson)
	if health_bar_fill and health_component:
		var hp_p = health_component.current_health / health_component.max_health
		health_bar_fill.scale.x = hp_p
		health_bar_fill.color = Color.CRIMSON.lerp(Color.SPRING_GREEN, hp_p)
		
	# ATMOSPHERIC TURBULENCE: Extremely subtle jitter, grass-skimming ONLY
	var turb_intensity = (1.0 - turb_altitude_ratio) * (velocity.length() / 2500.0)
	if turb_intensity > 0.05:
		turb_v = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * turb_intensity * 0.08
	else:
		# Rapidly zero out effects when ship comes to a stop
		turb_v = turb_v.lerp(Vector3.ZERO, 15.0 * delta)
	
	# ORBIT CAMERA ROTATION (Right Stick & Mouse)
	if not _mobile_perf:
		const CAM_DEAD = 0.15
		var rs_x = Input.get_joy_axis(0, JOY_AXIS_RIGHT_X)
		var rs_y = Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		if abs(rs_x) < CAM_DEAD: rs_x = 0.0
		if abs(rs_y) < CAM_DEAD: rs_y = 0.0
		
		if abs(rs_x) > 0.01: cam_orbit.x -= rs_x * cam_orbit_sensitivity * delta * 2.0
		if abs(rs_y) > 0.01: cam_orbit.y -= rs_y * cam_orbit_sensitivity * delta * 2.0
	cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2) 
	
	# SHADOWGLASS 30FPS SYNC: Only update visual nodes every 33.3ms
	var cur_v_tick = int(Time.get_ticks_msec() / 33.33)
	var v_update_30 = cur_v_tick != _v_tick_30_p
	if v_update_30: _v_tick_30_p = cur_v_tick

	# ACE MOBILE TELEMETRY: push speed/altitude/warp to the HUD readout. Driven
	# here (not in _process) so the value is fresh relative to the physics step.
	if mobile_ui_ref and mobile_ui_ref.has_method("set_telemetry"):
		mobile_ui_ref.set_telemetry(velocity.length(), true_altitude, is_warping)

	move_and_slide()
	
	# ACE SAFETY FLOOR: Terrain-aware anti-clipping recovery (Radius-Aware)
	# MOBILE: get_terrain_elevation runs layered FastNoiseLite samples — throttle
	# to every 3rd physics frame (still >10Hz) and reuse the cached height
	# between recomputes.
	if target_planet and target_planet.has_method("get_terrain_elevation"):
		var p_center = target_planet.global_position
		var to_ship = global_position - p_center
		var dist_to_center = to_ship.length()
		var up_dir = to_ship / dist_to_center

		_terrain_floor_tick += 1
		var _t_update: bool = true
		if _mobile_perf and (_terrain_floor_tick % 3) != 0:
			_t_update = false
		var terrain_h: float
		if _t_update:
			terrain_h = target_planet.get_terrain_elevation(up_dir)
			_terrain_floor_cached = terrain_h
		else:
			terrain_h = _terrain_floor_cached
		var p_radius = target_planet.get("planet_radius")
		
		# ACE HARDENING: Optimized for 6m Hull Radius
		# Target: 1.0m absolute gap for extreme ground-skimming
		var ship_hull_radius = 6.0
		var min_safe_dist = p_radius + terrain_h + ship_hull_radius + 1.0
		
		if dist_to_center < min_safe_dist:
			# ACE REPULSION: Instantly eject ship from the terrain 
			# We use a higher correction factor for low-altitude high-speed safety
			var correction = up_dir * (min_safe_dist - dist_to_center)
			global_position += correction
			
			# Kill downward velocity
			var v_dot = velocity.dot(up_dir)
			if v_dot < 0:
				# Bounce slightly more aggressively when close to ground to prevent stickiness
				velocity -= up_dir * v_dot * 1.8 
		
		# ACE TERRAIN FOLLOWING (NMS Style): Predictive pitch correction
		# If we are close and moving, pull the nose up slightly to follow the land
		if dist_to_center < (p_radius + terrain_h + 100.0):
			var fwd = -global_transform.basis.z
			if fwd.dot(up_dir) < -0.1: # Pointing down
				# Apply a small virtual 'lift' force
				velocity += up_dir * 120.0 * delta 
	
	# CELESTIAL CAMERA SYNC (Top-Level Smoothing)
	# ACE HARDENING: We sync AFTER move_and_slide to prevent frame-latency at 12km/s.
	if cam_pivot:
		# 1. POSITION SYNC: Snap the independent pivot to the ship's final physical location
		# ACE HARDENING: Position must sync every physics frame to prevent 'Separation Jitter' at km/s speeds.
		cam_pivot.global_position = global_position
		
		# 2. ORIENTATION SYNC: Calculate the tracking target
		world_up = (global_position - target_planet.global_position).normalized() if target_planet else Vector3.UP
		if is_instance_valid(pinned_target):
			# TRACKING: Frame the Ship and Adversary
			var t_dir = (pinned_target.global_position - global_position).normalized()
			var s_fwd = -global_transform.basis.z
			var look_dir = s_fwd.lerp(t_dir, 0.35).normalized()
			var cam_q = Basis.looking_at(look_dir, world_up).get_rotation_quaternion()
			
			var orbit_q = Quaternion(Vector3.UP, cam_orbit.x) * Quaternion(Vector3.RIGHT, cam_orbit.y)
			# ROTATION HARDENING: Camera orientation must follow at physics-rate to keep ship centered
			cam_pivot.global_transform.basis = Basis(cam_q * orbit_q)
		else:
			# CHASE: Follow the hull with horizon-locked stabilization
			var ship_q = global_transform.basis.get_rotation_quaternion()
			var orbit_q = Quaternion(Vector3.UP, cam_orbit.x) * Quaternion(Vector3.RIGHT, cam_orbit.y)
			
			var target_q = (ship_q * orbit_q).normalized()
			var current_q = cam_pivot.global_transform.basis.get_rotation_quaternion()
			# Orient at physics-rate for atmospheric stability
			cam_pivot.global_transform.basis = Basis(current_q.slerp(target_q, 15.0 * delta))
	
	_update_polar_weather(delta)
		

	
	# UPDATE THRUSTER TRAILS (Sync after physical move to prevent high-velocity lag)
	# At 64km/s, even a single frame of lag causes a 1km visual gap.
	# Using the ship_model.global_transform ensures we catch the 25x model-space offsets.
	# MOBILE: Rebuild the ImmediateMesh ribbon every other frame (15Hz at 30fps
	# cap) to halve the vertex-submission cost of the 5-port trail system.
	# Nozzle orb / OmniLight sync still runs every frame below so ignition is crisp.
	_thruster_tick += 1
	if ship_model:
		for t in thruster_trails:
			var world_pos = ship_model.global_transform * t.offset
			# Always update every frame — the old every-other-frame skip caused the ribbon
			# to freeze while the nozzle glow kept moving, producing a flicker at 30fps.
			# Mobile trail length is capped inside ThrusterTrail to keep vertex cost low.
			t.node.update_trail(world_pos, global_transform.basis.z, velocity, is_warping, thrust_mapped, delta)
			
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
				_trigger_hit_flash(clamp(impact_force / 400.0, 0.4, 0.95))
				
				# ACE: Negligible damage for Space Stations (Layer 8)
				var damage_mult = 0.02
				if coll.get_collider().collision_layer & 8:
					damage_mult = 0.0001
				
				if health_component: health_component.take_damage(impact_force * damage_mult)
	
	# 5. VISUAL HULL DYNAMICS
	# Simulates physical G-Forces forcing the Starhawk to bank and pitch violently during maneuvers
	if ship_model:
		var target_bank = yaw * lerp(18.0, 7.0, surface_assist) # Biting into the turn (Roll left/right)
		var target_pitch_visual = (thrust_mapped * 6.0) - (reverse_mapped * 6.0) # Nose shifts up/down
		if is_surface_flight:
			target_pitch_visual = lerp(target_pitch_visual, 0.0, surface_assist)
		
		# Because the model is baseline-rotated -90.0 on Y, X becomes local Roll and Z becomes local Pitch!
		var target_hull_euler = Vector3(target_bank, -90.0, target_pitch_visual)
		
		# KINEMATIC BANKING: Sync with deadzone-hardened flight controls to purge drift-lean
		var bank_deg = yaw * lerp(28.0, 10.0, surface_assist)
		var dip_deg = lerp(-pitch * 8.0, 0.0, surface_assist)
		dip_deg += (thrust_mapped - reverse_mapped) * lerp(6.0, 1.5, surface_assist)
		if is_surface_flight:
			dip_deg = clamp(dip_deg, -2.0, 4.0)
		var t_rot = Vector3(bank_deg, -90.0, dip_deg)
		
		# ACE ROTATION HARDENING: Smooth lerp banking/dip every frame to prevent jitter
		var rot_weight = 12.0 if (abs(yaw) < 0.01 and abs(pitch) < 0.01) else 4.0
		if is_surface_flight:
			rot_weight = 14.0
		
		# BARREL ROLL LOGIC: 360 Degree helical rotation
		var is_rolling = barrel_roll_t > 0.0
		if is_rolling:
			barrel_roll_t -= delta * 1.85 # ~0.54s duration
			var roll_perc = 1.0 - barrel_roll_t
			var roll_angle = roll_perc * 360.0 * barrel_roll_dir
			ship_model.rotation_degrees.x = roll_angle
			
			var ground_damping = clamp(true_altitude / 1000.0, 0.25, 1.0) 
			var strafe_dir = -global_transform.basis.x * barrel_roll_dir
			if target_planet and true_altitude < 20000.0:
				strafe_dir = strafe_dir.slide(world_up).normalized()
			velocity += strafe_dir * (2800.0 * ground_damping)

			if barrel_roll_t <= 0.0:
				ship_model.rotation_degrees.x = 0.0 
		else:
			# ACE SYNC: Interpolate banking at physics-rate, but only snap visuals at 30fps if needed.
			# For Starfox-fidelity, we maintain banking smoothness at physics-rate.
			ship_model.rotation_degrees = ship_model.rotation_degrees.lerp(t_rot, rot_weight * delta)

		# Identity Snap: Force exact level-flight if within 0.1 degree of target
		if abs(ship_model.rotation_degrees.x) < 0.1 and abs(ship_model.rotation_degrees.z) < 0.1 and abs(yaw) < 0.01:
			ship_model.rotation_degrees.x = 0.0
			ship_model.rotation_degrees.z = 0.0
		
		# HOVER IDLE ANIMATION (Physics-rate smooth lerp)
		var speed_ratio = clamp(velocity.length() / 200.0, 0.0, 1.0)
		var hover_bob = sin(Time.get_ticks_msec() * 0.0015) * 1.5 * (1.0 - speed_ratio)
		ship_model.position.y = lerp(ship_model.position.y, hover_bob, 5.0 * delta)

	# ACE: Master Camera & HUD Sync
	_process_ace_camera(delta)
	_was_in_atmo = is_in_atmo

func _fire_alternating_cannon() -> void:
	fire_cooldown = FIRE_RATE

	# Play fire SFX
	var md_nodes = get_tree().get_nodes_in_group("MusicDirector")
	if md_nodes.size() > 0 and md_nodes[0].has_method("play_fire"):
		md_nodes[0].play_fire()

	var wing_up = global_transform.basis.x.normalized()
	var main_scene = get_parent()
	if not main_scene: return
	
	# STARFOX TWIN-LASER SYNC: Micro-convergence for hitbox-anchored fire
	if not ship_model: return
	var weapon_offsets = [-0.14, 0.14]
	for off in weapon_offsets:
		# MUZZLE SYNC: Using dynamic AABB nose detection
		var turret_pos = ship_model.global_transform * Vector3(ship_nose_offset, -0.18, off)
		recoil_v += (global_transform.basis.z * 0.25)
		
		# CONVERGENCE: Point bullets toward the current Pilot HUD reticle
		var fire_dir = (_cur_aim_point - turret_pos).normalized()
		
		# BOLT ORIGIN: Shifted 10m FORWARD to ensure clearance from internal meshes
		var bolt_origin = turret_pos - (global_transform.basis.z * 10.0)
		_spawn_muzzle_flash(turret_pos, fire_dir)



		
		# BUILD BOLT: 3.5m Girth, 50m Length (Tighter for relativistic sync)
		var bolt = MeshInstance3D.new()
		var capsule = CapsuleMesh.new()
		capsule.radius = 3.5; capsule.height = 50.0
		bolt.mesh = capsule

		
		var mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.2, 0.9, 1.0); mat.emission_enabled = true; mat.emission = Color(0.2, 0.9, 1.0); mat.emission_energy_multiplier = 18.0; mat.disable_fog = true; bolt.material_override = mat
		
		# WORLD-SPACE RELEASE: Firing AFTER movement guarantees muzzle-alignment
		main_scene.add_child(bolt)
		bolt.add_to_group("World")
		
		# ACE TARGET HAND-OFF: Pass either pinned or auto-lock
		var final_t = pinned_target if is_instance_valid(pinned_target) else lock_on_target
		
		# MUZZLE SYNC
		bolt.global_position = bolt_origin
		if fire_dir.length() > 0.001:
			bolt.look_at(bolt.global_position + fire_dir)
			bolt.rotate_object_local(Vector3.RIGHT, PI / 2.0)
		
		# ACE RELATIVISTIC MOMENTUM: inherited ship full vector + 9k-35k Acceleration Ramp
		live_bolts.append({
			"node": bolt, 
			"dir": fire_dir, 
			"life": 0.0, 
			"ship_v": velocity,
			"target": final_t,
			"pos": bolt_origin # Physical position
		})


		
	# NEWTONIAN RECOIL: Physical Impulse backwash
	velocity += global_transform.basis.z * 25.0 # Enhanced recoil weight

func _spawn_muzzle_flash(pos: Vector3, _dir: Vector3) -> void:
	# POINT LIGHT FLASH: Replaced mesh with high-energy point light for true "light flash" look
	var flash = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.95, 0.7) # Bright Warm Flash
	flash.omni_range = 35.0 # Illuminates ship wings/hull
	flash.light_energy = 12.0
	flash.light_specular = 0.5
	flash.shadow_enabled = false # No shadow maps on muzzle flash - avoids square artifacts
	get_parent().add_child(flash)
	flash.global_position = pos
	
	var t = get_tree().create_timer(0.04)
	t.timeout.connect(func(): if is_instance_valid(flash): flash.queue_free())

# LEGACY CAMERA SYSTEM DELETED FOR ALPHA-ORBIT STABILITY

func _input(event: InputEvent) -> void:
	# YIELD INPUT TO STATION UI: When docked, Player must not consume any events.
	var stations := get_tree().get_nodes_in_group("SpaceStation")
	for s in stations:
		if s.get("_ui_visible") == true:
			return

	# ESC: Toggle mouse lock
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		if mouse_locked: unlock_mouse()
		else: lock_mouse()

	# KEYBOARD FIRE: F key (single press, no hold repeat)
	if event is InputEventKey and event.keycode == KEY_F and event.pressed and not event.echo:
		print("--- GUNSMITH: F KEY DETECTED --- in_ship:", in_ship, " cooldown:", fire_cooldown)
		if in_ship and fire_cooldown <= 0.0:
			_fire_alternating_cannon()
	
	# ORBIT CAMERA: Mouse Look (Desktop only to avoid Gyro-Mouse emulation conflicts)
	if not _mobile_perf and event is InputEventMouseMotion and mouse_locked and in_ship and not mobile_throttle_dragging:
		cam_orbit.x -= event.relative.x * 0.002
		cam_orbit.y -= event.relative.y * 0.002
		cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2)
	
	# ORBIT CAMERA: Touch Look (Mobile only)
	# This explicitly separates touch-dragging from gyro tilt emulation.
	if _mobile_perf and event is InputEventScreenDrag and not mobile_throttle_dragging:
		# Use position.x > viewport.size.x * 0.3 to avoid throttle interference
		if event.position.x > get_viewport().size.x * 0.3:
			cam_orbit.x -= event.relative.x * 0.005 # Faster for touch
			cam_orbit.y -= event.relative.y * 0.005
			cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2)
	
	# CONTROLLER FIRE: Triangle (PS) / Y (Xbox)
	if event is InputEventJoypadButton and event.button_index == JOY_BUTTON_Y and event.pressed:
		print("--- GUNSMITH: Y BUTTON DETECTED --- in_ship:", in_ship)
		if in_ship and fire_cooldown <= 0.0:
			_fire_alternating_cannon()
		
	if event is InputEventJoypadButton and event.pressed:
		var cur_time = Time.get_ticks_msec() / 1000.0
		if event.button_index == JOY_BUTTON_LEFT_SHOULDER:
			if (cur_time - last_tap_l) < 0.22: _trigger_barrel_roll(1.0)
			last_tap_l = cur_time
		if event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			if (cur_time - last_tap_r) < 0.22: _trigger_barrel_roll(-1.0)
			last_tap_r = cur_time
		
		# ACE LOCK-ON: Left Joystick Click (L3) OR B-Button (Right Face)
		if event.button_index == JOY_BUTTON_LEFT_STICK or event.button_index == JOY_BUTTON_B:
			pinned_target = lock_on_target
			if pinned_target: print("--- PILOT: TARGET PINNED ---")
		
	# E: Embark / Disembark
	if event is InputEventKey and event.keycode == KEY_E and event.pressed:
		if in_ship and true_altitude < 500.0: _disembark()
		elif not in_ship and parked_ship and global_position.distance_to(parked_ship.global_position) < 80.0: _embark()
		
	# MOUSE LOOK (On-Foot)
	if not _mobile_perf and event is InputEventMouseMotion and mouse_locked and not mobile_throttle_dragging and not in_ship:
		walk_yaw -= event.relative.x * 0.005
		cam_orbit.y -= event.relative.y * 0.005
		cam_orbit.y = clamp(cam_orbit.y, -1.2, 1.2)

func _process(delta: float) -> void:
	# SHADOWGLASS 30FPS SYNC: Only update visual nodes every 33.3ms
	var cur_v_tick = int(Time.get_ticks_msec() / 33.33)
	var v_update_30 = cur_v_tick != _v_tick_30_v
	if v_update_30: _v_tick_30_v = cur_v_tick
	
	# ACE LOCK-ON ACTIVE (Radar Online)
	# Factors in BOTH ship forward velocity AND base projectile speed (150km/s avg)
	if hud_reticle and camera:
		var p_speed = 22000.0 # Average cinematic ramp-speed for visual tracking
		var bullet_v = (-global_transform.basis.z * p_speed) + velocity
		# RADAR THROTTLE: Scans for targets with frame-jitter protection (Throttled to ~6Hz)
		_radar_tick += 1
		if _radar_tick >= 10:
			_radar_tick = 0
			var best_target: Node3D = null
			var fwd = -global_transform.basis.z 
			# CACHE: Fetch Enemies once and reuse for both the radar scan and the
			# off-screen threat arrows. Saves a second SceneTree group traversal.
			var enemies_pool = get_tree().get_nodes_in_group("Enemies") if is_inside_tree() else []
			if is_inside_tree():
				# Enemies use tight cone (~11°); mineable/passive use wider cone (~28°)
				# Targeting range raised to 35 km so asteroid mining works at much
				# longer distances (the laser bolt itself reaches ~37.5 km before
				# despawning, so 35 km gives a margin without exceeding range).
				const RADAR_RANGE_SQ := 35000.0 * 35000.0
				const LOCK_ON_RANGE_SQ := 35000.0 * 35000.0
				var highest_dot = 0.95 if _mobile_perf else 0.98

				var candidate_pools = [
					enemies_pool,
					get_tree().get_nodes_in_group("Targets"),
					get_tree().get_nodes_in_group("Mineable"),
					get_tree().get_nodes_in_group("Destructible")
				]

				# Visibility raycast — skip targets occluded by terrain
				var vis_query = PhysicsRayQueryParameters3D.new()
				vis_query.collision_mask = 1  # terrain only
				vis_query.exclude = [self]
				var space = get_world_3d().direct_space_state

				for pool_idx in range(candidate_pools.size()):
					var pool = candidate_pools[pool_idx]
					# Wider cone for passive mineable/destructible targets
					var pool_dot_thresh = highest_dot if pool_idx < 2 else 0.82
					for t in pool:
						if not is_instance_valid(t) or t.is_queued_for_deletion(): continue
						# Use target center for aim calculation if available
						var aim_pos: Vector3 = t.get_target_center() if t.has_method("get_target_center") else t.global_position
						var d_v = (aim_pos - global_position)
						var d_sq = d_v.length_squared()
						if d_sq > RADAR_RANGE_SQ: continue
						if d_sq < 0.0001: continue
						var d_len := sqrt(d_sq)
						var dot = fwd.dot(d_v / d_len)
						if dot < pool_dot_thresh: continue
						# VISIBILITY CHECK: skip targets behind terrain
						vis_query.from = global_position
						vis_query.to = aim_pos
						var vis_result = space.intersect_ray(vis_query)
						if vis_result and is_instance_valid(vis_result.collider) and vis_result.collider != t:
							continue  # occluded — skip
						# PREFER CLOSER TARGETS: bias dot score by proximity
						var score = dot + (1.0 - clamp(d_len / 5000.0, 0.0, 1.0)) * 0.1
						if score > highest_dot:
							highest_dot = score
							best_target = t
					# If we found an enemy in the first pool, don't even look at passive targets
					if best_target: break

			lock_on_target = best_target

			# AUTO-LOCK: On mobile or when firing, automatically pin the best target
			if auto_lock_enabled and lock_on_target and not is_instance_valid(pinned_target):
				if _mobile_perf or mobile_fire:
					pinned_target = lock_on_target

			# FLEET THREAT TRACKER: Draw arrows for ALL off-screen enemies
			var adversaries = enemies_pool
			var arrow_idx = 0
			for a in adversaries:
				if not is_instance_valid(a) or a.is_queued_for_deletion(): continue
				if a == pinned_target: continue 
				if arrow_idx >= hud_threat_arrows.size(): break
				
				if camera.is_position_behind(a.global_position) or not camera.is_position_in_frustum(a.global_position):
					_draw_fleet_arrow(hud_threat_arrows[arrow_idx], a.global_position)
					arrow_idx += 1
			# Clean up unused arrows
			for k in range(arrow_idx, hud_threat_arrows.size()):
				hud_threat_arrows[k].hide()

		# KINETIC RETICLE SYNC: Determines whether the crosshair tracks the target
		var default_aim = global_position + (bullet_v * 0.25)
		var final_target_point = default_aim
		
		# RETICLE SNAPPING: Jump visually to the target when within lock-cone
		if is_instance_valid(lock_on_target):
			if lock_on_target.has_method("get_target_center"):
				final_target_point = lock_on_target.get_target_center()
			else:
				final_target_point = lock_on_target.global_position
			hud_reticle.is_locked = true
		else:
			hud_reticle.is_locked = false
		
		# INITIAL BOOT: Snap first frame to avoid screen-zip
		if _cur_aim_point.length_squared() < 1.0:
			_cur_aim_point = final_target_point
			
		# ACE TRACKING: Smooth 18.0x lerp for fluid target hand-offs
		_cur_aim_point = _cur_aim_point.lerp(final_target_point, 18.0 * delta)
		
		if camera.is_position_behind(_cur_aim_point):
			hud_reticle.hide()
		else:
			hud_reticle.show()
			var screen_pos = camera.unproject_position(_cur_aim_point)
			hud_reticle.position = screen_pos - (hud_reticle.size / 2.0)

	# RECOIL & TURBULENCE & REENTRY SHAKE


	recoil_v = recoil_v.lerp(Vector3.ZERO, 12.0 * delta)
	
	reentry_v = Vector3.ZERO
	if reentry_timer > 0.0:
		reentry_timer -= delta
		var intensity = (reentry_timer / 3.0) * reentry_intensity
		reentry_v = Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * intensity
		
	# VISUAL HEAT GLOW: Animate hull emission based on shake/speed
	# ACE HEAT HYGIENE: Ensure this resets to zero even when the timer is inactive
	var reentry_heat = (reentry_timer / 3.0) if reentry_timer > 0.0 else 0.0
	if heat_glow_mat:
		var speed_mod = clamp(velocity.length() / 8000.0, 0.5, 2.0)
		var heat = reentry_heat * speed_mod
		heat_glow_mat.emission_enabled = heat > 0.05
		heat_glow_mat.emission = Color(1.0, 0.3 * heat, 0.0) # From Bright Orange to Deep Red
		heat_glow_mat.emission_energy_multiplier = heat * 12.0
	
	# REENTRY HEAT VIGNETTE SYNC: Tracks both active timer and static altitudeBAND
	if reentry_vignette:
		var raw_dist = clamp((true_altitude - 18000.0) / (26000.0 - 18000.0), 0.0, 1.0)
		var alt_heat = 1.0 - abs(raw_dist - 0.5) * 2.0 
		alt_heat = clamp(alt_heat, 0.0, 1.0)
		reentry_vignette.material.set_shader_parameter("intensity", max(reentry_heat, alt_heat))
			
		# ACE MUZZLE-VISUAL SYNC: Poll and Fire in _process for interpolated visual alignment
		# AERO-VORTEX TRAILS: Spawn condensation streaks during reentry (Uncapped 60FPS)
		if reentry_intensity > 0.05: 
			# ACE DISTANCE THROTTLE: Only spawn if the ship has traveled 15m since the last streak
			var ship_vel_len = velocity.length()
			if global_position.distance_to(_last_trail_pos) > 15.0:
				_last_trail_pos = global_position
				var wing_up = global_transform.basis.x.normalized()
				var fire_dir = -global_transform.basis.z.normalized()
				var heat_val = (reentry_timer / 3.0)
				var s_length = clamp(ship_vel_len * 0.02, 40.0, 200.0)
				for side in [-1.0, 1.0]:
					var jitter = Vector3(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5), randf_range(-0.5, 0.5)) * reentry_intensity
					_spawn_vortex_trail(global_position + (wing_up * 14.0 * side) + jitter, fire_dir, heat_val, s_length)

	
	# CAMERA DYNAMICS: Recoil & Reentry Shake (Ship-only Visual Sync)
	# Snap the camera pivot in _process to align with visual 'leaning' and 'banking'
	var cam_base_y = 10.0 if in_ship else 1.85
	if cam_spring: cam_spring.position = Vector3(0, cam_base_y, 0) + recoil_v + turb_v + reentry_v + shake_v
	
	# BOLT POOL UPDATE: Relativistic Physics Hardening
	# 25km/s base creates the 'Cracked the Code' visual lead observed in elite titles (Starfox/NMS).
	const BOLT_SPEED: float = 25000.0 
	const BOLT_LIFETIME: float = 1.5
	var space_state = get_world_3d().direct_space_state
	
	var i = live_bolts.size() - 1
	while i >= 0:
		var b = live_bolts[i]
		var node = b["node"]
		b["life"] += delta
		
		# Despawn expired bolts to prevent memory leaks and zombie nodes
		if b["life"] > 2.5: # Matches LaserBolt.LIFETIME
			if is_instance_valid(node): node.queue_free()
			live_bolts.remove_at(i)
			i -= 1
			continue
		
		# 9,000m/s start (relative) ensures the discharge ignites AT THE MUZZLE in Frame 1.
		# 35,000m/s peak ensures a more cinematic planetary dogfight feel.
		var accel_t = clamp(b["life"] / 0.6, 0.0, 1.0)
		
		# ACE TUNER: I will use a non-linear quadratic ramp for 'Muzzle Ignite' feel.
		var ease_t = accel_t * accel_t # Quadratic Ramp
		var current_rel_speed = lerp(9000.0, 35000.0, ease_t)

		# ACE SMART-LOCK HOMING: Fired bolts track the target mid-flight.
		# Cone widened (0.98 → 0.80, ~37° window) and turn rate ~5× faster so
		# bolts reliably curve onto small mineable resources.  Without this,
		# small targets like flora-mineable crystals frequently slipped past
		# the bolt even though the player was locked on.
		if is_instance_valid(b["target"]) and b["target"].is_inside_tree():
			var aim_pos: Vector3
			if b["target"].has_method("get_target_center"):
				aim_pos = b["target"].get_target_center()
			else:
				aim_pos = b["target"].global_position
			var t_dir = (aim_pos - node.global_position).normalized()
			var align = b["dir"].dot(t_dir)
			if align > 0.80:
				b["dir"] = b["dir"].lerp(t_dir, 12.0 * delta).normalized()
				if b["dir"].length() > 0.01:
					node.look_at(node.global_position + b["dir"])
					node.rotate_object_local(Vector3.RIGHT, PI / 2.0)



		
		var old_pos = b["pos"]
		# NEWTONIAN VECTOR SYNC: Inherit full ship inertia + directional relative speed
		var move_dist = (b["dir"] * current_rel_speed + b["ship_v"]) * delta
		var next_pos = old_pos + move_dist
		b["pos"] = next_pos # Update internal physical pos
		
		# SWEPT-FRAME PHYSICS: proxy check first (layer 6, bypasses terrain),
		# then normal world/enemy check. Two raycasts prevent terrain from
		# intercepting bolts before they reach surface prop collision spheres.
		_proxy_ray_q.from = old_pos
		_proxy_ray_q.to = next_pos
		var result = space_state.intersect_ray(_proxy_ray_q)
		if not result:
			_ray_q.from = old_pos
			_ray_q.to = next_pos
			result = space_state.intersect_ray(_ray_q)
		
		if result and is_instance_valid(result.collider):
			var c = result.collider
			var p_name = c.get_parent().name if c.get_parent() else "NONE"
			var c_groups = c.get_groups()
			print("--- GUNSMITH: Bolt Hit! [%s] (Parent: %s) Layer: %d Groups: %s ---" % [c.name, p_name, c.collision_layer, str(c_groups)])
			var target = result.collider
			var hp = target.get_node_or_null("HealthComponent")
			var is_dying = false

			# MINEABLE PRIORITY: planet-surface minerals own their HP/take_damage
			# directly (no HealthComponent child).  When the bolt hits one, ask
			# it to take 1 damage — MineableResource will run _on_mined() and
			# explode into LootGem shards once health drops to zero.  The
			# collider can be either the StaticBody3D itself or a child mesh,
			# so check both before falling back to the generic NPC path.
			var mineable: Node = null
			if target.is_in_group("Mineable"):
				mineable = target
			elif target.get_parent() and target.get_parent().is_in_group("Mineable"):
				mineable = target.get_parent()

			if mineable and mineable.has_method("take_damage"):
				# is_dying based on the mineral's own health field (1 dmg per
				# shot, so health <= 1 means this hit shatters it).
				var hp_var = mineable.get("health")
				var cur_hp: float = float(hp_var) if hp_var != null else 1.0
				is_dying = cur_hp <= 1.0
				mineable.take_damage(1.0)
			elif hp:
				is_dying = (hp.current_health <= 25.0)
				hp.take_damage(25.0)

				# ACE DESTRUCTION: Handle actual removal if health is depleted
				if is_dying:
					target.set_deferred("collision_layer", 0); target.set_deferred("collision_mask", 0)
					# Hide all visual components (Meshes/HP Bars)
					for child in target.get_children():
						if child is VisualInstance3D: child.hide()
					get_tree().create_timer(0.15).timeout.connect(func(): if is_instance_valid(target): target.queue_free())

			# ACE VISUALS: Hit-spark vs Catastrophic Nova
			_trigger_explosion_inline(result.position, target, result.normal, is_dying)


			node.queue_free(); live_bolts.remove_at(i)
		elif v_update_30:
			node.global_position = b["pos"]
			# KINETIC STRETCH: Close the 30Hz gap for visual continuity in Retro Mode
			# Bridges the 500m-1km gaps between frames with a solid energy streak.
			var stretch_len = (move_dist.length() * 2.5) / 120.0 
			for child in node.get_children():
				if child is MeshInstance3D:
					child.scale.y = max(1.0, stretch_len)
		i -= 1
				
	# GUNSMITH FINAL SYNC: Fire AFTER bolt pool updates to ensure muzzle-snapping
	if in_ship and fire_cooldown <= 0.0:
		var cur_fire = Input.is_key_pressed(KEY_F) or mobile_fire
		var cur_joy_fire = Input.is_joy_button_pressed(0, JOY_BUTTON_Y)
		# Continuous fire if cur_fire is held, no need for _prev_fire_key
		if cur_fire or cur_joy_fire:
			_fire_alternating_cannon()
			fire_cooldown = 0.18 # ACE RPS NERF: 5.5 shots per second
		_prev_fire_key = cur_fire

	# Update thruster audio — pitch and volume scale with ship speed
	if in_ship:
		var is_boosting = Input.is_joy_button_pressed(0, JOY_BUTTON_A) or Input.is_key_pressed(KEY_SHIFT) or mobile_boost
		var md_nodes = get_tree().get_nodes_in_group("MusicDirector")
		if md_nodes.size() > 0 and md_nodes[0].has_method("update_thruster_audio"):
			md_nodes[0].update_thruster_audio(velocity.length(), is_boosting)



func _trigger_explosion_inline(pos: Vector3, target: Node, normal: Vector3, is_big: bool = false) -> void:
	# Play explosion SFX
	var md_nodes = get_tree().get_nodes_in_group("MusicDirector")
	if md_nodes.size() > 0 and md_nodes[0].has_method("play_explosion"):
		md_nodes[0].play_explosion(is_big)

	_spawn_impact_flash(pos, normal)
	# MOBILE: Skip scorch Decals entirely. Decal nodes are forward-cluster
	# expensive on tiled-GPU chips and the retro toon aesthetic hides their absence.
	if not _mobile_perf:
		_spawn_scorch_mark(pos, target, normal)
	
	var explosion_script = load("res://src/combat/ExplosionFX.gd")
	if not explosion_script: return
	var fx = Node3D.new()
	fx.set_script(explosion_script)
	
	# HULL WELDING: Small hit-sparks follow the ship. 
	# Catastrophic Novas stay at world-origin for visual stability.
	if not is_big and is_instance_valid(target):
		target.add_child(fx)
		fx.global_position = pos # Position in world then convert to local via add_child
	else:
		get_tree().root.add_child(fx)
		fx.global_position = pos
	
	var sz = 8.0 # Small hit spark (Wind Waker style)
	if is_big:
		if target.is_in_group("Enemies") or target.is_in_group("Player"):
			sz = 600.0 # TITANIC NOVA (Ships)
		else:
			# ASTEROID: Match physical diameter (1:1 visual payout)
			sz = target.scale.x * 16.0
	
	fx.set("explosion_scale", clamp(sz, 8.0, 1600.0))

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
	# MOBILE: Rate-limit to one flash every 80ms — OmniLight3D spawning is one of
	# the dearer costs on A14 during sustained fire. Visual feel is preserved
	# because bolts spawn at >5Hz and flashes overlap.
	if _mobile_perf:
		var now_ms = Time.get_ticks_msec()
		if now_ms - _last_flash_ms < 80:
			return
		_last_flash_ms = now_ms
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
	
	# Manifest an empty decoy hull SNAPPED to the surface
	var path = "res://assets/models/player/ship/Meshy_AI_Starhawk_01_0331051011_texture.glb"
	if FileAccess.file_exists(path) and target_planet:
		var scene = load(path)
		if scene:
			parked_ship = scene.instantiate()
			get_parent().add_child(parked_ship)
			# LANDING SYNC: Align to surface normal + Snapping!
			var g_up = (global_position - target_planet.global_position).normalized()
			var h = target_planet.get_terrain_elevation(g_up)
			var ground_pos = target_planet.global_position + (g_up * (target_planet.planet_radius + h))

			var t_bas = _surface_aligned_basis(g_up, -global_transform.basis.z)
			
			parked_ship.global_transform.basis = t_bas
			parked_ship.global_position = ground_pos + (g_up * 10.0) # Prince-scale landing height
			parked_ship.scale = Vector3(25.0, 25.0, 25.0)
			parked_ship.rotate_object_local(Vector3.UP, deg_to_rad(-90.0))
			
	if coll_node: coll_node.shape.radius = 8.0
	if ship_marker: ship_marker.show()
	if cam_pivot: cam_pivot.position.y = 8.5 # 'Prince' Scale Eye-Level
	if cam_spring: 
		cam_spring.position.y = 0.0 
		cam_spring.spring_length = 35.0 # Titanic Overview Standoff

func _draw_fleet_arrow(arrow: Control, target_pos: Vector3) -> void:
	# ACE: THREAT RADIAL INDICATOR
	var screen_pos = camera.unproject_position(target_pos)
	var screen_size = get_viewport().get_visible_rect().size
	var is_behind = camera.is_position_behind(target_pos)
	
	arrow.show()
	var margin = 60.0
	var clamped_x = clamp(screen_pos.x, margin, screen_size.x - margin)
	var clamped_y = clamp(screen_pos.y, margin, screen_size.y - margin)
	
	if is_behind:
		clamped_x = margin if screen_pos.x > screen_size.x/2 else screen_size.x - margin
	
	arrow.position = Vector2(clamped_x, clamped_y) - Vector2(25, 25)
	var dist = global_position.distance_to(target_pos)
	# RANGE BOOST: Persistent tracking up to 50km
	var danger = clamp(1.0 - (dist / 50000.0), 0.5, 1.0)
	arrow.modulate = Color(1, 0, 0, danger) # Red stays vivid
	arrow.scale = Vector2.ONE * danger



func _embark() -> void:
	in_ship = true
	cam_orbit.x = 0; cam_orbit.y = 0
	velocity = Vector3.ZERO
	if ship_model: ship_model.show()
	if ship_marker: ship_marker.hide()
	if cam_pivot: cam_pivot.position.y = 0.0 # Reset to ship hull origin
	if parked_ship: 
		# We must restore POSITION and ROTATION, but absolutely strip the SCALE! 
		# If the 25x scale leaks to the parent body, movement vectors become 25x faster!
		var st_tf = parked_ship.global_transform
		st_tf = st_tf.rotated_local(Vector3.UP, deg_to_rad(90.0)) # Un-rotate visual offset
		global_position = st_tf.origin
		global_transform.basis = st_tf.basis.orthonormalized() # Strip the scale matrix!
		parked_ship.queue_free(); parked_ship = null
	if coll_node: coll_node.shape.radius = 16.0
	if cam_spring: 
		cam_spring.position.y = 10.0 # Restore Ship-clearance vertical lift
		cam_spring.spring_length = 250.0 # Restore Space Standoff

func _trigger_barrel_roll(dir: float) -> void:
	if not in_ship: return
	if barrel_roll_t > 0.1: return # Prevent spam-stacking
	barrel_roll_t = 1.0
	barrel_roll_dir = dir
	print("--- PILOT: BARREL ROLL TRIGGERED (Dir: ", dir, ") ---")

func _surface_aligned_basis(up_dir: Vector3, forward_hint: Vector3) -> Basis:
	var up = up_dir.normalized()
	var fwd = forward_hint.slide(up)
	if fwd.length_squared() < 0.0001:
		fwd = up.cross(Vector3.RIGHT)
	if fwd.length_squared() < 0.0001:
		fwd = up.cross(Vector3.FORWARD)
	fwd = fwd.normalized()
	var right = up.cross(fwd)
	if right.length_squared() < 0.0001:
		right = up.cross(Vector3.RIGHT if abs(up.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD)
	right = right.normalized()
	fwd = right.cross(up).normalized()
	return Basis(right, up, -fwd).orthonormalized()

func _get_surface_forward_hint(world_up: Vector3) -> Vector3:
	var hint: Vector3 = Vector3.ZERO
	if velocity.length_squared() > 25.0:
		hint = velocity.slide(world_up)
	if hint.length_squared() < 0.0001:
		hint = (-global_transform.basis.z).slide(world_up)
	if hint.length_squared() < 0.0001 and cam_pivot:
		hint = (-cam_pivot.global_transform.basis.z).slide(world_up)
	if hint.length_squared() < 0.0001:
		hint = world_up.cross(Vector3.RIGHT)
	if hint.length_squared() < 0.0001:
		hint = world_up.cross(Vector3.FORWARD)
	return hint.normalized()


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

	# Reuse the shared shard material so the GPU pipeline stays hot — first-boost
	# stalls of 1-3s on iOS came from compiling this StandardMaterial3D variant
	# (unshaded + emission) on demand for every spawn.
	if _shared_shard_mat == null:
		_shared_shard_mat = StandardMaterial3D.new()
		_shared_shard_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_shared_shard_mat.albedo_color = Color.RED
		_shared_shard_mat.emission_enabled = true
		_shared_shard_mat.emission = Color.RED
		_shared_shard_mat.emission_energy_multiplier = 4.0
	shard.material_override = _shared_shard_mat
	
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

func _setup_polar_weather() -> void:
	# ACE WEATHER: Blocky 'Superhot' style snow particles
	snow_particles = CPUParticles3D.new()
	# Attach to camera so they always surround the player but stay local to the world
	if camera: camera.add_child(snow_particles)
	# MOBILE: Cut particle budget ~60% across the board. Weather is a flavour layer,
	# not a gameplay system, and 800 box-mesh particles at 30fps eats GPU on A14.
	snow_particles.amount = 320 if _mobile_perf else 800
	snow_particles.lifetime = 2.5
	snow_particles.preprocess = 1.0
	
	var m = BoxMesh.new(); m.size = Vector3(0.35, 0.35, 0.35)
	snow_particles.mesh = m
	
	snow_particles.direction = Vector3(0, -1, 0)
	snow_particles.spread = 20.0
	snow_particles.gravity = Vector3(12.0, -15.0, 5.0) # Wind-drifted snow
	snow_particles.initial_velocity_min = 25.0
	snow_particles.initial_velocity_max = 45.0
	
	snow_particles.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	snow_particles.emission_box_extents = Vector3(200, 100, 200)
	snow_particles.position = Vector3(0, 80.0, -50.0) # Spawn overhead and slightly ahead
	snow_particles.emitting = false

func prewarm_vfx() -> void:
	# Multi-pass prewarm behind the loading screen so every shader variant the
	# player can trigger has its Metal / Vulkan pipeline compiled before
	# gameplay starts.  Each pass waits 8 frames on mobile (2 on desktop) so
	# the GPU actually finishes async PSO linking before the next pass —
	# iOS Metal serializes compilation on the main thread on A14 and older,
	# so we render at full intensity (visible, in front of the camera) and
	# eat the wait-time behind the splash rather than mid-gameplay.
	#
	# Passes covered:
	#   1) cruise thrust trail + red glow
	#   2) warp trail (120-pt cyan ribbon — the variant that caused the freeze)
	#   3) boost trail + orange/white-hot glow
	#   4) plasma shard (unshaded + emission StandardMaterial3D)
	#   5) laser bolt + explosion FX (fired weapons share emission/multimesh
	#      pipelines, prewarming them keeps first-fire from compounding the
	#      first-thrust stall)
	if not _mobile_perf:
		# Desktop GPUs compile pipelines fast enough that the 6 passes of
		# stalling-on-first-frame here cost more than the freeze they prevent.
		# Only mobile pays the iOS Metal hitch.
		Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	var fwd := -global_transform.basis.z

	# --- Helper: set all glow nodes to a given power / color ---
	var _set_glows := func(power: float, col: Color) -> void:
		if not (ship_model and get("thruster_trails")): return
		for t_data in get("thruster_trails"):
			if typeof(t_data) != TYPE_DICTIONARY: continue
			var tn = t_data.get("node")
			if not is_instance_valid(tn): continue
			if tn.has_meta("glow_node"):
				var gn = tn.get_meta("glow_node")
				if is_instance_valid(gn) and gn is MeshInstance3D and gn.material_override is ShaderMaterial:
					gn.visible = true
					gn.material_override.set_shader_parameter("power", power)
					gn.material_override.set_shader_parameter("glow_color", col)

	# 8 frames per pass on mobile — iOS Metal serializes pipeline compilation
	# on the main thread on A14 and older.  Each variant can take 1-3 s; we
	# pay that cost up front behind the loading splash rather than as a
	# 10-20 s freeze on the first boost.  Desktop GPUs compile fast enough
	# that 2 frames is plenty.
	var wait_frames := 8 if _mobile_perf else 2

	# --- Pass 1: cruise/thrust variant (low ribbon, red glow) ---
	if ship_model and get("thruster_trails"):
		for t_data in get("thruster_trails"):
			if typeof(t_data) != TYPE_DICTIONARY: continue
			var trail_node = t_data.get("node")
			var offset = t_data.get("offset", Vector3.ZERO)
			if not is_instance_valid(trail_node): continue
			var world_pos: Vector3 = ship_model.global_transform * offset
			if trail_node.has_method("prewarm"):
				trail_node.prewarm(world_pos, fwd)
	_set_glows.call(0.5, Color.RED)
	for _w1 in range(wait_frames):
		await get_tree().process_frame

	# --- Pass 2: warp variant (120-pt ribbon, cyan glow) — the one that was missing ---
	if ship_model and get("thruster_trails"):
		for t_data in get("thruster_trails"):
			if typeof(t_data) != TYPE_DICTIONARY: continue
			var trail_node = t_data.get("node")
			var offset = t_data.get("offset", Vector3.ZERO)
			if not is_instance_valid(trail_node): continue
			var world_pos: Vector3 = ship_model.global_transform * offset
			# Force the max-length warp ribbon so the GPU compiles that pipeline.
			trail_node.update_trail(world_pos, fwd, fwd * 60000.0, true, 1.0, 0.016)
	_set_glows.call(2.0, Color.CYAN)
	for _w2 in range(wait_frames):
		await get_tree().process_frame

	# --- Pass 3: boost/full-power variant ---
	if ship_model and get("thruster_trails"):
		for t_data in get("thruster_trails"):
			if typeof(t_data) != TYPE_DICTIONARY: continue
			var trail_node = t_data.get("node")
			var offset = t_data.get("offset", Vector3.ZERO)
			if not is_instance_valid(trail_node): continue
			var world_pos: Vector3 = ship_model.global_transform * offset
			trail_node.update_trail(world_pos, fwd, fwd * 120000.0, false, 1.0, 0.016)
	_set_glows.call(3.5, Color(1.0, 0.6, 0.1))
	for _w3 in range(wait_frames):
		await get_tree().process_frame

	# --- Pass 4: plasma shard (unshaded + emission StandardMaterial3D) ---
	# Spawn one near the camera so the rasterizer actually compiles its PSO,
	# then queue_free immediately.  The static _shared_shard_mat caches the
	# pipeline for every subsequent shard.
	var prewarm_root: Node = get_parent() if get_parent() else self
	if camera and is_instance_valid(camera):
		var shard_pos = camera.global_transform.origin - camera.global_transform.basis.z * 25.0
		_spawn_plasma_shard(shard_pos)
	for _w4 in range(wait_frames):
		await get_tree().process_frame

	# --- Pass 5: laser bolt + explosion (first fire would otherwise stall) ---
	if bolt_script and camera and is_instance_valid(camera):
		var bolt = Area3D.new()
		bolt.set_script(bolt_script)
		prewarm_root.add_child(bolt)
		bolt.global_transform.origin = camera.global_transform.origin - camera.global_transform.basis.z * 30.0
		# Despawn before the bolt's lifetime so it doesn't fly into anything
		# during the loading screen.
		get_tree().create_timer(0.1).timeout.connect(func():
			if is_instance_valid(bolt): bolt.queue_free()
		)

	# Force one explosion FX to compile its multimesh + outline-pass pipeline.
	var ex_script = load("res://src/combat/ExplosionFX.gd")
	if ex_script and camera and is_instance_valid(camera):
		var fx = Node3D.new()
		fx.set_script(ex_script)
		prewarm_root.add_child(fx)
		fx.global_position = camera.global_transform.origin - camera.global_transform.basis.z * 40.0
		fx.set("explosion_scale", 1.0)
	for _w5 in range(wait_frames):
		await get_tree().process_frame

	# --- Clear all trails and dim glow to invisible ---
	if ship_model and get("thruster_trails"):
		for t_data in get("thruster_trails"):
			if typeof(t_data) != TYPE_DICTIONARY: continue
			var trail_node = t_data.get("node")
			if not is_instance_valid(trail_node): continue
			trail_node.points.clear()
			trail_node.mesh_gen.clear_surfaces()
	_set_glows.call(0.0, Color.RED)

# (c) On the Side LLC. and affiliates. Confidential and proprietary.

var _weather_tick: int = 0
func _update_polar_weather(delta: float) -> void:
	if not snow_particles: return
	# MOBILE: Weather classification (nearest planet, archetype) only needs
	# refreshing a few times per second — not every physics tick. Throttle to
	# ~5Hz on mobile, ~15Hz on desktop to save the planet scan + group iteration.
	_weather_tick += 1
	var _w_target: int = 6 if _mobile_perf else 2
	if _weather_tick % _w_target != 0:
		return

	# Detect if we are at a pole of a snowy-capable planet
	var nearest_p = null; var min_d = 1e16
	for p in get_tree().get_nodes_in_group("Planet"):
		var d = p.global_position.distance_to(global_position)
		if d < min_d: min_d = d; nearest_p = p
	
	# Atmospheric Layer: Extend detection	# UNIVERSAL VOID: No atmospheric skyboxes per GEMINI mandates
	# The background color is handled globally by Main.gd (Stark Charcoal)
	# We only handle local lighting/fog here if needed
	pass
	
	if nearest_p and min_d < nearest_p.planet_radius + 60000.0:
		var p_type = nearest_p.get("archetype")
		
		# POLAR vs GLOBAL WEATHER
		var is_polar_only = (p_type == "FROZEN" or p_type == "LUSH" or p_type == "CANDY")
		var global_intensity = 1.0
		if is_polar_only:
			var l_pos = (global_position - nearest_p.global_position).normalized()
			var dot_up = l_pos.dot(nearest_p.global_transform.basis.y)
			global_intensity = smoothstep(0.72, 0.92, abs(dot_up)) # 42-degree frost zone
		
		var alt_mask = 1.0 - smoothstep(15000.0, 45000.0, true_altitude)
		var intensity = global_intensity * alt_mask
		
		# DYNAMIC WEATHER EFFECTS based on Archtype
		var mat = snow_particles.material_override
		if not mat:
			mat = StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			snow_particles.material_override = mat
			
		# MOBILE: Halve the per-archetype budget. Keeps the weather feel but
		# avoids CPUParticles3D transform churn eating our 33ms frame budget.
		var _p_scale: float = 0.4 if _mobile_perf else 1.0
		match p_type:
			"VOLCANIC":
				mat.albedo_color = Color(1.0, 0.35, 0.1) # Glowing Ash
				snow_particles.gravity = Vector3(3.0, -5.0, 3.0) # Floating embers
				snow_particles.amount = int(400 * _p_scale)
			"DESERT":
				mat.albedo_color = Color(0.85, 0.75, 0.5) # Sand
				snow_particles.gravity = Vector3(45.0, -8.0, 15.0) # Horizon-sweeping Wind
				snow_particles.amount = int(1200 * _p_scale)
			"TOXIC", "RADIATED":
				mat.albedo_color = Color(0.35, 0.95, 0.45) # Acid rain
				snow_particles.gravity = Vector3(5.0, -45.0, 5.0) # Heavy fall
				snow_particles.amount = int(1000 * _p_scale)
			"ABYSS":
				mat.albedo_color = Color(0.1, 0.2, 0.3) # Dark mist drops
				snow_particles.gravity = Vector3(2.0, -5.0, 2.0)
				snow_particles.amount = int(600 * _p_scale)
			_: # FROZEN, LUSH, CANDY
				mat.albedo_color = Color.WHITE # Snow
				snow_particles.gravity = Vector3(12.0, -15.0, 5.0)
				snow_particles.amount = int(800 * _p_scale)
				
		snow_particles.emitting = intensity > 0.05
	else:
		snow_particles.emitting = false

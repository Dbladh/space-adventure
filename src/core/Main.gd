
extends Node3D

# Main.gd (Performance Telemetry Edition)
# Managed by THE ARCHITECT.

var diag_label: Label
var retro_node: CanvasLayer = null
var hud_visible: bool = true
var hud_layer: CanvasLayer
var _player_ref: Node = null   # Cached — avoids get_nodes_in_group() every frame
var _hud_tick: int = 0         # HUD update throttle counter

# ATMOSPHERIC REFERENCES
var main_env: WorldEnvironment
var main_sun: DirectionalLight3D
var main_sky_mat: ShaderMaterial
var planet_ref: Node3D
var solar_time: float = 0.0

func _ready() -> void:
	print("--- [DIAGNOSTIC] EXECUTING PERFORMANCE TELEMETRY SYNC ---")
	
	# CAP AT 30 FPS: Doubles the per-frame time budget, smoothing generation stalls
	# and preventing the GPU from burning power rendering frames faster than needed.
	Engine.max_fps = 30
	
	# 1. ATOMIC PURGE
	_purge_ghost_entities()
	
	# 2. HARDENED VIEWPORT / INFINITE TOON SKYBOX
	_setup_stellar_horizon()
	
	# 3. SOLAR GENESIS 
	_setup_hardened_solar_genesis()
	
	# 5. TITAN-WORLD GENESIS
	_setup_titan_planetary()
	
	# 5.5 STELLAR DEBRIS: Asteroid Belt
	_setup_asteroid_belt()
	
	# 6. TITAN TELEMETRY HUD (F3)
	_setup_hardened_diag_hud()
	
	# 7. MATERIALIZE PILOT
	_spawn_ace_pilot(Vector3.ZERO)

func _purge_ghost_entities() -> void:
	for child in get_children():
		if child.name.contains("Player") or child is WorldEnvironment or child is DirectionalLight3D or child.name == "StarSphere":
			child.queue_free()

func _setup_stellar_horizon() -> void:
	var env = WorldEnvironment.new()
	var sky_env = Environment.new()
	sky_env.tonemap_mode = 0 # TONE_MAP_LINEAR (Ensures raw vivid colors aren't washed out)
	sky_env.tonemap_exposure = 1.0
	sky_env.tonemap_white = 1.0
	
	# INFINITE PROCEDURAL TOON SKY
	sky_env.background_mode = Environment.BG_SKY
	var master_sky = Sky.new()
	var sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://src/world/cel_sky.gdshader")
	
	var fn_s = FastNoiseLite.new(); fn_s.noise_type = FastNoiseLite.TYPE_CELLULAR; fn_s.frequency = 0.05
	var nt_s = NoiseTexture2D.new(); nt_s.width = 512; nt_s.height = 512; nt_s.noise = fn_s
	
	var fn_n = FastNoiseLite.new(); fn_n.noise_type = FastNoiseLite.TYPE_SIMPLEX; fn_n.frequency = 0.02
	var nt_n = NoiseTexture2D.new(); nt_n.width = 512; nt_n.height = 512; nt_n.noise = fn_n; nt_n.seamless = true
	
	# MACROSCOPIC CLOUD NOISE: 64^3 costs 8x less VRAM than 128^3 with identical visual quality at sky scale
	var fn_c = FastNoiseLite.new(); fn_c.noise_type = FastNoiseLite.TYPE_SIMPLEX; fn_c.frequency = 0.025; fn_c.fractal_octaves = 2
	var nt_c = NoiseTexture3D.new(); nt_c.width = 64; nt_c.height = 64; nt_c.depth = 64; nt_c.noise = fn_c; nt_c.seamless = true
	
	sky_mat.set_shader_parameter("star_noise", nt_s)
	sky_mat.set_shader_parameter("nebula_noise", nt_n)
	sky_mat.set_shader_parameter("cloud_noise", nt_c)
	
	master_sky.sky_material = sky_mat; sky_env.sky = master_sky
	main_sky_mat = sky_mat
	
	sky_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	sky_env.ambient_light_color = Color("#3A75C4")
	sky_env.ambient_light_energy = 0.65 
	env.environment = sky_env
	add_child(env); move_child(env, 0); main_env = env
	
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	get_viewport().scaling_3d_scale = 0.75 

func _setup_hardened_solar_genesis() -> void:
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 45, 0) 
	
	# WARM SUNLIGHT: Compensates for the new saturated blue shadows
	sun.light_color = Color("#FFF0CE")
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	
	# CEL SHADING OVERRIDES: Razor sharp pixel shadows
	sun.directional_shadow_blend_splits = false
	sun.set("shadow_blur", 0.0)
	
	sun.directional_shadow_max_distance = 6000.0 
	sun.add_to_group("World")
	add_child(sun)
	main_sun = sun

func _setup_titan_planetary() -> void:
	var planet_gen_script = load("res://src/world/PlanetGen.gd")
	if planet_gen_script:
		# MAIN PLANET (75% Scale) — Seed 1001 for deterministic unique terrain+palette
		var planet = Node3D.new(); planet.set_script(planet_gen_script)
		planet.name = "Planet"
		planet.set("planet_radius", 1125000.0)
		planet.set("planet_seed", 1001)  # Deterministic unique terrain noise seed!
		add_child(planet)
		planet.global_position = Vector3(0, 0, -1425000.0)
		planet.add_to_group("World")
		planet_ref = planet
		
		# SECONDARY MOON — Seed 2002 for guaranteed distinct terrain+palette
		var moon = Node3D.new(); moon.set_script(planet_gen_script)
		moon.name = "Moon"
		moon.set("planet_radius", 450000.0)
		moon.set("planet_seed", 2002)  # Guaranteed distinct seed from main planet!
		add_child(moon)
		moon.global_position = Vector3(1800000.0, 400000.0, -1400000.0)
		moon.add_to_group("World")

func _setup_asteroid_belt() -> void:
	var belt_script = load("res://src/world/AsteroidBelt.gd")
	if belt_script and planet_ref:
		var belt = Node3D.new(); belt.set_script(belt_script)
		belt.name = "PlanetaryRingSystem"
		belt.set("belt_seed", 9999)
		# TIGHT PLANETARY RING: Orbiting just above the surface (1,400km - 2,000km)
		# Note: Planet 1 radius is 1,125km.
		belt.set("inner_radius", 1400000.0)
		belt.set("outer_radius", 2000000.0)
		belt.set("thickness", 40000.0) # Compressed vertically for a sharp ring look
		belt.set("count", 3000)
		add_child(belt)
		belt.global_position = planet_ref.global_position
		belt.add_to_group("World")

func _setup_hardened_diag_hud() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.layer = 100 
	diag_label = Label.new()
	diag_label.position = Vector2(20, 20)
	diag_label.add_theme_font_size_override("font_size", 20)
	diag_label.add_theme_color_override("font_color", Color.CHARTREUSE)
	hud_layer.add_child(diag_label)
	add_child(hud_layer)

func _spawn_ace_pilot(pos: Vector3) -> void:
	var player_scene = load("res://src/combat/Player.tscn")
	if player_scene:
		var player = player_scene.instantiate()
		player.name = "AcePlayer"; add_child(player)
		player.global_position = pos
		var origin = get_tree().get_first_node_in_group("FloatingOrigin")
		if origin: origin.player_node = player

func _process(_delta: float) -> void:
	# Cache player reference — group scans are expensive; only search once
	if not _player_ref or not is_instance_valid(_player_ref):
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: _player_ref = found[0]
		else: return
	var p = _player_ref
	
	# ASTROMETRY & ATMOSPHERIC TRANSITION (every frame — needed for smooth sky blend)
	var alt_m = 100000.0
	if "target_planet" in p and p.target_planet: 
		alt_m = p.true_altitude
	_update_atmospheric_transition(p)
	_update_shadow_distance(p)
	
	if not hud_visible or not diag_label: return
	
	# HUD THROTTLE: Rebuild text only every 3 frames.
	# String construction + label reflow is surprisingly expensive at 60fps.
	_hud_tick += 1
	if _hud_tick < 3: return
	_hud_tick = 0
	
	var alt = floor(alt_m / 1000.0)
	var speed = floor(p.velocity.length() if "velocity" in p else 0.0)
	
	# TITAN TELEMETRY DATA
	var fps = Performance.get_monitor(Performance.TIME_FPS)
	var m_time = Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var draws = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var objs = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var vram = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024 * 1024)
	var ram = Performance.get_monitor(Performance.MEMORY_STATIC) / (1024 * 1024)
	
	var act = ""
	if "in_ship" in p:
		if p.in_ship:
			if p.true_altitude < 500.0: act = " | [E] TO DISEMBARK"
		else:
			var dist = p.global_position.distance_to(p.parked_ship.global_position) if p.parked_ship else 1000.0
			var fuel = floor(p.jetpack_fuel) if "jetpack_fuel" in p else 100
			act = " | JETPACK FUEL: %d%%" % fuel
			if dist < 80.0: act += " | [E] TO EMBARK"
			else: act += " | SHIP OUT OF RANGE"
			
	diag_label.text = (
		"STARHAWK INTERCEPTOR | TITAN TELEMETRY (F3)\n" +
		"-----------------------------------------\n" +
		"ALTITUDE: %dkm | SPEED: %dkm/s\n" +
		"FPS: %d (%.2fms)\n" +
		"GPU DRAWS: %d | OBJS: %d\n" +
		"VRAM: %dMB | RAM: %dMB\n" +
		"VISOR: [V] | MOUSE: [ESC]%s"
	) % [alt, floor(speed/1000.0), fps, m_time, draws, objs, vram, ram, act]
	
	# SOLAR ORBIT: Slowly rotate the sun around the world axis
	# This creates a dynamic day/night cycle and shifts the planetary shadows perfectly.
	solar_time += _delta * 0.005 # Majestic, slow galactic rotation
	if main_sun:
		main_sun.rotation_degrees.y = fmod(solar_time * 30.0, 360.0)
		main_sun.rotation_degrees.x = -45.0 # Fixed tilt for consistent highlight contrast

func _update_atmospheric_transition(p: Node) -> void:
	var alt_m = 100000.0
	var target = null
	if "target_planet" in p and p.target_planet:
		alt_m = p.true_altitude
		target = p.target_planet
		
	# Synchronized Cinematic Exosphere Transition (18km-26km Corridor)
	var space_alt = 26000.0 # 26km - Deep space
	var surface_alt = 18000.0 # 18km - Clean surface atmosphere
	
	var raw_ratio = clamp((alt_m - surface_alt) / (space_alt - surface_alt), 0.0, 1.0) 
	var ratio = raw_ratio * raw_ratio * (3.0 - 2.0 * raw_ratio) # Cubic S-curve smoothing
	
	if main_sky_mat:
		main_sky_mat.set_shader_parameter("space_blend", ratio)
		# UNIQUE PLANETARY SKYBOX
		# Inject the dynamic sunset/zenith colors calculated by the current orbital body
		if target and "sky_horizon_color" in target:
			main_sky_mat.set_shader_parameter("horizon_color", target.sky_horizon_color)
			main_sky_mat.set_shader_parameter("zenith_color", target.sky_zenith_color)
	
	if main_env and main_env.environment:
		var sky_env = main_env.environment
		sky_env.ambient_light_color = Color("#3A75C4").lerp(Color("#0B1021"), ratio)
		sky_env.ambient_light_energy = lerp(0.65, 0.1, ratio)
		
	if main_sun:
		main_sun.light_color = Color("#FFF0CE").lerp(Color.WHITE, ratio)
		main_sun.light_energy = lerp(1.2, 1.6, ratio)

func _update_shadow_distance(p: Node) -> void:
	if not main_sun: return
	# ON FOOT: collapse shadow range to 400m — player can't see shadows beyond nearby terrain.
	# IN SHIP: restore full 6000m for cinematic planetary shadows during flight.
	var on_foot = "in_ship" in p and not p.in_ship
	main_sun.directional_shadow_max_distance = 400.0 if on_foot else 6000.0

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_V: _toggle_retro_vfx()
		if event.keycode == KEY_F3 or event.keycode == KEY_H: _toggle_hud()

func _toggle_hud() -> void:
	hud_visible = !hud_visible
	hud_layer.visible = hud_visible

func _toggle_retro_vfx() -> void:
	if retro_node: retro_node.queue_free(); retro_node = null
	else:
		retro_node = CanvasLayer.new(); retro_node.layer = -1
		var rect = ColorRect.new(); rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var smat = ShaderMaterial.new(); smat.shader = load("res://src/world/retro_vfx.gdshader")
		rect.material = smat; retro_node.add_child(rect); add_child(retro_node)

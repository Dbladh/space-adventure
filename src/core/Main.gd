
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
	
	# 8. TITAN DEVELOPER TOOLS (The Slider Sync)
	_setup_debug_developer_suite()

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
	
	# MACROSCOPIC CLOUD NOISE: 512x512 2D texture restores cinematic FPS and visual continuity
	var fn_c = FastNoiseLite.new(); fn_c.noise_type = FastNoiseLite.TYPE_SIMPLEX; fn_c.frequency = 0.025; fn_c.fractal_octaves = 2
	var nt_c = NoiseTexture2D.new(); nt_c.width = 512; nt_c.height = 512; nt_c.noise = fn_c; nt_c.seamless = true
	
	sky_mat.set_shader_parameter("star_noise", nt_s)
	sky_mat.set_shader_parameter("nebula_noise", nt_n)
	sky_mat.set_shader_parameter("cloud_noise", nt_c)
	
	master_sky.sky_material = sky_mat; sky_env.sky = master_sky
	main_sky_mat = sky_mat
	
	sky_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Warm neutral ambient so shadow-side terrain reads as dark amber, not pitch black
	sky_env.ambient_light_color = Color("#C8B89A")
	sky_env.ambient_light_energy = 1.1
	
	# BOTW-STYLE ATMOSPHERIC HAZE: Exponential distance fog for aerial perspective
	# This will fade distant mountains into a soft haze, giving enormous perceived depth
	sky_env.fog_enabled = true
	sky_env.fog_light_color = Color(0.72, 0.82, 0.95)  # Soft sky blue starter — updated per planet
	sky_env.fog_light_energy = 0.4  # Low enough that OmniLights don't expose cluster tile boundaries
	sky_env.fog_density = 0.0   # Start at 0, updated per-frame in _update_atmospheric_transition
	sky_env.fog_aerial_perspective = 0.3  # Subtle sky blend — only affects very distant horizon
	sky_env.fog_sun_scatter = 0.25  # Warm glow near the sun direction for golden horizon feel
	env.environment = sky_env
	add_child(env); move_child(env, 0); main_env = env
	
	get_viewport().scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	get_viewport().scaling_3d_scale = 0.75 

func _setup_hardened_solar_genesis() -> void:
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 45, 0) 
	
	# WARM SUNLIGHT: Slightly reduced to balance the brighter ambient fill
	sun.light_color = Color("#FFF0CE")
	sun.light_energy = 0.90
	sun.shadow_enabled = true
	
	# ACE SHADOW LOD: 4-Split CSM (Cascaded Shadow Maps) for proximity fidelity
	# High quality near player, low fidelity for distant horizon silhouettes
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_split_1 = 0.05 # Near focus (High Detail)
	sun.directional_shadow_split_2 = 0.15
	sun.directional_shadow_split_3 = 0.45 # Far focus
	
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	sun.set("shadow_blur", 3.5) # Noticeably softer shadow edges on the terrain cliffs
	sun.shadow_bias = 0.12
	sun.shadow_normal_bias = 4.0 
	
	sun.directional_shadow_max_distance = 8000.0 
	sun.add_to_group("World")
	add_child(sun)
	main_sun = sun

func _setup_titan_planetary() -> void:
	var planet_gen_script = load("res://src/world/PlanetGen.gd")
	if planet_gen_script:
		# -----------------------------------------------------------------------
		# GALAXY REGISTRY — THE ARCHITECT
		# Solar system of 4 bodies, each with a unique seed ensuring distinct
		# terrain noise, palette, and landmark placement per celestial body.
		# Positions form a natural inner-system arc at varied orbital inclinations.
		# -----------------------------------------------------------------------

		# PLANET 1 — Hero World (seed 1001) — Main landable planet near origin
		var planet = Node3D.new(); planet.set_script(planet_gen_script)
		planet.name = "Planet_Varn"
		planet.set("planet_radius", 1125000.0)
		planet.set("planet_seed", 1001)
		add_child(planet)
		# Varn: 1.5Mkm forward (–Z) — the home world directly ahead at game start
		planet.global_position = Vector3(0, 0, -1500000.0)
		planet.add_to_group("World")
		planet_ref = planet

		# PLANET 2 — Tethys (seed 2002)
		var moon = Node3D.new(); moon.set_script(planet_gen_script)
		moon.name = "Planet_Tethys"
		moon.set("planet_radius", 625000.0)
		moon.set("planet_seed", 2002)
		add_child(moon)
		moon.global_position = Vector3(2500000.0, 400000.0, -1800000.0)
		moon.add_to_group("World")

		# PLANET 3 — Keth (seed 3003)
		var planet3 = Node3D.new(); planet3.set_script(planet_gen_script)
		planet3.name = "Planet_Keth"
		planet3.set("planet_radius", 820000.0)
		planet3.set("planet_seed", 3003)
		add_child(planet3)
		planet3.global_position = Vector3(-3500000.0, -800000.0, 2800000.0)
		planet3.add_to_group("World")

		# PLANET 4 — Ido (seed 4004)
		var planet4 = Node3D.new(); planet4.set_script(planet_gen_script)
		planet4.name = "Planet_Ido"
		planet4.set("planet_radius", 380000.0)
		planet4.set("planet_seed", 4004)
		add_child(planet4)
		planet4.global_position = Vector3(1800000.0, 300000.0, 450000.0)
		planet4.add_to_group("World")

		# --- OUTER SYSTEM (Compressed) ---

		# PLANET 5 — Obsidia (seed 5005)
		var planet5 = Node3D.new(); planet5.set_script(planet_gen_script)
		planet5.name = "Planet_Obsidia"
		planet5.set("planet_radius", 1850000.0)
		planet5.set("planet_seed", 5005)
		add_child(planet5)
		planet5.global_position = Vector3(-5000000.0, 1500000.0, -6800000.0)
		planet5.add_to_group("World")

		# PLANET 6 — Xylos (seed 6006)
		var planet6 = Node3D.new(); planet6.set_script(planet_gen_script)
		planet6.name = "Planet_Xylos"
		planet6.set("planet_radius", 940000.0)
		planet6.set("planet_seed", 6006)
		add_child(planet6)
		planet6.global_position = Vector3(8500000.0, -2200000.0, 5200000.0)
		planet6.add_to_group("World")

		# PLANET 7 — Beryll (seed 7007)
		var planet7 = Node3D.new(); planet7.set_script(planet_gen_script)
		planet7.name = "Planet_Beryll"
		planet7.set("planet_radius", 2400000.0)
		planet7.set("planet_seed", 7007)
		add_child(planet7)
		planet7.global_position = Vector3(-12000000.0, 3500000.0, 11500000.0)
		planet7.add_to_group("World")

		# PLANET 8 — Null-9 (seed 8008)
		var planet8 = Node3D.new(); planet8.set_script(planet_gen_script)
		planet8.name = "Planet_Null9"
		planet8.set("planet_radius", 450000.0)
		planet8.set("planet_seed", 8008)
		add_child(planet8)
		planet8.global_position = Vector3(4000000.0, -8500000.0, -19500000.0)
		planet8.add_to_group("World")

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
	
	# SOLAR ORBIT: FROZEN FOR CINEMATIC STABILITY
	# This creates a static, iconic high-contrast lighting environment.
	if main_sun:
		main_sun.rotation_degrees.y = 45.0 # Fixed iconic highlight angle
		main_sun.rotation_degrees.x = -45.0 

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
	var lighting_ratio = raw_ratio * raw_ratio * (3.0 - 2.0 * raw_ratio) # Real altitude ratio for lighting
	
	if main_sky_mat:
		main_sky_mat.set_shader_parameter("space_blend", 1.0) # Always space — clouds are the sky now
	
	if main_env and main_env.environment:
		var sky_env = main_env.environment
		# ACE: Use altitude-based ratio for lighting so surface gets warm ambient fill
		# Surface (ratio=0): warm amber ambient at 1.3, good fill for shadow faces
		# Space  (ratio=1): near-black ambient at 0.08, authentic vacuum lighting
		sky_env.ambient_light_color = Color("C8B89A").lerp(Color("0B1021"), lighting_ratio)
		sky_env.ambient_light_energy = lerp(1.3, 0.08, lighting_ratio)
		
		# ATMOSPHERIC HAZE: Drastically reduced density so distant planets remain visible!
		# Godot's exponential fog math completely wipes out geometry > 500km away at normal densities.
		var surface_fog_density = 0.000005
		sky_env.fog_density = lerp(surface_fog_density, 0.0, lighting_ratio)
		sky_env.fog_aerial_perspective = 0.85 # Cranks up horizon haze to compensate for thinner fog
		
		# Tint the fog to the planet's horizon color for per-biome atmosphere feel
		var fog_col = Color(0.72, 0.82, 0.95) # Default sky blue
		if target and "sky_horizon_color" in target:
			# Blend planet color with a bright sky tint so fog stays luminous, not muddy
			fog_col = target.sky_horizon_color.lerp(Color(0.85, 0.90, 1.0), 0.5)
		sky_env.fog_light_color = fog_col
		
	if main_sun:
		main_sun.light_color = Color("#FFF0CE").lerp(Color.WHITE, lighting_ratio)
		main_sun.light_energy = lerp(0.90, 1.6, lighting_ratio)

func _update_shadow_distance(p: Node) -> void:
	if not main_sun: return
	# MACROSCOPIC SHADOW HUD: Increase distance during high-altitude transit
	var on_foot = "in_ship" in p and not p.in_ship
	main_sun.directional_shadow_max_distance = 800.0 if on_foot else 8000.0

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_V: _toggle_retro_vfx()
		if event.keycode == KEY_F3 or event.keycode == KEY_H: _toggle_hud()
		if event.keycode == KEY_F4: _toggle_debug_suite()

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

var _debug_panel: Control = null
func _setup_debug_developer_suite() -> void:
	var canvas = CanvasLayer.new(); canvas.layer = 120; add_child(canvas)
	var panel = PanelContainer.new(); canvas.add_child(panel); _debug_panel = panel
	
	# STYLEBOX SYNC: Deep charcoal background for elite visibility
	var sb = StyleBoxFlat.new(); sb.bg_color = Color(0.1, 0.1, 0.1, 0.95); sb.set_corner_radius_all(10); sb.set_expand_margin_all(20.0); panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(460, 240) # TITANIC SCALE SYNC
	
	# CENTER-STAGE PRESET: Robust G4 anchor logic definitive visibility
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_KEEP_WIDTH, 150)
	
	var vb = VBoxContainer.new(); panel.add_child(vb)
	var title = Label.new(); vb.add_child(title); title.text = "--- TITAN DEVELOPER TOOLS (F4) ---"; title.add_theme_color_override("font_color", Color.CHARTREUSE); title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	
	# INTERACTION HARDENING: Large targets for easy control
	var t_box = HBoxContainer.new(); vb.add_child(t_box); t_box.add_child(Label.new()); t_box.get_child(0).text = "Trees: "
	var t_sli = HSlider.new(); t_box.add_child(t_sli); t_sli.min_value = 0.1; t_sli.max_value = 2.0; t_sli.value = 1.0; t_sli.custom_minimum_size.x = 250; t_sli.size_flags_horizontal = 3; t_sli.value_changed.connect(func(v): DebugSettings.tree_mult = v)
	var r_box = HBoxContainer.new(); vb.add_child(r_box); r_box.add_child(Label.new()); r_box.get_child(0).text = "Rocks: "
	var r_sli = HSlider.new(); r_box.add_child(r_sli); r_sli.min_value = 0.1; r_sli.max_value = 2.0; r_sli.value = 1.0; r_sli.custom_minimum_size.x = 250; r_sli.size_flags_horizontal = 3; r_sli.value_changed.connect(func(v): DebugSettings.rock_mult = v)
	var c_box = HBoxContainer.new(); vb.add_child(c_box); c_box.add_child(Label.new()); c_box.get_child(0).text = "Chaos: "
	var c_sli = HSlider.new(); c_box.add_child(c_sli); c_sli.min_value = 0.1; c_sli.max_value = 2.0; c_sli.value = 1.0; c_sli.custom_minimum_size.x = 250; c_sli.size_flags_horizontal = 3; c_sli.value_changed.connect(func(v): DebugSettings.terrain_complexity = v)
	
	var btn = Button.new(); vb.add_child(btn); btn.text = "APPLY & REGENERATE WORLD"; btn.pressed.connect(func(): DebugSettings.emit_rebuild())
	panel.visible = false

func _toggle_debug_suite() -> void:
	if not _debug_panel: return
	_debug_panel.visible = !_debug_panel.visible
	if _debug_panel.visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

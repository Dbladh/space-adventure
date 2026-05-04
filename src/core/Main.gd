extends Node3D
class_name Main

# Main.gd (Performance Telemetry Edition)
# Managed by THE ARCHITECT.

var diag_label: Label
var retro_node: CanvasLayer = null
var hud_visible: bool = true
var diag_visible: bool = false
var hud_layer: CanvasLayer
var _player_ref: Node = null   # Cached — avoids get_nodes_in_group() every frame
var map_node: Control = null

# ATMOSPHERIC REFERENCES
var main_env: WorldEnvironment
var main_sun: DirectionalLight3D
var main_sky_mat: ShaderMaterial
var planet_ref: Node3D
var world_root: Node3D  # O(1) World Shifting Root
var benchmark_manager: Node = null
var _mineral_spawn_queue: Array = []
static var instance: Node = null
var player_node: Node3D
var _pause_overlay: ColorRect = null
var _is_loading: bool = true
var _load_overlay: ColorRect = null
var _load_label: Label = null
var _load_progress: float = 0.0
var _is_finishing: bool = false
var _boot_timer: float = 0.5 # Mandatory settle time
var _mobile_perf_mode: bool = false
var music_director: Node = null

static var _r_cache: Dictionary = {}
static func _get_res(path: String) -> Resource:
	if not _r_cache.has(path): _r_cache[path] = load(path)
	return _r_cache[path]
static func _get_tex(path: String) -> Texture2D:
	return _get_res(path) as Texture2D

func _ready() -> void:
	instance = self
	# Do NOT set PROCESS_MODE_ALWAYS here — that would propagate to ALL children
	# (Player, physics, enemies) and prevent get_tree().paused from working.
	# Only specific UI nodes (MobileControlsUI, GalaxyMapUI, _pause_overlay) need ALWAYS.
	_mobile_perf_mode = OS.get_name() == "iOS" or OS.has_feature("mobile")
	if _mobile_perf_mode:
		DebugSettings.terrain_complexity = 0.8
	print("--- [DIAGNOSTIC] EXECUTING TITAN GENESIS BOOT SEQUENCE ---")
	_setup_titan_splash()
	
	# ... existing initialization ...
	# CELESTIAL HEADROOM: Increase engine ceiling to 60fps to provide the budget
	# needed for 30fps quantization without stuttering.
	# MOBILE LOCK: iOS/Android run a hard 30fps cap (with matching physics tick)
	# to fit within A14-class thermal/power budgets and avoid hitches.
	# Desktop still runs 60fps ceiling.
	if _mobile_perf_mode:
		Engine.max_fps = 30
		Engine.physics_ticks_per_second = 30
	else:
		Engine.max_fps = 60
	
	# ECONOMY GENESIS: The Architect's Vault
	var econ_script = load("res://src/core/EconomyManager.gd")
	if econ_script:
		var econ = econ_script.new()
		econ.name = "EconomyManager"
		add_child(econ)
		Engine.set_meta("EconomyManager", econ)

	# INVENTORY GENESIS: Resource stacks
	var inv_script = load("res://src/core/InventoryManager.gd")
	if inv_script:
		var inv = inv_script.new()
		inv.name = "InventoryManager"
		add_child(inv)
		Engine.set_meta("InventoryManager", inv)
	
	# 1. ATOMIC PURGE
	_purge_ghost_entities()
	
	# 2. HARDENED VIEWPORT / INFINITE TOON SKYBOX
	_setup_stellar_horizon()
	
	# 3. SOLAR GENESIS 
	_setup_hardened_solar_genesis()
	
	# 4. TITAN-WORLD ROOT
	world_root = Node3D.new()
	world_root.name = "WorldRoot"
	world_root.add_to_group("WorldRoot")
	add_child(world_root)
	
	# 5. TITAN-WORLD GENESIS
	_setup_titan_planetary()
	
	# 5.5 STELLAR DEBRIS: Asteroid Belt
	_setup_asteroid_belt()

	# 5.6 SPACE STATION
	_setup_space_station()
	
	# 6. TITAN TELEMETRY HUD (F3)
	_setup_hardened_diag_hud()
	
	# 7. MATERIALIZE PILOT
	_spawn_ace_pilot(Vector3.ZERO)
	
	# 8. PROCEDURAL MUSIC DIRECTOR
	_setup_music_director()

	# 9. TITAN DEVELOPER TOOLS (The Slider Sync)
	_setup_debug_developer_suite()
	
	# 10. SHADOWGLASS SIGNATURE: Default to Retro Mode
	_toggle_retro_vfx()

	# 11. BENCHMARK UTILITY
	benchmark_manager = load("res://src/tests/BenchmarkManager.gd").new()
	add_child(benchmark_manager)

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
	# MOBILE: load a stripped sky variant (1 cloud lookup vs 5, no trig phasing,
	# no starburst). Keeps the same uniform interface so the per-frame
	# space_blend / atmospheric updates work unchanged.
	var _sky_path := "res://src/world/cel_sky_mobile.gdshader" if _mobile_perf_mode else "res://src/world/cel_sky.gdshader"
	sky_mat.shader = load(_sky_path)
	
	var fn_s = FastNoiseLite.new(); fn_s.noise_type = FastNoiseLite.TYPE_CELLULAR; fn_s.frequency = 0.05
	var sky_tex_size = 256 if _mobile_perf_mode else 512
	var nt_s = NoiseTexture2D.new(); nt_s.width = sky_tex_size; nt_s.height = sky_tex_size; nt_s.noise = fn_s
	
	var fn_n = FastNoiseLite.new(); fn_n.noise_type = FastNoiseLite.TYPE_SIMPLEX; fn_n.frequency = 0.02
	var nt_n = NoiseTexture2D.new(); nt_n.width = sky_tex_size; nt_n.height = sky_tex_size; nt_n.noise = fn_n; nt_n.seamless = true
	
	# MACROSCOPIC CLOUD NOISE: Mobile uses a smaller source texture to cut startup and shader cost
	var fn_c = FastNoiseLite.new(); fn_c.noise_type = FastNoiseLite.TYPE_SIMPLEX; fn_c.frequency = 0.025; fn_c.fractal_octaves = 2
	var nt_c = NoiseTexture2D.new(); nt_c.width = sky_tex_size; nt_c.height = sky_tex_size; nt_c.noise = fn_c; nt_c.seamless = true
	
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
	# CINEMATIC BLOOM: Critical for energy bolt visibility in Retro/Pixelated modes.
	# MOBILE: Glow is one of the most expensive post effects on tiled-GPU chips
	# (A14/A15). Disable entirely on iOS/Android — the flat toon look holds up.
	if not _mobile_perf_mode:
		sky_env.glow_enabled = true
		sky_env.glow_intensity = 0.8
		sky_env.glow_strength = 1.0
		sky_env.glow_bloom = 0.4
		sky_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	else:
		sky_env.glow_enabled = false
	
	env.environment = sky_env
	add_child(env); move_child(env, 0); main_env = env
	
	var vp = get_viewport()
	# ACE EXTREME RETRO SCALING: 25% internal resolution (Super-Chunky)
	# This drastically reduces fragment shader pressure while leaning into the aesthetic.
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	# MOBILE: Drop to 15% internal resolution on iOS so iPhone 12-class GPUs
	# can maintain a locked 30fps under planet-scale fragment loads.
	# The FSR upscale + nearest-neighbour filter keeps the toon look readable.
	vp.scaling_3d_scale = 0.15 if _mobile_perf_mode else 0.25
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	if _mobile_perf_mode:
		# MSAA is cheap on desktop but very expensive on tiled-GPU chips
		vp.msaa_3d = Viewport.MSAA_DISABLED
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
		vp.use_debanding = false
		vp.use_taa = false

func _setup_titan_splash() -> void:
	_load_overlay = ColorRect.new()
	_load_overlay.color = Color("#080808")
	_load_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	var canvas = CanvasLayer.new()
	canvas.layer = 120 # Above HUD
	canvas.add_child(_load_overlay)
	
	_load_label = Label.new()
	_load_label.text = "TITAN UNIVERSAL GENESIS - BOOTING..."
	_load_label.add_theme_font_size_override("font_size", 32)
	_load_label.add_theme_color_override("font_color", Color.CHARTREUSE)
	_load_overlay.add_child(_load_label)
	_load_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	
	add_child(canvas)

func _finish_loading() -> void:
	if _is_finishing: return
	_is_finishing = true
	
	print("--- ARCHITECT: Universe is Ready ---")
	
	# Release Player IMMEDIATELY so interaction feels snappy
	if player_node:
		player_node.set_physics_process(true)
		player_node.set_process(true)
		if player_node.has_method("prewarm_vfx"):
			await player_node.prewarm_vfx()
	
	var t = create_tween()
	t.tween_property(_load_overlay, "modulate:a", 0.0, 1.0).set_trans(Tween.TRANS_SINE).set_delay(0.2)
	t.tween_callback(func():
		_is_loading = false
		_load_overlay.get_parent().queue_free()
	)

func _setup_hardened_solar_genesis() -> void:
	# ACE: Force the minimalist 'Shadowglass' environment
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.06, 0.08) # Stark Charcoal Void
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.1, 0.1, 0.1)
	
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 45, 0) 
	sun.light_color = Color("#FFF0CE")
	sun.light_energy = 1.4
	sun.shadow_enabled = not _mobile_perf_mode
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_blend_splits = false # Sharp splits for that retro feel
	sun.directional_shadow_max_distance = 2500.0 if _mobile_perf_mode else 6500.0 
	
	sun.add_to_group("World")
	add_child(sun)
	main_sun = sun

func _setup_titan_planetary() -> void:
	# Starter planet has been removed per user request.
	pass

func _setup_space_station() -> void:
	# Planet_Varn: centre (0,0,-1,500,000), radius 1,125,000m, belt to ~2,625,000m.
	# Stations are ~300 km across so the POI beacon height must exceed their radius.

	# 1. Orbital — Near side of Planet_Varn, offset so it doesn't trigger UI at spawn.
	#    Positioned at ~943km from player spawn, easily visible, clearing the atmosphere.
	_spawn_station("Orbital",
		Vector3(800_000, 400_000, -300_000),
		Color(0.3, 1.0, 0.5))   # green — the "home" station

	# 2. Alpha — deep space along -Z, far from the belt
	_spawn_station("Alpha",
		Vector3(0, 0, -3_500_000),
		Color(0.3, 0.8, 1.0))   # cyan

	# 3. Beta — off in another quadrant
	_spawn_station("Beta",
		Vector3(-3_000_000, 600_000, -2_000_000),
		Color(0.9, 0.5, 1.0))   # purple

func _spawn_station(display_name: String, pos: Vector3, beacon_col: Color) -> void:
	var ss_script = load("res://src/world/SpaceStation.gd")
	if not ss_script: return
	var station := Node3D.new()
	station.set_script(ss_script)
	station.name = "SpaceStation_" + display_name
	station.set("station_display_name", display_name)
	station.add_to_group("SpaceStation")
	world_root.add_child(station)
	station.global_position = pos

	var marker_script = load("res://src/ui/POIMarker.gd")
	if marker_script:
		var marker := Node3D.new()
		marker.set_script(marker_script)
		# Beacon column height well above the 215 km ring radius
		marker.call_deferred("setup", display_name + " Station", "station", 600_000.0, beacon_col)
		station.add_child(marker)

func _setup_asteroid_belt() -> void:
	var belt_script = load("res://src/world/AsteroidBelt.gd")
	if belt_script:
		var belt = Node3D.new(); belt.set_script(belt_script)
		belt.name = "DeepSpaceAsteroidBelt"
		belt.set("belt_seed", 9999)
		# DEEP SPACE BELT:
		belt.set("inner_radius", 1400000.0)
		belt.set("outer_radius", 2000000.0)
		belt.set("thickness", 40000.0)
		belt.set("count", 1800 if _mobile_perf_mode else 3000)
		belt.set("mmi_count", 8000 if _mobile_perf_mode else 14000)
		belt.set("phys_count", 240 if _mobile_perf_mode else 500)
		belt.set("mobile_perf", _mobile_perf_mode)
		world_root.add_child(belt)
		belt.global_position = Vector3(0, 0, -1500000.0)
		belt.add_to_group("World")
		
	# DEEP SPACE SALVAGE: Rare minerals floating in the void
	_setup_deep_space_minerals()

func _setup_deep_space_minerals() -> void:
	var m_script = _get_res("res://src/world/MineableResource.gd")
	if not m_script: return
	
	var types = ["Copper", "Silver", "Gold", "Platinum", "Diamond"]
	var rng = RandomNumberGenerator.new(); rng.seed = 77777 
	
	# ACE: We queue these for staggered spawning to prevent Physics Server lock-up
	# MOBILE: Cut from 250 → 80 minerals on iOS; each mineral carries an OmniLight3D
	# + SubViewport HUD, so count directly drives draw calls and touch latency.
	var _mineral_count = 80 if _mobile_perf_mode else 250
	for i in range(_mineral_count):
		var type_idx = 0
		var r = rng.randf()
		if r > 0.98: type_idx = 4
		elif r > 0.90: type_idx = 3
		elif r > 0.75: type_idx = 2
		elif r > 0.5: type_idx = 1
		else: type_idx = 0
		
		# Scatter in the inner system
		var pos = Vector3(rng.randf_range(-1,1), rng.randf_range(-0.3, 0.3), rng.randf_range(-1,1)).normalized()
		var g_pos = pos * rng.randf_range(2000000.0, 15000000.0)
		_mineral_spawn_queue.append({"type": types[type_idx], "pos": g_pos, "script": m_script})

func _setup_hardened_diag_hud() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.layer = 125
	hud_layer.add_to_group("GameHUD")
	diag_label = Label.new()
	# ACE: Safe Area Padding for iPhone 15 (Dynamic Island fallback)
	diag_label.position = Vector2(80, 40)
	diag_label.add_theme_font_size_override("font_size", 20)
	diag_label.add_theme_color_override("font_color", Color.CHARTREUSE)
	hud_layer.add_child(diag_label)
	diag_label.visible = diag_visible
	
	# ACE ECONOMY: Real-time Credit Display
	var creds = Label.new(); creds.name = "CreditLabel"
	creds.text = "$0"
	creds.add_theme_font_size_override("font_size", 72) # ACE: 2x Scale Upgrade
	creds.add_theme_color_override("font_color", Color.GOLD)
	hud_layer.add_child(creds)
	# Position directly below the Health Bar (Top Center)
	creds.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE, 0)
	creds.position.y = 120.0 # Lowered to avoid Dynamic Island
	creds.grow_horizontal = Control.GROW_DIRECTION_BOTH
	
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.currency_changed.connect(func(n): creds.text = "$" + str(n))

	# INVENTORY ROW: Shows resource stacks below the credit counter
	var inv_label = Label.new(); inv_label.name = "InventoryLabel"
	inv_label.text = ""
	inv_label.add_theme_font_size_override("font_size", 28)
	inv_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	hud_layer.add_child(inv_label)
	inv_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE, 0)
	inv_label.position.y = 200.0
	inv_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		var _refresh_inv = func(_type: String, _amt: int) -> void:
			var all = inv.get_all()
			var parts: Array[String] = []
			for r in ResourceRegistry.all_names():
				if all.get(r, 0) > 0:
					parts.append(ResourceRegistry.get_abbrev(r) + ":" + str(all[r]))
			inv_label.text = "  ".join(parts)
		inv.inventory_changed.connect(_refresh_inv)

	# NAVIGATION BEACON: Compact corner widget — bearing + distance to nearest station.
	# Positioned below RECENTER GYRO (which ends at roughly y=90 on most screens).
	var beacon_script = load("res://src/ui/NavBeacon.gd")
	if beacon_script:
		var beacon = Control.new()
		beacon.set_script(beacon_script)
		beacon.set_anchors_preset(Control.PRESET_TOP_LEFT)
		beacon.custom_minimum_size = Vector2(200, 90)
		beacon.position = Vector2(8, 100)
		hud_layer.add_child(beacon)

	# SCREEN-SPACE POI HUD: NMS-style markers for all stations and planets.
	var poi_hud_script = load("res://src/ui/ScreenPOIHUD.gd")
	if poi_hud_script:
		var poi_hud = Control.new()
		poi_hud.set_script(poi_hud_script)
		poi_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		poi_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud_layer.add_child(poi_hud)

	# ACE NAVIGATION: Inject the tactical galaxy map into the HUD
	var map_script = load("res://src/ui/GalaxyMapUI.gd")
	if map_script:
		map_node = Control.new()
		map_node.set_script(map_script)
		map_node.custom_minimum_size = Vector2(480, 480)
		hud_layer.add_child(map_node)
		_reset_map_to_corner()
		map_node.hide() # ACE: Hidden during normal play
	
	_pause_overlay = ColorRect.new()
	_pause_overlay.color = Color(0, 0, 0, 0.55)
	_pause_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_pause_overlay.process_mode = PROCESS_MODE_ALWAYS
	_pause_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE  # let MobileControlsUI handle touches
	hud_layer.add_child(_pause_overlay)
	_pause_overlay.hide()

	add_child(hud_layer)

func _spawn_ace_pilot(pos: Vector3) -> void:
	var player_scene = load("res://src/combat/Player.tscn")
	if player_scene:
		var player = player_scene.instantiate()
		player.name = "AcePlayer"; add_child(player)
		player_node = player
		player.global_position = pos
		var origin = get_tree().get_first_node_in_group("FloatingOrigin")
		if origin: 
			origin.player_node = player
			origin.world_root = world_root

func _setup_music_director() -> void:
	var md_script = load("res://src/audio/MusicDirector.gd")
	if md_script:
		music_director = md_script.new()
		music_director.name = "MusicDirector"
		add_child(music_director)

func _process(_delta: float) -> void:
	# ACE TITAN INITIALIZATION: Track time immediately
	if _boot_timer > 0:
		_boot_timer -= _delta
		return
		
	# ACE: Spawn minerals and check readiness BEFORE any early-returns
	var batch_size = 50 if _is_loading else 15
	for i in range(min(_mineral_spawn_queue.size(), batch_size)):
		var data = _mineral_spawn_queue.pop_back()
		var mineral = StaticBody3D.new()
		mineral.set_script(data.script)
		mineral.set("resource_type", data.type)
		world_root.add_child(mineral)
		mineral.global_position = data.pos
	
	# Check if all planets have finished their staggered initialization
	var all_ready = _mineral_spawn_queue.is_empty()
	var planets = get_tree().get_nodes_in_group("Planet")
	for pl in planets:
		if pl.get("_prewarm_count") < pl.get("_prewarm_target"):
			all_ready = false
			break
	
	if _is_loading:
		if all_ready:
			_finish_loading()
		else:
			var _mtotal = 80 if _mobile_perf_mode else 250
			_load_label.text = "CALIBRATING QUANTUM FIELD: %d%%" % (100 - _mineral_spawn_queue.size() * 100 / max(_mtotal, 1))
		return # Stay focused on loading

	# HUD & TELEMETRY LOGIC (Runs only after loading is done)
	if not _player_ref or not is_instance_valid(_player_ref):
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: _player_ref = found[0]
		else: return
	
	var p = _player_ref
	
	# ACE: Always calculate altitude for HUD telemetry
	var alt_m: float = 100000.0
	if "target_planet" in p and p.target_planet: 
		alt_m = p.true_altitude

	# 1. OPTIMIZED TELEMETRY: Throttle the heavy environmental updates.
	# MOBILE: Drop atmospheric + shadow updates to ~5Hz so the string/shader
	# parameter churn doesn't collide with the 30fps render pacing.
	# STAGGER: Use Engine.get_process_frames() with offset phases so env and
	# hud rebuilds NEVER land on the same frame (mobile: env=phase 0, hud=phase 3
	# of a 6-frame cycle → zero overlap, halves the worst-case spike).
	var fr := Engine.get_process_frames()
	var _env_target: int = 6 if _mobile_perf_mode else 4
	if fr % _env_target == 0:
		_update_atmospheric_transition(p)
		_update_shadow_distance(p)

	if not hud_visible or not diag_label: return

	# HUD THROTTLE: Rebuild text only every N frames.
	# String construction + label reflow is surprisingly expensive at 60fps.
	# MOBILE: Stretch to 6 frames — telemetry readability is fine at ~5Hz.
	var _hud_target: int = 6 if _mobile_perf_mode else 3
	var _hud_phase: int = 3 if _mobile_perf_mode else 2
	if (fr + _hud_phase) % _hud_target != 0: return
	
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
			
	var q_f = 0; var q_d = 0; var q_z = 0
	# ACE TELEMETRY SYNC: Reuse planets from genesis check
	for pl in planets:
		if "finalize_queue" in pl: q_f += pl.finalize_queue.size()
		if "death_row" in pl: q_d += pl.death_row.size()
		if "zombie_pool" in pl: q_z += pl.zombie_pool.size()

	diag_label.text = (
		"STARHAWK INTERCEPTOR | TITAN TELEMETRY (F3)\n" +
		"-----------------------------------------\n" +
		"ALTITUDE: %dkm | SPEED: %dkm/s\n" +
		"FPS: %d (%.2fms) | QUEUES: F:%d D:%d Z:%d\n" +
		"GPU DRAWS: %d | OBJS: %d\n" +
		"VRAM: %dMB | RAM: %dMB\n" +
		"VISOR: [V] | MOUSE: [ESC]%s"
	) % [alt, floor(speed/1000.0), fps, m_time, q_f, q_d, q_z, draws, objs, vram, ram, act]
	
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
		main_sky_mat.set_shader_parameter("space_blend", lighting_ratio)
	
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
		if event.keycode == KEY_F3: _toggle_diag()
		if event.keycode == KEY_H: _toggle_hud()
		if event.keycode == KEY_ENTER: _toggle_map_fullscreen()
		if event.keycode == KEY_F4: _toggle_debug_suite()
		if event.keycode == KEY_R: get_tree().reload_current_scene()
		if event.keycode == KEY_ESCAPE:
			# ACE: Only toggle pause if no other full-screen UI is active.
			# If the game is paused but _pause_overlay is hidden, it means
			# a SpaceStation or Cinematic has the stage.
			if not get_tree().paused or _pause_overlay.visible:
				toggle_pause()
		if event.keycode == KEY_B: 
			if benchmark_manager: benchmark_manager.start_automated_test(_player_ref)

func toggle_pause() -> void:
	if _is_loading: return
	get_tree().paused = !get_tree().paused
	
	if get_tree().paused:
		_pause_overlay.show()
		_toggle_map_fullscreen_to(true)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_pause_overlay.hide()
		_toggle_map_fullscreen_to(false)
		map_node.hide()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _toggle_map_fullscreen_to(active: bool) -> void:
	if not map_node: return
	map_node.visible = active
	map_node.is_fullscreen = active
	if active:
		# PAUSE MAP: 300×300 centred on screen.
		# hud_layer is a CanvasLayer so anchors are relative to the screen rect.
		var map_sz := 300.0
		map_node.custom_minimum_size = Vector2(map_sz, map_sz)
		map_node.anchor_left   = 0.5;  map_node.anchor_right  = 0.5
		map_node.anchor_top    = 0.5;  map_node.anchor_bottom = 0.5
		map_node.offset_left   = -map_sz * 0.5
		map_node.offset_top    = -map_sz * 0.5
		map_node.offset_right  =  map_sz * 0.5
		map_node.offset_bottom =  map_sz * 0.5
	else:
		map_node.custom_minimum_size = Vector2(480, 480)
		_reset_map_to_corner()

func _toggle_hud() -> void:
	hud_visible = !hud_visible
	hud_layer.visible = hud_visible

func _toggle_diag() -> void:
	diag_visible = !diag_visible
	if diag_label: diag_label.visible = diag_visible

func _toggle_map_fullscreen() -> void:
	if not map_node: return
	map_node.is_fullscreen = !map_node.is_fullscreen
	if map_node.is_fullscreen:
		map_node.set_anchors_and_offsets_preset(Control.PRESET_CENTER, Control.PRESET_MODE_MINSIZE, 60)
		map_node.custom_minimum_size = Vector2(800, 800)
		map_node.anchor_left = 0.5; map_node.anchor_top = 0.5; map_node.anchor_right = 0.5; map_node.anchor_bottom = 0.5
		map_node.offset_left = -400; map_node.offset_top = -400
		map_node.offset_right = 400; map_node.offset_bottom = 400
	else:
		map_node.custom_minimum_size = Vector2(480, 480)
		_reset_map_to_corner()

func _reset_map_to_corner() -> void:
	if not map_node: return
	map_node.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	map_node.offset_left = -510 # (480 + 30)
	map_node.offset_top = -510
	map_node.offset_right = -30
	map_node.offset_bottom = -30

func _toggle_retro_vfx() -> void:
	if retro_node: retro_node.queue_free(); retro_node = null
	else:
		retro_node = CanvasLayer.new(); retro_node.layer = 110
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

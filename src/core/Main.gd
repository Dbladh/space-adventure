extends Node3D
class_name Main

# Main.gd (Performance Telemetry Edition)
# Managed by THE ARCHITECT.

const HUDStyle = preload("res://src/ui/HUDStyle.gd")
const ResourceChipScene = preload("res://src/ui/ResourceChip.gd")

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
var _pause_overlay: Control = null  # PauseMenuUI script attached
var _rebind_ui: Control = null      # transient RebindUI instance
var _is_loading: bool = true
var _load_overlay: ColorRect = null
var _load_label: Label = null
var _load_progress: float = 0.0
var _is_finishing: bool = false
var _boot_timer: float = 0.5 # Mandatory settle time
var music_director: Node = null

static var _r_cache: Dictionary = {}
static func _get_res(path: String) -> Resource:
	if not _r_cache.has(path): _r_cache[path] = load(path)
	return _r_cache[path]
static func _get_tex(path: String) -> Texture2D:
	return _get_res(path) as Texture2D

func _ready() -> void:
	instance = self
	Engine.max_fps = 0  # Uncapped — let the monitor's refresh rate govern
	print("--- [DIAGNOSTIC] EXECUTING TITAN GENESIS BOOT SEQUENCE ---")
	# Register remappable input actions (fire/warp/roll_left/roll_right/pause)
	# with default bindings before any subsystem polls Input.is_action_*.
	var ia_script: Script = load("res://src/core/InputActions.gd")
	if ia_script and ia_script.has_method("register_all"):
		ia_script.call("register_all")
	# Pixel-art arcade theme (chunky bevel buttons, CRT-green data panels,
	# Press Start 2P font).  Installed on the root window so any
	# Button/Panel/Label/LineEdit picks it up unless explicitly overridden.
	HUDStyle.apply_default_theme(get_window())
	_setup_titan_splash()
	
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

	# UPGRADE GENESIS: Stat tracks (Attack/Health/Luck/Slots/Movement)
	var up_script = load("res://src/core/UpgradeManager.gd")
	if up_script:
		var up = up_script.new()
		up.name = "UpgradeManager"
		add_child(up)
		Engine.set_meta("UpgradeManager", up)

	# SAVE GENESIS: JSON persistence (user://save.json)
	var save_script = load("res://src/core/SaveManager.gd")
	if save_script:
		var sm = save_script.new()
		sm.name = "SaveManager"
		add_child(sm)
		Engine.set_meta("SaveManager", sm)
		sm.load_if_exists()

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

	# 5.7 REHYDRATE FORGED PLANETS from save (no-op if save was empty).
	# Has to wait until WorldRoot exists and at least one SpaceStation is in
	# the tree (the rehydrate method is an instance method).
	var stations := get_tree().get_nodes_in_group("SpaceStation")
	if stations.size() > 0 and stations[0].has_method("_rehydrate_active_planets"):
		stations[0]._rehydrate_active_planets()

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

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED:
		if Engine.has_meta("SaveManager"):
			Engine.get_meta("SaveManager").save_now()

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
	# Mobile uses the simplified sky variant (same uniform interface).
	# Sky covers the full screen on every frame — even a small per-fragment
	# saving compounds across the entire viewport.
	sky_mat.shader = load("res://src/world/cel_sky_mobile.gdshader" if MobilePerf.is_mobile() else "res://src/world/cel_sky.gdshader")
	
	var fn_s = FastNoiseLite.new(); fn_s.noise_type = FastNoiseLite.TYPE_CELLULAR; fn_s.frequency = 0.05
	var nt_s = NoiseTexture2D.new(); nt_s.width = 512; nt_s.height = 512; nt_s.noise = fn_s
	
	var fn_n = FastNoiseLite.new(); fn_n.noise_type = FastNoiseLite.TYPE_SIMPLEX; fn_n.frequency = 0.02
	var nt_n = NoiseTexture2D.new(); nt_n.width = 512; nt_n.height = 512; nt_n.noise = fn_n; nt_n.seamless = true
	
	var fn_c = FastNoiseLite.new(); fn_c.noise_type = FastNoiseLite.TYPE_SIMPLEX; fn_c.frequency = 0.025; fn_c.fractal_octaves = 2
	var nt_c = NoiseTexture2D.new(); nt_c.width = 512; nt_c.height = 512; nt_c.noise = fn_c; nt_c.seamless = true
	
	sky_mat.set_shader_parameter("star_noise", nt_s)
	sky_mat.set_shader_parameter("nebula_noise", nt_n)
	sky_mat.set_shader_parameter("cloud_noise", nt_c)
	
	master_sky.sky_material = sky_mat; sky_env.sky = master_sky
	main_sky_mat = sky_mat
	
	sky_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Cool blue ambient (pre-regression value) — the warm-beige bump in commit
	# d7fb9a9 ("Shadowglass retro-snapping") combined with the new ambient
	# energy of 1.1 was the main cause of bleach-white planet impostors.
	sky_env.ambient_light_color = Color("#3A75C4")
	sky_env.ambient_light_energy = 0.65
	
	# BOTW-STYLE ATMOSPHERIC HAZE: Exponential distance fog for aerial perspective
	# This will fade distant mountains into a soft haze, giving enormous perceived depth
	sky_env.fog_enabled = true
	sky_env.fog_light_color = Color(0.72, 0.82, 0.95)  # Soft sky blue starter — updated per planet
	sky_env.fog_light_energy = 0.4  # Low enough that OmniLights don't expose cluster tile boundaries
	sky_env.fog_density = 0.0   # Start at 0, updated per-frame in _update_atmospheric_transition
	# Aerial perspective adds a per-pixel sky sample to the fog math — cheap on
	# desktop, but a noticeable hit on mobile tiled renderers. Drop to 0 there.
	sky_env.fog_aerial_perspective = 0.0 if MobilePerf.is_mobile() else 0.3
	sky_env.fog_sun_scatter = 0.25  # Warm glow near the sun direction for golden horizon feel
	# Subtle bloom: only HDR highlights (>1.05) glow, lit surfaces don't bleach.
	# Glow is the single biggest mobile cost in this scene (the station's 8x
	# emission floods the blur passes and bleaches the silhouette at FSR scale).
	if not MobilePerf.is_mobile():
		sky_env.glow_enabled = true
		sky_env.glow_intensity = 0.35
		sky_env.glow_strength = 0.7
		sky_env.glow_bloom = 0.05
		sky_env.glow_hdr_threshold = 1.05
		sky_env.glow_hdr_scale = 1.4
		sky_env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	else:
		sky_env.glow_enabled = false
	
	env.environment = sky_env
	add_child(env); move_child(env, 0); main_env = env
	
	var vp = get_viewport()
	# DESKTOP RETRO SCALING: 40% internal resolution gives the chunky pixel aesthetic
	# while keeping the GPU well within budget on a 1080p/1440p monitor.
	# FSR 1.0 upscales cleanly from ~540p/720p → native.
	# Mobile drops to 30% — the extra blur is hidden by the pixel-art aesthetic
	# and FSR upscaling, and fragment cost drops ~44% vs. 40%.
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = 0.30 if MobilePerf.is_mobile() else 0.40
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	# 2x MSAA is essentially free on desktop discrete GPUs and eliminates the worst
	# aliasing on geometry edges at our resolution scale — but on mobile tilers it
	# doubles per-pixel bandwidth, so disable.
	vp.msaa_3d = Viewport.MSAA_DISABLED if MobilePerf.is_mobile() else Viewport.MSAA_2X
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED  # FSR already handles this
	# Debanding does a fullscreen dither pass; mobile fillrate is precious.
	vp.use_debanding = not MobilePerf.is_mobile()

func _setup_titan_splash() -> void:
	_load_overlay = ColorRect.new()
	_load_overlay.color = Color("#080808")
	_load_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	var canvas = CanvasLayer.new()
	canvas.layer = 120 # Above HUD
	canvas.add_child(_load_overlay)
	
	_load_label = Label.new()
	_load_label.text = "TITAN UNIVERSAL GENESIS - BOOTING..."
	HUDStyle.style_label(_load_label, HUDStyle.HUD_FONT_LRG, HUDStyle.CRT_GREEN_BG)
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
	sun.light_energy = 1.2
	# Shadows are the second-biggest mobile win after glow — the cascade render
	# costs pile up on tiled GPUs and every lit fragment pays for a sample even
	# when the cascade is mostly empty. Day/night feel is preserved by the sun
	# direction + ambient.
	sun.shadow_enabled = not MobilePerf.is_mobile()
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_blend_splits = false # Sharp splits for that retro feel
	sun.directional_shadow_max_distance = 6500.0
	
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
	
	# ACE UNIVERSE SYNC: Link station events to the cosmic density controller
	if station.has_signal("planet_forged"):
		station.planet_forged.connect(_on_planet_count_changed)

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
		# Primary "main" belt — densest, near origin.
		_spawn_asteroid_belt(belt_script, "DeepSpaceAsteroidBelt",
			9999, Vector3(0, 0, -1500000.0), Vector3.ZERO,
			1400000.0, 2000000.0, 40000.0, 14000, 500)

		# SECONDARY BELTS — rotated and offset so asteroids aren't only in one
		# narrow ring, but distributed around the inner system.  Each belt is
		# itself a flattened ring; stacking several at different orientations
		# gives the impression of asteroids "everywhere in space".
		_spawn_asteroid_belt(belt_script, "ScatterBeltAlpha",
			17371, Vector3(2200000.0, 400000.0, 600000.0),
			Vector3(deg_to_rad(35), deg_to_rad(60), 0.0),
			900000.0, 1700000.0, 80000.0, 7000, 300)
		_spawn_asteroid_belt(belt_script, "ScatterBeltBeta",
			28983, Vector3(-1800000.0, -300000.0, 1100000.0),
			Vector3(deg_to_rad(-25), deg_to_rad(-40), deg_to_rad(15)),
			1100000.0, 1900000.0, 60000.0, 8000, 320)
		_spawn_asteroid_belt(belt_script, "ScatterBeltGamma",
			41207, Vector3(500000.0, 1200000.0, 2200000.0),
			Vector3(deg_to_rad(70), deg_to_rad(20), deg_to_rad(-30)),
			800000.0, 1500000.0, 100000.0, 6000, 260)

	# DEEP SPACE SALVAGE: Rare minerals floating in the void
	_setup_deep_space_minerals()


func _spawn_asteroid_belt(belt_script: Script, belt_name: String, seed_val: int,
		pos: Vector3, rot_euler: Vector3,
		inner_r: float, outer_r: float, thick: float,
		mmi_count: int, phys_count: int) -> void:
	var belt = Node3D.new()
	belt.set_script(belt_script)
	belt.name = belt_name
	belt.set("belt_seed", seed_val)
	belt.set("inner_radius", inner_r)
	belt.set("outer_radius", outer_r)
	belt.set("thickness", thick)
	belt.set("mmi_count", mmi_count)
	belt.set("phys_count", phys_count)
	world_root.add_child(belt)
	belt.global_position = pos
	belt.rotation = rot_euler
	belt.add_to_group("World")

func _setup_deep_space_minerals() -> void:
	var m_script = _get_res("res://src/world/MineableResource.gd")
	if not m_script: return
	
	var types = ["Copper", "Silver", "Gold", "Platinum", "Diamond"]
	var rng = RandomNumberGenerator.new(); rng.seed = 77777 
	
	# ACE: We queue these for staggered spawning to prevent Physics Server lock-up
	# ADAPTIVE DENSITY: Starting with 600 minerals when the universe is empty.
	var _mineral_count = 600
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

var _active_minerals: Array[Node] = []

func _on_planet_count_changed(count: int) -> void:
	# ACE: Adaptive Universe density. 
	# More planets -> less deep space debris to maintain frame budget.
	# We cull 150 asteroids per forged planet.
	var target_count = 600 - (count * 150)
	print("--- ARCHITECT: Adaptive Density Sync (Planets: %d, Target Asteroids: %d) ---" % [count, target_count])
	while _active_minerals.size() > target_count and not _active_minerals.is_empty():
		var m = _active_minerals.pop_back()
		if is_instance_valid(m):
			m.queue_free()

func _setup_hardened_diag_hud() -> void:
	hud_layer = CanvasLayer.new()
	hud_layer.layer = 125
	hud_layer.add_to_group("GameHUD")
	diag_label = Label.new()
	# ACE: Safe Area Padding for iPhone 15 (Dynamic Island fallback)
	diag_label.position = Vector2(80, 40)
	HUDStyle.style_label(diag_label, HUDStyle.HUD_FONT_SMALL, HUDStyle.CRT_GREEN_BG)
	hud_layer.add_child(diag_label)
	diag_label.visible = diag_visible
	
	# ACE ECONOMY: Real-time Credit Display — top-right corner, wrapped in a
	# beveled gold chip so it reads as part of the chunky pixel-art chrome.
	# The chip's PanelContainer hugs its label so the chip auto-sizes as the
	# credits grow; we anchor only the right edge so it grows leftwards.
	var creds_chip := PanelContainer.new()
	creds_chip.name = "CreditChip"
	creds_chip.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.TIER_COLOR_4.darkened(0.15)))
	creds_chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	creds_chip.modulate.a = 0.85
	hud_layer.add_child(creds_chip)
	creds_chip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 0)
	creds_chip.position = Vector2(HUDStyle.CREDITS_OFFSET.x, HUDStyle.CREDITS_OFFSET.y)
	creds_chip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	# On mobile the PAUSE button lives in the top-right and is wider than on
	# desktop — push the credit chip further down so it doesn't sit underneath
	# the button.  Below the top button rect (24 inset + 88 high + a few px
	# breathing room) lands the chip at y≈124.
	if MobilePerf.is_mobile():
		creds_chip.position = Vector2(HUDStyle.CREDITS_OFFSET.x, 124.0)

	var creds = Label.new(); creds.name = "CreditLabel"
	creds.text = "$0"
	HUDStyle.style_label(creds, HUDStyle.HUD_FONT_MED, Color.WHITE)
	creds.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	creds.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	creds_chip.add_child(creds)

	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.currency_changed.connect(func(n): creds.text = "$" + str(n))
		# Reflect any credits already restored by SaveManager (whose load
		# emission happens before this HUD listener attaches).
		creds.text = "$" + str(int(econ.credits))

	# INVENTORY ROW: top-left chip strip.  Each resource becomes a
	# colour-tinted chip with a tier-coloured top stripe.  Chips are pooled
	# (created on first appearance, freed when the count returns to 0) and
	# play a scale-pulse + "+N" floater on every additive change.  Order:
	# rarest-first (tier desc, abbrev asc) so the bankable items lead.
	var inv_box = FlowContainer.new()
	inv_box.name = "InventoryRow"
	inv_box.add_theme_constant_override("h_separation", HUDStyle.CHIP_GAP)
	inv_box.add_theme_constant_override("v_separation", HUDStyle.CHIP_GAP)
	inv_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inv_box.modulate.a = 0.85
	hud_layer.add_child(inv_box)
	if MobilePerf.is_mobile():
		# Mobile layout: centre the chip strip below the health bar (which is
		# at y≈24 with 18 px height) and span the full top width MINUS the
		# RECENTER / PAUSE button rects on the corners.  alignment=CENTER
		# packs the chips in the middle and lets them flow outward; the inset
		# stops them from sliding under either button.
		const _MOBILE_TOP_BTN_INSET := 24.0 + 260.0 + 16.0   # button left/right inset + width + small gap
		inv_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE, Control.PRESET_MODE_KEEP_SIZE, 0)
		inv_box.offset_left  = _MOBILE_TOP_BTN_INSET
		inv_box.offset_right = -_MOBILE_TOP_BTN_INSET
		inv_box.offset_top   = 52.0    # 24 (bar top) + 18 (bar) + 10 (gap)
		inv_box.offset_bottom = 240.0
		inv_box.alignment = FlowContainer.ALIGNMENT_CENTER
	else:
		inv_box.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_KEEP_SIZE, 0)
		inv_box.offset_left = HUDStyle.INVENTORY_OFFSET.x
		inv_box.offset_right = HUDStyle.INVENTORY_OFFSET.x + 720
		inv_box.offset_top = HUDStyle.INVENTORY_OFFSET.y
		inv_box.offset_bottom = HUDStyle.INVENTORY_OFFSET.y + 240

	var chips_by_name: Dictionary = {}

	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		var _refresh_inv = func(res_type: String, amt: int) -> void:
			# Existing chip: update count.  Drops to zero → free and remove.
			if chips_by_name.has(res_type):
				var existing = chips_by_name[res_type]
				if amt <= 0:
					existing.queue_free()
					chips_by_name.erase(res_type)
				else:
					existing.set_count(amt)
				_resort_inventory_row(inv_box, chips_by_name)
				return
			# New chip on first appearance.
			if amt <= 0:
				return
			var chip = ResourceChipScene.new()
			chip.setup(res_type)
			inv_box.add_child(chip)
			chips_by_name[res_type] = chip
			chip.set_count(amt)
			_resort_inventory_row(inv_box, chips_by_name)
		inv.inventory_changed.connect(_refresh_inv)
		# Replay any items already restored by SaveManager so they appear
		# in the HUD on launch (SaveManager runs before this listener attaches).
		# Deferred because inv_box's CanvasLayer parent isn't add_child'd until
		# later in _ready — ResourceChip.set_count() touches get_tree() and
		# would crash if invoked before the chip is in the tree.
		var restored: Dictionary = inv.get_all()
		for res_type in restored.keys():
			var amt: int = int(restored[res_type])
			if amt > 0:
				_refresh_inv.call_deferred(res_type, amt)

	# Station-guide NavBeacon widget removed — the screen-space POI HUD
	# below renders bearing + distance markers for every station / planet
	# directly on screen, so the duplicate top-left corner widget was
	# redundant clutter.  Kept the script file (NavBeacon.gd) in place
	# in case the widget is wanted back later.

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
	
	# Pause menu — full-screen Control with Resume / Rebind / Quit buttons.
	# Has its own _input handler with process_mode = ALWAYS so unpause works
	# while the scene tree is paused (Main itself is INHERIT-paused so its
	# _unhandled_input is silent during pause).
	var pause_script: Script = load("res://src/ui/PauseMenuUI.gd")
	var pause_node := Control.new()
	pause_node.set_script(pause_script)
	hud_layer.add_child(pause_node)
	pause_node.hide()
	pause_node.resume_requested.connect(toggle_pause)
	pause_node.rebind_requested.connect(_on_open_rebind)
	pause_node.quit_requested.connect(func() -> void: get_tree().quit())
	_pause_overlay = pause_node

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

	# Beat-sync: push MusicDirector's beat intensity into the sky shader so
	# stars twinkle in time with the music.
	if main_sky_mat:
		var md_nodes := get_tree().get_nodes_in_group("MusicDirector")
		if md_nodes.size() > 0:
			var beat_v: float = float(md_nodes[0].beat_intensity)
			main_sky_mat.set_shader_parameter("music_beat", beat_v)
		
	# ACE: Spawn minerals and check readiness BEFORE any early-returns
	var batch_size = 80 if _is_loading else 25
	for i in range(min(_mineral_spawn_queue.size(), batch_size)):
		var entry = _mineral_spawn_queue.pop_back()
		var m = entry.script.new()
		m.set("resource_type", entry.type)
		world_root.add_child(m)
		m.global_position = entry.pos
		_active_minerals.append(m)
	
	# Check if all planets have finished their staggered initialization
	var all_ready = _mineral_spawn_queue.is_empty()
	var planets = get_tree().get_nodes_in_group("Planet")
	if not planets.is_empty() and _is_loading:
		for pl in planets:
			var pc = pl.get("_prewarm_count")
			var pt = pl.get("_prewarm_target")
			if pc != null and pt != null:
				if pc < pt:
					all_ready = false
					break
			else:
				# Script not loaded or variables missing
				printerr("--- ARCHITECT: Planet [%s] has no prewarm data! ---" % pl.name)
	
	if _is_loading:
		if all_ready:
			_finish_loading()
		else:
			var _mtotal = 250
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
	if fr % 4 == 0:
		_update_atmospheric_transition(p)
		_update_shadow_distance(p)

	if not hud_visible or not diag_label: return

	# HUD THROTTLE: Rebuild text only every 3 frames (~20Hz at 60fps).
	if (fr + 2) % 3 != 0: return
	
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
		sky_env.ambient_light_color = Color("3A75C4").lerp(Color("0B1021"), lighting_ratio)
		sky_env.ambient_light_energy = lerp(0.65, 0.1, lighting_ratio)
		
		# ATMOSPHERIC HAZE: Drastically reduced density so distant planets remain visible!
		# Godot's exponential fog math completely wipes out geometry > 500km away at normal densities.
		var surface_fog_density = 0.000005
		sky_env.fog_density = lerp(surface_fog_density, 0.0, lighting_ratio)
		# Aerial perspective at 0.85 was blending 85% of the bright sky colour
		# into distant terrain, so even a vivid pink CANDY planet read as
		# uniform cyan-white from any distance. 0.2 keeps subtle horizon haze
		# without erasing the procedural biome colour. Mobile drops to 0 —
		# the per-pixel sky sample is the most expensive fog term.
		sky_env.fog_aerial_perspective = 0.0 if MobilePerf.is_mobile() else 0.2
		
		# Tint the fog to the planet's horizon color for per-biome atmosphere feel
		var fog_col = Color(0.72, 0.82, 0.95) # Default sky blue
		if target and "sky_horizon_color" in target:
			# Blend planet color with a bright sky tint so fog stays luminous, not muddy
			fog_col = target.sky_horizon_color.lerp(Color(0.85, 0.90, 1.0), 0.5)
		sky_env.fog_light_color = fog_col
		
	if main_sun:
		main_sun.light_color = Color("#FFF0CE").lerp(Color.WHITE, lighting_ratio)
		main_sun.light_energy = lerp(1.2, 1.6, lighting_ratio)

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
		# Debug instrumentation: F5 dumps a world-content audit, F6 inspects
		# whatever mesh is under the cursor.  Both write to MCPRuntime's log
		# (fetchable via the godot_mcp `get_runtime_log` tool) and stdout.
		if event.keycode == KEY_F5:
			var WorldAudit = load("res://src/debug/WorldAudit.gd")
			if WorldAudit: WorldAudit.dump()
		if event.keycode == KEY_F6:
			var p_ref := get_tree().get_first_node_in_group("Player")
			if p_ref and "camera" in p_ref:
				var MeshInspector = load("res://src/debug/MeshInspector.gd")
				if MeshInspector:
					MeshInspector.inspect_at(get_viewport(), p_ref.camera)
	# Gamepad START toggles pause — without this, once paused with a
	# gamepad-only input chain there's no way to unpause (the pause
	# overlay has no buttons of its own).  Same gating as ESCAPE.
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_START:
			if not get_tree().paused or _pause_overlay.visible:
				toggle_pause()

func _on_open_rebind() -> void:
	# Hide the pause menu, show the rebind submenu.  Game stays paused so
	# nothing moves while the user is rebinding.  RebindUI's `closed`
	# signal returns us to the pause menu.
	if is_instance_valid(_rebind_ui): return
	var script: Script = load("res://src/ui/RebindUI.gd")
	var ui := Control.new()
	ui.set_script(script)
	# Add at the canvas-layer level so it draws on top of the pause overlay.
	if _pause_overlay and _pause_overlay.get_parent():
		_pause_overlay.get_parent().add_child(ui)
	else:
		add_child(ui)
	ui.closed.connect(_on_close_rebind)
	if _pause_overlay: _pause_overlay.hide()
	_rebind_ui = ui


func _on_close_rebind() -> void:
	if is_instance_valid(_rebind_ui):
		_rebind_ui.queue_free()
	_rebind_ui = null
	if _pause_overlay and get_tree().paused:
		_pause_overlay.show()


func _any_modal_ui_open() -> bool:
	# True if a SpaceStation has its docking UI open, or a PlanetPlacementUI
	# is in flight — used to suppress the global pause overlay so we never
	# stack two menus on top of each other.
	for s in get_tree().get_nodes_in_group("SpaceStation"):
		if "_ui_visible" in s and bool(s.get("_ui_visible")):
			return true
	# PlanetPlacementUI doesn't add itself to a group; detect via class
	# (it extends Control and has placement_confirmed signal).
	for n in get_tree().get_nodes_in_group("PlacementUI"):
		if n is Control and n.visible:
			return true
	return false


func toggle_pause() -> void:
	if _is_loading: return
	# Mutual exclusion: don't layer the pause overlay over an already-open
	# station/forge UI.  If a station has a UI visible, do nothing — that
	# UI's own _input already handles its own close-button (Escape / START
	# / B).  Same for an in-flight placement UI.
	if not get_tree().paused and _any_modal_ui_open(): return
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

# Re-order inventory chips so rarest tier appears first.  Called after every
# add/remove.  Cheap — there are at most ~16 resource types in the registry.
func _resort_inventory_row(container: Node, chips_by_name: Dictionary) -> void:
	var entries: Array = []
	for res_name in chips_by_name.keys():
		var data: Dictionary = ResourceRegistry.get_data(res_name)
		entries.append({
			"chip": chips_by_name[res_name],
			"tier": int(data.get("tier", 1)),
			"abbrev": String(data.get("abbrev", res_name)),
		})
	entries.sort_custom(func(a, b):
		if a.tier != b.tier:
			return a.tier > b.tier  # higher tier first
		return a.abbrev < b.abbrev
	)
	for i in range(entries.size()):
		var chip = entries[i].chip
		if chip.get_parent() == container:
			container.move_child(chip, i)

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

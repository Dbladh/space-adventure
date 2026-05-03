extends StaticBody3D

# MineableResource.gd
# Managed by THE PROCEDURALIST.
# A deterministic, low-poly mineral deposit that responds to projectile impacts.

@export var resource_type: String = "Copper"
var health: float = 3.0 # 3-12 hits depending on type
var max_health: float = 3.0 # ACE: Healthbar scaling
var flash_timer: float = 0.0 # ACE: Damage feedback persistence
var health_bar: ProgressBar = null
var hud_sprite: Sprite3D = null # ACE: Distance-culled HUD element
var mesh_inst: MeshInstance3D = null
var _visual_tick: int = 0
# MOBILE PERF cached at _ready — disables OmniLight3D + SubViewport HUD
# (each mineral would otherwise own a light and a transparent SubViewport).
var _mobile_perf: bool = false

# PERSISTENT DESTRUCTION REGISTRY: Track destroyed mineral positions so they
# don't respawn if planet chunks reload. Uses position.hash() for fast lookup.
static var _destroyed_positions: Dictionary = {}

# ASYNC PERF (mobile): Shared mesh + collision-shape caches.
# Building one ArrayMesh per type and reusing it across every instance avoids
# the SurfaceTool.commit() main-thread spike that used to fire 10-20 times
# every chunk load.  Per-instance variation is preserved via mesh_inst.scale.
# Cylinder shapes are quantized into 5m buckets so a planet's ~80 minerals
# share ~15-30 unique Shape3D resources rather than one each.
static var _shared_meshes: Dictionary = {}    # resource_type → ArrayMesh
static var _shared_shapes: Dictionary = {}    # size_bucket(int) → CylinderShape3D
const _MESH_UNIT_SIZE: float = 1.0            # unit-scale octahedron geometry

func _ready() -> void:
	add_to_group("Mineable") # ACE: Absolute identification for projectiles
	_mobile_perf = OS.get_name() == "iOS" or OS.has_feature("mobile")
	# ACE SCALING: Balanced Mining Integrity – Just a few shots
	match resource_type:
		"Silver": health = 5.0
		"Gold": health = 8.0
		"Platinum": health = 10.0
		"Diamond": health = 12.0
		_: health = 3.0
	max_health = health
	
	_generate_low_poly_node()
	# MOBILE: Skip the SubViewport HUD. 80 transparent SubViewports in flight
	# shred the forward-cluster budget on A14-class GPUs and the health bar
	# is rarely read against a moving ship reticle.
	if not _mobile_perf:
		_setup_tactical_hud()

func _generate_low_poly_node() -> void:
	# ACE GEOMETRY: Procedural 'Rupee' Octahedron (Anchored at Tip)
	# ASYNC PERF: Shared cached mesh + scale-per-instance, no SurfaceTool work
	# in the hot path on mobile.  See _get_or_build_mesh() for the unit geometry.
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(global_position) + resource_type)

	var col = _get_resource_color()
	var size = rng.randf_range(80.0, 160.0) # (80m - 160m)
	if resource_type == "Diamond": size *= 1.4

	# Mesh: shared per type, scale brings unit geometry up to actual mineral size.
	mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = _get_or_build_mesh(resource_type)
	mesh_inst.scale = Vector3.ONE * size

	# ACE MATERIAL: per-instance so each mineral's glint phase varies independently.
	# (Sharing the material would synchronise every mineral's pulse — distracting.)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.metallic = 1.0
	mat.roughness = 0.02
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.emission_enabled = true
	mat.emission = col * 1.5
	mat.emission_energy_multiplier = 0.6
	mesh_inst.material_override = mat

	if not _mobile_perf:
		var light = OmniLight3D.new()
		light.light_color = col
		light.light_energy = 0.7
		light.omni_range = size * 3.5
		add_child(light)

	add_child(mesh_inst)
	set_process(true)

	# Collision shape: shared CylinderShape3D from the size-bucket cache.
	# Position remains per-instance so the collider matches the visual scale exactly.
	var shape = CollisionShape3D.new()
	shape.shape = _get_or_build_shape(size)
	shape.position = Vector3(0, size * 2.5, 0)
	add_child(shape)

# -------------------------------------------------------------------
#  STATIC SHARED-RESOURCE BUILDERS
# -------------------------------------------------------------------
# These build the heavy ArrayMesh/Shape3D objects once and cache them in
# class-level dictionaries.  Subsequent calls are O(1) dictionary lookups —
# no SurfaceTool work, no GPU upload, no shape allocation.

static func _get_or_build_mesh(type: String) -> ArrayMesh:
	if _shared_meshes.has(type):
		return _shared_meshes[type]

	var col := _color_for_type(type)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Unit-scale octahedron — every instance scales this via mesh_inst.scale.
	var s := _MESH_UNIT_SIZE
	var v_top := Vector3(0, s * 5.0, 0)
	var v_bot := Vector3(0, 0, 0)
	var v_mid := [
		Vector3(s, s * 2.5, 0),
		Vector3(0, s * 2.5, s),
		Vector3(-s, s * 2.5, 0),
		Vector3(0, s * 2.5, -s)
	]
	for i in range(4):
		var m1: Vector3 = v_mid[i]
		var m2: Vector3 = v_mid[(i + 1) % 4]
		var n_up := (m1 - v_top).cross(m2 - v_top).normalized()
		st.set_normal(n_up); st.set_color(col); st.add_vertex(v_top)
		st.set_normal(n_up); st.set_color(col); st.add_vertex(m1)
		st.set_normal(n_up); st.set_color(col); st.add_vertex(m2)
		var n_down := (m2 - v_bot).cross(m1 - v_bot).normalized()
		st.set_normal(n_down); st.set_color(col); st.add_vertex(v_bot)
		st.set_normal(n_down); st.set_color(col); st.add_vertex(m2)
		st.set_normal(n_down); st.set_color(col); st.add_vertex(m1)

	var mesh := st.commit()
	_shared_meshes[type] = mesh
	return mesh

static func _color_for_type(type: String) -> Color:
	# Static mirror of _get_resource_color() (which is instance-scoped).
	# Used by _get_or_build_mesh() at class scope.
	match type:
		"Copper":   return Color(0.48, 0.18, 0.08)
		"Silver":   return Color(0.7, 0.7, 0.75)
		"Gold":     return Color(1.0, 0.6, 0.0)
		"Platinum": return Color(0.85, 0.85, 0.95)
		"Diamond":  return Color(0.3, 0.8, 1.0)
	return Color.GRAY

static func _get_or_build_shape(size: float) -> CylinderShape3D:
	# Quantize to 5m buckets so e.g. size 87.3 and 89.6 share the same shape.
	# Visual mismatch is at most 2.5m on a 100m+ object — imperceptible.
	var bucket := int(size / 5.0) * 5
	if _shared_shapes.has(bucket):
		return _shared_shapes[bucket]
	var cyl := CylinderShape3D.new()
	cyl.height = float(bucket) * 5.0
	cyl.radius = float(bucket) * 1.1
	_shared_shapes[bucket] = cyl
	return cyl

func _get_resource_color() -> Color:
	match resource_type:
		"Copper": return Color(0.48, 0.18, 0.08) # ACE: Deep Burnished Copper (High Contrast)
		"Silver": return Color(0.7, 0.7, 0.75)
		"Gold": return Color(1.0, 0.6, 0.0) # Richer Gold
		"Platinum": return Color(0.85, 0.85, 0.95)
		"Diamond": return Color(0.3, 0.8, 1.0)
	return Color.GRAY

func take_damage(_amount: float) -> void:
	# print("[MINERAL] Hit Detected! Health: ", health - 1.0)
	flash_timer = 0.2 # ACE: Trigger a 0.2s high-energy flash
	
	health -= 1.0
	if health_bar:
		health_bar.value = health
		# ACE: Fade in healthbar on first hit if needed (already visible)
	
	if health <= 0:
		# print("[MINERAL] SHATTERED! Spawning Loot.")
		_on_mined()

func _process(_delta: float) -> void:
	var was_flashing := flash_timer > 0.0
	if flash_timer > 0.0:
		flash_timer = maxf(flash_timer - _delta, 0.0)

	# The glint and HUD fade do not need a 60Hz refresh; update them on a lower cadence
	# unless the resource is actively flashing from damage.
	_visual_tick = (_visual_tick + 1) % 4
	if not was_flashing and flash_timer <= 0.0 and _visual_tick != 0:
		rotate_object_local(Vector3.UP, _delta * 0.4)
		return

	# ACE: Extreme Glint for high-contrast 'Discovery'
	var pulse = sin(Time.get_ticks_msec() * 0.0035)
	var glint = pow(max(0.0, pulse), 50.0) # Even Sharper

	if mesh_inst and mesh_inst.material_override:
		if flash_timer > 0.0:
			# ACE: Damage flash takes priority over shimmmery glint
			mesh_inst.material_override.emission_energy_multiplier = 45.0
		else:
			# ACE: normal shimmery glint
			mesh_inst.material_override.emission_energy_multiplier = 0.2 + (glint * 40.0)

	if hud_sprite:
		var cam = get_viewport().get_camera_3d()
		if cam:
			var dist = global_position.distance_to(cam.global_position)
			# ACE: Tactical HUD Alpha Fade (10km range)
			var hud_range = 10000.0
			hud_sprite.visible = dist < hud_range
			hud_sprite.modulate.a = clamp(1.0 - (dist / hud_range), 0.0, 1.0)
			
	# Subtle local spin for tactical consistency
	rotate_object_local(Vector3.UP, _delta * 0.4)

func _on_mined() -> void:
	# ACE: Award the player $1 for destroying this mineral (immediate payout),
	# then spawn 10-20 'Shatter' shards that arc up, land on the planet surface
	# for 1 s, then magnet-fly into the ship like Ratchet & Clank bolts.

	# Register this position as destroyed so if the planet chunk reloads,
	# the mineral doesn't respawn.  Use position hash for O(1) lookup.
	var pos_hash = hash(global_position.round())
	_destroyed_positions[pos_hash] = true

	var economy = get_node_or_null("/root/EconomyManager")
	if economy:
		economy.call("add_credits", 1)

	# Musical stinger: harmonic burst tuned to the resource type
	var md_nodes = get_tree().get_nodes_in_group("MusicDirector")
	if md_nodes.size() > 0 and md_nodes[0].has_method("play_mining_stinger"):
		md_nodes[0].play_mining_stinger(resource_type)

	var gem_script = load("res://src/world/LootGem.gd")
	if not gem_script:
		queue_free()
		return

	# Find the nearest planet so the shards know where "down" is and at what
	# radius the surface sits — the mineral's own global_position is on the
	# surface, so its distance-from-centre IS the landing altitude.
	var nearest_p: Node3D = null
	var min_d: float = 1e16
	for p in get_tree().get_nodes_in_group("Planet"):
		var d = p.global_position.distance_to(global_position)
		if d < min_d:
			min_d = d
			nearest_p = p

	# Per-shard credit value: rarer minerals → more credits per shard, but
	# count stays 10-20 so the visual moment is consistent.
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var count = 10 + rng.randi_range(0, 10)  # 10-20
	var per_value = 80
	match resource_type:
		"Silver": per_value = 140
		"Gold": per_value = 260
		"Platinum": per_value = 480
		"Diamond": per_value = 900

	var shard_col = _get_resource_color().lerp(Color.WHITE, 0.4)
	for i in range(count):
		var gem = Node3D.new()
		gem.set_script(gem_script)
		gem.set("col", shard_col)
		gem.set("value", per_value)
		gem.set("planet", nearest_p)
		gem.set("surface_dist", min_d)
		get_tree().root.add_child(gem)
		# Spawn slightly above the mineral's bottom tip so the burst originates
		# inside the (now-shattered) gem volume rather than underground.
		gem.global_position = global_position + Vector3(0, 30.0, 0)

	queue_free()

func _setup_tactical_hud() -> void:
	# ACE: High-Fidelity Tactical Healthbar Assembly
	var view = SubViewport.new()
	view.size = Vector2(256, 30)
	view.transparent_bg = true
	add_child(view)
	
	health_bar = ProgressBar.new()
	health_bar.size = Vector2(256, 30)
	health_bar.max_value = max_health
	health_bar.value = health
	health_bar.show_percentage = false
	
	# ACE: Cyberpunk Styling
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.8, 0.1, 0.9) # Neon Green
	sb.set_border_width_all(2)
	sb.border_color = Color(1, 1, 1, 0.5)
	health_bar.add_theme_stylebox_override("fill", sb)
	
	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.5)
	health_bar.add_theme_stylebox_override("background", bg)
	
	view.add_child(health_bar)
	
	# Create Sprite3D to hold the viewport UI
	hud_sprite = Sprite3D.new()
	hud_sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hud_sprite.fixed_size = false # ACE: Allow natural scaling with distance
	hud_sprite.pixel_size = 0.05 # ACE: Balanced pixel scale (12.8m HUD)
	hud_sprite.position = Vector3(0, 300.0, 0)
	hud_sprite.visible = false
	add_child(hud_sprite)
	
	# ACE: Link Viewport to Sprite (Requires a Frame Wait for Render initialization)
	await get_tree().process_frame
	hud_sprite.texture = view.get_texture()
	
	health_bar.value = health

extends StaticBody3D

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

# MineableResource.gd
# Managed by THE PROCEDURALIST.
# A deterministic, low-poly mineral deposit that responds to projectile impacts.

@export var resource_type: String = "Copper"
# Whether this deposit emits its own glow + omni light. Defaults true for the
# legacy / deep-space mineral spawn path, overridden to false for plain flora
# (Wood / Stone / Carbon Fiber) so every planet doesn't have glowing trees.
@export var glows: bool = true
var health: float = 3.0 # 3-12 hits depending on type
var max_health: float = 3.0 # ACE: Healthbar scaling
var flash_timer: float = 0.0 # ACE: Damage feedback persistence
var health_bar: ProgressBar = null
var hud_sprite: Sprite3D = null # ACE: Distance-culled HUD element
var mesh_inst: MeshInstance3D = null
var size: float = 100.0
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
static var _shared_shapes: Dictionary = {}    # type+bucket key → CylinderShape3D
static var _shared_materials: Dictionary = {} # tier_key (e.g. "t4", "t5_mobile", "flora") → Material
static var _aabb_cache: Dictionary = {}       # resource_type → AABB of its unit mesh
const _MESH_UNIT_SIZE: float = 1.0            # unit-scale octahedron geometry
const _PREMIUM_SHADER = preload("res://src/shaders/mineral_premium.gdshader")

# Per-instance visual centre (set in _generate_low_poly_node from the mesh AABB).
# Used by get_target_center() so lock-on / bolt homing aims at the actual model
# instead of an old hard-coded y=size*2.5 above it.
var _target_local_offset: Vector3 = Vector3(0, 1.0, 0)

func _ready() -> void:
	# ACE: Robustly resolve the planetary root node by traversing parents until we find the PlanetGen node
	var planet_root = get_parent()
	var trace = ""
	while is_instance_valid(planet_root):
		trace += " -> " + planet_root.name + " (" + str(planet_root.get_groups()) + ")"
		if planet_root.is_in_group("Planet"):
			break
		planet_root = planet_root.get_parent()
	
	if not is_instance_valid(planet_root) or not planet_root.is_in_group("Planet"):
		print("--- PROCEDURALIST: Mineral [%s] FAILED to find Planet. Trace: %s ---" % [name, trace])
	
	var p_pos = planet_root.global_position if is_instance_valid(planet_root) else Vector3.ZERO
	var p_name = planet_root.name if is_instance_valid(planet_root) else "NONE"
	print("--- PROCEDURALIST: Mineral Spawned [%s] at %s (Planet [%s] at %s) ---" % [resource_type, str(global_position), p_name, str(p_pos)])
	add_to_group("Mineable") # ACE: Absolute identification for projectiles
	collision_layer = 1 << 2 # Layer 3
	collision_mask = 0        # Minerals don't need to detect anything themselves
	_mobile_perf = MobilePerf.is_mobile()
	# Health scales with resource tier — rarer deposits take more shots
	var tier := ResourceRegistry.get_tier(resource_type)
	match tier:
		1: health = 2.0
		2: health = 3.0
		3: health = 4.5
		4: health = 7.0
		5: health = 12.0
		_: health = 3.0
	max_health = health
	
	_generate_low_poly_node()
	# Health-bar HUD permanently disabled: with hundreds of mineable
	# resources alive at once on a forged planet, every instance spawning
	# its own SubViewport + ProgressBar + billboard Sprite3D produced a
	# stack of green bars that read as a noise field from any altitude
	# above ~500 m, on top of the per-instance render cost on desktop
	# and the GPU budget hit on mobile.  Re-enable per-instance via an
	# @export bool if a tactical view is wanted later.
	# if not _mobile_perf:
	#     _setup_tactical_hud()

func _generate_low_poly_node() -> void:
	# Shared mesh per resource type + shared material per tier — no per-instance
	# allocation, and the premium shader uses world-position to phase-shift each
	# mineral's pulse independently. See MineralShapes for shape catalog and
	# mineral_premium.gdshader for the T2-T5 visual treatment.
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(str(global_position) + resource_type)

	var col = _get_resource_color()
	# ACE: Flora resources (Wood, Stone, Carbon Fiber) are tree/bush scale.
	# Mineral deposits (Copper, Iron, Diamond etc.) are large geological formations.
	var is_flora := resource_type in ["Wood", "Stone", "Carbon Fiber", "Living Resin", "Organic Sludge", "Primal Fruit"]
	if is_flora:
		size = rng.randf_range(8.0, 14.0)
	else:
		size = rng.randf_range(80.0, 160.0) # (80m - 160m)
	if resource_type == "Diamond": size *= 1.4

	# Mesh: shared per type, scale brings unit geometry up to actual mineral size.
	mesh_inst = MeshInstance3D.new()
	mesh_inst.mesh = _get_or_build_mesh(resource_type)
	mesh_inst.scale = Vector3.ONE * size

	# Shared per-tier material. Vertex colors in the mesh carry the resource hue.
	var tier := ResourceRegistry.get_tier(resource_type)
	mesh_inst.material_override = _get_or_build_material(tier, glows, _mobile_perf)

	if glows and not _mobile_perf and tier >= 3:
		# Only Blue+ minerals get a point light — keeps grey/green deposits
		# from over-lighting the scene and capped on mobile.
		var light = OmniLight3D.new()
		light.light_color = col
		light.light_energy = 0.4
		light.omni_range = size * 2.5
		add_child(light)

	add_child(mesh_inst)
	set_process(true)

	# Build the collision shape from the actual visual mesh AABB so the hitbox
	# wraps what the player sees. The old fixed `y = size * 3.5` cylinder was
	# tuned to the original octahedron and sat way above the new shorter shapes
	# — bolts would whiff and lock-on aimed at empty space.
	var aabb := _get_or_build_aabb(resource_type)
	var visual_center_local := aabb.position + aabb.size * 0.5    # unit space
	var visual_half_h: float = max(aabb.size.y * 0.5, 0.5)
	var visual_half_w: float = max(max(aabb.size.x, aabb.size.z) * 0.5, 0.5)
	_target_local_offset = visual_center_local * size

	var shape = CollisionShape3D.new()
	shape.shape = _get_or_build_shape_aabb(resource_type, size, is_flora, visual_half_h, visual_half_w)
	shape.position = Vector3(0, visual_center_local.y * size, 0)
	add_child(shape)

# -------------------------------------------------------------------
#  PUBLIC API
# -------------------------------------------------------------------

func get_target_center() -> Vector3:
	# Returns the visual centre of this resource for aiming reticle snapping
	# and bolt homing. Sourced from the actual mesh AABB so lock-on targets
	# the model the player sees, not a phantom point above it.
	return global_transform * _target_local_offset

# -------------------------------------------------------------------
#  STATIC SHARED-RESOURCE BUILDERS
# -------------------------------------------------------------------
# These build the heavy ArrayMesh/Shape3D objects once and cache them in
# class-level dictionaries.  Subsequent calls are O(1) dictionary lookups —
# no SurfaceTool work, no GPU upload, no shape allocation.

static func _get_or_build_mesh(type: String) -> ArrayMesh:
	if _shared_meshes.has(type):
		return _shared_meshes[type]
	var mesh: ArrayMesh = MineralShapes.build(type)
	_shared_meshes[type] = mesh
	return mesh

# ── Shared per-tier materials ────────────────────────────────────────────────
# A planet's worth of minerals share these 6 materials instead of allocating
# one StandardMaterial3D per instance. Vertex colors in each mesh carry the
# resource hue, so a single material can colour every Copper / Silver / Gold
# nugget correctly.  T2–T5 use the premium shader for emission + pulse +
# iridescence (mobile path falls back to plain StandardMaterial3D variants).
static func _get_or_build_material(tier: int, p_glows: bool, mobile: bool) -> Material:
	var key: String
	if not p_glows:
		key = "flora"
	elif mobile and tier >= 4:
		key = "t%d_mobile" % tier
	else:
		key = "t%d" % tier
	if _shared_materials.has(key):
		return _shared_materials[key]
	var mat: Material = _build_material(tier, p_glows, mobile)
	_shared_materials[key] = mat
	return mat

static func _build_material(tier: int, p_glows: bool, mobile: bool) -> Material:
	if not p_glows:
		# Flora / non-glow props: matte, surface-rough, vertex-coloured.
		var fm := StandardMaterial3D.new()
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		fm.vertex_color_use_as_albedo = true
		fm.metallic = 0.0
		fm.roughness = 0.85
		fm.emission_enabled = false
		return fm

	# Tier 1: plain gem material, minimal emission. No shader cost.
	if tier == 1:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.vertex_color_use_as_albedo = true
		m.metallic = 0.3
		m.roughness = 0.55
		m.emission_enabled = false
		return m

	# Mobile fallback for T4/T5: stronger emission via StandardMaterial3D,
	# no shader — keeps the GPU budget tight on Apple/Android tiles.
	if mobile and tier >= 4:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		m.vertex_color_use_as_albedo = true
		m.metallic = 0.85
		m.roughness = 0.18
		m.emission_enabled = true
		# Emission picked up from vertex color via the special operator-mul.
		m.emission = Color(1, 1, 1, 1)
		m.emission_energy_multiplier = (0.55 if tier == 4 else 0.85)
		return m

	# Tier 2-5 on desktop: premium shader with tier-tuned uniforms.
	var sm := ShaderMaterial.new()
	sm.shader = _PREMIUM_SHADER
	match tier:
		2:
			sm.set_shader_parameter("emission_strength", 0.12)
			sm.set_shader_parameter("pulse_amount", 0.05)
			sm.set_shader_parameter("iridescence", 0.0)
			sm.set_shader_parameter("sparkle_amount", 0.0)
			sm.set_shader_parameter("metallic_amount", 0.35)
			sm.set_shader_parameter("roughness_amount", 0.40)
		3:
			sm.set_shader_parameter("emission_strength", 0.22)
			sm.set_shader_parameter("pulse_amount", 0.10)
			sm.set_shader_parameter("iridescence", 0.0)
			sm.set_shader_parameter("sparkle_amount", 0.0)
			sm.set_shader_parameter("metallic_amount", 0.65)
			sm.set_shader_parameter("roughness_amount", 0.25)
		4:
			sm.set_shader_parameter("emission_strength", 0.38)
			sm.set_shader_parameter("pulse_amount", 0.25)
			sm.set_shader_parameter("iridescence", 0.10)
			sm.set_shader_parameter("sparkle_amount", 0.08)
			sm.set_shader_parameter("metallic_amount", 0.85)
			sm.set_shader_parameter("roughness_amount", 0.18)
		5:
			sm.set_shader_parameter("emission_strength", 0.55)
			sm.set_shader_parameter("pulse_amount", 0.22)
			sm.set_shader_parameter("iridescence", 0.45)
			sm.set_shader_parameter("sparkle_amount", 0.25)
			sm.set_shader_parameter("metallic_amount", 0.95)
			sm.set_shader_parameter("roughness_amount", 0.12)
		_:
			sm.set_shader_parameter("emission_strength", 0.30)
			sm.set_shader_parameter("metallic_amount", 0.4)
			sm.set_shader_parameter("roughness_amount", 0.4)
	return sm

static func _get_or_build_shape(size: float, is_flora: bool = false) -> CylinderShape3D:
	# Legacy uniform-cylinder builder. Kept for any caller that doesn't have an
	# AABB handy. New mineral spawns prefer _get_or_build_shape_aabb below.
	var bucket := int(size / 5.0) * 5
	var key := str(bucket) + ("_flora" if is_flora else "")
	if _shared_shapes.has(key):
		return _shared_shapes[key]
	var cyl := CylinderShape3D.new()
	if is_flora:
		cyl.height = float(bucket) * 8.0
		cyl.radius = float(bucket) * 4.0
	else:
		cyl.height = float(bucket) * 8.0
		cyl.radius = float(bucket) * 2.2
	_shared_shapes[key] = cyl
	return cyl

# AABB-aware shape builder. Wraps the actual visual extents with a generous
# margin so the bolt's swept raycast can't slip past a thin gem. Cached per
# (type, size-bucket) so a planet's ~80 instances share ~3-5 shapes.
static func _get_or_build_shape_aabb(type: String, size: float, is_flora: bool, half_h_unit: float, half_w_unit: float) -> CylinderShape3D:
	var bucket := int(size / 5.0) * 5
	var key := type + "_" + str(bucket)
	if _shared_shapes.has(key):
		return _shared_shapes[key]
	# Convert unit half-extents to world units, then expand for forgiving aim.
	var half_h: float = max(half_h_unit * size * 1.4, 30.0)
	var radius_mult: float = 2.4 if is_flora else 1.8
	var radius: float = max(half_w_unit * size * radius_mult, 30.0)
	var cyl := CylinderShape3D.new()
	cyl.height = half_h * 2.0
	cyl.radius = radius
	_shared_shapes[key] = cyl
	return cyl

# Cache the unit-space AABB of each resource's mesh — used to position the
# collision shape and the target-centre at the actual visible center.
static func _get_or_build_aabb(type: String) -> AABB:
	if _aabb_cache.has(type):
		return _aabb_cache[type]
	var mesh := _get_or_build_mesh(type)
	var aabb: AABB = mesh.get_aabb() if mesh else AABB(Vector3.ZERO, Vector3(1, 1, 1))
	_aabb_cache[type] = aabb
	return aabb

func _get_resource_color() -> Color:
	return ResourceRegistry.get_color(resource_type)

func take_damage(_amount: float) -> void:
	print("--- PROCEDURALIST: Mineral Hit! [%s] health=%.1f ---" % [resource_type, health - 1.0])
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

	# Beat sync — read MusicDirector's intensity floats. Cached lookup so we
	# only do the group query once per node (cleared if invalid).
	var beat_pulse: float = 0.0
	var kick_pulse: float = 0.0
	var md = _get_music_director()
	if md:
		beat_pulse = md.beat_intensity
		kick_pulse = md.kick_intensity

	# The glint and HUD fade do not need a 60Hz refresh; update them on a lower cadence
	# unless the resource is actively flashing from damage.
	_visual_tick = (_visual_tick + 1) % 4
	if not was_flashing and flash_timer <= 0.0 and _visual_tick != 0:
		# Spin rate gets a beat boost so minerals visibly accelerate on each hit.
		rotate_object_local(Vector3.UP, _delta * (0.4 + beat_pulse * 1.2))
		return

	# Damage flash + beat-sync glow are now driven via per-instance shader
	# parameters on the shared material. Cost is one StringName lookup per
	# mineral per quarter-frame — fine even with hundreds alive.
	if mesh_inst and glows and mesh_inst.material_override is ShaderMaterial:
		var beat: float = kick_pulse * 1.2 + beat_pulse * 0.35
		mesh_inst.set_instance_shader_parameter(&"flash_strength", flash_timer)
		mesh_inst.set_instance_shader_parameter(&"beat_glow", beat)

	if hud_sprite:
		var cam = get_viewport().get_camera_3d()
		if cam:
			var dist = global_position.distance_to(cam.global_position)
			# ACE: Tactical HUD Alpha Fade (10km range)
			var hud_range = 10000.0
			hud_sprite.visible = dist < hud_range
			hud_sprite.modulate.a = clamp(1.0 - (dist / hud_range), 0.0, 1.0)

	# Spin gets a kick-synced burst on top of the base rate — minerals visibly
	# pulse-spin on every kick.
	rotate_object_local(Vector3.UP, _delta * (0.4 + kick_pulse * 1.8))

# Cached MusicDirector ref — looked up via group on first miss.
var _md_ref = null
func _get_music_director():
	if _md_ref and is_instance_valid(_md_ref):
		return _md_ref
	var nodes := get_tree().get_nodes_in_group("MusicDirector")
	if nodes.size() > 0:
		_md_ref = nodes[0]
		return _md_ref
	return null

func _on_mined() -> void:
	# ACE: Award the player $1 for destroying this mineral (immediate payout),
	# then spawn 10-20 'Shatter' shards that arc up, land on the planet surface
	# for 1 s, then magnet-fly into the ship like Ratchet & Clank bolts.

	# Register this position as destroyed so if the planet chunk reloads,
	# the mineral doesn't respawn.  Use position hash for O(1) lookup.
	var pos_hash = hash(global_position.round())
	_destroyed_positions[pos_hash] = true

	if Engine.has_meta("EconomyManager"):
		Engine.get_meta("EconomyManager").add_credits(1)

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
	
	# DROPS POLICY: some resources drop secondary items (like Resin from Wood)
	var drops: Array[Dictionary] = []
	if resource_type == "Wood":
		drops.append({type="Wood", weight=0.7, val=80})
		drops.append({type="Living Resin", weight=0.25, val=150})
		drops.append({type="Primal Fruit", weight=0.05, val=500})
	elif resource_type == "Carbon Fiber":
		drops.append({type="Carbon Fiber", weight=0.8, val=60})
		drops.append({type="Organic Sludge", weight=0.2, val=30})
	else:
		# Standard minerals drop themselves
		var per_val = 80
		match resource_type:
			"Silver": per_val = 140
			"Gold": per_val = 260
			"Platinum": per_val = 480
			"Diamond": per_val = 900
		drops.append({type=resource_type, weight=1.0, val=per_val})

	# LUCK: bias the roll toward rarer side-drops (index >= 1).
	# Index 0 is the primary drop; everything else is rarer.
	var luck_bias: float = 0.0
	if Engine.has_meta("UpgradeManager"):
		luck_bias = float(Engine.get_meta("UpgradeManager").get_luck_drop_bias())
	if luck_bias > 0.0 and drops.size() > 1:
		var total: float = 0.0
		for i in range(drops.size()):
			if i > 0:
				drops[i].weight = float(drops[i].weight) + luck_bias
			total += float(drops[i].weight)
		if total > 0.0:
			for d in drops:
				d.weight = float(d.weight) / total

	for i in range(count):
		# Pick a drop type based on weights
		var roll = rng.randf()
		var cumulative = 0.0
		var selected_drop = drops[0]
		for d in drops:
			cumulative += d.weight
			if roll <= cumulative:
				selected_drop = d
				break

		var gem = Node3D.new()
		gem.set_script(gem_script)
		var shard_col = ResourceRegistry.get_color(selected_drop.type).lerp(Color.WHITE, 0.4)
		gem.set("col", shard_col)
		gem.set("value", selected_drop.val)
		gem.set("resource_type", selected_drop.type)
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

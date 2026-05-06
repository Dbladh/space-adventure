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
static var _shared_shapes: Dictionary = {}    # size_bucket(int) → CylinderShape3D
const _MESH_UNIT_SIZE: float = 1.0            # unit-scale octahedron geometry

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
	_mobile_perf = OS.get_name() == "iOS" or OS.has_feature("mobile")
	# Health scales with resource tier — rarer deposits take more shots
	var tier := ResourceRegistry.get_tier(resource_type)
	match tier:
		1: health = 2.0
		2: health = 4.0
		3: health = 7.0
		4: health = 12.0
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

	# ACE MATERIAL: per-instance so each mineral's glint phase varies independently.
	# (Sharing the material would synchronise every mineral's pulse — distracting.)
	var mat = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.metallic = 1.0 if glows else 0.3
	mat.roughness = 0.02 if glows else 0.85
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	# Non-glowing flora props read as natural surface scenery — no emission, no
	# point light. Only "real" mineral deposits keep the gem-like glint behaviour.
	mat.emission_enabled = glows
	if glows:
		mat.emission = col * 1.0
		mat.emission_energy_multiplier = 0.25
	mesh_inst.material_override = mat

	if glows and not _mobile_perf:
		var light = OmniLight3D.new()
		light.light_color = col
		light.light_energy = 0.4
		light.omni_range = size * 2.5
		add_child(light)

	add_child(mesh_inst)
	set_process(true)

	# Collision shape — flora gets a larger radius for easier shooting.
	var shape = CollisionShape3D.new()
	shape.shape = _get_or_build_shape(size, is_flora)
	# Center the cylinder at object midpoint — Shifted UP to ensure visibility above terrain
	shape.position = Vector3(0, size * 3.5, 0)
	add_child(shape)

# -------------------------------------------------------------------
#  PUBLIC API
# -------------------------------------------------------------------

func get_target_center() -> Vector3:
	# Returns the visual centre of this resource for aiming reticle snapping.
	return global_transform * Vector3(0, size * 2.5, 0)

# -------------------------------------------------------------------
#  STATIC SHARED-RESOURCE BUILDERS
# -------------------------------------------------------------------
# These build the heavy ArrayMesh/Shape3D objects once and cache them in
# class-level dictionaries.  Subsequent calls are O(1) dictionary lookups —
# no SurfaceTool work, no GPU upload, no shape allocation.

static func _get_or_build_mesh(type: String) -> ArrayMesh:
	if _shared_meshes.has(type):
		return _shared_meshes[type]

	var mesh: ArrayMesh
	if type == "Silver" or type == "Basalt Glass":
		mesh = _build_blocky_mesh()
	elif type == "Wood" or type == "Carbon Fiber" or type == "Living Resin":
		mesh = _build_flora_mesh(type)
	else:
		mesh = _build_octahedron_mesh(type)
	_shared_meshes[type] = mesh
	return mesh

static func _build_flora_mesh(type: String) -> ArrayMesh:
	var col := _color_for_type(type)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := _MESH_UNIT_SIZE
	
	if type == "Carbon Fiber":
		# Grass clump mesh
		for i in range(5):
			var ang = i * TAU / 5.0
			var v1 = Vector3(cos(ang)*s, 0, sin(ang)*s)
			var v2 = Vector3(cos(ang+0.5)*s, 0, sin(ang+0.5)*s)
			var v3 = Vector3(0, s * 4.0, 0)
			st.set_normal(Vector3.UP); st.set_color(col); st.add_vertex(v1)
			st.set_normal(Vector3.UP); st.set_color(col); st.add_vertex(v2)
			st.set_normal(Vector3.UP); st.set_color(col); st.add_vertex(v3)
	else:
		# Tree-like trunk segment
		var sides = 6
		for i in range(sides):
			var a1 = i * TAU / sides; var a2 = (i + 1) * TAU / sides
			var b1 = Vector3(cos(a1)*s, 0, sin(a1)*s)
			var b2 = Vector3(cos(a2)*s, 0, sin(a2)*s)
			var t1 = Vector3(cos(a1)*s*0.7, s*5.0, sin(a1)*s*0.7)
			var t2 = Vector3(cos(a2)*s*0.7, s*5.0, sin(a2)*s*0.7)
			st.set_normal(b1.normalized()); st.set_color(col); st.add_vertex(b1)
			st.set_normal(b2.normalized()); st.set_color(col); st.add_vertex(b2)
			st.set_normal(t1.normalized()); st.set_color(col); st.add_vertex(t1)
			st.set_normal(b2.normalized()); st.set_color(col); st.add_vertex(b2)
			st.set_normal(t2.normalized()); st.set_color(col); st.add_vertex(t2)
			st.set_normal(t1.normalized()); st.set_color(col); st.add_vertex(t1)
			
	return st.commit()

static func _build_octahedron_mesh(type: String) -> ArrayMesh:
	var col := _color_for_type(type)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
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
	return st.commit()

static func _build_blocky_mesh() -> ArrayMesh:
	# Silver: squat rectangular prism with a tapered top — more "ore chunk" than crystal spike.
	var col := _color_for_type("Silver")
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := _MESH_UNIT_SIZE
	var w := s * 1.3   # base half-width
	var h := s * 3.5   # total height
	var tw := s * 0.8  # top half-width (slight taper)
	# Base corners (y=0), top corners (y=h)
	var b: Array[Vector3] = [Vector3(-w, 0, -w), Vector3(w, 0, -w), Vector3(w, 0, w), Vector3(-w, 0, w)]
	var t: Array[Vector3] = [Vector3(-tw, h, -tw), Vector3(tw, h, -tw), Vector3(tw, h, tw), Vector3(-tw, h, tw)]
	# 4 side faces
	for i in range(4):
		var j := (i + 1) % 4
		var n: Vector3 = (b[j] - b[i]).cross(t[i] - b[i]).normalized()
		st.set_normal(n); st.set_color(col); st.add_vertex(b[i])
		st.set_normal(n); st.set_color(col); st.add_vertex(b[j])
		st.set_normal(n); st.set_color(col); st.add_vertex(t[i])
		st.set_normal(n); st.set_color(col); st.add_vertex(b[j])
		st.set_normal(n); st.set_color(col); st.add_vertex(t[j])
		st.set_normal(n); st.set_color(col); st.add_vertex(t[i])
	# Top face
	st.set_normal(Vector3.UP); st.set_color(col)
	st.add_vertex(t[0]); st.add_vertex(t[2]); st.add_vertex(t[1])
	st.add_vertex(t[0]); st.add_vertex(t[3]); st.add_vertex(t[2])
	# Bottom face
	st.set_normal(Vector3.DOWN); st.set_color(col)
	st.add_vertex(b[0]); st.add_vertex(b[1]); st.add_vertex(b[2])
	st.add_vertex(b[0]); st.add_vertex(b[2]); st.add_vertex(b[3])
	return st.commit()

static func _color_for_type(type: String) -> Color:
	return ResourceRegistry.get_color(type)

static func _get_or_build_shape(size: float, is_flora: bool = false) -> CylinderShape3D:
	# Quantize to 5m buckets so nearby sizes share the same shape.
	var bucket := int(size / 5.0) * 5
	var key := str(bucket) + ("_flora" if is_flora else "")
	if _shared_shapes.has(key):
		return _shared_shapes[key]
	var cyl := CylinderShape3D.new()
	if is_flora:
		# Flora (trees, rocks) need a large hit cylinder so they're easy to shoot.
		# Height spans the full object; radius is generous for reliable collision.
		cyl.height = float(bucket) * 8.0
		cyl.radius = float(bucket) * 4.0
	else:
		cyl.height = float(bucket) * 8.0
		cyl.radius = float(bucket) * 2.2
	_shared_shapes[key] = cyl
	return cyl

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
			# ACE: Damage flash takes priority — keep loud so hits read clearly
			mesh_inst.material_override.emission_energy_multiplier = 12.0
		elif glows:
			# Subtle gem-like shimmer for real deposits; non-glowing flora skips this entirely.
			mesh_inst.material_override.emission_energy_multiplier = 0.15 + (glint * 6.0)

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

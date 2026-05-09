
extends Node3D

# AsteroidBelt.gd — True-streaming LOD with hysteresis.
# Slots are pre-computed deterministically; StaticBody3D nodes stream in/out
# from a pool as the player approaches/leaves. Visual MMIs follow the same
# state. Combat (collision + Targets/Destructible/Mineable groups) is coupled
# so lock-on cannot acquire a target the laser bolt cannot hit.

@export var belt_seed: int = 9999
@export var mmi_count: int = 14000
@export var phys_count: int = 250
@export var inner_radius: float = 1400000.0
@export var outer_radius: float = 2000000.0
@export var thickness: float = 20000.0

var rock_mesh_low: ArrayMesh
var rock_mesh_med: ArrayMesh
var rock_mesh_high: ArrayMesh

# Slot table — pre-computed at init, never reallocated
var belt_slots: Array = []                          # Dictionary per slot
var slot_active: Array = []                         # null or StaticBody3D
var slot_lod: PackedByteArray = PackedByteArray()   # 0=streaming-out, 1=low, 2=high
var asteroid_pool: Array = []                       # recycled StaticBody3D refs

var mmi_back: MultiMeshInstance3D
var mmi_phys_med: MultiMeshInstance3D
var mmi_phys_high: MultiMeshInstance3D
var player: Node3D
var _health_component_script: Script = null
var _mine_component_script: Script = null
var _asteroid_script: Script = null
var _cached_cel_mat: ShaderMaterial = null

# LOD thresholds (squared for cheap distance compare)
const SPAWN_DIST_SQ:        float =  500000.0 *  500000.0   # stream in
const DESPAWN_DIST_SQ:      float =  800000.0 *  800000.0   # stream out (300km hyst)
const PHYS_ENABLE_DIST_SQ:  float =   45000.0 *   45000.0   # collision + groups on
const PHYS_DISABLE_DIST_SQ: float =   65000.0 *   65000.0   # collision + groups off (20km hyst)
const HIGH_LOD_ENTER_SQ:    float =   10000.0 *   10000.0   # high-detail mesh
const HIGH_LOD_EXIT_SQ:     float =   15000.0 *   15000.0   # back to low (5km hyst)
const STELLAR_CUTOFF_SQ:    float = 4000000.0 * 4000000.0
const ATMOSPHERE_HIDE_DIST: float = 1375000.0
const SPAWN_BUDGET_PER_FRAME: int = 4
const DESPAWN_BUDGET_PER_FRAME: int = 6

var _rng: RandomNumberGenerator
var _md_ref = null
var _pulse_mats: Array = []

func _ready() -> void:
	rock_mesh_low = _build_faceted_rock_mesh(4)
	rock_mesh_med = _build_faceted_rock_mesh(8)
	rock_mesh_high = _build_faceted_rock_mesh(12)
	_health_component_script = load("res://src/combat/HealthComponent.gd")
	_mine_component_script = load("res://src/world/AsteroidMineComponent.gd")
	_asteroid_script = load("res://src/world/Asteroid.gd")
	_spawn_deterministic_belt()
	set_process(true)

	var players = get_tree().get_nodes_in_group("Player")
	if players.size() > 0: player = players[0]

func _spawn_deterministic_belt() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = belt_seed

	if not _cached_cel_mat:
		_cached_cel_mat = ShaderMaterial.new()
		_cached_cel_mat.shader = load("res://src/shaders/hatch_toon.gdshader")
		var outline = ShaderMaterial.new()
		outline.shader = load("res://src/shaders/outline.gdshader")
		outline.set_shader_parameter("outline_width", 1.2)
		outline.set_shader_parameter("outline_color", Color.BLACK)
		_cached_cel_mat.next_pass = outline

	var mmi_mat = _cached_cel_mat.duplicate()
	var phys_mat = _cached_cel_mat.duplicate()
	_pulse_mats = [mmi_mat, phys_mat]

	# TIER 1: Distant ambient background (untouched, separate seed positions)
	mmi_back = MultiMeshInstance3D.new()
	mmi_back.multimesh = MultiMesh.new()
	mmi_back.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi_back.multimesh.use_colors = true
	mmi_back.multimesh.instance_count = mmi_count
	mmi_back.multimesh.mesh = rock_mesh_low
	mmi_back.material_override = mmi_mat
	mmi_back.visibility_range_begin = 400000.0
	add_child(mmi_back)

	# TIER 2 & 3: Streamed-slot MMIs (mesh swap drives low/high detail)
	mmi_phys_med = MultiMeshInstance3D.new()
	mmi_phys_med.multimesh = MultiMesh.new()
	mmi_phys_med.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi_phys_med.multimesh.instance_count = phys_count
	mmi_phys_med.multimesh.mesh = rock_mesh_med
	mmi_phys_med.material_override = phys_mat
	mmi_phys_med.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi_phys_med)

	mmi_phys_high = MultiMeshInstance3D.new()
	mmi_phys_high.multimesh = MultiMesh.new()
	mmi_phys_high.multimesh.transform_format = MultiMesh.TRANSFORM_3D
	mmi_phys_high.multimesh.instance_count = phys_count
	mmi_phys_high.multimesh.mesh = rock_mesh_high
	mmi_phys_high.material_override = phys_mat
	add_child(mmi_phys_high)

	var big_aabb = AABB(Vector3(-2e6, -5e4, -2e6), Vector3(4e6, 1e5, 4e6))
	mmi_back.custom_aabb = big_aabb
	mmi_phys_med.custom_aabb = big_aabb
	mmi_phys_high.custom_aabb = big_aabb

	# Populate ambient background MMI (unchanged)
	for i in range(mmi_count):
		var angle = _rng.randf() * TAU
		var dist = _rng.randf_range(inner_radius, outer_radius)
		var h = pow(_rng.randf_range(-1.0, 1.0), 3.0) * thickness
		var xform = Transform3D().rotated(Vector3(_rng.randf(), _rng.randf(), _rng.randf()).normalized(), _rng.randf() * TAU)
		xform = xform.scaled(Vector3.ONE * (5.0 + pow(_rng.randf(), 2.0) * 120.0))
		xform.origin = Vector3(cos(angle) * dist, h, sin(angle) * dist)
		mmi_back.multimesh.set_instance_transform(i, xform)
		var inst_col = Color.from_hsv(0, 0, _rng.randf_range(0.2, 0.4))
		if _rng.randf() > 0.45: inst_col = Color.from_hsv(_rng.randf_range(0.04, 0.08), 0.4, _rng.randf_range(0.3, 0.5))
		mmi_back.multimesh.set_instance_color(i, inst_col)

	# Build deterministic slot table (no nodes instantiated yet)
	slot_active.resize(phys_count)
	slot_lod.resize(phys_count)
	for i in range(phys_count):
		var angle2 = _rng.randf() * TAU
		var dist2 = _rng.randf_range(inner_radius, outer_radius)
		var h2 = pow(_rng.randf_range(-1.0, 1.0), 2.0) * (thickness * 0.8)
		var rot_v = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU)
		var s_roll = _rng.randf()
		var scale_val = 25.0 + pow(s_roll, 4.0) * 1600.0
		var pos = Vector3(cos(angle2) * dist2, h2, sin(angle2) * dist2)
		var slot_basis = Basis.from_euler(rot_v).scaled(Vector3.ONE * scale_val)
		var xform = Transform3D(slot_basis, pos)
		var slot = {
			"pos": pos,
			"rot": rot_v,
			"scale_val": scale_val,
			"xform": xform,
			"alive": true,
		}
		belt_slots.append(slot)
		slot_active[i] = null
		slot_lod[i] = 0
		mmi_phys_med.multimesh.set_instance_transform(i, Transform3D().scaled(Vector3.ZERO))
		mmi_phys_high.multimesh.set_instance_transform(i, Transform3D().scaled(Vector3.ZERO))

func _get_music_director():
	if _md_ref and is_instance_valid(_md_ref):
		return _md_ref
	var nodes := get_tree().get_nodes_in_group("MusicDirector")
	if nodes.size() > 0:
		_md_ref = nodes[0]
	return _md_ref

func _process(_delta: float) -> void:
	if not player:
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0: player = found[0]
		return

	var md = _get_music_director()
	if md and not _pulse_mats.is_empty():
		var kick_amt: float = float(md.kick_intensity) * 0.14
		var beat_amt: float = float(md.beat_intensity) * 0.04
		var s: float = 1.0 + kick_amt + beat_amt
		for mat in _pulse_mats:
			if mat:
				mat.set_shader_parameter("pulse_scale", s)

	var ship_pos = player.global_position
	var dist_to_planet = ship_pos.distance_to(global_position)

	if dist_to_planet < ATMOSPHERE_HIDE_DIST:
		if visible: hide()
		return
	elif not visible:
		show()

	if dist_to_planet * dist_to_planet > STELLAR_CUTOFF_SQ:
		return

	var ship_local = to_local(ship_pos)
	var spawned: int = 0
	var despawned: int = 0
	var slot_count: int = belt_slots.size()

	for i in range(slot_count):
		var slot: Dictionary = belt_slots[i]
		if not slot.alive:
			continue
		var d_sq: float = (slot.pos as Vector3).distance_squared_to(ship_local)
		var active = slot_active[i]

		# Stream in / out — full lifecycle gated by hysteresis
		if active == null:
			if d_sq < SPAWN_DIST_SQ and spawned < SPAWN_BUDGET_PER_FRAME:
				active = _stream_in(i, slot)
				slot_active[i] = active
				spawned += 1
			else:
				continue
		elif d_sq > DESPAWN_DIST_SQ and despawned < DESPAWN_BUDGET_PER_FRAME:
			_stream_out(i)
			despawned += 1
			continue

		# Mesh detail swap with hysteresis
		var lod_state: int = slot_lod[i]
		if lod_state != 2 and d_sq < HIGH_LOD_ENTER_SQ:
			_set_detail(i, 2)
		elif lod_state != 1 and d_sq > HIGH_LOD_EXIT_SQ:
			_set_detail(i, 1)

		# Combat (collision + groups) with hysteresis — locks targeting to actual hit range
		var has_phys: bool = active.get_meta("phys_active", false)
		if not has_phys and d_sq < PHYS_ENABLE_DIST_SQ:
			_enable_combat(active)
		elif has_phys and d_sq > PHYS_DISABLE_DIST_SQ:
			_disable_combat(active)

func _stream_in(slot_idx: int, slot: Dictionary) -> StaticBody3D:
	var node: StaticBody3D
	if asteroid_pool.size() > 0:
		node = asteroid_pool.pop_back()
		_reset_pooled(node)
		if node.get_parent() == null:
			add_child(node)
	else:
		node = _build_asteroid()
		add_child(node)

	node.transform = slot.xform
	node.set_meta("slot_idx", slot_idx)
	node.set_meta("phys_active", false)
	mmi_phys_med.multimesh.set_instance_transform(slot_idx, slot.xform)
	mmi_phys_high.multimesh.set_instance_transform(slot_idx, Transform3D().scaled(Vector3.ZERO))
	slot_lod[slot_idx] = 1
	return node

func _stream_out(slot_idx: int) -> void:
	var node = slot_active[slot_idx]
	if node == null: return
	if node.get_meta("phys_active", false):
		_disable_combat(node)
	mmi_phys_med.multimesh.set_instance_transform(slot_idx, Transform3D().scaled(Vector3.ZERO))
	mmi_phys_high.multimesh.set_instance_transform(slot_idx, Transform3D().scaled(Vector3.ZERO))
	slot_active[slot_idx] = null
	slot_lod[slot_idx] = 0
	node.set_meta("slot_idx", -1)
	node.transform = Transform3D()
	asteroid_pool.append(node)

func _set_detail(slot_idx: int, level: int) -> void:
	var slot: Dictionary = belt_slots[slot_idx]
	if level == 2:
		mmi_phys_high.multimesh.set_instance_transform(slot_idx, slot.xform)
		mmi_phys_med.multimesh.set_instance_transform(slot_idx, Transform3D().scaled(Vector3.ZERO))
	else:
		mmi_phys_med.multimesh.set_instance_transform(slot_idx, slot.xform)
		mmi_phys_high.multimesh.set_instance_transform(slot_idx, Transform3D().scaled(Vector3.ZERO))
	slot_lod[slot_idx] = level

func _enable_combat(node: StaticBody3D) -> void:
	var coll = node.get_node_or_null("CollisionShape3D")
	if coll: coll.disabled = false
	if not node.is_in_group("Targets"): node.add_to_group("Targets")
	if not node.is_in_group("Destructible"): node.add_to_group("Destructible")
	if not node.is_in_group("Mineable"): node.add_to_group("Mineable")
	node.set_meta("phys_active", true)

func _disable_combat(node: StaticBody3D) -> void:
	var coll = node.get_node_or_null("CollisionShape3D")
	if coll: coll.disabled = true
	if node.is_in_group("Targets"): node.remove_from_group("Targets")
	if node.is_in_group("Destructible"): node.remove_from_group("Destructible")
	if node.is_in_group("Mineable"): node.remove_from_group("Mineable")
	node.set_meta("phys_active", false)

func _build_asteroid() -> StaticBody3D:
	var node = StaticBody3D.new()
	if _asteroid_script:
		node.set_script(_asteroid_script)

	var coll = CollisionShape3D.new()
	coll.name = "CollisionShape3D"
	var shape = SphereShape3D.new()
	# Local radius; parent scale (25–1625) multiplies → world hitbox tracks visible silhouette
	shape.radius = 8.0
	coll.shape = shape
	coll.disabled = true
	node.add_child(coll)

	if _health_component_script:
		var hc = Node.new()
		hc.set_script(_health_component_script)
		hc.name = "HealthComponent"
		hc.set("max_health", 4.0)
		node.add_child(hc)

	if _mine_component_script:
		var mc = Node3D.new()
		mc.set_script(_mine_component_script)
		mc.name = "MineComponent"
		node.add_child(mc)
		var hc_ref = node.get_node_or_null("HealthComponent")
		if hc_ref and not hc_ref.is_connected("health_depleted", mc._on_health_depleted):
			hc_ref.health_depleted.connect(mc._on_health_depleted)
		if mc.has_signal("asteroid_destroyed") and not mc.is_connected("asteroid_destroyed", _on_asteroid_destroyed):
			mc.asteroid_destroyed.connect(_on_asteroid_destroyed)

	return node

func _reset_pooled(node: StaticBody3D) -> void:
	var hc = node.get_node_or_null("HealthComponent")
	if hc:
		hc.current_health = hc.max_health
	var mc = node.get_node_or_null("MineComponent")
	if mc:
		mc.set("destroyed", false)
		mc.set("_health", 4)
	_disable_combat(node)
	var coll = node.get_node_or_null("CollisionShape3D")
	if coll and coll.shape is SphereShape3D:
		(coll.shape as SphereShape3D).radius = 8.0
	node.set_meta("phys_active", false)

func _on_asteroid_destroyed(asteroid: Node) -> void:
	if not (asteroid is StaticBody3D): return
	var sb := asteroid as StaticBody3D
	var slot_idx: int = int(sb.get_meta("slot_idx", -1))
	if slot_idx < 0 or slot_idx >= belt_slots.size():
		return
	(belt_slots[slot_idx] as Dictionary)["alive"] = false
	mmi_phys_med.multimesh.set_instance_transform(slot_idx, Transform3D().scaled(Vector3.ZERO))
	mmi_phys_high.multimesh.set_instance_transform(slot_idx, Transform3D().scaled(Vector3.ZERO))
	if sb.get_meta("phys_active", false):
		_disable_combat(sb)
	slot_active[slot_idx] = null
	slot_lod[slot_idx] = 0
	sb.set_meta("slot_idx", -1)
	sb.transform = Transform3D()
	asteroid_pool.append(sb)

func _build_faceted_rock_mesh(sides: int) -> ArrayMesh:
	var st = SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r1 = 8.0; var y1 = 4.0; var r2 = 5.0; var y2 = 7.0
	var top = Vector3(2.0, 9.0, -1.0); var center_bot = Vector3(0, -4.5, 0); var center_top = top - Vector3(0, 4.5, 0)
	var c_bot = Color("#2D1B1B"); var c_mid1 = Color("#3E2723"); var c_mid2 = Color("#4E342E"); var c_top = Color("#5D4037")
	for i in range(sides):
		var a1 = i * TAU/sides; var a2 = (i+1) * TAU/sides
		var b1 = Vector3(cos(a1)*r1, -4.5, sin(a1)*r1); var b2 = Vector3(cos(a2)*r1, -4.5, sin(a2)*r1)
		var j1 = sin(a1 * 4.0) * 1.5 if sides > 4 else 0.0
		var j2 = sin(a2 * 4.0) * 1.5 if sides > 4 else 0.0
		var m1 = Vector3(cos(a1)*(r1+j1), y1-4.5+j1, sin(a1)*(r1+j1)); var m2 = Vector3(cos(a2)*(r1+j2), y1-4.5+j2, sin(a2)*(r1+j2))
		var t1 = Vector3(cos(a1)*r2, y2-4.5+j1*0.5, sin(a1)*r2); var t2 = Vector3(cos(a2)*r2, y2-4.5+j2*0.5, sin(a2)*r2)
		st.set_color(c_bot); st.add_vertex(b2); st.set_color(c_mid1); st.add_vertex(m1); st.set_color(c_bot); st.add_vertex(b1)
		st.set_color(c_mid1); st.add_vertex(m2); st.add_vertex(m1); st.set_color(c_bot); st.add_vertex(b2)
		st.set_color(c_mid1); st.add_vertex(m2); st.set_color(c_mid2); st.add_vertex(t1); st.set_color(c_mid1); st.add_vertex(m1)
		st.set_color(c_mid2); st.add_vertex(t2); st.add_vertex(t1); st.set_color(c_mid1); st.add_vertex(m2)
		st.set_color(c_mid2); st.add_vertex(t2); st.set_color(c_top); st.add_vertex(center_top); st.set_color(c_mid2); st.add_vertex(t1)
		st.set_color(c_bot); st.add_vertex(b1); st.add_vertex(center_bot); st.add_vertex(b2)
	st.generate_normals(false); return st.commit()

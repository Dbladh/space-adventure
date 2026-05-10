extends Node3D

# SurfaceCell.gd
# One streaming cell on a planet's cube-grid surface.  Owns all scatter
# (trees, rocks, grass, minerals) for a fixed angular tile.  Lifecycle:
#
#   build_async()          -> schedules CellPropGenerator on WorkerThreadPool
#   poll_build()           -> main-thread check; transitions to BUILT once ready
#   activate_tier(tier)    -> atomic add/remove of MMIs and collision body
#   deactivate()           -> teardown all children, return to UNBUILT
#   apply_damage_to_shape  -> routes laser bolt hits to the right prop slot
#
# Atomic activation is the key correctness property: when a cell becomes
# Tier-2, the collision body and all its shapes are added in the same
# call as the visuals, so the player can never see a tree without a hitbox.

const SurfaceCellId = preload("res://src/world/streaming/SurfaceCellId.gd")
const CellPropGenerator = preload("res://src/world/streaming/CellPropGenerator.gd")
const SurfaceLootSpawner = preload("res://src/world/streaming/SurfaceLootSpawner.gd")

# Tier states.
const TIER_NONE: int = -1   # not yet built
const TIER_OFF:  int = 0    # built, but no scene contents
const TIER_VIS:  int = 1    # visual MMIs only
const TIER_FULL: int = 2    # visual + collision body + mineral nodes

# Build states.
const BUILD_IDLE: int = 0
const BUILD_RUNNING: int = 1
const BUILD_DONE: int = 2

# Hittable bit (Layer 3, value 4).  Pre-Phase-4 we coexist with Layer 6 by
# keeping both bits on the body so legacy LaserBolt's mask still works.
const HITTABLE_LAYER: int = (1 << 2) | (1 << 5)

# Collision sphere radius hints — match the legacy SurfacePropProxy values
# (PlanetChunk._spawn_rock 25m, _spawn_tree_lods 40m).
const TREE_SPHERE_R: float = 40.0
const ROCK_SPHERE_R: float = 25.0
const TREE_HEALTH: int = 2
const ROCK_HEALTH: int = 2

# Per-MMI GPU-side visibility fade.  Each cell's MMI fades its instances out
# beyond these distances, letting the renderer skip them even though the
# MMI itself is still in the active set.  Trunks track foliage so distant
# trees aren't disembodied floating canopies; grass and rocks have their
# own tighter ranges since they don't read as silhouette at long distance.
const FOLIAGE_VIS_RANGE_END:    float = 8000.0
const FOLIAGE_VIS_RANGE_MARGIN: float = 1500.0
const TRUNK_VIS_RANGE_END:      float = 7500.0   # was 1500 — match foliage so trunks don't disappear early
const TRUNK_VIS_RANGE_MARGIN:   float = 1500.0
const ROCK_VIS_RANGE_END:       float = 6000.0
const ROCK_VIS_RANGE_MARGIN:    float = 1200.0
const GRASS_VIS_RANGE_END:      float =  800.0
const GRASS_VIS_RANGE_MARGIN:   float =  300.0

var planet: Node = null
var cell_id: int = 0
var streamer: Node = null

var _tier: int = TIER_NONE
var _build_state: int = BUILD_IDLE
var _task_id: int = -1
var _gen_data: Dictionary = {}

# Scene children — null when not at the relevant tier.
var _trees_mmi: MultiMeshInstance3D = null
var _trunk_mmi: MultiMeshInstance3D = null
var _rocks_mmi: MultiMeshInstance3D = null
var _grass_mmi: MultiMeshInstance3D = null
var _coll_body: StaticBody3D = null
var _mineral_nodes: Array[StaticBody3D] = []

# Per-shape table for damage routing.  Index = shape_index inside _coll_body.
# Each entry is { kind: "tree"|"rock", arr_idx: int, health: int, dead: bool, mmi: MultiMeshInstance3D, paired: Array[MultiMeshInstance3D], local_idx: int, res_type: String }
var _shape_table: Array = []

# Staged-build state machine for the visual tier.  Spawning all four prop
# types (minerals + rocks + trees + grass) in the same frame produces an
# FPS dip every time a cell streams in — each MMI allocation triggers GPU
# buffer upload, and mineral nodes are full StaticBody3Ds with lights.
# Instead, queue the work into four ordered stages and drain one per frame.
# Order: minerals (rare landmarks) → rocks → trees → grass.
const _STAGE_NONE:     int = -1
const _STAGE_MINERALS: int = 0
const _STAGE_ROCKS:    int = 1
const _STAGE_TREES:    int = 2
const _STAGE_GRASS:    int = 3
const _STAGE_DONE:     int = 4
# After this many frames stuck on the same stage under throttle, push through
# anyway so a cell can't permanently sit half-built.
const _STAGE_MAX_DEFER_FRAMES: int = 60
var _visual_stage: int = _STAGE_NONE
var _stage_defer_frames: int = 0

func setup(p_planet: Node, p_cell_id: int, p_streamer: Node) -> void:
	planet = p_planet
	cell_id = p_cell_id
	streamer = p_streamer
	# Place the cell at the planet's origin so all child transforms (which
	# CellPropGenerator emits in planet-local space) land in the correct
	# world spot.  The cell is just a logical container.
	transform = Transform3D.IDENTITY

# ─── BUILD ────────────────────────────────────────────────────────────────────

var _destroyed_snapshot: PackedInt32Array = PackedInt32Array()

func build_async() -> void:
	if _build_state != BUILD_IDLE:
		return
	# Snapshot the destruction registry on the main thread so the worker
	# task can run independently of registry mutations from gameplay code.
	_destroyed_snapshot = PackedInt32Array()
	if streamer != null:
		var registry: Node = streamer.get_destruction_registry()
		if registry != null and registry.has_method("get_destroyed_for_cell"):
			_destroyed_snapshot = registry.call("get_destroyed_for_cell", cell_id)
	_build_state = BUILD_RUNNING
	# Worker-thread task.  The generator only reads thread-safe planet state.
	_task_id = WorkerThreadPool.add_task(_threaded_build)

func _threaded_build() -> void:
	_gen_data = CellPropGenerator.generate(planet, cell_id, _destroyed_snapshot)

# Returns true once build_async has completed and the cell is ready for
# tier activation.  Streamer calls this every frame for cells in flight.
func poll_build() -> bool:
	if _build_state == BUILD_DONE:
		return true
	if _build_state != BUILD_RUNNING or _task_id == -1:
		return false
	if not WorkerThreadPool.is_task_completed(_task_id):
		return false
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1
	_build_state = BUILD_DONE
	_tier = TIER_OFF
	return true

func is_built() -> bool:
	return _build_state == BUILD_DONE

func current_tier() -> int:
	return _tier

# ─── TIER ACTIVATION ──────────────────────────────────────────────────────────

func activate_tier(target_tier: int) -> void:
	if not is_built():
		return
	if target_tier == _tier:
		return
	# Walk through tiers monotonically.  Both directions are atomic with
	# respect to physics: the collision body and its shapes always move in
	# lockstep with the visuals.
	if target_tier > _tier:
		if _tier < TIER_VIS and target_tier >= TIER_VIS:
			_enter_visual_tier()
		if _tier < TIER_FULL and target_tier >= TIER_FULL:
			_enter_full_tier()
	else:
		if _tier >= TIER_FULL and target_tier < TIER_FULL:
			_exit_full_tier()
		if _tier >= TIER_VIS and target_tier < TIER_VIS:
			_exit_visual_tier()
	_tier = target_tier

func deactivate() -> void:
	if _tier >= TIER_FULL: _exit_full_tier()
	if _tier >= TIER_VIS: _exit_visual_tier()
	_tier = TIER_NONE
	_build_state = BUILD_IDLE
	_gen_data.clear()
	_shape_table.clear()

# ─── VISUAL TIER ──────────────────────────────────────────────────────────────

func _enter_visual_tier() -> void:
	# Don't build anything synchronously — just kick off the staged build.
	# _process() will drain one stage per frame in the canonical order:
	# minerals → rocks → trees → grass.  Tier-2 promotion (collision body)
	# can still happen mid-build because _enter_full_tier reads from
	# _gen_data directly, not from the rendered MMIs.
	_visual_stage = _STAGE_MINERALS
	set_process(true)

func _process(_delta: float) -> void:
	if _visual_stage < _STAGE_MINERALS or _visual_stage >= _STAGE_DONE:
		set_process(false)
		return
	# Adaptive throttle: skip this stage if the engine is already over
	# budget.  Cell remains processing so it picks up where it left off
	# next frame.  Safety hatch (_STAGE_MAX_DEFER_FRAMES) guarantees we
	# eventually push the stage through, so chronically-slow hardware
	# can't leave a cell stuck half-built.
	if streamer != null and "frame_time_budget_ms" in streamer:
		var ms: float = float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
		if ms > 0.0 and ms > streamer.frame_time_budget_ms:
			_stage_defer_frames += 1
			if _stage_defer_frames < _STAGE_MAX_DEFER_FRAMES:
				return
			# Fall through: stage gets built this frame regardless of budget.
	_stage_defer_frames = 0
	# Run exactly one stage this frame, then advance the counter.
	match _visual_stage:
		_STAGE_MINERALS:
			var minerals: Array = _gen_data.get("minerals", [])
			if not minerals.is_empty():
				_build_mineral_nodes(minerals)
		_STAGE_ROCKS:
			var rocks: Array = _gen_data.get("rocks", [])
			if not rocks.is_empty():
				_build_rock_mmi(rocks)
		_STAGE_TREES:
			var trees: Array = _gen_data.get("trees", [])
			if not trees.is_empty():
				_build_tree_mmis(trees)
		_STAGE_GRASS:
			var grass: Array = _gen_data.get("grass", [])
			if not grass.is_empty():
				_build_grass_mmi(grass)
	_visual_stage += 1
	if _visual_stage >= _STAGE_DONE:
		set_process(false)

func _exit_visual_tier() -> void:
	# Cancel any in-flight staged build so cells that despawn mid-stage
	# don't keep ticking through later stages on a freed instance.
	_visual_stage = _STAGE_NONE
	_stage_defer_frames = 0
	set_process(false)

	for n in [_trees_mmi, _trunk_mmi, _rocks_mmi, _grass_mmi]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_trees_mmi = null
	_trunk_mmi = null
	_rocks_mmi = null
	_grass_mmi = null
	# Mineral nodes are now Tier-1 children too — tear them down when the
	# visual tier exits so they don't survive cell despawn.
	for m in _mineral_nodes:
		if is_instance_valid(m):
			for c in m.tree_exiting.get_connections():
				m.tree_exiting.disconnect(c.callable)
			m.queue_free()
	_mineral_nodes.clear()

func _build_tree_mmis(trees: Array) -> void:
	var meshes: Dictionary = streamer.get_archetype_meshes()
	var foliage_mat: Material = streamer.get_foliage_material()
	var trunk_mat: Material = streamer.get_trunk_material()
	if meshes.is_empty():
		return

	var n: int = trees.size()
	# Foliage MMI (high-detail by default — Tier-2 cells are already close enough
	# that lower-detail foliage would be visibly chunky).
	var fol_mesh: ArrayMesh = meshes.get("fol_h", null)
	if fol_mesh == null:
		fol_mesh = meshes.get("fol_l", null)
	var trk_mesh: ArrayMesh = meshes.get("trk_h", null)
	if trk_mesh == null:
		trk_mesh = meshes.get("trk_l", null)

	if fol_mesh != null:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = fol_mesh
		mm.instance_count = n
		var pal_h: float = 0.3
		if "pal_forest_h" in planet:
			pal_h = float(planet.get("pal_forest_h"))
		for i in range(n):
			var xf: Transform3D = trees[i]
			var pos: Vector3 = xf.origin
			var t_hue: float = fposmod(pal_h + 0.5 + fposmod(pos.x * 0.012, 0.3) - 0.15, 1.0)
			var t_col := Color.from_hsv(t_hue, 0.85, 0.92)
			mm.set_instance_transform(i, xf)
			mm.set_instance_color(i, t_col)
		mm.custom_aabb = _calc_forest_aabb(trees)
		_trees_mmi = MultiMeshInstance3D.new()
		_trees_mmi.multimesh = mm
		_trees_mmi.material_override = foliage_mat
		_trees_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_trees_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_trees_mmi.visibility_range_end = FOLIAGE_VIS_RANGE_END
		_trees_mmi.visibility_range_end_margin = FOLIAGE_VIS_RANGE_MARGIN
		_trees_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(_trees_mmi)

	if trk_mesh != null:
		var mt := MultiMesh.new()
		mt.transform_format = MultiMesh.TRANSFORM_3D
		mt.use_colors = true
		mt.mesh = trk_mesh
		mt.instance_count = n
		for i in range(n):
			var xf: Transform3D = trees[i]
			var pos: Vector3 = xf.origin
			var trk_seed: int = int(abs(pos.x * 133.0 + pos.z * 77.0)) % 3
			var tr_c := Color(0.35, 0.25, 0.15)
			if trk_seed == 1: tr_c = Color(0.55, 0.45, 0.35)
			elif trk_seed == 2: tr_c = Color(0.85, 0.85, 0.8)
			mt.set_instance_transform(i, xf)
			mt.set_instance_color(i, tr_c)
		mt.custom_aabb = _calc_forest_aabb(trees)
		_trunk_mmi = MultiMeshInstance3D.new()
		_trunk_mmi.multimesh = mt
		_trunk_mmi.material_override = trunk_mat
		_trunk_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		_trunk_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_trunk_mmi.visibility_range_end = TRUNK_VIS_RANGE_END
		_trunk_mmi.visibility_range_end_margin = TRUNK_VIS_RANGE_MARGIN
		_trunk_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		add_child(_trunk_mmi)

func _build_rock_mmi(rocks: Array) -> void:
	var meshes: Dictionary = streamer.get_archetype_meshes()
	var rock_mat: Material = streamer.get_rock_material()
	var rock_mesh: ArrayMesh = meshes.get("rock", null)
	if rock_mesh == null:
		return

	var n: int = rocks.size()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = rock_mesh
	mm.instance_count = n
	for i in range(n):
		var xf: Transform3D = rocks[i]
		var h_v: int = hash(xf.origin)
		var g: float = 0.34 + fposmod(float(h_v % 100) / 100.0, 0.32)
		var r_col := Color(g * 1.05, g * 0.95, g * 0.85, 1.0)
		mm.set_instance_transform(i, xf)
		mm.set_instance_color(i, r_col)
	mm.custom_aabb = _calc_aabb_padded(rocks, 8.0, 50.0)
	_rocks_mmi = MultiMeshInstance3D.new()
	_rocks_mmi.multimesh = mm
	_rocks_mmi.material_override = rock_mat
	_rocks_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_rocks_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rocks_mmi.visibility_range_end = ROCK_VIS_RANGE_END
	_rocks_mmi.visibility_range_end_margin = ROCK_VIS_RANGE_MARGIN
	_rocks_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_rocks_mmi)

func _build_grass_mmi(grass: Array) -> void:
	var meshes: Dictionary = streamer.get_archetype_meshes()
	var grass_mat: Material = streamer.get_grass_material()
	var grass_mesh: ArrayMesh = meshes.get("grass", null)
	if grass_mesh == null:
		return

	var n: int = grass.size()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = grass_mesh
	mm.instance_count = n
	for i in range(n):
		var xf: Transform3D = grass[i]
		mm.set_instance_transform(i, xf)
		var j: float = fmod(float(hash(xf.origin)), 10.0) / 10.0
		mm.set_instance_custom_data(i, Color(j, 0, 0, 0))
	mm.custom_aabb = _calc_aabb_padded(grass, 6.0, 30.0)
	_grass_mmi = MultiMeshInstance3D.new()
	_grass_mmi.multimesh = mm
	_grass_mmi.material_override = grass_mat
	_grass_mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	_grass_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_grass_mmi.visibility_range_end = GRASS_VIS_RANGE_END
	_grass_mmi.visibility_range_end_margin = GRASS_VIS_RANGE_MARGIN
	_grass_mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	add_child(_grass_mmi)

# ─── MINERALS (Tier 1) ────────────────────────────────────────────────────────

func _build_mineral_nodes(minerals: Array) -> void:
	# Spawn mineral deposits as full StaticBody3D children of the cell.  They
	# own their own collision shape + light + VFX (MineableResource handles
	# all that), so they're independent of the cell's aggregate body which
	# only covers trees/rocks for per-shape damage routing.  Done at Tier 1
	# so glowing landmark crystals are visible as soon as a cell becomes
	# visible — minerals are the gameplay-relevant payoff, they shouldn't
	# wait for the player to be within 6km.
	var m_script: Resource = load("res://src/world/MineableResource.gd")
	if m_script == null:
		return
	# Plain flora props (Wood/Stone/Carbon Fiber) only glow on rare A-tier+
	# planets.  Mirrors PlanetChunk:2087-2090.
	var rank_label: String = ""
	if "planet_rank" in planet:
		rank_label = String(planet.get("planet_rank"))
	var planet_can_glow: bool = rank_label in ["A", "S", "SS", "★ LEGENDARY"]
	var flora_types := ["Wood", "Stone", "Carbon Fiber"]
	for item in minerals:
		var xf: Transform3D = item.get("xform", Transform3D())
		var type: String = String(item.get("type", "Copper"))
		var local_idx: int = int(item.get("local_idx", -1))
		var res := StaticBody3D.new()
		res.set_script(m_script)
		res.set("resource_type", type)
		var prop_glows: bool = true
		if type in flora_types:
			prop_glows = planet_can_glow and ((hash(xf.origin) & 1) == 0)
		res.set("glows", prop_glows)
		res.transform = xf
		res.set_meta("surface_cell", weakref(self))
		res.set_meta("cell_local_idx", local_idx)
		res.tree_exiting.connect(_on_mineral_exiting.bind(local_idx))
		add_child(res)
		_mineral_nodes.append(res)

# ─── FULL (collision aggregate) TIER ──────────────────────────────────────────

func _enter_full_tier() -> void:
	var trees: Array = _gen_data.get("trees", [])
	var rocks: Array = _gen_data.get("rocks", [])
	var tree_idx: PackedInt32Array = _gen_data.get("tree_indices", PackedInt32Array())
	var rock_idx: PackedInt32Array = _gen_data.get("rock_indices", PackedInt32Array())

	# Build aggregate body with one sphere per Tier-2-eligible prop.
	# Shapes are added in tree-then-rock order so shape_index is stable.
	if not trees.is_empty() or not rocks.is_empty():
		_coll_body = StaticBody3D.new()
		_coll_body.collision_layer = HITTABLE_LAYER
		_coll_body.collision_mask = 0
		_coll_body.add_to_group("Mineable")
		_coll_body.add_to_group("Targets")
		_coll_body.add_to_group("Destructible")
		_coll_body.set_meta("surface_cell", weakref(self))
		add_child(_coll_body)

		var shape_index: int = 0

		for i in range(trees.size()):
			var xf: Transform3D = trees[i]
			var local_idx: int = int(tree_idx[i]) if i < tree_idx.size() else -1
			var sphere := SphereShape3D.new()
			sphere.radius = TREE_SPHERE_R
			var cs := CollisionShape3D.new()
			cs.shape = sphere
			# Position the shape at the prop, lifted slightly along the local
			# up axis so the sphere sits on the trunk rather than the ground.
			var up: Vector3 = xf.basis.y.normalized()
			cs.transform = Transform3D(Basis(), xf.origin + up * (TREE_SPHERE_R * 0.65))
			_coll_body.add_child(cs)
			_shape_table.append({
				"kind": "tree",
				"arr_idx": i,
				"shape_index": shape_index,
				"shape_node": cs,
				"health": TREE_HEALTH,
				"dead": false,
				"local_idx": local_idx,
				"res_type": "Wood",
				"world_pos": xf.origin,
			})
			shape_index += 1

		for i in range(rocks.size()):
			var xf: Transform3D = rocks[i]
			var local_idx: int = int(rock_idx[i]) if i < rock_idx.size() else -1
			var sphere := SphereShape3D.new()
			sphere.radius = ROCK_SPHERE_R
			var cs := CollisionShape3D.new()
			cs.shape = sphere
			var up: Vector3 = xf.basis.y.normalized()
			cs.transform = Transform3D(Basis(), xf.origin + up * (ROCK_SPHERE_R * 0.65))
			_coll_body.add_child(cs)
			_shape_table.append({
				"kind": "rock",
				"arr_idx": i,
				"shape_index": shape_index,
				"shape_node": cs,
				"health": ROCK_HEALTH,
				"dead": false,
				"local_idx": local_idx,
				"res_type": "Stone",
				"world_pos": xf.origin,
			})
			shape_index += 1

func _exit_full_tier() -> void:
	# Mineral nodes are owned by the visual tier now — only the aggregate
	# collision body for trees/rocks belongs to the full tier.
	if _coll_body != null and is_instance_valid(_coll_body):
		_coll_body.queue_free()
	_coll_body = null
	_shape_table.clear()

# ─── DAMAGE ROUTING ───────────────────────────────────────────────────────────

# Result codes from apply_damage_to_shape.
const HIT_RESULT_MISS:    int = 0  # bad index or prop already dead — bolt should pass through
const HIT_RESULT_WOUNDED: int = 1  # prop took damage and survived — bolt explodes (small VFX)
const HIT_RESULT_KILLED:  int = 2  # prop just died — bolt explodes (big VFX)

# Called from LaserBolt._on_body_shape_entered (Phase 5) or directly from
# Player.gd's swept raycast.  shape_index is the body-scope shape index
# reported by the physics engine; it maps 1:1 to entries in _shape_table.
# Returns one of HIT_RESULT_*.
func apply_damage_to_shape(shape_index: int, dmg: float) -> int:
	if shape_index < 0 or shape_index >= _shape_table.size():
		return HIT_RESULT_MISS
	var entry: Dictionary = _shape_table[shape_index]
	if entry.get("dead", false):
		return HIT_RESULT_MISS
	var health: int = int(entry.get("health", 1))
	health -= int(round(dmg))
	if health > 0:
		entry["health"] = health
		_shape_table[shape_index] = entry
		return HIT_RESULT_WOUNDED
	# Dead — tear down this shape + its visual instance, register destruction,
	# drop loot.
	entry["dead"] = true
	entry["health"] = 0
	_shape_table[shape_index] = entry

	var shape_node: CollisionShape3D = entry.get("shape_node", null)
	if shape_node != null and is_instance_valid(shape_node):
		shape_node.disabled = true

	var kind: String = String(entry.get("kind", ""))
	var arr_idx: int = int(entry.get("arr_idx", -1))
	var hidden: Transform3D = Transform3D().scaled(Vector3.ZERO)
	if kind == "tree":
		if _trees_mmi != null and is_instance_valid(_trees_mmi) and _trees_mmi.multimesh != null:
			_trees_mmi.multimesh.set_instance_transform(arr_idx, hidden)
		if _trunk_mmi != null and is_instance_valid(_trunk_mmi) and _trunk_mmi.multimesh != null:
			_trunk_mmi.multimesh.set_instance_transform(arr_idx, hidden)
	elif kind == "rock":
		if _rocks_mmi != null and is_instance_valid(_rocks_mmi) and _rocks_mmi.multimesh != null:
			_rocks_mmi.multimesh.set_instance_transform(arr_idx, hidden)

	# Destruction registry: prop stays gone if cell streams out & back.
	var local_idx: int = int(entry.get("local_idx", -1))
	if local_idx >= 0 and streamer != null:
		var registry: Node = streamer.get_destruction_registry()
		if registry != null:
			registry.mark_destroyed(cell_id, local_idx)

	# Loot.
	var world_pos: Vector3 = Vector3(entry.get("world_pos", Vector3.ZERO))
	var res_type: String = String(entry.get("res_type", "Stone"))
	var planet_xform: Transform3D = (planet as Node3D).global_transform if planet is Node3D else Transform3D.IDENTITY
	SurfaceLootSpawner.drop(planet_xform * world_pos, res_type, get_tree())
	return HIT_RESULT_KILLED

# When MineableResource finishes its self-destruction (its _on_mined queues
# itself free), we mark the corresponding cell-local index as destroyed so
# the cell respawns it as gone.
func _on_mineral_exiting(local_idx: int) -> void:
	if local_idx < 0 or streamer == null:
		return
	var registry: Node = streamer.get_destruction_registry()
	if registry != null:
		registry.mark_destroyed(cell_id, local_idx)

# ─── HELPERS ──────────────────────────────────────────────────────────────────

func _calc_forest_aabb(points: Array) -> AABB:
	if points.is_empty(): return AABB()
	var min_v: Vector3 = (points[0] as Transform3D).origin
	var max_v: Vector3 = min_v
	for p in points:
		var o: Vector3 = (p as Transform3D).origin
		min_v = min_v.min(o)
		max_v = max_v.max(o)
	return AABB(min_v - Vector3(15, 15, 15), (max_v - min_v) + Vector3(30, 200, 30))

func _calc_aabb_padded(points: Array, pad_xy: float, pad_y_high: float) -> AABB:
	if points.is_empty(): return AABB()
	var min_v: Vector3 = (points[0] as Transform3D).origin
	var max_v: Vector3 = min_v
	for p in points:
		var o: Vector3 = (p as Transform3D).origin
		min_v = min_v.min(o)
		max_v = max_v.max(o)
	return AABB(min_v - Vector3(pad_xy, pad_xy, pad_xy), (max_v - min_v) + Vector3(pad_xy * 2.0, pad_y_high, pad_xy * 2.0))

# Streamer queries this when budgeting work.
func has_any_props() -> bool:
	if not is_built(): return false
	return not (_gen_data.get("trees", []).is_empty() and _gen_data.get("rocks", []).is_empty() and _gen_data.get("grass", []).is_empty() and _gen_data.get("minerals", []).is_empty())

# Surface-distance to a world point — used by streamer to decide T2 promotion.
func center_world() -> Vector3:
	if planet == null:
		return global_position
	var planet_radius: float = float(planet.get("planet_radius"))
	var local_center: Vector3 = SurfaceCellId.cell_center_local(
		SurfaceCellId.unpack(cell_id)["face"],
		SurfaceCellId.unpack(cell_id)["ix"],
		SurfaceCellId.unpack(cell_id)["iy"],
		planet_radius
	)
	return (planet as Node3D).global_transform * local_center

func _exit_tree() -> void:
	# If the cell is freed mid-build, drain the worker task so we don't
	# leak it.  WorkerThreadPool.wait_for_task_completion is safe even if
	# the task already finished.
	if _task_id != -1:
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1

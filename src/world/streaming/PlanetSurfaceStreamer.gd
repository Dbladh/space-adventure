extends Node3D

# PlanetSurfaceStreamer.gd
# Per-planet driver for cell-based surface streaming.  Replaces the per-chunk
# _process LOD loop and pooled SurfacePropProxy lifecycle.
#
# CRITICAL: This MUST extend Node3D (not Node) so its child SurfaceCells
# inherit the planet's global transform via the scene-tree.  When it extended
# Node, cells rendered at world origin instead of on the planet surface.
#
# Tick (10 Hz): compute the desired set of active cells around the player and
# their target tier (visual vs. interactive).  Diff against the current cell
# map to produce spawn/despawn/tier-change lists.
#
# Frame: drain the spawn/despawn queues with a fixed budget per frame so a
# warp dive or 50-cell traversal doesn't spike the main thread.

const SurfaceCellId = preload("res://src/world/streaming/SurfaceCellId.gd")
const SurfaceCell = preload("res://src/world/streaming/SurfaceCell.gd")
const PlanetDestructionRegistry = preload("res://src/world/streaming/PlanetDestructionRegistry.gd")

@export var enabled: bool = true
# Cells around the player that hold visual scatter.  3x3 = 9 cells (was 5x5 =
# 25, which produced too many concurrent MMIs — every cell needs 3-4 separate
# MultiMesh draw calls, so 25 cells × 4 ≈ 100 prop draw calls per planet).
@export var t1_radius_cells: int = 1
# World-distance cap for promotion to Tier-2 (interactive collision).
@export var t2_radius_m: float = 6000.0
@export var t2_hysteresis_m: float = 800.0
# Maximum altitude (above planet surface) at which the streamer keeps cells
# alive.  Beyond this, every cell streams out and the planet renders as
# unscattered terrain — props you can't make out from orbit shouldn't burn
# GPU draws.  Tuned so cells stay in place during normal low-altitude flight
# (well above the 6km Tier-2 cap) but stream out once you climb to orbit.
@export var max_stream_altitude_m: float = 30000.0
@export var max_stream_altitude_exit_m: float = 40000.0  # 10km hysteresis
@export var streamer_tick_hz: float = 10.0
@export var spawn_budget_per_frame: int = 2
@export var despawn_budget_per_frame: int = 4
# Burst multiplier triggered when the player crosses many cells in one tick
# (warp/dive).  Buys throughput at the cost of one-frame spike.
@export var warp_burst_multiplier: int = 4
@export var debug_draw_cells: bool = false

# Adaptive frame-time throttle.  Streaming work backs off when the engine is
# already busy (combat VFX, LootGem bursts, etc.) so spawning a new MMI never
# tips an already-heavy frame past its budget.  Measured against last frame's
# process time so the reaction lags by exactly 1 frame.
#
# Thresholds tuned for the project's typical ~30-40 fps baseline — 18 ms
# (target 60 fps) made the gate engage every single frame and the streamer
# never activated anything.  The new defaults trigger only on genuine
# spikes above the baseline.  Even when triggered, a safety hatch
# (`max_frames_between_activations`) forces at least one cell through
# every N frames so the streamer can't permanently stall.
@export var frame_time_budget_ms: float = 32.0      # soft: defer activations + new spawns
@export var frame_time_hard_limit_ms: float = 55.0  # hard: defer everything
# Safety hatch — if we've been deferring activations for this many frames
# in a row, force one through regardless of frame budget.  Guarantees
# cells eventually fill in even on chronically slow hardware.
@export var max_frames_between_activations: int = 90  # ~1.5 s at 60fps, ~3 s at 30fps
# Frustum-aware priority — cells the camera is looking at get promoted first.
# FOV margin > 1 inflates the priority cone so cells just off-screen are still
# warm when the player turns toward them.
@export var frustum_fov_deg: float = 60.0
@export var frustum_fov_margin: float = 1.4
@export var debug_log_throttles: bool = false

var planet: Node = null
var registry: Node = null

# Active cells: cell_id -> SurfaceCell node.
var _cells: Dictionary = {}
# Cells whose build_async() has been kicked off but who haven't been
# promoted yet.  Polled each frame.
var _pending_build: Array[SurfaceCell] = []
# Queued spawns / despawns for budgeted execution.
var _spawn_queue: Array[int] = []
var _despawn_queue: Array[SurfaceCell] = []

# Cached archetype meshes (built lazily on first use via a hidden helper chunk).
var _archetype_meshes: Dictionary = {}
var _mesh_helper: Node = null

# Reusable handle to the player.
var _player: Node3D = null
# Cached active camera — refreshed if the previous one is freed or replaced.
var _camera: Camera3D = null

# 10 Hz tick accumulator.
var _tick_accum: float = 0.0
# Track the player's last cell to detect warp jumps (>2 cell traversal in one tick).
var _last_player_cell: int = -1
# Altitude-gated stream toggle. False at high orbit, true at low-flight range.
var _stream_active: bool = false
# Frames since the last successful cell activation.  Drives the safety hatch
# that forces an activation through after a long throttled stretch.
var _frames_since_activation: int = 0
# Mirror of _frames_since_activation for the spawn-queue path.  Without this,
# a chronic frame-time overrun (e.g. running in-editor with debugger overhead
# on a desktop machine where frame_time_budget_ms=32ms is regularly exceeded)
# leaves the spawn queue locked forever and no scatter ever appears.
var _frames_since_spawn: int = 0

func _ready() -> void:
	# Find the parent planet.  PlanetGen instantiates this streamer as a child.
	var p: Node = get_parent()
	if p != null and p.is_in_group("Planet"):
		planet = p
	# Stand up the destruction registry as a sibling Node child of the planet
	# (or as a child of this streamer if planet is null).
	registry = PlanetDestructionRegistry.new()
	registry.name = "PlanetDestructionRegistry"
	add_child(registry)

	# Resolve the player.
	var found: Array = get_tree().get_nodes_in_group("Player")
	if not found.is_empty():
		_player = found[0]

	# Mobile: raise the throttle thresholds so the engine still defers under
	# real spikes but doesn't permanently stall. At a 25-30 fps baseline the
	# desktop default (32 ms soft) engages every frame and the streamer never
	# spawns props. Also shrink the activation window and altitude so we don't
	# waste budget on cells the player can't make out at low resolution.
	if MobilePerf.is_mobile():
		frame_time_budget_ms = 80.0
		frame_time_hard_limit_ms = 130.0
		max_frames_between_activations = 20
		spawn_budget_per_frame = 1
		max_stream_altitude_m = 15000.0
		max_stream_altitude_exit_m = 20000.0
	else:
		# Desktop: extend the loaded cell window so scatter doesn't pop in
		# at the 1-cell-radius edge (~7 km).  5x5 = 25 cells gives ~12 km
		# of visible scatter before the boundary — well past the visible
		# horizon at low altitude.  Mobile keeps 3x3 (9 cells) for draw-call
		# budget.  Each cell adds ~3-4 MMI draws, so 25 cells ≈ 100 — fine
		# on desktop GPUs.
		t1_radius_cells = 2
		spawn_budget_per_frame = 3  # drain the larger window faster
		if OS.has_feature("editor"):
			# In-editor on desktop: debugger + MCP overhead push frame time
			# past the 32 ms soft limit, locking the spawn queue the way the
			# mobile path used to.  Standalone desktop builds keep the tight
			# thresholds — they don't need this.
			frame_time_budget_ms = 60.0
			frame_time_hard_limit_ms = 110.0
			max_frames_between_activations = 20

	set_process(true)

func get_destruction_registry() -> Node:
	return registry

# Mesh + material accessors used by SurfaceCell when building MMIs.
# Lazy-built via a hidden PlanetChunk helper since the existing mesh
# generators are instance methods that key off self.archetype.
func get_archetype_meshes() -> Dictionary:
	if _archetype_meshes.is_empty():
		_build_archetype_meshes()
	return _archetype_meshes

func get_foliage_material() -> Material:
	if planet != null and "foliage_material" in planet:
		var m = planet.get("foliage_material")
		if m != null: return m
	return null

func get_trunk_material() -> Material:
	if planet != null and "trunk_material" in planet:
		var m = planet.get("trunk_material")
		if m != null: return m
	return null

func get_rock_material() -> Material:
	if planet != null and "rock_material" in planet:
		var m = planet.get("rock_material")
		if m != null: return m
	# PlanetChunk's static _get_rock_mat() falls back when the planet
	# hasn't initialized rock_material yet.
	var pc_script: GDScript = load("res://src/world/PlanetChunk.gd") as GDScript
	if pc_script != null and pc_script.has_method("_get_rock_mat"):
		return pc_script.call("_get_rock_mat")
	return null

func get_grass_material() -> Material:
	if planet != null and "grass_material" in planet:
		var m = planet.get("grass_material")
		if m != null: return m
	return null

func _build_archetype_meshes() -> void:
	if planet == null:
		return
	var archetype: String = "LUSH"
	if "archetype" in planet:
		archetype = String(planet.get("archetype"))
	# Spin up a hidden helper chunk so the existing instance-method mesh
	# builders (which key off self.archetype) can populate the static caches.
	if _mesh_helper == null:
		var pc_script: GDScript = load("res://src/world/PlanetChunk.gd") as GDScript
		if pc_script == null:
			return
		_mesh_helper = pc_script.new()
		_mesh_helper.archetype = archetype
		# Skip setup() since we don't render, but provide a planet ref so
		# any helpers that read planet config don't crash.
		_mesh_helper.planet = planet
		_mesh_helper.face = null
		_mesh_helper.face_normal = Vector3.UP
		_mesh_helper.x_axis = Vector3.RIGHT
		_mesh_helper.y_axis = Vector3.FORWARD
		_mesh_helper.scale_factor = 0.0001
		_mesh_helper.hide()
		add_child(_mesh_helper)

	# Populate static archetype caches (read by the dictionary access below).
	# These have to run on the main thread because they call SurfaceTool which
	# is not thread-safe.
	var fol_h_dict: Dictionary = _mesh_helper.get("_c_fol_h_by_arch")
	var fol_l_dict: Dictionary = _mesh_helper.get("_c_fol_l_by_arch")
	var trk_h_dict: Dictionary = _mesh_helper.get("_c_trk_h_by_arch")
	var trk_l_dict: Dictionary = _mesh_helper.get("_c_trk_l_by_arch")

	if not fol_h_dict.has(archetype):
		fol_h_dict[archetype] = _mesh_helper._build_varied_foliage(true, 4)
	if not fol_l_dict.has(archetype):
		fol_l_dict[archetype] = _mesh_helper._build_varied_foliage(false, 2)
	if not trk_h_dict.has(archetype):
		trk_h_dict[archetype] = _mesh_helper._build_botw_trunk(true)
	if not trk_l_dict.has(archetype):
		trk_l_dict[archetype] = _mesh_helper._build_botw_trunk(false)

	var rock_mesh: ArrayMesh = _mesh_helper._build_faceted_rock_mesh(12)
	var grass_mesh: ArrayMesh = _mesh_helper._build_grass_mesh()

	_archetype_meshes = {
		"fol_h": fol_h_dict.get(archetype, null),
		"fol_l": fol_l_dict.get(archetype, null),
		"trk_h": trk_h_dict.get(archetype, null),
		"trk_l": trk_l_dict.get(archetype, null),
		"rock": rock_mesh,
		"grass": grass_mesh,
	}

# ─── MAIN LOOP ────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not enabled or planet == null:
		return

	# Resolve player lazily; the planet might be ready before the ship.
	if _player == null or not is_instance_valid(_player):
		var found: Array = get_tree().get_nodes_in_group("Player")
		if found.is_empty():
			return
		_player = found[0]

	# 10 Hz tick — diff active cell set.
	_tick_accum += delta
	var tick_period: float = 1.0 / max(streamer_tick_hz, 0.1)
	if _tick_accum >= tick_period:
		_tick_accum = 0.0
		_run_tick()

	# Per-frame: poll pending builds, drain spawn/despawn queues.
	_drain_pending_builds()
	_drain_spawn_queue()
	_drain_despawn_queue()

func _run_tick() -> void:
	var player_world: Vector3 = _player.global_position

	# Altitude gate: if the player is high above the planet surface, all
	# cells stream out.  Without this the streamer keeps a 3x3 cell window
	# alive while in deep orbit — props you can't see eating GPU draws.
	# Hysteresis avoids thrashing at the boundary.
	var planet_radius: float = float(planet.get("planet_radius"))
	var altitude: float = (planet as Node3D).global_position.distance_to(player_world) - planet_radius
	if _stream_active:
		if altitude > max_stream_altitude_exit_m:
			_stream_active = false
	else:
		if altitude < max_stream_altitude_m:
			_stream_active = true

	# Compute desired cell set.
	var desired: PackedInt64Array
	if _stream_active:
		desired = SurfaceCellId.cells_around_player(planet, player_world, t1_radius_cells)
	else:
		desired = PackedInt64Array()

	# Detect warp/dive: large change in player's projected cell since last tick.
	var burst: bool = false
	if not desired.is_empty():
		@warning_ignore("integer_division")
		var center_cell: int = desired[desired.size() / 2]
		if _last_player_cell != -1 and _last_player_cell != center_cell:
			# Crude crossing test — if the cell ids differ at all, the player
			# moved to a new center; if they differ a lot we burst.
			# Without an ix/iy delta computation here, treat any change >1 as
			# a warp candidate via the cell-center distance.
			var prev: Dictionary = SurfaceCellId.unpack(_last_player_cell)
			var curr: Dictionary = SurfaceCellId.unpack(center_cell)
			if prev["face"] != curr["face"]:
				burst = true
			else:
				var dx: int = abs(int(curr["ix"]) - int(prev["ix"]))
				var dy: int = abs(int(curr["iy"]) - int(prev["iy"]))
				if dx + dy > 2:
					burst = true
		_last_player_cell = center_cell

	# Build a fast lookup of desired cells.
	var desired_set: Dictionary = {}
	for cid in desired:
		desired_set[cid] = true

	# Despawn cells no longer desired.
	for cid in _cells.keys():
		if not desired_set.has(cid):
			var cell: SurfaceCell = _cells[cid]
			if not _despawn_queue.has(cell):
				_despawn_queue.append(cell)

	# Spawn missing cells, and refresh tier targets for everyone in the set.
	for cid in desired:
		if not _cells.has(cid):
			if not _spawn_queue.has(cid):
				_spawn_queue.append(cid)
			continue
		# Existing cell: set its tier target now.
		var cell: SurfaceCell = _cells[cid]
		_apply_target_tier(cell, player_world)

	# Burst budget for this frame.
	if burst:
		_drain_spawn_queue(spawn_budget_per_frame * warp_burst_multiplier)
		_drain_despawn_queue(despawn_budget_per_frame * warp_burst_multiplier)

func _apply_target_tier(cell: SurfaceCell, player_world: Vector3) -> void:
	if not cell.is_built():
		return
	var center: Vector3 = cell.center_world()
	var d: float = center.distance_to(player_world)
	var current: int = cell.current_tier()
	var target: int = SurfaceCell.TIER_VIS
	# Hysteresis: enter Tier-2 closer than t2_radius_m, leave it past t2 + hyst.
	if current == SurfaceCell.TIER_FULL:
		if d > t2_radius_m + t2_hysteresis_m:
			target = SurfaceCell.TIER_VIS
		else:
			target = SurfaceCell.TIER_FULL
	else:
		if d <= t2_radius_m:
			target = SurfaceCell.TIER_FULL
		else:
			target = SurfaceCell.TIER_VIS
	cell.activate_tier(target)

# ─── ADAPTIVE THROTTLE HELPERS ────────────────────────────────────────────────

# Last frame's process time in ms.  Performance.TIME_PROCESS is in seconds.
# Returns 0.0 on the very first frame before Godot has a measurement —
# callers should treat 0 as "no data, normal budget".
func _frame_time_ms() -> float:
	return float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0

# Throttle state.
#  0 = normal budget (all work proceeds)
#  1 = soft throttle (defer activations + new spawns, keep despawns + tier-2)
#  2 = hard throttle (defer everything, including despawns)
func _throttle_state() -> int:
	var ms: float = _frame_time_ms()
	if ms <= 0.0:
		return 0  # no measurement yet
	if ms > frame_time_hard_limit_ms:
		return 2
	if ms > frame_time_budget_ms:
		return 1
	return 0

# Active 3D camera, cached.  Refreshes lazily if the previous reference is
# invalid (camera replaced or scene reloaded).
func _get_camera() -> Camera3D:
	if _camera != null and is_instance_valid(_camera):
		return _camera
	_camera = get_viewport().get_camera_3d()
	return _camera

# Score a cell for activation priority: 1.0 = directly in front of the camera,
# -1.0 = directly behind.  Cells with score above cos(half_fov * margin) are
# "in view"; the rest are deprioritized.
func _score_cell_for_activation(cell: SurfaceCell) -> float:
	var cam: Camera3D = _get_camera()
	if cam == null or not is_instance_valid(cell):
		return 0.0
	var forward: Vector3 = -cam.global_transform.basis.z
	var to_cell: Vector3 = cell.center_world() - cam.global_position
	var dist_sq: float = to_cell.length_squared()
	if dist_sq < 1.0:
		return 1.0
	return to_cell.normalized().dot(forward)

# True if a cell's center sits inside the inflated FOV cone (margin applied).
func _cell_in_priority_cone(cell: SurfaceCell) -> bool:
	var half_fov_rad: float = deg_to_rad(frustum_fov_deg) * frustum_fov_margin
	var threshold: float = cos(half_fov_rad)
	return _score_cell_for_activation(cell) > threshold

# ─── QUEUE DRAINS ─────────────────────────────────────────────────────────────

func _drain_pending_builds() -> void:
	# Cap how many cells promote to TIER_VIS per frame.  Spread promotions
	# across frames so each cell's stages naturally offset from its
	# neighbours' — combined with the per-cell staged build, this means at
	# most one new prop-type spawn per frame across the entire planet.
	const ACTIVATIONS_PER_FRAME: int = 1
	_frames_since_activation += 1

	# Adaptive throttle: yield streaming work when the engine is already busy.
	# Soft throttle pauses new activations (and spawns, drained separately).
	# Hard throttle pauses absolutely everything.  Despawns still run under
	# the soft threshold because they release resources.
	#
	# Safety hatch: if we've been throttled long enough that the player
	# would notice cells aren't filling in, force one through regardless of
	# frame budget.  Without this, hardware that runs chronically over
	# `frame_time_budget_ms` (e.g. low-end laptop at 25 fps) would never
	# spawn anything.
	var throttle: int = _throttle_state()
	var force_through: bool = _frames_since_activation >= max_frames_between_activations
	if throttle >= 1 and not force_through:
		if debug_log_throttles:
			print("[streamer] pending-build skip: frame %.1fms (deferred %d frames)" % [_frame_time_ms(), _frames_since_activation])
		return

	# Frustum priority — sort pending cells so the ones the player can see
	# are activated first.  poll_build status is independent of view, so we
	# may still be waiting on the in-view cell's worker task; in that case
	# the next-best (out-of-view but ready) cell still gets its turn.
	var ready_in_view: Array[SurfaceCell] = []
	var ready_out_of_view: Array[SurfaceCell] = []
	var not_ready: Array[SurfaceCell] = []
	for cell in _pending_build:
		if not is_instance_valid(cell):
			continue
		if not cell.poll_build():
			not_ready.append(cell)
		elif _cell_in_priority_cone(cell):
			ready_in_view.append(cell)
		else:
			ready_out_of_view.append(cell)

	var activated: int = 0
	var still_pending: Array[SurfaceCell] = []

	# Pass 1: activate cells in view, up to budget.
	for cell in ready_in_view:
		if activated < ACTIVATIONS_PER_FRAME:
			cell.activate_tier(SurfaceCell.TIER_VIS)
			activated += 1
			_frames_since_activation = 0
		else:
			still_pending.append(cell)
	# Pass 2: activate cells out of view, only if budget remains.
	for cell in ready_out_of_view:
		if activated < ACTIVATIONS_PER_FRAME:
			cell.activate_tier(SurfaceCell.TIER_VIS)
			activated += 1
			_frames_since_activation = 0
		else:
			still_pending.append(cell)
	# Pass 3: keep cells whose worker task hasn't finished yet.
	for cell in not_ready:
		still_pending.append(cell)
	_pending_build = still_pending

func _drain_spawn_queue(budget_override: int = -1) -> void:
	_frames_since_spawn += 1
	# Adaptive throttle: don't kick off NEW background tasks (which will
	# eventually need main-thread activation) when the engine is already busy.
	# Safety hatch: if we've been throttled long enough that the player would
	# notice nothing is filling in, force ONE cell through regardless of frame
	# budget.  Otherwise hardware (or in-editor debug overhead) that runs
	# chronically over frame_time_budget_ms leaves the queue locked forever.
	var force_through: bool = _frames_since_spawn >= max_frames_between_activations
	if _throttle_state() >= 1 and not force_through:
		if debug_log_throttles:
			print("[streamer] spawn-queue skip: frame %.1fms" % _frame_time_ms())
		return
	var budget: int = budget_override if budget_override > 0 else spawn_budget_per_frame
	if force_through:
		# Trickle a single cell through during chronic throttle.
		budget = max(budget, 1)
	while budget > 0 and not _spawn_queue.is_empty():
		var cid: int = _spawn_queue.pop_front()
		if _cells.has(cid):
			continue
		var cell := SurfaceCell.new()
		cell.name = "SurfaceCell_%d" % cid
		cell.setup(planet, cid, self)
		add_child(cell)
		_cells[cid] = cell
		cell.build_async()
		_pending_build.append(cell)
		budget -= 1
		_frames_since_spawn = 0
		if force_through:
			break  # Only force ONE cell — don't blow the budget further.

func _drain_despawn_queue(budget_override: int = -1) -> void:
	# Despawns release resources — only paused by the HARD throttle.  Under
	# soft throttle they still run, which can actually help frame-time
	# recovery (freeing node-tree entries, dropping MMI memory).
	if _throttle_state() >= 2:
		return
	var budget: int = budget_override if budget_override > 0 else despawn_budget_per_frame
	while budget > 0 and not _despawn_queue.is_empty():
		var cell: SurfaceCell = _despawn_queue.pop_front()
		if cell == null or not is_instance_valid(cell):
			continue
		_cells.erase(cell.cell_id)
		# Remove from pending-build if still there.
		var idx: int = _pending_build.find(cell)
		if idx >= 0:
			_pending_build.remove_at(idx)
		cell.deactivate()
		cell.queue_free()
		budget -= 1

# ─── PUBLIC PROBES ────────────────────────────────────────────────────────────

func active_cell_count() -> int:
	return _cells.size()

func pending_build_count() -> int:
	return _pending_build.size()

func _exit_tree() -> void:
	for cell in _cells.values():
		if is_instance_valid(cell):
			cell.deactivate()
	_cells.clear()
	_pending_build.clear()
	_spawn_queue.clear()
	_despawn_queue.clear()

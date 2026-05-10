# (c) On the Side LLC. and affiliates. Confidential and proprietary.
# THE GUNSMITH: High-fidelity loot fragments that explode from shattered minerals.
# Three-phase state machine — EXPLODING (arc) → LANDED (rest 1 s on surface) →
# HOMING (Ratchet & Clank-style magnetic flight to the ship).

extends Node3D

# Shared geometry: one ArrayMesh built on first instantiation, reused by every gem.
# Prevents the ~50× synchronous SurfaceTool.commit() freeze on bulk loot drops.
static var _shared_mesh: ArrayMesh = null

# Shared visual + audio caches.  Bulk mining can spawn 100-200 shards in a few
# frames; allocating a fresh material + audio stream per shard caused major
# frame drops (each new StandardMaterial3D triggers a shader pipeline compile
# for the unshaded+emission variant the first time it appears, and every
# load() of item_whoosh.wav hit disk anew).  Cache once, reuse for every
# shard of the same colour-key.
static var _shared_materials: Dictionary = {}      # color_key (int) -> StandardMaterial3D
static var _shared_whoosh: AudioStream = null
static var _cached_music_director: Node = null    # set on first collect

var target_player: Node3D = null
var velocity: Vector3 = Vector3.ZERO
var state: String = "EXPLODING"
var timer: float = 0.0
var land_timer: float = 0.0
var value: int = 250
var resource_type: String = "Copper"
var col: Color = Color.WHITE
# Surface-landing context: passed in by MineableResource at spawn so each shard
# knows its planet and the radius (planet center → mineral root) to settle at.
var planet: Node3D = null
var surface_dist: float = 0.0
var spin_axis: Vector3 = Vector3.UP
var spin_speed: float = 4.0

# Whoosh effect during homing
var _whoosh_player: AudioStreamPlayer3D = null
var _has_played_whoosh: bool = false

func _ready() -> void:
	if _shared_mesh == null:
		_shared_mesh = _build_shared_mesh()
	var mi = MeshInstance3D.new()
	mi.mesh = _shared_mesh
	mi.material_override = _get_or_build_material(col)
	add_child(mi)

	# Audio player is deferred — most shards never get close enough to play
	# their whoosh, so allocating an AudioStreamPlayer3D up-front is wasted.
	# Built on demand in the HOMING state once dist < whoosh range.

	# EXPLOSION VELOCITY: random direction biased upward (away from planet
	# centre) so shards arc dramatically above the mineral before falling back
	# to the surface.  Increased velocity from 220-420 to 380-680 so the burst
	# feels more violent and shards spread wider across the surface.
	var up_dir: Vector3
	if planet:
		up_dir = (global_position - planet.global_position).normalized()
	else:
		up_dir = Vector3.UP
	var random_dir = Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-0.2, 0.6),
		randf_range(-1.0, 1.0)
	).normalized()
	# 0.8 up bias (increased from 0.7) keeps the burst arc visually consistent
	# and more upward; the random component spreads shards outward.
	var explode_dir = (up_dir * 0.8 + random_dir * 0.8).normalized()
	velocity = explode_dir * randf_range(380.0, 680.0)
	spin_axis = Vector3(randf(), randf(), randf()).normalized()
	spin_speed = randf_range(3.0, 7.0)

static func _build_shared_mesh() -> ArrayMesh:
	# ACE GEOMETRY: Mini-Rupee (Emerald cut). Vertex colors omitted so per-gem
	# tint is driven entirely by the material's albedo/emission.
	# Increased size (16.0 vs 8.0) so shards feel more substantial and are
	# easier to visually track as they arc and home.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := 16.0
	var v_top := Vector3(0, size, 0)
	var v_bot := Vector3(0, -size, 0)
	var v_mid := [Vector3(size, 0, 0), Vector3(0, 0, size), Vector3(-size, 0, 0), Vector3(0, 0, -size)]
	for i in range(4):
		var m1: Vector3 = v_mid[i]
		var m2: Vector3 = v_mid[(i + 1) % 4]
		var n_up := (m1 - v_top).cross(m2 - v_top).normalized()
		st.set_normal(n_up); st.add_vertex(v_top)
		st.set_normal(n_up); st.add_vertex(m1)
		st.set_normal(n_up); st.add_vertex(m2)
		var n_down := (m2 - v_bot).cross(m1 - v_bot).normalized()
		st.set_normal(n_down); st.add_vertex(v_bot)
		st.set_normal(n_down); st.add_vertex(m2)
		st.set_normal(n_down); st.add_vertex(m1)
	return st.commit()

# Material cache — one per unique colour-key.  Shards within a single mining
# burst all share the same colour, so this cache typically holds 1-3 entries
# per session and dodges the per-shard pipeline compile cost.
static func _get_or_build_material(gem_col: Color) -> StandardMaterial3D:
	# Quantise the colour to a 8-bit-per-channel key so near-identical colours
	# share the same material.  Saves dictionary churn when the burst uses
	# subtly randomized tints.
	var key: int = (int(gem_col.r * 255.0) << 16) | (int(gem_col.g * 255.0) << 8) | int(gem_col.b * 255.0)
	if _shared_materials.has(key):
		return _shared_materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = gem_col
	mat.emission_enabled = true
	mat.emission = gem_col
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shared_materials[key] = mat
	return mat

# Build the whoosh AudioStreamPlayer3D the first time a shard actually gets
# close enough to play it.  Most shards never enter whoosh range (collected
# while still arcing or homing in fast), so deferring the allocation saves
# 10-20 audio-player nodes per mining burst.
func _ensure_whoosh_player() -> void:
	if _whoosh_player != null:
		return
	if _shared_whoosh == null:
		_shared_whoosh = load("res://assets/resources/audio/item_whoosh.wav")
	_whoosh_player = AudioStreamPlayer3D.new()
	_whoosh_player.bus = "Master"
	_whoosh_player.stream = _shared_whoosh
	_whoosh_player.volume_db = -18.0
	_whoosh_player.max_distance = 3000.0
	_whoosh_player.unit_size = 1200.0
	_whoosh_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_whoosh_player.pitch_scale = randf_range(0.4, 0.95)
	add_child(_whoosh_player)

func _process(delta: float) -> void:
	timer += delta
	match state:
		"EXPLODING":
			global_position += velocity * delta
			# Apply gravity toward planet centre (or generic -Y if loose in space).
			if planet:
				var grav_dir = (planet.global_position - global_position).normalized()
				velocity += grav_dir * 320.0 * delta
			else:
				velocity.y -= 80.0 * delta

			# SURFACE-CONTACT TEST: shard's distance from the planet centre is
			# now equal to (or below) the mineral's anchor distance, meaning
			# we've fallen back through the surface plane.  Snap to the
			# surface, kill velocity, transition to LANDED.
			if planet and surface_dist > 0.0:
				var dist_now = global_position.distance_to(planet.global_position)
				if dist_now <= surface_dist + 6.0:
					var up = (global_position - planet.global_position).normalized()
					global_position = planet.global_position + up * (surface_dist + 6.0)
					velocity = Vector3.ZERO
					state = "LANDED"
					land_timer = 0.0

			# Hard timeout: if we never find a surface (loose-in-space mineral
			# or weird geometry), start homing after 1.5 s so we don't strand
			# the gem flying off forever.
			if state == "EXPLODING" and timer > 1.5:
				state = "HOMING"

			rotate(spin_axis, delta * spin_speed)

		"LANDED":
			# 1 s settle on the surface — the brief hover gives the player
			# visual feedback of WHERE the mineral was before the magnetic
			# pull whisks the shards into the ship.
			land_timer += delta
			rotate(spin_axis, delta * (spin_speed * 0.4))
			if land_timer >= 1.0:
				state = "HOMING"

		"HOMING":
			if not target_player:
				var p = get_tree().get_nodes_in_group("Player")
				if p.size() > 0: target_player = p[0]
				else: return

			var dir = (target_player.global_position - global_position).normalized()
			var dist = global_position.distance_to(target_player.global_position)

			# GUARANTEED CATCH-UP: Shards match player speed + distance scaling
			# so they never get left behind by a boosting Starhawk.
			var p_vel: float = target_player.velocity.length() if target_player.get("velocity") != null else 0.0
			var speed: float = p_vel + 2000.0 + (dist * 4.0)
			
			var move_dist: float = speed * delta
			global_position += dir * move_dist

			rotate(spin_axis, delta * (spin_speed * 2.0))

			# Whoosh effect — lazy-build the audio player only when a shard
			# actually crosses the whoosh threshold.  Bulk drops where most
			# shards collect within a few frames never pay the per-shard
			# AudioStreamPlayer3D cost.
			if not _has_played_whoosh and dist < 1800.0:
				_ensure_whoosh_player()
				if _whoosh_player:
					_whoosh_player.play()
					_has_played_whoosh = true

			if dist < 120.0 or dist <= move_dist:
				_on_collected()

func _on_collected() -> void:
	# Stop whoosh effect
	if _whoosh_player and _whoosh_player.playing:
		_whoosh_player.stop()

	# Flash the ship white without shaking
	if target_player and target_player.has_method("_trigger_hit_flash"):
		target_player.call("_trigger_hit_flash", 0.7, Color.WHITE, false)

	# Play item collect sound — MusicDirector reference cached once across
	# the whole session so we don't re-walk the group tree per shard.
	if _cached_music_director == null or not is_instance_valid(_cached_music_director):
		var md_nodes = get_tree().get_nodes_in_group("MusicDirector")
		if md_nodes.size() > 0:
			_cached_music_director = md_nodes[0]
	if _cached_music_director and _cached_music_director.has_method("play_item_collect"):
		_cached_music_director.call("play_item_collect")

	# Add resource to inventory — player sells at station for credits
	if Engine.has_meta("InventoryManager"):
		Engine.get_meta("InventoryManager").add(resource_type, 1)
	queue_free()

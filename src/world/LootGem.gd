# (c) On the Side LLC. and affiliates. Confidential and proprietary.
# THE GUNSMITH: High-fidelity loot fragments that explode from shattered minerals.
# Three-phase state machine — EXPLODING (arc) → LANDED (rest 1 s on surface) →
# HOMING (Ratchet & Clank-style magnetic flight to the ship).

extends Node3D

# Shared geometry: one ArrayMesh built on first instantiation, reused by every gem.
# Prevents the ~50× synchronous SurfaceTool.commit() freeze on bulk loot drops.
static var _shared_mesh: ArrayMesh = null

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
	var mat = StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)



	# Setup whoosh effect (3D spatial audio)
	_whoosh_player = AudioStreamPlayer3D.new()
	_whoosh_player.bus = "Master"
	_whoosh_player.stream = load("res://assets/resources/audio/item_whoosh.wav")
	_whoosh_player.volume_db = -18.0 # Even quieter base volume
	_whoosh_player.max_distance = 3000.0
	_whoosh_player.unit_size = 1200.0 # Maintain spatial approach bubble
	_whoosh_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_whoosh_player.pitch_scale = randf_range(0.4, 0.95) # Global randf_range for distinct variation per shard
	add_child(_whoosh_player)

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

			# RATCHET & CLANK MAGNETIC PULL: speed inversely proportional to
			# distance — close shards rip toward the ship, distant ones drift
			# in.  Clamps prevent both glacial drift at long range and missile
			# overshoot at point-blank range.
			var speed = clamp(9000.0 / (dist + 10.0), 1800.0, 28000.0)
			global_position += dir * speed * delta

			rotate(spin_axis, delta * (spin_speed * 2.0))

			# Whoosh effect: play once when in range (1 second out) and let 3D spatial audio handle volume
			if _whoosh_player and not _has_played_whoosh and dist < 1800.0:
				_whoosh_player.play()
				_has_played_whoosh = true

			if dist < 80.0:
				_on_collected()

func _on_collected() -> void:
	# Stop whoosh effect
	if _whoosh_player and _whoosh_player.playing:
		_whoosh_player.stop()

	# Flash the ship white without shaking
	if target_player and target_player.has_method("_trigger_hit_flash"):
		target_player.call("_trigger_hit_flash", 0.7, Color.WHITE, false)

	# Play item collect sound
	var music_director = get_tree().get_nodes_in_group("MusicDirector")
	if music_director.size() > 0:
		music_director[0].call("play_item_collect")

	# Add resource to inventory
	if Engine.has_meta("InventoryManager"):
		Engine.get_meta("InventoryManager").add(resource_type, 1)
	# Also award credits until SpaceStation exists
	if Engine.has_meta("EconomyManager"):
		Engine.get_meta("EconomyManager").add_credits(value)
	queue_free()

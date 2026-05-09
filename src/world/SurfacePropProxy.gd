extends StaticBody3D

# SurfacePropProxy.gd
# Invisible collision body co-located with a MultiMesh surface prop (rock or tree).
# Lifecycle is now driven by PlanetChunk's per-instance LOD update — proxies are
# pulled from a chunk-local pool when a prop becomes visible to the ship and
# returned to the pool when the prop streams out. set_combat_active(true|false)
# toggles group membership and collision layer in lockstep so a target can never
# be locked-on if the laser bolt couldn't actually hit it.

const COMBAT_LAYER: int = 1 << 5  # Layer 6 — bolt + proxy raycasts in Player.gd

const GEM_VALUE: Dictionary = {
	"Stone": 15,
	"Wood":  25,
}
const GEM_COLOR: Dictionary = {
	"Stone": Color(0.55, 0.52, 0.48),
	"Wood":  Color(0.45, 0.28, 0.12),
}

# PERSISTENT DESTRUCTION REGISTRY: position-keyed dict of destroyed proxies so
# they don't reappear when the chunk reloads.
static var _destroyed_positions: Dictionary = {}

var resource_type: String = "Copper"
var _mmis: Array = []
var _instance_idx: int = -1
var _health: int = 2
var health: int = 2

func _ready() -> void:
	# Default state is INACTIVE: proxies are invisible to combat until the
	# owning chunk activates them via set_combat_active(true). Without this
	# default, every freshly-pooled proxy would appear in Targets/Mineable
	# groups for one frame before the chunk could disable it.
	collision_layer = 0
	collision_mask = 0

func setup(mmis: Array, idx: int, res_type: String) -> void:
	_mmis = mmis
	_instance_idx = idx
	resource_type = res_type
	_health = 2
	health = 2

func set_combat_active(active: bool) -> void:
	if active:
		collision_layer = COMBAT_LAYER
		if not is_in_group("Mineable"): add_to_group("Mineable")
		if not is_in_group("Targets"): add_to_group("Targets")
		if not is_in_group("Destructible"): add_to_group("Destructible")
	else:
		collision_layer = 0
		if is_in_group("Mineable"): remove_from_group("Mineable")
		if is_in_group("Targets"): remove_from_group("Targets")
		if is_in_group("Destructible"): remove_from_group("Destructible")

func take_damage(_amount: float) -> void:
	_health -= 1
	health = _health
	if _health <= 0:
		_on_destroyed()

func _on_destroyed() -> void:
	# Persistent registry: position hash matches the spawner's filter so the
	# prop stays gone across chunk reloads.
	_destroyed_positions[hash(global_position.round())] = true

	if _instance_idx >= 0:
		var zero := Transform3D().scaled(Vector3.ZERO)
		for mmi in _mmis:
			if is_instance_valid(mmi) and mmi.multimesh != null:
				mmi.multimesh.set_instance_transform(_instance_idx, zero)

	var nearest_planet: Node3D = null
	var min_dist: float = 1e16
	for p in get_tree().get_nodes_in_group("Planet"):
		var d: float = p.global_position.distance_to(global_position)
		if d < min_dist:
			min_dist = d
			nearest_planet = p

	var gem_script = load("res://src/world/LootGem.gd")
	if gem_script:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		var count: int = rng.randi_range(1, 2)
		var col: Color  = GEM_COLOR.get(resource_type, Color.WHITE)
		var val: int    = GEM_VALUE.get(resource_type, 30)
		for i in range(count):
			var gem := Node3D.new()
			gem.set_script(gem_script)
			gem.set("resource_type", resource_type)
			gem.set("value", val)
			gem.set("col", col)
			gem.set("planet", nearest_planet)
			gem.set("surface_dist", min_dist)
			get_tree().root.add_child(gem)
			gem.global_position = global_position + Vector3(0, 6.0, 0)

	# Disable combat before queue_free so any in-flight bolt's body_entered
	# doesn't fire a second hit on a destroyed proxy.
	set_combat_active(false)
	queue_free()

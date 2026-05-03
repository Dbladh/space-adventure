extends StaticBody3D

# SurfacePropProxy.gd
# Invisible collision body co-located with a MultiMesh surface prop (rock or tree).
# When shot by a LaserBolt, take_damage() reduces health; at 0 it zeroes the matching
# MultiMesh instance (making the prop vanish) and spawns LootGems.
#
# Lifecycle: added as a child of PlanetChunk. When the chunk sleeps/resets,
# PlanetGen's death_row system frees the proxy automatically — no manual cleanup needed.

const GEM_VALUE: Dictionary = {
	"Stone": 15,
	"Wood":  25,
}
const GEM_COLOR: Dictionary = {
	"Stone": Color(0.55, 0.52, 0.48),   # grey
	"Wood":  Color(0.45, 0.28, 0.12),   # brown
}

var resource_type: String = "Copper"
var _mmis: Array = []          # MultiMeshInstance3D references
var _instance_idx: int = -1
var _health: int = 2

func _ready() -> void:
	add_to_group("Mineable")
	add_to_group("Targets")
	add_to_group("Destructible")

func setup(mmis: Array, idx: int, res_type: String) -> void:
	_mmis = mmis
	_instance_idx = idx
	resource_type = res_type

func take_damage(_amount: float) -> void:
	_health -= 1
	if _health <= 0:
		_on_destroyed()

func _on_destroyed() -> void:
	# Remove the visual prop by zeroing its MultiMesh transform
	if _instance_idx >= 0:
		var zero := Transform3D().scaled(Vector3.ZERO)
		for mmi in _mmis:
			if is_instance_valid(mmi) and mmi.multimesh != null:
				mmi.multimesh.set_instance_transform(_instance_idx, zero)

	# Find the nearest planet so gems know which way is "down"
	var nearest_planet: Node3D = null
	var min_dist: float = 1e16
	for p in get_tree().get_nodes_in_group("Planet"):
		var d: float = p.global_position.distance_to(global_position)
		if d < min_dist:
			min_dist = d
			nearest_planet = p

	# Spawn 1–2 loot gems
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

	queue_free()

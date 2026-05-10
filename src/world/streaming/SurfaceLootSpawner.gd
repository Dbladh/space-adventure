extends RefCounted

# SurfaceLootSpawner.gd
# Drop loot gems when a streamed prop is destroyed.  Carved from
# SurfacePropProxy._on_destroyed so the same drop logic can run from a
# SurfaceCell's per-shape damage handler without standing up a proxy.

const _GEM_VALUE: Dictionary = {
	"Stone": 15,
	"Wood":  25,
}
const _GEM_COLOR: Dictionary = {
	"Stone": Color(0.55, 0.52, 0.48),
	"Wood":  Color(0.45, 0.28, 0.12),
}

# Spawns 1-2 gems at `world_position` for the given resource type.  Picks the
# nearest planet (group "Planet") so the gem can settle correctly on terrain.
static func drop(world_position: Vector3, resource_type: String, scene_tree: SceneTree) -> void:
	if scene_tree == null:
		return
	var gem_script: Resource = load("res://src/world/LootGem.gd")
	if gem_script == null:
		return

	var nearest_planet: Node3D = null
	var min_dist: float = 1e16
	for p in scene_tree.get_nodes_in_group("Planet"):
		var d: float = (p as Node3D).global_position.distance_to(world_position)
		if d < min_dist:
			min_dist = d
			nearest_planet = p

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var count: int = rng.randi_range(1, 2)
	var col: Color = _GEM_COLOR.get(resource_type, Color.WHITE)
	var val: int = _GEM_VALUE.get(resource_type, 30)

	for i in range(count):
		var gem := Node3D.new()
		gem.set_script(gem_script)
		gem.set("resource_type", resource_type)
		gem.set("value", val)
		gem.set("col", col)
		gem.set("planet", nearest_planet)
		gem.set("surface_dist", min_dist)
		scene_tree.root.add_child(gem)
		gem.global_position = world_position + Vector3(0, 6.0, 0)

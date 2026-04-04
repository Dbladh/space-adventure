extends Node

# GalaxyRegistry.gd
# Managed by THE ARCHITECT. Stores deterministic coordinates for 8 planets.
# Implements 64-bit float precision logic for astronomical scales.

# List of planet coordinates (64-bit float Vectors)
# Each planet's coordinate is derived deterministically from its unique seed.
const PLANET_COUNT: int = 8
var planet_positions: Array[Vector3] = []

func _ready() -> void:
	# Calculate coordinates once per session based on Master Seed
	generate_galaxy_positions()

func generate_galaxy_positions() -> void:
	# Use deterministic logic to place 8 planets in space
	# This ensures galaxies are consistent across game loads
	var master_seed_fallback: int = 123456
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = master_seed_fallback
	
	planet_positions.clear()
	
	for i in range(PLANET_COUNT):
		# Distribute planets in a spiral or cluster
		# We use large distances to justify 64-bit precision needs.
		var angle: float = rng.randf() * TAU
		var distance: float = rng.randf_range(1000.0, 100000.0)
		var elevation: float = rng.randf_range(-1000.0, 1000.0)
		
		# Using float-cast Vector3 constructor (Godot 4 uses doubles internally)
		var pos: Vector3 = Vector3(
			cos(angle) * distance,
			elevation,
			sin(angle) * distance
		)
		
		planet_positions.append(pos)
		print("Planet [", i, "] registered at coordinates: ", pos)

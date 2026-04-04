extends Node

# GlobalSeed.gd
# This is an Autoload script managed by THE ARCHITECT.
# It stores the master 64-bit integer seed for the entire universe.

# Project Octo-Loot's master 64-bit seed (Example starting value).
# This is a large 64-bit integer that will seed all generation calls.
var master_seed: int = 1234567890123456789:
	set(value):
		master_seed = value
		# Seed the engine to ensure built-in rand functions are deterministic.
		seed(master_seed)

## ARCHITECT: Master Seed Unpacking logic
## This logic derives smaller, deterministic sub-seeds from the master 64-bit integer.
func get_planet_seed(planet_index: int) -> int:
	# Extract a 16-bit segment from the master seed per planet (8 planets total)
	# Shift master seed right by 8 bits * index, then mask with a 16-bit range.
	var shift_bits: int = (planet_index * 8) % 64
	var sub_segment: int = (master_seed >> shift_bits) & 0xFFFF
	return hash(str(master_seed) + "_planet_" + str(sub_segment))

func _ready() -> void:
	# Initializing the engine seed based on the master 64-bit integer
	seed(master_seed)
	print("--- Project Octo-Loot: Master Seed Initialized ---")
	print("Master Seed: ", master_seed)

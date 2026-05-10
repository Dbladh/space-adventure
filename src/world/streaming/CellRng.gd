extends RefCounted

# CellRng.gd
# Deterministic per-cell, per-phase RNG seeding so trees, rocks, grass, and
# minerals each get an independent reproducible stream from (planet_seed, cell_id).

const PHASE_TREES:    int = 0
const PHASE_ROCKS:    int = 1
const PHASE_GRASS:    int = 2
const PHASE_MINERALS: int = 3
const PHASE_VARIANT:  int = 4  # generic per-instance variation (color, scale jitter)

# Mix the seed integers into a 64-bit hash. Cheap multiplicative+xor mixer
# tuned to avoid 64-bit unsigned constants (GDScript ints are signed 64-bit
# so anything >= 2^63 fails to parse).  Determinism is the only requirement.
static func _mix(a: int, b: int, c: int) -> int:
	var x: int = a * 2654435761
	x = (x ^ (b * 1597334677)) * 374761393
	x = (x ^ (x >> 16))
	x = (x ^ (c * 2246822519)) * 3266489917
	return x ^ (x >> 16)

static func for_cell_phase(planet_seed: int, cell_id: int, phase: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = _mix(planet_seed, cell_id, phase)
	return rng

static func cell_seed(planet_seed: int, cell_id: int, phase: int) -> int:
	return _mix(planet_seed, cell_id, phase)

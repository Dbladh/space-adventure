extends Node

# PlanetDestructionRegistry.gd
# Per-planet, in-memory record of destroyed surface props.  Keyed by integer
# cell_id and a small per-cell ordinal index (the order in which the cell's
# generator emitted that prop).  Replaces the old global static dicts in
# SurfacePropProxy/MineableResource which used float-position hashing and
# never released memory.
#
# Persistence scope: lifetime of the planet node.  When the player leaves the
# system or restarts the game the registry goes with it.  This matches the
# "within session only" requirement.

# cell_id -> PackedInt32Array of destroyed local indices (sorted ascending)
var _by_cell: Dictionary = {}

func mark_destroyed(cell_id: int, local_idx: int) -> void:
	var arr: PackedInt32Array = _by_cell.get(cell_id, PackedInt32Array())
	# Maintain sorted-unique invariant so is_destroyed can binary-search.
	var lo: int = 0
	var hi: int = arr.size()
	while lo < hi:
		var mid: int = (lo + hi) >> 1
		if arr[mid] < local_idx: lo = mid + 1
		else: hi = mid
	if lo < arr.size() and arr[lo] == local_idx:
		return  # already recorded
	arr.insert(lo, local_idx)
	_by_cell[cell_id] = arr

func is_destroyed(cell_id: int, local_idx: int) -> bool:
	var arr: PackedInt32Array = _by_cell.get(cell_id, PackedInt32Array())
	if arr.is_empty():
		return false
	# Linear scan is fine for the tiny per-cell arrays (typically <50 props,
	# few destroyed); binary search would buy nothing but obscure the code.
	for v in arr:
		if v == local_idx:
			return true
		if v > local_idx:
			return false
	return false

func get_destroyed_for_cell(cell_id: int) -> PackedInt32Array:
	return _by_cell.get(cell_id, PackedInt32Array())

func cell_has_any(cell_id: int) -> bool:
	var arr: PackedInt32Array = _by_cell.get(cell_id, PackedInt32Array())
	return not arr.is_empty()

func clear_all() -> void:
	_by_cell.clear()

func cell_count() -> int:
	return _by_cell.size()

func total_destroyed() -> int:
	var n: int = 0
	for arr in _by_cell.values():
		n += arr.size()
	return n

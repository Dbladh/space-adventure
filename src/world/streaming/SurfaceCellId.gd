extends RefCounted

# SurfaceCellId.gd
# Cell-id packing/unpacking and cube-face math for the surface streamer.
# A planet is overlaid with a 6-face cube grid, each face divided into
# CELLS_PER_FACE x CELLS_PER_FACE cells. cell_id = packed (face, ix, iy).

const CELL_GRID_VERSION: int = 1
const CELLS_PER_FACE: int = 32

# Bit layout: 3 bits face (0..5) | 14 bits iy | 14 bits ix.
const _FACE_BITS: int = 3
const _AXIS_BITS: int = 14
const _AXIS_MASK: int = (1 << _AXIS_BITS) - 1
const _FACE_MASK: int = (1 << _FACE_BITS) - 1

# Mirror of PlanetGen.FACE_NORMALS — duplicated so streaming code never
# has to load PlanetGen at parse time.
const FACE_NORMALS: Array[Vector3] = [
	Vector3.FORWARD, Vector3.BACK,
	Vector3.LEFT, Vector3.RIGHT,
	Vector3.UP, Vector3.DOWN
]

static func pack(face_idx: int, ix: int, iy: int) -> int:
	return (face_idx & _FACE_MASK) | ((ix & _AXIS_MASK) << _FACE_BITS) | ((iy & _AXIS_MASK) << (_FACE_BITS + _AXIS_BITS))

static func unpack(cell_id: int) -> Dictionary:
	return {
		"face": cell_id & _FACE_MASK,
		"ix":   (cell_id >> _FACE_BITS) & _AXIS_MASK,
		"iy":   (cell_id >> (_FACE_BITS + _AXIS_BITS)) & _AXIS_MASK,
	}

# Returns the parametric (u, v) of a cell center in [-1, 1] face-local space.
static func cell_center_uv(ix: int, iy: int) -> Vector2:
	var step: float = 2.0 / float(CELLS_PER_FACE)
	return Vector2(-1.0 + (float(ix) + 0.5) * step, -1.0 + (float(iy) + 0.5) * step)

# Half-extent of one cell in face-local parametric units (cell spans 2*half wide).
static func cell_half_extent() -> float:
	return 1.0 / float(CELLS_PER_FACE)

# Mirror of QuadTreeFace _init: pick orthonormal axes for a given face normal.
static func face_axes(normal: Vector3) -> Array:
	var x_axis: Vector3
	if abs(normal.y) > 0.999:
		x_axis = Vector3.RIGHT
	else:
		x_axis = Vector3.UP.cross(normal).normalized()
	var y_axis: Vector3 = normal.cross(x_axis).normalized()
	return [x_axis, y_axis]

# Cell-center surface point in planet-local coordinates (sphere surface, no
# terrain elevation factored in — terrain is added per-prop downstream).
static func cell_center_local(face_idx: int, ix: int, iy: int, planet_radius: float) -> Vector3:
	var normal: Vector3 = FACE_NORMALS[face_idx]
	var axes := face_axes(normal)
	var uv := cell_center_uv(ix, iy)
	var face_pos: Vector3 = normal + uv.x * axes[0] + uv.y * axes[1]
	return face_pos.normalized() * planet_radius

# Returns the unit-sphere surface normal at a parametric (face, u, v).
static func face_uv_to_normal(face_idx: int, u: float, v: float) -> Vector3:
	var normal: Vector3 = FACE_NORMALS[face_idx]
	var axes := face_axes(normal)
	return (normal + u * axes[0] + v * axes[1]).normalized()

# Project a planet-local direction onto the dominant cube face and return
# {face, u, v} — picks the face whose normal has the largest dot product
# with `dir_local` (axis-aligned closest face).
static func project_dir_to_face(dir_local: Vector3) -> Dictionary:
	var d: Vector3 = dir_local.normalized()
	var best_face: int = 0
	var best_dot: float = -1.0
	for i in range(FACE_NORMALS.size()):
		var dot: float = d.dot(FACE_NORMALS[i])
		if dot > best_dot:
			best_dot = dot
			best_face = i
	# Reproject onto that face's plane: scale d so its component along the
	# face normal equals 1, then read off the (x_axis, y_axis) coordinates.
	var n: Vector3 = FACE_NORMALS[best_face]
	var axes := face_axes(n)
	# d_proj = d * (1 / d.dot(n)) lands on the face plane (normal-component = 1)
	var nd: float = d.dot(n)
	if nd <= 1e-6:
		# Should not happen because best_dot picked the dominant face, but
		# guard against numerical edge cases (player exactly on an edge).
		nd = 1e-6
	var d_proj: Vector3 = d / nd
	return {
		"face": best_face,
		"u": d_proj.dot(axes[0]),
		"v": d_proj.dot(axes[1]),
	}

# Convert a parametric (u, v) on a face into integer cell coords. Clamps to
# the face's valid grid; out-of-range values get clamped to the edge cell.
static func uv_to_cell_index(u: float, v: float) -> Vector2i:
	var step: float = 2.0 / float(CELLS_PER_FACE)
	var ix: int = clamp(int(floor((u + 1.0) / step)), 0, CELLS_PER_FACE - 1)
	var iy: int = clamp(int(floor((v + 1.0) / step)), 0, CELLS_PER_FACE - 1)
	return Vector2i(ix, iy)

# Returns the set of cell_ids within `window_radius` cells of the player's
# projected position on the dominant face. Adjacent faces are NOT included
# right now — a near-edge player gets the inner subset clipped to one face.
# Cube-edge crossings will be handled in a follow-up; for the initial
# streamer they're rare and only cost a temporary cell-ring on one side.
static func cells_around_player(planet: Node, player_world_pos: Vector3, window_radius: int) -> PackedInt64Array:
	var out: PackedInt64Array = PackedInt64Array()
	if planet == null:
		return out
	var local: Vector3 = planet.to_local(player_world_pos)
	if local.length_squared() < 1e-3:
		return out
	var hit := project_dir_to_face(local)
	var face_idx: int = hit["face"]
	var center := uv_to_cell_index(float(hit["u"]), float(hit["v"]))
	var ix0: int = center.x
	var iy0: int = center.y
	var max_idx: int = CELLS_PER_FACE - 1
	for dy in range(-window_radius, window_radius + 1):
		for dx in range(-window_radius, window_radius + 1):
			var ix: int = ix0 + dx
			var iy: int = iy0 + dy
			if ix < 0 or ix > max_idx or iy < 0 or iy > max_idx:
				continue
			out.append(pack(face_idx, ix, iy))
	return out

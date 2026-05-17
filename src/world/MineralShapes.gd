class_name MineralShapes

# MineralShapes.gd — procedural shape catalog for every mineable resource.
# One ArrayMesh per resource type, all cached after first build. Every mesh
# encodes the resource's hue in vertex colors so the shared per-tier material
# can read them via vertex_color_use_as_albedo.
#
# Unit size convention: meshes are built around 1.0 units; the parent
# MineableResource scales them up to the actual world size.

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

const UNIT: float = 1.0
const _SHARDED_RNG_SEED: int = 0x5EED

# -------------------------------------------------------------------
#  PUBLIC: dispatch a resource name to its builder.
# -------------------------------------------------------------------
static func build(type: String) -> ArrayMesh:
	var col := ResourceRegistry.get_color(type)
	match type:
		# Tier 1 — Grey
		"Stone":          return _build_rock_cluster(col, 3, 1.2)
		"Wood":           return _build_log(col)
		"Neon Moss":      return _build_moss_rock(col)
		"Silica Dust":    return _build_pyramid_pile(col)
		"Carbon Fiber":   return _build_plate_stack(col)
		"Organic Sludge": return _build_squashed_blob(col)
		# Tier 2 — Green
		"Verdant Spore":  return _build_mushroom_cluster(col)
		"Chloro Crystal": return _build_tall_hex_crystal(col)
		"Bloomstone":     return _build_gem_studded_stone(col)
		# Tier 3 — Blue
		"Copper":         return _build_nugget_cluster(col, 3, 1.0)
		"Azure Sap":      return _build_teardrop(col)
		"Basalt Glass":   return _build_angular_shard(col)
		"Silver":         return _build_ingot(col)
		"Living Resin":   return _build_glow_orb(col)
		# Tier 4 — Purple
		"Gold":           return _build_nugget_cluster(col, 4, 1.4)
		"Platinum":       return _build_faceted_gem(col)
		"Primal Fruit":   return _build_spiked_sphere(col)
		"Aether Crystal": return _build_crystal_stack(col)
		# Tier 5 — Orange (premium)
		"Prismatic Alloy": return _build_rhombic_cube(col)
		"Nebula Core":    return _build_torus_swirl(col)
		_:
			# Fallback for unknown / legacy names — keep the old octahedron look.
			return _build_octahedron(col)

# -------------------------------------------------------------------
#  PRIMITIVE HELPERS
# -------------------------------------------------------------------
static func _add_box(st: SurfaceTool, col: Color, center: Vector3, half: Vector3) -> void:
	var p: Array[Vector3] = [
		center + Vector3(-half.x, -half.y, -half.z),
		center + Vector3( half.x, -half.y, -half.z),
		center + Vector3( half.x, -half.y,  half.z),
		center + Vector3(-half.x, -half.y,  half.z),
		center + Vector3(-half.x,  half.y, -half.z),
		center + Vector3( half.x,  half.y, -half.z),
		center + Vector3( half.x,  half.y,  half.z),
		center + Vector3(-half.x,  half.y,  half.z),
	]
	# 6 faces, normals from cross-product.
	var faces := [
		[0, 1, 2, 3, Vector3.DOWN],
		[5, 4, 7, 6, Vector3.UP],
		[1, 0, 4, 5, Vector3.FORWARD],
		[3, 2, 6, 7, Vector3.BACK],
		[0, 3, 7, 4, Vector3.LEFT],
		[2, 1, 5, 6, Vector3.RIGHT],
	]
	for f in faces:
		var a: Vector3 = p[f[0]]; var b: Vector3 = p[f[1]]; var c: Vector3 = p[f[2]]; var d: Vector3 = p[f[3]]
		var n: Vector3 = f[4]
		_tri(st, col, n, a, b, c)
		_tri(st, col, n, a, c, d)

static func _add_cone(st: SurfaceTool, col: Color, base_center: Vector3, height: float, radius: float, sides: int) -> void:
	var apex := base_center + Vector3(0, height, 0)
	for i in range(sides):
		var a1: float = float(i) / float(sides) * TAU
		var a2: float = float(i + 1) / float(sides) * TAU
		var v1: Vector3 = base_center + Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		var v2: Vector3 = base_center + Vector3(cos(a2) * radius, 0, sin(a2) * radius)
		var n: Vector3 = ((v2 - apex).cross(v1 - apex)).normalized()
		_tri(st, col, n, apex, v1, v2)

static func _add_hex_prism(st: SurfaceTool, col: Color, base_center: Vector3, height: float, radius_base: float, radius_top: float) -> void:
	# 6-sided prism with optional taper. Top closed as hex fan, bottom open
	# (gem sits in the ground / on the host rock).
	var apex_top := base_center + Vector3(0, height, 0)
	var sides := 6
	for i in range(sides):
		var a1: float = float(i) / float(sides) * TAU
		var a2: float = float(i + 1) / float(sides) * TAU
		var b1: Vector3 = base_center + Vector3(cos(a1) * radius_base, 0, sin(a1) * radius_base)
		var b2: Vector3 = base_center + Vector3(cos(a2) * radius_base, 0, sin(a2) * radius_base)
		var t1: Vector3 = apex_top + Vector3(cos(a1) * radius_top, 0, sin(a1) * radius_top)
		var t2: Vector3 = apex_top + Vector3(cos(a2) * radius_top, 0, sin(a2) * radius_top)
		var n: Vector3 = ((b2 - b1).cross(t1 - b1)).normalized()
		_tri(st, col, n, b1, b2, t1)
		_tri(st, col, n, b2, t2, t1)
	# Cap at top so the gem reads as solid from above.
	if radius_top > 0.01:
		for i in range(sides):
			var a1: float = float(i) / float(sides) * TAU
			var a2: float = float(i + 1) / float(sides) * TAU
			var t1: Vector3 = apex_top + Vector3(cos(a1) * radius_top, 0, sin(a1) * radius_top)
			var t2: Vector3 = apex_top + Vector3(cos(a2) * radius_top, 0, sin(a2) * radius_top)
			_tri(st, col, Vector3.UP, apex_top, t1, t2)

static func _add_icosphere(st: SurfaceTool, col: Color, center: Vector3, radius: float, lat: int = 6, lon: int = 8) -> void:
	# UV-style sphere — adequate for low-poly look, single mesh.
	for i in range(lat):
		var v1: float = float(i) / float(lat) * PI
		var v2: float = float(i + 1) / float(lat) * PI
		var r1: float = sin(v1) * radius
		var r2: float = sin(v2) * radius
		var y1: float = cos(v1) * radius
		var y2: float = cos(v2) * radius
		for j in range(lon):
			var u1: float = float(j) / float(lon) * TAU
			var u2: float = float(j + 1) / float(lon) * TAU
			var p1: Vector3 = center + Vector3(cos(u1) * r1, y1, sin(u1) * r1)
			var p2: Vector3 = center + Vector3(cos(u2) * r1, y1, sin(u2) * r1)
			var p3: Vector3 = center + Vector3(cos(u2) * r2, y2, sin(u2) * r2)
			var p4: Vector3 = center + Vector3(cos(u1) * r2, y2, sin(u1) * r2)
			var n1: Vector3 = (p1 - center).normalized()
			var n2: Vector3 = (p2 - center).normalized()
			var n3: Vector3 = (p3 - center).normalized()
			var n4: Vector3 = (p4 - center).normalized()
			_tri_n(st, col, n1, p1, n2, p2, n3, p3)
			_tri_n(st, col, n1, p1, n3, p3, n4, p4)

static func _add_cylinder(st: SurfaceTool, col: Color, base_center: Vector3, height: float, radius: float, sides: int = 8) -> void:
	for i in range(sides):
		var a1: float = float(i) / float(sides) * TAU
		var a2: float = float(i + 1) / float(sides) * TAU
		var b1: Vector3 = base_center + Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		var b2: Vector3 = base_center + Vector3(cos(a2) * radius, 0, sin(a2) * radius)
		var t1: Vector3 = b1 + Vector3(0, height, 0)
		var t2: Vector3 = b2 + Vector3(0, height, 0)
		var n1: Vector3 = (b1 - base_center).normalized()
		var n2: Vector3 = (b2 - base_center).normalized()
		_tri_n(st, col, n1, b1, n2, b2, n1, t1)
		_tri_n(st, col, n2, b2, n2, t2, n1, t1)
	# Top + bottom caps
	for i in range(sides):
		var a1: float = float(i) / float(sides) * TAU
		var a2: float = float(i + 1) / float(sides) * TAU
		var t1: Vector3 = base_center + Vector3(cos(a1) * radius, height, sin(a1) * radius)
		var t2: Vector3 = base_center + Vector3(cos(a2) * radius, height, sin(a2) * radius)
		_tri(st, col, Vector3.UP, base_center + Vector3(0, height, 0), t1, t2)
		var b1: Vector3 = base_center + Vector3(cos(a1) * radius, 0, sin(a1) * radius)
		var b2: Vector3 = base_center + Vector3(cos(a2) * radius, 0, sin(a2) * radius)
		_tri(st, col, Vector3.DOWN, base_center, b2, b1)

static func _tri(st: SurfaceTool, col: Color, n: Vector3, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_normal(n); st.set_color(col); st.add_vertex(a)
	st.set_normal(n); st.set_color(col); st.add_vertex(b)
	st.set_normal(n); st.set_color(col); st.add_vertex(c)

static func _tri_n(st: SurfaceTool, col: Color, na: Vector3, a: Vector3, nb: Vector3, b: Vector3, nc: Vector3, c: Vector3) -> void:
	# Per-vertex normals for smooth-shaded primitives.
	st.set_normal(na); st.set_color(col); st.add_vertex(a)
	st.set_normal(nb); st.set_color(col); st.add_vertex(b)
	st.set_normal(nc); st.set_color(col); st.add_vertex(c)

# -------------------------------------------------------------------
#  SHAPE BUILDERS
# -------------------------------------------------------------------

# Fallback / legacy
static func _build_octahedron(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := UNIT
	var v_top := Vector3(0, s * 5.0, 0)
	var v_bot := Vector3(0, 0, 0)
	var v_mid := [
		Vector3(s, s * 2.5, 0),
		Vector3(0, s * 2.5, s),
		Vector3(-s, s * 2.5, 0),
		Vector3(0, s * 2.5, -s),
	]
	for i in range(4):
		var m1: Vector3 = v_mid[i]
		var m2: Vector3 = v_mid[(i + 1) % 4]
		var n_up: Vector3 = (m1 - v_top).cross(m2 - v_top).normalized()
		_tri(st, col, n_up, v_top, m1, m2)
		var n_down: Vector3 = (m2 - v_bot).cross(m1 - v_bot).normalized()
		_tri(st, col, n_down, v_bot, m2, m1)
	return st.commit()

# Stone: cluster of jittered boxes for a rocky-pile feel.
static func _build_rock_cluster(col: Color, count: int, scale: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = _SHARDED_RNG_SEED + count
	for i in range(count):
		var pos := Vector3(rng.randf_range(-0.5, 0.5) * scale, rng.randf_range(0.0, 0.6) * scale, rng.randf_range(-0.5, 0.5) * scale)
		var half := Vector3(rng.randf_range(0.4, 0.7), rng.randf_range(0.4, 0.7), rng.randf_range(0.4, 0.7))
		_add_box(st, col, pos + Vector3(0, half.y, 0), half)
	return st.commit()

# Wood: tapered upright trunk with a flat capped top (so you don't see inside
# the cylinder when looking down at it).
static func _build_log(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sides := 7
	var s := UNIT
	var top_center := Vector3(0, s * 5.0, 0)
	for i in range(sides):
		var a1: float = float(i) / float(sides) * TAU
		var a2: float = float(i + 1) / float(sides) * TAU
		var b1: Vector3 = Vector3(cos(a1) * s, 0, sin(a1) * s)
		var b2: Vector3 = Vector3(cos(a2) * s, 0, sin(a2) * s)
		var t1: Vector3 = Vector3(cos(a1) * s * 0.75, s * 5.0, sin(a1) * s * 0.75)
		var t2: Vector3 = Vector3(cos(a2) * s * 0.75, s * 5.0, sin(a2) * s * 0.75)
		var n1: Vector3 = Vector3(cos(a1), 0.1, sin(a1)).normalized()
		var n2: Vector3 = Vector3(cos(a2), 0.1, sin(a2)).normalized()
		_tri_n(st, col, n1, b1, n2, b2, n1, t1)
		_tri_n(st, col, n2, b2, n2, t2, n1, t1)
		# Top cap fan — slight inset darken so the cut surface reads as wood grain.
		_tri(st, col.darkened(0.18), Vector3.UP, top_center, t1, t2)
		# Bottom cap so the trunk reads as solid when viewed from below as well.
		_tri(st, col.darkened(0.28), Vector3.DOWN, Vector3.ZERO, b2, b1)
	return st.commit()

# Neon Moss: low rock base + 3 thin upright "spore stalks" for the glowy bits.
static func _build_moss_rock(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Squat rock base.
	_add_box(st, col.darkened(0.4), Vector3(0, 0.4, 0), Vector3(0.9, 0.4, 0.9))
	# 3 glowy stalks on top.
	var positions: Array[Vector3] = [Vector3(-0.4, 0.8, -0.2), Vector3(0.3, 0.8, 0.4), Vector3(0.0, 0.8, -0.4)]
	for p in positions:
		_add_box(st, col, p + Vector3(0, 1.0, 0), Vector3(0.15, 1.0, 0.15))
	return st.commit()

# Silica Dust: low square pyramid (sand pile).
static func _build_pyramid_pile(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var s := UNIT
	var apex := Vector3(0, s * 2.0, 0)
	var corners: Array[Vector3] = [
		Vector3(-s, 0, -s), Vector3(s, 0, -s), Vector3(s, 0, s), Vector3(-s, 0, s),
	]
	for i in range(4):
		var c1: Vector3 = corners[i]
		var c2: Vector3 = corners[(i + 1) % 4]
		var n: Vector3 = ((c2 - apex).cross(c1 - apex)).normalized()
		_tri(st, col, n, apex, c1, c2)
	# Base square so it's solid from below.
	_tri(st, col, Vector3.DOWN, corners[0], corners[2], corners[1])
	_tri(st, col, Vector3.DOWN, corners[0], corners[3], corners[2])
	return st.commit()

# Carbon Fiber: stacked flat plates (a slab of woven material).
static func _build_plate_stack(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(4):
		var y := 0.2 + float(i) * 0.4
		_add_box(st, col, Vector3(0, y, 0), Vector3(0.9 - float(i) * 0.1, 0.15, 0.9 - float(i) * 0.1))
	return st.commit()

# Organic Sludge: squashed sphere, low and dome-like.
static func _build_squashed_blob(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Half-sphere flattened (hemisphere).
	var radius := 1.2
	var lat := 4
	var lon := 8
	for i in range(lat):
		var v1: float = float(i) / float(lat) * (PI * 0.5)  # only top half
		var v2: float = float(i + 1) / float(lat) * (PI * 0.5)
		var r1: float = sin(v1) * radius
		var r2: float = sin(v2) * radius
		var y1: float = cos(v1) * radius * 0.5  # squash factor
		var y2: float = cos(v2) * radius * 0.5
		for j in range(lon):
			var u1: float = float(j) / float(lon) * TAU
			var u2: float = float(j + 1) / float(lon) * TAU
			var p1: Vector3 = Vector3(cos(u1) * r1, y1, sin(u1) * r1)
			var p2: Vector3 = Vector3(cos(u2) * r1, y1, sin(u2) * r1)
			var p3: Vector3 = Vector3(cos(u2) * r2, y2, sin(u2) * r2)
			var p4: Vector3 = Vector3(cos(u1) * r2, y2, sin(u1) * r2)
			var n: Vector3 = ((p2 - p1).cross(p4 - p1)).normalized()
			_tri(st, col, n, p1, p2, p3)
			_tri(st, col, n, p1, p3, p4)
	return st.commit()

# Verdant Spore: cluster of small mushroom shapes (stem + cap).
static func _build_mushroom_cluster(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var positions: Array[Vector3] = [
		Vector3(0.0, 0.0, 0.0),
		Vector3(-0.5, 0.0, 0.3),
		Vector3(0.5, 0.0, -0.2),
	]
	var heights: Array[float] = [1.4, 0.9, 1.1]
	for i in range(positions.size()):
		var p: Vector3 = positions[i]
		var h: float = heights[i]
		# Stem (thin cylinder)
		_add_cylinder(st, col.lightened(0.2), p, h, 0.13, 6)
		# Cap (squashed sphere on top)
		_add_icosphere(st, col, p + Vector3(0, h + 0.15, 0), 0.38, 4, 7)
	return st.commit()

# Chloro Crystal: single tall hexagonal prism with sharp taper to a point.
static func _build_tall_hex_crystal(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Tapered hex prism
	_add_hex_prism(st, col.darkened(0.1), Vector3.ZERO, 3.5, 0.7, 0.4)
	# Pointed cap above
	_add_cone(st, col, Vector3(0, 3.5, 0), 0.8, 0.4, 6)
	return st.commit()

# Bloomstone: rounded green-tinted rock studded with bigger gem chunks so the
# silhouette reads as "green ore", not "dark grey terrain rock".
static func _build_gem_studded_stone(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Rock base — keep the hue, only mildly darkened so it stays recognisably green.
	var rock := col.darkened(0.25)
	_add_icosphere(st, rock, Vector3(0, 0.8, 0), 1.1, 4, 7)
	# Embedded gem chunks — larger than the original 0.18 chips so they read at
	# planet-surface distance. Lightened tint makes the gems pop on the body.
	var gem_col := col.lightened(0.15)
	var gem_pos: Array[Vector3] = [
		Vector3(0.7, 1.2, 0.4),
		Vector3(-0.5, 1.0, 0.8),
		Vector3(0.0, 1.7, -0.5),
		Vector3(-0.7, 1.1, -0.4),
		Vector3(0.5, 1.5, -0.2),
	]
	for p in gem_pos:
		_add_box(st, gem_col, p, Vector3(0.30, 0.30, 0.30))
	return st.commit()

# Copper-style: irregular nugget cluster (jittered spheres).
static func _build_nugget_cluster(col: Color, count: int, scale: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = _SHARDED_RNG_SEED + count * 7
	for i in range(count):
		var p: Vector3 = Vector3(rng.randf_range(-0.5, 0.5) * scale, rng.randf_range(0.3, 0.7) * scale, rng.randf_range(-0.5, 0.5) * scale)
		var r: float = rng.randf_range(0.4, 0.65) * scale
		_add_icosphere(st, col, p, r, 4, 7)
	return st.commit()

# Azure Sap: teardrop — sphere stretched upward into a tapered point.
static func _build_teardrop(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(0, 1.0, 0)
	var radius := 0.8
	var lat := 6; var lon := 8
	for i in range(lat):
		var v1: float = float(i) / float(lat) * PI
		var v2: float = float(i + 1) / float(lat) * PI
		# Taper top: small radii at top get pulled into a long point.
		var taper1: float = 1.0 + smoothstep(0.5, 0.0, v1 / PI) * 1.6
		var taper2: float = 1.0 + smoothstep(0.5, 0.0, v2 / PI) * 1.6
		var r1: float = sin(v1) * radius
		var r2: float = sin(v2) * radius
		var y1: float = cos(v1) * radius * taper1
		var y2: float = cos(v2) * radius * taper2
		for j in range(lon):
			var u1: float = float(j) / float(lon) * TAU
			var u2: float = float(j + 1) / float(lon) * TAU
			var p1: Vector3 = center + Vector3(cos(u1) * r1, y1, sin(u1) * r1)
			var p2: Vector3 = center + Vector3(cos(u2) * r1, y1, sin(u2) * r1)
			var p3: Vector3 = center + Vector3(cos(u2) * r2, y2, sin(u2) * r2)
			var p4: Vector3 = center + Vector3(cos(u1) * r2, y2, sin(u1) * r2)
			var n: Vector3 = ((p2 - p1).cross(p4 - p1)).normalized()
			_tri(st, col, n, p1, p2, p3)
			_tri(st, col, n, p1, p3, p4)
	return st.commit()

# Basalt Glass: angular shard — irregular wedge with sharp facets.
static func _build_angular_shard(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Hand-crafted vertices for a jagged shard.
	var verts: Array[Vector3] = [
		Vector3(-0.6, 0.0, -0.4),     # 0 base
		Vector3(0.7, 0.0, -0.2),       # 1 base
		Vector3(0.4, 0.0, 0.6),        # 2 base
		Vector3(-0.5, 0.0, 0.5),       # 3 base
		Vector3(-0.1, 2.4, 0.2),       # 4 apex
		Vector3(0.3, 1.6, -0.3),       # 5 mid-front
		Vector3(-0.3, 1.4, 0.4),       # 6 mid-back
	]
	var tris: Array = [
		[0, 1, 5], [0, 5, 4], [0, 4, 6], [0, 6, 3],
		[3, 6, 2], [6, 4, 2], [4, 5, 2], [2, 5, 1],
		[0, 3, 2], [0, 2, 1],  # base
	]
	for tri in tris:
		var a: Vector3 = verts[tri[0]]; var b: Vector3 = verts[tri[1]]; var c: Vector3 = verts[tri[2]]
		var n: Vector3 = ((b - a).cross(c - a)).normalized()
		_tri(st, col, n, a, b, c)
	return st.commit()

# Silver: ingot — flat rectangular brick with tapered top.
static func _build_ingot(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var b: Array[Vector3] = [Vector3(-1.0, 0.0, -0.5), Vector3(1.0, 0.0, -0.5), Vector3(1.0, 0.0, 0.5), Vector3(-1.0, 0.0, 0.5)]
	var t: Array[Vector3] = [Vector3(-0.75, 0.6, -0.35), Vector3(0.75, 0.6, -0.35), Vector3(0.75, 0.6, 0.35), Vector3(-0.75, 0.6, 0.35)]
	for i in range(4):
		var j := (i + 1) % 4
		var n: Vector3 = ((b[j] - b[i]).cross(t[i] - b[i])).normalized()
		_tri(st, col, n, b[i], b[j], t[i])
		_tri(st, col, n, b[j], t[j], t[i])
	_tri(st, col, Vector3.UP, t[0], t[2], t[1])
	_tri(st, col, Vector3.UP, t[0], t[3], t[2])
	_tri(st, col, Vector3.DOWN, b[0], b[1], b[2])
	_tri(st, col, Vector3.DOWN, b[0], b[2], b[3])
	return st.commit()

# Living Resin: spherical orb (glow comes from the shader emission).
static func _build_glow_orb(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_icosphere(st, col, Vector3(0, 1.0, 0), 1.0, 6, 9)
	return st.commit()

# Platinum: faceted gem — diamond cut with multiple facets.
static func _build_faceted_gem(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Octahedron with extra equator facets for a brilliant-cut look.
	var apex_top := Vector3(0, 2.2, 0)
	var apex_bot := Vector3(0, 0.4, 0)
	var girdle: Array[Vector3] = []
	var sides := 8
	for i in range(sides):
		var a: float = float(i) / float(sides) * TAU
		girdle.append(Vector3(cos(a) * 0.9, 1.3, sin(a) * 0.9))
	for i in range(sides):
		var g1: Vector3 = girdle[i]
		var g2: Vector3 = girdle[(i + 1) % sides]
		var nt: Vector3 = ((g1 - apex_top).cross(g2 - apex_top)).normalized()
		_tri(st, col, nt, apex_top, g1, g2)
		var nb: Vector3 = ((g2 - apex_bot).cross(g1 - apex_bot)).normalized()
		_tri(st, col, nb, apex_bot, g2, g1)
	return st.commit()

# Primal Fruit: sphere covered in small spikes (cones).
static func _build_spiked_sphere(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var center := Vector3(0, 1.0, 0)
	_add_icosphere(st, col, center, 0.9, 5, 8)
	# Spikes — radiating cones at fixed lat/long positions.
	var lat_count := 4; var lon_count := 6
	for i in range(1, lat_count):
		var phi: float = float(i) / float(lat_count) * PI
		var r: float = sin(phi) * 0.9
		var y: float = cos(phi) * 0.9
		for j in range(lon_count):
			var theta: float = float(j) / float(lon_count) * TAU + (float(i) * 0.3)
			var base: Vector3 = center + Vector3(cos(theta) * r, y, sin(theta) * r)
			var dir: Vector3 = (base - center).normalized()
			# Cone with apex extending outward along dir.
			var apex: Vector3 = base + dir * 0.35
			# 3-sided cone for low poly.
			var basis: Basis = Basis.looking_at(dir, Vector3.UP if abs(dir.y) < 0.95 else Vector3.FORWARD)
			for k in range(3):
				var a1: float = float(k) / 3.0 * TAU
				var a2: float = float(k + 1) / 3.0 * TAU
				var v1: Vector3 = base + basis * Vector3(cos(a1) * 0.08, 0, sin(a1) * 0.08)
				var v2: Vector3 = base + basis * Vector3(cos(a2) * 0.08, 0, sin(a2) * 0.08)
				var n: Vector3 = ((v2 - apex).cross(v1 - apex)).normalized()
				_tri(st, col, n, apex, v1, v2)
	return st.commit()

# Aether Crystal: vertical stack of hex prisms at different heights — a
# crystalline cluster reaching skyward.
static func _build_crystal_stack(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Main central tall crystal
	_add_hex_prism(st, col, Vector3(0, 0, 0), 3.0, 0.55, 0.25)
	_add_cone(st, col, Vector3(0, 3.0, 0), 0.7, 0.25, 6)
	# Side crystals (shorter)
	_add_hex_prism(st, col.lightened(0.1), Vector3(0.6, 0, 0.3), 2.0, 0.35, 0.15)
	_add_cone(st, col.lightened(0.1), Vector3(0.6, 2.0, 0.3), 0.5, 0.15, 6)
	_add_hex_prism(st, col.darkened(0.1), Vector3(-0.5, 0, 0.4), 1.6, 0.3, 0.12)
	_add_cone(st, col.darkened(0.1), Vector3(-0.5, 1.6, 0.4), 0.4, 0.12, 6)
	_add_hex_prism(st, col.lightened(0.05), Vector3(-0.3, 0, -0.6), 1.4, 0.28, 0.1)
	_add_cone(st, col.lightened(0.05), Vector3(-0.3, 1.4, -0.6), 0.35, 0.1, 6)
	return st.commit()

# Prismatic Alloy: rhombic cube — cube rotated to stand on a corner.
static func _build_rhombic_cube(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Cube with diagonal vertical axis.
	var s := 0.85
	# Vertices of a cube rotated 45° around X then Z.
	var verts: Array[Vector3] = [
		Vector3(0, 0, 0),                    # 0 bottom
		Vector3(s, s, 0),                    # 1 right
		Vector3(0, s, s),                    # 2 front
		Vector3(-s, s, 0),                   # 3 left
		Vector3(0, s, -s),                   # 4 back
		Vector3(0, s * 2.0, 0),              # 5 top
	]
	# 8 triangular faces forming an octahedron-like rhombic shape.
	var tris: Array = [
		[0, 2, 1], [0, 3, 2], [0, 4, 3], [0, 1, 4],   # bottom 4
		[5, 1, 2], [5, 2, 3], [5, 3, 4], [5, 4, 1],   # top 4
	]
	for tri in tris:
		var a: Vector3 = verts[tri[0]]; var b: Vector3 = verts[tri[1]]; var c: Vector3 = verts[tri[2]]
		var n: Vector3 = ((b - a).cross(c - a)).normalized()
		_tri(st, col, n, a, b, c)
	return st.commit()

# Nebula Core: small core sphere with a surrounding torus — atomic-feel.
static func _build_torus_swirl(col: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Core
	_add_icosphere(st, col.lightened(0.2), Vector3(0, 1.0, 0), 0.55, 5, 8)
	# Torus (ring of segments)
	var major := 1.0
	var minor := 0.15
	var seg_u := 12  # around major
	var seg_v := 6   # around tube
	for i in range(seg_u):
		var a1: float = float(i) / float(seg_u) * TAU
		var a2: float = float(i + 1) / float(seg_u) * TAU
		for j in range(seg_v):
			var b1: float = float(j) / float(seg_v) * TAU
			var b2: float = float(j + 1) / float(seg_v) * TAU
			var p1: Vector3 = _torus_point(a1, b1, major, minor, 1.0)
			var p2: Vector3 = _torus_point(a2, b1, major, minor, 1.0)
			var p3: Vector3 = _torus_point(a2, b2, major, minor, 1.0)
			var p4: Vector3 = _torus_point(a1, b2, major, minor, 1.0)
			var n1: Vector3 = _torus_normal(a1, b1)
			var n2: Vector3 = _torus_normal(a2, b1)
			var n3: Vector3 = _torus_normal(a2, b2)
			var n4: Vector3 = _torus_normal(a1, b2)
			_tri_n(st, col, n1, p1, n2, p2, n3, p3)
			_tri_n(st, col, n1, p1, n3, p3, n4, p4)
	return st.commit()

static func _torus_point(u: float, v: float, major: float, minor: float, y_offset: float) -> Vector3:
	var r: float = major + minor * cos(v)
	return Vector3(cos(u) * r, y_offset + minor * sin(v), sin(u) * r)

static func _torus_normal(u: float, v: float) -> Vector3:
	return Vector3(cos(u) * cos(v), sin(v), sin(u) * cos(v)).normalized()

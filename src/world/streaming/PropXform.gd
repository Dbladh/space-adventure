extends RefCounted

# PropXform.gd
# Static helpers for converting (surface position, surface normal, noise, scale)
# into the per-instance Transform3D used by trees, rocks, grass, and minerals.
# Carved out of PlanetChunk._get_object_xform/_get_rock_xform/_get_grass_xform
# so legacy chunk code and the new streaming generator emit byte-identical
# transforms during the migration.

# Trees, mineral deposits, mineable trees/grass.
static func object_xform(pos: Vector3, up: Vector3, noise_val: float, b_scale: float) -> Transform3D:
	var t_bas := Basis()
	t_bas.y = up
	t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1:
		t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	var xf := Transform3D(t_bas, pos)
	var sv: float = 1.0 + (abs(noise_val) * 7.0)
	return xf.scaled_local(Vector3(b_scale, b_scale * sv, b_scale))

# Rocks: heavily skewed scale distribution — lots of small pebbles, some
# medium boulders, only the rare monolith.  The pow(r_rand, 5.0) curve
# pushes the median rock to ~0.5x base (small), with the top 1% reaching
# ~3x (the visual monoliths the user wants kept rare).
#
# Reference table (r_rand uniform [0,1] -> s_mult):
#   r_rand=0.30 (30th %ile): s_mult ≈ 0.21  (tiny pebble)
#   r_rand=0.50 (median):    s_mult ≈ 0.29  (small)
#   r_rand=0.80 (80th %ile): s_mult ≈ 0.98  (medium)
#   r_rand=0.95 (95th %ile): s_mult ≈ 2.52  (large boulder)
#   r_rand=0.99 (99th %ile): s_mult ≈ 3.05  (monolith — rare)
static func rock_xform(pos: Vector3, up: Vector3, noise_val: float, b_scale: float) -> Transform3D:
	var t_bas := Basis()
	t_bas.y = up
	t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1:
		t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	var r_rand: float = abs(fmod(noise_val * 4123.0, 1.0))
	var s_mult: float = 0.2 + (pow(r_rand, 5.0) * 3.0)
	return Transform3D(t_bas, pos) \
		.scaled_local(Vector3(b_scale * s_mult, b_scale * s_mult * (0.8 + r_rand * 0.4), b_scale * s_mult)) \
		.rotated_local(Vector3.UP, abs(fmod(noise_val * 9999.0, PI * 2.0)))

# Grass clumps: smaller, lighter rotation/jitter.
static func grass_xform(pos: Vector3, up: Vector3, rand_val: float) -> Transform3D:
	var t_bas := Basis()
	t_bas.y = up
	t_bas.x = up.cross(Vector3.RIGHT).normalized()
	if t_bas.x.length() < 0.1:
		t_bas.x = up.cross(Vector3.FORWARD).normalized()
	t_bas.z = t_bas.x.cross(t_bas.y).normalized()
	var s: float = 2.5 + (rand_val * 2.0)
	return Transform3D(t_bas, pos) \
		.scaled_local(Vector3(s, s * (0.8 + rand_val * 0.6), s)) \
		.rotated_local(Vector3.UP, rand_val * PI * 2.0)

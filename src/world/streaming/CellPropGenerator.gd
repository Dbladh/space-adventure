extends RefCounted

# CellPropGenerator.gd
# Cell-scope deterministic prop emission.  Carved from
# PlanetChunk._scatter_deterministic_stellar_layers_thread_safe so that the
# streamer can populate a SurfaceCell without standing up a full PlanetChunk.
# Designed to run on a WorkerThreadPool task — touches only data that's safe
# for concurrent read access (planet.noise is FastNoiseLite, planet_seed,
# planet_resources, archetype, etc. are set before chunk/cell generation).

const SurfaceCellId = preload("res://src/world/streaming/SurfaceCellId.gd")
const PropXform = preload("res://src/world/streaming/PropXform.gd")

# Match the chunk's fine sampling step at the densest LOD — see
# PlanetChunk._scatter_deterministic_stellar_layers_thread_safe lines 484-489.
# A single streaming cell at radius 100km/1.0 ratio yields ~234 samples/axis
# (~55k iterations).  Worker-thread cost on desktop is well under 5ms per cell.
const BASE_CELL: float = 0.00008
# Grass cell sampling — coarser than the legacy chunk's 0.0000045 because the
# chunk only ran grass at scale_factor <= 0.00055 (chunk size ~0.001 face-
# local).  A streaming cell spans ~0.0625 face-local, so the legacy value
# produced a 14k×14k grid (cap of 600 in the loop killed grass entirely on
# streamer cells).  Coarser sampling gives ~190 samples/axis = ~36k grid
# points, which the 3% grass numerator turns into ~1100 candidates per cell,
# capped at MAX_GRASS_PER_CELL.
const GRASS_CELL: float = 0.0001

# Density rules — quartered from the chunk scatter values for the cell
# streamer.  The legacy chunk system relied on QuadTree subdivision to throttle
# how many chunks were active; the streamer keeps a fixed window alive, so the
# same per-cell densities produced visibly oversaturated surfaces.  Two passes
# of halving bring per-screen prop count into the NMS-style breathing-room
# range and leave the GPU room to render terrain and impostors comfortably.
# Rocks get an extra cut beyond the global halve since the user reported them
# as the most over-represented prop type.
const MINERAL_RARITY_DENOM: int = 300000
const TREE_DENOM: int = 1000
const ROCK_DENOM: int = 1000
const GRASS_DENOM: int = 100
const TREE_BASE_NUMERATOR: int = 31   # was 62 — half again
const ROCK_BASE_NUMERATOR: int = 6    # was 15 — extra cut for rocks specifically
const GRASS_BASE_NUMERATOR: int = 3   # was 6 — half again
const MINEABLE_TREE_RARITY: int = 500
const MINEABLE_ROCK_RARITY: int = 800
const MINEABLE_GRASS_RARITY: int = 120

# Minimum elevation above the planet's sea_level for a prop to spawn.  Trees
# need a margin so they don't poke out of shallow water at the shoreline;
# rocks and grass can sit a bit lower.  All three replace the legacy
# hardcoded -150 / -50 thresholds which were sea-level-agnostic.
const TREE_ABOVE_SEA_M:  float = 30.0
const ROCK_ABOVE_SEA_M:  float = 10.0
const GRASS_ABOVE_SEA_M: float = 20.0

# Cap defensive: each cell's prop count is bounded so the per-cell MMI's
# instance-buffer stays small.  With a 3x3 active window (9 cells) a 128
# cap on trees gives a worst-case 1152 tree instances on screen — plenty
# for a dense JUNGLE planet without overcommitting GPU.  Grass is allowed a
# higher cap since each blade is tiny, fades out past 800m, and dense fields
# are what sells the ground texture.
const MAX_PER_TYPE: int = 128
const MAX_GRASS_PER_CELL: int = 384

# Returns:
# {
#   trees:        Array[Transform3D]      (planet-local)
#   rocks:        Array[Transform3D]
#   grass:        Array[Transform3D]
#   minerals:     Array[Dictionary {xform, type, local_idx}]
#   tree_indices: PackedInt32Array        (stable local idx per tree, parallel array)
#   rock_indices: PackedInt32Array
#   grass_indices: PackedInt32Array        (kept for symmetry; grass is non-destructible)
#   destroyed:    PackedInt32Array        (local indices the registry says are gone)
# }
#
# `local_idx` is the deterministic ordinal an item received during emission
# (incremented across all four types).  This is the index the destruction
# registry stores when the player kills a prop.
#
# `destroyed_indices` is a snapshot of the registry's destroyed-list for this
# cell, taken on the main thread before this function is dispatched to a
# worker.  Using a snapshot keeps the worker thread independent of registry
# state — callers can safely write the registry from gameplay code without
# racing the generator.
static func generate(planet: Node, cell_id: int, destroyed_indices: PackedInt32Array) -> Dictionary:
	var out: Dictionary = {
		"trees": [],
		"rocks": [],
		"grass": [],
		"minerals": [],
		"tree_indices": PackedInt32Array(),
		"rock_indices": PackedInt32Array(),
		"grass_indices": PackedInt32Array(),
		"mineral_indices": PackedInt32Array(),
		"destroyed": PackedInt32Array(),
	}
	if planet == null or not "noise" in planet:
		return out

	var noise: FastNoiseLite = planet.noise
	if noise == null:
		return out

	var info: Dictionary = SurfaceCellId.unpack(cell_id)
	var face_idx: int = info["face"]
	var ix: int = info["ix"]
	var iy: int = info["iy"]
	var face_normal: Vector3 = SurfaceCellId.FACE_NORMALS[face_idx]
	var axes := SurfaceCellId.face_axes(face_normal)
	var x_axis: Vector3 = axes[0]
	var y_axis: Vector3 = axes[1]

	var planet_radius: float = float(planet.get("planet_radius"))
	var planet_seed: int = int(planet.get("planet_seed"))
	var sea_level: float = float(planet.get("sea_level")) if "sea_level" in planet else -120.0
	var archetype: String = String(planet.get("archetype")) if "archetype" in planet else "LUSH"
	var continent_pole: Vector3 = Vector3.UP
	if "continent_pole" in planet:
		continent_pole = planet.get("continent_pole")

	var mineable_pool: Array[String] = []
	if "planet_resources" in planet:
		for r in planet.get("planet_resources"):
			if r != "Stone" and r != "Wood":
				mineable_pool.append(r)
	if mineable_pool.is_empty():
		mineable_pool = ["Copper"]

	# Per-archetype tree-density multiplier (PlanetChunk:531-540).
	var nat_scale: float = 1.0
	match archetype:
		"BARREN", "ASH", "MUDFLAT", "DESERT", "RUST":
			nat_scale = 0.0
		"JUNGLE":
			nat_scale = 2.0
		"SAVANNA":
			nat_scale = 0.4
		"OBSIDIAN":
			nat_scale = 0.2

	# DebugSettings is autoload-static — safe to read from worker threads
	# (it's a simple float; no logic).
	var debug_settings_script = load("res://src/core/DebugSettings.gd")
	var tree_mult: float = float(debug_settings_script.get("tree_mult"))
	var rock_mult: float = float(debug_settings_script.get("rock_mult"))

	# Cell parametric bounds in face-local [-1, 1] space.
	var step: float = 2.0 / float(SurfaceCellId.CELLS_PER_FACE)
	var u_lo: float = -1.0 + float(ix) * step
	var u_hi: float = u_lo + step
	var v_lo: float = -1.0 + float(iy) * step
	var v_hi: float = v_lo + step

	var radius_ratio: float = clamp(planet_radius / 1000000.0, 0.3, 1.5)
	var t_cell: float = BASE_CELL / radius_ratio

	# Each grid index (gx, gy) maps to ONE cell deterministically: the cell
	# that contains the point (gx + 0.5) * t_cell.  We iterate over the range
	# of (gx, gy) whose centers fall within [u_lo, u_hi) × [v_lo, v_hi).
	var gx_lo: int = int(floor(u_lo / t_cell))
	var gx_hi: int = int(ceil(u_hi / t_cell))
	var gy_lo: int = int(floor(v_lo / t_cell))
	var gy_hi: int = int(ceil(v_hi / t_cell))

	var local_idx_counter: int = 0
	var trees: Array = []
	var rocks: Array = []
	var grass: Array = []
	var minerals: Array = []
	var tree_indices := PackedInt32Array()
	var rock_indices := PackedInt32Array()
	var grass_indices := PackedInt32Array()
	var mineral_indices := PackedInt32Array()

	for y_idx in range(gy_lo, gy_hi):
		for x_idx in range(gx_lo, gx_hi):
			var h_v: int = hash(Vector3(float(x_idx), float(y_idx), float(planet_seed) + face_normal.x * 13.0))

			var j_x: float = (float(h_v % 100) / 100.0 - 0.5) * 1.5
			var j_y: float = (float((h_v >> 6) % 100) / 100.0 - 0.5) * 1.5
			var sample_u: float = (float(x_idx) + j_x) * t_cell
			var sample_v: float = (float(y_idx) + j_y) * t_cell

			# Cell ownership: a sample's *jittered* point can drift outside
			# the integer cell's parametric range. We gate on the sample
			# point actually landing inside this streaming cell so adjacent
			# cells never produce overlapping props.
			if sample_u < u_lo or sample_u >= u_hi:
				continue
			if sample_v < v_lo or sample_v >= v_hi:
				continue

			var cp: Vector3 = (face_normal + x_axis * sample_u + y_axis * sample_v).normalized()
			var cluster_n: float = noise.get_noise_3dv(cp * 18000.0)
			var detail_n: float = noise.get_noise_3dv(cp * 65000.0)

			# Mineral lottery: extremely rare deposit.
			if (h_v % MINERAL_RARITY_DENOM) < 1:
				var h: float = _terrain_elevation(planet, cp)
				if h > sea_level + ROCK_ABOVE_SEA_M:
					var type: String = mineable_pool[int(abs(float(h_v >> 7))) % mineable_pool.size()]
					var xf := PropXform.object_xform(cp * (planet_radius + h + 5.0), cp, detail_n, 1.0)
					if minerals.size() < MAX_PER_TYPE:
						var idx: int = local_idx_counter
						local_idx_counter += 1
						if not _is_destroyed(destroyed_indices, idx):
							minerals.append({"xform": xf, "type": type, "local_idx": idx})
							mineral_indices.append(idx)
				continue

			# Nature path: trees in groves, rocks in barren spots.
			if cluster_n > 0.35 and nat_scale > 0.0:
				var grove_strength: float = clamp((cluster_n - 0.35) * 8.0, 0.0, 1.0)
				if (h_v % TREE_DENOM) < int(TREE_BASE_NUMERATOR * grove_strength * tree_mult * nat_scale):
					var h_t: float = _terrain_elevation(planet, cp)
					if h_t > sea_level + TREE_ABOVE_SEA_M and (h_t + sin(cp.x * 12000.0) * 300.0) < 1450.0:
						var base_pos: Vector3 = cp * (planet_radius + max(h_t, sea_level - 50.0))
						var xform := PropXform.object_xform(base_pos, cp, detail_n, 12.0)
						# Mineable-tree variant (rare).
						if h_v % MINEABLE_TREE_RARITY < 1:
							if minerals.size() < MAX_PER_TYPE:
								var idx: int = local_idx_counter
								local_idx_counter += 1
								if not _is_destroyed(destroyed_indices, idx):
									minerals.append({"xform": xform, "type": "Wood", "local_idx": idx})
									mineral_indices.append(idx)
						else:
							if trees.size() < MAX_PER_TYPE:
								var idx2: int = local_idx_counter
								local_idx_counter += 1
								if not _is_destroyed(destroyed_indices, idx2):
									var rotated: Transform3D = xform.rotated_local(Vector3.UP, float(h_v % 360))
									trees.append(rotated)
									tree_indices.append(idx2)
			elif cluster_n < -0.30:
				if (h_v % ROCK_DENOM) < int(ROCK_BASE_NUMERATOR * rock_mult * nat_scale):
					var h_r: float = _terrain_elevation(planet, cp)
					if h_r > sea_level + ROCK_ABOVE_SEA_M:
						var r_pos: Vector3 = cp * (planet_radius + max(h_r, sea_level - 50.0))

						# Spawn-collision avoidance.  Cell-local: only checks
						# props already emitted by THIS cell; cross-cell
						# overlap (≤ 1 prop pair per cell edge) is acceptable.
						var too_close: bool = false
						for tp in trees:
							if (tp as Transform3D).origin.distance_to(r_pos) < 12.0:
								too_close = true
								break
						if not too_close:
							for rp in rocks:
								if (rp as Transform3D).origin.distance_to(r_pos) < 10.0:
									too_close = true
									break
						if not too_close:
							var r_xf := PropXform.rock_xform(r_pos, cp, detail_n, 5.0)
							if h_v % MINEABLE_ROCK_RARITY < 1:
								if minerals.size() < MAX_PER_TYPE:
									var idx3: int = local_idx_counter
									local_idx_counter += 1
									if not _is_destroyed(destroyed_indices, idx3):
										var mineable_xf := PropXform.rock_xform(r_pos, cp, detail_n, 8.0)
										minerals.append({"xform": mineable_xf, "type": "Stone", "local_idx": idx3})
										mineral_indices.append(idx3)
							else:
								if rocks.size() < MAX_PER_TYPE:
									var idx4: int = local_idx_counter
									local_idx_counter += 1
									if not _is_destroyed(destroyed_indices, idx4):
										rocks.append(r_xf)
										rock_indices.append(idx4)

	# Grass pass — finer grid, gated on continent-mask noise.
	var g_cell: float = GRASS_CELL / radius_ratio
	var ggx_lo: int = int(floor(u_lo / g_cell))
	var ggx_hi: int = int(ceil(u_hi / g_cell))
	var ggy_lo: int = int(floor(v_lo / g_cell))
	var ggy_hi: int = int(ceil(v_hi / g_cell))

	# Bound grass iteration so a pathologically wide cell doesn't blow up the
	# worker thread.  With GRASS_CELL=0.0001 and the canonical cell span of
	# 0.0625 face-local, this is ~190 samples/axis — comfortably under the
	# guard.
	if (ggx_hi - ggx_lo) <= 1200:
		for y_idx in range(ggy_lo, ggy_hi):
			for x_idx in range(ggx_lo, ggx_hi):
				var h_v: int = hash(Vector3(float(x_idx), float(y_idx), float(planet_seed) + face_normal.x * 7.0 + face_normal.z * 3.0))
				if (h_v % GRASS_DENOM) >= GRASS_BASE_NUMERATOR:
					continue
				var j_x: float = (float(h_v % 50) / 50.0 - 0.5) * 1.8
				var j_y: float = (float((h_v >> 4) % 50) / 50.0 - 0.5) * 1.8
				var sample_u: float = (float(x_idx) + j_x) * g_cell
				var sample_v: float = (float(y_idx) + j_y) * g_cell
				if sample_u < u_lo or sample_u >= u_hi: continue
				if sample_v < v_lo or sample_v >= v_hi: continue

				var cp: Vector3 = (face_normal + x_axis * sample_u + y_axis * sample_v).normalized()
				var g_cn: float = noise.get_noise_3dv(cp * 2.2)
				var warp_off: Vector3 = Vector3(
					noise.get_noise_3dv(cp * 0.5),
					noise.get_noise_3dv(cp * 0.6 + Vector3(7,7,7)),
					noise.get_noise_3dv(cp * 0.7 - Vector3(3,3,3))
				) * 0.35
				var g_w_cp: Vector3 = (cp + warp_off).normalized()
				var g_dist: float = g_w_cp.distance_to(continent_pole)
				var g_prox: float = 1.0 - smoothstep(0.0, 1.1, g_dist)
				var g_mask: float = smoothstep(0.32, 0.48, g_cn + g_prox * 0.85)
				if g_mask <= 0.65:
					continue

				var h_g: float = _terrain_elevation(planet, cp)
				if h_g <= sea_level + GRASS_ABOVE_SEA_M:
					continue
				var g_xf := PropXform.object_xform(cp * (planet_radius + h_g), cp, 0.0, 3.5)
				if h_v % MINEABLE_GRASS_RARITY < 1:
					if minerals.size() < MAX_PER_TYPE:
						var idx5: int = local_idx_counter
						local_idx_counter += 1
						if not _is_destroyed(destroyed_indices, idx5):
							minerals.append({"xform": g_xf, "type": "Carbon Fiber", "local_idx": idx5})
							mineral_indices.append(idx5)
				else:
					if grass.size() < MAX_GRASS_PER_CELL:
						var idx6: int = local_idx_counter
						local_idx_counter += 1
						# Grass has no destruction routing (visual-only) but we
						# keep an index so registry calls stay symmetric.
						grass.append(g_xf)
						grass_indices.append(idx6)

	out["trees"] = trees
	out["rocks"] = rocks
	out["grass"] = grass
	out["minerals"] = minerals
	out["tree_indices"] = tree_indices
	out["rock_indices"] = rock_indices
	out["grass_indices"] = grass_indices
	out["mineral_indices"] = mineral_indices
	return out

# Compute terrain elevation using the SAME formula PlanetChunk uses for
# vertex placement.  Critical: PlanetGen's own `get_terrain_elevation`
# hardcodes `noise * 600.0` while PlanetChunk reads `planet.noise_frequency`
# (which is set to 300/400/600/800 per the planet's topology roll).  Going
# through PlanetGen's method would place props at heights that don't match
# the chunks' rendered surface — props end up floating in the air or buried
# below ground on any non-MOUNTAINOUS planet.  Mirror the chunk formula
# exactly so the prop sits on the actual terrain.
static func _terrain_elevation(planet: Node, sn: Vector3) -> float:
	if planet == null:
		return 0.0
	var noise: FastNoiseLite = planet.noise
	if noise == null:
		return 0.0

	var noise_freq: float = 600.0
	if "noise_frequency" in planet:
		noise_freq = float(planet.get("noise_frequency"))
	var terrain_strength: float = 5000.0
	if "terrain_strength" in planet:
		terrain_strength = float(planet.get("terrain_strength"))
	var sea_level: float = -120.0
	if "sea_level" in planet:
		sea_level = float(planet.get("sea_level"))
	var archetype: String = "LUSH"
	if "archetype" in planet:
		archetype = String(planet.get("archetype"))

	var macro_h: float = noise.get_noise_3dv(sn * noise_freq)
	var micro_crag: float = noise.get_noise_3dv(sn * 15000.0) * 0.1
	var local_geo: float = 0.0

	match archetype:
		"DESERT":
			var mesa: float = smoothstep(-0.1, 0.1, macro_h) * 2.0 - 1.0
			local_geo = (mesa * 0.6 + micro_crag) * terrain_strength * 0.7
		"VOLCANIC", "ABYSS":
			var jagged: float = 1.0 - abs(macro_h * 1.5)
			local_geo = (jagged * 2.0 - 0.8 + micro_crag * 2.5) * terrain_strength * 1.4
		"FROZEN":
			var plains: float = macro_h * 0.4
			var spikes: float = max(0.0, noise.get_noise_3dv(sn * 2500.0) - 0.65) * 6.0
			local_geo = (plains + spikes + micro_crag * 0.4) * terrain_strength
		"TOXIC", "RADIATED":
			var craters: float = abs(noise.get_noise_3dv(sn * 1200.0))
			var bubbling: float = noise.get_noise_3dv(sn * 3000.0) * 0.5
			local_geo = (macro_h - craters * 1.8 + bubbling + micro_crag) * terrain_strength * 0.6
		"ALPINE":
			var ridge: float = 1.0 - abs(macro_h)
			local_geo = (ridge * 2.5 - 0.8 + micro_crag * 1.5) * terrain_strength * 1.5
		_:
			# LUSH / CANDY / JUNGLE / etc. — standard terraced terrain.
			local_geo = (macro_h + micro_crag) * terrain_strength
			var volcanic: float = noise.get_noise_3dv(sn * 25000.0)
			if volcanic > 0.45:
				local_geo -= 1000.0
			var terrace_height: float = 80.0
			var h_frac: float = fposmod(local_geo, terrace_height) / terrace_height
			var layer_step: float = floor(local_geo / terrace_height) + smoothstep(0.15, 0.85, h_frac)
			local_geo = layer_step * terrace_height

	var c_n: float = noise.get_noise_3dv(sn * 220.0)
	c_n += noise.get_noise_3dv(sn * 520.0) * 0.55
	c_n += noise.get_noise_3dv(sn * 1100.0) * 0.25
	var cont_mask: float = smoothstep(-0.18, 0.18, c_n + 0.05)
	var abyss_depth: float = sea_level - 400.0
	return lerp(abyss_depth, local_geo + (sea_level + 50.0), cont_mask)

static func _is_destroyed(destroyed_indices: PackedInt32Array, local_idx: int) -> bool:
	if destroyed_indices.is_empty():
		return false
	# Linear scan — destroyed lists are typically <10 entries per cell.
	for v in destroyed_indices:
		if v == local_idx:
			return true
		if v > local_idx:
			return false
	return false

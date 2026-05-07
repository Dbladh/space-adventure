extends Object

# WorldAudit.gd
#
# One-shot scene-tree census for diagnosing planet/world content.
#
# Walks every node in the "Planet" group plus WorldRoot's direct children,
# bucketing meshes by class so visual outliers (a BoxMesh sitting on a
# planet, a 4500m flat MultiMesh, ...) show up immediately.  Emits via
# MCPRuntime.push_runtime_log so results are fetchable from outside the
# game with the godot_mcp `get_runtime_log` tool.
#
# Triggered from Main._unhandled_input on F5.  Static-only — no node
# lifecycle, no per-frame work.  Call:  WorldAudit.dump()

# ---- Suspicious-flag heuristics ------------------------------------------
# A flat-primitive MultiMesh source larger than this on any axis with a
# meaningful instance count is almost certainly a stray impostor block.
const SUSPICIOUS_BOX_SIZE_M: float = 1000.0
const SUSPICIOUS_INSTANCE_COUNT: int = 100
# Direct MeshInstance3D using a flat primitive on a planet is suspicious
# at much smaller sizes (real terrain shouldn't use BoxMesh at all).
const SUSPICIOUS_PLANET_BOX_SIZE_M: float = 100.0
# Axis ratio for a "slab" — catches the 6000×60×6000 metropolitan slab.
const SUSPICIOUS_AXIS_RATIO: float = 30.0


static func dump() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_emit("warn", "no SceneTree")
		return

	_emit("info", "==== WORLD AUDIT ====")

	# Top-level: WorldRoot direct children breakdown.
	var world_roots := tree.get_nodes_in_group("WorldRoot")
	if world_roots.is_empty():
		_emit("warn", "no WorldRoot in group — aborting")
		return
	var world_root: Node = world_roots[0]
	_emit("info", "WorldRoot direct children: %d" % world_root.get_child_count())
	var direct_class_hist: Dictionary = {}
	for c in world_root.get_children():
		var k: String = c.get_class()
		direct_class_hist[k] = int(direct_class_hist.get(k, 0)) + 1
	for k in direct_class_hist:
		_emit("info", "  WorldRoot[%s] × %d" % [k, direct_class_hist[k]])

	# Per-planet audit.
	var planets := tree.get_nodes_in_group("Planet")
	_emit("info", "Planets in scene: %d" % planets.size())
	for p in planets:
		_audit_planet(p)

	_emit("info", "==== /WORLD AUDIT ====")


# Walks a single planet's subtree, builds histograms, runs suspicious
# checks, emits the per-planet section.
static func _audit_planet(p: Node) -> void:
	var arche: String = "?"
	var arche_v = p.get("archetype") if "archetype" in p else null
	if arche_v != null: arche = str(arche_v)
	var rad_v = p.get("planet_radius") if "planet_radius" in p else null
	var rad_str: String = "?"
	if rad_v is float or rad_v is int: rad_str = "%dm" % int(rad_v)
	_emit("info", "Planet %s (archetype=%s, radius=%s)" % [p.name, arche, rad_str])

	var mi_hist: Dictionary = {}        # mesh_class -> [visible_count, hidden_count]
	var mmi_hist: Dictionary = {}       # mesh_class -> [mmi_count, total_instance_count]
	var suspicious: Array = []
	_walk(p, mi_hist, mmi_hist, suspicious, p)

	for k in mi_hist:
		var v: Array = mi_hist[k]
		_emit("info", "  MI[%s] × %d  (visible=%d hidden=%d)" % [k, v[0] + v[1], v[0], v[1]])
	for k in mmi_hist:
		var v2: Array = mmi_hist[k]
		_emit("info", "  MMI[%s] × %d nodes, %d total instances" % [k, v2[0], v2[1]])

	for s in suspicious:
		_emit("warn", "  SUSPICIOUS: %s" % s)


static func _walk(n: Node, mi_hist: Dictionary, mmi_hist: Dictionary, suspicious: Array, planet_root: Node) -> void:
	if n is MeshInstance3D:
		_classify_mi(n as MeshInstance3D, mi_hist, suspicious, planet_root)
	elif n is MultiMeshInstance3D:
		_classify_mmi(n as MultiMeshInstance3D, mmi_hist, suspicious, planet_root)
	for c in n.get_children():
		_walk(c, mi_hist, mmi_hist, suspicious, planet_root)


static func _classify_mi(mi: MeshInstance3D, mi_hist: Dictionary, suspicious: Array, planet_root: Node) -> void:
	if mi.mesh == null: return
	var k: String = mi.mesh.get_class()
	if not k in mi_hist: mi_hist[k] = [0, 0]
	if mi.is_visible_in_tree():
		mi_hist[k][0] += 1
	else:
		mi_hist[k][1] += 1
	# Flat-primitive check — terrain should never use BoxMesh/PlaneMesh/QuadMesh.
	if k in ["BoxMesh", "PlaneMesh", "QuadMesh"]:
		var size: Vector3 = mi.mesh.get_aabb().size
		var max_d: float = max(size.x, max(size.y, size.z))
		if max_d > SUSPICIOUS_PLANET_BOX_SIZE_M:
			suspicious.append("MI %s size=%s under %s" % [k, _vec_str(size), planet_root.name])


static func _classify_mmi(mmi: MultiMeshInstance3D, mmi_hist: Dictionary, suspicious: Array, planet_root: Node) -> void:
	if mmi.multimesh == null or mmi.multimesh.mesh == null: return
	var k: String = mmi.multimesh.mesh.get_class()
	if not k in mmi_hist: mmi_hist[k] = [0, 0]
	mmi_hist[k][0] += 1
	mmi_hist[k][1] += mmi.multimesh.instance_count

	# Source mesh is a flat primitive — check size + count + axis ratio.
	if k in ["BoxMesh", "PlaneMesh"]:
		var size: Vector3 = mmi.multimesh.mesh.get_aabb().size
		var max_d: float = max(size.x, max(size.y, size.z))
		if max_d > SUSPICIOUS_BOX_SIZE_M and mmi.multimesh.instance_count >= SUSPICIOUS_INSTANCE_COUNT:
			suspicious.append("MMI %s size=%s × %d instances under %s" % [
				k, _vec_str(size), mmi.multimesh.instance_count, planet_root.name])
		else:
			# Slab axis-ratio test.
			var dims: Array = [size.x, size.y, size.z]
			dims.sort()
			if dims[0] > 0.001 and dims[2] / dims[0] > SUSPICIOUS_AXIS_RATIO:
				suspicious.append("MMI %s flat-slab size=%s ratio=%.0f under %s" % [
					k, _vec_str(size), dims[2] / dims[0], planet_root.name])


static func _vec_str(v: Vector3) -> String:
	return "(%.0f×%.0f×%.0f)" % [v.x, v.y, v.z]


static func _emit(level: String, text: String) -> void:
	# Print to stdout for editor visibility, plus push to MCP runtime log.
	print("[WORLD-AUDIT] " + text)
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return
	if tree.root.has_node("/root/MCPRuntime"):
		var mcp: Node = tree.root.get_node("/root/MCPRuntime")
		if mcp.has_method("push_runtime_log"):
			mcp.push_runtime_log(level, "[WORLD-AUDIT] " + text)

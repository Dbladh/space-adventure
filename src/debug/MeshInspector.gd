extends Object

# MeshInspector.gd
#
# Click-to-identify visual-pick tool.  Casts a ray from the mouse cursor
# through the active camera, iterates every visible MeshInstance3D /
# MultiMeshInstance3D under WorldRoot, and reports the closest hit's
# identity to the MCP runtime log.
#
# Why mesh-AABB iteration instead of physics raycast: many of the
# visual-only objects we want to identify (city impostors, hero
# landmarks, cloud / aurora shells) lack any CollisionShape3D.  A
# physics raycast finds the underlying terrain chunk instead of the
# artifact above and tells us nothing.  Iterating O(visible-mesh-count)
# AABBs per click is fine for a debug tool.
#
# Triggered from Main._unhandled_input on F6.  Static-only.  Call:
#   MeshInspector.inspect_at(get_viewport(), player.camera)


static func inspect_at(viewport: Viewport, camera: Camera3D) -> void:
	if viewport == null or camera == null:
		_emit("warn", "missing viewport/camera")
		return
	var mouse: Vector2 = viewport.get_mouse_position()
	var ray_o: Vector3 = camera.project_ray_origin(mouse)
	var ray_d: Vector3 = camera.project_ray_normal(mouse)

	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		_emit("warn", "no SceneTree")
		return
	var roots: Array = tree.get_nodes_in_group("WorldRoot")
	if roots.is_empty():
		_emit("warn", "no WorldRoot")
		return
	var world_root: Node = roots[0]

	var best: Dictionary = {
		"t": INF,
		"node": null,
		"hit": Vector3.ZERO,
	}
	_walk(world_root, ray_o, ray_d, camera, best)

	if best["node"] == null:
		_emit("info", "no hit (mouse=%s)" % str(mouse))
		return
	_report(best, mouse)


static func _walk(n: Node, ray_o: Vector3, ray_d: Vector3, cam: Camera3D, best: Dictionary) -> void:
	# Skip whole subtrees if the parent Node3D is hidden.
	if n is Node3D and not (n as Node3D).is_visible_in_tree():
		return
	if n is MeshInstance3D:
		_test_mi(n as MeshInstance3D, ray_o, ray_d, cam, best)
	elif n is MultiMeshInstance3D:
		_test_mmi(n as MultiMeshInstance3D, ray_o, ray_d, cam, best)
	for c in n.get_children():
		_walk(c, ray_o, ray_d, cam, best)


static func _test_mi(mi: MeshInstance3D, ray_o: Vector3, ray_d: Vector3, cam: Camera3D, best: Dictionary) -> void:
	if mi.mesh == null: return
	var d_to_cam: float = cam.global_position.distance_to(mi.global_position)
	# Mirror Godot's visibility-range cull so we don't pick objects that
	# the engine isn't actually drawing.
	if mi.visibility_range_end > 0.0 and d_to_cam > mi.visibility_range_end:
		return
	if d_to_cam < mi.visibility_range_begin: return

	# Prefer custom_aabb when set (hero landmarks set this — their
	# SurfaceTool meshes have a per-instance aabb that's wrong for picking).
	var local_aabb: AABB = mi.mesh.get_aabb()
	if mi.custom_aabb.size != Vector3.ZERO:
		local_aabb = mi.custom_aabb
	var world_aabb: AABB = mi.global_transform * local_aabb
	var hit = world_aabb.intersects_ray(ray_o, ray_d)
	if hit == null: return
	var t: float = (hit as Vector3 - ray_o).length()
	if t < best["t"]:
		best["t"] = t
		best["node"] = mi
		best["hit"] = hit


static func _test_mmi(mmi: MultiMeshInstance3D, ray_o: Vector3, ray_d: Vector3, cam: Camera3D, best: Dictionary) -> void:
	if mmi.multimesh == null or mmi.multimesh.mesh == null: return
	var d_to_cam: float = cam.global_position.distance_to(mmi.global_position)
	if mmi.visibility_range_end > 0.0 and d_to_cam > mmi.visibility_range_end:
		return
	if d_to_cam < mmi.visibility_range_begin: return

	# MultiMesh.get_aabb() is the union of all instance AABBs (mesh AABB
	# transformed by each instance transform), so we treat it as one
	# aggregate AABB.  Picking individual instances would require
	# iterating get_instance_count — overkill for a debug tool.
	var local_aabb: AABB = mmi.multimesh.get_aabb()
	var world_aabb: AABB = mmi.global_transform * local_aabb
	var hit = world_aabb.intersects_ray(ray_o, ray_d)
	if hit == null: return
	var t: float = (hit as Vector3 - ray_o).length()
	if t < best["t"]:
		best["t"] = t
		best["node"] = mmi
		best["hit"] = hit


static func _report(best: Dictionary, mouse: Vector2) -> void:
	var node: Node = best["node"]
	var t: float = best["t"]
	_emit("info", "==== MESH INSPECTOR ====")
	_emit("info", "Click viewport %s → world %s (dist=%.0f m)" % [
		str(mouse), _vec_str(best["hit"]), t])
	_emit("info", "Node: %s  [%s]" % [str(node.get_path()), node.get_class()])

	if node is MeshInstance3D:
		var mi: MeshInstance3D = node
		_emit("info", "Mesh: %s  size=%s" % [
			mi.mesh.get_class(), _vec_str(mi.mesh.get_aabb().size)])
		_emit("info", "Visibility range: [%.0f, %.0f]" % [
			mi.visibility_range_begin, mi.visibility_range_end])
		_emit("info", "Material: " + _mat_desc(mi.material_override))
	elif node is MultiMeshInstance3D:
		var mmi: MultiMeshInstance3D = node
		_emit("info", "Source mesh: %s  size=%s" % [
			mmi.multimesh.mesh.get_class(), _vec_str(mmi.multimesh.mesh.get_aabb().size)])
		_emit("info", "Instances: %d  bounds=%s" % [
			mmi.multimesh.instance_count, _vec_str(mmi.multimesh.get_aabb().size)])
		_emit("info", "Visibility range: [%.0f, %.0f]" % [
			mmi.visibility_range_begin, mmi.visibility_range_end])
		_emit("info", "Material: " + _mat_desc(mmi.material_override))

	# Parent chain — up to 4 levels — so we can see e.g. "Planet → quadface
	# → chunk → THIS" and immediately tell whether this is a chunk-attached
	# foliage MMI or a planet-root impostor.
	var chain: Array = []
	var p: Node = node.get_parent()
	for i in range(4):
		if p == null: break
		chain.append("%s [%s]" % [p.name, p.get_class()])
		p = p.get_parent()
	_emit("info", "Parent chain: " + " ← ".join(chain))
	_emit("info", "==== /MESH INSPECTOR ====")


static func _mat_desc(m) -> String:
	if m == null: return "<no override>"
	if m is StandardMaterial3D:
		var sm: StandardMaterial3D = m
		return "StandardMaterial3D albedo=%s emission=%s" % [str(sm.albedo_color), str(sm.emission)]
	if m is ShaderMaterial:
		var sm2: ShaderMaterial = m
		var path: String = sm2.shader.resource_path if sm2.shader else "<inline>"
		return "ShaderMaterial shader=%s" % path
	return m.get_class()


static func _vec_str(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


static func _emit(level: String, text: String) -> void:
	print("[MESH-INSPECT] " + text)
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null: return
	if tree.root.has_node("/root/MCPRuntime"):
		var mcp: Node = tree.root.get_node("/root/MCPRuntime")
		if mcp.has_method("push_runtime_log"):
			mcp.push_runtime_log(level, "[MESH-INSPECT] " + text)

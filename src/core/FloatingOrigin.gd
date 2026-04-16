
extends Node

# FloatingOrigin.gd (10km M1-Harden Edition)
# Managed by THE ARCHITECT.

@export var threshold: float = 100000.0 # 100km M1 Hardened Ceiling
var player_node: Node3D
var world_root: Node3D

func _ready() -> void:
	self.add_to_group("FloatingOrigin")

func _physics_process(_delta: float) -> void:
	if not player_node:
		var players = get_tree().get_nodes_in_group("Player")
		if players.size() > 0:
			player_node = players[0]
			return
		else:
			return

	if player_node.global_position.length() > threshold:
		shift_world()

func shift_world() -> void:
	var shift_offset = player_node.global_position
	print("--- ARCHITECT: Floating Origin Shift Triggered ---")
	print("Shifted world by: ", -shift_offset)
	
	# Reset Physics Interpolation (Critical Godot 4 Fix)
	# This prevents the 10km teleport from 'smearing' across the screen.
	player_node.reset_physics_interpolation()
	
	# Recursively reset the entire Camera Stack (Pivot -> SpringArm -> Camera)
	var cam = get_viewport().get_camera_3d()
	if cam:
		cam.reset_physics_interpolation()
		var p = cam.get_parent()
		while p and p != player_node:
			p.reset_physics_interpolation()
			p = p.get_parent()
	
	# Shift the WorldRoot (O(1) Efficiency)
	if is_instance_valid(world_root):
		world_root.global_position -= shift_offset
	else:
		# Fallback: Shift individual group members if root is missing
		for node in get_tree().get_nodes_in_group("World"):
			if node is Node3D:
				node.global_position -= shift_offset
	
	# Reset Player to Origin
	player_node.global_position = Vector3.ZERO
	
	# SYNC PROCEDURAL TRAILS
	get_tree().call_group("Trails", "shift_points", shift_offset)

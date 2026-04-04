
class_name LootFactory
extends Node

# LootFactory.gd (Gunsmith Edition)
# Managed by THE GUNSMITH.
# Composition over Inheritance framework for modular weaponry.

const types: Array[String] = ["Driver", "Conduit", "Ejector", "Pulse"]
const roots: Array[String] = ["Nebula", "Cosmos", "Star", "Void", "Quantum"]

# SOCKRET REGISTRY: Hand-tuned offsets for the 1.5m player model
const BARREL_SOCKET: Vector3 = Vector3(0, 0, -0.3)
const GRIP_SOCKET: Vector3 = Vector3(0, -0.15, -0.05)

static func spawn_weapon_vfx(anchor: Marker3D, seed_val: int) -> void:
	assemble_weapon(anchor, seed_val)

static func assemble_weapon(anchor: Marker3D, seed_val: int) -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed_val
	
	var weapon_name: String = str(roots[rng.randi() % roots.size()], " ", types[rng.randi() % types.size()])
	
	# COMPOSITION: Step 1 - Build the RECEIVER (The Core)
	var receiver: MeshInstance3D = MeshInstance3D.new()
	receiver.mesh = BoxMesh.new()
	receiver.mesh.size = Vector3(0.1, 0.3, 0.4) 
	receiver.name = "Receiver_" + weapon_name
	
	var mat_loot: StandardMaterial3D = StandardMaterial3D.new()
	mat_loot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat_loot.albedo_color = Color("#1A1A1A") # Deep Charcoal (Mandate)
	receiver.material_override = mat_loot
	
	anchor.add_child(receiver)
	
	# COMPOSITION: Step 2 - Attach the BARREL (Socket: 0, 0, -0.3)
	var barrel: MeshInstance3D = MeshInstance3D.new()
	barrel.mesh = BoxMesh.new()
	var b_len = rng.randf_range(0.5, 1.0)
	barrel.mesh.size = Vector3(0.05, 0.05, b_len)
	barrel.position = BARREL_SOCKET + Vector3(0, 0, -b_len/2.0)
	barrel.material_override = mat_loot
	receiver.add_child(barrel)
	
	# COMPOSITION: Step 3 - Attach the GRIP (Socket: 0, -0.15, -0.05)
	var grip: MeshInstance3D = MeshInstance3D.new()
	grip.mesh = BoxMesh.new()
	grip.mesh.size = Vector3(0.05, 0.2, 0.05)
	grip.position = GRIP_SOCKET
	grip.material_override = mat_loot
	receiver.add_child(grip)
	
	# GUNSMITH: Log the assembly metadata
	print("--- Project Octo-Loot: Modular Assembly ---")
	print("Assembled: ", weapon_name)
	print("-----------------------------------------")

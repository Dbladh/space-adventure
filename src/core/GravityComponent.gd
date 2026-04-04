
extends Node
class_name GravityComponent

# GravityComponent.gd
# Managed by THE ARCHITECT.

@export var parent_body: Node3D # ARCHITECT: Support any body type
@export var gravity_strength: float = 10.0 # Restored for space exploration

func _physics_process(delta: float) -> void:
	if not parent_body:
		return
		
	# Find the nearest "Planet" from the group.
	var planets: Array[Node] = get_tree().get_nodes_in_group("Planet")
	var nearest_planet: Node3D = null
	var min_distance: float = INF
	
	for planet in planets:
		if planet is Node3D:
			var distance: float = parent_body.global_position.distance_to(planet.global_position)
			if distance < min_distance:
				min_distance = distance
				nearest_planet = planet
				
	if nearest_planet:
		apply_spherical_gravity(nearest_planet, delta)

## ARCHITECT: The "Spherical Down" calculation.
func apply_spherical_gravity(planet: Node3D, delta: float) -> void:
	var gravity_dir: Vector3 = (planet.global_position - parent_body.global_position).normalized()
	
	# Support different body types
	if parent_body is RigidBody3D:
		parent_body.apply_central_force(gravity_dir * gravity_strength)
	elif parent_body is CharacterBody3D:
		# Add gravity to the existing velocity
		parent_body.velocity += gravity_dir * gravity_strength * delta
	
	# Align the parent body's rotation so that "Down" is toward the planet.
	var target_basis: Basis = calculate_alignment_basis(gravity_dir)
	# parent_body.basis = parent_body.basis.slerp(target_basis, 0.1) # AUDIT: Disabled to prevent look_at conflicts
	
func calculate_alignment_basis(down_dir: Vector3) -> Basis:
	# Calculate basis where -Y is aligned with gravity direction.
	var up: Vector3 = -down_dir
	var right: Vector3 = parent_body.basis.x.cross(up).normalized()
	if right.length() == 0:
		right = Vector3.RIGHT.cross(up).normalized()
	var forward: Vector3 = up.cross(right).normalized()
	
	return Basis(right, up, forward)

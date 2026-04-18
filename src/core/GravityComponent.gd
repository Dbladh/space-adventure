
extends Node
class_name GravityComponent

# GravityComponent.gd
# Managed by THE ARCHITECT.

@export var parent_body: Node3D # ARCHITECT: Support any body type
@export var gravity_strength: float = 10.0 # Restored for space exploration

var _planet_refresh_tick: int = 0
var _cached_planets: Array[Node3D] = []

func _physics_process(delta: float) -> void:
	if not parent_body:
		return

	# The planet set is static for most of the session, so refresh it on a small cadence
	# instead of scanning the whole group every physics tick for every gravity source.
	_planet_refresh_tick += 1
	if _planet_refresh_tick >= 12 or _cached_planets.is_empty():
		_planet_refresh_tick = 0
		_cached_planets.clear()
		var planets: Array[Node] = get_tree().get_nodes_in_group("Planet")
		for planet in planets:
			if planet is Node3D:
				_cached_planets.append(planet)

	# Find the nearest cached planet.
	var nearest_planet: Node3D = null
	var min_distance: float = INF
	
	for planet in _cached_planets:
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

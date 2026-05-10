extends Node3D

# Slow orbital rotation for SKY_ISLES archetype. The flotilla orbits the planet
# at ~1 revolution per 12 minutes — fast enough to feel alive at low orbital
# fly-bys, slow enough not to disorient at the surface.
const ANGULAR_SPEED: float = TAU / 720.0

func _process(delta: float) -> void:
	rotate_y(ANGULAR_SPEED * delta)

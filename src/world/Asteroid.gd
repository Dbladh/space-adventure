extends StaticBody3D

# Asteroid.gd
# Minimal proxy to forward damage to the HealthComponent.

func take_damage(amount: float) -> void:
	var hc = get_node_or_null("HealthComponent")
	if hc:
		hc.take_damage(amount)

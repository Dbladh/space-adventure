extends StaticBody3D

# Asteroid.gd
# Minimal proxy to forward damage to the HealthComponent.

# Expose current health so the bolt loop can compute is_dying correctly.
# Without this, mineable.get("health") returns null → cur_hp = 1.0 →
# the catastrophic nova fires on every shot instead of just the killing blow.
var health: float:
	get:
		var hc = get_node_or_null("HealthComponent")
		return hc.current_health if hc else 0.0

func take_damage(amount: float) -> void:
	var hc = get_node_or_null("HealthComponent")
	if hc:
		hc.take_damage(amount)

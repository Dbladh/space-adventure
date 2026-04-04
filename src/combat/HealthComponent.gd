extends Node
class_name HealthComponent

# HealthComponent.gd
# Demonstrating Composition over Inheritance. 
# Reusable node for handling health stat for any entity.

signal health_changed(new_health: float)
signal health_depleted()

@export var max_health: float = 100.0
@onready var current_health: float = max_health

## Deduct health and emit signals.
func take_damage(amount: float) -> void:
	current_health = maxf(0.0, current_health - amount)
	health_changed.emit(current_health)
	
	if current_health <= 0.0:
		health_depleted.emit()

## Heal the component.
func heal(amount: float) -> void:
	current_health = min(max_health, current_health + amount)
	health_changed.emit(current_health)

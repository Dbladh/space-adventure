extends Control

# High-Performance Combat Visor Script
# Handles circular reticle rendering with anti-aliased arcs

func _draw():
	# ACE VISOR: Central targeting circle
	var center = size / 2.0
	var radius = 28.0
	var color = Color(0.2, 0.9, 1.0, 0.8) # Electric Cyan
	
	# Draw the outer ring
	draw_arc(center, radius, 0, TAU, 64, color, 1.5, true)
	
	# Draw inner targeting pips (Starfox 64 Style)
	var pip_len = 6.0
	draw_line(center + Vector2(radius + 2, 0), center + Vector2(radius + 2 + pip_len, 0), color, 2.0)
	draw_line(center - Vector2(radius + 2, 0), center - Vector2(radius + 2 + pip_len, 0), color, 2.0)
	draw_line(center + Vector2(0, radius + 2), center + Vector2(0, radius + 2 + pip_len), color, 2.0)
	draw_line(center - Vector2(0, radius + 2), center - Vector2(0, radius + 2 + pip_len), color, 2.0)
	
	# Center dot
	draw_circle(center, 1.5, Color.WHITE)

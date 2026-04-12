extends Control

# TargetLockUI.gd
# PILOT INTERFACE: A red diamond for locked targets

func _draw():
	var center = size / 2.0
	var s = 36.0
	var color = Color(1.0, 0.1, 0.2, 0.9) # Crimson Red (Target Lock)
	
	# Draw a futuristic diamond bracket
	var pts = [
		Vector2(center.x, center.y - s),
		Vector2(center.x + s, center.y),
		Vector2(center.x, center.y + s),
		Vector2(center.x - s, center.y),
		Vector2(center.x, center.y - s)
	]
	draw_polyline(pts, color, 2.5, true)
	
	# Corner notches
	var notch = 10.0
	draw_line(Vector2(center.x - s, center.y - s), Vector2(center.x - s + notch, center.y - s), color, 2.5)
	draw_line(Vector2(center.x - s, center.y - s), Vector2(center.x - s, center.y - s + notch), color, 2.5)
	
	draw_line(Vector2(center.x + s, center.y - s), Vector2(center.x + s - notch, center.y - s), color, 2.5)
	draw_line(Vector2(center.x + s, center.y - s), Vector2(center.x + s, center.y - s + notch), color, 2.5)
	
	draw_line(Vector2(center.x - s, center.y + s), Vector2(center.x - s + notch, center.y + s), color, 2.5)
	draw_line(Vector2(center.x - s, center.y + s), Vector2(center.x - s, center.y + s - notch), color, 2.5)
	
	draw_line(Vector2(center.x + s, center.y + s), Vector2(center.x + s - notch, center.y + s), color, 2.5)
	draw_line(Vector2(center.x + s, center.y + s), Vector2(center.x + s, center.y + s - notch), color, 2.5)

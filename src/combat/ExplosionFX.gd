extends Node3D

const STYLED_SMOKE_COUNT: int = 12 # Main bubble mass
const FRAGMENT_COUNT: int = 8      # Physical rock shards
const SPIKE_COUNT: int = 6         # Radiant 'smoke' pillars
const LIFETIME: float = 2.4
const FADE_DELAY: float = 0.8
const SPREAD_SPEED: float = 12.0

var explosion_scale: float = 12.0 # Injected by Player.gd
var elapsed: float = 0.0
var pieces: Array[Node3D] = []
var velocities: Array[Vector3] = []
var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.randomize()
	_spawn_all()

func _spawn_all() -> void:
	# 1. THE CORE: BUBBLE CLOUDS (Wind Waker 'Cloud' Clusters)
	# Alternating between Orange (#FF8800) and Yellow (#FFCC00)
	for i in range(STYLED_SMOKE_COUNT):
		var mi = _create_bubble(i % 2 == 0)
		# Rapid initial expansion
		var sc = rng.randf_range(0.8, 1.5) * explosion_scale
		mi.scale = Vector3.ZERO
		
		var t = get_tree().create_tween()
		t.tween_property(mi, "scale", Vector3.ONE * sc, rng.randf_range(0.05, 0.15)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		
		# Billow Velocity: Slow outward drift
		var dir = Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()
		velocities.append(dir * SPREAD_SPEED * (explosion_scale * 0.1))
		pieces.append(mi)
		
	# 2. THE BLAST: RADIANT SPIKES (Velocity Pillars)
	for i in range(SPIKE_COUNT):
		var mi = _create_bubble(false) # Pure Yellow
		var dir = Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()
		var sc = explosion_scale * 0.6
		mi.scale = Vector3.ZERO
		
		# Align with outward direction (NaN STABILITY)
		if dir.length() > 0.1:
			var target_vec = mi.position + dir.normalized()
			if not mi.position.is_equal_approx(target_vec):
				mi.look_at(target_vec)
				mi.rotate_object_local(Vector3.RIGHT, PI/2.0)
		
		var t = get_tree().create_tween()
		# Long 'Pillar' Scaling
		t.tween_property(mi, "scale", Vector3(sc * 0.5, sc * 3.5, sc * 0.5), 0.1).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
		
		velocities.append(dir * SPREAD_SPEED * (explosion_scale * 0.6))
		pieces.append(mi)
		
	# 3. PHYSICAL TEXTURE: FRAGMENTS (Grey Rock)
	for i in range(FRAGMENT_COUNT):
		var mi = _create_bubble(false, true) # Concrete Grey Rock
		mi.scale = Vector3.ONE * (explosion_scale * 0.15)
		var dir = Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-1.0, 1.0)).normalized()
		velocities.append(dir * SPREAD_SPEED * (explosion_scale * 0.8))
		pieces.append(mi)

func _create_bubble(is_orange: bool, is_rock: bool = false) -> MeshInstance3D:
	var mi = MeshInstance3D.new()
	var sm = SphereMesh.new()
	sm.radial_segments = 8; sm.rings = 4 # Faceted Retro look
	mi.mesh = sm
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
	if is_rock:
		mat.albedo_color = Color(0.533, 0.533, 0.533) # Charcoal Grey
	elif is_orange:
		mat.albedo_color = Color(1.0, 0.53, 0.0) # Orange #FF8800
	else:
		mat.albedo_color = Color(1.0, 0.8, 0.0) # Yellow #FFCC00
		
	mi.material_override = mat
	add_child(mi)
	return mi

func _process(delta: float) -> void:
	elapsed += delta
	# SLOW BILLOW PHYSICS
	for i in range(pieces.size()):
		var mi = pieces[i]
		velocities[i] *= 0.92 # Stellar Drag
		mi.position += velocities[i] * delta
		
	# FADE-OUT SEQUENCE
	if elapsed > FADE_DELAY:
		for mi in pieces:
			if is_instance_valid(mi) and mi.scale.x > 0.01:
				mi.scale = mi.scale.move_toward(Vector3.ZERO, delta * (explosion_scale * 2.0))
			
	if elapsed > LIFETIME:
		queue_free()

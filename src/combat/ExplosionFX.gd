extends Node3D

# ExplosionFX.gd (Zero-Latency MultiMesh Edition)
# THE PROCEDURALIST: Wind Waker-style Cel-Shaded Explosion (Optimized for 60FPS)

const STYLED_SMOKE_COUNT: int = 16 # Total particle count
const LIFETIME: float = 2.4
const FADE_DELAY: float = 0.5
const SPREAD_SPEED: float = 48.0

var explosion_scale: float = 12.0
var elapsed: float = 0.0
var mmi: MultiMeshInstance3D
var velocities: Array[Vector3] = []
var scaling_data: Array[float] = [] # Per-particle scale multipliers
var _v_tick: int = 0
var rng := RandomNumberGenerator.new()

func _ready() -> void:
	rng.randomize()
	_setup_multimesh()

func _setup_multimesh() -> void:
	mmi = MultiMeshInstance3D.new()
	var mm = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true # Toon palette shifts
	
	# LOW-POLY: Faceted sphere (Rule 2)
	var sm = SphereMesh.new()
	sm.radial_segments = 8; sm.rings = 6
	mm.mesh = sm
	
	mm.instance_count = STYLED_SMOKE_COUNT
	mmi.multimesh = mm
	add_child(mmi)
	
	# STYLED MAT: Pure flat unshaded colors (Wind Waker style)
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	
	var out = StandardMaterial3D.new()
	out.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	out.cull_mode = BaseMaterial3D.CULL_FRONT
	out.albedo_color = Color.BLACK
	out.grow = true; out.grow_amount = 0.1
	mat.next_pass = out
	
	mmi.material_override = mat
	
	# INITIALIZE PARTICLES
	for i in range(STYLED_SMOKE_COUNT):
		var dir = Vector3(rng.randf_range(-1,1), rng.randf_range(-1,1), rng.randf_range(-1,1)).normalized()
		velocities.append(dir * SPREAD_SPEED * (rng.randf_range(0.2, 1.2)))
		scaling_data.append(rng.randf_range(0.8, 1.5) * explosion_scale)
		
		# Orange -> Yellow -> Smoke White
		var col = Color(1.0, 0.4, 0.0) 
		if i > (STYLED_SMOKE_COUNT * 0.4): col = Color(1.0, 0.8, 0.0)
		if i > (STYLED_SMOKE_COUNT * 0.7): col = Color(0.9, 0.9, 0.9)
		mm.set_instance_color(i, col)
		
		# Snap to center
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3.ZERO))

func _process(delta: float) -> void:
	# SHADOWGLASS 8FPS SYNC
	var v_t = int(Time.get_ticks_msec() / 125.0)
	var v_update = v_t != _v_tick
	if v_update: _v_tick = v_t
	
	elapsed += delta
	if not v_update: return
	
	var mm = mmi.multimesh
	
	for i in range(STYLED_SMOKE_COUNT):
		var tf = mm.get_instance_transform(i)
		
		# 1. DRAG-AWARE KINETICS
		velocities[i] *= (1.0 - 1.5 * delta)
		tf.origin += velocities[i] * delta
		
		# 2. WIND WAKER SCALING (Bouncy Pop-out -> Late Shrink)
		var sc = scaling_data[i]
		if elapsed < 0.2:
			# Pop-in (Rapid)
			var pop = elapsed / 0.2
			tf.basis = Basis().scaled(Vector3.ONE * sc * pop)
		elif elapsed > FADE_DELAY:
			# Fade-out (Shrink)
			var fade = 1.0 - ((elapsed - FADE_DELAY) / (LIFETIME - FADE_DELAY))
			tf.basis = Basis().scaled(Vector3.ONE * sc * clamp(fade, 0.0, 1.0))
		else:
			tf.basis = Basis().scaled(Vector3.ONE * sc)
			
		mm.set_instance_transform(i, tf)

	if elapsed > LIFETIME:
		queue_free()

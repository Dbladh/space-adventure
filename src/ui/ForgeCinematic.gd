extends Node3D

signal completed()

# ForgeCinematic.gd
# Dramatic planet-forging cinematic: camera pulls back from behind the ship,
# a ball of light grows to nearly fill the screen, then dissipates to reveal
# the new planet. Camera smoothly returns to the player camera when done.

var _target_pos: Vector3
var _player_node: Node3D
var _planet_node: Node3D
var _player_cam: Camera3D
var _cine_cam: Camera3D
var _light_mesh: MeshInstance3D
var _flash_layer: CanvasLayer
var _flash_rect: ColorRect
var _timer: float = 0.0
var _start_cam_xform: Transform3D
var _zoomed_xform: Transform3D
var _max_light_r: float = 1000000.0
var _hidden_layers: Array = []

const DURATION: float = 8.0

func setup(target_pos: Vector3, player_node: Node3D, planet_node: Node3D) -> void:
	_target_pos = target_pos
	_player_node = player_node
	_planet_node = planet_node
	_player_cam = get_viewport().get_camera_3d()

	# Hide the planet until the reveal moment
	_planet_node.hide()

	var world_root = get_tree().get_nodes_in_group("WorldRoot")
	var parent = world_root[0] if world_root.size() > 0 else get_tree().root

	# Capture starting camera transform (behind the ship)
	_start_cam_xform = _player_cam.global_transform

	# ── Compute the zoomed-out camera position ──────────────────────────
	var ship_pos = _player_node.global_position
	var ship_to_planet_dist = _target_pos.distance_to(ship_pos)
	var zoom_dist = clampf(ship_to_planet_dist * 0.2, 2000000.0, 20000000.0)

	# Pull straight back along the ship's backward axis + slight vertical lift.
	# This keeps the ship visible in the foreground, shrinking as we pull out.
	var ship_back = _player_node.global_basis.z
	var zoomed_pos = ship_pos + ship_back * zoom_dist + Vector3.UP * zoom_dist * 0.18

	# Look at a point between the ship and the planet target
	var look_target = ship_pos.lerp(_target_pos, 0.35)

	# ── 1. Cinematic Camera ────────────────────────────────────────────
	_cine_cam = Camera3D.new()
	_cine_cam.far = 400000000.0
	_cine_cam.near = 12.0
	_cine_cam.fov = 70.0
	parent.add_child(_cine_cam)

	# Compute the zoomed-out transform by positioning + look_at
	_cine_cam.global_position = zoomed_pos
	_cine_cam.look_at(look_target, Vector3.UP)
	_zoomed_xform = _cine_cam.global_transform

	# Start from the player camera's exact position
	_cine_cam.global_transform = _start_cam_xform
	_cine_cam.make_current()

	# Light ball max radius: sized so it nearly fills the screen from the
	# zoomed-out camera position (~45% of camera-to-planet distance).
	var cam_to_planet_dist = zoomed_pos.distance_to(_target_pos)
	_max_light_r = cam_to_planet_dist * 0.45

	# ── 2. Light Ball (additive glow sphere) ───────────────────────────
	_light_mesh = MeshInstance3D.new()
	var sm = SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	sm.radial_segments = 32
	sm.rings = 16
	_light_mesh.mesh = sm
	_light_mesh.scale = Vector3.ONE

	var mat = ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = _LIGHT_SHADER
	mat.set_shader_parameter("intensity", 0.0)
	mat.set_shader_parameter("time", 0.0)
	_light_mesh.material_override = mat
	_light_mesh.hide()
	parent.add_child(_light_mesh)
	# Set global_position AFTER add_child — WorldRoot may be shifted by the
	# floating-origin system, so setting global_position before parenting
	# would leave the light at parent_offset + _target_pos (wrong by Mm).
	_light_mesh.global_position = _target_pos

	# ── 3. Screen flash overlay (2D white rect) ───────────────────────
	_flash_layer = CanvasLayer.new()
	_flash_layer.layer = 200
	get_tree().root.add_child(_flash_layer)

	_flash_rect = ColorRect.new()
	_flash_rect.color = Color(1.0, 0.95, 0.85, 0.0)
	_flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash_layer.add_child(_flash_rect)

	# ── 4. Hide HUD layers ────────────────────────────────────────────
	# Track which layers were visible so we can restore THEM specifically —
	# don't blanket-show everything on cleanup or you'll un-hide debug
	# overlays etc. that the user intentionally hid.
	_hidden_layers.clear()
	for c in get_tree().root.get_children():
		if c is CanvasLayer and c != _flash_layer and c.visible:
			c.visible = false
			_hidden_layers.append(c)
	for n in get_tree().get_nodes_in_group("GameHUD"):
		if n is CanvasLayer and n.visible and not _hidden_layers.has(n):
			n.visible = false
			_hidden_layers.append(n)
		elif not (n is CanvasLayer):
			if "visible" in n and n.visible:
				n.visible = false
				_hidden_layers.append(n)


func _process(delta: float) -> void:
	_timer += delta
	var t = clampf(_timer / DURATION, 0.0, 1.0)

	if t >= 1.0:
		_finish()
		return

	# ── Phase timing curves (all smoothstep for butter-smooth easing) ──
	var zoom_out    = smoothstep(0.0,  0.25, t)   # Camera pulls back
	var light_grow  = smoothstep(0.10, 0.50, t)   # Light ball grows
	var light_peak  = smoothstep(0.46, 0.54, t)   # Screen flash builds
	var light_fade  = smoothstep(0.54, 0.70, t)   # Light + flash fade
	var zoom_back   = smoothstep(0.72, 0.97, t)   # Camera returns to ship

	# ── CAMERA ─────────────────────────────────────────────────────────
	if t < 0.72:
		# Zoom out: ease from player camera → zoomed-out position
		_cine_cam.global_transform = _interp_xform(_start_cam_xform, _zoomed_xform, zoom_out)
	else:
		# Zoom back: ease from zoomed-out → current player camera
		# Read the player camera's CURRENT transform (ship may have drifted)
		var player_xform = _player_cam.global_transform
		_cine_cam.global_transform = _interp_xform(_zoomed_xform, player_xform, zoom_back)

	# ── LIGHT BALL ─────────────────────────────────────────────────────
	# light_alive ramps up then back down: grow * (1 - fade)
	var light_alive = light_grow * (1.0 - light_fade)

	if light_grow > 0.001 and light_fade < 0.999:
		_light_mesh.show()
		# sqrt curve: fast initial burst, gradual expansion to max
		var current_r = _max_light_r * pow(light_alive, 0.5)
		_light_mesh.scale = Vector3.ONE * maxf(current_r, 1.0)
		_light_mesh.rotate_y(delta * 1.5)

		var mat = _light_mesh.material_override
		if mat:
			mat.set_shader_parameter("intensity", light_alive * 4.5)
			mat.set_shader_parameter("time", _timer)
	else:
		_light_mesh.hide()

	# ── SCREEN FLASH ───────────────────────────────────────────────────
	# Peaks when light_peak=1 and light_fade=0, fades as light_fade→1
	var flash_alpha = light_peak * (1.0 - light_fade) * 0.85
	_flash_rect.color = Color(1.0, 0.95, 0.85, flash_alpha)

	# ── PLANET REVEAL ──────────────────────────────────────────────────
	# Show the real planet as the flash begins to fade (light still partially
	# visible gives a warm "cooling" glow on the fresh planet surface).
	if t > 0.58 and is_instance_valid(_planet_node) and not _planet_node.visible:
		_planet_node.show()


func _interp_xform(a: Transform3D, b: Transform3D, weight: float) -> Transform3D:
	var q_a = a.basis.get_rotation_quaternion()
	var q_b = b.basis.get_rotation_quaternion()
	return Transform3D(
		Basis(q_a.slerp(q_b, weight)),
		a.origin.lerp(b.origin, weight)
	)


func _finish() -> void:
	# Clean up VFX nodes
	if is_instance_valid(_light_mesh): _light_mesh.queue_free()
	if is_instance_valid(_flash_layer): _flash_layer.queue_free()

	# Snap cinematic camera to player camera before switching, avoiding any
	# visible pop on the handoff frame.
	if is_instance_valid(_player_cam):
		if is_instance_valid(_cine_cam):
			_cine_cam.global_transform = _player_cam.global_transform
		_player_cam.make_current()
	if is_instance_valid(_cine_cam): _cine_cam.queue_free()

	# Restore HUD layers — only the ones we actually hid, preserving any
	# intentional hidden state (debug overlays, FPS labels, etc.)
	for c in _hidden_layers:
		if is_instance_valid(c): c.visible = true
	_hidden_layers.clear()

	# Ensure planet is visible (safety net)
	if is_instance_valid(_planet_node) and not _planet_node.visible:
		_planet_node.show()

	completed.emit()
	queue_free()


# ─────────────────────────────────────────────────────────────────────────────
# LIGHT BALL SHADER
# Additive glowing sphere: hot white core, warm golden mid-glow, subtle blue
# rim, with a gentle energy pulse. Combined with the 2D screen flash overlay,
# this creates the "ball of light that nearly fills the screen" effect.
# ─────────────────────────────────────────────────────────────────────────────
const _LIGHT_SHADER: String = """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

uniform float intensity : hint_range(0.0, 10.0) = 0.0;
uniform float time = 0.0;

void fragment() {
	// Fresnel: 1.0 at center (normal faces camera), 0.0 at silhouette edges
	float d = max(dot(NORMAL, VIEW), 0.0);

	// Core: tight hot-white center
	float core = pow(d, 5.0);
	// Mid: warm golden glow
	float glow = pow(d, 1.5);
	// Rim: faint blue corona at the edges
	float rim = pow(1.0 - d, 3.0) * 0.35;

	// Subtle energy pulse (two frequencies for organic feel)
	float pulse = 1.0 + sin(time * 8.0) * 0.1 + sin(time * 13.0) * 0.05;

	vec3 white = vec3(1.0, 0.97, 0.92);
	vec3 gold  = vec3(1.0, 0.82, 0.35);
	vec3 blue  = vec3(0.5, 0.7, 1.0);

	vec3 col = white * core * 3.0 + gold * glow * 1.5 + blue * rim;
	ALBEDO = col * intensity * pulse;
	ALPHA = clamp((core * 2.0 + glow * 0.6 + rim) * intensity, 0.0, 1.0);
}
"""

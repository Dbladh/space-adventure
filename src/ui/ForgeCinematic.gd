extends Node

signal completed()

# ForgeCinematic.gd — full forge sequence.
#
# 1. Camera rotates in place to face the new planet (smooth eased slerp)
# 2. Lens-zoom FOV narrows, with a slight overshoot for cinematic feel
# 3. White flash peaks; planet revealed and scales in with elastic ease-out
# 4. Camera shake punches the flash impact
# 5. Time dilation slows gameplay around the flash
# 6. Camera holds with subtle drift, planet name + rank label fades in
# 7. Camera rotates back, FOV widens, label fades out, audio restored.
#
# All driven off real wall-clock time so Engine.time_scale changes don't
# warp the cinematic itself.

var _player_node: Node3D
var _planet_node: Node3D
var _target_pos: Vector3
var _camera: Camera3D
var _flash_layer: CanvasLayer
var _flash_rect: ColorRect
var _letterbox_top: ColorRect
var _letterbox_bot: ColorRect
var _label_root: VBoxContainer
var _name_label: Label
var _rank_label: Label
var _hidden_huds: Array = []

var _start_basis: Basis
var _end_basis: Basis

# Player ship rotation. We turn the ship itself to face the planet so the
# cam-spring naturally frames the shot and the player ends the cinematic
# already pointing at the new world.
var _ship_start_basis: Basis
var _ship_end_basis: Basis

var _start_fov: float = 65.0
var _zoom_fov: float = 12.0
var _overshoot_fov: float = 9.0  # tighter than zoom_fov so we ease back
var _shake_seed: int = 0
var _drift_basis: Basis  # base for the slow drift during hold

# The camera's local transform on cam_spring at setup time, so we can ease
# back to it cleanly on cinematic end.
var _camera_local_at_start: Transform3D = Transform3D.IDENTITY

# Real-time tracking so Engine.time_scale doesn't warp the cinematic.
var _start_ms: int = 0

# Resource handles for cleanup.
var _build_player: AudioStreamPlayer = null
var _impact_player: AudioStreamPlayer = null
var _music_bus_idx: int = -1
var _music_orig_db: float = 0.0
var _orig_time_scale: float = 1.0
var _impostor_target_scale: Vector3 = Vector3.ONE

const DURATION    : float = 8.5
const T_TURN_END  : float = 0.30
const T_OVERSHOOT_SETTLE : float = 0.42  # FOV eases from overshoot → zoom
const T_FLASH     : float = 0.45
const T_REVEAL_END: float = 0.62  # planet scale-in finishes
const T_HOLD_END  : float = 0.85  # held longer for the name + rank to read
const T_DONE      : float = 1.00


static func _ease_in_out_cubic(x: float) -> float:
	if x < 0.5:
		return 4.0 * x * x * x
	var f := -2.0 * x + 2.0
	return 1.0 - (f * f * f) * 0.5


static func _ease_out_elastic(x: float) -> float:
	if x <= 0.0: return 0.0
	if x >= 1.0: return 1.0
	var c4 := (2.0 * PI) / 3.0
	return pow(2.0, -10.0 * x) * sin((x * 10.0 - 0.75) * c4) + 1.0


func setup(target_pos: Vector3, player_node: Node3D, planet_node: Node3D, _ignored = null) -> void:
	_target_pos = target_pos
	_player_node = player_node
	_planet_node = planet_node
	_camera = get_viewport().get_camera_3d()
	_start_ms = Time.get_ticks_msec()
	_shake_seed = randi()

	if not is_instance_valid(_camera):
		completed.emit()
		queue_free()
		return

	_start_basis = _camera.global_transform.basis
	_start_fov = _camera.fov
	_camera_local_at_start = _camera.transform  # local, relative to cam_spring
	var origin: Vector3 = _camera.global_transform.origin

	# ── Ship rotation target: ship's -Z points at the planet ──────────
	# Use WORLD up as the reference so the ship lands level rather than
	# inheriting whatever roll it currently has — this also prevents the
	# planet from ending up off-centre under the narrow zoom FOV.
	_ship_start_basis = _player_node.global_transform.basis
	var ship_pos: Vector3 = _player_node.global_position
	var ship_to_planet: Vector3 = (_target_pos - ship_pos).normalized()
	var world_up := Vector3.UP
	if abs(world_up.dot(ship_to_planet)) > 0.99:
		world_up = Vector3.RIGHT
	var ship_look_xform := Transform3D(Basis(), ship_pos).looking_at(_target_pos, world_up)
	_ship_end_basis = ship_look_xform.basis

	# ── Camera look-at-planet basis (same world-up reference) ─────────
	var to_planet_dir: Vector3 = (_target_pos - origin).normalized()
	var cam_up := Vector3.UP
	if abs(cam_up.dot(to_planet_dir)) > 0.99:
		cam_up = Vector3.RIGHT
	var look_xform := Transform3D(Basis(), origin).looking_at(_target_pos, cam_up)
	_end_basis = look_xform.basis

	# ── Lens zoom amount: planet fills ~70% of frame on hold ──────────
	var planet_r: float = 800000.0
	if is_instance_valid(_planet_node) and _planet_node.get("planet_radius") != null:
		planet_r = float(_planet_node.get("planet_radius"))
	var dist_to_planet: float = origin.distance_to(_target_pos)
	if dist_to_planet > planet_r * 1.5:
		var apparent_diameter_deg: float = rad_to_deg(2.0 * atan(planet_r / dist_to_planet))
		_zoom_fov = clampf(apparent_diameter_deg / 0.7, 6.0, 35.0)
	else:
		_zoom_fov = 35.0
	_overshoot_fov = max(_zoom_fov - 3.0, 5.0)  # slightly tighter than zoom_fov

	# ── Hide planet until the flash ──────────────────────────────────
	if is_instance_valid(_planet_node):
		_planet_node.hide()

	# ── HUD hide ─────────────────────────────────────────────────────
	_hidden_huds.clear()
	for n in get_tree().get_nodes_in_group("GameHUD"):
		if "visible" in n and n.visible:
			n.visible = false
			_hidden_huds.append(n)

	# ── Pause player ─────────────────────────────────────────────────
	if is_instance_valid(_player_node):
		_player_node.set_process(false)
		_player_node.set_physics_process(false)

	# ── CanvasLayer for cinematic overlays (flash, letterbox, label) ──
	_flash_layer = CanvasLayer.new()
	_flash_layer.layer = 200
	_flash_layer.process_mode = Node.PROCESS_MODE_ALWAYS  # survive time_scale = 0
	get_tree().root.add_child(_flash_layer)

	# Letterbox bars — animate in.
	_letterbox_top = ColorRect.new()
	_letterbox_top.color = Color(0, 0, 0, 1)
	_letterbox_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_letterbox_top.size.y = 0.0
	_flash_layer.add_child(_letterbox_top)
	_letterbox_bot = ColorRect.new()
	_letterbox_bot.color = Color(0, 0, 0, 1)
	_letterbox_bot.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_letterbox_bot.size.y = 0.0
	_letterbox_bot.position.y = get_viewport().get_visible_rect().size.y
	_flash_layer.add_child(_letterbox_bot)

	# Planet name + rank label.
	_label_root = VBoxContainer.new()
	_label_root.alignment = BoxContainer.ALIGNMENT_CENTER
	_label_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label_root.modulate = Color(1, 1, 1, 0)
	_label_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_layer.add_child(_label_root)

	var planet_name := "PLANET"
	if is_instance_valid(_planet_node):
		planet_name = String(_planet_node.name).replace("Planet_", "").replace("_", " ").to_upper()
	_name_label = Label.new()
	_name_label.text = planet_name
	_name_label.add_theme_font_size_override("font_size", 96)
	_name_label.add_theme_color_override("font_color", Color(1, 0.97, 0.85))
	_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_name_label.add_theme_constant_override("outline_size", 8)
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label_root.add_child(_name_label)

	var rank_text := ""
	var rank_color := Color(0.9, 0.9, 0.9)
	if is_instance_valid(_planet_node) and _planet_node.get("planet_rank") != null:
		var rank_label_str := String(_planet_node.get("planet_rank"))
		if rank_label_str != "":
			rank_text = "RANK " + rank_label_str
			# Map rank → color (mirror PlanetSeedKitchen.rank_planet).
			match rank_label_str:
				"★ LEGENDARY": rank_color = Color(1.0, 0.55, 0.05)
				"SS":          rank_color = Color(0.95, 0.2, 0.9)
				"S":           rank_color = Color(0.35, 0.85, 1.0)
				"A":           rank_color = Color(0.45, 1.0, 0.45)
				"B":           rank_color = Color(0.55, 0.55, 1.0)
				"C":           rank_color = Color(0.85, 0.85, 0.85)
				"D":           rank_color = Color(0.6, 0.55, 0.45)
				_:             rank_color = Color(0.5, 0.5, 0.5)
	_rank_label = Label.new()
	_rank_label.text = rank_text
	_rank_label.add_theme_font_size_override("font_size", 64)
	_rank_label.add_theme_color_override("font_color", rank_color)
	_rank_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	_rank_label.add_theme_constant_override("outline_size", 6)
	_rank_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label_root.add_child(_rank_label)

	# Flash overlay (added LAST so it sits above the letterbox + label).
	_flash_rect = ColorRect.new()
	_flash_rect.color = Color(1.0, 0.95, 0.85, 0.0)
	_flash_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_layer.add_child(_flash_rect)

	# ── Audio: buildup rumble + impact boom + music duck ──────────────
	_orig_time_scale = Engine.time_scale
	_music_bus_idx = AudioServer.get_bus_index("Music")
	if _music_bus_idx >= 0:
		_music_orig_db = AudioServer.get_bus_volume_db(_music_bus_idx)
		AudioServer.set_bus_volume_db(_music_bus_idx, _music_orig_db - 10.0)

	# Buildup rumble — atmosphere stream, low-pitched, fades in over rotate.
	var rumble = load("res://assets/resources/audio/ship_enter_atmosphere.mp3")
	if rumble:
		_build_player = AudioStreamPlayer.new()
		_build_player.stream = rumble
		_build_player.volume_db = -8.0
		_build_player.pitch_scale = 0.7
		_build_player.bus = "Master"
		_build_player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_build_player)
		_build_player.play()

	# Impact boom — fired at flash peak inside _process.
	var boom = load("res://assets/resources/audio/explosion_big.mp3")
	if boom:
		_impact_player = AudioStreamPlayer.new()
		_impact_player.stream = boom
		_impact_player.volume_db = 0.0
		_impact_player.pitch_scale = 0.85  # slightly lower for weight
		_impact_player.bus = "Master"
		_impact_player.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_impact_player)


func _process(_engine_delta: float) -> void:
	if not is_instance_valid(_camera):
		_finish()
		return

	# Real-time progression so Engine.time_scale doesn't warp the cinematic.
	var elapsed: float = (Time.get_ticks_msec() - _start_ms) / 1000.0
	var t: float = clampf(elapsed / DURATION, 0.0, 1.0)
	if t >= 1.0:
		_finish()
		return

	# ── PLAYER SHIP ROTATION ─────────────────────────────────────────
	# Rotate the ship's basis from its start orientation to facing the
	# planet during the rotate-in phase, then hold.  We don't rotate it
	# back at the end — the player should end the cinematic already
	# pointed at their new world.
	if is_instance_valid(_player_node):
		var ship_q_start: Quaternion = _ship_start_basis.get_rotation_quaternion()
		var ship_q_end: Quaternion = _ship_end_basis.get_rotation_quaternion()
		if ship_q_start.dot(ship_q_end) < 0.0:
			ship_q_end = -ship_q_end
		var ship_basis: Basis
		if t < T_TURN_END:
			var w: float = _ease_in_out_cubic(clampf(t / T_TURN_END, 0.0, 1.0))
			ship_basis = Basis(ship_q_start.slerp(ship_q_end, w))
		else:
			ship_basis = Basis(ship_q_end)
		var ship_pos: Vector3 = _player_node.global_position
		_player_node.global_transform = Transform3D(ship_basis, ship_pos)

	# Cache origin (camera parent may drift slightly).
	var origin: Vector3 = _camera.global_transform.origin

	# ── BASIS ────────────────────────────────────────────────────────
	var q_start: Quaternion = _start_basis.get_rotation_quaternion()
	var q_end: Quaternion = _end_basis.get_rotation_quaternion()
	if q_start.dot(q_end) < 0.0:
		q_end = -q_end

	var current_basis: Basis
	if t < T_TURN_END:
		var w: float = _ease_in_out_cubic(clampf(t / T_TURN_END, 0.0, 1.0))
		current_basis = Basis(q_start.slerp(q_end, w))
	elif t < T_HOLD_END:
		current_basis = Basis(q_end)
	else:
		# Return phase: slerp camera basis from "looking at planet" toward
		# the cam-spring's natural orientation (cam_spring.global_basis ×
		# camera's original LOCAL basis). Since the ship now faces the
		# planet, this naturally lands the camera behind the ship.
		var w: float = _ease_in_out_cubic(clampf((t - T_HOLD_END) / (T_DONE - T_HOLD_END), 0.0, 1.0))
		var cam_parent: Node = _camera.get_parent()
		var natural_basis: Basis
		if cam_parent is Node3D:
			natural_basis = (cam_parent as Node3D).global_transform.basis * _camera_local_at_start.basis
		else:
			natural_basis = Basis(q_end)
		var q_natural: Quaternion = natural_basis.get_rotation_quaternion()
		if q_end.dot(q_natural) < 0.0:
			q_natural = -q_natural
		current_basis = Basis(q_end.slerp(q_natural, w))

	# Slow drift during hold — small yaw to keep the shot from feeling frozen.
	if t >= T_TURN_END and t < T_HOLD_END:
		var hold_t: float = clampf((t - T_TURN_END) / (T_HOLD_END - T_TURN_END), 0.0, 1.0)
		var drift_yaw: float = sin(hold_t * PI) * deg_to_rad(0.6)
		current_basis = current_basis.rotated(current_basis.y, drift_yaw)

	# Camera shake at the flash — decaying random rotation over ~0.5 sec.
	var shake_t: float = clampf((t - T_FLASH) / 0.06, 0.0, 1.0)  # how far past flash
	var shake_amp: float = max(0.0, 1.0 - (t - T_FLASH) / 0.10) if t >= T_FLASH else 0.0
	if shake_amp > 0.0:
		var rng := RandomNumberGenerator.new()
		rng.seed = _shake_seed + int(elapsed * 60.0)  # change every frame
		var sx := rng.randf_range(-1.0, 1.0) * shake_amp * deg_to_rad(2.0)
		var sy := rng.randf_range(-1.0, 1.0) * shake_amp * deg_to_rad(2.0)
		current_basis = current_basis.rotated(current_basis.x, sx)
		current_basis = current_basis.rotated(current_basis.y, sy)

	_camera.global_transform = Transform3D(current_basis, origin)

	# ── FOV (with overshoot then settle) ──────────────────────────────
	if t < T_TURN_END:
		var w: float = _ease_in_out_cubic(clampf(t / T_TURN_END, 0.0, 1.0))
		_camera.fov = lerpf(_start_fov, _overshoot_fov, w)
	elif t < T_OVERSHOOT_SETTLE:
		var w: float = _ease_in_out_cubic(clampf((t - T_TURN_END) / (T_OVERSHOOT_SETTLE - T_TURN_END), 0.0, 1.0))
		_camera.fov = lerpf(_overshoot_fov, _zoom_fov, w)
	elif t < T_HOLD_END:
		_camera.fov = _zoom_fov
	else:
		var w: float = _ease_in_out_cubic(clampf((t - T_HOLD_END) / (T_DONE - T_HOLD_END), 0.0, 1.0))
		_camera.fov = lerpf(_zoom_fov, _start_fov, w)

	# ── FLASH ─────────────────────────────────────────────────────────
	var flash_alpha: float = smoothstep(T_FLASH - 0.06, T_FLASH, t) \
			* (1.0 - smoothstep(T_FLASH, T_FLASH + 0.20, t))
	_flash_rect.color = Color(1.0, 0.95, 0.85, flash_alpha * 0.95)

	# ── PLANET REVEAL + SCALE-IN ──────────────────────────────────────
	if t >= T_FLASH and is_instance_valid(_planet_node):
		# First-frame reveal.
		if not _planet_node.visible:
			_planet_node.show()
			if _planet_node.has_method("_ensure_impostor_active"):
				_planet_node.call("_ensure_impostor_active", true)
			# Fire the impact boom + dip time scale.
			if _impact_player and not _impact_player.playing:
				_impact_player.play()
			Engine.time_scale = 0.35
			# Capture impostor's natural scale so we can grow back to it.
			var impostor = _planet_node.get("impostor")
			if impostor is Node3D:
				_impostor_target_scale = impostor.scale

		# Restore time scale just after the flash settles.
		if Engine.time_scale != _orig_time_scale and t > T_FLASH + 0.06:
			Engine.time_scale = _orig_time_scale

		# Elastic-out scale on the impostor for the birth pop.
		var reveal_t: float = clampf((t - T_FLASH) / (T_REVEAL_END - T_FLASH), 0.0, 1.0)
		var s := _ease_out_elastic(reveal_t)
		var impostor_node = _planet_node.get("impostor")
		if impostor_node is Node3D:
			impostor_node.scale = _impostor_target_scale * maxf(s * 0.9 + 0.1, 0.05)

	# ── LETTERBOX BARS ────────────────────────────────────────────────
	var bar_target: float = 90.0
	var bar_t: float
	if t < 0.10:
		bar_t = smoothstep(0.0, 0.10, t)
	elif t > T_DONE - 0.10:
		bar_t = 1.0 - smoothstep(T_DONE - 0.10, T_DONE, t)
	else:
		bar_t = 1.0
	var bar_h: float = bar_target * bar_t
	if is_instance_valid(_letterbox_top):
		_letterbox_top.size.y = bar_h
	if is_instance_valid(_letterbox_bot):
		_letterbox_bot.size.y = bar_h
		_letterbox_bot.position.y = get_viewport().get_visible_rect().size.y - bar_h

	# ── NAME + RANK LABEL ─────────────────────────────────────────────
	var label_alpha: float
	if t < T_FLASH:
		label_alpha = 0.0
	elif t < T_FLASH + 0.18:
		label_alpha = smoothstep(T_FLASH, T_FLASH + 0.18, t)
	elif t < T_HOLD_END - 0.05:
		label_alpha = 1.0
	else:
		label_alpha = 1.0 - smoothstep(T_HOLD_END - 0.05, T_HOLD_END + 0.05, t)
	if is_instance_valid(_label_root):
		_label_root.modulate.a = clampf(label_alpha, 0.0, 1.0)

	# ── BUILDUP RUMBLE FADE ───────────────────────────────────────────
	if _build_player and _build_player.playing:
		# Ramp up slightly through the rotate-in, then fade after flash.
		if t < T_FLASH:
			_build_player.volume_db = lerpf(-12.0, -3.0, t / T_FLASH)
		else:
			_build_player.volume_db = lerpf(-3.0, -30.0, clampf((t - T_FLASH) / 0.15, 0.0, 1.0))
			if t > T_FLASH + 0.15 and _build_player.playing:
				_build_player.stop()


func _finish() -> void:
	# Time scale safety.
	Engine.time_scale = _orig_time_scale

	# Restore HUD.
	for n in _hidden_huds:
		if is_instance_valid(n):
			n.visible = true
	_hidden_huds.clear()

	# Restore player processing.
	if is_instance_valid(_player_node):
		_player_node.set_process(true)
		_player_node.set_physics_process(true)

	# Restore camera FOV + reset its local transform so it follows cam_spring
	# naturally from here on (the ship is now facing the planet, so the
	# camera ends up behind the ship pointed at the new world).
	if is_instance_valid(_camera):
		_camera.fov = _start_fov
		_camera.transform = _camera_local_at_start
	if is_instance_valid(_planet_node):
		_planet_node.show()
		if _planet_node.has_method("_ensure_impostor_active"):
			_planet_node.call("_ensure_impostor_active", true)
		var impostor_node = _planet_node.get("impostor")
		if impostor_node is Node3D:
			impostor_node.scale = _impostor_target_scale

	# Restore music bus.
	if _music_bus_idx >= 0:
		AudioServer.set_bus_volume_db(_music_bus_idx, _music_orig_db)

	# Tear down overlays + audio nodes.
	if is_instance_valid(_flash_layer):
		_flash_layer.queue_free()
	if is_instance_valid(_build_player):
		_build_player.stop()
		_build_player.queue_free()
	if is_instance_valid(_impact_player):
		_impact_player.queue_free()

	completed.emit()
	queue_free()

extends Node

# StartScreen.gd
# Boot scene shown before the main game. Renders a procedural 3D starfield +
# 3-5 decorative planets into a low-res SubViewport so the background reads
# as chunky retro pixel art, then overlays the title logo + menu buttons at
# native resolution. Continue is hidden when no save exists.

const HUDStyle = preload("res://src/ui/HUDStyle.gd")
const SettingsPanelScript = preload("res://src/ui/SettingsPanel.gd")
const _PLANET_SHADER = preload("res://src/shaders/background_planet.gdshader")
const _RING_SHADER = preload("res://src/shaders/background_ring.gdshader")
const _STAR_SHADER = preload("res://src/shaders/background_star.gdshader")
const _MILKYWAY_SHADER = preload("res://src/shaders/background_milkyway.gdshader")
# Same post-process the main game uses (Main.gd:1102). Pixelation + Bayer
# dither + 5-step palette banding + shadow tint — applied as a top CanvasLayer
# so the start screen reads identically to the in-game world.
const _RETRO_SHADER = preload("res://src/world/retro_vfx.gdshader")

# Background tint pool — mirrors the variety of nebula zones the player flies
# through in-game. Picked randomly per session so each launch feels like a
# different patch of space.
#
# IMPORTANT: tints must have luminance >= ~0.4 to survive the retro_vfx
# shadow tint pass (which fully replaces any pixel with lum < 0.4 with the
# deep-purple shadow colour). Below that threshold every session reads as
# the same purple-black no matter the source hue. Values here target
# lum 0.3–0.5 so the hue character carries through the dither + palette
# crush instead of getting flattened.
const _SKY_TINTS: Array[Color] = [
	Color(0.20, 0.20, 0.55),   # starlit blue
	Color(0.50, 0.20, 0.55),   # vivid violet nebula
	Color(0.15, 0.45, 0.55),   # cyan aurora
	Color(0.60, 0.30, 0.15),   # ember dust
	Color(0.20, 0.55, 0.30),   # emerald cloud
	Color(0.55, 0.15, 0.30),   # crimson void
	Color(0.40, 0.20, 0.55),   # cosmic indigo
	Color(0.50, 0.45, 0.15),   # ochre dust
	Color(0.20, 0.35, 0.60),   # twilight steel
	Color(0.55, 0.30, 0.50),   # cosmic pink
]

const GAMEPLAY_SCENE: String = "res://node_3d.tscn"
const SAVE_PATH: String = "user://save.json"
const LOGO_PATH: String = "res://assets/logo/game_logo.png"

# Archetype palette pool for the start screen — restricted to the high-
# saturation archetypes from PlanetGen. FROZEN / ALPINE / BARREN / ASH look
# correct in-game (intentionally pale ice + dust worlds), but a menu full of
# snowballs reads as washed out. Pure show-stoppers only here.
const _ARCHETYPES: Array[String] = [
	"VOLCANIC", "CANDY", "TOXIC", "JUNGLE", "AMETHYST", "CORAL",
	"AURORA", "CRYSTAL", "LUSH", "DESERT",
]

var _scene_3d: Node3D = null
var _settings_panel: SettingsPanel = null
var _settings_layer: Control = null
var _confirm_layer: Control = null
var _ui_layer: CanvasLayer = null
var _retro_layer: CanvasLayer = null
# Sits above the retro post-process so interactive UI (menu buttons, settings
# panel, confirm modals) renders crisp — the chunky pixelation + dither only
# applies to the 3D world + logo below it.
var _overlay_layer: CanvasLayer = null
var _has_save: bool = false
var _is_mobile_ui: bool = MobilePerf.is_mobile()
var _sky_tint: Color = Color(0.04, 0.05, 0.14)

# ─── Scrolling background ─────────────────────────────────────────────────
# Stars sit in a wide horizontal slab. We translate the parent node leftward
# every frame and wrap when it crosses the slab half-width so the field reads
# as continuously drifting. The Milky Way scrolls via its shader's TIME uniform.
const _STAR_SLAB_WIDTH: float = 700.0   # half-width; full slab spans ±700 in X
var _starfield: MultiMeshInstance3D = null
var _milkyway: MeshInstance3D = null
const _STAR_SCROLL_SPEED: float = 4.0   # world units / second

# ─── Parallax state ───────────────────────────────────────────────────────
# Each planet stores its base position + a per-depth multiplier so the camera
# tilt translates into a small position shift, with closer planets moving
# more (foreground reads as parallax against the deep background).
var _parallax_planets: Array = []   # [{node, base_pos, depth_factor}, ...]
var _parallax_camera: Camera3D = null
var _parallax_cam_base: Vector3 = Vector3.ZERO
# UI parallax targets — title + button column shift gently along with the scene.
# We cache the original anchor offsets and add a delta each frame, because
# Controls in Godot 4 are positioned via offset_left/right/top/bottom (writing
# `position` directly gets clobbered on the next layout pass).
var _parallax_title: Control = null
var _parallax_buttons: Control = null
var _parallax_title_offsets: Vector4 = Vector4.ZERO   # (left, top, right, bottom)
var _parallax_buttons_offsets: Vector4 = Vector4.ZERO
# Smoothed tilt vector in -1..1 range; lerps toward the live target each frame
# so motion feels weighted instead of jittering.
var _tilt: Vector2 = Vector2.ZERO
var _tilt_target: Vector2 = Vector2.ZERO


func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	set_process(true)
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	_has_save = FileAccess.file_exists(SAVE_PATH)
	_sky_tint = _SKY_TINTS[rng.randi() % _SKY_TINTS.size()]

	_scene_3d = Node3D.new()
	add_child(_scene_3d)
	_spawn_environment(_scene_3d)
	_spawn_milkyway(_scene_3d, rng)
	_spawn_starfield(_scene_3d, rng)
	_spawn_planets(_scene_3d, rng)
	_build_ui()
	_build_retro_post()


# Top CanvasLayer running the same retro_vfx shader the main game uses
# (Main.gd:1102) — pixelation + 8×8 Bayer dither + 5-step palette banding
# + shadow tint. Sits above the 3D world + logo so they read as retro pixel
# art. Interactive UI (buttons, modals) lives on `_overlay_layer` above
# this, so it renders crisp and stays readable.
func _build_retro_post() -> void:
	_retro_layer = CanvasLayer.new()
	_retro_layer.layer = 110
	add_child(_retro_layer)
	var rect := ColorRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = _RETRO_SHADER
	rect.material = mat
	_retro_layer.add_child(rect)


# ─── World setup ──────────────────────────────────────────────────────────

func _spawn_environment(host: Node) -> void:
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	# Per-session nebula tint — picked once in _ready from a curated palette.
	# The retro_vfx top layer dithers + bands this base colour so it reads
	# like an actual nebula zone rather than a flat fill.
	env.background_color = _sky_tint
	# Minimal ambient — strong ambient turned planets into pastel washes.
	# A near-zero ambient lets the planet shader's own emission carry the colour.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.28, 0.42)
	env.ambient_light_energy = 0.12
	# LINEAR tonemap — matches the main game's setting (Main.gd:166). Both
	# FILMIC and AGX compress highlights, which silently desaturates the
	# bright continent colours. Linear keeps the palette pure.
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	env.tonemap_white = 1.0
	# Lower glow than the first pass — strong bloom washes saturated pixels
	# toward white, sapping the palette pop we just unlocked with LINEAR.
	# A touch of glow keeps the galaxy core / planet highlights luminous
	# without bleaching the colour off the planet bodies.
	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_bloom = 0.05
	# Glow only fires on actually-bright pixels — the threshold keeps the
	# fully-lit planet faces out of the bloom pass so they stay saturated.
	env.glow_hdr_threshold = 1.0
	env.glow_hdr_scale = 2.0
	env_node.environment = env
	host.add_child(env_node)

	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.5, 16)
	cam.rotation_degrees = Vector3(-5, 0, 0)
	cam.fov = 55
	cam.far = 2000.0
	host.add_child(cam)
	cam.current = true
	_parallax_camera = cam
	_parallax_cam_base = cam.position

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-25, 35, 0)
	key.light_energy = 1.2
	key.light_color = Color(1.0, 0.95, 0.85)
	host.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(20, -150, 0)
	fill.light_energy = 0.25
	fill.light_color = Color(0.55, 0.65, 1.0)
	host.add_child(fill)


func _spawn_starfield(host: Node, rng: RandomNumberGenerator) -> void:
	# Stars laid out in a wide horizontal slab so we can scroll the whole
	# field leftward and wrap seamlessly at the slab boundary. Mobile gets
	# fewer to stay easy on the GPU.
	var star_count: int = 350 if _is_mobile_ui else 650
	var starfield := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = star_count
	var quad := QuadMesh.new()
	# Tiny quad — after 1/3 SubViewport pixelation each star resolves to a
	# chunky single-pixel block on screen, like Asteroids.
	quad.size = Vector2(0.55, 0.55)
	mm.mesh = quad
	# Slab dimensions: wide on X (so scroll has room to wrap), Y/Z keep the
	# parallax sphere-ish feel.
	for i in range(star_count):
		var x: float = rng.randf_range(-_STAR_SLAB_WIDTH, _STAR_SLAB_WIDTH)
		var y: float = rng.randf_range(-220.0, 220.0)
		var z: float = rng.randf_range(-350.0, -150.0)
		var pos := Vector3(x, y, z)
		var star_basis := Basis.looking_at(-pos.normalized(), Vector3.UP).orthonormalized()
		var s_scale: float = rng.randf_range(0.7, 1.6)
		var xf := Transform3D(star_basis, pos).scaled_local(Vector3.ONE * s_scale)
		mm.set_instance_transform(i, xf)
		var t := rng.randf()
		var col := Color(0.95, 0.95, 1.0)
		if t < 0.15: col = Color(0.78, 0.92, 1.0)   # blue giants
		elif t > 0.85: col = Color(1.0, 0.88, 0.65) # yellow / red dwarfs
		col.a = rng.randf_range(0.6, 1.0)
		mm.set_instance_color(i, col)
	starfield.multimesh = mm
	_starfield = starfield

	# Custom twinkle shader — phase-shifts the per-instance brightness so the
	# field shimmers asynchronously. Additive blend keeps stars pure against
	# the dark background regardless of the FILMIC tonemap.
	var star_mat := ShaderMaterial.new()
	star_mat.shader = _STAR_SHADER
	star_mat.set_shader_parameter("twinkle_speed", 2.2)
	star_mat.set_shader_parameter("min_alpha", 0.20)
	star_mat.set_shader_parameter("emission_strength", 1.6)
	starfield.material_override = star_mat
	host.add_child(starfield)


func _spawn_milkyway(host: Node, rng: RandomNumberGenerator) -> void:
	# Spiral galaxy backdrop — sits as a focal element directly behind the
	# title logo. Square plane so the spiral isn't stretched. Camera-facing
	# so the shader's polar maths just works.
	var mw := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	# Sized to read as the hero element of the background. The shader handles
	# its own radial falloff so the edges fade rather than hard-clipping.
	var galaxy_size: float = 460.0
	plane.size = Vector2(galaxy_size, galaxy_size)
	mw.mesh = plane
	# Locked to screen-centre horizontally and biased upward so the spiral
	# core lands directly behind the title logo. At z=-380 it sits well
	# behind the planets (which span z=-12..+6) but in front of the starfield.
	mw.position = Vector3(0.0, 85.0, -380.0)
	# Rotate -90° around X so plane faces the camera (PlaneMesh defaults to
	# +Y normal; -90° around X swings it to face -Z = camera).
	mw.rotation_degrees = Vector3(-90, 0, 0)

	var mat := ShaderMaterial.new()
	mat.shader = _MILKYWAY_SHADER
	# Per-session randomisation so the galaxy looks different each launch.
	mat.set_shader_parameter("arm_count", float(rng.randi_range(2, 4)))
	mat.set_shader_parameter("arm_twist", rng.randf_range(5.5, 8.5))
	mat.set_shader_parameter("core_radius", rng.randf_range(0.14, 0.22))
	mat.set_shader_parameter("falloff", rng.randf_range(3.0, 3.8))
	# Intensity capped so the additive-blended galaxy doesn't push arm colours
	# past 1.0 and clip to white — keeps the cyan / purple character readable.
	mat.set_shader_parameter("intensity", rng.randf_range(1.1, 1.5))
	# Visibly spinning over a menu visit — at 0.12–0.18 rad/sec a full
	# rotation completes in ~35–50s, so the motion reads as live without
	# being distracting or motion-sick inducing.
	mat.set_shader_parameter("rotation_speed", rng.randf_range(0.12, 0.18))
	mat.set_shader_parameter("phase_offset", rng.randf() * TAU)
	# Palette: bright cyan + purple per the reference, with subtle variation
	# in hue so each session reads differently without losing the look.
	var core := Color.from_hsv(rng.randf_range(0.45, 0.55), rng.randf_range(0.10, 0.25), 1.0)
	var arm_a := Color.from_hsv(rng.randf_range(0.48, 0.55), rng.randf_range(0.75, 0.90), rng.randf_range(0.85, 1.0))
	var arm_b := Color.from_hsv(rng.randf_range(0.74, 0.82), rng.randf_range(0.70, 0.90), rng.randf_range(0.80, 1.0))
	var outer := Color.from_hsv(rng.randf_range(0.72, 0.80), rng.randf_range(0.70, 0.90), rng.randf_range(0.55, 0.75))
	mat.set_shader_parameter("core_color", _color_to_vec3(core))
	mat.set_shader_parameter("arm_color_a", _color_to_vec3(arm_a))
	mat.set_shader_parameter("arm_color_b", _color_to_vec3(arm_b))
	mat.set_shader_parameter("outer_color", _color_to_vec3(outer))
	mw.material_override = mat
	host.add_child(mw)
	_milkyway = mw


func _spawn_planets(host: Node, rng: RandomNumberGenerator) -> void:
	# Fixed-region layout so each screen quadrant gets a planet — the previous
	# random shuffle could cluster all picks into one part of the screen.
	# Per-session variety comes from the jitter below + the per-planet
	# archetype/colour/ring rolls in _make_planet.
	#
	# Slot 4 sits far back centre-right (out of the title + button column) to
	# add depth without crowding the UI now that the galaxy + bigger logo
	# occupy the upper-centre region.
	# Positions chosen so each planet sits in a different screen region and
	# stays clear of the title (upper-centre, now occupied by the galaxy +
	# logo) and the button column (middle-centre). Upper slots are pushed
	# wider; the bottom-right slot is lowered so it sits below the buttons.
	var slots: Array = [
		{"pos": Vector3(-7.5, -2.5, 6.0), "radius": 3.8},   # bottom-left hero (foreground)
		{"pos": Vector3(11.0, 3.0, -2.5), "radius": 2.4},   # upper-right mid-foreground
		{"pos": Vector3(-12.0, 3.5, -6.0), "radius": 1.8},  # upper-left mid
		{"pos": Vector3(11.0, -5.0, -6.0), "radius": 1.9},  # bottom-right mid (below buttons)
		{"pos": Vector3(1.0, -7.0, -16.0), "radius": 1.0},  # bottom-centre far back
	]
	for slot in slots:
		# Subtle per-session jitter so positions feel fresh without leaving
		# the slot's screen region.
		var jitter := Vector3(
			rng.randf_range(-0.8, 0.8),
			rng.randf_range(-0.6, 0.6),
			rng.randf_range(-1.5, 1.5),
		)
		_make_planet(host, slot["pos"] + jitter, slot["radius"], rng)


func _make_planet(host: Node, pos: Vector3, radius: float, rng: RandomNumberGenerator) -> void:
	var planet := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	# Lower poly than the in-game planets — the pixelation hides any faceting.
	sphere.radial_segments = 32
	sphere.rings = 16
	planet.mesh = sphere
	planet.position = pos

	var mat := ShaderMaterial.new()
	mat.shader = _PLANET_SHADER

	var archetype: String = _ARCHETYPES[rng.randi() % _ARCHETYPES.size()]
	var palette := _palette_for_archetype(archetype, rng)
	mat.set_shader_parameter("color_water", _color_to_vec3(palette.water))
	mat.set_shader_parameter("color_land",  _color_to_vec3(palette.land))
	mat.set_shader_parameter("color_high",  _color_to_vec3(palette.high))
	mat.set_shader_parameter("color_atmo",  _color_to_vec3(palette.atmo))
	mat.set_shader_parameter("seed", rng.randf() * 60.0)
	# Wider noise scale range — bigger numbers = more, smaller continents, like
	# the chunky continents on the in-game planets.
	mat.set_shader_parameter("noise_scale", rng.randf_range(1.6, 3.2))
	mat.set_shader_parameter("sea_level", rng.randf_range(0.42, 0.6))
	# Razor-thin coastline (0.012–0.025) so land and water read as distinct
	# colour blocks through the pixelation, matching the game-world planets.
	mat.set_shader_parameter("coast_sharpness", rng.randf_range(0.012, 0.025))
	var cloud_low: float = 0.0
	var cloud_high: float = 0.45
	if archetype == "FROZEN" or archetype == "DESERT":
		cloud_high = 0.15
	mat.set_shader_parameter("cloud_density", rng.randf_range(cloud_low, cloud_high))
	mat.set_shader_parameter("atmo_strength", rng.randf_range(0.55, 0.95))
	mat.set_shader_parameter("spin_rate", rng.randf_range(0.025, 0.065) * (1.0 if rng.randf() < 0.5 else -1.0))
	mat.set_shader_parameter("emission_strength", 0.25 if archetype in ["AURORA", "CRYSTAL"] else 0.0)
	# Vividness pushed past 1.0 to fight tonemap roll-off; explicit saturation
	# bump keeps land + ocean from collapsing into the same pastel hue.
	mat.set_shader_parameter("vividness", rng.randf_range(1.4, 1.75))
	mat.set_shader_parameter("saturation", rng.randf_range(1.4, 1.8))
	planet.material_override = mat

	host.add_child(planet)

	# Register for parallax. Closer planets (larger Z) move noticeably more
	# than distant ones, matching how the player would expect depth to read.
	# depth_factor is normalised against the foreground hero slot's z=6.
	var depth_factor: float = clamp((pos.z + 14.0) / 20.0, 0.15, 1.0)
	_parallax_planets.append({
		"node": planet,
		"base_pos": pos,
		"depth_factor": depth_factor,
	})

	# ~30% planets get a flat Saturn-style ring on a tilted PlaneMesh — much
	# better silhouette than the old TorusMesh which read as a thick tube.
	if rng.randf() < 0.32:
		var ring := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		var ring_outer: float = radius * 2.6
		plane.size = Vector2(ring_outer * 2.0, ring_outer * 2.0)
		ring.mesh = plane
		var rmat := ShaderMaterial.new()
		rmat.shader = _RING_SHADER
		# Dimmer ring colour — was atmo.lightened(0.15) which read as a
		# glowing donut. A slightly darkened palette colour reads as dust.
		rmat.set_shader_parameter("ring_color", _color_to_vec3(palette.atmo.darkened(0.15)))
		rmat.set_shader_parameter("inner_radius", radius * 1.5 / ring_outer)
		rmat.set_shader_parameter("outer_radius", radius * 2.5 / ring_outer)
		# Translucent so the planet behind shows through cleanly.
		rmat.set_shader_parameter("opacity", rng.randf_range(0.28, 0.45))
		rmat.set_shader_parameter("band_density", rng.randf_range(18.0, 38.0))
		# Stronger banding so the ring reads as discrete debris stripes, not a slab.
		rmat.set_shader_parameter("band_strength", 0.35)
		ring.material_override = rmat
		ring.position = pos
		# Tilt away from camera so we see the ring as an ellipse, plus a random
		# yaw so they aren't all aligned the same way.
		ring.rotation_degrees = Vector3(rng.randf_range(70.0, 88.0), rng.randf_range(0.0, 360.0), 0.0)
		host.add_child(ring)
		# Ring rides the same parallax as its host planet so they stay aligned.
		_parallax_planets.append({
			"node": ring,
			"base_pos": pos,
			"depth_factor": clamp((pos.z + 14.0) / 20.0, 0.15, 1.0),
		})


# Same palette rules as PlanetGen so background planets read as game-world bodies.
func _palette_for_archetype(arch: String, rng: RandomNumberGenerator) -> Dictionary:
	var water: Color
	var land: Color
	var high: Color
	var atmo: Color
	match arch:
		"LUSH":
			var h: float = rng.randf_range(0.28, 0.42)
			land = Color.from_hsv(h, 0.65, 0.85)
			high = Color.from_hsv(rng.randf_range(0.05, 0.15), 0.3, 0.5)
			water = Color.from_hsv(0.55, 0.75, 0.8)
			atmo = Color.from_hsv(0.55, 0.4, 1.0)
		"DESERT":
			var h: float = rng.randf_range(0.02, 0.15)
			land = Color.from_hsv(h, 0.7, 0.9)
			high = Color.from_hsv(h, 0.4, 0.6)
			water = Color.from_hsv(0.05, 0.9, 0.4)
			atmo = Color.from_hsv(h, 0.5, 1.0)
		"FROZEN":
			var h: float = rng.randf_range(0.5, 0.65)
			land = Color.from_hsv(h, 0.15, 0.95)
			high = Color.from_hsv(h + 0.1, 0.4, 0.6)
			water = Color.from_hsv(0.6, 0.5, 0.9)
			atmo = Color.from_hsv(0.58, 0.45, 1.0)
		"ALPINE":
			var h: float = rng.randf_range(0.58, 0.62)
			land = Color.from_hsv(h, 0.15, 0.98)
			high = Color.from_hsv(h, 0.4, 0.45)
			water = Color.from_hsv(0.6, 0.8, 0.9)
			atmo = Color.from_hsv(0.6, 0.5, 1.0)
		"VOLCANIC":
			land = Color.from_hsv(0.0, 0.9, 0.5)
			high = Color.from_hsv(0.0, 0.0, 0.15)
			water = Color.from_hsv(0.0, 1.0, 0.45)
			atmo = Color.from_hsv(0.03, 0.85, 1.0)
		"CANDY":
			var h: float = rng.randf_range(0.85, 0.98)
			land = Color.from_hsv(h, 0.45, 0.95)
			high = Color.from_hsv(h, 0.25, 0.7)
			water = Color.from_hsv(0.5, 0.4, 0.9)
			atmo = Color.from_hsv(h, 0.4, 1.0)
		"TOXIC":
			var h: float = rng.randf_range(0.18, 0.28)
			land = Color.from_hsv(h, 0.85, 0.9)
			high = Color.from_hsv(0.8, 0.5, 0.4)
			water = Color.from_hsv(h + 0.2, 0.85, 0.7)
			atmo = Color.from_hsv(h, 0.6, 1.0)
		"SAVANNA":
			var h: float = rng.randf_range(0.13, 0.16)
			land = Color.from_hsv(h, 0.55, 0.85)
			high = Color.from_hsv(0.08, 0.4, 0.5)
			water = Color.from_hsv(0.55, 0.6, 0.7)
			atmo = Color.from_hsv(0.55, 0.4, 1.0)
		"JUNGLE":
			land = Color.from_hsv(0.32, 0.9, 0.7)
			high = Color.from_hsv(0.28, 0.45, 0.4)
			water = Color.from_hsv(0.42, 0.85, 0.45)
			atmo = Color.from_hsv(0.35, 0.5, 1.0)
		"AMETHYST":
			var h: float = rng.randf_range(0.74, 0.82)
			land = Color.from_hsv(h, 0.6, 0.7)
			high = Color.from_hsv(h, 0.7, 0.45)
			water = Color.from_hsv(h + 0.04, 0.7, 0.5)
			atmo = Color.from_hsv(h, 0.5, 1.0)
		"CORAL":
			var h: float = rng.randf_range(0.02, 0.06)
			land = Color.from_hsv(h, 0.7, 0.95)
			high = Color.from_hsv(h + 0.02, 0.5, 0.55)
			water = Color.from_hsv(0.48, 0.7, 0.85)
			atmo = Color.from_hsv(0.48, 0.4, 1.0)
		"AURORA":
			var h: float = rng.randf_range(0.0, 1.0)
			land = Color.from_hsv(h, 0.7, 0.9)
			high = Color.from_hsv(fposmod(h + 0.33, 1.0), 0.65, 0.7)
			water = Color.from_hsv(fposmod(h + 0.66, 1.0), 0.8, 0.7)
			atmo = Color.from_hsv(fposmod(h + 0.5, 1.0), 0.5, 1.0)
		"CRYSTAL":
			var h: float = rng.randf_range(0.0, 1.0)
			land = Color.from_hsv(h, 0.85, 0.85)
			high = Color.from_hsv(fposmod(h + 0.5, 1.0), 0.85, 0.55)
			water = Color.from_hsv(fposmod(h + 0.25, 1.0), 0.7, 0.7)
			atmo = Color.from_hsv(h, 0.55, 1.0)
		_:
			land = Color.from_hsv(rng.randf(), 0.5, 0.7)
			high = land.darkened(0.3)
			water = land.lightened(0.1)
			atmo = Color(0.6, 0.8, 1.0)
	return {"water": water, "land": land, "high": high, "atmo": atmo}


func _color_to_vec3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)


# ─── UI overlay (full resolution, above the pixelated 3D) ─────────────────

func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	# CanvasLayer.follow_viewport stays at native res regardless of the
	# SubViewportContainer's stretch, so the UI is always crisp.
	add_child(_ui_layer)

	# Anchor root that fills the screen — child controls position against this.
	var anchor := Control.new()
	anchor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui_layer.add_child(anchor)

	# Overlay layer sits ABOVE the retro post-process (layer 110) so the
	# interactive UI — menu buttons + any modal that opens — renders crisp
	# instead of being pixelated/dithered alongside the background.
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = 111
	add_child(_overlay_layer)

	var overlay_anchor := Control.new()
	overlay_anchor.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay_anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(overlay_anchor)

	# Resolve logo texture once so we know the title height for layout.
	var logo_tex: Texture2D = null
	if ResourceLoader.exists(LOGO_PATH):
		logo_tex = load(LOGO_PATH) as Texture2D

	# ── TITLE ─────────────────────────────────────────────────────────
	# Holder is sized to match the logo aspect exactly and anchored
	# top-centre, so the visible art fills it without any centering slack.
	# Three caps determine the title height:
	#  • a fixed max so the logo doesn't dominate huge desktop screens
	#  • a width-derived cap so it never overflows narrow portrait phones
	#  • a height-budget cap so there's always room for the button column
	#    + the configured logo-to-button gap below it
	# `_compute_btn_bias` lower down then pushes the buttons exactly
	# `_LOGO_TO_BTN_GAP` below the holder's bottom edge.
	var viewport_h: float = get_viewport().get_visible_rect().size.y
	var viewport_w: float = get_viewport().get_visible_rect().size.x
	var side_margin: int = 16 if _is_mobile_ui else 40
	var title_top: int = 24 if _is_mobile_ui else 36
	var title_height: int
	if _is_mobile_ui:
		var max_h_from_width: float = (viewport_w - float(side_margin * 2)) / _LOGO_ASPECT
		# 380 (button column) + 24 (gap below buttons) + 56 (top inset slack)
		var max_h_from_layout: float = viewport_h - 460.0
		title_height = int(max(120.0, min(500.0, max_h_from_width, max_h_from_layout)))
	else:
		title_height = 240
	var title_width: int = int(float(title_height) * _LOGO_ASPECT)

	var title_holder := Control.new()
	title_holder.set_anchors_preset(Control.PRESET_CENTER_TOP)
	title_holder.offset_left = -float(title_width) * 0.5
	title_holder.offset_right = float(title_width) * 0.5
	title_holder.offset_top = title_top
	title_holder.offset_bottom = title_top + title_height
	title_holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(title_holder)
	_parallax_title = title_holder
	_parallax_title_offsets = Vector4(
		title_holder.offset_left, title_holder.offset_top,
		title_holder.offset_right, title_holder.offset_bottom,
	)

	if logo_tex:
		var logo := TextureRect.new()
		logo.texture = logo_tex
		logo.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		logo.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title_holder.add_child(logo)
	else:
		var fallback := Label.new()
		fallback.text = "MY TINY GALAXY"
		fallback.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fallback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var fs: int = HUDStyle.HUD_FONT_XL if _is_mobile_ui else HUDStyle.HUD_FONT_TITLE
		HUDStyle.style_label(fallback, fs, HUDStyle.CRT_GREEN_BG)
		fallback.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		fallback.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title_holder.add_child(fallback)

	# ── BUTTON COLUMN ─────────────────────────────────────────────────
	# Vertically centred in the viewport, biased downward so it doesn't
	# visually collide with the title. Button width is clamped to viewport
	# width minus side margin so it never overflows on narrow phones
	# (iPhone SE ≈ 375 px, Android compact ≈ 360 px). The vertical bias is
	# derived from the title height + viewport so the bigger mobile logo
	# never overlaps the buttons on short / portrait viewports.
	var max_btn_w: int = 460 if _is_mobile_ui else 360
	var btn_w: int = int(min(max_btn_w, viewport_w - 32))
	var btn_box_h: int = 380 if _is_mobile_ui else 330
	var btn_y_bias: float = _compute_btn_bias(viewport_h, title_height, btn_box_h)

	var btn_box := VBoxContainer.new()
	btn_box.alignment = BoxContainer.ALIGNMENT_CENTER
	btn_box.add_theme_constant_override("separation", 14 if _is_mobile_ui else 16)
	btn_box.set_anchors_preset(Control.PRESET_CENTER)
	btn_box.offset_left = -float(btn_w) * 0.5
	btn_box.offset_right = float(btn_w) * 0.5
	btn_box.offset_top = -float(btn_box_h) * 0.5 + btn_y_bias
	btn_box.offset_bottom = float(btn_box_h) * 0.5 + btn_y_bias
	btn_box.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay_anchor.add_child(btn_box)
	_parallax_buttons = btn_box
	_parallax_buttons_offsets = Vector4(
		btn_box.offset_left, btn_box.offset_top,
		btn_box.offset_right, btn_box.offset_bottom,
	)

	# Re-layout on rotation / window resize so the column tracks the new width.
	get_viewport().size_changed.connect(_relayout_buttons.bind(btn_box, max_btn_w, btn_box_h))

	if _has_save:
		var cont := _make_menu_btn("CONTINUE GAME", HUDStyle.BTN_GREEN, btn_w)
		cont.pressed.connect(_on_continue_pressed)
		btn_box.add_child(cont)

	var new_btn := _make_menu_btn(
		"START NEW GAME",
		HUDStyle.BTN_RED if _has_save else HUDStyle.BTN_BLUE,
		btn_w
	)
	new_btn.pressed.connect(_on_new_game_pressed)
	btn_box.add_child(new_btn)

	var settings_btn := _make_menu_btn("SETTINGS", HUDStyle.BTN_BLUE, btn_w)
	settings_btn.pressed.connect(_on_settings_pressed)
	btn_box.add_child(settings_btn)

	if not _is_mobile_ui:
		var quit_btn := _make_menu_btn("QUIT", HUDStyle.BTN_RED, btn_w)
		quit_btn.custom_minimum_size = Vector2(btn_w, 44)
		quit_btn.pressed.connect(func() -> void: get_tree().quit())
		btn_box.add_child(quit_btn)


func _relayout_buttons(btn_box: VBoxContainer, max_btn_w: int, btn_box_h: int) -> void:
	if not is_instance_valid(btn_box):
		return
	var vw: float = get_viewport().get_visible_rect().size.x
	var vh: float = get_viewport().get_visible_rect().size.y
	var new_w: int = int(min(float(max_btn_w), vw - 32.0))
	# Title height stays at its initial value (the holder isn't resized here),
	# so read it back off the cached holder to keep button clearance correct
	# after rotation / resize.
	var th: int = 240
	if is_instance_valid(_parallax_title):
		th = int(_parallax_title.offset_bottom - _parallax_title.offset_top)
	var bias: float = _compute_btn_bias(vh, th, btn_box_h)
	btn_box.offset_left = -float(new_w) * 0.5
	btn_box.offset_right = float(new_w) * 0.5
	btn_box.offset_top = -float(btn_box_h) * 0.5 + bias
	btn_box.offset_bottom = float(btn_box_h) * 0.5 + bias
	# Re-cache the parallax baseline so the tilt math keeps centring on the
	# newly-laid-out position instead of drifting after rotation.
	_parallax_buttons_offsets = Vector4(
		btn_box.offset_left, btn_box.offset_top,
		btn_box.offset_right, btn_box.offset_bottom,
	)
	for child in btn_box.get_children():
		if child is Button:
			var h: float = child.custom_minimum_size.y
			child.custom_minimum_size = Vector2(new_w, h)


# Logo PNG aspect (cropped to visible art, no transparent padding). The
# title holder below is sized to this aspect exactly so the visible art
# fills it with no centering slack — letting us treat the holder bottom
# as the visible art bottom for layout purposes.
const _LOGO_ASPECT: float = 1042.0 / 582.0   # ~1.79
const _LOGO_TO_BTN_GAP: float = 24.0

func _compute_btn_bias(viewport_h: float, title_height: int, btn_box_h: int) -> float:
	if not _is_mobile_ui:
		return 40.0
	# Holder is aspect-matched to the logo so its bottom edge IS the visible
	# art's bottom edge — no padding to compensate for.
	var visible_logo_bottom: float = 24.0 + float(title_height)
	var min_bias: float = visible_logo_bottom + _LOGO_TO_BTN_GAP - viewport_h * 0.5 + float(btn_box_h) * 0.5
	return max(40.0, min_bias)


func _make_menu_btn(text: String, color: Color, width: int = -1) -> Button:
	var b := Button.new()
	b.text = text
	HUDStyle.style_button(b, color, HUDStyle.HUD_FONT_LRG)
	var w: int = width if width > 0 else (460 if _is_mobile_ui else 360)
	var h: int = 82 if _is_mobile_ui else 62
	b.custom_minimum_size = Vector2(w, h)
	return b


# ─── Button handlers ──────────────────────────────────────────────────────

func _on_continue_pressed() -> void:
	get_tree().change_scene_to_file(GAMEPLAY_SCENE)


func _on_new_game_pressed() -> void:
	if _has_save:
		_show_new_game_confirm()
	else:
		_start_new_game()


func _start_new_game() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var stamp: String = str(Time.get_unix_time_from_system())
		var bak: String = SAVE_PATH + ".bak." + stamp
		var d: DirAccess = DirAccess.open("user://")
		if d != null:
			d.rename(SAVE_PATH.replace("user://", ""), bak.replace("user://", ""))
	get_tree().change_scene_to_file(GAMEPLAY_SCENE)


func _show_new_game_confirm() -> void:
	if _confirm_layer != null and is_instance_valid(_confirm_layer):
		_confirm_layer.show()
		return
	_confirm_layer = Control.new()
	_confirm_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_confirm_layer.mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.65)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_confirm_layer.add_child(dim)

	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	plate.set_anchors_preset(Control.PRESET_CENTER)
	var cw: int = 300 if _is_mobile_ui else 240
	var ch: int = 220 if _is_mobile_ui else 180
	plate.offset_left = -cw; plate.offset_right = cw
	plate.offset_top  = -ch; plate.offset_bottom = ch
	_confirm_layer.add_child(plate)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 14)
	plate.add_child(vb)

	var hdr := Label.new()
	hdr.text = "START NEW GAME?"
	hdr.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	HUDStyle.style_label(hdr, HUDStyle.HUD_FONT_LRG, HUDStyle.CRT_GREEN_BG)
	vb.add_child(hdr)

	var msg := Label.new()
	msg.text = "Starting a new game will erase your current\nprogress. A backup will be kept just in case."
	msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	HUDStyle.style_label(msg, HUDStyle.HUD_FONT_SMALL, Color(0.9, 0.85, 0.85))
	vb.add_child(msg)

	var pad := Control.new(); pad.custom_minimum_size = Vector2(0, 6); vb.add_child(pad)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 12)
	vb.add_child(row)

	var cancel := _make_menu_btn("CANCEL", HUDStyle.BTN_BLUE)
	cancel.custom_minimum_size = Vector2(230, 68) if _is_mobile_ui else Vector2(150, 52)
	cancel.pressed.connect(func() -> void: _confirm_layer.hide())
	row.add_child(cancel)

	var go := _make_menu_btn("START NEW", HUDStyle.BTN_RED)
	go.custom_minimum_size = Vector2(230, 68) if _is_mobile_ui else Vector2(150, 52)
	go.pressed.connect(func() -> void:
		_confirm_layer.hide()
		_start_new_game())
	row.add_child(go)

	_overlay_layer.add_child(_confirm_layer)


func _on_settings_pressed() -> void:
	if _settings_layer != null and is_instance_valid(_settings_layer):
		_settings_layer.show()
		if is_instance_valid(_settings_panel):
			_settings_panel.focus_first_control()
		return

	_settings_layer = Control.new()
	_settings_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_settings_layer.mouse_filter = Control.MOUSE_FILTER_STOP

	var dim := ColorRect.new()
	dim.color = Color(HUDStyle.BG_DEEP_PURPLE.r, HUDStyle.BG_DEEP_PURPLE.g, HUDStyle.BG_DEEP_PURPLE.b, 0.86)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_settings_layer.add_child(dim)

	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	plate.set_anchors_preset(Control.PRESET_CENTER)
	var pw: int = 340 if _is_mobile_ui else 260
	var ph: int = 360 if _is_mobile_ui else 280
	plate.offset_left = -pw; plate.offset_right = pw
	plate.offset_top  = -ph; plate.offset_bottom = ph
	_settings_layer.add_child(plate)

	_settings_panel = SettingsPanelScript.new()
	_settings_panel.show_hud_toggle = false
	_settings_panel.music_volume_changed.connect(_on_setting_music)
	_settings_panel.sfx_volume_changed.connect(_on_setting_sfx)
	_settings_panel.gyro_toggled.connect(_on_setting_gyro)
	_settings_panel.sens_changed.connect(_on_setting_sens)
	_settings_panel.dead_changed.connect(_on_setting_dead)
	_settings_panel.rebind_requested.connect(_on_rebind_pressed)
	_settings_panel.back_requested.connect(func() -> void: _settings_layer.hide())
	plate.add_child(_settings_panel)

	_overlay_layer.add_child(_settings_layer)


# ─── Settings forwarding to SettingsManager autoload ──────────────────────

func _on_setting_music(level: int) -> void:
	if Engine.has_meta("SettingsManager"):
		Engine.get_meta("SettingsManager").set_music_level(level)

func _on_setting_sfx(level: int) -> void:
	if Engine.has_meta("SettingsManager"):
		Engine.get_meta("SettingsManager").set_sfx_level(level)

func _on_setting_gyro(paused: bool) -> void:
	if Engine.has_meta("SettingsManager"):
		Engine.get_meta("SettingsManager").set_gyro_paused(paused)

func _on_setting_sens(idx: int) -> void:
	if Engine.has_meta("SettingsManager"):
		Engine.get_meta("SettingsManager").set_sens_idx(idx)

func _on_setting_dead(idx: int) -> void:
	if Engine.has_meta("SettingsManager"):
		Engine.get_meta("SettingsManager").set_dead_idx(idx)

func _on_rebind_pressed() -> void:
	pass


# ─── Input ────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if not _is_close_event(event): return
	if _confirm_layer != null and is_instance_valid(_confirm_layer) and _confirm_layer.visible:
		_confirm_layer.hide()
		get_viewport().set_input_as_handled()
		return
	if _settings_layer != null and is_instance_valid(_settings_layer) and _settings_layer.visible:
		_settings_layer.hide()
		get_viewport().set_input_as_handled()
		return


func _is_close_event(event: InputEvent) -> bool:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		return true
	if event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_B:
			return true
	return false


# ─── Parallax tick ────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_update_tilt_target()
	# Critically-damped lerp so the scene weights into the tilt rather than
	# tracking the cursor 1:1 (which would feel jittery and unstable).
	_tilt = _tilt.lerp(_tilt_target, clamp(delta * 6.0, 0.0, 1.0))
	_apply_parallax()
	_scroll_background(delta)


func _scroll_background(delta: float) -> void:
	# Drift the star slab leftward. When the field has translated by more
	# than its half-width the seamless-tile assumption breaks, so we wrap
	# back by the full slab width — the wrap is invisible because every X
	# inside the slab is equally populated.
	if is_instance_valid(_starfield):
		var x: float = _starfield.position.x - _STAR_SCROLL_SPEED * delta
		if x < -_STAR_SLAB_WIDTH:
			x += _STAR_SLAB_WIDTH * 2.0
		_starfield.position.x = x
	# Milky Way scrolls in its own shader via TIME — nothing else to do here,
	# but if we ever swap to a procedural texture this is where the texture
	# offset would advance.


# Compute target tilt in -1..1 range.  Mobile reads accelerometer; desktop
# uses mouse position relative to viewport centre.  Settings/confirm modals
# zero the tilt so menu interactions feel still.
func _update_tilt_target() -> void:
	if (_settings_layer != null and is_instance_valid(_settings_layer) and _settings_layer.visible) \
			or (_confirm_layer != null and is_instance_valid(_confirm_layer) and _confirm_layer.visible):
		_tilt_target = Vector2.ZERO
		return

	if _is_mobile_ui:
		# Accelerometer x/y are roughly -10..10 (m/s²) when the phone is tilted.
		# Divide by gravity magnitude so a full tilt maps to ~1.0.
		var accel: Vector3 = Input.get_accelerometer()
		if accel == Vector3.ZERO:
			# Some devices report no accel — fall back to gravity which is
			# always available on iOS / modern Android.
			accel = Input.get_gravity()
		_tilt_target = Vector2(
			clamp(accel.x / 6.0, -1.0, 1.0),
			clamp(-accel.y / 6.0, -1.0, 1.0),
		)
	else:
		var size: Vector2 = get_viewport().get_visible_rect().size
		if size.x < 1.0 or size.y < 1.0:
			_tilt_target = Vector2.ZERO
			return
		var m: Vector2 = get_viewport().get_mouse_position()
		_tilt_target = Vector2(
			clamp((m.x / size.x) * 2.0 - 1.0, -1.0, 1.0),
			clamp((m.y / size.y) * 2.0 - 1.0, -1.0, 1.0),
		)


func _apply_parallax() -> void:
	# Subtle parallax — the scene barely drifts under the camera. Tighter
	# magnitudes than the first pass so the menu feels stable rather than
	# motion-sick. Mobile gyro reading is noisy so keeping motion small
	# also stops random twitch from showing up.
	const CAM_MAG: float = 0.18
	if is_instance_valid(_parallax_camera):
		_parallax_camera.position = _parallax_cam_base + Vector3(_tilt.x * CAM_MAG, -_tilt.y * CAM_MAG, 0.0)

	# Planets shift opposite to the camera, scaled by depth_factor so the
	# foreground hero planet moves slightly more than the deep background.
	const PLANET_MAG: float = 0.38
	for entry in _parallax_planets:
		var node = entry["node"]
		if not is_instance_valid(node):
			continue
		var base: Vector3 = entry["base_pos"]
		var df: float = float(entry["depth_factor"])
		node.position = base + Vector3(-_tilt.x * PLANET_MAG * df, _tilt.y * PLANET_MAG * df, 0.0)

	# UI nudges in the opposite direction so the title/buttons feel like a
	# foreground glass layer. Halved from the first pass — was too jittery
	# on mouse-driven desktop.
	const UI_MAG: float = 7.0
	if is_instance_valid(_parallax_title):
		var dx_t: float = -_tilt.x * UI_MAG
		var dy_t: float = -_tilt.y * UI_MAG * 0.4
		_parallax_title.offset_left = _parallax_title_offsets.x + dx_t
		_parallax_title.offset_top = _parallax_title_offsets.y + dy_t
		_parallax_title.offset_right = _parallax_title_offsets.z + dx_t
		_parallax_title.offset_bottom = _parallax_title_offsets.w + dy_t
	if is_instance_valid(_parallax_buttons):
		var dx_b: float = -_tilt.x * UI_MAG * 0.5
		var dy_b: float = -_tilt.y * UI_MAG * 0.25
		_parallax_buttons.offset_left = _parallax_buttons_offsets.x + dx_b
		_parallax_buttons.offset_top = _parallax_buttons_offsets.y + dy_b
		_parallax_buttons.offset_right = _parallax_buttons_offsets.z + dx_b
		_parallax_buttons.offset_bottom = _parallax_buttons_offsets.w + dy_b

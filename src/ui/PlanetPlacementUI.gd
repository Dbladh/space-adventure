extends Control

signal placement_confirmed(world_pos: Vector3, planet_name: String)
signal placement_canceled()

const HUDStyle := preload("res://src/ui/HUDStyle.gd")

# Sci-fi planet name pool — classical, compound, catalog-style, and pure made-
# up entries so each cycle through feels distinct. The randomize button picks
# from this list on every press; the initial name is also rolled from here.
const PLANET_NAMES: Array[String] = [
	# Classical / mythological
	"Acheron", "Aether", "Aldebaran", "Altair", "Andromeda", "Antares", "Apollo",
	"Ares", "Arcturus", "Atlas", "Bellatrix", "Betelgeuse", "Calypso", "Cassiopeia",
	"Centauri", "Cerberus", "Cygnus", "Daedalus", "Deneb", "Eos", "Erebus", "Europa",
	"Fomalhaut", "Gaia", "Hadar", "Helios", "Hyperion", "Icarus", "Io", "Janus",
	"Kronos", "Lyra", "Megrez", "Mimas", "Nemesis", "Nyx", "Oberon", "Orion",
	"Osiris", "Pallas", "Pandora", "Phobos", "Polaris", "Proxima", "Pyxis",
	"Regulus", "Rigel", "Sirius", "Solaris", "Tartarus", "Tethys", "Thalassa",
	"Titan", "Triton", "Vega", "Vulcan", "Yggdrasil", "Zephyr", "Zenith",
	"Asgard", "Avalon", "Elysium", "Olympus", "Valhalla", "Hyperborea", "Hades",
	# Compound sci-fi
	"Nova Prime", "Aurora Reach", "Crimson Echo", "Silent Drift", "Vermillion Tide",
	"Onyx Veil", "Cobalt Halo", "Azure Crest", "Obsidian Sky", "Helix Major",
	"Quasar Beacon", "Pulsar Edge", "Nebula Pass", "Vortex Reach", "Stellar Forge",
	"Cinder Reach", "Frost Crown", "Ember Halo", "Mistral Wake", "Verdant Pyre",
	"Twilight Vale", "Glacial Hymn", "Arc Cardinal", "Singularity Point",
	"Vermilion Spire", "Tantalus Hollow", "Cradle Nine", "Iron Reverie",
	"Echo Prime", "Wraith Ascendant",
	# Made-up alien
	"Kelvar", "Xerath", "Vyndor", "Zeyra", "Kaelis", "Threnos", "Vexen", "Sythari",
	"Ozymar", "Quintar", "Velthros", "Synthia", "Nyxon", "Orethel", "Drazhar",
	"Ixion", "Maeloth", "Crelix", "Zarathos", "Voltari", "Aeryn", "Kestral",
	"Talvex", "Brynhal", "Volaria", "Cydon", "Tessari", "Phobaris",
	# Catalog-style designations
	"Kepler-186", "Trappist-1", "HD 209458", "Gliese 581", "Wolf 359", "Tau Ceti",
	"TYC-9999", "PSR-1257", "K2-141", "GJ-1214", "WASP-12", "55 Cancri",
]

var max_range: float = 6250000.0
var placement_target: Vector2 = Vector2.ZERO
var is_valid_placement: bool = false
var name_input: LineEdit
var map_display: Control
var _name_rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _pick_random_planet_name() -> String:
	# Avoid picking the currently-shown name so consecutive presses always
	# advance the displayed text. Falls through after a small bounded retry
	# so we never spin if the pool happens to roll the same index twice in
	# a row when only one name is in the list.
	if PLANET_NAMES.is_empty():
		return "Nova Prime"
	var current: String = name_input.text if name_input != null else ""
	var pick: String = current
	for _i in range(8):
		pick = PLANET_NAMES[_name_rng.randi_range(0, PLANET_NAMES.size() - 1)]
		if pick != current:
			break
	return pick

# Minimum-distance tuning for the placement validator.  Old constants
# (1500 km between planets, 500 km from stations, 2000 km from player)
# were sized for a previous era of much larger planets and didn't read
# any actual radii — they were both too loose against stations (a
# scaled station model is ~500 km across, so 500 km from centre still
# clipped) and far too conservative against tiny planets (60-140 km
# now, so the old 1500 km guard reserved ~10× the actual contact
# distance).  All three checks are now (existing_radius +
# new_planet_radius + safety_margin) using whatever radius data the
# nodes expose.
const NEW_PLANET_RADIUS_ASSUMED: float = 150000.0  # 150 km — generous for the about-to-spawn planet
const PLANET_SAFETY_MARGIN: float = 50000.0        # 50 km buffer between planet surfaces
const STATION_SAFETY_MARGIN: float = 100000.0      # 100 km buffer around station extent
const STATION_RADIUS_ASSUMED: float = 500000.0     # 500 km — visual extent of the scaled station model
const PLAYER_SAFETY_MARGIN: float = 100000.0       # 100 km buffer around player ship

func _ready() -> void:
	process_mode = PROCESS_MODE_ALWAYS
	# Group so Main._any_modal_ui_open() can detect us and suppress the
	# global pause overlay — keeps the rule "one menu at a time".
	add_to_group("PlacementUI")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	
	# 1. Saturated arcade-purple background — matches Designercize canvas.
	var bg = ColorRect.new()
	bg.color = Color(HUDStyle.BG_DEEP_PURPLE.r, HUDStyle.BG_DEEP_PURPLE.g, HUDStyle.BG_DEEP_PURPLE.b, 0.96)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# 2. Map Display — drawn into a CRT-green screen via _on_map_draw.
	#    Wrapped in a beveled bezel that frames the screen.
	var map_bezel := PanelContainer.new()
	map_bezel.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	map_bezel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	map_bezel.offset_left = -312
	map_bezel.offset_top = -312
	map_bezel.offset_right = 312
	map_bezel.offset_bottom = 312
	add_child(map_bezel)

	map_display = Control.new()
	map_display.custom_minimum_size = Vector2(600, 600)
	map_display.mouse_filter = Control.MOUSE_FILTER_STOP
	map_display.draw.connect(_on_map_draw)
	map_display.gui_input.connect(_on_map_input)
	map_bezel.add_child(map_display)

	# Title
	var lbl = Label.new()
	lbl.text = "SELECT PLANET ORBIT"
	HUDStyle.style_label(lbl, HUDStyle.HUD_FONT_TITLE, HUDStyle.CRT_GREEN_BG)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	lbl.offset_top = 48
	add_child(lbl)
	# Name input row — LineEdit (auto-styled by theme as a CRT screen) +
	# randomize button. Anchored at bottom-centre below the map.
	_name_rng.randomize()
	var name_row := HBoxContainer.new()
	name_row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	name_row.custom_minimum_size = Vector2(540, 64)
	name_row.offset_left = -300
	name_row.offset_top = -200
	name_row.offset_right = 300
	name_row.offset_bottom = -136
	name_row.add_theme_constant_override("separation", 10)
	add_child(name_row)

	name_input = LineEdit.new()
	name_input.placeholder_text = "ENTER PLANET NAME..."
	name_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	HUDStyle.style_line_edit(name_input, HUDStyle.HUD_FONT_MED)
	name_input.custom_minimum_size = Vector2(420, 64)
	name_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Initial name is also rolled from the pool so every Forge session starts
	# with a fresh suggestion rather than always defaulting to "Nova Prime".
	name_input.text = PLANET_NAMES[_name_rng.randi_range(0, PLANET_NAMES.size() - 1)]
	name_row.add_child(name_input)

	var randomize_btn := Button.new()
	randomize_btn.text = "RND"
	randomize_btn.tooltip_text = "Pick a random sci-fi name"
	HUDStyle.style_button(randomize_btn, HUDStyle.BTN_PINK, HUDStyle.HUD_FONT_MED)
	randomize_btn.custom_minimum_size = Vector2(96, 64)
	randomize_btn.focus_mode = Control.FOCUS_NONE
	randomize_btn.pressed.connect(func(): name_input.text = _pick_random_planet_name())
	name_row.add_child(randomize_btn)

	# Confirm / Cancel buttons.
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 24)
	hbox.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hbox.offset_top = -110
	hbox.offset_bottom = -40
	hbox.offset_left = -320
	hbox.offset_right = 320
	add_child(hbox)

	var confirm_btn = Button.new()
	confirm_btn.text = "FORGE PLANET"
	HUDStyle.style_button(confirm_btn, HUDStyle.BTN_GREEN, HUDStyle.HUD_FONT_LRG)
	confirm_btn.custom_minimum_size = Vector2(280, 64)
	confirm_btn.pressed.connect(_on_confirm)
	hbox.add_child(confirm_btn)

	var cancel_btn = Button.new()
	cancel_btn.text = "CANCEL"
	HUDStyle.style_button(cancel_btn, HUDStyle.BTN_RED, HUDStyle.HUD_FONT_LRG)
	cancel_btn.custom_minimum_size = Vector2(220, 64)
	cancel_btn.pressed.connect(func(): placement_canceled.emit(); queue_free())
	hbox.add_child(cancel_btn)

	# Grab focus on Confirm so a gamepad user can press A immediately
	# after picking a spot, and B / START / Esc to back out without
	# having to mouse to the Cancel button.  Deferred so the buttons
	# are fully in the tree before grab_focus runs.
	cancel_btn.set_meta("placement_cancel_btn", true)
	confirm_btn.call_deferred("grab_focus")

func _input(event: InputEvent) -> void:
	# Cancel via Escape OR gamepad B (ui_cancel) OR gamepad START.
	# Pre-empts the global pause toggle so pause-while-placing closes
	# this UI rather than stacking the pause overlay on top.
	var cancel_pressed := false
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		cancel_pressed = true
	elif event is InputEventJoypadButton and event.pressed:
		if event.button_index == JOY_BUTTON_START or event.button_index == JOY_BUTTON_B:
			cancel_pressed = true
	if cancel_pressed:
		placement_canceled.emit()
		queue_free()
		get_viewport().set_input_as_handled()

func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		placement_target = event.position
		is_valid_placement = _check_placement_valid(placement_target)
		map_display.queue_redraw()

func _check_placement_valid(ui_pos: Vector2) -> bool:
	var w_pos = _map_to_world(ui_pos)
	var planets = get_tree().get_nodes_in_group("Planet")
	var stations = get_tree().get_nodes_in_group("SpaceStation")

	# Each minimum is (existing_radius + new_planet_radius + margin) so
	# planets can sit close to one another / to stations / to the player
	# while still leaving a buffer that prevents surface clipping.
	for p in planets:
		var pr: float = float(p.get("planet_radius")) if "planet_radius" in p else 100000.0
		var min_d: float = pr + NEW_PLANET_RADIUS_ASSUMED + PLANET_SAFETY_MARGIN
		if p.global_position.distance_to(w_pos) < min_d:
			return false

	for s in stations:
		# SpaceStations don't currently expose a radius — fall back to a
		# conservative footprint matching the scaled model's visible
		# extent, with an extra margin so the docking ring stays clear.
		var sr: float = float(s.get("station_radius")) if "station_radius" in s else STATION_RADIUS_ASSUMED
		var min_d: float = sr + NEW_PLANET_RADIUS_ASSUMED + STATION_SAFETY_MARGIN
		if s.global_position.distance_to(w_pos) < min_d:
			return false

	var players = get_tree().get_nodes_in_group("Player")
	if players.size() > 0:
		var min_d: float = NEW_PLANET_RADIUS_ASSUMED + PLAYER_SAFETY_MARGIN
		if players[0].global_position.distance_to(w_pos) < min_d:
			return false

	return true

func _on_confirm() -> void:
	if placement_target == Vector2.ZERO: return
	if not is_valid_placement: return
	var p_name = name_input.text.strip_edges()
	if p_name == "": p_name = _pick_random_planet_name()
	
	placement_confirmed.emit(_map_to_world(placement_target), p_name)
	queue_free()

func _on_map_draw() -> void:
	var map_cen = map_display.size / 2.0
	var map_r = map_display.size.x / 2.0

	# CRT-green screen background — fill the whole map area then draw the
	# rest of the radar in dark "CRT ink" so it reads as a vintage tactical
	# monitor.  Border colours are picked from HUDStyle.CRT_GREEN_BORDER /
	# CRT_GREEN_INK so the radar feels of-a-piece with the surrounding chrome.
	map_display.draw_rect(Rect2(Vector2.ZERO, map_display.size), HUDStyle.CRT_GREEN_BG)

	var ink: Color = HUDStyle.CRT_GREEN_INK
	var faint: Color = Color(ink.r, ink.g, ink.b, 0.35)

	# Grid rings + crosshair drawn in dark green ink on the bright CRT.
	for i in range(1, 6):
		map_display.draw_arc(map_cen, map_r * (float(i) / 5.0), 0, TAU, 64, faint, 1.5)
	map_display.draw_line(Vector2(0, map_cen.y), Vector2(map_display.size.x, map_cen.y), faint, 1.0)
	map_display.draw_line(Vector2(map_cen.x, 0), Vector2(map_cen.x, map_display.size.y), faint, 1.0)

	var planets = get_tree().get_nodes_in_group("Planet")
	var stations = get_tree().get_nodes_in_group("SpaceStation")
	var player = get_tree().get_nodes_in_group("Player")
	var font: Font = HUDStyle.PIXEL_FONT

	# Draw Player — bright pink dot, easy to spot on the green screen.
	if player.size() > 0:
		var p_node = player[0]
		var p_ui = _world_to_map(p_node.global_position)
		var p_col = HUDStyle.BTN_PINK
		map_display.draw_circle(map_cen + p_ui, 6.0, p_col)
		map_display.draw_arc(map_cen + p_ui, 12.0, 0, TAU, 16, p_col, 2.0)

	# Draw Planets — solid CRT-ink dots labelled with pixel font.
	for p in planets:
		if not is_instance_valid(p): continue
		var p_ui = _world_to_map(p.global_position)
		map_display.draw_circle(map_cen + p_ui, 10.0, ink)
		map_display.draw_string(font, map_cen + p_ui + Vector2(14, 6), p.name.replace("Planet_", "").to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, ink)

	# Draw Stations — diamond markers in tier-orange so they stand out from
	# planets without abandoning the CRT palette.
	for s in stations:
		if not is_instance_valid(s): continue
		var s_ui = _world_to_map(s.global_position)
		var s_pts = PackedVector2Array([
			map_cen + s_ui + Vector2(0, -9),
			map_cen + s_ui + Vector2(9, 0),
			map_cen + s_ui + Vector2(0, 9),
			map_cen + s_ui + Vector2(-9, 0)
		])
		var s_col: Color = HUDStyle.TIER_COLOR_4
		map_display.draw_colored_polygon(s_pts, s_col)
		var s_name = s.name.replace("SpaceStation_", "").replace("OrbitalStation", "Orbital")
		map_display.draw_string(font, map_cen + s_ui + Vector2(14, 6), s_name.to_upper(), HORIZONTAL_ALIGNMENT_LEFT, -1, HUDStyle.HUD_FONT_TINY, s_col.darkened(0.3))

	# Draw Placement Marker — green for valid, red for invalid.  Both pop
	# against the CRT background.
	if placement_target != Vector2.ZERO:
		var col: Color = HUDStyle.BTN_GREEN if is_valid_placement else HUDStyle.BTN_RED
		var pulse = (sin(Time.get_ticks_msec() * 0.012) + 1.0) * 0.5
		map_display.draw_arc(placement_target, 20.0 + pulse * 10.0, 0, TAU, 32, col, 3.0)
		map_display.draw_circle(placement_target, 5.0, col)
		map_display.draw_line(placement_target - Vector2(30, 0), placement_target + Vector2(30, 0), col, 2.0)
		map_display.draw_line(placement_target - Vector2(0, 30), placement_target + Vector2(0, 30), col, 2.0)

		if not is_valid_placement:
			map_display.draw_string(font, placement_target + Vector2(-90, -45), "ORBIT OCCUPIED", HORIZONTAL_ALIGNMENT_CENTER, -1, HUDStyle.HUD_FONT_SMALL, col.darkened(0.2))

func _world_to_map(w_pos: Vector3) -> Vector2:
	var rel = Vector2(w_pos.x, w_pos.z)
	var scaled = rel / max_range * 300.0
	return scaled

func _map_to_world(ui_pos: Vector2) -> Vector3:
	var centered = ui_pos - Vector2(300, 300)
	var w_x = (centered.x / 300.0) * max_range
	var w_z = (centered.y / 300.0) * max_range
	return Vector3(w_x, 0.0, w_z)

func _process(_delta: float) -> void:
	map_display.queue_redraw()

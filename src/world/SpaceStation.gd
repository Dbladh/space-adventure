extends Node3D

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

# SpaceStation.gd
# Dockable station. Fly within DOCK_RANGE for the UI to auto-open.
#   • Sell All  — converts held resources to credits
#   • Forge     — spend 3 resource slots to spawn a deterministic planet
#   • Dismantle — destroy a forged planet and recover the resources

const DOCK_RANGE: float = 600000.0   # 600 km — stations are massive now
const MAX_PLANETS: int = 3

var station_display_name: String = "Alpha"   # set before add_child()
var _ring_node: Node3D = null                # rotated each frame
var _player: Node3D = null
var _ui_layer: CanvasLayer = null
var _panel: Control = null
var _inv_label: Label = null
var _creds_label: Label = null
var _forge_slots: Array = []          # Array[OptionButton]
var _forge_status: Label = null
var _planets_container: VBoxContainer = null
var _worlds_header: Label = null
var _ui_visible: bool = false

# Each entry: { node: Node3D, r1: String, r2: String, r3: String }
var _active_planets: Array[Dictionary] = []

func _ready() -> void:
	# ALWAYS so the Close button and _process work even when tree is paused for docking
	process_mode = PROCESS_MODE_ALWAYS
	add_to_group("SpaceStation")
	_build_visual()
	_build_ui()

# ---------------------------------------------------------------------------
# VISUAL
# ---------------------------------------------------------------------------

func _build_visual() -> void:
	# All sizes in metres.  Station is ~300 km across — Death Star scale.
	const DISC_R   := 150_000.0   # main disc radius
	const DISC_H   :=  28_000.0   # disc thickness
	const RING_IN  := 170_000.0   # orbital ring inner radius
	const RING_OUT := 215_000.0   # orbital ring outer radius
	const CORE_R   :=  42_000.0   # central sphere radius

	# ── Main disc body ────────────────────────────────────────────────
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius    = DISC_R
	disc_mesh.bottom_radius = DISC_R
	disc_mesh.height        = DISC_H
	disc_mesh.radial_segments = 24

	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.42, 0.52, 0.62)
	disc_mat.emission_enabled = true
	disc_mat.emission = Color(0.15, 0.35, 0.75)
	disc_mat.emission_energy_multiplier = 1.2
	disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	disc_mesh.material = disc_mat

	var disc := MeshInstance3D.new()
	disc.mesh = disc_mesh
	add_child(disc)

	# ── Central core sphere ───────────────────────────────────────────
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = CORE_R
	sphere_mesh.height = CORE_R * 2.0
	sphere_mesh.radial_segments = 16
	sphere_mesh.rings = 8

	var core_mat := StandardMaterial3D.new()
	core_mat.albedo_color = Color(0.6, 0.75, 1.0)
	core_mat.emission_enabled = true
	core_mat.emission = Color(0.2, 0.6, 1.0)
	core_mat.emission_energy_multiplier = 3.5
	core_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere_mesh.material = core_mat

	var core := MeshInstance3D.new()
	core.mesh = sphere_mesh
	add_child(core)

	# ── Orbital ring (slowly rotates) ────────────────────────────────
	var torus := TorusMesh.new()
	torus.inner_radius = RING_IN
	torus.outer_radius = RING_OUT
	torus.rings         = 48
	torus.ring_segments = 12

	var ring_mat := StandardMaterial3D.new()
	ring_mat.albedo_color = Color(0.1, 0.8, 1.0)
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.1, 0.8, 1.0)
	ring_mat.emission_energy_multiplier = 5.0
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	torus.material = ring_mat

	_ring_node = Node3D.new()
	var ring := MeshInstance3D.new()
	ring.mesh = torus
	_ring_node.add_child(ring)
	add_child(_ring_node)

	# ── OmniLight so the station glows across the system ─────────────
	var light := OmniLight3D.new()
	light.light_color = Color(0.3, 0.7, 1.0)
	light.light_energy = 8.0
	light.omni_range   = RING_OUT * 8.0
	add_child(light)

# ---------------------------------------------------------------------------
# UI BUILD
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 130
	# ALWAYS so buttons remain interactive while the gameplay tree is paused
	_ui_layer.process_mode = PROCESS_MODE_ALWAYS
	add_child(_ui_layer)

	# Use a ScrollContainer so the panel adapts to variable planet list height
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	scroll.custom_minimum_size = Vector2(560, 680)
	scroll.offset_top    = -340
	scroll.offset_left   = -280
	scroll.offset_bottom =  340
	scroll.offset_right  =  280
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_ui_layer.add_child(scroll)
	_panel = scroll  # hide/show the scroll container as our panel

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	# ---- Title ----
	var title := Label.new()
	title.text = "[ STATION " + station_display_name.to_upper() + " ]"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color.CYAN)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# ---- Credits ----
	_creds_label = Label.new()
	_creds_label.text = "$0"
	_creds_label.add_theme_font_size_override("font_size", 26)
	_creds_label.add_theme_color_override("font_color", Color.GOLD)
	_creds_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_creds_label)

	# ---- Inventory ----
	_inv_label = Label.new()
	_inv_label.text = "Inventory: (empty)"
	_inv_label.add_theme_font_size_override("font_size", 20)
	_inv_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_inv_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_inv_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_inv_label)

	# ---- Sell ----
	var sell_btn := Button.new()
	sell_btn.text = "Sell All Resources"
	sell_btn.add_theme_font_size_override("font_size", 22)
	sell_btn.pressed.connect(_on_sell_all)
	vbox.add_child(sell_btn)

	vbox.add_child(HSeparator.new())

	# ---- Forge ----
	var forge_title := Label.new()
	forge_title.text = "— FORGE PLANET —\nChoose 3 resources (consumed on forge)"
	forge_title.add_theme_font_size_override("font_size", 20)
	forge_title.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	forge_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	forge_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(forge_title)

	var slots_hbox := HBoxContainer.new()
	slots_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_hbox.add_theme_constant_override("separation", 16)
	vbox.add_child(slots_hbox)

	for i in range(3):
		var opt := OptionButton.new()
		opt.add_theme_font_size_override("font_size", 20)
		opt.custom_minimum_size = Vector2(130, 44)
		for r in ResourceRegistry.all_names():
			opt.add_item(ResourceRegistry.get_abbrev(r))
		opt.selected = i  # default: Cu / Ag / Au
		_forge_slots.append(opt)
		slots_hbox.add_child(opt)

	_forge_status = Label.new()
	_forge_status.text = ""
	_forge_status.add_theme_font_size_override("font_size", 18)
	_forge_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
	_forge_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_forge_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_forge_status)

	var forge_btn := Button.new()
	forge_btn.text = "FORGE PLANET"
	forge_btn.add_theme_font_size_override("font_size", 26)
	forge_btn.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	forge_btn.pressed.connect(_on_forge_planet)
	vbox.add_child(forge_btn)

	vbox.add_child(HSeparator.new())

	# ---- Active Worlds ----
	_worlds_header = Label.new()
	_worlds_header.text = "— ACTIVE WORLDS (0/" + str(MAX_PLANETS) + ") —"
	_worlds_header.add_theme_font_size_override("font_size", 20)
	_worlds_header.add_theme_color_override("font_color", Color(0.6, 1.0, 0.8))
	_worlds_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_worlds_header)

	_planets_container = VBoxContainer.new()
	_planets_container.add_theme_constant_override("separation", 6)
	vbox.add_child(_planets_container)

	var close_btn := Button.new()
	close_btn.text = "Close  [fly away]"
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.pressed.connect(_hide_ui)
	vbox.add_child(close_btn)

	# Wire signals
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.currency_changed.connect(func(n: int) -> void: _creds_label.text = "$" + str(n))
		_creds_label.text = "$" + str(econ.credits)

	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		inv.inventory_changed.connect(func(_t: String, _a: int) -> void: _refresh_inv_display())
		_refresh_inv_display()

	_panel.hide()

# ---------------------------------------------------------------------------
# REFRESH HELPERS
# ---------------------------------------------------------------------------

func _refresh_inv_display() -> void:
	if not Engine.has_meta("InventoryManager"):
		return
	var inv = Engine.get_meta("InventoryManager")
	var all: Dictionary = inv.get_all()
	var parts: Array[String] = []
	for r in ResourceRegistry.all_names():
		var amt: int = all.get(r, 0)
		if amt > 0:
			parts.append(ResourceRegistry.get_abbrev(r) + ":" + str(amt))
	_inv_label.text = "Inventory: " + ("  ".join(parts) if parts.size() > 0 else "(empty)")

func _refresh_planets_ui() -> void:
	for child in _planets_container.get_children():
		child.queue_free()

	_worlds_header.text = "— ACTIVE WORLDS (" + str(_active_planets.size()) + "/" + str(MAX_PLANETS) + ") —"

	if _active_planets.is_empty():
		var none_lbl := Label.new()
		none_lbl.text = "(no forged planets)"
		none_lbl.add_theme_font_size_override("font_size", 18)
		none_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
		none_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_planets_container.add_child(none_lbl)
		return

	for entry in _active_planets:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		_planets_container.add_child(row)

		var combo: String = ResourceRegistry.get_abbrev(entry.r1) + "+" + ResourceRegistry.get_abbrev(entry.r2) + "+" + ResourceRegistry.get_abbrev(entry.r3)
		var seed_val: int = PlanetSeedKitchen.make_seed(entry.r1, entry.r2, entry.r3)

		var lbl := Label.new()
		lbl.text = combo + "  (seed " + str(seed_val) + ")"
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", Color(0.8, 0.9, 0.8))
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)

		var dis_btn := Button.new()
		dis_btn.text = "Dismantle"
		dis_btn.add_theme_font_size_override("font_size", 17)
		dis_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		# Capture entry by value with a local copy
		var captured := entry
		dis_btn.pressed.connect(func() -> void: _on_dismantle(captured))
		row.add_child(dis_btn)

# ---------------------------------------------------------------------------
# PROXIMITY LOOP
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	# Slowly rotate the orbital ring for visual interest
	if _ring_node:
		_ring_node.rotate_y(delta * 0.04)

	if not _player:
		var found = get_tree().get_nodes_in_group("Player")
		if found.size() > 0:
			_player = found[0]
		return

	var dist: float = global_position.distance_to(_player.global_position)
	if dist < DOCK_RANGE and not _ui_visible:
		_show_ui()
	elif dist >= DOCK_RANGE and _ui_visible:
		_hide_ui()

func _show_ui() -> void:
	_ui_visible = true
	_panel.show()
	_refresh_inv_display()
	_refresh_planets_ui()
	_forge_status.text = ""
	# Hide all gameplay HUD and freeze the world while docked
	get_tree().call_group("GameHUD", "hide")
	get_tree().paused = true

func _hide_ui() -> void:
	_ui_visible = false
	_panel.hide()
	# Restore gameplay HUD and unpause
	get_tree().paused = false
	get_tree().call_group("GameHUD", "show")

# ---------------------------------------------------------------------------
# ACTIONS
# ---------------------------------------------------------------------------

func _on_sell_all() -> void:
	if not Engine.has_meta("InventoryManager") or not Engine.has_meta("EconomyManager"):
		return
	var inv = Engine.get_meta("InventoryManager")
	var econ = Engine.get_meta("EconomyManager")
	var total: int = 0
	for r in ResourceRegistry.all_names():
		var amt: int = inv.get_amount(r)
		if amt > 0:
			total += amt * ResourceRegistry.get_value(r)
			inv.consume(r, amt)
	if total > 0:
		econ.add_credits(total)
		_set_status("Sold for $" + str(total), Color.GREEN)
	else:
		_set_status("Nothing to sell.", Color(1.0, 0.5, 0.3))

func _on_forge_planet() -> void:
	_set_status("", Color(1.0, 0.5, 0.3))

	# Prune entries whose planets were destroyed externally
	_active_planets = _active_planets.filter(func(e: Dictionary) -> bool:
		return is_instance_valid(e.node))

	if _active_planets.size() >= MAX_PLANETS:
		_set_status("Max " + str(MAX_PLANETS) + " planets reached.\nDismantle one first.", Color(1.0, 0.5, 0.3))
		return

	if not Engine.has_meta("InventoryManager"):
		return
	var inv = Engine.get_meta("InventoryManager")

	var r1: String = ResourceRegistry.all_names()[_forge_slots[0].selected]
	var r2: String = ResourceRegistry.all_names()[_forge_slots[1].selected]
	var r3: String = ResourceRegistry.all_names()[_forge_slots[2].selected]
	var cost: Dictionary = PlanetSeedKitchen.resource_cost(r1, r2, r3)

	for res in cost:
		if inv.get_amount(res) < cost[res]:
			_set_status("Need: " + _format_cost(cost) + "\nNot enough resources.", Color(1.0, 0.5, 0.3))
			return

	for res in cost:
		inv.consume(res, cost[res])

	var seed_val: int = PlanetSeedKitchen.make_seed(r1, r2, r3)
	var planet_node := _spawn_planet_node(seed_val)
	# Set what resources this planet contains based on the forge tier
	var planet_res := PlanetSeedKitchen.resources_for_planet(r1, r2, r3)
	planet_node.set("planet_resources", planet_res)
	_active_planets.append({node = planet_node, r1 = r1, r2 = r2, r3 = r3})
	_refresh_planets_ui()

	var combo: String = ResourceRegistry.get_abbrev(r1) + "+" + ResourceRegistry.get_abbrev(r2) + "+" + ResourceRegistry.get_abbrev(r3)
	_set_status("Planet forged! (" + combo + ")\nSeed: " + str(seed_val), Color(0.4, 1.0, 0.6))

func _on_dismantle(entry: Dictionary) -> void:
	if is_instance_valid(entry.node):
		entry.node.queue_free()

	# Refund the 3 resources
	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		var cost: Dictionary = PlanetSeedKitchen.resource_cost(entry.r1, entry.r2, entry.r3)
		for res in cost:
			inv.add(res, cost[res])

	_active_planets.erase(entry)
	_refresh_planets_ui()

	var combo: String = ResourceRegistry.get_abbrev(entry.r1) + "+" + ResourceRegistry.get_abbrev(entry.r2) + "+" + ResourceRegistry.get_abbrev(entry.r3)
	_set_status("Dismantled (" + combo + ")\nResources refunded.", Color(0.8, 0.8, 0.4))

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

func _set_status(msg: String, col: Color) -> void:
	_forge_status.text = msg
	_forge_status.add_theme_color_override("font_color", col)

func _format_cost(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for r in cost:
		parts.append(str(cost[r]) + "× " + ResourceRegistry.get_abbrev(r))
	return ",  ".join(parts)

func _spawn_planet_node(seed_val: int) -> Node3D:
	var pg_script = load("res://src/world/PlanetGen.gd")
	if not pg_script:
		return Node3D.new()

	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var angle: float = rng.randf() * TAU
	var dist: float = rng.randf_range(4000000.0, 8000000.0)
	var height: float = rng.randf_range(-500000.0, 500000.0)
	var spawn_pos := global_position + Vector3(cos(angle) * dist, height, sin(angle) * dist)

	var base_radius: float = 600000.0 + float(seed_val % 1200) * 500.0
	if seed_val % 11 == 0:
		base_radius *= 1.4

	var planet := Node3D.new()
	planet.set_script(pg_script)
	planet.name = "Planet_Forged_" + str(seed_val)
	planet.set("planet_seed", seed_val)
	planet.set("planet_radius", base_radius)

	var world_root = get_tree().get_nodes_in_group("WorldRoot")
	if world_root.size() > 0:
		world_root[0].add_child(planet)
	else:
		get_tree().root.add_child(planet)

	planet.global_position = spawn_pos
	planet.add_to_group("Planet")
	planet.add_to_group("ForgedPlanet")
	return planet

extends Node3D

# SpaceStation.gd
# Dockable station. Fly within DOCK_RANGE for the UI to auto-open.
#   • Sell All  — converts held resources to credits
#   • Forge     — spend 3 resource slots to spawn a deterministic planet
#   • Dismantle — destroy a forged planet and recover the resources

const DOCK_RANGE: float = 200000.0
const MAX_PLANETS: int = 3

const RESOURCE_NAMES: Array = ["Copper", "Silver", "Gold", "Platinum", "Diamond"]
const RESOURCE_ABBREV: Dictionary = {
	"Copper":   "Cu",
	"Silver":   "Ag",
	"Gold":     "Au",
	"Platinum": "Pt",
	"Diamond":  "Di",
}
const RESOURCE_VALUES: Dictionary = {
	"Copper":   10,
	"Silver":   50,
	"Gold":     250,
	"Platinum": 1000,
	"Diamond":  5000,
}

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
	add_to_group("SpaceStation")
	_build_visual()
	_build_ui()

# ---------------------------------------------------------------------------
# VISUAL
# ---------------------------------------------------------------------------

func _build_visual() -> void:
	var mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(6000, 2000, 6000)
	mi.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.65, 0.75)
	mat.emission_enabled = true
	mat.emission = Color(0.2, 0.45, 0.9)
	mat.emission_energy_multiplier = 1.8
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	add_child(mi)

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 3500
	torus.outer_radius = 4200
	ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.emission_enabled = true
	ring_mat.emission = Color(0.1, 0.9, 1.0)
	ring_mat.emission_energy_multiplier = 4.0
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override = ring_mat
	add_child(ring)

# ---------------------------------------------------------------------------
# UI BUILD
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 130
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
	title.text = "[ SPACE STATION ]"
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
		for r in RESOURCE_NAMES:
			opt.add_item(RESOURCE_ABBREV[r])
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
	for r in RESOURCE_NAMES:
		var amt: int = all.get(r, 0)
		if amt > 0:
			parts.append(RESOURCE_ABBREV[r] + ":" + str(amt))
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

		var combo: String = RESOURCE_ABBREV[entry.r1] + "+" + RESOURCE_ABBREV[entry.r2] + "+" + RESOURCE_ABBREV[entry.r3]
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

func _process(_delta: float) -> void:
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

func _hide_ui() -> void:
	_ui_visible = false
	_panel.hide()

# ---------------------------------------------------------------------------
# ACTIONS
# ---------------------------------------------------------------------------

func _on_sell_all() -> void:
	if not Engine.has_meta("InventoryManager") or not Engine.has_meta("EconomyManager"):
		return
	var inv = Engine.get_meta("InventoryManager")
	var econ = Engine.get_meta("EconomyManager")
	var total: int = 0
	for r in RESOURCE_NAMES:
		var amt: int = inv.get_amount(r)
		if amt > 0:
			total += amt * RESOURCE_VALUES[r]
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

	var r1: String = RESOURCE_NAMES[_forge_slots[0].selected]
	var r2: String = RESOURCE_NAMES[_forge_slots[1].selected]
	var r3: String = RESOURCE_NAMES[_forge_slots[2].selected]
	var cost: Dictionary = PlanetSeedKitchen.resource_cost(r1, r2, r3)

	for res in cost:
		if inv.get_amount(res) < cost[res]:
			_set_status("Need: " + _format_cost(cost) + "\nNot enough resources.", Color(1.0, 0.5, 0.3))
			return

	for res in cost:
		inv.consume(res, cost[res])

	var seed_val: int = PlanetSeedKitchen.make_seed(r1, r2, r3)
	var planet_node := _spawn_planet_node(seed_val)
	_active_planets.append({node = planet_node, r1 = r1, r2 = r2, r3 = r3})
	_refresh_planets_ui()

	var combo: String = RESOURCE_ABBREV[r1] + "+" + RESOURCE_ABBREV[r2] + "+" + RESOURCE_ABBREV[r3]
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

	var combo: String = RESOURCE_ABBREV[entry.r1] + "+" + RESOURCE_ABBREV[entry.r2] + "+" + RESOURCE_ABBREV[entry.r3]
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
		parts.append(str(cost[r]) + "× " + RESOURCE_ABBREV[r])
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

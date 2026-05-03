extends Node3D

# SpaceStation.gd
# A dockable station that lets the player:
#   1. Sell resources for credits
#   2. Forge new planets by spending 3 resource stacks
#
# UI auto-shows when the player enters DOCK_RANGE, hides when they leave.

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
var _panel: Panel = null
var _inv_label: Label = null
var _creds_label: Label = null
var _forge_slots: Array = []   # Array[OptionButton]
var _forge_status: Label = null
var _ui_visible: bool = false

# Track planets this station has forged so we can enforce the cap
var _active_planets: Array = []  # Array[Node3D]

func _ready() -> void:
	add_to_group("SpaceStation")
	_build_visual()
	_build_ui()

func _build_visual() -> void:
	# Toon-style angular station silhouette
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

	# Beacon ring
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

func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 130
	add_child(_ui_layer)

	_panel = Panel.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_panel.custom_minimum_size = Vector2(560, 640)
	_panel.offset_top = -320
	_panel.offset_left = -280
	_panel.offset_bottom = 320
	_panel.offset_right = 280
	_ui_layer.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	var _add_margin := func(parent: Container, top: int = 8) -> void:
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_top", top)
		parent.add_child(m)

	var title := Label.new()
	title.text = "[ SPACE STATION ]"
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color.CYAN)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	_creds_label = Label.new()
	_creds_label.text = "$0"
	_creds_label.add_theme_font_size_override("font_size", 26)
	_creds_label.add_theme_color_override("font_color", Color.GOLD)
	_creds_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_creds_label)

	_inv_label = Label.new()
	_inv_label.text = "Inventory: (empty)"
	_inv_label.add_theme_font_size_override("font_size", 20)
	_inv_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
	_inv_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_inv_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_inv_label)

	var sell_btn := Button.new()
	sell_btn.text = "Sell All Resources"
	sell_btn.add_theme_font_size_override("font_size", 22)
	sell_btn.pressed.connect(_on_sell_all)
	vbox.add_child(sell_btn)

	vbox.add_child(HSeparator.new())

	var forge_title := Label.new()
	forge_title.text = "— FORGE PLANET —\nChoose 3 resources (1 of each consumed)"
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
		# Default progression: slot 0=Cu, 1=Ag, 2=Au
		opt.selected = i
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

	var close_btn := Button.new()
	close_btn.text = "Close  [fly away]"
	close_btn.add_theme_font_size_override("font_size", 18)
	close_btn.pressed.connect(_hide_ui)
	vbox.add_child(close_btn)

	# Wire economy display
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.currency_changed.connect(func(n: int) -> void: _creds_label.text = "$" + str(n))
		_creds_label.text = "$" + str(econ.credits)

	# Wire inventory display
	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		inv.inventory_changed.connect(func(_t: String, _a: int) -> void: _refresh_inv_display())
		_refresh_inv_display()

	_panel.hide()

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
	_forge_status.text = ""

func _hide_ui() -> void:
	_ui_visible = false
	_panel.hide()

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
		_forge_status.text = "Sold for $" + str(total)
		_forge_status.add_theme_color_override("font_color", Color.GREEN)
	else:
		_forge_status.text = "Nothing to sell."
		_forge_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))

func _on_forge_planet() -> void:
	_forge_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))

	# Prune destroyed planets from tracking list
	_active_planets = _active_planets.filter(func(p): return is_instance_valid(p))

	if _active_planets.size() >= MAX_PLANETS:
		_forge_status.text = "Max " + str(MAX_PLANETS) + " planets reached.\nDestroy one first."
		return

	if not Engine.has_meta("InventoryManager"):
		return
	var inv = Engine.get_meta("InventoryManager")

	var r1: String = RESOURCE_NAMES[_forge_slots[0].selected]
	var r2: String = RESOURCE_NAMES[_forge_slots[1].selected]
	var r3: String = RESOURCE_NAMES[_forge_slots[2].selected]
	var cost: Dictionary = PlanetSeedKitchen.resource_cost(r1, r2, r3)

	# Check affordability
	for res in cost:
		if inv.get_amount(res) < cost[res]:
			_forge_status.text = "Need: " + _format_cost(cost) + "\nNot enough resources."
			return

	# Consume resources
	for res in cost:
		inv.consume(res, cost[res])

	# Compute deterministic seed and spawn planet
	var seed_val: int = PlanetSeedKitchen.make_seed(r1, r2, r3)
	_spawn_forged_planet(seed_val, r1, r2, r3)

	var combo = RESOURCE_ABBREV[r1] + "+" + RESOURCE_ABBREV[r2] + "+" + RESOURCE_ABBREV[r3]
	_forge_status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.6))
	_forge_status.text = "Planet forged! (" + combo + ")\nSeed: " + str(seed_val)

func _format_cost(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for r in cost:
		parts.append(str(cost[r]) + "× " + RESOURCE_ABBREV[r])
	return ",  ".join(parts)

func _spawn_forged_planet(seed_val: int, r1: String, r2: String, r3: String) -> void:
	var pg_script = load("res://src/world/PlanetGen.gd")
	if not pg_script:
		return

	# Scatter in a roughly orbital ring around the station
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_val
	var angle: float = rng.randf() * TAU
	var dist: float = rng.randf_range(4000000.0, 8000000.0)
	var height: float = rng.randf_range(-500000.0, 500000.0)
	var spawn_pos := global_position + Vector3(cos(angle) * dist, height, sin(angle) * dist)

	# Radius varies with seed — rarer combos make bigger worlds
	var base_radius: float = 600000.0 + float(seed_val % 1200) * 500.0
	# Diamond-heavy combos (seed divisible by 11) get the biggest worlds
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
	_active_planets.append(planet)

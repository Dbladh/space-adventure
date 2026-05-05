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
var _forge_slots: Array = []          # Array[OptionButton] (legacy, unused)
var _forge_selected: Array[String] = []  # Up to 3 chosen resource names
var _forge_card_grid: GridContainer = null
var _forge_slot_labels: Array = []    # 3 Label nodes showing chosen slots
var _forge_btn: Button = null
var _forge_status: Label = null
var _planets_container: VBoxContainer = null
var _worlds_header: Label = null
var _prompt_btn: Button = null
var _ui_visible: bool = false
var _in_range: bool = false
var _cinematic_active: bool = false

# Each entry: { node: Node3D, r1: String, r2: String, r3: String }
static var _active_planets: Array[Dictionary] = []

class ForgeSlot extends PanelContainer:
	var slot_index: int = 0
	var station_ref: Node = null
	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "resource"
	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		station_ref._on_card_pressed(data["res"])
	func _get_drag_data(_at_position: Vector2) -> Variant:
		if slot_index >= station_ref._forge_selected.size(): return null
		var r: String = station_ref._forge_selected[slot_index]
		var preview := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = station_ref._tier_color(ResourceRegistry.get_tier(r)).darkened(0.5)
		sb.content_margin_left = 10; sb.content_margin_right = 10
		sb.content_margin_top = 4; sb.content_margin_bottom = 4
		preview.add_theme_stylebox_override("panel", sb)
		var lbl := Label.new()
		lbl.text = ResourceRegistry.get_abbrev(r)
		preview.add_child(lbl)
		set_drag_preview(preview)
		station_ref._on_remove_slot(slot_index)
		return {"type": "removed_resource", "res": r}

class ResourceCard extends PanelContainer:
	var resource_id: String = ""
	var available_count: int = 0
	var station_ref: Node = null
	func _get_drag_data(_at_position: Vector2) -> Variant:
		if available_count <= 0 or station_ref._forge_selected.size() >= 3: return null
		var preview := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = station_ref._tier_color(ResourceRegistry.get_tier(resource_id)).darkened(0.5)
		sb.content_margin_left = 10; sb.content_margin_right = 10
		sb.content_margin_top = 4; sb.content_margin_bottom = 4
		preview.add_theme_stylebox_override("panel", sb)
		var lbl := Label.new()
		lbl.text = ResourceRegistry.get_abbrev(resource_id)
		preview.add_child(lbl)
		set_drag_preview(preview)
		return {"type": "resource", "res": resource_id}

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

	_prompt_btn = Button.new()
	_prompt_btn.text = "DOCK STATION [E]"
	_prompt_btn.add_theme_font_size_override("font_size", 24)
	_prompt_btn.add_theme_color_override("font_color", Color(0.3, 1.0, 0.5))
	_prompt_btn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_prompt_btn.offset_top = -140
	_prompt_btn.offset_bottom = -90
	_prompt_btn.offset_left = -160
	_prompt_btn.offset_right = 160
	_prompt_btn.pressed.connect(_on_dock_pressed)
	_prompt_btn.hide()
	_ui_layer.add_child(_prompt_btn)

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
	forge_title.text = "— FORGE PLANET —\nSelect 3 resources to consume"
	forge_title.add_theme_font_size_override("font_size", 20)
	forge_title.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	forge_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	forge_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(forge_title)

	# ── Selected slots row ──────────────────────────────────────────────
	var slots_row := HBoxContainer.new()
	slots_row.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_row.add_theme_constant_override("separation", 6)
	vbox.add_child(slots_row)

	for i in range(3):
		var slot_panel := ForgeSlot.new()
		slot_panel.slot_index = i
		slot_panel.station_ref = self
		
		var slot_sb := StyleBoxFlat.new()
		slot_sb.bg_color = Color(0.08, 0.08, 0.15)
		slot_sb.border_color = Color(0.4, 0.4, 0.6)
		slot_sb.set_border_width_all(2)
		slot_sb.set_corner_radius_all(6)
		slot_sb.content_margin_left = 6; slot_sb.content_margin_right = 6
		slot_sb.content_margin_top = 4;  slot_sb.content_margin_bottom = 4
		slot_panel.add_theme_stylebox_override("panel", slot_sb)
		slot_panel.custom_minimum_size = Vector2(90, 40)

		var slot_vb := VBoxContainer.new()
		slot_vb.alignment = BoxContainer.ALIGNMENT_CENTER
		slot_panel.add_child(slot_vb)

		var slot_lbl := Label.new()
		slot_lbl.text = "[ SLOT " + str(i + 1) + " ]"
		slot_lbl.add_theme_font_size_override("font_size", 14)
		slot_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		slot_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot_vb.add_child(slot_lbl)
		_forge_slot_labels.append(slot_lbl)

		# Keep the array populated for legacy sync, but hide the remove btn
		var remove_btn := Button.new()
		remove_btn.visible = false
		_forge_slots.append(remove_btn)

		slots_row.add_child(slot_panel)

	_forge_status = Label.new()
	_forge_status.text = ""
	_forge_status.add_theme_font_size_override("font_size", 15)
	_forge_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
	_forge_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_forge_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_forge_status)

	# ── Resource card grid ──────────────────────────────────────────────
	var card_title := Label.new()
	card_title.text = "Available Resources:"
	card_title.add_theme_font_size_override("font_size", 16)
	card_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(card_title)

	_forge_card_grid = GridContainer.new()
	_forge_card_grid.columns = 3
	_forge_card_grid.add_theme_constant_override("h_separation", 8)
	_forge_card_grid.add_theme_constant_override("v_separation", 8)
	vbox.add_child(_forge_card_grid)

	_forge_btn = Button.new()
	_forge_btn.text = "FORGE PLANET"
	_forge_btn.add_theme_font_size_override("font_size", 26)
	_forge_btn.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	_forge_btn.pressed.connect(_on_forge_planet)
	vbox.add_child(_forge_btn)

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
	_rebuild_forge_cards()

func _tier_color(tier: int) -> Color:
	match tier:
		1: return Color(0.75, 0.75, 0.75)   # Common — grey
		2: return Color(0.35, 0.85, 1.0)    # Uncommon — blue
		3: return Color(0.6,  0.3,  1.0)    # Rare — purple
		4: return Color(1.0,  0.55, 0.05)   # Legendary — gold
		_: return Color(0.55, 0.55, 0.55)

func _rebuild_forge_cards() -> void:
	if not _forge_card_grid: return
	for c in _forge_card_grid.get_children(): c.queue_free()
	if not Engine.has_meta("InventoryManager"): return

	var inv = Engine.get_meta("InventoryManager")
	var any_shown := false

	for r in ResourceRegistry.all_names():
		var amt: int = inv.get_amount(r)
		if amt <= 0: continue
		any_shown = true

		var tier := ResourceRegistry.get_tier(r)
		var rarity_col := _tier_color(tier)

		# Count how many times this resource is already selected
		var selected_count := _forge_selected.count(r)
		var available := amt - selected_count

		# Card outer panel
		var card := ResourceCard.new()
		card.resource_id = r
		card.available_count = available
		card.station_ref = self
		
		var sb := StyleBoxFlat.new()
		sb.bg_color = rarity_col.darkened(0.65)
		sb.border_color = rarity_col
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 6; sb.content_margin_right = 6
		sb.content_margin_top = 4;  sb.content_margin_bottom = 4
		card.add_theme_stylebox_override("panel", sb)
		card.custom_minimum_size = Vector2(100, 46)

		var vb := VBoxContainer.new()
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_theme_constant_override("separation", -2)
		card.add_child(vb)

		# Resource name
		var name_lbl := Label.new()
		name_lbl.text = ResourceRegistry.get_abbrev(r)
		name_lbl.add_theme_font_size_override("font_size", 15)
		name_lbl.add_theme_color_override("font_color", rarity_col)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(name_lbl)

		# Qty + tier badge row
		var sub_row := HBoxContainer.new()
		sub_row.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_child(sub_row)

		var qty_lbl := Label.new()
		qty_lbl.text = "x" + str(amt)
		if selected_count > 0:
			qty_lbl.text += " (" + str(available) + " left)"
		qty_lbl.add_theme_font_size_override("font_size", 12)
		qty_lbl.add_theme_color_override("font_color", Color(0.8, 0.8, 0.8))
		sub_row.add_child(qty_lbl)

		# Greyed out if none available or slots full
		var can_pick := available > 0 and _forge_selected.size() < 3
		if not can_pick:
			sb.bg_color = Color(0.08, 0.08, 0.1)
			sb.border_color = Color(0.25, 0.25, 0.3)
			name_lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
		elif available > 0:
			card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

		_forge_card_grid.add_child(card)

	if not any_shown:
		var empty_lbl := Label.new()
		empty_lbl.text = "(no eligible resources in inventory)"
		empty_lbl.add_theme_font_size_override("font_size", 16)
		empty_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_forge_card_grid.add_child(empty_lbl)

func _on_card_pressed(r: String) -> void:
	if _forge_selected.size() >= 3: return
	if not Engine.has_meta("InventoryManager"): return
	var inv = Engine.get_meta("InventoryManager")
	if inv.get_amount(r) - _forge_selected.count(r) <= 0: return
	_forge_selected.append(r)
	_update_slot_display()
	_rebuild_forge_cards()

func _on_remove_slot(idx: int) -> void:
	if idx >= _forge_selected.size(): return
	_forge_selected.remove_at(idx)
	_update_slot_display()
	_rebuild_forge_cards()

func _update_slot_display() -> void:
	for i in range(3):
		var lbl: Label = _forge_slot_labels[i]
		if i < _forge_selected.size():
			var r := _forge_selected[i]
			var tier := ResourceRegistry.get_tier(r)
			var col := _tier_color(tier)
			lbl.text = ResourceRegistry.get_abbrev(r)
			lbl.add_theme_color_override("font_color", col)
		else:
			lbl.text = "[ SLOT " + str(i + 1) + " ]"
			lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
	# Enable forge button only when all 3 slots filled
	if _forge_btn:
		_forge_btn.disabled = _forge_selected.size() < 3

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
		row.add_theme_constant_override("separation", 10)
		_planets_container.add_child(row)

		var combo: String = ResourceRegistry.get_abbrev(entry.r1) + "+" + ResourceRegistry.get_abbrev(entry.r2) + "+" + ResourceRegistry.get_abbrev(entry.r3)
		var seed_val: int = PlanetSeedKitchen.make_seed(entry.r1, entry.r2, entry.r3)
		var rank: Dictionary = PlanetSeedKitchen.rank_planet(entry.r1, entry.r2, entry.r3, seed_val)

		# ── Rank Badge ──────────────────────────────────────────────────
		var badge_panel := PanelContainer.new()
		var badge_sb := StyleBoxFlat.new()
		badge_sb.bg_color = rank.color.darkened(0.55)
		badge_sb.border_color = rank.color
		badge_sb.set_border_width_all(2)
		badge_sb.set_corner_radius_all(6)
		badge_sb.content_margin_left = 8; badge_sb.content_margin_right = 8
		badge_sb.content_margin_top = 2;  badge_sb.content_margin_bottom = 2
		badge_panel.add_theme_stylebox_override("panel", badge_sb)

		var badge_lbl := Label.new()
		badge_lbl.text = rank.label
		badge_lbl.add_theme_font_size_override("font_size", 16)
		badge_lbl.add_theme_color_override("font_color", rank.color)
		badge_panel.add_child(badge_lbl)
		row.add_child(badge_panel)

		# ── Planet name + combo ─────────────────────────────────────────
		var lbl := Label.new()
		lbl.text = combo
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
	if dist < DOCK_RANGE:
		if not _in_range:
			_in_range = true
			if not _ui_visible and not _cinematic_active:
				_prompt_btn.show()
	else:
		if _in_range:
			_in_range = false
			_prompt_btn.hide()
			if _ui_visible:
				_hide_ui()

func _input(event: InputEvent) -> void:
	if _ui_visible:
		if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
			_hide_ui()
			get_viewport().set_input_as_handled()
		return

	if _in_range and not _ui_visible:
		if event is InputEventKey and event.keycode == KEY_E and event.pressed and not event.echo:
			_on_dock_pressed()
			get_viewport().set_input_as_handled()
		elif event is InputEventJoypadButton and event.button_index == JOY_BUTTON_X and event.pressed:
			_on_dock_pressed()
			get_viewport().set_input_as_handled()

func _on_dock_pressed() -> void:
	_prompt_btn.hide()
	_show_ui()

var _hud_was_visible: Array = []   # snapshot of HUD nodes hidden by _show_ui

func _show_ui() -> void:
	_ui_visible = true
	_panel.show()
	_refresh_inv_display()
	_refresh_planets_ui()
	_forge_status.text = ""
	_update_slot_display()
	# Hide all gameplay HUD and freeze the world while docked.
	# Snapshot only nodes that are currently visible so we restore exactly
	# that set on close — otherwise force-showing children un-hides the
	# debug FPS overlay (and anything else the user toggled off).
	_hud_was_visible.clear()
	for node in get_tree().get_nodes_in_group("GameHUD"):
		if node is CanvasLayer:
			if node.visible:
				node.visible = false
				_hud_was_visible.append(node)
		elif "visible" in node and node.visible:
			node.visible = false
			_hud_was_visible.append(node)
	get_tree().paused = true
	# Enable mouse cursor for UI interaction
	if _player and _player.has_method("unlock_mouse"):
		_player.unlock_mouse()

func _hide_ui() -> void:
	_ui_visible = false
	_panel.hide()
	if _in_range:
		_prompt_btn.show()

	# Restore gameplay HUD and unpause — only the nodes WE hid, so the
	# diag overlay / debug suite / anything else stays hidden if it was.
	get_tree().paused = false
	for node in _hud_was_visible:
		if is_instance_valid(node):
			node.visible = true
	_hud_was_visible.clear()
	# Lock mouse cursor back for gameplay
	if _player and _player.has_method("lock_mouse"):
		_player.lock_mouse()

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

	if _forge_selected.size() < 3:
		_set_status("Select 3 resources first.", Color(1.0, 0.5, 0.3))
		return

	if not Engine.has_meta("InventoryManager"):
		return
	var inv = Engine.get_meta("InventoryManager")

	var r1: String = _forge_selected[0]
	var r2: String = _forge_selected[1]
	var r3: String = _forge_selected[2]
	var cost: Dictionary = PlanetSeedKitchen.resource_cost(r1, r2, r3)

	for res in cost:
		if inv.get_amount(res) < cost[res]:
			_set_status("Need: " + _format_cost(cost) + "\nNot enough resources.", Color(1.0, 0.5, 0.3))
			return

	# Launch Placement UI
	var p_ui = load("res://src/ui/PlanetPlacementUI.gd").new()
	_ui_layer.add_child(p_ui)
	_panel.hide()

	p_ui.placement_canceled.connect(func():
		_panel.show()
	)

	p_ui.placement_confirmed.connect(func(pos: Vector3, p_name: String):
		_hide_ui() # Close station UI immediately
		_cinematic_active = true
		_prompt_btn.hide()

		# 1. Consume resources
		for res in cost:
			inv.consume(res, cost[res])

		# 2. Spawn planet immediately (it will start generating in background)
		var pos_salt: int = hash(pos.round()) & 0x7FFFFFFF
		var seed_val: int = PlanetSeedKitchen.make_seed(r1, r2, r3) + (_active_planets.size() * 777) + pos_salt
		var planet_node := _spawn_planet_node(seed_val, pos, p_name)
		var planet_res := PlanetSeedKitchen.resources_for_planet(r1, r2, r3)
		planet_node.set("planet_resources", planet_res)
		_active_planets.append({node = planet_node, r1 = r1, r2 = r2, r3 = r3})
		_refresh_planets_ui()

		# 3. Clear selection for next forge
		_forge_selected.clear()
		_update_slot_display()

		# 4. Trigger Dramatic Forge Cinematic
		var cine_script = load("res://src/ui/ForgeCinematic.gd")
		var cinematic = cine_script.new()
		get_tree().root.add_child(cinematic)

		cinematic.setup(pos, _player, planet_node)

		cinematic.completed.connect(func():
			_cinematic_active = false
			var combo: String = ResourceRegistry.get_abbrev(r1) + "+" + ResourceRegistry.get_abbrev(r2) + "+" + ResourceRegistry.get_abbrev(r3)
			_set_status("Planet " + p_name + " forged! (" + combo + ")", Color(0.4, 1.0, 0.6))
		)
	)

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

func _spawn_planet_node(seed_val: int, custom_pos: Vector3, custom_name: String) -> Node3D:
	var pg_script = load("res://src/world/PlanetGen.gd")
	if not pg_script:
		return Node3D.new()

	var base_radius: float = 600000.0 + float(seed_val % 1200) * 500.0
	if seed_val % 11 == 0:
		base_radius *= 1.4

	var planet := Node3D.new()
	planet.set_script(pg_script)
	planet.name = "Planet_" + custom_name.replace(" ", "_")
	planet.set("planet_seed", seed_val)
	planet.set("planet_radius", base_radius)

	var world_root = get_tree().get_nodes_in_group("WorldRoot")
	if world_root.size() > 0:
		world_root[0].add_child(planet)
	else:
		get_tree().root.add_child(planet)

	planet.global_position = custom_pos
	planet.add_to_group("Planet")
	planet.add_to_group("ForgedPlanet")
	return planet

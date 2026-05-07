extends Node3D

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

# SpaceStation.gd
# Dockable station. Fly within DOCK_RANGE for the UI to auto-open.
#   • Sell All  — converts held resources to credits
#   • Forge     — spend 3 resource slots to spawn a deterministic planet
#   • Dismantle — destroy a forged planet and recover the resources

const DOCK_RANGE: float = 2000000.0   # 2000 km — Closer to the model surface
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

# ACE SIGNALS: Notify the universe of major system changes
signal planet_forged(count: int)

# Market panel references
var _market_scroll: ScrollContainer = null
var _market_rows_vbox: VBoxContainer = null
var _market_status: Label = null
const BUY_MARKUP: float = 1.8

# Tab references
var _tab_btns: Array = []  # [market_btn, forge_btn]
var _active_tab: int = 0  # 0 = Market, 1 = Forge
var _tab_market_panel: Control = null
var _tab_forge_panel: Control = null

# Gamepad cursor/focus
var _virtual_cursor: ColorRect = null
var _last_mouse_pos: Vector2 = Vector2.ZERO

# Each entry: { node: Node3D, r1: String, r2: String, r3: String }
static var _active_planets: Array[Dictionary] = []

class ForgeSlot extends PanelContainer:
	var slot_index: int = 0
	var station_ref: Node = null
	func _init() -> void:
		# Gamepad navigation: focusable so ui_accept (Enter / gamepad A)
		# triggers the same "remove this slot" action that drag-out does.
		focus_mode = Control.FOCUS_ALL
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
	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept"):
			if station_ref and slot_index < station_ref._forge_selected.size():
				station_ref._on_remove_slot(slot_index)
				accept_event()

class ResourceCard extends PanelContainer:
	var resource_id: String = ""
	var available_count: int = 0
	var station_ref: Node = null
	func _init() -> void:
		# Gamepad navigation: focusable so ui_accept (Enter / gamepad A)
		# triggers the same "add to forge" action that drag-in does.
		focus_mode = Control.FOCUS_ALL
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
	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept"):
			if station_ref and available_count > 0 and station_ref._forge_selected.size() < 3:
				station_ref._on_card_pressed(resource_id)
				accept_event()

func _ready() -> void:
	add_to_group("SpaceStation")
	# ALWAYS so the Close button and _process work even when tree is paused for docking
	process_mode = PROCESS_MODE_ALWAYS
	_build_visual()
	_build_ui()

# ---------------------------------------------------------------------------
# VISUAL
# ---------------------------------------------------------------------------

func _build_visual() -> void:
	# ACE ASSET INTEGRATION: Load the high-fidelity space station model 
	# Replacing legacy procedural primitives with 'The Gunsmith's' signature asset.
	var model_path := "res://assets/models/space station/space_station.glb"
	var station_scene: PackedScene = load(model_path)
	
	if station_scene:
		var instance = station_scene.instantiate()
		# ACE SCALE: The model is scaled to astronomical proportions (~300km)
		# to maintain consistent navigation telemetry across the system.
		# ACE MEGA-SCALE: 10x previous size. 3,000km diameter.
		instance.scale = Vector3(40000.0, 40000.0, 40000.0)
		add_child(instance)
		
		# ACE MATERIAL OVERHAUL: Injecting Normal Maps and Emission Glow
		_apply_station_materials(instance)
		
		# We hook into the existing rotation logic used for the procedural ring.
		# Now the entire station rotates majestically around its axis.
		_ring_node = instance
	else:
		# FALLBACK: Maintain structural integrity if asset is missing
		printerr("--- ARCHITECT: Space Station asset missing at [%s]. Using fallback. ---" % model_path)
		var sphere = MeshInstance3D.new()
		sphere.mesh = SphereMesh.new()
		sphere.mesh.radius = 1500000.0
		sphere.mesh.height = 3000000.0
		add_child(sphere)
		_ring_node = sphere

	# ── OmniLight so the station glows across the system ─────────────
	var light := OmniLight3D.new()
	light.light_color = Color(0.3, 0.7, 1.0)
	light.light_energy = 8.0
	light.omni_range   = 3000000.0 * 10.0
	add_child(light)

func _apply_station_materials(node: Node) -> void:
	# ACE: Explicitly load textures to ensure they are assigned correctly
	var tex_albedo = load("res://assets/models/space station/space_station_0.jpg")
	var tex_normal = load("res://assets/models/space station/space_station_2.jpg")
	var tex_emission = load("res://assets/models/space station/space_station_3.jpg")

	for child in node.get_children():
		if child is MeshInstance3D:
			var body := StaticBody3D.new()
			# Layer 8: Space Station (Special-cased for negligible damage)
			body.collision_layer = 8 
			child.add_child(body)
			
			var coll_node := CollisionShape3D.new()
			coll_node.shape = child.mesh.create_trimesh_shape()
			body.add_child(coll_node)

			# ACE: The model may have multiple surfaces; we must iterate and enhance each.
			for i in range(child.mesh.get_surface_count()):
				var mat = child.get_active_material(i)
				if mat is StandardMaterial3D:
					var new_mat = mat.duplicate()
					
					# ACE TEXTURE SYNC: Explicitly assigning maps to avoid null-defaults
					new_mat.albedo_texture = tex_albedo
					
					new_mat.normal_enabled = true
					new_mat.normal_texture = tex_normal
					
					# ACE EMISSION MASKING: Using the dedicated light-mask (space_station_3.jpg)
					# to ensure only the actual fixtures glow, not the hull plating.
					new_mat.emission_enabled = true
					new_mat.emission_texture = tex_emission
					new_mat.emission = Color(1.0, 0.9, 0.4)
					new_mat.emission_energy_multiplier = 8.0
					
					child.set_surface_override_material(i, new_mat)
		_apply_station_materials(child)

# ---------------------------------------------------------------------------
# UI BUILD
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_ui_layer = CanvasLayer.new()
	_ui_layer.layer = 130
	# ALWAYS so buttons remain interactive while the gameplay tree is paused
	_ui_layer.process_mode = PROCESS_MODE_ALWAYS
	add_child(_ui_layer)

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

	# Use a ScrollContainer so the panel adapts to variable planet list height
	_market_scroll = ScrollContainer.new()
	_market_scroll.process_mode = PROCESS_MODE_ALWAYS
	_market_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_market_scroll.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_market_scroll.custom_minimum_size = Vector2(560, 680)
	_market_scroll.offset_top    = -340
	_market_scroll.offset_left   = -280
	_market_scroll.offset_bottom =  340
	_market_scroll.offset_right  =  280
	_market_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_ui_layer.add_child(_market_scroll)
	_panel = _market_scroll

	var vbox := VBoxContainer.new()
	vbox.process_mode = PROCESS_MODE_ALWAYS
	vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	_market_scroll.add_child(vbox)

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

	# ---- Tabs: MARKET | FORGE ----
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab_row)

	for tab_i in range(2):
		var tab_lbl: String = ["  MARKET  ", "  FORGE  "][tab_i]
		var tb: Button = Button.new()
		tb.text = tab_lbl
		tb.add_theme_font_size_override("font_size", 20)
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var captured_i: int = tab_i
		tb.pressed.connect(func() -> void: _switch_tab(captured_i))
		tab_row.add_child(tb)
		_tab_btns.append(tb)

	# ======================== MARKET TAB ========================
	_tab_market_panel = VBoxContainer.new()
	_tab_market_panel.add_theme_constant_override("separation", 8)
	_tab_market_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tab_market_panel)

	_market_status = Label.new()
	_market_status.text = ""
	_market_status.add_theme_font_size_override("font_size", 15)
	_market_status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	_market_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_market_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tab_market_panel.add_child(_market_status)

	# Column header row
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 4)
	_tab_market_panel.add_child(header_row)
	for col_text in ["Resource", "Held", "Sell", "Buy"]:
		var h := Label.new()
		h.text = col_text
		h.add_theme_font_size_override("font_size", 13)
		h.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		h.size_flags_horizontal = Control.SIZE_EXPAND_FILL if col_text == "Resource" else Control.SIZE_SHRINK_CENTER
		h.custom_minimum_size.x = 90 if col_text == "Resource" else 58
		header_row.add_child(h)

	_market_rows_vbox = VBoxContainer.new()
	_market_rows_vbox.add_theme_constant_override("separation", 4)
	_tab_market_panel.add_child(_market_rows_vbox)

	var sell_all_btn := Button.new()
	sell_all_btn.text = "Sell ALL Resources"
	sell_all_btn.add_theme_font_size_override("font_size", 20)
	sell_all_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	sell_all_btn.pressed.connect(_on_sell_all)
	_tab_market_panel.add_child(sell_all_btn)

	# ======================== FORGE TAB ========================
	_tab_forge_panel = VBoxContainer.new()
	_tab_forge_panel.add_theme_constant_override("separation", 8)
	_tab_forge_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tab_forge_panel)

	var forge_title := Label.new()
	forge_title.text = "— FORGE PLANET —\nDrag 3 resources into the slots"
	forge_title.add_theme_font_size_override("font_size", 20)
	forge_title.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	forge_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	forge_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tab_forge_panel.add_child(forge_title)

	# ── Selected slots row (inside forge tab) ──────────────────────────
	var slots_row := HBoxContainer.new()
	slots_row.alignment = BoxContainer.ALIGNMENT_CENTER
	slots_row.add_theme_constant_override("separation", 6)
	_tab_forge_panel.add_child(slots_row)

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
	_tab_forge_panel.add_child(_forge_status)

	# ── Resource card grid (inside forge tab) ──────────────────────────
	var card_title := Label.new()
	card_title.text = "Available Resources:"
	card_title.add_theme_font_size_override("font_size", 16)
	card_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_tab_forge_panel.add_child(card_title)

	_forge_card_grid = GridContainer.new()
	_forge_card_grid.columns = 3
	_forge_card_grid.add_theme_constant_override("h_separation", 8)
	_forge_card_grid.add_theme_constant_override("v_separation", 8)
	_tab_forge_panel.add_child(_forge_card_grid)

	_forge_btn = Button.new()
	_forge_btn.text = "FORGE PLANET"
	_forge_btn.add_theme_font_size_override("font_size", 26)
	_forge_btn.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	_forge_btn.pressed.connect(_on_forge_planet)
	_tab_forge_panel.add_child(_forge_btn)

	vbox.add_child(HSeparator.new())

	# ---- Active Worlds (always visible below tabs) ----
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
	_rebuild_market_rows()

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

	# Gamepad: card grid was just rebuilt, so any previously-focused card
	# is gone.  If the user was navigating with a controller, drop focus
	# onto the first usable card so they can keep selecting; if none is
	# usable, fall through to the Forge button (handled in caller).
	_grab_first_usable_card_focus_deferred()


func _grab_first_usable_card_focus_deferred() -> void:
	# Defer one frame so the new cards are inside the tree before we ask
	# for focus — grab_focus on a freshly-added Control is a no-op.
	call_deferred("_grab_first_usable_card_focus")


func _grab_first_usable_card_focus() -> void:
	if _forge_card_grid == null: return
	# Only steal focus if the previously-focused control is gone (i.e. it
	# was a card we just freed) — otherwise the user might have moved to
	# a slot or the Forge button and we'd yank them back.
	var f: Control = get_viewport().gui_get_focus_owner()
	if f != null and is_instance_valid(f): return
	for c in _forge_card_grid.get_children():
		if c is ResourceCard:
			var card: ResourceCard = c
			if card.available_count > 0 and _forge_selected.size() < 3:
				card.grab_focus()
				return
	# No usable cards left — try the Forge Planet button.
	if _forge_btn and not _forge_btn.disabled:
		_forge_btn.grab_focus()

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

	# GAMEPAD CURSOR: Scroll menu with right stick when UI is visible
	if _ui_visible:
		_handle_gamepad_cursor(delta)

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

	# Hide the DOCK prompt while the pause menu is up so the prompt
	# button can't steal focus from the pause-menu Resume button.
	# (process_mode = ALWAYS means this node still ticks during pause.)
	if _prompt_btn.visible and get_tree().paused:
		_prompt_btn.hide()
	elif not _prompt_btn.visible and _in_range and not _ui_visible \
			and not _cinematic_active and not get_tree().paused:
		_prompt_btn.show()

func _input(event: InputEvent) -> void:
	# Close-menu input — Escape OR gamepad B (ui_cancel) OR gamepad START.
	# Pre-empts the global pause handler so pressing pause-while-docked
	# closes the station menu instead of layering the pause overlay on
	# top of it.  Only intercept when the UI is actually open so
	# button mouse clicks aren't blocked.
	if _ui_visible:
		var close_pressed := false
		if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
			close_pressed = true
		elif event is InputEventJoypadButton and event.pressed:
			if event.button_index == JOY_BUTTON_START or event.button_index == JOY_BUTTON_B:
				close_pressed = true
		if close_pressed:
			_hide_ui()
			get_viewport().set_input_as_handled()
			return

	# Don't allow docking while the pause overlay owns the screen — the
	# station UI would render behind a paused tree and look broken.
	if _in_range and not _ui_visible and not get_tree().paused:
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
	_rebuild_market_rows()
	_refresh_planets_ui()
	_forge_status.text = ""
	_market_status.text = ""
	_update_slot_display()
	_switch_tab(0)  # Always open on Market tab

	# GRAB FOCUS for gamepad navigation
	if _tab_btns.size() > 0:
		_tab_btns[0].grab_focus()
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
	# Freeze the player in place WITHOUT pausing the scene tree.
	# get_tree().paused breaks Godot 4's Viewport GUI event routing,
	# preventing all button clicks from registering.
	if _player:
		_player.set_physics_process(false)
		_player.set_process(false)
		if _player.has_method("unlock_mouse"):
			_player.unlock_mouse()

func _hide_ui() -> void:
	_ui_visible = false
	_panel.hide()
	if _in_range:
		_prompt_btn.show()
	# Restore player movement and HUD.
	if _player:
		_player.set_physics_process(true)
		_player.set_process(true)
		if _player.has_method("lock_mouse"):
			_player.lock_mouse()
	for node in _hud_was_visible:
		if is_instance_valid(node):
			node.visible = true
	_hud_was_visible.clear()

func _switch_tab(idx: int) -> void:
	_active_tab = idx
	if _tab_market_panel: _tab_market_panel.visible = (idx == 0)
	if _tab_forge_panel:  _tab_forge_panel.visible  = (idx == 1)
	# Style active tab btn brighter, inactive dimmed
	for i in _tab_btns.size():
		var btn: Button = _tab_btns[i]
		if i == idx:
			btn.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
			btn.add_theme_stylebox_override("normal", _tab_active_style())
		else:
			btn.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
			btn.remove_theme_stylebox_override("normal")
	# Gamepad: move focus into the newly-visible tab so the next A press
	# acts on real content rather than re-firing the tab button.
	# Only re-grab if focus is currently on a tab button (i.e. the user
	# just navigated here); otherwise leave focus alone.
	var f: Control = get_viewport().gui_get_focus_owner()
	if f != null and f in _tab_btns:
		call_deferred("_grab_first_in_active_tab")


func _grab_first_in_active_tab() -> void:
	var panel: Control = _tab_market_panel if _active_tab == 0 else _tab_forge_panel
	if panel == null: return
	var first := _find_first_focusable(panel)
	if first: first.grab_focus()


func _find_first_focusable(n: Node) -> Control:
	# Depth-first walk to the first Control that accepts focus.
	if n is Control:
		var c: Control = n
		if c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree():
			return c
	for child in n.get_children():
		var found := _find_first_focusable(child)
		if found: return found
	return null

func _tab_active_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.14, 0.25)
	sb.border_color = Color(0.4, 0.8, 1.0)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8; sb.content_margin_right = 8
	sb.content_margin_top = 6;  sb.content_margin_bottom = 6
	return sb

func _handle_gamepad_cursor(delta: float) -> void:
	# Right stick scrolls the menu — no warp_mouse (that breaks hover detection)
	var scroll_y := Input.get_axis("ui_up", "ui_down")
	if abs(scroll_y) > 0.15 and _market_scroll:
		_market_scroll.scroll_vertical += int(scroll_y * 1000.0 * delta)

	# Left stick also moves the actual OS mouse cursor for button selection
	var mx := Input.get_axis("ui_left", "ui_right")
	var my := Input.get_axis("ui_up", "ui_down")
	if Vector2(mx, my).length() > 0.15:
		var vp := get_viewport()
		var new_pos := vp.get_mouse_position() + Vector2(mx, my) * 1000.0 * delta
		# Clamp inside viewport
		new_pos.x = clamp(new_pos.x, 0.0, vp.get_visible_rect().size.x)
		new_pos.y = clamp(new_pos.y, 0.0, vp.get_visible_rect().size.y)
		vp.warp_mouse(new_pos)


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
		_set_market_status("+$" + str(total) + " — Sold everything!", Color(0.4, 1.0, 0.7))
	else:
		_set_market_status("Nothing to sell.", Color(1.0, 0.5, 0.3))
	_refresh_inv_display()

func _on_sell_one(resource_type: String) -> void:
	if not Engine.has_meta("InventoryManager") or not Engine.has_meta("EconomyManager"): return
	var inv = Engine.get_meta("InventoryManager")
	var econ = Engine.get_meta("EconomyManager")
	if inv.get_amount(resource_type) <= 0:
		_set_market_status("None in inventory.", Color(1.0, 0.5, 0.3))
		return
	var sell_price: int = ResourceRegistry.get_value(resource_type)
	inv.consume(resource_type, 1)
	econ.add_credits(sell_price)
	_set_market_status("+$" + str(sell_price) + " for " + resource_type, Color(0.4, 1.0, 0.7))
	_refresh_inv_display()

func _on_buy_one(resource_type: String) -> void:
	if not Engine.has_meta("InventoryManager") or not Engine.has_meta("EconomyManager"): return
	var inv = Engine.get_meta("InventoryManager")
	var econ = Engine.get_meta("EconomyManager")
	var buy_price: int = int(ResourceRegistry.get_value(resource_type) * BUY_MARKUP)
	if econ.credits < buy_price:
		_set_market_status("Need $" + str(buy_price) + " to buy " + resource_type, Color(1.0, 0.5, 0.3))
		return
	econ.credits -= buy_price
	econ.emit_signal("currency_changed", econ.credits)
	inv.add(resource_type, 1)
	_set_market_status("-$" + str(buy_price) + " — Bought " + resource_type, Color(1.0, 0.85, 0.3))
	_refresh_inv_display()

func _set_market_status(msg: String, col: Color) -> void:
	if _market_status:
		_market_status.text = msg
		_market_status.add_theme_color_override("font_color", col)

func _rebuild_market_rows() -> void:
	if not _market_rows_vbox: return
	for c in _market_rows_vbox.get_children(): c.queue_free()

	var inv_ref = Engine.get_meta("InventoryManager") if Engine.has_meta("InventoryManager") else null
	var econ_ref = Engine.get_meta("EconomyManager") if Engine.has_meta("EconomyManager") else null

	for r in ResourceRegistry.all_names():
		var tier: int = ResourceRegistry.get_tier(r)
		var rarity_col: Color = _tier_color(tier)
		var sell_val: int = ResourceRegistry.get_value(r)
		var buy_price: int = int(sell_val * BUY_MARKUP)
		var held: int = inv_ref.get_amount(r) if inv_ref else 0
		var credits_val: int = econ_ref.credits if econ_ref else 0

		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		_market_rows_vbox.add_child(row)

		# ── Resource name badge ────────────────────────────────────────
		var name_panel: PanelContainer = PanelContainer.new()
		var name_sb: StyleBoxFlat = StyleBoxFlat.new()
		name_sb.bg_color = rarity_col.darkened(0.72)
		name_sb.border_color = rarity_col.darkened(0.2)
		name_sb.set_border_width_all(1)
		name_sb.set_corner_radius_all(4)
		name_sb.content_margin_left = 6; name_sb.content_margin_right = 6
		name_sb.content_margin_top = 2;  name_sb.content_margin_bottom = 2
		name_panel.add_theme_stylebox_override("panel", name_sb)
		name_panel.custom_minimum_size = Vector2(90, 30)
		name_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = r
		name_lbl.add_theme_font_size_override("font_size", 13)
		name_lbl.add_theme_color_override("font_color", rarity_col)
		name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_panel.add_child(name_lbl)
		row.add_child(name_panel)

		# ── Held qty ──────────────────────────────────────────────────
		var held_lbl := Label.new()
		held_lbl.text = "x" + str(held)
		held_lbl.add_theme_font_size_override("font_size", 14)
		held_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0) if held > 0 else Color(0.4, 0.4, 0.4))
		held_lbl.custom_minimum_size = Vector2(46, 0)
		held_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		held_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(held_lbl)

		# ── Sell button ───────────────────────────────────────────────
		var sell_btn: Button = Button.new()
		sell_btn.text = "$" + str(sell_val)
		sell_btn.add_theme_font_size_override("font_size", 13)
		sell_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
		sell_btn.custom_minimum_size = Vector2(58, 28)
		sell_btn.disabled = held <= 0
		var sell_r: String = r  # capture
		sell_btn.pressed.connect(func() -> void: _on_sell_one(sell_r))
		row.add_child(sell_btn)

		# ── Buy button ────────────────────────────────────────────────
		var buy_btn: Button = Button.new()
		buy_btn.text = "$" + str(buy_price)
		buy_btn.add_theme_font_size_override("font_size", 13)
		buy_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		buy_btn.custom_minimum_size = Vector2(58, 28)
		buy_btn.disabled = credits_val < buy_price
		var buy_r: String = r  # capture
		buy_btn.pressed.connect(func() -> void: _on_buy_one(buy_r))
		row.add_child(buy_btn)


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
		var rank: Dictionary = PlanetSeedKitchen.rank_planet(r1, r2, r3, seed_val)
		planet_node.set("planet_rank", String(rank.get("label", "")))
		# (Impostor activation is deferred to the cinematic — the planet stays
		# hidden until the flash peaks and is revealed there.)

		# Record to persistent registry
		_active_planets.append({node=planet_node, r1=r1, r2=r2, r3=r3})
		
		# ACE UNIVERSE SYNC: Notify that a planet was added
		planet_forged.emit(_active_planets.size())
		
		_refresh_planets_ui()

		# 3. Clear selection for next forge
		_forge_selected.clear()
		_update_slot_display()

		# 4. Trigger Dramatic Forge Cinematic — pass the colours of the three
		# forged resources so the converging motes match what was consumed.
		var cine_script = load("res://src/ui/ForgeCinematic.gd")
		var cinematic = cine_script.new()
		get_tree().root.add_child(cinematic)

		var mote_cols: Array = [
			ResourceRegistry.get_color(r1),
			ResourceRegistry.get_color(r2),
			ResourceRegistry.get_color(r3),
		]
		cinematic.setup(pos, _player, planet_node, mote_cols)

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
	print("--- FORGE: Spawning Planet Node at %s ---" % str(custom_pos))
	var pg_script = load("res://src/world/PlanetGen.gd")
	if not pg_script:
		return Node3D.new()

	var base_radius: float = 60000.0 + float(seed_val % 800) * 60.0
	if seed_val % 11 == 0:
		base_radius *= 1.3

	var planet := Node3D.new()
	planet.set_script(pg_script)
	planet.name = "Planet_" + custom_name.replace(" ", "_")
	planet.set("planet_seed", seed_val)
	planet.set("planet_radius", base_radius)
	planet.add_to_group("Planet")
	planet.add_to_group("ForgedPlanet")

	var world_root = get_tree().get_nodes_in_group("WorldRoot")
	if world_root.size() > 0:
		print("--- FORGE: Attaching Planet [%s] to WorldRoot at %s ---" % [planet.name, str(custom_pos)])
		world_root[0].add_child(planet)
	else:
		get_tree().root.add_child(planet)
	# Set global_position AFTER reparenting so Godot computes the correct
	# local offset against WorldRoot's transform.  Setting it before
	# add_child treated custom_pos as a local position, so once the
	# floating-origin system shifted WorldRoot to track the player, every
	# new planet landed at (WorldRoot.global_position + custom_pos)
	# instead of custom_pos — the off-target forge cinematic camera.
	planet.global_position = custom_pos

	return planet

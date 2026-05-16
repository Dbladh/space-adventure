extends Node3D

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

# SpaceStation.gd
# Dockable station. Fly within DOCK_RANGE for the UI to auto-open.
#   • Sell All  — converts held resources to credits
#   • Forge     — spend 3 resource slots to spawn a deterministic planet
#   • Dismantle — destroy a forged planet and recover the resources

const DOCK_RANGE: float = 2000000.0   # 2000 km — Closer to the model surface
const _DEFAULT_MAX_PLANETS: int = 1   # starting cap before any Forge Slot upgrades

# Mobile UI sizing — panel margins, tap-target heights, column widths, fonts.
# Desktop keeps the existing compact 560×680 layout; mobile expands the panel
# to near-full-width and grows every button to a 44+ pt tap target.
const _PANEL_MARGIN_MOBILE: int = 20
const _BTN_H_MOBILE: int = 52
const _BTN_MIN_W_MOBILE: int = 96
const _NAME_COL_MIN_MOBILE: int = 140
const _HELD_COL_MIN_MOBILE: int = 64
const _TAB_H_MOBILE: int = 56
const _BIGBTN_H_MOBILE: int = 56
const _FORGE_BTN_H_MOBILE: int = 64
const _FORGE_SLOT_W_MOBILE: int = 130
const _FORGE_SLOT_H_MOBILE: int = 72
const _FORGE_CARD_W_MOBILE: int = 150
const _FORGE_CARD_H_MOBILE: int = 72
const _UPGRADE_BTN_H_MOBILE: int = 52
const _UPGRADE_RIGHT_W_MOBILE: int = 280
var _is_mobile_ui: bool = MobilePerf.is_mobile()

static func _max_planets() -> int:
	if Engine.has_meta("UpgradeManager"):
		return int(Engine.get_meta("UpgradeManager").get_forge_slots())
	return _DEFAULT_MAX_PLANETS

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
var _tab_btns: Array = []  # [market_btn, forge_btn, upgrades_btn]
var _active_tab: int = 0  # 0 = Market, 1 = Forge, 2 = Upgrades
var _tab_market_panel: Control = null
var _tab_forge_panel: Control = null
var _tab_upgrades_panel: Control = null
var _upgrade_rows: Dictionary = {}  # track -> PanelContainer
var _upgrades_status: Label = null

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
		# On mobile, drag-and-drop competes with ScrollContainer touch
		# scrolling. Tap-to-remove (below) covers the same intent.
		if station_ref and station_ref._is_mobile_ui: return null
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
		# Mobile tap-to-remove. Fire on RELEASE, not press — so a swipe-to-
		# scroll inside the panel gets stolen by ScrollContainer mid-drag and
		# the release never reaches us. Only a clean tap fires.
		elif station_ref and station_ref._is_mobile_ui \
				and event is InputEventMouseButton \
				and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			if slot_index < station_ref._forge_selected.size():
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
		# On mobile, drag-and-drop competes with ScrollContainer touch
		# scrolling. Tap-to-add (below) covers the same intent.
		if station_ref and station_ref._is_mobile_ui: return null
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
		# Mobile tap-to-add. Fire on RELEASE, not press — so a swipe-to-scroll
		# over a card gets stolen by the ScrollContainer mid-drag and the
		# release never reaches us. Only a clean tap fires.
		elif station_ref and station_ref._is_mobile_ui \
				and event is InputEventMouseButton \
				and not event.pressed \
				and event.button_index == MOUSE_BUTTON_LEFT:
			if available_count > 0 and station_ref._forge_selected.size() < 3:
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
					# 8x looks great with glow on desktop, but on mobile (glow
					# disabled, low FSR scale) the emission texture clips to
					# pure white and bleaches the entire silhouette. 2x keeps
					# the lit-windows read without the bleach.
					new_mat.emission_energy_multiplier = 2.0 if MobilePerf.is_mobile() else 8.0
					
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
	if _is_mobile_ui:
		_market_scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_market_scroll.custom_minimum_size = Vector2.ZERO
		_market_scroll.offset_left    =  _PANEL_MARGIN_MOBILE
		_market_scroll.offset_right   = -_PANEL_MARGIN_MOBILE
		_market_scroll.offset_top     =  _PANEL_MARGIN_MOBILE
		_market_scroll.offset_bottom  = -_PANEL_MARGIN_MOBILE
	else:
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
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", 34)
	title.add_theme_color_override("font_color", Color.CYAN)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# ---- Credits ----
	_creds_label = Label.new()
	_creds_label.text = "$0"
	_creds_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_creds_label.add_theme_font_size_override("font_size", 26)
	_creds_label.add_theme_color_override("font_color", Color.GOLD)
	_creds_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_creds_label)

	# ---- Inventory ----
	_inv_label = Label.new()
	_inv_label.text = "Inventory: (empty)"
	_inv_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
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

	for tab_i in range(3):
		var tab_lbl: String = ["  MARKET  ", "  FORGE  ", "  UPGRADES  "][tab_i]
		var tb: Button = Button.new()
		tb.text = tab_lbl
		tb.add_theme_font_size_override("font_size", 22 if _is_mobile_ui else 20)
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if _is_mobile_ui:
			tb.custom_minimum_size = Vector2(0, _TAB_H_MOBILE)
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
	_market_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_market_status.add_theme_font_size_override("font_size", 15)
	_market_status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	_market_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_market_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tab_market_panel.add_child(_market_status)

	# Column header row
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 8 if _is_mobile_ui else 4)
	_tab_market_panel.add_child(header_row)
	for col_text in ["Resource", "Held", "Sell", "Buy"]:
		var h := Label.new()
		h.text = col_text
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_theme_font_size_override("font_size", 17 if _is_mobile_ui else 13)
		h.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		if _is_mobile_ui:
			# Resource label centers within its own column; Held/Sell/Buy stretch
			# to consume horizontal space so the buttons below them grow with the
			# screen width.
			if col_text == "Resource":
				h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				h.custom_minimum_size.x = _NAME_COL_MIN_MOBILE
			else:
				h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				h.custom_minimum_size.x = _HELD_COL_MIN_MOBILE if col_text == "Held" else _BTN_MIN_W_MOBILE
				h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		else:
			h.size_flags_horizontal = Control.SIZE_EXPAND_FILL if col_text == "Resource" else Control.SIZE_SHRINK_CENTER
			h.custom_minimum_size.x = 90 if col_text == "Resource" else 58
		header_row.add_child(h)

	_market_rows_vbox = VBoxContainer.new()
	_market_rows_vbox.add_theme_constant_override("separation", 8 if _is_mobile_ui else 4)
	_tab_market_panel.add_child(_market_rows_vbox)

	var sell_all_btn := Button.new()
	sell_all_btn.text = "Sell ALL Resources"
	sell_all_btn.add_theme_font_size_override("font_size", 22 if _is_mobile_ui else 20)
	sell_all_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	if _is_mobile_ui:
		sell_all_btn.custom_minimum_size = Vector2(0, _BIGBTN_H_MOBILE)
	sell_all_btn.pressed.connect(_on_sell_all)
	_tab_market_panel.add_child(sell_all_btn)

	# ======================== FORGE TAB ========================
	_tab_forge_panel = VBoxContainer.new()
	_tab_forge_panel.add_theme_constant_override("separation", 8)
	_tab_forge_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tab_forge_panel)

	var forge_title := Label.new()
	forge_title.text = "— FORGE PLANET —\n" + ("Tap 3 resources to fill the slots" if _is_mobile_ui else "Drag 3 resources into the slots")
	forge_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		slot_panel.custom_minimum_size = Vector2(_FORGE_SLOT_W_MOBILE, _FORGE_SLOT_H_MOBILE) if _is_mobile_ui else Vector2(90, 40)

		var slot_vb := VBoxContainer.new()
		slot_vb.alignment = BoxContainer.ALIGNMENT_CENTER
		slot_panel.add_child(slot_vb)

		var slot_lbl := Label.new()
		slot_lbl.text = "[ SLOT " + str(i + 1) + " ]"
		slot_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_lbl.add_theme_font_size_override("font_size", 17 if _is_mobile_ui else 14)
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
	_forge_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_forge_status.add_theme_font_size_override("font_size", 15)
	_forge_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
	_forge_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_forge_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tab_forge_panel.add_child(_forge_status)

	# ── Resource card grid (inside forge tab) ──────────────────────────
	var card_title := Label.new()
	card_title.text = "Available Resources:"
	card_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card_title.add_theme_font_size_override("font_size", 16)
	card_title.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	_tab_forge_panel.add_child(card_title)

	_forge_card_grid = GridContainer.new()
	_forge_card_grid.columns = 2 if _is_mobile_ui else 3
	_forge_card_grid.add_theme_constant_override("h_separation", 10 if _is_mobile_ui else 8)
	_forge_card_grid.add_theme_constant_override("v_separation", 10 if _is_mobile_ui else 8)
	_tab_forge_panel.add_child(_forge_card_grid)

	_forge_btn = Button.new()
	_forge_btn.text = "FORGE PLANET"
	_forge_btn.add_theme_font_size_override("font_size", 28 if _is_mobile_ui else 26)
	_forge_btn.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	if _is_mobile_ui:
		_forge_btn.custom_minimum_size = Vector2(0, _FORGE_BTN_H_MOBILE)
	_forge_btn.pressed.connect(_on_forge_planet)
	_tab_forge_panel.add_child(_forge_btn)

	# ---- Active Worlds (forge tab only — your forged planets live here) ----
	_tab_forge_panel.add_child(HSeparator.new())
	_worlds_header = Label.new()
	_worlds_header.text = "— ACTIVE WORLDS (0/" + str(_max_planets()) + ") —"
	_worlds_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_worlds_header.add_theme_font_size_override("font_size", 20)
	_worlds_header.add_theme_color_override("font_color", Color(0.6, 1.0, 0.8))
	_worlds_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tab_forge_panel.add_child(_worlds_header)

	_planets_container = VBoxContainer.new()
	_planets_container.add_theme_constant_override("separation", 6)
	_tab_forge_panel.add_child(_planets_container)

	# ======================== UPGRADES TAB ========================
	_tab_upgrades_panel = VBoxContainer.new()
	_tab_upgrades_panel.add_theme_constant_override("separation", 8)
	_tab_upgrades_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tab_upgrades_panel)
	_build_upgrades_panel(_tab_upgrades_panel)

	var close_btn := Button.new()
	close_btn.text = "Close  [fly away]"
	close_btn.add_theme_font_size_override("font_size", 22 if _is_mobile_ui else 18)
	if _is_mobile_ui:
		close_btn.custom_minimum_size = Vector2(0, _BIGBTN_H_MOBILE)
	close_btn.pressed.connect(_hide_ui)
	vbox.add_child(close_btn)

	# Wire signals
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.currency_changed.connect(func(n: int) -> void: _creds_label.text = "$" + str(n))
		_creds_label.text = "$" + str(econ.credits)

	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		inv.inventory_changed.connect(func(_t: String, _a: int) -> void:
			_refresh_inv_display()
			if _active_tab == 2:
				_rebuild_all_upgrade_rows())
		_refresh_inv_display()

	if Engine.has_meta("EconomyManager"):
		var econ2 = Engine.get_meta("EconomyManager")
		econ2.currency_changed.connect(func(_n: int) -> void:
			if _active_tab == 2:
				_rebuild_all_upgrade_rows())

	if Engine.has_meta("UpgradeManager"):
		var up = Engine.get_meta("UpgradeManager")
		up.upgrade_changed.connect(_on_upgrade_changed)
		up.upgrade_purchase_failed.connect(_on_upgrade_purchase_failed)

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
		if _is_mobile_ui:
			card.custom_minimum_size = Vector2(_FORGE_CARD_W_MOBILE, _FORGE_CARD_H_MOBILE)
			card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			card.custom_minimum_size = Vector2(100, 46)

		var vb := VBoxContainer.new()
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_theme_constant_override("separation", -2)
		card.add_child(vb)

		# Resource name
		var name_lbl := Label.new()
		name_lbl.text = ResourceRegistry.get_abbrev(r)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_lbl.add_theme_font_size_override("font_size", 18 if _is_mobile_ui else 15)
		name_lbl.add_theme_color_override("font_color", rarity_col)
		name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(name_lbl)

		# Qty + tier badge row
		var sub_row := HBoxContainer.new()
		sub_row.alignment = BoxContainer.ALIGNMENT_CENTER
		vb.add_child(sub_row)

		var qty_lbl := Label.new()
		qty_lbl.text = "x" + str(amt)
		qty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if selected_count > 0:
			qty_lbl.text += " (" + str(available) + " left)"
		qty_lbl.add_theme_font_size_override("font_size", 15 if _is_mobile_ui else 12)
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

	_worlds_header.text = "— ACTIVE WORLDS (" + str(_active_planets.size()) + "/" + str(_max_planets()) + ") —"

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
		var rank: Dictionary = PlanetSeedKitchen.rank_planet(entry.r1, entry.r2, entry.r3, seed_val, float(entry.get("luck_variance", 0.0)))

		# ── Planet thumbnail (4× the old 40px, crisp nearest-neighbour) ──
		var thumb := TextureRect.new()
		thumb.texture = _planet_thumbnail_for(entry)
		thumb.custom_minimum_size = Vector2(160, 160)
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(thumb)

		# Stack name + badge + combo vertically so the row stays compact next
		# to the larger thumbnail.
		var info_vb := VBoxContainer.new()
		info_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		info_vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		info_vb.add_theme_constant_override("separation", 6)
		row.add_child(info_vb)

		# ── Planet name ────────────────────────────────────────────────
		var name_lbl := Label.new()
		name_lbl.text = _display_planet_name(entry)
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_lbl.add_theme_font_size_override("font_size", 20 if _is_mobile_ui else 18)
		name_lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 1.0))
		info_vb.add_child(name_lbl)

		# ── Rank Badge + Combo on one line ──────────────────────────────
		var sub_row := HBoxContainer.new()
		sub_row.add_theme_constant_override("separation", 10)
		info_vb.add_child(sub_row)

		var badge_panel := PanelContainer.new()
		badge_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		badge_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge_lbl.add_theme_font_size_override("font_size", 16)
		badge_lbl.add_theme_color_override("font_color", rank.color)
		badge_panel.add_child(badge_lbl)
		sub_row.add_child(badge_panel)

		# ── Combo (resource recipe) ────────────────────────────────────
		var lbl := Label.new()
		lbl.text = combo
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lbl.add_theme_font_size_override("font_size", 18)
		lbl.add_theme_color_override("font_color", Color(0.8, 0.9, 0.8))
		sub_row.add_child(lbl)

		var dis_btn := Button.new()
		dis_btn.text = "Dismantle"
		dis_btn.add_theme_font_size_override("font_size", 20 if _is_mobile_ui else 17)
		dis_btn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		dis_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dis_btn.custom_minimum_size = Vector2(160, _BTN_H_MOBILE) if _is_mobile_ui else Vector2(110, 38)
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
	# Freeze the whole world while docked. The station UI's CanvasLayer and
	# its descendants are PROCESS_MODE_ALWAYS, so buttons keep receiving
	# input even with the scene tree paused.
	if _player:
		_player.set_physics_process(false)
		_player.set_process(false)
		if _player.has_method("unlock_mouse"):
			_player.unlock_mouse()
	get_tree().paused = true

func _hide_ui() -> void:
	_ui_visible = false
	_panel.hide()
	if _in_range:
		_prompt_btn.show()
	# Unfreeze the world before restoring the player so the next physics tick
	# sees the player active.
	get_tree().paused = false
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
	if _tab_market_panel:   _tab_market_panel.visible   = (idx == 0)
	if _tab_forge_panel:    _tab_forge_panel.visible    = (idx == 1)
	if _tab_upgrades_panel: _tab_upgrades_panel.visible = (idx == 2)
	if idx == 2:
		_rebuild_all_upgrade_rows()
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
	var panel: Control = null
	match _active_tab:
		0: panel = _tab_market_panel
		1: panel = _tab_forge_panel
		2: panel = _tab_upgrades_panel
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
		row.add_theme_constant_override("separation", 10 if _is_mobile_ui else 4)
		_market_rows_vbox.add_child(row)

		# ── Resource name badge ────────────────────────────────────────
		var name_panel: PanelContainer = PanelContainer.new()
		# IGNORE so touch-drags fall through to the ScrollContainer instead of
		# being eaten by the panel's default MOUSE_FILTER_STOP.
		name_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var name_sb: StyleBoxFlat = StyleBoxFlat.new()
		name_sb.bg_color = rarity_col.darkened(0.72)
		name_sb.border_color = rarity_col.darkened(0.2)
		name_sb.set_border_width_all(1)
		name_sb.set_corner_radius_all(4)
		if _is_mobile_ui:
			name_sb.content_margin_left = 10; name_sb.content_margin_right = 10
			name_sb.content_margin_top = 6;   name_sb.content_margin_bottom = 6
		else:
			name_sb.content_margin_left = 6; name_sb.content_margin_right = 6
			name_sb.content_margin_top = 2;  name_sb.content_margin_bottom = 2
		name_panel.add_theme_stylebox_override("panel", name_sb)
		name_panel.custom_minimum_size = Vector2(_NAME_COL_MIN_MOBILE, _BTN_H_MOBILE) if _is_mobile_ui else Vector2(90, 30)
		name_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var name_lbl := Label.new()
		name_lbl.text = r
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_lbl.add_theme_font_size_override("font_size", 17 if _is_mobile_ui else 13)
		name_lbl.add_theme_color_override("font_color", rarity_col)
		name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_panel.add_child(name_lbl)
		row.add_child(name_panel)

		# ── Held qty ──────────────────────────────────────────────────
		var held_lbl := Label.new()
		held_lbl.text = "x" + str(held)
		held_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		held_lbl.add_theme_font_size_override("font_size", 18 if _is_mobile_ui else 14)
		held_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0) if held > 0 else Color(0.4, 0.4, 0.4))
		held_lbl.custom_minimum_size = Vector2(_HELD_COL_MIN_MOBILE, _BTN_H_MOBILE) if _is_mobile_ui else Vector2(46, 0)
		held_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		held_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(held_lbl)

		# ── Sell button ───────────────────────────────────────────────
		var sell_btn: Button = Button.new()
		sell_btn.text = "$" + str(sell_val)
		sell_btn.add_theme_font_size_override("font_size", 18 if _is_mobile_ui else 13)
		sell_btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
		if _is_mobile_ui:
			sell_btn.custom_minimum_size = Vector2(_BTN_MIN_W_MOBILE, _BTN_H_MOBILE)
			sell_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			sell_btn.custom_minimum_size = Vector2(58, 28)
		sell_btn.disabled = held <= 0
		var sell_r: String = r  # capture
		sell_btn.pressed.connect(func() -> void: _on_sell_one(sell_r))
		row.add_child(sell_btn)

		# ── Buy button ────────────────────────────────────────────────
		var buy_btn: Button = Button.new()
		buy_btn.text = "$" + str(buy_price)
		buy_btn.add_theme_font_size_override("font_size", 18 if _is_mobile_ui else 13)
		buy_btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
		if _is_mobile_ui:
			buy_btn.custom_minimum_size = Vector2(_BTN_MIN_W_MOBILE, _BTN_H_MOBILE)
			buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			buy_btn.custom_minimum_size = Vector2(58, 28)
		buy_btn.disabled = credits_val < buy_price
		var buy_r: String = r  # capture
		buy_btn.pressed.connect(func() -> void: _on_buy_one(buy_r))
		row.add_child(buy_btn)


func _on_forge_planet() -> void:
	_set_status("", Color(1.0, 0.5, 0.3))

	# Prune entries whose planets were destroyed externally.
	# Entries restored from a save start with node == null and are kept
	# (rehydration spawns the node lazily — see _rehydrate_active_planets).
	_active_planets = _active_planets.filter(func(e: Dictionary) -> bool:
		return e.get("node", null) == null or is_instance_valid(e.node))

	if _active_planets.size() >= _max_planets():
		_set_status("Max " + str(_max_planets()) + " planets reached.\nDismantle one first.", Color(1.0, 0.5, 0.3))
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
		# Rank + resources are computed FIRST and passed into _spawn_planet_node
		# so they're set on the node before add_child triggers _ready() — otherwise
		# PlanetGen would always fall through to the C-tier archetype pool fallback.
		var pos_salt: int = hash(pos.round()) & 0x7FFFFFFF
		var seed_val: int = PlanetSeedKitchen.make_seed(r1, r2, r3) + (_active_planets.size() * 777) + pos_salt
		# Luck variance is captured at forge time so a later Luck upgrade
		# doesn't retroactively shift the displayed rank of older planets.
		var luck_var: float = 0.0
		if Engine.has_meta("UpgradeManager"):
			luck_var = float(Engine.get_meta("UpgradeManager").get_luck_forge_variance())
		var rank: Dictionary = PlanetSeedKitchen.rank_planet(r1, r2, r3, seed_val, luck_var)
		# MINERAL INFLUENCE — combined PlanetProfile drives archetype, noise,
		# palette, clouds, biolum, rings, glow inside PlanetGen._ready().
		var profile: Dictionary = PlanetSeedKitchen.derive_profile(r1, r2, r3, seed_val)
		var planet_res := PlanetSeedKitchen.resources_for_planet(r1, r2, r3)
		var planet_node := _spawn_planet_node(seed_val, pos, p_name, String(rank.get("label", "")), planet_res, profile)
		# (Impostor activation is deferred to the cinematic — the planet stays
		# hidden until the flash peaks and is revealed there.)

		# Record to persistent registry. pos / name / seed_val are stored so
		# SaveManager can rehydrate this planet on a future launch.
		_active_planets.append({
			node = planet_node,
			r1 = r1, r2 = r2, r3 = r3,
			luck_variance = luck_var,
			pos = pos,
			name = p_name,
			seed_val = seed_val,
		})

		# ACE UNIVERSE SYNC: Notify that a planet was added
		planet_forged.emit(_active_planets.size())

		# Persist immediately — forging is a milestone, no debounce needed.
		if Engine.has_meta("SaveManager"):
			Engine.get_meta("SaveManager").save_now()

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

	# Persist the smaller planet list immediately.
	if Engine.has_meta("SaveManager"):
		Engine.get_meta("SaveManager").save_now()

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

# Strip the engine "Planet_" prefix so the UI shows just the human-friendly
# bit ("Cydon", "Aldebaran") instead of "Planet_Cydon".  Falls back to the
# combo abbreviation if the planet was freed or never got named.
func _display_planet_name(entry: Dictionary) -> String:
	var node = entry.get("node", null)
	if node != null and is_instance_valid(node):
		var raw: String = String(node.name)
		if raw.begins_with("Planet_"):
			raw = raw.substr(7)
		return raw.replace("_", " ")
	return ResourceRegistry.get_abbrev(entry.r1) + "+" + ResourceRegistry.get_abbrev(entry.r2)

# Procedural 32×32 thumbnail derived from the planet's palette.  Generated
# on first call and cached on the entry so repeated UI refreshes don't
# regenerate the image.  Doesn't render the actual planet — that would need
# a SubViewport + camera per slot — instead we paint a stylized icon using
# the planet's own grass/water/sky colors, which reads as a recognizable
# "summary card" of what the world looks like up close.
func _planet_thumbnail_for(entry: Dictionary) -> ImageTexture:
	if entry.has("thumbnail") and entry.thumbnail != null:
		return entry.thumbnail

	var node = entry.get("node", null)
	var grass_col: Color = Color(0.30, 0.65, 0.30)
	var mount_col: Color = Color(0.55, 0.50, 0.45)
	var water_col: Color = Color(0.10, 0.40, 0.80)
	var sky_col: Color   = Color(0.05, 0.05, 0.08)
	var planet_seed: int = 0
	var has_basin: bool = true  # most planets have water; archetype-aware fallback below
	if node != null and is_instance_valid(node):
		if "pal_grass_col" in node: grass_col = node.get("pal_grass_col")
		if "pal_mount_col" in node: mount_col = node.get("pal_mount_col")
		if "pal_water_base" in node: water_col = node.get("pal_water_base")
		if "sky_horizon_color" in node: sky_col = node.get("sky_horizon_color")
		if "planet_seed" in node: planet_seed = int(node.get("planet_seed"))
		# Dry-world archetypes don't have surface water.
		if "archetype" in node:
			var arche: String = String(node.get("archetype"))
			if arche in ["DESERT", "RUST", "BARREN", "ASH", "MUDFLAT", "VOLCANIC", "OBSIDIAN"]:
				has_basin = false

	var size: int = 32
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	# Deterministic seed → same planet always renders the same icon.
	var seed_int: int = planet_seed if planet_seed != 0 else hash(str(entry.r1) + str(entry.r2) + str(entry.r3))

	# Two FBM noise layers drive an irregular continent mask — coarse for the
	# overall landmass shape, fine for the jagged coastlines.  Using noise
	# instead of overlapping circles is what turns a "round blob" into
	# something that reads as a continent.
	var noise_continent := FastNoiseLite.new()
	noise_continent.seed = seed_int
	noise_continent.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_continent.frequency = 0.12
	noise_continent.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_continent.fractal_octaves = 4
	noise_continent.fractal_lacunarity = 2.1
	noise_continent.fractal_gain = 0.55

	var noise_detail := FastNoiseLite.new()
	noise_detail.seed = seed_int + 7919
	noise_detail.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_detail.frequency = 0.32
	noise_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_detail.fractal_octaves = 3
	noise_detail.fractal_lacunarity = 2.0
	noise_detail.fractal_gain = 0.5

	var cx: float = float(size) * 0.5
	var cy: float = float(size) * 0.5
	var r: float = float(size) * 0.46

	# Thresholds — dry worlds get more land coverage so the icon doesn't
	# look mostly water on a planet that has none.
	var land_threshold: float = 0.0 if has_basin else -0.18
	var mountain_threshold: float = 0.20  # above this on top of land = mountain colour

	for y in range(size):
		for x in range(size):
			var dx: float = float(x) + 0.5 - cx
			var dy: float = float(y) + 0.5 - cy
			var d: float = sqrt(dx * dx + dy * dy)
			if d > r:
				continue

			# Combine coarse continent shape with finer coastline jitter.
			var n: float = noise_continent.get_noise_2d(float(x), float(y)) \
				+ noise_detail.get_noise_2d(float(x), float(y)) * 0.35
			# Fall-off near the disc edge so continents don't run off the
			# visible globe — produces oceans at the limb regardless of noise.
			var rim_t: float = clampf(d / r, 0.0, 1.0)
			n -= pow(rim_t, 3.0) * 0.45

			var base: Color
			if has_basin and n < land_threshold:
				base = water_col
			elif n > mountain_threshold:
				base = mount_col
			else:
				base = grass_col

			# West-darker / east-lighter shading sells the lit-globe look.
			var shade: float = 0.82 + (dx / r) * 0.20
			# Slight darkening near the rim (atmosphere occlusion) so the
			# planet doesn't blend into the halo.
			shade *= 1.0 - rim_t * 0.10

			base.r = clampf(base.r * shade, 0.0, 1.0)
			base.g = clampf(base.g * shade, 0.0, 1.0)
			base.b = clampf(base.b * shade, 0.0, 1.0)
			base.a = 1.0
			img.set_pixel(x, y, base)

	# Atmosphere halo — one-pixel ring tinted with the planet's sky colour.
	var halo: Color = sky_col.lerp(Color.WHITE, 0.35)
	halo.a = 0.55
	for ang_i in range(64):
		var ang: float = float(ang_i) / 64.0 * TAU
		var hx: int = int(round(cx + cos(ang) * (r + 0.6)))
		var hy: int = int(round(cy + sin(ang) * (r + 0.6)))
		if hx >= 0 and hx < size and hy >= 0 and hy < size:
			img.set_pixel(hx, hy, halo)

	var tex := ImageTexture.create_from_image(img)
	entry["thumbnail"] = tex
	return tex

func _spawn_planet_node(seed_val: int, custom_pos: Vector3, custom_name: String, rank_label: String = "", planet_res: Array = [], profile: Dictionary = {}) -> Node3D:
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
	# Rank, resources, and the combined MineralInfluence profile MUST be set
	# BEFORE add_child — PlanetGen._ready() reads them to pick the archetype
	# pool, seed the resource list, and apply the per-mineral palette /
	# noise / cloud / glow knobs.
	planet.set("planet_rank", rank_label)
	if not planet_res.is_empty():
		planet.set("planet_resources", planet_res)
	planet.set("planet_profile", profile)
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

# ---------------------------------------------------------------------------
# UPGRADES TAB
# ---------------------------------------------------------------------------

func _build_upgrades_panel(parent: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "— UPGRADES —"
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color(1.0, 0.65, 0.85))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(title)

	_upgrades_status = Label.new()
	_upgrades_status.text = ""
	_upgrades_status.add_theme_font_size_override("font_size", 14)
	_upgrades_status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	_upgrades_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(_upgrades_status)

	if not Engine.has_meta("UpgradeManager"):
		var warn := Label.new()
		warn.text = "(UpgradeManager not loaded)"
		warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		warn.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		parent.add_child(warn)
		return

	var up = Engine.get_meta("UpgradeManager")
	_upgrade_rows.clear()
	for track in up.TRACKS:
		var row := _build_upgrade_row(track)
		parent.add_child(row)
		_upgrade_rows[track] = row

func _build_upgrade_row(track: String) -> PanelContainer:
	var up = Engine.get_meta("UpgradeManager")
	var lvl: int = up.get_level(track)
	var max_lvl: int = up.get_max_level(track)
	var maxed: bool = up.is_maxed(track)
	var cost: Dictionary = up.next_cost(track)
	var affordable: bool = up.can_afford(track)

	var panel := PanelContainer.new()
	# IGNORE so scroll touches fall through to the ScrollContainer; the
	# UPGRADE Button child still gets its own taps via STOP.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.14, 0.85)
	sb.border_color = Color(0.35, 0.35, 0.5)
	sb.border_width_left = 2; sb.border_width_top = 2
	sb.border_width_right = 2; sb.border_width_bottom = 2
	sb.content_margin_left = 10; sb.content_margin_right = 10
	sb.content_margin_top = 8; sb.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", sb)
	panel.set_meta("track", track)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(row)

	# LEFT: name + pips + level label
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 4)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(left)

	var name_lbl := Label.new()
	name_lbl.text = String(up.DISPLAY_NAME.get(track, track.to_upper()))
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	left.add_child(name_lbl)

	var pip_row := HBoxContainer.new()
	pip_row.add_theme_constant_override("separation", 3)
	left.add_child(pip_row)
	var pip_color: Color = _tier_color(int(ceilf(float(maxi(lvl, 1)) / float(maxi(max_lvl, 1)) * 4.0)))
	for i in range(max_lvl):
		var pip := ColorRect.new()
		pip.custom_minimum_size = Vector2(20, 14) if _is_mobile_ui else Vector2(16, 10)
		pip.color = pip_color if i < lvl else Color(0.2, 0.2, 0.25)
		pip_row.add_child(pip)

	var lvl_lbl := Label.new()
	lvl_lbl.text = "Lvl " + str(lvl) + " / " + str(max_lvl)
	lvl_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lvl_lbl.add_theme_font_size_override("font_size", 13)
	lvl_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	left.add_child(lvl_lbl)

	# RIGHT: cost + materials + button
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 4)
	right.custom_minimum_size = Vector2(_UPGRADE_RIGHT_W_MOBILE if _is_mobile_ui else 240, 0)
	row.add_child(right)

	if maxed:
		var maxed_lbl := Label.new()
		maxed_lbl.text = "MAXED"
		maxed_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		maxed_lbl.add_theme_font_size_override("font_size", 18)
		maxed_lbl.add_theme_color_override("font_color", Color(1.0, 0.8, 0.2))
		maxed_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		right.add_child(maxed_lbl)
	else:
		var econ_credits: int = int(Engine.get_meta("EconomyManager").credits) if Engine.has_meta("EconomyManager") else 0
		var cost_credits: int = int(cost.get("credits", 0))
		var credits_ok: bool = econ_credits >= cost_credits

		var cost_lbl := Label.new()
		cost_lbl.text = "$" + str(cost_credits)
		cost_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cost_lbl.add_theme_font_size_override("font_size", 16)
		cost_lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2) if credits_ok else Color(1.0, 0.4, 0.4))
		cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		right.add_child(cost_lbl)

		var mat_row := HFlowContainer.new()
		mat_row.add_theme_constant_override("h_separation", 6)
		mat_row.add_theme_constant_override("v_separation", 3)
		right.add_child(mat_row)

		var inv = Engine.get_meta("InventoryManager") if Engine.has_meta("InventoryManager") else null
		var mats: Dictionary = cost.get("mats", {})
		for mat_name in mats.keys():
			var need: int = int(mats[mat_name])
			var have: int = inv.get_amount(mat_name) if inv else 0
			var ok: bool = have >= need
			var chip := PanelContainer.new()
			var csb := StyleBoxFlat.new()
			csb.bg_color = _tier_color(ResourceRegistry.get_tier(mat_name)).darkened(0.55)
			csb.border_color = Color(0.1, 0.1, 0.12)
			csb.border_width_left = 1; csb.border_width_right = 1
			csb.border_width_top = 1; csb.border_width_bottom = 1
			csb.content_margin_left = 5; csb.content_margin_right = 5
			csb.content_margin_top = 1; csb.content_margin_bottom = 1
			chip.add_theme_stylebox_override("panel", csb)
			var chip_lbl := Label.new()
			chip_lbl.text = ResourceRegistry.get_abbrev(mat_name) + " " + str(have) + "/" + str(need)
			chip_lbl.add_theme_font_size_override("font_size", 12)
			chip_lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0) if ok else Color(1.0, 0.45, 0.45))
			chip.add_child(chip_lbl)
			mat_row.add_child(chip)

		var btn := Button.new()
		btn.text = "UPGRADE"
		btn.add_theme_font_size_override("font_size", 22 if _is_mobile_ui else 18)
		btn.add_theme_color_override("font_color", Color(0.4, 1.0, 0.55) if affordable else Color(0.55, 0.55, 0.55))
		btn.disabled = not affordable
		btn.custom_minimum_size = Vector2(0, _UPGRADE_BTN_H_MOBILE if _is_mobile_ui else 38)
		var captured_track: String = track
		btn.pressed.connect(func() -> void: _on_upgrade_purchase_pressed(captured_track))
		right.add_child(btn)

	return panel

func _rebuild_all_upgrade_rows() -> void:
	if not Engine.has_meta("UpgradeManager"):
		return
	if _tab_upgrades_panel == null:
		return
	var up = Engine.get_meta("UpgradeManager")
	for track in up.TRACKS:
		_rebuild_upgrade_row(track)

func _rebuild_upgrade_row(track: String) -> void:
	if not _upgrade_rows.has(track):
		return
	var old: PanelContainer = _upgrade_rows[track]
	if old == null or not is_instance_valid(old):
		return
	var parent := old.get_parent()
	if parent == null:
		return
	var idx: int = old.get_index()
	var fresh := _build_upgrade_row(track)
	parent.add_child(fresh)
	parent.move_child(fresh, idx)
	old.queue_free()
	_upgrade_rows[track] = fresh

func _on_upgrade_purchase_pressed(track: String) -> void:
	if not Engine.has_meta("UpgradeManager"):
		return
	Engine.get_meta("UpgradeManager").try_purchase(track)

func _on_upgrade_changed(track: String, new_level: int) -> void:
	if _upgrades_status != null:
		_upgrades_status.text = String(track).to_upper() + " UPGRADED → Lvl " + str(new_level)
		_upgrades_status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	if _active_tab == 2:
		_rebuild_all_upgrade_rows()

func _on_upgrade_purchase_failed(track: String, reason: String) -> void:
	if _upgrades_status == null:
		return
	var msg := ""
	match reason:
		"maxed": msg = String(track).to_upper() + " is already MAXED."
		"insufficient": msg = "Insufficient credits or materials for " + String(track).to_upper() + "."
		_: msg = "Could not upgrade " + String(track).to_upper() + " (" + reason + ")."
	_upgrades_status.text = msg
	_upgrades_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.4))

# ---------------------------------------------------------------------------
# FORGED PLANET PERSISTENCE
# ---------------------------------------------------------------------------

# Serialize the static _active_planets registry to a JSON-safe Array.
# Skips the live node reference and the cached thumbnail (regenerated on load).
static func active_planets_for_save() -> Array:
	var out: Array = []
	for entry in _active_planets:
		# Skip entries whose nodes were freed without a clean dismantle —
		# we don't want to resurrect a planet the engine has already discarded.
		if entry.get("node", null) != null and not is_instance_valid(entry.node):
			continue
		var pos: Vector3 = entry.get("pos", Vector3.ZERO)
		out.append({
			"r1":             String(entry.get("r1", "")),
			"r2":             String(entry.get("r2", "")),
			"r3":             String(entry.get("r3", "")),
			"luck_variance":  float(entry.get("luck_variance", 0.0)),
			"seed_val":       int(entry.get("seed_val", 0)),
			"name":           String(entry.get("name", "")),
			"pos":            {"x": pos.x, "y": pos.y, "z": pos.z},
		})
	return out

# Replace _active_planets with descriptors loaded from disk. Nodes are
# left null; _rehydrate_active_planets() spawns them once world_root exists.
static func load_active_planets_from_save(arr: Array) -> void:
	_active_planets.clear()
	for raw in arr:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var pos_data: Dictionary = raw.get("pos", {})
		var pos := Vector3(
			float(pos_data.get("x", 0.0)),
			float(pos_data.get("y", 0.0)),
			float(pos_data.get("z", 0.0)),
		)
		_active_planets.append({
			node = null,
			r1 = String(raw.get("r1", "")),
			r2 = String(raw.get("r2", "")),
			r3 = String(raw.get("r3", "")),
			luck_variance = float(raw.get("luck_variance", 0.0)),
			seed_val = int(raw.get("seed_val", 0)),
			name = String(raw.get("name", "")),
			pos = pos,
		})

# Walk _active_planets and spawn a Node3D for any entry whose node is null.
# Called from Main.gd once world_root is in the tree.
func _rehydrate_active_planets() -> void:
	var spawned: int = 0
	for entry in _active_planets:
		if entry.get("node", null) != null and is_instance_valid(entry.node):
			continue
		var r1: String = entry.r1
		var r2: String = entry.r2
		var r3: String = entry.r3
		var seed_val: int = int(entry.get("seed_val", 0))
		var pos: Vector3 = entry.get("pos", Vector3.ZERO)
		var p_name: String = String(entry.get("name", ""))
		var luck_var: float = float(entry.get("luck_variance", 0.0))
		var rank: Dictionary = PlanetSeedKitchen.rank_planet(r1, r2, r3, seed_val, luck_var)
		var planet_res := PlanetSeedKitchen.resources_for_planet(r1, r2, r3)
		var profile: Dictionary = PlanetSeedKitchen.derive_profile(r1, r2, r3, seed_val)
		var node := _spawn_planet_node(seed_val, pos, p_name, String(rank.get("label", "")), planet_res, profile)
		entry.node = node
		spawned += 1
	if spawned > 0:
		print("--- SAVE: rehydrated ", spawned, " forged planet(s) ---")
		planet_forged.emit(_active_planets.size())
		_refresh_planets_ui()

extends Node3D

const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")
const HUDStyle = preload("res://src/ui/HUDStyle.gd")

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
# Modal redesign — _panel is now a full-rect Control hosting a dim ColorRect
# behind a centered PanelContainer "plate".  The existing ScrollContainer +
# VBoxContainer move inside the plate so the scroll is contained, the close
# X stays fixed top-right, and a dimmed backdrop signals modality.
var _modal_dim: ColorRect = null
var _modal_plate: PanelContainer = null
var _close_btn: Button = null
# Safe-area insets (notch / Dynamic Island / home-indicator).  Mirrors the
# pattern in MobileControlsUI._calculate_safe_area().
var _safe_left: float   = 0.0
var _safe_right: float  = 0.0
var _safe_top: float    = 0.0
var _safe_bottom: float = 0.0
var _inv_label: Label = null
var _creds_label: Label = null
# Captain identity header — left side of the new top bar.
var _captain_avatar: TextureRect = null
var _captain_name_lbl: Label = null
# Right side: stat readouts keyed by id for live refresh on signal.
var _stat_labels: Dictionary = {}   # id (String) -> Label
var _forge_slots: Array = []          # Array[OptionButton] (legacy, unused)
var _forge_selected: Array[String] = []  # Up to 3 chosen resource names
var _forge_card_grid: VBoxContainer = null
var _forge_slot_labels: Array = []    # 3 Label nodes showing chosen slots
var _forge_slot_hints: Array = []     # 3 small "tap to remove" hint labels
var _forge_slot_panels: Array = []    # 3 ForgeSlot panels — for stylebox tinting
var _forge_btn: Button = null
var _forge_cost_label: Label = null
var _forge_status: Label = null
var _prompt_btn: Button = null
var _ui_visible: bool = false
var _in_range: bool = false
var _cinematic_active: bool = false

# Forge-ready celebration animation: rainbow modulate + scale pulse on the
# FORGE PLANET button when all 3 slots are filled and the cost is affordable.
var _forge_ready_tween: Tween = null
var _forge_ready_scale_tween: Tween = null
var _forge_ready_active: bool = false

# ACE SIGNALS: Notify the universe of major system changes
signal planet_forged(count: int)

# Market panel references
var _market_scroll: ScrollContainer = null
var _market_rows_vbox: VBoxContainer = null
var _market_status: Label = null
# Bulk-trade quantity mode for the Market tab.  Values: "1", "10", "100",
# "max".  Applied to BOTH the Sell and Buy columns so a single global toggle
# drives the price totals shown on every row.  Reset to "1" each time the
# modal opens so the player can't accidentally bulk-sell on next visit.
var _market_qty_mode: String = "1"
var _market_qty_btns: Array = []  # 4 toggle buttons, indexed by preset order

# Tab references
var _tab_btns: Array = []  # [market_btn, upgrades_btn, planets_btn, forge_btn]
var _active_tab: int = 0  # 0 = Market, 1 = Upgrades, 2 = Planets, 3 = Forge
var _tab_market_panel: Control = null
var _tab_forge_panel: Control = null
var _tab_upgrades_panel: Control = null
var _tab_planets_panel: Control = null
# Planets tab paging state — index into _active_planets for the currently
# displayed planet, plus refs to nodes that get repopulated each refresh.
var _planet_view_idx: int = 0
var _planet_illustration: TextureRect = null
var _planet_name_lbl: Label = null
var _planet_rank_badge: PanelContainer = null
var _planet_rank_lbl: Label = null
var _planet_combo_lbl: Label = null
var _planet_page_lbl: Label = null
var _planet_resource_grid: GridContainer = null
var _planet_prev_btn: Button = null
var _planet_next_btn: Button = null
var _planet_empty_lbl: Label = null
var _planet_content_root: VBoxContainer = null
var _planet_content_window: Control = null   # clipping wrapper for slide animation
var _planet_dismantle_btn: Button = null
var _planet_slide_tween: Tween = null
var _planet_slide_in_progress: bool = false
var _upgrade_rows: Dictionary = {}  # track -> PanelContainer
var _upgrades_status: Label = null

# Gamepad cursor/focus
var _virtual_cursor: ColorRect = null
var _last_mouse_pos: Vector2 = Vector2.ZERO

# Each entry: { node: Node3D, r1: String, r2: String, r3: String }
static var _active_planets: Array[Dictionary] = []

# Lifetime forge count — used to grant the first forge for free as an on-ramp
# and to scale subsequent forge credit costs. Persisted via SaveManager.
static var _total_forges: int = 0

static func get_total_forges() -> int:
	return _total_forges

static func set_total_forges(n: int) -> void:
	_total_forges = max(0, int(n))

# Cinematic / hide-HUD flag — when set by the pause-menu toggle, every
# SpaceStation suppresses its DOCK prompt (auto-shows it on proximity by
# default).  Static so a single setting drives every station in the world.
static var _hud_hidden: bool = false

static func set_hud_hidden(v: bool) -> void:
	_hud_hidden = bool(v)

# Called by LootGem on collection so we can mark resources discovered on
# the planet they came from.  No-op if the planet isn't a forged one
# (e.g., legacy/natural worlds we don't track).  Notifies a live
# SpaceStation so any open Planets tab refreshes immediately.
static func record_discovery(planet_node: Node, resource_name: String) -> void:
	if planet_node == null or resource_name == "":
		return
	for entry in _active_planets:
		if entry.get("node", null) == planet_node:
			var discovered: Array = entry.get("discovered", [])
			if not discovered.has(resource_name):
				discovered.append(resource_name)
				entry["discovered"] = discovered
				# Refresh any open station UI showing this planet.
				_emit_discovery_refresh()
			return

# Walks SpaceStation instances in the tree and asks them to refresh their
# Planets tab.  Done as a soft pull so we don't need a global signal bus.
# Throttled to only refresh stations whose UI is actually open AND on the
# Planets tab — otherwise we'd rebuild the planet view on every shard
# collected (10-20 per mineral × every station in the world).
static func _emit_discovery_refresh() -> void:
	if Engine.get_main_loop() == null: return
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null: return
	for station in tree.get_nodes_in_group("SpaceStation"):
		var visible: bool = bool(station.get("_ui_visible")) if "_ui_visible" in station else false
		var on_planets_tab: bool = int(station.get("_active_tab")) == 2 if "_active_tab" in station else false
		if visible and on_planets_tab and station.has_method("_refresh_planets_ui"):
			station.call_deferred("_refresh_planets_ui")

# Slop-guarded tap radius — if the finger moves more than this between
# press and release (or during press), the tap is canceled so the parent
# ScrollContainer can take over.  Standard mobile UX pattern.
const _TAP_SLOP_DESKTOP: float = 15.0
const _TAP_SLOP_MOBILE: float = 12.0

# Drop-in replacement for Button that emits a custom `tapped` signal only
# when the press → release happened without the finger drifting past the
# slop radius.  Built so the player can scroll past a button inside a
# ScrollContainer without accidentally firing it.
#
# Wire it like a Button: instantiate, set text/style/disabled/etc., then
# connect to .tapped instead of .pressed.  Do NOT also connect to .pressed
# — we don't suppress the built-in signal, so a redundant connection
# would fire twice.  In practice, prefer .tapped only.
class _TapButton extends Button:
	signal tapped
	var slop_sq: float = _TAP_SLOP_DESKTOP * _TAP_SLOP_DESKTOP
	var _press_pos: Vector2 = Vector2.ZERO
	var _press_active: bool = false
	# Set true the moment the finger drifts past slop.  From then on, this
	# button forwards motion deltas to the parent ScrollContainer instead
	# of doing anything tap-like.  Required because Godot 4 captures the
	# touch on the deepest Control and never hands it off to the
	# ScrollContainer on its own — without explicit forwarding, swiping
	# over a button area is dead input.
	var _scrolling: bool = false
	# Cached on first use via _get_scroll_parent().
	var _scroll_parent: ScrollContainer = null

	func _get_scroll_parent() -> ScrollContainer:
		if _scroll_parent != null and is_instance_valid(_scroll_parent):
			return _scroll_parent
		var n: Node = get_parent()
		while n != null:
			if n is ScrollContainer:
				_scroll_parent = n
				return n
			n = n.get_parent()
		return null

	func _gui_input(event: InputEvent) -> void:
		if disabled:
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_pos = event.position
				_press_active = true
				_scrolling = false
				button_pressed = true
			else:
				# Release.  If we never scrolled and the finger stayed within
				# slop, this is a clean tap.  Otherwise swallow the release.
				var was_scrolling: bool = _scrolling
				_press_active = false
				_scrolling = false
				button_pressed = false
				if not was_scrolling:
					var d_sq: float = _press_pos.distance_squared_to(event.position)
					if d_sq <= slop_sq:
						tapped.emit()
						# Consume so Button's internal handling doesn't also
						# fire its built-in pressed signal.
						accept_event()
		elif event is InputEventMouseMotion and _press_active:
			# Always forward motion to the parent ScrollContainer the moment
			# the finger moves — even sub-slop motion scrolls 1:1.  Slop
			# only gates whether the release fires a tap (any drift past
			# slop suppresses the tap on release).  This keeps scroll
			# buttery-smooth without a "stick then jump" feel at slop boundary.
			var sp: ScrollContainer = _get_scroll_parent()
			if sp != null and event.relative.y != 0.0:
				sp.scroll_vertical -= int(event.relative.y)
			if not _scrolling:
				var d_sq: float = _press_pos.distance_squared_to(event.position)
				if d_sq > slop_sq:
					_scrolling = true
					button_pressed = false
			if _scrolling:
				accept_event()


class ForgeSlot extends PanelContainer:
	var slot_index: int = 0
	var station_ref: Node = null
	# Track press position so tap-to-remove only fires on clean taps —
	# release without significant finger drift.  Without this a press-drag-
	# release within the slot would still fire even if the player meant to
	# swipe past.
	var _tap_press_pos: Vector2 = Vector2.ZERO
	var _tap_active: bool = false
	func _init() -> void:
		# Gamepad navigation: focusable so ui_accept (Enter / gamepad A)
		# triggers the same "remove this slot" action that drag-out does.
		focus_mode = Control.FOCUS_ALL
	func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
		return typeof(data) == TYPE_DICTIONARY and data.has("type") and data["type"] == "resource"
	func _drop_data(_at_position: Vector2, data: Variant) -> void:
		station_ref._on_card_pressed(data["res"])
	func _get_drag_data(_at_position: Vector2) -> Variant:
		# Slots live outside the scrollable resource list, so drag-from-slot
		# doesn't fight the ScrollContainer on mobile.
		if slot_index >= station_ref._forge_selected.size(): return null
		var r: String = station_ref._forge_selected[slot_index]
		set_drag_preview(station_ref._make_drag_preview(r))
		station_ref._on_remove_slot(slot_index)
		return {"type": "removed_resource", "res": r}
	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept"):
			if station_ref and slot_index < station_ref._forge_selected.size():
				station_ref._on_remove_slot(slot_index)
				accept_event()
			return
		# Mobile tap-to-remove with slop guarding.  Only fires if the finger
		# stayed within the tap-slop radius between press and release.
		if not (station_ref and station_ref._is_mobile_ui): return
		if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT) \
				and not event is InputEventMouseMotion:
			return
		if event is InputEventMouseButton:
			if event.pressed:
				_tap_press_pos = event.position
				_tap_active = true
			else:
				if _tap_active and slot_index < station_ref._forge_selected.size():
					_tap_active = false
					var slop: float = _TAP_SLOP_MOBILE if station_ref._is_mobile_ui else _TAP_SLOP_DESKTOP
					if _tap_press_pos.distance_squared_to(event.position) <= slop * slop:
						station_ref._on_remove_slot(slot_index)
						accept_event()
		elif event is InputEventMouseMotion and _tap_active:
			var slop_m: float = _TAP_SLOP_MOBILE if station_ref._is_mobile_ui else _TAP_SLOP_DESKTOP
			if _tap_press_pos.distance_squared_to(event.position) > slop_m * slop_m:
				_tap_active = false

class ResourceCard extends PanelContainer:
	var resource_id: String = ""
	var available_count: int = 0
	var station_ref: Node = null
	# Press/hold/arm state for visual feedback.
	# pressed: finger is down on this card (dim tint).
	# armed:   mobile press-and-hold threshold reached (bright tint + floating
	#          ghost preview) — drag is now permitted.
	var _press_time_ms: int = 0
	var _press_pos: Vector2 = Vector2.ZERO   # for slop-guarded tap detection
	var _pressed: bool = false
	var _armed: bool = false
	var _scrolling: bool = false     # finger drifted past slop → forwarding scroll
	var _drag_ghost: Control = null
	var _scroll_parent: ScrollContainer = null
	# How long the finger must stay down on mobile before a drag is permitted.
	# Set deliberately long (~½ sec) so a brief "where is my finger" pause
	# before swiping doesn't arm a drag.  Below this, motion forwards to the
	# parent ScrollContainer for scroll.
	const _DRAG_ARM_MS: int = 500
	func _init() -> void:
		# Gamepad navigation: focusable so ui_accept (Enter / gamepad A)
		# triggers the same "add to forge" action that drag-in does.
		focus_mode = Control.FOCUS_ALL
	func _exit_tree() -> void:
		_hide_drag_ghost()
	func _process(_delta: float) -> void:
		# Mobile hold-to-arm: once the threshold passes without motion, swap
		# to the "drag is ready" visuals and surface a floating ghost preview
		# so the user knows they can now drag.  But if the finger has been
		# scrolling the list, never arm — the player meant to scroll, not drag.
		if _pressed and not _armed and not _scrolling:
			var elapsed: int = Time.get_ticks_msec() - _press_time_ms
			if elapsed >= _DRAG_ARM_MS:
				_set_armed(true)
	func _set_pressed_visual(p: bool) -> void:
		if p:
			modulate = Color(0.82, 0.86, 1.0)
		else:
			modulate = Color(1, 1, 1)
	func _set_armed(a: bool) -> void:
		_armed = a
		if a:
			modulate = Color(1.25, 1.2, 1.45)
			pivot_offset = size * 0.5
			scale = Vector2(1.035, 1.035)
			_show_drag_ghost()
		else:
			scale = Vector2.ONE
			_hide_drag_ghost()
	func _show_drag_ghost() -> void:
		if _drag_ghost != null or station_ref == null or not is_inside_tree():
			return
		_drag_ghost = station_ref._make_drag_preview(resource_id)
		_drag_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Add to the modal root so the ghost can float above the
		# ScrollContainer that clips the card.
		var host: Node = station_ref._panel if station_ref._panel else station_ref
		host.add_child(_drag_ghost)
		var card_rect: Rect2 = get_global_rect()
		_drag_ghost.global_position = Vector2(
			card_rect.position.x + card_rect.size.x * 0.5,
			card_rect.position.y
		)
	func _hide_drag_ghost() -> void:
		if _drag_ghost != null:
			_drag_ghost.queue_free()
			_drag_ghost = null
	func _reset_press_state() -> void:
		_hide_drag_ghost()
		_pressed = false
		_armed = false
		_scrolling = false
		_press_time_ms = 0
		set_process(false)
		modulate = Color(1, 1, 1)
		scale = Vector2.ONE
	func _get_scroll_parent() -> ScrollContainer:
		if _scroll_parent != null and is_instance_valid(_scroll_parent):
			return _scroll_parent
		var n: Node = get_parent()
		while n != null:
			if n is ScrollContainer:
				_scroll_parent = n
				return n
			n = n.get_parent()
		return null
	func _get_drag_data(_at_position: Vector2) -> Variant:
		# Drag works on mobile too — the new forge layout isolates the
		# scrollable area to the left column so a horizontal drag toward the
		# slots on the right doesn't conflict with vertical scroll.
		if available_count <= 0 or station_ref._forge_selected.size() >= 3:
			_reset_press_state()
			return null
		# Mobile hold gate: if the user starts moving immediately after touch,
		# treat the gesture as a scroll, not a drag.  Desktop has no hold
		# requirement — a mouse click+drag is unambiguous.
		if station_ref._is_mobile_ui and not _armed:
			return null
		set_drag_preview(station_ref._make_drag_preview(resource_id))
		_reset_press_state()
		return {"type": "resource", "res": resource_id}
	func _gui_input(event: InputEvent) -> void:
		if event.is_action_pressed("ui_accept"):
			if station_ref and available_count > 0 and station_ref._forge_selected.size() < 3:
				station_ref._on_card_pressed(resource_id)
				accept_event()
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_time_ms = Time.get_ticks_msec()
				_press_pos = event.position
				_pressed = true
				_scrolling = false
				_set_pressed_visual(true)
				# _process drives the mobile arm-after-hold visual swap.
				# Desktop drag is immediate on motion, no timer needed.
				if station_ref and station_ref._is_mobile_ui:
					set_process(true)
			else:
				# Release.  Order matters here: snapshot state, reset, decide.
				var was_armed := _armed
				var was_scrolling := _scrolling
				var release_pos: Vector2 = event.position
				_reset_press_state()
				# If we were scrolling (finger drifted past slop), suppress
				# the tap entirely — the gesture was a swipe-scroll, not a tap.
				if was_scrolling:
					return
				# Tap-to-add fires only if we never armed AND release was
				# within slop of the press (clean tap).
				if not was_armed and station_ref and station_ref._is_mobile_ui \
						and available_count > 0 and station_ref._forge_selected.size() < 3:
					var slop: float = _TAP_SLOP_MOBILE if station_ref._is_mobile_ui else _TAP_SLOP_DESKTOP
					if _press_pos.distance_squared_to(release_pos) <= slop * slop:
						station_ref._on_card_pressed(resource_id)
						accept_event()
		elif event is InputEventMouseMotion and _pressed:
			# Before the hold window completes, ALL motion forwards to the
			# parent ScrollContainer 1:1 — no slop gate, so scrolling tracks
			# the finger from the first pixel.  Slop only decides whether
			# the release fires a tap (any drift past slop suppresses it).
			# Once the player drifts past slop we also flag _scrolling so
			# the arm timer (_process) refuses to arm a drag.
			if not _armed:
				var sp: ScrollContainer = _get_scroll_parent()
				if sp != null and event.relative.y != 0.0:
					sp.scroll_vertical -= int(event.relative.y)
				if not _scrolling:
					var slop_m: float = _TAP_SLOP_MOBILE if station_ref and station_ref._is_mobile_ui else _TAP_SLOP_DESKTOP
					if _press_pos.distance_squared_to(event.position) > slop_m * slop_m:
						_scrolling = true
						_set_pressed_visual(false)
				if _scrolling:
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
	# Drop the "[E]" keyboard hint on mobile — there's no E key, and the
	# bracketed shortcut just looks broken next to thumb-only controls.
	_prompt_btn.text = "DOCK STATION" if _is_mobile_ui else "DOCK STATION [E]"
	HUDStyle.style_button(_prompt_btn, HUDStyle.BTN_GREEN, 28 if _is_mobile_ui else 24)
	_prompt_btn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	# Mobile: tuck the button down at the bottom of the screen so it sits
	# vertically aligned with the ROLL L / ROLL R thumb-buttons (which live
	# 36 + safe_bottom from the bottom and are 88px tall, vertically centred
	# at screen_h - 80 - safe_bottom).  Make the dock button match.
	# Desktop: keep the original position 90–140 px above the bottom.
	if _is_mobile_ui:
		_calculate_safe_area()
		var dock_h: int = 100
		var dock_w: int = 360
		# Centred at screen_h - 80 - safe_bottom: top = centre - h/2.
		_prompt_btn.offset_top    = -80 - _safe_bottom - dock_h / 2
		_prompt_btn.offset_bottom = -80 - _safe_bottom + dock_h / 2
		_prompt_btn.offset_left   = -dock_w / 2
		_prompt_btn.offset_right  =  dock_w / 2
	else:
		_prompt_btn.offset_top = -140
		_prompt_btn.offset_bottom = -90
		_prompt_btn.offset_left = -160
		_prompt_btn.offset_right = 160
	_prompt_btn.pressed.connect(_on_dock_pressed)
	_prompt_btn.hide()
	_ui_layer.add_child(_prompt_btn)

	# ── MODAL ROOT ─────────────────────────────────────────────────────────
	# Full-rect Control with STOP filter — owns input and signals modality.
	_calculate_safe_area()
	var modal_root := Control.new()
	modal_root.process_mode = PROCESS_MODE_ALWAYS
	modal_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	modal_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_ui_layer.add_child(modal_root)
	_panel = modal_root

	# ── DIM BACKDROP ───────────────────────────────────────────────────────
	_modal_dim = ColorRect.new()
	_modal_dim.color = Color(HUDStyle.BG_DEEP_PURPLE.r, HUDStyle.BG_DEEP_PURPLE.g, HUDStyle.BG_DEEP_PURPLE.b, 0.72)
	_modal_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_modal_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	modal_root.add_child(_modal_dim)

	# ── PLATE ──────────────────────────────────────────────────────────────
	# Always full-rect minus margin so the modal can never exceed the viewport.
	# Mobile: pulls in by safe-area + 20px chrome.
	# Desktop: generous 80px border so the dim backdrop frames the modal.
	_modal_plate = PanelContainer.new()
	_modal_plate.add_theme_stylebox_override("panel", HUDStyle.bevel_panel(HUDStyle.PANEL_BEVEL))
	_modal_plate.mouse_filter = Control.MOUSE_FILTER_STOP
	_modal_plate.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _is_mobile_ui:
		_modal_plate.offset_left   =  _PANEL_MARGIN_MOBILE + _safe_left
		_modal_plate.offset_right  = -_PANEL_MARGIN_MOBILE - _safe_right
		_modal_plate.offset_top    =  _PANEL_MARGIN_MOBILE + _safe_top
		_modal_plate.offset_bottom = -_PANEL_MARGIN_MOBILE - _safe_bottom
	else:
		var dm := 80  # desktop margin
		_modal_plate.offset_left   =  dm
		_modal_plate.offset_right  = -dm
		_modal_plate.offset_top    =  dm
		_modal_plate.offset_bottom = -dm
	modal_root.add_child(_modal_plate)

	# ── PLATE INNER ────────────────────────────────────────────────────────
	# PanelContainer hosts one child; this Control wraps both the sticky-
	# header VBox (layout) and the corner-anchored close X (free-positioned).
	var plate_inner := Control.new()
	plate_inner.mouse_filter = Control.MOUSE_FILTER_PASS
	plate_inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	plate_inner.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_modal_plate.add_child(plate_inner)

	# ── OUTER VBOX (sticky header + scroll) ────────────────────────────────
	# Fills plate_inner.  Title / credits / inventory / tabs go here and stay
	# pinned; the ScrollContainer below takes the remaining height so only
	# per-tab content scrolls.
	#
	# IMPORTANT: vbox is added BEFORE _close_btn so the close X renders on
	# top (siblings render in document order).  Otherwise the vbox's full-
	# rect anchors would cover the close button and swallow its taps.
	var vbox := VBoxContainer.new()
	vbox.process_mode = PROCESS_MODE_ALWAYS
	vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	vbox.add_theme_constant_override("separation", 10)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Inner padding so content doesn't kiss the bezel / close X.
	var pad_top: int = 12 if _is_mobile_ui else 12
	var pad_side: int = 16 if _is_mobile_ui else 24
	vbox.offset_left   =  pad_side
	vbox.offset_right  = -pad_side
	vbox.offset_top    =  pad_top
	vbox.offset_bottom = -pad_top
	plate_inner.add_child(vbox)

	# ── CLOSE X (fixed top-right of plate, on top of vbox) ─────────────────
	# Added LAST so it renders above vbox and receives taps cleanly.
	_close_btn = Button.new()
	_close_btn.text = "✕"
	HUDStyle.style_button(_close_btn, HUDStyle.BTN_RED, 28 if _is_mobile_ui else 22)
	var x_size: int = 52 if _is_mobile_ui else 40
	_close_btn.custom_minimum_size = Vector2(x_size, x_size)
	_close_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_close_btn.offset_left   = -(x_size + 6)
	_close_btn.offset_top    = 6
	_close_btn.offset_right  = -6
	_close_btn.offset_bottom = 6 + x_size
	_close_btn.pressed.connect(_hide_ui)
	plate_inner.add_child(_close_btn)

	# ---- Captain header (avatar + name on left, stats on right) ----
	# Replaces the old centered credits label.  Stats refresh via signals
	# wired further down (UpgradeManager, EconomyManager) and on _show_ui()
	# for the per-session counters (planets / kills / playtime).
	_build_captain_header(vbox)

	# ---- Tabs: MARKET | UPGRADES | PLANETS | FORGE ----
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override("separation", 4)
	tab_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(tab_row)

	for tab_i in range(4):
		var tab_lbl: String = ["  MARKET  ", "  UPGRADES  ", "  PLANETS  ", "  FORGE  "][tab_i]
		var tb: Button = Button.new()
		tb.text = tab_lbl
		# toggle_mode + style_button gives us recessed-when-pressed behavior;
		# _switch_tab() swaps the active tab's stylebox to BTN_PINK and toggles
		# button_pressed so it renders pink + visually pushed in.
		tb.toggle_mode = true
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if _is_mobile_ui:
			tb.custom_minimum_size = Vector2(0, _TAB_H_MOBILE)
		_apply_tab_color(tb, false)  # initial: all inactive (blue, raised)
		var captured_i: int = tab_i
		tb.pressed.connect(func() -> void: _switch_tab(captured_i))
		tab_row.add_child(tb)
		_tab_btns.append(tb)

	# ── SCROLL CONTAINER (takes remaining height under the sticky header) ──
	# Only per-tab content scrolls; title/credits/inventory/tabs stay pinned.
	_market_scroll = ScrollContainer.new()
	_market_scroll.process_mode = PROCESS_MODE_ALWAYS
	_market_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_market_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_market_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_market_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(_market_scroll)

	var inner_vbox := VBoxContainer.new()
	inner_vbox.process_mode = PROCESS_MODE_ALWAYS
	inner_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	inner_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_vbox.add_theme_constant_override("separation", 10)
	_market_scroll.add_child(inner_vbox)

	# ======================== MARKET TAB ========================
	_tab_market_panel = VBoxContainer.new()
	_tab_market_panel.add_theme_constant_override("separation", 8)
	_tab_market_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_vbox.add_child(_tab_market_panel)

	_market_status = Label.new()
	_market_status.text = ""
	_market_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_market_status.add_theme_font_size_override("font_size", 15)
	_market_status.add_theme_color_override("font_color", Color(0.4, 1.0, 0.7))
	_market_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_market_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	_tab_market_panel.add_child(_market_status)

	# ── Bulk quantity selector (applies to BOTH sell and buy) ──────────
	# Single global mode drives every row's button labels + disabled state.
	# Resets to "1" each modal open so the player doesn't accidentally
	# bulk-trade on next visit (handled in _show_ui).
	var qty_row := HBoxContainer.new()
	qty_row.add_theme_constant_override("separation", 4)
	qty_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_market_panel.add_child(qty_row)

	var qty_lbl := Label.new()
	qty_lbl.text = "QUANTITY:"
	qty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	qty_lbl.add_theme_font_size_override("font_size", 16 if _is_mobile_ui else 14)
	qty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.7))
	qty_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	qty_lbl.custom_minimum_size = Vector2(110 if _is_mobile_ui else 90, 0)
	qty_row.add_child(qty_lbl)

	_market_qty_btns.clear()
	var presets: Array = ["1", "10", "100", "max"]
	for p_i in range(presets.size()):
		var preset: String = presets[p_i]
		var btn := _TapButton.new()
		btn.slop_sq = pow(_TAP_SLOP_MOBILE if _is_mobile_ui else _TAP_SLOP_DESKTOP, 2)
		btn.text = ("×" + preset) if preset != "max" else "MAX"
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if _is_mobile_ui:
			btn.custom_minimum_size = Vector2(0, _TAB_H_MOBILE - 8)
		else:
			btn.custom_minimum_size = Vector2(0, 32)
		_apply_qty_btn_color(btn, preset == _market_qty_mode)
		var captured_preset: String = preset
		btn.tapped.connect(func() -> void: _on_market_qty_pressed(captured_preset))
		qty_row.add_child(btn)
		_market_qty_btns.append(btn)

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

	var sell_all_btn := _TapButton.new()
	sell_all_btn.slop_sq = pow(_TAP_SLOP_MOBILE if _is_mobile_ui else _TAP_SLOP_DESKTOP, 2)
	sell_all_btn.text = "Sell ALL Resources"
	HUDStyle.style_button(sell_all_btn, HUDStyle.BTN_GREEN, 22 if _is_mobile_ui else 20)
	if _is_mobile_ui:
		sell_all_btn.custom_minimum_size = Vector2(0, _BIGBTN_H_MOBILE)
	sell_all_btn.tapped.connect(_on_sell_all)
	_tab_market_panel.add_child(sell_all_btn)

	# ======================== FORGE TAB ========================
	# Forge tab is a sibling of _market_scroll under `vbox` (NOT inside the
	# outer ScrollContainer).  This lets the slots+button column fill the
	# visible height exactly, with only the resources column scrolling.
	# _switch_tab toggles _market_scroll vs _tab_forge_panel visibility.
	_tab_forge_panel = HBoxContainer.new()
	_tab_forge_panel.add_theme_constant_override("separation", 12)
	_tab_forge_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_forge_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tab_forge_panel)

	# ── LEFT COLUMN: scrollable resource list ─────────────────────────
	var left_col := VBoxContainer.new()
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_col.add_theme_constant_override("separation", 6)
	_tab_forge_panel.add_child(left_col)

	var forge_title := Label.new()
	forge_title.text = "— RESOURCES —\nDrag or tap to fill slots"
	forge_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	forge_title.add_theme_font_size_override("font_size", 18 if _is_mobile_ui else 16)
	forge_title.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	forge_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	forge_title.autowrap_mode = TextServer.AUTOWRAP_WORD
	left_col.add_child(forge_title)

	var res_scroll := ScrollContainer.new()
	res_scroll.process_mode = PROCESS_MODE_ALWAYS
	res_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	res_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	res_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	res_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left_col.add_child(res_scroll)

	# Repurpose _forge_card_grid as a vertical list of resource rows. Same
	# member name to avoid churn at callsites; only the layout differs.
	_forge_card_grid = VBoxContainer.new()
	_forge_card_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_forge_card_grid.add_theme_constant_override("separation", 6)
	res_scroll.add_child(_forge_card_grid)

	_forge_status = Label.new()
	_forge_status.text = ""
	_forge_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_forge_status.add_theme_font_size_override("font_size", 15)
	_forge_status.add_theme_color_override("font_color", Color(1.0, 0.5, 0.3))
	_forge_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_forge_status.autowrap_mode = TextServer.AUTOWRAP_WORD
	left_col.add_child(_forge_status)

	# ── RIGHT COLUMN: 3 large stacked slots + cost + giant FORGE button ─
	var right_col := VBoxContainer.new()
	right_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_col.add_theme_constant_override("separation", 6)
	var right_col_w: int = 240 if _is_mobile_ui else 300
	right_col.custom_minimum_size = Vector2(right_col_w, 0)
	_tab_forge_panel.add_child(right_col)

	var slots_header := Label.new()
	slots_header.text = "— FORGE PLANET —\nUse resources to forge a planet"
	slots_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slots_header.add_theme_font_size_override("font_size", 20 if _is_mobile_ui else 18)
	slots_header.add_theme_color_override("font_color", Color(0.8, 0.6, 1.0))
	slots_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	slots_header.autowrap_mode = TextServer.AUTOWRAP_WORD
	right_col.add_child(slots_header)

	# Vertical group of the 3 slots — its own EXPAND_FILL wrapper so the cost
	# label + FORGE button sit snug at the bottom (small separation), while
	# the slots share whatever vertical space remains.
	var slots_box := VBoxContainer.new()
	slots_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slots_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	slots_box.add_theme_constant_override("separation", 8)
	right_col.add_child(slots_box)

	for i in range(3):
		var slot_panel := ForgeSlot.new()
		slot_panel.slot_index = i
		slot_panel.station_ref = self
		slot_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

		var slot_sb := StyleBoxFlat.new()
		slot_sb.bg_color = Color(0.08, 0.08, 0.15)
		slot_sb.border_color = Color(0.4, 0.4, 0.6)
		slot_sb.set_border_width_all(2)
		slot_sb.set_corner_radius_all(10)
		slot_sb.content_margin_left = 10; slot_sb.content_margin_right = 10
		slot_sb.content_margin_top = 8;   slot_sb.content_margin_bottom = 8
		slot_panel.add_theme_stylebox_override("panel", slot_sb)

		# Side-by-side: large abbrev on the left, small "tap to remove" hint
		# on the right.  Center-aligned so the empty placeholder reads cleanly.
		var slot_hb := HBoxContainer.new()
		slot_hb.alignment = BoxContainer.ALIGNMENT_CENTER
		slot_hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot_hb.size_flags_vertical = Control.SIZE_EXPAND_FILL
		slot_hb.add_theme_constant_override("separation", 12)
		slot_panel.add_child(slot_hb)

		var slot_lbl := Label.new()
		slot_lbl.text = "[ SLOT " + str(i + 1) + " ]"
		slot_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_lbl.add_theme_font_size_override("font_size", 32 if _is_mobile_ui else 28)
		slot_lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
		slot_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot_hb.add_child(slot_lbl)
		_forge_slot_labels.append(slot_lbl)

		# Hidden until the slot is filled — then surfaces "tap to remove" so
		# players discover the removal gesture.  Sits to the right of the
		# abbreviation so it reads as "Cu — tap to remove".
		var slot_hint := Label.new()
		slot_hint.text = "tap to remove"
		slot_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot_hint.add_theme_font_size_override("font_size", 14 if _is_mobile_ui else 12)
		slot_hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.8, 0.85))
		slot_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot_hint.visible = false
		slot_hb.add_child(slot_hint)
		_forge_slot_hints.append(slot_hint)

		# Keep _forge_slots populated for legacy compatibility (handlers
		# elsewhere index into it).  Remove buttons aren't used in this layout.
		var remove_btn := Button.new()
		remove_btn.visible = false
		_forge_slots.append(remove_btn)

		_forge_slot_panels.append(slot_panel)
		slots_box.add_child(slot_panel)

	# Cost + button live in a tight footer group so the button hugs the slots.
	var footer := VBoxContainer.new()
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_theme_constant_override("separation", 4)
	right_col.add_child(footer)

	_forge_cost_label = Label.new()
	_forge_cost_label.text = ""
	_forge_cost_label.add_theme_font_size_override("font_size", 22 if _is_mobile_ui else 18)
	_forge_cost_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	_forge_cost_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_forge_cost_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	footer.add_child(_forge_cost_label)

	_forge_btn = Button.new()
	_forge_btn.text = "FORGE PLANET"
	HUDStyle.style_button(_forge_btn, HUDStyle.BTN_PINK, 40 if _is_mobile_ui else 36)
	_forge_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_forge_btn.custom_minimum_size = Vector2(0, 120 if _is_mobile_ui else 96)
	_forge_btn.pressed.connect(_on_forge_planet)
	# Forge-ready animation scales from the button's centre.
	_forge_btn.pivot_offset = Vector2.ZERO
	_forge_btn.resized.connect(func() -> void:
		_forge_btn.pivot_offset = _forge_btn.size * 0.5)
	footer.add_child(_forge_btn)

	# Active Worlds section intentionally removed from the Forge tab —
	# replaced by the dedicated Planets tab below.

	# ======================== PLANETS TAB ========================
	# Sibling of _tab_forge_panel under `vbox` — fills the visible area and
	# never overflows into the outer ScrollContainer.  One planet at a time;
	# prev/next arrows step through _active_planets.
	_tab_planets_panel = HBoxContainer.new()
	_tab_planets_panel.add_theme_constant_override("separation", 8)
	_tab_planets_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_planets_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_planets_panel.visible = false
	vbox.add_child(_tab_planets_panel)

	_planet_prev_btn = Button.new()
	_planet_prev_btn.text = "‹"
	HUDStyle.style_button(_planet_prev_btn, HUDStyle.BTN_BLUE, 48 if _is_mobile_ui else 40)
	_planet_prev_btn.custom_minimum_size = Vector2(64 if _is_mobile_ui else 52, 0)
	_planet_prev_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_planet_prev_btn.pressed.connect(_on_planet_prev)
	_tab_planets_panel.add_child(_planet_prev_btn)

	# Clipping window so the slide animation doesn't bleed past the arrows.
	# The center content is a child of this Control with PRESET_FULL_RECT
	# anchors so we can tween its offsets to slide it horizontally.
	_planet_content_window = Control.new()
	_planet_content_window.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_planet_content_window.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_planet_content_window.clip_contents = true
	_planet_content_window.mouse_filter = Control.MOUSE_FILTER_PASS
	_tab_planets_panel.add_child(_planet_content_window)

	_planet_content_root = VBoxContainer.new()
	_planet_content_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_planet_content_root.add_theme_constant_override("separation", 6)
	_planet_content_root.alignment = BoxContainer.ALIGNMENT_BEGIN
	_planet_content_window.add_child(_planet_content_root)

	# Page indicator sits across the top, centered above the two columns.
	_planet_page_lbl = Label.new()
	_planet_page_lbl.text = ""
	_planet_page_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_planet_page_lbl.add_theme_font_size_override("font_size", 14 if _is_mobile_ui else 13)
	_planet_page_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.65))
	_planet_page_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_planet_content_root.add_child(_planet_page_lbl)

	# ── TWO COLUMNS: illustration left, resource chips right ──────────
	var two_col := HBoxContainer.new()
	two_col.add_theme_constant_override("separation", 16)
	two_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	two_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_planet_content_root.add_child(two_col)

	# ── LEFT COLUMN: name / rank+combo / large illustration ───────────
	var planet_left := VBoxContainer.new()
	planet_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	planet_left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	planet_left.alignment = BoxContainer.ALIGNMENT_CENTER
	planet_left.add_theme_constant_override("separation", 8)
	two_col.add_child(planet_left)

	_planet_name_lbl = Label.new()
	_planet_name_lbl.text = ""
	_planet_name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_planet_name_lbl.add_theme_font_size_override("font_size", 28 if _is_mobile_ui else 26)
	_planet_name_lbl.add_theme_color_override("font_color", Color(0.9, 0.92, 1.0))
	_planet_name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	planet_left.add_child(_planet_name_lbl)

	# Rank badge + combo on one line, centered.
	var rank_row := HBoxContainer.new()
	rank_row.alignment = BoxContainer.ALIGNMENT_CENTER
	rank_row.add_theme_constant_override("separation", 12)
	planet_left.add_child(rank_row)

	_planet_rank_badge = PanelContainer.new()
	_planet_rank_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var badge_sb := StyleBoxFlat.new()
	badge_sb.bg_color = Color(0.2, 0.2, 0.25)
	badge_sb.border_color = Color(0.5, 0.5, 0.6)
	badge_sb.set_border_width_all(2)
	badge_sb.set_corner_radius_all(8)
	badge_sb.content_margin_left = 12; badge_sb.content_margin_right = 12
	badge_sb.content_margin_top = 3;   badge_sb.content_margin_bottom = 3
	_planet_rank_badge.add_theme_stylebox_override("panel", badge_sb)
	_planet_rank_lbl = Label.new()
	_planet_rank_lbl.text = ""
	_planet_rank_lbl.add_theme_font_size_override("font_size", 22 if _is_mobile_ui else 20)
	_planet_rank_badge.add_child(_planet_rank_lbl)
	rank_row.add_child(_planet_rank_badge)

	_planet_combo_lbl = Label.new()
	_planet_combo_lbl.text = ""
	_planet_combo_lbl.add_theme_font_size_override("font_size", 18 if _is_mobile_ui else 16)
	_planet_combo_lbl.add_theme_color_override("font_color", Color(0.75, 0.9, 0.8))
	_planet_combo_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	rank_row.add_child(_planet_combo_lbl)

	# Illustration fills the remaining vertical space in the left column.
	# STRETCH_KEEP_ASPECT_CENTERED + EXPAND_FILL lets the icon grow as big as
	# the column allows while staying square + crisp (nearest filter).
	_planet_illustration = TextureRect.new()
	_planet_illustration.custom_minimum_size = Vector2(
		240 if _is_mobile_ui else 280,
		240 if _is_mobile_ui else 280)
	_planet_illustration.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_planet_illustration.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_planet_illustration.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_planet_illustration.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_planet_illustration.size_flags_vertical = Control.SIZE_EXPAND_FILL
	planet_left.add_child(_planet_illustration)

	# ── RIGHT COLUMN: resource chip grid + dismantle ───────────────────
	var planet_right := VBoxContainer.new()
	planet_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	planet_right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	planet_right.add_theme_constant_override("separation", 10)
	two_col.add_child(planet_right)

	var slots_title := Label.new()
	slots_title.text = "RESOURCES ON THIS PLANET"
	slots_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slots_title.add_theme_font_size_override("font_size", 16 if _is_mobile_ui else 14)
	slots_title.add_theme_color_override("font_color", Color(0.7, 0.6, 1.0))
	slots_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	planet_right.add_child(slots_title)

	_planet_resource_grid = GridContainer.new()
	_planet_resource_grid.columns = 3
	_planet_resource_grid.add_theme_constant_override("h_separation", 8)
	_planet_resource_grid.add_theme_constant_override("v_separation", 10)
	_planet_resource_grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_planet_resource_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	planet_right.add_child(_planet_resource_grid)

	# Dismantle button — narrower and centered at the bottom of the column.
	_planet_dismantle_btn = Button.new()
	_planet_dismantle_btn.text = "Dismantle Planet"
	HUDStyle.style_button(_planet_dismantle_btn, HUDStyle.BTN_RED, 18 if _is_mobile_ui else 16)
	_planet_dismantle_btn.custom_minimum_size = Vector2(
		200 if _is_mobile_ui else 180,
		44 if _is_mobile_ui else 38)
	_planet_dismantle_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_planet_dismantle_btn.pressed.connect(_on_planet_view_dismantle)
	planet_right.add_child(_planet_dismantle_btn)

	# Empty state — shown when _active_planets is empty.  Sits on top of
	# the two-column layout so it can hide everything else without re-flow.
	_planet_empty_lbl = Label.new()
	_planet_empty_lbl.text = "No forged planets yet.\nForge one from the Forge tab."
	_planet_empty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_planet_empty_lbl.add_theme_font_size_override("font_size", 20 if _is_mobile_ui else 18)
	_planet_empty_lbl.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	_planet_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_planet_empty_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_planet_empty_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	_planet_empty_lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_planet_empty_lbl.visible = false
	_planet_content_window.add_child(_planet_empty_lbl)

	_planet_next_btn = Button.new()
	_planet_next_btn.text = "›"
	HUDStyle.style_button(_planet_next_btn, HUDStyle.BTN_BLUE, 48 if _is_mobile_ui else 40)
	_planet_next_btn.custom_minimum_size = Vector2(64 if _is_mobile_ui else 52, 0)
	_planet_next_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_planet_next_btn.pressed.connect(_on_planet_next)
	_tab_planets_panel.add_child(_planet_next_btn)

	# ======================== UPGRADES TAB ========================
	_tab_upgrades_panel = VBoxContainer.new()
	_tab_upgrades_panel.add_theme_constant_override("separation", 8)
	_tab_upgrades_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner_vbox.add_child(_tab_upgrades_panel)
	_build_upgrades_panel(_tab_upgrades_panel)

	var close_btn := Button.new()
	close_btn.text = "Close  [fly away]"
	HUDStyle.style_button(close_btn, HUDStyle.BTN_RED, 22 if _is_mobile_ui else 18)
	if _is_mobile_ui:
		close_btn.custom_minimum_size = Vector2(0, _BIGBTN_H_MOBILE)
	close_btn.pressed.connect(_hide_ui)
	inner_vbox.add_child(close_btn)

	# Wire signals
	if Engine.has_meta("EconomyManager"):
		var econ = Engine.get_meta("EconomyManager")
		econ.currency_changed.connect(func(n: int) -> void: _creds_label.text = "$" + str(n))
		_creds_label.text = "$" + str(econ.credits)

	if Engine.has_meta("InventoryManager"):
		var inv = Engine.get_meta("InventoryManager")
		inv.inventory_changed.connect(func(_t: String, _a: int) -> void:
			_refresh_inv_display()
			if _active_tab == 1:
				_rebuild_all_upgrade_rows())
		_refresh_inv_display()

	if Engine.has_meta("EconomyManager"):
		var econ2 = Engine.get_meta("EconomyManager")
		econ2.currency_changed.connect(func(_n: int) -> void:
			# Refresh the forge button's enabled state — it gates on credits
			# >= cost.  Without this, a market sale lifts your credits past
			# the cost but the Forge button stays disabled.
			_update_slot_display()
			# Market button labels (MAX-buy in particular) depend on credits.
			if _active_tab == 0:
				_rebuild_market_rows()
			if _active_tab == 1:
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
	# _inv_label was removed from the modal header; the per-resource quantities
	# now live in the Forge tab's left column.  Skip the summary if no label.
	if _inv_label != null:
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
	return HUDStyle.tier_color(tier)

# Push a sampled palette colour toward the brightness/saturation the player
# actually perceives on the rendered planet (which benefits from emission,
# HDR lighting and bloom).  Returns the boosted colour, clamped to [0, 1].
func _vivify_palette(col: Color, sat_mul: float, val_mul: float) -> Color:
	var h: float = col.h
	var s: float = clampf(col.s * sat_mul, 0.0, 1.0)
	var v: float = clampf(col.v * val_mul, 0.0, 1.0)
	var out: Color = Color.from_hsv(h, s, v)
	out.a = col.a
	return out

# Large, finger-visible drag preview used by ResourceCard and ForgeSlot.
# The Godot default puts the preview at the cursor's top-left, which on a
# touchscreen sits directly under the user's fingertip and can be obscured.
# We oversize the chip and offset its pivot so it floats above the finger.
func _make_drag_preview(res_id: String) -> Control:
	var rarity_col: Color = _tier_color(ResourceRegistry.get_tier(res_id))
	var full_name: String = String(ResourceRegistry.get_data(res_id).get("name", res_id))
	var abbrev: String = ResourceRegistry.get_abbrev(res_id)

	# Wrapper Control lets us shift the preview up so the chip floats above
	# the finger instead of hiding underneath it.
	var preview_root := Control.new()
	preview_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var chip_w: int = 220 if _is_mobile_ui else 180
	var chip_h: int = 96 if _is_mobile_ui else 76
	preview_root.custom_minimum_size = Vector2(chip_w, chip_h)

	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Float the chip above the finger so it stays visible on touch devices.
	chip.position = Vector2(- chip_w * 0.5, - chip_h - (40 if _is_mobile_ui else 12))
	var sb := StyleBoxFlat.new()
	sb.bg_color = rarity_col.darkened(0.45)
	sb.border_color = rarity_col
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14; sb.content_margin_right = 14
	sb.content_margin_top = 8;   sb.content_margin_bottom = 8
	chip.add_theme_stylebox_override("panel", sb)
	preview_root.add_child(chip)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(vb)

	var name_lbl := Label.new()
	name_lbl.text = full_name
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.add_theme_font_size_override("font_size", 22 if _is_mobile_ui else 18)
	name_lbl.add_theme_color_override("font_color", Color(1, 1, 1))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(name_lbl)

	var abbrev_lbl := Label.new()
	abbrev_lbl.text = abbrev
	abbrev_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	abbrev_lbl.add_theme_font_size_override("font_size", 26 if _is_mobile_ui else 22)
	abbrev_lbl.add_theme_color_override("font_color", rarity_col)
	abbrev_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(abbrev_lbl)

	return preview_root

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
		var full_name: String = String(ResourceRegistry.get_data(r).get("name", r))
		var abbrev: String = ResourceRegistry.get_abbrev(r)

		# Count how many times this resource is already selected
		var selected_count := _forge_selected.count(r)
		var available := amt - selected_count

		# Each resource is a full-width horizontal row: swatch | name (abbrev) | qty
		var card := ResourceCard.new()
		card.resource_id = r
		card.available_count = available
		card.station_ref = self
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.custom_minimum_size = Vector2(0, 64 if _is_mobile_ui else 48)

		var sb := StyleBoxFlat.new()
		sb.bg_color = rarity_col.darkened(0.65)
		sb.border_color = rarity_col
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		sb.content_margin_left = 10; sb.content_margin_right = 10
		sb.content_margin_top = 6;   sb.content_margin_bottom = 6
		card.add_theme_stylebox_override("panel", sb)

		var hb := HBoxContainer.new()
		hb.alignment = BoxContainer.ALIGNMENT_CENTER
		hb.add_theme_constant_override("separation", 10)
		hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_child(hb)

		# Tier color swatch on the left.
		var swatch := ColorRect.new()
		swatch.color = rarity_col
		swatch.custom_minimum_size = Vector2(14, 28)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(swatch)

		# "Copper (Cu)"
		var name_lbl := Label.new()
		name_lbl.text = full_name + " (" + abbrev + ")"
		name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_lbl.add_theme_font_size_override("font_size", 19 if _is_mobile_ui else 17)
		name_lbl.add_theme_color_override("font_color", rarity_col)
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hb.add_child(name_lbl)

		# Quantity on the right.
		var qty_lbl := Label.new()
		qty_lbl.text = "x" + str(amt)
		if selected_count > 0:
			qty_lbl.text += "  (" + str(available) + " left)"
		qty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		qty_lbl.add_theme_font_size_override("font_size", 17 if _is_mobile_ui else 15)
		qty_lbl.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		qty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		qty_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		hb.add_child(qty_lbl)

		# Greyed out if none available or slots full
		var can_pick := available > 0 and _forge_selected.size() < 3
		if not can_pick:
			sb.bg_color = Color(0.08, 0.08, 0.1)
			sb.border_color = Color(0.25, 0.25, 0.3)
			name_lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
			swatch.color = rarity_col.darkened(0.6)
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
	# The deferred dispatch can outrun scene-teardown (e.g. when the player
	# triggers New Game and the reset fires inventory_changed signals while
	# the scene is about to reload).  By the time we get here the SpaceStation
	# may be detached, making get_viewport() null.  Bail safely in that case.
	if not is_inside_tree(): return
	var vp := get_viewport()
	if vp == null: return
	# Only steal focus if the previously-focused control is gone (i.e. it
	# was a card we just freed) — otherwise the user might have moved to
	# a slot or the Forge button and we'd yank them back.
	var f: Control = vp.gui_get_focus_owner()
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
		var filled := i < _forge_selected.size()
		var slot_sb: StyleBoxFlat = null
		if i < _forge_slot_panels.size():
			slot_sb = _forge_slot_panels[i].get_theme_stylebox("panel") as StyleBoxFlat
		if filled:
			var r := _forge_selected[i]
			var tier := ResourceRegistry.get_tier(r)
			var col := _tier_color(tier)
			lbl.text = ResourceRegistry.get_abbrev(r)
			lbl.add_theme_color_override("font_color", col)
			if slot_sb:
				slot_sb.bg_color = col.darkened(0.7)
				slot_sb.border_color = col
			if i < _forge_slot_hints.size():
				_forge_slot_hints[i].add_theme_color_override("font_color", col.lerp(Color(1, 1, 1), 0.4))
		else:
			lbl.text = "[ SLOT " + str(i + 1) + " ]"
			lbl.add_theme_color_override("font_color", Color(0.5, 0.5, 0.6))
			if slot_sb:
				slot_sb.bg_color = Color(0.08, 0.08, 0.15)
				slot_sb.border_color = Color(0.4, 0.4, 0.6)
		if i < _forge_slot_hints.size():
			_forge_slot_hints[i].visible = filled

	var slots_full := _forge_selected.size() >= 3
	var credit_cost := 0
	var can_afford_credits := true
	if slots_full:
		credit_cost = 0 if _total_forges == 0 else PlanetSeedKitchen.forge_credit_cost(
			_forge_selected[0], _forge_selected[1], _forge_selected[2])
		if credit_cost > 0 and Engine.has_meta("EconomyManager"):
			can_afford_credits = int(Engine.get_meta("EconomyManager").credits) >= credit_cost

	if _forge_cost_label:
		if not slots_full:
			_forge_cost_label.text = ""
		elif _total_forges == 0:
			_forge_cost_label.text = "FREE — FIRST FORGE"
			_forge_cost_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.6))
		else:
			_forge_cost_label.text = "FORGE COST: $" + str(credit_cost)
			var ok_col := Color(0.85, 0.85, 0.6) if can_afford_credits else Color(1.0, 0.5, 0.3)
			_forge_cost_label.add_theme_color_override("font_color", ok_col)

	# Enable forge button only when all 3 slots filled AND credits sufficient
	if _forge_btn:
		_forge_btn.disabled = not slots_full or not can_afford_credits

	# Celebration animation when the player has met all conditions to forge.
	var should_glow := slots_full and can_afford_credits
	if should_glow and not _forge_ready_active:
		_start_forge_ready_anim()
	elif not should_glow and _forge_ready_active:
		_stop_forge_ready_anim()


func _start_forge_ready_anim() -> void:
	if _forge_btn == null: return
	_forge_ready_active = true
	if _forge_ready_tween: _forge_ready_tween.kill()
	if _forge_ready_scale_tween: _forge_ready_scale_tween.kill()
	_forge_btn.pivot_offset = _forge_btn.size * 0.5

	# Rainbow modulate cycle — bright tints that read against the pink button.
	var col_a := Color(1.4, 0.8, 1.3)   # pink-magenta
	var col_b := Color(0.9, 1.4, 1.0)   # green
	var col_c := Color(1.0, 1.1, 1.5)   # cyan-blue
	_forge_ready_tween = create_tween().set_loops()
	_forge_ready_tween.tween_property(_forge_btn, "modulate", col_a, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_forge_ready_tween.tween_property(_forge_btn, "modulate", col_b, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_forge_ready_tween.tween_property(_forge_btn, "modulate", col_c, 0.7) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	# Scale pulse in parallel.
	_forge_ready_scale_tween = create_tween().set_loops()
	_forge_ready_scale_tween.tween_property(_forge_btn, "scale", Vector2(1.05, 1.05), 0.55) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_forge_ready_scale_tween.tween_property(_forge_btn, "scale", Vector2.ONE, 0.55) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_forge_ready_anim() -> void:
	_forge_ready_active = false
	if _forge_ready_tween:
		_forge_ready_tween.kill()
		_forge_ready_tween = null
	if _forge_ready_scale_tween:
		_forge_ready_scale_tween.kill()
		_forge_ready_scale_tween = null
	if _forge_btn:
		_forge_btn.modulate = Color.WHITE
		_forge_btn.scale = Vector2.ONE

func _refresh_planets_ui() -> void:
	# Populates the Planets tab with the currently-paged planet.  Safe to
	# call when the tab hasn't been built yet (e.g. during early _show_ui).
	if _tab_planets_panel == null or _planet_resource_grid == null:
		return

	var total := _active_planets.size()

	# Clamp page index whenever the list size changes (e.g. after dismantle).
	if total == 0:
		_planet_view_idx = 0
	else:
		_planet_view_idx = clampi(_planet_view_idx, 0, total - 1)

	# Empty state overlays the populated content via PRESET_FULL_RECT inside
	# _planet_content_window, so we just toggle the two as a pair.
	var has_planets := total > 0
	if _planet_content_root: _planet_content_root.visible = has_planets
	if _planet_empty_lbl: _planet_empty_lbl.visible = not has_planets
	# Page indicator + arrows are only meaningful when there's something to page through.
	if _planet_page_lbl: _planet_page_lbl.visible = total > 1
	if _planet_prev_btn: _planet_prev_btn.visible = total > 1
	if _planet_next_btn: _planet_next_btn.visible = total > 1

	for c in _planet_resource_grid.get_children():
		c.queue_free()

	if not has_planets:
		return

	var entry: Dictionary = _active_planets[_planet_view_idx]
	var r1: String = entry.get("r1", "")
	var r2: String = entry.get("r2", "")
	var r3: String = entry.get("r3", "")
	var seed_val: int = int(entry.get("seed_val", PlanetSeedKitchen.make_seed(r1, r2, r3)))
	var rank: Dictionary = PlanetSeedKitchen.rank_planet(
		r1, r2, r3, seed_val, float(entry.get("luck_variance", 0.0)))

	_planet_page_lbl.text = str(_planet_view_idx + 1) + " / " + str(total)
	_planet_name_lbl.text = _display_planet_name(entry)

	_planet_rank_lbl.text = String(rank.get("label", "?"))
	_planet_rank_lbl.add_theme_color_override("font_color", rank.color)
	var badge_sb: StyleBoxFlat = _planet_rank_badge.get_theme_stylebox("panel") as StyleBoxFlat
	if badge_sb:
		badge_sb.bg_color = rank.color.darkened(0.55)
		badge_sb.border_color = rank.color

	var combo: String = ResourceRegistry.get_abbrev(r1) + "+" + ResourceRegistry.get_abbrev(r2) + "+" + ResourceRegistry.get_abbrev(r3)
	_planet_combo_lbl.text = combo
	_planet_illustration.texture = _planet_thumbnail_for(entry)

	# Resource discovery slots.  Pool = the planet's natural spawn list, but
	# Wood/Carbon Fiber nodes can drop *secondary* resources outside that pool
	# (Living Resin, Primal Fruit, Organic Sludge).  So we display the UNION
	# of the pool + anything the player has actually discovered here.  This
	# way blue/purple secondaries the player mined show up as discovered
	# chips even though they weren't in the planet's base pool.
	#
	# Sorted least → most rare; ties break alphabetically.
	var discovered: Array = entry.get("discovered", ["Stone", "Wood"])
	var pool: Array = PlanetSeedKitchen.resources_for_planet(r1, r2, r3)
	var combined: Dictionary = {}
	for r in pool: combined[String(r)] = true
	for r in discovered: combined[String(r)] = true
	var display_list: Array = combined.keys()
	display_list.sort_custom(func(a, b):
		var ta := ResourceRegistry.get_tier(String(a))
		var tb := ResourceRegistry.get_tier(String(b))
		if ta != tb: return ta < tb
		return String(a) < String(b))
	for res_name in display_list:
		_planet_resource_grid.add_child(
			_build_planet_resource_chip(String(res_name), discovered.has(String(res_name))))


# Build a single resource-slot chip for the Planets tab.
# Discovered: solid rarity-tinted chip with abbrev + full name.
# Locked:     faded tier-colored silhouette, no text — partial reveal of rarity.
func _build_planet_resource_chip(res_name: String, discovered: bool) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var chip_w: int = 130 if _is_mobile_ui else 150
	var chip_h: int = 64 if _is_mobile_ui else 60
	chip.custom_minimum_size = Vector2(chip_w, chip_h)

	var tier := ResourceRegistry.get_tier(res_name)
	var col := _tier_color(tier)

	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 8; sb.content_margin_right = 8
	sb.content_margin_top = 4;  sb.content_margin_bottom = 4
	if discovered:
		sb.bg_color = col.darkened(0.65)
		sb.border_color = col
		sb.set_border_width_all(2)
	else:
		# Locked: very dim wash of the tier color so rarity is hinted.
		sb.bg_color = col.darkened(0.85)
		sb.border_color = col.darkened(0.6)
		sb.set_border_width_all(1)
	chip.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(vb)

	if discovered:
		var ab := Label.new()
		ab.text = ResourceRegistry.get_abbrev(res_name)
		ab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ab.add_theme_font_size_override("font_size", 24 if _is_mobile_ui else 22)
		ab.add_theme_color_override("font_color", col)
		ab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(ab)

		var nm := Label.new()
		nm.text = String(ResourceRegistry.get_data(res_name).get("name", res_name))
		nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
		nm.add_theme_font_size_override("font_size", 14 if _is_mobile_ui else 13)
		nm.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		nm.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(nm)
	else:
		# Locked silhouette: a single faint glyph hint so the chip doesn't
		# read as totally empty — purely decorative, no resource identity.
		var lock_lbl := Label.new()
		lock_lbl.text = "?"
		lock_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		lock_lbl.add_theme_font_size_override("font_size", 24 if _is_mobile_ui else 22)
		lock_lbl.add_theme_color_override("font_color", col.darkened(0.3))
		lock_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vb.add_child(lock_lbl)

	return chip


func _on_planet_prev() -> void:
	_slide_to_planet(-1)


func _on_planet_next() -> void:
	_slide_to_planet(1)


# Slide the current planet view off-screen, swap to the new index, then
# slide the new view in from the opposite side.  `dir`: -1 = previous (slide
# right out, new comes in from left), +1 = next (slide left out, in from right).
func _slide_to_planet(dir: int) -> void:
	if _planet_slide_in_progress: return
	if _active_planets.size() <= 1: return
	if _planet_content_root == null or _planet_content_window == null: return
	_planet_slide_in_progress = true

	var W: float = max(_planet_content_window.size.x, 600.0)
	if _planet_slide_tween: _planet_slide_tween.kill()

	# Phase 1: slide out in the direction of travel.
	var t1 := create_tween().set_parallel(true)
	t1.tween_property(_planet_content_root, "offset_left", -dir * W, 0.16) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	t1.tween_property(_planet_content_root, "offset_right", -dir * W, 0.16) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_planet_slide_tween = t1
	await t1.finished

	# Swap data + jump to the opposite side so the slide-in feels continuous.
	_planet_view_idx = (_planet_view_idx + dir + _active_planets.size()) % _active_planets.size()
	_planet_content_root.offset_left = dir * W
	_planet_content_root.offset_right = dir * W
	_refresh_planets_ui()

	# Phase 2: slide in from the opposite side.
	var t2 := create_tween().set_parallel(true)
	t2.tween_property(_planet_content_root, "offset_left", 0.0, 0.20) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t2.tween_property(_planet_content_root, "offset_right", 0.0, 0.20) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_planet_slide_tween = t2
	await t2.finished
	_planet_slide_in_progress = false


func _on_planet_view_dismantle() -> void:
	if _active_planets.is_empty(): return
	if _planet_view_idx < 0 or _planet_view_idx >= _active_planets.size(): return
	_on_dismantle(_active_planets[_planet_view_idx])

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
			if not _ui_visible and not _cinematic_active and not _hud_hidden:
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
	if _prompt_btn.visible and (get_tree().paused or _hud_hidden):
		_prompt_btn.hide()
	elif not _prompt_btn.visible and _in_range and not _ui_visible \
			and not _cinematic_active and not _hud_hidden and not get_tree().paused:
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

# Compute hardware safe-area insets (notch, Dynamic Island, home indicator).
# Mirrors the pattern in MobileControlsUI._calculate_safe_area().
func _calculate_safe_area() -> void:
	var safe_rect = DisplayServer.screen_get_usable_rect()
	var screen_sz = Vector2(DisplayServer.screen_get_size())
	_safe_left   = max(0.0, float(safe_rect.position.x))
	_safe_top    = max(0.0, float(safe_rect.position.y))
	_safe_right  = max(0.0, screen_sz.x - float(safe_rect.position.x + safe_rect.size.x))
	_safe_bottom = max(0.0, screen_sz.y - float(safe_rect.position.y + safe_rect.size.y))

# Suppress MobileControlsUI input + drawing while the modal is up so its
# combat / pause-mode columns can't intercept swipes meant for the
# ScrollContainer or render over the modal plate.
func _notify_mobile_controls(open: bool) -> void:
	var mc = get_tree().get_first_node_in_group("mobile_controls_ui")
	if mc and mc.has_method("set_modal_ui_open"):
		mc.set_modal_ui_open(open)

var _hud_was_visible: Array = []   # snapshot of HUD nodes hidden by _show_ui

func _show_ui() -> void:
	_ui_visible = true
	_notify_mobile_controls(true)
	_panel.show()
	# Reset bulk-trade mode each session so the player never bulk-sells by
	# accident on next visit.  The visual state of the segmented selector
	# is repainted inside the rebuild below.
	_market_qty_mode = "1"
	for b in _market_qty_btns:
		_apply_qty_btn_color(b, b.text == "×1")
	_refresh_inv_display()
	_rebuild_market_rows()
	_refresh_planets_ui()
	_refresh_captain_header()
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
	_notify_mobile_controls(false)
	_stop_forge_ready_anim()
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
	# Tab index map: 0 Market, 1 Upgrades, 2 Planets, 3 Forge.
	# Market + Upgrades live inside the outer ScrollContainer; Planets and
	# Forge are siblings of the scroll (so they can fill the visible height).
	if _tab_market_panel:   _tab_market_panel.visible   = (idx == 0)
	if _tab_upgrades_panel: _tab_upgrades_panel.visible = (idx == 1)
	if _tab_planets_panel:  _tab_planets_panel.visible  = (idx == 2)
	if _tab_forge_panel:    _tab_forge_panel.visible    = (idx == 3)
	if _market_scroll:      _market_scroll.visible      = (idx == 0 or idx == 1)
	if idx == 1:
		_rebuild_all_upgrade_rows()
	elif idx == 2:
		_refresh_planets_ui()
	# Active tab: pink + recessed.  Inactive tabs: blue + raised.  Mirrors the
	# EASY-button "selected = pushed-in pink" look from the Designercize ref.
	for i in _tab_btns.size():
		_apply_tab_color(_tab_btns[i], i == idx)
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
		1: panel = _tab_upgrades_panel
		2: panel = _tab_planets_panel
		3: panel = _tab_forge_panel
	if panel == null: return
	var first := _find_first_focusable(panel)
	if first: first.grab_focus()


func _find_first_focusable(n: Node) -> Control:
	# Depth-first walk to the first Control that accepts focus.
	# Skip disabled buttons — focusing them paints the bright focus stylebox
	# over the disabled stylebox, which misleadingly makes a button the player
	# can't actually press look enabled.
	if n is Control:
		var c: Control = n
		if c.focus_mode != Control.FOCUS_NONE and c.is_visible_in_tree():
			if c is BaseButton and (c as BaseButton).disabled:
				pass  # fall through to children
			else:
				return c
	for child in n.get_children():
		var found := _find_first_focusable(child)
		if found: return found
	return null

func _apply_tab_color(btn: Button, active: bool) -> void:
	var fs: int = 22 if _is_mobile_ui else 20
	var base_col: Color = HUDStyle.BTN_PINK if active else HUDStyle.BTN_BLUE
	HUDStyle.style_button(btn, base_col, fs)
	btn.button_pressed = active

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

func _on_sell_resource(resource_type: String) -> void:
	if not Engine.has_meta("InventoryManager") or not Engine.has_meta("EconomyManager"): return
	var inv = Engine.get_meta("InventoryManager")
	var econ = Engine.get_meta("EconomyManager")
	var held: int = inv.get_amount(resource_type)
	var qty: int = _market_qty_for_sell(held)
	if qty <= 0 or held < qty:
		_set_market_status("Not enough " + resource_type + " to sell ×" + str(max(qty, 1)) + ".", Color(1.0, 0.5, 0.3))
		return
	var unit_price: int = ResourceRegistry.get_value(resource_type)
	var total: int = qty * unit_price
	inv.consume(resource_type, qty)
	econ.add_credits(total)
	_set_market_status("+$" + str(total) + " — Sold ×" + str(qty) + " " + resource_type, Color(0.4, 1.0, 0.7))
	_refresh_inv_display()

func _on_buy_resource(resource_type: String) -> void:
	if not Engine.has_meta("InventoryManager") or not Engine.has_meta("EconomyManager"): return
	var inv = Engine.get_meta("InventoryManager")
	var econ = Engine.get_meta("EconomyManager")
	var unit_price: int = ResourceRegistry.get_buy_price(resource_type)
	var qty: int = _market_qty_for_buy(unit_price, int(econ.credits))
	var total: int = qty * unit_price
	if qty <= 0 or econ.credits < total:
		_set_market_status("Need $" + str(total) + " to buy ×" + str(max(qty, 1)) + " " + resource_type, Color(1.0, 0.5, 0.3))
		return
	econ.credits -= total
	econ.emit_signal("currency_changed", econ.credits)
	inv.add(resource_type, qty)
	_set_market_status("-$" + str(total) + " — Bought ×" + str(qty) + " " + resource_type, Color(1.0, 0.85, 0.3))
	_refresh_inv_display()

# Resolve the effective sell quantity based on the active selector mode and
# how much the player currently holds.  "max" returns everything; numeric
# modes return the literal value (caller checks for `held < qty` to disable
# the button when there isn't enough).
func _market_qty_for_sell(held: int) -> int:
	match _market_qty_mode:
		"10": return 10
		"100": return 100
		"max": return held
		_: return 1

# Same for the buy side — "max" is the largest qty the player can afford
# at the given unit price.  Returns 0 when the player can't even afford one.
func _market_qty_for_buy(unit_price: int, credits: int) -> int:
	match _market_qty_mode:
		"10": return 10
		"100": return 100
		"max":
			if unit_price <= 0: return 0
			return credits / unit_price
		_: return 1

# Format a market-row button label.  MAX mode appends the count so the
# player can see how many will trade without having to glance at the Held
# column; numeric modes hide the count since it's already in the button text.
func _market_btn_label(total: int, qty: int) -> String:
	if _market_qty_mode == "max":
		return "$" + str(total) + " (×" + str(qty) + ")"
	return "$" + str(total)

func _on_market_qty_pressed(preset: String) -> void:
	if _market_qty_mode == preset:
		# Re-affirm visual state — the toggle button can come up un-pressed if
		# the user clicks the active one again.
		for b in _market_qty_btns:
			_apply_qty_btn_color(b, b.text == ("×" + preset) or (preset == "max" and b.text == "MAX"))
		return
	_market_qty_mode = preset
	for b in _market_qty_btns:
		_apply_qty_btn_color(b, b.text == ("×" + preset) or (preset == "max" and b.text == "MAX"))
	_rebuild_market_rows()

func _apply_qty_btn_color(btn: Button, active: bool) -> void:
	var fs: int = 18 if _is_mobile_ui else 14
	var base_col: Color = HUDStyle.BTN_PINK if active else HUDStyle.BTN_BLUE
	HUDStyle.style_button(btn, base_col, fs)
	btn.button_pressed = active

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
		var buy_price: int = ResourceRegistry.get_buy_price(r)
		var held: int = inv_ref.get_amount(r) if inv_ref else 0
		var credits_val: int = econ_ref.credits if econ_ref else 0
		var abbrev: String = ResourceRegistry.get_abbrev(r)

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
		name_lbl.text = r + " (" + abbrev + ")"
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

		# ── Sell button (quantity from global _market_qty_mode) ────────
		var sell_qty: int = _market_qty_for_sell(held)
		var sell_btn := _TapButton.new()
		sell_btn.slop_sq = pow(_TAP_SLOP_MOBILE if _is_mobile_ui else _TAP_SLOP_DESKTOP, 2)
		sell_btn.text = _market_btn_label(sell_qty * sell_val, sell_qty)
		HUDStyle.style_button(sell_btn, HUDStyle.BTN_GREEN, 18 if _is_mobile_ui else 13)
		if _is_mobile_ui:
			sell_btn.custom_minimum_size = Vector2(_BTN_MIN_W_MOBILE, _BTN_H_MOBILE)
			sell_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			sell_btn.custom_minimum_size = Vector2(58, 28)
		sell_btn.disabled = sell_qty <= 0 or held < sell_qty
		var sell_r: String = r  # capture
		sell_btn.tapped.connect(func() -> void: _on_sell_resource(sell_r))
		row.add_child(sell_btn)

		# ── Buy button (quantity from global _market_qty_mode) ─────────
		var buy_qty: int = _market_qty_for_buy(buy_price, credits_val)
		var buy_btn := _TapButton.new()
		buy_btn.slop_sq = pow(_TAP_SLOP_MOBILE if _is_mobile_ui else _TAP_SLOP_DESKTOP, 2)
		buy_btn.text = _market_btn_label(buy_qty * buy_price, buy_qty)
		HUDStyle.style_button(buy_btn, HUDStyle.BTN_YELLOW, 18 if _is_mobile_ui else 13)
		if _is_mobile_ui:
			buy_btn.custom_minimum_size = Vector2(_BTN_MIN_W_MOBILE, _BTN_H_MOBILE)
			buy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			buy_btn.custom_minimum_size = Vector2(58, 28)
		buy_btn.disabled = buy_qty <= 0 or credits_val < buy_qty * buy_price
		var buy_r: String = r  # capture
		buy_btn.tapped.connect(func() -> void: _on_buy_resource(buy_r))
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

	# Credit cost: first forge in this save is free, subsequent forges scale
	# with the tiers of the chosen minerals.
	var credit_cost: int = 0 if _total_forges == 0 else PlanetSeedKitchen.forge_credit_cost(r1, r2, r3)
	var econ_ref = Engine.get_meta("EconomyManager") if Engine.has_meta("EconomyManager") else null
	if credit_cost > 0 and (econ_ref == null or int(econ_ref.credits) < credit_cost):
		var have: int = int(econ_ref.credits) if econ_ref else 0
		_set_status("Need $" + str(credit_cost) + " to forge\n(have $" + str(have) + ")", Color(1.0, 0.5, 0.3))
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

		# 1. Consume resources + credits
		for res in cost:
			inv.consume(res, cost[res])
		if credit_cost > 0 and econ_ref != null:
			econ_ref.credits = int(econ_ref.credits) - credit_cost
			econ_ref.emit_signal("currency_changed", econ_ref.credits)
		_total_forges += 1

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
		# `discovered` tracks resource types the player has mined from this
		# planet; Stone + Wood are pre-filled as they're always present.
		_active_planets.append({
			node = planet_node,
			r1 = r1, r2 = r2, r3 = r3,
			luck_variance = luck_var,
			pos = pos,
			name = p_name,
			seed_val = seed_val,
			discovered = ["Stone", "Wood"],
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
const _PLANET_THUMB_VERSION: int = 9

func _planet_thumbnail_for(entry: Dictionary) -> ImageTexture:
	# Versioned cache — bump _PLANET_THUMB_VERSION to invalidate older
	# session-cached thumbnails when the renderer changes.
	if int(entry.get("thumb_version", 0)) == _PLANET_THUMB_VERSION \
			and entry.has("thumbnail") and entry.thumbnail != null:
		return entry.thumbnail

	var node = entry.get("node", null)
	var grass_col: Color = Color(0.30, 0.65, 0.30)
	var mount_col: Color = Color(0.55, 0.50, 0.45)
	var water_col: Color = Color(0.10, 0.40, 0.80)
	var sky_col: Color   = Color(0.05, 0.05, 0.08)
	var planet_seed: int = 0
	var has_basin: bool = true
	var archetype: String = ""
	# Track whether the colors we sampled actually came from a fully-initialized
	# PlanetGen palette.  If they're still the GDScript default (Color(0,0,0,1)
	# = pitch black) the live node is in the gap between construction and
	# _ready() — we use defaults instead and skip caching so the next refresh
	# can pick up the real palette.
	var palette_live: bool = false
	# Live-node ring detection — PlanetGen attaches a TorusMesh child when
	# the planet rolled rings, so we can mirror that exactly instead of
	# guessing from the profile.
	var live_has_rings: bool = false
	if node != null and is_instance_valid(node):
		var maybe_grass: Color = node.get("pal_grass_col") if "pal_grass_col" in node else Color(0,0,0,1)
		if maybe_grass.r + maybe_grass.g + maybe_grass.b > 0.03:
			grass_col = maybe_grass
			palette_live = true
			if "pal_mount_col" in node: mount_col = node.get("pal_mount_col")
			if "pal_water_base" in node: water_col = node.get("pal_water_base")
			if "sky_horizon_color" in node: sky_col = node.get("sky_horizon_color")
		if "planet_seed" in node: planet_seed = int(node.get("planet_seed"))
		if "archetype" in node:
			archetype = String(node.get("archetype"))
			# Only truly dry archetypes skip the "basin" (water/lava) pass.
			# VOLCANIC + OBSIDIAN are wet with lava/glass and should show
			# their water_base colour as oceans.
			if archetype in ["DESERT", "RUST", "BARREN", "ASH", "MUDFLAT"]:
				has_basin = false
		for c in node.get_children():
			if c is MeshInstance3D and c.mesh is TorusMesh:
				live_has_rings = true
				break

	# Vivify the sampled palette — the in-game planet reads brighter than the
	# raw albedo because of emission shaders, HDR lighting and bloom; pumping
	# saturation and value here brings the icon closer to what the player
	# actually sees on the rendered globe.
	grass_col = _vivify_palette(grass_col, 1.40, 1.15)
	mount_col = _vivify_palette(mount_col, 1.30, 1.10)
	water_col = _vivify_palette(water_col, 1.45, 1.20)

	# Mineral-derived profile gives clouds / rings / biolum / glow even if
	# the live PlanetGen node hasn't been spawned yet (loaded-from-save case).
	var profile: Dictionary = PlanetSeedKitchen.derive_profile(
		String(entry.get("r1", "")),
		String(entry.get("r2", "")),
		String(entry.get("r3", "")),
		int(entry.get("seed_val", 0)))
	var cloud_coverage: float = clampf(0.45 + float(profile.get("cloud_coverage_delta", 0.0)), 0.0, 1.0)
	var cloud_alpha: float = clampf(0.55 + float(profile.get("cloud_alpha_delta", 0.0)), 0.0, 1.0)
	var biolum: float = clampf(float(profile.get("biolum_boost", 0.0)), 0.0, 1.5)
	var glow: float = clampf(float(profile.get("glow_boost", 0.0)), 0.0, 1.5)
	var frozen: bool = archetype in ["FROZEN", "ICE", "ALPINE", "TUNDRA"]
	# Rings: prefer ground truth from the live planet's TorusMesh child.  When
	# the planet isn't rehydrated yet, replay the seeded RNG roll that
	# PlanetGen uses so the icon matches what the player would see if they
	# flew there.  Both branches use the same `0.5 + ring_boost` chance.
	var has_rings: bool = live_has_rings
	if not live_has_rings and node == null:
		var ring_rng := RandomNumberGenerator.new()
		ring_rng.seed = int(entry.get("seed_val", 0))
		var ring_chance: float = clampf(0.5 + float(profile.get("ring_boost", 0.0)), 0.0, 1.0)
		has_rings = ring_rng.randf() < ring_chance

	# Larger canvas + tighter planet radius so the rings have room to extend
	# past the disc without being clipped at the image bounds.
	var size: int = 144
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	# Deterministic seed → same planet always renders the same icon.
	var seed_int: int = planet_seed if planet_seed != 0 else hash(str(entry.r1) + str(entry.r2) + str(entry.r3))

	# Noise layers: continent shape, coastline detail, clouds.
	var noise_continent := FastNoiseLite.new()
	noise_continent.seed = seed_int
	noise_continent.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_continent.frequency = 0.04
	noise_continent.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_continent.fractal_octaves = 4
	noise_continent.fractal_lacunarity = 2.1
	noise_continent.fractal_gain = 0.55

	var noise_detail := FastNoiseLite.new()
	noise_detail.seed = seed_int + 7919
	noise_detail.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_detail.frequency = 0.11
	noise_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_detail.fractal_octaves = 3
	noise_detail.fractal_lacunarity = 2.0
	noise_detail.fractal_gain = 0.5

	var noise_cloud := FastNoiseLite.new()
	noise_cloud.seed = seed_int + 13337
	noise_cloud.noise_type = FastNoiseLite.TYPE_PERLIN
	noise_cloud.frequency = 0.06
	noise_cloud.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise_cloud.fractal_octaves = 3

	var cx: float = float(size) * 0.5
	var cy: float = float(size) * 0.5
	# Planet radius — sized so the widest ring band (1.55x) still fits inside
	# the image with a few pixels of breathing room (max image radius = 72px
	# on a 144 canvas → planet r 43px puts the outer ring at ~67px).
	var r: float = float(size) * 0.30

	# ── Percentile-based thresholds (computed below from a noise pre-pass) ──
	# Plain Perlin output for a tiny 144px window can be heavily biased
	# (one seed = 95% water, another = 95% land).  We sample every disc
	# pixel up-front, sort the values, then pick land/mountain cutoffs at
	# fixed percentiles so the basin/land/mountain ratio is always the same
	# regardless of the seed's particular noise bias.
	#
	# Target ratios:
	#   Wet world  (has_basin = true):  ~50% basin · ~38% land · ~12% mountain
	#   Dry world  (has_basin = false):  0% basin · ~85% land · ~15% mountain
	var land_threshold: float = 0.0
	var mountain_threshold: float = 0.0
	# Stash per-pixel noise values during the pre-pass so we don't recompute
	# them during the render pass.  Indexed by y * size + x.
	var n_lookup: PackedFloat32Array = PackedFloat32Array()
	n_lookup.resize(size * size)
	var disc_values: Array[float] = []
	for py in range(size):
		for px in range(size):
			var dxp: float = float(px) + 0.5 - cx
			var dyp: float = float(py) + 0.5 - cy
			var dp: float = sqrt(dxp * dxp + dyp * dyp)
			if dp > r:
				continue
			var np: float = noise_continent.get_noise_2d(float(px), float(py)) \
				+ noise_detail.get_noise_2d(float(px), float(py)) * 0.35
			var rim_tp: float = clampf(dp / r, 0.0, 1.0)
			np -= pow(rim_tp, 3.0) * 0.22
			n_lookup[py * size + px] = np
			disc_values.append(np)
	disc_values.sort()
	var dv_count: int = disc_values.size()
	if dv_count > 0:
		if has_basin:
			land_threshold = disc_values[mini(int(dv_count * 0.50), dv_count - 1)]
			mountain_threshold = disc_values[mini(int(dv_count * 0.88), dv_count - 1)]
		else:
			# No basin on dry worlds — push the threshold below the min so
			# the basin branch never fires.
			land_threshold = disc_values[0] - 1.0
			mountain_threshold = disc_values[mini(int(dv_count * 0.85), dv_count - 1)]

	# ── Background half of ring system (drawn before the planet body) ──
	# Multi-band ring with a Cassini-style gap so it reads as detailed rather
	# than a flat sash.  Each band has its own radius range, alpha, and tint
	# bias.  Front arcs are composited again after the planet pass.
	var ring_tint: Color = sky_col.lerp(Color(1.0, 0.93, 0.78), 0.55)
	var ring_bands: Array = [
		# {inner_mult, outer_mult, alpha, tint_lerp_white}
		{"inner": 1.08, "outer": 1.22, "alpha": 0.80, "shade": 0.10},  # bright main inner
		{"inner": 1.24, "outer": 1.30, "alpha": 0.55, "shade": 0.32},  # narrow secondary
		# 1.30 – 1.36  Cassini-style gap (no band drawn)
		{"inner": 1.36, "outer": 1.48, "alpha": 0.78, "shade": 0.05},  # main outer
		{"inner": 1.50, "outer": 1.55, "alpha": 0.38, "shade": 0.48},  # faint outer dust
	]
	if has_rings:
		for band in ring_bands:
			_draw_planet_ring(img, cx, cy, r,
				r * float(band["inner"]), r * float(band["outer"]),
				ring_tint.lerp(Color.WHITE, float(band["shade"])),
				float(band["alpha"]), true)

	# ── Planet body: terrain + clouds + polar caps + biolum ───────────
	for y in range(size):
		for x in range(size):
			var dx: float = float(x) + 0.5 - cx
			var dy: float = float(y) + 0.5 - cy
			var d: float = sqrt(dx * dx + dy * dy)
			if d > r:
				continue

			# Reuse the noise value sampled during the percentile pre-pass.
			var n: float = n_lookup[y * size + x]
			var rim_t: float = clampf(d / r, 0.0, 1.0)

			var base: Color
			var is_land: bool = true
			if has_basin and n < land_threshold:
				base = water_col
				is_land = false
			elif n > mountain_threshold:
				base = mount_col
			else:
				base = grass_col

			# Polar caps on cold worlds — fade in toward the top/bottom rows.
			# Latitude approximated by dy / r (-1 = top, +1 = bottom).
			if frozen and is_land:
				var lat: float = abs(dy) / r
				var cap_t: float = smoothstep(0.55, 0.95, lat)
				if cap_t > 0.01:
					base = base.lerp(Color(0.92, 0.95, 1.0), cap_t)

			# Bioluminescent dots — sparse glow spots on land driven by noise
			# threshold so the same planet always shows the same pattern.
			if is_land and biolum > 0.3:
				var bl: float = noise_detail.get_noise_2d(float(x) * 3.1, float(y) * 3.1)
				if bl > 0.55 - (biolum - 0.3) * 0.25:
					var glow_col: Color = Color(0.4, 1.0, 0.85)
					base = base.lerp(glow_col, 0.55)

			# West-darker / east-lighter shading sells the lit-globe look —
			# kept gentle (min 0.92×) so the planet's vivid palette doesn't get
			# muted into a dull wash.  Same gentleness on rim atmospheric
			# falloff (was 10% darkening at the limb; now 5%).
			var shade: float = 0.92 + (dx / r) * 0.12
			shade *= 1.0 - rim_t * 0.05

			base.r = clampf(base.r * shade, 0.0, 1.0)
			base.g = clampf(base.g * shade, 0.0, 1.0)
			base.b = clampf(base.b * shade, 0.0, 1.0)

			# Cloud layer — semi-opaque white where cloud noise exceeds
			# threshold modulated by coverage; lighter alpha so the planet's
			# base colour reads clearly under the clouds.
			if cloud_coverage > 0.1:
				var cl: float = noise_cloud.get_noise_2d(float(x), float(y) * 1.4)
				var cl_t: float = clampf((cl - (0.55 - cloud_coverage)) / 0.35, 0.0, 1.0)
				if cl_t > 0.02:
					var cloud_col: Color = Color(1, 1, 1)
					base = base.lerp(cloud_col, cl_t * cloud_alpha * 0.5)

			base.a = 1.0
			img.set_pixel(x, y, base)

	# ── Front half of rings (overlays the planet body for in-front arc) ─
	if has_rings:
		for band in ring_bands:
			_draw_planet_ring(img, cx, cy, r,
				r * float(band["inner"]), r * float(band["outer"]),
				ring_tint.lerp(Color.WHITE, float(band["shade"])),
				float(band["alpha"]), false)

	# ── Atmospheric halo (2-pixel soft gradient) + emissive glow ─────
	var halo: Color = sky_col.lerp(Color.WHITE, 0.35)
	for halo_t in range(3):
		var rad: float = r + 0.5 + float(halo_t)
		var alpha: float = 0.60 - float(halo_t) * 0.18
		alpha = clampf(alpha + glow * 0.20, 0.0, 0.85)
		halo.a = alpha
		var steps: int = max(96, int(rad * 6.0))
		for ang_i in range(steps):
			var ang: float = float(ang_i) / float(steps) * TAU
			var hx: int = int(round(cx + cos(ang) * rad))
			var hy: int = int(round(cy + sin(ang) * rad))
			if hx >= 0 and hx < size and hy >= 0 and hy < size:
				var existing: Color = img.get_pixel(hx, hy)
				if existing.a < halo.a:
					img.set_pixel(hx, hy, halo)

	var tex := ImageTexture.create_from_image(img)
	# Only cache once we've actually got the live planet's palette; otherwise
	# the next refresh re-renders with the real colours instead of fallbacks.
	if palette_live:
		entry["thumbnail"] = tex
		entry["thumb_version"] = _PLANET_THUMB_VERSION
	return tex


# Paints a tilted ring around the planet.  `behind = true` draws the back
# arc (top half — hidden by the planet body) and `behind = false` draws the
# front arc (bottom half — visible across the planet body).  Call once
# before the planet pass for the back arc and once after for the front
# arc so the ring weaves through the disc.
func _draw_planet_ring(img: Image, cx: float, cy: float, planet_r: float,
		inner: float, outer: float, tint: Color, max_alpha: float, behind: bool) -> void:
	var size: int = img.get_width()
	# Slight vertical squish so the ring reads as elliptical (viewed at a tilt).
	var ring_y_scale: float = 0.30
	var ring_y_offset: float = -planet_r * 0.05
	for y in range(size):
		for x in range(size):
			var dx: float = float(x) + 0.5 - cx
			var dy: float = (float(y) + 0.5 - (cy + ring_y_offset)) / ring_y_scale
			var d: float = sqrt(dx * dx + dy * dy)
			if d < inner or d > outer:
				continue
			var dy_real: float = float(y) + 0.5 - cy
			var d_real: float = sqrt(dx * dx + dy_real * dy_real)
			var inside_disc: bool = d_real < planet_r
			# Back pass hides whatever's inside the planet body — that arc
			# is occluded by the globe.  Front pass keeps drawing over the
			# body so the ring's front sweep is visible across it.
			if behind and inside_disc:
				continue
			# Front/back split: pixels below the planet center are 'in front'.
			var is_front_half: bool = (float(y) + 0.5) > cy
			if behind and is_front_half: continue
			if (not behind) and (not is_front_half): continue
			# Soft fall-off at inner/outer edge.
			var t: float = (d - inner) / max(outer - inner, 0.001)
			var edge_a: float = smoothstep(0.0, 0.15, t) * (1.0 - smoothstep(0.85, 1.0, t))
			var alpha: float = max_alpha * edge_a
			if alpha < 0.04: continue
			# Manual alpha blend — Image.set_pixel doesn't composite, so we
			# read the existing pixel (planet body, halo, or transparent bg)
			# and lerp toward the ring tint by `alpha`.  Preserves the
			# underlying opaqueness so we don't punch transparent holes in
			# the disc when drawing the front arc across it.
			var existing: Color = img.get_pixel(x, y)
			var blended: Color
			if existing.a > 0.01:
				blended = existing.lerp(tint, alpha)
				blended.a = max(existing.a, alpha)
			else:
				blended = tint
				blended.a = alpha
			img.set_pixel(x, y, blended)

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
	# One-shot diagnostic — confirms green/etc. are in the spawn pool. Remove
	# once the rarity rework is bedded in.
	print("--- FORGE: Planet [%s] rank=%s resources=%s ---" % [custom_name, rank_label, str(planet_res)])
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
	var pip_color: Color = _tier_color(int(ceilf(float(maxi(lvl, 1)) / float(maxi(max_lvl, 1)) * 5.0)))
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

		var btn := _TapButton.new()
		btn.slop_sq = pow(_TAP_SLOP_MOBILE if _is_mobile_ui else _TAP_SLOP_DESKTOP, 2)
		btn.text = "UPGRADE"
		HUDStyle.style_button(btn, HUDStyle.BTN_GREEN, 22 if _is_mobile_ui else 18)
		btn.disabled = not affordable
		btn.custom_minimum_size = Vector2(0, _UPGRADE_BTN_H_MOBILE if _is_mobile_ui else 38)
		var captured_track: String = track
		btn.tapped.connect(func() -> void: _on_upgrade_purchase_pressed(captured_track))
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
	if _active_tab == 1:
		_rebuild_all_upgrade_rows()
	_refresh_upgrade_stat_cells()

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
		var discovered: Array = entry.get("discovered", ["Stone", "Wood"])
		out.append({
			"r1":             String(entry.get("r1", "")),
			"r2":             String(entry.get("r2", "")),
			"r3":             String(entry.get("r3", "")),
			"luck_variance":  float(entry.get("luck_variance", 0.0)),
			"seed_val":       int(entry.get("seed_val", 0)),
			"name":           String(entry.get("name", "")),
			"pos":            {"x": pos.x, "y": pos.y, "z": pos.z},
			"discovered":     discovered.duplicate(),
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
		var disc_raw: Array = raw.get("discovered", ["Stone", "Wood"])
		var discovered: Array = []
		for d in disc_raw:
			discovered.append(String(d))
		_active_planets.append({
			node = null,
			r1 = String(raw.get("r1", "")),
			r2 = String(raw.get("r2", "")),
			r3 = String(raw.get("r3", "")),
			luck_variance = float(raw.get("luck_variance", 0.0)),
			seed_val = int(raw.get("seed_val", 0)),
			name = String(raw.get("name", "")),
			pos = pos,
			discovered = discovered,
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


# ─── Captain header (top of station UI) ──────────────────────────────────
# Avatar + name on the left, an 8-cell stat grid on the right.  Stats:
# CREDITS / PLANETS / KILLS / TIME and the four upgrade levels the player
# cares about (ATTACK / HULL / WARP / LUCK).  Refresh paths:
#   - CREDITS: existing currency_changed signal handler updates _creds_label.
#   - Upgrades: signal-driven via _refresh_stat_grid() on upgrade_changed.
#   - PLANETS / KILLS / TIME: refreshed each _show_ui() call (cheap, no tick).

func _build_captain_header(parent: VBoxContainer) -> void:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(header)

	# ── Left: avatar + name ─────────────────────────────────────────────
	var left := VBoxContainer.new()
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 4)
	left.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	header.add_child(left)

	_captain_avatar = TextureRect.new()
	_captain_avatar.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_captain_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var avatar_size: int = 88 if _is_mobile_ui else 72
	_captain_avatar.custom_minimum_size = Vector2(avatar_size, avatar_size)
	_captain_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(_captain_avatar)

	_captain_name_lbl = Label.new()
	_captain_name_lbl.text = "CAPT."
	_captain_name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_captain_name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	HUDStyle.style_label(_captain_name_lbl, HUDStyle.HUD_FONT_MED, HUDStyle.CRT_GREEN_BG)
	left.add_child(_captain_name_lbl)

	# ── Right: 2-column stat grid ──────────────────────────────────────
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 4)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(grid)

	_creds_label = _add_stat_cell(grid, "credits", "CREDITS", "$0", Color.GOLD)
	_add_stat_cell(grid, "planets", "PLANETS", "0")
	_add_stat_cell(grid, "kills", "KILLS", "0")
	_add_stat_cell(grid, "time", "TIME", "0:00")
	_add_stat_cell(grid, "attack", "ATTACK", "Lv 0")
	_add_stat_cell(grid, "hull", "HULL", "Lv 0")
	_add_stat_cell(grid, "warp", "WARP", "Lv 0")
	_add_stat_cell(grid, "luck", "LUCK", "Lv 0")


func _add_stat_cell(grid: GridContainer, key: String, label_text: String, default_value: String, value_color: Color = HUDStyle.CRT_GREEN_BG) -> Label:
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", 6)
	grid.add_child(cell)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	HUDStyle.style_label(lbl, HUDStyle.HUD_FONT_SMALL, Color(0.55, 0.6, 0.75))
	cell.add_child(lbl)

	var value := Label.new()
	value.text = default_value
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	HUDStyle.style_label(value, HUDStyle.HUD_FONT_MED, value_color)
	cell.add_child(value)

	_stat_labels[key] = value
	return value


func _refresh_captain_header() -> void:
	# Pull identity + counters from the live managers; tolerate any missing
	# (e.g. station UI built before save load completes).
	var p_name: String = "CAPTAIN"
	var character: String = "axolotl"
	if Engine.has_meta("SaveManager"):
		var sm = Engine.get_meta("SaveManager")
		if String(sm.player_name).strip_edges() != "":
			p_name = String(sm.player_name)
		character = String(sm.player_character)
	if is_instance_valid(_captain_name_lbl):
		_captain_name_lbl.text = "CAPT. " + p_name.to_upper()
	if is_instance_valid(_captain_avatar):
		var portrait_path: String = "res://assets/images/portraits/%s/%s_default.png" % [character, character]
		if ResourceLoader.exists(portrait_path):
			_captain_avatar.texture = load(portrait_path) as Texture2D

	if _stat_labels.has("planets"):
		_stat_labels["planets"].text = str(_active_planets.size())

	if Engine.has_meta("StatsTracker"):
		var st = Engine.get_meta("StatsTracker")
		if _stat_labels.has("kills"):
			_stat_labels["kills"].text = str(st.enemy_kills)
		if _stat_labels.has("time"):
			_stat_labels["time"].text = st.format_playtime()

	_refresh_upgrade_stat_cells()


func _refresh_upgrade_stat_cells() -> void:
	if not Engine.has_meta("UpgradeManager"): return
	var up = Engine.get_meta("UpgradeManager")
	# Map our display keys to UpgradeManager track keys.
	var mapping: Dictionary = {
		"attack": "attack",
		"hull":   "health",
		"warp":   "movement",
		"luck":   "luck",
	}
	for display_key in mapping.keys():
		var track: String = mapping[display_key]
		if _stat_labels.has(display_key):
			_stat_labels[display_key].text = "Lv " + str(up.get_level(track))

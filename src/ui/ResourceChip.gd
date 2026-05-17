extends PanelContainer

# ResourceChip.gd
# Pill-style chip rendering one inventory cell.  Left half is a solid-colour
# circle in the resource's tier colour (rarity cue) containing the resource's
# two-letter abbreviation; right half shows the count over a transparent tint
# in the resource's own colour.  Text colour is auto-chosen against the
# effective background for legibility on any resource hue.
#
# Animations on inventory_changed:
#   delta > 0: scale pulse + circle flash + "+N" floater
#   delta > 0 and tier >= 4: extra glow-burst behind the chip (Purple+)
#   delta == 0 or < 0: silent count update
#   first appearance (count was 0, now > 0): fade-in + scale-from-0.7

const HUDStyle = preload("res://src/ui/HUDStyle.gd")
const ResourceRegistry = preload("res://src/core/ResourceRegistry.gd")

const CIRCLE_DIAM: float = 24.0
const PILL_HEIGHT: float = 28.0
const PILL_PAD_LEFT: float = 3.0
const PILL_PAD_RIGHT: float = 8.0
const FLOATER_COALESCE_S: float = 0.10

var resource_name: String = ""
var tier: int = 1
var res_color: Color = Color.WHITE
var abbrev: String = ""

var _displayed_count: int = 0
var _circle: Control = null
var _count_label: Label = null
var _pending_delta: int = 0
var _pending_floater_timer: float = 0.0
var _scale_tween: Tween = null
var _flash_tween: Tween = null
var _entrance_tween: Tween = null
var _flash_t: float = 0.0
var _is_first_show: bool = true
# Throttle marker — last time (msec) we kicked off a scale-pulse animation.
# Bulk loot collection fires inventory_changed 10-20× per second; restarting
# the Tween that often makes the chip "stutter-pulse" and pegs the main
# thread.  PULSE_THROTTLE_MS is the minimum gap between pulse restarts.
const PULSE_THROTTLE_MS: int = 160
var _last_pulse_ms: int = -10000

func setup(res_name: String) -> void:
	resource_name = res_name
	var data: Dictionary = ResourceRegistry.get_data(res_name)
	tier = int(data.get("tier", 1))
	res_color = data.get("color", Color.WHITE)
	abbrev = String(data.get("abbrev", "??"))

	custom_minimum_size = Vector2(0, PILL_HEIGHT)

	# Beveled chip — chunky raised panel in a darkened tier colour so each
	# resource reads as a tiny pixel button.  The tier circle on the left
	# keeps its full vivid tier hue, so rarity is still legible at a glance.
	# Tight content margins keep the 28px-tall pill shape — the standard
	# bevel_panel factory uses larger margins meant for full-size buttons.
	var tier_col: Color = HUDStyle.tier_color(tier)
	var body_bg: Color = tier_col.darkened(0.55)
	body_bg.a = 0.95
	var sb := HUDStyle.bevel_panel(body_bg)
	sb.content_margin_left = PILL_PAD_LEFT
	sb.content_margin_right = PILL_PAD_RIGHT
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	add_theme_stylebox_override("panel", sb)

	# Internal layout: [circle] [count]
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 6)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hbox)

	# Left: solid-colour circle with the two-letter abbreviation inside.
	_circle = Control.new()
	_circle.custom_minimum_size = Vector2(CIRCLE_DIAM, CIRCLE_DIAM)
	_circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_circle.draw.connect(_draw_circle)
	hbox.add_child(_circle)

	# Right: count.  Pixel font with a tier-tinted ink so the count visually
	# anchors to the chip's rarity bucket.
	_count_label = Label.new()
	_count_label.add_theme_font_override("font", HUDStyle.PIXEL_FONT)
	_count_label.add_theme_font_size_override("font_size", HUDStyle.HUD_FONT_SMALL)
	_count_label.add_theme_color_override("font_color", _tier_text_color(tier_col, body_bg))
	_count_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_count_label.add_theme_constant_override("outline_size", 0)
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(_count_label)

	pivot_offset = size * 0.5
	resized.connect(func(): pivot_offset = size * 0.5)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_render_count(0)

func _draw_circle() -> void:
	if _circle == null:
		return
	var center: Vector2 = _circle.size * 0.5
	var radius: float = CIRCLE_DIAM * 0.5
	# Tier colour ring, flashing toward white when an add happens.
	var ring_col: Color = HUDStyle.tier_color(tier).lerp(Color.WHITE, _flash_t)
	_circle.draw_circle(center, radius, ring_col)
	# Subtle inner shading so the circle reads as a 3D badge, not a flat dot.
	_circle.draw_circle(center, radius - 1.5, ring_col.darkened(0.05))

	# Two-letter abbreviation centred in the circle — pixel font keeps the
	# chip on-brand with the rest of the chrome.
	var font: Font = HUDStyle.PIXEL_FONT
	var fs: int = HUDStyle.HUD_FONT_TINY
	var text_col: Color = _readable_text_color(ring_col)
	var text_size: Vector2 = font.get_string_size(abbrev, HORIZONTAL_ALIGNMENT_CENTER, -1, fs)
	var text_pos: Vector2 = Vector2(center.x - text_size.x * 0.5, center.y + fs * 0.34)
	_circle.draw_string(font, text_pos, abbrev, HORIZONTAL_ALIGNMENT_CENTER, -1, fs, text_col)

func set_count(new_amount: int) -> void:
	var delta: int = new_amount - _displayed_count
	_render_count(new_amount)

	if _is_first_show and new_amount > 0:
		_is_first_show = false
		_play_entrance()
		if delta > 0:
			_play_pulse()
			_play_flash()
			_queue_floater(delta)
			if tier >= 4:
				_play_glow_burst()
		return

	if delta > 0:
		_play_pulse()
		_play_flash()
		_queue_floater(delta)
		if tier >= 4:
			_play_glow_burst()

func _render_count(n: int) -> void:
	_displayed_count = n
	if _count_label != null:
		_count_label.text = str(n)

# ── Accessibility helpers ─────────────────────────────────────────────────────

# WCAG relative luminance (sRGB).
static func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

# Pick a foreground text colour that reads against the given OPAQUE bg.
# Used for the abbreviation letter inside the solid tier circle.
func _readable_text_color(bg: Color) -> Color:
	return Color.BLACK if _luminance(bg) > 0.62 else Color.WHITE

# Pick a count-label colour: start from the tier hue lightened (so the
# count visually anchors to the chip's tier palette) and fall back to
# pure white if it lacks contrast against the effective pill background.
# `pill_bg` is alpha-blended over the dark game canvas, same as on screen.
func _tier_text_color(tier_col: Color, pill_bg: Color) -> Color:
	const CANVAS_LUM: float = 0.08
	var effective_lum: float = pill_bg.a * _luminance(pill_bg) + (1.0 - pill_bg.a) * CANVAS_LUM
	var candidate: Color = tier_col.lerp(Color.WHITE, 0.30)
	if _luminance(candidate) - effective_lum < 0.45:
		return Color.WHITE
	return candidate

# ── Animations ────────────────────────────────────────────────────────────────

func _play_entrance() -> void:
	if _entrance_tween and _entrance_tween.is_valid():
		_entrance_tween.kill()
	modulate.a = 0.0
	scale = Vector2(0.7, 0.7)
	_entrance_tween = create_tween().set_parallel(true)
	_entrance_tween.tween_property(self, "modulate:a", 1.0, 0.22)
	_entrance_tween.tween_property(self, "scale", Vector2.ONE, 0.22) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _play_pulse() -> void:
	# Bulk loot bursts (10-20 shards collected in <1s) used to restart the
	# Tween on every shard, pegging the main thread and producing a juddery
	# "stutter pulse".  Throttle: don't restart if one is already in flight
	# inside PULSE_THROTTLE_MS — the in-flight pulse covers the whole burst.
	var now: int = Time.get_ticks_msec()
	if now - _last_pulse_ms < PULSE_THROTTLE_MS:
		return
	_last_pulse_ms = now
	if _scale_tween and _scale_tween.is_valid():
		_scale_tween.kill()
	scale = Vector2.ONE
	_scale_tween = create_tween()
	_scale_tween.tween_property(self, "scale", Vector2(1.15, 1.15), 0.08) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_scale_tween.tween_property(self, "scale", Vector2.ONE, 0.12) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _play_flash() -> void:
	# Same burst-collection throttle as _play_pulse — a single in-flight
	# flash covers any rapid follow-up adds within the throttle window.
	if _flash_tween and _flash_tween.is_valid():
		return
	_flash_t = 1.0
	if _circle != null:
		_circle.queue_redraw()
	_flash_tween = create_tween()
	_flash_tween.tween_method(_set_flash_t, 1.0, 0.0, 0.22) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _set_flash_t(t: float) -> void:
	_flash_t = t
	if _circle != null:
		_circle.queue_redraw()

func _queue_floater(delta: int) -> void:
	_pending_delta += delta
	if _pending_floater_timer > 0.0:
		return
	_pending_floater_timer = FLOATER_COALESCE_S
	get_tree().create_timer(FLOATER_COALESCE_S).timeout.connect(_emit_floater)

func _emit_floater() -> void:
	var total: int = _pending_delta
	_pending_delta = 0
	_pending_floater_timer = 0.0
	if total <= 0:
		return
	var floater := Label.new()
	floater.text = "+%d" % total
	floater.add_theme_font_size_override("font_size", HUDStyle.HUD_FONT_MED)
	floater.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 1.0))
	floater.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.85))
	floater.add_theme_constant_override("outline_size", 4)
	floater.mouse_filter = Control.MOUSE_FILTER_IGNORE
	floater.top_level = true
	floater.position = global_position + Vector2(size.x * 0.5 - 14, -4)
	add_child(floater)
	var t := create_tween().set_parallel(true)
	t.tween_property(floater, "position:y", floater.position.y - 24.0, 0.50) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(floater, "modulate:a", 0.0, 0.50)
	t.chain().tween_callback(floater.queue_free)

var _last_burst_ms: int = -10000

func _play_glow_burst() -> void:
	# Tier-4+ bonus — a soft duplicate panel scales 1.0 → 1.7 and fades
	# behind the chip.  top_level so it doesn't reflow the FlowContainer.
	# Throttled the same way as the pulse: rapid mining of an Aether
	# deposit shouldn't spawn 15 duplicate panels in 0.5s.
	var now: int = Time.get_ticks_msec()
	if now - _last_burst_ms < 250:
		return
	_last_burst_ms = now
	var burst := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(res_color.r, res_color.g, res_color.b, 0.45)
	sb.set_corner_radius_all(int(PILL_HEIGHT * 0.5))
	burst.add_theme_stylebox_override("panel", sb)
	burst.modulate = Color(1.0, 1.0, 1.0, 0.55)
	burst.mouse_filter = Control.MOUSE_FILTER_IGNORE
	burst.top_level = true
	burst.size = size
	burst.position = global_position
	burst.pivot_offset = size * 0.5
	add_child(burst)
	var t := create_tween().set_parallel(true)
	t.tween_property(burst, "scale", Vector2(1.7, 1.7), 0.40) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(burst, "modulate:a", 0.0, 0.40)
	t.chain().tween_callback(burst.queue_free)

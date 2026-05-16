extends RefCounted

# HUDStyle.gd
# Shared style kit for the in-game UI.  Three jobs:
#   1. Tier palette + chip layout constants used by Main.gd, ResourceChip,
#      ScreenPOIHUD, etc. so loot rarity reads the same everywhere.
#   2. Beveled stylebox factories (raised / pressed / hover) — chunky 80s-arcade
#      depth via 2-tone highlight + drop shadow, matching the EASY / MEDIUM /
#      HARD reference.  Two ways in: PixelButton subclass for `Button` nodes,
#      or `draw_beveled_rect()` for code that draws its own rects (mobile).
#   3. apply_default_theme() — installs the pixel font + default styleboxes on
#      the root viewport so any Button/Panel/Label that doesn't customise gets
#      the look for free.
#
# Combat HUD (reticle, locks, health bar, threat arrows) is intentionally NOT
# routed through this kit — those need to stay thin and readable mid-fight.

const PIXEL_FONT: FontFile = preload("res://assets/fonts/PressStart2P-Regular.ttf")

# ── Font sizes ────────────────────────────────────────────────────────────────
# Pixel font is fat, so we use slightly smaller sizes than the prior fallback
# font and rely on the bitmap weight to carry the impact.
const HUD_FONT_TINY:  int = 8
const HUD_FONT_SMALL: int = 10
const HUD_FONT_MED:   int = 14
const HUD_FONT_LRG:   int = 18
const HUD_FONT_XL:    int = 28
const HUD_FONT_TITLE: int = 40

# ── Tier colours (resource rarity) ────────────────────────────────────────────
# Synced with SpaceStation._tier_color so the in-game HUD chips read as
# miniatures of the forge-menu resource cards — same palette, same rarity
# bucket per tier.  Any change here should be mirrored there.
const TIER_COLOR_1: Color = Color(0.75, 0.75, 0.75)  # T1 common — grey
const TIER_COLOR_2: Color = Color(0.35, 0.85, 1.00)  # T2 uncommon — cyan
const TIER_COLOR_3: Color = Color(0.60, 0.30, 1.00)  # T3 rare — purple
const TIER_COLOR_4: Color = Color(1.00, 0.55, 0.05)  # T4 legendary — orange-gold

# ── Arcade-chrome palette (NEW — for menus / dialogs / chrome) ────────────────
# Borrowed from the Designercize reference but kept distinct from tier palette.
const BG_DEEP_PURPLE:  Color = Color(0.32, 0.20, 0.92)  # menu canvas
const BG_DEEP_NAVY:    Color = Color(0.06, 0.07, 0.12)  # outer frame
const PANEL_BEVEL:     Color = Color(0.18, 0.20, 0.42)  # neutral beveled panel
const CRT_GREEN_BG:      Color = Color(0.61, 0.95, 0.62)  # bright CRT data screen
const CRT_GREEN_BG_DARK: Color = Color(0.06, 0.22, 0.12)  # authentic dark phosphor backdrop
const CRT_GREEN_INK:     Color = Color(0.06, 0.20, 0.10)  # text drawn on CRT screens
const CRT_GREEN_INK_LIT: Color = Color(0.45, 0.95, 0.55)  # bright phosphor lines on dark CRT
const CRT_GREEN_BORDER:  Color = Color(0.18, 0.55, 0.22)  # CRT inner frame
const BTN_BLUE:        Color = Color(0.20, 0.45, 1.00)
const BTN_GREEN:       Color = Color(0.25, 0.78, 0.40)
const BTN_YELLOW:      Color = Color(0.98, 0.78, 0.18)
const BTN_RED:         Color = Color(0.92, 0.32, 0.28)
const BTN_PINK:        Color = Color(0.95, 0.40, 0.78)

# ── Chip layout ───────────────────────────────────────────────────────────────
const CHIP_PADDING_X: int = 6
const CHIP_PADDING_Y: int = 2
const CHIP_STRIPE_H:  int = 2  # height of the top tier-stripe in pixels
const CHIP_GAP:       int = 4

# ── HUD margins ───────────────────────────────────────────────────────────────
const CREDITS_OFFSET: Vector2 = Vector2(-24, 12)  # from TOP_RIGHT anchor
const INVENTORY_OFFSET: Vector2 = Vector2(24, 56) # from TOP_LEFT anchor (clear of health bar)
const HP_MARGIN_Y: float = 24.0                   # was 96 in Player.gd

# ── Bevel geometry ────────────────────────────────────────────────────────────
const BEVEL_WIDTH: int = 2  # pixel thickness of highlight + shadow strips

# ── Static helpers ────────────────────────────────────────────────────────────

static func tier_color(tier: int) -> Color:
	match tier:
		1: return TIER_COLOR_1
		2: return TIER_COLOR_2
		3: return TIER_COLOR_3
		4: return TIER_COLOR_4
		_: return TIER_COLOR_1

# Flat, sharp-cornered panel with optional pixel border.  Used by chips and
# any other HUD element that wants the retro panel look.
static func make_pixel_panel(bg: Color, border: Color = Color.TRANSPARENT, border_w: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(0)
	sb.anti_aliasing = false
	if border.a > 0.0 and border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border
	sb.content_margin_left = CHIP_PADDING_X
	sb.content_margin_right = CHIP_PADDING_X
	sb.content_margin_top = CHIP_PADDING_Y + CHIP_STRIPE_H
	sb.content_margin_bottom = CHIP_PADDING_Y
	return sb

# Resource chip background.  Beveled in the resource's tier colour so each
# chip reads as a chunky pixel button — depth from the highlight + drop
# shadow, with the tier hue carrying rarity at a glance.
static func make_resource_chip_panel(_res_color: Color, tier: int) -> StyleBoxFlat:
	var base: Color = tier_color(tier).darkened(0.55)
	base.a = 0.95
	return bevel_panel(base)

# Recursively force nearest-neighbour filtering on a node tree.  Use it on
# any TextureRect that displays pixel-art so it stays crisp at scale.
static func apply_nearest_filter(node: CanvasItem) -> void:
	if node == null:
		return
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for child in node.get_children():
		if child is CanvasItem:
			apply_nearest_filter(child)


# ─────────────────────────────────────────────────────────────────────────────
# BEVEL FACTORIES
# ─────────────────────────────────────────────────────────────────────────────
# Each interactive element gets up to four styleboxes — normal (raised),
# hover (raised + brightened), pressed (recessed), disabled (greyed).  Pressed
# inverts highlight + shadow so the element visibly sinks into the surface,
# and shifts content 2px down-right so the label looks pushed in.  Identical
# behaviour for `Button` (via styleboxes) and for code that draws its own
# rects (via draw_beveled_rect).

# Raised bevel — for buttons in their normal/hover state, and for panels.
static func bevel_stylebox(base: Color, pressed: bool = false, hovered: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(0)
	sb.anti_aliasing = false
	if pressed:
		# Recessed: noticeably darker fill, dark "inset" border around the
		# top/left edges (the rim of the depression casts shadow downward),
		# plus a thin highlight on bottom/right where light reaches the
		# inside-back wall.  Content nudged down-right so the label/icon
		# visibly pushes into the surface, matching the EASY-style selected
		# look from the reference.
		sb.bg_color = base.darkened(0.32)
		sb.border_width_top = BEVEL_WIDTH
		sb.border_width_left = BEVEL_WIDTH
		sb.border_width_bottom = 0
		sb.border_width_right = 0
		sb.border_color = base.darkened(0.60)
		sb.shadow_size = 0
		sb.content_margin_left = 12
		sb.content_margin_top = 10
		sb.content_margin_right = 10
		sb.content_margin_bottom = 8
	else:
		# Raised: highlight on top/left (light from above-left), drop shadow
		# on bottom/right via shadow_size + shadow_offset.
		var fill: Color = base.lightened(0.08) if hovered else base
		sb.bg_color = fill
		sb.border_width_top = BEVEL_WIDTH
		sb.border_width_left = BEVEL_WIDTH
		sb.border_width_bottom = 0
		sb.border_width_right = 0
		sb.border_color = base.lightened(0.40)
		sb.shadow_color = Color(0.0, 0.0, 0.0, 0.55)
		sb.shadow_size = BEVEL_WIDTH
		sb.shadow_offset = Vector2(BEVEL_WIDTH, BEVEL_WIDTH)
		sb.content_margin_left = 10
		sb.content_margin_top = 8
		sb.content_margin_right = 12
		sb.content_margin_bottom = 10
	return sb

# Disabled: flat, no highlight, no shadow, low contrast.
static func bevel_stylebox_disabled(base: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(0)
	sb.anti_aliasing = false
	sb.bg_color = base.darkened(0.55)
	sb.set_border_width_all(1)
	sb.border_color = base.darkened(0.70)
	sb.content_margin_left = 11
	sb.content_margin_top = 9
	sb.content_margin_right = 11
	sb.content_margin_bottom = 9
	return sb

# Beveled panel (no interaction) — same look as a button at rest.
static func bevel_panel(base: Color) -> StyleBoxFlat:
	return bevel_stylebox(base, false, false)

# CRT-green data screen — for "monitor" surfaces that display readouts.
static func crt_screen_panel() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(0)
	sb.anti_aliasing = false
	sb.bg_color = CRT_GREEN_BG
	sb.set_border_width_all(BEVEL_WIDTH)
	sb.border_color = CRT_GREEN_BORDER
	sb.content_margin_left = 16
	sb.content_margin_top = 14
	sb.content_margin_right = 16
	sb.content_margin_bottom = 14
	return sb

# Apply the four-state bevel to a Button.  Caller supplies the base colour
# (BTN_BLUE / BTN_GREEN / etc.) and a font size — this handles everything
# else: pixel font, white text, dark outline, no focus dotted box (we lean
# on the bevel for focus feedback).
static func style_button(btn: Button, base: Color, font_size: int = HUD_FONT_MED) -> void:
	btn.add_theme_stylebox_override("normal",   bevel_stylebox(base, false, false))
	btn.add_theme_stylebox_override("hover",    bevel_stylebox(base, false, true))
	btn.add_theme_stylebox_override("pressed",  bevel_stylebox(base, true,  false))
	btn.add_theme_stylebox_override("focus",    _focus_outline(base))
	btn.add_theme_stylebox_override("disabled", bevel_stylebox_disabled(base))
	# Toggle-mode buttons (selected = recessed permanently — like EASY)
	btn.add_theme_stylebox_override("hover_pressed", bevel_stylebox(base, true, true))
	# Pixel font + readable white-on-dark text with chunky outline.
	btn.add_theme_font_override("font", PIXEL_FONT)
	btn.add_theme_font_size_override("font_size", font_size)
	var fg: Color = Color.WHITE if base.get_luminance() < 0.55 else Color(0.06, 0.06, 0.10)
	btn.add_theme_color_override("font_color",          fg)
	btn.add_theme_color_override("font_hover_color",    fg)
	btn.add_theme_color_override("font_pressed_color",  fg.lightened(0.15) if fg == Color.WHITE else fg.darkened(0.15))
	btn.add_theme_color_override("font_focus_color",    fg)
	btn.add_theme_color_override("font_disabled_color", fg.darkened(0.4) if fg == Color.WHITE else fg.lightened(0.4))
	btn.add_theme_color_override("font_outline_color",  Color(0, 0, 0, 0.9))
	btn.add_theme_constant_override("outline_size", 0)  # outline disabled — pixel font + flat border read better

# Apply pixel font + outline to a Label.
static func style_label(lbl: Label, font_size: int = HUD_FONT_SMALL, color: Color = Color.WHITE) -> void:
	lbl.add_theme_font_override("font", PIXEL_FONT)
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	lbl.add_theme_constant_override("outline_size", 0)

# Style a LineEdit to match the CRT-green data screens.
static func style_line_edit(le: LineEdit, font_size: int = HUD_FONT_MED) -> void:
	le.add_theme_font_override("font", PIXEL_FONT)
	le.add_theme_font_size_override("font_size", font_size)
	le.add_theme_color_override("font_color",            CRT_GREEN_INK)
	le.add_theme_color_override("font_placeholder_color", CRT_GREEN_BORDER)
	le.add_theme_color_override("caret_color",           CRT_GREEN_INK)
	le.add_theme_color_override("selection_color",       CRT_GREEN_BORDER)
	var box := crt_screen_panel()
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 8
	box.content_margin_bottom = 8
	le.add_theme_stylebox_override("normal",   box)
	le.add_theme_stylebox_override("focus",    box)
	le.add_theme_stylebox_override("read_only", box)

# Inner focus frame — a thin bright inset so a focused button reads clearly
# without breaking the bevel illusion.
static func _focus_outline(base: Color) -> StyleBoxFlat:
	var sb := bevel_stylebox(base, false, true)
	sb.border_width_top = BEVEL_WIDTH
	sb.border_width_left = BEVEL_WIDTH
	sb.border_color = Color.WHITE
	return sb

# ─────────────────────────────────────────────────────────────────────────────
# Manual draw helpers (for code that draws its own rects — mobile controls)
# ─────────────────────────────────────────────────────────────────────────────

# Draw a beveled rectangle into a CanvasItem.  Mirrors bevel_stylebox so
# canvas-drawn buttons (MobileControlsUI) and Button nodes look identical.
#   pressed = false: fill, top+left highlight, bottom+right drop shadow
#   pressed = true:  fill darker, bottom+right highlight, no drop shadow,
#                    fill rect shifted down-right 2px (icon nudge)
static func draw_beveled_rect(ci: CanvasItem, rect: Rect2, base: Color, pressed: bool = false) -> void:
	var w: float = float(BEVEL_WIDTH)
	if pressed:
		# Recessed: darker fill with a dark inset shadow on top/left (the
		# depression rim blocks light from above-left).  No drop shadow.
		var fill: Color = base.darkened(0.32)
		ci.draw_rect(rect, fill, true)
		var sh: Color = base.darkened(0.60)
		ci.draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x, w), sh, true)
		ci.draw_rect(Rect2(rect.position.x, rect.position.y, w, rect.size.y), sh, true)
	else:
		# Drop shadow first, offset down-right.
		var sh: Color = Color(0.0, 0.0, 0.0, 0.55)
		ci.draw_rect(Rect2(rect.position + Vector2(w, w), rect.size), sh, true)
		# Main fill on top.
		ci.draw_rect(rect, base, true)
		# Top/left highlight strip.
		var hi: Color = base.lightened(0.40)
		ci.draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x, w), hi, true)
		ci.draw_rect(Rect2(rect.position.x, rect.position.y, w, rect.size.y), hi, true)

# Draw a CRT-screen backdrop: solid base fill + horizontal scanlines.  Mirrors
# the dark-phosphor look of a CRT monitor — every other row is dimmed by `dim`
# strength, so a base of CRT_GREEN_BG_DARK reads as alternating dark/black
# stripes characteristic of the Designercize reference aesthetic.  `step`
# controls the scanline pitch (2 = every other pixel — the classic look).
static func draw_crt_screen(ci: CanvasItem, rect: Rect2,
		base: Color = CRT_GREEN_BG_DARK,
		step: int = 2, dim: float = 0.55) -> void:
	ci.draw_rect(rect, base, true)
	var stripe: Color = base.darkened(dim)
	var y: float = rect.position.y
	while y < rect.end.y:
		ci.draw_rect(Rect2(rect.position.x, y, rect.size.x, 1), stripe, true)
		y += step

# Draw a bevel-recessed CRT-green screen — for code that wants to draw an
# inset display area into a parent surface (galaxy map bezel, etc.).
static func draw_crt_panel(ci: CanvasItem, rect: Rect2) -> void:
	# Inverted bevel so the screen reads as inset into the surrounding bezel.
	var w: float = float(BEVEL_WIDTH)
	ci.draw_rect(rect, CRT_GREEN_BG, true)
	# Top/left shadow (recessed → light is blocked by the rim above-left).
	ci.draw_rect(Rect2(rect.position.x, rect.position.y, rect.size.x, w), CRT_GREEN_BORDER.darkened(0.4), true)
	ci.draw_rect(Rect2(rect.position.x, rect.position.y, w, rect.size.y), CRT_GREEN_BORDER.darkened(0.4), true)
	# Bottom/right faint highlight where the inset bottom catches light.
	ci.draw_rect(Rect2(rect.position.x, rect.end.y - w, rect.size.x, w), CRT_GREEN_BORDER, true)
	ci.draw_rect(Rect2(rect.end.x - w, rect.position.y, w, rect.size.y), CRT_GREEN_BORDER, true)


# ─────────────────────────────────────────────────────────────────────────────
# Theme installer — call once at boot from Main.gd.
# ─────────────────────────────────────────────────────────────────────────────
# Builds a Theme programmatically and assigns it to the root window so any
# Button/Panel/Label/LineEdit that doesn't override gets the pixel font and
# beveled defaults for free.

static func apply_default_theme(root: Window) -> void:
	if root == null:
		return
	var th := Theme.new()
	th.default_font = PIXEL_FONT
	th.default_font_size = HUD_FONT_MED

	# Default Button — neutral blue bevel.  Most callers re-style with their
	# own colour via style_button(); this is the fallback if they don't.
	th.set_stylebox("normal",   "Button", bevel_stylebox(BTN_BLUE, false, false))
	th.set_stylebox("hover",    "Button", bevel_stylebox(BTN_BLUE, false, true))
	th.set_stylebox("pressed",  "Button", bevel_stylebox(BTN_BLUE, true,  false))
	th.set_stylebox("hover_pressed", "Button", bevel_stylebox(BTN_BLUE, true, true))
	th.set_stylebox("focus",    "Button", _focus_outline(BTN_BLUE))
	th.set_stylebox("disabled", "Button", bevel_stylebox_disabled(BTN_BLUE))
	th.set_color("font_color",          "Button", Color.WHITE)
	th.set_color("font_hover_color",    "Button", Color.WHITE)
	th.set_color("font_pressed_color",  "Button", Color(0.92, 0.92, 1.0))
	th.set_color("font_disabled_color", "Button", Color(0.65, 0.65, 0.70))
	th.set_color("font_outline_color",  "Button", Color(0, 0, 0, 0.9))
	th.set_constant("outline_size", "Button", 0)

	# Default Panel — chunky bevel using the neutral panel colour.
	th.set_stylebox("panel",      "Panel",          bevel_panel(PANEL_BEVEL))
	th.set_stylebox("panel",      "PanelContainer", bevel_panel(PANEL_BEVEL))

	# Default Label — pixel font, no outline (callers add when needed).
	th.set_color("font_color",         "Label", Color.WHITE)
	th.set_color("font_outline_color", "Label", Color(0, 0, 0, 0.85))
	th.set_constant("outline_size",    "Label", 0)

	# LineEdit — CRT-green data screen by default.
	var le_box := crt_screen_panel()
	le_box.content_margin_left = 12
	le_box.content_margin_right = 12
	le_box.content_margin_top = 8
	le_box.content_margin_bottom = 8
	th.set_stylebox("normal",    "LineEdit", le_box)
	th.set_stylebox("focus",     "LineEdit", le_box)
	th.set_stylebox("read_only", "LineEdit", le_box)
	th.set_color("font_color",             "LineEdit", CRT_GREEN_INK)
	th.set_color("font_placeholder_color", "LineEdit", CRT_GREEN_BORDER)
	th.set_color("caret_color",            "LineEdit", CRT_GREEN_INK)
	th.set_color("selection_color",        "LineEdit", CRT_GREEN_BORDER)

	root.theme = th

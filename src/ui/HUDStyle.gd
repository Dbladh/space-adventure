extends RefCounted

# HUDStyle.gd
# Shared style constants + stylebox factories for the in-game HUD.  Used by
# Main.gd (credits, inventory chips), Player.gd (health bar), and
# ScreenPOIHUD.gd (POI tracker) so every chip and label reads as part of
# the same set.
#
# Sharp 1-2px borders, flat panel fills, nearest-neighbour filtering —
# matches the dithered retro aesthetic the rest of the game uses.

# ── Font sizes ────────────────────────────────────────────────────────────────
const HUD_FONT_SMALL: int = 14
const HUD_FONT_MED:   int = 18
const HUD_FONT_LRG:   int = 22

# ── Tier colours (resource rarity) ────────────────────────────────────────────
# Synced with SpaceStation._tier_color so the in-game HUD chips read as
# miniatures of the forge-menu resource cards — same palette, same rarity
# bucket per tier.  Any change here should be mirrored there.
const TIER_COLOR_1: Color = Color(0.75, 0.75, 0.75)  # T1 common — grey
const TIER_COLOR_2: Color = Color(0.35, 0.85, 1.00)  # T2 uncommon — cyan
const TIER_COLOR_3: Color = Color(0.60, 0.30, 1.00)  # T3 rare — purple
const TIER_COLOR_4: Color = Color(1.00, 0.55, 0.05)  # T4 legendary — orange-gold

# ── Chip layout ───────────────────────────────────────────────────────────────
const CHIP_PADDING_X: int = 6
const CHIP_PADDING_Y: int = 2
const CHIP_STRIPE_H:  int = 2  # height of the top tier-stripe in pixels
const CHIP_GAP:       int = 4

# ── HUD margins ───────────────────────────────────────────────────────────────
const CREDITS_OFFSET: Vector2 = Vector2(-24, 12)  # from TOP_RIGHT anchor
const INVENTORY_OFFSET: Vector2 = Vector2(24, 56) # from TOP_LEFT anchor (clear of health bar)
const HP_MARGIN_Y: float = 24.0                   # was 96 in Player.gd

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
	if border.a > 0.0 and border_w > 0:
		sb.set_border_width_all(border_w)
		sb.border_color = border
	sb.content_margin_left = CHIP_PADDING_X
	sb.content_margin_right = CHIP_PADDING_X
	sb.content_margin_top = CHIP_PADDING_Y + CHIP_STRIPE_H
	sb.content_margin_bottom = CHIP_PADDING_Y
	return sb

# Resource chip background.  Tints toward the resource's own colour so each
# chip carries a hint of what it represents (green-ish for Neon Moss, brown
# for Wood, blue for Aether, etc).
static func make_resource_chip_panel(res_color: Color, _tier: int) -> StyleBoxFlat:
	var bg: Color = res_color.darkened(0.62)
	bg.a = 0.90
	return make_pixel_panel(bg, Color(0.0, 0.0, 0.0, 0.45), 1)

# Recursively force nearest-neighbour filtering on a node tree.  Use it on
# any TextureRect that displays pixel-art so it stays crisp at scale.
static func apply_nearest_filter(node: CanvasItem) -> void:
	if node == null:
		return
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	for child in node.get_children():
		if child is CanvasItem:
			apply_nearest_filter(child)

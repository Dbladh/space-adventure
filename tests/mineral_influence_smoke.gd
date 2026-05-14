extends Node

# Standalone smoke test for the MineralInfluence + PlanetSeedKitchen overhaul.
# Run via res://tests/mineral_influence_smoke.tscn.
# Prints PASS/FAIL lines for each assertion, then quits the app.

# MineralInfluence and PlanetSeedKitchen are available as globals via class_name.

var _pass: int = 0
var _fail: int = 0

func _ready() -> void:
	print("\n===== MINERAL INFLUENCE SMOKE TEST =====")
	_test_synergy_bonus_metallic_trio()
	_test_unknown_mineral_neutral()
	_test_neutral_default_profile()
	_test_combine_gold_trio()
	_test_combine_sludge_trio()
	_test_archetype_pick_neon_moss()
	_test_archetype_pick_basalt_glass()
	_test_determinism()
	print("\n===== RESULT: %d passed / %d failed =====" % [_pass, _fail])
	get_tree().quit(0 if _fail == 0 else 1)

func _check(label: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS  %s%s" % [label, "  [" + detail + "]" if detail != "" else ""])
	else:
		_fail += 1
		print("  FAIL  %s%s" % [label, "  [" + detail + "]" if detail != "" else ""])

func _test_combine_gold_trio() -> void:
	var p: Dictionary = MineralInfluence.combine("Gold", "Gold", "Gold")
	# 1.5 * 1.5 * 1.5 = 3.375, clamped to 2.5
	_check("Gold×3 saturation_mult clamped", is_equal_approx(p["saturation_mult"], 2.5), "got=%f" % p["saturation_mult"])
	# 0.4 * 3 = 1.2, clamped to 1.5
	_check("Gold×3 ring_boost stacked", is_equal_approx(p["ring_boost"], 1.2), "got=%f" % p["ring_boost"])
	# DESERT vote: 1.5 * 3 = 4.5  ; VOLCANIC vote: 1.0 * 3 = 3.0
	_check("Gold×3 DESERT vote dominant",
		float(p["archetype_votes"]["DESERT"]) > float(p["archetype_votes"]["VOLCANIC"]),
		"DESERT=%f VOLCANIC=%f" % [p["archetype_votes"]["DESERT"], p["archetype_votes"]["VOLCANIC"]])
	_check("Gold×3 glow_boost high",
		float(p["glow_boost"]) >= 1.0,
		"got=%f" % p["glow_boost"])

func _test_combine_sludge_trio() -> void:
	var p: Dictionary = MineralInfluence.combine("Organic Sludge", "Organic Sludge", "Organic Sludge")
	# 2.0 * 3 = 6.0 ABYSS vote
	_check("Sludge×3 ABYSS vote heavy",
		is_equal_approx(p["archetype_votes"]["ABYSS"], 6.0),
		"got=%f" % p["archetype_votes"]["ABYSS"])
	# -0.20 * 3 = -0.60, clamped to -0.6
	_check("Sludge×3 value_delta darkens",
		is_equal_approx(p["value_delta"], -0.6),
		"got=%f" % p["value_delta"])
	# -50 * 3 = -150
	_check("Sludge×3 sea_level dropped",
		float(p["sea_level_delta"]) < -100.0,
		"got=%f" % p["sea_level_delta"])

func _test_archetype_pick_neon_moss() -> void:
	var p: Dictionary = MineralInfluence.combine("Neon Moss", "Neon Moss", "Neon Moss")
	var arch := MineralInfluence.pick_archetype(p, 1234)
	_check("Neon Moss×3 picks CANDY or RADIATED",
		arch in ["CANDY", "RADIATED"],
		"got=%s" % arch)

func _test_archetype_pick_basalt_glass() -> void:
	var p: Dictionary = MineralInfluence.combine("Basalt Glass", "Basalt Glass", "Basalt Glass")
	var arch := MineralInfluence.pick_archetype(p, 9999)
	_check("Basalt Glass×3 picks VOLCANIC",
		arch == "VOLCANIC",
		"got=%s" % arch)
	_check("Basalt Glass×3 terrain_mult clamped high",
		float(p["terrain_mult"]) >= 4.0,
		"got=%f" % p["terrain_mult"])

func _test_determinism() -> void:
	# Same trio + same seed → same archetype every time.
	var seed_val := PlanetSeedKitchen.make_seed("Gold", "Gold", "Gold")
	var arch1: String = ""
	var same := true
	for i in range(10):
		var prof: Dictionary = PlanetSeedKitchen.derive_profile("Gold", "Gold", "Gold", seed_val)
		if arch1 == "":
			arch1 = prof["archetype"]
		elif prof["archetype"] != arch1:
			same = false
			break
	_check("Gold×3 archetype deterministic across 10 calls", same, "first=%s" % arch1)

func _test_synergy_bonus_metallic_trio() -> void:
	# All 3 metallic → +10 synergy. With Tier 3 inputs the score is high enough to land an upper rank.
	var seed_val := PlanetSeedKitchen.make_seed("Gold", "Silver", "Platinum")
	var rank: Dictionary = PlanetSeedKitchen.rank_planet("Gold", "Silver", "Platinum", seed_val)
	_check("Gold+Silver+Platinum (3× metallic) → rank label set",
		String(rank.get("label", "")) != "",
		"label=%s score=%d" % [rank.get("label",""), int(rank.get("score",0))])
	# Compare to non-synergy trio of equivalent tier.
	var seed_b := PlanetSeedKitchen.make_seed("Gold", "Gold", "Wood")
	var rank_b: Dictionary = PlanetSeedKitchen.rank_planet("Gold", "Gold", "Wood", seed_b)
	# Both same average tier ~2.33 ish, but synergy bonus should make metallic trio higher.
	# Allow equal in pathological cosmic-bonus edge cases.
	_check("Metallic trio score >= mixed trio",
		int(rank.get("score",0)) >= int(rank_b.get("score",0)),
		"metallic=%d  mixed=%d" % [rank.get("score",0), rank_b.get("score",0)])

func _test_unknown_mineral_neutral() -> void:
	var inf: Dictionary = MineralInfluence.get_influence("NotARealMineral")
	_check("Unknown mineral returns neutral", is_equal_approx(inf["terrain_mult"], 1.0))
	_check("Unknown mineral empty votes", inf["archetype_votes"].is_empty())

func _test_neutral_default_profile() -> void:
	# combine of unknown trio should still yield a usable profile with archetype fallback.
	var p: Dictionary = MineralInfluence.combine("X","Y","Z")
	var arch := MineralInfluence.pick_archetype(p, 42)
	_check("Unknown trio yields fallback archetype",
		arch in MineralInfluence.VALID_ARCHETYPES,
		"got=%s" % arch)

class_name MobilePerf

# Single source of truth for "is this a mobile-tier device?".
# All `_mobile_perf` / `mobile_perf` callers across the project should go
# through MobilePerf.is_mobile() so the override below propagates everywhere.
#
# DEV TOGGLE — flip to true to force-test mobile branches in the desktop
# editor (F5 on Mac runs as if it were iPhone). Real iOS / Android builds
# always evaluate to true regardless of this flag, so it's safe to ship.
const FORCE_IN_EDITOR := false

static func is_mobile() -> bool:
	if FORCE_IN_EDITOR and OS.has_feature("editor"):
		return true
	if "--force-mobile" in OS.get_cmdline_args():
		return true
	return OS.get_name() == "iOS" \
		or OS.get_name() == "Android" \
		or OS.has_feature("mobile")

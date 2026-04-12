extends Node
class_name DebugSettings

# DebugSettings.gd (The Global Static Sync)
# Managed by THE ARCHITECT.

static var tree_mult: float = 1.0
static var rock_mult: float = 1.0
static var terrain_complexity: float = 1.0

# STATIC SIGNAL EMULATION: Use a common Hub or static reference
# In G4, we will use a static signal if available, otherwise a static class works.
static var _signal_hub: Node = null

static func emit_rebuild() -> void:
	if _signal_hub: _signal_hub.emit_signal("rebuild_requested")

static func connect_rebuild(obj: Object, method: String) -> void:
	if not _signal_hub:
		_signal_hub = Node.new()
		_signal_hub.add_user_signal("rebuild_requested")
	_signal_hub.connect("rebuild_requested", Callable(obj, method))

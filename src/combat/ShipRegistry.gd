extends RefCounted
class_name ShipRegistry

# ShipRegistry.gd
# Single source of truth for the four player-selectable ship hulls.  Used
# by Player.gd (in-game) and StartScreen.gd (selection preview).  Add new
# ships by appending a dictionary entry here — id is the save-file key.

const SHIPS: Array[Dictionary] = [
	{
		"id": "ship1",
		"display_name": "STARHAWK",
		"path": "res://assets/models/player/ship/Meshy_AI_Starhawk_01_0331051011_texture.glb",
	},
	{
		"id": "ship2",
		"display_name": "INTERCEPTOR",
		"path": "res://assets/models/player/ship 2/player_ship_2.glb",
	},
	{
		"id": "ship3",
		"display_name": "PROWLER",
		"path": "res://assets/models/player/ship 3/player_ship_3.glb",
	},
	{
		"id": "ship4",
		"display_name": "VOYAGER",
		"path": "res://assets/models/player/ship 4/player_ship_4.glb",
	},
]

const DEFAULT_ID: String = "ship1"

static func by_id(ship_id: String) -> Dictionary:
	for s in SHIPS:
		if s["id"] == ship_id:
			return s
	return SHIPS[0]

static func path_for(ship_id: String) -> String:
	return String(by_id(ship_id)["path"])

static func display_name_for(ship_id: String) -> String:
	return String(by_id(ship_id)["display_name"])

static func ids() -> Array[String]:
	var out: Array[String] = []
	for s in SHIPS:
		out.append(String(s["id"]))
	return out

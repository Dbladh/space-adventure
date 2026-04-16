# (c) On the Side LLC. and affiliates. Confidential and proprietary.
extends Node

# TITAN BENCHMARK SUITE: Performance stress testing for procedural worlds.
# Managed by THE ARCHITECT.

signal benchmark_completed(report: String)

var _results: Array = []
var _current_step: int = 0
var _timer: float = 0.0
var _is_running: bool = false
var _player: Node3D = null

# Stress scenarios: Name, Position (relative), Wait Time
var _scenarios = [
	{"name": "DEEP_SPACE", "pos": Vector3(5000000, 0, 0), "wait": 2.0},
	{"name": "HIGH_ORBIT_VARN", "pos": Vector3(0, 300000, 200000), "wait": 3.0},
	{"name": "LOW_ATMO_CITY", "pos": Vector3(0, 1150, 0), "wait": 5.0},
	{"name": "ASTEROID_BELT", "pos": Vector3(1500000, 0, 0), "wait": 4.0}
]

func start_automated_test(player: Node3D) -> void:
	_player = player
	_is_running = true
	_current_step = 0
	_results.clear()
	print("\n--- [TITAN_BENCHMARK] BEGINNING STRESS TEST ---")
	_execute_next_step()

func _process(delta: float) -> void:
	if not _is_running: return
	
	_timer -= delta
	if _timer <= 0:
		_record_data()
		_current_step += 1
		if _current_step < _scenarios.size():
			_execute_next_step()
		else:
			_finish_benchmark()

func _execute_next_step() -> void:
	var s = _scenarios[_current_step]
	_timer = s.wait
	if _player:
		_player.global_position = s.pos
	print("    TESTING SCENARIO: ", s.name)

func _record_data() -> void:
	var s = _scenarios[_current_step]
	var fps = Performance.get_monitor(Performance.TIME_FPS)
	var draws = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var objs = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var vram = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024 * 1024)
	
	_results.append({
		"name": s.name,
		"fps": fps,
		"draws": draws,
		"objs": objs,
		"vram": vram
	})

func _finish_benchmark() -> void:
	_is_running = false
	var report = "\n--- [TITAN_BENCHMARK_REPORT] ---\n"
	report += "SCENARIO | FPS | DRAWS | OBJS | VRAM\n"
	report += "------------------------------------\n"
	for r in _results:
		report += "%s | %d | %d | %d | %dMB\n" % [r.name, r.fps, r.draws, r.objs, r.vram]
	
	print(report)
	benchmark_completed.emit(report)

extends SceneTree

# PhysXFlow3D.sample_temperature(): a hot emitter and a cold, smoky one side by
# side for 3 s, read back with cpu_readback. Over the hot one the gas reads hot,
# the cold one's smoke reads near zero (so it's the temperature field, not the
# smoke), far away reads zero, and with cpu_readback off it returns -1 like
# sample_smoke. Needs a window (headless has no RenderingDevice):
#   godot --path . --script res://test/flow/flow_temperature_test.gd

const HOT := Vector3(-2, 0, 0)
const COLD := Vector3(2, 0, 0)

var _flow: Node3D
var _tick := 0
var _pass := true


func _initialize() -> void:
	# A broken test must fail and close its window, not hang.
	create_timer(30.0).timeout.connect(func() -> void:
		print("[flow_temp] FAIL: timed out")
		quit(1))
	if not ClassDB.class_exists("PhysXFlow3D"):
		print("[flow_temp] SKIP: this build has no Flow support (flow_sdk=)")
		quit(0)
		return
	var root := Node3D.new()
	get_root().add_child(root)
	_flow = ClassDB.instantiate("PhysXFlow3D")
	_flow.cpu_readback = true
	root.add_child(_flow)
	_add_emitter(root, HOT, 1.0, 0.2)
	_add_emitter(root, COLD, 0.0, 1.0)


func _add_emitter(p_root: Node3D, p_at: Vector3, p_temperature: float, p_smoke: float) -> void:
	var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	e.position = p_at
	e.radius = 0.4
	e.velocity = Vector3(0, 1, 0)
	e.temperature = p_temperature
	e.smoke = p_smoke
	p_root.add_child(e)


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %-50s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


func _physics_process(_delta: float) -> bool:
	if _flow == null:
		return true # skipped: no Flow in this build
	_tick += 1
	if _tick == 180:
		var s: Dictionary = _flow.get_stats()
		_check("Flow running", s.running, str(s.error))
		var hot: float = _flow.sample_temperature(HOT)
		var cold: float = _flow.sample_temperature(COLD)
		var cold_smoke: float = _flow.sample_smoke(COLD)
		var away: float = _flow.sample_temperature(Vector3(0, 1, 9))
		_check("hot over the hot emitter", hot > 0.3, "%.3f" % hot)
		_check("the cold emitter's smoke is there but not hot", cold_smoke > 0.1 and cold < 0.1 * hot, "temperature %.3f, smoke %.3f" % [cold, cold_smoke])
		_check("nothing far away", absf(away) < 0.01, "%.3f" % away)
		_flow.cpu_readback = false
		var off: float = _flow.sample_temperature(HOT)
		_check("-1 without cpu_readback", off == -1.0, "%.3f" % off)
		print("[flow_temp] ", "PASS" if _pass else "FAIL")
		quit(0 if _pass else 1)
		return true
	return false

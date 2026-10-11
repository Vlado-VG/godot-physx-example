extends SceneTree

# PhysXFlow3D.floor_enabled: Flow's colliders don't include heightmaps or trimeshes,
# so gas blown at terrain goes straight through it. Two flows 30 m apart, each
# with an emitter 1 m up blowing cold smoke down at a HeightMapShape3D ground:
# without the floor the smoke sinks below the ground; with floor_enabled
# (floor_height = 0) none gets under it and it gathers over the floor. Measured
# with sample_smoke (get_stats().bounds is block-coarse, ~0.8 m steps). Needs a
# window (headless has no RenderingDevice):
#   godot --path . --script res://test/flow/flow_floor_test.gd

const SEPARATION := 30.0

var _open: Node3D
var _floored: Node3D
var _tick := 0
var _pass := true


func _initialize() -> void:
	create_timer(30.0).timeout.connect(func() -> void:
		print("[flow_floor] FAIL: timed out")
		quit(1))
	if not ClassDB.class_exists("PhysXFlow3D"):
		print("[flow_floor] SKIP: this build has no Flow support (flow_sdk=)")
		quit(0)
		return
	var has_floor := ClassDB.class_has_method("PhysXFlow3D", "set_floor_enabled")
	if not has_floor:
		print("[flow_floor] PhysXFlow3D has no floor_enabled (reporting the no-floor case only)")
	var root := Node3D.new()
	get_root().add_child(root)

	# Terrain Flow can't see: a heightmap ground, flat at y = 0.
	var ground := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var hm := HeightMapShape3D.new()
	hm.map_width = 80
	hm.map_depth = 80
	cs.shape = hm
	ground.add_child(cs)
	ground.position = Vector3(SEPARATION * 0.5, 0, 0)
	root.add_child(ground)

	_open = _make_flow(root, "Open", Vector3(0, 0, 0))
	_floored = _make_flow(root, "Floored", Vector3(SEPARATION, 0, 0))
	if has_floor:
		_floored.set("floor_enabled", true)
		_floored.set("floor_height", 0.0)


func _make_flow(root: Node3D, name: String, at: Vector3) -> Node3D:
	var flow: Node3D = ClassDB.instantiate("PhysXFlow3D")
	flow.name = name
	flow.cpu_readback = true
	flow.position = at
	root.add_child(flow)
	var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	e.radius = 0.4
	e.velocity = Vector3(0, -4, 0)
	e.temperature = 0.0
	e.smoke = 1.0
	e.position = at + Vector3(0, 1, 0)
	root.add_child(e)
	e.set("flow", e.get_path_to(flow))
	return flow


# The most smoke found at height y within a metre of the flow's emitter column.
func _smoke(flow: Node3D, y: float) -> float:
	var best := 0.0
	for dx in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		for dz in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			best = maxf(best, flow.sample_smoke(flow.position + Vector3(dx, y, dz)))
	return best


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %-44s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


func _physics_process(_delta: float) -> bool:
	if _open == null:
		return true
	_tick += 1
	if _tick % 60 == 0:
		print("[flow_floor] tick %d  smoke 0.5 m under the ground: open %.3f  floored %.3f | 0.3 m over it: open %.3f  floored %.3f" % [
			_tick, _smoke(_open, -0.5), _smoke(_floored, -0.5), _smoke(_open, 0.3), _smoke(_floored, 0.3)])
	if _tick == 180:
		var so: Dictionary = _open.get_stats()
		var sf: Dictionary = _floored.get_stats()
		_check("both flows running", so.running and sf.running, "%s / %s" % [so.error, sf.error])
		var under_open := _smoke(_open, -0.5)
		var under_floored := _smoke(_floored, -0.5)
		var over_floored := _smoke(_floored, 0.3)
		_check("without a floor, smoke sinks through the ground", under_open > 0.05, "%.3f at 0.5 m under" % under_open)
		_check("with floor_enabled, none gets under it", under_floored < 0.01, "%.3f at 0.5 m under" % under_floored)
		_check("and it gathers over the floor instead", over_floored > 0.05, "%.3f at 0.3 m over" % over_floored)
		print("[flow_floor] step %.2f ms open, %.2f ms floored" % [so.step_ms, sf.step_ms])
		print("[flow_floor] ", "PASS" if _pass else "FAIL")
		quit(0 if _pass else 1)
		return true
	return false

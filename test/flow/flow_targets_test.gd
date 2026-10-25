extends SceneTree

# A PhysXFlowSimulation3D simulates only the emitters its `emitters` array
# names: two flows 10 m apart, each naming its own emitter -- each flow's gas
# must sit at its emitter only. A third emitter named by neither feeds no flow.
# Reads the gas back (cpu_readback); needs a window:
#   godot --path . --script res://test/flow/flow_targets_test.gd

var _a: Node3D
var _b: Node3D
var _tick := 0
var _pass := true


func _initialize() -> void:
	# A broken test must fail and close its window, not hang.
	create_timer(30.0).timeout.connect(func() -> void:
		print("[flow] FAIL: timed out")
		quit(1))
	if not ClassDB.class_exists("PhysXFlowSimulation3D"):
		print("[flow-targets] SKIP: no Flow support in this build")
		quit(0)
		return
	var root := Node3D.new()
	get_root().add_child(root)
	_a = _flow(root, "A", Vector3(-5, 0, 0), Vector3(-5, 0.5, 0))
	_b = _flow(root, "B", Vector3(5, 0, 0), Vector3(5, 0.5, 0))
	var stray: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	stray.position = Vector3(0, 0.5, 8)
	stray.velocity = Vector3(0, 1, 0)
	root.add_child(stray)


func _flow(root: Node, n: String, pos: Vector3, emitter_pos: Vector3) -> Node3D:
	var f: Node3D = ClassDB.instantiate("PhysXFlowSimulation3D")
	f.name = n
	f.cpu_readback = true
	f.position = pos
	root.add_child(f)
	var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	e.position = emitter_pos
	e.velocity = Vector3(0, 1, 0)
	root.add_child(e)
	f.emitters = [e.get_path()]
	return f


func _bounds(f: Node3D) -> AABB:
	return AABB(f.get_active_bounds_min(), f.get_active_bounds_size())


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %-50s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


func _physics_process(_delta: float) -> bool:
	if _a == null:
		return true # skipped: no Flow in this build
	_tick += 1
	if _tick == 150:
		var ba := _bounds(_a)
		var bb := _bounds(_b)
		_check("flow A's gas is at its emitter (x -5)", ba.has_volume() and absf(ba.get_center().x + 5.0) < 1.5, str(ba.get_center()))
		_check("flow B's gas is at its emitter (x +5)", bb.has_volume() and absf(bb.get_center().x - 5.0) < 1.5, str(bb.get_center()))
		_check("neither picked up the stray emitter (z +8)", ba.end.z < 6.0 and bb.end.z < 6.0, "A z<=%.1f B z<=%.1f" % [ba.end.z, bb.end.z])
		print("[flow-targets] ", "PASS" if _pass else "FAIL")
		quit(0 if _pass else 1)
		return true
	return false

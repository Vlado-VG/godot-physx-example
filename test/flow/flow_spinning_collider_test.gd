extends SceneTree

# A collision shape on a spinning body (a capsule on a turntable hub, its shape a
# direct child of the AnimatableBody3D) is a solid for PhysXFlow3D: inside the
# capsule there's no smoke, while on its circle ahead of it there is. Needs a
# window (headless has no RenderingDevice):
#   godot --path . --script res://test/flow/flow_spinning_collider_test.gd

const RADIUS := 1.0 # the capsule's distance from the hub
const SPIN := -40.0 # deg/s about +Y

var _flow: Node3D
var _hub: AnimatableBody3D
var _tick := 0
var _pass := true


func _initialize() -> void:
	create_timer(40.0).timeout.connect(func() -> void:
		print("[flow_spin] FAIL: timed out")
		quit(1))
	if not ClassDB.class_exists("PhysXFlow3D"):
		print("[flow_spin] SKIP: this build has no Flow support (flow_sdk=)")
		quit(0)
		return
	var root := Node3D.new()
	get_root().add_child(root)
	_flow = ClassDB.instantiate("PhysXFlow3D")
	_flow.set("floor_enabled", true)
	_flow.set("buoyancy", 0.0)
	_flow.set("smoke_fade", 0.02)
	_flow.set("cpu_readback", true)
	root.add_child(_flow)
	var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	e.set("shape", 1)
	e.set("size", Vector3(3, 0.8, 3))
	e.set("temperature", 0.0)
	e.set("smoke", 1.0)
	e.set("couple_rate", 0.5)
	e.position = Vector3(0, 0.4, 0)
	root.add_child(e)
	e.set("flow", e.get_path_to(_flow))

	_hub = AnimatableBody3D.new()
	_hub.sync_to_physics = false
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.25
	cap.height = 1.2
	cs.shape = cap
	cs.position = Vector3(RADIUS, 0.6, 0)
	_hub.add_child(cs)
	root.add_child(_hub)

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.look_at_from_position(Vector3(0, 4, 4), Vector3.ZERO)


func _smoke_at(angle_offset_deg: float) -> float:
	var local := Vector3(RADIUS, 0.4, 0).rotated(Vector3.UP, deg_to_rad(angle_offset_deg))
	return _flow.sample_smoke(_hub.global_transform * local)


func _check(label: String, ok: bool, detail: String) -> void:
	print("  [%s] %-44s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


func _physics_process(delta: float) -> bool:
	if _flow == null:
		return true
	_tick += 1
	_hub.rotate_y(deg_to_rad(SPIN) * delta)
	if _tick == 240:
		# The hub turns toward negative angles: -120 deg is ahead, not reached for 3 s.
		var at := _smoke_at(0.0)
		var ahead := _smoke_at(-120.0)
		print("[flow_spin] smoke inside the capsule %.3f, on its circle ahead %.3f" % [at, ahead])
		_check("the fog is there ahead of the capsule", ahead > 0.2, "")
		_check("and the capsule keeps it out", at < ahead * 0.3, "")
		print("[flow_spin] ", "PASS" if _pass else "FAIL")
		quit(0 if _pass else 1)
		return true
	return false

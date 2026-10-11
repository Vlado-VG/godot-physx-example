extends SceneTree

# U39 regression (godot-physx-example#1): on a GPU scene, PhysX hands a freed
# body's material ID to the next createMaterial() at once, but the GPU only
# drops the old material at its next simulate() -- a body created in between
# was bound to the dead slot and slid "as if on ice". Box on a 20 deg slope,
# friction 1 (tan 20 = 0.36, so it must hold): one created normally, one
# created in the same frame another body was freed. Both must hold.
# Only GPU scenes had the bug; on the CPU path both hold anyway.

var _t := 0
var _victim: RigidBody3D
var _control: RigidBody3D
var _reuse: RigidBody3D
var _start := {}


func _slope(x: float) -> void:
	var b := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = Vector3(6, 1, 30)
	cs.shape = s
	b.add_child(cs)
	b.position = Vector3(x, 0, 0)
	b.rotation_degrees = Vector3(20, 0, 0)
	get_root().add_child(b)


func _box(x: float, friction: float) -> RigidBody3D:
	var r := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = Vector3(1, 1, 1)
	cs.shape = s
	r.add_child(cs)
	var m := PhysicsMaterial.new()
	m.friction = friction
	r.physics_material_override = m
	r.position = Vector3(x, 1.2, 0)
	r.rotation_degrees = Vector3(20, 0, 0)
	get_root().add_child(r)
	return r


func _initialize() -> void:
	_slope(-8)
	_slope(8)
	_victim = _box(30, 0.0) # a frictionless body elsewhere: its material gets freed
	physics_frame.connect(_tick)


func _tick() -> void:
	_t += 1
	if _t == 30:
		_control = _box(-8, 1.0)
		_victim.free() # releases its material...
		_reuse = _box(8, 1.0) # ...and this one is created before the next simulate()
	if _t == 40:
		_start[_control] = _control.position
		_start[_reuse] = _reuse.position
	if _t < 160:
		return
	var c := _control.position.distance_to(_start[_control])
	var r := _reuse.position.distance_to(_start[_reuse])
	print("[material_reuse] slid in 2 s on a 20 deg slope: control %.2f m, created after a free %.2f m" % [c, r])
	if c < 0.1 and r < 0.1:
		print("[material_reuse] PASS -- a body created right after another is freed keeps its friction")
		quit(0)
	else:
		print("[material_reuse] FAIL: the body created after a free lost its friction")
		quit(1)

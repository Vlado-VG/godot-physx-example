extends SceneTree

# U32 regression (godot-physx-example#1): area-vs-area monitoring used to run
# the exact shape test on every shape pair of every (monitoring, monitorable)
# area pair each step. 28 monitoring areas x 80 shapes against 111 monitorable
# areas cost ~8.5 ms a frame here (31-37 ms in a real game). Bounds are now
# compared first. Two checks:
#   - same answers: exactly the 12 areas placed on a strip are entered
#   - fast: physics time per tick (TIME_PHYSICS_PROCESS: the physics server's
#     step included) stays low (~1.2 ms here; the old code ~9.5 ms). Run it
#     without --fixed-fps: that mode leaves this monitor at 0.

const FRAMES := 180
const MAX_MS := 5.0
var _t := 0
var _physics_sum := 0.0
var _entered := 0


func _area(pos: Vector3, monitoring: bool, monitorable: bool) -> Area3D:
	var a := Area3D.new()
	a.position = pos
	a.collision_layer = 1
	a.collision_mask = 0xFFFFFFFF
	a.monitoring = monitoring
	a.monitorable = monitorable
	return a


func _initialize() -> void:
	# 28 monitoring "strips" of 80 small spheres, 6 m apart along z.
	for i in 28:
		var a := _area(Vector3(0, 0, i * 6.0), true, false)
		for k in 80:
			var cs := CollisionShape3D.new()
			var s := SphereShape3D.new()
			s.radius = 0.6
			cs.shape = s
			cs.position = Vector3(k * 0.5, 0, 0)
			a.add_child(cs)
		a.area_entered.connect(func(_o: Area3D) -> void: _entered += 1)
		get_root().add_child(a)
	# 12 monitorable boxes sitting on strips 0..11, the rest 50 m up, clear of everything.
	for i in 111:
		var on_strip := i < 12
		var pos := Vector3(10.0, 0.0, i * 6.0) if on_strip else Vector3((i % 20) * 5.0, 50.0, (i / 20) * 5.0)
		var b := _area(pos, false, true)
		var cs := CollisionShape3D.new()
		var s := BoxShape3D.new()
		s.size = Vector3(1, 2, 1)
		cs.shape = s
		b.add_child(cs)
		get_root().add_child(b)
	physics_frame.connect(_tick)


func _tick() -> void:
	_t += 1
	if _t > 30:
		_physics_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if _t < 30 + FRAMES:
		return
	var ms := _physics_sum * 1000.0 / FRAMES
	print("[area_scale] area_entered %d (expected 12), avg physics tick %.2f ms (limit %.1f)" % [_entered, ms, MAX_MS])
	if _entered == 12 and ms < MAX_MS:
		print("[area_scale] PASS -- many-area monitoring is correct and cheap")
		quit(0)
	else:
		print("[area_scale] FAIL")
		quit(1)

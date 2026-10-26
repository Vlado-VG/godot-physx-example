extends SceneTree

# Area-vs-area detection keeps a resting area's world bounds between steps (uno1982/godot#12): a monitoring sensor
# must still see a resting target that changes without moving -- its box shape grown into it or shrunk away, its
# collision shape disabled and enabled, the shape swapped for another -- and one that moves in and out. Each change
# is followed by 10 physics frames; the sensor's area_entered / area_exited count after each must match.

var _sensor: Area3D
var _target: Area3D
var _shape: CollisionShape3D
var _box: BoxShape3D
var _entered := 0
var _exited := 0
var _tick := 0
var _step := 0
var _failed := false

# Each step: what to do, then the enter / exit totals expected 10 frames later.
var _steps := [
	["start apart", 0, 0],
	["grow into the sensor", 1, 0],
	["shrink away", 1, 1],
	["move in", 2, 1],
	["move away", 2, 2],
	["move back in", 3, 2],
	["disable its shape", 3, 3],
	["enable its shape", 4, 3],
	["swap in a small sphere", 4, 4],
	["swap in a big box", 5, 4],
]


func _initialize() -> void:
	print("[area_cache] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))
	_sensor = Area3D.new()
	var sensor_shape := CollisionShape3D.new()
	var sensor_box := BoxShape3D.new()
	sensor_box.size = Vector3(1, 1, 1)
	sensor_shape.shape = sensor_box
	_sensor.add_child(sensor_shape)
	_sensor.area_entered.connect(func(_a): _entered += 1)
	_sensor.area_exited.connect(func(_a): _exited += 1)
	get_root().add_child(_sensor)

	_target = Area3D.new()
	_target.monitoring = false
	_target.position = Vector3(3, 0, 0)
	_shape = CollisionShape3D.new()
	_box = BoxShape3D.new()
	_box.size = Vector3(1, 1, 1)
	_shape.shape = _box
	_target.add_child(_shape)
	get_root().add_child(_target)
	physics_frame.connect(_physics)


func _apply(p_what: String) -> void:
	match p_what:
		"grow into the sensor":
			_box.size = Vector3(5, 1, 1)
		"shrink away":
			_box.size = Vector3(1, 1, 1)
		"move in":
			_target.position = Vector3(0.5, 0, 0)
		"move away":
			_target.position = Vector3(3, 0, 0)
		"move back in":
			_target.position = Vector3(0.5, 0, 0)
		"disable its shape":
			_shape.disabled = true
		"enable its shape":
			_shape.disabled = false
		"swap in a small sphere":
			var sphere := SphereShape3D.new()
			sphere.radius = 0.1
			_target.position = Vector3(1.5, 0, 0)
			_shape.shape = sphere
		"swap in a big box":
			var big := BoxShape3D.new()
			big.size = Vector3(4, 1, 1)
			_shape.shape = big


func _physics() -> void:
	_tick += 1
	if _tick % 10 != 0:
		return
	var expected: Array = _steps[_step]
	var ok: bool = _entered == expected[1] and _exited == expected[2]
	print("[area_cache] after '%s': entered=%d exited=%d (expected %d / %d) -> %s" % [expected[0], _entered, _exited, expected[1], expected[2], "ok" if ok else "FAIL"])
	if not ok:
		_failed = true
	_step += 1
	if _step == _steps.size():
		print("[area_cache] overall -> ", "FAIL" if _failed else "PASS")
		quit(1 if _failed else 0)
		return
	_apply(_steps[_step][0])

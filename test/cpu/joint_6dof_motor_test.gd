extends SceneTree

# U21: Generic6DOFJoint3D motors. A 1 kg unit box hangs on a 6DOF joint to a static
# anchor, gravity off. Matches Jolt (Godot Physics doesn't drive this setup at all):
#   an angular motor on X / Y / Z spins the box at its target velocity, in Jolt's
#   direction: a positive target is a NEGATIVE angular velocity about that joint
#   axis (clockwise, as Godot's joint angles run);
#   the angular force limit is a torque: 0.5 N m on I = 1/6 kg m^2 -> 3 rad/s^2;
#   the linear force limit is a force: 2 N on 1 kg -> 2 m/s^2;
#   live changes act: a new target velocity, and a motor switched off lets the box
#   spin on freely (it used to brake to a stop) -- even after it fell asleep;
#   a slow motor (50 kg box, 1.5 N m: 0.18 rad/s^2) spins up from rest instead of
#   being put to sleep first (PhysX drives don't keep a body awake). Beyond Jolt:
#   Jolt puts this one to sleep too (0.00 rad/s), only faster motors get going there.

const TARGET := 2.0

var _cases := []
var _t := 0
var _ok := true
var _live: Generic6DOFJoint3D
var _last_joint: Generic6DOFJoint3D
var _live_box: RigidBody3D


func _check(cond: bool, msg: String) -> void:
	print("[6dof_motor] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _make(x: float, setup: Callable) -> RigidBody3D:
	var anchor := StaticBody3D.new()
	anchor.position = Vector3(x, 5, 0)
	get_root().add_child(anchor)
	var box := RigidBody3D.new()
	box.position = Vector3(x, 5, 0)
	box.gravity_scale = 0.0
	box.mass = 1.0
	box.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	box.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	box.can_sleep = false
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = Vector3.ONE
	cs.shape = b
	box.add_child(cs)
	get_root().add_child(box)
	var j := Generic6DOFJoint3D.new()
	j.position = Vector3(x, 5, 0)
	get_root().add_child(j)
	setup.call(j)
	_last_joint = j
	j.node_a = j.get_path_to(anchor)
	j.node_b = j.get_path_to(box)
	return box


func _angular(axis: String, target: float, limit: float) -> Callable:
	return func(j: Generic6DOFJoint3D) -> void:
		j.set("angular_limit_%s/enabled" % axis, false)
		j.set("angular_motor_%s/enabled" % axis, true)
		j.set("angular_motor_%s/target_velocity" % axis, target)
		j.set("angular_motor_%s/force_limit" % axis, limit)


func _initialize() -> void:
	var axes := {"x": Vector3.RIGHT, "y": Vector3.UP, "z": Vector3.BACK}
	var x := 0.0
	for a in axes:
		_cases.append({"kind": "spin", "axis": a, "dir": axes[a], "box": _make(x, _angular(a, TARGET, 1000.0))})
		x += 4.0
	var live_box := _make(x, _angular("y", TARGET, 1000.0))
	_live = _last_joint
	_live_box = live_box
	x += 4.0
	_cases.append({"kind": "torque", "box": _make(x, _angular("x", 10.0, 0.5))})
	x += 4.0
	var slow := _make(x, _angular("y", 3.0, 1.5))
	slow.mass = 50.0
	slow.can_sleep = true
	_cases.append({"kind": "slow", "box": slow})
	x += 4.0
	_cases.append({"kind": "force", "box": _make(x, func(j: Generic6DOFJoint3D) -> void:
		j.set("linear_limit_x/enabled", false)
		j.set("linear_motor_x/enabled", true)
		j.set("linear_motor_x/target_velocity", 5.0)
		j.set("linear_motor_x/force_limit", 2.0))})
	print("[6dof_motor] engine: %s" % ProjectSettings.get_setting("physics/3d/physics_engine"))
	physics_frame.connect(_tick)


func _tick() -> void:
	_t += 1
	if _t == 31: # 0.5 s of motor
		for c in _cases:
			var box: RigidBody3D = c.box
			match c.kind:
				"torque":
					var w := box.angular_velocity.x
					print("[6dof_motor] torque-limited spin after 0.5 s: %.3f rad/s about x" % w)
					_check(absf(absf(w) - 1.5) < 0.3, "angular force_limit is a torque (0.5 N m / (1/6 kg m^2) * 0.5 s = 1.5 rad/s, got %.2f)" % absf(w))
				"force":
					var v := box.linear_velocity.x
					print("[6dof_motor] force-limited slide after 0.5 s: %.3f m/s along x" % v)
					_check(absf(v - 1.0) < 0.2, "linear force_limit is a force (2 N / 1 kg * 0.5 s = 1.0 m/s, got %.2f)" % v)
	if _t == 61:
		for c in _cases:
			if c.kind != "spin":
				continue
			var box: RigidBody3D = c.box
			var w: float = box.angular_velocity.dot(c.dir)
			var other: float = (box.angular_velocity - c.dir * w).length()
			print("[6dof_motor] motor %s: %.3f rad/s about the axis, %.3f about the others" % [c.axis, w, other])
			_check(absf(w + TARGET) < 0.1 and other < 0.1, "angular motor %s spins at -%.1f rad/s about its axis, as Jolt (got %.2f)" % [c.axis, TARGET, w])
		var lw := _live_box.angular_velocity.y
		_check(absf(lw + TARGET) < 0.1, "live: motor y at +2 -> %.2f rad/s" % lw)
		_live.set("angular_motor_y/target_velocity", -1.0)
	if _t == 91:
		var lw := _live_box.angular_velocity.y
		_check(absf(lw - 1.0) < 0.1, "live: target changed to -1 -> %.2f rad/s (want +1)" % lw)
		_live.set("angular_motor_y/enabled", false)
	if _t == 121:
		for c in _cases:
			if c.kind == "slow":
				var sw := absf((c.box as RigidBody3D).angular_velocity.y)
				_check(absf(sw - 0.36) < 0.05, "slow motor spins up from rest: %.2f rad/s after 2 s (want ~0.36, 1.5 N m / 8.33 kg m^2)" % sw)
		var lw := _live_box.angular_velocity.y
		_check(absf(lw - 1.0) < 0.1, "live: motor off -> spins on freely at %.2f rad/s (want +1, not braked)" % lw)
		_live_box.angular_velocity = Vector3.ZERO
		_live_box.can_sleep = true
		_live_box.sleeping = true
	if _t == 131:
		_live.set("angular_motor_y/enabled", true)
	if _t == 161:
		var lw := _live_box.angular_velocity.y
		_check(absf(lw - 1.0) < 0.1, "live: motor back on while asleep -> %.2f rad/s (want +1)" % lw)
		print("[6dof_motor] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)

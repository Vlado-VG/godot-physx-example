extends SceneTree

# Drive-direction isolation probe: builds a PhysXVehicle3D via ClassDB and
# toggles one demo trait at a time (mode arg) to find what flips the drive
# direction vs the redot smoke test. Usage: -s this.gd -- <mode>

var car: Node
var frame := 0
var mode := 0
var steer_sign := 1.0

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		mode = int(args[0])

	var ground: Node = ClassDB.instantiate("StaticBody3D")
	root.add_child(ground)
	var gs: Node = ClassDB.instantiate("CollisionShape3D")
	var gbox: Object = ClassDB.instantiate("BoxShape3D")
	gbox.set("size", Vector3(400, 1, 400))
	gs.set("shape", gbox)
	ground.add_child(gs)
	ground.set_position(Vector3(0, -0.5, 0))

	car = ClassDB.instantiate("PhysXVehicle3D")
	root.add_child(car)
	car.global_transform = Transform3D(Basis(), Vector3(0, 1.0, 0))
	car.set("mass", 1200.0 if mode < 1 else 900.0)
	car.set("can_sleep", false)
	if mode >= 1:
		car.set("center_of_mass_mode", 1)
		car.set("center_of_mass", Vector3(0, -0.1, 0))

	var chassis: Node = ClassDB.instantiate("CollisionShape3D")
	var cbox: Object = ClassDB.instantiate("BoxShape3D")
	# mode>=2: the demo's actual BodyBox (high and forward of the origin).
	cbox.set("size", Vector3(1.9717, 1, 2.08592) if mode >= 2 else Vector3(1.8, 0.6, 4.0))
	chassis.set("shape", cbox)
	chassis.set_position(Vector3(0.0026385, 0.827398, 0.719927) if mode >= 2 else Vector3(0, 0.1, 0))
	car.add_child(chassis)

	for i in 4:
		var w: Node = ClassDB.instantiate("PhysXVehicleWheel3D")
		var front := i < 2
		w.set_position(Vector3(-0.85 if i % 2 == 0 else 0.85,
				-0.1, -1.4 if front else 1.4))
		w.set("use_as_steering", front)
		w.set("use_as_traction", true)
		w.set("radius", 0.37)
		w.set("suspension_travel", 0.357)
		w.set("suspension_stiffness", 9300.0)
		w.set("suspension_damping", 1100.0)
		car.add_child(w)

	car.set("throttle", 1.0)
	physics_frame.connect(_tick)
	steer_sign = 1.0 if mode % 2 == 0 else -1.0

func _tick() -> void:
	frame += 1
	if frame == 60:
		car.set("steer", 0.5 * steer_sign)
	if frame % 30 == 0:
		print("[probe m%d] f=%d pos=%s fwd=%.2f j0=%.2f" % [
				mode, frame, car.global_position,
				car.get_forward_speed(), car.get_wheel_jounce(0)])
	if frame >= 150:
		print("[probe m%d] RESULT pos=%s fwd=%.2f" % [mode, car.global_position, car.get_forward_speed()])
		quit(0)

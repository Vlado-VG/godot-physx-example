extends Node3D

# Rigid-body features you set in the Inspector, one station each. Walk up to
# them; everything here is plain Godot nodes and properties.
#
#   Carousel / Elevator   MovingPlatform (demo/common/moving_platform.gd), an
#                         AnimatableBody3D with spin / travel / period. Stand
#                         on one: CharacterBody3D picks up the platform's
#                         motion -- spin included -- and so do the crates.
#   Constant force        RigidBody3D > Constant Forces. The crates' upward
#                         force equals their weight, so they float where you
#                         shove them; the pinwheel's constant torque keeps it
#                         turning (its angular damp sets the top speed).
#   Inertia               RigidBody3D > Mass Distribution > Inertia. Both
#                         flywheels are the same disc; the gold one's inertia
#                         is 5x the shape's own, so the same kick (F) spins it
#                         5x slower. Zero = computed from the shape.
#   Center of mass        RigidBody3D > Mass Distribution > Center Of Mass
#                         Mode = Custom. The green toy's center of mass sits
#                         low in its round base, so it rights itself when
#                         knocked over (G); the red one (Auto) stays down.
#   Generic6DOFJoint3D    Per-axis motors and springs. Two fans on an angular
#                         motor (Y, 3 rad/s): the steel one's force limit is
#                         60 N m, the gold one's 1.5 N m, so it spins up slowly
#                         and stops when you stand in it (M toggles both
#                         motors: off, they coast). A shuttle on a linear motor
#                         between limits, its target flipped at each end. A
#                         flap on an angular spring swings back to rest (H).
#
#   WASD move   SPACE jump   click: capture mouse / look   ESC release mouse
#   F  kick both flywheels   G  knock the toys over   M  fan motors   H  knock the flap   R  reset

const FLYWHEEL_KICK := 50.0 # N*m*s about the axle
const TOY_KNOCK := 2.5 # N*s, sideways at the top
const FLAP_KNOCK := 12.0 # N*s, at the flap's lower edge
const SHUTTLE_SPEED := 1.5 # m/s
const SHUTTLE_TURN := 2.0 # m from the middle: flip the motor's target here

@onready var _char: CharacterBody3D = $Player
@onready var _cam: Camera3D = $Player/Camera3D
@onready var _hud: Label = $HUD/Label
@onready var _flywheels: Array[RigidBody3D] = [$Inertia/Flywheel, $Inertia/HeavyFlywheel]
@onready var _toys: Array[RigidBody3D] = [$CenterOfMass/LowCenter, $CenterOfMass/AutoCenter]
@onready var _fans: Array[RigidBody3D] = [$Joints6DOF/Fan, $Joints6DOF/WeakFan]
@onready var _fan_joints: Array[Generic6DOFJoint3D] = [$Joints6DOF/FanJoint, $Joints6DOF/WeakFanJoint]
@onready var _shuttle: RigidBody3D = $Joints6DOF/Shuttle
@onready var _shuttle_joint: Generic6DOFJoint3D = $Joints6DOF/ShuttleJoint
@onready var _flap: RigidBody3D = $Joints6DOF/Flap
var _fp: FirstPersonCharacter


func _ready() -> void:
	_fp = FirstPersonCharacter.new(_char, _cam, self)


func _physics_process(delta: float) -> void:
	_fp.physics_process(delta)
	# The shuttle's linear motor drives toward the end it's facing; flip at each end.
	var offset := _shuttle.position.x - _shuttle_joint.position.x
	var target: float = _shuttle_joint.get("linear_motor_x/target_velocity")
	if (offset > SHUTTLE_TURN and target > 0.0) or (offset < -SHUTTLE_TURN and target < 0.0):
		_shuttle_joint.set("linear_motor_x/target_velocity", -target)
	var lines := PackedStringArray()
	lines.append("WASD move  SPACE jump  click look  F kick flywheels  G knock toys  M fan motors  H knock flap  R reset")
	lines.append("flywheels  %.1f rad/s  |  %.1f rad/s (5x inertia)" % [_flywheels[0].angular_velocity.y, _flywheels[1].angular_velocity.y])
	lines.append("toys tilt  %.0f deg (custom COM)  |  %.0f deg (auto)" % [_tilt(_toys[0]), _tilt(_toys[1])])
	lines.append("fans  %.1f rad/s (60 N m)  |  %.1f rad/s (1.5 N m)  motors %s   shuttle %+.1f m   flap %.0f deg" % [
			absf(_fans[0].angular_velocity.y), absf(_fans[1].angular_velocity.y),
			"on" if _fan_joints[0].get("angular_motor_y/enabled") else "off",
			_shuttle.position.x - _shuttle_joint.position.x, _tilt(_flap)])
	_hud.text = "\n".join(lines)


func _tilt(rb: RigidBody3D) -> float:
	return rad_to_deg(rb.global_basis.y.angle_to(Vector3.UP))


func _unhandled_input(event: InputEvent) -> void:
	if _fp.handle_input(event):
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
				else:
					get_tree().quit()
			KEY_F:
				for w in _flywheels:
					w.apply_torque_impulse(Vector3(0, FLYWHEEL_KICK, 0))
			KEY_G:
				for toy in _toys:
					# Sideways at the head: tips the toy over.
					toy.apply_impulse(Vector3(TOY_KNOCK, 0, 0), toy.global_basis.y * 1.0)
			KEY_M:
				for j in _fan_joints:
					j.set("angular_motor_y/enabled", not j.get("angular_motor_y/enabled"))
			KEY_H:
				# At the lower edge, from the shuttle's side: swings it about the hinge.
				_flap.apply_impulse(Vector3(-FLAP_KNOCK, 0, 0), -_flap.global_basis.y * 0.6)
			KEY_R:
				get_tree().reload_current_scene()

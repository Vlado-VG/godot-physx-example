extends RigidBody3D
# Keyboard driving for a boat built from PhysXBuoyancy3D + PhysXBoat3D
# children, with a chase camera that follows behind it.
#
#   W / S    throttle ahead / astern
#   A / D    steer left / right
#   B        boat camera on/off (back to the scene's own camera)

@export var throttle_rate := 1.5 # throttle change per second
@export var steering_rate := 3.0 # steering change per second
@export var camera_distance := 7.0
@export var camera_height := 2.6
@export var camera_follow := 4.0 # higher = tighter follow

@onready var _boat: PhysXBoat3D = find_children("*", "PhysXBoat3D", false, false)[0]
@onready var _camera: Camera3D = $ChaseCamera

var _throttle := 0.0
var _steering := 0.0
var _scene_camera: Camera3D

func _ready() -> void:
	add_to_group("hud_info")
	_camera.top_level = true
	_camera.global_position = global_position - global_basis.z * camera_distance + Vector3.UP * camera_height
	_camera.look_at(global_position + Vector3.UP * 0.5)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_B:
		if _camera.current:
			if _scene_camera:
				_scene_camera.make_current()
		else:
			_scene_camera = get_viewport().get_camera_3d()
			_camera.make_current()

func _physics_process(delta: float) -> void:
	var t_in := float(Input.is_key_pressed(KEY_W)) - float(Input.is_key_pressed(KEY_S))
	var s_in := float(Input.is_key_pressed(KEY_A)) - float(Input.is_key_pressed(KEY_D))
	# Only while the boat camera is on, so the fly camera's WASD doesn't drive it.
	if not _camera.current:
		t_in = 0.0
		s_in = 0.0
	_throttle = move_toward(_throttle, t_in, throttle_rate * delta)
	_steering = move_toward(_steering, s_in, steering_rate * delta)
	_boat.throttle = _throttle
	_boat.steering = _steering

func _process(delta: float) -> void:
	# Follow behind along the boat's heading (flattened, so pitching and
	# rolling don't swing the camera).
	var fwd := global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 1e-6 else Vector3.FORWARD
	var eye := global_position - fwd * camera_distance + Vector3.UP * camera_height
	_camera.global_position = _camera.global_position.lerp(eye, clampf(camera_follow * delta, 0.0, 1.0))
	_camera.look_at(global_position + Vector3.UP * 0.5)

func get_hud_text() -> String:
	return "Boat: W/S throttle  A/D steer  B boat camera\nspeed %.1f m/s (%.0f km/h)  throttle %+.2f  thrust %.0f N" % [
		_boat.get_forward_speed(), _boat.get_forward_speed() * 3.6, _throttle, _boat.get_applied_thrust()]

extends RigidBody3D
# Keyboard driving for a boat built from PhysXBuoyancy3D + PhysXBoat3D
# children, with a chase camera that follows behind it.
#
#   W / S    throttle ahead / astern
#   A / D    steer left / right
#   Tab      swap between the boat camera and the scene's fly camera
#   Hold RMB look around the boat (eases back behind it when released)
#   Wheel    camera distance

@export var throttle_rate := 1.5 # throttle change per second
@export var steering_rate := 3.0 # steering change per second
@export var camera_distance := 7.0
@export var camera_height := 2.6
@export var camera_follow := 4.0 # higher = tighter follow
@export var mouse_sensitivity := 0.004
@export var camera_return_speed := 1.5 # how fast the look eases back behind the boat (per second)

@onready var _boat: PhysXBoat3D = find_children("*", "PhysXBoat3D", false, false)[0]
@onready var _camera: Camera3D = $ChaseCamera

var _throttle := 0.0
var _steering := 0.0
var _scene_camera: Camera3D
var _orbit_yaw := 0.0 # around the boat, relative to behind it
var _orbit_pitch := 0.0 # added elevation
var _looking := false

func _ready() -> void:
	add_to_group("hud_info")
	_camera.top_level = true
	_camera.global_position = global_position - global_basis.z * camera_distance + Vector3.UP * camera_height
	_camera.look_at(global_position + Vector3.UP * 0.5)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		if _camera.current:
			if _scene_camera:
				_scene_camera.make_current()
		else:
			_scene_camera = get_viewport().get_camera_3d()
			_camera.make_current()
		_set_looking(false)
		get_viewport().set_input_as_handled()
		return
	if not _camera.current:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_set_looking(event.pressed)
			get_viewport().set_input_as_handled()
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = maxf(camera_distance * 0.9, 3.0)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = minf(camera_distance / 0.9, 30.0)
	elif event is InputEventMouseMotion and _looking:
		_orbit_yaw -= event.relative.x * mouse_sensitivity
		_orbit_pitch = clampf(_orbit_pitch - event.relative.y * mouse_sensitivity, -0.3, 1.2)
		get_viewport().set_input_as_handled()

func _set_looking(p_on: bool) -> void:
	_looking = p_on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if p_on else Input.MOUSE_MODE_VISIBLE

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
	if not _looking:
		var k := clampf(camera_return_speed * delta, 0.0, 1.0)
		_orbit_yaw = lerp_angle(_orbit_yaw, 0.0, k)
		_orbit_pitch = lerpf(_orbit_pitch, 0.0, k)
	# Behind the boat, swung round by the mouse look.
	var back := (-fwd).rotated(Vector3.UP, _orbit_yaw)
	var reach := Vector2(camera_distance, camera_height).length()
	var elevation := clampf(atan2(camera_height, camera_distance) + _orbit_pitch, -0.1, 1.45)
	var eye := global_position + back * cos(elevation) * reach + Vector3.UP * sin(elevation) * reach
	# Snappy while looking (it follows the mouse), smoothed otherwise.
	var follow := 20.0 if _looking else camera_follow
	_camera.global_position = _camera.global_position.lerp(eye, clampf(follow * delta, 0.0, 1.0))
	_camera.look_at(global_position + Vector3.UP * 0.5)

func get_hud_text() -> String:
	return "Boat: W/S throttle  A/D steer  hold RMB look  wheel zoom  Tab swap camera\nspeed %.1f m/s (%.0f km/h)  throttle %+.2f  thrust %.0f N" % [
		_boat.get_forward_speed(), _boat.get_forward_speed() * 3.6, _throttle, _boat.get_applied_thrust()]

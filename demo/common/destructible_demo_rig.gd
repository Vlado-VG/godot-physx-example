extends Camera3D
# Fly-cam rig for the PhysXDestructible3D showcase: hold RMB to look, WASD to
# fly, left-click to raycast forward and apply radial damage wherever it
# hits -- same shoot pattern as debris.gd's _shoot(), just calling
# apply_radial_damage() on whatever's in the "destructible" group instead of
# spawning a chunk burst.

const FlyCamera = preload("res://demo/common/fly_camera.gd")

@export var fly_speed := 8.0
@export var shot_damage := 5.0 # deliberate overkill -- see the module's Blast
	# planning notes on why damage exactly equal to a bond's initial health
	# was insufficient in testing.
@export var shot_min_radius := 0.3
@export var shot_max_radius := 3.5

var _fly: FlyCamera

func _ready() -> void:
	_fly = FlyCamera.new(self, fly_speed)

func _process(delta: float) -> void:
	_fly.process(delta)

func _unhandled_input(event: InputEvent) -> void:
	if _fly.handle_input(event):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_shoot()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _shoot() -> void:
	var from := global_position
	var to := from + global_transform.basis.z * -60.0
	var params := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(params)
	if not hit:
		return
	for target in get_tree().get_nodes_in_group("destructible"):
		target.apply_radial_damage(hit.position, shot_damage, shot_min_radius, shot_max_radius)

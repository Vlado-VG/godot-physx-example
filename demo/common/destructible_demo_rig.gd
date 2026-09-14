extends Camera3D
# Fly-cam rig for the PhysXDestructible3D showcase: hold RMB to look, WASD to
# fly, left-click to raycast forward and apply radial damage wherever it
# hits -- same shoot pattern as debris.gd's _shoot(), just calling
# apply_radial_damage() on whatever's in the "destructible" group instead of
# spawning a chunk burst. Middle-click fires the physx_playground.gd bomb: a
# real thrown RigidBody3D ball that explodes on contact -- for testing
# dynamic destructibles' impact/force response (knockback, getting knocked
# into each other), not just precision damage. Can't reuse RMB like the
# playground does -- FlyCamera already holds RMB for its look-around gesture.
#
# The bomb can't reuse physx_playground.gd's own _blast() (RigidBody3D-only:
# `if col is RigidBody3D`) since a PhysXDestructible3D's pieces are raw
# PhysicsServer3D RIDs with no owning RigidBody3D node to match -- instead it
# calls apply_radial_damage() on every "destructible" group member at the
# explosion point, same as _shoot(), just triggered by a physical impact
# instead of a raycast, and with a wider radius/softer damage to suit an
# area blast rather than a precise hit.

const FlyCamera = preload("res://demo/common/fly_camera.gd")

@export var fly_speed := 8.0
@export var shot_damage := 5.0 # deliberate overkill -- see the module's Blast
	# planning notes on why damage exactly equal to a bond's initial health
	# was insufficient in testing.
@export var shot_min_radius := 0.3
@export var shot_max_radius := 3.5

@export var bomb_damage := 8.0
@export var bomb_min_radius := 0.5
@export var bomb_max_radius := 7.0
@export var bomb_speed := 45.0

var _fly: FlyCamera

func _ready() -> void:
	_fly = FlyCamera.new(self, fly_speed)

func _process(delta: float) -> void:
	_fly.process(delta)

func _unhandled_input(event: InputEvent) -> void:
	if _fly.handle_input(event):
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_shoot()
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_fire_bomb()
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

func _fire_bomb() -> void:
	var fwd := (-global_transform.basis.z).normalized()
	var ball := RigidBody3D.new()
	ball.mass = 6.0
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.35
	sm.height = 0.7
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.95, 0.3, 0.1)
	m.emission_enabled = true
	m.emission = Color(0.6, 0.15, 0.0)
	sm.material = m
	mi.mesh = sm
	ball.add_child(mi)
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.35
	cs.shape = sh
	ball.add_child(cs)
	ball.contact_monitor = true
	ball.max_contacts_reported = 4
	get_parent().add_child(ball)
	ball.global_position = global_position + fwd * 1.5
	ball.linear_velocity = fwd * bomb_speed
	ball.body_entered.connect(_on_bomb_hit.bind(ball), CONNECT_ONE_SHOT)

func _on_bomb_hit(_other: Node, ball: RigidBody3D) -> void:
	var center := ball.global_position
	for target in get_tree().get_nodes_in_group("destructible"):
		target.apply_radial_damage(center, bomb_damage, bomb_min_radius, bomb_max_radius)
	var t := get_tree().create_timer(0.05)
	t.timeout.connect(func() -> void: if is_instance_valid(ball): ball.queue_free())

extends Camera3D
# Fly-cam rig for the PhysXDestructible3D showcase: hold RMB to look, WASD to
# fly, left-click fires the physx_playground.gd bomb -- a real thrown
# RigidBody3D ball that explodes on contact -- for testing destructibles'
# impact/force response (knockback, getting knocked into each other), not
# just precision damage. Used to also have a separate raycast-and-shoot
# precision-damage mode; dropped in favor of the bomb alone being the one
# showcase, and its own explosion covers the same "apply real damage to a
# static destructible" case a precise shot did (see apply_radial_damage()'s
# min/max radius -- a static prop within the blast radius takes damage same
# as one hit dead-on).
#
# The bomb can't reuse physx_playground.gd's own _blast() (RigidBody3D-only:
# `if col is RigidBody3D`) since a PhysXDestructible3D's pieces are raw
# PhysicsServer3D RIDs with no owning RigidBody3D node to match -- instead it
# calls apply_radial_damage() on every "destructible" group member at the
# explosion point. Only STATIC destructibles belong in that group -- dynamic
# ones already get real, physically-grounded breaking from their own
# _check_impact_fracture() the instant the ball collides with them, so
# putting one in the group too would apply this explosion damage on top of
# that, redundant at best (see destructible_demo.tscn's own staticsphere for
# the intended pattern: only it carries groups=["destructible"]).

const FlyCamera = preload("res://demo/common/fly_camera.gd")

@export var bomb_damage := 8.0
@export var bomb_min_radius := 0.5
@export var bomb_max_radius := 7.0
@export var bomb_speed := 45.0
@export var fly_speed := 8.0

var _fly: FlyCamera

func _ready() -> void:
	_fly = FlyCamera.new(self, fly_speed)

func _process(delta: float) -> void:
	_fly.process(delta)

func _unhandled_input(event: InputEvent) -> void:
	if _fly.handle_input(event):
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_fire_bomb()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

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

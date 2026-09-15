extends CharacterBody3D
# First-person rig for the PhysXDestructible3D showcase -- shares
# FirstPersonCharacter (see demo/common/first_person_character.gd) with
# physx_playground.gd, so walking into a destructible's pieces exercises the
# same push-on-collision path, and firing a ragdoll into debris gives a real
# CharacterBody3D-driven RigidBody3D to test collision layers/masks against
# instead of only the bomb.
#
#   WASD / arrows   move        SPACE  jump        mouse  look
#   left click      launch a ragdoll
#   right click     fire the bomb -- a real thrown RigidBody3D ball that
#                   explodes on contact -- for testing destructibles' impact/
#                   force response (knockback, getting knocked into each
#                   other), not just precision damage
#   ESC             release mouse / quit
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

const FirstPersonCharacter = preload("res://demo/common/first_person_character.gd")

@export var bomb_damage := 8.0
@export var bomb_min_radius := 0.5
@export var bomb_max_radius := 7.0
@export var bomb_speed := 45.0
@export var fly_speed := 8.0

var _fp: FirstPersonCharacter
@onready var _cam: Camera3D = $Camera3D

func _ready() -> void:
	_fp = FirstPersonCharacter.new(self, _cam, get_parent(), fly_speed)

func _physics_process(delta: float) -> void:
	_fp.physics_process(delta)

func _unhandled_input(event: InputEvent) -> void:
	if _fp.handle_input(event):
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_fp.fire_ragdoll()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_fire_bomb()

func _fire_bomb() -> void:
	var fwd := (-_cam.global_transform.basis.z).normalized()
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
	ball.global_position = _cam.global_position + fwd * 1.5
	ball.linear_velocity = fwd * bomb_speed
	ball.body_entered.connect(_on_bomb_hit.bind(ball), CONNECT_ONE_SHOT)

func _on_bomb_hit(_other: Node, ball: RigidBody3D) -> void:
	var center := ball.global_position
	for target in get_tree().get_nodes_in_group("destructible"):
		target.apply_radial_damage(center, bomb_damage, bomb_min_radius, bomb_max_radius)
	var t := get_tree().create_timer(0.05)
	t.timeout.connect(func() -> void: if is_instance_valid(ball): ball.queue_free())

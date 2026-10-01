extends Node3D
# Character cloth showcase: a MakeHuman monk whose robe is a PhysXSkinnedCloth3D
# (compute shaders, any GPU), running the Quaternius animation library around a
# circle so the robe reacts to real movement and turning, not just the
# animation in place.
#
#   1-7   idle / walk / jog / sprint / roll / spell / dance
#   C     cloth on/off (off = the plain skinned robe, for comparison)
#   M     move around the circle / stay in place
#   F     follow camera / free fly (WASD + hold RMB)
#   R     reset the cloth onto the animated pose

const ANIMS := [
	["Idle", 0.0],
	["Walk", 1.4],
	["Jog_Fwd", 3.2],
	["Sprint", 5.6],
	["Roll", 3.0],
	["Spell_Simple_Shoot", 0.0],
	["Dance", 0.0],
]

@export var circle_radius := 5.0
@export var start_animation := 2

@onready var _monk: Node3D = $Monk
@onready var _cam: Camera3D = $Camera3D
@onready var _hud: Label = $HUD/Label

var _ap: AnimationPlayer
var _cloth: PhysXSkinnedCloth3D
var _fly: FlyCamera
var _anim := 0
var _moving := true
var _follow := true
var _angle := 0.0

func _ready() -> void:
	# The monk and the animation library are both retargeted to Godot's
	# humanoid profile on import (see demo/common/monk/*_bonemap.tres); the
	# library's tracks address "Armature/GeneralSkeleton".
	_monk.get_node("Human_rig").name = "Armature"
	var ual := (load("res://demo/common/monk/ual_animations.glb") as PackedScene).instantiate()
	var lib: AnimationLibrary = (ual.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer).get_animation_library("")
	ual.free()
	_ap = AnimationPlayer.new()
	_monk.add_child(_ap)
	_ap.root_node = _ap.get_path_to(_monk)
	_ap.add_animation_library("", lib)

	_cloth = PhysXSkinnedCloth3D.new()
	_monk.add_child(_cloth)
	_cloth.pin_height = 1.15
	_cloth.max_distance = 0.25
	_cloth.body_mesh_path = _cloth.get_path_to(_monk.get_node("Armature/GeneralSkeleton/Human"))
	_cloth.mesh_instance_path = _cloth.get_path_to(_monk.get_node("Armature/GeneralSkeleton/Human_donitz_monk_robe"))

	_fly = FlyCamera.new(_cam)
	_play(start_animation)

func _play(i: int) -> void:
	_anim = clampi(i, 0, ANIMS.size() - 1)
	_ap.play(ANIMS[_anim][0], 0.25)

func _process(delta: float) -> void:
	var speed: float = ANIMS[_anim][1] if _moving else 0.0
	if speed > 0.0:
		_angle += speed * delta / circle_radius
	var pos := Vector3(cos(_angle), 0.0, sin(_angle)) * circle_radius
	var forward := Vector3(-sin(_angle), 0.0, cos(_angle)) # direction of travel (counter-clockwise from above)
	_monk.global_position = pos if _moving else _monk.global_position
	if _moving:
		# glTF characters face +Z.
		_monk.global_basis = Basis.looking_at(-forward, Vector3.UP)

	if _follow:
		var side := _monk.global_basis.x
		var target := _monk.global_position + Vector3(0, 1.0, 0)
		var eye := target - _monk.global_basis.z * 2.2 + side * 2.0 + Vector3(0, 0.6, 0)
		_cam.global_position = _cam.global_position.lerp(eye, clampf(delta * 4.0, 0.0, 1.0))
		_cam.look_at(target)
		_fly.yaw = _cam.rotation.y
		_fly.pitch = _cam.rotation.x
	else:
		_fly.process(delta)

	_hud.text = "Character cloth -- PhysXSkinnedCloth3D (compute shaders, any GPU)\n1-7 animation   C cloth on/off   M move/stay   F follow/fly (WASD + RMB)   R reset\n%s   cloth %s   %d particles   FPS %d" % [
		ANIMS[_anim][0], "ON" if _cloth.simulating and _cloth.is_inside_tree() else "OFF", _cloth.get_particle_count(), Engine.get_frames_per_second()]

func _unhandled_input(event: InputEvent) -> void:
	if not _follow and _fly.handle_input(event):
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var k := (event as InputEventKey).keycode
		if k >= KEY_1 and k <= KEY_7:
			_play(k - KEY_1)
		elif k == KEY_C:
			_toggle_cloth()
		elif k == KEY_M:
			_moving = not _moving
		elif k == KEY_F:
			_follow = not _follow
		elif k == KEY_R:
			_cloth.reset()

func _toggle_cloth() -> void:
	# Off: take the cloth node out (the skinned robe shows again); on: put it
	# back, which rebuilds it on the animated pose.
	if _cloth.is_inside_tree():
		_monk.remove_child(_cloth)
	else:
		_monk.add_child(_cloth)

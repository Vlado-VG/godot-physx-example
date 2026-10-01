extends Node3D
# Character cloth showcase: a MakeHuman character whose garment is a PhysXSkinnedCloth3D
# (compute shaders, any GPU), running the Quaternius animation library around a
# circle so the cloth reacts to real movement and turning, not just the
# animation in place.
#
#   1-7   idle / walk / jog / sprint / roll / spell / dance
#   C     cloth on/off (off = the plain skinned garment, for comparison)
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
## The character (an imported MakeHuman glTF with a PhysXSkinnedCloth3D child).
@export var character: Node3D
@onready var _cam: Camera3D = $Camera3D
@onready var _hud: Label = $HUD/Label

var _ap: AnimationPlayer
var _cloth: PhysXSkinnedCloth3D
var _fly: FlyCamera
var _anim := 0
var _moving := true
var _follow := true
var _angle := 0.0

var _character: Node3D

func _ready() -> void:
	_character = character
	# The characters and the animation library are all retargeted to Godot's
	# humanoid profile on import (see demo/common/monk/*_bonemap.tres). The
	# library's tracks address "Armature/GeneralSkeleton"; the MakeHuman rig
	# is "Human_rig", so point the tracks at it.
	var ual := (load("res://demo/common/monk/ual_animations.glb") as PackedScene).instantiate()
	var lib: AnimationLibrary = (ual.find_children("*", "AnimationPlayer", true, false)[0] as AnimationPlayer).get_animation_library("")
	ual.free()
	for anim_name in lib.get_animation_list():
		var anim := lib.get_animation(anim_name)
		for t in anim.get_track_count():
			var path := String(anim.track_get_path(t))
			if path.begins_with("Armature/"):
				anim.track_set_path(t, NodePath("Human_rig/" + path.trim_prefix("Armature/")))
	_ap = AnimationPlayer.new()
	_character.add_child(_ap)
	_ap.root_node = _ap.get_path_to(_character)
	_ap.add_animation_library("", lib)

	# The cloth node is in the scene so its max distances can be painted in
	# the editor (select Monk/Cloth, then Paint Cloth in the 3D toolbar): a
	# height ramp for the skirt, plus loose cuffs so the sleeves hang.
	_cloth = _character.find_children("*", "PhysXSkinnedCloth3D", false, false)[0]

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
	_character.global_position = pos if _moving else _character.global_position
	if _moving:
		# glTF characters face +Z.
		_character.global_basis = Basis.looking_at(-forward, Vector3.UP)

	if _follow:
		var side := _character.global_basis.x
		var target := _character.global_position + Vector3(0, 1.0, 0)
		var eye := target - _character.global_basis.z * 2.2 + side * 2.0 + Vector3(0, 0.6, 0)
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
		_character.remove_child(_cloth)
	else:
		_character.add_child(_cloth)

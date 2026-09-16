extends Node3D

# Vehicle2 test-day scene: ESC quits; the crate wall, slalom pylons and the
# loop-the-loop are spawned here so the scene file stays readable. The car,
# level layout and HUD are node-authored in vehicle.tscn / vehicle_car.tscn.

const CRATE_SIZE := 0.7
const CRATE_MASS := 15.0

# Loop-the-loop (GTA Online stunt-track style): a circle of box segments on
# the east straight. The car must carry enough speed to keep the wheels pinned
# to the loop's inside ("floor") over the top, else it drops head-first.
# r = 10 m needs v_top >= sqrt(g*r) ~ 9.9 m/s -> ~22 m/s at the bottom with
# zero losses; curve-entry scrub pushes the real requirement to ~100 km/h.
const LOOP_RADIUS := 10.0
const LOOP_SEGMENTS := 24
const LOOP_WIDTH := 8.0
const LOOP_CENTER := Vector3(24.0, LOOP_RADIUS - 0.25, -50.0)  # -0.25: road surface flush with ground

@onready var _crate_mat := preload("res://demo/common/materials/crate_material.tres")
@onready var _loop_mat := preload("res://demo/common/materials/loop_material.tres")


func _ready() -> void:
	_spawn_crate_wall()
	_spawn_slalom()
	_spawn_loop()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		get_tree().quit()


## Stacked crate wall to plow through (east side of the start straight).
func _spawn_crate_wall() -> void:
	for ix in 3:
		for iy in 4:
			var crate := RigidBody3D.new()
			crate.mass = CRATE_MASS
			crate.position = Vector3(11.3 + ix * (CRATE_SIZE + 0.05),
					CRATE_SIZE * 0.5 + iy * CRATE_SIZE, -10.0)
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3.ONE * CRATE_SIZE
			cs.shape = shape
			crate.add_child(cs)
			var mi := MeshInstance3D.new()
			var mesh := BoxMesh.new()
			mesh.size = Vector3.ONE * CRATE_SIZE
			mi.mesh = mesh
			mi.material_override = _crate_mat
			crate.add_child(mi)
			$Props.add_child(crate)


## Slalom pylons on the west side, alternating left/right.
func _spawn_slalom() -> void:
	for i in 5:
		var pylon := StaticBody3D.new()
		pylon.position = Vector3(-16.0 + (i % 2) * 4.0, 0.55, -2.0 - i * 4.0)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.35, 1.1, 0.35)
		cs.shape = shape
		pylon.add_child(cs)
		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.35, 1.1, 0.35)
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.75, 0.15)
		mi.material_override = mat
		pylon.add_child(mi)
		$Props.add_child(pylon)


## The loop: a ring of box segments whose INNER faces are the driving surface.
## Angle 0 is the bottom of the circle (tangent to the ground, car passes
## through moving -Z), the top is 2*r up. The two low segments on the entry
## side are OMITTED: they would wall the entrance off (the car would smash
## into the ring's outer face). The gap lets the car drive into the ring's
## interior, get caught by the far arm's rising inside surface, and follow it
## around. Entering too slow means gravity wins somewhere past the apex —
## the car drops inside the loop, head first.
const LOOP_DOOR_DEG := Vector2(322.0, 348.0)  # omitted arc, entry side
func _spawn_loop() -> void:
	var seg_len := TAU * LOOP_RADIUS / LOOP_SEGMENTS
	for i in LOOP_SEGMENTS:
		var a := TAU * i / LOOP_SEGMENTS
		var deg := rad_to_deg(a)
		if deg >= LOOP_DOOR_DEG.x and deg < LOOP_DOOR_DEG.y:
			continue
		# Center-pointing normal (the driving surface faces the circle center).
		var normal := Vector3(0.0, cos(a), sin(a))
		# Tangent along the direction of travel (entry moves -Z at the bottom).
		var tangent := Vector3(0.0, sin(a), -cos(a))
		var pos := LOOP_CENTER - normal * LOOP_RADIUS
		var seg := StaticBody3D.new()
		seg.transform = Transform3D(Basis(normal.cross(tangent), normal, tangent), pos)
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(LOOP_WIDTH, 0.5, seg_len * 1.12)  # overlap hides seams
		cs.shape = shape
		seg.add_child(cs)
		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = shape.size
		mi.mesh = mesh
		mi.material_override = _loop_mat
		seg.add_child(mi)
		$Props.add_child(seg)
	var sign_l := Label3D.new()
	sign_l.text = "LOOP\nenter at 110+ km/h"
	sign_l.font_size = 220
	sign_l.outline_size = 24
	sign_l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign_l.position = Vector3(LOOP_CENTER.x + 8.0, 3.0, LOOP_CENTER.z + 16.0)
	add_child(sign_l)

extends SceneTree

# U20: which bodies an Area3D detects. Each area watches one body that moves into
# it: a CharacterBody3D (move_and_slide), an AnimatableBody3D, a RigidBody3D
# frozen kinematic, a RigidBody3D (control) -- and a StaticBody3D placed inside.
# Also MOVING areas (hitboxes) sweeping over still bodies of each kind. As Godot
# Physics and Jolt: every kind is detected, static bodies included (PhysX areas
# were static actors, and PhysX never pairs two statics).

var _rows := []
var _t := 0
var _ok := true


func _check(cond: bool, msg: String) -> void:
	print("[area_kin] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _box(size: Vector3) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	cs.shape = b
	return cs


func _area(x: float) -> Area3D:
	var a := Area3D.new()
	a.position = Vector3(x, 1, 0)
	a.add_child(_box(Vector3(2, 2, 2)))
	get_root().add_child(a)
	return a


func _row(kind: String, x: float, body: Node3D, want: bool) -> void:
	var a := _area(x)
	var row := {"kind": kind, "area": a, "body": body, "want": want, "entered": false}
	a.body_entered.connect(func(b: Node) -> void:
		if b == body:
			row.entered = true)
	_rows.append(row)


func _initialize() -> void:
	print("[area_kin] engine: %s" % ProjectSettings.get_setting("physics/3d/physics_engine"))
	var ch := CharacterBody3D.new()
	ch.position = Vector3(0, 1, 4)
	ch.add_child(_box(Vector3(0.6, 1.6, 0.6)))
	get_root().add_child(ch)
	_row("CharacterBody3D", 0, ch, true)

	var an := AnimatableBody3D.new()
	an.sync_to_physics = false
	an.position = Vector3(6, 1, 4)
	an.add_child(_box(Vector3(0.6, 0.6, 0.6)))
	get_root().add_child(an)
	_row("AnimatableBody3D", 6, an, true)

	var fr := RigidBody3D.new()
	fr.freeze = true
	fr.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	fr.position = Vector3(12, 1, 4)
	fr.add_child(_box(Vector3(0.6, 0.6, 0.6)))
	get_root().add_child(fr)
	_row("RigidBody3D frozen kinematic", 12, fr, true)

	var rb := RigidBody3D.new()
	rb.gravity_scale = 0.0
	rb.position = Vector3(18, 1, 4)
	rb.add_child(_box(Vector3(0.6, 0.6, 0.6)))
	get_root().add_child(rb)
	_row("RigidBody3D", 18, rb, true)

	var st := StaticBody3D.new()
	st.position = Vector3(24, 1, 0)
	st.add_child(_box(Vector3(0.6, 0.6, 0.6)))
	get_root().add_child(st)
	_row("StaticBody3D inside", 24, st, true)

	# A moving area (hitbox) sweeping over a resting rigid body.
	var target := RigidBody3D.new()
	target.gravity_scale = 0.0
	target.position = Vector3(30, 1, 0)
	target.add_child(_box(Vector3(0.6, 0.6, 0.6)))
	get_root().add_child(target)
	var hit := Area3D.new()
	hit.position = Vector3(30, 1, 4)
	hit.add_child(_box(Vector3(1, 1, 1)))
	get_root().add_child(hit)
	var hrow := {"kind": "moving Area3D over a RigidBody3D", "area": hit, "body": target, "want": true, "entered": false, "moves": true}
	hit.body_entered.connect(func(b: Node) -> void:
		if b == target:
			hrow.entered = true)
	_rows.append(hrow)

	# Moving areas (hitboxes) sweeping over still bodies of each other kind.
	var still := {
		"CharacterBody3D": CharacterBody3D.new(),
		"RigidBody3D frozen kinematic": RigidBody3D.new(),
		"StaticBody3D": StaticBody3D.new(),
	}
	var x := 36.0
	for kind in still:
		var body: PhysicsBody3D = still[kind]
		if body is RigidBody3D:
			(body as RigidBody3D).freeze = true
			(body as RigidBody3D).freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		body.position = Vector3(x, 1, 0)
		body.add_child(_box(Vector3(0.6, 0.6, 0.6)))
		get_root().add_child(body)
		var area := Area3D.new()
		area.position = Vector3(x, 1, 4)
		area.add_child(_box(Vector3(1, 1, 1)))
		get_root().add_child(area)
		var row := {"kind": "moving Area3D over a still " + kind, "area": area, "body": body, "want": true, "entered": false, "moves": true}
		area.body_entered.connect(func(b: Node) -> void:
			if b == body:
				row.entered = true)
		_rows.append(row)
		x += 6.0

	physics_frame.connect(_tick)


func _tick() -> void:
	_t += 1
	if _t > 10 and _t <= 70:
		# Everything moves 4 m toward -Z over 1 s.
		var step := Vector3(0, 0, -4.0 / 60.0)
		for r in _rows:
			var b: Node3D = r.body
			if r.get("moves", false):
				(r.area as Area3D).position += step
			elif b is CharacterBody3D:
				(b as CharacterBody3D).velocity = step * 60.0
				(b as CharacterBody3D).move_and_slide()
			elif b is AnimatableBody3D or (b is RigidBody3D and (b as RigidBody3D).freeze):
				b.position += step
			elif b is RigidBody3D:
				(b as RigidBody3D).linear_velocity = step * 60.0
	if _t == 90:
		for r in _rows:
			var overlap: bool = (r.area as Area3D).overlaps_body(r.body)
			_check(r.entered == r.want, "%s: body_entered %s (want %s), overlaps_body %s" % [r.kind, r.entered, r.want, overlap])
		print("[area_kin] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)

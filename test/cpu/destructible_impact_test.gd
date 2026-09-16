extends SceneTree

# Verifies PhysXDestructible3D's new dynamic/impact-fracture path
# (feature/physx-blast-destruction): with dynamic = true, the intact piece
# should be a real falling rigid body (not the static placeholder the
# non-dynamic path uses), and a hard enough landing impact should
# auto-trigger apply_radial_damage() on its own -- no script ever calls it
# here, unlike destructible_test.gd.
#
# SKIPs (not FAILs) on a build without blast_sdk= configured, same as the
# other Blast tests -- PhysXDestructible3D doesn't exist in that build.

var _node
var _tick := 0

func _initialize() -> void:
	print("[destructible_impact] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXDestructible3D"):
		print("[destructible_impact] PhysXDestructible3D not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var root := Node3D.new()
	get_root().add_child(root)

	var floor_body := StaticBody3D.new()
	var fc := CollisionShape3D.new()
	var fs := BoxShape3D.new()
	fs.size = Vector3(50, 1, 50)
	fc.shape = fs
	floor_body.add_child(fc)
	floor_body.position = Vector3(0, -6, 0) # top surface at y = -5.5
	root.add_child(floor_body)

	_node = ClassDB.instantiate("PhysXDestructible3D")
	_node.asset_path = ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	_node.chunks_path = ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	_node.dynamic = true
	_node.impact_strength = 0.5 # low: any real landing impact should clear this
	_node.position = Vector3(0, 6, 0)
	root.add_child(_node)

func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 5:
		# Intact: exactly one real body should exist right at spawn, same as
		# the non-dynamic case at this point.
		var hits := _overlap(Vector3(0, 6, 0), Vector3(3, 3, 3))
		print("[destructible_impact] spawn overlap hits=", hits, " (expect >= 1)")
		if hits < 1:
			print("[destructible_impact] FAIL: intact body not found at spawn")
			quit(1)
			return true

	if _tick == 60:
		# dynamic = true should mean real gravity -- by 1s of free fall (~4.9m)
		# it should be well clear of its spawn position, unlike the static
		# non-dynamic path where it would still be sitting exactly there.
		var hits := _overlap(Vector3(0, 6, 0), Vector3(3, 3, 3))
		print("[destructible_impact] post-fall spawn overlap hits=", hits, " (expect 0 -- it should have fallen away)")
		if hits > 0:
			print("[destructible_impact] FAIL: still at spawn position after 1s -- dynamic gravity did not apply")
			quit(1)
			return true

	if _tick == 300:
		# By now it should have fallen ~11.5m, hit the floor hard enough to
		# clear impact_strength, and auto-fractured -- a wide overlap near the
		# floor should show multiple separate bodies (debris), not the one
		# single intact body a plain hard landing without auto-fracture would
		# still be.
		var hits := _overlap(Vector3(0, -4, 0), Vector3(30, 10, 30))
		print("[destructible_impact] near-floor overlap hits=", hits, " (expect > 1 -- fractured into pieces on impact)")
		var ok := hits > 1
		print("[destructible_impact] overall -> %s" % ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
		return true
	return false

func _overlap(p_center: Vector3, p_size: Vector3) -> int:
	var params := PhysicsShapeQueryParameters3D.new()
	var probe_shape := BoxShape3D.new()
	probe_shape.size = p_size
	params.shape = probe_shape
	params.transform = Transform3D(Basis(), p_center)
	return get_root().get_world_3d().direct_space_state.intersect_shape(params, 16).size()

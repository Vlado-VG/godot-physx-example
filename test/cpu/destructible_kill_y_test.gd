extends SceneTree

# Verifies PhysXDestructible3D's kill_y cleanup: without it, debris that
# falls past the world (a miss, a hole, no floor at all) would simulate and
# consume memory forever, since fractured pieces are raw PhysicsServer3D
# RIDs with no owning Node a normal kill-floor Area3D could ever catch.
#
# SKIPs (not FAILs) on a build without blast_sdk= configured, same as the
# other Blast tests.

var _node
var _tick := 0

func _initialize() -> void:
	print("[destructible_kill_y] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXDestructible3D"):
		print("[destructible_kill_y] PhysXDestructible3D not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var root := Node3D.new()
	get_root().add_child(root)
	# Deliberately no floor -- pieces should fall straight through kill_y.

	_node = ClassDB.instantiate("PhysXDestructible3D")
	_node.asset_path = ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	_node.chunks_path = ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	_node.kill_y = -20.0
	_node.position = Vector3(0, 5, 0)
	root.add_child(_node)

func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 10:
		var spawned: int = _node.apply_radial_damage(Vector3(0, 5, 0), 5.0, 0.1, 3.0)
		print("[destructible_kill_y] apply_radial_damage spawned=", spawned, " (expect 8)")
		if spawned != 8:
			print("[destructible_kill_y] FAIL: expected 8 pieces")
			quit(1)
			return true

	if _tick == 30:
		var hits := _overlap(Vector3(0, 5, 0), Vector3(20, 20, 20))
		print("[destructible_kill_y] mid-fall overlap hits=", hits, " (expect > 0 -- still falling, not cleaned up yet)")
		if hits < 1:
			print("[destructible_kill_y] FAIL: pieces vanished before reaching kill_y")
			quit(1)
			return true

	if _tick == 300:
		# By now (5s of free fall with no floor) every piece should be well
		# past kill_y = -20 and freed -- nothing left anywhere nearby at all.
		var hits := _overlap(Vector3(0, -100, 0), Vector3(40, 400, 40))
		print("[destructible_kill_y] post-kill_y overlap hits=", hits, " (expect 0 -- all pieces freed)")
		var ok := hits == 0
		print("[destructible_kill_y] overall -> %s" % ("PASS" if ok else "FAIL"))
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

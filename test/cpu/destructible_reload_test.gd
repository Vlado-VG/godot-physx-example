extends SceneTree

# Verifies two related bugs found via real editor use (feature/physx-blast-
# destruction): (1) assigning blast_asset to a PhysXDestructible3D already
# inside the tree with nothing loaded yet (an "empty" node, or one whose
# initial load failed) did nothing until the scene was closed and reopened;
# (2) moving an already-spawned destructible didn't move its visual/physics
# piece. Both traced to the same root cause -- the property setters
# (set_blast_asset/set_asset_path/set_chunks_path) never re-triggered
# load+spawn, only NOTIFICATION_ENTER_WORLD did. Exercises the exact same
# C++ path (_reload()) a real editor run does; only physics-body creation is
# is_editor_hint()-gated, not the load/spawn logic itself, so a plain
# headless run (is_editor_hint() == false, so it DOES get a real body) is a
# valid, stronger test -- verifiable via overlap queries instead of pixels.
#
# SKIPs (not FAILs) on a build without blast_sdk= configured, same as the
# other Blast tests.

var _node
var _tick := 0

func _initialize() -> void:
	print("[destructible_reload] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXDestructible3D") or not ClassDB.class_exists("PhysXBlastAuthoring"):
		print("[destructible_reload] Blast classes not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var root := Node3D.new()
	get_root().add_child(root)

	# Empty -- no asset_path/chunks_path/blast_asset set at all, matching a
	# freshly-created node in an open scene before anything is assigned.
	_node = ClassDB.instantiate("PhysXDestructible3D")
	_node.position = Vector3(0, 5, 0)
	root.add_child(_node)

func _physics_process(_delta: float) -> bool:
	_tick += 1

	if _tick == 5:
		var hits := _overlap(Vector3(0, 5, 0))
		print("[destructible_reload] empty-node overlap hits=", hits, " (expect 0 -- nothing to spawn yet)")
		if hits != 0:
			print("[destructible_reload] FAIL: something spawned with no asset assigned")
			quit(1)
			return true

		# The reported bug: assign an asset to a node already in the tree
		# (the "drag a PhysXBlastAsset onto an empty PhysXDestructible3D"
		# workflow) and expect it to show up right away, not on next reopen.
		var box := BoxMesh.new()
		box.size = Vector3(1.5, 1.5, 1.5)
		var authoring = ClassDB.instantiate("PhysXBlastAuthoring")
		var asset = authoring.fracture_mesh(box, 8, 3)
		if asset == null:
			print("[destructible_reload] FAIL: fracture_mesh failed")
			quit(1)
			return true
		_node.blast_asset = asset

	if _tick == 10:
		var hits := _overlap(Vector3(0, 5, 0))
		print("[destructible_reload] post-assign overlap hits=", hits, " (expect >= 1 -- should appear immediately, no reopen needed)")
		if hits < 1:
			print("[destructible_reload] FAIL: assigning blast_asset to an already-in-tree node did not spawn anything")
			quit(1)
			return true

		# The other reported bug: moving it afterward should move the spawned
		# piece too, live -- not require a reopen either.
		_node.position = Vector3(10, 5, 0)

	if _tick == 15:
		var old_pos_hits := _overlap(Vector3(0, 5, 0))
		var new_pos_hits := _overlap(Vector3(10, 5, 0))
		print("[destructible_reload] after move: old_pos hits=", old_pos_hits, " new_pos hits=", new_pos_hits, " (expect 0 / >=1)")
		var ok := old_pos_hits == 0 and new_pos_hits >= 1
		print("[destructible_reload] overall -> %s" % ("PASS" if ok else "FAIL"))
		quit(0 if ok else 1)
		return true
	return false

func _overlap(p_center: Vector3) -> int:
	var params := PhysicsShapeQueryParameters3D.new()
	var probe_shape := BoxShape3D.new()
	probe_shape.size = Vector3(3, 3, 3)
	params.shape = probe_shape
	params.transform = Transform3D(Basis(), p_center)
	return get_root().get_world_3d().direct_space_state.intersect_shape(params, 8).size()

extends SceneTree

# Verifies the Blast runtime-bridge MVP (feature/physx-blast-destruction):
# GodotPhysXBlastProbe loads a real Blast asset (a cube Voronoi-fractured
# into 8 chunks, authored offline by the module's throwaway blast_test_gen
# tool -- see test/data/blast_cube.asset/.chunks), applies radial damage
# covering the whole thing, and should split into 8 real rigid bodies, one
# per leaf chunk, each with a real convex collision shape cooked from that
# chunk's render-mesh points via the normal PhysicsServer3D path.
#
# This only builds/runs when the engine was compiled with blast_sdk= set
# (GodotPhysXBlastProbe doesn't exist in a build without it) -- SKIP, not
# FAIL, if the class isn't registered, so this test doesn't break a normal
# PhysX-only build.

func _initialize() -> void:
	print("[blast_probe] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("GodotPhysXBlastProbe"):
		print("[blast_probe] GodotPhysXBlastProbe not registered (build without blast_sdk=) -> SKIP")
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
	floor_body.position = Vector3(0, -5, 0)
	root.add_child(floor_body)

	var probe = ClassDB.instantiate("GodotPhysXBlastProbe")
	probe.set_space(get_root().get_world_3d().space)
	probe.set_base_transform(Transform3D(Basis(), Vector3(0, 5, 0)))
	probe.set_base_velocity(Vector3.ZERO)

	var asset_path := ProjectSettings.globalize_path("res://test/data/blast_cube.asset")
	var chunks_path := ProjectSettings.globalize_path("res://test/data/blast_cube.chunks")
	var loaded: bool = probe.load(asset_path, chunks_path)
	if not loaded:
		print("[blast_probe] load() failed -> FAIL")
		quit(1)
		return
	print("[blast_probe] loaded, live_actor_count=", probe.get_live_actor_count())

	# Overkill damage covering the whole 2x2x2 cube from its center -- see
	# the module's Blast planning notes for why damage=1.0 (exact 100% of
	# the bonds' initial health) was insufficient in the standalone prototype
	# despite reporting health=0.0; 5.0 reliably crosses whatever the real
	# break threshold is.
	var spawned: int = probe.apply_radial_damage(Vector3.ZERO, 5.0, 0.1, 3.0)
	print("[blast_probe] apply_radial_damage spawned=", spawned, " body_count=", probe.get_body_count())

	var ok: bool = spawned == 8 and probe.get_body_count() == 8
	if ok:
		# Confirm the spawned bodies are real, live PhysicsServer3D rigid
		# bodies with a sane transform (base_transform's translation, since
		# the probe places every new body there directly) -- not just RIDs
		# that happen to exist.
		for i in probe.get_body_count():
			var rid: RID = probe.get_body(i)
			var xform: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
			if xform.origin.distance_to(Vector3(0, 5, 0)) > 0.01:
				print("[blast_probe] body %d has unexpected transform %s -> FAIL" % [i, xform])
				ok = false

	print("[blast_probe] overall -> %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

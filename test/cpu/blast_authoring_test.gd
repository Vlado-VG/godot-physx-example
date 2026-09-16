extends SceneTree

# Verifies PhysXBlastAuthoring -- the real in-engine replacement for the
# standalone throwaway blast_test_gen.cpp tool this whole Blast effort
# prototyped with (feature/physx-blast-destruction, Phase 4 first step).
#
# Two levels of proof:
#  1. Fracture a BoxMesh in-engine, confirm the resulting PhysXBlastAsset has
#     the expected chunk count (9 = 1 root + 8 leaves, same params the
#     standalone tool used to produce test/data/blast_cube.asset), and that
#     it survives a real Resource save/load round-trip.
#  2. Feed the SAME in-memory result through GodotPhysXBlastProbe (dumping it
#     to temp files in the exact format that class already parses) and run
#     the identical damage -> fracture -> split -> 8-bodies check
#     blast_probe_test.gd already proves against the pre-authored asset --
#     confirming the in-engine authoring path produces genuinely valid data,
#     not just plausible-looking bytes.
#
# SKIPs (not FAILs) on a build without blast_sdk= configured.

func _initialize() -> void:
	print("[blast_authoring] engine = ", ProjectSettings.get_setting("physics/3d/physics_engine", "?"))

	if not ClassDB.class_exists("PhysXBlastAuthoring"):
		print("[blast_authoring] PhysXBlastAuthoring not registered (build without blast_sdk=) -> SKIP")
		quit(0)
		return

	var box := BoxMesh.new()
	box.size = Vector3(2, 2, 2)

	var authoring = ClassDB.instantiate("PhysXBlastAuthoring")
	var asset = authoring.fracture_mesh(box, 8, 42)
	if asset == null:
		print("[blast_authoring] fracture_mesh returned null -> FAIL")
		quit(1)
		return

	var chunk_count: int = asset.get_chunk_count()
	var asset_bytes: PackedByteArray = asset.asset_bytes
	print("[blast_authoring] chunk_count=", chunk_count, " asset_bytes=", asset_bytes.size(), " bytes")
	if chunk_count != 9 or asset_bytes.is_empty():
		print("[blast_authoring] FAIL: expected chunk_count=9 and non-empty asset_bytes")
		quit(1)
		return

	# Resource save/load round-trip.
	var save_path := "user://blast_authoring_test.tres"
	var save_err := ResourceSaver.save(asset, save_path)
	if save_err != OK:
		print("[blast_authoring] ResourceSaver.save failed: ", save_err, " -> FAIL")
		quit(1)
		return
	var reloaded = ResourceLoader.load(save_path)
	if reloaded == null or reloaded.get_chunk_count() != chunk_count:
		print("[blast_authoring] FAIL: round-tripped resource doesn't match (chunk_count=",
				(reloaded.get_chunk_count() if reloaded else -1), ")")
		quit(1)
		return
	print("[blast_authoring] resource round-trip OK (chunk_count=", reloaded.get_chunk_count(), ")")

	# Full end-to-end proof: dump this in-engine-authored asset into the same
	# two-file format GodotPhysXBlastProbe already parses, and run the exact
	# same damage/split/spawn check blast_probe_test.gd proves against the
	# pre-authored blast_cube.asset -- confirms the DATA is really valid, not
	# just correctly-shaped.
	var asset_path := "user://blast_authoring_test.asset"
	var af := FileAccess.open(asset_path, FileAccess.WRITE)
	af.store_buffer(reloaded.asset_bytes)
	af.close()

	var chunks_path := "user://blast_authoring_test.chunks"
	var cf := FileAccess.open(chunks_path, FileAccess.WRITE)
	var chunk_points: Array = reloaded.chunk_points
	cf.store_line("chunks %d" % chunk_points.size())
	for i in chunk_points.size():
		var points: PackedVector3Array = chunk_points[i]
		var tri_count := points.size() / 3
		cf.store_line("chunk %d %d" % [i, tri_count])
		for t in tri_count:
			var a := points[t * 3 + 0]
			var b := points[t * 3 + 1]
			var c := points[t * 3 + 2]
			cf.store_line("%f %f %f %f %f %f %f %f %f" % [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z])
	cf.close()

	var root := Node3D.new()
	get_root().add_child(root)
	var probe = ClassDB.instantiate("GodotPhysXBlastProbe")
	probe.set_space(get_root().get_world_3d().space)
	probe.set_base_transform(Transform3D(Basis(), Vector3(0, 5, 0)))
	var globalized_asset := ProjectSettings.globalize_path(asset_path)
	var globalized_chunks := ProjectSettings.globalize_path(chunks_path)
	print("[blast_authoring] loading probe from: ", globalized_asset, " / ", globalized_chunks)
	if not probe.load(globalized_asset, globalized_chunks):
		print("[blast_authoring] probe.load() of the in-engine-authored dump failed -> FAIL")
		quit(1)
		return
	print("[blast_authoring] probe loaded, live_actor_count=", probe.get_live_actor_count())
	# GodotPhysXBlastProbe's damage position is LOCAL-space (unlike
	# PhysXDestructible3D's, which converts world->local internally) --
	# base_transform only places spawned bodies in world space. Vector3.ZERO
	# here, same as blast_probe_test.gd, not the world spawn position.
	var spawned: int = probe.apply_radial_damage(Vector3.ZERO, 5.0, 0.1, 3.0)
	print("[blast_authoring] end-to-end probe test: spawned=", spawned, " body_count=", probe.get_body_count())

	var ok: bool = spawned == 8 and probe.get_body_count() == 8
	print("[blast_authoring] overall -> %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

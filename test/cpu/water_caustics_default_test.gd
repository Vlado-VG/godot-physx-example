extends SceneTree

# PhysXWaterSurface3D.caustics_enabled defaults to false (R14: the pass draws every
# frame, so it's opt-in), and the demo scenes that show caustics turn it on
# explicitly. Scenes are only instantiated, never added to the tree, so this
# runs headless.

const CAUSTIC_SCENES := [
	"res://demo/editor/cpu/beach.tscn",
	"res://demo/editor/cpu/lake.tscn",
	"res://demo/editor/cpu/round_pool.tscn",
]


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXWaterSurface3D"):
		print("[caustics_default] PhysXWaterSurface3D not registered -> SKIP")
		quit(0)
		return
	var ok := true
	var fresh: Node = ClassDB.instantiate("PhysXWaterSurface3D")
	ok = _check("a new surface has caustics off", fresh.get("caustics_enabled") == false) and ok
	fresh.free()
	for path in CAUSTIC_SCENES:
		var scene := (load(path) as PackedScene).instantiate()
		var water := scene.find_child("Water", true, false)
		ok = _check("%s turns caustics on" % path.get_file(), water != null and water.get("caustics_enabled") == true) and ok
		scene.free()
	print("[caustics_default] -> %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


func _check(what: String, cond: bool) -> bool:
	print("[caustics_default]   %s: %s" % [what, "ok" if cond else "FAILED"])
	return cond

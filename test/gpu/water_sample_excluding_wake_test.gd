extends SceneTree

# PhysXWaterSurface3D.sample_height_excluding_wake(world_pos, wake) (R8). The demo
# boat is pushed along on still water so its PhysXWaterWake3D builds a dip and bow
# wave; around the hull, leaving that wake out must change the height, passing
# null must give exactly sample_height(), and far from the boat they all agree.
# Needs a windowed run (the water and wake simulate on the GPU).

const SPEED := 6.0

var _water: Node3D
var _boat: RigidBody3D
var _wake: Node
var _tick := 0


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXWaterSurface3D", "sample_height_excluding_wake"):
		print("[excl_wake] PhysXWaterSurface3D has no sample_height_excluding_wake -> FAIL")
		quit(1)
		return
	var root := Node3D.new()
	root.name = "Root"
	get_root().add_child(root)
	_water = ClassDB.instantiate("PhysXWaterSurface3D")
	_water.name = "Water"
	_water.set("domain_size", Vector2(60, 60))
	_water.set("wave_amplitude", 0.0) # still water: any difference is the wake
	root.add_child(_water)
	_boat = (load("res://demo/common/boat/boat.tscn") as PackedScene).instantiate()
	_boat.set_script(null) # no player controller; the test pushes it
	_boat.position = Vector3(0, 0.3, -15)
	root.add_child(_boat)
	_boat.get_node("Buoyancy").set("water_surface_path", NodePath("../../Water"))
	_wake = _boat.get_node("Wake")


func _physics_process(_d: float) -> bool:
	if _boat == null:
		return true
	_tick += 1
	# Hold the boat on a straight course at SPEED along +Z (its forward).
	var v := _boat.linear_velocity
	_boat.linear_velocity = Vector3(0.0, v.y, SPEED)
	if _tick == 180:
		var pos := _boat.global_position
		var fwd := _boat.global_basis.z
		var side := _boat.global_basis.x
		var biggest := 0.0
		var null_same := true
		for along in [-2.0, -1.0, 0.0, 1.0, 2.0, 3.0]:
			for across in [-1.0, 0.0, 1.0]:
				var p: Vector3 = pos + fwd * along + side * across
				var all: float = _water.sample_height(p)
				var ex: float = _water.sample_height_excluding_wake(p, _wake)
				biggest = maxf(biggest, absf(all - ex))
				null_same = null_same and is_equal_approx(all, _water.sample_height_excluding_wake(p, null))
		var far := pos + side * 25.0
		var far_diff := absf(_water.sample_height(far) - _water.sample_height_excluding_wake(far, _wake))
		var ok := biggest > 0.02 and null_same and far_diff < 0.001
		print("[excl_wake] boat at %s  wake's share near the hull up to %.3f m (want > 0.02)  null == sample_height: %s  25 m off to the side: %.4f -> %s" % [
			pos, biggest, null_same, far_diff, "PASS" if ok else "FAIL"])
		quit(0 if ok else 1)
	return false

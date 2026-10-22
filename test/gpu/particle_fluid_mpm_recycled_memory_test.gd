extends SceneTree

# An MPM fluid spawned after a scene was instantiated and freed keeps running.
# The block-sparse passes' indirect dispatch used to read its group count
# without a barrier against the pass that wrote it; on the first step it read
# whatever the buffer's memory held before -- here, the freed scene's -- and the
# GPU ran a near-endless dispatch (the frames stopped). Which memory comes back
# depends on the GPU, the driver and the window's size at startup (on an
# RTX 5070 / D3D12, 960x540 hung and 1280x720 didn't), so the test reruns itself
# in a child process started at 960x540; a pass elsewhere proves less than a fail.
# Needs a window (the MPM solver runs on the GPU):
#   godot --path . --script res://test/gpu/particle_fluid_mpm_recycled_memory_test.gd

const FRAMES := 160
const WATCHDOG_MSEC := 30000

var _t := 0
var _fluid: Node3D
var _watchdog := Thread.new()
var _done := false


func _watch() -> void:
	var start := Time.get_ticks_msec()
	while not _done:
		if Time.get_ticks_msec() - start > WATCHDOG_MSEC:
			printerr("[mpm_recycled] FAIL frames stopped at %d of %d (GPU hang)" % [_t, FRAMES])
			OS.kill(OS.get_process_id())
		OS.delay_msec(200)


func _initialize() -> void:
	if not ("child" in OS.get_cmdline_user_args()):
		var out := []
		var code := OS.execute(OS.get_executable_path(), ["--path", ProjectSettings.globalize_path("res://"), "--resolution", "960x540", "--script", "res://test/gpu/particle_fluid_mpm_recycled_memory_test.gd", "--", "child"], out, true)
		# The watchdog's kill exits 0 on Windows: the child's own PASS line decides.
		var ok := false
		for line in "".join(out).split("\n"):
			if line.begins_with("[mpm_recycled]"):
				print("  child: ", line.strip_edges())
				ok = ok or line.strip_edges() == "[mpm_recycled] PASS"
		ok = ok and code == 0
		print("[mpm_recycled] ", "PASS" if ok else "FAIL")
		quit(0 if ok else 1)
		return
	# Stock content, instantiated and freed outside the tree.
	var debris := (load("res://demo/editor/fluid/debris.tscn") as PackedScene).instantiate()
	for c in debris.get_children():
		if not (String(c.name) in ["WorldEnvironment", "Sun", "Camera3D", "Ground", "BackWall", "LeftWall", "RightWall"]):
			debris.remove_child(c)
			c.free()
	debris.free()

	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	get_root().add_child(floor_body)
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor_mesh.mesh = pm
	get_root().add_child(floor_mesh)
	_fluid = ClassDB.instantiate("PhysXParticleFluid3D")
	_fluid.set("solver", 2)
	_fluid.set("particle_size", 0.04)
	_fluid.set("spawn_on_ready", false)
	_fluid.set("spawn_region_size", Vector3(0.8, 0.4, 0.8))
	_fluid.set("mpm_auto_colliders", true)
	_fluid.position = Vector3(0, 0.3, 0)
	get_root().add_child(_fluid)
	var cam := Camera3D.new()
	get_root().add_child(cam)
	cam.look_at_from_position(Vector3(0, 1.5, 2.5), Vector3(0, 0.2, 0))
	_watchdog.start(_watch)
	process_frame.connect(_frame)


func _frame() -> void:
	_t += 1
	if _t == 20:
		_fluid.call("spawn")
	if _t == FRAMES:
		var live := int(_fluid.call("get_live_particle_count"))
		var ok := live > 0
		print("[mpm_recycled] %s %d frames after spawn, %d particles live" % ["ok  " if ok else "FAIL", FRAMES - 20, live])
		print("[mpm_recycled] ", "PASS" if ok else "FAIL")
		_done = true
		_watchdog.wait_to_finish()
		quit(0 if ok else 1)

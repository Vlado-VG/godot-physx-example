extends SceneTree

# PhysXParticleFluid3D.render_mode (Particles / Isosurface / Screen Space):
#   a scene saved before render_mode (surface_mesh = true) loads as Isosurface;
#   render_mode round-trips, and surface_mesh is no longer written when saving;
#   a Screen Space fluid draws: where its block of particles sits, the frame
#   changes once it is spawned.
# Needs a window (the MPM solver and the screen-space pass run on the GPU):
#   godot --path . --script res://test/gpu/fluid_render_mode_test.gd

var _t := 0
var _ok := true
var _fluid: Node3D
var _cam: Camera3D
var _before := Color()
var _px := Vector2i()


func _check(cond: bool, msg: String) -> void:
	print("[render_mode] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _initialize() -> void:
	if not ClassDB.class_has_method("PhysXParticleFluid3D", "set_render_mode"):
		print("[render_mode] SKIP: this engine build has no fluid render modes yet")
		quit(0)
		return
	# An old scene, as saved before render_mode: surface_mesh = true.
	var f := FileAccess.open("user://old_fluid.tscn", FileAccess.WRITE)
	f.store_string('[gd_scene format=3]

[node name="Root" type="Node3D"]

[node name="Fluid" type="PhysXParticleFluid3D" parent="."]
surface_mesh = true
')
	f.close()
	var old: Node = (ResourceLoader.load("user://old_fluid.tscn", "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	_check(int(old.get_node("Fluid").get("render_mode")) == 1, "an old surface_mesh = true scene loads as render_mode Isosurface")
	old.free()

	var probe: Node = ClassDB.instantiate("PhysXParticleFluid3D")
	for m in [2, 1, 0]:
		probe.set("render_mode", m)
		_check(int(probe.get("render_mode")) == m, "render_mode round-trips (%d)" % m)
	probe.set("render_mode", 1)
	var holder := Node3D.new()
	holder.add_child(probe)
	probe.owner = holder
	var packed := PackedScene.new()
	packed.pack(holder)
	var state := packed.get_state()
	var saved := []
	for i in state.get_node_property_count(1):
		saved.append(state.get_node_property_name(1, i))
	_check("render_mode" in saved and not ("surface_mesh" in saved), "saving writes render_mode, not surface_mesh (saved: %s)" % [saved])
	holder.free()

	# A live screen-space fluid.
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
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	get_root().add_child(sun)
	_fluid = ClassDB.instantiate("PhysXParticleFluid3D")
	_fluid.set("solver", 2)
	_fluid.set("render_mode", 2) # Screen Space
	_fluid.set("particle_size", 0.04)
	_fluid.set("spawn_on_ready", false)
	_fluid.set("spawn_region_size", Vector3(0.8, 0.4, 0.8))
	_fluid.set("mpm_domain_size", Vector3(4, 0.6, 4)) # its implicit floor: spawn y - 0.3 = the ground
	_fluid.position = Vector3(0, 0.3, 0)
	get_root().add_child(_fluid)
	_cam = Camera3D.new()
	get_root().add_child(_cam)
	_cam.look_at_from_position(Vector3(0, 1.5, 2.5), Vector3(0, 0.2, 0))
	process_frame.connect(_frame)


# The frame's colour where the fluid sits (unproject_position works in the
# window's logical size, which needn't match the captured image's).
func _sample() -> Color:
	var img := get_root().get_texture().get_image()
	var uv := _cam.unproject_position(Vector3(0, 0.1, 0)) / get_root().get_visible_rect().size
	_px = Vector2i(uv * Vector2(img.get_size()))
	return img.get_pixelv(_px)


func _frame() -> void:
	_t += 1
	if _t == 20:
		_before = _sample()
		_fluid.call("spawn")
	if _t == 140:
		var after := _sample()
		var diff := absf(after.r - _before.r) + absf(after.g - _before.g) + absf(after.b - _before.b)
		_check(diff > 0.05, "a Screen Space fluid (%d particles) draws where it sits (pixel %s: %s -> %s)" % [int(_fluid.call("get_live_particle_count")), _px, _before, after])
		get_root().get_texture().get_image().save_png("res://excluded/shots/fluid_render_mode_test.png")
		print("[render_mode] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)

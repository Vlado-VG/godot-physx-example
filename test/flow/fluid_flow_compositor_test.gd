extends SceneTree

# A screen-space PhysXParticleFluid3D and a PhysXFlow3D in one world:
#  - both draw, whichever is added first, with or without the user's own
#    Compositor (each used to overwrite the other's injection into it);
#  - the fluid runs first and Flow marches to its surface: smoke behind the
#    liquid is hidden, smoke in front of it draws over it;
#  - nothing is left installed once both are gone.
# The fluid is an opaque red MPM puddle (no CUDA needed). Needs a window:
#   godot --path . --script res://test/flow/fluid_flow_compositor_test.gd

const USER_EFFECT_SRC := """
extends CompositorEffect
var calls := 0
func _render_callback(_type: int, _data: RenderData) -> void:
	calls += 1
"""

var _pass := true
var _root: Node3D
var _cam: Camera3D
var _fluid: Node3D


func _initialize() -> void:
	create_timer(180.0).timeout.connect(func() -> void:
		print("[fluid-flow] FAIL: timed out")
		quit(1))
	if not ClassDB.class_exists("PhysXFlow3D"):
		print("[fluid-flow] SKIP: no Flow support in this build")
		quit(0)
		return
	_root = Node3D.new()
	get_root().add_child(_root)
	var floor_body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20, 1, 20)
	cs.shape = box
	floor_body.add_child(cs)
	floor_body.position = Vector3(0, -0.5, 0)
	_root.add_child(floor_body)
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(20, 20)
	floor_mesh.mesh = pm
	_root.add_child(floor_mesh)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	_root.add_child(sun)
	_cam = Camera3D.new()
	_root.add_child(_cam)
	_cam.look_at_from_position(Vector3(0, 1.2, 3.0), Vector3(0, 0.3, 0))
	_cam.make_current()
	_run.call_deferred()


func _check(label: String, ok: bool, detail: String = "") -> void:
	print("  [%s] %-58s %s" % ["ok" if ok else "FAIL", label, detail])
	if not ok:
		_pass = false


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _world_compositor() -> Compositor:
	return ClassDB.class_call_static("PhysXFlowRenderEffect", "get_world_compositor", _root.get_world_3d())


func _add_flow(z: float) -> Node3D:
	var f: Node3D = ClassDB.instantiate("PhysXFlow3D")
	_root.add_child(f)
	var e: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	e.velocity = Vector3(0, 1.5, 0)
	e.position = Vector3(0, 0, z)
	f.add_child(e)
	e.flow = NodePath("..")
	return f


func _add_fluid() -> void:
	_fluid = ClassDB.instantiate("PhysXParticleFluid3D")
	_fluid.set("solver", 2)
	_fluid.set("render_mode", 2) # Screen Space
	_fluid.set("particle_size", 0.04)
	_fluid.set("spawn_on_ready", false)
	_fluid.set("spawn_region_size", Vector3(0.8, 0.4, 0.8))
	_fluid.set("mpm_domain_size", Vector3(4, 0.6, 4)) # its implicit floor: the ground
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.8, 0.05, 0.05)
	_fluid.set("material_override", m)
	_fluid.position = Vector3(0, 0.3, 0)
	_root.add_child(_fluid)


# The frame where the puddle sits.
func _puddle() -> Color:
	var img := get_root().get_texture().get_image()
	var uv := _cam.unproject_position(Vector3(0, 0.03, 0)) / get_root().get_visible_rect().size
	return img.get_pixelv(Vector2i(uv * Vector2(img.get_size())))


func _red(c: Color) -> bool:
	return c.r - c.g > 0.25


func _draws_per_frame(flow: Node3D, n: int) -> float:
	# With rendering on its own thread the count runs up to a frame behind this one: wait for it at both ends.
	RenderingServer.force_sync()
	var before: int = flow.get_stats().render_calls
	await _frames(n)
	RenderingServer.force_sync()
	return float(flow.get_stats().render_calls - before) / n


func _run() -> void:
	await _frames(5)
	var user_script := GDScript.new()
	user_script.source_code = USER_EFFECT_SRC
	user_script.reload()
	var user_effect := CompositorEffect.new()
	user_effect.set_script(user_script)
	user_effect.effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	var user_compositor := Compositor.new()
	user_compositor.compositor_effects = [user_effect]
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.compositor = user_compositor
	_root.add_child(env)

	print("1) Flow first, then the fluid, on the user's compositor; smoke behind the puddle")
	var flow := _add_flow(-1.5)
	await _frames(5)
	_add_fluid()
	await _frames(10)
	_fluid.call("spawn")
	await _frames(140)
	var calls: int = user_effect.calls
	var rate := await _draws_per_frame(flow, 20)
	var behind := _puddle()
	_check("the fluid draws", _red(behind), "%s" % behind)
	_check("Flow draws once per frame", is_equal_approx(rate, 1.0), "%.2f" % rate)
	_check("the user's effect still runs", user_effect.calls > calls)
	_check("the user's effects array is untouched", user_compositor.compositor_effects.size() == 1)

	print("2) smoke in front of the puddle")
	flow.queue_free()
	flow = _add_flow(1.6)
	await _frames(100)
	rate = await _draws_per_frame(flow, 20)
	var front := _puddle()
	_check("Flow draws once per frame", is_equal_approx(rate, 1.0), "%.2f" % rate)
	_check("the smoke draws over the liquid", front.g > behind.g + 0.1, "%s -> %s" % [behind, front])

	print("3) no smoke")
	flow.queue_free()
	await _frames(30)
	var none := _puddle()
	var d := absf(none.r - behind.r) + absf(none.g - behind.g) + absf(none.b - behind.b)
	_check("the smoke behind the liquid was hidden", d < 0.05, "%s vs %s" % [behind, none])

	print("4) the user's compositor goes; a flow comes back")
	env.queue_free()
	await _frames(5)
	flow = _add_flow(-1.5)
	await _frames(60)
	rate = await _draws_per_frame(flow, 20)
	_check("the fluid draws", _red(_puddle()), "%s" % _puddle())
	_check("Flow draws once per frame", is_equal_approx(rate, 1.0), "%.2f" % rate)

	print("5) both gone")
	flow.queue_free()
	_fluid.queue_free()
	await _frames(10)
	_check("nothing left installed on the world", _world_compositor() == null)

	print("[fluid-flow] %s" % ("PASS" if _pass else "FAIL"))
	quit(0 if _pass else 1)

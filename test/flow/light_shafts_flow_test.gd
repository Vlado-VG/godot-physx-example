extends SceneTree

# PhysXLightShafts3D with PhysXFlow3D: glowing gas isn't the sun. A bright fire
# beside a low sun, on the sky to its left. The shafts take their light from
# the frame without the gas, so the fire doesn't stream out from the sun's
# place like sunlight: on the sky past the fire (on the line out from the sun)
# the shafts add no more than on the sky the same distance right of the sun,
# where there's no gas. Before, the fire's light was smeared along that line
# (a bright streak across the screen).
# Needs a window and a Flow build:
#   godot --path . --script res://test/flow/light_shafts_flow_test.gd

var _cam: Camera3D
var _shafts: Node3D
var _t := 0
var _ok := true
var _off: Image


func _check(cond: bool, msg: String) -> void:
	print("[shafts_flow] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXLightShafts3D") or not ClassDB.class_exists("PhysXFlowSimulation3D"):
		print("[shafts_flow] SKIP: no PhysXLightShafts3D / PhysXFlow3D")
		quit(0)
		return
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	we.environment = env
	get_root().add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-5, 180, 0) # low, ahead of the camera
	get_root().add_child(sun)
	_shafts = ClassDB.instantiate("PhysXLightShafts3D")
	_shafts.visible = false
	sun.add_child(_shafts)
	_cam = Camera3D.new()
	get_root().add_child(_cam)
	_cam.position = Vector3(0, 2, 0)

	# A fire left of the sun, glowing far brighter than the bloom threshold.
	var flow: Node3D = ClassDB.instantiate("PhysXFlowSimulation3D")
	flow.set("fire_emission", true)
	flow.set("fire_emission_strength", 20.0)
	flow.set("temperature_range", 1.04)
	flow.set("smoke_fade", 0.25)
	get_root().add_child(flow)
	var emitter: Node3D = ClassDB.instantiate("PhysXFlowEmitter3D")
	emitter.position = Vector3(-2.2, 2.0, -12)
	emitter.set("velocity", Vector3(0, 2, 0))
	emitter.set("temperature", 8.0)
	emitter.set("smoke", 9.4)
	flow.add_child(emitter)
	flow.emitters = [emitter.get_path()]
	process_frame.connect(_frame)


func _lum(img: Image, p: Vector2) -> float:
	var c := img.get_pixelv(Vector2i(p))
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _frame() -> void:
	_t += 1
	if _t == 300:
		_off = get_root().get_texture().get_image()
		_shafts.visible = true
	elif _t == 302:
		var on := get_root().get_texture().get_image()
		var h := float(get_root().get_visible_rect().size.y)
		var sun_px := _cam.unproject_position(_cam.position + Vector3(0, tan(deg_to_rad(5)), -1) * 100.0)
		var fire_px := _cam.unproject_position(Vector3(-2.2, 3.0, -12))
		# Past the fire on the line out from the sun, and its mirror right of the sun.
		var dir := (fire_px - sun_px).normalized()
		var past := sun_px + dir * (fire_px.distance_to(sun_px) + 0.12 * h)
		var mirror := sun_px + Vector2(-dir.x, dir.y) * (fire_px.distance_to(sun_px) + 0.12 * h)
		var fire_lum := _lum(_off, fire_px)
		var gain_past := _lum(on, past) - _lum(_off, past)
		var gain_mirror := _lum(on, mirror) - _lum(_off, mirror)
		print("[shafts_flow] sun %s fire %s (lum %.3f) past %s mirror %s" % [sun_px, fire_px, fire_lum, past, mirror])
		_check(fire_lum > 0.8, "the fire glows (lum %.3f)" % fire_lum)
		_check(gain_past <= gain_mirror + 0.02, "no streak from the fire: the shafts add %.3f past it, %.3f on the clear side" % [gain_past, gain_mirror])
		on.save_png("user://light_shafts_flow.png")
		print("[shafts_flow] ", "PASS" if _ok else "FAIL")
		quit(0 if _ok else 1)

extends SceneTree

# PhysXLightShafts3D: UE-style light shafts from a DirectionalLight3D, in
# screen space. A low sun just right of a box's edge (the box covers the sky
# left of the sun); sampled on the sky the same distance left / right of it:
#   1. occlusion only: the left sample (its way to the sun runs through the
#      box) darkens; the right one (open way) doesn't change;
#   2. bloom only: the right sample (open way to the bright sun) brightens;
#   3. the sun behind the camera: the frame is the same with the node on;
#   4. the node hidden: the frame is the same as without it.
# Needs a window (the effect is a compositor effect):
#   godot --path . --script res://test/gpu/light_shafts_test.gd

var _cam: Camera3D
var _sun: DirectionalLight3D
var _shafts: Node3D
var _t := 0
var _ok := true
var _shots := {}


func _check(cond: bool, msg: String) -> void:
	print("[shafts] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXLightShafts3D"):
		print("[shafts] SKIP: no PhysXLightShafts3D")
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
	_sun = DirectionalLight3D.new()
	_sun.rotation_degrees = Vector3(-5, 180, 0) # low, ahead of the camera
	get_root().add_child(_sun)
	_cam = Camera3D.new()
	get_root().add_child(_cam)
	_cam.position = Vector3(0, 2, 0)
	# The sky left of the sun: a box whose right edge stops short of it.
	var box := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(6, 6, 1)
	box.mesh = bm
	box.position = Vector3(-3.6, 2 + 20 * tan(deg_to_rad(5)), -20)
	get_root().add_child(box)
	_shafts = ClassDB.instantiate("PhysXLightShafts3D")
	_shafts.visible = false
	_sun.add_child(_shafts)
	process_frame.connect(_frame)


func _shot() -> Image:
	return get_root().get_texture().get_image()


func _lum(img: Image, p: Vector2) -> float:
	var c := img.get_pixelv(Vector2i(p))
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _max_diff(a: Image, b: Image) -> float:
	var d := 0.0
	for y in range(0, a.get_height(), 4):
		for x in range(0, a.get_width(), 4):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			d = maxf(d, maxf(absf(ca.r - cb.r), maxf(absf(ca.g - cb.g), absf(ca.b - cb.b))))
	return d


func _frame() -> void:
	_t += 1
	# Each state gets 20 frames to settle, then a shot.
	match _t:
		30:
			_shots["off"] = _shot()
			_shafts.visible = true
			_shafts.set("mode", 2) # occlusion
		50:
			_shots["occlusion"] = _shot()
			_shafts.set("mode", 1) # bloom
		70:
			_shots["bloom"] = _shot()
			_shafts.visible = false
		90:
			_shots["hidden"] = _shot()
			_sun.rotation_degrees = Vector3(-5, 0, 0) # behind the camera
		110:
			_shots["behind_off"] = _shot()
			_shafts.visible = true
			_shafts.set("mode", 0)
		130:
			_shots["behind_on"] = _shot()
			_finish()


func _finish() -> void:
	var h := float(get_root().get_visible_rect().size.y)
	var sun_px := _cam.unproject_position(_cam.position + Vector3(0, tan(deg_to_rad(5)), -1) * 100.0)
	var left := sun_px + Vector2(-0.12 * h, -0.2 * h)
	var right := sun_px + Vector2(0.12 * h, -0.2 * h)
	var off: Image = _shots["off"]
	var occ: Image = _shots["occlusion"]
	var blm: Image = _shots["bloom"]
	print("[shafts] sun at %s; left %s right %s" % [sun_px, left, right])
	_check(_lum(occ, left) < _lum(off, left) * 0.97, "occlusion: blocked sky darkens (%.3f -> %.3f)" % [_lum(off, left), _lum(occ, left)])
	_check(absf(_lum(occ, right) - _lum(off, right)) < 0.02, "occlusion: open sky unchanged (%.3f -> %.3f)" % [_lum(off, right), _lum(occ, right)])
	_check(_lum(blm, right) > _lum(off, right) * 1.05, "bloom: open sky near the sun brightens (%.3f -> %.3f)" % [_lum(off, right), _lum(blm, right)])
	var hid := _max_diff(off, _shots["hidden"])
	_check(hid < 0.01, "hidden node: frame unchanged (max diff %.4f)" % hid)
	var beh := _max_diff(_shots["behind_off"], _shots["behind_on"])
	_check(beh < 0.01, "sun behind the camera: frame unchanged (max diff %.4f)" % beh)
	off.save_png("user://light_shafts_off.png")
	occ.save_png("user://light_shafts_occlusion.png")
	blm.save_png("user://light_shafts_bloom.png")
	print("[shafts] ", "PASS" if _ok else "FAIL")
	quit(0 if _ok else 1)

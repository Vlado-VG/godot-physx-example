extends SceneTree

# PhysXLensDirt3D: the frame's bright light lights a dirt texture laid over the
# screen and is added on top (Unreal's bloom dirt mask). A bright sky over
# the top half of the view, a black panel over the bottom; the dirt texture
# white on its left half, black (clean) on its right:
#   1. bright sky behind dirt (top left) brightens;
#   2. bright sky behind clean glass (top right) doesn't change;
#   3. the dark panel (bottom left, behind dirt) brightens far less: only light
#      reaching the lens lights the dirt;
#   4. the node hidden, or without a texture, leaves the frame as it was.
# Needs a window (the effect is a compositor effect):
#   godot --path . --script res://test/gpu/lens_dirt_test.gd

var _dirt: Node3D
var _dirt_tex: Texture2D
var _t := 0
var _ok := true
var _shots := {}


func _check(cond: bool, msg: String) -> void:
	print("[lens_dirt] %s %s" % ["ok  " if cond else "FAIL", msg])
	_ok = _ok and cond


func _initialize() -> void:
	if not ClassDB.class_exists("PhysXLensDirt3D"):
		print("[lens_dirt] SKIP: no PhysXLensDirt3D")
		quit(0)
		return
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	# Mid grey: room to brighten before the (linear) tonemapper clips at 1.
	env.background_color = Color(0.4, 0.4, 0.4)
	we.environment = env
	get_root().add_child(we)
	var cam := Camera3D.new()
	get_root().add_child(cam)
	# A black panel over the bottom half of the view.
	var panel := MeshInstance3D.new()
	var q := QuadMesh.new()
	q.size = Vector2(40, 10)
	panel.mesh = q
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color.BLACK
	panel.material_override = m
	panel.position = Vector3(0, -5, -5)
	get_root().add_child(panel)

	var img := Image.create(64, 36, false, Image.FORMAT_RGB8)
	for y in 36:
		for x in 64:
			img.set_pixel(x, y, Color.WHITE if x < 32 else Color.BLACK)
	_dirt_tex = ImageTexture.create_from_image(img)
	_dirt = ClassDB.instantiate("PhysXLensDirt3D")
	_dirt.visible = false
	_dirt.set("dirt_texture", _dirt_tex)
	get_root().add_child(_dirt)
	process_frame.connect(_frame)


func _shot() -> Image:
	return get_root().get_texture().get_image()


func _lum(img: Image, u: float, v: float) -> float:
	var c := img.get_pixel(int(u * img.get_width()), int(v * img.get_height()))
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
	match _t:
		20:
			_shots["off"] = _shot()
			_dirt.visible = true
		40:
			_shots["on"] = _shot()
			_dirt.visible = false
		60:
			_shots["hidden"] = _shot()
			_dirt.visible = true
			_dirt.set("dirt_texture", null)
		80:
			_shots["no_texture"] = _shot()
			_finish()


func _finish() -> void:
	var off: Image = _shots["off"]
	var on: Image = _shots["on"]
	var dirty_sky := _lum(on, 0.25, 0.2) - _lum(off, 0.25, 0.2)
	var clean_sky := _lum(on, 0.75, 0.2) - _lum(off, 0.75, 0.2)
	var dirty_dark := _lum(on, 0.1, 0.92) - _lum(off, 0.1, 0.92)
	print("[lens_dirt] brightened by: dirty sky %.3f, clean sky %.3f, dirty dark %.3f (sky %.3f, dark %.3f without)" % [dirty_sky, clean_sky, dirty_dark, _lum(off, 0.25, 0.2), _lum(off, 0.1, 0.92)])
	_check(dirty_sky > 0.05, "bright light behind dirt lights it (+%.3f)" % dirty_sky)
	_check(absf(clean_sky) < 0.01, "clean glass in front of the same light: unchanged (%+.3f)" % clean_sky)
	_check(dirty_dark < dirty_sky * 0.5, "dirt in front of the dark panel: far less (+%.3f vs +%.3f)" % [dirty_dark, dirty_sky])
	var hid := _max_diff(off, _shots["hidden"])
	_check(hid < 0.01, "hidden node: frame unchanged (max diff %.4f)" % hid)
	var none := _max_diff(off, _shots["no_texture"])
	_check(none < 0.01, "no dirt texture: frame unchanged (max diff %.4f)" % none)
	on.save_png("user://lens_dirt_test.png")
	print("[lens_dirt] ", "PASS" if _ok else "FAIL")
	quit(0 if _ok else 1)

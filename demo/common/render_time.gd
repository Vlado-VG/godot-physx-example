extends RefCounted
class_name RenderTime
# The demo HUDs' render times, as text. Reading a viewport's measured render
# time makes the main thread wait for the render thread. With rendering on its
# own thread (rendering/driver/threads/thread_model = Separate) that wait (and
# the warning Godot prints with it) every frame cut the light scattering demo
# from ~280 to ~30 FPS, so there the numbers are read twice a second and held
# in between. FPS and the process / physics times don't wait on anything.

const SEPARATE_REFRESH_MSEC := 500

static var _cpu := 0.0
static var _gpu := 0.0
static var _read_at := -SEPARATE_REFRESH_MSEC


static func _refresh(p_viewport: RID) -> void:
	var now := Time.get_ticks_msec()
	if not RenderingServer.is_on_render_thread() and now - _read_at < SEPARATE_REFRESH_MSEC:
		return
	_read_at = now
	_cpu = RenderingServer.viewport_get_measured_render_time_cpu(p_viewport) + RenderingServer.get_frame_setup_time_cpu()
	_gpu = RenderingServer.viewport_get_measured_render_time_gpu(p_viewport)


# "render cpu X ms   gpu Y ms"
static func cpu_gpu(p_viewport: RID) -> String:
	_refresh(p_viewport)
	return "render cpu %.2f ms   gpu %.2f ms" % [_cpu, _gpu]


# "render gpu Y ms"
static func gpu(p_viewport: RID) -> String:
	_refresh(p_viewport)
	return "render gpu %.2f ms" % _gpu

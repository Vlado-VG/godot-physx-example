shader_type spatial;
// Water mask: an invisible lid over a hull's opening. Drawn after opaque
// geometry (it's "transparent") but before the water (lower render_priority
// on the material), it writes depth only, so the water below it -- inside
// the hull -- fails the depth test and isn't drawn, while the boat's own
// interior (already drawn) and the water outside it are untouched.
render_mode unshaded, cull_disabled, depth_draw_always, blend_mix, shadows_disabled;

void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}

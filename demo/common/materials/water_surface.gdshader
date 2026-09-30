shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Water surface for PhysXWaterSurface3D (lit variant of the node's built-in
// material). The node binds the textures and sets choppiness, grid_center
// and the domain sizes; the rest are look settings.

uniform sampler2D ripple_height_tex : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D ocean_height_tex : hint_default_black, filter_linear, repeat_enable;
// Ocean chop multiplier over the ripple domain: 1 in deep water, fading to 0
// at the waterline (bound by PhysXWaterSurface3D when it has a seabed).
uniform sampler2D ocean_fade_tex : hint_default_white, filter_linear, repeat_disable;
// Choppy horizontal displacement (x, z) of the ocean layer.
uniform sampler2D ocean_disp_tex : hint_default_black, filter_linear, repeat_enable;
uniform float choppiness = 1.0;
// Ocean slopes and displacement derivatives (dh/dx, dh/dz, dDx/dx, dDz/dz),
// straight from the FFT, for exact per-pixel normals and foam.
uniform sampler2D ocean_deriv_tex : hint_default_black, filter_linear, repeat_enable;
// true: normals and foam per pixel from ocean_deriv_tex (smooth crests at any
// mesh density). false: per vertex, from finite differences of the displaced
// mesh (set by PhysXWaterSurface3D::normal_mode).
uniform bool per_pixel_normals = true;
uniform vec2 ripple_domain_size = vec2(20.0, 20.0);
uniform vec2 ocean_domain_size = vec2(40.0, 40.0);
uniform vec2 grid_center = vec2(0.0);
// Mean surface height (node-relative), what the ripple layer settles back to
// past the edge of its domain when the surface is rendered further out.
uniform float water_level = 0.0;
uniform vec4 water_color : source_color = vec4(0.09, 0.32, 0.42, 0.65);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.04;
// Persistent whitecap foam (0..1) on the ocean grid, injected where the
// waves fold and fading over the node's foam_persistence (set by
// PhysXWaterSurface3D).
uniform sampler2D ocean_foam_tex : hint_default_black, filter_linear, repeat_enable;
uniform vec4 foam_color : source_color = vec4(0.92, 0.95, 0.97, 0.95);
// How much fading foam breaks up into lace instead of thinning evenly
// (0 = solid sheet until it's gone).
uniform float foam_breakup : hint_range(0.0, 1.0) = 0.6;
// Size of that lace: noise cells per metre, fixed to the water.
uniform float foam_detail_scale = 1.5;
// Shore foam (0..1) on the ripple grid: the foamy sheet where waves wash in
// over the shallows (set by PhysXWaterSurface3D; needs a seabed).
uniform sampler2D shore_foam_tex : hint_default_black, filter_linear, repeat_disable;
// Shore foam is a thin sheet, not a whitecap: fainter, finer and lacier.
uniform float shore_foam_strength : hint_range(0.0, 1.0) = 0.65;
uniform float shore_foam_breakup : hint_range(0.0, 1.0) = 0.85;
// Churned, milky water over the shallows: tints toward shallow_color as the
// ocean fade drops off near the shore (shallow_tint 0 = off). Its alpha also
// replaces water_color's there.
uniform vec4 shallow_color : source_color = vec4(0.42, 0.66, 0.64, 0.55);
uniform float shallow_tint : hint_range(0.0, 1.0) = 0.6;
// Still-water depth in metres over the ripple domain (dry shore negative,
// pool walls deep), set by PhysXWaterSurface3D: the waterline is measured in
// real depth, independent of shallow_fade_depth.
uniform sampler2D shore_depth_tex : hint_default_white, filter_linear, repeat_disable;
// Soft contact with the shore: the surface fades out over this much water
// depth (m) at the waterline instead of meeting the sand at a hard line.
uniform float shore_edge_softness : hint_range(0.0, 0.5, 0.005) = 0.08;
// Moving waterline: how much water depth (m) the visible edge can pull back
// over. Arriving crests push it toward the sand, troughs pull it back, and
// slow ground-fixed noise keeps it irregular -- so the edge scallops with the
// waves instead of following a depth contour, but only ever goes clear where
// the water really is that thin.
uniform float swash_reach : hint_range(0.0, 1.0, 0.01) = 0.25;
// Swash and wet sand from PhysXWaterSurface3D (swash_run_up, ...): r = how
// high (m) above still water the last waves ran up, g = sand wetness.
uniform sampler2D swash_tex : hint_default_black, filter_linear, repeat_disable;
// Thickness (m) of the swash film over the sand -- just enough to stay above
// the ground mesh.
uniform float swash_film_thickness : hint_range(0.0, 0.2, 0.005) = 0.03;
// Fine ragged fingering of the swash edge: how much water depth (m) drifting
// small-scale noise adds or takes away there (on a 1:14 beach, 0.035 m is
// about half a metre of ragged edge).
uniform float swash_edge_breakup : hint_range(0.0, 0.2, 0.005) = 0.035;
// Wet sand: rgb blended over the ground where the water has been, alpha the
// strength -- darkens it, fading as it dries.
uniform vec4 wet_sand_color : source_color = vec4(0.16, 0.12, 0.07, 0.45);
// Wet sand sheen: lower is glossier (more sun glare off the wet beach).
uniform float wet_sand_roughness : hint_range(0.0, 1.0) = 0.5;
// Wave height (m) that pushes the waterline all the way in.
uniform float swash_wave_height = 0.3;
// Thin bright foam rim just behind the moving edge.
uniform float shore_rim_strength : hint_range(0.0, 1.0) = 0.8;

varying vec3 v_world_normal;
varying float v_foam;
varying vec2 v_rest_xz;

// Offset of the surface point that rests at world_xz: (dx, height, dz).
vec3 surface_offset(vec2 world_xz) {
	vec2 rel = world_xz - grid_center;
	vec2 cuv_r = clamp(rel / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	vec2 cuv_o = rel / ocean_domain_size + 0.5; // wraps: the FFT ocean is periodic
	float fade = texture(ocean_fade_tex, cuv_r).r;
	// Negative: moving against the displacement gathers points into the
	// crests (same convention as the node's built-in material).
	vec2 d = -choppiness * fade * texture(ocean_disp_tex, cuv_o).rg;
	// The ripple layer isn't periodic: past its domain, ease back to still water.
	vec2 from_center = abs(rel / ripple_domain_size);
	float inside = 1.0 - smoothstep(0.46, 0.5, max(from_center.x, from_center.y));
	float ripple = mix(water_level, texture(ripple_height_tex, cuv_r).r, inside);
	float h = ripple + texture(ocean_height_tex, cuv_o).r * fade;
	// Never below the ground: over dry sand (and in the deepest troughs over
	// shallows) the surface lies on the sand as a thin film, which is where
	// the swash shows.
	float ground = water_level - texture(shore_depth_tex, cuv_r).r;
	h = max(h, ground + swash_film_thickness);
	return vec3(d.x, h, d.y);
}

// Exact normal of the displaced surface at the point resting at world_xz:
// tangents of P(x0) = x0 + s D(x0) + h(x0) from the FFT's own derivatives. The ripple layer has no FFT, so its slope
// is a small central difference.
vec3 surface_normal_pixel(vec2 world_xz) {
	vec2 rel = world_xz - grid_center;
	vec2 cuv_r = clamp(rel / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	vec2 cuv_o = rel / ocean_domain_size + 0.5; // wraps: the FFT ocean is periodic
	float fade = texture(ocean_fade_tex, cuv_r).r;
	float s = -choppiness * fade;
	vec4 der = texture(ocean_deriv_tex, cuv_o);
	float dxz = texture(ocean_disp_tex, cuv_o).b;
	const float e = 0.2;
	vec2 du = vec2(e) / ripple_domain_size;
	float rx = (texture(ripple_height_tex, cuv_r + vec2(du.x, 0.0)).r - texture(ripple_height_tex, cuv_r - vec2(du.x, 0.0)).r) / (2.0 * e);
	float rz = (texture(ripple_height_tex, cuv_r + vec2(0.0, du.y)).r - texture(ripple_height_tex, cuv_r - vec2(0.0, du.y)).r) / (2.0 * e);
	// The ripple layer steps at the waterline (dry cells report their wet
	// neighbours' mean), which the sun picked out as bright streaks along the
	// shore; over the sand the swash film just follows the ground.
	float wet_w = smoothstep(0.0, 0.15, texture(shore_depth_tex, cuv_r).r);
	rx *= wet_w;
	rz *= wet_w;
	vec3 tx = vec3(1.0 + s * der.z, der.x * fade + rx, s * dxz);
	vec3 tz = vec3(s * dxz, der.y * fade + rz, 1.0 + s * der.w);
	return normalize(cross(tz, tx));
}

float foam_hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float foam_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(foam_hash(i), foam_hash(i + vec2(1.0, 0.0)), u.x),
			mix(foam_hash(i + vec2(0.0, 1.0)), foam_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Visible foam for the water resting at world_xz: the persistent foam amount,
// eroded by fixed-to-the-water noise so it breaks into lace as it fades.
float foam_at(vec2 world_xz) {
	vec2 rel = world_xz - grid_center;
	vec2 cuv_r = clamp(rel / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	vec2 cuv_o = rel / ocean_domain_size + 0.5; // wraps: the FFT ocean is periodic
	float amount = texture(ocean_foam_tex, cuv_o).r * texture(ocean_fade_tex, cuv_r).r;
	vec2 p = world_xz * foam_detail_scale;
	float n = 0.5 * foam_value_noise(p) + 0.3 * foam_value_noise(p * 2.7 + 17.0) + 0.2 * foam_value_noise(p * 7.3 - 5.0);
	// Gentle ramp: fresh foam is solid, thinning foam turns translucent and
	// lacy as the noise eats into it, rather than cutting off at an edge.
	float f = clamp(amount * (1.0 + foam_breakup) - n * foam_breakup, 0.0, 1.0);
	return f * f * (3.0 - 2.0 * f);
}

// Visible shore foam at world_xz: finer, heavier lace at partial strength.
float shore_foam_at(vec2 world_xz) {
	vec2 cuv_r = clamp((world_xz - grid_center) / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	vec2 q = world_xz * foam_detail_scale * 2.2 + 31.0;
	float ns = 0.5 * foam_value_noise(q) + 0.5 * foam_value_noise(q * 2.3 - 11.0);
	float shore = texture(shore_foam_tex, cuv_r).r;
	float g = clamp(shore * (1.0 + shore_foam_breakup) - ns * shore_foam_breakup, 0.0, 1.0);
	return g * g * (3.0 - 2.0 * g) * shore_foam_strength;
}

// Water depth (m) above the moving waterline: the still-water depth minus an
// offset in [0, swash_reach] -- small under an arriving crest (the edge
// reaches in), large under a trough, jittered by slow noise. <= 0 is past
// the visible edge.
float shore_signal(vec2 world_xz, float time) {
	vec2 rel = world_xz - grid_center;
	vec2 cuv_r = clamp(rel / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	vec2 cuv_o = rel / ocean_domain_size + 0.5; // wraps: the FFT ocean is periodic
	float depth = texture(shore_depth_tex, cuv_r).r;
	float eta = texture(ocean_height_tex, cuv_o).r; // unfaded: the waves arriving here
	// Lobes a few metres across (like real swash), drifting, with the waves
	// pushing the whole edge in and out over time.
	vec2 p = world_xz * 0.45;
	float n = 0.65 * foam_value_noise(p + vec2(time * 0.12, time * 0.05)) + 0.35 * foam_value_noise(p * 2.4 - vec2(time * 0.07, 0.0));
	float wave = clamp(eta / max(swash_wave_height, 1e-3), -1.0, 1.0);
	float offset = swash_reach * clamp(0.5 + (n - 0.5) * 1.6 - 0.35 * wave, 0.0, 1.0);
	// The pull-back only applies in the water; over dry sand the swash
	// film reaches exactly as far as the run-up (and the wet sand) does.
	vec2 q = world_xz;
	float eb = 0.5 * foam_value_noise(q * 2.3 + vec2(time * 0.25, 0.0)) + 0.3 * foam_value_noise(q * 6.1 + vec2(3.0, time * 0.4)) + 0.2 * foam_value_noise(q * 15.0 - 7.0);
	return depth - offset * smoothstep(0.0, 0.1, depth) + texture(swash_tex, cuv_r).r + (eb - 0.5) * 2.0 * swash_edge_breakup;
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_rest_xz = world_pos.xz;
	VERTEX += surface_offset(world_pos.xz);
	v_world_normal = vec3(0.0, 1.0, 0.0);
	v_foam = 0.0;
	// Per pixel, fragment() computes the normal and foam instead.
	if (!per_pixel_normals) {
		// Per-vertex: normal from central differences of the displaced
		// surface -- e is in world metres, small against the grids' cell
		// size.
		const float e = 0.2;
		vec3 px1 = vec3(e, 0.0, 0.0) + surface_offset(world_pos.xz + vec2(e, 0.0));
		vec3 px0 = vec3(-e, 0.0, 0.0) + surface_offset(world_pos.xz - vec2(e, 0.0));
		vec3 pz1 = vec3(0.0, 0.0, e) + surface_offset(world_pos.xz + vec2(0.0, e));
		vec3 pz0 = vec3(0.0, 0.0, -e) + surface_offset(world_pos.xz - vec2(0.0, e));
		vec3 tx = px1 - px0;
		vec3 tz = pz1 - pz0;
		v_world_normal = normalize(cross(tz, tx));
		v_foam = foam_at(world_pos.xz);
	}
}

void fragment() {
	vec3 world_normal = v_world_normal;
	float foam = v_foam;
	if (per_pixel_normals) {
		world_normal = surface_normal_pixel(v_rest_xz);
		foam = foam_at(v_rest_xz);
	}
	// The swash film over the sand is flat, so the sun made one smooth mirror
	// disc on it; small drifting ripples break that into glitter.
	vec2 cuv_film = clamp((v_rest_xz - grid_center) / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	float film = 1.0 - smoothstep(0.0, 0.15, texture(shore_depth_tex, cuv_film).r);
	vec2 gp = v_rest_xz * 6.0;
	vec2 tilt = vec2(foam_value_noise(gp + vec2(TIME * 0.9, 0.0)), foam_value_noise(gp * 1.3 + vec2(0.0, TIME * 0.7) + 13.0)) - 0.5;
	world_normal = normalize(world_normal + vec3(tilt.x, 0.0, tilt.y) * 0.35 * film);
	// Fragment-stage NORMAL is view space -- transform the world-space normal.
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	float shore = shore_signal(v_rest_xz, TIME);
	// Shore foam belongs to the moving edge: full at it, thinning over the
	// next ~0.6 m of depth, so the white sheet scallops with the edge instead
	// of filling the band. (Whitecaps are left alone.)
	foam = max(foam, shore_foam_at(v_rest_xz) * (1.0 - smoothstep(0.02, 0.6, shore)));
	// Bright rim right behind the moving edge, broken into lace.
	// Over dry sand the swash film is only as thick as the run-up's excess
	// over the sand -- a few cm -- so it fades in over a fifth of the
	// softness there, or the uprush would barely show.
	vec2 cuv_here = clamp((v_rest_xz - grid_center) / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	float soft = max(shore_edge_softness, 1e-3) * mix(0.2, 1.0, smoothstep(-0.05, 0.1, texture(shore_depth_tex, cuv_here).r));
	float rim = smoothstep(0.0, soft * 0.5, shore) * (1.0 - smoothstep(soft * 0.6, soft * 2.2, shore));
	rim *= shore_rim_strength * (0.55 + 0.45 * foam_value_noise(v_rest_xz * 6.0));
	foam = max(foam, rim);
	vec2 cuv_fade = clamp((v_rest_xz - grid_center) / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	float shallow = (1.0 - texture(ocean_fade_tex, cuv_fade).r) * shallow_tint;
	vec3 base_rgb = mix(water_color.rgb, shallow_color.rgb, shallow);
	float base_a = mix(water_color.a, shallow_color.a, shallow);
	// Thin water is clear: the swash film and the last few cm at the edge let
	// the sand show through, turning opaque by ~25 cm of depth.
	base_a *= mix(0.4, 1.0, smoothstep(0.0, 0.25, shore));
	ALBEDO = mix(base_rgb, foam_color.rgb, foam);
	float water_a = mix(base_a, foam_color.a, foam) * smoothstep(0.0, soft, shore);
	// Wet sand under and behind the swash: blended in where the water is
	// thin or gone, so it shows through the film and lingers after it.
	// Noise eats into the wet edge, so it dries back ragged rather than
	// along a clean line.
	float wn = 0.6 * foam_value_noise(v_rest_xz * 1.7) + 0.4 * foam_value_noise(v_rest_xz * 5.3 + 7.0);
	float wet = clamp((texture(swash_tex, cuv_fade).g - 0.35 * wn) / 0.65, 0.0, 1.0);
	float wet_a = wet * wet * (3.0 - 2.0 * wet) * wet_sand_color.a * (1.0 - water_a);
	ALPHA = water_a + wet_a;
	ALBEDO = (ALBEDO * water_a + wet_sand_color.rgb * wet_a) / max(ALPHA, 1e-4);
	// Wet sand is glossy.
	ROUGHNESS = mix(mix(roughness_val, 0.8, foam), wet_sand_roughness, wet_a / max(ALPHA, 1e-4));
	METALLIC = 0.0;
}

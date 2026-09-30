shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

// Water surface for PhysXWaterSurface3D (lit variant of the node's built-in
// material). The node binds the textures and sets choppiness, grid_center
// and the domain sizes; the rest are look settings.

uniform sampler2D ripple_height_tex : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D ocean_height_tex : hint_default_black, filter_linear, repeat_disable;
// Ocean chop multiplier over the ripple domain: 1 in deep water, fading to 0
// at the waterline (bound by PhysXWaterSurface3D when it has a seabed).
uniform sampler2D ocean_fade_tex : hint_default_white, filter_linear, repeat_disable;
// Choppy horizontal displacement (x, z) of the ocean layer.
uniform sampler2D ocean_disp_tex : hint_default_black, filter_linear, repeat_disable;
uniform float choppiness = 1.0;
// Ocean slopes and displacement derivatives (dh/dx, dh/dz, dDx/dx, dDz/dz),
// straight from the FFT, for exact per-pixel normals and foam.
uniform sampler2D ocean_deriv_tex : hint_default_black, filter_linear, repeat_disable;
// true: normals and foam per pixel from ocean_deriv_tex (smooth crests at any
// mesh density). false: per vertex, from finite differences of the displaced
// mesh (set by PhysXWaterSurface3D::normal_mode).
uniform bool per_pixel_normals = true;
uniform vec2 ripple_domain_size = vec2(20.0, 20.0);
uniform vec2 ocean_domain_size = vec2(40.0, 40.0);
uniform vec2 grid_center = vec2(0.0);
uniform vec4 water_color : source_color = vec4(0.09, 0.32, 0.42, 0.65);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.04;
// Whitecaps where the choppy displacement squeezes the surface: foam fades
// in as the area Jacobian drops below foam_threshold (1 = unsqueezed, 0 =
// folding over).
uniform float foam_threshold : hint_range(0.0, 1.0) = 0.7;
uniform vec4 foam_color : source_color = vec4(0.92, 0.95, 0.97, 0.95);

varying vec3 v_world_normal;
varying float v_foam;
varying vec2 v_rest_xz;

// Offset of the surface point that rests at world_xz: (dx, height, dz).
vec3 surface_offset(vec2 world_xz) {
	vec2 rel = world_xz - grid_center;
	vec2 cuv_r = clamp(rel / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	vec2 cuv_o = clamp(rel / ocean_domain_size + 0.5, vec2(0.0), vec2(1.0));
	float fade = texture(ocean_fade_tex, cuv_r).r;
	// Negative: moving against the displacement gathers points into the
	// crests (same convention as the node's built-in material).
	vec2 d = -choppiness * fade * texture(ocean_disp_tex, cuv_o).rg;
	float h = texture(ripple_height_tex, cuv_r).r + texture(ocean_height_tex, cuv_o).r * fade;
	return vec3(d.x, h, d.y);
}

// Exact normal of the displaced surface at the point resting at world_xz,
// and its area Jacobian (for foam): tangents of P(x0) = x0 + s D(x0) + h(x0)
// from the FFT's own derivatives. The ripple layer has no FFT, so its slope
// is a small central difference.
vec3 surface_normal_pixel(vec2 world_xz, out float jacobian) {
	vec2 rel = world_xz - grid_center;
	vec2 cuv_r = clamp(rel / ripple_domain_size + 0.5, vec2(0.0), vec2(1.0));
	vec2 cuv_o = clamp(rel / ocean_domain_size + 0.5, vec2(0.0), vec2(1.0));
	float fade = texture(ocean_fade_tex, cuv_r).r;
	float s = -choppiness * fade;
	vec4 der = texture(ocean_deriv_tex, cuv_o);
	float dxz = texture(ocean_disp_tex, cuv_o).b;
	const float e = 0.2;
	vec2 du = vec2(e) / ripple_domain_size;
	float rx = (texture(ripple_height_tex, cuv_r + vec2(du.x, 0.0)).r - texture(ripple_height_tex, cuv_r - vec2(du.x, 0.0)).r) / (2.0 * e);
	float rz = (texture(ripple_height_tex, cuv_r + vec2(0.0, du.y)).r - texture(ripple_height_tex, cuv_r - vec2(0.0, du.y)).r) / (2.0 * e);
	vec3 tx = vec3(1.0 + s * der.z, der.x * fade + rx, s * dxz);
	vec3 tz = vec3(s * dxz, der.y * fade + rz, 1.0 + s * der.w);
	jacobian = tx.x * tz.z - tx.z * tz.x;
	return normalize(cross(tz, tx));
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_rest_xz = world_pos.xz;
	VERTEX += surface_offset(world_pos.xz);
	v_world_normal = vec3(0.0, 1.0, 0.0);
	v_foam = 0.0;
	// Per pixel, fragment() computes the normal and foam instead.
	if (!per_pixel_normals) {
		// Per-vertex: normal and Jacobian from central differences of the
		// displaced surface -- e is in world metres, small against the grids'
		// cell size.
		const float e = 0.2;
		vec3 px1 = vec3(e, 0.0, 0.0) + surface_offset(world_pos.xz + vec2(e, 0.0));
		vec3 px0 = vec3(-e, 0.0, 0.0) + surface_offset(world_pos.xz - vec2(e, 0.0));
		vec3 pz1 = vec3(0.0, 0.0, e) + surface_offset(world_pos.xz + vec2(0.0, e));
		vec3 pz0 = vec3(0.0, 0.0, -e) + surface_offset(world_pos.xz - vec2(0.0, e));
		vec3 tx = px1 - px0;
		vec3 tz = pz1 - pz0;
		v_world_normal = normalize(cross(tz, tx));
		float jacobian = (tx.x * tz.z - tx.z * tz.x) / (4.0 * e * e);
		v_foam = 1.0 - smoothstep(foam_threshold - 0.3, foam_threshold, jacobian);
	}
}

void fragment() {
	vec3 world_normal = v_world_normal;
	float foam = v_foam;
	if (per_pixel_normals) {
		float jacobian;
		world_normal = surface_normal_pixel(v_rest_xz, jacobian);
		foam = 1.0 - smoothstep(foam_threshold - 0.3, foam_threshold, jacobian);
	}
	// Fragment-stage NORMAL is view space -- transform the world-space normal.
	NORMAL = normalize((VIEW_MATRIX * vec4(world_normal, 0.0)).xyz);
	ALBEDO = mix(water_color.rgb, foam_color.rgb, foam);
	ALPHA = mix(water_color.a, foam_color.a, foam);
	ROUGHNESS = mix(roughness_val, 0.8, foam);
	METALLIC = 0.0;
}

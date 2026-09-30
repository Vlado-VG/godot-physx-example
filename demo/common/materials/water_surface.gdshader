shader_type spatial;
render_mode blend_mix, cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D ripple_height_tex : hint_default_black, filter_linear, repeat_disable;
uniform sampler2D ocean_height_tex : hint_default_black, filter_linear, repeat_disable;
// Ocean chop multiplier over the ripple domain: 1 in deep water, fading to 0
// at the waterline (bound by PhysXWaterSurface3D when it has a seabed).
uniform sampler2D ocean_fade_tex : hint_default_white, filter_linear, repeat_disable;
uniform vec2 ripple_domain_size = vec2(20.0, 20.0);
uniform vec2 ocean_domain_size = vec2(40.0, 40.0);
uniform vec2 grid_center = vec2(0.0);
uniform vec4 water_color : source_color = vec4(0.09, 0.32, 0.42, 0.65);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.04;

varying vec3 v_world_normal;

float sample_h(vec2 world_xz) {
	vec2 rel = world_xz - grid_center;
	vec2 uv_r = rel / ripple_domain_size + 0.5;
	vec2 uv_o = rel / ocean_domain_size + 0.5;
	vec2 cuv_r = clamp(uv_r, vec2(0.0), vec2(1.0));
	return texture(ripple_height_tex, cuv_r).r + texture(ocean_height_tex, clamp(uv_o, vec2(0.0), vec2(1.0))).r * texture(ocean_fade_tex, cuv_r).r;
}

void vertex() {
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += sample_h(world_pos.xz);

	// Central-difference normal -- e is in world meters, small relative to
	// the ripple/ocean grids' own cell size so it stays a meaningful local
	// gradient estimate, not aliased noise between texels.
	const float e = 0.2;
	float hx1 = sample_h(world_pos.xz + vec2(e, 0.0));
	float hx0 = sample_h(world_pos.xz - vec2(e, 0.0));
	float hz1 = sample_h(world_pos.xz + vec2(0.0, e));
	float hz0 = sample_h(world_pos.xz - vec2(0.0, e));
	v_world_normal = normalize(vec3(hx0 - hx1, 2.0 * e, hz0 - hz1));
}

void fragment() {
	// Fragment-stage NORMAL is view space in this engine's spatial shader
	// pipeline -- transform the world-space normal computed in vertex().
	NORMAL = normalize((VIEW_MATRIX * vec4(v_world_normal, 0.0)).xyz);

	// Real transparency via Godot's own GPU alpha blending (ALPHA,
	// blend_mix) -- see this file's own top-of-namespace comment for why
	// manual screen-space refraction was dropped. The root cause of the
	// "whitewash" turned out to be neither refraction nor blending at all:
	// a plain EMISSION=(0,1,0) diagnostic, well inside [0,1], still crushed
	// to near-white -- confirmed via real research (not guessing) that this
	// engine's Forward+ renderer always computes lighting in an internal
	// HDR buffer before a final tonemap pass, and this scene's Environment
	// uses ACES tonemapping with the engine's default tonemap_white=1.0,
	// far below the 6.0-8.0 Godot's own docs recommend for ACES -- any
	// reasonably-lit or blended value easily exceeds that low a reference
	// white and blows out. Fixed at the Environment level (tonemap_white),
	// not in this shader.
	ALBEDO = water_color.rgb;
	ALPHA = water_color.a;
	ROUGHNESS = roughness_val;
	METALLIC = 0.0;
}

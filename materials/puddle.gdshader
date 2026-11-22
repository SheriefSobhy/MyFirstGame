shader_type spatial;
// Shallow puddle: a dark, mirror-smooth, slightly transparent quad.
// It picks up the sky through the environment's reflections, and a slow
// ripple wobbles the normal so the reflection isn't perfectly flat.
render_mode blend_mix, depth_draw_never, cull_back, shadows_disabled, specular_schlick_ggx;

uniform sampler2D mask_tex : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform vec3 water_color : source_color = vec3(0.06, 0.055, 0.05);
uniform float opacity = 0.75;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	float m = texture(mask_tex, UV).a * COLOR.a;
	vec2 r = texture(noise_tex, world_pos.xz * 0.35 + TIME * 0.015).gb - 0.5;
	ALBEDO = water_color;
	ROUGHNESS = 0.04;
	METALLIC = 0.0;
	SPECULAR = 0.8;
	NORMAL = normalize(NORMAL + (VIEW_MATRIX * vec4(r.x, 0.0, r.y, 0.0)).xyz * 0.08);
	ALPHA = smoothstep(0.05, 0.6, m) * opacity;
}

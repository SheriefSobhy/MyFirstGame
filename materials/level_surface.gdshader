shader_type spatial;
// Surface shader for the yard's static boxes (floor, walls, buildings,
// containers, barriers). It is built to stay cheap on phones:
// - World-aligned projection with ONE sample per texture (the boxes are
//   axis-aligned), instead of the 3 samples StandardMaterial's triplanar does.
// - Breaks up tiling with a low-frequency noise texture: brightness/tint
//   blotches, optional patches of a second texture, vertical rain streaks.
// - Dirt that rises from the ground at the bottom of walls, and grime on
//   the floor along the perimeter walls, both computed from world position.
// Lightmaps (UV2) work automatically with custom shaders.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform sampler2D patch_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 tint : source_color = vec3(1.0);
uniform float uv_scale = 0.3;
uniform float normal_strength = 1.0;
uniform float roughness_add = 0.0;

group_uniforms variation;
uniform float macro_scale = 0.06;     // noise tiles per metre
uniform float macro_strength = 0.3;   // brightness swing of the blotches
uniform vec3 macro_tint : source_color = vec3(0.85, 0.78, 0.68);
uniform float patch_amount = 0.0;     // 0 = no second-texture patches
uniform float patch_scale = 0.35;
uniform vec3 patch_tint : source_color = vec3(1.0);
uniform float streak_strength = 0.0;  // vertical rain/rust streaks on walls

group_uniforms grime;
uniform vec3 dirt_color : source_color = vec3(0.32, 0.27, 0.21);
uniform float dirt_height = 0.7;      // metres of dirt at the base of walls
uniform float dirt_strength = 0.65;
uniform float ground_y = 0.0;
uniform float edge_dirt_start = 0.0;  // floor only: |x| or |z| where grime starts (0 = off)
uniform float edge_dirt_end = 12.0;

varying vec3 world_pos;
varying vec3 world_nrm;
varying vec2 proj_uv;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vec3 an = abs(world_nrm);
	vec3 t;
	vec3 b;
	// Godot's convention: TANGENT = dP/du, BINORMAL = -dP/dv.
	if (an.y >= an.x && an.y >= an.z) {
		proj_uv = world_pos.xz;
		t = vec3(1.0, 0.0, 0.0);
		b = vec3(0.0, 0.0, -1.0);
	} else if (an.x >= an.z) {
		proj_uv = vec2(world_pos.z * sign(world_nrm.x), -world_pos.y);
		t = vec3(0.0, 0.0, sign(world_nrm.x));
		b = vec3(0.0, 1.0, 0.0);
	} else {
		proj_uv = vec2(-world_pos.x * sign(world_nrm.z), -world_pos.y);
		t = vec3(-sign(world_nrm.z), 0.0, 0.0);
		b = vec3(0.0, 1.0, 0.0);
	}
	mat3 to_model = inverse(mat3(MODEL_MATRIX));
	TANGENT = normalize(to_model * t);
	BINORMAL = normalize(to_model * b);
}

void fragment() {
	vec2 uv = proj_uv * uv_scale;
	vec3 albedo = texture(albedo_tex, uv).rgb * tint;
	float rough = texture(roughness_tex, uv).r;

	// r = big blotches, g = medium detail, b = fine grain
	vec3 n = texture(noise_tex, proj_uv * macro_scale + world_pos.y * 0.013).rgb;
	float blotch = n.r * 0.7 + n.g * 0.3;
	albedo *= mix(vec3(1.0), macro_tint, smoothstep(0.35, 0.75, blotch) * 0.6);
	albedo *= 1.0 + (blotch - 0.5) * macro_strength * 2.0;

	if (patch_amount > 0.0) {
		float p = smoothstep(0.58, 0.66, n.r + (n.b - 0.5) * 0.15) * patch_amount;
		vec3 patch_col = texture(patch_tex, proj_uv * patch_scale).rgb * patch_tint;
		albedo = mix(albedo, patch_col, p);
		rough = mix(rough, 0.9, p);
	}

	float side = 1.0 - abs(world_nrm.y);
	if (streak_strength > 0.0) {
		// Stretch the noise vertically so it reads as runs of grime from the top.
		float s = texture(noise_tex, vec2(proj_uv.x * 0.23, proj_uv.y * 0.02 + 0.5)).g;
		// Only where the big blotch noise allows, so they don't form even bands.
		float where = smoothstep(0.45, 0.7, n.r);
		albedo *= 1.0 - smoothstep(0.5, 0.8, s) * streak_strength * side * where;
	}

	// Dirt splashed up from the ground at the base of walls.
	float h = world_pos.y - ground_y;
	float dirt = 1.0 - smoothstep(0.0, dirt_height * (0.55 + n.g * 0.9), h);
	dirt *= side * dirt_strength;

	// Floor: grime accumulates along the perimeter walls.
	if (edge_dirt_start > 0.0) {
		float e = max(abs(world_pos.x), abs(world_pos.z));
		float fd = smoothstep(edge_dirt_start - n.g * 1.2, edge_dirt_end, e);
		dirt = max(dirt, fd * dirt_strength * (1.0 - side));
	}
	albedo = mix(albedo, albedo * dirt_color * 1.6, dirt);
	rough = mix(rough, 1.0, dirt * 0.6);

	ALBEDO = albedo;
	ROUGHNESS = clamp(rough + roughness_add, 0.0, 1.0);
	NORMAL_MAP = texture(normal_tex, uv).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
}

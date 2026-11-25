shader_type spatial;
// The modular level kit (tools/blender/build_kit.py): ONE material for every
// kit piece, so a merged chunk of walls, frames, pipes and signs is one draw call.
// - kit_albedo / kit_normal: a 1024 atlas of 6 cells (brick, concrete,
//   corrugated iron, metal, wood, signs). UV is cell-local and keeps
//   repeating; the shader wraps it inside the cell (textureGrad keeps the
//   mip level right across the wrap, and is capped so cells don't bleed).
// - COLOR.a = (cell + 8 * palette index + 0.5) / 128 (set in Blender);
//   COLOR.rgb = per-instance tint / 2 (set by tools/kit_builder.gd).
// - CUSTOM0.xy: UV into kit_ao, the ambient occlusion baked in Blender.
//   (UV2 stays free for the yard's lightmap.)
// - Cheap world-space variation, like level_surface.gdshader: tint
//   blotches and dirt at the foot of walls.

uniform sampler2D albedo_atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : hint_normal, filter_linear_mipmap, repeat_disable;
uniform sampler2D ao_atlas : hint_default_white, filter_linear_mipmap, repeat_disable;
uniform sampler2D noise_tex : hint_default_white, filter_linear_mipmap, repeat_enable;

uniform vec3 tint : source_color = vec3(1.0);
uniform float ao_strength = 0.85;       // how much of the baked AO darkens direct light too
uniform float normal_strength = 1.0;
uniform float macro_strength = 0.2;
uniform vec3 macro_tint : source_color = vec3(0.85, 0.78, 0.68);
uniform vec3 dirt_color : source_color = vec3(0.32, 0.27, 0.21);
uniform float dirt_height = 0.6;
uniform float dirt_strength = 0.5;

// Cells in Godot UV space (x, y, w, h), same order as CELLS in build_kit.py.
const vec4 CELLS[6] = vec4[](
	vec4(0.0, 0.0, 0.5, 0.5),     // brick
	vec4(0.5, 0.0, 0.5, 0.5),     // concrete
	vec4(0.0, 0.5, 0.5, 0.5),     // corrugated iron
	vec4(0.5, 0.5, 0.25, 0.25),   // metal
	vec4(0.75, 0.5, 0.25, 0.25),  // wood
	vec4(0.5, 0.75, 0.5, 0.25)    // signs (not repeating)
);
const float ROUGH[6] = float[](0.9, 0.92, 0.72, 0.62, 0.85, 0.7);
// Paint / material tints, same order as PAL in build_kit.py.
const vec3 PALETTE[11] = vec3[](
	vec3(1.0), vec3(0.95, 0.93, 0.9), vec3(0.45, 0.46, 0.5), vec3(0.75, 0.77, 0.8),
	vec3(1.6, 1.58, 1.5), vec3(0.12, 0.15, 0.2), vec3(0.12), vec3(1.9, 1.35, 0.25),
	vec3(0.55, 0.85, 0.55), vec3(0.45, 0.6, 1.1), vec3(0.25)
);

varying vec4 v_cell;
varying vec3 v_tint;
varying float v_rough;
varying vec2 v_ao_uv;
varying vec3 world_pos;
varying vec3 world_nrm;

void vertex() {
	int code = int(COLOR.a * 128.0);
	int id = clamp(code % 8, 0, 5);
	v_cell = CELLS[id];
	v_rough = ROUGH[id];
	v_tint = PALETTE[clamp(code / 8, 0, 10)] * COLOR.rgb * 2.0;
	v_ao_uv = CUSTOM0.xy;
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_nrm = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	// Wrap inside the cell, half a texel in from its border.
	vec2 pad = vec2(1.0 / 1024.0) / v_cell.zw;
	vec2 cuv = v_cell.xy + v_cell.zw * (pad + fract(UV) * (1.0 - 2.0 * pad));
	vec2 dx = dFdx(UV) * v_cell.zw;
	vec2 dy = dFdy(UV) * v_cell.zw;
	// Cap the mip level (at most 1/32 of the cell per pixel) so far-away
	// surfaces don't blend in the neighbouring cells.
	float cap = v_cell.z / 32.0;
	dx *= min(1.0, cap / max(length(dx), 1e-6));
	dy *= min(1.0, cap / max(length(dy), 1e-6));
	vec3 albedo = textureGrad(albedo_atlas, cuv, dx, dy).rgb * v_tint * tint;
	vec3 nmap = textureGrad(normal_atlas, cuv, dx, dy).rgb;

	vec3 n = texture(noise_tex, world_pos.xz * 0.06 + world_pos.y * 0.013).rgb;
	float blotch = n.r * 0.7 + n.g * 0.3;
	albedo *= mix(vec3(1.0), macro_tint, smoothstep(0.35, 0.75, blotch) * 0.6);
	albedo *= 1.0 + (blotch - 0.5) * macro_strength * 2.0;

	float side = 1.0 - abs(world_nrm.y);
	float dirt = (1.0 - smoothstep(0.0, dirt_height * (0.55 + n.g * 0.9), world_pos.y)) * side * dirt_strength;
	albedo = mix(albedo, albedo * dirt_color * 1.6, dirt);

	float ao = texture(ao_atlas, v_ao_uv).r;
	ALBEDO = albedo * mix(1.0, ao, ao_strength);
	AO = ao;
	ROUGHNESS = clamp(v_rough + dirt * 0.3, 0.0, 1.0);
	NORMAL_MAP = nmap;
	NORMAL_MAP_DEPTH = normal_strength;
}

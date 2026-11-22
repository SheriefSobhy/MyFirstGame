shader_type spatial;
// Fake decal for the Compatibility renderer (it has no Decal node support):
// a flat quad, alpha-blended with an almost-black colour, so it darkens
// what's under it by (1 - alpha), like a multiply. (A real blend_mul quad
// renders black inside sun shadows in the Compatibility renderer.)
// Many quads are merged into one mesh, so each texture is one draw call.
render_mode blend_mix, unshaded, cull_back, depth_draw_never, fog_disabled, shadows_disabled;

uniform sampler2D decal_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform float strength = 1.0;

void fragment() {
	vec4 t = texture(decal_tex, UV);
	// A hint of the texture's colour; mostly it just darkens.
	ALBEDO = t.rgb * 0.12;
	// COLOR.a holds a per-quad strength so merged quads can vary.
	ALPHA = t.a * strength * COLOR.a;
}

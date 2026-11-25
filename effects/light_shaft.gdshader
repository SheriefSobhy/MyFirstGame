shader_type spatial;
// A fake light shaft: an open cylinder / cone drawn additively. It fades at
// its silhouette edges (so it looks like a soft volume from every side), at
// both ends along its length, and close to the camera (no hard overlap).
// No depth texture is read: it works the same in Compatibility and Mobile.
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform vec3 beam_color : source_color = vec3(1.0);
uniform float intensity = 0.2;
uniform float fade_in = 0.15;      // fraction of the length it fades in over (from the source)
uniform float fade_out = 0.5;      // fraction it fades out over (at the far end)
uniform float edge_power = 1.6;
uniform float near_fade = 3.0;     // metres from the camera where it is fully visible

void fragment() {
	float edge = pow(abs(dot(normalize(NORMAL), normalize(VIEW))), edge_power);
	// CylinderMesh puts its side in the top half of the UV square: v runs 0..0.5.
	float t = UV.y * 2.0;
	float along = smoothstep(0.0, max(fade_in, 0.001), t) * (1.0 - smoothstep(1.0 - fade_out, 1.0, t));
	float near = smoothstep(0.6, near_fade, length(VERTEX));
	ALBEDO = beam_color;
	ALPHA = clamp(edge * along * near * intensity, 0.0, 1.0);
}

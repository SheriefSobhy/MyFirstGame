shader_type canvas_item;
// Sniper scope: black everywhere except a round lens in the middle of the
// screen, with thin crosshair lines and a slight dark edge inside the lens.

uniform float aspect = 1.777;   // screen width / height, set by hud.gd
uniform float radius = 0.46;    // lens radius as a fraction of screen height

void fragment() {
	vec2 p = (UV - 0.5) * vec2(aspect, 1.0);
	float d = length(p);
	float outside = smoothstep(radius - 0.003, radius + 0.003, d);
	float edge = smoothstep(radius * 0.75, radius, d) * 0.45;
	float line_w = 0.0012;
	float cross = (abs(p.x) < line_w || abs(p.y) < line_w) ? 0.9 : 0.0;
	cross *= step(0.012, d);  // small gap in the very centre
	COLOR = vec4(0.0, 0.0, 0.0, max(outside, max(edge, cross)));
}

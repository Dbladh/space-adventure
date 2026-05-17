shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_opaque;

// background_ring.gdshader
// Saturn-style flat planet ring rendered on a PlaneMesh, not a torus. The
// previous TorusMesh approach gave a thick "tube" look; a flat disc with a
// radial alpha mask reads correctly from any camera angle.

uniform vec3 ring_color : source_color = vec3(0.85, 0.78, 0.62);
uniform float inner_radius : hint_range(0.0, 1.0) = 0.55;
uniform float outer_radius : hint_range(0.0, 1.0) = 0.95;
uniform float opacity : hint_range(0.0, 1.0) = 0.7;
uniform float band_density : hint_range(0.0, 60.0) = 24.0;
uniform float band_strength : hint_range(0.0, 1.0) = 0.25;

void fragment() {
	// Plane UV runs 0..1 — recentre to -1..1 so distance-from-centre is just length().
	vec2 c = UV * 2.0 - 1.0;
	float d = length(c);

	// Smooth inner + outer cutoff so the ring edges fade instead of pixel-stepping.
	float inner = smoothstep(inner_radius - 0.012, inner_radius + 0.012, d);
	float outer = 1.0 - smoothstep(outer_radius - 0.012, outer_radius + 0.012, d);
	float ring_mask = inner * outer;

	// Radial bands carved by sin() — multiplicative on alpha so the ring
	// reads as discrete dust stripes with translucent gaps, not a glowing slab.
	float bands = 1.0 - band_strength + sin(d * band_density) * band_strength;
	bands = clamp(bands, 0.0, 1.0);

	// Soft edge falloff so the ring doesn't have a sharp opaque mid-band.
	float mid = (inner_radius + outer_radius) * 0.5;
	float half_w = (outer_radius - inner_radius) * 0.5;
	float edge_dist = abs(d - mid) / max(half_w, 0.001);
	float edge_fade = 1.0 - smoothstep(0.7, 1.0, edge_dist);

	ALBEDO = ring_color;
	ALPHA = ring_mask * opacity * bands * edge_fade;
}

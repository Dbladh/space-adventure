shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, depth_test_disabled;

// background_star.gdshader
// Per-instance twinkling pixel stars. Phase derived from world position so
// every star pulses on its own rhythm — zero CPU cost. Designed to read as
// a single chunky pixel through the SubViewportContainer pixelation.

uniform float twinkle_speed : hint_range(0.0, 8.0) = 2.4;
// Lower bound of the alpha sine wave — keeps faint stars always faintly lit
// instead of fully disappearing every cycle.
uniform float min_alpha : hint_range(0.0, 1.0) = 0.25;
// Optional emission boost so the bloom can grab the brightest twinkles.
uniform float emission_strength : hint_range(0.0, 4.0) = 1.6;

void fragment() {
	// Per-instance phase from world position — different for every star.
	float phase = MODEL_MATRIX[3].x * 0.137
		+ MODEL_MATRIX[3].y * 0.219
		+ MODEL_MATRIX[3].z * 0.083;
	float t = sin(TIME * twinkle_speed + phase * 6.2831);
	float twinkle = 0.5 + 0.5 * t;

	vec3 base = COLOR.rgb;
	float a = COLOR.a * mix(min_alpha, 1.0, twinkle);

	ALBEDO = base;
	ALPHA = a;
	EMISSION = base * emission_strength * (0.4 + 0.6 * twinkle);
}

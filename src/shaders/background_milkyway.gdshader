shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never;

// background_milkyway.gdshader
// Vibrant top-down spiral galaxy — cyan + purple arms with a bright core,
// matching the user's reference image. Slowly rotates and pulses; the
// SubViewportContainer's nearest-filter pixelation gives it the pixel-art
// look you see in the menu. depth_test stays on so the planets correctly
// occlude the backdrop.

uniform vec3 core_color : source_color = vec3(0.85, 1.0, 0.95);     // bright cyan-white centre
uniform vec3 arm_color_a : source_color = vec3(0.10, 0.85, 0.95);   // cyan arms
uniform vec3 arm_color_b : source_color = vec3(0.65, 0.20, 0.95);   // purple arms
uniform vec3 outer_color : source_color = vec3(0.45, 0.15, 0.80);   // deep violet halo

// Spiral parameters.
uniform float arm_count : hint_range(2.0, 6.0) = 3.0;
uniform float arm_twist : hint_range(2.0, 12.0) = 6.5;
uniform float core_radius : hint_range(0.05, 0.5) = 0.18;
uniform float falloff : hint_range(1.0, 8.0) = 3.4;
uniform float intensity : hint_range(0.0, 4.0) = 1.6;
// Slow self-rotation in radians/sec — gives the galaxy life without making
// the player notice it spinning during a quick menu visit.
uniform float rotation_speed : hint_range(0.0, 0.5) = 0.015;
// Per-instance offset so each session draws the spiral with a different
// starting phase (set from script).
uniform float phase_offset = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i + vec2(0, 0));
	float b = hash21(i + vec2(1, 0));
	float c = hash21(i + vec2(0, 1));
	float d = hash21(i + vec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p, int oct) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= oct) break;
		v += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	// Centre coords. UV runs 0..1, centre at (0.5, 0.5).
	vec2 c = UV * 2.0 - 1.0;
	float r = length(c);
	float theta = atan(c.y, c.x);

	// Rotate the disc — slow and constant.
	float t = TIME * rotation_speed + phase_offset;
	theta += t;

	// Log-spiral arm phase. Higher arm_twist = more tightly wound; arm_count
	// controls how many arms wrap around the disc.
	float arm_phase = theta * arm_count + log(r + core_radius * 0.3) * arm_twist;

	// Arm density profile — peaks at the arm centre, falls off between arms.
	// Squaring the cosine narrows the arm and brightens the centre.
	float arms = pow(0.5 + 0.5 * cos(arm_phase), 2.0);

	// Turbulent dust adds ragged variation along each arm so the spiral
	// reads as gas + stars rather than a clean geometric pattern.
	float dust = fbm(vec2(theta * 1.4 + t * 0.7, r * 6.0), 4);
	arms *= 0.55 + dust * 0.9;

	// Radial falloff — bright central bulge fading out toward the edge.
	float disc = exp(-r * falloff);

	// Bright unobstructed core.
	float core = smoothstep(core_radius * 1.4, core_radius * 0.4, r);

	// Colour mixing: yellow-white core → cyan arms → purple outer halo.
	// Per-fragment colour depends on the local arm phase so the two colours
	// alternate between adjacent arms instead of mixing into a wash.
	float arm_tint = 0.5 + 0.5 * sin(theta * arm_count * 0.5 + dust * 2.0);
	vec3 arm_col = mix(arm_color_a, arm_color_b, arm_tint);

	vec3 disc_col = mix(outer_color, arm_col, smoothstep(0.0, 0.45, disc));
	vec3 col = mix(disc_col, core_color, core);

	// Final intensity — arms × disc gives a falling-off spiral; core lifts
	// the centre to white-hot.
	float i_arms = arms * disc * intensity;
	float i_core = core * 1.5 * intensity;
	float a = clamp(i_arms + i_core, 0.0, 1.0);

	ALBEDO = col * (i_arms + i_core);
	ALPHA = a;
}

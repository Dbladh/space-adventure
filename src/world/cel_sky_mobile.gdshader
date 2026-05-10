shader_type sky;

// Mobile-tuned sky. Same uniform interface as cel_sky.gdshader so update code
// doesn't need to branch. Cuts texture lookups from 5 -> 1 and removes the
// per-pixel trig used for nebula/void color phasing — the visual identity
// holds at the 15% mobile render scale (~240x135).

uniform vec3 horizon_color : source_color = vec3(0.2, 0.65, 0.9);
uniform vec3 zenith_color : source_color = vec3(0.1, 0.45, 0.85);

uniform float space_blend : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.8);
uniform float sun_size : hint_range(0.0, 0.2) = 0.04;
uniform float sun_blur : hint_range(0.0, 0.2) = 0.01;

uniform sampler2D star_noise;
uniform sampler2D nebula_noise;
uniform sampler2D cloud_noise;

void sky() {
	// Local planetary up-vector (preserves the BOTW-style horizon alignment).
	// POSITION is constant per draw on a sky shader so the compiler can hoist this.
	vec3 up = normalize(POSITION - vec3(0.0, 0.0, -1800000.0));
	vec3 north = vec3(0.0, 1.0, 0.0);
	if (abs(dot(up, north)) > 0.99) north = vec3(0.0, 0.0, 1.0);
	vec3 right = normalize(cross(north, up));
	vec3 forward = cross(up, right);
	vec3 local_e = vec3(dot(right, EYEDIR), dot(up, EYEDIR), dot(forward, EYEDIR));

	// Cheap UV for stars/nebula. Skips the atan/acos polar transform — minor
	// pole distortion is invisible at mobile scale.
	vec2 sky_uv = EYEDIR.xz * 0.5 + 0.5;

	// Stars: single lookup, single threshold.
	float raw_stars = texture(star_noise, sky_uv * 8.0).r;
	vec3 stars = vec3(step(0.85, raw_stars) * 1.35);

	// Nebula: single lookup, fixed iconic purple-red tint (no sin/cos phase).
	float dust = texture(nebula_noise, sky_uv * 2.0).r;
	float band = smoothstep(0.1, 1.0, 1.0 - abs(EYEDIR.y * 1.8));
	dust = smoothstep(0.3, 0.8, dust * band) * 0.75;
	vec3 nebula_col = vec3(0.42, 0.03, 0.30); // mid-mix of purple+red, neb_pulse baked in

	// Deep void: fixed color (was 4 sin/cos + 3 mixes).
	vec3 void_col = vec3(0.02, 0.015, 0.035);
	vec3 space_col = mix(void_col, nebula_col, dust * 0.65) + stars;

	// Atmospheric gradient.
	float sky_grad = smoothstep(-0.35, 0.7, local_e.y);
	vec3 final_col = mix(horizon_color, zenith_color, sky_grad);

	// Skybox clouds removed — planet cloud shells handle real cloud cover
	// when near a body. cloud_noise uniform left declared so existing
	// material binding code in Main.gd doesn't warn.

	// Sun: disc + bloom only (starburst dropped — barely readable at 240x135).
	float sun_dot = max(0.0, dot(EYEDIR, LIGHT0_DIRECTION));
	float sun_disc = smoothstep(0.9992, 0.9996, sun_dot);
	vec3 out_sun = sun_disc * vec3(10.0);
	out_sun += pow(sun_dot, 60.0) * vec3(1.0, 0.95, 0.85) * 6.0;

	COLOR = mix(final_col, space_col, space_blend) + out_sun;
}

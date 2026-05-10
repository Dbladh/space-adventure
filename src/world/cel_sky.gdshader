shader_type sky;

uniform vec3 horizon_color : source_color = vec3(0.2, 0.65, 0.9);
uniform vec3 zenith_color : source_color = vec3(0.1, 0.45, 0.85);

uniform float space_blend : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.8);
uniform float sun_size : hint_range(0.0, 0.2) = 0.04;
uniform float sun_blur : hint_range(0.0, 0.2) = 0.01;

uniform sampler2D star_noise;
uniform sampler2D nebula_noise;
uniform sampler2D cloud_noise;

// Driven by MusicDirector's beat intensity each frame — peaks on every
// 16th-note step. Stars twinkle in time with the music when this is high.
uniform float music_beat : hint_range(0.0, 2.0) = 0.0;

void sky() {
	// 0. LOCAL PLANETARY HORIZON ROTATION
	vec3 up = normalize(POSITION - vec3(0.0, 0.0, -1800000.0));
	vec3 north = vec3(0.0, 1.0, 0.0);
	if (abs(dot(up, north)) > 0.99) north = vec3(0.0, 0.0, 1.0);
	vec3 right = normalize(cross(north, up));
	vec3 forward = cross(up, right);
	
	// Transform global EYEDIR into a localized atmospheric vector. 
	vec3 local_e = vec3(dot(right, EYEDIR), dot(up, EYEDIR), dot(forward, EYEDIR));
	
	// 1. DENSE GALACTIC NEBULA & TWINKLING STARS
	vec3 space_col = vec3(0.0);
	if (space_blend > 0.01) {
		vec2 polar_uv = vec2(atan(EYEDIR.z, EYEDIR.x) / (2.0 * PI) + 0.5, acos(EYEDIR.y) / PI);
		
		// Procedural Twinkling Stars — phase modulated by per-star noise so
		// each star peaks at a different point of the beat. music_beat
		// drives the overall brightness amplitude.
		float raw_stars = texture(star_noise, polar_uv * vec2(16.0, 8.0)).r;
		float star_mask = step(0.85, raw_stars);

		// Per-star phase comes from the noise value itself — different stars
		// twinkle at different phases of the same beat, so the field shimmers.
		float star_phase = raw_stars * 6.2832;
		float twinkle = 0.5 + music_beat * (0.5 + 0.5 * sin(star_phase));
		vec3 stars = vec3(star_mask * (0.6 + twinkle * 1.8));
		
		vec2 nebula_uv = polar_uv * vec2(2.0, 1.0);
		float dust = texture(nebula_noise, nebula_uv).r;
		float band = smoothstep(0.1, 1.0, 1.0 - abs(EYEDIR.y * 1.8)); 
		
		float neb_pulse = 0.75;
		dust = smoothstep(0.3, 0.8, dust * band) * neb_pulse;
		
		float c_phase = sin(polar_uv.x * PI * 2.0) * cos(polar_uv.y * PI * 2.0);
		c_phase = smoothstep(-0.5, 0.5, c_phase);
		
		vec3 c_purple = vec3(0.25, 0.0, 0.45);
		vec3 c_red = vec3(0.65, 0.05, 0.15);
		vec3 nebula_col = mix(c_purple, c_red, c_phase) * (0.8 + neb_pulse * 0.4);
		
		float void_phase1 = sin(polar_uv.x * PI * 2.0) * 0.5 + 0.5;
		float void_phase2 = cos(polar_uv.y * PI * 2.0) * 0.5 + 0.5;
		
		vec3 deep_black  = vec3(0.01, 0.01, 0.01);
		vec3 deep_blue   = vec3(0.01, 0.02, 0.05);
		vec3 deep_purple = vec3(0.03, 0.01, 0.04);
		vec3 deep_red    = vec3(0.04, 0.01, 0.02);
		
		vec3 void_mix1 = mix(deep_black, deep_blue, void_phase1);
		vec3 void_mix2 = mix(deep_purple, deep_red, 1.0 - void_phase1);
		vec3 void_col  = mix(void_mix1, void_mix2, void_phase2);
		
		space_col = mix(void_col, nebula_col, dust * 0.65) + stars;
	}
	
	// 2. STRIKING ATMOSPHERIC GRADIENT (Static Sunset)
	float sky_grad = smoothstep(-0.35, 0.7, local_e.y);
	vec3 final_col = mix(horizon_color, zenith_color, sky_grad);
	
	// Skybox clouds removed — they read as distracting streaks across the
	// atmosphere and over space. Planet cloud shells
	// (PlanetGen._spawn_majestic_clouds_and_rings) handle real cloud cover
	// near a body. cloud_noise uniform left declared so existing material
	// binding in Main.gd continues to bind without warnings.

	// 4. ICONIC TOON SUN (The central Great Sea star)
	float sun_dot = max(0.0, dot(EYEDIR, LIGHT0_DIRECTION));
	float sun_disc = smoothstep(0.9992, 0.9996, sun_dot); // Sharp, iconic disc
	
	// 4-POINT ICONIC STARBURST
	vec3 light_right = normalize(cross(LIGHT0_DIRECTION, vec3(0.0, 1.0, 0.0)));
	vec3 light_up = cross(light_right, LIGHT0_DIRECTION);
	float s_x = abs(dot(EYEDIR, light_right));
	float s_y = abs(dot(EYEDIR, light_up));
	float burst = pow(max(0.0, 1.0 - s_x * 8.0), 30.0) + pow(max(0.0, 1.0 - s_y * 8.0), 30.0);
	float starburst = burst * pow(sun_dot, 8.0) * 2.5;
	
	vec3 out_sun = (sun_disc * vec3(1.0) * 10.0) + (starburst * vec3(1.0));
	// Soft golden bloom around the disc
	out_sun += pow(sun_dot, 150.0) * vec3(1.0, 0.95, 0.85) * 6.0;
	
	// FINAL COMPOSITION: Atmospheric blend + The Star
	COLOR = mix(final_col, space_col, space_blend) + out_sun;
}

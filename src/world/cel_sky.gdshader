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
	vec2 polar_uv = vec2(atan(EYEDIR.z, EYEDIR.x) / (2.0 * PI) + 0.5, acos(EYEDIR.y) / PI);
	
	// Procedural Twinkling Stars
	float raw_stars = texture(star_noise, polar_uv * vec2(16.0, 8.0)).r;
	float star_mask = step(0.85, raw_stars);
	
	// ACE STATIC SYNC: Twinkle halted for cinematic stability
	float twinkle = 0.5; 
	vec3 stars = vec3(star_mask * (0.6 + twinkle * 1.5)); 
	
	// Soft, Transparent Milky Way Dust
	// Frozen nebula position for iconic visual alignment
	vec2 nebula_uv = polar_uv * vec2(2.0, 1.0);
	
	float dust = texture(nebula_noise, nebula_uv).r;
	float band = smoothstep(0.1, 1.0, 1.0 - abs(EYEDIR.y * 1.8)); 
	
	// PULSING GALAXY: Halted at 75% intensity for consistent contrast
	float neb_pulse = 0.75;
	dust = smoothstep(0.3, 0.8, dust * band) * neb_pulse;
	
	// Dynamic Shifting Colors: Static iconic purple-red blend
	float c_phase = sin(polar_uv.x * PI * 2.0) * cos(polar_uv.y * PI * 2.0);
	c_phase = smoothstep(-0.5, 0.5, c_phase);
	
	vec3 c_purple = vec3(0.25, 0.0, 0.45);
	vec3 c_red = vec3(0.65, 0.05, 0.15);
	vec3 nebula_col = mix(c_purple, c_red, c_phase) * (0.8 + neb_pulse * 0.4);
	
	// The Absolute Void: Halted phase loop
	float void_phase1 = sin(polar_uv.x * PI * 2.0) * 0.5 + 0.5;
	float void_phase2 = cos(polar_uv.y * PI * 2.0) * 0.5 + 0.5;
	
	vec3 deep_black  = vec3(0.01, 0.01, 0.01);
	vec3 deep_blue   = vec3(0.01, 0.02, 0.05);
	vec3 deep_purple = vec3(0.03, 0.01, 0.04);
	vec3 deep_red    = vec3(0.04, 0.01, 0.02);
	
	vec3 void_mix1 = mix(deep_black, deep_blue, void_phase1);
	vec3 void_mix2 = mix(deep_purple, deep_red, 1.0 - void_phase1);
	vec3 void_col  = mix(void_mix1, void_mix2, void_phase2);
	
	// Compositing the Universe
	vec3 space_col = mix(void_col, nebula_col, dust * 0.65) + stars;
	
	// 2. STRIKING ATMOSPHERIC GRADIENT (Static Sunset)
	float sky_grad = smoothstep(-0.35, 0.7, local_e.y);
	vec3 final_col = mix(horizon_color, zenith_color, sky_grad);
	
	// 3. ICONIC WINDWAKER CLOUDS (Deep-Space Throttle)
	// ACE: We dramatically reduce coordinate precision and movement when in orbit
	float cloud_throttle = 1.0 - space_blend;
	vec3 cl_pos1 = local_e * vec3(0.35, 1.2, 0.35); 
	
	// If in deep space, we freeze the UVs to a stable state to prevent shimmer
	vec2 cl_uv1 = cl_pos1.xz + cl_pos1.y * 0.15;
	if (cloud_throttle < 0.05) {
		cl_uv1 = floor(cl_uv1 * 100.0) / 100.0;
	}
	
	float base_n = texture(cloud_noise, cl_uv1).r;
	float bumpy_n = texture(cloud_noise, cl_uv1 * 3.5).r;
	float final_n = base_n + bumpy_n * 0.2; 
	float puff_mask1 = step(0.86, final_n);
	
	// ICONIC SHADOW SYNC
	vec2 shad_uv = cl_uv1 - vec2(0.02, 0.02);
	float n_shad = texture(cloud_noise, shad_uv).r + texture(cloud_noise, shad_uv * 3.5).r * 0.2;
	float is_shadow = puff_mask1 * (1.0 - step(0.86, n_shad));
	
	// Layer B: Distant horizon puffs
	vec2 cl_uv2 = (local_e * vec3(1.1, 2.5, 1.1)).xz;
	float n2 = texture(cloud_noise, cl_uv2).r;
	float puff_mask2 = step(0.92, n2);
	
	float cloud_mask = clamp(puff_mask1 + puff_mask2, 0.0, 1.0);
	
	// FADE AT HORIZON
	float atmospheric_wrap = smoothstep(0.04, 0.28, local_e.y);
	cloud_mask *= atmospheric_wrap;
	is_shadow *= atmospheric_wrap;
	
	final_col = mix(final_col, vec3(1.0), cloud_mask * (1.0 - space_blend));
	// LUMINOUS CLOUD HARDENING: Light airy feel
	vec3 light_shadow = mix(vec3(1.0), zenith_color, 0.15);
	final_col = mix(final_col, light_shadow, is_shadow * (1.0 - space_blend));
	
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

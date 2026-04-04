shader_type sky;

uniform vec3 horizon_color : source_color = vec3(0.2, 0.65, 0.9);
uniform vec3 zenith_color : source_color = vec3(0.1, 0.45, 0.85);

uniform float space_blend : hint_range(0.0, 1.0) = 1.0;
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.8);
uniform float sun_size : hint_range(0.0, 0.2) = 0.04;
uniform float sun_blur : hint_range(0.0, 0.2) = 0.01;

uniform sampler2D star_noise;
uniform sampler2D nebula_noise;
uniform sampler3D cloud_noise;

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
	
	// Multiply the raw noise value by 1000 as a sine offset, forcing every single star to twinkle totally out-of-sync!
	float twinkle = sin(TIME * 3.0 + raw_stars * 1000.0) * 0.5 + 0.5;
	vec3 stars = vec3(star_mask * (0.6 + twinkle * 1.5)); 
	
	// Soft, Transparent Milky Way Dust
	// Slowly drift the galactic nebula UVs to simulate a living universe
	vec2 nebula_uv = polar_uv * vec2(2.0, 1.0);
	nebula_uv.x += TIME * 0.002;
	nebula_uv.y += sin(TIME * 0.005) * 0.05;
	
	float dust = texture(nebula_noise, nebula_uv).r;
	float band = smoothstep(0.1, 1.0, 1.0 - abs(EYEDIR.y * 1.8)); 
	
	// PULSING GALAXY: Slow rhythmic fade in and out from 10% to 100% intensity
	float neb_pulse = sin(TIME * 0.05) * 0.45 + 0.55;
	dust = smoothstep(0.3, 0.8, dust * band) * neb_pulse;
	
	// Dynamic Shifting Colors
	float c_phase = sin(polar_uv.x * PI * 2.0 + TIME * 0.05) * cos(polar_uv.y * PI * 2.0 + TIME * 0.03);
	c_phase = smoothstep(-0.5, 0.5, c_phase);
	
	vec3 c_purple = vec3(0.25, 0.0, 0.45);
	vec3 c_red = vec3(0.65, 0.05, 0.15);
	vec3 nebula_col = mix(c_purple, c_red, c_phase) * (0.8 + neb_pulse * 0.4);
	
	// The Absolute Void
	// Slowly interpolates between incredibly subtle dark hues so the deep space background is never completely flat
	// Multipliers on PI must be EVEN INTEGERS (2.0, 4.0) to ensure the seams perfectly loop!
	float void_phase1 = sin(polar_uv.x * PI * 2.0 + TIME * 0.015) * 0.5 + 0.5;
	float void_phase2 = cos(polar_uv.y * PI * 2.0 - TIME * 0.01) * 0.5 + 0.5;
	
	vec3 deep_black  = vec3(0.01, 0.01, 0.01);
	vec3 deep_blue   = vec3(0.01, 0.02, 0.05);
	vec3 deep_purple = vec3(0.03, 0.01, 0.04);
	vec3 deep_red    = vec3(0.04, 0.01, 0.02);
	
	vec3 void_mix1 = mix(deep_black, deep_blue, void_phase1);
	vec3 void_mix2 = mix(deep_purple, deep_red, 1.0 - void_phase1);
	vec3 void_col  = mix(void_mix1, void_mix2, void_phase2);
	
	// Compositing the Universe (Lowering dust multiplier to 65% makes it beautifully transparent!)
	vec3 space_col = mix(void_col, nebula_col, dust * 0.65) + stars;
	
	// 2. STRIKING ATMOSPHERIC GRADIENT (Animated Sunset)
	// Make the horizon mathematically breathe/pulse slightly using TIME
	float horizon_pulse = sin(TIME * 0.3) * 0.08;
	
	// Shift the gradient up slightly and blend the colors with the animated pulse
	float sky_grad = smoothstep(-0.35, 0.7 + horizon_pulse, local_e.y);
	
	// Force the horizon band to be extraordinarily vivid for that glowing sunset look
	vec3 glowing_horizon = mix(horizon_color, horizon_color * 1.5, abs(horizon_pulse) * 5.0);
	vec3 final_col = mix(glowing_horizon, zenith_color, sky_grad);
	
	// 3. HORIZONTAL TOON CLOUDS
	// Squash clouds strictly vertically relative to local gravity to form Zelda banks
	vec3 cl_pos = local_e * vec3(2.0, 5.5, 2.0);
	cl_pos.x += TIME * 0.02; // Rapid horizontal drift
	cl_pos.z += cos(TIME * 0.15) * 0.1; // Gentle coordinate shifting
	float n = texture(cloud_noise, cl_pos).r;
	
	// Dynamic Shifting Cloud Density
	float c_pulse = sin(TIME * 0.1) * 0.04;
	float c_target = 0.62 + c_pulse;
	float cloud_mask = step(c_target, n);
	
	// TRUE LOCAL DOWN-SHADOWING
	vec3 lower_pos = cl_pos;
	lower_pos.y -= 0.15; 
	float n_lower = texture(cloud_noise, lower_pos).r;
	
	float is_bottom = cloud_mask * (1.0 - step(c_target, n_lower));
	float is_top = cloud_mask - is_bottom;
	
	// FADE CLOUDS AT THE HORIZON
	// Gradually dissolve clouds slightly above the horizon (0.15) down to the absolute horizon (0.02)
	// This prevents clouds from intersecting or bunching up tightly against the terrain mesh!
	float atmospheric_wrap = smoothstep(0.02, 0.15, local_e.y);
	is_top *= atmospheric_wrap;
	is_bottom *= atmospheric_wrap;
	
	// Shadows render as a dark stain on the local zenith color
	// Tops are painted white, but restricted to 75% alpha! This makes the clouds somewhat transparent!
	final_col = mix(final_col, final_col * 0.70, is_bottom * (1.0 - space_blend));
	final_col = mix(final_col, vec3(1.0), is_top * 0.75 * (1.0 - space_blend));
	
	// 4. THE CENTRAL STAR (SUN)
	// Calculate a razor-sharp sun disc that aligns perfectly with the main light source
	float sun_dot = max(0.0, dot(EYEDIR, LIGHT0_DIRECTION));
	float s_size = 0.022; // Slightly smaller and sharper
	float s_blur = 0.008;
	float sun_disc = smoothstep(1.0 - s_size - s_blur, 1.0 - s_size, sun_dot);
	
	// WARM PHOTONIC CORE
	vec3 warm_sun = mix(sun_color, vec3(1.0, 0.6, 0.2), 0.5);
	
	// Add a massive procedural corona glow around the star
	float sun_glow = pow(sun_dot, 80.0) * 5.0; 
	vec3 out_sun = (sun_disc * warm_sun * 30.0) + (sun_glow * warm_sun * 8.0);
	
	// 5. CINEMATIC STARBURST & HALO
	vec3 light_right = normalize(cross(LIGHT0_DIRECTION, vec3(0.0, 1.0, 0.0)));
	vec3 light_up = cross(light_right, LIGHT0_DIRECTION);
	
	// A. ORBITAL HALO RING (Thin glowing circle)
	float halo_dist = 0.94;
	float halo = smoothstep(halo_dist - 0.005, halo_dist, sun_dot) * (1.0 - smoothstep(halo_dist, halo_dist + 0.005, sun_dot));
	out_sun += halo * warm_sun * 4.0;
	
	// B. HIGH-FREQUENCY STARBURST (Thin rays)
	float angle = atan(dot(EYEDIR, light_right), dot(EYEDIR, light_up));
	// Multi-frequency wave interference creates realistic, non-uniform ray patterns
	float ray_pattern = pow(abs(sin(angle * 45.0)), 12.0) + pow(abs(cos(angle * 12.0 + 0.5)), 8.0) * 0.4;
	float starburst = ray_pattern * pow(sun_dot, 150.0) * 15.0;
	out_sun += starburst * warm_sun;
	
	// C. ANAMORPHIC HORIZONTAL STREAK
	float flare_h = pow(max(0.0, 1.0 - abs(dot(EYEDIR, light_right)) * 18.0), 220.0);
	out_sun += flare_h * warm_sun * 6.0 * pow(sun_dot, 4.0);
	
	// FINAL COMPOSITION: Atmospheric blend + The Star
	COLOR = mix(final_col, space_col, space_blend) + out_sun;
}

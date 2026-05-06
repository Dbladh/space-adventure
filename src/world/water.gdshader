shader_type spatial;
render_mode diffuse_lambert, blend_mix;

// Procedural ocean / lava shader (FloatingOrigin-proof: samples LOCAL space).
// Drives water colour from the planet's pal_water_* palette.

uniform float radius = 1000000.0;
uniform vec3 pal_water_base  : source_color = vec3(0.0, 0.35, 0.95);
uniform vec3 pal_water_light : source_color = vec3(0.0, 0.65, 1.00);
uniform vec3 pal_water_shore : source_color = vec3(0.3, 0.85, 1.00);
uniform bool is_lava = false;

varying vec3 v_local_pos;     // Local-space position (immune to origin-shift drift)
varying float v_shore;        // 0=deep ocean, 1=shoreline (baked into vertex color)
varying vec3 v_world_normal;  // World-space normal for lighting

// Hash-based 2D value noise (no axis-aligned grid artefacts).
vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	float a = hash2(i).x;
	float b = hash2(i + vec2(1.0, 0.0)).x;
	float c = hash2(i + vec2(0.0, 1.0)).x;
	float d = hash2(i + vec2(1.0, 1.0)).x;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.6;
	float freq = 1.0;
	v += value_noise(p * freq) * amp;
	freq *= 2.1; amp *= 0.45;
	v += value_noise(vec2(p.y - p.x, p.x + p.y) * freq * 0.7) * amp;
	return v;
}

void vertex() {
	v_shore = COLOR.r;
	v_local_pos = VERTEX;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);

	// Animate waves only when the camera is close.
	float d_to_cam = distance((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD);
	float wave_mask = 1.0 - smoothstep(1500.0, 4000.0, d_to_cam);
	if (wave_mask > 0.01) {
		// Smooth continuous time — old shader quantized to 1/8 s
		// floor steps then scaled, producing visible jerks.
		float wt = TIME * 0.9;
		float disp = sin(dot(VERTEX.xz, vec2(0.047,  0.031)) + wt * 1.2) * 2.2
				   + sin(dot(VERTEX.xz, vec2(-0.039, 0.052)) + wt * 0.9) * 1.8
				   + sin(dot(VERTEX.xz, vec2(0.028, -0.061)) + wt * 1.5) * 1.4
				   + sin(dot(VERTEX.xz, vec2(0.057,  0.023)) + wt * 0.7) * 1.0;
		VERTEX += normalize(VERTEX) * disp * wave_mask;
	}
}

void fragment() {
	float d_to_cam = distance((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD);
	float wave_mask = 1.0 - smoothstep(2000.0, 5000.0, d_to_cam);
	// Smooth time — was floor(TIME * 8.0) / 8.0, which froze the noise
	// pattern in 1/8 s steps and made each "frame" of the noise read as a
	// stamp of discrete cells (the diamond patches in the water).
	float wt = TIME;
	float shore = v_shore;

	float SCALE = 0.0018;
	vec2 ocean_uv = v_local_pos.xz * SCALE;

	float wave_cel = 0.0;
	float crest_cel = 0.0;
	float shore_rings = 0.0;

	if (wave_mask > 0.01) {
		float warp_speed = 0.07;
		vec2 warp = vec2(
			fbm(ocean_uv + vec2(wt * warp_speed, 1.7)),
			fbm(ocean_uv + vec2(3.4, wt * warp_speed * 0.8))
		) * 0.8 - 0.4;
		float shoal_freq = mix(1.0, 1.8, smoothstep(0.2, 0.8, shore));
		// Add a higher-frequency detail octave so the dominant fbm cell
		// (~500 m at SCALE=0.0018) doesn't read as one big diamond patch
		// at low altitude — the detail breaks the silhouette.
		float ocean_n = fbm((ocean_uv + warp) * shoal_freq + vec2(wt * 0.06, wt * 0.04));
		float ocean_d = fbm((ocean_uv + warp) * shoal_freq * 4.3 + vec2(-wt * 0.08, wt * 0.05));
		ocean_n = ocean_n * 0.78 + ocean_d * 0.22;

		// Soft thresholds via smoothstep — old hard step()s stamped out
		// discrete polygonal cells when noise crossed the cutoff.  Now
		// wave swells feather into one another organically.
		wave_cel  = smoothstep(0.46, 0.62, ocean_n) * (1.0 - smoothstep(0.62, 0.78, ocean_n));
		crest_cel = smoothstep(0.66, 0.82, ocean_n);

		float deep_mask = smoothstep(0.75, 0.25, shore);
		wave_cel  *= (deep_mask * wave_mask);
		crest_cel *= (deep_mask * wave_mask);

		if (shore > 0.02 && shore < 0.97) {
			float s_warped = shore + (ocean_n - 0.5) * 0.12;
			float ring_a = sin(s_warped * 32.0 - wt * 3.2);
			float ring_b = sin(s_warped * 18.0 - wt * 2.0);
			shore_rings = clamp(pow(max(0.0, ring_a * ring_b), 3.5) * 12.0, 0.0, 1.0) * wave_mask;
		}
	}

	// Shimmer — also softened.  step() was creating sharp-edged glitter
	// patches that read as small diamond highlights against the ocean.
	float shimmer_n = fbm(v_local_pos.xz * 0.009 + vec2(wt * 0.4, -wt * 0.35));
	float shimmer = smoothstep(0.74, 0.88, shimmer_n)
				  * smoothstep(0.35, 0.55, dot(v_world_normal, vec3(0.0, 1.0, 0.0)));
	shimmer *= smoothstep(0.45, 0.0, shore);

	float fresnel = pow(1.0 - dot(NORMAL, VIEW), 3.0);
	vec3 col = pal_water_base;
	col = mix(col, pal_water_light, wave_cel * 0.55);
	col = mix(col, vec3(1.0), crest_cel * 0.45);
	col = mix(col, vec3(1.0), shore_rings);
	col = mix(col, vec3(1.0, 1.0, 0.93), shimmer * 0.85);

	ALBEDO = col;
	if (is_lava) {
		EMISSION = col * (fresnel + 0.5) * 1.2;
	}
	METALLIC = 0.0;
	ROUGHNESS = 0.08;
}

void light() {
	float l_level = dot(NORMAL, LIGHT);
	float t_shadow = step(0.15, l_level);
	float t_bright = step(0.65, l_level);
	vec3 shadow_col = ALBEDO * 0.60;
	vec3 lit_col    = ALBEDO * 0.90;
	vec3 bright_col = ALBEDO * 1.05;
	vec3 final_col  = mix(shadow_col, lit_col, t_shadow);
	final_col       = mix(final_col, bright_col, t_bright);
	DIFFUSE_LIGHT  += final_col * LIGHT_COLOR * ATTENUATION;

	// Tight believable sun glint, not a screen-wide hot spot.
	vec3 H = normalize(LIGHT + VIEW);
	float NdotH = max(dot(NORMAL, H), 0.0);
	float spec_mid  = step(0.985, NdotH);
	float spec_core = step(0.996, NdotH);
	vec3 sun_halo = LIGHT_COLOR * vec3(1.0, 0.92, 0.70) * 0.7;
	vec3 sun_core = vec3(1.0, 0.98, 0.90) * 1.3;
	float lit_mask = t_shadow * ATTENUATION;
	SPECULAR_LIGHT += (sun_halo * spec_mid + sun_core * spec_core) * lit_mask;
}

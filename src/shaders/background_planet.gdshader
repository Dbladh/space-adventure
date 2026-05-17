shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// background_planet.gdshader
// Simplified spherical-planet shader for the start screen. Reads as a real
// game-world planet without needing PlanetGen's chunk system — one SphereMesh
// + procedural fbm + a rim-glow atmosphere.

// Three palette stops driving water/lowlands → land → highlands.
uniform vec3 color_water : source_color = vec3(0.18, 0.42, 0.72);
uniform vec3 color_land  : source_color = vec3(0.32, 0.62, 0.28);
uniform vec3 color_high  : source_color = vec3(0.78, 0.68, 0.45);
uniform vec3 color_atmo  : source_color = vec3(0.6, 0.8, 1.0);

// Seed per-planet so each instance has a unique continent layout.
uniform float seed : hint_range(0.0, 100.0) = 0.0;
// Larger = finer continents.
uniform float noise_scale : hint_range(0.5, 6.0) = 1.6;
// Surface land-water balance. 0.55 = roughly half-and-half.
uniform float sea_level : hint_range(0.2, 0.8) = 0.55;
// Coast sharpness — small = pixel-snap shoreline (matches in-game look),
// large = soft beach gradient. Game-world planets read crisp at 0.015.
uniform float coast_sharpness : hint_range(0.001, 0.2) = 0.015;
// Cloud band density (0 = no clouds).
uniform float cloud_density : hint_range(0.0, 1.0) = 0.45;
// Atmosphere rim glow strength.
uniform float atmo_strength : hint_range(0.0, 2.0) = 0.6;
// Slow spin rate in radians/sec around object-space Y.
uniform float spin_rate : hint_range(0.0, 0.5) = 0.04;
// Color saturation boost for premium archetypes (AURORA/CRYSTAL).
uniform float emission_strength : hint_range(0.0, 1.0) = 0.0;
// Overall colour vividness pushed into the output. Bumping this brightens
// the planet without changing the underlying palette.
uniform float vividness : hint_range(1.0, 2.5) = 1.35;
// Pure saturation multiplier — pushes colours away from grey. 1.0 = no-op,
// 1.5 = noticeably bolder, 2.0 = arcade-saturated.
uniform float saturation : hint_range(0.5, 2.5) = 1.5;

// ── Hash + value noise (IQ-style) ─────────────────────────────────────

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash31(i + vec3(0,0,0));
	float b = hash31(i + vec3(1,0,0));
	float c = hash31(i + vec3(0,1,0));
	float d = hash31(i + vec3(1,1,0));
	float e = hash31(i + vec3(0,0,1));
	float g = hash31(i + vec3(1,0,1));
	float h = hash31(i + vec3(0,1,1));
	float k = hash31(i + vec3(1,1,1));
	return mix(
		mix(mix(a, b, f.x), mix(c, d, f.x), f.y),
		mix(mix(e, g, f.x), mix(h, k, f.x), f.y),
		f.z
	);
}

float fbm(vec3 p, int octaves) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= octaves) break;
		v += amp * vnoise(p);
		p *= 2.0;
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	// Rotate sample point around Y so the surface spins gently without the
	// sphere transform actually moving (avoids breaking the camera framing).
	float a = TIME * spin_rate + seed * 0.137;
	float cs = cos(a); float sn = sin(a);
	vec3 p = NORMAL;  // unit-sphere direction in object space (smooth-shaded sphere)
	p = vec3(cs * p.x + sn * p.z, p.y, -sn * p.x + cs * p.z);
	p *= noise_scale;
	p += vec3(seed * 1.3, seed * 2.1, seed * 0.7);

	float terrain = fbm(p, 5);                   // continents
	float detail  = fbm(p * 3.2 + 17.0, 3);      // fine relief
	float h_val = terrain + detail * 0.18;

	// Sharp coastline like the in-game planets: water and land are bold
	// distinct colours with only a thin smoothstep window between them.
	float coast = smoothstep(sea_level - coast_sharpness, sea_level + coast_sharpness, h_val);

	// Below water: deep blue → shallow blue gradient, no land bleed.
	vec3 deep = color_water * 0.7;
	vec3 shallow = color_water;
	vec3 below = mix(deep, shallow, smoothstep(sea_level - 0.35, sea_level, h_val));

	// Above water: land → highlands. Wider transition so high terrain shows
	// a clear secondary band.
	vec3 above = mix(color_land, color_high, smoothstep(sea_level + 0.08, sea_level + 0.45, h_val));

	vec3 col = mix(below, above, coast);

	// Cloud band — independent noise field, drifts at half spin rate.
	if (cloud_density > 0.01) {
		vec3 cp = p * 1.4 + vec3(TIME * 0.015, 0.0, 0.0);
		float clouds = fbm(cp, 4);
		float cloud_mask = smoothstep(0.55, 0.78, clouds) * cloud_density;
		col = mix(col, vec3(1.0), cloud_mask * 0.7);
	}

	// Atmosphere rim — Fresnel-based, additive.
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - ndv, 3.0);

	// Apply vividness (gamma-style brightening) + explicit saturation push so
	// the planet doesn't get desaturated by FILMIC tonemap + ambient light.
	vec3 boosted = pow(col, vec3(1.0 / vividness));
	float lum = dot(boosted, vec3(0.299, 0.587, 0.114));
	boosted = mix(vec3(lum), boosted, saturation);

	ALBEDO = boosted;
	METALLIC = 0.0;
	ROUGHNESS = 0.95;
	// Emission keeps the bold colours visible regardless of lighting falloff.
	// Higher base (0.35) than before so the dark side of each planet still
	// reads as the right hue rather than going grey.
	EMISSION = color_atmo * rim * atmo_strength + boosted * (0.35 + emission_strength * 0.5);
}

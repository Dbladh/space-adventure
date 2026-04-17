shader_type canvas_item;

uniform float intensity : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

void fragment() {
	vec4 color = texture(SCREEN_TEXTURE, SCREEN_UV);
	
	// 1. RADIAL VIGNETTE
	vec2 center = vec2(0.5, 0.5);
	float dist = distance(SCREEN_UV, center);
	float vignette = smoothstep(0.4, 0.9, dist);
	
	// 2. HEAT DISTORTION (Subtle UV wobble)
	// ACE: Distortion is expensive on Mobile (fetches screen texture)
	// We only enable it on Desktop for maximum atmospheric performance.
	vec2 distortion = vec2(0.0);
	#if !defined(MOBILE)
	distortion = vec2(
		sin(TIME * 5.0 + SCREEN_UV.y * 10.0),
		cos(TIME * 5.2 + SCREEN_UV.x * 12.0)
	) * 0.005 * intensity;
	#endif
	vec4 distorted_color = texture(SCREEN_TEXTURE, SCREEN_UV + distortion);
	
	// 3. COLOR BLEND: From deep red to bright orange
	vec3 heat_color = mix(vec3(0.8, 0.1, 0.0), vec3(1.0, 0.4, 0.0), vignette);
	
	// Apply intensity modifier
	float final_vignette = vignette * intensity * 0.8;
	COLOR.rgb = mix(distorted_color.rgb, heat_color, final_vignette);
	
	// 4. SUBTLE OVERALL RED TINT
	COLOR.rgb = mix(COLOR.rgb, vec3(1.0, 0.1, 0.0), intensity * 0.15);
	COLOR.a = 1.0;
}

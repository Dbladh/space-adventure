shader_type canvas_item;

uniform float pixel_size : hint_range(1, 20) = 6.0;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.4;
uniform float saturation : hint_range(0.0, 3.0) = 1.6;
uniform float contrast : hint_range(0.0, 3.0) = 1.35;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_nearest;

// Larger Bayer Matrix for pronounced hardware-restricted look (8x8)
float bayer8(ivec2 p) {
    int x = p.x % 8;
    int y = p.y % 8;
    const int m[64] = int[](
         0, 32,  8, 40,  2, 34, 10, 42,
        48, 16, 56, 24, 50, 18, 58, 26,
        12, 44,  4, 36, 14, 46,  6, 38,
        60, 28, 52, 20, 62, 30, 54, 22,
         3, 35, 11, 43,  1, 33,  9, 41,
        51, 19, 59, 27, 49, 17, 57, 25,
        15, 47,  7, 39, 13, 45,  5, 37,
        63, 31, 55, 23, 61, 29, 53, 21
    );
    return float(m[y * 8 + x]) / 64.0;
}

void fragment() {
    // 1. CHUNKY PIXEL GRID
    vec2 size = vec2(textureSize(SCREEN_TEXTURE, 0));
    vec2 p_size = size / pixel_size;
    vec2 uv = floor(SCREEN_UV * p_size) / p_size;
    
    // 2. PRIMARY SAMPLING
    vec3 scene_col = texture(SCREEN_TEXTURE, uv).rgb;
    
    // 3. COLOR HARDENING (Reference style: Purple/Orange/Hot-Pink pop)
    // Contrast boost to crush blacks and blow out highlights
    scene_col = (scene_col - 0.5) * contrast + 0.5;
    
    // Saturaion boost for Neon-Noir palette
    float lum = dot(scene_col, vec3(0.299, 0.587, 0.114));
    scene_col = mix(vec3(lum), scene_col, saturation);
    
    // 4. AGGRESSIVE 8x8 DITHERING
    // Maps screen coordinates to the pixel-art grid scale
    ivec2 d_pos = ivec2(FRAGCOORD.xy / pixel_size);
    float d_val = bayer8(d_pos);
    
    // Apply dither primarily to the midtones for that 'Airbrushed Pixel' look
    float d_mask = (1.0 - abs(lum - 0.5) * 2.0) * dither_strength;
    scene_col += (d_val - 0.5) * d_mask;
    
    // 5. PALETTE CRUSH (4-bit per channel - 16-level banding)
    // This creates the distinct banding 'stairs' seen in the reference image
    scene_col = floor(scene_col * 5.0 + 0.5) / 5.0;
    
    // 6. TINT HARDENING: Force shadows to a deep purple/blue bias
    vec3 shadow_tint = vec3(0.1, 0.0, 0.2);
    scene_col = mix(shadow_tint, scene_col, smoothstep(-0.1, 0.4, lum));

    COLOR = vec4(scene_col, 1.0);
}

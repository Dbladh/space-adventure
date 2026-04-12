shader_type canvas_item;

uniform float pixel_size : hint_range(1, 20) = 4.0;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.25;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_nearest;

// Bayer Matrix for Ordering Dithering (4x4)
const mat4 bayer_matrix = mat4(
    vec4(0.0625, 0.5625, 0.1875, 0.6875),
    vec4(0.8125, 0.3125, 0.9375, 0.4375),
    vec4(0.25, 0.75, 0.125, 0.625),
    vec4(1.0, 0.5, 0.875, 0.375)
);

void fragment() {
    // 1. FIXED PIXEL GRID (Simulate hardware low-res buffer)
    vec2 size = vec2(textureSize(SCREEN_TEXTURE, 0));
    vec2 p_size = size / pixel_size;
    vec2 uv = floor(SCREEN_UV * p_size) / p_size;
    
    // 2. SCENE COLOR SAMPLING
    vec3 scene_col = texture(SCREEN_TEXTURE, uv).rgb;
    
    // 3. SHADOWGLASS VIBRANCE: Saturated but crunchy color depth
    float lum = dot(scene_col, vec3(0.299, 0.587, 0.114));
    scene_col = mix(vec3(lum), scene_col, 1.25); // Boost color richness
    
    // 4. LUMINANCE-STEERED DITHERING
    // Dither intensity spikes in mid-tones and gradients to simulate painterly depth
    ivec2 pixel = ivec2(FRAGCOORD.xy / pixel_size);
    float dither = bayer_matrix[pixel.x % 4][pixel.y % 4];
    
    // Focused dither mask for textured transitions
    float d_mask = (1.0 - abs(lum - 0.5) * 2.0) * dither_strength;
    scene_col += (dither - 0.5) * d_mask;
    
    // 5. CRUNCHY PALETTE CLAMP (6-level bit depth for extreme retro banding)
    scene_col = floor(scene_col * 6.5 + 0.5) / 6.5;

    COLOR = vec4(scene_col, 1.0);
}

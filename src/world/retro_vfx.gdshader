shader_type canvas_item;

uniform float pixel_size : hint_range(1, 20) = 2.0;
uniform float dither_strength : hint_range(0.0, 1.0) = 0.08;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_nearest;

// Bayer Matrix for Ordering Dithering (4x4)
const mat4 bayer_matrix = mat4(
    vec4(0.0625, 0.5625, 0.1875, 0.6875),
    vec4(0.8125, 0.3125, 0.9375, 0.4375),
    vec4(0.25, 0.75, 0.125, 0.625),
    vec4(1.0, 0.5, 0.875, 0.375)
);

void fragment() {
    // 1. PIXELATION
    vec2 size = vec2(textureSize(SCREEN_TEXTURE, 0));
    vec2 uv = floor(SCREEN_UV * size / pixel_size) / (size / pixel_size);
    
    vec4 scene_color = texture(SCREEN_TEXTURE, uv);
    
    // 2. DITHERING
    ivec2 pixel = ivec2(FRAGCOORD.xy / pixel_size);
    float threshold = bayer_matrix[pixel.x % 4][pixel.y % 4];
    scene_color.rgb += (threshold - 0.5) * dither_strength;
    
    // 3. SCANLINES
    float scanline = sin(FRAGCOORD.y * 1.5) * 0.04;
    scene_color.rgb -= scanline;
    
    // 4. COLOR CRUNCH (16-level bit depth for cleaner toon gradients)
    scene_color.rgb = floor(scene_color.rgb * 16.0) / 16.0;

    COLOR = scene_color;
}

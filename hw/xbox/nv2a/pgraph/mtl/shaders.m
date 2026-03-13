/*
 * Metal Renderer - Shaders
 *
 * Compiles and manages MSL shaders for the renderer
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>

static const char *vertex_shader_msl = 
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct VertexAttribute {\n"
"    float4 position;\n"
"    float4 color;\n"
"    float2 texcoord;\n"
"    float3 normal;\n"
"};\n"
"\n"
"struct VertexShaderOutput {\n"
"    float4 position [[position]];\n"
"    float4 color;\n"
"    float2 texcoord;\n"
"    float3 normal;\n"
"};\n"
"\n"
"struct Uniforms {\n"
"    float4x4 model_view_projection;\n"
"    float4x4 model_view;\n"
"    float4x4 projection;\n"
"    float time;\n"
"    float alpha;\n"
"};\n"
"\n"
"vertex VertexShaderOutput vertex_main(uint vertexID [[vertex_id]],\n"
"                                     constant VertexAttribute *vertices [[buffer(0)]],\n"
"                                     constant Uniforms &uniforms [[buffer(1)]]) {\n"
"    VertexShaderOutput out;\n"
"    \n"
"    out.position = uniforms.model_view_projection * vertices[vertexID].position;\n"
"    out.color = vertices[vertexID].color * uniforms.alpha;\n"
"    out.texcoord = vertices[vertexID].texcoord;\n"
"    out.normal = vertices[vertexID].normal;\n"
"    \n"
"    return out;\n"
"}\n";

static const char *fragment_shader_msl =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct FragmentShaderInput {\n"
"    float4 position [[position]];\n"
"    float4 color;\n"
"    float2 texcoord;\n"
"    float3 normal;\n"
"};\n"
"\n"
"struct FragmentUniforms {\n"
"    float4 ambient;\n"
"    float4 diffuse;\n"
"    float4 specular;\n"
"    float shininess;\n"
"    float alpha;\n"
"    int texture_enabled;\n"
"    int lighting_enabled;\n"
"};\n"
"\n"
"fragment float4 fragment_main(FragmentShaderInput in [[stage_in]],\n"
"                            constant FragmentUniforms &uniforms [[buffer(0)]],\n"
"                            texture2d<float> colorTexture [[texture(0)]],\n"
"                            sampler textureSampler [[sampler(0)]]) {\n"
"    float4 color = in.color;\n"
"    \n"
"    if (uniforms.texture_enabled != 0) {\n"
"        float4 texColor = colorTexture.sample(textureSampler, in.texcoord);\n"
"        color = texColor * color;\n"
"    }\n"
"    \n"
"    if (uniforms.lighting_enabled != 0) {\n"
"        float3 normal = normalize(in.normal);\n"
"        float4 ambient = uniforms.ambient * color;\n"
"        float4 diffuse = uniforms.diffuse * max(dot(normal, float3(0, 0, 1)), 0.0);\n"
"        color = ambient + diffuse + uniforms.specular;\n"
"    }\n"
"    \n"
"    color.a *= uniforms.alpha;\n"
"    \n"
"    return color;\n"
"}\n";

static const char *texture_fragment_shader_msl =
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct TextureVertexOutput {\n"
"    float4 position [[position]];\n"
"    float2 texcoord;\n"
"};\n"
"\n"
"fragment float4 texture_fragment(TextureVertexOutput in [[stage_in]],\n"
"                               texture2d<float> colorTexture [[texture(0)]],\n"
"                               sampler textureSampler [[sampler(0)]]) {\n"
"    return colorTexture.sample(textureSampler, in.texcoord);\n"
"}\n";

void pgraph_mtl_shaders_init(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing shaders\n");
    
    if (!r->device) {
        fprintf(stderr, "Metal: No device for shader init\n");
        r->initialized = false;
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    NSError *error = nil;
    
    NSString *combinedSrc = [NSString stringWithUTF8String:vertex_shader_msl];
    combinedSrc = [combinedSrc stringByAppendingString:[NSString stringWithUTF8String:fragment_shader_msl]];
    combinedSrc = [combinedSrc stringByAppendingString:[NSString stringWithUTF8String:texture_fragment_shader_msl]];
    
    id<MTLLibrary> library = [device newLibraryWithSource:combinedSrc options:nil error:&error];
    if (error) {
        fprintf(stderr, "Metal: Failed to compile shaders: %s\n", [[error localizedDescription] UTF8String]);
        r->initialized = false;
        return;
    }
    
    r->shader_library = (__bridge void *)library;
    
    fprintf(stderr, "Metal: Shaders compiled successfully\n");
}

void pgraph_mtl_shaders_destroy(PGRAPHMTLState *r)
{
    if (r->shader_library) {
        r->shader_library = nil;
    }
}

#endif

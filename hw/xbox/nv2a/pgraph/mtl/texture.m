/*
 * Metal Renderer - Texture Management
 *
 * Manages texture loading and binding
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>

#define MAX_TEXTURES 16

typedef struct {
    void *texture;
    uint32_t width;
    uint32_t height;
    uint32_t format;
    uint64_t hash;
    bool valid;
} TextureSlot;

void pgraph_mtl_init_textures(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing textures\n");
    
    if (!r->device) {
        fprintf(stderr, "Metal: No device for texture init\n");
        return;
    }
    
    r->texture_cache = calloc(MAX_TEXTURES, sizeof(TextureSlot));
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.mipFilter = MTLSamplerMipFilterLinear;
    samplerDesc.sAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.tAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.rAddressMode = MTLSamplerAddressModeRepeat;
    samplerDesc.maxAnisotropy = 16;
    
    r->sampler_state = (__bridge void *)[device newSamplerStateWithDescriptor:samplerDesc];
    
    fprintf(stderr, "Metal: Textures initialized with %d slots\n", MAX_TEXTURES);
}

void pgraph_mtl_destroy_textures(PGRAPHMTLState *r)
{
    if (r->texture_cache) {
        free(r->texture_cache);
        r->texture_cache = NULL;
    }
}

void pgraph_mtl_texture_update(PGRAPHMTLState *r, unsigned int slot)
{
    if (!r->device || slot >= MAX_TEXTURES) {
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    TextureSlot *textures = (TextureSlot *)r->texture_cache;
    TextureSlot *tex = &textures[slot];
    
    uint32_t width = 256;
    uint32_t height = 256;
    uint32_t format = MTLPixelFormatRGBA8Unorm;
    
    if (tex->texture && tex->width == width && tex->height == height && tex->format == format) {
        return;
    }
    
    if (tex->texture) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)tex->texture;
        t = nil;
        tex->texture = NULL;
    }
    
    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)format
                                                                                 width:width
                                                                                height:height
                                                                             mipmapped:NO];
    texDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    texDesc.storageMode = MTLStorageModeManaged;
    
    tex->texture = (__bridge void *)[device newTextureWithDescriptor:texDesc];
    tex->width = width;
    tex->height = height;
    tex->format = format;
    tex->valid = true;
}

void pgraph_mtl_bind_texture(PGRAPHMTLState *r, unsigned int slot)
{
    if (!r->render_encoder || slot >= MAX_TEXTURES) {
        return;
    }
    
    TextureSlot *textures = (TextureSlot *)r->texture_cache;
    TextureSlot *tex = &textures[slot];
    
    if (!tex->texture || !tex->valid) {
        return;
    }
    
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)r->render_encoder;
    id<MTLTexture> texture = (__bridge id<MTLTexture>)tex->texture;
    
    [encoder setFragmentTexture:texture atIndex:slot];
}

void pgraph_mtl_setup_texture_stage(PGRAPHMTLState *r, unsigned int stage)
{
    if (!r->device || stage >= MAX_TEXTURES) {
        return;
    }
    
    pgraph_mtl_texture_update(r, stage);
}

void pgraph_mtl_upload_texture_data(PGRAPHMTLState *r, unsigned int slot,
                                   const void *data, uint32_t width, uint32_t height)
{
    if (!r->device || slot >= MAX_TEXTURES) {
        return;
    }
    
    TextureSlot *textures = (TextureSlot *)r->texture_cache;
    TextureSlot *tex = &textures[slot];
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    MTLPixelFormat format = MTLPixelFormatRGBA8Unorm;
    NSInteger bytesPerPixel = 4;
    NSInteger bytesPerRow = width * bytesPerPixel;
    
    if (!tex->texture || tex->width != width || tex->height != height) {
        if (tex->texture) {
            id<MTLTexture> t = (__bridge id<MTLTexture>)tex->texture;
            t = nil;
            tex->texture = NULL;
        }
        
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:NO];
        texDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        texDesc.storageMode = MTLStorageModeManaged;
        
        tex->texture = (__bridge void *)[device newTextureWithDescriptor:texDesc];
        tex->width = width;
        tex->height = height;
        tex->format = format;
    }
    
    id<MTLTexture> texture = (__bridge id<MTLTexture>)tex->texture;
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
              mipmapLevel:0
                withBytes:data
              bytesPerRow:bytesPerRow];
    
    tex->valid = true;
}

#endif

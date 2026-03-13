/*
 * Metal Renderer - Surface Management
 *
 * Manages color and depth surfaces (framebuffers)
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stdlib.h>

#ifndef NV2A_STATE_C
#define NV2A_STATE_C
struct NV2AState;
typedef struct NV2AState NV2AState;
#endif

#ifndef PGRAPH_STATE_C
#define PGRAPH_STATE_C
struct PGRAPHState;
typedef struct PGRAPHState PGRAPHState;
#endif

#ifndef PGRAPH_STATE_C
#define PGRAPH_STATE_C
struct PGRAPHState;
typedef struct PGRAPHState PGRAPHState;
#endif

void pgraph_mtl_init_surfaces(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing surfaces\n");
    
    if (!r->device) {
        fprintf(stderr, "Metal: No device for surface init\n");
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    uint32_t width = r->viewport_width ? r->viewport_width : 640;
    uint32_t height = r->viewport_height ? r->viewport_height : 480;
    
    MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    colorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    colorDesc.storageMode = MTLStorageModePrivate;
    
    r->surface_color = (__bridge void *)[device newTextureWithDescriptor:colorDesc];
    
    MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                      width:width
                                                                                     height:height
                                                                                  mipmapped:NO];
    depthDesc.usage = MTLTextureUsageRenderTarget;
    depthDesc.storageMode = MTLStorageModePrivate;
    
    r->surface_zeta = (__bridge void *)[device newTextureWithDescriptor:depthDesc];
    
    r->framebuffer_texture = r->surface_color;
    
    fprintf(stderr, "Metal: Surfaces initialized (%dx%d)\n", width, height);
}

void pgraph_mtl_surface_update(PGRAPHMTLState *r)
{
    if (!r->device || !r->surface_color) {
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    uint32_t width = r->viewport_width;
    uint32_t height = r->viewport_height;
    
    if (width == 0) width = 640;
    if (height == 0) height = 480;
    
    id<MTLTexture> colorTex = (__bridge id<MTLTexture>)r->surface_color;
    
    if (colorTex.width != width || colorTex.height != height) {
        if (r->surface_color) {
            id<MTLTexture> t = (__bridge id<MTLTexture>)r->surface_color;
            t = nil;
            r->surface_color = NULL;
        }
        if (r->surface_zeta) {
            id<MTLTexture> d = (__bridge id<MTLTexture>)r->surface_zeta;
            d = nil;
            r->surface_zeta = NULL;
        }
        
        MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        colorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        colorDesc.storageMode = MTLStorageModePrivate;
        
        r->surface_color = (__bridge void *)[device newTextureWithDescriptor:colorDesc];
        
        MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
        depthDesc.usage = MTLTextureUsageRenderTarget;
        depthDesc.storageMode = MTLStorageModePrivate;
        
        r->surface_zeta = (__bridge void *)[device newTextureWithDescriptor:depthDesc];
        
        r->framebuffer_texture = r->surface_color;
    }
}

void pgraph_mtl_surface_clear(PGRAPHMTLState *r)
{
    (void)r;
}

void pgraph_mtl_surface_destroy(PGRAPHMTLState *r)
{
    if (r->surface_color) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)r->surface_color;
        t = nil;
        r->surface_color = NULL;
    }
    
    if (r->surface_zeta) {
        id<MTLTexture> d = (__bridge id<MTLTexture>)r->surface_zeta;
        d = nil;
        r->surface_zeta = NULL;
    }
    
    if (r->framebuffer_texture) {
        r->framebuffer_texture = NULL;
    }
}

void *pgraph_mtl_get_color_surface(PGRAPHMTLState *r)
{
    return r->surface_color;
}

void *pgraph_mtl_get_depth_surface(PGRAPHMTLState *r)
{
    return r->surface_zeta;
}

void pgraph_mtl_surface_update_from_vram(NV2AState *d, bool upload, bool color_write, bool zeta_write)
{
    (void)d;
    (void)upload;
    (void)color_write;
    (void)zeta_write;
}

#endif

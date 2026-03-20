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

#include "hw/xbox/nv2a/nv2a_regs.h"

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

static MTLPixelFormat pgraph_mtl_color_pixel_format(uint32_t color_format)
{
    switch (color_format) {
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_O1R5G5B5:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_O8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_Z1A7R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1A7R8G8B8_O1A7R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8:
    default:
        return MTLPixelFormatBGRA8Unorm;
    }
}

static MTLPixelFormat pgraph_mtl_zeta_pixel_format(uint32_t zeta_format)
{
    switch (zeta_format) {
    case NV097_SET_SURFACE_FORMAT_ZETA_Z16:
        return MTLPixelFormatDepth16Unorm;
    case NV097_SET_SURFACE_FORMAT_ZETA_Z24S8:
    default:
        return MTLPixelFormatDepth32Float_Stencil8;
    }
}

static MTLStorageMode pgraph_mtl_zeta_storage_mode(void)
{
    return MTLStorageModePrivate;
}

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
    
    MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pgraph_mtl_color_pixel_format(r->color_format)
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:NO];
    colorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    colorDesc.storageMode = MTLStorageModeManaged;
    
    r->surface_color = (__bridge void *)[device newTextureWithDescriptor:colorDesc];
    
    MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pgraph_mtl_zeta_pixel_format(r->zeta_format)
                                                                                       width:width
                                                                                      height:height
                                                                                   mipmapped:NO];
    depthDesc.usage = MTLTextureUsageRenderTarget;
    depthDesc.storageMode = pgraph_mtl_zeta_storage_mode();
    
    r->surface_zeta = (__bridge void *)[device newTextureWithDescriptor:depthDesc];
    
    r->framebuffer_texture = r->surface_color;
    
    fprintf(stderr, "Metal: Surfaces initialized (%dx%d)\n", width, height);
}

void pgraph_mtl_surface_update(PGRAPHMTLState *r)
{
    MTLPixelFormat desired_color_format;
    MTLPixelFormat desired_zeta_format;

    if (!r->device) {
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    
    uint32_t width = r->viewport_width;
    uint32_t height = r->viewport_height;
    
    if (width == 0) width = 640;
    if (height == 0) height = 480;

    desired_color_format = pgraph_mtl_color_pixel_format(r->color_format);
    desired_zeta_format = pgraph_mtl_zeta_pixel_format(r->zeta_format);
    
    id<MTLTexture> colorTex = r->surface_color ?
        (__bridge id<MTLTexture>)r->surface_color : nil;
    id<MTLTexture> depthTex = r->surface_zeta ?
        (__bridge id<MTLTexture>)r->surface_zeta : nil;
    
    if (!colorTex || colorTex.width != width || colorTex.height != height ||
        colorTex.pixelFormat != desired_color_format ||
        !depthTex || depthTex.pixelFormat != desired_zeta_format) {
        if (r->surface_color) {
            r->surface_color = NULL;
        }
        if (r->surface_zeta) {
            r->surface_zeta = NULL;
        }
        
        MTLTextureDescriptor *colorDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:desired_color_format
                                                                                          width:width
                                                                                         height:height
                                                                                      mipmapped:NO];
        colorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        colorDesc.storageMode = MTLStorageModeManaged;
        
        r->surface_color = (__bridge void *)[device newTextureWithDescriptor:colorDesc];
        
        MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:desired_zeta_format
                                                                                            width:width
                                                                                           height:height
                                                                                        mipmapped:NO];
        depthDesc.usage = MTLTextureUsageRenderTarget;
        depthDesc.storageMode = pgraph_mtl_zeta_storage_mode();
        
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
        r->surface_color = NULL;
    }
    
    if (r->surface_zeta) {
        r->surface_zeta = NULL;
    }
    
    if (r->framebuffer_texture) {
        r->framebuffer_texture = NULL;
    }
}

void pgraph_mtl_surface_upload_color(PGRAPHMTLState *r, const void *data,
                                     uint32_t width, uint32_t height,
                                     uint32_t bytes_per_row)
{
    if (!r || !r->surface_color || !data || !width || !height) {
        return;
    }

    id<MTLTexture> colorTex = (__bridge id<MTLTexture>)r->surface_color;
    [colorTex replaceRegion:MTLRegionMake2D(0, 0, width, height)
                mipmapLevel:0
                  withBytes:data
                bytesPerRow:bytes_per_row];
}

void pgraph_mtl_surface_upload_zeta(PGRAPHMTLState *r, const void *data,
                                    uint32_t width, uint32_t height,
                                    uint32_t bytes_per_row)
{
    if (!r || !r->surface_zeta || !r->command_queue || !r->staging_buffer ||
        !data || !width || !height) {
        return;
    }

    size_t size = (size_t)bytes_per_row * height;
    id<MTLBuffer> stagingBuffer = (__bridge id<MTLBuffer>)r->staging_buffer;
    if (stagingBuffer.length < size) {
        fprintf(stderr, "Metal: staging buffer too small for zeta upload (%zu)\n",
                size);
        return;
    }

    memcpy(stagingBuffer.contents, data, size);

    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)r->command_queue;
    id<MTLTexture> zetaTex = (__bridge id<MTLTexture>)r->surface_zeta;
    id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];

    [blitEncoder copyFromBuffer:stagingBuffer
                   sourceOffset:0
              sourceBytesPerRow:bytes_per_row
            sourceBytesPerImage:size
                     sourceSize:MTLSizeMake(width, height, 1)
                      toTexture:zetaTex
               destinationSlice:0
               destinationLevel:0
              destinationOrigin:MTLOriginMake(0, 0, 0)];

    [blitEncoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];
}

#endif

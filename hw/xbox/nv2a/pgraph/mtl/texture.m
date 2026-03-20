/*
 * Metal Renderer - Texture Management
 *
 * Manages texture loading and binding.
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>

#include "qemu/osdep.h"
#include "qemu/fast-hash.h"
#include "hw/xbox/nv2a/nv2a_regs.h"
#include "hw/xbox/nv2a/pgraph/s3tc.h"
#include "hw/xbox/nv2a/pgraph/swizzle.h"

#include <stdio.h>
#include <string.h>

#define MAX_TEXTURES 16
#define MTL_GET_MASK(v, mask) (((v) & (mask)) >> __builtin_ctz(mask))

typedef struct TextureShapeLocal {
    bool cubemap;
    unsigned int dimensionality;
    unsigned int color_format;
    unsigned int levels;
    unsigned int width;
    unsigned int height;
    unsigned int depth;
    bool border;
    unsigned int min_mipmap_level;
    unsigned int max_mipmap_level;
    unsigned int pitch;
} TextureShapeLocal;

typedef struct BasicColorFormatInfoLocal {
    unsigned int bytes_per_pixel;
    bool linear;
    bool depth;
} BasicColorFormatInfoLocal;

extern const BasicColorFormatInfoLocal kelvin_color_format_info_map[66];
extern uint8_t *pgraph_convert_texture_data(TextureShapeLocal s,
                                            const uint8_t *data,
                                            const uint8_t *palette_data,
                                            unsigned int width,
                                            unsigned int height,
                                            unsigned int depth,
                                            unsigned int row_pitch,
                                            unsigned int slice_pitch,
                                            size_t *converted_size);

typedef struct TextureSlot {
    void *texture;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t levels;
    uint32_t pixel_format;
    uint64_t hash;
    bool valid;
} TextureSlot;

static TextureShapeLocal pgraph_mtl_make_local_shape(
    const PGRAPHMTLTextureShape *shape)
{
    TextureShapeLocal local = {
        .cubemap = shape->cubemap,
        .dimensionality = shape->dimensionality,
        .color_format = shape->color_format,
        .levels = shape->levels,
        .width = shape->width,
        .height = shape->height,
        .depth = shape->depth,
        .border = shape->border,
        .min_mipmap_level = shape->min_mipmap_level,
        .max_mipmap_level = shape->max_mipmap_level,
        .pitch = shape->pitch,
    };

    return local;
}

static uint64_t pgraph_mtl_texture_hash(const PGRAPHMTLTextureShape *shape,
                                        const uint8_t *data, size_t data_len,
                                        const uint8_t *palette_data,
                                        size_t palette_len)
{
    uint64_t hash = fast_hash((void *)shape, sizeof(*shape));

    if (data && data_len) {
        hash ^= fast_hash((void *)data, data_len);
    }
    if (palette_data && palette_len) {
        hash ^= fast_hash((void *)palette_data, palette_len);
    }

    return hash;
}

static MTLSamplerMinMagFilter pgraph_mtl_minmag_filter(unsigned int value)
{
    switch (value) {
    case NV_PGRAPH_TEXFILTER0_MIN_BOX_LOD0:
    case NV_PGRAPH_TEXFILTER0_MIN_BOX_NEARESTLOD:
    case NV_PGRAPH_TEXFILTER0_MIN_BOX_TENT_LOD:
        return MTLSamplerMinMagFilterNearest;
    default:
        return MTLSamplerMinMagFilterLinear;
    }
}

static MTLSamplerMipFilter pgraph_mtl_mip_filter(unsigned int value)
{
    switch (value) {
    case NV_PGRAPH_TEXFILTER0_MIN_BOX_LOD0:
    case NV_PGRAPH_TEXFILTER0_MIN_TENT_LOD0:
    case NV_PGRAPH_TEXFILTER0_MIN_CONVOLUTION_2D_LOD0:
        return MTLSamplerMipFilterNotMipmapped;
    case NV_PGRAPH_TEXFILTER0_MIN_BOX_NEARESTLOD:
    case NV_PGRAPH_TEXFILTER0_MIN_TENT_NEARESTLOD:
        return MTLSamplerMipFilterNearest;
    default:
        return MTLSamplerMipFilterLinear;
    }
}

static MTLSamplerAddressMode pgraph_mtl_addr_mode(unsigned int value)
{
    switch (value) {
    case NV_PGRAPH_TEXADDRESS0_ADDRU_WRAP:
        return MTLSamplerAddressModeRepeat;
    case NV_PGRAPH_TEXADDRESS0_ADDRU_MIRROR:
        return MTLSamplerAddressModeMirrorRepeat;
    case NV_PGRAPH_TEXADDRESS0_ADDRU_BORDER:
        return MTLSamplerAddressModeClampToBorderColor;
    case NV_PGRAPH_TEXADDRESS0_ADDRU_CLAMP_TO_EDGE:
    case NV_PGRAPH_TEXADDRESS0_ADDRU_CLAMP_OGL:
    default:
        return MTLSamplerAddressModeClampToEdge;
    }
}

static bool pgraph_mtl_is_direct_bgra_format(unsigned int color_format,
                                             MTLPixelFormat *pixel_format,
                                             bool *alpha_ignored)
{
    switch (color_format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8R8G8B8:
        *pixel_format = MTLPixelFormatBGRA8Unorm;
        *alpha_ignored = false;
        return true;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X8R8G8B8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X8R8G8B8:
        *pixel_format = MTLPixelFormatBGRA8Unorm;
        *alpha_ignored = true;
        return true;
    case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8G8B8A8:
    case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R8G8B8A8:
        *pixel_format = MTLPixelFormatRGBA8Unorm;
        *alpha_ignored = false;
        return true;
    default:
        return false;
    }
}

static enum S3TC_DECOMPRESS_FORMAT pgraph_mtl_get_s3tc_format(
    unsigned int color_format)
{
    switch (color_format) {
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5:
        return S3TC_DECOMPRESS_FORMAT_DXT1;
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8:
        return S3TC_DECOMPRESS_FORMAT_DXT3;
    case NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8:
        return S3TC_DECOMPRESS_FORMAT_DXT5;
    default:
        return S3TC_DECOMPRESS_FORMAT_DXT1;
    }
}

static uint8_t *pgraph_mtl_convert_uncompressed_to_rgba8(
    const TextureShapeLocal *shape, const uint8_t *data, unsigned int width,
    unsigned int height, unsigned int depth, unsigned int row_pitch,
    unsigned int slice_pitch, size_t *converted_size)
{
    uint8_t *out = g_malloc(width * height * depth * 4);

    for (unsigned int z = 0; z < depth; z++) {
        for (unsigned int y = 0; y < height; y++) {
            const uint8_t *src = data + z * slice_pitch + y * row_pitch;
            uint8_t *dst = out + ((z * height + y) * width * 4);

            for (unsigned int x = 0; x < width; x++) {
                uint8_t r = 0, g = 0, b = 0, a = 255;

                switch (shape->color_format) {
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_Y8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_Y8:
                    r = g = b = src[x];
                    break;
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_AY8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_AY8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8:
                    r = g = b = src[x];
                    a = src[x];
                    break;
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8Y8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8Y8:
                    r = g = b = src[x * 2 + 0];
                    a = src[x * 2 + 1];
                    break;
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A1R5G5B5:
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A1R5G5B5:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5: {
                    uint16_t v = ((const uint16_t *)src)[x];
                    b = ((v >> 0) & 0x1f) * 255 / 31;
                    g = ((v >> 5) & 0x1f) * 255 / 31;
                    r = ((v >> 10) & 0x1f) * 255 / 31;
                    a = (shape->color_format ==
                                 NV097_SET_TEXTURE_FORMAT_COLOR_SZ_X1R5G5B5 ||
                             shape->color_format ==
                                 NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_X1R5G5B5)
                            ? 255
                            : (((v >> 15) & 1) ? 255 : 0);
                    break;
                }
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A4R4G4B4:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A4R4G4B4: {
                    uint16_t v = ((const uint16_t *)src)[x];
                    b = ((v >> 0) & 0x0f) * 17;
                    g = ((v >> 4) & 0x0f) * 17;
                    r = ((v >> 8) & 0x0f) * 17;
                    a = ((v >> 12) & 0x0f) * 17;
                    break;
                }
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R5G6B5:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_R5G6B5: {
                    uint16_t v = ((const uint16_t *)src)[x];
                    b = ((v >> 0) & 0x1f) * 255 / 31;
                    g = ((v >> 5) & 0x3f) * 255 / 63;
                    r = ((v >> 11) & 0x1f) * 255 / 31;
                    break;
                }
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_G8B8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_G8B8:
                    r = src[x * 2 + 0];
                    g = src[x * 2 + 1];
                    b = src[x * 2 + 0];
                    break;
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R8B8:
                    r = src[x * 2 + 1];
                    g = src[x * 2 + 0];
                    b = src[x * 2 + 0];
                    break;
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_R6G5B5: {
                    uint16_t v = ((const uint16_t *)src)[x];
                    r = ((v >> 10) & 0x3f) * 255 / 63;
                    g = ((v >> 5) & 0x1f) * 255 / 31;
                    b = (v & 0x1f) * 255 / 31;
                    break;
                }
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_A8B8G8R8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_A8B8G8R8:
                    r = src[x * 4 + 0];
                    g = src[x * 4 + 1];
                    b = src[x * 4 + 2];
                    a = src[x * 4 + 3];
                    break;
                case NV097_SET_TEXTURE_FORMAT_COLOR_SZ_B8G8R8A8:
                case NV097_SET_TEXTURE_FORMAT_COLOR_LU_IMAGE_B8G8R8A8:
                    b = src[x * 4 + 0];
                    g = src[x * 4 + 1];
                    r = src[x * 4 + 2];
                    a = src[x * 4 + 3];
                    break;
                default:
                    r = src[x * 4 + 0];
                    g = src[x * 4 + 1];
                    b = src[x * 4 + 2];
                    a = src[x * 4 + 3];
                    break;
                }

                dst[x * 4 + 0] = r;
                dst[x * 4 + 1] = g;
                dst[x * 4 + 2] = b;
                dst[x * 4 + 3] = a;
            }
        }
    }

    *converted_size = width * height * depth * 4;
    return out;
}

static uint8_t *pgraph_mtl_decode_level(const PGRAPHMTLTextureShape *shape,
                                        const uint8_t *data,
                                        const uint8_t *palette_data,
                                        unsigned int width,
                                        unsigned int height,
                                        unsigned int depth,
                                        unsigned int row_pitch,
                                        unsigned int slice_pitch,
                                        bool *direct_upload,
                                        MTLPixelFormat *pixel_format,
                                        size_t *decoded_size)
{
    TextureShapeLocal local = pgraph_mtl_make_local_shape(shape);
    uint8_t *decoded = NULL;
    bool alpha_ignored = false;

    *direct_upload = false;
    *pixel_format = MTLPixelFormatRGBA8Unorm;

    if (pgraph_mtl_is_direct_bgra_format(shape->color_format, pixel_format,
                                         &alpha_ignored)) {
        *direct_upload = true;
        *decoded_size = row_pitch * height * depth;
        if (alpha_ignored && *pixel_format == MTLPixelFormatBGRA8Unorm) {
            decoded = g_memdup2(data, *decoded_size);
            for (unsigned int z = 0; z < depth; z++) {
                for (unsigned int y = 0; y < height; y++) {
                    uint8_t *line = decoded + z * slice_pitch + y * row_pitch;
                    for (unsigned int x = 0; x < width; x++) {
                        line[x * 4 + 3] = 0xff;
                    }
                }
            }
            *direct_upload = false;
            *pixel_format = MTLPixelFormatRGBA8Unorm;
        }
        if (*direct_upload) {
            return NULL;
        }
    }

    if (shape->color_format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5 ||
        shape->color_format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8 ||
        shape->color_format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8) {
        decoded = depth > 1
                      ? s3tc_decompress_3d(
                            pgraph_mtl_get_s3tc_format(shape->color_format),
                            data, width, height, depth)
                      : s3tc_decompress_2d(
                            pgraph_mtl_get_s3tc_format(shape->color_format),
                            data, width, height);
        *decoded_size = width * height * depth * 4;
        *pixel_format = MTLPixelFormatRGBA8Unorm;
        return decoded;
    }

    if (!kelvin_color_format_info_map[shape->color_format].linear) {
        unsigned int bytes_per_pixel =
            kelvin_color_format_info_map[shape->color_format].bytes_per_pixel;
        uint8_t *unswizzled;

        if (depth > 1) {
            unsigned int unswizzled_size = row_pitch * height * depth;
            unswizzled = g_malloc(unswizzled_size);
            unswizzle_box(data, width, height, depth, unswizzled, row_pitch,
                          slice_pitch, bytes_per_pixel);
            data = unswizzled;
        } else {
            unsigned int unswizzled_size = row_pitch * height;
            unswizzled = g_malloc(unswizzled_size);
            unswizzle_rect(data, width, height, unswizzled, row_pitch,
                           bytes_per_pixel);
            data = unswizzled;
        }

        decoded = pgraph_convert_texture_data(local, data, palette_data, width,
                                              height, depth, row_pitch,
                                              slice_pitch, decoded_size);
        if (!decoded) {
            decoded = pgraph_mtl_convert_uncompressed_to_rgba8(
                &local, data, width, height, depth, row_pitch, slice_pitch,
                decoded_size);
        }
        g_free((void *)data);
        *pixel_format = MTLPixelFormatRGBA8Unorm;
        return decoded;
    }

    decoded = pgraph_convert_texture_data(local, data, palette_data, width,
                                          height, depth, row_pitch,
                                          slice_pitch, decoded_size);
    if (!decoded) {
        decoded = pgraph_mtl_convert_uncompressed_to_rgba8(
            &local, data, width, height, depth, row_pitch, slice_pitch,
            decoded_size);
    }
    *pixel_format = MTLPixelFormatRGBA8Unorm;
    return decoded;
}

void pgraph_mtl_init_textures(PGRAPHMTLState *r)
{
    fprintf(stderr, "Metal: Initializing textures\n");

    if (!r->device) {
        fprintf(stderr, "Metal: No device for texture init\n");
        return;
    }

    r->texture_cache = g_new0(TextureSlot, MAX_TEXTURES);

    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];

    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
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
    if (!r || !r->texture_cache) {
        return;
    }

    TextureSlot *textures = (TextureSlot *)r->texture_cache;
    for (unsigned int i = 0; i < MAX_TEXTURES; i++) {
        textures[i].texture = nil;
        r->sampler_states[i] = nil;
    }

    g_free(r->texture_cache);
    r->texture_cache = NULL;
}

void pgraph_mtl_texture_update(PGRAPHMTLState *r, unsigned int slot)
{
    (void)r;
    (void)slot;
}

void pgraph_mtl_bind_texture(PGRAPHMTLState *r, unsigned int slot)
{
    if (!r || !r->render_encoder || slot >= MAX_TEXTURES || !r->texture_cache) {
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
    if (r->sampler_states[slot]) {
        [encoder setFragmentSamplerState:(__bridge id<MTLSamplerState>)r->sampler_states[slot]
                                 atIndex:slot];
    }
}

void pgraph_mtl_setup_texture_stage(PGRAPHMTLState *r, unsigned int stage,
                                    uint32_t filter, uint32_t address)
{
    id<MTLDevice> device;
    MTLSamplerDescriptor *desc;
    unsigned int min_filter;
    unsigned int mag_filter;
    unsigned int addru;
    unsigned int addrv;
    unsigned int addrp;

    if (!r || !r->device || stage >= 4) {
        return;
    }

    device = (__bridge id<MTLDevice>)r->device;
    min_filter = MTL_GET_MASK(filter, NV_PGRAPH_TEXFILTER0_MIN);
    mag_filter = MTL_GET_MASK(filter, NV_PGRAPH_TEXFILTER0_MAG);
    addru = MTL_GET_MASK(address, NV_PGRAPH_TEXADDRESS0_ADDRU);
    addrv = MTL_GET_MASK(address, NV_PGRAPH_TEXADDRESS0_ADDRV);
    addrp = MTL_GET_MASK(address, NV_PGRAPH_TEXADDRESS0_ADDRP);

    desc = [[MTLSamplerDescriptor alloc] init];
    desc.minFilter = pgraph_mtl_minmag_filter(min_filter);
    desc.magFilter = pgraph_mtl_minmag_filter(mag_filter);
    desc.mipFilter = pgraph_mtl_mip_filter(min_filter);
    desc.sAddressMode = pgraph_mtl_addr_mode(addru);
    desc.tAddressMode = pgraph_mtl_addr_mode(addrv);
    desc.rAddressMode = pgraph_mtl_addr_mode(addrp);
    desc.maxAnisotropy = 1;
    desc.lodMinClamp = 0.0f;
    desc.lodMaxClamp = 16.0f;
    if (desc.sAddressMode == MTLSamplerAddressModeClampToBorderColor ||
        desc.tAddressMode == MTLSamplerAddressModeClampToBorderColor ||
        desc.rAddressMode == MTLSamplerAddressModeClampToBorderColor) {
        desc.borderColor = MTLSamplerBorderColorTransparentBlack;
    }

    r->sampler_states[stage] = (__bridge void *)[device newSamplerStateWithDescriptor:desc];
}

void pgraph_mtl_upload_texture(PGRAPHMTLState *r, unsigned int slot,
                               const PGRAPHMTLTextureShape *shape,
                               const uint8_t *data, size_t data_len,
                               const uint8_t *palette_data,
                               size_t palette_len)
{
    if (!r || !r->device || !r->texture_cache || slot >= MAX_TEXTURES ||
        !shape || !data || shape->levels == 0) {
        return;
    }

    TextureSlot *textures = (TextureSlot *)r->texture_cache;
    TextureSlot *tex = &textures[slot];
    uint64_t hash = pgraph_mtl_texture_hash(shape, data, data_len,
                                            palette_data, palette_len);
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    uint32_t adjusted_width = shape->width;
    uint32_t adjusted_height = shape->height;
    uint32_t adjusted_depth = shape->depth;
    uint32_t adjusted_pitch = shape->pitch;
    MTLPixelFormat texture_format = MTLPixelFormatRGBA8Unorm;
    MTLTextureDescriptor *desc;

    if (tex->texture && tex->hash == hash && tex->width == shape->width &&
        tex->height == shape->height && tex->depth == shape->depth &&
        tex->levels == shape->levels) {
        tex->valid = true;
        return;
    }

    if (!kelvin_color_format_info_map[shape->color_format].linear &&
        shape->border) {
        adjusted_width = MAX(16u, adjusted_width * 2);
        adjusted_height = MAX(16u, adjusted_height * 2);
        adjusted_pitch = adjusted_width * (shape->pitch / MAX(1u, shape->width));
        adjusted_depth = MAX(16u, adjusted_depth * 2);
    }

    if (shape->cubemap) {
        desc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:texture_format
                                                                    size:adjusted_width
                                                               mipmapped:(shape->levels > 1)];
        desc.arrayLength = 1;
    } else if (shape->dimensionality >= 3) {
        desc = [[MTLTextureDescriptor alloc] init];
        desc.textureType = MTLTextureType3D;
        desc.pixelFormat = texture_format;
        desc.width = adjusted_width;
        desc.height = adjusted_height;
        desc.depth = adjusted_depth;
        desc.mipmapLevelCount = shape->levels;
    } else {
        desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:texture_format
                                                                  width:adjusted_width
                                                                 height:adjusted_height
                                                              mipmapped:(shape->levels > 1)];
    }
    desc.usage = MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeManaged;
    desc.mipmapLevelCount = shape->levels;

    tex->texture = (__bridge void *)[device newTextureWithDescriptor:desc];
    tex->width = shape->width;
    tex->height = shape->height;
    tex->depth = shape->depth;
    tex->levels = shape->levels;
    tex->pixel_format = texture_format;
    tex->hash = hash;
    tex->valid = true;

    id<MTLTexture> texture = (__bridge id<MTLTexture>)tex->texture;
    const uint8_t *texture_data = data;

    if (shape->dimensionality >= 3 && !shape->cubemap) {
        unsigned int width = adjusted_width;
        unsigned int height = adjusted_height;
        unsigned int depth = adjusted_depth;

        for (unsigned int level = 0; level < shape->levels; level++) {
            width = MAX(width, 1u);
            height = MAX(height, 1u);
            depth = MAX(depth, 1u);

            unsigned int row_pitch = width * MAX(1u, kelvin_color_format_info_map[shape->color_format].bytes_per_pixel);
            unsigned int slice_pitch = row_pitch * height;
            bool direct_upload;
            MTLPixelFormat level_format;
            size_t decoded_size;
            uint8_t *decoded = pgraph_mtl_decode_level(shape, texture_data,
                                                       palette_data, width,
                                                       height, depth,
                                                       row_pitch, slice_pitch,
                                                       &direct_upload,
                                                       &level_format,
                                                       &decoded_size);
            const uint8_t *upload_data = direct_upload ? texture_data : decoded;
            NSUInteger bytes_per_row = direct_upload ? row_pitch : width * 4;
            NSUInteger bytes_per_image = direct_upload ? slice_pitch : width * height * 4;

            [texture replaceRegion:MTLRegionMake3D(0, 0, 0, width, height, depth)
                       mipmapLevel:level
                         withBytes:upload_data
                       bytesPerRow:bytes_per_row
                     bytesPerImage:bytes_per_image];

            g_free(decoded);
            texture_data += kelvin_color_format_info_map[shape->color_format].linear
                                ? height * shape->pitch * depth
                                : width * height * depth *
                                      MAX(1u, kelvin_color_format_info_map[shape->color_format].bytes_per_pixel);
            width /= 2;
            height /= 2;
            depth /= 2;
        }
        return;
    }

    if (shape->cubemap) {
        size_t face_len = data_len / 6;
        for (unsigned int face = 0; face < 6; face++) {
            unsigned int width = adjusted_width;
            unsigned int height = adjusted_height;
            const uint8_t *face_data = data + face * face_len;

            for (unsigned int level = 0; level < shape->levels; level++) {
                width = MAX(width, 1u);
                height = MAX(height, 1u);

                unsigned int row_pitch = width * MAX(1u, kelvin_color_format_info_map[shape->color_format].bytes_per_pixel);
                bool direct_upload;
                MTLPixelFormat level_format;
                size_t decoded_size;
                uint8_t *decoded = pgraph_mtl_decode_level(shape, face_data,
                                                           palette_data, width,
                                                           height, 1,
                                                           row_pitch, 0,
                                                           &direct_upload,
                                                           &level_format,
                                                           &decoded_size);
                const uint8_t *upload_data = direct_upload ? face_data : decoded;

                [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                           mipmapLevel:level
                                 slice:face
                             withBytes:upload_data
                           bytesPerRow:(direct_upload ? row_pitch : width * 4)
                         bytesPerImage:(direct_upload ? row_pitch * height : width * height * 4)];

                g_free(decoded);
                face_data += width * height *
                    MAX(1u, kelvin_color_format_info_map[shape->color_format].bytes_per_pixel);
                width /= 2;
                height /= 2;
            }
        }
        return;
    }

    {
        unsigned int width = adjusted_width;
        unsigned int height = adjusted_height;

        for (unsigned int level = 0; level < shape->levels; level++) {
            width = MAX(width, 1u);
            height = MAX(height, 1u);

            unsigned int row_pitch = kelvin_color_format_info_map[shape->color_format].linear
                                         ? adjusted_pitch
                                         : width * MAX(1u, kelvin_color_format_info_map[shape->color_format].bytes_per_pixel);
            bool direct_upload;
            MTLPixelFormat level_format;
            size_t decoded_size;
            uint8_t *decoded = pgraph_mtl_decode_level(shape, texture_data,
                                                       palette_data, width,
                                                       height, 1,
                                                       row_pitch, 0,
                                                       &direct_upload,
                                                       &level_format,
                                                       &decoded_size);
            const uint8_t *upload_data = direct_upload ? texture_data : decoded;

            [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                       mipmapLevel:level
                         withBytes:upload_data
                       bytesPerRow:(direct_upload ? row_pitch : width * 4)];

            g_free(decoded);

            if (shape->color_format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5 ||
                shape->color_format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT23_A8R8G8B8 ||
                shape->color_format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT45_A8R8G8B8) {
                unsigned int block_size =
                    shape->color_format == NV097_SET_TEXTURE_FORMAT_COLOR_L_DXT1_A1R5G5B5
                        ? 8
                        : 16;
                unsigned int physical_width = (width + 3) & ~3u;
                unsigned int physical_height = (height + 3) & ~3u;
                texture_data += physical_width / 4 * physical_height / 4 *
                                block_size;
            } else if (kelvin_color_format_info_map[shape->color_format].linear) {
                texture_data += height * adjusted_pitch;
            } else {
                texture_data += width * height *
                                MAX(1u, kelvin_color_format_info_map[shape->color_format].bytes_per_pixel);
            }
            width /= 2;
            height /= 2;
        }
    }
}

#endif

/*
 * Metal Renderer - Draw Operations
 *
 * Manages render pipelines and drawing operations
 */

#import "renderer.h"

#if TARGET_OS_MAC

#import <Metal/Metal.h>
#import <simd/simd.h>

#include "hw/xbox/nv2a/nv2a_regs.h"

#include <stdio.h>
#include <string.h>

#define MTL_GET_MASK(v, mask) (((v) & (mask)) >> __builtin_ctz(mask))

typedef struct MTLFragmentUniforms {
    uint32_t texture_enable_mask;
    uint32_t alpha_func;
    float alpha_ref;
    uint32_t alpha_test_enabled;
    uint32_t combiner_control;
    uint32_t shader_stage_program;
    uint32_t other_stage_input;
    uint32_t final_inputs_0;
    uint32_t final_inputs_1;
    uint32_t rgb_inputs[8];
    uint32_t rgb_outputs[8];
    uint32_t alpha_inputs[8];
    uint32_t alpha_outputs[8];
    uint32_t pad0[3];
    simd_float4 combiner_consts[18];
    simd_float4 fog_color;
    uint32_t tex_modes[4];
    uint32_t input_tex[4];
    uint32_t dot_map[4];
    uint32_t alphakill[4];
    uint32_t colorkey_mode[4];
    uint32_t color_key[4];
    uint32_t color_key_mask[4];
    uint32_t rect_tex[4];
    uint32_t tex_cubemap[4];
    uint32_t dim_tex[4];
    uint32_t compare_mode[4][4];
    simd_float4 bump_mat[4];
    float bump_scale[4];
    float bump_offset[4];
} MTLFragmentUniforms;

static MTLPixelFormat pgraph_mtl_pipeline_color_format(uint32_t color_format)
{
    switch (color_format) {
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_R5G6B5:
        return MTLPixelFormatB5G6R5Unorm;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_B8:
        return MTLPixelFormatR8Unorm;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_G8B8:
        return MTLPixelFormatRG8Unorm;
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X1R5G5B5_Z1R5G5B5:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_X8R8G8B8_Z8R8G8B8:
    case NV097_SET_SURFACE_FORMAT_COLOR_LE_A8R8G8B8:
    default:
        return MTLPixelFormatBGRA8Unorm;
    }
}

static MTLPixelFormat pgraph_mtl_pipeline_depth_format(uint32_t zeta_format)
{
    switch (zeta_format) {
    case NV097_SET_SURFACE_FORMAT_ZETA_Z16:
        return MTLPixelFormatDepth16Unorm;
    case NV097_SET_SURFACE_FORMAT_ZETA_Z24S8:
        return MTLPixelFormatDepth32Float_Stencil8;
    default:
        return MTLPixelFormatDepth32Float;
    }
}

static MTLCompareFunction pgraph_mtl_compare_func(unsigned int func)
{
    switch (func) {
    case NV_PGRAPH_CONTROL_0_ZFUNC_NEVER:
        return MTLCompareFunctionNever;
    case NV_PGRAPH_CONTROL_0_ZFUNC_LESS:
        return MTLCompareFunctionLess;
    case NV_PGRAPH_CONTROL_0_ZFUNC_EQUAL:
        return MTLCompareFunctionEqual;
    case NV_PGRAPH_CONTROL_0_ZFUNC_LEQUAL:
        return MTLCompareFunctionLessEqual;
    case NV_PGRAPH_CONTROL_0_ZFUNC_GREATER:
        return MTLCompareFunctionGreater;
    case NV_PGRAPH_CONTROL_0_ZFUNC_NOTEQUAL:
        return MTLCompareFunctionNotEqual;
    case NV_PGRAPH_CONTROL_0_ZFUNC_GEQUAL:
        return MTLCompareFunctionGreaterEqual;
    case NV_PGRAPH_CONTROL_0_ZFUNC_ALWAYS:
    default:
        return MTLCompareFunctionAlways;
    }
}

static MTLStencilOperation pgraph_mtl_stencil_op(unsigned int op)
{
    switch (op) {
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_KEEP:
        return MTLStencilOperationKeep;
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_ZERO:
        return MTLStencilOperationZero;
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_REPLACE:
        return MTLStencilOperationReplace;
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_INCRSAT:
        return MTLStencilOperationIncrementClamp;
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_DECRSAT:
        return MTLStencilOperationDecrementClamp;
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_INVERT:
        return MTLStencilOperationInvert;
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_INCR:
        return MTLStencilOperationIncrementWrap;
    case NV_PGRAPH_CONTROL_2_STENCIL_OP_V_DECR:
        return MTLStencilOperationDecrementWrap;
    default:
        return MTLStencilOperationKeep;
    }
}

static MTLBlendFactor pgraph_mtl_blend_factor(unsigned int factor)
{
    switch (factor) {
    case NV_PGRAPH_BLEND_SFACTOR_ZERO:
        return MTLBlendFactorZero;
    case NV_PGRAPH_BLEND_SFACTOR_ONE:
        return MTLBlendFactorOne;
    case NV_PGRAPH_BLEND_SFACTOR_SRC_COLOR:
        return MTLBlendFactorSourceColor;
    case NV_PGRAPH_BLEND_SFACTOR_ONE_MINUS_SRC_COLOR:
        return MTLBlendFactorOneMinusSourceColor;
    case NV_PGRAPH_BLEND_SFACTOR_SRC_ALPHA:
        return MTLBlendFactorSourceAlpha;
    case NV_PGRAPH_BLEND_SFACTOR_ONE_MINUS_SRC_ALPHA:
        return MTLBlendFactorOneMinusSourceAlpha;
    case NV_PGRAPH_BLEND_SFACTOR_DST_ALPHA:
        return MTLBlendFactorDestinationAlpha;
    case NV_PGRAPH_BLEND_SFACTOR_ONE_MINUS_DST_ALPHA:
        return MTLBlendFactorOneMinusDestinationAlpha;
    case NV_PGRAPH_BLEND_SFACTOR_DST_COLOR:
        return MTLBlendFactorDestinationColor;
    case NV_PGRAPH_BLEND_SFACTOR_ONE_MINUS_DST_COLOR:
        return MTLBlendFactorOneMinusDestinationColor;
    case NV_PGRAPH_BLEND_SFACTOR_SRC_ALPHA_SATURATE:
        return MTLBlendFactorSourceAlphaSaturated;
    case NV_PGRAPH_BLEND_SFACTOR_CONSTANT_COLOR:
        return MTLBlendFactorBlendColor;
    case NV_PGRAPH_BLEND_SFACTOR_ONE_MINUS_CONSTANT_COLOR:
        return MTLBlendFactorOneMinusBlendColor;
    case NV_PGRAPH_BLEND_SFACTOR_CONSTANT_ALPHA:
        return MTLBlendFactorBlendAlpha;
    case NV_PGRAPH_BLEND_SFACTOR_ONE_MINUS_CONSTANT_ALPHA:
        return MTLBlendFactorOneMinusBlendAlpha;
    default:
        return MTLBlendFactorOne;
    }
}

static MTLBlendOperation pgraph_mtl_blend_op(unsigned int eqn)
{
    switch (eqn) {
    case 0:
        return MTLBlendOperationSubtract;
    case 1:
        return MTLBlendOperationReverseSubtract;
    case 3:
        return MTLBlendOperationMin;
    case 4:
        return MTLBlendOperationMax;
    case 2:
    default:
        return MTLBlendOperationAdd;
    }
}

void pgraph_mtl_init_pipelines(PGRAPHMTLState *r)
{
    bool depth_enabled;

    if (!r->device || !r->shader_library) {
        return;
    }

    if (r->pipeline_state && r->pipeline_blend_reg == r->blend_reg &&
        r->pipeline_control_0_reg == r->control_0_reg &&
        r->pipeline_control_1_reg == r->control_1_reg &&
        r->pipeline_control_2_reg == r->control_2_reg &&
        r->pipeline_setup_raster_reg == r->setup_raster_reg &&
        r->pipeline_color_format == r->color_format &&
        r->pipeline_zeta_format == r->zeta_format) {
        return;
    }
    
    id<MTLDevice> device = (__bridge id<MTLDevice>)r->device;
    id<MTLLibrary> library = (__bridge id<MTLLibrary>)r->shader_library;
    id<MTLTexture> colorTexture = r->surface_color ?
        (__bridge id<MTLTexture>)r->surface_color : nil;
    id<MTLTexture> depthTexture = r->surface_zeta ?
        (__bridge id<MTLTexture>)r->surface_zeta : nil;
    
    id<MTLFunction> vertexFunc = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunc = [library newFunctionWithName:@"fragment_main"];
    
    if (!vertexFunc || !fragmentFunc) {
        return;
    }
    
    MTLVertexDescriptor *vertexDesc = [[MTLVertexDescriptor alloc] init];
    
    vertexDesc.attributes[0].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[0].offset = 0;
    vertexDesc.attributes[0].bufferIndex = 0;
    
    vertexDesc.attributes[1].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[1].offset = 16;
    vertexDesc.attributes[1].bufferIndex = 0;
    
    vertexDesc.attributes[2].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[2].offset = 32;
    vertexDesc.attributes[2].bufferIndex = 0;
    
    vertexDesc.attributes[3].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[3].offset = 48;
    vertexDesc.attributes[3].bufferIndex = 0;

    vertexDesc.attributes[4].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[4].offset = 64;
    vertexDesc.attributes[4].bufferIndex = 0;

    vertexDesc.attributes[5].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[5].offset = 80;
    vertexDesc.attributes[5].bufferIndex = 0;

    vertexDesc.attributes[6].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[6].offset = 96;
    vertexDesc.attributes[6].bufferIndex = 0;

    vertexDesc.attributes[7].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[7].offset = 112;
    vertexDesc.attributes[7].bufferIndex = 0;

    vertexDesc.attributes[8].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[8].offset = 128;
    vertexDesc.attributes[8].bufferIndex = 0;

    vertexDesc.attributes[9].format = MTLVertexFormatFloat4;
    vertexDesc.attributes[9].offset = 144;
    vertexDesc.attributes[9].bufferIndex = 0;
    
    vertexDesc.layouts[0].stride = 160;
    vertexDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    
    MTLRenderPipelineDescriptor *pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDesc.vertexFunction = vertexFunc;
    pipelineDesc.fragmentFunction = fragmentFunc;
    pipelineDesc.vertexDescriptor = vertexDesc;
    
    pipelineDesc.colorAttachments[0].pixelFormat =
        colorTexture ? colorTexture.pixelFormat :
                       pgraph_mtl_pipeline_color_format(r->color_format);
    pipelineDesc.colorAttachments[0].blendingEnabled =
        !!(r->blend_reg & NV_PGRAPH_BLEND_EN);
    pipelineDesc.colorAttachments[0].rgbBlendOperation =
        pgraph_mtl_blend_op(MTL_GET_MASK(r->blend_reg, NV_PGRAPH_BLEND_EQN));
    pipelineDesc.colorAttachments[0].alphaBlendOperation =
        pgraph_mtl_blend_op(MTL_GET_MASK(r->blend_reg, NV_PGRAPH_BLEND_EQN));
    pipelineDesc.colorAttachments[0].sourceRGBBlendFactor =
        pgraph_mtl_blend_factor(MTL_GET_MASK(r->blend_reg,
                                             NV_PGRAPH_BLEND_SFACTOR));
    pipelineDesc.colorAttachments[0].sourceAlphaBlendFactor =
        pgraph_mtl_blend_factor(MTL_GET_MASK(r->blend_reg,
                                             NV_PGRAPH_BLEND_SFACTOR));
    pipelineDesc.colorAttachments[0].destinationRGBBlendFactor =
        pgraph_mtl_blend_factor(MTL_GET_MASK(r->blend_reg,
                                             NV_PGRAPH_BLEND_DFACTOR));
    pipelineDesc.colorAttachments[0].destinationAlphaBlendFactor =
        pgraph_mtl_blend_factor(MTL_GET_MASK(r->blend_reg,
                                             NV_PGRAPH_BLEND_DFACTOR));
    pipelineDesc.colorAttachments[0].writeMask = 0;
    if (r->control_0_reg & NV_PGRAPH_CONTROL_0_RED_WRITE_ENABLE) {
        pipelineDesc.colorAttachments[0].writeMask |= MTLColorWriteMaskRed;
    }
    if (r->control_0_reg & NV_PGRAPH_CONTROL_0_GREEN_WRITE_ENABLE) {
        pipelineDesc.colorAttachments[0].writeMask |= MTLColorWriteMaskGreen;
    }
    if (r->control_0_reg & NV_PGRAPH_CONTROL_0_BLUE_WRITE_ENABLE) {
        pipelineDesc.colorAttachments[0].writeMask |= MTLColorWriteMaskBlue;
    }
    if (r->control_0_reg & NV_PGRAPH_CONTROL_0_ALPHA_WRITE_ENABLE) {
        pipelineDesc.colorAttachments[0].writeMask |= MTLColorWriteMaskAlpha;
    }
    
    pipelineDesc.depthAttachmentPixelFormat =
        depthTexture ? depthTexture.pixelFormat :
                       pgraph_mtl_pipeline_depth_format(r->zeta_format);
    pipelineDesc.stencilAttachmentPixelFormat =
        depthTexture && depthTexture.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ?
            depthTexture.pixelFormat : MTLPixelFormatInvalid;
    
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
    
    if (error) {
        fprintf(stderr, "Metal: Failed to create pipeline: %s\n", [[error localizedDescription] UTF8String]);
        return;
    }
    
    r->pipeline_state = (__bridge void *)pipeline;
    
    MTLDepthStencilDescriptor *depthDesc = [[MTLDepthStencilDescriptor alloc] init];
    depth_enabled = !!(r->control_0_reg & NV_PGRAPH_CONTROL_0_ZENABLE);
    depthDesc.depthCompareFunction = depth_enabled ?
        pgraph_mtl_compare_func(MTL_GET_MASK(r->control_0_reg,
                                             NV_PGRAPH_CONTROL_0_ZFUNC)) :
        MTLCompareFunctionAlways;
    depthDesc.depthWriteEnabled = depth_enabled &&
                                  !!(r->control_0_reg &
                                     NV_PGRAPH_CONTROL_0_ZWRITEENABLE);

    if (r->control_1_reg & NV_PGRAPH_CONTROL_1_STENCIL_TEST_ENABLE) {
        MTLStencilDescriptor *stencil = [[MTLStencilDescriptor alloc] init];
        stencil.stencilCompareFunction = pgraph_mtl_compare_func(
            MTL_GET_MASK(r->control_1_reg, NV_PGRAPH_CONTROL_1_STENCIL_FUNC));
        stencil.stencilFailureOperation = pgraph_mtl_stencil_op(
            MTL_GET_MASK(r->control_2_reg, NV_PGRAPH_CONTROL_2_STENCIL_OP_FAIL));
        stencil.depthFailureOperation = pgraph_mtl_stencil_op(
            MTL_GET_MASK(r->control_2_reg, NV_PGRAPH_CONTROL_2_STENCIL_OP_ZFAIL));
        stencil.depthStencilPassOperation = pgraph_mtl_stencil_op(
            MTL_GET_MASK(r->control_2_reg, NV_PGRAPH_CONTROL_2_STENCIL_OP_ZPASS));
        stencil.readMask = MTL_GET_MASK(r->control_1_reg,
                                        NV_PGRAPH_CONTROL_1_STENCIL_MASK_READ);
        stencil.writeMask = MTL_GET_MASK(r->control_1_reg,
                                         NV_PGRAPH_CONTROL_1_STENCIL_MASK_WRITE);
        depthDesc.frontFaceStencil = stencil;
        depthDesc.backFaceStencil = stencil;
    }
    
    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:depthDesc];
    r->depth_stencil_state = (__bridge void *)depthState;

    r->pipeline_blend_reg = r->blend_reg;
    r->pipeline_control_0_reg = r->control_0_reg;
    r->pipeline_control_1_reg = r->control_1_reg;
    r->pipeline_control_2_reg = r->control_2_reg;
    r->pipeline_setup_raster_reg = r->setup_raster_reg;
    r->pipeline_color_format = r->color_format;
    r->pipeline_zeta_format = r->zeta_format;
}

void pgraph_mtl_destroy_pipelines(PGRAPHMTLState *r)
{
    if (r->pipeline_state) {
        id<MTLRenderPipelineState> pipeline = (__bridge id<MTLRenderPipelineState>)r->pipeline_state;
        pipeline = nil;
        r->pipeline_state = NULL;
    }
    
    if (r->depth_stencil_state) {
        id<MTLDepthStencilState> depthState = (__bridge id<MTLDepthStencilState>)r->depth_stencil_state;
        depthState = nil;
        r->depth_stencil_state = NULL;
    }
    
    if (r->vertex_descriptor) {
        // MTLVertexDescriptor is a struct, not an object - just free the memory
        free(r->vertex_descriptor);
        r->vertex_descriptor = NULL;
    }
}

void pgraph_mtl_draw(PGRAPHMTLState *r, bool is_indexed, uint32_t first_vertex, uint32_t vertex_count)
{
    bool cull_all = false;

    if (!r->command_buffer || !r->render_encoder) {
        return;
    }
    
    if (vertex_count == 0) {
        return;
    }

    if (!r->pipeline_state) {
        pgraph_mtl_init_pipelines(r);
        if (!r->pipeline_state) {
            return;
        }
    }
    
    id<MTLRenderCommandEncoder> encoder = (__bridge id<MTLRenderCommandEncoder>)r->render_encoder;
    id<MTLRenderPipelineState> pipeline = (__bridge id<MTLRenderPipelineState>)r->pipeline_state;

    pgraph_mtl_init_pipelines(r);
    pipeline = (__bridge id<MTLRenderPipelineState>)r->pipeline_state;
    
    [encoder setRenderPipelineState:pipeline];
    
    if (r->depth_stencil_state) {
        id<MTLDepthStencilState> depthState = (__bridge id<MTLDepthStencilState>)r->depth_stencil_state;
        [encoder setDepthStencilState:depthState];
        [encoder setStencilReferenceValue:MTL_GET_MASK(r->control_1_reg,
                                                       NV_PGRAPH_CONTROL_1_STENCIL_REF)];
    }

    if (r->clip_width && r->clip_height) {
        MTLScissorRect scissor = {
            .x = r->clip_x,
            .y = r->clip_y,
            .width = r->clip_width,
            .height = r->clip_height,
        };
        [encoder setScissorRect:scissor];
    }

    if (r->setup_raster_reg & NV_PGRAPH_SETUPRASTER_CULLENABLE) {
        switch (MTL_GET_MASK(r->setup_raster_reg, NV_PGRAPH_SETUPRASTER_CULLCTRL)) {
        case NV_PGRAPH_SETUPRASTER_CULLCTRL_FRONT:
            [encoder setCullMode:MTLCullModeFront];
            break;
        case NV_PGRAPH_SETUPRASTER_CULLCTRL_BACK:
            [encoder setCullMode:MTLCullModeBack];
            break;
        case NV_PGRAPH_SETUPRASTER_CULLCTRL_FRONT_AND_BACK:
            cull_all = true;
            break;
        default:
            [encoder setCullMode:MTLCullModeNone];
            break;
        }
    } else {
        [encoder setCullMode:MTLCullModeNone];
    }
    [encoder setFrontFacingWinding:(r->setup_raster_reg & NV_PGRAPH_SETUPRASTER_FRONTFACE) ?
        MTLWindingCounterClockwise : MTLWindingClockwise];

    if (cull_all) {
        return;
    }

    if (r->blend_reg & NV_PGRAPH_BLEND_EN) {
        float blend_constants[4] = {
            ((r->blend_color_reg >> 16) & 0xff) / 255.0f,
            ((r->blend_color_reg >> 8) & 0xff) / 255.0f,
            (r->blend_color_reg & 0xff) / 255.0f,
            ((r->blend_color_reg >> 24) & 0xff) / 255.0f,
        };
        [encoder setBlendColorRed:blend_constants[0]
                            green:blend_constants[1]
                             blue:blend_constants[2]
                            alpha:blend_constants[3]];
    }
    
    if (r->vertex_buffer) {
        id<MTLBuffer> vertexBuffer = (__bridge id<MTLBuffer>)r->vertex_buffer;
        [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
    }
    
    if (r->uniform_buffer) {
        id<MTLBuffer> uniformBuffer = (__bridge id<MTLBuffer>)r->uniform_buffer;
        (void)uniformBuffer;
    }
    
    if (r->sampler_state) {
        id<MTLSamplerState> sampler = (__bridge id<MTLSamplerState>)r->sampler_state;
        for (unsigned int i = 0; i < 4; i++) {
            [encoder setFragmentSamplerState:sampler atIndex:i];
        }
    }

    MTLFragmentUniforms frag_uniforms = {
        .texture_enable_mask = r->texture_enable_mask,
        .alpha_func = r->alpha_func,
        .alpha_ref = r->alpha_ref,
        .alpha_test_enabled = r->alpha_test_enabled,
        .combiner_control = r->combiner_control,
        .shader_stage_program = r->shader_stage_program,
        .other_stage_input = r->other_stage_input,
        .final_inputs_0 = r->final_inputs_0,
        .final_inputs_1 = r->final_inputs_1,
    };
    memcpy(frag_uniforms.rgb_inputs, r->rgb_inputs, sizeof(frag_uniforms.rgb_inputs));
    memcpy(frag_uniforms.rgb_outputs, r->rgb_outputs, sizeof(frag_uniforms.rgb_outputs));
    memcpy(frag_uniforms.alpha_inputs, r->alpha_inputs, sizeof(frag_uniforms.alpha_inputs));
    memcpy(frag_uniforms.alpha_outputs, r->alpha_outputs, sizeof(frag_uniforms.alpha_outputs));
    memcpy(frag_uniforms.combiner_consts, r->combiner_consts,
           sizeof(frag_uniforms.combiner_consts));
    memcpy(&frag_uniforms.fog_color, r->fog_color,
           sizeof(frag_uniforms.fog_color));
    memcpy(frag_uniforms.tex_modes, r->tex_modes, sizeof(frag_uniforms.tex_modes));
    memcpy(frag_uniforms.input_tex, r->input_tex, sizeof(frag_uniforms.input_tex));
    memcpy(frag_uniforms.dot_map, r->dot_map, sizeof(frag_uniforms.dot_map));
    memcpy(frag_uniforms.alphakill, r->alphakill, sizeof(frag_uniforms.alphakill));
    memcpy(frag_uniforms.colorkey_mode, r->colorkey_mode, sizeof(frag_uniforms.colorkey_mode));
    memcpy(frag_uniforms.color_key, r->color_key, sizeof(frag_uniforms.color_key));
    memcpy(frag_uniforms.color_key_mask, r->color_key_mask, sizeof(frag_uniforms.color_key_mask));
    memcpy(frag_uniforms.rect_tex, r->rect_tex, sizeof(frag_uniforms.rect_tex));
    memcpy(frag_uniforms.tex_cubemap, r->tex_cubemap, sizeof(frag_uniforms.tex_cubemap));
    memcpy(frag_uniforms.dim_tex, r->dim_tex, sizeof(frag_uniforms.dim_tex));
    memcpy(frag_uniforms.compare_mode, r->compare_mode, sizeof(frag_uniforms.compare_mode));
    memcpy(frag_uniforms.bump_mat, r->bump_mat, sizeof(frag_uniforms.bump_mat));
    memcpy(frag_uniforms.bump_scale, r->bump_scale, sizeof(frag_uniforms.bump_scale));
    memcpy(frag_uniforms.bump_offset, r->bump_offset, sizeof(frag_uniforms.bump_offset));
    [encoder setFragmentBytes:&frag_uniforms
                       length:sizeof(frag_uniforms)
                      atIndex:0];

    if (r->texture_cache) {
        for (unsigned int i = 0; i < 4; i++) {
            pgraph_mtl_bind_texture(r, i);
        }
    }

    if (r->zpass_pixel_count_enable && r->visibility_result_buffer &&
        r->num_queries_in_flight < r->max_queries_in_flight) {
        [encoder setVisibilityResultMode:MTLVisibilityResultModeCounting
                                  offset:r->num_queries_in_flight * sizeof(uint64_t)];
        r->query_in_flight = true;
    } else {
        [encoder setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
    }
    
    if (is_indexed && r->index_buffer) {
        id<MTLBuffer> indexBuffer = (__bridge id<MTLBuffer>)r->index_buffer;
        [encoder drawIndexedPrimitives:(MTLPrimitiveType)r->primitive_type
                            indexCount:vertex_count
                             indexType:MTLIndexTypeUInt32
                       indexBuffer:indexBuffer
                  indexBufferOffset:0];
    } else {
        [encoder drawPrimitives:(MTLPrimitiveType)r->primitive_type
                    vertexStart:first_vertex
                    vertexCount:vertex_count];
    }

    if (r->query_in_flight) {
        [encoder setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
        r->num_queries_in_flight++;
        r->query_in_flight = false;
    }
}

void pgraph_mtl_draw_inline(PGRAPHMTLState *r, uint32_t vertex_count)
{
    pgraph_mtl_draw(r, false, 0, vertex_count);
}

void pgraph_mtl_clear(PGRAPHMTLState *r, float r_val, float g_val, float b_val, float a_val)
{
    if (!r) {
        return;
    }

    r->clear_pending = true;
    r->clear_color_pending = true;
    r->clear_color[0] = r_val;
    r->clear_color[1] = g_val;
    r->clear_color[2] = b_val;
    r->clear_color[3] = a_val;
}

#endif

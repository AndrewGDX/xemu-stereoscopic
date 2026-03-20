/*
 * Geforce NV2A PGRAPH Metal Renderer
 *
 * Copyright (c) 2024-2025 Matt Borgerson
 *
 * C-compatible Metal renderer interface
 */

#ifndef HW_XBOX_NV2A_PGRAPH_MTL_RENDERER_H
#define HW_XBOX_NV2A_PGRAPH_MTL_RENDERER_H

#include <TargetConditionals.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#include "exec/hwaddr.h"

#if TARGET_OS_MAC

#include "xemu-config.h"

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

#ifndef ERROR_C
#define ERROR_C
struct Error;
typedef struct Error Error;
#endif

#ifndef GPU_PROPERTIES_C
#define GPU_PROPERTIES_C
struct GPUProperties;
typedef struct GPUProperties GPUProperties;
#endif

#if defined(__cplusplus) || defined(__OBJC__)
extern GPUProperties g_mtl_gpu_properties;
#endif

typedef struct PGRAPHMTLState {
    void *device;
    void *command_queue;
    void *command_buffer;
    void *render_encoder;
    void *blit_encoder;
    void *render_pass_descriptor;
    
    void *command_buffer_semaphore;
    void *frame_semaphore;
    
    void *vertex_buffer;
    void *uniform_buffer;
    void *index_buffer;
    void *staging_buffer;
    
    void *framebuffer_texture;
    void *surface_color;
    void *surface_zeta;
    void *texture_cache;
    
    void *pipeline_state;
    void *depth_stencil_state;
    void *sampler_state;
    void *shader_library;
    void *vertex_descriptor;
    
    bool initialized;
    bool debug_enabled;
    bool command_buffer_in_progress;
    bool render_pass_active;
    bool clear_pending;
    bool clear_color_pending;
    bool clear_zeta_pending;
    bool zpass_pixel_count_enable;

    uint32_t current_frame_index;
    uint64_t frame_count;

    float clear_color[4];
    float clear_depth;
    uint32_t clear_stencil;
    
    uint32_t color_format;
    uint32_t zeta_format;
    
    uint32_t viewport_width;
    uint32_t viewport_height;
    uint32_t clip_x;
    uint32_t clip_y;
    uint32_t clip_width;
    uint32_t clip_height;
    
    void *display_layer;
    void *display_drawable;
    void *display_texture;
    void *display_fence;
    uint32_t display_width;
    uint32_t display_height;
    bool display_valid;
    void *display_surface_cache;
    uint32_t primitive_type;
    uint32_t prepared_vertex_count;
    uint32_t texture_enable_mask;
    uint32_t alpha_func;
    float alpha_ref;
    bool alpha_test_enabled;
    uint32_t blend_reg;
    uint32_t blend_color_reg;
    uint32_t control_0_reg;
    uint32_t control_1_reg;
    uint32_t control_2_reg;
    uint32_t control_3_reg;
    uint32_t setup_raster_reg;
    uint32_t zoffset_bias_reg;
    uint32_t zoffset_factor_reg;
    void *sampler_states[4];
    uint32_t pipeline_blend_reg;
    uint32_t pipeline_control_0_reg;
    uint32_t pipeline_control_1_reg;
    uint32_t pipeline_control_2_reg;
    uint32_t pipeline_setup_raster_reg;
    uint32_t pipeline_color_format;
    uint32_t pipeline_zeta_format;
    uint32_t combiner_control;
    uint32_t shader_stage_program;
    uint32_t other_stage_input;
    uint32_t final_inputs_0;
    uint32_t final_inputs_1;
    uint32_t rgb_inputs[8];
    uint32_t rgb_outputs[8];
    uint32_t alpha_inputs[8];
    uint32_t alpha_outputs[8];
    float combiner_consts[18][4];
    float fog_color[4];
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
    float bump_mat[4][4];
    float bump_scale[4];
    float bump_offset[4];

    void *visibility_result_buffer;
    void *report_queue;
    uint32_t num_queries_in_flight;
    uint32_t max_queries_in_flight;
    bool query_in_flight;
    uint64_t zpass_pixel_count_result;
} PGRAPHMTLState;

typedef struct MTLVertex {
    float position[4];
    float diffuse[4];
    float specular[4];
    float texcoord0[4];
    float texcoord1[4];
    float texcoord2[4];
    float texcoord3[4];
    float fog[4];
    float normal[4];
} MTLVertex;

typedef struct PGRAPHMTLTextureShape {
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
} PGRAPHMTLTextureShape;

typedef struct PGRAPHMTLDisplaySurfaceCacheEntry {
    hwaddr vram_addr;
    hwaddr size;
    uint32_t pitch;
    uint32_t width;
    uint32_t height;
    uint32_t tex_width;
    uint32_t tex_height;
    uint32_t frame_time;
    uint8_t *data;
} PGRAPHMTLDisplaySurfaceCacheEntry;

void pgraph_mtl_init(NV2AState *d, Error **errp);
void pgraph_mtl_flush(PGRAPHMTLState *r);
void pgraph_mtl_submit(PGRAPHMTLState *r);

void pgraph_mtl_init_device(PGRAPHMTLState *r, Error **errp);
void pgraph_mtl_finalize_device(PGRAPHMTLState *r);
void pgraph_mtl_init_buffers(PGRAPHMTLState *r);
void pgraph_mtl_destroy_buffers(PGRAPHMTLState *r);

void pgraph_mtl_init_surfaces(PGRAPHMTLState *r);
void pgraph_mtl_surface_update(PGRAPHMTLState *r);
void pgraph_mtl_surface_clear(PGRAPHMTLState *r);
void pgraph_mtl_surface_destroy(PGRAPHMTLState *r);
void pgraph_mtl_surface_upload_color(PGRAPHMTLState *r, const void *data,
                                     uint32_t width, uint32_t height,
                                     uint32_t bytes_per_row);
void pgraph_mtl_surface_upload_zeta(PGRAPHMTLState *r, const void *data,
                                    uint32_t width, uint32_t height,
                                    uint32_t bytes_per_row);

void pgraph_mtl_surface_update_from_vram(NV2AState *d, bool upload, bool color_write, bool zeta_write);
void pgraph_mtl_surface_flush(NV2AState *d);
bool pgraph_mtl_update_display_from_scanout(NV2AState *d);

void pgraph_mtl_init_textures(PGRAPHMTLState *r);
void pgraph_mtl_destroy_textures(PGRAPHMTLState *r);
void pgraph_mtl_texture_update(PGRAPHMTLState *r, unsigned int slot);

void pgraph_mtl_bind_texture(PGRAPHMTLState *r, unsigned int stage);
void pgraph_mtl_setup_texture_stage(PGRAPHMTLState *r, unsigned int stage,
                                    uint32_t filter, uint32_t address);
void pgraph_mtl_upload_texture(PGRAPHMTLState *r, unsigned int slot,
                               const PGRAPHMTLTextureShape *shape,
                               const uint8_t *data, size_t data_len,
                               const uint8_t *palette_data,
                               size_t palette_len);

void pgraph_mtl_bind_textures(NV2AState *d);

void pgraph_mtl_shaders_init(PGRAPHMTLState *r);
void pgraph_mtl_shaders_destroy(PGRAPHMTLState *r);

void pgraph_mtl_init_pipelines(PGRAPHMTLState *r);
void pgraph_mtl_destroy_pipelines(PGRAPHMTLState *r);

void pgraph_mtl_bind_vertex_attributes(PGRAPHMTLState *r, unsigned int min_element, unsigned int max_element);
void pgraph_mtl_update_vertex_buffer_from_data(PGRAPHMTLState *r, const void *data, size_t size, size_t offset);

void pgraph_mtl_bind_vertex_data(NV2AState *d);

void pgraph_mtl_draw(PGRAPHMTLState *r, bool is_indexed, uint32_t first_vertex, uint32_t vertex_count);
void pgraph_mtl_draw_inline(PGRAPHMTLState *r, uint32_t vertex_count);
void pgraph_mtl_clear(PGRAPHMTLState *r, float r_val, float g_val, float b_val, float a_val);

void pgraph_mtl_begin_command_buffer(PGRAPHMTLState *r);
void pgraph_mtl_end_command_buffer(PGRAPHMTLState *r);
void pgraph_mtl_submit_command_buffer(PGRAPHMTLState *r);
void pgraph_mtl_wait_idle(PGRAPHMTLState *r);
void pgraph_mtl_sync_texture_for_cpu(PGRAPHMTLState *r, void *texture);

void pgraph_mtl_image_blit(PGRAPHMTLState *r);

void pgraph_mtl_init_reports(PGRAPHMTLState *r);
void pgraph_mtl_await_reports(PGRAPHMTLState *r);
uint32_t pgraph_mtl_copy_query_results(PGRAPHMTLState *r, uint64_t *dst,
                                       uint32_t max_results);
void pgraph_mtl_destroy_reports(PGRAPHMTLState *r);

void pgraph_mtl_init_display(PGRAPHMTLState *r);
void pgraph_mtl_display_render(PGRAPHMTLState *r);
bool pgraph_mtl_display_refresh(PGRAPHMTLState *r);
void pgraph_mtl_display_present(PGRAPHMTLState *r);
void pgraph_mtl_display_destroy(PGRAPHMTLState *r);
void pgraph_mtl_display_set_size(PGRAPHMTLState *r, uint32_t width, uint32_t height);
void pgraph_mtl_display_get_texture_size(PGRAPHMTLState *r, uint32_t *width, uint32_t *height);
void *pgraph_mtl_display_get_texture(PGRAPHMTLState *r);
bool pgraph_mtl_display_upload(PGRAPHMTLState *r, const void *data,
                               uint32_t width, uint32_t height,
                               uint32_t bytes_per_row);

#ifdef __cplusplus
extern "C" {
#endif

void pgraph_mtl_set_display_device(void *device);
unsigned int pgraph_mtl_display_get_gl_texture(void *device,
                                               void *display_texture,
                                               uint32_t width,
                                               uint32_t height);
void pgraph_mtl_destroy_display_presenter(void);
bool pgraph_mtl_display_copy_texture(void *texture, void *dst,
                                      size_t bytes_per_row,
                                      uint32_t width, uint32_t height);

#ifdef __cplusplus
}
#endif

void pgraph_mtl_bind_texture_stage(PGRAPHMTLState *r, unsigned int stage);
void pgraph_mtl_setup_texture(PGRAPHMTLState *r, unsigned int stage);
bool pgraph_mtl_check_textures_dirty(NV2AState *d);

GPUProperties *pgraph_mtl_get_gpu_properties(void);

#endif /* TARGET_OS_MAC */
#endif /* HW_XBOX_NV2A_PGRAPH_MTL_RENDERER_H */

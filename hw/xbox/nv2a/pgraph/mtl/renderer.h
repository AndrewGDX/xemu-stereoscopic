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
    
    uint32_t current_frame_index;
    uint64_t frame_count;
    
    uint32_t color_format;
    uint32_t zeta_format;
    
    uint32_t viewport_width;
    uint32_t viewport_height;
    
    void *display_layer;
    void *display_drawable;
    void *display_texture;
    void *display_fence;
    uint32_t display_width;
    uint32_t display_height;
} PGRAPHMTLState;

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

void pgraph_mtl_surface_update_from_vram(NV2AState *d, bool upload, bool color_write, bool zeta_write);
void pgraph_mtl_surface_flush(NV2AState *d);

void pgraph_mtl_init_textures(PGRAPHMTLState *r);
void pgraph_mtl_destroy_textures(PGRAPHMTLState *r);
void pgraph_mtl_texture_update(PGRAPHMTLState *r, unsigned int slot);

void pgraph_mtl_texture_bind(PGRAPHMTLState *r, unsigned int stage);
void pgraph_mtl_setup_texture_stage(PGRAPHMTLState *r, unsigned int stage);
void pgraph_mtl_upload_texture_data(PGRAPHMTLState *r, unsigned int slot,
                                   const void *data, uint32_t width, uint32_t height);

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

void pgraph_mtl_image_blit(PGRAPHMTLState *r);

void pgraph_mtl_init_reports(PGRAPHMTLState *r);
void pgraph_mtl_await_reports(PGRAPHMTLState *r);
void pgraph_mtl_download_reports(PGRAPHMTLState *r);

void pgraph_mtl_init_display(PGRAPHMTLState *r);
void pgraph_mtl_display_render(PGRAPHMTLState *r);
void pgraph_mtl_display_present(PGRAPHMTLState *r);
void pgraph_mtl_display_destroy(PGRAPHMTLState *r);
void pgraph_mtl_display_set_size(PGRAPHMTLState *r, uint32_t width, uint32_t height);
void pgraph_mtl_display_get_texture_size(PGRAPHMTLState *r, uint32_t *width, uint32_t *height);
void *pgraph_mtl_display_get_texture(PGRAPHMTLState *r);

void pgraph_mtl_bind_texture_stage(PGRAPHMTLState *r, unsigned int stage);
void pgraph_mtl_setup_texture(PGRAPHMTLState *r, unsigned int stage);
bool pgraph_mtl_check_textures_dirty(NV2AState *d);

GPUProperties *pgraph_mtl_get_gpu_properties(void);

#endif /* TARGET_OS_MAC */
#endif /* HW_XBOX_NV2A_PGRAPH_MTL_RENDERER_H */

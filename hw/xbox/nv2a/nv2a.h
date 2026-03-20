/*
 * QEMU Geforce NV2A implementation
 *
 * Copyright (c) 2012 espes
 * Copyright (c) 2020-2021 Matt Borgerson
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, see <http://www.gnu.org/licenses/>.
 */

#ifndef HW_NV2A_H
#define HW_NV2A_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct PCIBus PCIBus;
typedef struct MemoryRegion MemoryRegion;

void nv2a_init(PCIBus *bus, int devfn, MemoryRegion *ram);
void nv2a_context_init(void);
int nv2a_get_framebuffer_surface(void);
void nv2a_release_framebuffer_surface(void);
int nv2a_get_active_renderer(void);
void nv2a_set_surface_scale_factor(unsigned int scale);
unsigned int nv2a_get_surface_scale_factor(void);
const uint8_t *nv2a_get_dac_palette(void);
int nv2a_get_screen_off(void);

#ifdef CONFIG_METAL
void *nv2a_get_metal_display_texture(int *width, int *height);
bool nv2a_copy_metal_display_frame(void *dst, size_t bytes_per_row,
                                   int *width, int *height);
#if defined(TARGET_OS_MAC)
void pgraph_mtl_destroy_display_presenter(void);
#endif
#endif

#endif

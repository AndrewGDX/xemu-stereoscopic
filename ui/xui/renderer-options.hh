#pragma once

#include "widgets.hh"

struct DisplayRendererOption {
    CONFIG_DISPLAY_RENDERER type;
    const char *label;
};

static constexpr DisplayRendererOption kDisplayRendererOptions[] = {
    { CONFIG_DISPLAY_RENDERER_NULL, "Null" },
#ifdef CONFIG_OPENGL
    { CONFIG_DISPLAY_RENDERER_OPENGL, "OpenGL" },
#endif
#ifdef CONFIG_VULKAN
    { CONFIG_DISPLAY_RENDERER_VULKAN, "Vulkan" },
#endif
#ifdef CONFIG_METAL
    { CONFIG_DISPLAY_RENDERER_METAL, "Metal" },
#endif
};

static inline int DisplayRendererOptionCount(void)
{
    return sizeof(kDisplayRendererOptions) /
           sizeof(kDisplayRendererOptions[0]);
}

static inline int DisplayRendererComboIndex(CONFIG_DISPLAY_RENDERER type)
{
    for (int i = 0; i < DisplayRendererOptionCount(); i++) {
        if (kDisplayRendererOptions[i].type == type) {
            return i;
        }
    }

    return 0;
}

static inline CONFIG_DISPLAY_RENDERER DisplayRendererTypeFromIndex(int index)
{
    if (index < 0 || index >= DisplayRendererOptionCount()) {
        return kDisplayRendererOptions[0].type;
    }

    return kDisplayRendererOptions[index].type;
}

static inline bool DisplayRendererGetter(void *opaque, int index,
                                         const char **out_text)
{
    (void)opaque;

    if (index < 0 || index >= DisplayRendererOptionCount()) {
        return false;
    }

    *out_text = kDisplayRendererOptions[index].label;
    return true;
}

static inline bool DisplayRendererChevronCombo(
    const char *label, CONFIG_DISPLAY_RENDERER *renderer,
    const char *description = nullptr)
{
    int current_item = DisplayRendererComboIndex(*renderer);
    bool value_changed = ChevronCombo(
        label, &current_item, DisplayRendererGetter, nullptr,
        DisplayRendererOptionCount(), description);

    if (value_changed) {
        *renderer = DisplayRendererTypeFromIndex(current_item);
    }

    return value_changed;
}

static inline bool DisplayRendererCombo(const char *label,
                                        CONFIG_DISPLAY_RENDERER *renderer)
{
    int current_item = DisplayRendererComboIndex(*renderer);
    bool value_changed = ImGui::Combo(label, &current_item,
                                      DisplayRendererGetter, nullptr,
                                      DisplayRendererOptionCount());

    if (value_changed) {
        *renderer = DisplayRendererTypeFromIndex(current_item);
    }

    return value_changed;
}

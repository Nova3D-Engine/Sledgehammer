APP_NAME := Sledgehammer
BUILD_DIR := build
SRC_DIR := src
ASSET_DIR := assets
NOVA_ROOT := ..
NOVA_SDK_ROOT ?=
NOVA_CORE_DIR := $(NOVA_ROOT)/NovaCore
NOVA_EDITOR_DIR := $(NOVA_ROOT)/NovaEditor
NOVA_RENDERER_MTL_DIR := $(NOVA_ROOT)/NovaRendererMTL
NOVA_RENDERER_VK_DIR := $(NOVA_ROOT)/NovaRendererVK
CGLM_PREFIX := $(shell brew --prefix cglm 2>/dev/null)
USE_NOVA_SDK := $(if $(strip $(NOVA_SDK_ROOT)),1,0)
SDK_OBJC_SOURCES :=

LOCAL_OBJC_SOURCES := \
	$(SRC_DIR)/main.m \
	$(SRC_DIR)/viewer_app.m \
	$(SRC_DIR)/viewport.m

LOCAL_C_SOURCES := \
	$(SRC_DIR)/vmf_editor.c \
	$(SRC_DIR)/vmf_parser.c \
	$(SRC_DIR)/vmf_geometry.c \
	$(SRC_DIR)/file_index.c

NOVA_SOURCE_OBJC_SOURCES := \
	$(NOVA_RENDERER_MTL_DIR)/app_metal.mm \
	$(NOVA_RENDERER_MTL_DIR)/app_metal_editor_viewport_renderer.mm \
	$(NOVA_RENDERER_MTL_DIR)/app_metal_indirect.mm \
	$(NOVA_RENDERER_MTL_DIR)/app_metal_renderer.mm \
	$(NOVA_RENDERER_MTL_DIR)/app_metal_shader.mm

NOVA_SOURCE_C_SOURCES := \
	$(NOVA_CORE_DIR)/app_io.c \
	$(NOVA_CORE_DIR)/app_logging.c \
	$(NOVA_CORE_DIR)/nova_scene_data.c \
	$(NOVA_CORE_DIR)/nova_scene_ecs.c \
	$(NOVA_RENDERER_MTL_DIR)/app_metal_shadow_common.c

OBJC_SOURCES := $(LOCAL_OBJC_SOURCES)
C_SOURCES := $(LOCAL_C_SOURCES)

ifeq ($(USE_NOVA_SDK),0)
OBJC_SOURCES += $(NOVA_SOURCE_OBJC_SOURCES)
C_SOURCES += $(NOVA_SOURCE_C_SOURCES)
endif

METAL_SOURCES := $(SRC_DIR)/shaders.metal
FONT_ASSET := $(ASSET_DIR)/MaterialSymbolsOutlined.ttf

CFLAGS := -Wall -Wextra -Wpedantic -O2 -g \
	-I$(SRC_DIR) \
	-I/opt/homebrew/include \
	-I/usr/local/include
ifneq ($(strip $(CGLM_PREFIX)),)
CFLAGS += -I$(CGLM_PREFIX)/include
endif

ifeq ($(USE_NOVA_SDK),1)
SDK_OBJC_SOURCES := $(BUILD_DIR)/imgui_impl_osx.mm
CFLAGS += \
	-I"$(NOVA_SDK_ROOT)/include" \
	-I"$(NOVA_SDK_ROOT)/include/backends" \
	-I"$(NOVA_SDK_ROOT)/include/NovaCore" \
	-I"$(NOVA_SDK_ROOT)/include/NovaRendererMTL"
SDK_LINK_FLAGS := -L"$(NOVA_SDK_ROOT)/lib" -Wl,-rpath,@executable_path
SDK_LIBS := -lNovaRendererMTL -lNovaCore
SDK_RUNTIME_DEPS := $(BUILD_DIR)/.nova-sdk-runtime
else
CFLAGS += \
	-I$(NOVA_CORE_DIR) \
	-I$(NOVA_EDITOR_DIR) \
	-I$(NOVA_RENDERER_MTL_DIR) \
	-I$(NOVA_RENDERER_VK_DIR)
SDK_LINK_FLAGS :=
SDK_LIBS :=
SDK_RUNTIME_DEPS :=
endif

OBJC_ALL_SOURCES := $(OBJC_SOURCES) $(SDK_OBJC_SOURCES)
C_ALL_SOURCES := $(C_SOURCES)
OBJC_OBJECTS := $(addprefix $(BUILD_DIR)/,$(addsuffix .o,$(basename $(notdir $(OBJC_ALL_SOURCES)))))
C_OBJECTS := $(addprefix $(BUILD_DIR)/,$(addsuffix .o,$(basename $(notdir $(C_ALL_SOURCES)))))

OBJCFLAGS := -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework CoreText -framework Foundation -framework GameController -framework Metal -framework MetalKit -framework QuartzCore -framework UniformTypeIdentifiers

CONTENT_DIR := content

all: $(BUILD_DIR)/$(APP_NAME)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/content: $(CONTENT_DIR) | $(BUILD_DIR)
	rsync -a --delete $(CONTENT_DIR)/ $(BUILD_DIR)/content/

$(BUILD_DIR)/default.metallib: $(METAL_SOURCES) | $(BUILD_DIR)
	xcrun -sdk macosx metal -c $(METAL_SOURCES) -o $(BUILD_DIR)/shaders.air
	xcrun -sdk macosx metallib $(BUILD_DIR)/shaders.air -o $(BUILD_DIR)/default.metallib

$(BUILD_DIR)/MaterialSymbolsOutlined.ttf: $(FONT_ASSET) | $(BUILD_DIR)
	cp $(FONT_ASSET) $@

$(BUILD_DIR)/.nova-sdk-runtime: | $(BUILD_DIR)
	@if [ ! -d "$(NOVA_SDK_ROOT)" ]; then \
		echo "NOVA_SDK_ROOT '$(NOVA_SDK_ROOT)' does not exist"; \
		exit 1; \
	fi
	rm -rf $(BUILD_DIR)/shaders
	mkdir -p $(BUILD_DIR)/shaders
	cp -R "$(NOVA_SDK_ROOT)/runtime/shaders/." "$(BUILD_DIR)/shaders/"
	cp "$(NOVA_SDK_ROOT)/sources/imgui_impl_osx.mm" "$(BUILD_DIR)/imgui_impl_osx.mm"
	@find "$(NOVA_SDK_ROOT)/lib" -maxdepth 1 -type f -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do \
		cp "$$dylib" "$(BUILD_DIR)/"; \
	done
	@touch $@

$(BUILD_DIR)/imgui_impl_osx.mm: $(BUILD_DIR)/.nova-sdk-runtime
	@test -f "$@"

define COMPILE_OBJC_OBJECT
$(BUILD_DIR)/$(basename $(notdir $1)).o: $1 | $(BUILD_DIR)
	clang++ $(CFLAGS) $(OBJCFLAGS) -x objective-c++ -std=c++17 -c $$< -o $$@
endef

define COMPILE_C_OBJECT
$(BUILD_DIR)/$(basename $(notdir $1)).o: $1 | $(BUILD_DIR)
	clang $(CFLAGS) -std=gnu11 -x c -c $$< -o $$@
endef

$(foreach source,$(OBJC_ALL_SOURCES),$(eval $(call COMPILE_OBJC_OBJECT,$(source))))
$(foreach source,$(C_ALL_SOURCES),$(eval $(call COMPILE_C_OBJECT,$(source))))

$(BUILD_DIR)/$(APP_NAME): $(OBJC_OBJECTS) $(C_OBJECTS) $(BUILD_DIR)/default.metallib $(BUILD_DIR)/MaterialSymbolsOutlined.ttf $(BUILD_DIR)/content $(SDK_RUNTIME_DEPS) | $(BUILD_DIR)
	clang++ $(OBJC_OBJECTS) $(C_OBJECTS) $(FRAMEWORKS) $(SDK_LINK_FLAGS) $(SDK_LIBS) -o $@

run: all
	./$(BUILD_DIR)/$(APP_NAME)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run clean
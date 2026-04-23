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
CFLAGS += \
	-I$(NOVA_SDK_ROOT)/include/NovaCore \
	-I$(NOVA_SDK_ROOT)/include/NovaRendererMTL
SDK_LINK_FLAGS := -L$(NOVA_SDK_ROOT)/lib -Wl,-rpath,@executable_path -Wl,-rpath,$(abspath $(NOVA_SDK_ROOT)/lib)
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

OBJCFLAGS := -fobjc-arc
FRAMEWORKS := -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore -framework UniformTypeIdentifiers

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
	cp -R $(NOVA_SDK_ROOT)/runtime/shaders/. $(BUILD_DIR)/shaders/
	@for dylib in $(NOVA_SDK_ROOT)/lib/*.dylib; do \
		[ -e "$$dylib" ] || continue; \
		cp "$$dylib" $(BUILD_DIR)/; \
	done
	@touch $@

$(BUILD_DIR)/$(APP_NAME): $(OBJC_SOURCES) $(C_SOURCES) $(BUILD_DIR)/default.metallib $(BUILD_DIR)/MaterialSymbolsOutlined.ttf $(BUILD_DIR)/content $(SDK_RUNTIME_DEPS) | $(BUILD_DIR)
	clang $(CFLAGS) $(OBJCFLAGS) $(OBJC_SOURCES) $(C_SOURCES) $(FRAMEWORKS) $(SDK_LINK_FLAGS) $(SDK_LIBS) -o $@

run: all
	./$(BUILD_DIR)/$(APP_NAME)

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all run clean
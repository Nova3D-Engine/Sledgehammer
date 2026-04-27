# Sledgehammer

Sledgehammer is a native macOS VMF viewer built with C for parsing and geometry generation, plus Metal for rendering.

## Features

- Loads `.vmf` files from any Source-engine game that uses standard brush solid definitions.
- Renders four real Hammer-style panes with one perspective viewport plus `XY`, `XZ`, and `ZY` orthographic editors.
- Orthographic panes default to classic wireframe editor grids, driven by the same viewport class as the 3D pane.
- Each viewport instance can render shaded or wireframe; the default layout uses shaded 3D and wireframe 2D views.
- Panes use draggable splitters, borders, and headers so you can resize the layout to emphasize one view.
- Includes brush entities such as `func_detail` and other entities with `solid` children.
- Supports opening a single `.vmf` or recursively indexing all `.vmf` files under a directory.
- Fast loading path based on a single-pass text parser and direct brush triangulation.

## Build

```sh
brew install cglm
make
```

## Run

```sh
./build/Sledgehammer [optional path-to-vmf-or-directory]
```

If no path is passed, use `Cmd+O` from the app to open a file or directory.

## Plugins

Sledgehammer now exposes a public C plugin ABI in `include/sledgehammer_plugin_api.h`.

- On the CMake build, plugins are loaded from `build/bin/plugins` by default.
- You can override the directory with the `SLEDGEHAMMER_PLUGIN_DIR` environment variable.
- The app watches the plugins directory and hot-reloads rebuilt `.dylib` files automatically.
- Reloads are done from a copied runtime image, so recompiling a plugin does not fight with an already loaded binary.

The current API is command-oriented: plugins can register menu commands and use a host service surface for logging, alerts, current document/material/path queries, lightweight editor stats, debug overlay bounds, `Frame Scene`, and mesh rebuilds.

The bundled sample plugin now includes practical commands:

- `Run Practical Diagnostics`: quick map/setup checks (unsaved state, light count, brush complexity, texture directory setup).
- `Spawn Debug Box` / `Clear Debug Box`: visual overlay checks for plugin-driven viewport annotations.

The root CMake build includes a sample target named `SledgehammerSamplePlugin`. Rebuilding just that target is the intended hot-reload loop during development:

```sh
cmake --build build --target SledgehammerSamplePlugin
```

After the build finishes, use the `Plugins` menu inside Sledgehammer to invoke the sample command or trigger a manual reload.

## Controls

- `Cmd+O`: Open file or directory
- Native empty-state UI: Click `Open VMF Or Folder` to browse for a map
- Drag and drop: Drop a `.vmf` or folder into the window to load it
- `N`: Next indexed VMF file
- `P`: Previous indexed VMF file
- `1`: Set the focused viewport to shaded mode
- `2`: Set the focused viewport to wireframe mode
- `R`: Reload current VMF
- `K`: Frame scene bounds
- Left drag in perspective: Orbit camera in Source-style `Z-up`
- Left drag in `XY`, `XZ`, `ZY`: Pan the orthographic viewport
- Hold right mouse in perspective: Lock and hide the cursor for free-look
- `W`, `A`, `S`, `D` while holding right mouse: Move in full camera direction, including vertical pitch
- Scroll over perspective: Zoom
- Scroll over `XY`, `XZ`, `ZY`: Zoom that orthographic viewport
- Drag splitters: Resize panes like Hammer
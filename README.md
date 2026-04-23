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

## Controls

- `Cmd+O`: Open file or directory
- Native empty-state UI: Click `Open VMF Or Folder` to browse for a map
- Drag and drop: Drop a `.vmf` or folder into the window to load it
- `N`: Next indexed VMF file
- `P`: Previous indexed VMF file
- `1`: Set the focused viewport to shaded mode
- `2`: Set the focused viewport to wireframe mode
- `R`: Reload current VMF
- `F`: Frame scene bounds
- Left drag in perspective: Orbit camera in Source-style `Z-up`
- Left drag in `XY`, `XZ`, `ZY`: Pan the orthographic viewport
- Hold right mouse in perspective: Lock and hide the cursor for free-look
- `W`, `A`, `S`, `D` while holding right mouse: Move in full camera direction, including vertical pitch
- Scroll over perspective: Zoom
- Scroll over `XY`, `XZ`, `ZY`: Zoom that orthographic viewport
- Drag splitters: Resize panes like Hammer
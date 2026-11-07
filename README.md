# bsp_decompile: Quake and GoldSrc BSPs for Mirai

A plugin for the Mirai engine editor that imports compiled maps of Quake (BSP 29), GoldSrc (BSP 30, Half-
Life and Counter-Strike 1.6) and BSP2: it rebuilds their brushes from the BSP tree, writes them as Valve
220 in memory and the loader of [valve220](https://github.com/5hif7y/mirai-valve220) imports that, with
the textures the BSP keeps inside.

It needs `valve220` and [map_convert](https://github.com/5hif7y/mirai-map-convert).

## Install

It is not in the catalog on its own: there it is part of
[brush_maps](https://github.com/5hif7y/mirai-brush-maps), which joins the map plugins in one install
(`mirai plugin add brush_maps`). Installed alone, by its address, in the folder of a Mirai project:

```sh
mirai plugin add https://github.com/5hif7y/mirai-valve220.git
mirai plugin add https://github.com/5hif7y/mirai-map-convert.git
mirai plugin add https://github.com/5hif7y/mirai-bsp-decompile.git
```

## How a BSP becomes brushes

The method of the decompiler of [ericw-tools](https://github.com/ericwa/ericw-tools)
(`common/decompile.cc`, `bsputil --decompile`):

1. Each solid leaf of the tree of a model is the region behind the planes on the way to it, and
   becomes a brush: the planes of the path and of the bounds of the model, minus those that do not
   touch it.
2. A side of the brush takes the drawn faces of the node of its plane that look the same way, clipped
   to the brush.
3. A side whose faces have different textures is split through an edge of one of them, until each side
   has one texture.
4. A side without a face is hidden. On import it is `skip`, which is not drawn; the API can instead give
   it the texture of the side most opposite to it, as ericw-tools does, so the map compiles again.

The brushes are not the ones of the mapper: the compiler cut them along the tree.

Textures the BSP keeps inside (GoldSrc keeps their palette) import as they are; a texture kept in a WAD
comes from `textures/<name>.png` beside the BSP, which `map_convert.unpack_wad` writes. The textures of
Quake keep no palette inside the BSP.

## API

- `bsp_decompile.to_valve220 {path, out, skip_hidden}`: decompiles a BSP to a Valve 220 `.map` in the
  project, with the textures it keeps as PNG in `textures/` beside it.

## Measured

On Windows 10 with an Intel Core i5-7400, against the maps of Counter-Strike 1.6, which are not in the
repository:

| Map | Time | Brushes | Faces of the BSP covered by a side |
| --- | --- | --- | --- |
| fy_pool_day | 0.11 s | 442 | 1 918 of 1 958 (98 %) |
| de_dust2 | 0.63 s | 7 410 (ericw-tools: 7 375) | 18 851 of 19 236 (98 %) |

A face is covered when its center lies on a textured side of a brush. Most uncovered faces are thin
masked faces of `func_illusionary` and `func_wall`, and the doors that turn around an origin.

## Tests

With `mirai test plugins/bsp_decompile/editor/bsp`. The BSP of the tests is a cube the test writes.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.

The decompilation method is the one of [ericw-tools](https://github.com/ericwa/ericw-tools), by Eric
Wasylishen and its contributors (GPL-2.0-or-later), and this plugin owes it to them: its `bsputil
--decompile` and `common/decompile.cc` describe how a BSP becomes brushes again. The code of this plugin
is an implementation in Odin written for it, and its tests are its own. It runs only in the editor, on
import: it is not part of a game made with Mirai.

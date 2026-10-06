# Third-party notices

Short version: the addon's code is ours and MIT-licensed (see [LICENSE](./LICENSE) and the
scope note in [NOTICE](./NOTICE)); the two arrow textures are not ours to license; the quest
data comes from Questie, which users install themselves; TomTom is credited for one idea and
nothing else.

## Arrow artwork — `arrow_body.tga`, `arrow_gloss.tga`

These two files are our own rework of a single texture we obtained from
[DragonUI](https://github.com/NeticSoul/DragonUI): `DragonUI/Textures/Minimap/poi-corpse.tga`,
the corpse arrow of the retail minimap.

- `arrow_body.tga` — that texture's red channel turned into grayscale. This is the layer we tint
  with the distance colour, so it needs to carry the shading and nothing else.
- `arrow_gloss.tga` — a highlight mask we pulled out of the same texture, so the artist's white
  highlights stay white whatever colour the body is.

Behind DragonUI's copy is Blizzard's own user-interface artwork: `poi-corpse` is the retail
minimap corpse-arrow texture, and DragonUI ships it alongside textures taken from the 3.3.5a
client and from later retail and Classic clients. Reworking a texture like this does not make it
ours — it is still © Blizzard Entertainment, Inc.

So these two files are **not** covered by our MIT License and we claim no rights over them —
see [NOTICE](./NOTICE) for the exact scope. They are shipped for one purpose only: letting the
addon draw its arrow inside World of Warcraft, the same way the client draws the original.

DragonUI's MIT notice itself is reproduced in [`LICENSES/DragonUI-MIT.txt`](./LICENSES/DragonUI-MIT.txt)
so that its attribution terms are met in full — see the [DragonUI](#dragonui) section below.

If you would rather not ship Blizzard artwork at all, drop in your own arrow instead — the code
only tints and rotates these textures, it does not depend on how they look.

## Screenshots

The images in `screenshots/` are cropped in-game captures. The World of Warcraft interface
artwork and terrain they show are © Blizzard Entertainment, Inc. and are likewise not
covered by this project's MIT License.

## DragonUI

DragonUI is the minimap this addon is made for, and the addon we obtained the arrow texture
from.

DragonUI is MIT-licensed (`Copyright (c) 2026 NeticSoul and DragonUI contributors`). To meet the
attribution condition of that license in full, its MIT notice is reproduced verbatim in
[`LICENSES/DragonUI-MIT.txt`](./LICENSES/DragonUI-MIT.txt). That MIT license does **not** extend
to the Blizzard artwork described above — DragonUI states this itself in its own notice.

No DragonUI code is bundled here. DragonUI is credited as the source of the arrow texture and as
the UI the arrow is styled to match.

DragonUI's own notices credit the projects its `Textures/Minimap/` files were obtained via —
pretty_minimap by s0h2x and RetailUI — and describe them as conduits, not as the authors of the
art. We pass that credit on. `pretty_minimap` publishes no license file of its own, and no code
from either project is used here.

## Questie

Questie is our data source. The quest log, objectives, spawn coordinates, zone mapping and phasing
all come from Questie at runtime, through `QuestieLoader:ImportModule` (`QuestieMap`, `ZoneDB`,
`TrackerUtils`, `Phasing`) plus its bundled `HereBeDragonsQuestie-2.0` library. Questie is a hard
dependency (`RequiredDeps` and `LoadWith` in the `.toc`), and users install it themselves — from
the [Questie-335](https://github.com/Aldori15/Questie) backport or from upstream
[Questie](https://github.com/Questie/Questie).

**No Questie code, data or assets are bundled with or redistributed by this addon.** Questie
stays in its own folder, under its own license.

## TomTom

TomTom is credited for exactly one thing: the idea of colouring the arrow by the distance to the
target, so that green means close and red means far. That is inspiration. The implementation in
this addon — the gradient maths, the tinting, the placement and the rotation on the minimap — is
our own.

No TomTom code, textures or data are bundled or redistributed. TomTom stays under its own license.

## Trademarks

World of Warcraft, Warcraft and Blizzard Entertainment are trademarks or registered
trademarks of Blizzard Entertainment, Inc. in the U.S. and/or other countries.

This is a free, fan-made addon. It is **not** affiliated with or endorsed by Blizzard
Entertainment, Questie, TomTom, or DragonUI.

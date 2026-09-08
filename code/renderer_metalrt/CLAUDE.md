# MoHAA Metal RT Renderer

## What this is
A native Metal, ray-traced renderer for OpenMoHAA, replacing only the
renderer module. Server, client, game (`fgame`), cgame, and ui are the
existing OpenMoHAA implementation and are treated as correct and complete.
This project adds rendering capability. It does not change gameplay,
physics, AI, weapons, or level logic — not as a later phase, as a
permanent constraint. Single-player and co-op are the target;
multiplayer is out of scope (rule 7) — nothing here gets held back for
competitive-fairness reasons.

**Not the same thing as `renderer_metal`.** This repo already has a
renderer named `renderer_metal` (`cmake/renderer_metal.cmake`,
`code/sdl/sdl_metalimp.c`) that reuses `code/renderergl2`'s existing
GLSL/GLES3 source unchanged, translated to Metal at the driver level via
Google's ANGLE. It is not native, implements no `refexport_t` function
itself, and has no ray tracing — it exists to get off Apple's slow
OpenGL-over-Metal shim without touching gameplay-visible rendering. This
project is the from-scratch native renderer described below; it's named
`renderer_metalrt` specifically so it doesn't collide with that target.
`renderer_metal` stays as-is — it's a legitimate fast fallback, and a
cheap, working visual reference to diff this renderer's output against
(several subsystems this project needs to port — TIKI skinning, curve
tessellation, tcMod animation, the ghost-texture particle system — are
*already compiled and running through it today*, unchanged; it's worth
checking whether a given porting task is genuinely new work before
assuming it is).

## Hard rules
1. Do not modify `code/server/`, `code/game/`, `code/cgame/`, `code/ui/`,
   `code/qcommon/`. Read-only reference. If a task seems to need a change
   here, the task is scoped wrong — stop and say so instead of editing.
2. The only touches to `code/client/` allowed: renderer-loader plumbing
   to register `renderer_metalrt` as a selectable backend (`cl_renderer
   "metalrt"` — `"metal"` is already taken by the ANGLE backend above),
   and cvar registration. Mirror how the existing renderer(s) are loaded
   — don't redesign the loader.
3. All new code lives in `code/renderer_metalrt/`.
4. Implement the full `refexport_t` contract (see docs/ARCHITECTURE.md).
   No silent no-ops — unimplemented calls assert/log loudly, they never
   fail quietly. The real interface is 84 functions (85 if built with
   `__USEA3D` — a dead Aureal3D hint, safe to stub), not a short sketch —
   read `code/renderercommon/tr_public.h` directly before treating any
   checklist as complete.
5. Where the original renderer's math determines gameplay-visible
   fidelity, port that logic from `code/renderergl2/` — treat it as the
   reference implementation, not prior art to improve on. At minimum:
   - Patch tessellation, TIKI skinning/blend weights. Note: bone-hierarchy
     animation *blending* (keyframe interpolation, channel weighting) is
     not renderer code at all — it lives in `code/skeletor/`, reached
     through `refimport_t`. The renderer's real job is narrower than "GPU
     skinning" suggests: receive already-blended per-bone matrices, then
     skin. The existing renderer does this skin on the CPU into a flat
     vertex buffer from variable-stride, pointer-walked weight records —
     porting to a GPU compute skin means a fixed-stride preprocessing
     pass, not a recompile.
   - Particle/FX emission, decals. Gameplay particles and decal placement
     are cgame's (correctly out of scope) — but `tr_marks.c`'s BSP
     polygon-clip decal-fragment algorithm, and `tr_ghost.cpp`'s
     self-contained particle-*physics* simulation for procedural "ghost"
     textures (fire/energy surface effects, uploaded as a live-updating
     2D texture — unrelated to cgame's sprite particles), are genuinely
     renderer-owned and need porting.
   - Brush-entity kinematics (`func_rotating`, `func_door`, `func_train`,
     `func_plat`, etc.) — the renderer just draws these wherever game
     code currently places them, every tick, unconditionally. Confirmed:
     zero renderer-side logic exists for this today: no per-entity-type
     branching anywhere in the renderer.
   - Shader-level texture animation (`tcMod scroll/rotate/turb`) — pure
     UV animation, no geometry change.
   - Fog (density, color, distance) — also a fairness input, see rule 7.
     Two subsystems coexist: a legacy per-BSP-brush volumetric fog that's
     fully implemented but currently dead code (its load call is
     commented out), and an active, server-authoritative, runtime-mutable
     distance/farplane fog that differs between the main view and a
     portal-sky sub-view (separate cvars, separate cull mode, evaluated
     per sub-scene). Match the active one's per-portal behavior, not one
     global value.
   - Sky / portal-sky rendering.
   - View-model (first-person weapon) rendering — same FOV as the world
     (there is no second FOV/projection); the wall-clipping fix is the
     classic idTech3 depth-range hack (`RF_DEPTHHACK`, compressed
     `glDepthRange`) plus a separate LOD-cap curve. Port the depth-range
     compression, not a second FOV.
   - Scoped-weapon rendering — confirmed to be a single `R_RenderScene`
     call: a server-driven FOV change on the *same* camera, plus a 2D
     full-screen overlay quad (vignette/letterbox/binoculars-mask
     shader) drawn in the ordinary HUD pass. Not a second camera or a
     second render pass.
   - Cutscene/video-texture playback: confirmed present, `.roq` format,
     fully decoded client-side (`code/client/cl_cin.cpp`). Not a
     rendering concern beyond what every backend already needs — decoded
     frames arrive as plain RGBA through the same generic texture-upload
     + textured-quad path used for UI/HUD. No RoQ-specific work expected;
     smoke-test actual playback once far enough into Phase 1.
   This is a floor, not a ceiling — anything that changes what the
   player sees during normal play is fidelity-critical until proven
   otherwise.
6. Each phase in docs/ROADMAP.md has an exit criterion checked against a
   real build and a real play session. "It compiles" is never the bar.
7. This project targets single-player and co-op only. Multiplayer
   fairness is resolved, not deferred — it is not a constraint anywhere
   in this codebase:
   - No lighting-driven-visibility clamping, ever. RT shadows,
     reflections, AO, and GI ship at whatever fidelity looks best.
   - FOV / aspect ratio is a normal rendering preference, not a
     fairness-gated decision — the "wider FOV is a competitive
     advantage" concern only applies against other players, which isn't
     in scope. Pick whatever looks and feels right.
   - If multiplayer is ever added back into scope later, revisit both —
     the original concern was real, just not relevant to what's built
     here. See docs/ARCHITECTURE.md.

## License
GPLv2, matching upstream OpenMoHAA. `code/renderer_metalrt/` is GPLv2
too — no separate license for the new module. Lives in this repo
alongside the existing renderers, not a separate fork.

## Platform
macOS, arm64, Apple M3-family GPU minimum. Hardware-accelerated ray
tracing on Apple GPUs is gated to `MTLGPUFamily.apple9`, which starts at
M3/M3 Pro/M3 Max/M3 Ultra (and A17 Pro) — that's the real API-level
minimum-spec check (`MTLDevice.supportsRaytracing`). Worth stating
precisely: "M3 minimum, no Intel path" is a deliberate scope choice, not
a hard capability wall — Metal's ray tracing API is older than M3 and
does run via software/compute BVH traversal on M1/M2/Intel GPUs (just
without dedicated hardware, too slow for this project's target), and at
least one Intel Mac config with a discrete AMD RDNA2 GPU has genuine
hardware RT through the same API. None of that changes the scope
decision — it just means "M3 minimum" should be documented as "this is
where we chose to draw the line," not "this is the only hardware the API
supports."

## Assets
No original retail game content ships in this repo. MOH:AA / Spearhead /
Breakthrough pak files are the user's own retail copies, same as
upstream OpenMoHAA. This repo may ship code that generates texture
enhancements locally from a user's own retail files (see
docs/CONTENT_STRATEGY.md, Tier 2) — the tool ships, its output never
does. Freshly authored content that doesn't derive from original files
(Tier 3) isn't restricted by this rule.

## Docs
- `docs/ARCHITECTURE.md` — refexport_t contract, material system,
  acceleration structures, render pipeline, cvars.
- `docs/ROADMAP.md` — phases, exit criteria, session sizing.
- `docs/CONTENT_STRATEGY.md` — what's in and out of scope for touching
  maps and textures. Separate from, and optional relative to, the
  renderer work. Not yet written.

## Status log
Append one line per session: date, what shipped, what's next. Newest on top.

- 2026-09-07: Phase 1, session 18 shipped: closed the long-open
  "GL1 200fps vs metalrt 85-95fps" investigation - a diagnostic session,
  no rendering-path fix needed or applied, no visual verification
  required either (nothing changed on screen). `com_speeds 1`'s
  per-frame timing breakdown (sv/ev/cl/gm/rf/bk buckets, all in ms) on
  the training map showed `rf`+`bk` (render frontend/backend - CPU-side
  Metal encode+submit) reading essentially 0ms on every single frame:
  real Metal rendering was never the bottleneck. The old 85-95fps figure
  is almost certainly just `com_maxfps` (qcommon/common.c, defaults to
  85, a generic engine-wide frame limiter, not renderer-specific) -
  confirmed directly: explicitly testing at `com_maxfps 85` gives an
  ~11-12ms frame period (matches 1000/85 almost exactly), while
  `com_maxfps 0` (uncapped) gives ~7-9ms (~110-140fps) with `rf`/`bk`
  still flat 0ms either way. So the original GL1-vs-metalrt comparison
  was very likely just two runs with different `com_maxfps` settings,
  not a real Metal performance deficit - this is considered closed, not
  an open item anymore. Along the way, found (via reading `nextDrawable`/
  `presentDrawable` in `rt_init.mm`) that this renderer relied silently
  on `CAMetalLayer.displaySyncEnabled`'s default (YES) for its vsync
  pacing, never setting it explicitly the way `sdl_glimp.c` exposes
  `r_swapinterval` for GL1/GL2 - made this one line explicit with a
  comment explaining why, a zero-behavior-change hardening edit (`rt_init.mm`
  near the layer setup). Verified: `LoadWorld` still 68/69 (session 17's
  number, unchanged), stable 90+ seconds, no crash, no regression - both
  the com_maxfps tests and the displaySyncEnabled change are purely
  config/clarity, not new rendering code. Next: real skybox rendering
  (`skyParms`, to close the last 1/69 - has real 6-face JPG assets ready
  since session 15, needs visual verification once the screen unlocks),
  real LOD-adaptive patch subdivision, real lightgrid-based lighting, or
  TIKI animation/skinning - all still open.

- 2026-09-07: Phase 1, session 17 shipped: a real bug fix found while
  scanning content for session 16's PNG impact, not a new format.
  `RT_LoadImageFile` (`rt_image.mm`), when given a name with an explicit
  extension (e.g. `.tga`, exactly what a `.shader` script's `map` line
  usually gives), only ever tried that one loader and returned
  immediately even on failure - it never fell through to try other
  extensions against the same base name, unlike the real engine's
  `R_FindImageFile`. This mattered concretely: this era's assets
  routinely have a `.shader` reference `foo.tga` when only `foo.jpg`
  ever shipped (confirmed directly - `textures/interior/trenchwall2.tga`
  is referenced by `textures/interior/woodbeamed_trenchwall2`'s shader,
  but only `trenchwall2.jpg` exists in the pk3s). Fixed by falling
  through to the existing extension-search loop whenever the
  named-extension attempt returns NULL. Impact on the training map:
  `LoadWorld`'s shader-group texturing jumped from session 15/16's
  63/69 to **68/69** - every world shader but one now resolves. The
  lone holdout, `textures/sky/mohday2`, uses `skyParms` with no
  `map`/`clampmap` stage at all - a real skybox feature, correctly out
  of scope for this parser, not a bug. Verified stable (90s+, no crash,
  no regression). Next: real skybox rendering (`skyParms`) to close the
  last 1/69, real LOD-adaptive patch subdivision, real lightgrid-based
  lighting, TIKI animation/skinning, or the GL1-vs-metalrt FPS gap - all
  still open.

- 2026-09-07: Phase 1, session 16 shipped: real PNG image decoding.
  `tr_image_png.c` + `puff.c` (its inflate implementation) are, like
  TGA/BMP/PCX, pure in-tree C with no external library dependency -
  unlike session 15's JPG (which needed the vendored libjpeg) this was a
  direct addition to `RENDERER_METALRT_SOURCES` in
  `cmake/renderer_metalrt.cmake`, no glob/third-party dir/extra defines
  needed. `R_LoadPNG` matches the same `(name, byte**, int*, int*)` →
  RGBA contract as the other four loaders, so `rt_image.mm`'s
  `RT_LoadImageFile` table gained `{"png", R_LoadPNG}` with zero other
  changes. Built and linked clean. Verified stable on the training map
  (2.5+ minutes, no crash, no regression) - `LoadWorld` still reports
  63/69 shader groups textured, unchanged from session 15, because the
  remaining 6 are the already-known complex multi-stage/lightmap/sky
  shaders, not a format gap. Worth being explicit about: a full scan of
  every installed pk3 (`main/` and `mainta/`, both the base game and the
  Restoration/Allied-Assault content) found **zero** `.png` files and
  zero `.shader` script references to png - so this session adds real,
  correct decoding capability but has no visible effect on the currently
  installed asset set. That's an honest, expected result (this asset
  era predates PNG's use in this engine's content), not a wasted
  session - the loader is now there for whatever content does use it.
  Next: broader `.shader` multi-stage/lightmap-aware parsing for the
  remaining 6/69 world shaders, real LOD-adaptive patch subdivision,
  real lightgrid-based lighting, TIKI animation/skinning, or the
  GL1-vs-metalrt FPS gap - all still open.

- 2026-09-07: Phase 1, session 15 shipped: real JPG image decoding,
  closing most of session 14's 59/69 unresolved-shader gap in one move.
  Hypothesis going in: the original 2002 MOHAA assets mix TGA and JPG
  textures freely, so many of those 59 unresolved world shaders were
  probably blocked on missing JPG decoding, not `.shader`-script parsing
  depth. Confirmed vendored `code/thirdparty/jpeg-9f` (full libjpeg 9f)
  and `code/renderercommon/tr_image_jpg.c`'s `R_LoadJPG` (same
  `(name, byte**, int*, int*)` signature as the already-working TGA/BMP/
  PCX loaders, already outputs RGBA with alpha forced to 255) needed zero
  downstream changes - purely an additive loader. `cmake/renderer_metalrt.cmake`
  now builds `tr_image_jpg.c` plus a glob of `jpeg-9f/j*.c` (mirroring
  `cmake/libraries/jpeg.cmake`'s existing GL1/GL2 `USE_INTERNAL_JPEG`
  pattern, `disable_warnings()`'d since it's third-party), and
  `rt_image.mm`'s `RT_LoadImageFile` loader table gained a `{"jpg",
  R_LoadJPG}` entry. Linked clean on the first build - no symbol
  collisions with the vendored jpeg sources. On the training map:
  `LoadWorld`'s shader-group texturing jumped from session 14's 10/69 to
  **63/69** - confirming the hypothesis; the remaining 6 are still the
  genuinely complex multi-stage/lightmap/sky/fog shaders session 14
  already called out as out of scope for the current `.shader` parser.
  Stable 2.5+ minutes, no crash. Not visually confirmed this session -
  the user's screen was locked again at test time (same recurring
  blocker as sessions 12-13) - verification relied on the LoadWorld log
  line and process stability; a live pixel check is still owed whenever
  the screen next unlocks. Next: PNG support (the other common format
  gap, needs puff.c's inflate), broader `.shader` multi-stage/lightmap-
  aware parsing for the remaining 6, real LOD-adaptive patch subdivision,
  real lightgrid-based lighting, or the GL1-vs-metalrt FPS gap - all
  still open.

- 2026-09-07: Phase 1, session 14 shipped: real world/BSP surface
  texturing, closing the single biggest visual gap the GL1 before/after
  comparison exposed - only entity models (sessions 7-8) had ever gotten
  real textures; the map geometry itself always drew flat gray. Every
  `dsurface_t` carries a `shaderNum` into the BSP's own `LUMP_SHADERS`
  lump (`dshader_t::shader`, a name string) - `RT_LoadWorld`
  (`rt_world.mm`) now groups planar/patch surfaces by shader instead of
  processing them in file order, resolving each unique shader name
  through the exact same `RT_RegisterImageCommon`/`.shader`-script
  pipeline entity surfaces already use (sessions 7-8), and baking each
  vertex's real UV from `drawVert_t::st` (planar) or interpolating it
  via the same Bezier basis weights as position/normal (patches,
  extending session 11's `RT_EvalBezierPatch3x3`). World geometry still
  has no index buffer (session 4's original design - a flat, non-indexed
  triangle list), so "per-surface texturing" here means grouping each
  shader's surfaces into one CONTIGUOUS range of the shared vertex/
  normal/texcoord arrays and drawing that range directly via
  `vertexStart`/`vertexCount` - the non-indexed equivalent of
  `rt_scene.mm`'s per-surface `indexOffset`/`indexCount`. Extracted a
  new shared helper, `RT_DrawTexturedGeometry` (`rt_scene.mm`, moved
  `RT_EnsurePipelineTextured3D` out of its anonymous namespace to expose
  it too), so `rt_world.mm` reuses the exact same three pipeline
  variants (opaque/alpha/additive, session 13) entities already use,
  rather than a second copy. On the training map: 69 unique shaders in
  use, 10 resolved a real texture (most world shaders are more complex
  than a single map/clampmap stage - multi-stage lightmap blending, sky,
  fog - well beyond this session's parser); those 59 unresolved groups
  correctly fall back to the same flat-gray pipeline every world surface
  used before this session, not a regression. Visually confirmed live:
  tree/foliage geometry that previously blended into flat gray now shows
  real, visible stippled texture detail. Stable for 4+ minutes, no
  crash, no regression to lighting, entity texturing/blend-modes, or 2D
  UI. Next: broader `.shader` stage support (specifically multi-stage/
  lightmap-aware parsing, to raise that 10/69 ratio - the natural
  continuation of this session), real LOD-adaptive patch subdivision,
  real lightgrid-based lighting, or investigating the GL1-vs-metalrt FPS
  gap (200 vs ~85-95, recorded but not yet investigated) are all open.

- 2026-09-07: Post-unlock verification closed out both sessions 12 and
  13's deferred visual checks (the user's screen was locked for the
  entirety of both). Confirmed on the training map: session 12's
  `DrawString` genuinely renders live, dynamic text ("Health"/"100"/an
  FPS counter that visibly changes frame to frame, so it can't be a
  baked image) - not just parsing successfully, actually drawing
  correctly. Session 13's blend-mode pipeline additions cause no
  regression to existing opaque rendering (nothing in this specific
  scene happens to use a transparent/additive shader, so the blend
  paths themselves still await a direct visual hit, but the change is
  provably safe). Also did a direct side-by-side against `opengl1`
  (real retail rendering) from the identical training-map spawn point,
  at the user's request, to honestly answer "is this doing heavy
  lifting": geometry, perspective, and lighting/shading all match GL1's
  scene layout exactly (same guard tower, road, fence positions;
  visible gradient shading on the terrain) - real, substantial work,
  not cosmetic. The stark, honest gap the comparison exposes: **world/
  BSP surfaces still have zero texturing** (flat gray everywhere) -
  only entity models (weapons/props, sessions 7-8) ever got real
  textures; the map geometry itself never did. Also recorded for
  reference, not yet investigated: GL1 ran this scene at 200 FPS vs.
  metalrt's 84.7 - a real, currently-unexplained performance gap (a
  likely early suspect: `RT_DrawStretchPic`/`RT_DrawString`'s per-call
  `newBufferWithBytes` for every 2D quad, allocating a fresh Metal
  buffer every single glyph/UI element every frame instead of reusing
  one). Next: real world/BSP surface texturing (the clear top pick -
  it's the single biggest remaining visual gap and now has direct
  before/after proof), the FPS gap, real LOD-adaptive patch subdivision,
  real lightgrid-based lighting, or broader `.shader` stage support are
  all open.

- 2026-09-07: Phase 1, session 13 shipped: real `.shader` blend-mode
  support - transparent/additive surfaces (glass, glow, fire, energy
  effects) previously always rendered fully opaque regardless of what
  their shader specified. `RT_ClassifyBlendFunc`/`RT_FindShaderScriptTexture`
  (`rt_image.mm`) now also scan a matched shader block for a `blendfunc`
  line and classify it into one of 3 buckets (`rtBlendMode_t`,
  `rt_local.h`): opaque (no blendfunc), alpha, or additive - mirroring
  `ParseStage`'s own "simple blends first (`add`/`filter`/`blend`, plus
  OPENMOHAA's `alphaadd`), then complex double-token form" dispatch
  (`tr_shader.c`), but deliberately coarse: Metal needs a distinct
  pipeline per blend config, so this renderer maintains 3, not one per
  unique GL src/dst factor combination - `filter` (a multiply-darken
  preset) folds into the alpha bucket as the closer of the two
  approximations, and any complex-form blend whose dst factor is
  `GL_ONE` (the common trait of every additive-looking blend,
  regardless of its src factor) classifies as additive. Classification
  is cached on the resolved image handle (`rtImage_t::blendMode`,
  `RT_GetImageBlendMode`) alongside its texture, not re-parsed per use.
  Two new textured 3D pipeline variants (`rtPipelineTexturedAlpha3D`/
  `rtPipelineTexturedAdditive3D`) share the exact same compiled vertex/
  fragment shader as the existing opaque one - only their color-
  attachment blend config differs - plus a separate depth state for
  both blended variants (`rtDepthStateBlended3D`: tests depth so solid
  geometry still occludes them, but doesn't write it, so one
  transparent surface can't incorrectly block another drawn later the
  same frame). `RT_RenderScene` picks the pipeline+depth-state pair
  per-surface from its cached blend mode. Verified real content
  actually uses this: `scripts/environmentalfx.shader` has genuine
  `blendFunc add` and `blendfunc GL_ONE GL_ONE_MINUS_SRC_ALPHA` lines,
  both handled correctly by the new classifier (confirmed via static
  inspection of the retail PK3, not runtime). All 3 pipeline variants
  compile successfully; stable for 4+ minutes on the training map, no
  crash. Honest limitation, continued from session 12: the user's
  screen remained locked for this entire session too, so no live pixel
  check of an actual transparent/additive surface was possible -
  correctness rests on real-content syntax validation plus reuse of
  the already-proven vertex/fragment shader (only the blend STATE is
  new, a standard, narrow Metal API surface), not a direct visual.
  **Both this session and session 12 need a real screenshot next time
  the screen is unlocked before trusting them further** - this is the
  first priority for the next session, before any new feature work.

- 2026-09-07: Phase 1, session 12 shipped: real font loading and text
  rendering (`LoadFont`/`DrawString`/`GetFontHeight`/`GetFontStringWidth`,
  new `rt_font.mm`), replacing the session-1 crash-safe-but-invisible
  stub. MOHAA's simple fonts are plain-text `fonts/<name>.RitualFont`
  files - parsed with the same `COM_Parse` tokenizer already linked in
  for `.shader` scripts (session 8): a height, an aspect ratio, a
  256-entry `indirection` table (character code -> glyph slot, -1 = no
  glyph), and a 256-entry `locations` table of normalized UV rects into
  one shared glyph-atlas texture named `gfx/fonts/<name>` - resolved
  through the exact same `RT_RegisterImageCommon`/`.shader` pipeline any
  other image name goes through. `DrawString` draws each glyph by
  calling the already-proven `RT_DrawStretchPic` once per character
  (exposed non-`static` for this) - text rendering is genuinely just
  "the same textured-quad draw, looped," so it reuses that function's
  entire pipeline/Set2DWindow-mapping/encoding logic rather than
  duplicating any of it. Ported byte-for-byte from the real renderer's
  `R_LoadFont_sgl`/`R_DrawString_sgl`/`R_GetFontStringWidth_sgl`
  (`tr_font.cpp`), including the `pvVirtualScreen` scaling path. Scoped
  to the common case only (`fontheader_t::numPages == 0`, a single sgl
  page) - matches the real renderer's own dispatch; multi-page/CJK
  fonts (rarer, real, separate work) still get a safe, glyph-empty
  fallback rather than crashing. On the training map: 4 real fonts
  parsed successfully (`verdana-14`, `verdana-12`, `marlett`,
  `facfont-20`, all with plausible height/aspect values), each
  resolving a real glyph-atlas texture; `DrawString` confirmed invoked
  with sane parameters (real font, in-range screen coordinates, correct
  virtual-screen detection) via a temporary diagnostic (removed before
  committing). Honest limitation: the user's screen was locked for this
  entire session, so no live *visual* confirmation of actual rendered
  glyphs was possible (`screencapture`/window capture both fail while
  locked - confirmed via `CGSSessionScreenIsLocked`) - correctness rests
  on the parsing/invocation evidence above plus reuse of `DrawStretchPic`'s
  already-extensively-verified pipeline, not a direct pixel check. Get a
  real screenshot of rendered text next session before trusting this
  further. Next: that visual verification, real LOD-adaptive patch
  subdivision, real lighting derived from the map's actual data
  (lightgrid/light entities), or broader `.shader` stage support are all
  still open.

- 2026-09-07: Phase 1, session 11 shipped: real MST_PATCH (curved
  surface) tessellation, closing the largest remaining world-geometry
  gap - 788 of the training map's surfaces (about 18% of the total)
  were being skipped entirely since session 4. `RT_TessellatePatchSurface`
  (`rt_world.mm`) implements the classic idTech3 curved-surface scheme:
  a `patchWidth`x`patchHeight` control-point grid is really a set of
  overlapping 3x3 biquadratic Bezier sub-patches (each pair of extra
  rows/columns beyond the first 3 shares an edge with the next
  sub-patch). `RT_EvalBezierPatch3x3` evaluates one sub-patch at
  parametric (u,v) via the standard closed-form biquadratic basis
  functions - a deliberate simplification of the real renderer's
  `R_SubdividePatchToGrid` (`tr_curve.c`), which iteratively refines the
  grid via LOD-adaptive row/column insertion instead; this tessellates
  every patch at one fixed resolution (`RT_PATCH_TESSELLATION` = 8
  subdivisions/edge) - mathematically the same curve, just not
  view-distance-adaptive or crack-prevented against neighboring patches
  at a different LOD yet. Per-vertex normals are interpolated from the
  control points' own normals using the same Bezier basis weights,
  rather than recomputed from the tessellated geometry
  (`MakeMeshNormals` in the real engine) - a reasonable first-pass
  approximation. Output is appended to the exact same flat,
  non-indexed world vertex/normal arrays planar surfaces already use -
  no new pipeline, buffer, or draw call needed. On the training map: all
  788 patch surfaces tessellated successfully (627,255 total verts
  uploaded, up from 32,055 planar-only). Visually confirmed live: a
  road/path surface that previously rendered as a single flat, familiar
  dark shape with no visible structure now shows real geometry with
  correct receding perspective and edges, and a gate structure
  previously invisible against the flat background is now clearly
  visible. Stable for 4+ minutes, no crash, no regression to lighting,
  texturing, or entity rendering. Next: real LOD-adaptive patch
  subdivision (view-distance-based, crack prevention - this session's
  fixed-resolution approach can show visible seams between adjacent
  patches at very close range), real lighting derived from the map's
  actual data (BSP lightgrid/light entities), broader `.shader` stage
  support, or real `DrawString`/font rendering are all still open.

- 2026-09-07: Phase 1, session 10 shipped: real per-vertex directional
  lighting for both world geometry and entities, replacing flat/uniform
  color everywhere. Honest scope: a single fixed "sun" direction
  (`RT_GetLightDir`, `rt_scene.mm`) with a simple ambient-floor +
  Lambertian diffuse term (`mix(0.35, 1.0, max(dot(N,L),0))`) - not yet
  anything derived from a map's actual light entities or BSP lightgrid
  (real, separate work for later). World geometry now bakes real
  per-vertex normals from `drawVert_t::normal` (`rt_world.mm`, already
  present in the BSP data, just unused until now); entity models bake
  normals in `RT_BakeTikiModel` using only the vertex's FIRST bone
  weight's rotation, matching the real renderer's own
  `SkelVertGetNormal` (`tr_model.cpp`) - normals use a single dominant
  bone even in the fully-correct animated path, unlike positions which
  correctly sum every weight; the flat-magenta placeholder box also got
  real per-face normals (6 hardcoded outward directions) so it's lit
  consistently with everything else rather than being a special case.
  Both 3D pipelines (`rt_vertex_3d`/`rt_fragment_3d` and
  `rt_vertex_3d_tex`/`rt_fragment_3d_tex`) now take a per-vertex normal
  buffer plus a per-draw `normalMatrix` (the entity's model-rotation 3x3,
  valid directly with no inverse-transpose since `RT_BuildModelMatrix`'s
  axes are always orthonormal) and a shared `lightDir` uniform. Visually
  confirmed live on the training map: previously-flat, uniformly-gray
  terrain and structures now show real per-face shading - a wooden
  guard tower's individual planks/beams are now clearly visible via
  light/dark face contrast, where before they blended into flat
  background gray with no visible structure at all. No regression (world
  load, entity registration/texturing, 2D UI all unaffected code paths);
  stable for 4+ minutes on the training map. Next: real lighting derived
  from the map's actual data (BSP lightgrid or light entities, replacing
  the fixed sun direction), patch/curve tessellation (the 788
  still-skipped BSP surfaces), broader `.shader` stage support (blend
  modes, tcMod scroll/animation), or real `DrawString`/font rendering
  are all still open.

- 2026-09-07: Phase 1, session 9 shipped: fixed a real, previously
  undetected Y-axis bug in session 5's `Set2DWindow`/`Scissor` fix. Root
  cause: `UIWidget::set2D()` (`code/uilib/uiwidget.cpp`) computes its Y
  parameter for BOTH `Rend_Set2D`/`Rend_Scissor` as `vidHeight - (widget's
  local bottom edge)` - a real `qglViewport`/`qglScissor` call needs that
  (OpenGL's viewport origin is bottom-left), but Metal's viewport/pixel Y
  is top-down. `RT_MapLocalToScreen`/`RT_Scissor` (`rt_image.mm`) were
  using that value directly as if it were already a top-down screen Y,
  which is a different, generally-wrong value - the true top-down top
  edge is `vidHeight - (vy + vh)`, not `vy` itself. This silently escaped
  every session-5/6/7/8 visual check because the error is invisible for
  widgets that span nearly the full window height (`vy≈0`, e.g. the
  `main_a`/`main_b` background) or for symmetric pairs only ever compared
  against each other (the pause menu's "Back to Game"/"Quit" - both were
  wrong by the identical amount, so their left/right spread still looked
  "fixed," even though both were actually rendering near the TOP of the
  screen instead of the bottom where the `.urc` places them, y=448 of
  480). Found by chasing the user's live report of the *actual* main
  menu (`ui/main.urc`, richer than the 2-button pause menu ever
  exercised) looking "garbled, objects improperly placed" - root-caused
  with a temporary diagnostic (logging every `DrawStretchPic` call's
  resolved screen rect against its image name, `rt_image.mm`, removed
  before committing) cross-referenced directly against `main.urc`'s real
  widget rects extracted from the retail PK3s: `bigmap` ("new game old"
  button, `.urc` rect 139,89,192,160) was landing 237px too low on
  screen - `237 ≈ 800 - 2×148.3 - 266.7`, i.e. exactly the gap between
  "vy used directly" and "vy correctly converted," which conclusively
  distinguished a coordinate bug from a design-intentional overlap with
  the neighboring `war_records` button. Fixed in both
  `RT_MapLocalToScreen` (2D image/text draws) and `RT_Scissor` (clip
  rects) - both take the same GL-bottom-up Y from the same
  `UIWidget::set2D` call, so both needed the identical conversion.
  Visually confirmed live by the user on the real main menu (previously
  showed a garbled/duplicate-looking overlap; now clean) and by the
  author (the pause menu's "Quit" button now correctly sits near the
  bottom-right, matching its `.urc` position, instead of the top-right
  it incorrectly rendered at since session 5). No regression on 3D
  world/entity rendering (unaffected code path) or the previously-fixed
  simple pause-menu case, reconfirmed on the training map. Next: real
  lighting, patch/curve tessellation (the 788 still-skipped BSP
  surfaces), broader `.shader` stage support (blend modes, tcMod
  scroll/animation), or real `DrawString`/font rendering (found as a
  genuine unimplemented stub during this session's investigation -
  distinct from this session's fix, since `ui/main.urc`'s button "text"
  turned out to be baked into the button images, not dynamically drawn;
  other UI screens that DO use dynamic text will currently render it as
  nothing) are all still open.

- 2026-09-07: Phase 1, session 8 shipped: real `.shader` script parsing
  (`RT_FindShaderScriptTexture`, `rt_image.mm`) - the gating dependency
  session 7 identified for its texturing infrastructure to have any
  visible effect. Reuses the tokenizer already linked into this
  renderer's dylib for other reasons (`COM_ParseExt`/`SkipBracedSection`/
  `COM_StripExtension`, from `code/qcommon/q_shared.c`, already compiled
  in per `cmake/renderer_metalrt.cmake`) rather than writing a new one:
  `ri.FS_ListFiles("scripts", ".shader", ...)` enumerates every shader
  script (PK3-aware, same call the real renderer's own
  `ScanAndLoadShaderFiles` makes), then for a requested shader name,
  linearly scans each file's top-level tokens for a case-insensitive
  name match (skipping non-matching blocks via `SkipBracedSection`,
  mirroring the real renderer's `FindShaderInShaderText`), then scans
  every stage inside the matched block - not just the first - for the
  first `map`/`clampmap` argument that isn't one of the three special
  non-file values (`$whiteimage`/`$lightmap`/`$deluxemap`). That
  cross-stage scan matters: some real world shaders put `$lightmap` in
  stage 1 and the actual diffuse texture in stage 2 (confirmed with a
  real example, `scripts/algiers.shader`'s `lightplaster1`) - stopping
  at the first stage's first `map` would silently resolve nothing for
  those. `RT_RegisterImageCommon` now tries this lookup first and only
  falls back to treating the name as a direct image file (the *only*
  thing it did through session 7) if no shader script matches - the
  same order the real renderer's `R_FindShaderEx` uses. Result on the
  training map: 118 successful texture resolutions vs. 4 failures, up
  from 32/175 in session 7 - and critically, this time real gameplay
  content resolved correctly (`M2FragGrenade`, `colt`, `P38`, `Garand`,
  `springfield`, `KAR98`, etc.), not just 2D UI textures. Visually
  confirmed live via the same synthetic debug-entity method used in
  sessions 6-7 (removed before committing) - a grenade model now shows
  its own real, naturally-resolved M2FragGrenade texture (correct
  fragmentation pattern, no manual forcing needed this time). Also
  fixed, as a side effect of the same change: the radio pickup HUD icon
  (`textures/hud/item_radio`, first noted failing back in session 4's
  status log) now resolves and renders correctly too, confirmed live by
  the user recognizing it on screen without prompting. Deliberately
  narrow scope, matching the plan: only `map`/`clampmap` are understood;
  everything else a shader can specify (blend modes, tcMod animation,
  rgbGen, alphaFunc, sort, cull, deformVertexes, sky, fog, multiple
  independently-blended stages) is silently skipped by the parser's own
  token fallthrough - not a "no silent no-ops" violation, since skipping
  unrecognized syntax is normal parser behavior, not a failure; it just
  means every real texture still renders unlit/flat and un-blended
  rather than with its actual intended look. Next: real lighting (the
  natural next visual gap now that real geometry+textures both exist),
  patch/curve tessellation (the 788 still-skipped BSP surfaces), or
  broadening shader-stage support (blend modes for transparent/additive
  surfaces, tcMod scroll/animation) are all still open.

- 2026-09-07: Phase 1, session 7 shipped: real per-surface model
  texturing infrastructure. `RT_BakeTikiModel` (`rt_scene.mm`) now also
  bakes each vertex's `skeletorVertex_t::texCoords` into a parallel
  texcoord buffer, and records one draw range (index offset/count) per
  real mesh surface instead of merging a whole model into a single
  draw. Each surface's texture is resolved by matching its baked name
  (e.g. "ranger_top") against `dtiki_t::surfaces[]`'s TIKI-level
  `surface <name> shader <name>` mappings from the .tik script - a
  SEPARATE list from the mesh geometry surfaces, matched by name, the
  same way the real renderer's `R_InitStaticModels` resolves shaders for
  static props - then reuses `RT_RegisterImageCommon` (rt_image.mm,
  moved out of its anonymous namespace so this file can call it) to try
  loading it as a direct image file. A new textured pipeline
  (`rt_vertex_3d_tex`/`rt_fragment_3d_tex`) samples a resolved texture
  using the baked UVs; any surface with no resolvable texture keeps
  using the original flat-magenta pipeline, per-surface, not per-model -
  a model can legitimately mix both. On the training map: 32 direct
  image loads succeeded, 175 failed - but *all 32 successes were 2D
  UI/HUD textures*, zero from any of the 138 registered models' surfaces.
  This is an honest, expected result, not a bug: real MoHAA model
  materials are virtually all `.shader`-script references (multi-stage,
  blend/animation effects), not bare image files, so this session's
  infrastructure is real and correct but has no visible effect on actual
  gameplay content yet - `.shader` script parsing (repeatedly deferred to
  "Phase 2" since session 2) is the actual gating dependency for any
  model to visibly render textured. Verified the textured pipeline
  itself is genuinely correct anyway, via a temporary two-part
  hack (removed before committing): forced `RT_ResolveSurfaceTexture` to
  fall back to a known-loadable UI texture (`textures/hud/compassface`)
  when normal resolution failed, and re-added session 6's synthetic
  debug-entity injection (`m2fgrenade.tik`) - the result was a
  correctly-oriented compass texture visibly wrapped around the real
  grenade mesh shape, confirming UV baking, sampling, and compositing
  all work correctly end to end. Next: `.shader` script parsing (the
  real unlock for this session's work to have any visible payoff),
  patch/curve tessellation (the 788 still-skipped BSP surfaces), or
  extending session 5's `Set2DWindow` coordinate fix to the other 2D
  draw calls are all still open.

- 2026-09-07: Phase 1, session 6 shipped: real static TIKI mesh geometry,
  replacing every `RT_MODEL` entity's flat-magenta placeholder box with
  its actual mesh shape. Turns out this needed almost no new parsing
  code: `code/tiki/`'s full text-`.tik` + binary-`.skd` parser is already
  reachable through `refimport_t` (`ri.TIKI_RegisterTikiFlags`,
  `ri.TIKI_GetSkel`, `ri.TIKI_GetSkelAnimFrame`, `ri.TIKI_GetLocalChannel`)
  - the same import table this renderer already uses for
  `ri.FS_ReadFile`. `RT_RegisterModelInternal` now calls
  `ri.TIKI_RegisterTikiFlags` (replacing the old bare existence check)
  and, on success, bakes every mesh/surface's vertices into one flat
  position-only vertex+index buffer via `RT_BakeTikiModel` (`rt_scene.mm`):
  walk the variable-stride `skeletorVertex_t`+weights chain per vertex,
  transform each weight's bone-relative offset by a `skelBoneCache_t`
  from one `ri.TIKI_GetSkelAnimFrame` call (idle/frame-0 pose - no
  runtime skinning, matching the real renderer's own `R_InitStaticModels`
  for non-animating props), and sum over *every* weight rather than only
  the first (the real `R_InitStaticModels` takes that shortcut, correct
  only for single-weight vertices - ported the fully-correct summed
  version from the animated path's `SkelWeightGetXyz` instead, at
  effectively no extra cost since this only runs once per model at
  registration). No normals/UVs baked yet - the 3D pipeline has no
  lighting or texturing to feed them to (still one flat fragment color
  per draw call, same as the box it replaces). On the training map, all
  138 registered models baked real geometry with zero placeholder-box
  fallbacks. Visually confirmed live via the same temporary-injection
  method session 3 used (a synthetic entity referencing a real baked
  handle, removed before committing): first tried a weapon viewmodel
  (`colt45.tik`) and it rendered "upside down" - turned out to be the
  wrong test subject, not a bug, since viewmodels are authored for
  hand-bone attachment with additional transforms this renderer doesn't
  apply yet, not for free-standing display. Switched to a world/pickup
  model (`models/projectiles/m2fgrenade.tik`) and got a correctly-shaped,
  correctly-oriented grenade sitting on the terrain. Next: real per-model
  texturing (resolve each surface's shader name to a registered image
  and add UV output/texture sampling to the 3D pipeline - currently every
  real mesh still draws in the same flat magenta as the box it replaced),
  patch/curve tessellation (the 788 still-skipped BSP surfaces), or
  extending session 5's `Set2DWindow` coordinate fix to the other 2D draw
  calls (`DrawTilePic`/`DrawStretchPic2`/etc.) are all still open.

- 2026-09-07: Phase 1, session 4 shipped: real world/BSP geometry.
  `LoadWorld` (`rt_world.mm`, new file) reads a `.bsp` via `ri.FS_ReadFile`,
  validates `BSP_MIN_VERSION`/`BSP_MAX_VERSION`, walks `LUMP_SURFACES` via
  `Q_GetLumpByVersion`, and uploads every `MST_PLANAR` surface's triangles
  (indexed into the shared map-wide `LUMP_DRAWVERTS` array, already
  world-space) into one `MTLBuffer`. Non-planar surface types (patches,
  triangle soup, terrain, flares) are counted and logged as skipped, not
  silently dropped. `RT_DrawWorld` reuses session 3's exact 3D pipeline/
  depth-state (`RT_EnsurePipeline3D`, now exposed outside `rt_scene.mm`'s
  anonymous namespace) with an identity model matrix and a flat gray
  fragment color, drawn unconditionally before entities each frame. On
  the training map: 3553 planar surfaces / 32055 verts loaded and
  uploaded successfully; 788 non-planar surfaces correctly skipped.
  Visually confirmed live - the user saw real geometry ("a blue road
  going into the distance") matching the training map's actual layout.
  One real, reproducible crash found and fixed along the way, unrelated
  to world geometry itself: `renderer_metalrt` never called
  `ri.IN_Init(window)` after creating its SDL window (both `sdl_glimp.c`
  and `sdl_metalimp.c` do this for their renderers; this one never did,
  since session 1 didn't know the input subsystem needed it). Effect:
  `sdl_input.c`'s internal `SDL_window` stayed NULL forever, and
  `IN_Frame` only actually dereferences it once gameplay reaches a fully
  active, unpaused state (menu/loading states short-circuit before that
  line) - hence a SIGABRT that reproduced 3/3 times but always at a
  seemingly different, late point, not on frame 1. Fixed by adding the
  matching `ri.IN_Init`/`ri.IN_Shutdown` calls to
  `RT_InitWindowAndDevice`/`RT_ShutdownWindowAndDevice`; verified stable
  for ~2 minutes past every previous crash point after the fix, with no
  further backtraces. Also found, NOT fixed this session (separate,
  pre-existing, 2D-UI scope from session 2): `Set2DWindow` is still a
  loud stub (`rt_stubs.cpp`) - `DrawStretchPic` never picks up the
  viewport/ortho window it's supposed to establish, so every menu
  element draws through the same fixed full-window transform instead of
  its own position. Visible symptom: hovering different main-menu/pause-
  menu buttons shows each one stacked in the same wrong spot (top-left)
  instead of spread across the screen. Next: implement `Set2DWindow`
  properly (real fix for the menu-layout bug above - likely the more
  valuable pick, since it blocks reading any menu that isn't a single
  full-screen button); alternatively, real TIKI mesh parsing (replace
  session 3's placeholder boxes with actual model geometry) or patch/
  curve tessellation (the 788 currently-skipped non-planar surfaces) are
  both still open.

- 2026-09-07: Phase 1, session 5 shipped: real `Set2DWindow`/`Scissor`
  (`rt_image.mm`), fixing the menu-layout bug session 4 found. Root
  cause, traced directly in `code/uilib/uiwidget.cpp`: every UI widget
  calls `Set2DWindow` once before drawing itself
  (`UIWidget::set2D`, line 841) with its own screen-space viewport rect
  and a local coordinate origin, then draws its background/hover art at
  local `(0,0,width,height)` (line 1974 onward) - relying entirely on
  that mapping to land at its real position. `DrawStretchPic` was
  treating those local coordinates as absolute screen pixels, so every
  widget's `(0,0)` was misread as the literal top-left corner - hence
  every menu button drawing stacked in the same spot. Fixed by storing
  the viewport+ortho state `Set2DWindow` establishes and remapping every
  `DrawStretchPic` call's local coordinates through it
  (`RT_MapLocalToScreen`) before the existing screen-to-NDC conversion;
  defaults to an identity mapping (matching the real renderers' own
  full-screen default, e.g. GL1's `RB_SetGL2D`) so anything drawn before
  the first real `Set2DWindow` call behaves exactly as before. `Scissor`
  is a real, clamped `setScissorRect:` call now too - implemented
  alongside `Set2DWindow` since `UIWidget::set2D` always calls both
  together, and Metal's scissor state resets automatically each frame
  (a fresh encoder is created every `RE_BeginFrame`), so a widget's clip
  rect from a UI frame can't leak into the next frame's 3D pass. No
  regressions on world/entity/HUD rendering (compass, health bar all
  correct on the training map). Visually confirmed live by the user: the
  pause menu's "Back to Game" and "Quit" buttons, previously both
  stacked in the same top-left spot, now render as two distinct buttons
  in their own positions (top-left and top-right). Only `DrawStretchPic`
  respects `Set2DWindow` so far - `DrawTilePic`/`DrawStretchPic2`/etc.
  remain stubs, so any widget using `WF_TILESHADER` still won't draw
  (loud stub warning, not silently broken). Next: real TIKI mesh parsing
  (session 3's placeholder boxes), patch/curve tessellation (the 788
  currently-skipped BSP surfaces), or extending the coordinate fix to
  the other 2D draw calls are all still open.

- 2026-09-07: Phase 1, session 3 shipped: a real 3D scene path.
  `RegisterModel`/`RegisterServerModel`/`SpawnEffectModel` (all three
  funnel through one shared registration helper, `rt_scene.mm`, matching
  how `R_RegisterModelInternal` backs all three in the real renderer)
  check that a named `.tik` file genuinely exists in the PK3-mounted
  filesystem and hand back a real handle - no TIKI parsing yet, each
  handle just means "draw a flat-magenta placeholder box," a deliberate
  stand-in for real model geometry. `ClearScene`/`AddRefEntityToScene`/
  `RenderScene` are real too: a proper view+projection matrix is built
  from the `refdef_t` the game actually submits each frame
  (`vieworg`/`viewaxis`/`fov_x`/`fov_y`), and every valid `RT_MODEL`
  entity draws its placeholder box at the correct world position through
  a new depth-tested 3D pipeline (added a `Depth32Float` texture/
  `MTLDepthStencilState`, the first depth buffer this renderer has had).
  Visually confirmed live via a temporary synthetic test box injected
  directly in front of the camera (removed before this commit) - correct
  perspective, correct depth compositing, correct 2D-HUD-over-3D-scene
  ordering. Two real fixes along the way: (1) `ri.FS_FileExists` only
  checks the loose homepath data directory, not PK3 archives (it's wired
  to `FS_FileExists_HomeData` in `cl_main.cpp`) - `.tik` existence checks
  need `FS_ReadFile(name, NULL)` instead, the same PK3-aware mechanism
  the image loaders already use; (2) confirmed via `tr_main.c`'s
  `R_RotateForViewer`/`s_flipMatrix` comment ("looking down X" ->
  "looking down -Z") the exact camera axis convention:
  `viewaxis[0]`=forward, `[1]`=left, `[2]`=up, used to derive the view
  matrix from scratch for Metal. On real training-map content, 138
  distinct `.tik` models registered successfully across all three entry
  points, confirming the registration path handles real game data at
  scale even though no single real entity happened to be in view during
  headless testing (the ones that were had a genuinely unregistered
  model - `models/fx/fx_fence_wood.tik` doesn't exist in this install).
  Next: real TIKI parsing (read `code/tiki/`'s formats, replace the
  placeholder box with actual mesh data - no skinning/animation yet,
  just static geometry) is the natural next step now that registration
  and scene submission are proven; alternatively, JPG/PNG image loading
  (still open from session 2) or world/BSP rendering (`LoadWorld`) are
  both still untouched and viable next sessions.

- 2026-09-07: Phase 1, session 2 shipped: real `RegisterShader`/
  `RegisterShaderNoMip`/`DrawStretchPic` (`rt_image.mm`), visually
  confirmed live - a real menu button ("QUIT") loads and draws correctly,
  alpha-blended, over the session-1 clear color. `RegisterShader`
  currently treats its name as a direct image file (TGA/BMP/PCX only -
  JPG needs libjpeg, PNG needs puff.c's inflate, both real but deferred
  to their own session for the CMake wiring), not a `.shader` script -
  that parser is Phase 2's job, so most menu shader names correctly log
  "no .shader script support yet" and don't draw, which is expected, not
  a bug. Also restructured `RE_BeginFrame`/`RE_EndFrame` to keep one
  `MTLRenderCommandEncoder` open across the whole frame (previously
  opened+closed immediately in `BeginFrame` with nothing to draw) so
  draw calls in between can encode into it; added `RT_GetDevice()`/
  `RT_GetCurrentEncoder()` accessors to rt_local.h for that. 2D
  projection is a direct CPU-side screen-pixels-to-NDC conversion, no
  projection matrix/uniform yet - fine for now, revisit if something
  needs it (e.g. a future scissor/viewport feature). Next: either wire
  up JPG/PNG loading (real content will need both), or start on
  `RegisterModel`/a minimal 3D scene path (`ClearScene`/
  `AddRefEntityToScene`/`RenderScene`) - whichever blocks seeing more of
  the actual menu/game content next.

- 2026-09-07: Phase 1, session 1 shipped: `renderer_metalrt` builds and
  loads via `cl_renderer "metalrt"` (new `cmake/renderer_metalrt.cmake`,
  `enable_language(OBJCXX)` added to macos.cmake for this - the project's
  first Objective-C++ file). `GetRefAPI` opens a real SDL Metal window,
  creates an `MTLDevice`/command queue/`CAMetalLayer` swapchain, and
  `BeginFrame`/`EndFrame` clear-and-present a solid color every frame -
  visually confirmed live. All 84 `refexport_t` functions are populated
  (5 real lifecycle/frame functions in `rt_init.mm`, the other 79 as
  loud one-time-warn stubs in `rt_stubs.cpp`, never silent per rule 4).
  Two real crashes found and fixed along the way, both worth remembering
  for later sessions: (1) `UIFont`'s constructor (`code/uilib/uifont.cpp`)
  hard-`Sys_Error`s if `LoadFont` returns NULL - can't reach any screen,
  menu or otherwise, without a font. (2) `UIFont::getCharWidth`/`getHeight`
  read a `fontheader_t`'s `sgl[]`/`charTable` internals *directly*,
  bypassing `GetFontStringWidth`/`GetFontHeight`/`DrawString` entirely -
  so even a non-NULL empty font struct segfaults on `sgl[0]->indirection[ch]`
  the first time any UI text measures itself (unavoidable during startup,
  `View3D::InitSubtitle`). `RT_LoadFont`'s stub now returns a font with
  one real (if glyph-empty) `sgl` page to satisfy this until real font
  loading exists. Also: show the window only after the layer's device/
  pixelFormat/drawableSize are set, not before. Next: pick one real
  `refexport_t` function (or start the window/device teardown-and-recreate
  path for `vid_restart`, which session 1 doesn't handle at all yet) as
  Phase 1, session 2.

- 2026-09-07: Planning docs (ROADMAP/ARCHITECTURE/CLAUDE) fact-checked
  against the real codebase (7 parallel verification passes) and against
  current Metal ray-tracing API reality. Corrected: refexport_t is 84
  functions, not ~20 (R_Init doesn't exist; no gradient draw call
  exists); scoped-weapon rendering is one R_RenderScene call, not two;
  view-model uses a depth-range hack, not a second FOV; terrain and
  static-prop model format are both resolved (ordinary shader stages,
  all-TIKI respectively — no separate paths needed). Added to scope:
  fog's per-portal behavior (partly dead/partly active-and-complex),
  `tr_ghost.cpp`'s procedural particle-texture system, `tr_marks.c`'s
  decal-clip algorithm. Flagged as a real risk, not just a Phase 5
  checklist item: MetalFX's temporal upscaler and a custom SVGF/ReSTIR
  denoiser will compound their temporal accumulation by default —
  investigate Apple's Metal 4 unified denoise+upscale API before hand-
  integrating two separate systems. Renamed the project `renderer_metalrt`
  to avoid colliding with the existing ANGLE-backed `renderer_metal`,
  which stays as a fallback/reference. Next: Phase 0 — confirm the
  existing build/paks still serve as the regression baseline, then start
  Phase 1 against the real 84-function refexport_t checklist.

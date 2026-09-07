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

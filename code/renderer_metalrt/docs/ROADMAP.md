# Roadmap

Each phase has one exit criterion. Do not start the next phase until the
current one's is met against a real build and a real play session.

## Phase 0 — Baseline (done)
Working OpenMoHAA arm64 build, AA/Breakthrough/Spearhead paks installed
and playable. This is the regression reference for every phase below —
keep it around, untouched, to compare against.

A second, non-native reference point also exists now: `renderer_metal`
(ANGLE-backed — `code/renderergl2`'s existing GLSL/GLES3 source, unchanged,
translated to Metal at the driver level). It isn't part of this project
and isn't a substitute for it, but it's a cheap, working A/B target — use
it during Phase 1 to sanity-check whether a given rendering difference is
a real `renderer_metalrt` bug or something the reference renderer also
does.

## Phase 1 — Renderer parity, no RT
Build `renderer_metalrt` (`code/renderer_metalrt/`): full `refexport_t`
implemented, rasterized only, Metal instead of OpenGL. The real interface
is 84 functions (85 with `__USEA3D`, safely stubbable) — read
`code/renderercommon/tr_public.h` directly and treat it as the checklist,
not a short sketch. Port tessellation, skinning, particle, and decal
logic from the existing renderer rather than reimplementing it — see
docs/ARCHITECTURE.md's fidelity list, which now explicitly includes fog's
per-portal behavior and the `tr_ghost.cpp` procedural-texture system
alongside tessellation/skinning/particles/decals.

**Exit criterion:** full single-player campaign playable start to finish,
several MP maps load and play as content (not as a hosted multiplayer
session — see CLAUDE.md rule 7), visually indistinguishable from the
existing renderer side by side, zero gameplay regressions — including
every item in CLAUDE.md rule 5 (brush-entity kinematics, shader
animation, sky, fog including its per-portal behavior, scoped-weapon
FOV-change-plus-overlay compositing, view-model depth-range handling,
cutscenes), not just static world geometry. This is the highest-risk
phase — everything after it is additive on top of a proven-correct base.

## Phase 2 — Material translation layer
Shader-script parser → material params + override file. No required
visual change yet — this phase is about having correct data ready for
Phase 4. Terrain needs no special-case handling here — it resolves
through the same shader-stage system as every other surface (confirmed
against the actual terrain code; see docs/ARCHITECTURE.md).

**Exit criterion:** every shader in every shipped map resolves to a
material with no parser errors or unhandled cases.

## Phase 3 — Acceleration structures
Static BLAS (BSP + terrain, cached), dynamic BLAS (TIKI, GPU-skinned —
refit each frame via `MTLAccelerationStructureUsageRefit`, with an
explicit periodic full-rebuild policy since refit alone can't handle a
topology/triangle-count change like an LOD swap or dismemberment), TLAS
per frame (a full per-frame rebuild is Metal's normal, low-risk default
for the instance structure, not a fallback).

**Exit criterion:** BLAS/TLAS build and update correctly for every
shipped map and every animated entity type in the campaign, measured
against a frame-time budget, before any ray gets traced through them.

## Phase 4 — RT effects
In order: shadows → reflections → AO → GI. Each is its own milestone.
Define a scalability ladder alongside these milestones as you build them
— per-effect ray-budget/resolution knobs, which effect degrades first
under load — rather than treating "all four at full quality
simultaneously" as the only target. No known shipping title runs that
full stack in real time even on much more powerful discrete GPUs than
M3 Ultra, so a fallback tier is part of this phase's deliverable, not a
stretch goal to bolt on later.

**Exit criterion per effect:** toggling its cvar on and off in a live
session shows the effect working correctly across at least three
lighting scenarios (interior, exterior/sun, dynamic-light-only), with no
regression to effects shipped before it.

## Phase 5 — Denoise, upscale, perf tuning
Temporal+spatial denoiser, MetalFX upscale, tuned against real M3 Ultra
frame budgets at whatever target resolution/refresh rate the display
setup calls for.

**Exit criterion:** stable frame time (state the target explicitly once
hardware/display is fixed) with all Phase 4 effects on, in the densest
map in the campaign — and no visible temporal smearing during combat
motion (muzzle flash, explosions, fast camera turns), checked live in an
actual firefight, not a static screenshot. The denoiser and MetalFX
upscale both do temporal accumulation; verify they aren't compounding
into each other before calling this done — this is a known, well-
documented failure mode when a custom SVGF/ReSTIR denoiser feeds
straight into `MTLFXTemporalScaler` (see docs/ARCHITECTURE.md's
"Denoise & upscale" section), not a hypothetical edge case, so budget
real time to test it under fast motion and disocclusion specifically.
Evaluate Apple's Metal 4 unified denoise+upscale API as a way to avoid
the problem structurally before hand-integrating two separate temporal
systems.

## Phase 6 — Packaging
LICENSE (GPLv2), README stating asset requirements (bring your own
retail paks), build instructions, credits (OpenMoHAA, ioquake3, F.A.K.K
SDK).

**Exit criterion:** a second machine — not the one it was built on — can
clone, build, and run it against retail paks with no undocumented steps.

## Session sizing for Claude Code
One `refexport_t` function or one visual feature per session. Open the
equivalent function in the existing `code/renderergl2/` implementation as
the reference before writing the Metal version — port the math, don't
re-derive it. With the real function count (84, not the original ~20
estimate) budget accordingly, but don't assume every remaining function
needs its own session — a large fraction are thin/mechanical (queries,
UI draw calls) that group naturally. End every session with a one-line
update to CLAUDE.md's status log.

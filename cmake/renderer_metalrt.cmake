if(NOT BUILD_CLIENT OR NOT BUILD_RENDERER_METALRT)
    return()
endif()

if(NOT APPLE)
    message(FATAL_ERROR "BUILD_RENDERER_METALRT is only supported on macOS")
endif()

include(utils/set_output_dirs)
include(renderer_common)

# Deliberately does NOT pull in all of RENDERER_COMMON_SOURCES - several
# of those files assume the qgl* proc-pointer table exists, which this
# renderer never populates (it never touches OpenGL/GLES at all). Add
# sources individually as sessions give them a real (non-stub)
# implementation that needs them - see CLAUDE.md's status log.
#
# tr_image_tga/bmp/pcx.c are pure C, no external library (unlike
# tr_image_jpg.c, which needs libjpeg, and tr_image_png.c, which needs
# puff.c's inflate) - session 2 only wires up the dependency-free
# formats; jpg/png are real, separate follow-up work.
set(RENDERER_METALRT_SOURCES
    ${SOURCE_DIR}/renderer_metalrt/rt_init.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_image.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_scene.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_stubs.cpp
    ${SOURCE_DIR}/renderercommon/tr_image_tga.c
    ${SOURCE_DIR}/renderercommon/tr_image_bmp.c
    ${SOURCE_DIR}/renderercommon/tr_image_pcx.c
)

set(RENDERER_METALRT_BASENAME renderer_metalrt)
set(RENDERER_METALRT_BINARY ${RENDERER_METALRT_BASENAME})

list(APPEND RENDERER_METALRT_BINARY_SOURCES
    ${RENDERER_METALRT_SOURCES})

if(USE_RENDERER_DLOPEN)
    # This renderer is self-contained like the others (USE_RENDERER_DLOPEN
    # loads it as a standalone dylib), but it needs only the small shared
    # helper set (Com_Memset/Q_strncpyz/etc. from q_shared.c), not
    # RENDERER_LIBRARY_SOURCES/DYNAMIC_RENDERER_SOURCES' GL-oriented extras.
    list(APPEND RENDERER_METALRT_BINARY_SOURCES
        ${SOURCE_DIR}/qcommon/q_shared.c
        ${SOURCE_DIR}/qcommon/q_math.c
        ${SOURCE_DIR}/renderercommon/tr_subs.c)

    add_library(${RENDERER_METALRT_BINARY} SHARED ${RENDERER_METALRT_BINARY_SOURCES})

    target_link_libraries(      ${RENDERER_METALRT_BINARY} PRIVATE ${COMMON_LIBRARIES} ${SDL2_LIBRARIES} "-framework Metal" "-framework QuartzCore")
    target_include_directories( ${RENDERER_METALRT_BINARY} PRIVATE ${SDL2_INCLUDE_DIRS})
    target_compile_definitions( ${RENDERER_METALRT_BINARY} PRIVATE ${RENDERER_DEFINITIONS})

    set_output_dirs(${RENDERER_METALRT_BINARY})

    INSTALL(TARGETS ${RENDERER_METALRT_BINARY} DESTINATION ${INSTALL_LIBDIR_FULL})
endif()

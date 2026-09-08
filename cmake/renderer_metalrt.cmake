if(NOT BUILD_CLIENT OR NOT BUILD_RENDERER_METALRT)
    return()
endif()

if(NOT APPLE)
    message(FATAL_ERROR "BUILD_RENDERER_METALRT is only supported on macOS")
endif()

include(utils/set_output_dirs)
include(utils/disable_warnings)
include(renderer_common)

# Deliberately does NOT pull in all of RENDERER_COMMON_SOURCES - several
# of those files assume the qgl* proc-pointer table exists, which this
# renderer never populates (it never touches OpenGL/GLES at all). Add
# sources individually as sessions give them a real (non-stub)
# implementation that needs them - see CLAUDE.md's status log.
#
# tr_image_tga/bmp/pcx.c are pure C, no external library - session 2
# wired up the dependency-free formats first. tr_image_jpg.c (session
# 15) needs libjpeg - always the vendored thirdparty/jpeg-9f source
# (matching cmake/libraries/jpeg.cmake's USE_INTERNAL_JPEG path), not a
# system libjpeg, to keep this renderer's build fully self-contained
# with no external dependency to find. tr_image_png.c (session 16) needs
# puff.c's inflate, which - like tga/bmp/pcx - is pure in-tree C with no
# external library, so it's added directly alongside them.
set(RENDERER_METALRT_SOURCES
    ${SOURCE_DIR}/renderer_metalrt/rt_init.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_image.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_scene.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_world.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_font.mm
    ${SOURCE_DIR}/renderer_metalrt/rt_stubs.cpp
    ${SOURCE_DIR}/renderercommon/tr_image_tga.c
    ${SOURCE_DIR}/renderercommon/tr_image_bmp.c
    ${SOURCE_DIR}/renderercommon/tr_image_pcx.c
    ${SOURCE_DIR}/renderercommon/tr_image_jpg.c
    ${SOURCE_DIR}/renderercommon/tr_image_png.c
    ${SOURCE_DIR}/renderercommon/puff.c
)

set(RENDERER_METALRT_JPEG_DIR ${SOURCE_DIR}/thirdparty/jpeg-9f)
file(GLOB RENDERER_METALRT_JPEG_SOURCES ${RENDERER_METALRT_JPEG_DIR}/j*.c)
disable_warnings(${RENDERER_METALRT_JPEG_SOURCES})
list(APPEND RENDERER_METALRT_SOURCES ${RENDERER_METALRT_JPEG_SOURCES})

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
    target_include_directories( ${RENDERER_METALRT_BINARY} PRIVATE ${SDL2_INCLUDE_DIRS} ${RENDERER_METALRT_JPEG_DIR})
    target_compile_definitions( ${RENDERER_METALRT_BINARY} PRIVATE ${RENDERER_DEFINITIONS} USE_INTERNAL_JPEG)

    set_output_dirs(${RENDERER_METALRT_BINARY})

    INSTALL(TARGETS ${RENDERER_METALRT_BINARY} DESTINATION ${INSTALL_LIBDIR_FULL})
endif()

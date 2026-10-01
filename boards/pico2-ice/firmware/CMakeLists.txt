cmake_minimum_required(VERSION 3.13)

# points straight at the submodule rather than symlinking it like the SDK's examples
set(PICO_ICE_SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/pico-ice-sdk)

include(${PICO_ICE_SDK_PATH}/cmake/preinit_pico_ice_sdk.cmake)

set(PICO_SDK_PATH ${PICO_ICE_SDK_PATH}/lib/pico-sdk/)
include(pico_sdk_import.cmake)

project(pico2_ice_bridge C CXX ASM)
pico_sdk_init()

add_subdirectory(${PICO_ICE_SDK_PATH} pico-ice-sdk-build)

add_executable(${CMAKE_PROJECT_NAME}
    main.c
    tpu_tile.c
    usb_descriptors.c
    )
target_link_libraries(${CMAKE_PROJECT_NAME}
    pico_ice_sdk
    pico_ice_usb
    )
target_include_directories(${CMAKE_PROJECT_NAME} PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}
    )

# must match the gateware's USE_SPI
option(TPU_LINK_SPI "Bridge the TPU CDC port to SPI instead of uart0" OFF)
if (TPU_LINK_SPI)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE TPU_LINK_SPI=1)
endif()

pico_add_extra_outputs(${CMAKE_PROJECT_NAME})

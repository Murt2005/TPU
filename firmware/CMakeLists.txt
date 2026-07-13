cmake_minimum_required(VERSION 3.13)

# Unlike the SDK's own examples (which symlink pico-ice-sdk/ and pico-sdk/
# into each example directory), this project points straight at the
# TPU/firmware/pico-ice-sdk/ git submodule in this same directory.
set(PICO_ICE_SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/pico-ice-sdk)

include(${PICO_ICE_SDK_PATH}/cmake/preinit_pico_ice_sdk.cmake)

# import the pico-sdk
set(PICO_SDK_PATH ${PICO_ICE_SDK_PATH}/lib/pico-sdk/)
include(pico_sdk_import.cmake)

# configure the pico-sdk project
project(pico2_ice_bridge C CXX ASM)
pico_sdk_init()

# add the pico-ice-sdk
add_subdirectory(${PICO_ICE_SDK_PATH} pico-ice-sdk-build)

# add the local files
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

# Host-link PHY selection. OFF (default): bridge the TPU CDC port to uart0,
# matching a USE_SPI=0 gateware build. ON: bridge it to spi0 on the shared
# RP2350<->iCE40 config bus instead, matching `make USE_SPI=1` gateware
# (see rtl/spi_slave.sv and main.c's TPU_LINK_SPI section):
#   cmake -DTPU_LINK_SPI=ON ..
option(TPU_LINK_SPI "Bridge the TPU CDC port to SPI instead of uart0" OFF)
if (TPU_LINK_SPI)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PRIVATE TPU_LINK_SPI=1)
endif()

pico_add_extra_outputs(${CMAKE_PROJECT_NAME})

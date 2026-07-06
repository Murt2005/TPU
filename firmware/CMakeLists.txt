cmake_minimum_required(VERSION 3.13)

# Unlike the SDK's own examples (which symlink pico-ice-sdk/ and pico-sdk/
# into each example directory), this project lives at TPU/firmware/
# and points straight at the vendored TPU/pico-ice-sdk/ clone one level up.
set(PICO_ICE_SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/../pico-ice-sdk)

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
    usb_descriptors.c
    )
target_link_libraries(${CMAKE_PROJECT_NAME}
    pico_ice_sdk
    pico_ice_usb
    )
target_include_directories(${CMAKE_PROJECT_NAME} PUBLIC
    ${CMAKE_CURRENT_LIST_DIR}
    )
pico_add_extra_outputs(${CMAKE_PROJECT_NAME})

cmake_minimum_required(VERSION 4.0)
project(IOSCheck LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(APP_ICON ${CMAKE_CURRENT_SOURCE_DIR}/assets/AppIcon.png)

add_executable(IOSCheck MACOSX_BUNDLE main.mm)

target_compile_features(IOSCheck PRIVATE cxx_std_20)
target_compile_options(IOSCheck PRIVATE "-fobjc-arc")
target_link_libraries(IOSCheck
    "-framework AppKit"
    "-framework Security"
)

set_source_files_properties(${APP_ICON} PROPERTIES
    MACOSX_PACKAGE_LOCATION Resources
)
target_sources(IOSCheck PRIVATE ${APP_ICON})

set_target_properties(IOSCheck PROPERTIES
    MACOSX_BUNDLE_BUNDLE_NAME "IOSCheck"
    MACOSX_BUNDLE_GUI_IDENTIFIER "com.azukibits.ioscheck"
    MACOSX_BUNDLE_BUNDLE_VERSION "0.1.0"
    MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1.0"
    MACOSX_BUNDLE_INFO_STRING "IOS account switch assistant"
)

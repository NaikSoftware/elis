cmake_minimum_required(VERSION 3.21)
project(elis VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Widgets Network DBus Svg Sql Test)
find_package(KF6CoreAddons REQUIRED)
find_package(KF6XmlGui REQUIRED)
set(CMAKE_AUTORCC ON)

# KParts: the real package when libkf6parts-dev is installed, else headers unpacked by
# scripts/fetch-kparts-headers.sh linked against the runtime library (no root needed).
find_package(KF6Parts QUIET)
if(NOT TARGET KF6::Parts)
  find_path(KPARTS_INCLUDE_DIR kparts/readonlypart.h
    PATHS ${CMAKE_SOURCE_DIR}/.deps/usr/include/KF6/KParts NO_DEFAULT_PATH)
  find_library(KPARTS_LIBRARY NAMES libKF6Parts.so.6 KF6Parts)
  if(NOT KPARTS_INCLUDE_DIR OR NOT KPARTS_LIBRARY)
    message(FATAL_ERROR "KParts headers not found: install libkf6parts-dev or run scripts/fetch-kparts-headers.sh")
  endif()
  add_library(KF6::Parts UNKNOWN IMPORTED)
  set_target_properties(KF6::Parts PROPERTIES
    IMPORTED_LOCATION ${KPARTS_LIBRARY}
    INTERFACE_INCLUDE_DIRECTORIES ${KPARTS_INCLUDE_DIR}
    INTERFACE_LINK_LIBRARIES "KF6::CoreAddons;KF6::XmlGui")
endif()

# ElisBridge: ElisCore (macos/ElisCore, shared with the Mac) behind a C ABI, built by SwiftPM with the Swift stdlib
# linked in, so running Elis needs no Swift runtime
find_program(SWIFT swift DOC "the Swift 6.3 toolchain's swift, which builds linux/shared")
if(NOT SWIFT)
  message(FATAL_ERROR "swift not found: install Swift 6.3 (the swift.org tarball or swiftly) and put it on PATH, or pass -DSWIFT=/path/to/swift")
endif()
set(ELIS_BRIDGE ${CMAKE_BINARY_DIR}/swift/release/libElisBridge.so)
file(GLOB_RECURSE ELIS_BRIDGE_SOURCES CONFIGURE_DEPENDS ${CMAKE_SOURCE_DIR}/shared/Sources/*.swift ${CMAKE_SOURCE_DIR}/../macos/ElisCore/Sources/*.swift)
add_custom_command(OUTPUT ${ELIS_BRIDGE}
  # a soname, so what links it records the name and finds it on the rpath, not this build path
  COMMAND ${SWIFT} build -c release -Xswiftc -static-stdlib -Xlinker -soname=libElisBridge.so -Xlinker --strip-all --package-path ${CMAKE_SOURCE_DIR}/shared --scratch-path ${CMAKE_BINARY_DIR}/swift
  COMMAND ${CMAKE_COMMAND} -E touch ${ELIS_BRIDGE} # SwiftPM leaves an unchanged product's time alone
  DEPENDS ${ELIS_BRIDGE_SOURCES} ${CMAKE_SOURCE_DIR}/shared/Package.swift ${CMAKE_SOURCE_DIR}/../macos/ElisCore/Package.swift
  COMMENT "Building ElisBridge (Swift ElisCore)" USES_TERMINAL VERBATIM)
add_custom_target(elis-bridge DEPENDS ${ELIS_BRIDGE})
add_library(ElisBridge SHARED IMPORTED)
set_target_properties(ElisBridge PROPERTIES IMPORTED_LOCATION ${ELIS_BRIDGE} INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_SOURCE_DIR}/shared/include)
add_dependencies(ElisBridge elis-bridge)

add_library(elis-core STATIC src/core/store.cpp src/core/control.cpp src/core/launcher.cpp src/core/keymap.cpp src/core/hooks.cpp src/core/restore.cpp src/core/commands.cpp src/core/installers.cpp src/core/livehost.cpp src/core/transcript.cpp)
target_include_directories(elis-core PUBLIC src/core)
target_link_libraries(elis-core PUBLIC Qt6::Core ElisBridge PRIVATE Qt6::Sql)

find_package(KF6Config REQUIRED)
find_package(KF6WidgetsAddons REQUIRED)
add_library(elis-ui STATIC src/app/mainwindow.cpp src/app/config.cpp src/app/settingsdialog.cpp src/app/sidebar.cpp src/app/palette.cpp src/app/overlay.cpp src/app/dashboard.cpp src/app/library.cpp src/app/attention.cpp src/app/konsoleprivate.cpp src/app/controlui.cpp src/app/help.cpp src/app/smoothwheel.cpp src/app/phone.cpp src/ctl/qrcodegen/qrcodegen.cpp
  resources/resources.qrc)
target_include_directories(elis-ui PUBLIC src/app)
find_package(KF6Notifications REQUIRED)
find_package(KF6SyntaxHighlighting REQUIRED)
find_package(KF6WindowSystem REQUIRED)
target_link_libraries(elis-ui PUBLIC elis-core Qt6::Widgets Qt6::DBus Qt6::Svg KF6::Parts KF6::Notifications KF6::SyntaxHighlighting KF6::WindowSystem KF6::ConfigCore KF6::WidgetsAddons ${CMAKE_DL_LIBS})
add_executable(elis src/app/main.cpp)
target_link_libraries(elis PRIVATE elis-ui Qt6::Network KF6::ConfigCore)

add_executable(elis-session-host src/host/sessionhost.cpp) # plain POSIX: it outlives the app, so no Qt
target_link_libraries(elis-session-host PRIVATE util)
add_dependencies(elis elis-session-host) # spawned from the app's own directory

add_executable(elisctl src/ctl/elisctl.cpp src/ctl/mobile.cpp src/ctl/qrcodegen/qrcodegen.cpp)
target_link_libraries(elisctl PRIVATE elis-core Qt6::Network)

enable_testing()
add_executable(test_core tests/test_core.cpp)
target_link_libraries(test_core PRIVATE elis-core Qt6::Sql Qt6::Test)
target_compile_definitions(test_core PRIVATE ELIS_SOURCE_SHARE="${CMAKE_SOURCE_DIR}/share" ELIS_SESSION_HOST="$<TARGET_FILE:elis-session-host>")
add_dependencies(test_core elis-session-host)
add_test(NAME core COMMAND test_core)
add_executable(test_ui tests/test_ui.cpp)
target_link_libraries(test_ui PRIVATE elis-ui Qt6::Test)
add_test(NAME ui COMMAND test_ui)
set_tests_properties(ui PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen;ELIS_STATE_DIR=/tmp/elis-test-ui")

target_sources(elis-core PRIVATE src/core/filetree.cpp src/core/fileicons.cpp)
target_sources(elis-ui PRIVATE src/app/filepanel.cpp src/app/fileviewer.cpp resources/fileicons.qrc)
add_executable(test_filepanel tests/test_filepanel.cpp)
target_link_libraries(test_filepanel PRIVATE elis-ui Qt6::Test)
add_test(NAME filepanel COMMAND test_filepanel)
set_tests_properties(filepanel PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

include(GNUInstallDirs)
install(TARGETS elis elisctl elis-session-host RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES ${ELIS_BRIDGE} DESTINATION ${CMAKE_INSTALL_LIBDIR}/elis)
file(RELATIVE_PATH ELIS_BRIDGE_RPATH ${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_BINDIR} ${CMAKE_INSTALL_PREFIX}/${CMAKE_INSTALL_LIBDIR}/elis)
set_target_properties(elis elisctl PROPERTIES INSTALL_RPATH "$ORIGIN/${ELIS_BRIDGE_RPATH}")
configure_file(packaging/elis.desktop.in elis.desktop @ONLY) # Exec is absolute: the Plasma menu does not see ~/.local/bin
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/elis.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
install(DIRECTORY resources/icons/ DESTINATION ${CMAKE_INSTALL_DATADIR}/icons)
install(DIRECTORY share/agent-status share/skill USE_SOURCE_PERMISSIONS DESTINATION ${CMAKE_INSTALL_DATADIR}/elis)
# a build-tree run finds the shipped agent-status package and skill in the source tree
target_compile_definitions(elis-ui PRIVATE ELIS_SOURCE_SHARE="${CMAKE_SOURCE_DIR}/share")

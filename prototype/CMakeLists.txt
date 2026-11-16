# The prototype app as a macOS .app bundle (alternative to build.sh, e.g. for CLion).
file(GLOB_RECURSE SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/Sources/*.swift")

add_executable(TranscribeAndPractice MACOSX_BUNDLE ${SOURCES})

set_target_properties(TranscribeAndPractice PROPERTIES
    Swift_LANGUAGE_VERSION 6
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
)

# The app's entry point is an @main type, not main.swift.
target_compile_options(TranscribeAndPractice PRIVATE -parse-as-library)

cmake_minimum_required(VERSION 3.29)

set(CMAKE_OSX_DEPLOYMENT_TARGET "26.0" CACHE STRING "Minimum macOS version")

project(TranscribeAndPractice LANGUAGES Swift)

add_subdirectory(prototype)

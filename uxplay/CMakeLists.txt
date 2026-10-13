# Builds only UxPlay's AirPlay protocol library (no GStreamer renderers) as
# static libraries that the Remi Xcode target links against. Run through
# bin/build-uxplay, which prepares the patched sources and libplist.
cmake_minimum_required(VERSION 3.13)
project(remi_uxplay C)

set(UXPLAY_DIR "" CACHE PATH "Patched copy of UxPlay sources")

add_subdirectory(${UXPLAY_DIR}/lib/llhttp llhttp)
add_subdirectory(${UXPLAY_DIR}/lib/playfair playfair)
add_subdirectory(${UXPLAY_DIR}/lib airplay)

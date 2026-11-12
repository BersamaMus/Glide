cmake_minimum_required(VERSION 3.14)

project(native_imaging_library VERSION 0.0.1 LANGUAGES CXX)

# Finding a picture's subject, for the editor's background effects: ONNX
# Runtime, and IS-Net (general use, from rembg; Apache-2.0) as its model.
# Fetched once, checked against these hashes, and kept in third_party.
set(NI_THIRD_PARTY "${CMAKE_CURRENT_SOURCE_DIR}/../third_party")
set(NI_ORT_VERSION "1.20.1")
set(NI_ORT_DIR "${NI_THIRD_PARTY}/onnxruntime-win-x64-${NI_ORT_VERSION}")
set(NI_MODEL "${NI_THIRD_PARTY}/isnet-general-use.onnx")

if(NOT EXISTS "${NI_ORT_DIR}/lib/onnxruntime.dll")
  message(STATUS "Downloading ONNX Runtime ${NI_ORT_VERSION}")
  file(DOWNLOAD
    "https://github.com/microsoft/onnxruntime/releases/download/v${NI_ORT_VERSION}/onnxruntime-win-x64-${NI_ORT_VERSION}.zip"
    "${NI_THIRD_PARTY}/onnxruntime.zip"
    EXPECTED_HASH SHA256=78d447051e48bd2e1e778bba378bec4ece11191c9e538cf7b2c4a4565e8f5581
    SHOW_PROGRESS)
  execute_process(COMMAND ${CMAKE_COMMAND} -E tar xf "${NI_THIRD_PARTY}/onnxruntime.zip"
                  WORKING_DIRECTORY "${NI_THIRD_PARTY}")
  file(REMOVE "${NI_THIRD_PARTY}/onnxruntime.zip")
endif()

if(NOT EXISTS "${NI_MODEL}")
  message(STATUS "Downloading the IS-Net model (about 170 MB)")
  file(DOWNLOAD
    "https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx"
    "${NI_MODEL}"
    EXPECTED_HASH SHA256=60920e99c45464f2ba57bee2ad08c919a52bbf852739e96947fbb4358c0d964a
    SHOW_PROGRESS)
endif()

add_library(native_imaging SHARED
  "native_imaging.cpp"
  "phones.cpp"
  "drives.cpp"
  "models.cpp"
  "subject.cpp"
  "look.cpp"
)

set_target_properties(native_imaging PROPERTIES
  PUBLIC_HEADER native_imaging.h
  OUTPUT_NAME "native_imaging"
  CXX_STANDARD 17
)

target_compile_definitions(native_imaging PRIVATE UNICODE _UNICODE NOMINMAX)
target_include_directories(native_imaging PRIVATE "${NI_ORT_DIR}/include")
target_link_libraries(native_imaging PRIVATE windowscodecs ole32 oleaut32 shell32 propsys gdi32 user32 PortableDeviceGUIDs
  "${NI_ORT_DIR}/lib/onnxruntime.lib" delayimp)
# Loaded only when a background's first edited, from beside this library
# (not an older copy Windows may have of its own).
target_link_options(native_imaging PRIVATE "/DELAYLOAD:onnxruntime.dll")

# Shipped beside the app, with native_imaging.dll.
set(NI_SUBJECT_FILES "${NI_ORT_DIR}/lib/onnxruntime.dll" "${NI_MODEL}" PARENT_SCOPE)

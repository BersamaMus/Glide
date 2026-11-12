#pragma once

// The models the app runs on ONNX Runtime (models.cpp): IS-Net for a
// picture's subject (subject.cpp). Shipped beside this library.

#include <windows.h>

// ONNX Runtime is loaded when it's first needed (delay-loaded, from beside
// this library), so its API is set up then rather than when this loads.
#define ORT_API_MANUAL_INIT
#include <onnxruntime_cxx_api.h>

#include <string>

// A model, loaded the first time it's run and kept until the process ends
// (never destroyed: torn down as this library unloads, after ONNX Runtime's
// own threads have gone, it would crash), with its first input's and
// output's names.
struct Model
{
    const wchar_t *file;
    Ort::Session *session = nullptr;
    std::string input, output;
};

// Loads ONNX Runtime and the model, once. Fails with ERROR_FILE_NOT_FOUND
// or ERROR_MOD_NOT_FOUND if either wasn't shipped. Call it under a lock of
// the model's own.
HRESULT load(Model &model);

// Where the named file shipped beside this library (native_imaging.dll) is.
std::wstring besideThisLibrary(const wchar_t *name);

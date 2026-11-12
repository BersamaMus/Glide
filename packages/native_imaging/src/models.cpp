// Loading ONNX Runtime and the models run on it. See models.h.

#include "models.h"

#include <memory>
#include <mutex>

namespace {

std::mutex g_mutex;
// Kept until the process ends, as the sessions are.
Ort::Env *g_env = nullptr;

} // namespace

std::wstring besideThisLibrary(const wchar_t *name)
{
    HMODULE self = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&besideThisLibrary), &self);
    std::wstring path(MAX_PATH, L'\0');
    DWORD length = 0;
    while ((length = GetModuleFileNameW(self, path.data(), DWORD(path.size()))) == path.size()) path.resize(path.size() * 2);
    path.resize(length);
    return path.substr(0, path.find_last_of(L"\\/") + 1) + name;
}

HRESULT load(Model &model)
{
    if (model.session) return S_OK;
    const std::wstring file = besideThisLibrary(model.file);
    if (GetFileAttributesW(file.c_str()) == INVALID_FILE_ATTRIBUTES) return HRESULT_FROM_WIN32(ERROR_FILE_NOT_FOUND);
    {
        // ONNX Runtime and its environment once, whichever model's first.
        std::lock_guard lock(g_mutex);
        if (!g_env) {
            // This copy, not an older one Windows may have of its own: once
            // it's loaded, the delay-load finds it by name.
            if (!LoadLibraryExW(besideThisLibrary(L"onnxruntime.dll").c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH))
                return HRESULT_FROM_WIN32(GetLastError());
            Ort::InitApi();
            g_env = new Ort::Env(ORT_LOGGING_LEVEL_ERROR, "native_imaging");
        }
    }
    Ort::SessionOptions options;
    options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
    auto session = std::make_unique<Ort::Session>(*g_env, file.c_str(), options);
    Ort::AllocatorWithDefaultOptions allocator;
    model.input = session->GetInputNameAllocated(0, allocator).get();
    model.output = session->GetOutputNameAllocated(0, allocator).get();
    model.session = session.release();
    return S_OK;
}

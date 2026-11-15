#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// The folder or picture Glide was started with, as Explorer passes it for
// "Open with"; empty if there's none. A full path: the Glide it's handed to
// runs in another folder.
std::wstring OpenedPath() {
  std::wstring opened;
  int count = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &count);
  if (!argv) return opened;
  for (int i = 1; i < count && opened.empty(); i++) {
    if (::GetFileAttributesW(argv[i]) == INVALID_FILE_ATTRIBUTES) continue;
    DWORD length = ::GetFullPathNameW(argv[i], 0, nullptr, nullptr);
    if (length == 0) continue;
    std::wstring full(length, L'\0');
    length = ::GetFullPathNameW(argv[i], length, full.data(), nullptr);
    full.resize(length);
    opened = full;
  }
  ::LocalFree(argv);
  return opened;
}

// Hands [path] (which may be empty) to the Glide already running, which
// comes to the front, waiting a little for its window if it's only just
// starting.
void SendToRunning(const std::wstring& path) {
  HWND running = nullptr;
  for (int tries = 0; tries < 100 && !running; tries++) {
    // Win32Window's class (kWindowClassName in win32_window.cpp), marked as
    // Glide's by FlutterWindow.
    ::EnumWindows(
        [](HWND window, LPARAM found) -> BOOL {
          wchar_t name[64];
          if (!::GetClassNameW(window, name, 64) ||
              wcscmp(name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0 ||
              !::GetPropW(window, FlutterWindow::kWindowMark)) {
            return TRUE;
          }
          *reinterpret_cast<HWND*>(found) = window;
          return FALSE;
        },
        reinterpret_cast<LPARAM>(&running));
    if (!running) ::Sleep(100);
  }
  if (!running) return;
  DWORD process = 0;
  ::GetWindowThreadProcessId(running, &process);
  // This process was just started, so it may hand over the foreground.
  ::AllowSetForegroundWindow(process);
  std::wstring text = path;
  COPYDATASTRUCT data{};
  data.dwData = FlutterWindow::kOpenDataId;
  data.cbData = static_cast<DWORD>(text.size() * sizeof(wchar_t));
  data.lpData = text.data();
  DWORD_PTR ignored;
  ::SendMessageTimeoutW(running, WM_COPYDATA, 0,
                        reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG,
                        5000, &ignored);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One Glide at a time, as with Blimp and Vessel. Opened again, perhaps
  // with a picture from Explorer, the one already running shows it instead
  // of a second window starting. The handle is let go of as the process
  // ends. A debug build has its own, so it runs beside an installed Glide
  // rather than handing over to it.
#ifdef _DEBUG
  ::CreateMutexW(nullptr, FALSE, L"Glide.SingleInstance.Debug");
#else
  ::CreateMutexW(nullptr, FALSE, L"Glide.SingleInstance");
#endif
  // Read straight away: the calls below change the last error.
  bool already_running = ::GetLastError() == ERROR_ALREADY_EXISTS;
  if (already_running) {
    SendToRunning(OpenedPath());
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Glide", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

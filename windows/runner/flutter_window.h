#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

// A window that hosts a Flutter view, and takes the folder or picture a
// second copy of Glide was started with (see main.cpp).
class FlutterWindow : public Win32Window {
 public:
  // A property on Glide's window, to tell it from other Flutter apps' when
  // a second copy looks for it.
  static constexpr const wchar_t* kWindowMark = L"Glide.Window";

  // Marks a WM_COPYDATA message as a path from a second copy of Glide
  // ("GLID").
  static constexpr ULONG_PTR kOpenDataId = 0x474C4944;

  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "glide/open": tells the app what a second copy was started with
  // (lib/screens/app_shell.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> open_channel_;

  // Whether the app is listening on "glide/open" yet (it says "ready" once
  // it is). Until then, paths a second copy hands over wait in
  // |waiting_paths_|: sent sooner, they'd be lost.
  bool app_ready_ = false;
  std::vector<std::string> waiting_paths_;

  // Hands |path| to the app now, or once it's listening.
  void Open(std::string path);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

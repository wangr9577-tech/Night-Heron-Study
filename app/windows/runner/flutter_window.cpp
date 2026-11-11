#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>
#include "local_ocr.h"

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  ocr_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
    flutter_controller_->engine()->messenger(), "zhi/local_ocr", &flutter::StandardMethodCodec::GetInstance());
  ocr_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "recognize") { result->NotImplemented(); return; }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) { result->Error("arguments", "Missing image path"); return; }
    auto file = args->find(flutter::EncodableValue("path"));
    auto language = args->find(flutter::EncodableValue("language"));
    if (file == args->end() || language == args->end() ||
        !std::holds_alternative<std::string>(file->second) ||
        !std::holds_alternative<std::string>(language->second)) {
      result->Error("arguments", "Invalid image path or language"); return;
    }
    // Reap finished work before accepting a new recognition request.
    for (auto it = ocr_workers_.begin(); it != ocr_workers_.end();) {
      if (it->wait_for(std::chrono::seconds(0)) == std::future_status::ready) it = ocr_workers_.erase(it);
      else ++it;
    }
    ocr_workers_.push_back(std::async(std::launch::async, RecognizeLocalImage, GetHandle(),
      std::get<std::string>(file->second), std::get<std::string>(language->second), std::move(result)));
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  for (auto& worker : ocr_workers_) worker.wait();
  MSG pending;
  while (::PeekMessage(&pending, GetHandle(), kOcrComplete, kOcrComplete, PM_REMOVE))
    delete reinterpret_cast<OcrReply*>(pending.lParam);
  ocr_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kOcrComplete) {
    std::unique_ptr<OcrReply> reply(reinterpret_cast<OcrReply*>(lparam));
    if (reply->error.empty()) reply->result->Success(flutter::EncodableValue(reply->text));
    else reply->result->Error("windows_ocr", reply->error);
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

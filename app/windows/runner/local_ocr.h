#pragma once
#include <flutter/method_result.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>
#include <string>
constexpr UINT kOcrComplete = WM_APP + 71;
struct OcrReply {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  std::string text;
  std::string error;
};
void RecognizeLocalImage(HWND window, std::string file, std::string language,
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

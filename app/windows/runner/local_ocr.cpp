#include "local_ocr.h"
#include <stdexcept>
#include <algorithm>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Globalization.h>
#include <winrt/Windows.Graphics.Imaging.h>
#include <winrt/Windows.Media.Ocr.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Streams.h>

void RecognizeLocalImage(HWND window, std::string file, std::string language,
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto reply = std::make_unique<OcrReply>();
  reply->result = std::move(result);
  const char* stage = "Open image";
  try {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    using namespace winrt::Windows;
    std::wstring windows_path(winrt::to_hstring(file));
    std::replace(windows_path.begin(), windows_path.end(), L'/', L'\\');
    const auto input = Storage::StorageFile::GetFileFromPathAsync(windows_path).get();
    const auto stream = input.OpenAsync(Storage::FileAccessMode::Read).get();
    const auto decoder = Graphics::Imaging::BitmapDecoder::CreateAsync(stream).get();
    const auto bitmap = decoder.GetSoftwareBitmapAsync(Graphics::Imaging::BitmapPixelFormat::Bgra8,
      Graphics::Imaging::BitmapAlphaMode::Premultiplied).get();
    stage = "Load OCR language";
    auto engine = Media::Ocr::OcrEngine::TryCreateFromLanguage(Globalization::Language(winrt::to_hstring(language)));
    if (!engine) engine = Media::Ocr::OcrEngine::TryCreateFromUserProfileLanguages();
    if (!engine) throw std::runtime_error("Windows OCR language pack is unavailable. Install the desired language OCR feature in Windows Settings.");
    const auto max_dimension = static_cast<int64_t>(Media::Ocr::OcrEngine::MaxImageDimension());
    if (static_cast<int64_t>(bitmap.PixelWidth()) > max_dimension ||
        static_cast<int64_t>(bitmap.PixelHeight()) > max_dimension) {
      throw std::runtime_error("Image exceeds Windows OCR dimensions. Use a smaller image.");
    }
    stage = "Recognize image";
    reply->text = winrt::to_string(engine.RecognizeAsync(bitmap).get().Text());
    bitmap.Close();
    stream.Close();
  } catch (const winrt::hresult_error& error) {
    reply->error = std::string(stage) + ": " + winrt::to_string(error.message());
  } catch (const std::exception& error) { reply->error = error.what(); }
  if (::PostMessage(window, kOcrComplete, 0, reinterpret_cast<LPARAM>(reply.get()))) reply.release();
}

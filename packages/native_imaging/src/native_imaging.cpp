#include "native_imaging.h"
#include "look.h"
#include "subject.h"

#include <windows.h>
#include <propvarutil.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wincodecsdk.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>

using Microsoft::WRL::ComPtr;

namespace {

// COM for the length of one call. Dart may run an isolate's calls on any of
// its threads, so nothing is kept initialised between calls. A thread that
// already has COM in another mode works as it is.
class ComScope
{
public:
    explicit ComScope(DWORD mode) : hr_(CoInitializeEx(nullptr, mode)) {}
    ~ComScope()
    {
        if (SUCCEEDED(hr_)) CoUninitialize();
    }

private:
    HRESULT hr_;
};

#define RETURN_IF_FAILED(expr)       \
    do {                             \
        HRESULT hr_ = (expr);        \
        if (FAILED(hr_)) return hr_; \
    } while (0)

ComPtr<IWICImagingFactory> factory()
{
    ComPtr<IWICImagingFactory> wic;
    CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic));
    return wic;
}

// The EXIF orientation (1 to 8; 1 is upright), from the metadata policy WIC
// maps onto each format's own tag, or from the JPEG and TIFF tags directly.
int orientationOf(IWICBitmapFrameDecode *frame)
{
    ComPtr<IWICMetadataQueryReader> reader;
    if (FAILED(frame->GetMetadataQueryReader(&reader))) return 1;
    for (const wchar_t *query : {L"System.Photo.Orientation", L"/app1/ifd/{ushort=274}", L"/ifd/{ushort=274}"}) {
        PROPVARIANT value;
        PropVariantInit(&value);
        if (SUCCEEDED(reader->GetMetadataByName(query, &value))) {
            USHORT orientation = 1;
            const bool read = SUCCEEDED(PropVariantToUInt16(value, &orientation));
            PropVariantClear(&value);
            if (read && orientation >= 1 && orientation <= 8) return orientation;
        }
    }
    return 1;
}

WICBitmapTransformOptions transformFor(int orientation)
{
    switch (orientation) {
    case 2: return WICBitmapTransformFlipHorizontal;
    case 3: return WICBitmapTransformRotate180;
    case 4: return WICBitmapTransformFlipVertical;
    case 5: return WICBitmapTransformOptions(WICBitmapTransformRotate270 | WICBitmapTransformFlipHorizontal);
    case 6: return WICBitmapTransformRotate90;
    case 7: return WICBitmapTransformOptions(WICBitmapTransformRotate90 | WICBitmapTransformFlipHorizontal);
    case 8: return WICBitmapTransformRotate270;
    default: return WICBitmapTransformRotate0;
    }
}

// Orientations 5 to 8 turn the picture on its side.
bool swapsSides(int orientation) { return orientation >= 5; }

HRESULT openFrame(IWICImagingFactory *wic, const wchar_t *path, ComPtr<IWICBitmapFrameDecode> &frame)
{
    ComPtr<IWICBitmapDecoder> decoder;
    RETURN_IF_FAILED(wic->CreateDecoderFromFilename(path, nullptr, GENERIC_READ, WICDecodeMetadataCacheOnDemand,
                                                    &decoder));
    return decoder->GetFrame(0, &frame);
}

HRESULT openFrame(IWICImagingFactory *wic, const uint8_t *data, int64_t length,
                  ComPtr<IWICBitmapFrameDecode> &frame)
{
    if (length <= 0 || length > MAXDWORD) return E_INVALIDARG;
    ComPtr<IWICStream> stream;
    RETURN_IF_FAILED(wic->CreateStream(&stream));
    RETURN_IF_FAILED(stream->InitializeFromMemory(const_cast<BYTE *>(data), DWORD(length)));
    ComPtr<IWICBitmapDecoder> decoder;
    RETURN_IF_FAILED(wic->CreateDecoderFromStream(stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder));
    return decoder->GetFrame(0, &frame);
}

// See ni_decode. A preview the file has of itself (a camera's EXIF
// thumbnail, a RAW file's JPEG) is used instead of the whole picture if
// it's at least min_preview: it's in the file's first few kilobytes.
HRESULT decodeFrame(IWICImagingFactory *wic, IWICBitmapFrameDecode *frame, int32_t max_size, int32_t min_preview,
                    int32_t *width, int32_t *height, uint8_t **pixels);

// The thumbnail Windows has kept of the picture (File Explorer's), if it has
// one; never made here, as that means reading the whole picture.
HRESULT cachedThumbnail(const wchar_t *path, int32_t size, int32_t *width, int32_t *height, uint8_t **pixels)
{
    ComPtr<IShellItemImageFactory> images;
    RETURN_IF_FAILED(SHCreateItemFromParsingName(path, nullptr, IID_PPV_ARGS(&images)));
    HBITMAP bitmap = nullptr;
    RETURN_IF_FAILED(images->GetImage(SIZE{size, size}, SIIGBF_RESIZETOFIT | SIIGBF_INCACHEONLY, &bitmap));

    BITMAP info{};
    GetObjectW(bitmap, sizeof(info), &info);
    const int w = info.bmWidth;
    const int h = info.bmHeight < 0 ? -info.bmHeight : info.bmHeight;
    BITMAPINFO format{};
    format.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    format.bmiHeader.biWidth = w;
    format.bmiHeader.biHeight = -h; // top row first
    format.bmiHeader.biPlanes = 1;
    format.bmiHeader.biBitCount = 32;
    format.bmiHeader.biCompression = BI_RGB;
    const size_t bytes = size_t(w) * h * 4;
    auto *buffer = static_cast<uint8_t *>(malloc(bytes));
    if (!buffer) {
        DeleteObject(bitmap);
        return E_OUTOFMEMORY;
    }
    HDC screen = GetDC(nullptr);
    const int rows = GetDIBits(screen, bitmap, 0, UINT(h), buffer, &format, DIB_RGB_COLORS);
    ReleaseDC(nullptr, screen);
    DeleteObject(bitmap);
    if (rows != h || w <= 0) {
        free(buffer);
        return E_FAIL;
    }

    // Windows' BGRA to RGBA, premultiplied as both have it. A photo's
    // thumbnail often has no alpha at all (all 0): it's opaque.
    bool anyAlpha = false;
    for (size_t i = 3; i < bytes && !anyAlpha; i += 4) anyAlpha = buffer[i] != 0;
    for (size_t i = 0; i < bytes; i += 4) {
        std::swap(buffer[i], buffer[i + 2]);
        if (!anyAlpha) buffer[i + 3] = 255;
    }
    *width = w;
    *height = h;
    *pixels = buffer;
    return S_OK;
}

} // namespace

NI_EXPORT int32_t ni_recycle(const wchar_t **paths, int32_t count, int32_t *aborted)
{
    *aborted = 0;
    // The shell's file operations want a single-threaded apartment.
    ComScope com(COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);

    ComPtr<IFileOperation> operation;
    RETURN_IF_FAILED(CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&operation)));
    // Undoable (to the Recycle Bin) without asking; but a warning, rather
    // than a silent permanent delete, where there's no Recycle Bin.
    RETURN_IF_FAILED(operation->SetOperationFlags(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_WANTNUKEWARNING |
                                                  FOF_SILENT | FOFX_EARLYFAILURE));
    for (int32_t i = 0; i < count; i++) {
        ComPtr<IShellItem> item;
        RETURN_IF_FAILED(SHCreateItemFromParsingName(paths[i], nullptr, IID_PPV_ARGS(&item)));
        RETURN_IF_FAILED(operation->DeleteItem(item.Get(), nullptr));
    }
    const HRESULT hr = operation->PerformOperations();
    BOOL anyAborted = FALSE;
    operation->GetAnyOperationsAborted(&anyAborted);
    *aborted = anyAborted ? 1 : 0;
    return hr;
}

NI_EXPORT int32_t ni_transfer(const wchar_t **paths, int32_t count, const wchar_t *destination, int32_t move,
                              int32_t *aborted)
{
    *aborted = 0;
    ComScope com(COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);

    ComPtr<IFileOperation> operation;
    RETURN_IF_FAILED(CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_ALL, IID_PPV_ARGS(&operation)));
    // Undoable, with Windows' own progress and name clash dialogs.
    RETURN_IF_FAILED(operation->SetOperationFlags(FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR));
    ComPtr<IShellItem> folder;
    RETURN_IF_FAILED(SHCreateItemFromParsingName(destination, nullptr, IID_PPV_ARGS(&folder)));
    for (int32_t i = 0; i < count; i++) {
        ComPtr<IShellItem> item;
        RETURN_IF_FAILED(SHCreateItemFromParsingName(paths[i], nullptr, IID_PPV_ARGS(&item)));
        RETURN_IF_FAILED(move ? operation->MoveItem(item.Get(), folder.Get(), nullptr, nullptr)
                              : operation->CopyItem(item.Get(), folder.Get(), nullptr, nullptr));
    }
    const HRESULT hr = operation->PerformOperations();
    BOOL anyAborted = FALSE;
    operation->GetAnyOperationsAborted(&anyAborted);
    *aborted = anyAborted ? 1 : 0;
    return hr;
}

static int32_t decodeUnguarded(const wchar_t *path, int32_t max_size, int32_t *width, int32_t *height,
                            uint8_t **pixels)
{
    *pixels = nullptr;
    ComScope com(COINIT_MULTITHREADED);
    const ComPtr<IWICImagingFactory> wic = factory();
    if (!wic) return E_FAIL;

    ComPtr<IWICBitmapFrameDecode> frame;
    RETURN_IF_FAILED(openFrame(wic.Get(), path, frame));
    return decodeFrame(wic.Get(), frame.Get(), max_size, max_size, width, height, pixels);
}

static int32_t thumbnailUnguarded(const wchar_t *path, int32_t size, int32_t *width, int32_t *height,
                               uint8_t **pixels)
{
    *pixels = nullptr;
    // Some thumbnail handlers want a single-threaded apartment.
    ComScope com(COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    // Explorer's, if it's shown the picture before: nothing to read at all.
    if (SUCCEEDED(cachedThumbnail(path, size, width, height, pixels))) return S_OK;

    // Else the file's own preview (in its first few kilobytes), if it has
    // one worth showing at a tile's size; else the picture, decoded at that
    // size (a JPEG is decoded at an eighth, a quarter... as fits).
    const ComPtr<IWICImagingFactory> wic = factory();
    if (!wic) return E_FAIL;
    ComPtr<IWICBitmapFrameDecode> frame;
    RETURN_IF_FAILED(openFrame(wic.Get(), path, frame));
    return decodeFrame(wic.Get(), frame.Get(), size, std::min(size, 120), width, height, pixels);
}

static int32_t decodeMemoryUnguarded(const uint8_t *data, int64_t length, int32_t max_size, int32_t *width,
                                   int32_t *height, uint8_t **pixels)
{
    *pixels = nullptr;
    ComScope com(COINIT_MULTITHREADED);
    const ComPtr<IWICImagingFactory> wic = factory();
    if (!wic) return E_FAIL;

    ComPtr<IWICBitmapFrameDecode> frame;
    RETURN_IF_FAILED(openFrame(wic.Get(), data, length, frame));
    return decodeFrame(wic.Get(), frame.Get(), max_size, max_size, width, height, pixels);
}

namespace {

HRESULT decodeFrame(IWICImagingFactory *wic, IWICBitmapFrameDecode *frame, int32_t max_size, int32_t min_preview,
                    int32_t *width,
                    int32_t *height, uint8_t **pixels)
{
    const int orientation = orientationOf(frame);

    UINT w = 0, h = 0;
    RETURN_IF_FAILED(frame->GetSize(&w, &h));
    ComPtr<IWICBitmapSource> source = frame;

    // A small size: the file's own preview (a camera's EXIF thumbnail, a RAW
    // file's JPEG), when that's big enough, saves decoding the whole picture.
    if (max_size > 0 && max_size <= 640) {
        ComPtr<IWICBitmapSource> thumbnail;
        UINT tw = 0, th = 0;
        // Only one of the picture's shape: cameras keep a 4:3 one, black
        // bars and all, even of a 16:9 photo, and an edit made elsewhere
        // may have left the uncropped picture's.
        if (SUCCEEDED(frame->GetThumbnail(&thumbnail)) && SUCCEEDED(thumbnail->GetSize(&tw, &th)) &&
            std::max(tw, th) >= UINT(min_preview) && w > 0 && h > 0 && tw > 0 && th > 0 &&
            std::abs(double(tw) / th - double(w) / h) <= 0.02 * double(w) / h) {
            source = thumbnail;
            w = tw;
            h = th;
        }
    }

    if (max_size > 0 && std::max(w, h) > UINT(max_size)) {
        const double scale = double(max_size) / std::max(w, h);
        const UINT sw = std::max(1u, UINT(w * scale + 0.5));
        const UINT sh = std::max(1u, UINT(h * scale + 0.5));
        ComPtr<IWICBitmapScaler> scaler;
        RETURN_IF_FAILED(wic->CreateBitmapScaler(&scaler));
        RETURN_IF_FAILED(scaler->Initialize(source.Get(), sw, sh, WICBitmapInterpolationModeFant));
        source = scaler;
        w = sw;
        h = sh;
    }

    if (orientation != 1) {
        ComPtr<IWICBitmapFlipRotator> rotator;
        RETURN_IF_FAILED(wic->CreateBitmapFlipRotator(&rotator));
        RETURN_IF_FAILED(rotator->Initialize(source.Get(), transformFor(orientation)));
        source = rotator;
        if (swapsSides(orientation)) std::swap(w, h);
    }

    ComPtr<IWICFormatConverter> converter;
    RETURN_IF_FAILED(wic->CreateFormatConverter(&converter));
    // Premultiplied, as Flutter takes raw pixels.
    RETURN_IF_FAILED(converter->Initialize(source.Get(), GUID_WICPixelFormat32bppPRGBA, WICBitmapDitherTypeNone,
                                           nullptr, 0.0, WICBitmapPaletteTypeCustom));

    const UINT stride = w * 4;
    const size_t bytes = size_t(stride) * h;
    auto *buffer = static_cast<uint8_t *>(malloc(bytes));
    if (!buffer) return E_OUTOFMEMORY;
    const HRESULT hr = converter->CopyPixels(nullptr, stride, UINT(bytes), buffer);
    if (FAILED(hr)) {
        free(buffer);
        return hr;
    }
    *width = int32_t(w);
    *height = int32_t(h);
    *pixels = buffer;
    return S_OK;
}

} // namespace

namespace {

// The picture turned by `transform`, if it's not none.
HRESULT turned(IWICImagingFactory *wic, ComPtr<IWICBitmapSource> &source, WICBitmapTransformOptions transform)
{
    if (transform == WICBitmapTransformRotate0) return S_OK;
    ComPtr<IWICBitmapFlipRotator> rotator;
    RETURN_IF_FAILED(wic->CreateBitmapFlipRotator(&rotator));
    RETURN_IF_FAILED(rotator->Initialize(source.Get(), transform));
    source = rotator;
    return S_OK;
}

// Copies the picture's metadata into the new one, then says it's upright
// now and gives its new size. In the same format, every block (EXIF, XMP,
// IPTC...) as it was; into another (a JPEG of a RAW file), what the formats
// have in common: when and where it was taken, and with what.
void copyMetadata(IWICBitmapFrameDecode *from, IWICBitmapFrameEncode *to, bool sameFormat, UINT width,
                  UINT height)
{
    ComPtr<IWICMetadataQueryReader> reader;
    ComPtr<IWICMetadataQueryWriter> writer;
    if (FAILED(from->GetMetadataQueryReader(&reader)) || FAILED(to->GetMetadataQueryWriter(&writer))) return;
    ComPtr<IWICMetadataBlockReader> blocksIn;
    ComPtr<IWICMetadataBlockWriter> blocksOut;
    if (sameFormat && SUCCEEDED(from->QueryInterface(IID_PPV_ARGS(&blocksIn))) &&
        SUCCEEDED(to->QueryInterface(IID_PPV_ARGS(&blocksOut)))) {
        blocksOut->InitializeFromBlockReader(blocksIn.Get());
        // But not the small preview a camera put in it: of the picture as
        // it was, uncropped and unturned, it'd show for the edit's tile.
        for (const wchar_t *thumbnail : {L"/app1/thumb", L"/app1/ifd/thumb", L"/ifd/thumb"})
            writer->RemoveMetadataByName(thumbnail);
    } else {
        for (const wchar_t *policy :
             {L"System.Photo.DateTaken", L"System.Photo.CameraManufacturer", L"System.Photo.CameraModel",
              L"System.Photo.FNumber", L"System.Photo.ExposureTime", L"System.Photo.ISOSpeed",
              L"System.Photo.FocalLength", L"System.Photo.LensModel", L"System.GPS.Latitude",
              L"System.GPS.LatitudeRef", L"System.GPS.Longitude", L"System.GPS.LongitudeRef", L"System.GPS.Altitude",
              L"System.Title", L"System.Author", L"System.Copyright", L"System.Keywords", L"System.Rating"}) {
            PROPVARIANT value;
            PropVariantInit(&value);
            if (SUCCEEDED(reader->GetMetadataByName(policy, &value))) writer->SetMetadataByName(policy, &value);
            PropVariantClear(&value);
        }
    }
    PROPVARIANT value;
    PropVariantInit(&value);
    value.vt = VT_UI2;
    value.uiVal = 1;
    writer->SetMetadataByName(L"System.Photo.Orientation", &value);
    // EXIF's own record of the size, where there is one.
    for (const auto &[query, size] : {std::pair{L"/app1/ifd/exif/{ushort=40962}", width},
                                      std::pair{L"/app1/ifd/exif/{ushort=40963}", height}}) {
        PROPVARIANT old;
        PropVariantInit(&old);
        if (SUCCEEDED(reader->GetMetadataByName(query, &old))) {
            PROPVARIANT now;
            PropVariantInit(&now);
            now.vt = VT_UI4;
            now.ulVal = size;
            writer->SetMetadataByName(query, &now);
        }
        PropVariantClear(&old);
    }
}

} // namespace

static int32_t editUnguarded(const wchar_t *source, const wchar_t *destination, int32_t quarter_turns,
                          int32_t flip_horizontal, double crop_left, double crop_top, double crop_width,
                          double crop_height, int32_t out_format, int32_t background, uint32_t background_color,
                          double blur_spread, const uint8_t *mask, int32_t mask_width, int32_t mask_height,
                          const float *look, int32_t look_count)
{
    ComScope com(COINIT_MULTITHREADED);
    const ComPtr<IWICImagingFactory> wic = factory();
    if (!wic) return E_FAIL;

    ComPtr<IWICBitmapDecoder> decoder;
    RETURN_IF_FAILED(wic->CreateDecoderFromFilename(source, nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
                                                    &decoder));
    ComPtr<IWICBitmapFrameDecode> frame;
    RETURN_IF_FAILED(decoder->GetFrame(0, &frame));
    GUID original{};
    RETURN_IF_FAILED(decoder->GetContainerFormat(&original));
    const GUID container = out_format == 1 ? GUID_ContainerFormatJpeg : out_format == 2 ? GUID_ContainerFormatPng : original;

    // Upright, as it's shown, adjusted and filtered, its background changed;
    // then the user's turns and flip.
    ComPtr<IWICBitmapSource> picture = frame;
    RETURN_IF_FAILED(turned(wic.Get(), picture, transformFor(orientationOf(frame.Get()))));
    RETURN_IF_FAILED(withLook(wic.Get(), picture, look, look_count));
    RETURN_IF_FAILED(
        withBackground(wic.Get(), picture, background, background_color, blur_spread, mask, mask_width, mask_height));
    static constexpr WICBitmapTransformOptions turns[] = {WICBitmapTransformRotate0, WICBitmapTransformRotate90,
                                                          WICBitmapTransformRotate180, WICBitmapTransformRotate270};
    RETURN_IF_FAILED(turned(wic.Get(), picture, turns[((quarter_turns % 4) + 4) % 4]));
    if (flip_horizontal) RETURN_IF_FAILED(turned(wic.Get(), picture, WICBitmapTransformFlipHorizontal));

    UINT w = 0, h = 0;
    RETURN_IF_FAILED(picture->GetSize(&w, &h));
    WICRect rect;
    rect.X = std::min(INT(std::clamp(crop_left, 0.0, 1.0) * w + 0.5), INT(w) - 1);
    rect.Y = std::min(INT(std::clamp(crop_top, 0.0, 1.0) * h + 0.5), INT(h) - 1);
    rect.Width = std::clamp(INT(crop_width * w + 0.5), 1, INT(w) - rect.X);
    rect.Height = std::clamp(INT(crop_height * h + 0.5), 1, INT(h) - rect.Y);
    if (rect.X != 0 || rect.Y != 0 || UINT(rect.Width) != w || UINT(rect.Height) != h) {
        ComPtr<IWICBitmapClipper> clipper;
        RETURN_IF_FAILED(wic->CreateBitmapClipper(&clipper));
        RETURN_IF_FAILED(clipper->Initialize(picture.Get(), &rect));
        picture = clipper;
    }

    ComPtr<IWICStream> stream;
    RETURN_IF_FAILED(wic->CreateStream(&stream));
    RETURN_IF_FAILED(stream->InitializeFromFilename(destination, GENERIC_WRITE));
    ComPtr<IWICBitmapEncoder> encoder;
    RETURN_IF_FAILED(wic->CreateEncoder(container, nullptr, &encoder));
    RETURN_IF_FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache));
    ComPtr<IWICBitmapFrameEncode> out;
    ComPtr<IPropertyBag2> options;
    RETURN_IF_FAILED(encoder->CreateNewFrame(&out, &options));
    if (container == GUID_ContainerFormatJpeg || container == GUID_ContainerFormatHeif) {
        // Close to a camera's own: no visible loss for being saved again.
        PROPBAG2 option{};
        option.pstrName = const_cast<LPOLESTR>(L"ImageQuality");
        VARIANT quality;
        VariantInit(&quality);
        quality.vt = VT_R4;
        quality.fltVal = 0.92f;
        options->Write(1, &option, &quality);
    }
    RETURN_IF_FAILED(out->Initialize(options.Get()));
    RETURN_IF_FAILED(out->SetSize(UINT(rect.Width), UINT(rect.Height)));

    // The encoder says which pixel format it takes; the picture is
    // converted to that.
    WICPixelFormatGUID format{};
    RETURN_IF_FAILED(picture->GetPixelFormat(&format));
    WICPixelFormatGUID wanted = format;
    RETURN_IF_FAILED(out->SetPixelFormat(&wanted));
    if (wanted != format) {
        ComPtr<IWICFormatConverter> converter;
        RETURN_IF_FAILED(wic->CreateFormatConverter(&converter));
        RETURN_IF_FAILED(converter->Initialize(picture.Get(), wanted, WICBitmapDitherTypeNone, nullptr, 0.0,
                                               WICBitmapPaletteTypeMedianCut));
        picture = converter;
    }

    copyMetadata(frame.Get(), out.Get(), container == original, UINT(rect.Width), UINT(rect.Height));
    RETURN_IF_FAILED(out->WriteSource(picture.Get(), nullptr));
    RETURN_IF_FAILED(out->Commit());
    return encoder->Commit();
}

namespace {

// Milliseconds since 1970 (UTC) for a FILETIME (100 ns since 1601, UTC).
int64_t fileTimeMs(const FILETIME &time)
{
    const ULONGLONG ticks = (ULONGLONG(time.dwHighDateTime) << 32) | time.dwLowDateTime;
    return int64_t(ticks / 10000) - 11644473600000LL;
}

// "2020:01:02 03:04:05", EXIF's way, as local time; 0 if it isn't one.
int64_t exifTextMs(const char *text)
{
    SYSTEMTIME local{}, utc{};
    if (sscanf_s(text, "%hu:%hu:%hu %hu:%hu:%hu", &local.wYear, &local.wMonth, &local.wDay, &local.wHour,
                 &local.wMinute, &local.wSecond) != 6 ||
        local.wYear < 1900)
        return 0;
    FILETIME file{};
    if (!TzSpecificLocalTimeToSystemTime(nullptr, &local, &utc) || !SystemTimeToFileTime(&utc, &file)) return 0;
    return fileTimeMs(file);
}

// When the picture was taken; 0 if it doesn't say.
int64_t dateTaken(IWICImagingFactory *wic, const wchar_t *path)
{
    ComPtr<IWICBitmapFrameDecode> frame;
    ComPtr<IWICMetadataQueryReader> reader;
    if (FAILED(openFrame(wic, path, frame)) || FAILED(frame->GetMetadataQueryReader(&reader))) return 0;
    int64_t result = 0;
    PROPVARIANT value;
    PropVariantInit(&value);
    // Windows' own name for it, which it maps onto each format's tag.
    if (SUCCEEDED(reader->GetMetadataByName(L"System.Photo.DateTaken", &value)) && value.vt == VT_FILETIME)
        result = fileTimeMs(value.filetime);
    PropVariantClear(&value);
    // Else EXIF's tag itself, in JPEG's and TIFF's (and most RAW's) places.
    for (const wchar_t *query : {L"/app1/ifd/exif/{ushort=36867}", L"/ifd/exif/{ushort=36867}"}) {
        if (result) break;
        PropVariantInit(&value);
        if (SUCCEEDED(reader->GetMetadataByName(query, &value)) && value.vt == VT_LPSTR)
            result = exifTextMs(value.pszVal);
        PropVariantClear(&value);
    }
    return result;
}

} // namespace

// Online-only OneDrive files (and other cloud placeholders): read, they'd
// be downloaded.
static bool onlyOnline(const wchar_t *path)
{
    const DWORD attributes = GetFileAttributesW(path);
    return attributes != INVALID_FILE_ATTRIBUTES &&
           (attributes & (FILE_ATTRIBUTE_RECALL_ON_DATA_ACCESS | FILE_ATTRIBUTE_RECALL_ON_OPEN | FILE_ATTRIBUTE_OFFLINE));
}

static int32_t sizeUnguarded(const wchar_t *path, int32_t *width, int32_t *height)
{
    ComScope com(COINIT_MULTITHREADED);
    const ComPtr<IWICImagingFactory> wic = factory();
    if (!wic) return E_FAIL;

    ComPtr<IWICBitmapFrameDecode> frame;
    RETURN_IF_FAILED(openFrame(wic.Get(), path, frame));
    UINT w = 0, h = 0;
    RETURN_IF_FAILED(frame->GetSize(&w, &h));
    if (swapsSides(orientationOf(frame.Get()))) std::swap(w, h);
    *width = int32_t(w);
    *height = int32_t(h);
    return S_OK;
}

namespace {

// Where each detail may be: Windows' name for it, which it maps onto each
// format's own tag, then EXIF's tag in JPEG's place and in TIFF's (and most
// RAW's and HEIC's).
struct Detail
{
    const wchar_t *key;
    const wchar_t *queries[3];
};

constexpr Detail textDetails[] = {
    {L"make", {L"System.Photo.CameraManufacturer", L"/app1/ifd/{ushort=271}", L"/ifd/{ushort=271}"}},
    {L"model", {L"System.Photo.CameraModel", L"/app1/ifd/{ushort=272}", L"/ifd/{ushort=272}"}},
    {L"lens", {L"System.Photo.LensModel", L"/app1/ifd/exif/{ushort=42036}", L"/ifd/exif/{ushort=42036}"}},
};

constexpr Detail numberDetails[] = {
    {L"fnumber", {L"System.Photo.FNumber", L"/app1/ifd/exif/{ushort=33437}", L"/ifd/exif/{ushort=33437}"}},
    {L"exposure", {L"System.Photo.ExposureTime", L"/app1/ifd/exif/{ushort=33434}", L"/ifd/exif/{ushort=33434}"}},
    {L"iso", {L"System.Photo.ISOSpeed", L"/app1/ifd/exif/{ushort=34855}", L"/ifd/exif/{ushort=34855}"}},
    {L"focal", {L"System.Photo.FocalLength", L"/app1/ifd/exif/{ushort=37386}", L"/ifd/exif/{ushort=37386}"}},
    {L"focal35",
     {L"System.Photo.FocalLengthInFilm", L"/app1/ifd/exif/{ushort=41989}", L"/ifd/exif/{ushort=41989}"}},
};

// The index-th number in a value: a plain number, or EXIF's rational
// (numerator in the low 32 bits, denominator in the high), alone or in a
// list (GPS's degrees, minutes and seconds). NaN if it isn't one.
double numberIn(const PROPVARIANT &value, ULONG index = 0)
{
    const auto rational = [](ULONGLONG raw, bool isSigned) {
        const double numerator = isSigned ? double(INT32(raw & 0xFFFFFFFF)) : double(raw & 0xFFFFFFFF);
        const double denominator = isSigned ? double(INT32(raw >> 32)) : double(raw >> 32);
        return denominator == 0 ? NAN : numerator / denominator;
    };
    switch (value.vt) {
    case VT_UI8: return index == 0 ? rational(value.uhVal.QuadPart, false) : NAN;
    case VT_I8: return index == 0 ? rational(ULONGLONG(value.hVal.QuadPart), true) : NAN;
    case VT_VECTOR | VT_UI8: return index < value.cauh.cElems ? rational(value.cauh.pElems[index].QuadPart, false) : NAN;
    case VT_VECTOR | VT_R8: return index < value.cadbl.cElems ? value.cadbl.pElems[index] : NAN;
    case VT_VECTOR | VT_UI2: return index < value.caui.cElems ? double(value.caui.pElems[index]) : NAN;
    case VT_VECTOR | VT_UI4: return index < value.caul.cElems ? double(value.caul.pElems[index]) : NAN;
    default: {
        double number = 0;
        return index == 0 && SUCCEEDED(PropVariantToDouble(value, &number)) ? number : NAN;
    }
    }
}

// The first of the queries the picture answers, in value (to clear).
bool readAny(IWICMetadataQueryReader *reader, const wchar_t *const *queries, size_t count, PROPVARIANT &value)
{
    for (size_t i = 0; i < count; i++) {
        if (!queries[i]) continue;
        PropVariantInit(&value);
        if (SUCCEEDED(reader->GetMetadataByName(queries[i], &value)) && value.vt != VT_EMPTY) return true;
        PropVariantClear(&value);
    }
    return false;
}

std::wstring textIn(const PROPVARIANT &value)
{
    std::wstring text;
    if (value.vt == VT_LPSTR && value.pszVal) {
        for (const char *c = value.pszVal; *c; c++) text += wchar_t(static_cast<unsigned char>(*c));
    } else {
        PWSTR got = nullptr;
        if (SUCCEEDED(PropVariantToStringAlloc(value, &got)) && got) text = got;
        CoTaskMemFree(got);
    }
    // Tabs and line breaks split the lines handed back; cameras pad with spaces.
    for (wchar_t &c : text)
        if (c == L'\t' || c == L'\n' || c == L'\r' || c == L'\0') c = L' ';
    const size_t start = text.find_first_not_of(L' ');
    if (start == std::wstring::npos) return {};
    return text.substr(start, text.find_last_not_of(L' ') - start + 1);
}

std::wstring numberText(double number)
{
    wchar_t buffer[64];
    swprintf_s(buffer, L"%.10g", number);
    return buffer;
}

// A latitude or longitude in degrees, south and west negative; NaN if the
// picture doesn't say.
double coordinate(IWICMetadataQueryReader *reader, const wchar_t *policy, const wchar_t *policyRef,
                  const wchar_t *tag, const wchar_t *tagRef)
{
    const wchar_t *queries[] = {policy, tag};
    const wchar_t *refQueries[] = {policyRef, tagRef};
    PROPVARIANT value;
    if (!readAny(reader, queries, 2, value)) return NAN;
    double degrees = numberIn(value, 0);
    const double minutes = numberIn(value, 1), seconds = numberIn(value, 2);
    PropVariantClear(&value);
    if (std::isnan(degrees)) return NAN;
    if (!std::isnan(minutes)) degrees += minutes / 60;
    if (!std::isnan(seconds)) degrees += seconds / 3600;
    if (readAny(reader, refQueries, 2, value)) {
        const std::wstring ref = textIn(value);
        if (!ref.empty() && (ref[0] == L'S' || ref[0] == L'W' || ref[0] == L's' || ref[0] == L'w')) degrees = -degrees;
        PropVariantClear(&value);
    }
    return degrees;
}

// Where the picture was taken, if it says (and it's somewhere on Earth).
bool placeOf(IWICMetadataQueryReader *reader, double &latitude, double &longitude)
{
    latitude = coordinate(reader, L"System.GPS.Latitude", L"System.GPS.LatitudeRef", L"/app1/ifd/gps/{ushort=2}",
                          L"/app1/ifd/gps/{ushort=1}");
    longitude = coordinate(reader, L"System.GPS.Longitude", L"System.GPS.LongitudeRef", L"/app1/ifd/gps/{ushort=4}",
                           L"/app1/ifd/gps/{ushort=3}");
    // 0, 0 is a phone that hadn't found where it was.
    return std::isfinite(latitude) && std::isfinite(longitude) && (latitude != 0 || longitude != 0) &&
           std::abs(latitude) <= 90 && std::abs(longitude) <= 180;
}

// See ni_details.
std::wstring detailsOf(IWICBitmapFrameDecode *frame)
{
    std::wstring text;
    UINT w = 0, h = 0;
    if (SUCCEEDED(frame->GetSize(&w, &h))) {
        if (swapsSides(orientationOf(frame))) std::swap(w, h);
        text += L"width\t" + std::to_wstring(w) + L"\nheight\t" + std::to_wstring(h) + L'\n';
    }
    ComPtr<IWICMetadataQueryReader> reader;
    if (FAILED(frame->GetMetadataQueryReader(&reader))) return text;
    PROPVARIANT value;
    for (const Detail &detail : textDetails) {
        if (!readAny(reader.Get(), detail.queries, 3, value)) continue;
        const std::wstring found = textIn(value);
        PropVariantClear(&value);
        if (!found.empty()) text += std::wstring(detail.key) + L'\t' + found + L'\n';
    }
    for (const Detail &detail : numberDetails) {
        if (!readAny(reader.Get(), detail.queries, 3, value)) continue;
        const double found = numberIn(value);
        PropVariantClear(&value);
        if (std::isfinite(found) && found > 0) text += std::wstring(detail.key) + L'\t' + numberText(found) + L'\n';
    }
    double latitude = 0, longitude = 0;
    if (placeOf(reader.Get(), latitude, longitude))
        text += L"latitude\t" + numberText(latitude) + L"\nlongitude\t" + numberText(longitude) + L'\n';
    return text;
}

int32_t handBackText(const std::wstring &text, wchar_t **out)
{
    const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    *out = static_cast<wchar_t *>(malloc(bytes));
    if (!*out) return E_OUTOFMEMORY;
    memcpy(*out, text.c_str(), bytes);
    return S_OK;
}

} // namespace

static int32_t detailsUnguarded(const wchar_t *path, wchar_t **lines)
{
    ComScope com(COINIT_MULTITHREADED);
    const ComPtr<IWICImagingFactory> wic = factory();
    if (!wic) return E_FAIL;
    ComPtr<IWICBitmapFrameDecode> frame;
    RETURN_IF_FAILED(openFrame(wic.Get(), path, frame));
    return handBackText(detailsOf(frame.Get()), lines);
}

static int32_t detailsMemoryUnguarded(const uint8_t *data, int64_t length, wchar_t **lines)
{
    ComScope com(COINIT_MULTITHREADED);
    const ComPtr<IWICImagingFactory> wic = factory();
    if (!wic) return E_FAIL;
    ComPtr<IWICBitmapFrameDecode> frame;
    RETURN_IF_FAILED(openFrame(wic.Get(), data, length, frame));
    return handBackText(detailsOf(frame.Get()), lines);
}

// ---------------------------------------------------------------------------
// The decoders' calls, guarded. Codecs run in this process, some of them
// other companies' (RAW, HEIF), and a file can make one crash: a corrupt
// photo, or a drive unplugged while the file's mapped into memory (an "in
// page" error). Caught here, that fails the one call rather than closing
// the app. (What the crashed call held may leak; that's the lesser harm.)
// ---------------------------------------------------------------------------

namespace {

// Everything but a stack overflow, which can't be carried on from.
int crashFilter(DWORD code)
{
    return code == EXCEPTION_STACK_OVERFLOW ? EXCEPTION_CONTINUE_SEARCH : EXCEPTION_EXECUTE_HANDLER;
}

template <typename Call>
int32_t guarded(Call &call)
{
    __try {
        return call();
    } __except (crashFilter(GetExceptionCode())) {
        return E_UNEXPECTED;
    }
}

} // namespace

NI_EXPORT int32_t ni_decode(const wchar_t *path, int32_t max_size, int32_t *width, int32_t *height,
                            uint8_t **pixels)
{
    *pixels = nullptr;
    auto call = [&] { return decodeUnguarded(path, max_size, width, height, pixels); };
    return guarded(call);
}

NI_EXPORT int32_t ni_thumbnail(const wchar_t *path, int32_t size, int32_t *width, int32_t *height,
                               uint8_t **pixels)
{
    *pixels = nullptr;
    auto call = [&] { return thumbnailUnguarded(path, size, width, height, pixels); };
    return guarded(call);
}

NI_EXPORT int32_t ni_decode_memory(const uint8_t *data, int64_t length, int32_t max_size, int32_t *width,
                                   int32_t *height, uint8_t **pixels)
{
    *pixels = nullptr;
    auto call = [&] { return decodeMemoryUnguarded(data, length, max_size, width, height, pixels); };
    return guarded(call);
}

NI_EXPORT int32_t ni_edit(const wchar_t *source, const wchar_t *destination, int32_t quarter_turns,
                          int32_t flip_horizontal, double crop_left, double crop_top, double crop_width,
                          double crop_height, int32_t out_format, int32_t background, uint32_t background_color,
                          double blur_spread, const uint8_t *mask, int32_t mask_width, int32_t mask_height,
                          const float *look, int32_t look_count)
{
    auto call = [&] {
        return editUnguarded(source, destination, quarter_turns, flip_horizontal, crop_left, crop_top, crop_width,
                             crop_height, out_format, background, background_color, blur_spread, mask, mask_width,
                             mask_height, look, look_count);
    };
    return guarded(call);
}

static int32_t subjectMaskUnguarded(const wchar_t *path, int32_t *width, int32_t *height, uint8_t **mask)
{
    // Found in the picture at about the model's size: it's no sharper for
    // more.
    uint8_t *pixels = nullptr;
    RETURN_IF_FAILED(decodeUnguarded(path, 1024, width, height, &pixels));
    auto *found = static_cast<uint8_t *>(malloc(size_t(*width) * *height));
    if (!found) {
        free(pixels);
        return E_OUTOFMEMORY;
    }
    const HRESULT hr = findSubject(pixels, *width, *height, found);
    free(pixels);
    if (FAILED(hr)) {
        free(found);
        return hr;
    }
    *mask = found;
    return S_OK;
}

NI_EXPORT int32_t ni_subject_mask(const wchar_t *path, int32_t *width, int32_t *height, uint8_t **mask)
{
    *mask = nullptr;
    auto call = [&] { return subjectMaskUnguarded(path, width, height, mask); };
    return guarded(call);
}

NI_EXPORT void ni_dates_taken(const wchar_t **paths, int32_t count, int64_t *taken, int32_t *states)
{
    // COM and the factory once for them all; each picture read guarded, so
    // one that crashes its codec costs only its date (and the factory, made
    // afresh after, in case the crash left it broken).
    ComScope com(COINIT_MULTITHREADED);
    ComPtr<IWICImagingFactory> wic = factory();
    for (int32_t i = 0; i < count; i++) {
        taken[i] = 0;
        states[i] = 1;
        if (onlyOnline(paths[i])) {
            states[i] = 2;
            continue;
        }
        if (!wic) continue;
        auto call = [&] {
            taken[i] = dateTaken(wic.Get(), paths[i]);
            return 0;
        };
        if (guarded(call) != 0) {
            taken[i] = 0;
            wic = factory();
            continue;
        }
        if (taken[i]) states[i] = 0;
    }
}

NI_EXPORT int32_t ni_size(const wchar_t *path, int32_t *width, int32_t *height)
{
    auto call = [&] { return sizeUnguarded(path, width, height); };
    return guarded(call);
}

NI_EXPORT int32_t ni_details(const wchar_t *path, wchar_t **lines)
{
    *lines = nullptr;
    auto call = [&] { return detailsUnguarded(path, lines); };
    return guarded(call);
}

NI_EXPORT int32_t ni_details_memory(const uint8_t *data, int64_t length, wchar_t **lines)
{
    *lines = nullptr;
    auto call = [&] { return detailsMemoryUnguarded(data, length, lines); };
    return guarded(call);
}

// ---------------------------------------------------------------------------
// The clipboard.
// ---------------------------------------------------------------------------

NI_EXPORT int32_t ni_copy_picture(const uint8_t *rgba, int32_t width, int32_t height, const uint8_t *png,
                                  int64_t png_length)
{
    if (width <= 0 || height <= 0 || png_length <= 0) return E_INVALIDARG;
    // The clipboard's to be owned by a window: one of this thread's own,
    // for as long as it takes. What's put on it stays after it's gone.
    HWND owner = CreateWindowExW(0, L"STATIC", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, nullptr, nullptr);
    if (!owner) return HRESULT_FROM_WIN32(GetLastError());
    HRESULT hr = S_OK;
    for (int attempt = 0; !OpenClipboard(owner); attempt++) {
        // Another program has it open for a moment.
        if (attempt == 10) {
            DestroyWindow(owner);
            return HRESULT_FROM_WIN32(GetLastError());
        }
        Sleep(20);
    }
    EmptyClipboard();

    // As a PNG, for programs that keep the transparency (Office, browsers,
    // chat apps)...
    if (HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, SIZE_T(png_length))) {
        memcpy(GlobalLock(data), png, size_t(png_length));
        GlobalUnlock(data);
        if (!SetClipboardData(RegisterClipboardFormatW(L"PNG"), data)) GlobalFree(data);
    }
    // ...and as a bitmap, for every other (Paint: on white). Bottom row
    // first, BGRA, its colours premultiplied as Windows has them.
    const size_t pixels = size_t(width) * height * 4;
    if (HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPV5HEADER) + pixels)) {
        auto *header = static_cast<BITMAPV5HEADER *>(GlobalLock(data));
        *header = {};
        header->bV5Size = sizeof(BITMAPV5HEADER);
        header->bV5Width = width;
        header->bV5Height = height;
        header->bV5Planes = 1;
        header->bV5BitCount = 32;
        header->bV5Compression = BI_BITFIELDS;
        header->bV5RedMask = 0x00FF0000;
        header->bV5GreenMask = 0x0000FF00;
        header->bV5BlueMask = 0x000000FF;
        header->bV5AlphaMask = 0xFF000000;
        header->bV5CSType = LCS_sRGB;
        header->bV5Intent = LCS_GM_IMAGES;
        auto *out = reinterpret_cast<uint8_t *>(header + 1);
        for (int32_t y = 0; y < height; y++) {
            const uint8_t *from = rgba + size_t(height - 1 - y) * width * 4;
            uint8_t *to = out + size_t(y) * width * 4;
            for (int32_t x = 0; x < width; x++, from += 4, to += 4) {
                const unsigned a = from[3];
                to[0] = uint8_t((from[2] * a + 127) / 255);
                to[1] = uint8_t((from[1] * a + 127) / 255);
                to[2] = uint8_t((from[0] * a + 127) / 255);
                to[3] = uint8_t(a);
            }
        }
        GlobalUnlock(data);
        if (!SetClipboardData(CF_DIBV5, data)) {
            hr = HRESULT_FROM_WIN32(GetLastError());
            GlobalFree(data);
        }
    } else {
        hr = E_OUTOFMEMORY;
    }
    CloseClipboard();
    DestroyWindow(owner);
    return hr;
}

NI_EXPORT void ni_free(void *memory) { free(memory); }

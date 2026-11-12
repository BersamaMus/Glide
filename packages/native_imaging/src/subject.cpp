// Finding a picture's subject with IS-Net (rembg's general-use model) on
// ONNX Runtime, and blurring, removing, replacing or greying what's behind
// it. See subject.h.

#include "subject.h"

#include "models.h"

#include <algorithm>
#include <cmath>
#include <mutex>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

#define RETURN_IF_FAILED(expr)       \
    do {                             \
        HRESULT hr_ = (expr);        \
        if (FAILED(hr_)) return hr_; \
    } while (0)

// The model's input: a square picture this many pixels a side.
constexpr int kModelSize = 1024;

std::mutex g_mutex;
Model g_isnet{L"isnet-general-use.onnx"};

// One channel of a (width by height) buffer, read between pixels.
template <typename T>
float sample(const T *data, int width, int height, int stride, float x, float y)
{
    x = std::clamp(x, 0.0f, float(width - 1));
    y = std::clamp(y, 0.0f, float(height - 1));
    const int x0 = int(x), y0 = int(y);
    const int x1 = std::min(x0 + 1, width - 1), y1 = std::min(y0 + 1, height - 1);
    const float fx = x - x0, fy = y - y0;
    const auto at = [&](int px, int py) { return float(data[(size_t(py) * width + px) * stride]); };
    return (at(x0, y0) * (1 - fx) + at(x1, y0) * fx) * (1 - fy) + (at(x0, y1) * (1 - fx) + at(x1, y1) * fx) * fy;
}

// Blurs each of the channels (width by height, `channels` floats a pixel)
// in place: three box blurs of radius r, close to a Gaussian.
void blur(std::vector<float> &data, int width, int height, int channels, int r)
{
    std::vector<float> line(size_t(std::max(width, height)) * channels);
    const auto pass = [&](int count, int length, size_t step, size_t next) {
        for (int i = 0; i < count; i++) {
            float *start = data.data() + i * next;
            for (int c = 0; c < channels; c++) {
                // A running sum along the line, its ends repeated past them.
                const auto at = [&](int j) { return start[size_t(std::clamp(j, 0, length - 1)) * step + c]; };
                float sum = 0;
                for (int j = -r; j <= r; j++) sum += at(j);
                for (int j = 0; j < length; j++) {
                    line[size_t(j) * channels + c] = sum / (2 * r + 1);
                    sum += at(j + r + 1) - at(j - r);
                }
            }
            for (int j = 0; j < length; j++)
                for (int c = 0; c < channels; c++) start[size_t(j) * step + c] = line[size_t(j) * channels + c];
        }
    };
    for (int round = 0; round < 3; round++) {
        pass(height, width, channels, size_t(width) * channels);   // rows
        pass(width, height, size_t(width) * channels, channels);   // columns
    }
}

} // namespace

HRESULT findSubject(const uint8_t *rgba, int32_t width, int32_t height, uint8_t *mask)
{
    // The picture squeezed into the model's square, its values scaled as
    // rembg does: to 0..1 by its brightest, less a half.
    constexpr size_t plane = size_t(kModelSize) * kModelSize;
    std::vector<float> input(3 * plane);
    const float sx = float(width) / kModelSize, sy = float(height) / kModelSize;
    float brightest = 1e-6f;
    for (int y = 0; y < kModelSize; y++) {
        for (int x = 0; x < kModelSize; x++) {
            const float px = (x + 0.5f) * sx - 0.5f, py = (y + 0.5f) * sy - 0.5f;
            for (int c = 0; c < 3; c++) {
                const float value = sample(rgba + c, width, height, 4, px, py);
                input[c * plane + size_t(y) * kModelSize + x] = value;
                brightest = std::max(brightest, value);
            }
        }
    }
    for (float &value : input) value = value / brightest - 0.5f;

    try {
        std::lock_guard lock(g_mutex);
        RETURN_IF_FAILED(load(g_isnet));
        const auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        const int64_t shape[] = {1, 3, kModelSize, kModelSize};
        Ort::Value tensor = Ort::Value::CreateTensor<float>(memory, input.data(), input.size(), shape, 4);
        const char *inputs[] = {g_isnet.input.c_str()};
        const char *outputs[] = {g_isnet.output.c_str()};
        auto results = g_isnet.session->Run(Ort::RunOptions{nullptr}, inputs, &tensor, 1, outputs, 1);

        // The first of what it says (1 by 1 by height by width): stretched
        // to 0..1, as rembg does, and back to the picture's shape.
        const auto dims = results[0].GetTensorTypeAndShapeInfo().GetShape();
        if (dims.size() < 2) return E_UNEXPECTED;
        const int ow = int(dims[dims.size() - 1]), oh = int(dims[dims.size() - 2]);
        const float *predicted = results[0].GetTensorData<float>();
        const auto [low, high] = std::minmax_element(predicted, predicted + size_t(ow) * oh);
        const float range = std::max(*high - *low, 1e-6f);
        const float mx = float(ow) / width, my = float(oh) / height;
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                const float value = sample(predicted, ow, oh, 1, (x + 0.5f) * mx - 0.5f, (y + 0.5f) * my - 0.5f);
                mask[size_t(y) * width + x] = uint8_t(std::clamp((value - *low) / range, 0.0f, 1.0f) * 255 + 0.5f);
            }
        }
        return S_OK;
    } catch (const Ort::Exception &) {
        return E_FAIL;
    } catch (const std::bad_alloc &) {
        return E_OUTOFMEMORY;
    }
}

HRESULT withBackground(IWICImagingFactory *wic, ComPtr<IWICBitmapSource> &picture, int32_t background, uint32_t color,
                       double blur_spread, const uint8_t *mask, int32_t mask_width, int32_t mask_height)
{
    if (background == kBackgroundNone) return S_OK;
    if (!mask || mask_width <= 0 || mask_height <= 0) return E_INVALIDARG;

    // The picture's pixels, to change in place.
    ComPtr<IWICFormatConverter> converter;
    RETURN_IF_FAILED(wic->CreateFormatConverter(&converter));
    RETURN_IF_FAILED(converter->Initialize(picture.Get(), GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone,
                                           nullptr, 0.0, WICBitmapPaletteTypeCustom));
    ComPtr<IWICBitmap> bitmap;
    RETURN_IF_FAILED(wic->CreateBitmapFromSource(converter.Get(), WICBitmapCacheOnLoad, &bitmap));
    UINT w = 0, h = 0;
    RETURN_IF_FAILED(bitmap->GetSize(&w, &h));
    const int width = int(w), height = int(h);

    // How much each pixel is the subject, 0 to 1.
    const float mx = float(mask_width) / width, my = float(mask_height) / height;
    const auto subjectAt = [&](int x, int y) {
        return sample(mask, mask_width, mask_height, 1, (x + 0.5f) * mx - 0.5f, (y + 0.5f) * my - 0.5f) / 255;
    };

    // For a blur: the background blurred shrunk (its longest side 512) and
    // read back between pixels; blurred by itself, so the subject's colours
    // don't spread into it. Where it's all subject, plainly blurred.
    int sw = 0, sh = 0;
    std::vector<float> blurred;   // r, g, b weighted by background; the weight; r, g, b plain
    if (background == kBackgroundBlur) {
        const float scale = 512.0f / std::max(width, height);
        sw = std::max(1, int(width * std::min(scale, 1.0f) + 0.5f));
        sh = std::max(1, int(height * std::min(scale, 1.0f) + 0.5f));
        ComPtr<IWICBitmapScaler> scaler;
        RETURN_IF_FAILED(wic->CreateBitmapScaler(&scaler));
        RETURN_IF_FAILED(scaler->Initialize(bitmap.Get(), UINT(sw), UINT(sh), WICBitmapInterpolationModeFant));
        // The scaler hands back its own order (BGRA): back to RGBA.
        ComPtr<IWICFormatConverter> order;
        RETURN_IF_FAILED(wic->CreateFormatConverter(&order));
        RETURN_IF_FAILED(order->Initialize(scaler.Get(), GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, nullptr,
                                           0.0, WICBitmapPaletteTypeCustom));
        std::vector<uint8_t> shrunk(size_t(sw) * sh * 4);
        RETURN_IF_FAILED(order->CopyPixels(nullptr, UINT(sw) * 4, UINT(shrunk.size()), shrunk.data()));
        blurred.resize(size_t(sw) * sh * 7);
        const float smx = float(mask_width) / sw, smy = float(mask_height) / sh;
        for (int y = 0; y < sh; y++) {
            for (int x = 0; x < sw; x++) {
                const uint8_t *p = &shrunk[(size_t(y) * sw + x) * 4];
                float *b = &blurred[(size_t(y) * sw + x) * 7];
                const float back =
                    1 - sample(mask, mask_width, mask_height, 1, (x + 0.5f) * smx - 0.5f, (y + 0.5f) * smy - 0.5f) / 255;
                for (int c = 0; c < 3; c++) {
                    b[c] = p[c] * back;
                    b[4 + c] = p[c];
                }
                b[3] = back;
            }
        }
        // Three box blurs of radius r spread it as a Gaussian of sigma
        // sqrt(r (r + 1)): r for blur_spread's sigma, a fraction of the
        // longest side.
        const double sigma = std::clamp(blur_spread, 0.001, 0.1) * std::max(sw, sh);
        blur(blurred, sw, sh, 7, std::max(1, int(std::lround((std::sqrt(1 + 4 * sigma * sigma) - 1) / 2))));
    }

    WICRect all{0, 0, width, height};
    ComPtr<IWICBitmapLock> lock;
    RETURN_IF_FAILED(bitmap->Lock(&all, WICBitmapLockWrite | WICBitmapLockRead, &lock));
    UINT stride = 0, size = 0;
    BYTE *pixels = nullptr;
    RETURN_IF_FAILED(lock->GetStride(&stride));
    RETURN_IF_FAILED(lock->GetDataPointer(&size, &pixels));
    const float fill[] = {float((color >> 16) & 0xFF), float((color >> 8) & 0xFF), float(color & 0xFF)};
    const float bx = float(sw) / width, by = float(sh) / height;
    for (int y = 0; y < height; y++) {
        uint8_t *row = pixels + size_t(y) * stride;
        for (int x = 0; x < width; x++) {
            uint8_t *p = row + size_t(x) * 4;
            const float subject = subjectAt(x, y);
            if (background == kBackgroundRemove) {
                p[3] = uint8_t(p[3] * subject + 0.5f);
                continue;
            }
            float behind[3];
            if (background == kBackgroundReplace) {
                std::copy(fill, fill + 3, behind);
            } else if (background == kBackgroundMono) {
                // Colour pop: the subject in colour, what's behind it in
                // black and white (Rec. 709's weights, as the look's).
                std::fill(behind, behind + 3, 0.2126f * p[0] + 0.7152f * p[1] + 0.0722f * p[2]);
            } else {
                const float fx = (x + 0.5f) * bx - 0.5f, fy = (y + 0.5f) * by - 0.5f;
                const float weight = sample(blurred.data() + 3, sw, sh, 7, fx, fy);
                for (int c = 0; c < 3; c++) {
                    const float plain = sample(blurred.data() + 4 + c, sw, sh, 7, fx, fy);
                    const float own = weight > 1e-3f ? sample(blurred.data() + c, sw, sh, 7, fx, fy) / weight : plain;
                    // Eased from its own to plain where there's little background about.
                    const float trust = std::clamp(weight * 10, 0.0f, 1.0f);
                    behind[c] = own * trust + plain * (1 - trust);
                }
            }
            for (int c = 0; c < 3; c++)
                p[c] = uint8_t(std::clamp(p[c] * subject + behind[c] * (1 - subject), 0.0f, 255.0f) + 0.5f);
            p[3] = 255;
        }
    }
    lock.Reset();
    // As BGRA, which every encoder takes as it is: given RGBA, PNG's settles
    // on a palette, losing the transparency.
    ComPtr<IWICFormatConverter> bgra;
    RETURN_IF_FAILED(wic->CreateFormatConverter(&bgra));
    RETURN_IF_FAILED(bgra->Initialize(bitmap.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone, nullptr, 0.0,
                                      WICBitmapPaletteTypeCustom));
    picture = bgra;
    return S_OK;
}

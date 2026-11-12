// The editor's adjustments and filters (see look.h). Each pixel goes
// through the same steps as in the preview's shader, shaders/look.frag.

#include "look.h"

#include <algorithm>
#include <cmath>

using Microsoft::WRL::ComPtr;

namespace {

#define RETURN_IF_FAILED(expr)       \
    do {                             \
        HRESULT hr_ = (expr);        \
        if (FAILED(hr_)) return hr_; \
    } while (0)

float luma(const float c[3]) { return 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2]; }

float smoothstep(float edge0, float edge1, float x)
{
    const float t = std::clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3 - 2 * t);
}

// One pixel (0 to 1, as it's stored) at (u, v), fractions across and down.
void apply(const float *s, float c[3], float u, float v)
{
    // Light: exposure in stops (±1.5), then brightness as a curve through
    // the middle tones.
    const float gain = std::exp2(s[kExposure] * 1.5f);
    const float gamma = std::exp2(-s[kBrightness] * 0.8f);
    for (int i = 0; i < 3; i++) c[i] = std::pow(std::max(c[i] * gain, 0.0f), gamma);

    // Shadows and highlights: the dark and the bright, lifted or pulled down.
    float l = std::clamp(luma(c), 0.0f, 1.0f);
    const float lift = 1 + s[kShadows] * 0.6f * (1 - l) * (1 - l) + s[kHighlights] * 0.5f * l * l;
    for (int i = 0; i < 3; i++) c[i] *= lift;

    // Contrast, about the middle grey.
    for (int i = 0; i < 3; i++) c[i] = (c[i] - 0.5f) * (1 + s[kContrast] * 0.6f) + 0.5f;

    // Colour: saturation, then as much black and white as asked for.
    l = luma(c);
    for (int i = 0; i < 3; i++) {
        c[i] = l + (c[i] - l) * (1 + s[kSaturation]);
        c[i] = c[i] + (l - c[i]) * s[kMono];
    }

    // Warmth (blue to amber) and tint (green to magenta).
    c[0] *= 1 + s[kWarmth] * 0.15f;
    c[2] *= 1 - s[kWarmth] * 0.15f;
    c[1] *= 1 - s[kTint] * 0.12f;

    // Faded: blacks lifted, whites a touch dimmer, as old prints.
    for (int i = 0; i < 3; i++) c[i] = s[kFade] * 0.12f + c[i] * (1 - s[kFade] * 0.22f);

    // Vignette: the corners darkened, or for less than 0, lightened.
    const float du = u - 0.5f, dv = v - 0.5f;
    const float edge = smoothstep(0.35f, 1.1f, std::sqrt(du * du + dv * dv) * 1.41421356f);
    for (int i = 0; i < 3; i++) {
        if (s[kVignette] >= 0) {
            c[i] *= 1 - s[kVignette] * 0.75f * edge;
        } else {
            c[i] += (1 - c[i]) * (-s[kVignette] * 0.6f * edge);
        }
        c[i] = std::clamp(c[i], 0.0f, 1.0f);
    }
}

} // namespace

HRESULT withLook(IWICImagingFactory *wic, ComPtr<IWICBitmapSource> &picture, const float *look, int32_t count)
{
    float s[kLookSettings] = {};
    if (look) std::copy(look, look + std::clamp(count, 0, int32_t(kLookSettings)), s);
    if (std::all_of(s, s + kLookSettings, [](float value) { return value == 0; })) return S_OK;

    // The pixels as BGRA, which every encoder takes as it is, changed in place.
    ComPtr<IWICFormatConverter> converter;
    RETURN_IF_FAILED(wic->CreateFormatConverter(&converter));
    RETURN_IF_FAILED(converter->Initialize(picture.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
                                           nullptr, 0.0, WICBitmapPaletteTypeCustom));
    ComPtr<IWICBitmap> bitmap;
    RETURN_IF_FAILED(wic->CreateBitmapFromSource(converter.Get(), WICBitmapCacheOnLoad, &bitmap));
    UINT w = 0, h = 0;
    RETURN_IF_FAILED(bitmap->GetSize(&w, &h));
    WICRect all{0, 0, INT(w), INT(h)};
    ComPtr<IWICBitmapLock> lock;
    RETURN_IF_FAILED(bitmap->Lock(&all, WICBitmapLockWrite | WICBitmapLockRead, &lock));
    UINT stride = 0, size = 0;
    BYTE *pixels = nullptr;
    RETURN_IF_FAILED(lock->GetStride(&stride));
    RETURN_IF_FAILED(lock->GetDataPointer(&size, &pixels));

    for (UINT y = 0; y < h; y++) {
        BYTE *row = pixels + size_t(y) * stride;
        const float v = (y + 0.5f) / h;
        for (UINT x = 0; x < w; x++) {
            BYTE *p = row + size_t(x) * 4;   // B, G, R, A
            float c[3] = {p[2] / 255.0f, p[1] / 255.0f, p[0] / 255.0f};
            apply(s, c, (x + 0.5f) / w, v);
            p[2] = BYTE(c[0] * 255 + 0.5f);
            p[1] = BYTE(c[1] * 255 + 0.5f);
            p[0] = BYTE(c[2] * 255 + 0.5f);
        }
    }
    lock.Reset();
    picture = bitmap;
    return S_OK;
}

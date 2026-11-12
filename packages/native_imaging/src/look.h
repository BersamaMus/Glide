#pragma once

// The editor's adjustments and filters, applied to a picture (look.cpp).
// The same sums as the preview's shader, shaders/look.frag in the app:
// change one, change both.

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <stdint.h>

// What ni_edit's look holds, in this order; each -1 to 1 (0 leaves the
// picture as it was), but mono and fade, 0 to 1.
enum LookSetting : int32_t {
    kExposure,
    kBrightness,
    kContrast,
    kHighlights,
    kShadows,
    kVignette,
    kSaturation,
    kWarmth,
    kTint,
    kMono,
    kFade,
    kLookSettings,
};

// The picture with the look's settings applied (count of them, from the
// first; the rest left at 0). Nothing done when they're all 0.
HRESULT withLook(IWICImagingFactory *wic, Microsoft::WRL::ComPtr<IWICBitmapSource> &picture, const float *look,
                 int32_t count);

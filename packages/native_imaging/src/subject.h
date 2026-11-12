#pragma once

// Finding a picture's subject, and doing something to what's behind it
// (subject.cpp): for ni_subject_mask and ni_edit.

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <stdint.h>

// What a picture's background becomes, as ni_edit takes it.
enum Background : int32_t {
    kBackgroundNone = 0,
    kBackgroundBlur = 1,
    kBackgroundRemove = 2,
    kBackgroundReplace = 3,
    // In black and white: "colour pop".
    kBackgroundMono = 4,
};

// How much each pixel of the picture (RGBA, width * 4 bytes a row) is its
// subject, 0 to 255, into mask (width * height bytes). The first call loads
// the model, which takes a second or so; it's kept for the next.
HRESULT findSubject(const uint8_t *rgba, int32_t width, int32_t height, uint8_t *mask);

// The picture with its background blurred, made transparent, replaced by
// color (0xRRGGBB), or turned black and white, where mask (mask_width by mask_height, the picture's
// shape, from findSubject) says it's not the subject. Upright, as the mask.
// A blur spreads as a Gaussian whose sigma is blur_spread of the picture's
// longest side.
HRESULT withBackground(IWICImagingFactory *wic, Microsoft::WRL::ComPtr<IWICBitmapSource> &picture, int32_t background,
                       uint32_t color, double blur_spread, const uint8_t *mask, int32_t mask_width,
                       int32_t mask_height);

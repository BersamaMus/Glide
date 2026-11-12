// The drives on this PC, and which are external (see native_imaging.h).
// Adapted from Vessel's DriveWatcher.cpp.

#include "native_imaging.h"

#include <windows.h>
#include <winioctl.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

enum Kind { Internal = 0, Usb = 1, Card = 2 };

// What the drive's plugged into: USB (or FireWire), an SD card slot, or
// neither (an internal disk).
Kind busKind(wchar_t letter)
{
    const std::wstring device{L'\\', L'\\', L'.', L'\\', letter, L':'};
    HANDLE handle = CreateFileW(device.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING, 0,
                                nullptr);
    if (handle == INVALID_HANDLE_VALUE) return Internal;

    STORAGE_PROPERTY_QUERY query{};
    query.PropertyId = StorageDeviceProperty;
    query.QueryType = PropertyStandardQuery;
    alignas(STORAGE_DEVICE_DESCRIPTOR) BYTE buffer[1024] = {};
    DWORD bytes = 0;
    Kind kind = Internal;
    if (DeviceIoControl(handle, IOCTL_STORAGE_QUERY_PROPERTY, &query, sizeof(query), buffer, sizeof(buffer), &bytes,
                        nullptr)) {
        switch (reinterpret_cast<const STORAGE_DEVICE_DESCRIPTOR *>(buffer)->BusType) {
        case BusTypeUsb:
        case BusType1394: kind = Usb; break;
        case BusTypeSd:
        case BusTypeMmc: kind = Card; break;
        default: break;
        }
    }
    CloseHandle(handle);
    return kind;
}

// Tabs and line breaks split the list; a label never has them.
std::wstring field(std::wstring text)
{
    std::replace_if(text.begin(), text.end(), [](wchar_t c) { return c == L'\t' || c == L'\n' || c == L'\r'; },
                    L' ');
    return text;
}

} // namespace

NI_EXPORT int32_t ni_drives(wchar_t **lines)
{
    std::wstring text;
    const DWORD letters = GetLogicalDrives();
    for (wchar_t letter = L'A'; letter <= L'Z'; ++letter) {
        if (!(letters & (1u << (letter - L'A')))) continue;
        const std::wstring root{letter, L':', L'\\'};
        const UINT type = GetDriveTypeW(root.c_str());
        if (type != DRIVE_REMOVABLE && type != DRIVE_FIXED) continue;
        // An empty card reader, say, isn't ready: no label to be had.
        WCHAR label[MAX_PATH + 1] = L"";
        if (!GetVolumeInformationW(root.c_str(), label, MAX_PATH + 1, nullptr, nullptr, nullptr, nullptr, 0))
            continue;
        Kind kind = busKind(letter);
        if (kind == Internal && type == DRIVE_REMOVABLE) kind = Usb;
        ULARGE_INTEGER free{}, total{};
        GetDiskFreeSpaceExW(root.c_str(), &free, &total, nullptr);
        text += root + L'\t' + std::to_wstring(int(kind)) + L'\t' + field(label) + L'\t' +
                std::to_wstring(total.QuadPart) + L'\t' + std::to_wstring(free.QuadPart) + L'\n';
    }
    const size_t size = (text.size() + 1) * sizeof(wchar_t);
    *lines = static_cast<wchar_t *>(malloc(size));
    if (!*lines) return E_OUTOFMEMORY;
    memcpy(*lines, text.c_str(), size);
    return S_OK;
}

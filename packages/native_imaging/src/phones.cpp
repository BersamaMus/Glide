// Phones over USB, through Windows Portable Devices (see native_imaging.h).
// Adapted from Vessel's PhoneDevices.cpp: browsed a folder at a time here,
// rather than searched whole for videos.

#include "native_imaging.h"

#include <windows.h>
#include <PortableDevice.h>
#include <PortableDeviceApi.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

// WPD's objects live in COM's multithreaded apartment. Keeping that apartment
// alive for the whole process lets any thread that hasn't joined one (Dart's
// isolate threads) use them.
void ensureCom()
{
    static const bool ready = [] {
        CO_MTA_USAGE_COOKIE cookie = nullptr;
        return SUCCEEDED(CoIncrementMTAUsage(&cookie));
    }();
    (void)ready;
}

template <typename T>
ComPtr<T> create(REFCLSID clsid)
{
    ComPtr<T> object;
    CoCreateInstance(clsid, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&object));
    return object;
}

// Makes a request, waiting a moment and asking again while the phone is busy
// with someone else's (about 5 s in all).
template <typename Call>
HRESULT retrying(Call &&call)
{
    HRESULT hr = call();
    for (int attempt = 1; hr == HRESULT_FROM_WIN32(ERROR_BUSY) && attempt <= 100; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20 + 10 * std::min(attempt, 8)));
        hr = call();
    }
    return hr;
}

std::wstring stringValue(IPortableDeviceValues *values, REFPROPERTYKEY key)
{
    LPWSTR text = nullptr;
    if (FAILED(values->GetStringValue(key, &text)) || !text) return {};
    std::wstring result(text);
    CoTaskMemFree(text);
    return result;
}

// Milliseconds since 1970 (UTC), or 0. MTP dates have no time zone; Windows
// hands them over as local time.
long long dateValue(IPortableDeviceValues *values, REFPROPERTYKEY key)
{
    PROPVARIANT value;
    PropVariantInit(&value);
    long long result = 0;
    SYSTEMTIME local{}, utc{};
    FILETIME file{};
    if (SUCCEEDED(values->GetValue(key, &value)) && value.vt == VT_DATE &&
        VariantTimeToSystemTime(value.date, &local) && TzSpecificLocalTimeToSystemTime(nullptr, &local, &utc) &&
        SystemTimeToFileTime(&utc, &file)) {
        const ULONGLONG ticks = (ULONGLONG(file.dwHighDateTime) << 32) | file.dwLowDateTime;
        result = (long long)(ticks / 10000) - 11644473600000LL;   // 100 ns since 1601 → ms since 1970
    }
    PropVariantClear(&value);
    return result;
}

// Tabs and line breaks split the lists handed back; a name never has them.
std::wstring field(std::wstring text)
{
    std::replace_if(text.begin(), text.end(), [](wchar_t c) { return c == L'\t' || c == L'\n' || c == L'\r'; },
                    L' ');
    return text;
}

int32_t handBack(const std::wstring &text, wchar_t **out)
{
    const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    *out = static_cast<wchar_t *>(malloc(bytes));
    if (!*out) return E_OUTOFMEMORY;
    memcpy(*out, text.c_str(), bytes);
    return S_OK;
}

// One connected phone, opened once and shared. MTP does one thing at a time,
// so its requests take turns.
struct Device
{
    std::wstring id;   // WPD's (Plug and Play) id
    std::wstring serial;
    std::wstring name;
    ComPtr<IPortableDevice> device;
    ComPtr<IPortableDeviceContent> content;
    ComPtr<IPortableDeviceProperties> properties;
    std::mutex mutex;
    // What was last learned about its storage, kept for when it can't be asked (busy).
    bool ready = false;
    unsigned long long bytesTotal = 0;
    unsigned long long bytesFree = 0;
};

std::mutex g_mutex;
std::map<std::wstring, std::shared_ptr<Device>> g_devices;   // by WPD id
std::set<std::wstring> g_notPhones;                           // USB drives and the like, by WPD id

// Opens a device, or returns null for something that isn't a phone (or can't be opened now).
std::shared_ptr<Device> open(IPortableDeviceManager *manager, const std::wstring &id)
{
    auto client = create<IPortableDeviceValues>(CLSID_PortableDeviceValues);
    if (!client) return nullptr;
    client->SetStringValue(WPD_CLIENT_NAME, L"Glide");
    client->SetUnsignedIntegerValue(WPD_CLIENT_DESIRED_ACCESS, GENERIC_READ);
    auto device = std::make_shared<Device>();
    device->id = id;
    device->device = create<IPortableDevice>(CLSID_PortableDeviceFTM);
    if (!device->device || FAILED(device->device->Open(id.c_str(), client.Get()))) return nullptr;
    device->device->Content(&device->content);
    if (!device->content || FAILED(device->content->Properties(&device->properties))) return nullptr;

    ComPtr<IPortableDeviceValues> info;
    retrying([&] {
        info.Reset();
        return device->properties->GetValues(WPD_DEVICE_OBJECT_ID, nullptr, &info);
    });
    if (!info) return nullptr;
    const std::wstring protocol = stringValue(info.Get(), WPD_DEVICE_PROTOCOL);
    if (protocol.rfind(L"MTP", 0) != 0 && protocol.rfind(L"PTP", 0) != 0) {
        std::lock_guard lock(g_mutex);
        g_notPhones.insert(id);   // a USB drive: it has a drive letter, and is browsed as one
        return nullptr;
    }
    device->serial = stringValue(info.Get(), WPD_DEVICE_SERIAL_NUMBER);
    if (device->serial.empty()) device->serial = id;
    WCHAR name[256] = L"";
    DWORD length = 256;
    manager->GetDeviceFriendlyName(id.c_str(), name, &length);
    device->name = name;
    if (device->name.empty()) device->name = stringValue(info.Get(), WPD_DEVICE_MODEL);
    return device;
}

// The objects in a folder (or storage, or the device); false if the phone couldn't say.
bool childIds(Device &device, const std::wstring &parent, std::vector<std::wstring> &ids)
{
    ids.clear();
    ComPtr<IEnumPortableDeviceObjectIDs> children;
    if (FAILED(retrying([&] {
            children.Reset();
            return device.content->EnumObjects(0, parent.c_str(), nullptr, &children);
        })))
        return false;
    LPWSTR batch[256];
    while (true) {
        ULONG got = 0;
        if (FAILED(retrying([&] { return children->Next(256, batch, &got); }))) return false;
        if (got == 0) return true;
        for (ULONG i = 0; i < got; ++i) {
            ids.emplace_back(batch[i]);
            CoTaskMemFree(batch[i]);
        }
    }
}

// Collects the results of a bulk property query. WPD holds on to it from its
// own threads and may let go after the query has ended, so it's reference
// counted properly and deletes itself when the last holder lets go.
class BulkCallback : public IPortableDevicePropertiesBulkCallback
{
public:
    std::vector<ComPtr<IPortableDeviceValues>> results;
    HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HRESULT result = E_PENDING;

    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override
    {
        const ULONG left = --refs_;
        if (left == 0) delete this;
        return left;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override
    {
        if (riid == IID_IUnknown || riid == IID_IPortableDevicePropertiesBulkCallback) {
            *out = this;
            AddRef();
            return S_OK;
        }
        *out = nullptr;
        return E_NOINTERFACE;
    }
    HRESULT STDMETHODCALLTYPE OnStart(REFGUID) override { return S_OK; }
    HRESULT STDMETHODCALLTYPE OnProgress(REFGUID, IPortableDeviceValuesCollection *values) override
    {
        DWORD count = 0;
        values->GetCount(&count);
        for (DWORD i = 0; i < count; ++i) {
            ComPtr<IPortableDeviceValues> v;
            if (SUCCEEDED(values->GetAt(i, &v))) results.push_back(v);
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE OnEnd(REFGUID, HRESULT hr) override
    {
        result = hr;
        SetEvent(done);
        return S_OK;
    }

private:
    ~BulkCallback() { CloseHandle(done); }   // through Release() only

    std::atomic<ULONG> refs_ = 1;
};

// The name, kind, size and date of each object: in one round of requests
// where the phone allows (a few hundred milliseconds for thousands of
// files), else one by one.
std::vector<ComPtr<IPortableDeviceValues>> describe(Device &device, const std::vector<std::wstring> &ids)
{
    auto keys = create<IPortableDeviceKeyCollection>(CLSID_PortableDeviceKeyCollection);
    for (const PROPERTYKEY &key : {WPD_OBJECT_ID, WPD_OBJECT_ORIGINAL_FILE_NAME, WPD_OBJECT_NAME,
                                   WPD_OBJECT_CONTENT_TYPE, WPD_OBJECT_SIZE, WPD_OBJECT_DATE_MODIFIED})
        keys->Add(key);

    ComPtr<IPortableDevicePropertiesBulk> bulk;
    if (SUCCEEDED(device.properties.As(&bulk))) {
        auto list = create<IPortableDevicePropVariantCollection>(CLSID_PortableDevicePropVariantCollection);
        for (const std::wstring &id : ids) {
            PROPVARIANT value;
            PropVariantInit(&value);
            value.vt = VT_LPWSTR;
            value.pwszVal = const_cast<LPWSTR>(id.c_str());
            list->Add(&value);   // copies it
        }
        ComPtr<BulkCallback> callback;
        callback.Attach(new BulkCallback);   // starts with our one reference
        GUID context{};
        if (SUCCEEDED(bulk->QueueGetValuesByObjectList(list.Get(), keys.Get(), callback.Get(), &context)) &&
            SUCCEEDED(bulk->Start(context))) {
            if (WaitForSingleObject(callback->done, 30'000) == WAIT_OBJECT_0 && SUCCEEDED(callback->result))
                return callback->results;
            bulk->Cancel(context);
            WaitForSingleObject(callback->done, 5000);
        }
    }

    std::vector<ComPtr<IPortableDeviceValues>> results;
    for (const std::wstring &id : ids) {
        ComPtr<IPortableDeviceValues> values;
        if (SUCCEEDED(retrying([&] {
                values.Reset();
                return device.properties->GetValues(id.c_str(), keys.Get(), &values);
            })))
            results.push_back(values);
    }
    return results;
}

std::vector<std::shared_ptr<Device>> refresh(IPortableDeviceManager *manager)
{
    manager->RefreshDeviceList();
    DWORD count = 0;
    manager->GetDevices(nullptr, &count);
    std::vector<LPWSTR> ids(count);
    if (count > 0) manager->GetDevices(ids.data(), &count);

    std::set<std::wstring> present;
    std::vector<std::shared_ptr<Device>> phones;
    for (DWORD i = 0; i < count; ++i) {
        const std::wstring id = ids[i];
        CoTaskMemFree(ids[i]);
        present.insert(id);
        std::shared_ptr<Device> device;
        {
            std::lock_guard lock(g_mutex);
            if (g_notPhones.count(id)) continue;
            if (auto found = g_devices.find(id); found != g_devices.end()) device = found->second;
        }
        if (!device) {
            device = open(manager, id);
            if (!device) continue;
            std::lock_guard lock(g_mutex);
            g_devices[id] = device;
        }
        phones.push_back(device);
    }

    // Forget what's been unplugged.
    std::lock_guard lock(g_mutex);
    for (auto it = g_devices.begin(); it != g_devices.end();)
        it = present.count(it->first) ? std::next(it) : g_devices.erase(it);
    for (auto it = g_notPhones.begin(); it != g_notPhones.end();)
        it = present.count(*it) ? std::next(it) : g_notPhones.erase(it);
    return phones;
}

std::shared_ptr<Device> bySerial(const std::wstring &serial)
{
    for (int pass = 0; pass < 2; ++pass) {
        {
            std::lock_guard lock(g_mutex);
            for (const auto &[id, device] : g_devices)
                if (device->serial == serial) return device;
        }
        if (pass == 0) {   // not opened yet (by this run of the app)
            auto manager = create<IPortableDeviceManager>(CLSID_PortableDeviceManager);
            if (!manager) return nullptr;
            refresh(manager.Get());
        }
    }
    return nullptr;
}

} // namespace

NI_EXPORT int32_t ni_phones(wchar_t **lines)
{
    *lines = nullptr;
    ensureCom();
    auto manager = create<IPortableDeviceManager>(CLSID_PortableDeviceManager);
    if (!manager) return E_FAIL;

    std::wstring text;
    for (const auto &device : refresh(manager.Get())) {
        std::lock_guard lock(device->mutex);
        // A locked phone, or one only charging, shows no storage.
        auto keys = create<IPortableDeviceKeyCollection>(CLSID_PortableDeviceKeyCollection);
        keys->Add(WPD_STORAGE_CAPACITY);
        keys->Add(WPD_STORAGE_FREE_SPACE_IN_BYTES);
        std::vector<std::wstring> storages;
        if (childIds(*device, WPD_DEVICE_OBJECT_ID, storages)) {
            bool ready = false;
            unsigned long long total = 0, free = 0;
            for (const std::wstring &storage : storages) {
                ComPtr<IPortableDeviceValues> values;
                if (FAILED(retrying([&] {
                        values.Reset();
                        return device->properties->GetValues(storage.c_str(), keys.Get(), &values);
                    })))
                    continue;
                ULONGLONG capacity = 0, available = 0;
                values->GetUnsignedLargeIntegerValue(WPD_STORAGE_CAPACITY, &capacity);
                values->GetUnsignedLargeIntegerValue(WPD_STORAGE_FREE_SPACE_IN_BYTES, &available);
                ready = true;
                total += capacity;
                free += available;
            }
            device->ready = ready;
            device->bytesTotal = total;
            device->bytesFree = free;
        }
        // Couldn't ask (busy all along): as it was last time, rather than as if it had been locked.
        text += field(device->serial) + L'\t' + field(device->name) + L'\t' + (device->ready ? L"1" : L"0") + L'\t' +
                std::to_wstring(device->bytesTotal) + L'\t' + std::to_wstring(device->bytesFree) + L'\n';
    }
    return handBack(text, lines);
}

NI_EXPORT int32_t ni_phone_list(const wchar_t *serial, const wchar_t *folder_id, wchar_t **lines)
{
    *lines = nullptr;
    ensureCom();
    const auto device = bySerial(serial);
    if (!device) return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);

    std::vector<ComPtr<IPortableDeviceValues>> children;
    {
        std::lock_guard lock(device->mutex);
        std::vector<std::wstring> ids;
        const std::wstring parent = *folder_id ? folder_id : WPD_DEVICE_OBJECT_ID;
        if (!childIds(*device, parent, ids)) return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);
        if (!ids.empty()) children = describe(*device, ids);
    }

    std::wstring text;
    for (const auto &values : children) {
        std::wstring name = stringValue(values.Get(), WPD_OBJECT_ORIGINAL_FILE_NAME);
        if (name.empty()) name = stringValue(values.Get(), WPD_OBJECT_NAME);
        if (name.empty()) continue;
        GUID type{};
        values->GetGuidValue(WPD_OBJECT_CONTENT_TYPE, &type);
        const bool folder = type == WPD_CONTENT_TYPE_FOLDER || type == WPD_CONTENT_TYPE_FUNCTIONAL_OBJECT;
        ULONGLONG size = 0;
        values->GetUnsignedLargeIntegerValue(WPD_OBJECT_SIZE, &size);
        text += field(stringValue(values.Get(), WPD_OBJECT_ID)) + L'\t' + field(name) + L'\t' + (folder ? L"1" : L"0") +
                L'\t' + std::to_wstring(size) + L'\t' +
                std::to_wstring(dateValue(values.Get(), WPD_OBJECT_DATE_MODIFIED)) + L'\n';
    }
    return handBack(text, lines);
}

NI_EXPORT int32_t ni_phone_read(const wchar_t *serial, const wchar_t *object_id, int32_t thumbnail, uint8_t **data,
                                int64_t *length)
{
    *data = nullptr;
    *length = 0;
    ensureCom();
    const auto device = bySerial(serial);
    if (!device) return HRESULT_FROM_WIN32(ERROR_DEVICE_NOT_CONNECTED);

    std::lock_guard lock(device->mutex);
    ComPtr<IPortableDeviceResources> resources;
    if (FAILED(device->content->Transfer(&resources))) return E_FAIL;
    ComPtr<IStream> stream;
    DWORD chunk = 0;
    const HRESULT opened = retrying([&] {
        stream.Reset();
        return resources->GetStream(object_id, thumbnail ? WPD_RESOURCE_THUMBNAIL : WPD_RESOURCE_DEFAULT, STGM_READ,
                                    &chunk, &stream);
    });
    if (FAILED(opened)) return opened;
    if (chunk == 0) chunk = 256 * 1024;

    std::vector<uint8_t> bytes;
    std::vector<uint8_t> buffer(chunk);
    while (true) {
        ULONG got = 0;
        const HRESULT hr = stream->Read(buffer.data(), chunk, &got);
        if (FAILED(hr)) return hr;
        if (got == 0) break;
        bytes.insert(bytes.end(), buffer.begin(), buffer.begin() + got);
        if (hr == S_FALSE) break;   // the end
    }
    if (bytes.empty()) return HRESULT_FROM_WIN32(ERROR_HANDLE_EOF);
    *data = static_cast<uint8_t *>(malloc(bytes.size()));
    if (!*data) return E_OUTOFMEMORY;
    memcpy(*data, bytes.data(), bytes.size());
    *length = int64_t(bytes.size());
    return S_OK;
}

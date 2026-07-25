#import "AZSSMC.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/IOKitKeys.h>
#import <libkern/OSTypes.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <unistd.h>
#include <vector>
#include <sys/sysctl.h>

namespace {

// AppleSMC's user client is undocumented. This is the 80-byte layout used by
// current Apple Silicon firmware (the older 56/60-byte layout makes every
// key-info request fail with "key not found" on M-series Macs).
struct SMCParamStruct {
    uint32_t key;
    uint8_t vers[4];
    uint8_t pLimitData[16];
    uint8_t padding0[4];
    uint32_t keyInfoDataSize;
    uint32_t keyInfoDataType;
    uint8_t keyInfoDataAttributes;
    uint8_t keyInfoPadding[3];
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint8_t padding1;
    uint32_t data32;
    uint8_t bytes[32];
};

static_assert(sizeof(SMCParamStruct) == 80, "AppleSMC structure layout changed");

constexpr uint8_t kReadBytes = 5;
constexpr uint8_t kWriteBytes = 6;
constexpr uint8_t kReadKeyInfo = 9;

io_connect_t gConnection = IO_OBJECT_NULL;
std::mutex gMutex;
std::string gLastError;

uint32_t keyCode(const char *key) {
    if (!key || std::strlen(key) < 4) return 0;
    return (uint32_t(uint8_t(key[0])) << 24) |
           (uint32_t(uint8_t(key[1])) << 16) |
           (uint32_t(uint8_t(key[2])) << 8) |
           uint32_t(uint8_t(key[3]));
}

void setError(const char *message) { gLastError = message ? message : "SMC error"; }

bool ensureConnection() {
    if (gConnection != IO_OBJECT_NULL) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                        IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) {
        setError("AppleSMC không khả dụng trên máy này");
        return false;
    }
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gConnection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        gConnection = IO_OBJECT_NULL;
        setError("Không mở được AppleSMC");
        return false;
    }
    return true;
}

bool call(SMCParamStruct &input, SMCParamStruct &output) {
    if (!ensureConnection()) return false;
    size_t outputSize = sizeof(output);
    kern_return_t kr = IOConnectCallStructMethod(gConnection, 2, &input,
                                                  sizeof(input), &output, &outputSize);
    if (kr != KERN_SUCCESS || output.result != 0) {
        if (kr == kIOReturnNotPermitted || kr == kIOReturnNotPrivileged) {
            setError("macOS từ chối quyền ghi SMC (cần helper quản trị)");
        } else {
            setError("AppleSMC không đọc/ghi được khóa này");
        }
        return false;
    }
    return true;
}

bool readKey(const char *key, uint8_t *bytes, uint32_t *size, uint32_t *type) {
    if (!bytes || !size || !type || !key) return false;
    SMCParamStruct input{};
    SMCParamStruct output{};
    input.key = keyCode(key);
    input.data8 = kReadKeyInfo;
    if (!call(input, output)) return false;

    uint32_t dataSize = output.keyInfoDataSize;
    if (dataSize == 0 || dataSize > sizeof(output.bytes)) {
        setError("Dữ liệu SMC không hợp lệ");
        return false;
    }
    *size = dataSize;
    *type = output.keyInfoDataType;
    input = {};
    output = {};
    input.key = keyCode(key);
    input.data8 = kReadBytes;
    input.keyInfoDataSize = dataSize;
    if (!call(input, output)) return false;
    std::memcpy(bytes, output.bytes, dataSize);
    return true;
}

bool writeKey(const char *key, const uint8_t *bytes, uint32_t size, uint32_t type) {
    if (!bytes || !key || size == 0 || size > 32) return false;
    SMCParamStruct input{};
    SMCParamStruct output{};
    input.key = keyCode(key);
    input.data8 = kWriteBytes;
    input.keyInfoDataSize = size;
    input.data32 = type;
    std::memcpy(input.bytes, bytes, size);
    return call(input, output);
}

double beFloat(const uint8_t *p) {
    uint32_t bits = (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
                    (uint32_t(p[2]) << 8) | uint32_t(p[3]);
    float value = 0;
    std::memcpy(&value, &bits, sizeof(value));
    return std::isfinite(value) ? double(value) : 0.0;
}

double leFloat(const uint8_t *p) {
    uint32_t bits = (uint32_t(p[3]) << 24) | (uint32_t(p[2]) << 16) |
                    (uint32_t(p[1]) << 8) | uint32_t(p[0]);
    float value = 0;
    std::memcpy(&value, &bits, sizeof(value));
    return std::isfinite(value) ? double(value) : 0.0;
}

double smcFloat(const uint8_t *p) {
    const double big = beFloat(p);
    const double little = leFloat(p);
    // Apple Silicon exposes flt  payloads little-endian while older Intel
    // Macs expose the same type big-endian. Prefer the plausible value.
    if (std::fabs(big) < 0.01 && std::fabs(little) >= 1.0) return little;
    return big;
}

double beSp78(const uint8_t *p) {
    int16_t raw = int16_t((uint16_t(p[0]) << 8) | uint16_t(p[1]));
    return double(raw) / 256.0;
}

uint32_t typeCode(const char *text) {
    return keyCode(text);
}

bool readFloatKey(const char *key, double &value) {
    uint8_t data[32]{};
    uint32_t size = 0, type = 0;
    if (!readKey(key, data, &size, &type) || size < 4) return false;
    value = (type == typeCode("fpe2")) ? (double((uint16_t(data[0]) << 8) | data[1]) / 4.0) : smcFloat(data);
    return std::isfinite(value);
}

bool readUIntKey(const char *key, uint32_t &value) {
    uint8_t data[32]{};
    uint32_t size = 0, type = 0;
    if (!readKey(key, data, &size, &type) || size == 0) return false;
    value = 0;
    for (uint32_t i = 0; i < size && i < 4; ++i) value = (value << 8) | data[i];
    return true;
}

bool readMode(int index, int32_t &manual) {
    char key[5]; std::snprintf(key, sizeof(key), "F%dMd", index);
    uint32_t mode = 0;
    if (!readUIntKey(key, mode)) {
        std::snprintf(key, sizeof(key), "F%dmd", index);
        if (!readUIntKey(key, mode)) return false;
    }
    // SMC fan mode 0 is automatic, 1 is forced/manual on most Macs.
    manual = mode != 0 ? 1 : 0;
    return true;
}

bool writeFanMode(int index, uint8_t mode) {
    char key[5];
    std::snprintf(key, sizeof(key), "F%dMd", index);
    if (writeKey(key, &mode, 1, typeCode("ui8 "))) return true;
    std::snprintf(key, sizeof(key), "F%dmd", index);
    return writeKey(key, &mode, 1, typeCode("ui8 "));
}

bool unlockManualMode(int index) {
    uint8_t force = 1;
    if (!writeKey("Ftst", &force, 1, typeCode("ui8 "))) return false;
    usleep(500000);
    return writeFanMode(index, 1);
}

bool writeFloatKey(const char *key, double value) {
    float f = float(value);
    uint32_t bits = 0;
    std::memcpy(&bits, &f, sizeof(bits));
    int arm64 = 0;
    size_t arm64Size = sizeof(arm64);
    sysctlbyname("hw.optional.arm64", &arm64, &arm64Size, nullptr, 0);
    // Apple Silicon exposes SMC `flt ` payloads little-endian; Intel Macs
    // use the traditional big-endian representation.
    uint8_t data[4]{};
    if (arm64) {
        data[0] = uint8_t(bits); data[1] = uint8_t(bits >> 8);
        data[2] = uint8_t(bits >> 16); data[3] = uint8_t(bits >> 24);
    } else {
        data[0] = uint8_t(bits >> 24); data[1] = uint8_t(bits >> 16);
        data[2] = uint8_t(bits >> 8); data[3] = uint8_t(bits);
    }
    return writeKey(key, data, sizeof(data), typeCode("flt "));
}

bool decodeTemperature(const uint8_t *data, uint32_t size, uint32_t type, double &value) {
    if (size >= 2 && type == typeCode("sp78")) value = beSp78(data);
    else if (size >= 2 && type == typeCode("fpe2")) value = double((uint16_t(data[0]) << 8) | data[1]) / 4.0;
    else if (size >= 4 && type == typeCode("flt ")) value = smcFloat(data);
    else return false;
    return std::isfinite(value) && value > 10 && value < 130;
}

std::vector<std::string> temperatureKeys() {
    std::vector<std::string> result;
    uint8_t countBytes[32]{};
    uint32_t countSize = 0, countType = 0;
    if (!readKey("#KEY", countBytes, &countSize, &countType) || countSize < 4) return result;
    uint32_t count = (uint32_t(countBytes[0]) << 24) | (uint32_t(countBytes[1]) << 16) |
                     (uint32_t(countBytes[2]) << 8) | uint32_t(countBytes[3]);
    count = std::min<uint32_t>(count, 4096);
    result.reserve(64);
    for (uint32_t index = 0; index < count; ++index) {
        SMCParamStruct input{};
        SMCParamStruct output{};
        input.data8 = 8; // read key name by index
        input.data32 = index;
        if (!call(input, output)) continue;
        char key[5] = {
            char((output.key >> 24) & 0xff), char((output.key >> 16) & 0xff),
            char((output.key >> 8) & 0xff), char(output.key & 0xff), 0
        };
        if (key[0] != 'T') continue;
        uint8_t data[32]{};
        uint32_t size = 0, type = 0;
        if (!readKey(key, data, &size, &type) || size < 2) continue;
        double value = 0;
        if (decodeTemperature(data, size, type, value) &&
            std::find(result.begin(), result.end(), key) == result.end()) result.emplace_back(key);
    }
    return result;
}

} // namespace

extern "C" int32_t AZSSMCReadFanCount(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    uint32_t count = 0;
    if (!readUIntKey("FNum", count)) return -1;
    return int32_t(std::min<uint32_t>(count, 16));
}

extern "C" int32_t AZSSMCReadFan(int32_t index, double *actualRPM, double *minimumRPM,
                                   double *maximumRPM, double *targetRPM, int32_t *manual) {
    if (index < 0 || index > 15 || !actualRPM || !minimumRPM || !maximumRPM || !targetRPM || !manual) return 0;
    std::lock_guard<std::mutex> lock(gMutex);
    char key[5];
    std::snprintf(key, sizeof(key), "F%dAc", int(index));
    if (!readFloatKey(key, *actualRPM)) return 0;
    std::snprintf(key, sizeof(key), "F%dMn", int(index));
    if (!readFloatKey(key, *minimumRPM)) *minimumRPM = 0;
    std::snprintf(key, sizeof(key), "F%dMx", int(index));
    if (!readFloatKey(key, *maximumRPM)) *maximumRPM = std::max(*minimumRPM, 5000.0);
    std::snprintf(key, sizeof(key), "F%dTg", int(index));
    if (!readFloatKey(key, *targetRPM)) *targetRPM = *actualRPM;
    if (!readMode(index, *manual)) *manual = 0;
    return 1;
}

extern "C" int32_t AZSSMCReadTemperature(const char *key, double *celsius) {
    if (!key || !celsius) return 0;
    std::lock_guard<std::mutex> lock(gMutex);
    uint8_t data[32]{};
    uint32_t size = 0, type = 0;
    if (!readKey(key, data, &size, &type) || size < 2) return 0;
    if (type == typeCode("sp78") || size == 2) *celsius = beSp78(data);
    else if (size >= 4) *celsius = beFloat(data);
    else return 0;
    return std::isfinite(*celsius) && *celsius > 10 && *celsius < 130;
}

extern "C" int32_t AZSSMCReadTemperatureSensorCount(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    return int32_t(temperatureKeys().size());
}

extern "C" int32_t AZSSMCReadTemperatureSensor(int32_t slot, char *keyOut,
                                                  int32_t keyCapacity, double *celsius) {
    if (slot < 0 || !keyOut || keyCapacity < 5 || !celsius) return 0;
    std::lock_guard<std::mutex> lock(gMutex);
    const auto keys = temperatureKeys();
    if (slot >= int32_t(keys.size())) return 0;
    std::snprintf(keyOut, size_t(keyCapacity), "%s", keys[size_t(slot)].c_str());
    uint8_t data[32]{};
    uint32_t size = 0, type = 0;
    if (!readKey(keyOut, data, &size, &type) || size < 2) return 0;
    return decodeTemperature(data, size, type, *celsius) ? 1 : 0;
}

extern "C" int32_t AZSSMCSetFanTarget(int32_t index, double rpm) {
    if (index < 0 || index > 15 || !std::isfinite(rpm) || rpm < 0) return 0;
    std::lock_guard<std::mutex> lock(gMutex);
    char key[5]; std::snprintf(key, sizeof(key), "F%dTg", int(index));
    bool targetWritten = writeFloatKey(key, rpm);
    bool modeWritten = writeFanMode(int(index), 1);
    if (!targetWritten || !modeWritten) {
        if (!unlockManualMode(int(index))) return 0;
        targetWritten = writeFloatKey(key, rpm);
        modeWritten = writeFanMode(int(index), 1);
    }
    return targetWritten && modeWritten ? 1 : 0;
}

extern "C" int32_t AZSSMCSetFanAuto(int32_t index) {
    if (index < 0 || index > 15) return 0;
    std::lock_guard<std::mutex> lock(gMutex);
    if (writeFanMode(int(index), 0)) return 1;
    uint8_t force = 0;
    writeKey("Ftst", &force, 1, typeCode("ui8 "));
    return writeFanMode(int(index), 0) ? 1 : 0;
}

extern "C" const char *AZSSMCLastError(void) {
    std::lock_guard<std::mutex> lock(gMutex);
    return gLastError.c_str();
}

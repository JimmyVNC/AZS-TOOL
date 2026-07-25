#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t AZSSMCReadFanCount(void);
int32_t AZSSMCReadFan(int32_t index, double *actualRPM, double *minimumRPM,
                     double *maximumRPM, double *targetRPM, int32_t *manual);
int32_t AZSSMCReadTemperature(const char *key, double *celsius);
int32_t AZSSMCReadTemperatureSensorCount(void);
int32_t AZSSMCReadTemperatureSensor(int32_t slot, char *keyOut, int32_t keyCapacity, double *celsius);
int32_t AZSSMCSetFanTarget(int32_t index, double rpm);
int32_t AZSSMCSetFanAuto(int32_t index);
const char *AZSSMCLastError(void);

#ifdef __cplusplus
}
#endif

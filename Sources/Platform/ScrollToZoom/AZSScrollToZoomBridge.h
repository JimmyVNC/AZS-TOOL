#pragma once
#include <stdbool.h>
#include <stdint.h>

// AZS-facing configuration adapter. The event transformation itself remains
// in ScrollToZoom's original C state machine and event-tap modules.
void AZSConfigureScrollToZoom(bool enabled,
                              uint32_t modifier,
                              double sensitivity,
                              bool reversed,
                              bool usesCommandKeys);
void AZSStopScrollToZoom(void);
bool AZSScrollToZoomUsesCommandKeys(void);
bool AZSScrollToZoomShouldBypassMOS(void);

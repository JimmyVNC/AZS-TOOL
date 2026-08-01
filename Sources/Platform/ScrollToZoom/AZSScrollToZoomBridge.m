#import "AZSScrollToZoomBridge.h"
#import "STZEventHandling.h"
#import "STZSettings.h"
#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

static bool AZSScrollToZoomEnabled = false;
static bool AZSUsesCommandKeys = false;

static STZFlags AZSModifierFlag(uint32_t modifier) {
    switch (modifier) {
    case 0: return kSTZModifierOption;
    case 1: return kSTZModifierControl;
    case 2: return kSTZModifierCommand;
    case 3: return kSTZModifierShift;
    default: return kSTZModifierOption;
    }
}

void AZSConfigureScrollToZoom(bool enabled,
                              uint32_t modifier,
                              double sensitivity,
                              bool reversed,
                              bool usesCommandKeys) {
    NSCAssert([NSThread isMainThread], @"ScrollToZoom event taps must be configured on the main thread");

    AZSScrollToZoomEnabled = enabled;
    AZSUsesCommandKeys = usesCommandKeys;
    STZSetTriggerFlags(AZSModifierFlag(modifier));

    double clampedSensitivity = fmax(0.25, fmin(3.0, sensitivity));
    double scalar = 0.0025 * clampedSensitivity;
    STZSetMagnificationScalar(reversed ? -scalar : scalar);
    STZSetMomentumZoomAttenuation(0.8);
    STZSetMomentumZoomMinValue(0.001);

    // Dictatorship is the reference implementation's compatibility path for
    // Mos and other tools that replace one physical wheel event with a soft
    // sequence. AZS's smooth-scroll engine has the same event topology.
    STZModes modes = enabled
        ? (kSTZTriggerFlagsEnabled | kSTZWantsDictatorship)
        : 0;
    if (!STZSetWorkingModes(modes) && enabled) {
        NSLog(@"AZS ScrollToZoom: could not create reference event-tap pipeline (AX trusted=%d)",
              AXIsProcessTrusted());
    }
}

void AZSStopScrollToZoom(void) {
    AZSScrollToZoomEnabled = false;
    STZSetWorkingModes(0);
}

bool AZSScrollToZoomUsesCommandKeys(void) {
    return AZSUsesCommandKeys;
}

bool STZIsLoggingEnabled(void) {
    return false;
}

void STZDebugLog(char const *message, ...) {
    (void)message;
}

void STZDidStopWorkingDueToEventTapTimeout(void) {
    if (!AZSScrollToZoomEnabled) { return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (AZSScrollToZoomEnabled) {
            STZSetWorkingModes(kSTZTriggerFlagsEnabled | kSTZWantsDictatorship);
        }
    });
}

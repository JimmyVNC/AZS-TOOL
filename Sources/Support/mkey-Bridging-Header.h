//
//  mkey-Bridging-Header.h
//  mkey
//

#import "MKGlobals.h"
#import "MKBridge.h"
#import "AZSSMC.h"
#import <Foundation/Foundation.h>
#import <IOKit/i2c/IOI2CInterface.h>
#import <CoreGraphics/CoreGraphics.h>

typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void* outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void* inputBuffer, uint32_t inputBufferSize);
extern CFDictionaryRef CoreDisplay_DisplayCreateInfoDictionary(CGDirectDisplayID display);
extern void CGSServiceForDisplayNumber(CGDirectDisplayID display, io_service_t* service);

#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

@interface VTParamSetSerializer : NSObject

/// Extracts parameter sets from a format description and serializes them
/// to the wire format. Returns nil if extraction fails.
+ (nullable NSData *)serializeFormatDescription:
                         (_Nonnull CMVideoFormatDescriptionRef)fmtDesc
                                          delta:(UInt32)delta
                                           data:(const char *_Nonnull)data
                                            len:(size_t)len;
@end

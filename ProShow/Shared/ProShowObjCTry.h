#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns NO instead of aborting when it raises an Objective-C exception
/// (AVAudioPlayerNode play throws NSException when LiveKit's audio graph is mid-reconfigure).
BOOL ProShowObjCTry(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END

#import "AudioExceptionGuard.h"
#include <stdio.h>

@interface ThrowingPlayer : AVAudioPlayerNode
@end
@implementation ThrowingPlayer
- (void)play {
    @throw [NSException exceptionWithName:@"InvalidAudioGraph" reason:@"Injected graph failure" userInfo:nil];
}
@end

@interface ReadyPlayer : AVAudioPlayerNode
@end
@implementation ReadyPlayer
- (void)play {}
@end

int main(void) {
    @autoreleasepool {
        if (RCAudioTryPlay([ThrowingPlayer new]) || !RCAudioTryPlay([ReadyPlayer new])) {
            fputs("FAIL: audio exception boundary\n", stderr);
            return 1;
        }
        puts("PASS: Objective-C playback exception becomes a recoverable failure");
    }
    return 0;
}

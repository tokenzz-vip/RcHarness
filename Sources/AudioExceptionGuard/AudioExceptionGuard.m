#import "AudioExceptionGuard.h"

BOOL RCAudioTryPlay(AVAudioPlayerNode *player) {
    @try {
        [player play];
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

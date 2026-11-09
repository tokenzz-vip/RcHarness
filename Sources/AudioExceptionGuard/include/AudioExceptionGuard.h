#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
// AVFAudio may raise NSException when HAL changes between start and play.
BOOL RCAudioTryPlay(AVAudioPlayerNode *player);
NS_ASSUME_NONNULL_END

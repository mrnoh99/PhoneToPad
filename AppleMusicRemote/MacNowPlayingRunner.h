#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mac Catalyst 에서 osascript 를 실행하고 stdout 문자열을 반환한다. 호출자는 free() 로 해제.
char *_Nullable PhoneToPadRunOsascript(char *_Nonnull const *_Nonnull arguments, int argumentCount);

NS_ASSUME_NONNULL_END

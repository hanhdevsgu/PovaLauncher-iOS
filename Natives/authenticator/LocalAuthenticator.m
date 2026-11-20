#import "BaseAuthenticator.h"
#import <CommonCrypto/CommonDigest.h>

@implementation LocalAuthenticator

+ (NSString *)offlineUUIDForUsername:(NSString *)username {
    NSString *source = [@"OfflinePlayer:" stringByAppendingString:username];
    const char *utf8 = source.UTF8String;
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(utf8, (CC_LONG)strlen(utf8), digest);
#pragma clang diagnostic pop
    // Set RFC 4122 version 3 (name-based MD5) and variant bits to match Java UUID.nameUUIDFromBytes
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5],
            digest[6], digest[7],
            digest[8], digest[9],
            digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]];
}

+ (BOOL)isValidOfflineUsername:(NSString *)username {
    if (!username) {
        return NO;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z0-9_]{3,16}$" options:0 error:nil];
    return [regex firstMatchInString:username options:0 range:NSMakeRange(0, username.length)] != nil;
}

- (void)loginWithCallback:(Callback)callback {
    NSString *rawInput = [self.authData[@"input"] description] ?: @"";
    NSString *trimmed = [rawInput stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![LocalAuthenticator isValidOfflineUsername:trimmed]) {
        NSError *err = [NSError errorWithDomain:@"PovaLauncher.Auth"
                                           code:400
                                       userInfo:@{NSLocalizedDescriptionKey: @"Tên người chơi phải dài 3-16 ký tự (chỉ gồm chữ, số và dấu _)."}];
        if (callback) {
            callback(err, NO);
        }
        return;
    }
    self.authData[@"input"] = trimmed;
    self.authData[@"oldusername"] = self.authData[@"username"] = trimmed;
    self.authData[@"profileId"] = [LocalAuthenticator offlineUUIDForUsername:trimmed];
    self.authData[@"accessToken"] = @"0";
    if (callback) {
        callback(nil, [super saveChanges]);
    }
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Offline accounts do not require token refresh
    if (callback) {
        callback(nil, YES);
    }
}

@end

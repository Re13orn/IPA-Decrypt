#import <Foundation/Foundation.h>
#include "client/client_internal.hpp"
#include <memory>
#include <mutex>

namespace {
std::mutex transferLock;
int64_t receivedBytes = 0;
int64_t totalBytes = 0;
int transferPhase = 0;

void updateTransfer(int phase, int64_t received, int64_t total) {
    std::lock_guard guard(transferLock);
    transferPhase = phase;
    receivedBytes = received;
    totalBytes = total;
}
}

extern "C" void IPALabResetTestFlightProgress() {
    updateTransfer(0, 0, 0);
}

extern "C" int IPALabTestFlightProgress(int64_t *received, int64_t *total) {
    std::lock_guard guard(transferLock);
    *received = receivedBytes;
    *total = totalBytes;
    return transferPhase;
}

namespace apple_auth::netdetail {
std::uint64_t download_file(const std::string& url, const Path& destination) {
    @autoreleasepool {
        require(url.starts_with("https://"), "Only HTTPS downloads are supported");
        require(!std::filesystem::exists(destination), "Download output already exists");
        NSURL *remote = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
        NSURL *local = [NSURL fileURLWithPath:[NSString stringWithUTF8String:destination.c_str()]];
        require(remote && local, "Invalid download URL");
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.HTTPShouldSetCookies = NO;
        configuration.URLCredentialStorage = nil;
        configuration.timeoutIntervalForRequest = 30;
        configuration.timeoutIntervalForResource = 600;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block std::uint64_t length = 0;
        __block NSString *failure = nil;
        NSURLSessionDownloadTask *task = [session downloadTaskWithURL:remote completionHandler:
          ^(NSURL *file, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
            NSError *fileError = nil;
            NSNumber *size = nil;
            if (error || !file || !http || http.statusCode != 200 || ![http.URL.scheme isEqualToString:@"https"]) {
                failure = [NSString stringWithFormat:@"IPA download failed (HTTP %ld, network error %ld)", (long)http.statusCode, (long)error.code];
            } else if (![file getResourceValue:&size forKey:NSURLFileSizeKey error:&fileError] ||
                       !size.unsignedLongLongValue || size.unsignedLongLongValue > (1ull << 34) ||
                       (http.expectedContentLength > 0 && size.unsignedLongLongValue != (std::uint64_t)http.expectedContentLength)) {
                failure = @"Invalid IPA transfer size";
            } else if (![[NSFileManager defaultManager] moveItemAtURL:file toURL:local error:&fileError]) {
                failure = @"Cannot write the IPA to disk";
            } else {
                length = size.unsignedLongLongValue;
            }
            dispatch_semaphore_signal(done);
        }];
        [task resume];
        while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC)) != 0) {
            updateTransfer(1, task.countOfBytesReceived, task.countOfBytesExpectedToReceive);
        }
        [session finishTasksAndInvalidate];
        if (failure) throw std::runtime_error(failure.UTF8String);
        updateTransfer(2, static_cast<int64_t>(length), static_cast<int64_t>(length));
        return length;
    }
}
}

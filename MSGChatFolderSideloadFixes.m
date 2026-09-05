//
//  MSGChatFolderSideloadFixes.m
//  MSGChatFolders — Messenger Chat Folders Tweak
//
//  Fixes for running Messenger with a modified bundle ID (sideloading).
//  Meta's crash reporter and various internal systems assert on the
//  original bundle ID. This file patches those checks.
//
//  Based on patterns from SNMessenger's SideloadedFixes.xm
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#define CFLOG(fmt, ...) NSLog(@"[MSGChatFolders][SideloadFix] " fmt, ##__VA_ARGS__)

static NSString *const kOriginalBundleID = @"com.facebook.Messenger";
static NSString *const kOriginalGroupPrefix = @"group.com.facebook.Messenger";

// ═══════════════════════════════════════════════════════════
// MARK: - Fake App Group Container
// ═══════════════════════════════════════════════════════════

static NSURL *fakeGroupContainerURL = nil;

static void createDirectoryIfNotExists(NSURL *URL) {
    if (![URL checkResourceIsReachableAndReturnError:nil]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:URL
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];
    }
}

// Original IMP for containerURLForSecurityApplicationGroupIdentifier:
static NSURL *(*orig_containerURL)(id self, SEL _cmd, NSString *groupId);

static NSURL *hooked_containerURL(id self, SEL _cmd, NSString *groupId) {
    // When the app asks for a group container (which fails with a changed bundle ID),
    // redirect to a fake directory inside the app's own container
    NSURL *fakeURL = [fakeGroupContainerURL URLByAppendingPathComponent:groupId];
    createDirectoryIfNotExists(fakeURL);
    createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library"]);
    createDirectoryIfNotExists([fakeURL URLByAppendingPathComponent:@"Library/Caches"]);
    return fakeURL;
}

// ═══════════════════════════════════════════════════════════
// MARK: - Bundle ID Spoofing
// ═══════════════════════════════════════════════════════════

static NSString *(*orig_bundleIdentifier)(id self, SEL _cmd);

static NSString *hooked_bundleIdentifier(id self, SEL _cmd) {
    // Only spoof the main bundle's identifier
    if (self == [NSBundle mainBundle]) {
        return kOriginalBundleID;
    }
    return orig_bundleIdentifier(self, _cmd);
}

// ═══════════════════════════════════════════════════════════
// MARK: - Keychain Access Group Fix
// ═══════════════════════════════════════════════════════════

// Messenger uses keychain access groups tied to the original bundle ID.
// With a changed bundle ID, keychain queries fail.
// We don't hook SecItem* directly (those are C functions), but we ensure
// the bundle ID reports correctly so Messenger forms the right queries.

// ═══════════════════════════════════════════════════════════
// MARK: - Registration
// ═══════════════════════════════════════════════════════════

__attribute__((constructor))
static void MSGChatFolders_SideloadFixes_init(void) {
    // Check if we're running with a modified bundle ID
    NSString *actualBundleID = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleIdentifier"];

    if ([actualBundleID isEqualToString:kOriginalBundleID]) {
        CFLOG(@"Running with original bundle ID — sideload fixes not needed.");
        return;
    }

    CFLOG(@"Modified bundle ID detected: %@ → applying sideload fixes", actualBundleID);

    // Set up fake group container directory
    NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    fakeGroupContainerURL = [NSURL fileURLWithPath:[docsPath stringByAppendingPathComponent:@"FakeGroupContainers"]];
    createDirectoryIfNotExists(fakeGroupContainerURL);

    // ── Fix 1: Spoof bundle identifier ──
    Class bundleClass = [NSBundle class];
    Method bundleIdMethod = class_getInstanceMethod(bundleClass, @selector(bundleIdentifier));
    if (bundleIdMethod) {
        orig_bundleIdentifier = (NSString *(*)(id, SEL))method_getImplementation(bundleIdMethod);
        method_setImplementation(bundleIdMethod, (IMP)hooked_bundleIdentifier);
        CFLOG(@"Patched NSBundle.bundleIdentifier");
    }

    // ── Fix 2: Fake group container ──
    Class fmClass = [NSFileManager class];
    Method containerMethod = class_getInstanceMethod(fmClass,
        @selector(containerURLForSecurityApplicationGroupIdentifier:));
    if (containerMethod) {
        orig_containerURL = (NSURL *(*)(id, SEL, NSString *))method_getImplementation(containerMethod);
        method_setImplementation(containerMethod, (IMP)hooked_containerURL);
        CFLOG(@"Patched NSFileManager.containerURLForSecurityApplicationGroupIdentifier:");
    }

    CFLOG(@"Sideload fixes applied. Spoofed bundle ID: %@", kOriginalBundleID);
}

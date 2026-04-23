#import <Cocoa/Cocoa.h>

#import "viewer_app.h"

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* startupPath = nil;
        if (argc > 1) {
            startupPath = [NSString stringWithUTF8String:argv[1]];
        }

        NSApplication* app = [NSApplication sharedApplication];
        ViewerAppDelegate* delegate = [[ViewerAppDelegate alloc] initWithStartupPath:startupPath];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app run];
    }
    return 0;
}

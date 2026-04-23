#ifndef VIEWER_APP_H
#define VIEWER_APP_H

#import <Cocoa/Cocoa.h>

@interface ViewerAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>

- (instancetype)initWithStartupPath:(NSString*)startupPath;

@end

#endif

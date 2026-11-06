#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

static NSString *gInboxPath = nil;
static NSPanel *gNotchPanel = nil;
static NSView *gDropContainer = nil;
static NSTextField *gLabelField = nil;
static BOOL gNotchVisible = NO;
static NSInteger gLastDragChangeCount = -1;
static EventHotKeyRef gHotKeyRef = NULL;

static void KestrelAppendEvent(NSDictionary *dict) {
  if (!gInboxPath) return;
  NSError *err = nil;
  NSData *json = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
  if (!json || err) return;
  NSMutableData *line = [json mutableCopy];
  [line appendBytes:"\n" length:1];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:gInboxPath]) {
    [line writeToFile:gInboxPath atomically:YES];
  } else {
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gInboxPath];
    if (fh) {
      [fh seekToEndOfFile];
      [fh writeData:line];
      [fh closeFile];
    } else {
      [line writeToFile:gInboxPath atomically:YES];
    }
  }
}

static void KestrelTriggerScreenshotAsk(void) {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *tempDir = NSTemporaryDirectory();
    long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
    NSString *path = [tempDir stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"kestrel_notch_shot_%lld.png", ts]];
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/sbin/screencapture";
    task.arguments = @[@"-i", @"-x", path];
    @try {
      [task launch];
      [task waitUntilExit];
    } @catch (NSException *exception) {
      return;
    }
    if (task.terminationStatus != 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (!attrs || [attrs fileSize] == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp activateIgnoringOtherApps:YES];
      for (NSWindow *win in [NSApp windows]) {
        if (win != gNotchPanel && [win canBecomeMainWindow]) {
          [win makeKeyAndOrderFront:nil];
          break;
        }
      }
      KestrelAppendEvent(@{
        @"type": @"screenshot",
        @"files": @[path]
      });
    });
  });
}

static OSStatus KestrelHotKeyHandler(EventHandlerCallRef nextHandler,
                                     EventRef theEvent,
                                     void *userData) {
  KestrelTriggerScreenshotAsk();
  return noErr;
}

@interface KestrelNotchDropView : NSView
@property (nonatomic, assign) BOOL highlight;
@end

@implementation KestrelNotchDropView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    [self registerForDraggedTypes:@[
      NSPasteboardTypeFileURL,
      NSPasteboardTypePNG,
      NSPasteboardTypeTIFF,
      NSPasteboardTypeString
    ]];
  }
  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  NSRect bounds = NSInsetRect(self.bounds, 1.5, 1.5);
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:18 yRadius:18];
  if (self.highlight) {
    [[NSColor colorWithSRGBRed:0.85 green:0.46 blue:0.34 alpha:0.96] setFill];
    [path fill];
    [[NSColor colorWithSRGBRed:1.0 green:0.85 blue:0.78 alpha:0.95] setStroke];
    path.lineWidth = 2.0;
    [path stroke];
  } else {
    [[NSColor colorWithSRGBRed:0.12 green:0.12 blue:0.14 alpha:0.92] setFill];
    [path fill];
    [[NSColor colorWithSRGBRed:0.85 green:0.46 blue:0.34 alpha:0.80] setStroke];
    path.lineWidth = 1.5;
    [path stroke];
  }
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  self.highlight = YES;
  gLabelField.stringValue = @"✨ 松开鼠标，立即投喂给 Kestrel";
  [self setNeedsDisplay:YES];
  return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  self.highlight = NO;
  gLabelField.stringValue = @"📥 拖入 Kestrel 提问 · ⌃⇧A 截图";
  [self setNeedsDisplay:YES];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  self.highlight = NO;
  gLabelField.stringValue = @"📥 拖入 Kestrel 提问 · ⌃⇧A 截图";
  [self setNeedsDisplay:YES];

  NSPasteboard *pb = [sender draggingPasteboard];
  NSMutableArray<NSString *> *filePaths = [NSMutableArray array];

  NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[[NSURL class]]
                                             options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  for (NSURL *url in urls) {
    if (url.path.length > 0) {
      [filePaths addObject:url.path];
    }
  }

  if (filePaths.count == 0) {
    NSData *png = [pb dataForType:NSPasteboardTypePNG];
    if (!png) {
      NSData *tiff = [pb dataForType:NSPasteboardTypeTIFF];
      if (tiff) {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:tiff];
        png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      }
    }
    if (png.length > 0) {
      long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
      NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"kestrel_drop_%lld.png", ts]];
      if ([png writeToFile:tempPath atomically:YES]) {
        [filePaths addObject:tempPath];
      }
    }
  }

  NSString *droppedText = nil;
  if (filePaths.count == 0) {
    droppedText = [pb stringForType:NSPasteboardTypeString];
  }

  if (filePaths.count > 0 || (droppedText && droppedText.length > 0)) {
    [NSApp activateIgnoringOtherApps:YES];
    for (NSWindow *win in [NSApp windows]) {
      if (win != gNotchPanel && [win canBecomeMainWindow]) {
        [win makeKeyAndOrderFront:nil];
        break;
      }
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"type"] = @"drop";
    if (filePaths.count > 0) payload[@"files"] = filePaths;
    if (droppedText.length > 0) payload[@"text"] = droppedText;
    KestrelAppendEvent(payload);
    return YES;
  }
  return NO;
}

@end

static void KestrelShowNotch(BOOL show) {
  if (!gNotchPanel || gNotchVisible == show) return;
  gNotchVisible = show;
  NSScreen *screen = [NSScreen mainScreen];
  if (!screen) return;
  NSRect visible = screen.visibleFrame;
  CGFloat width = 264;
  CGFloat height = 38;
  CGFloat x = NSMidX(screen.frame) - width / 2.0;
  CGFloat shownY = NSMaxY(visible) - height - 6.0;
  CGFloat hiddenY = NSMaxY(screen.frame) + 4.0;

  if (show) {
    [gNotchPanel setFrame:NSMakeRect(x, hiddenY, width, height) display:NO];
    gNotchPanel.alphaValue = 0.0;
    gNotchPanel.ignoresMouseEvents = NO;
    [gNotchPanel orderFrontRegardless];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      context.duration = 0.18;
      [[gNotchPanel animator] setFrame:NSMakeRect(x, shownY, width, height) display:YES];
      [[gNotchPanel animator] setAlphaValue:1.0];
    } completionHandler:nil];
  } else {
    gNotchPanel.ignoresMouseEvents = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
      context.duration = 0.15;
      [[gNotchPanel animator] setFrame:NSMakeRect(x, hiddenY, width, height) display:YES];
      [[gNotchPanel animator] setAlphaValue:0.0];
    } completionHandler:^{
      if (!gNotchVisible) {
        [gNotchPanel orderOut:nil];
      }
    }];
  }
}

static void KestrelHandleDragEvent(void) {
  NSScreen *screen = [NSScreen mainScreen];
  if (!screen) return;
  NSPoint mouse = [NSEvent mouseLocation];
  CGFloat midX = NSMidX(screen.frame);
  CGFloat topY = NSMaxY(screen.frame);
  BOOL nearTopCenter = (mouse.y >= topY - 120.0) && (fabs(mouse.x - midX) <= 260.0);
  NSPasteboard *dragPb = [NSPasteboard pasteboardWithName:NSPasteboardNameDrag];
  BOOL hasDragData = (dragPb.pasteboardItems.count > 0);
  if (nearTopCenter && hasDragData) {
    KestrelShowNotch(YES);
  } else if (gNotchVisible && mouse.y < topY - 150.0) {
    KestrelShowNotch(NO);
  }
}

__attribute__((visibility("default")))
void KestrelNotchInit(const char *inboxPathCString) {
  if (!inboxPathCString) return;
  NSString *path = [NSString stringWithUTF8String:inboxPathCString];
  dispatch_async(dispatch_get_main_queue(), ^{
    gInboxPath = [path copy];
    if (gNotchPanel != nil) return;

    CGFloat width = 264;
    CGFloat height = 38;
    gNotchPanel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    gNotchPanel.opaque = NO;
    gNotchPanel.backgroundColor = [NSColor clearColor];
    gNotchPanel.hasShadow = YES;
    gNotchPanel.level = NSStatusWindowLevel + 1;
    gNotchPanel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorFullScreenAuxiliary |
        NSWindowCollectionBehaviorStationary;
    gNotchPanel.ignoresMouseEvents = YES;
    gNotchPanel.alphaValue = 0.0;

    KestrelNotchDropView *dropView =
        [[KestrelNotchDropView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    dropView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 9, width - 24, 20)];
    label.stringValue = @"📥 拖入 Kestrel 提问 · ⌃⇧A 截图";
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor whiteColor];
    label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold];
    [dropView addSubview:label];

    gDropContainer = dropView;
    gLabelField = label;
    gNotchPanel.contentView = dropView;

    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged
                                           handler:^(NSEvent *event) {
      KestrelHandleDragEvent();
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDragged
                                          handler:^NSEvent *(NSEvent *event) {
      KestrelHandleDragEvent();
      return event;
    }];
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                           handler:^(NSEvent *event) {
      if (gNotchVisible) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          KestrelShowNotch(NO);
        });
      }
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *event) {
      if (gNotchVisible) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          KestrelShowNotch(NO);
        });
      }
      return event;
    }];

    // Register global hotkey Control + Shift + A (keyCode 0x00 = 'A')
    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind = kEventHotKeyPressed;
    InstallApplicationEventHandler(&KestrelHotKeyHandler, 1, &eventType, NULL, NULL);
    EventHotKeyID hotKeyID;
    hotKeyID.signature = 'KSTL';
    hotKeyID.id = 1;
    RegisterEventHotKey(0x00, controlKey | shiftKey, hotKeyID,
                        GetApplicationEventTarget(), 0, &gHotKeyRef);
  });
}

__attribute__((visibility("default")))
void KestrelNotchInitDefault(void) {
  NSString *inbox = [NSTemporaryDirectory() stringByAppendingPathComponent:@"kestrel_notch_inbox.jsonl"];
  KestrelNotchInit([inbox UTF8String]);
}

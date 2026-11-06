#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *gInboxPath = nil;
static NSString *gStatusPath = nil;
static NSPanel *gNotchPanel = nil;
static NSView *gDropContainer = nil;
static NSTextField *gLabelField = nil;
static BOOL gNotchVisible = NO;
static BOOL gDraggingNearTop = NO;
static BOOL gIslandActive = NO;
static EventHotKeyRef gHotKeyScreenshotRef = NULL;
static EventHotKeyRef gHotKeySelectionRef = NULL;

// PiP Mini Monitor window & controls
static NSPanel *gPipPanel = nil;
static NSTextField *gPipTitleField = nil;
static NSTextField *gPipStatusField = nil;
static NSTextField *gPipDetailField = nil;
static NSButton *gPipApproveBtn = nil;
static BOOL gPipVisible = NO;
static NSTimer *gStatusPollTimer = nil;

static void KestrelActivateMainWindow(void) {
  [NSApp activateIgnoringOtherApps:YES];
  for (NSWindow *win in [NSApp windows]) {
    if (win != gNotchPanel && win != gPipPanel && [win canBecomeMainWindow]) {
      [win makeKeyAndOrderFront:nil];
      break;
    }
  }
}

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
      KestrelActivateMainWindow();
      KestrelAppendEvent(@{
        @"type": @"screenshot",
        @"files": @[path]
      });
    });
  });
}

static void KestrelTriggerGrabSelection(void) {
  // Synthesize Cmd+C in the currently active application to grab highlighted text
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  if (src) {
    CGEventRef cmdCDown = CGEventCreateKeyboardEvent(src, (CGKeyCode)0x08, true); // 'c' = 0x08
    CGEventRef cmdCUp = CGEventCreateKeyboardEvent(src, (CGKeyCode)0x08, false);
    if (cmdCDown && cmdCUp) {
      CGEventSetFlags(cmdCDown, kCGEventFlagMaskCommand);
      CGEventSetFlags(cmdCUp, kCGEventFlagMaskCommand);
      CGEventPost(kCGHIDEventTap, cmdCDown);
      CGEventPost(kCGHIDEventTap, cmdCUp);
    }
    if (cmdCDown) CFRelease(cmdCDown);
    if (cmdCUp) CFRelease(cmdCUp);
    CFRelease(src);
  }

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.14 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *grabbed = [pb stringForType:NSPasteboardTypeString];
    KestrelActivateMainWindow();
    if (grabbed && grabbed.length > 0) {
      KestrelAppendEvent(@{
        @"type": @"selection",
        @"text": grabbed
      });
    }
  });
}

static OSStatus KestrelHotKeyHandler(EventHandlerCallRef nextHandler,
                                     EventRef theEvent,
                                     void *userData) {
  EventHotKeyID hkCom;
  OSStatus status = GetEventParameter(theEvent,
                                      kEventParamDirectObject,
                                      typeEventHotKeyID,
                                      NULL,
                                      sizeof(hkCom),
                                      NULL,
                                      &hkCom);
  if (status == noErr && hkCom.id == 2) {
    KestrelTriggerGrabSelection();
  } else {
    KestrelTriggerScreenshotAsk();
  }
  return noErr;
}

@interface KestrelNotchDropView : NSView
@property (nonatomic, assign) BOOL highlight;
@property (nonatomic, assign) BOOL isLiveActivity;
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

- (void)mouseDown:(NSEvent *)event {
  KestrelActivateMainWindow();
  KestrelAppendEvent(@{@"type": @"focus_active"});
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
  } else if (self.isLiveActivity) {
    [[NSColor colorWithSRGBRed:0.09 green:0.10 blue:0.12 alpha:0.95] setFill];
    [path fill];
    [[NSColor colorWithSRGBRed:0.34 green:0.72 blue:0.56 alpha:0.85] setStroke];
    path.lineWidth = 1.4;
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
  gLabelField.stringValue = @"✨ 松开鼠标，立即投喂给 Byte";
  [self setNeedsDisplay:YES];
  return NSDragOperationCopy;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  self.highlight = NO;
  gLabelField.stringValue = @"📥 拖入提问 · ⌃⇧A 截图 · ⌃⇧S 划词";
  [self setNeedsDisplay:YES];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  self.highlight = NO;
  gLabelField.stringValue = @"📥 拖入提问 · ⌃⇧A 截图 · ⌃⇧S 划词";
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
    KestrelActivateMainWindow();
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

@interface KestrelPipCardView : NSView
@end

@implementation KestrelPipCardView
- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  NSRect bounds = NSInsetRect(self.bounds, 1.0, 1.0);
  NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:14 yRadius:14];
  [[NSColor colorWithSRGBRed:0.11 green:0.12 blue:0.14 alpha:0.94] setFill];
  [path fill];
  [[NSColor colorWithSRGBRed:0.85 green:0.46 blue:0.34 alpha:0.65] setStroke];
  path.lineWidth = 1.2;
  [path stroke];
}
@end

@interface KestrelPipActionTarget : NSObject
- (void)onFocusMain:(id)sender;
- (void)onApprove:(id)sender;
- (void)onClosePip:(id)sender;
- (void)onScreenshot:(id)sender;
@end

@implementation KestrelPipActionTarget
- (void)onFocusMain:(id)sender {
  KestrelActivateMainWindow();
  KestrelAppendEvent(@{@"type": @"focus_active"});
}
- (void)onApprove:(id)sender {
  KestrelAppendEvent(@{@"type": @"approve_active"});
}
- (void)onClosePip:(id)sender {
  gPipVisible = NO;
  [gPipPanel orderOut:nil];
  KestrelAppendEvent(@{@"type": @"close_pip"});
}
- (void)onScreenshot:(id)sender {
  KestrelTriggerScreenshotAsk();
}
@end

static KestrelPipActionTarget *gPipTarget = nil;

static void KestrelShowNotch(BOOL show) {
  if (!gNotchPanel || gNotchVisible == show) return;
  gNotchVisible = show;
  NSScreen *screen = [NSScreen mainScreen];
  if (!screen) return;
  NSRect visible = screen.visibleFrame;
  CGFloat width = 310;
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
    gDraggingNearTop = YES;
    KestrelNotchDropView *dv = (KestrelNotchDropView *)gDropContainer;
    dv.isLiveActivity = NO;
    gLabelField.stringValue = @"📥 拖入提问 · ⌃⇧A 截图 · ⌃⇧S 划词";
    [dv setNeedsDisplay:YES];
    KestrelShowNotch(YES);
  } else if (gDraggingNearTop && mouse.y < topY - 150.0) {
    gDraggingNearTop = NO;
    if (!gIslandActive) {
      KestrelShowNotch(NO);
    }
  }
}

static void KestrelPollStatusFile(void) {
  if (!gStatusPath) return;
  NSData *data = [NSData dataWithContentsOfFile:gStatusPath];
  if (!data || data.length == 0) return;
  NSDictionary *status = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![status isKindOfClass:[NSDictionary class]]) return;

  // 1. Dynamic Island Live Activity (#22)
  NSString *islandText = status[@"islandText"];
  BOOL wantsIsland = [status[@"islandActive"] boolValue] &&
                     [islandText isKindOfClass:[NSString class]] &&
                     islandText.length > 0;
  gIslandActive = wantsIsland;
  if (!gDraggingNearTop) {
    KestrelNotchDropView *dv = (KestrelNotchDropView *)gDropContainer;
    if (wantsIsland) {
      dv.isLiveActivity = YES;
      gLabelField.stringValue = islandText;
      [dv setNeedsDisplay:YES];
      KestrelShowNotch(YES);
    } else {
      dv.isLiveActivity = NO;
      KestrelShowNotch(NO);
    }
  }

  // 2. Top-Right PiP Mini Monitor (#23)
  BOOL wantsPip = [status[@"pipVisible"] boolValue];
  if (wantsPip != gPipVisible) {
    gPipVisible = wantsPip;
    if (wantsPip) {
      NSScreen *screen = [NSScreen mainScreen];
      if (screen && !gPipPanel.isVisible) {
        NSRect visible = screen.visibleFrame;
        CGFloat w = gPipPanel.frame.size.width;
        CGFloat h = gPipPanel.frame.size.height;
        [gPipPanel setFrameOrigin:NSMakePoint(NSMaxX(visible) - w - 18.0,
                                              NSMaxY(visible) - h - 18.0)];
      }
      [gPipPanel orderFrontRegardless];
    } else {
      [gPipPanel orderOut:nil];
    }
  }

  if (gPipVisible) {
    NSString *title = status[@"pipTitle"];
    NSString *badge = status[@"pipStatus"];
    NSString *detail = status[@"pipDetail"];
    BOOL needsApproval = [status[@"needsApproval"] boolValue];
    if ([title isKindOfClass:[NSString class]]) {
      gPipTitleField.stringValue = title;
    }
    if ([badge isKindOfClass:[NSString class]]) {
      gPipStatusField.stringValue = badge;
    }
    if ([detail isKindOfClass:[NSString class]]) {
      gPipDetailField.stringValue = detail;
    }
    gPipApproveBtn.hidden = !needsApproval;
  }
}

static NSButton *KestrelMakePillButton(NSRect frame, NSString *title, SEL action) {
  NSButton *btn = [[NSButton alloc] initWithFrame:frame];
  btn.title = title;
  btn.bezelStyle = NSBezelStyleRoundRect;
  btn.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  btn.target = gPipTarget;
  btn.action = action;
  return btn;
}

static void KestrelSetupPipPanel(void) {
  if (gPipPanel != nil) return;
  gPipTarget = [[KestrelPipActionTarget alloc] init];
  CGFloat width = 288;
  CGFloat height = 112;
  gPipPanel = [[NSPanel alloc]
      initWithContentRect:NSMakeRect(0, 0, width, height)
                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:NO];
  gPipPanel.opaque = NO;
  gPipPanel.backgroundColor = [NSColor clearColor];
  gPipPanel.hasShadow = YES;
  gPipPanel.level = NSFloatingWindowLevel;
  gPipPanel.movableByWindowBackground = YES;
  gPipPanel.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces |
      NSWindowCollectionBehaviorFullScreenAuxiliary;

  KestrelPipCardView *card = [[KestrelPipCardView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];

  gPipTitleField = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 82, 168, 18)];
  gPipTitleField.stringValue = @"🦅 Byte 盯盘小窗";
  gPipTitleField.editable = NO;
  gPipTitleField.selectable = NO;
  gPipTitleField.bezeled = NO;
  gPipTitleField.drawsBackground = NO;
  gPipTitleField.textColor = [NSColor whiteColor];
  gPipTitleField.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightBold];
  gPipTitleField.lineBreakMode = NSLineBreakByTruncatingTail;
  [card addSubview:gPipTitleField];

  gPipStatusField = [[NSTextField alloc] initWithFrame:NSMakeRect(182, 82, 74, 18)];
  gPipStatusField.stringValue = @"⚪ 待命";
  gPipStatusField.editable = NO;
  gPipStatusField.selectable = NO;
  gPipStatusField.bezeled = NO;
  gPipStatusField.drawsBackground = NO;
  gPipStatusField.alignment = NSTextAlignmentRight;
  gPipStatusField.textColor = [NSColor colorWithSRGBRed:0.85 green:0.86 blue:0.88 alpha:1.0];
  gPipStatusField.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
  [card addSubview:gPipStatusField];

  NSButton *closeBtn = [[NSButton alloc] initWithFrame:NSMakeRect(260, 82, 20, 18)];
  closeBtn.title = @"✕";
  closeBtn.bordered = NO;
  closeBtn.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightBold];
  closeBtn.contentTintColor = [NSColor lightGrayColor];
  closeBtn.target = gPipTarget;
  closeBtn.action = @selector(onClosePip:);
  [card addSubview:closeBtn];

  gPipDetailField = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 44, width - 24, 34)];
  gPipDetailField.stringValue = @"实时监控后台任务进度与权限确认…";
  gPipDetailField.editable = NO;
  gPipDetailField.selectable = NO;
  gPipDetailField.bezeled = NO;
  gPipDetailField.drawsBackground = NO;
  gPipDetailField.textColor = [NSColor colorWithSRGBRed:0.76 green:0.78 blue:0.82 alpha:1.0];
  gPipDetailField.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
  gPipDetailField.maximumNumberOfLines = 2;
  gPipDetailField.lineBreakMode = NSLineBreakByTruncatingTail;
  [card addSubview:gPipDetailField];

  NSButton *focusBtn = KestrelMakePillButton(NSMakeRect(12, 10, 78, 24), @"切回主窗", @selector(onFocusMain:));
  [card addSubview:focusBtn];

  NSButton *shotBtn = KestrelMakePillButton(NSMakeRect(96, 10, 78, 24), @"📸 截图问", @selector(onScreenshot:));
  [card addSubview:shotBtn];

  gPipApproveBtn = KestrelMakePillButton(NSMakeRect(180, 10, 96, 24), @"✅ 允许执行", @selector(onApprove:));
  gPipApproveBtn.hidden = YES;
  [card addSubview:gPipApproveBtn];

  gPipPanel.contentView = card;
}

__attribute__((visibility("default")))
void KestrelNotchInit(const char *inboxPathCString) {
  if (!inboxPathCString) return;
  NSString *path = [NSString stringWithUTF8String:inboxPathCString];
  dispatch_async(dispatch_get_main_queue(), ^{
    gInboxPath = [path copy];
    gStatusPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"kestrel_live_status.json"] copy];
    if (gNotchPanel != nil) return;

    // Ensure macOS menu bar & window titles say "Byte"
    NSMenu *mainMenu = [NSApp mainMenu];
    if (mainMenu && mainMenu.numberOfItems > 0) {
      NSMenuItem *appItem = [mainMenu itemAtIndex:0];
      appItem.title = @"Byte";
      NSMenu *appSubmenu = appItem.submenu;
      if (appSubmenu) {
        appSubmenu.title = @"Byte";
        for (NSMenuItem *sub in appSubmenu.itemArray) {
          if ([sub.title containsString:@"Kestrel"]) {
            sub.title = [sub.title stringByReplacingOccurrencesOfString:@"Kestrel" withString:@"Byte"];
          }
        }
      }
    }
    for (NSWindow *win in [NSApp windows]) {
      if ([win.title isEqualToString:@"Kestrel"]) {
        win.title = @"Byte";
      }
    }

    CGFloat width = 310;
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
    label.stringValue = @"📥 拖入提问 · ⌃⇧A 截图 · ⌃⇧S 划词";
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.alignment = NSTextAlignmentCenter;
    label.textColor = [NSColor whiteColor];
    label.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightSemibold];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    [dropView addSubview:label];

    gDropContainer = dropView;
    gLabelField = label;
    gNotchPanel.contentView = dropView;

    KestrelSetupPipPanel();

    gStatusPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                       repeats:YES
                                                         block:^(NSTimer * _Nonnull timer) {
      KestrelPollStatusFile();
    }];

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
      if (gDraggingNearTop) {
        gDraggingNearTop = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          if (!gIslandActive) KestrelShowNotch(NO);
        });
      }
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp
                                          handler:^NSEvent *(NSEvent *event) {
      if (gDraggingNearTop) {
        gDraggingNearTop = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
          if (!gIslandActive) KestrelShowNotch(NO);
        });
      }
      return event;
    }];

    // Register global hotkeys:
    // 1. Control + Shift + A (keyCode 0x00 = 'A') -> Screenshot to Ask
    // 2. Control + Shift + S (keyCode 0x01 = 'S') -> Grab Selection from Any App
    EventTypeSpec eventType;
    eventType.eventClass = kEventClassKeyboard;
    eventType.eventKind = kEventHotKeyPressed;
    InstallApplicationEventHandler(&KestrelHotKeyHandler, 1, &eventType, NULL, NULL);

    EventHotKeyID hotKeyScreenshotID;
    hotKeyScreenshotID.signature = 'KSTL';
    hotKeyScreenshotID.id = 1;
    RegisterEventHotKey(0x00, controlKey | shiftKey, hotKeyScreenshotID,
                        GetApplicationEventTarget(), 0, &gHotKeyScreenshotRef);

    EventHotKeyID hotKeySelectionID;
    hotKeySelectionID.signature = 'KSTL';
    hotKeySelectionID.id = 2;
    RegisterEventHotKey(0x01, controlKey | shiftKey, hotKeySelectionID,
                        GetApplicationEventTarget(), 0, &gHotKeySelectionRef);
  });
}

__attribute__((visibility("default")))
void KestrelNotchInitDefault(void) {
  NSString *inbox = [NSTemporaryDirectory() stringByAppendingPathComponent:@"kestrel_notch_inbox.jsonl"];
  KestrelNotchInit([inbox UTF8String]);
}

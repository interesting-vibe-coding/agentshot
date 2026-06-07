// AgentShot — token-lean macOS screenshot compressor (Objective-C).
//
// Features: global hotkey (default F1, configurable) -> native region capture ->
// post-capture preview where C/Return copies the compressed image and ⇧C copies
// the original; first-run onboarding (launch-at-login + shortcut + permission);
// menubar tier/shortcut settings. Pure native macOS, zero third-party deps.
// Build with clang (see build.sh).

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UTCoreTypes.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <objc/runtime.h>

// MARK: - Config / persisted settings
static const NSInteger kDefaultEdge = 1568;          // default long-edge cap
static const NSInteger kByteLimit   = 1000 * 1024;   // hard cap: < 1000KB (always)
static const CGFloat   kQ[]         = {0.82, 0.72, 0.62, 0.52, 0.42, 0.34};
static const NSInteger kQn          = 6;
static const NSInteger kFallback[]  = {1280, 1024, 832};

static NSString * const kEdgeKey   = @"maxLongEdge";
static NSString * const kHKCodeKey = @"hotKeyCode";
static NSString * const kHKModKey  = @"hotKeyMods";
static NSString * const kOnboardedKey = @"didOnboard";

static NSInteger CurrentMaxEdge(void) {
    NSInteger v = [[NSUserDefaults standardUserDefaults] integerForKey:kEdgeKey];
    return v > 0 ? v : kDefaultEdge;
}
static UInt32 CurrentHKCode(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kHKCodeKey];
    return v ? (UInt32)[v integerValue] : (UInt32)kVK_F1;   // default F1
}
static UInt32 CurrentHKMods(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kHKModKey];
    return v ? (UInt32)[v integerValue] : 0;
}
// Human-readable shortcut label, e.g. "F1" or "⌘⇧2".
static NSString *ShortcutLabel(UInt32 code, UInt32 mods) {
    NSMutableString *s = [NSMutableString string];
    if (mods & controlKey) [s appendString:@"⌃"];
    if (mods & optionKey)  [s appendString:@"⌥"];
    if (mods & shiftKey)   [s appendString:@"⇧"];
    if (mods & cmdKey)     [s appendString:@"⌘"];
    NSDictionary *names = @{ @(kVK_F1):@"F1", @(kVK_F2):@"F2", @(kVK_F3):@"F3",
                            @(kVK_ANSI_2):@"2", @(kVK_ANSI_3):@"3", @(kVK_ANSI_5):@"5" };
    [s appendString:(names[@(code)] ?: [NSString stringWithFormat:@"key%u", code])];
    return s;
}

// MARK: - Compression
typedef struct { NSInteger outW,outH,srcW,srcH,srcBytes; CGFloat quality; BOOL ok; } ShotInfo;

static CGImageRef CreateDownscaled(CGImageSourceRef src, NSInteger maxEdge) {
    NSDictionary *o = @{ (id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                         (id)kCGImageSourceCreateThumbnailWithTransform:@YES,
                         (id)kCGImageSourceThumbnailMaxPixelSize:@(maxEdge) };
    return CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)o);
}
static NSData *EncodeJPEG(CGImageRef img, CGFloat q) {
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef d = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
    if (!d) return nil;
    CGImageDestinationAddImage(d, img, (__bridge CFDictionaryRef)
        @{ (id)kCGImageDestinationLossyCompressionQuality:@(q) });
    BOOL ok = CGImageDestinationFinalize(d); CFRelease(d);
    return ok ? out : nil;
}
static NSData *ProcessImage(NSURL *url, ShotInfo *info) {
    info->ok = NO;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;
    NSDictionary *p = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(src,0,NULL);
    info->srcW = [p[(id)kCGImagePropertyPixelWidth] integerValue];
    info->srcH = [p[(id)kCGImagePropertyPixelHeight] integerValue];
    info->srcBytes = (NSInteger)[[NSData dataWithContentsOfURL:url] length];

    NSData *best = nil; ShotInfo bi = *info;
    NSInteger maxEdge = CurrentMaxEdge();
    NSMutableArray<NSNumber*> *edges = [NSMutableArray arrayWithObject:@(maxEdge)];
    for (int i=0;i<3;i++) if (kFallback[i] < maxEdge) [edges addObject:@(kFallback[i])];
    for (NSNumber *en in edges) {
        CGImageRef img = CreateDownscaled(src, en.integerValue);
        if (!img) continue;
        NSInteger w = CGImageGetWidth(img), h = CGImageGetHeight(img);
        for (NSInteger qi=0; qi<kQn; qi++) {
            NSData *data = EncodeJPEG(img, kQ[qi]);
            if (!data) continue;
            best = data; bi = *info; bi.outW=w; bi.outH=h; bi.quality=kQ[qi]; bi.ok=YES;
            if ((NSInteger)data.length <= kByteLimit) {
                CGImageRelease(img); CFRelease(src); *info = bi; return data;
            }
        }
        CGImageRelease(img);
    }
    CFRelease(src); *info = bi; return best;
}

static void PutOnPasteboard(NSData *data, NSString *type) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setData:data forType:type];
}

// MARK: - HotKey (Carbon; re-registerable)
@interface HotKey : NSObject
- (void)reregisterCode:(UInt32)code mods:(UInt32)mods;
@end
@implementation HotKey {
    EventHotKeyRef _ref; BOOL _handlerInstalled;
}
static OSStatus HKHandler(EventHandlerCallRef n, EventRef e, void *ud);
- (void)reregisterCode:(UInt32)code mods:(UInt32)mods {
    if (!_handlerInstalled) {
        EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
        InstallEventHandler(GetApplicationEventTarget(), HKHandler, 1, &spec, NULL, NULL);
        _handlerInstalled = YES;
    }
    if (_ref) { UnregisterEventHotKey(_ref); _ref = NULL; }
    EventHotKeyID hkid = { 'ASHT', 1 };
    RegisterEventHotKey(code, mods, hkid, GetApplicationEventTarget(), 0, &_ref);
}
@end

// MARK: - App delegate
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) HotKey *hotKey;
@property (strong) NSPanel *preview;
@property (strong) NSWindow *onboard;
@property (strong) id keyMon;
@property (strong) NSData *compData;     // compressed JPEG of current shot
@property (strong) NSData *origData;     // original PNG bytes of current shot
@property (assign) ShotInfo info;
@property (strong) dispatch_block_t resetWork;
- (void)capture;
@end

static AppDelegate *gDelegate = nil;
static OSStatus HKHandler(EventHandlerCallRef n, EventRef e, void *ud) {
    (void)n;(void)e;(void)ud; [gDelegate capture]; return noErr;
}

@implementation AppDelegate

- (void)setIcon:(NSString *)symbol {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"AgentShot"];
    img.template = YES; self.statusItem.button.image = img; self.statusItem.button.title = @"";
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self setIcon:@"camera.viewfinder"];
    [self rebuildMenu];

    self.hotKey = [HotKey new];
    [self.hotKey reregisterCode:CurrentHKCode() mods:CurrentHKMods()];

    if (![[NSUserDefaults standardUserDefaults] boolForKey:kOnboardedKey])
        [self showOnboarding];
}

// ---- Menu ----
- (void)rebuildMenu {
    NSMenu *m = [[NSMenu alloc] init];
    NSString *sc = ShortcutLabel(CurrentHKCode(), CurrentHKMods());
    [m addItemWithTitle:[NSString stringWithFormat:@"Capture & compress  截图  (%@)", sc]
                 action:@selector(capture) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    // Shortcut submenu
    NSMenuItem *scItem = [[NSMenuItem alloc] initWithTitle:@"Shortcut  快捷键" action:nil keyEquivalent:@""];
    NSMenu *scMenu = [[NSMenu alloc] init];
    NSArray *opts = @[@[@"F1", @(kVK_F1), @0], @[@"F2", @(kVK_F2), @0],
                      @[@"⌘⇧2", @(kVK_ANSI_2), @(cmdKey|shiftKey)],
                      @[@"⌘⇧5", @(kVK_ANSI_5), @(cmdKey|shiftKey)]];
    UInt32 curCode = CurrentHKCode(), curMods = CurrentHKMods();
    for (NSArray *o in opts) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:o[0] action:@selector(setShortcut:) keyEquivalent:@""];
        it.tag = [o[1] integerValue];
        it.representedObject = o[2];
        it.state = ((UInt32)it.tag==curCode && (UInt32)[o[2] integerValue]==curMods) ? NSControlStateValueOn : NSControlStateValueOff;
        it.target = self; [scMenu addItem:it];
    }
    scItem.submenu = scMenu; [m addItem:scItem];

    // Quality submenu
    NSMenuItem *qItem = [[NSMenuItem alloc] initWithTitle:@"Quality  压缩档位" action:nil keyEquivalent:@""];
    NSMenu *qMenu = [[NSMenu alloc] init];
    NSArray *tiers = @[@[@"Max savings 极致省 · 1024px", @1024],
                       @[@"Balanced 平衡 · 1568px", @1568],
                       @[@"High fidelity 高保真 · 2560px", @2560]];
    NSInteger curEdge = CurrentMaxEdge();
    for (NSArray *t in tiers) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t[0] action:@selector(setTier:) keyEquivalent:@""];
        it.tag = [t[1] integerValue];
        it.state = (it.tag==curEdge) ? NSControlStateValueOn : NSControlStateValueOff;
        it.target = self; [qMenu addItem:it];
    }
    qItem.submenu = qMenu; [m addItem:qItem];

    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Launch at login  开机自启"
                          action:@selector(toggleLogin:) keyEquivalent:@""];
    login.state = [self loginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    login.target = self; [m addItem:login];

    [m addItem:[NSMenuItem separatorItem]];
    [[m addItemWithTitle:@"After capture: C copy · ⇧C original · Esc cancel" action:nil keyEquivalent:@""] setEnabled:NO];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItemWithTitle:@"Quit AgentShot" action:@selector(terminate:) keyEquivalent:@"q"];
    self.statusItem.menu = m;
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"AgentShot — 截图自动压缩 (%@)", sc];
}

- (void)setShortcut:(NSMenuItem *)sender {
    UInt32 code = (UInt32)sender.tag, mods = (UInt32)[sender.representedObject integerValue];
    [[NSUserDefaults standardUserDefaults] setInteger:code forKey:kHKCodeKey];
    [[NSUserDefaults standardUserDefaults] setInteger:mods forKey:kHKModKey];
    [self.hotKey reregisterCode:code mods:mods];
    [self rebuildMenu];
}
- (void)setTier:(NSMenuItem *)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:kEdgeKey];
    [self rebuildMenu];
}

// ---- Launch at login (SMAppService, macOS 13+) ----
- (BOOL)loginEnabled {
    if (@available(macOS 13.0, *)) return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    return NO;
}
- (void)setLogin:(BOOL)on {
    if (@available(macOS 13.0, *)) {
        NSError *err = nil;
        if (on) [SMAppService.mainAppService registerAndReturnError:&err];
        else    [SMAppService.mainAppService unregisterAndReturnError:&err];
        if (err) NSLog(@"[AgentShot] login item: %@", err.localizedDescription);
    }
}
- (void)toggleLogin:(NSMenuItem *)sender { [self setLogin:![self loginEnabled]]; [self rebuildMenu]; }

// ---- Capture flow ----
- (void)capture {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"agentshot-%@.png", [[NSUUID UUID] UUIDString]]];
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    t.arguments = @[@"-i", @"-o", tmp];
    __weak typeof(self) ws = self;
    t.terminationHandler = ^(NSTask *x){ (void)x; dispatch_async(dispatch_get_main_queue(), ^{ [ws handleCaptured:tmp]; }); };
    NSError *e=nil; if (![t launchAndReturnError:&e]) [self flash:@"✗ capture failed"];
}

- (void)handleCaptured:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;            // cancelled
    ShotInfo info; NSData *jpeg = ProcessImage([NSURL fileURLWithPath:path], &info);
    NSData *orig = [NSData dataWithContentsOfFile:path];
    [fm removeItemAtPath:path error:nil];
    if (!jpeg || !info.ok) { [self flash:@"✗ compress failed"]; return; }
    self.compData = jpeg; self.origData = orig; self.info = info;
    [self showPreviewWithJPEG:jpeg info:info];
}

// ---- Post-capture preview ----
- (void)showPreviewWithJPEG:(NSData *)jpeg info:(ShotInfo)info {
    [self closePreview];

    NSImage *thumb = [[NSImage alloc] initWithData:jpeg];
    CGFloat maxW = 460, maxH = 320;
    NSSize is = thumb.size; CGFloat r = MIN(maxW/is.width, maxH/is.height); r = MIN(r,1.0);
    NSSize ts = NSMakeSize(round(is.width*r), round(is.height*r));
    CGFloat pad = 16, barH = 30;
    NSRect frame = NSMakeRect(0,0, ts.width+pad*2, ts.height+pad*2+barH);

    NSPanel *p = [[NSPanel alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskUtilityWindow|NSWindowStyleMaskHUDWindow)
        backing:NSBackingStoreBuffered defer:NO];
    p.title = @"C / ↩ Copy   ·   ⇧C Original   ·   Esc Cancel";
    p.floatingPanel = YES; p.hidesOnDeactivate = NO;

    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(pad, pad+barH, ts.width, ts.height)];
    iv.image = thumb; iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    iv.wantsLayer = YES; iv.layer.cornerRadius = 6; iv.layer.masksToBounds = YES;
    [p.contentView addSubview:iv];

    NSInteger kb = (NSInteger)jpeg.length/1024, tok = info.outW*info.outH/750;
    NSTextField *lbl = [NSTextField labelWithString:
        [NSString stringWithFormat:@"%ld×%ld · %ldKB · ~%ld tok", (long)info.outW,(long)info.outH,(long)kb,(long)tok]];
    lbl.frame = NSMakeRect(pad, pad-2, ts.width, barH-6);
    lbl.alignment = NSTextAlignmentCenter; lbl.textColor = [NSColor secondaryLabelColor];
    lbl.font = [NSFont systemFontOfSize:11];
    [p.contentView addSubview:lbl];

    self.preview = p;
    [p center]; [NSApp activateIgnoringOtherApps:YES]; [p makeKeyAndOrderFront:nil];

    __weak typeof(self) ws = self;
    self.keyMon = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *ev){
        return [ws handlePreviewKey:ev];
    }];
}

- (NSEvent *)handlePreviewKey:(NSEvent *)ev {
    BOOL shift = (ev.modifierFlags & NSEventModifierFlagShift) != 0;
    switch (ev.keyCode) {
        case kVK_ANSI_C:
            if (shift) { PutOnPasteboard(self.origData, @"public.png"); [self flash:@"✓ original copied"]; }
            else       { PutOnPasteboard(self.compData, @"public.jpeg"); [self flashSaved]; }
            [self closePreview]; return nil;
        case kVK_Return: case kVK_ANSI_KeypadEnter:
            PutOnPasteboard(self.compData, @"public.jpeg"); [self flashSaved]; [self closePreview]; return nil;
        case kVK_Escape:
            [self closePreview]; return nil;
    }
    return ev;
}

- (void)closePreview {
    if (self.keyMon) { [NSEvent removeMonitor:self.keyMon]; self.keyMon = nil; }
    if (self.preview) { [self.preview close]; self.preview = nil; }
}

- (void)flashSaved {
    ShotInfo i = self.info;
    NSInteger st = i.srcW*i.srcH/750, ot = i.outW*i.outH/750;
    NSInteger saved = st>0 ? (NSInteger)(100.0*(1.0-(double)ot/st)) : 0;
    [self flash:[NSString stringWithFormat:@"✓ %ldKB · -%ld%% px", (long)self.compData.length/1024, (long)saved]];
}

- (void)flash:(NSString *)text {
    if (self.resetWork) dispatch_block_cancel(self.resetWork);
    self.statusItem.button.image = nil; self.statusItem.button.title = text;
    __weak typeof(self) ws = self;
    self.resetWork = dispatch_block_create(0, ^{ [ws setIcon:@"camera.viewfinder"]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)), dispatch_get_main_queue(), self.resetWork);
}

// ---- First-run onboarding ----
- (void)showOnboarding {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,460,330)
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable)
        backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Welcome to AgentShot";
    NSView *c = w.contentView;

    NSTextField *h = [NSTextField labelWithString:@"📸 AgentShot"];
    h.font = [NSFont boldSystemFontOfSize:22]; h.frame = NSMakeRect(28,272,400,32); [c addSubview:h];

    NSString *sc = ShortcutLabel(CurrentHKCode(), CurrentHKMods());
    NSTextField *body = [NSTextField wrappingLabelWithString:[NSString stringWithFormat:
        @"Snip a region and it's auto-compressed to the AI-vision sweet spot, then it's on your clipboard — ready to paste into any agent.\n\n"
         "• Shortcut:  %@   (change it in the menubar 📸 → Shortcut)\n"
         "• After a snip:  C / ↩ copy compressed · ⇧C copy original · Esc cancel\n"
         "• First capture asks for Screen Recording permission — allow it in System Settings, then re-open AgentShot.", sc]];
    body.frame = NSMakeRect(28,96,404,168); body.font = [NSFont systemFontOfSize:13]; [c addSubview:body];

    NSButton *login = [NSButton checkboxWithTitle:@"Launch AgentShot at login" target:nil action:nil];
    login.frame = NSMakeRect(26,56,400,22); login.state = NSControlStateValueOn; // default on
    [c addSubview:login];

    NSButton *start = [NSButton buttonWithTitle:@"Start" target:self action:@selector(finishOnboarding:)];
    start.frame = NSMakeRect(360,16,80,30); start.keyEquivalent = @"\r";
    start.bezelStyle = NSBezelStyleRounded; start.tag = (NSInteger)login.hash;
    [c addSubview:start];

    self.onboard = w;
    objc_setAssociatedObject(start, "loginBox", login, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [w center]; [NSApp activateIgnoringOtherApps:YES]; [w makeKeyAndOrderFront:nil];
}

- (void)finishOnboarding:(NSButton *)sender {
    NSButton *login = objc_getAssociatedObject(sender, "loginBox");
    if (login.state == NSControlStateValueOn) [self setLogin:YES];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kOnboardedKey];
    [self rebuildMenu];
    [self.onboard close]; self.onboard = nil;
}
@end

// MARK: - Entry (+ --selftest <img>)
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--selftest") == 0) {
            ShotInfo info; NSData *d = ProcessImage([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]], &info);
            if (!d || !info.ok) { fprintf(stderr,"selftest: failed\n"); return 1; }
            PutOnPasteboard(d, @"public.jpeg");
            NSInteger st=info.srcW*info.srcH/750, ot=info.outW*info.outH/750;
            printf("src %ldx%ld %ldKB ~%ld tok\nout %ldx%ld %ldKB ~%ld tok q%.2f\nsaved %ld%% ; <1000KB: %s\n",
                (long)info.srcW,(long)info.srcH,(long)info.srcBytes/1024,(long)st,
                (long)info.outW,(long)info.outH,(long)d.length/1024,(long)ot,info.quality,
                st?(long)(100*(1.0-(double)ot/st)):0, d.length<=kByteLimit?"YES":"NO");
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        gDelegate = [[AppDelegate alloc] init];
        app.delegate = gDelegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}

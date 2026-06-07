// AgentShot — token-lean macOS screenshot compressor (Objective-C port).
//
// Why ObjC: this machine's Swift toolchain has a compiler/SDK version mismatch
// that breaks `swiftc`, but `clang` + Objective-C compiles cleanly against the
// same frameworks. Functionally identical to Sources/AgentShot/main.swift.
//
// Build: see build.sh (clang -fobjc-arc ...). Single file, zero third-party deps.

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UTCoreTypes.h>
#import <Carbon/Carbon.h>

// MARK: - Config (token sweet spot + hard byte cap; see README)
static const NSInteger   kMaxLongEdge = 1568;        // Claude 1.15MP sweet spot
static const NSInteger   kByteLimit   = 1000 * 1024; // hard cap: < 1000KB
static const CGFloat     kStartQ      = 0.82;        // <1.3pp vision accuracy loss
static const CGFloat     kQ[]         = {0.82, 0.72, 0.62, 0.52, 0.42, 0.34};
static const NSInteger   kQn          = 6;
static const NSInteger   kEdges[]     = {1568, 1280, 1024, 832};
static const NSInteger   kEdgesN      = 4;

// MARK: - Compression result
typedef struct {
    NSInteger outW, outH, srcW, srcH, srcBytes;
    CGFloat   quality;
    BOOL      ok;
} ShotInfo;

// Downscale via ImageIO thumbnail (decodes at reduced resolution; no upscale).
static CGImageRef CreateDownscaled(CGImageSourceRef src, NSInteger maxEdge) {
    NSDictionary *opts = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform:   @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize:          @(maxEdge),
    };
    return CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
}

static NSData *EncodeJPEG(CGImageRef img, CGFloat quality) {
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dst = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, NULL);
    if (!dst) return nil;
    NSDictionary *props = @{ (id)kCGImageDestinationLossyCompressionQuality: @(quality) };
    CGImageDestinationAddImage(dst, img, (__bridge CFDictionaryRef)props);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst);
    return ok ? out : nil;
}

// Full pipeline: downscale -> quality/resolution backoff until < kByteLimit.
static NSData *ProcessImage(NSURL *url, ShotInfo *info) {
    info->ok = NO;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return nil;

    NSDictionary *p = (__bridge_transfer NSDictionary *)
        CGImageSourceCopyPropertiesAtIndex(src, 0, NULL);
    info->srcW = [p[(id)kCGImagePropertyPixelWidth] integerValue];
    info->srcH = [p[(id)kCGImagePropertyPixelHeight] integerValue];
    info->srcBytes = (NSInteger)[[NSData dataWithContentsOfURL:url] length];

    NSData *best = nil; ShotInfo bestInfo = *info;
    for (NSInteger e = 0; e < kEdgesN; e++) {
        CGImageRef img = CreateDownscaled(src, kEdges[e]);
        if (!img) continue;
        NSInteger w = CGImageGetWidth(img), h = CGImageGetHeight(img);
        for (NSInteger qi = 0; qi < kQn; qi++) {
            NSData *data = EncodeJPEG(img, kQ[qi]);
            if (!data) continue;
            best = data; bestInfo = *info;
            bestInfo.outW = w; bestInfo.outH = h; bestInfo.quality = kQ[qi]; bestInfo.ok = YES;
            if ((NSInteger)data.length <= kByteLimit) {
                CGImageRelease(img); CFRelease(src);
                *info = bestInfo; return data;
            }
        }
        CGImageRelease(img);
    }
    CFRelease(src);
    *info = bestInfo;
    return best; // smallest we managed (rare: couldn't hit the cap)
}

// MARK: - Clipboard (write raw JPEG bytes as public.jpeg only; no NSImage/TIFF bloat)
static void PutJPEGOnPasteboard(NSData *data) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setData:data forType:@"public.jpeg"];
}

// MARK: - App delegate
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) dispatch_block_t resetWork;
- (void)capture;
@end

static AppDelegate *gDelegate = nil; // for the Carbon C callback

static OSStatus HotKeyHandler(EventHandlerCallRef next, EventRef e, void *ud) {
    (void)next; (void)e; (void)ud;
    [gDelegate capture];
    return noErr;
}

@implementation AppDelegate

- (void)setIcon:(NSString *)symbol {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"AgentShot"];
    img.template = YES;
    self.statusItem.button.image = img;
    self.statusItem.button.title = @"";
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self setIcon:@"camera.viewfinder"];
    self.statusItem.button.toolTip = @"AgentShot — 截图自动压缩 (⌘⇧2)";

    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"截图并压缩  ⌘⇧2" action:@selector(capture) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [[menu addItemWithTitle:[NSString stringWithFormat:@"策略: 长边≤%ldpx · JPEG q%ld · <1000KB",
        (long)kMaxLongEdge, (long)(kStartQ*100)] action:nil keyEquivalent:@""] setEnabled:NO];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"退出 AgentShot" action:@selector(terminate:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;

    // ⌘⇧2 global hotkey (Carbon; no Accessibility permission needed)
    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallEventHandler(GetApplicationEventTarget(), HotKeyHandler, 1, &spec, NULL, NULL);
    EventHotKeyID hkid = { 'ASHT', 1 };
    EventHotKeyRef ref;
    RegisterEventHotKey(kVK_ANSI_2, cmdKey | shiftKey, hkid,
                        GetApplicationEventTarget(), 0, &ref);
}

- (void)capture {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"agentshot-%@.png", [[NSUUID UUID] UUIDString]]];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/screencapture"];
    task.arguments = @[@"-i", @"-o", tmp];           // interactive region/window, no shadow
    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *t) {
        (void)t;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handleCaptured:tmp]; });
    };
    NSError *err = nil;
    if (![task launchAndReturnError:&err]) { [self flash:@"✗ 截图失败"]; }
}

- (void)handleCaptured:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;          // user pressed Esc
    ShotInfo info;
    NSData *jpeg = ProcessImage([NSURL fileURLWithPath:path], &info);
    [fm removeItemAtPath:path error:nil];
    if (!jpeg || !info.ok) { [self flash:@"✗ 压缩失败"]; return; }
    PutJPEGOnPasteboard(jpeg);

    NSInteger srcTok = info.srcW * info.srcH / 750;
    NSInteger outTok = info.outW * info.outH / 750;
    NSInteger saved = srcTok > 0 ? (NSInteger)(100.0 * (1.0 - (double)outTok/srcTok)) : 0;
    NSInteger kb = (NSInteger)jpeg.length / 1024;
    NSLog(@"[AgentShot] ✓ %ldx%ld · %ldKB · ~%ld tok (省%ld%%)  src %ldx%ld %ldKB",
          (long)info.outW,(long)info.outH,(long)kb,(long)outTok,(long)saved,
          (long)info.srcW,(long)info.srcH,(long)info.srcBytes/1024);
    [self flash:[NSString stringWithFormat:@"✓ %ldKB · 省%ld%% 像素", (long)kb, (long)saved]];
}

- (void)flash:(NSString *)text {
    if (self.resetWork) dispatch_block_cancel(self.resetWork);
    self.statusItem.button.image = nil;
    self.statusItem.button.title = text;
    __weak typeof(self) weakSelf = self;
    self.resetWork = dispatch_block_create(0, ^{ [weakSelf setIcon:@"camera.viewfinder"]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), self.resetWork);
}
@end

// MARK: - Entry (+ hidden --selftest <imgfile> mode for verifying the pipeline)
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--selftest") == 0) {
            NSURL *u = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
            ShotInfo info; NSData *d = ProcessImage(u, &info);
            if (!d || !info.ok) { fprintf(stderr, "selftest: failed\n"); return 1; }
            PutJPEGOnPasteboard(d);
            NSInteger srcTok = info.srcW*info.srcH/750, outTok = info.outW*info.outH/750;
            printf("src   %ldx%ld  %ldKB  ~%ld tok\n",
                   (long)info.srcW,(long)info.srcH,(long)info.srcBytes/1024,(long)srcTok);
            printf("out   %ldx%ld  %ldKB  ~%ld tok  q%.2f\n",
                   (long)info.outW,(long)info.outH,(long)d.length/1024,(long)outTok,info.quality);
            printf("saved %ld%% pixel-tokens; bytes under 1000KB: %s; clipboard<-public.jpeg\n",
                   srcTok? (long)(100*(1.0-(double)outTok/srcTok)):0,
                   d.length<=kByteLimit?"YES":"NO");
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        gDelegate = [[AppDelegate alloc] init];
        app.delegate = gDelegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; // menubar only
        [app run];
    }
    return 0;
}

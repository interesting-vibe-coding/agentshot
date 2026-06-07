// AgentShot — token-lean macOS screenshot compressor (Objective-C).
//
// Global shortcut via a CGEventTap (consumes the key, so it overrides other apps
// like Snipaste — needs Accessibility permission) -> native region capture ->
// post-capture preview (C/↩ compressed · ⇧C original · Esc cancel). First-run
// onboarding lets you pick the shortcut and shows conflict/permission state.
// Menubar-only, zero third-party deps. Build with clang (see build.sh).

#import <Cocoa/Cocoa.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UTCoreTypes.h>
#import <Carbon/Carbon.h>
#import <ServiceManagement/ServiceManagement.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// MARK: - Config / persisted settings
static const NSInteger kDefaultEdge = 1568;
static const NSInteger kByteLimit   = 1000 * 1024;
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
    return v ? (UInt32)[v integerValue] : (UInt32)kVK_ANSI_2;   // default ⌘⇧2 — F-keys are media keys
                                                                // on most Macs and never reach a keyDown tap
}
static UInt32 CurrentHKMods(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kHKModKey];
    return v ? (UInt32)[v integerValue] : (UInt32)(cmdKey|shiftKey);   // default ⌘⇧2
}
static NSString *ShortcutLabel(UInt32 code, UInt32 mods) {
    NSMutableString *s = [NSMutableString string];
    if (mods & controlKey) [s appendString:@"⌃"];
    if (mods & optionKey)  [s appendString:@"⌥"];
    if (mods & shiftKey)   [s appendString:@"⇧"];
    if (mods & cmdKey)     [s appendString:@"⌘"];
    NSDictionary *names = @{ @(kVK_F1):@"F1", @(kVK_F2):@"F2",
                            @(kVK_ANSI_2):@"2", @(kVK_ANSI_5):@"5" };
    [s appendString:(names[@(code)] ?: [NSString stringWithFormat:@"key%u", code])];
    return s;
}
static CGEventFlags CGFlagsFromCarbon(UInt32 m) {
    CGEventFlags f = 0;
    if (m & cmdKey)     f |= kCGEventFlagMaskCommand;
    if (m & shiftKey)   f |= kCGEventFlagMaskShift;
    if (m & optionKey)  f |= kCGEventFlagMaskAlternate;
    if (m & controlKey) f |= kCGEventFlagMaskControl;
    return f;
}
static BOOL AXTrusted(BOOL prompt) {
    NSDictionary *o = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @(prompt) };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)o);
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
            if ((NSInteger)data.length <= kByteLimit) { CGImageRelease(img); CFRelease(src); *info=bi; return data; }
        }
        CGImageRelease(img);
    }
    CFRelease(src); *info = bi; return best;
}
static void PutOnPasteboard(NSData *data, NSString *type) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents]; [pb setData:data forType:type];
}

// MARK: - KeyTap (CGEventTap; consumes the key -> overrides other apps)
@class AppDelegate;
@interface KeyTap : NSObject
@property (assign) CGKeyCode code;
@property (assign) CGEventFlags flags;
@property (copy)   void (^onFire)(void);
@property (readonly, getter=isActive) BOOL active;
- (BOOL)restartWithCode:(CGKeyCode)c flags:(CGEventFlags)f;
@end

@implementation KeyTap {
    CFMachPortRef _tap; CFRunLoopSourceRef _src; BOOL _active;
}
- (BOOL)isActive { return _active; }
static CGEventRef TapCB(CGEventTapProxy proxy, CGEventType type, CGEventRef e, void *ud) {
    (void)proxy;
    KeyTap *kt = (__bridge KeyTap *)ud;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (kt->_tap) CGEventTapEnable(kt->_tap, true);
        return e;
    }
    if (type == kCGEventKeyDown) {
        CGKeyCode kc = (CGKeyCode)CGEventGetIntegerValueField(e, kCGKeyboardEventKeycode);
        CGEventFlags fl = CGEventGetFlags(e);
        if (getenv("ASDEBUG")) NSLog(@"[AS] keyDown kc=%d flags=0x%llx (want kc=%d flags=0x%llx)",
                                     kc, (unsigned long long)fl, kt.code, (unsigned long long)kt.flags);
        // F3 (keyCode 99): pin clipboard image
        if (kc == 99) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSApp delegate] performSelector:@selector(pinClipboard)];
            });
            return NULL;
        }
        CGEventFlags mask = kCGEventFlagMaskCommand|kCGEventFlagMaskShift|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl;
        if (kc == kt.code && (CGEventGetFlags(e) & mask) == kt.flags) {
            if (getenv("ASDEBUG")) NSLog(@"[AS] MATCH → firing capture");
            void (^fire)(void) = kt.onFire;
            if (fire) dispatch_async(dispatch_get_main_queue(), fire);
            return NULL;   // consume → steal from other apps (e.g. Snipaste)
        }
    } else if (getenv("ASDEBUG") && type == NSEventTypeSystemDefined) {
        NSLog(@"[AS] systemDefined event (a media/F-key like plain F1/brightness lands here, NOT keyDown)");
    }
    return e;
}
- (BOOL)restartWithCode:(CGKeyCode)c flags:(CGEventFlags)f {
    self.code = c; self.flags = f;
    if (_src) { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _src, kCFRunLoopCommonModes); CFRelease(_src); _src=NULL; }
    if (_tap) { CFMachPortInvalidate(_tap); CFRelease(_tap); _tap=NULL; }
    _active = NO;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    if (getenv("ASDEBUG")) mask |= CGEventMaskBit(NSEventTypeSystemDefined);  // observe media/F-keys
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, TapCB, (__bridge void *)self);
    if (!_tap) { if (getenv("ASDEBUG")) NSLog(@"[AS] CGEventTapCreate FAILED (not trusted?)"); return NO; }
    _src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _src, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    _active = YES;
    if (getenv("ASDEBUG")) NSLog(@"[AS] tap ACTIVE code=%d flags=0x%llx", c, (unsigned long long)f);
    return YES;
}
@end

// MARK: - PinView (double-click to close, scroll to zoom)
@interface PinView : NSImageView
@property (weak) NSPanel *pinPanel;
@property (weak) NSMutableArray *pinWindows;
@end
@implementation PinView
- (void)mouseDown:(NSEvent *)e {
    if (e.clickCount == 2) {
        [self.pinWindows removeObject:self.pinPanel];
        [self.pinPanel close];
    }
}
- (void)scrollWheel:(NSEvent *)e {
    CGFloat delta = e.scrollingDeltaY;
    if (e.hasPreciseScrollingDeltas) delta /= 5.0;
    NSRect f = self.pinPanel.frame;
    CGFloat scale = 1.0 + delta * 0.02;
    CGFloat nw = MAX(80, f.size.width * scale);
    CGFloat nh = MAX(60, f.size.height * scale);
    CGFloat dx = nw - f.size.width, dy = nh - f.size.height;
    f = NSMakeRect(f.origin.x - dx/2, f.origin.y - dy/2, nw, nh);
    [self.pinPanel setFrame:f display:YES animate:NO];
}
@end

// MARK: - Annotation
typedef NS_ENUM(NSInteger, AnnotTool) { AnnotRect=0, AnnotArrow, AnnotText, AnnotBlur, AnnotPencil };

@interface AnnotShape : NSObject
@property AnnotTool tool; @property NSPoint start,end; @property NSMutableArray<NSValue*>*points; @property NSString*text;
@end
@implementation AnnotShape
-(instancetype)init{self=[super init];_points=[NSMutableArray array];return self;}
@end

@interface AnnotView : NSView
@property (strong) NSImage *baseImage;
@property (strong) NSMutableArray<AnnotShape*> *shapes;
@property (strong) AnnotShape *live;
@property AnnotTool currentTool;
@end
@implementation AnnotView
-(instancetype)initWithFrame:(NSRect)f baseImage:(NSImage*)img{
    self=[super initWithFrame:f]; _baseImage=img; _shapes=[NSMutableArray array]; _currentTool=AnnotRect; return self;
}
-(BOOL)isFlipped{return YES;}
-(void)drawRect:(NSRect)r{
    [_baseImage drawInRect:self.bounds];
    [[NSColor colorWithRed:1 green:0.2 blue:0.2 alpha:1] set];
    for(AnnotShape*s in _shapes) [self drawShape:s];
    if(_live) [self drawShape:_live];
}
-(void)drawShape:(AnnotShape*)s{
    NSRect box=NSMakeRect(MIN(s.start.x,s.end.x),MIN(s.start.y,s.end.y),fabs(s.end.x-s.start.x),fabs(s.end.y-s.start.y));
    switch(s.tool){
        case AnnotRect:{
            NSBezierPath*p=[NSBezierPath bezierPathWithRect:box];
            [[NSColor colorWithRed:1 green:0.2 blue:0.2 alpha:0.15] set];[p fill];
            [[NSColor colorWithRed:1 green:0.2 blue:0.2 alpha:1] set];[p setLineWidth:2];[p stroke];break;
        }
        case AnnotArrow:{
            NSBezierPath*p=[NSBezierPath bezierPath];[p setLineWidth:2];
            [p moveToPoint:s.start];[p lineToPoint:s.end];
            CGFloat dx=s.end.x-s.start.x,dy=s.end.y-s.start.y,len=sqrt(dx*dx+dy*dy);
            if(len>0){CGFloat ux=dx/len,uy=dy/len,sz=10;
                NSPoint a1=NSMakePoint(s.end.x+(-ux+uy)*sz,s.end.y+(-uy-ux)*sz);
                NSPoint a2=NSMakePoint(s.end.x+(-ux-uy)*sz,s.end.y+(-uy+ux)*sz);
                [p moveToPoint:s.end];[p lineToPoint:a1];[p moveToPoint:s.end];[p lineToPoint:a2];}
            [[NSColor colorWithRed:1 green:0.2 blue:0.2 alpha:1] set];[p stroke];break;
        }
        case AnnotPencil:{
            if(s.points.count<2)break;
            NSBezierPath*p=[NSBezierPath bezierPath];[p setLineWidth:2];
            [p moveToPoint:[s.points[0] pointValue]];
            for(NSUInteger i=1;i<s.points.count;i++) [p lineToPoint:[s.points[i] pointValue]];
            [[NSColor colorWithRed:1 green:0.2 blue:0.2 alpha:1] set];[p stroke];break;
        }
        case AnnotText:{
            if(s.text.length){
                NSDictionary*attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:16],
                    NSForegroundColorAttributeName:[NSColor colorWithRed:1 green:0.2 blue:0.2 alpha:1]};
                [s.text drawAtPoint:s.start withAttributes:attrs];}break;
        }
        case AnnotBlur:{
            if(box.size.width<4||box.size.height<4)break;
            NSBitmapImageRep*rep=[self bitmapImageRepForCachingDisplayInRect:box];
            [self cacheDisplayInRect:box toBitmapImageRep:rep];
            NSImage*small=[[NSImage alloc]initWithSize:NSMakeSize(MAX(1,box.size.width/8),MAX(1,box.size.height/8))];
            [small lockFocus];[rep drawInRect:NSMakeRect(0,0,small.size.width,small.size.height)];[small unlockFocus];
            [small drawInRect:box];break;
        }
    }
}
-(void)mouseDown:(NSEvent*)e{
    NSPoint pt=[self convertPoint:[e locationInWindow] fromView:nil];
    if(_currentTool==AnnotText){
        NSTextField*tf=[[NSTextField alloc]initWithFrame:NSMakeRect(pt.x,pt.y,120,24)];
        tf.placeholderString=@"text"; [self addSubview:tf]; [tf becomeFirstResponder];
        __weak NSTextField*wtf=tf; __weak AnnotView*wv=self;
        [[NSNotificationCenter defaultCenter] addObserverForName:NSControlTextDidEndEditingNotification object:tf queue:nil usingBlock:^(NSNotification*n){
            AnnotShape*s=[AnnotShape new];s.tool=AnnotText;s.start=pt;s.text=wtf.stringValue;
            [wv.shapes addObject:s];[wtf removeFromSuperview];[wv setNeedsDisplay:YES];
        }]; return;
    }
    _live=[AnnotShape new];_live.tool=_currentTool;_live.start=pt;_live.end=pt;
}
-(void)mouseDragged:(NSEvent*)e{
    NSPoint pt=[self convertPoint:[e locationInWindow] fromView:nil];
    if(!_live)return;
    if(_currentTool==AnnotPencil)[_live.points addObject:[NSValue valueWithPoint:pt]];
    else _live.end=pt;
    [self setNeedsDisplay:YES];
}
-(void)mouseUp:(NSEvent*)e{
    if(_live){[_shapes addObject:_live];_live=nil;[self setNeedsDisplay:YES];}
}
-(NSImage*)flattenedImage{
    NSImage*out=[[NSImage alloc]initWithSize:_baseImage.size];
    [out lockFocus];
    [_baseImage drawInRect:NSMakeRect(0,0,out.size.width,out.size.height)];
    CGFloat sx=_baseImage.size.width/self.bounds.size.width, sy=_baseImage.size.height/self.bounds.size.height;
    for(AnnotShape*s in _shapes){
        AnnotShape*sc=[AnnotShape new];sc.tool=s.tool;
        sc.start=NSMakePoint(s.start.x*sx,s.start.y*sy);sc.end=NSMakePoint(s.end.x*sx,s.end.y*sy);
        sc.text=s.text;
        for(NSValue*v in s.points)[sc.points addObject:[NSValue valueWithPoint:NSMakePoint([v pointValue].x*sx,[v pointValue].y*sy)]];
        [self drawShape:sc];
    }
    [out unlockFocus];return out;
}
@end

// MARK: - Overlay capture
@interface OverlayView : NSView
@property (assign) CGImageRef frozen;
@property (assign) NSPoint dragStart;
@property (assign) NSPoint dragEnd;
@property (assign) BOOL dragging;
@property (copy) void (^onDone)(CGRect selectionInScreen);
@property (copy) void (^onCancel)(void);
@end

@implementation OverlayView
- (instancetype)initWithFrame:(NSRect)f frozen:(CGImageRef)img {
    self = [super initWithFrame:f];
    _frozen = CGImageRetain(img);
    return self;
}
- (void)dealloc { if (_frozen) CGImageRelease(_frozen); }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == kVK_Escape && self.onCancel) self.onCancel();
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect b = self.bounds;
    // draw frozen screenshot
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextDrawImage(ctx, b, _frozen);
    // dark mask
    [[NSColor colorWithWhite:0 alpha:0.3] set];
    NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
    if (_dragging || (!NSEqualPoints(_dragStart, _dragEnd))) {
        NSRect sel = [self selRect];
        if (sel.size.width > 0 && sel.size.height > 0) {
            // punch hole (clear the selection area back to the screenshot)
            CGContextSaveGState(ctx);
            CGContextSetBlendMode(ctx, kCGBlendModeCopy);
            CGRect cropSrc = CGRectMake(sel.origin.x / b.size.width * CGImageGetWidth(_frozen),
                                        (1.0 - (sel.origin.y + sel.size.height)/b.size.height) * CGImageGetHeight(_frozen),
                                        sel.size.width / b.size.width * CGImageGetWidth(_frozen),
                                        sel.size.height / b.size.height * CGImageGetHeight(_frozen));
            CGImageRef sub = CGImageCreateWithImageInRect(_frozen, cropSrc);
            if (sub) { CGContextDrawImage(ctx, sel, sub); CGImageRelease(sub); }
            CGContextRestoreGState(ctx);
            // 1px white border
            [[NSColor whiteColor] set];
            NSFrameRect(sel);
            // size label
            NSInteger w = (NSInteger)round(sel.size.width * self.window.backingScaleFactor);
            NSInteger h = (NSInteger)round(sel.size.height * self.window.backingScaleFactor);
            NSString *sizeStr = [NSString stringWithFormat:@"%ld×%ld", (long)w, (long)h];
            NSDictionary *attrs = @{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
                                    NSForegroundColorAttributeName:[NSColor whiteColor],
                                    NSBackgroundColorAttributeName:[NSColor colorWithWhite:0 alpha:0.6]};
            NSSize ts = [sizeStr sizeWithAttributes:attrs];
            NSPoint tp = NSMakePoint(NSMidX(sel) - ts.width/2, sel.origin.y - ts.height - 4);
            if (tp.y < 0) tp.y = sel.origin.y + sel.size.height + 4;
            [sizeStr drawAtPoint:tp withAttributes:attrs];
        }
    }
}
- (NSRect)selRect {
    CGFloat x = MIN(_dragStart.x, _dragEnd.x), y = MIN(_dragStart.y, _dragEnd.y);
    CGFloat w = fabs(_dragEnd.x - _dragStart.x), h = fabs(_dragEnd.y - _dragStart.y);
    return NSMakeRect(x, y, w, h);
}
- (void)mouseDown:(NSEvent *)e {
    _dragStart = [self convertPoint:e.locationInWindow fromView:nil];
    _dragEnd = _dragStart; _dragging = YES; [self setNeedsDisplay:YES];
}
- (void)mouseDragged:(NSEvent *)e {
    _dragEnd = [self convertPoint:e.locationInWindow fromView:nil];
    [self setNeedsDisplay:YES];
}
- (void)mouseUp:(NSEvent *)e {
    _dragging = NO;
    _dragEnd = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect sel = [self selRect];
    if (sel.size.width < 3 || sel.size.height < 3) { if (self.onCancel) self.onCancel(); return; }
    if (self.onDone) {
        // convert to screen-pixel rect for CGImage crop
        CGFloat scale = self.window.backingScaleFactor;
        NSRect b = self.bounds;
        CGFloat imgW = CGImageGetWidth(_frozen), imgH = CGImageGetHeight(_frozen);
        CGRect crop = CGRectMake(sel.origin.x / b.size.width * imgW,
                                 (1.0 - (sel.origin.y + sel.size.height)/b.size.height) * imgH,
                                 sel.size.width / b.size.width * imgW,
                                 sel.size.height / b.size.height * imgH);
        self.onDone(crop);
    }
}
@end

// MARK: - App delegate
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) KeyTap *keyTap;
@property (strong) NSPanel *preview;
@property (strong) NSWindow *onboard;
@property (strong) NSTextField *obHint;
@property (strong) NSButton *obScreenCb;
@property (strong) NSButton *obAxCb;
@property (strong) NSButton *obStart;
@property (strong) NSPopUpButton *obPop;
@property (strong) NSButton *obLogin;
@property (strong) NSTextField *obPermHint;
@property (strong) NSTimer *obTimer;
@property (strong) id keyMon;
@property (strong) NSData *compData;
@property (strong) NSData *origData;
@property (assign) ShotInfo info;
@property (strong) dispatch_block_t resetWork;
@property (strong) NSMutableArray *pinWindows;
@property (strong) AnnotView *annotView;
@property (strong) NSPanel *annotPanel;
@property (strong) NSWindow *overlayWindow;
- (void)capture;
- (void)pinClipboard;
- (void)closeMostRecentPin;
- (void)editAnnotation;
@end

@implementation AppDelegate

- (void)setIcon:(NSString *)symbol {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"AgentShot"];
    img.template = YES; self.statusItem.button.image = img; self.statusItem.button.title = @"";
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    self.pinWindows = [NSMutableArray array];
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    [self setIcon:@"camera.viewfinder"];
    [self rebuildMenu];

    __weak typeof(self) ws = self;
    self.keyTap = [KeyTap new];
    self.keyTap.onFire = ^{ [ws capture]; };
    [self applyShortcut:NO];

    // Ground truth = did the event tap actually load? If not, the shortcut can't
    // work (Accessibility not granted yet) -> onboarding. Self-correcting.
    if (!self.keyTap.isActive)
        [self showOnboarding];
}

// Start/refresh the event tap for the current shortcut; report if it couldn't be claimed.
- (void)applyShortcut:(BOOL)announce {
    // Only create the event tap when already trusted — calling CGEventTapCreate
    // while untrusted makes macOS pop the Accessibility prompt unprompted. We let
    // the prompt happen ONLY when the user ticks the checkbox (obToggleAccessibility).
    if (!AXIsProcessTrusted()) return;
    BOOL ok = [self.keyTap restartWithCode:(CGKeyCode)CurrentHKCode()
                                     flags:CGFlagsFromCarbon(CurrentHKMods())];
    NSString *sc = ShortcutLabel(CurrentHKCode(), CurrentHKMods());
    if (!ok)
        [self flash:[NSString stringWithFormat:@"⚠︎ allow Accessibility for %@", sc]];
    else if (announce)
        [self flash:[NSString stringWithFormat:@"shortcut → %@", sc]];
}

// ---- Menu ----
- (void)rebuildMenu {
    NSMenu *m = [[NSMenu alloc] init];

    // — Actions —
    NSMenuItem *cap = [[NSMenuItem alloc] initWithTitle:@"Capture Region" action:@selector(capture) keyEquivalent:@""];
    cap.toolTip = @"截图并自动压缩到剪贴板";
    UInt32 cc = CurrentHKCode(), cm = CurrentHKMods();
    if (cm & cmdKey)   cap.keyEquivalentModifierMask |= NSEventModifierFlagCommand;
    if (cm & shiftKey) cap.keyEquivalentModifierMask |= NSEventModifierFlagShift;
    if (cm & optionKey) cap.keyEquivalentModifierMask |= NSEventModifierFlagOption;
    if (cm & controlKey) cap.keyEquivalentModifierMask |= NSEventModifierFlagControl;
    NSDictionary *keyNames = @{ @(kVK_F1):@"\uF704", @(kVK_F2):@"\uF705",
                                @(kVK_ANSI_2):@"2", @(kVK_ANSI_5):@"5" };
    cap.keyEquivalent = keyNames[@(cc)] ?: @"";
    [m addItem:cap];

    NSMenuItem *pin = [[NSMenuItem alloc] initWithTitle:@"Pin Clipboard" action:@selector(pinClipboard) keyEquivalent:@"\uF706"];
    pin.keyEquivalentModifierMask = 0;
    pin.toolTip = @"将剪贴板图片钉在屏幕上";
    [m addItem:pin];

    NSMenuItem *color = [[NSMenuItem alloc] initWithTitle:@"Color Picker" action:@selector(startColorPicker) keyEquivalent:@""];
    color.toolTip = @"取色并复制 HEX 到剪贴板";
    [m addItem:color];

    [m addItem:[NSMenuItem separatorItem]];

    // — Settings —
    NSMenuItem *scItem = [[NSMenuItem alloc] initWithTitle:@"Shortcut" action:nil keyEquivalent:@""];
    NSMenu *scMenu = [[NSMenu alloc] init];
    NSArray *opts = @[@[@"F1", @(kVK_F1), @0], @[@"F2", @(kVK_F2), @0],
                      @[@"⌘⇧2", @(kVK_ANSI_2), @(cmdKey|shiftKey)],
                      @[@"⌘⇧5", @(kVK_ANSI_5), @(cmdKey|shiftKey)]];
    for (NSArray *o in opts) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:o[0] action:@selector(setShortcut:) keyEquivalent:@""];
        it.tag = [o[1] integerValue]; it.representedObject = o[2];
        it.state = ((UInt32)it.tag==cc && (UInt32)[o[2] integerValue]==cm) ? NSControlStateValueOn : NSControlStateValueOff;
        it.target = self; [scMenu addItem:it];
    }
    scItem.submenu = scMenu; [m addItem:scItem];

    NSMenuItem *qItem = [[NSMenuItem alloc] initWithTitle:@"Quality" action:nil keyEquivalent:@""];
    qItem.toolTip = @"压缩档位（长边像素上限）";
    NSMenu *qMenu = [[NSMenu alloc] init];
    NSArray *tiers = @[@[@"Compact (1024px)", @1024],
                       @[@"Balanced (1568px)", @1568],
                       @[@"High Fidelity (2560px)", @2560]];
    NSInteger ce = CurrentMaxEdge();
    for (NSArray *t in tiers) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t[0] action:@selector(setTier:) keyEquivalent:@""];
        it.tag = [t[1] integerValue];
        it.state = (it.tag==ce) ? NSControlStateValueOn : NSControlStateValueOff;
        it.target = self; [qMenu addItem:it];
    }
    qItem.submenu = qMenu; [m addItem:qItem];

    NSMenuItem *login = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                          action:@selector(toggleLogin:) keyEquivalent:@""];
    login.state = [self loginEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    login.toolTip = @"开机自动启动";
    login.target = self; [m addItem:login];

    [m addItem:[NSMenuItem separatorItem]];

    // — Quit —
    [m addItemWithTitle:@"Quit AgentShot" action:@selector(terminate:) keyEquivalent:@"q"];

    self.statusItem.menu = m;
    self.statusItem.button.toolTip = @"AgentShot";
}

- (void)setShortcut:(NSMenuItem *)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:kHKCodeKey];
    [[NSUserDefaults standardUserDefaults] setInteger:[sender.representedObject integerValue] forKey:kHKModKey];
    [self applyShortcut:YES];
    [self rebuildMenu];
}
- (void)setTier:(NSMenuItem *)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:sender.tag forKey:kEdgeKey];
    [self rebuildMenu];
}

// ---- Launch at login ----
- (BOOL)loginEnabled {
    if (@available(macOS 13.0, *)) return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    return NO;
}
- (void)setLogin:(BOOL)on {
    if (@available(macOS 13.0, *)) {
        NSError *err=nil;
        if (on) [SMAppService.mainAppService registerAndReturnError:&err];
        else    [SMAppService.mainAppService unregisterAndReturnError:&err];
    }
}
- (void)toggleLogin:(NSMenuItem *)s { [self setLogin:![self loginEnabled]]; [self rebuildMenu]; }

- (void)startColorPicker {
    if (@available(macOS 10.15, *)) {
        __weak typeof(self) ws = self;
        NSColorSampler *sampler = [[NSColorSampler alloc] init];
        [sampler showSamplerWithSelectionHandler:^(NSColor *color) {
            if (!color) return;
            NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            NSString *hex = [NSString stringWithFormat:@"#%02X%02X%02X",
                (int)round(c.redComponent*255),(int)round(c.greenComponent*255),(int)round(c.blueComponent*255)];
            NSPasteboard *pb = [NSPasteboard generalPasteboard];
            [pb clearContents]; [pb setString:hex forType:NSPasteboardTypeString];
            [ws flash:[NSString stringWithFormat:@"✓ %@", hex]];
        }];
    } else {
        [self flash:@"requires macOS 10.15+"];
    }
}

- (void)editAnnotation {
    if (!self.compData) return;
    NSImage *base = [[NSImage alloc] initWithData:self.compData];
    CGFloat maxW=600, maxH=400; NSSize s=base.size;
    CGFloat r=MIN(MIN(maxW/s.width,maxH/s.height),1.0);
    NSSize vs=NSMakeSize(round(s.width*r),round(s.height*r));
    CGFloat tbH=36;
    NSPanel *p=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,vs.width,vs.height+tbH)
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskUtilityWindow)
        backing:NSBackingStoreBuffered defer:NO];
    p.title=@"Annotate"; p.floatingPanel=YES;
    AnnotView *av=[[AnnotView alloc] initWithFrame:NSMakeRect(0,tbH,vs.width,vs.height) baseImage:base];
    [p.contentView addSubview:av];
    self.annotView=av;
    NSArray *tools=@[@"Rect",@"Arrow",@"Text",@"Blur",@"Pencil"];
    CGFloat bw=vs.width/6;
    for(NSInteger i=0;i<5;i++){
        NSButton *b=[NSButton buttonWithTitle:tools[i] target:self action:@selector(annotToolChanged:)];
        b.frame=NSMakeRect(i*bw,4,bw-2,28); b.tag=i; b.bezelStyle=NSBezelStyleRounded;
        if(i==0) b.state=NSControlStateValueOn;
        [p.contentView addSubview:b];
    }
    NSButton *done=[NSButton buttonWithTitle:@"Done" target:self action:@selector(doneAnnotation)];
    done.frame=NSMakeRect(5*bw,4,bw-2,28); done.bezelStyle=NSBezelStyleRounded;
    [p.contentView addSubview:done];
    self.annotPanel=p; [p center]; [p makeKeyAndOrderFront:nil];
}
- (void)annotToolChanged:(NSButton*)btn {
    self.annotView.currentTool=(AnnotTool)btn.tag;
}
- (void)doneAnnotation {
    NSImage *flat=[self.annotView flattenedImage];
    // encode to JPEG
    NSData *tiff=[flat TIFFRepresentation];
    NSBitmapImageRep *rep=[NSBitmapImageRep imageRepWithData:tiff];
    CGFloat q=0.82; NSData *jpeg=nil;
    while(q>=0.34){
        jpeg=[rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor:@(q)}];
        if(jpeg.length<=1000*1024) break;
        q-=0.10;
    }
    if(!jpeg) jpeg=[rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor:@(0.34)}];
    self.compData=jpeg;
    NSPasteboard *pb=[NSPasteboard generalPasteboard];
    [pb clearContents]; [pb setData:jpeg forType:@"public.jpeg"];
    [self.annotPanel close]; self.annotPanel=nil; self.annotView=nil;
    [self flash:@"✓ annotated"];
}

// ---- Pin clipboard image ----
- (void)pinClipboard {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSData *data = nil;
    for (NSString *type in @[@"public.tiff", @"public.png", @"public.jpeg"]) {
        data = [pb dataForType:type];
        if (data) break;
    }
    if (!data) { [self flash:@"No image on clipboard"]; return; }
    NSImage *img = [[NSImage alloc] initWithData:data];
    if (!img) { [self flash:@"Cannot read clipboard image"]; return; }

    NSSize s = img.size;
    CGFloat maxW = 600, maxH = 500;
    CGFloat r = MIN(MIN(maxW/s.width, maxH/s.height), 1.0);
    NSSize ds = NSMakeSize(round(s.width*r), round(s.height*r));

    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,ds.width,ds.height)
        styleMask:NSWindowStyleMaskBorderless
        backing:NSBackingStoreBuffered defer:NO];
    p.level = NSFloatingWindowLevel;
    p.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorManaged;
    p.movableByWindowBackground = YES;
    p.opaque = NO; p.backgroundColor = [NSColor clearColor];
    p.hasShadow = YES;

    PinView *iv = [[PinView alloc] initWithFrame:NSMakeRect(0,0,ds.width,ds.height)];
    iv.image = img; iv.imageScaling = NSImageScaleAxesIndependently;
    iv.wantsLayer = YES; iv.layer.cornerRadius = 4; iv.layer.masksToBounds = YES;
    iv.pinPanel = p; iv.pinWindows = self.pinWindows;
    [p.contentView addSubview:iv];

    [self.pinWindows addObject:p];
    [p center]; [p makeKeyAndOrderFront:nil];
}

- (void)closeMostRecentPin {
    if (self.pinWindows.count == 0) return;
    NSPanel *last = self.pinWindows.lastObject;
    [self.pinWindows removeLastObject];
    [last close];
}

// ---- Capture flow ----
- (void)capture {
    // Freeze the main display (dynamically call CGDisplayCreateImage to bypass macOS 15 SDK unavailability)
    CGDirectDisplayID displayID = CGMainDisplayID();
    typedef CGImageRef (*CGDisplayCreateImageFunc)(CGDirectDisplayID);
    CGDisplayCreateImageFunc createImg = (CGDisplayCreateImageFunc)dlsym(RTLD_DEFAULT, "CGDisplayCreateImage");
    CGImageRef frozen = createImg ? createImg(displayID) : NULL;
    if (!frozen) { [self flash:@"✗ capture failed"]; return; }

    NSScreen *screen = [NSScreen mainScreen];
    NSRect frame = screen.frame;

    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    w.level = NSScreenSaverWindowLevel - 1;
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    w.hasShadow = NO;
    w.ignoresMouseEvents = NO;
    w.releasedWhenClosed = NO;
    if (@available(macOS 12.0, *)) w.sharingType = NSWindowSharingNone;
    w.collectionBehavior = NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorCanJoinAllSpaces;

    OverlayView *ov = [[OverlayView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, frame.size.height) frozen:frozen];
    CGImageRelease(frozen);
    [w setContentView:ov];
    self.overlayWindow = w;

    __weak typeof(self) ws = self;
    ov.onCancel = ^{
        [ws.overlayWindow orderOut:nil];
        ws.overlayWindow = nil;
    };
    __weak OverlayView *wov = ov;
    ov.onDone = ^(CGRect cropRect) {
        CGImageRef cropped = CGImageCreateWithImageInRect(wov.frozen, cropRect);
        [ws.overlayWindow orderOut:nil];
        ws.overlayWindow = nil;
        if (!cropped) { [ws flash:@"✗ crop failed"]; return; }
        // Save to temp PNG and feed into existing pipeline
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"agentshot-%@.png", [[NSUUID UUID] UUIDString]]];
        NSURL *url = [NSURL fileURLWithPath:tmp];
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
            (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
        if (dest) {
            CGImageDestinationAddImage(dest, cropped, NULL);
            CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        CGImageRelease(cropped);
        [ws handleCaptured:tmp];
    };

    [w makeKeyAndOrderFront:nil];
    [w makeFirstResponder:ov];
}
- (void)handleCaptured:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return;
    ShotInfo info; NSData *jpeg = ProcessImage([NSURL fileURLWithPath:path], &info);
    NSData *orig = [NSData dataWithContentsOfFile:path];
    [fm removeItemAtPath:path error:nil];
    if (!jpeg || !info.ok) { [self flash:@"✗ compress failed"]; return; }
    self.compData = jpeg; self.origData = orig; self.info = info;
    [self showPreviewWithJPEG:jpeg info:info];
}

- (void)showPreviewWithJPEG:(NSData *)jpeg info:(ShotInfo)info {
    [self closePreview];
    NSImage *thumb = [[NSImage alloc] initWithData:jpeg];
    CGFloat maxW=460, maxH=320; NSSize is=thumb.size;
    CGFloat r=MIN(MIN(maxW/is.width,maxH/is.height),1.0);
    NSSize ts=NSMakeSize(round(is.width*r),round(is.height*r));
    CGFloat pad=16, barH=30;
    NSPanel *p = [[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,ts.width+pad*2,ts.height+pad*2+barH)
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskUtilityWindow|NSWindowStyleMaskHUDWindow)
        backing:NSBackingStoreBuffered defer:NO];
    p.title = @"C / ↩ Copy   ·   ⇧C Original   ·   Esc Cancel"; p.floatingPanel = YES;
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(pad,pad+barH,ts.width,ts.height)];
    iv.image=thumb; iv.imageScaling=NSImageScaleProportionallyUpOrDown;
    iv.wantsLayer=YES; iv.layer.cornerRadius=6; iv.layer.masksToBounds=YES; [p.contentView addSubview:iv];
    NSInteger kb=(NSInteger)jpeg.length/1024, tok=info.outW*info.outH/750;
    NSTextField *lbl=[NSTextField labelWithString:[NSString stringWithFormat:@"%ld×%ld · %ldKB · ~%ld tok",(long)info.outW,(long)info.outH,(long)kb,(long)tok]];
    lbl.frame=NSMakeRect(pad,pad-2,ts.width,barH-6); lbl.alignment=NSTextAlignmentCenter;
    lbl.textColor=[NSColor secondaryLabelColor]; lbl.font=[NSFont systemFontOfSize:11]; [p.contentView addSubview:lbl];
    NSButton *editBtn=[NSButton buttonWithTitle:@"Edit" target:self action:@selector(editAnnotation)];
    editBtn.frame=NSMakeRect(pad, pad-2+barH-6+4, 50, 22); editBtn.bezelStyle=NSBezelStyleRounded;
    [p.contentView addSubview:editBtn];
    self.preview=p; [p center]; [NSApp activateIgnoringOtherApps:YES]; [p makeKeyAndOrderFront:nil];
    __weak typeof(self) ws=self;
    self.keyMon=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *ev){ return [ws handlePreviewKey:ev]; }];
}
- (NSEvent *)handlePreviewKey:(NSEvent *)ev {
    BOOL shift = (ev.modifierFlags & NSEventModifierFlagShift) != 0;
    switch (ev.keyCode) {
        case kVK_ANSI_C:
            if (shift) { PutOnPasteboard(self.origData,@"public.png"); [self flash:@"✓ original copied"]; }
            else       { PutOnPasteboard(self.compData,@"public.jpeg"); [self flashSaved]; }
            [self closePreview]; return nil;
        case kVK_Return: case kVK_ANSI_KeypadEnter:
            PutOnPasteboard(self.compData,@"public.jpeg"); [self flashSaved]; [self closePreview]; return nil;
        case kVK_Escape:
            if (self.preview) { [self closePreview]; return nil; }
            [self closeMostRecentPin]; return nil;
    }
    return ev;
}
- (void)closePreview {
    if (self.keyMon) { [NSEvent removeMonitor:self.keyMon]; self.keyMon=nil; }
    if (self.preview) { [self.preview close]; self.preview=nil; }
}
- (void)flashSaved {
    ShotInfo i=self.info; NSInteger st=i.srcW*i.srcH/750, ot=i.outW*i.outH/750;
    NSInteger saved = st>0 ? (NSInteger)(100.0*(1.0-(double)ot/st)) : 0;
    [self flash:[NSString stringWithFormat:@"✓ %ldKB · -%ld%% px",(long)self.compData.length/1024,(long)saved]];
}
- (void)flash:(NSString *)text {
    if (self.resetWork) dispatch_block_cancel(self.resetWork);
    self.statusItem.button.image=nil; self.statusItem.button.title=text;
    __weak typeof(self) ws=self;
    self.resetWork=dispatch_block_create(0, ^{ [ws setIcon:@"camera.viewfinder"]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),dispatch_get_main_queue(),self.resetWork);
}

// ---- First-run onboarding (with shortcut picker + conflict/permission hint) ----
- (void)showOnboarding {
    // Already showing (e.g. relaunched while open): just bring it forward.
    if (self.onboard) {
        [NSApp activateIgnoringOtherApps:YES];
        [self.onboard makeKeyAndOrderFront:nil];
        [self.onboard orderFrontRegardless];
        [self refreshOnboardingState];
        return;
    }
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,480,360)
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    w.title=@"Welcome to AgentShot"; NSView *c=w.contentView;
    // Under ARC, a window defaults to releasedWhenClosed=YES; combined with our strong
    // `self.onboard` property, [close] + (self.onboard=nil) double-frees it → crash on Start.
    w.releasedWhenClosed = NO;
    // Normal level — NOT floating. A floating window sits ABOVE the system's
    // Accessibility permission dialog and hides it. We foreground it instead via
    // activateIgnoringOtherApps + orderFrontRegardless (below), which brings it to
    // front without covering system dialogs.

    NSTextField *h=[NSTextField labelWithString:@"📸 AgentShot"];
    h.font=[NSFont boldSystemFontOfSize:22]; h.frame=NSMakeRect(28,304,420,32); [c addSubview:h];

    NSTextField *body=[NSTextField wrappingLabelWithString:
        @"Snip a region and it's auto-compressed to the AI-vision sweet spot, then it's on your clipboard.\n"
         "After a snip:  C / ↩ copy compressed · ⇧C copy original · Esc cancel."];
    body.frame=NSMakeRect(28,238,424,58); body.font=[NSFont systemFontOfSize:13]; [c addSubview:body];

    NSTextField *scl=[NSTextField labelWithString:@"Shortcut"];
    scl.font=[NSFont boldSystemFontOfSize:13]; scl.frame=NSMakeRect(28,196,80,22); [c addSubview:scl];

    NSPopUpButton *pop=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(108,192,120,26)];
    [pop addItemsWithTitles:@[@"F1",@"F2",@"⌘⇧2",@"⌘⇧5"]];
    UInt32 cc=CurrentHKCode();
    NSInteger sel = cc==kVK_F2?1 : cc==kVK_ANSI_2?2 : cc==kVK_ANSI_5?3 : 0;
    [pop selectItemAtIndex:sel]; pop.target=self; pop.action=@selector(obPickShortcut:);
    [c addSubview:pop];

    self.obHint=[NSTextField wrappingLabelWithString:@""];
    self.obHint.frame=NSMakeRect(28,120,424,64); self.obHint.font=[NSFont systemFontOfSize:11.5];
    self.obHint.textColor=[NSColor secondaryLabelColor]; [c addSubview:self.obHint];
    [self obPickShortcut:pop];

    self.obLogin=[NSButton checkboxWithTitle:@"Launch AgentShot at login" target:nil action:nil];
    self.obLogin.frame=NSMakeRect(26,46,420,22); self.obLogin.state=NSControlStateValueOn; [c addSubview:self.obLogin];

    self.obAxCb=[NSButton checkboxWithTitle:@"Allow Accessibility (required for the global shortcut)" target:self action:@selector(obToggleAccessibility:)];
    self.obAxCb.frame=NSMakeRect(26,84,430,22); [c addSubview:self.obAxCb];

    self.obPermHint=[NSTextField wrappingLabelWithString:@""];
    self.obPermHint.frame=NSMakeRect(26,58,432,22); self.obPermHint.font=[NSFont systemFontOfSize:10];
    self.obPermHint.textColor=[NSColor secondaryLabelColor]; [c addSubview:self.obPermHint];

    self.obStart=[NSButton buttonWithTitle:@"Start" target:self action:@selector(finishOnboarding:)];
    self.obStart.frame=NSMakeRect(372,18,88,30); self.obStart.bezelStyle=NSBezelStyleRounded;
    self.obStart.keyEquivalent=@"\r"; [c addSubview:self.obStart];
    self.obPop=pop;

    self.onboard=w;
    [self refreshOnboardingState];
    // Re-check when the user returns from System Settings.
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshOnboardingState)
                                                 name:NSApplicationDidBecomeActiveNotification object:nil];
    // Poll so the checkbox stays in sync with System Settings without needing focus.
    self.obTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                     selector:@selector(refreshOnboardingState) userInfo:nil repeats:YES];
    [w center]; [NSApp activateIgnoringOtherApps:YES]; [w makeKeyAndOrderFront:nil]; [w orderFrontRegardless];
    __weak typeof(self) ws=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.4*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (ws.onboard) { [NSApp activateIgnoringOtherApps:YES]; [ws.onboard makeKeyAndOrderFront:nil]; [ws.onboard orderFrontRegardless]; }
    });
}
// map popup index -> (code,mods)
// The checkbox MIRRORS the real system setting (AXIsProcessTrusted), polled so it
// stays in sync the moment the user flips it in System Settings. The shortcut
// (CGEventTap) may still need a restart to actually start, hence the Restart hint.
- (void)refreshOnboardingState {
    if (!self.onboard) return;
    BOOL trusted = AXIsProcessTrusted();          // system's current grant for us
    if (trusted && !self.keyTap.isActive) [self applyShortcut:NO];  // try to start the tap now
    BOOL active = self.keyTap.isActive;           // is the shortcut actually working?

    self.obAxCb.state   = trusted ? NSControlStateValueOn : NSControlStateValueOff;  // sync with system
    self.obAxCb.enabled = !trusted;               // granted -> locked
    self.obStart.enabled = active;

    if (active)        self.obPermHint.stringValue = @"✓ Accessibility on — the shortcut is active. Click Start.";
    else if (trusted)  self.obPermHint.stringValue = @"Granted ✓ — activating the shortcut…";
    else               self.obPermHint.stringValue = @"Tick the box, then enable AgentShot in System Settings ▸ Privacy ▸ Accessibility.";
}
- (void)obToggleAccessibility:(NSButton*)sender {
    [NSApp activateIgnoringOtherApps:YES]; [self.onboard orderFrontRegardless];
    AXTrusted(YES);                               // Apple's own prompt (has "Open System Settings")
    [self refreshOnboardingState];                // snaps to real system state (stays unchecked until granted)
}
- (void)obIndex:(NSInteger)i code:(UInt32*)code mods:(UInt32*)mods {
    switch (i) { case 1:*code=kVK_F2;*mods=0;break; case 2:*code=kVK_ANSI_2;*mods=cmdKey|shiftKey;break;
                 case 3:*code=kVK_ANSI_5;*mods=cmdKey|shiftKey;break; default:*code=kVK_F1;*mods=0; }
}
- (void)obPickShortcut:(NSPopUpButton *)pop {
    UInt32 code,mods; [self obIndex:pop.indexOfSelectedItem code:&code mods:&mods];
    BOOL fkey = (code==kVK_F1 || code==kVK_F2);
    NSString *t = [NSString stringWithFormat:@"%@ will be captured system-wide — AgentShot intercepts it first, taking priority over other apps (e.g. Snipaste).",
                   ShortcutLabel(code,mods)];
    if (fkey) t = [t stringByAppendingString:@"\n⚠︎ Heads-up: on most Macs F-keys are media keys (brightness/volume) and won't trigger AgentShot unless you enable System Settings ▸ Keyboard ▸ \u201cUse F1, F2, etc. as standard function keys\u201d. A modifier combo like \u2318\u21e72 works everywhere — recommended."];
    self.obHint.stringValue = t;
}
- (void)finishOnboarding:(NSButton *)sender {
    if (!self.keyTap.isActive) { [self refreshOnboardingState]; return; }  // guard (Start is gated on this anyway)
    UInt32 code,mods; [self obIndex:self.obPop.indexOfSelectedItem code:&code mods:&mods];
    [[NSUserDefaults standardUserDefaults] setInteger:code forKey:kHKCodeKey];
    [[NSUserDefaults standardUserDefaults] setInteger:mods forKey:kHKModKey];
    if (self.obLogin.state==NSControlStateValueOn) [self setLogin:YES];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kOnboardedKey];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:nil];
    [self.obTimer invalidate]; self.obTimer=nil;
    [self applyShortcut:NO];
    [self rebuildMenu];
    [self.onboard close]; self.onboard=nil;
}
@end

// MARK: - Entry (+ --selftest)
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--selftest") == 0) {
            ShotInfo info; NSData *d = ProcessImage([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]], &info);
            if (!d || !info.ok) { fprintf(stderr,"selftest: failed\n"); return 1; }
            if (!getenv("CI")) PutOnPasteboard(d,@"public.jpeg");   // skip pasteboard in headless CI
            NSInteger st=info.srcW*info.srcH/750, ot=info.outW*info.outH/750;
            printf("src %ldx%ld %ldKB ~%ld tok\nout %ldx%ld %ldKB ~%ld tok q%.2f\nsaved %ld%% ; <1000KB: %s\n",
                (long)info.srcW,(long)info.srcH,(long)info.srcBytes/1024,(long)st,
                (long)info.outW,(long)info.outH,(long)d.length/1024,(long)ot,info.quality,
                st?(long)(100*(1.0-(double)ot/st)):0, d.length<=kByteLimit?"YES":"NO");
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *dg = [[AppDelegate alloc] init];
        app.delegate = dg;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}

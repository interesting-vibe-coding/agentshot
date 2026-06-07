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
    return v ? (UInt32)[v integerValue] : (UInt32)kVK_F1;   // default F1 (we steal it via event tap)
}
static UInt32 CurrentHKMods(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kHKModKey];
    return v ? (UInt32)[v integerValue] : 0;
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
        // F3 (keyCode 99): pin clipboard image
        if (kc == 99) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSApp delegate] performSelector:@selector(pinClipboard)];
            });
            return NULL;
        }
        CGEventFlags mask = kCGEventFlagMaskCommand|kCGEventFlagMaskShift|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl;
        if (kc == kt.code && (CGEventGetFlags(e) & mask) == kt.flags) {
            void (^fire)(void) = kt.onFire;
            if (fire) dispatch_async(dispatch_get_main_queue(), fire);
            return NULL;   // consume → steal from other apps (e.g. Snipaste)
        }
    }
    return e;
}
- (BOOL)restartWithCode:(CGKeyCode)c flags:(CGEventFlags)f {
    self.code = c; self.flags = f;
    if (_src) { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _src, kCFRunLoopCommonModes); CFRelease(_src); _src=NULL; }
    if (_tap) { CFMachPortInvalidate(_tap); CFRelease(_tap); _tap=NULL; }
    _active = NO;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    _tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, TapCB, (__bridge void *)self);
    if (!_tap) return NO;            // no Accessibility permission
    _src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), _src, kCFRunLoopCommonModes);
    CGEventTapEnable(_tap, true);
    _active = YES;
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

// MARK: - App delegate
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) KeyTap *keyTap;
@property (strong) NSPanel *preview;
@property (strong) NSWindow *onboard;
@property (strong) NSTextField *obHint;
@property (strong) id keyMon;
@property (strong) NSData *compData;
@property (strong) NSData *origData;
@property (assign) ShotInfo info;
@property (strong) dispatch_block_t resetWork;
@property (strong) NSMutableArray *pinWindows;
@property (strong) AnnotView *annotView;
@property (strong) NSPanel *annotPanel;
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
    if (@available(macOS 11.0, *)) CGRequestScreenCaptureAccess();

    if (![[NSUserDefaults standardUserDefaults] boolForKey:kOnboardedKey])
        [self showOnboarding];
}

// Start/refresh the event tap for the current shortcut; report if it couldn't be claimed.
- (void)applyShortcut:(BOOL)announce {
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
    NSString *sc = ShortcutLabel(CurrentHKCode(), CurrentHKMods());
    [m addItemWithTitle:[NSString stringWithFormat:@"Capture & compress  截图  (%@)", sc]
                 action:@selector(capture) keyEquivalent:@""];
    [m addItemWithTitle:@"Pin clipboard image  F3" action:@selector(pinClipboard) keyEquivalent:@""];
    [m addItemWithTitle:@"Pick color" action:@selector(startColorPicker) keyEquivalent:@""];
    [m addItem:[NSMenuItem separatorItem]];

    NSMenuItem *scItem = [[NSMenuItem alloc] initWithTitle:@"Shortcut  快捷键" action:nil keyEquivalent:@""];
    NSMenu *scMenu = [[NSMenu alloc] init];
    NSArray *opts = @[@[@"F1", @(kVK_F1), @0], @[@"F2", @(kVK_F2), @0],
                      @[@"⌘⇧2", @(kVK_ANSI_2), @(cmdKey|shiftKey)],
                      @[@"⌘⇧5", @(kVK_ANSI_5), @(cmdKey|shiftKey)]];
    UInt32 cc = CurrentHKCode(), cm = CurrentHKMods();
    for (NSArray *o in opts) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:o[0] action:@selector(setShortcut:) keyEquivalent:@""];
        it.tag = [o[1] integerValue]; it.representedObject = o[2];
        it.state = ((UInt32)it.tag==cc && (UInt32)[o[2] integerValue]==cm) ? NSControlStateValueOn : NSControlStateValueOff;
        it.target = self; [scMenu addItem:it];
    }
    scItem.submenu = scMenu; [m addItem:scItem];

    NSMenuItem *qItem = [[NSMenuItem alloc] initWithTitle:@"Quality  压缩档位" action:nil keyEquivalent:@""];
    NSMenu *qMenu = [[NSMenu alloc] init];
    NSArray *tiers = @[@[@"Max savings 极致省 · 1024px", @1024],
                       @[@"Balanced 平衡 · 1568px", @1568],
                       @[@"High fidelity 高保真 · 2560px", @2560]];
    NSInteger ce = CurrentMaxEdge();
    for (NSArray *t in tiers) {
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:t[0] action:@selector(setTier:) keyEquivalent:@""];
        it.tag = [t[1] integerValue];
        it.state = (it.tag==ce) ? NSControlStateValueOn : NSControlStateValueOff;
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
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,480,360)
        styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    w.title=@"Welcome to AgentShot"; NSView *c=w.contentView;

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

    NSButton *login=[NSButton checkboxWithTitle:@"Launch AgentShot at login" target:nil action:nil];
    login.frame=NSMakeRect(26,50,420,22); login.state=NSControlStateValueOn; [c addSubview:login];

    NSButton *screenCb=[NSButton checkboxWithTitle:@"Allow Screen Recording" target:self action:@selector(obRequestScreen:)];
    screenCb.frame=NSMakeRect(26,98,420,22); screenCb.state=NSControlStateValueOn; [c addSubview:screenCb];
    NSButton *axCb=[NSButton checkboxWithTitle:@"Allow Accessibility" target:self action:@selector(obRequestAccessibility:)];
    axCb.frame=NSMakeRect(26,74,420,22); axCb.state=NSControlStateValueOn; [c addSubview:axCb];

    NSTextField *hint=[NSTextField labelWithString:@"After granting permissions, quit and reopen AgentShot."];
    hint.frame=NSMakeRect(26,30,420,16); hint.font=[NSFont systemFontOfSize:10];
    hint.textColor=[NSColor secondaryLabelColor]; [c addSubview:hint];

    NSButton *start=[NSButton buttonWithTitle:@"Start" target:self action:@selector(finishOnboarding:)];
    start.frame=NSMakeRect(380,20,80,30); start.keyEquivalent=@"\r"; start.bezelStyle=NSBezelStyleRounded;
    [c addSubview:start];

    objc_setAssociatedObject(start,"pop",pop,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(start,"login",login,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    self.onboard=w; [w center]; [NSApp activateIgnoringOtherApps:YES]; [w makeKeyAndOrderFront:nil];
}
// map popup index -> (code,mods)
- (void)obRequestScreen:(NSButton*)sender {
    if (@available(macOS 11.0, *)) CGRequestScreenCaptureAccess();
}
- (void)obRequestAccessibility:(NSButton*)sender {
    NSDictionary *opts=@{(__bridge id)kAXTrustedCheckOptionPrompt:@YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
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
    if (fkey) t = [t stringByAppendingString:@"\nOn Macs where F-keys control brightness/volume, press fn+the key (or enable \u201cUse F1, F2 as standard function keys\u201d)."];
    t = [t stringByAppendingString:@"\nNeeds Accessibility permission — Start will ask for it."];
    self.obHint.stringValue = t;
}
- (void)finishOnboarding:(NSButton *)sender {
    NSPopUpButton *pop=objc_getAssociatedObject(sender,"pop");
    NSButton *login=objc_getAssociatedObject(sender,"login");
    UInt32 code,mods; [self obIndex:pop.indexOfSelectedItem code:&code mods:&mods];
    [[NSUserDefaults standardUserDefaults] setInteger:code forKey:kHKCodeKey];
    [[NSUserDefaults standardUserDefaults] setInteger:mods forKey:kHKModKey];
    if (login.state==NSControlStateValueOn) [self setLogin:YES];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kOnboardedKey];

    AXTrusted(YES);                                  // prompt Accessibility (for the key tap)
    if (@available(macOS 11.0,*)) CGRequestScreenCaptureAccess();
    [self applyShortcut:NO];
    [self rebuildMenu];
    [self.onboard close]; self.onboard=nil;
    if (!self.keyTap.isActive)
        [self flash:@"Grant Accessibility, then reopen AgentShot"];
}
@end

// MARK: - Entry (+ --selftest)
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "--selftest") == 0) {
            ShotInfo info; NSData *d = ProcessImage([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]], &info);
            if (!d || !info.ok) { fprintf(stderr,"selftest: failed\n"); return 1; }
            PutOnPasteboard(d,@"public.jpeg");
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

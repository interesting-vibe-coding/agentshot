import Cocoa
import ImageIO
import UniformTypeIdentifiers
import Carbon.HIToolbox

// MARK: - Configuration

/// Token-efficiency + hard byte cap defaults.
/// Rationale (see README): for Claude/GPT, image *tokens* depend on pixel
/// dimensions, not file bytes. Claude downscales anything over 1568px long
/// edge (1.15MP) anyway, so 1568 is the token sweet spot. JPEG quality only
/// affects bytes; q82 loses <1.3pp on vision benchmarks. We then back the
/// quality (and, as a last resort, the resolution) down until the file is
/// under the hard 1000KB ceiling.
enum Config {
    static let maxLongEdge: Int = 1568          // Claude 1.15MP sweet spot
    static let startQuality: CGFloat = 0.82     // ~<1.3pp vision accuracy loss
    static let byteLimit: Int = 1000 * 1024     // hard cap: < 1000KB, always
    static let qualitySteps: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42, 0.34]
    static let edgeFallbacks: [Int] = [1568, 1280, 1024, 832]
}

// MARK: - Compression pipeline

struct CompressResult {
    let data: Data
    let outWidth: Int
    let outHeight: Int
    let quality: CGFloat
    let srcWidth: Int
    let srcHeight: Int
    let srcBytes: Int
}

enum Compressor {

    /// Downscale `src` so its long edge <= `maxEdge`, decoding directly at the
    /// reduced resolution via ImageIO thumbnail (fast, no full decode, no upscale).
    private static func downscaled(_ src: CGImageSource, maxEdge: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxEdge
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Encode a CGImage to JPEG at the given quality.
    private static func jpeg(_ image: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Full pipeline: read file -> downscale -> quality/resolution backoff to < byteLimit.
    static func process(fileURL: URL) -> CompressResult? {
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }

        // Source dimensions for reporting / token math.
        var srcW = 0, srcH = 0
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            srcW = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            srcH = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        }
        let srcBytes = (try? Data(contentsOf: fileURL).count) ?? 0

        var best: CompressResult?

        for edge in Config.edgeFallbacks {
            guard let img = downscaled(src, maxEdge: edge) else { continue }
            for q in Config.qualitySteps {
                guard let data = jpeg(img, quality: q) else { continue }
                let candidate = CompressResult(
                    data: data, outWidth: img.width, outHeight: img.height,
                    quality: q, srcWidth: srcW, srcHeight: srcH, srcBytes: srcBytes)
                best = candidate                       // remember smallest-so-far
                if data.count <= Config.byteLimit {
                    return candidate                   // under the cap, done
                }
            }
        }
        // Never got under the cap (extremely unlikely for screenshots):
        // return the smallest we produced.
        return best
    }
}

// MARK: - Clipboard

enum Clipboard {
    /// Write raw JPEG bytes directly as `public.jpeg`. We deliberately avoid
    /// NSImage, which would re-encode to a huge uncompressed TIFF on the
    /// pasteboard and defeat the whole point.
    static func putJPEG(_ data: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
    }
}

// MARK: - Global hotkey (Carbon, no extra deps, no Accessibility permission)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    static var onFire: (() -> Void)?

    func register(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.onFire?()
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: OSType(0x41534854) /* 'ASHT' */, id: 1)
        RegisterEventHotKey(keyCode, modifiers, id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hotKey = HotKey()
    private var resetTitleWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon("camera.viewfinder")
        statusItem.button?.toolTip = "AgentShot — 截图自动压缩 (⌘⇧2)"

        let menu = NSMenu()
        menu.addItem(withTitle: "截图并压缩  ⌘⇧2", action: #selector(capture), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "策略: 长边≤\(Config.maxLongEdge)px · JPEG q\(Int(Config.startQuality*100)) · <1000KB",
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 AgentShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // ⌘⇧2
        HotKey.onFire = { [weak self] in self?.capture() }
        hotKey.register(keyCode: UInt32(kVK_ANSI_2),
                        modifiers: UInt32(cmdKey | shiftKey))
    }

    private func setIcon(_ symbol: String) {
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AgentShot") {
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.title = ""
        }
    }

    @objc private func capture() {
        // macOS interactive region/window selection. -o drops window shadow.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentshot-\(UUID().uuidString).png")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-i", "-o", tmp.path]
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleCaptured(tmp) }
        }
        do { try proc.run() } catch {
            flash("✗ 截图失败"); return
        }
    }

    private func handleCaptured(_ url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        // User pressed Esc / cancelled -> no file produced.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let r = Compressor.process(fileURL: url) else {
            flash("✗ 压缩失败"); return
        }
        Clipboard.putJPEG(r.data)

        let srcTok = r.srcWidth * r.srcHeight / 750
        let outTok = r.outWidth * r.outHeight / 750
        let saved = srcTok > 0 ? Int(100.0 * (1.0 - Double(outTok) / Double(srcTok))) : 0
        let kb = r.data.count / 1024
        let msg = "✓ \(r.outWidth)×\(r.outHeight) · \(kb)KB · ~\(outTok) tok (省\(saved)%)"
        NSLog("[AgentShot] %@  (src %d×%d, %dKB)", msg, r.srcWidth, r.srcHeight, r.srcBytes / 1024)
        flash("✓ \(kb)KB · 省\(saved)% token")
    }

    /// Brief textual feedback in the menubar, then revert to the icon.
    private func flash(_ text: String) {
        resetTitleWork?.cancel()
        statusItem.button?.image = nil
        statusItem.button?.title = text
        let work = DispatchWorkItem { [weak self] in self?.setIcon("camera.viewfinder") }
        resetTitleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menubar only, no Dock icon
app.run()

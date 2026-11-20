// Prototype: can a video window stay visible on the macOS lock screen?
// Moves a click-through, non-key window into a SkyLight space with an absolute level above
// the lock screen. Quits by itself after 90 s. Never takes keyboard or mouse input, so the
// password field keeps working even if the video covers it.
import Cocoa
import AVFoundation

typealias MainConnFn = @convention(c) () -> Int32
typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> Int
typealias SpaceSetLevelFn = @convention(c) (Int32, Int, Int32) -> Int32
typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
typealias AddWindowsFn = @convention(c) (Int32, Int, CFArray, Int32) -> Int32

func sym<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _: T.Type) -> T? {
    guard let p = dlsym(handle, name) else { print("missing symbol \(name)"); return nil }
    return unsafeBitCast(p, to: T.self)
}

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: lockproto <video>"); exit(1) }
let videoURL = URL(fileURLWithPath: args[1])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let screen = NSScreen.main else { exit(1) }
let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.ignoresMouseEvents = true
window.isOpaque = true
window.backgroundColor = .black
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
window.canHide = false

let view = NSView(frame: screen.frame)
view.wantsLayer = true
window.contentView = view

let item = AVPlayerItem(url: videoURL)
let player = AVQueuePlayer(playerItem: item)
let looper = AVPlayerLooper(player: player, templateItem: item)
player.isMuted = true
let layer = AVPlayerLayer(player: player)
layer.videoGravity = .resizeAspectFill
layer.frame = view.bounds
view.layer?.addSublayer(layer)


// Variant 2: the highest "shielding" level plus the flag meant for windows shown without login.
window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
window.canBecomeVisibleWithoutLogin = true
window.sharingType = .readOnly
window.orderFrontRegardless()
player.play()

guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
      let mainConn = sym(sky, "SLSMainConnectionID", MainConnFn.self),
      let spaceCreate = sym(sky, "SLSSpaceCreate", SpaceCreateFn.self),
      let setLevel = sym(sky, "SLSSpaceSetAbsoluteLevel", SpaceSetLevelFn.self),
      let showSpaces = sym(sky, "SLSShowSpaces", ShowSpacesFn.self),
      let addWindows = sym(sky, "SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindowsFn.self)
else { print("SkyLight unavailable"); exit(2) }

let cid = mainConn()
let space = spaceCreate(cid, 1, 0)
let r1 = setLevel(cid, space, 400)
let r2 = showSpaces(cid, [NSNumber(value: space)] as CFArray)
let r3 = addWindows(cid, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
print("cid=\(cid) space=\(space) setLevel=\(r1) show=\(r2) add=\(r3)")
fflush(stdout)

// Log lock/unlock so we can tell what happened from the output.
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
    print("\(Date()) screen locked, player rate=\(player.rate)"); fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .contains { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        print("\(Date()) 3s after lock: occlusionVisible=\(window.occlusionState.contains(.visible)) onScreenList=\(onScreen)"); fflush(stdout)
    }
}
DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
    print("\(Date()) screen unlocked, player rate=\(player.rate)"); fflush(stdout)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
    print("auto-quit after 90 s"); fflush(stdout)
    exit(0)
}
_ = looper
app.run()

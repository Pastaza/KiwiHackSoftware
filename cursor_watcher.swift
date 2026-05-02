import Cocoa
import IOBluetooth
import ApplicationServices
import QuartzCore
import Foundation
import Darwin

// MARK: - Image Paths

let imagePaths = [
    "/Users/pastaza/Documents/PlatformIO/Projects/Test/Img/IMG_1543.png", // image 1 / base
    "/Users/pastaza/Documents/PlatformIO/Projects/Test/Img/IMG_1544.png", // image 2
    "/Users/pastaza/Documents/PlatformIO/Projects/Test/Img/IMG_1545.png", // image 3
    "/Users/pastaza/Documents/PlatformIO/Projects/Test/Img/IMG_1546.png"  // image 4 / final
]

// Fat mouse special image
let specialCheeseImagePath = "/Users/pastaza/Documents/PlatformIO/Projects/Test/Img/IMG_1547.png"

// Cheese item image
let cheesePath = "/Users/pastaza/Documents/PlatformIO/Projects/Test/Img/Chese.png"

// Change this if your ESP32 port changes.
// Terminal command: ls /dev/cu.*
let serialPath = "/dev/cu.usbmodem101"

// MARK: - Sizes

let cursorSize: CGFloat = 80
let cheeseSize: CGFloat = 80

let textWindowWidth: CGFloat = 900
let textWindowHeight: CGFloat = 360
let textLabelWidth: CGFloat = 720
let textLabelHeight: CGFloat = 160

// MARK: - Timing

let normalImageProgressionInterval: TimeInterval = 20.0

let cheeseSpawnInterval: TimeInterval = 12.0
let cheeseRespawnAfterEat: TimeInterval = 4.0

// Fat mouse rule:
// only while on base image, eat 2 cheeses within 15 seconds.
let twoCheeseWindow: TimeInterval = 15.0

// Fat mouse lasts 20 seconds.
// If you click cheese before timeout, jump to IMG_1546.
// If you do nothing, return to image 1.
let fatMouseDuration: TimeInterval = 20.0

// MARK: - State

var currentImageIndex = 0
var isConnected = true
var isShowingSpecial1547 = false

var cursorWindow: NSWindow?
var imageView: NSImageView?

var cheeseWindow: NSWindow?

var timerWindow: NSWindow?
var timerLabel: NSTextField?

var textWindow: NSWindow?
var textLabel: NSTextField?

var cycleTimer: Timer?
var cheeseTimer: Timer?
var cheeseRespawnTimer: Timer?
var fatMouseTimer: Timer?
var displayTimer: Timer?
var cursorFollowTimer: Timer?
var seesawTimer: Timer?

var cheeseClickMonitor: Any?

var keyEventTap: CFMachPort?
var keyRunLoopSource: CFRunLoopSource?

var startTime = Date()

var isGlitching = false
var glitchOffsetX: CGFloat = 0
var glitchOffsetY: CGFloat = 0

var lastKeyWasSix = false
var isDoingSeesawAnim = false

var temperamentalBehaviorStarted = false

var serialFileDescriptor: Int32 = -1

var cheeseEatTimes: [Date] = []

@_silgen_name("CGSSetConnectionProperty")
func CGSSetConnectionProperty(_ cid: Int32, _ toClient: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

// MARK: - System Cursor

func hideSystemCursorPermanently() {
    let cid = CGSMainConnectionID()

    _ = CGSSetConnectionProperty(
        cid,
        cid,
        "SetsCursorInBackground" as CFString,
        kCFBooleanTrue
    )

    CGDisplayHideCursor(CGMainDisplayID())
}

// MARK: - ESP32 Serial

func openSerialConnection() {
    serialFileDescriptor = open(serialPath, O_RDWR | O_NOCTTY | O_NONBLOCK)

    if serialFileDescriptor == -1 {
        print("❌ Could not open serial port: \(serialPath)")
        print("➡️ Run this in Terminal to find your ESP32:")
        print("   ls /dev/cu.*")
        return
    }

    var options = termios()

    if tcgetattr(serialFileDescriptor, &options) != 0 {
        print("❌ Could not read serial settings")
        close(serialFileDescriptor)
        serialFileDescriptor = -1
        return
    }

    cfsetspeed(&options, speed_t(B115200))

    options.c_cflag |= tcflag_t(CLOCAL | CREAD)
    options.c_cflag &= ~tcflag_t(PARENB)
    options.c_cflag &= ~tcflag_t(CSTOPB)
    options.c_cflag &= ~tcflag_t(CSIZE)
    options.c_cflag |= tcflag_t(CS8)

    options.c_lflag = 0
    options.c_oflag = 0
    options.c_iflag = 0

    if tcsetattr(serialFileDescriptor, TCSANOW, &options) != 0 {
        print("❌ Could not apply serial settings")
        close(serialFileDescriptor)
        serialFileDescriptor = -1
        return
    }

    print("✅ Serial connected to ESP32 at \(serialPath)")

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        sendToESP32("P\(currentImageIndex)")
    }
}

func sendToESP32(_ message: String) {
    guard serialFileDescriptor != -1 else {
        print("⚠️ Serial not connected. Could not send: \(message)")
        return
    }

    let fullMessage = message + "\n"

    let result = fullMessage.withCString { pointer in
        write(serialFileDescriptor, pointer, strlen(pointer))
    }

    if result == -1 {
        print("❌ Failed to send to ESP32: \(message), retrying...")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let retryMessage = message + "\n"

            let retryResult = retryMessage.withCString { pointer in
                write(serialFileDescriptor, pointer, strlen(pointer))
            }

            if retryResult == -1 {
                print("❌ Retry failed: \(message)")
            } else {
                print("📤 Sent to ESP32 after retry: \(message)")
            }
        }
    } else {
        print("📤 Sent to ESP32: \(message)")
    }
}

// MARK: - Helpers

func clamp(_ value: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
    return max(minimum, min(value, maximum))
}

func screenContaining(_ point: NSPoint) -> NSScreen? {
    return NSScreen.screens.first { screen in
        screen.frame.contains(point)
    } ?? NSScreen.main
}

func safeTextWindowOrigin(near mouse: NSPoint, windowSize: NSSize) -> NSPoint {
    guard let screen = screenContaining(mouse) else {
        return NSPoint(
            x: mouse.x - windowSize.width / 2,
            y: mouse.y + 40
        )
    }

    let screenFrame = screen.visibleFrame

    var x = mouse.x - windowSize.width / 2
    var y = mouse.y + 40

    if y + windowSize.height > screenFrame.maxY {
        y = mouse.y - windowSize.height - 40
    }

    let maxX = max(screenFrame.minX, screenFrame.maxX - windowSize.width)
    let maxY = max(screenFrame.minY, screenFrame.maxY - windowSize.height)

    x = clamp(x, minimum: screenFrame.minX, maximum: maxX)
    y = clamp(y, minimum: screenFrame.minY, maximum: maxY)

    return NSPoint(x: x, y: y)
}

func loadImageIntoCursor(from path: String) {
    guard let image = NSImage(contentsOfFile: path) else {
        print("❌ Could not load image at \(path)")
        return
    }

    imageView?.image = image
}

// MARK: - Image Switching

func switchToImage(_ index: Int) {
    guard index >= 0 && index < imagePaths.count else {
        return
    }

    loadImageIntoCursor(from: imagePaths[index])

    currentImageIndex = index
    isShowingSpecial1547 = false

    fatMouseTimer?.invalidate()
    fatMouseTimer = nil

    print("✅ Switched to image \(index + 1)")

    /*
     ESP32 LED progress:
       P0 -> 1 LED
       P1 -> 2 LEDs
       P2 -> 3 LEDs
       P3 -> all 4 LEDs flashing on ESP32
    */
    sendToESP32("P\(index)")

    if index == 3 {
        startTime = Date()
        print("⏱ Timer reset - reached IMG_1546")
    }
}

func switchToSpecial1547Image() {
    loadImageIntoCursor(from: specialCheeseImagePath)
    isShowingSpecial1547 = true

    print("🐭 Switched to FAT MOUSE special image: IMG_1547")

    /*
     Do not send P here.
     IMG_1547 is a special fat mouse state, not part of the normal LED progression.

     Fat mouse behavior:
       - wait 20 seconds -> return to image 1
       - click cheese before 20 seconds -> jump to IMG_1546
    */

    fatMouseTimer?.invalidate()

    fatMouseTimer = Timer.scheduledTimer(withTimeInterval: fatMouseDuration, repeats: false) { _ in
        guard isShowingSpecial1547 else {
            return
        }

        print("🐭 Fat mouse timed out after \(Int(fatMouseDuration)) seconds - returning to image 1")

        cheeseEatTimes.removeAll()
        isShowingSpecial1547 = false

        // This loads IMG_1543 and sends P0 to ESP32.
        switchToImage(0)

        // Restart normal progression and cheese timers.
        startCycleAndCheese()
    }
}

// MARK: - Timer Display

func setupTimerDisplay() {
    let window = NSWindow(
        contentRect: NSRect(x: 20, y: 20, width: 220, height: 44),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )

    window.backgroundColor = .black
    window.isOpaque = true
    window.level = .init(rawValue: 2147483647)
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let label = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 44))
    label.stringValue = "🐭 Time: 00:00:00"
    label.textColor = .green
    label.backgroundColor = .black
    label.isBezeled = false
    label.isEditable = false
    label.isSelectable = false
    label.alignment = .center
    label.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .bold)

    window.contentView?.addSubview(label)

    timerLabel = label
    timerWindow = window

    window.orderFrontRegardless()
}

func startDisplayTimer() {
    startTime = Date()

    displayTimer?.invalidate()

    displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        let elapsed = Int(Date().timeIntervalSince(startTime))

        let h = elapsed / 3600
        let m = (elapsed % 3600) / 60
        let s = elapsed % 60

        timerLabel?.stringValue = String(format: "🐭 Time: %02d:%02d:%02d", h, m, s)
        timerWindow?.orderFrontRegardless()
    }
}

// MARK: - 67 Text Seesaw

func setupTextWindow() {
    let window = NSWindow(
        contentRect: NSRect(
            x: 0,
            y: 0,
            width: textWindowWidth,
            height: textWindowHeight
        ),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )

    window.backgroundColor = .clear
    window.isOpaque = false
    window.level = .init(rawValue: 2147483647)
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hasShadow = false
    window.alphaValue = 1.0

    let labelX = (textWindowWidth - textLabelWidth) / 2
    let labelY = (textWindowHeight - textLabelHeight) / 2

    let label = NSTextField(
        frame: NSRect(
            x: labelX,
            y: labelY,
            width: textLabelWidth,
            height: textLabelHeight
        )
    )

    label.stringValue = "6... 7... 6... 7...!"
    label.textColor = .yellow
    label.backgroundColor = .clear
    label.isBezeled = false
    label.isEditable = false
    label.isSelectable = false
    label.alignment = .center
    label.font = NSFont.boldSystemFont(ofSize: 34)
    label.drawsBackground = false

    label.wantsLayer = true
    label.layer?.masksToBounds = false
    label.frameCenterRotation = 0

    window.contentView?.wantsLayer = true
    window.contentView?.layer?.masksToBounds = false
    window.contentView?.addSubview(label)

    textLabel = label
    textWindow = window

    window.orderOut(nil)

    print("✅ Text window ready")
}

func resetTextAnimationState() {
    seesawTimer?.invalidate()
    seesawTimer = nil

    isDoingSeesawAnim = false

    textLabel?.frameCenterRotation = 0
    textWindow?.alphaValue = 1.0
    textWindow?.orderOut(nil)
}

func doSeesawAnimation() {
    guard !isDoingSeesawAnim,
          let textWindow = textWindow,
          let textLabel = textLabel else {
        return
    }

    isDoingSeesawAnim = true

    print("🎭 Doing TEXT seesaw animation")

    let mouse = NSEvent.mouseLocation
    let origin = safeTextWindowOrigin(near: mouse, windowSize: textWindow.frame.size)

    textWindow.setFrameOrigin(origin)
    textWindow.alphaValue = 1.0
    textWindow.orderFrontRegardless()

    textLabel.frameCenterRotation = 0

    let swings: [CGFloat] = [
        18, -18,
        18, -18,
        18, -18,
        0
    ]

    var step = 0

    seesawTimer?.invalidate()

    seesawTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { timer in
        if step >= swings.count {
            timer.invalidate()
            seesawTimer = nil

            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                textWindow.animator().alphaValue = 0.0
            }, completionHandler: {
                textLabel.frameCenterRotation = 0
                textWindow.orderOut(nil)
                textWindow.alphaValue = 1.0
                isDoingSeesawAnim = false
                print("🎭 Text seesaw done")
            })

            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            textLabel.animator().frameCenterRotation = swings[step]
        }

        step += 1
    }
}

// MARK: - Cursor Overlay

func setupCursorOverlay() {
    guard let image = NSImage(contentsOfFile: imagePaths[0]) else {
        print("❌ Could not load first image")
        return
    }

    let window = NSWindow(
        contentRect: NSRect(
            x: 0,
            y: 0,
            width: cursorSize,
            height: cursorSize
        ),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )

    window.backgroundColor = .clear
    window.isOpaque = false
    window.level = .init(rawValue: 2147483647)
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hasShadow = false

    let iv = NSImageView(
        frame: NSRect(
            x: 0,
            y: 0,
            width: cursorSize,
            height: cursorSize
        )
    )

    iv.image = image
    iv.imageScaling = .scaleAxesIndependently
    iv.wantsLayer = true
    iv.layer?.masksToBounds = false

    window.contentView?.wantsLayer = true
    window.contentView?.layer?.masksToBounds = false
    window.contentView?.addSubview(iv)

    imageView = iv
    cursorWindow = window

    print("✅ Cursor overlay ready")
}

// MARK: - Cheese

func setupCheeseWindow() {
    guard let image = NSImage(contentsOfFile: cheesePath) else {
        print("❌ Could not load cheese at \(cheesePath)")
        return
    }

    let window = NSWindow(
        contentRect: NSRect(
            x: 500,
            y: 500,
            width: cheeseSize,
            height: cheeseSize
        ),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )

    window.backgroundColor = .clear
    window.isOpaque = false
    window.level = .init(rawValue: 2147483647)
    window.ignoresMouseEvents = true
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.hasShadow = false

    let iv = NSImageView(
        frame: NSRect(
            x: 0,
            y: 0,
            width: cheeseSize,
            height: cheeseSize
        )
    )

    iv.image = image
    iv.imageScaling = .scaleAxesIndependently

    window.contentView?.addSubview(iv)

    cheeseWindow = window
    window.orderOut(nil)

    print("✅ Cheese window ready")
}

func showCheese() {
    guard let screen = NSScreen.main,
          let window = cheeseWindow else {
        return
    }

    let frame = screen.visibleFrame
    let margin: CGFloat = 100

    let minX = frame.minX + margin
    let maxX = max(minX, frame.maxX - cheeseSize - margin)

    let minY = frame.minY + margin
    let maxY = max(minY, frame.maxY - cheeseSize - margin)

    let x = CGFloat.random(in: minX...maxX)
    let y = CGFloat.random(in: minY...maxY)

    window.setFrameOrigin(NSPoint(x: x, y: y))
    window.orderFrontRegardless()

    print("🧀 Cheese shown at \(x), \(y)")
}

func hideCheese() {
    cheeseWindow?.orderOut(nil)
    print("🧀 Cheese hidden")
}

func pruneCheeseEatTimes() {
    let now = Date()

    cheeseEatTimes = cheeseEatTimes.filter {
        now.timeIntervalSince($0) <= twoCheeseWindow
    }
}

func scheduleCheeseRespawn(after delay: TimeInterval) {
    cheeseRespawnTimer?.invalidate()

    cheeseRespawnTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
        guard let cheeseW = cheeseWindow, !cheeseW.isVisible else {
            return
        }

        showCheese()
    }
}

func handleCheeseEaten() {
    hideCheese()

    /*
     Cheese rules:

     Normal timer moves upward:
       IMG_1543 -> IMG_1544 -> IMG_1545 -> IMG_1546

     Cheese moves downward:
       IMG_1545 -> IMG_1544
       IMG_1544 -> IMG_1543

     Final image:
       IMG_1546 + cheese -> full reset to IMG_1543

     Fat mouse special:
       IMG_1547 appears after 2 cheeses on IMG_1543.
       Then:
         wait 20 seconds -> IMG_1543
         click cheese before 20 seconds -> IMG_1546

     Fat mouse activation:
       Only on IMG_1543, eat 2 cheeses within 15 seconds -> IMG_1547.
    */

    if isShowingSpecial1547 {
        print("🐭 Cheese eaten before fat mouse timeout - jumping to IMG_1546")

        fatMouseTimer?.invalidate()
        fatMouseTimer = nil

        cheeseEatTimes.removeAll()
        isShowingSpecial1547 = false

        // IMG_1546 is imagePaths[3].
        // This sends P3 to ESP32, so all 4 LEDs flash.
        switchToImage(3)

        scheduleCheeseRespawn(after: cheeseRespawnAfterEat)
        return
    }

    // Final image: eating cheese resets to base.
    if currentImageIndex == 3 {
        print("🧀 Cheese eaten on IMG_1546 - full reset!")

        cheeseEatTimes.removeAll()
        resetToStart()
        return
    }

    // Image 3 or image 2: cheese moves DOWN one stage.
    if currentImageIndex > 0 {
        let oldIndex = currentImageIndex
        let newIndex = currentImageIndex - 1

        print("🧀 Cheese eaten - moving down from image \(oldIndex + 1) to image \(newIndex + 1)")

        cheeseEatTimes.removeAll()

        // This also sends P0/P1/P2 to ESP32.
        switchToImage(newIndex)

        scheduleCheeseRespawn(after: cheeseRespawnAfterEat)
        return
    }

    // Image 1/base: cheese counts toward fat mouse special.
    let now = Date()
    cheeseEatTimes.append(now)
    pruneCheeseEatTimes()

    let countIn15 = cheeseEatTimes.filter {
        now.timeIntervalSince($0) <= twoCheeseWindow
    }.count

    print("🧀 Cheese eaten on base IMG_1543! countIn15=\(countIn15)")

    if countIn15 >= 2 {
        print("🐭 2 cheeses on base IMG_1543 within 15 seconds - switching to FAT MOUSE IMG_1547")

        cheeseEatTimes.removeAll()
        switchToSpecial1547Image()
    }

    scheduleCheeseRespawn(after: cheeseRespawnAfterEat)
}

// MARK: - Reset

func resetCursorImageState() {
    cursorWindow?.alphaValue = 1.0
    cursorWindow?.setContentSize(NSSize(width: cursorSize, height: cursorSize))

    imageView?.frame = NSRect(
        x: 0,
        y: 0,
        width: cursorSize,
        height: cursorSize
    )

    imageView?.layer?.transform = CATransform3DIdentity
}

func resetToStart() {
    hideCheese()

    cycleTimer?.invalidate()
    cheeseTimer?.invalidate()
    cheeseRespawnTimer?.invalidate()
    fatMouseTimer?.invalidate()
    fatMouseTimer = nil

    isGlitching = false
    glitchOffsetX = 0
    glitchOffsetY = 0

    cheeseEatTimes.removeAll()
    isShowingSpecial1547 = false

    resetTextAnimationState()
    resetCursorImageState()

    // Reset on-screen timer.
    startTime = Date()

    // Back to first image.
    // This sends P0 to ESP32, so LEDs return to first-progress state.
    switchToImage(0)

    // Restart normal progression and cheese timers.
    startCycleAndCheese()

    print("🔄 Full reset to image 1")
}

// MARK: - Keyboard Listener

func startKeyListener() {
    if keyEventTap != nil {
        print("✅ Key tap already running")
        return
    }

    if !AXIsProcessTrusted() {
        print("❌ Accessibility not granted - requesting permission")

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]

        AXIsProcessTrustedWithOptions(options as CFDictionary)
    } else {
        print("✅ Accessibility granted")
    }

    let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, _, event, _ -> Unmanaged<CGEvent>? in
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            if keyCode == 22 {
                lastKeyWasSix = true
                print("6 detected - waiting for 7")
            } else if keyCode == 26 && lastKeyWasSix {
                lastKeyWasSix = false
                print("🎭 7 after 6 - text seesaw!")

                DispatchQueue.main.async {
                    doSeesawAnimation()
                }
            } else {
                lastKeyWasSix = false
            }

            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else {
        print("❌ Key tap failed - check Accessibility in System Settings")
        return
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    keyEventTap = tap
    keyRunLoopSource = source

    print("✅ Key tap running")
}

// MARK: - Glitch Behavior

func startTemperamentalBehavior() {
    if temperamentalBehaviorStarted {
        return
    }

    temperamentalBehaviorStarted = true

    func scheduleNextGlitch() {
        let delay = Double.random(in: 10...25)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard isConnected && currentImageIndex == 0 && !isShowingSpecial1547 else {
                scheduleNextGlitch()
                return
            }

            let glitchType = Int.random(in: 0...4)

            switch glitchType {
            case 0:
                print("😤 Glitch: shake")

                isGlitching = true

                var shakeCount = 0

                Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
                    glitchOffsetX = CGFloat.random(in: -30...30)
                    glitchOffsetY = CGFloat.random(in: -30...30)

                    shakeCount += 1

                    if shakeCount > 20 {
                        timer.invalidate()
                        isGlitching = false
                        glitchOffsetX = 0
                        glitchOffsetY = 0
                    }
                }

            case 1:
                print("👻 Glitch: disappear")

                cursorWindow?.alphaValue = 0

                DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.5...2.0)) {
                    cursorWindow?.alphaValue = 1.0
                }

            case 2:
                print("🏃 Glitch: run away")

                isGlitching = true
                glitchOffsetX = CGFloat.random(in: -200...200)
                glitchOffsetY = CGFloat.random(in: -200...200)

                DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1...3)) {
                    isGlitching = false
                    glitchOffsetX = 0
                    glitchOffsetY = 0
                }

            case 3:
                print("📏 Glitch: resize")

                let targetSize = CGFloat.random(in: 20...160)

                cursorWindow?.setContentSize(
                    NSSize(width: targetSize, height: targetSize)
                )

                imageView?.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: targetSize,
                    height: targetSize
                )

                DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 1...3)) {
                    cursorWindow?.setContentSize(
                        NSSize(width: cursorSize, height: cursorSize)
                    )

                    imageView?.frame = NSRect(
                        x: 0,
                        y: 0,
                        width: cursorSize,
                        height: cursorSize
                    )
                }

            case 4:
                print("🌀 Glitch: roam")

                isGlitching = true

                guard let screen = NSScreen.main else {
                    isGlitching = false
                    scheduleNextGlitch()
                    return
                }

                var roamCount = 0

                Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
                    glitchOffsetX = CGFloat.random(in: -screen.frame.width...screen.frame.width)
                    glitchOffsetY = CGFloat.random(in: -screen.frame.height...screen.frame.height)

                    roamCount += 1

                    if roamCount > 100 {
                        timer.invalidate()
                        isGlitching = false
                        glitchOffsetX = 0
                        glitchOffsetY = 0
                    }
                }

            default:
                break
            }

            scheduleNextGlitch()
        }
    }

    scheduleNextGlitch()
}

// MARK: - Cycle And Cheese

func startCycleAndCheese() {
    cycleTimer?.invalidate()
    cheeseTimer?.invalidate()
    cheeseRespawnTimer?.invalidate()

    cycleTimer = Timer.scheduledTimer(withTimeInterval: normalImageProgressionInterval, repeats: true) { timer in
        guard isConnected else {
            timer.invalidate()
            return
        }

        // Pause normal progression while fat mouse special IMG_1547 is showing.
        guard !isShowingSpecial1547 else {
            return
        }

        if currentImageIndex < imagePaths.count - 1 {
            switchToImage(currentImageIndex + 1)
        }
    }

    cheeseTimer = Timer.scheduledTimer(withTimeInterval: cheeseSpawnInterval, repeats: true) { _ in
        guard let cheeseW = cheeseWindow, !cheeseW.isVisible else {
            return
        }

        print("⏰ Cheese timer fired")
        showCheese()
    }

    if cheeseClickMonitor == nil {
        cheeseClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            guard let cheeseW = cheeseWindow,
                  cheeseW.isVisible else {
                return
            }

            let mouse = NSEvent.mouseLocation

            if cheeseW.frame.contains(mouse) {
                print("🧀 Cheese clicked!")
                handleCheeseEaten()
            }
        }
    }
}

// MARK: - Start Overlay

func startOverlay() {
    guard let window = cursorWindow else {
        return
    }

    window.orderFrontRegardless()

    hideSystemCursorPermanently()

    switchToImage(0)

    setupTimerDisplay()
    startDisplayTimer()

    cursorFollowTimer?.invalidate()

    cursorFollowTimer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in
        let mouse = NSEvent.mouseLocation

        let offsetX: CGFloat = isGlitching ? glitchOffsetX : 0
        let offsetY: CGFloat = isGlitching ? glitchOffsetY : 0

        window.setFrameOrigin(
            NSPoint(
                x: mouse.x - cursorSize / 2 + offsetX,
                y: mouse.y - cursorSize / 2 + offsetY
            )
        )

        window.orderFrontRegardless()
        CGDisplayHideCursor(CGMainDisplayID())
    }

    startCycleAndCheese()
    startTemperamentalBehavior()
    startKeyListener()

    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        print("🧀 Test cheese spawn")
        showCheese()
    }

    print("✅ Overlay started")
}

// MARK: - App Start

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let helperWindow = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)

helperWindow.backgroundColor = .clear
helperWindow.isOpaque = false
helperWindow.level = .floating
helperWindow.makeKeyAndOrderFront(nil)

setupCursorOverlay()
setupCheeseWindow()
setupTextWindow()

openSerialConnection()
startOverlay()

app.run()

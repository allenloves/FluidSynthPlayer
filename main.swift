// FluidSynth Player — menu bar MIDI player built on libfluidsynth.
//
// Open a .mid file: plays through FluidSynth + GeneralUser GS and shows a
// menu bar icon. The menu holds file name, elapsed/total time, a seek bar,
// play/pause and stop. Playback end or Stop quits the app (icon disappears).
// Relaunching the app while it runs (double-click without a file) also stops.

import AppKit
import CFluidSynth

let soundFontPath = NSHomeDirectory() + "/Library/Audio/Sounds/Banks/GeneralUser-GS.sf2"
let synthGain = 0.6

// MARK: - Tempo map (tick → seconds), parsed from the SMF itself

struct TempoMap {
    private var division = 480
    private var smpteTicksPerSecond: Double?
    // (tick, microseconds per quarter) sorted by tick
    private var changes: [(tick: Int, usPerQuarter: Int)] = [(0, 500_000)]

    init(url: URL) {
        guard let d = try? Data(contentsOf: url), d.count >= 14,
              d.prefix(4) == Data("MThd".utf8) else { return }
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
        let headerLen = u32(4)
        let div = u16(12)
        if div & 0x8000 != 0 {
            let fps = Double(256 - (div >> 8))
            smpteTicksPerSecond = (fps == 29 ? 29.97 : fps) * Double(div & 0xFF)
            return
        }
        division = max(div, 1)
        var found: [(Int, Int)] = []
        var pos = 8 + headerLen
        while pos + 8 <= b.count {
            let len = u32(pos + 4)
            let isTrack = b[pos..<pos + 4].elementsEqual("MTrk".utf8)
            let end = min(pos + 8 + len, b.count)
            if isTrack { found += Self.tempoEvents(b, from: pos + 8, to: end) }
            pos = end
        }
        if !found.isEmpty {
            found.sort { $0.0 < $1.0 }
            if found[0].0 != 0 { found.insert((0, 500_000), at: 0) }
            changes = found.map { (tick: $0.0, usPerQuarter: $0.1) }
        }
    }

    private static func tempoEvents(_ b: [UInt8], from start: Int, to end: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = start, tick = 0, running: UInt8 = 0
        func vlq() -> Int {
            var v = 0
            while i < end { let c = b[i]; i += 1; v = v << 7 | Int(c & 0x7F); if c & 0x80 == 0 { break } }
            return v
        }
        while i < end {
            tick += vlq()
            guard i < end else { break }
            var status = b[i]
            if status & 0x80 != 0 { i += 1 } else { status = running }
            switch status {
            case 0xFF:
                guard i < end else { return out }
                let type = b[i]; i += 1
                let len = vlq()
                if type == 0x51, len == 3, i + 3 <= end {
                    out.append((tick, Int(b[i]) << 16 | Int(b[i + 1]) << 8 | Int(b[i + 2])))
                }
                i += len
            case 0xF0, 0xF7:
                i += vlq()
            default:
                guard status & 0x80 != 0 else { return out } // corrupt: no running status
                running = status
                i += (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 1 : 2
            }
        }
        return out
    }

    func seconds(atTick tick: Int) -> Double {
        if let tps = smpteTicksPerSecond { return Double(tick) / tps }
        var sec = 0.0
        for (n, c) in changes.enumerated() where c.tick < tick {
            let next = n + 1 < changes.count ? min(changes[n + 1].tick, tick) : tick
            sec += Double(next - c.tick) * Double(c.usPerQuarter) / 1_000_000 / Double(division)
        }
        return sec
    }
}

func formatTime(_ s: Double) -> String {
    let t = Int(s.rounded(.down))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                     : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Engine: synth + audio driver live for the app's lifetime, player per file

final class Engine {
    private let settings: OpaquePointer
    private let synth: OpaquePointer
    private var driver: OpaquePointer?
    private var player: OpaquePointer?
    private(set) var tempoMap: TempoMap?
    private(set) var isPaused = false
    // fluid_player_seek while stopped only takes effect on the next play,
    // and get_current_tick keeps reporting the old position until then.
    private var pendingTick: Int?

    init() {
        fluid_set_log_function(Int32(FLUID_WARN.rawValue), nil, nil)
        settings = new_fluid_settings()
        fluid_settings_setnum(settings, "synth.gain", synthGain)
        synth = new_fluid_synth(settings)
        fluid_synth_sfload(synth, soundFontPath, 1)
        driver = new_fluid_audio_driver(settings, synth)
    }

    deinit {
        unload()
        if let driver { delete_fluid_audio_driver(driver) }
        delete_fluid_synth(synth)
        delete_fluid_settings(settings)
    }

    func load(_ url: URL) -> Bool {
        unload()
        let p = new_fluid_player(synth)!
        guard fluid_player_add(p, url.path) == FLUID_OK else { delete_fluid_player(p); return false }
        player = p
        tempoMap = TempoMap(url: url)
        isPaused = false
        pendingTick = nil
        fluid_player_play(p)
        return true
    }

    func unload() {
        guard let p = player else { return }
        fluid_player_stop(p)
        fluid_synth_all_notes_off(synth, -1)
        delete_fluid_player(p)
        fluid_synth_system_reset(synth)
        player = nil
    }

    var totalTicks: Int { player.map { Int(fluid_player_get_total_ticks($0)) } ?? 0 }

    var currentTick: Int {
        if let t = pendingTick { return t }
        guard let p = player else { return 0 }
        return min(Int(fluid_player_get_current_tick(p)), totalTicks)
    }

    /// True once the file has played to the end (not merely paused).
    var isFinished: Bool {
        guard let p = player else { return true }
        return !isPaused && fluid_player_get_status(p) == Int32(FLUID_PLAYER_DONE.rawValue)
    }

    func pause() {
        guard let p = player, !isPaused else { return }
        fluid_player_stop(p)
        fluid_synth_all_notes_off(synth, -1)
        isPaused = true
    }

    func resume() {
        guard let p = player, isPaused else { return }
        isPaused = false
        fluid_player_play(p)
        // keep showing the target until the player has actually moved there
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.pendingTick = nil }
    }

    func seek(toTick tick: Int) {
        guard let p = player else { return }
        let t = max(0, min(tick, totalTicks - 1))
        fluid_synth_all_notes_off(synth, -1)
        fluid_player_seek(p, Int32(t))
        pendingTick = t
        if !isPaused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.pendingTick = nil }
        }
    }
}

// MARK: - Menu content view

final class PlayerView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let playPauseButton = NSButton()
    let stopButton = NSButton()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 96))
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        slider.isContinuous = true
        for (b, symbol, tip) in [(playPauseButton, "pause.fill", "暫停"), (stopButton, "stop.fill", "停止")] {
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.imageScaling = .scaleProportionallyUpOrDown
            b.toolTip = tip
        }
        for v in [titleLabel, timeLabel, slider, playPauseButton, stopButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            slider.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            timeLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 6),
            timeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            stopButton.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            stopButton.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 18),
            stopButton.heightAnchor.constraint(equalToConstant: 18),
            playPauseButton.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
            playPauseButton.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -14),
            playPauseButton.widthAnchor.constraint(equalToConstant: 18),
            playPauseButton.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var engine = Engine()
    private var statusItem: NSStatusItem?
    private let view = PlayerView()
    private var timer: Timer?
    private var dragging = false
    private var fileName = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a document: nothing to play.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if self.statusItem == nil { NSApp.terminate(nil) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        guard engine.load(url) else {
            NSLog("FluidSynth Player: cannot load %@", url.path)
            if statusItem == nil { NSApp.terminate(nil) }
            return
        }
        fileName = url.deletingPathExtension().lastPathComponent
        setUpStatusItem()
        refresh()
    }

    // Double-clicking the app while it runs = stop.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        stop()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.unload()
    }

    private func setUpStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        let viewItem = NSMenuItem()
        viewItem.view = view
        menu.addItem(viewItem)
        item.menu = menu
        statusItem = item

        view.slider.target = self
        view.slider.action = #selector(sliderMoved(_:))
        view.playPauseButton.target = self
        view.playPauseButton.action = #selector(togglePlayPause)
        view.stopButton.target = self
        view.stopButton.action = #selector(stop)

        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common) // keep updating while the menu is open
        timer = t
    }

    private func tick() {
        if engine.isFinished { NSApp.terminate(nil); return }
        refresh()
    }

    private func refresh() {
        let total = engine.totalTicks
        let map = engine.tempoMap
        let totalSec = map?.seconds(atTick: total) ?? 0
        view.titleLabel.stringValue = fileName
        view.slider.maxValue = Double(max(total, 1))
        if !dragging { view.slider.doubleValue = Double(engine.currentTick) }
        let shownTick = dragging ? Int(view.slider.doubleValue) : engine.currentTick
        let sec = map?.seconds(atTick: shownTick) ?? 0
        view.timeLabel.stringValue = "\(formatTime(sec)) / \(formatTime(totalSec))"

        let paused = engine.isPaused
        view.playPauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                             accessibilityDescription: paused ? "播放" : "暫停")
        view.playPauseButton.toolTip = paused ? "播放" : "暫停"
        let icon = NSImage(systemSymbolName: paused ? "pause.circle" : "music.note",
                           accessibilityDescription: "FluidSynth Player")
        icon?.isTemplate = true
        statusItem?.button?.image = icon
        statusItem?.button?.toolTip = "\(fileName)（\(paused ? "已暫停" : "播放中")）"
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        let type = NSApp.currentEvent?.type
        if type == .leftMouseUp || type == nil || type == .keyDown {
            dragging = false
            engine.seek(toTick: Int(sender.doubleValue))
        } else {
            dragging = true
        }
        refresh()
    }

    @objc private func togglePlayPause() {
        engine.isPaused ? engine.resume() : engine.pause()
        refresh()
    }

    @objc private func stop() {
        statusItem?.menu?.cancelTracking()
        NSApp.terminate(nil)
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

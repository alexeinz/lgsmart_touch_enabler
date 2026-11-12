import CoreGraphics
import Testing
@testable import TouchCore

@Suite struct PermissionsTests {
    @Test func resetCoversBothGrantsForTheBundle() {
        #expect(Permissions.resetArguments(bundleID: "com.example.app") == [
            ["reset", "Accessibility", "com.example.app"],
            ["reset", "ListenEvent", "com.example.app"],
        ])
    }
}

@Suite struct ConfigTests {
    @Test func roundTrip() throws {
        var c = TouchConfig()
        c.scrollSpeed = 2.5; c.rotation = 90; c.displayID = 42
        c.setShortcut(Shortcut(keyCode: 12, flags: [.maskCommand, .maskShift]), for: .swipe4Up)
        #expect(try Fixture.roundTrip(c) == c)
    }

    @Test func missingKeysFallBackToDefaults() throws {
        let c = try Fixture.decode(#"{"scrollSpeed": 3}"#)
        #expect(c.scrollSpeed == 3)
        #expect(c.moveThreshold == TouchConfig().moveThreshold)
        #expect(c.enabled)
    }

    @Test func newGestureTogglesDefaultOnAndDecode() throws {
        let d = try Fixture.decode("{}")
        #expect(d.momentumScroll && d.twoFingerTapRightClick)
        let c = try Fixture.decode(#"{"momentumScroll": false}"#)
        #expect(!c.momentumScroll && c.twoFingerTapRightClick)
    }

    @Test func helperTogglesDefaultsAndDecode() throws {
        let d = try Fixture.decode("{}")
        #expect(!d.windowEdgeGrab && !d.windowThreeFingerDrag && !d.holdToSelect)
        #expect(d.windowSnap && d.touchMagnet && d.touchRipple && d.tripleTapSelectLine)
        let c = try Fixture.decode(#"{"windowEdgeGrab": true, "grabZone": 999}"#)
        #expect(c.windowEdgeGrab)
        #expect(c.sanitized().grabZone == 80)
    }

    @Test func storeSaveLoad() {
        let store = ConfigStore(url: Fixture.tempURL())
        #expect(!store.exists)
        #expect(store.load() == TouchConfig())
        var c = TouchConfig(); c.invertScroll = true
        #expect(store.save(c))
        #expect(store.exists)
        #expect(store.load().invertScroll)
    }

    @Test func corruptFileIsQuarantinedAndDefaultsReturned() throws {
        let url = Fixture.tempURL()
        try Fixture.writeCorrupt(at: url)
        let store = ConfigStore(url: url)
        #expect(store.load() == TouchConfig())
        #expect(Fixture.exists(url.path + ".bad"))
    }

    @Test func sanitizeClampsValues() {
        var c = TouchConfig()
        c.scrollSpeed = 999; c.rotation = 45; c.zoomStep = 0.1; c.swipeDistance = -1
        let s = c.sanitized()
        #expect(s.scrollSpeed <= 10)
        #expect(s.rotation == 0)
        #expect(s.zoomStep >= 1.02)
        #expect(s.swipeDistance >= 0.01)
    }

    @Test func settingDefaultShortcutRemovesOverride() {
        var c = TouchConfig()
        c.setShortcut(Shortcut(keyCode: 5), for: .swipe3Left)
        #expect(c.bindings.count == 1)
        c.setShortcut(GestureID.swipe3Left.defaultShortcut, for: .swipe3Left)
        #expect(c.bindings.isEmpty)
    }

    @Test func resetSensitivityKeepsBindingsAndDisplay() {
        var c = TouchConfig()
        c.scrollSpeed = 3; c.displayID = 7
        c.setShortcut(.disabled, for: .swipe5Up)
        c.resetSensitivity()
        #expect(c.scrollSpeed == TouchConfig().scrollSpeed)
        #expect(c.displayID == 7)
        #expect(c.shortcut(for: .swipe5Up).isDisabled)
    }

    @Test func everyGestureHasDefaultAndFingerCount() {
        for g in GestureID.allCases {
            #expect((1...5).contains(g.fingers))
            #expect(!g.title.isEmpty)
        }
    }
}

@Suite struct DisplayMappingTests {
    let b = CGRect(x: 100, y: 50, width: 1000, height: 500)

    @Test func identity() {
        #expect(Displays.map(CGPoint(x: 0.5, y: 0.5), rotation: 0, bounds: b) == CGPoint(x: 600, y: 300))
        #expect(Displays.map(CGPoint(x: 0, y: 0), rotation: 0, bounds: b) == CGPoint(x: 100, y: 50))
    }

    @Test func rotation180() {
        #expect(Displays.map(CGPoint(x: 0, y: 0), rotation: 180, bounds: b) == CGPoint(x: 1100, y: 550))
    }

    @Test func rotation90And270AreInverse() {
        let p = CGPoint(x: 0.2, y: 0.7)
        let a = Displays.map(p, rotation: 90, bounds: b)
        let c = Displays.map(p, rotation: 270, bounds: b)
        // 90 and 270 map to opposite corners of each other around the centre
        #expect(abs((a.x - 600) + (c.x - 600)) < 0.001)
        #expect(abs((a.y - 300) + (c.y - 300)) < 0.001)
    }
}

@Suite struct ShortcutTests {
    @Test func disabledHasNoKey() {
        #expect(Shortcut.disabled.isDisabled)
        #expect(!Shortcut(keyCode: 1).isDisabled)
    }

    @Test func flagsRoundTrip() {
        let s = Shortcut(keyCode: 4, flags: [.maskControl, .maskAlternate])
        #expect(s.cgFlags.contains(.maskControl))
        #expect(s.cgFlags.contains(.maskAlternate))
        #expect(!s.cgFlags.contains(.maskCommand))
    }

    @Test func displayStringMentionsModifiers() {
        let s = Shortcut(keyCode: Shortcut.kLeft, flags: .maskControl)
        #expect(s.displayString.contains("⌃"))
    }
}

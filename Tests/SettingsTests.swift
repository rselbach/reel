import Testing
import Foundation
@testable import Reel

// MARK: - HotkeyCombo Tests

@Suite("HotkeyCombo")
struct HotkeyComboTests {
    @Test("Default hotkey is Cmd+Shift+R")
    func defaultHotkey() {
        let combo = AppSettings.HotkeyCombo.default
        #expect(combo.keyCode == 15)  // R key
        #expect(combo.modifiers == 0x120000)  // Cmd + Shift
    }

    @Test("Display string shows correct symbols")
    func displayString() {
        let tests: [(keyCode: UInt16, modifiers: UInt32, want: String)] = [
            (15, 0x100000, "⌘R"),           // Cmd+R
            (15, 0x120000, "⇧⌘R"),          // Cmd+Shift+R
            (15, 0x180000, "⌥⌘R"),          // Cmd+Option+R
            (15, 0x1A0000, "⌥⇧⌘R"),         // Cmd+Option+Shift+R
            (15, 0x140000, "⌃⌘R"),          // Cmd+Control+R
            (49, 0x100000, "⌘Space"),       // Cmd+Space
            (122, 0x100000, "⌘F1"),         // Cmd+F1
            (29, 0x120000, "⇧⌘0"),          // Cmd+Shift+0
        ]

        for tc in tests {
            let combo = AppSettings.HotkeyCombo(keyCode: tc.keyCode, modifiers: tc.modifiers)
            #expect(combo.displayString == tc.want, "keyCode=\(tc.keyCode), modifiers=\(tc.modifiers)")
        }
    }

    @Test("Unknown keycode shows question mark")
    func unknownKeyCode() {
        let combo = AppSettings.HotkeyCombo(keyCode: 255, modifiers: 0x100000)
        #expect(combo.displayString == "⌘?")
    }

    @Test("JSON round-trip preserves values")
    func jsonRoundTrip() throws {
        let original = AppSettings.HotkeyCombo(keyCode: 42, modifiers: 0x1A0000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.HotkeyCombo.self, from: data)
        #expect(decoded == original)
    }

    @Test("Modifier mask filters device-dependent bits")
    func modifierMask() {
        // Modifier mask should keep only Cmd|Opt|Ctrl|Shift
        let fullFlags: UInt32 = 0xFFFFFFFF
        let masked = fullFlags & AppSettings.HotkeyCombo.modifierMask
        #expect(masked == 0x1E0000)
    }
}

// MARK: - VideoQuality Tests

@Suite("VideoQuality")
struct VideoQualityTests {
    @Test("Bitrates are in expected order")
    func bitrateOrder() {
        let qualities = AppSettings.VideoQuality.allCases
        var previousBitrate = 0
        for quality in qualities {
            #expect(quality.bitrate > previousBitrate, "\(quality) should have higher bitrate than previous")
            previousBitrate = quality.bitrate
        }
    }

    @Test("Specific bitrate values")
    func bitrateValues() {
        let tests: [(AppSettings.VideoQuality, Int)] = [
            (.low, 5_000_000),
            (.medium, 10_000_000),
            (.high, 20_000_000),
            (.maximum, 50_000_000),
        ]

        for (quality, want) in tests {
            #expect(quality.bitrate == want)
        }
    }

    @Test("Raw values are human-readable")
    func rawValues() {
        for quality in AppSettings.VideoQuality.allCases {
            #expect(quality.rawValue.contains("Mbps"))
        }
    }
}

// MARK: - CameraOverlaySize Tests

@Suite("CameraOverlaySize")
struct CameraOverlaySizeTests {
    @Test("Fractions are in expected order")
    func fractionOrder() {
        let small = AppSettings.CameraOverlaySize.small.fraction
        let medium = AppSettings.CameraOverlaySize.medium.fraction
        let large = AppSettings.CameraOverlaySize.large.fraction

        #expect(small < medium)
        #expect(medium < large)
    }

    @Test("Specific fraction values")
    func fractionValues() {
        #expect(AppSettings.CameraOverlaySize.small.fraction == 0.15)
        #expect(AppSettings.CameraOverlaySize.medium.fraction == 0.2)
        #expect(AppSettings.CameraOverlaySize.large.fraction == 0.25)
    }

    @Test("Fractions are reasonable percentages")
    func fractionRange() {
        for size in AppSettings.CameraOverlaySize.allCases {
            #expect(size.fraction > 0, "\(size) fraction should be positive")
            #expect(size.fraction < 0.5, "\(size) fraction should be less than half screen")
        }
    }
}

// MARK: - CameraOverlayPosition Tests

@Suite("CameraOverlayPosition")
struct CameraOverlayPositionTests {
    @Test("All four corners are represented")
    func allCorners() {
        let positions = AppSettings.CameraOverlayPosition.allCases
        #expect(positions.count == 4)

        let rawValues = Set(positions.map(\.rawValue))
        #expect(rawValues.contains("Bottom Left"))
        #expect(rawValues.contains("Bottom Right"))
        #expect(rawValues.contains("Top Left"))
        #expect(rawValues.contains("Top Right"))
    }
}

// MARK: - CameraOverlayShape Tests

@Suite("CameraOverlayShape")
struct CameraOverlayShapeTests {
    @Test("Both shapes are available")
    func allShapes() {
        let shapes = AppSettings.CameraOverlayShape.allCases
        #expect(shapes.count == 2)
        #expect(shapes.contains(.rectangle))
        #expect(shapes.contains(.circle))
    }
}

// MARK: - KeyCode Tests

@Suite("KeyCode")
struct KeyCodeTests {
    @Test("Letter key codes match Carbon virtual key codes")
    func letterKeyCodes() {
        // These are well-known Carbon virtual key codes
        #expect(KeyCode.a == 0)
        #expect(KeyCode.s == 1)
        #expect(KeyCode.d == 2)
        #expect(KeyCode.r == 15)  // Used in default hotkey
        #expect(KeyCode.q == 12)
    }

    @Test("Function key codes are defined")
    func functionKeyCodes() {
        #expect(KeyCode.f1 == 122)
        #expect(KeyCode.f12 == 111)
    }

    @Test("Special key codes")
    func specialKeyCodes() {
        #expect(KeyCode.escape == 53)
        #expect(KeyCode.space == 49)
        #expect(KeyCode.return == 36)
        #expect(KeyCode.tab == 48)
        #expect(KeyCode.delete == 51)
    }
}

// MARK: - RecordingSelection Tests

@Suite("RecordingSelection")
struct RecordingSelectionTests {
    @Test("Display selections compare by index")
    func displayEquality() {
        #expect(RecordingSelection.display(0) == RecordingSelection.display(0))
        #expect(RecordingSelection.display(0) != RecordingSelection.display(1))
    }

    @Test("Different types are not equal")
    func differentTypes() {
        // Can't easily test window equality without SCWindow, but we can test type mismatch
        let display = RecordingSelection.display(0)
        // This would require an SCWindow to test properly
        // Just verify the enum cases exist
        #expect(display == .display(0))
    }
}

// MARK: - ExportError Tests

@Suite("ExportError")
struct ExportErrorTests {
    @Test("Session creation failed has description")
    func sessionCreationFailed() {
        let error = ExportError.sessionCreationFailed
        #expect(error.errorDescription != nil)
        #expect(error.errorDescription!.contains("export session"))
    }
}

// MARK: - RecordingMode Tests

@Suite("RecordingMode")
struct RecordingModeTests {
    @Test("Both modes exist")
    func modesExist() {
        let display = RecordingMode.display
        let window = RecordingMode.window
        // Just verify they're distinct
        switch display {
        case .display: break
        case .window: Issue.record("display should not match window")
        }
        switch window {
        case .window: break
        case .display: Issue.record("window should not match display")
        }
    }
}

// MARK: - HotkeyCombo Edge Cases

@Suite("HotkeyCombo Edge Cases")
struct HotkeyComboEdgeCaseTests {
    @Test("No modifiers produces just the key")
    func noModifiers() {
        let combo = AppSettings.HotkeyCombo(keyCode: KeyCode.r, modifiers: 0)
        #expect(combo.displayString == "R")
    }

    @Test("All modifiers combined")
    func allModifiers() {
        // Cmd + Opt + Ctrl + Shift
        let combo = AppSettings.HotkeyCombo(keyCode: KeyCode.a, modifiers: 0x1E0000)
        #expect(combo.displayString == "⌃⌥⇧⌘A")
    }

    @Test("Function keys display correctly")
    func functionKeys() {
        let tests: [(UInt16, String)] = [
            (KeyCode.f1, "F1"),
            (KeyCode.f5, "F5"),
            (KeyCode.f12, "F12"),
        ]
        for (keyCode, expected) in tests {
            let combo = AppSettings.HotkeyCombo(keyCode: keyCode, modifiers: 0)
            #expect(combo.displayString == expected)
        }
    }

    @Test("Number keys display correctly")
    func numberKeys() {
        let numberCodes: [(UInt16, String)] = [
            (KeyCode.zero, "0"),
            (KeyCode.one, "1"),
            (KeyCode.nine, "9"),
        ]
        for (keyCode, expected) in numberCodes {
            let combo = AppSettings.HotkeyCombo(keyCode: keyCode, modifiers: 0)
            #expect(combo.displayString == expected)
        }
    }

    @Test("Equality is value-based")
    func equality() {
        let a = AppSettings.HotkeyCombo(keyCode: 15, modifiers: 0x100000)
        let b = AppSettings.HotkeyCombo(keyCode: 15, modifiers: 0x100000)
        let c = AppSettings.HotkeyCombo(keyCode: 15, modifiers: 0x120000)

        #expect(a == b)
        #expect(a != c)
    }
}

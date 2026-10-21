# Niimbu

A native macOS and iOS label app for NIIMBOT printers. It is built for the **D110 M**. Other D-series printers and the B1 share the same code paths but are untested.

- **Editor:** text, QR codes, Code 128 barcodes and images (threshold or dithered). The canvas shows the exact 1-bit image that will print. Drag elements to move them; drag the corner handle to resize.
- **Label detection:** the printer's RFID reader identifies genuine rolls, giving the label type and labels remaining. It is read on connect and again when the lid opens or closes. The label type is filled in automatically and can be overridden. If the printer reports the roll size, the canvas resizes to match.
- **Print settings:** density, copies, label type and fast/quality speed.
- **Diagnostics:** a packet log. Turn on "Log every packet" under Printer › Diagnostics.

## Layout

- `NiimbotKit/` is a Swift package containing the protocol: packets, image encoding, print sequences and the CoreBluetooth transport. It has no UI.
  - Run its tests with `cd NiimbotKit && swift test`.
  - The tests replay a real D110 M (firmware 4.23) capture and use a fake printer to check the print packet order.
- `Niimbu/` contains the SwiftUI app, shared by macOS and iOS.
- `project.yml` defines the project for [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Building

```sh
brew install xcodegen
xcodegen generate
open Niimbu.xcodeproj
```

1. Choose the `Niimbu-macOS` or `Niimbu-iOS` scheme.
2. To run on an iPhone, set your team under Signing & Capabilities and change the bundle id in `project.yml`.

Bluetooth doesn't work in the iOS Simulator; use a real device or the Mac app.

## Printing on a D110 M

- The printhead is 96 dots (12 mm) wide, so the label height across the printhead is capped at 12 mm. On a 15 mm roll the extra edge stays blank.
- With firmware that reports protocol v4 (e.g. 4.23), the app uses the D110 M v4 print sequence. Older firmware uses the B1 sequence.

## Credits

- The protocol is ported from [niimbluelib](https://github.com/MultiMote/niimbluelib) by MultiMote (MIT License), with reference to [NiimPrintX](https://github.com/labbots/NiimPrintX), [niimprint](https://github.com/AndBondStyle/niimprint) and [kjy00302/niimprint](https://github.com/kjy00302/niimprint).
- The D110 M packet capture in the tests comes from niimbluelib.

Not affiliated with NIIMBOT.

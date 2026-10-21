import Foundation

/// Command ids sent to the printer. Ported from niimbluelib (MIT, MultiMote).
public enum RequestCommand: UInt8, Sendable {
    case printStart = 0x01
    case pageStart = 0x03
    case setPageSize = 0x13
    case printQuantity = 0x15
    case rfidInfo = 0x1A
    case printClear = 0x20
    case setDensity = 0x21
    case setLabelType = 0x23
    case setAutoShutdownTime = 0x27
    case soundSettings = 0x58
    case printerInfo = 0x40
    case getPaperInfo = 0x59
    case printBitmapRowIndexed = 0x83
    /// Feeds until the gap sensor finds a label edge. Barely documented; on B1 it feeds ~15 cm.
    /// On a D110 M (firmware 4.31) it just feeds one label length from wherever the paper is, so it doesn't
    /// realign; printing a blank label does.
    case labelPositioningCalibration = 0x8E
    case printEmptyRow = 0x84
    case printBitmapRow = 0x85
    case printerCheckLine = 0x86
    case printStatus = 0xA3
    case printerStatusData = 0xA5
    case getPrinterCapabilities = 0xAF
    case connect = 0xC1
    case cancelPrint = 0xDA
    case heartbeat = 0xDC
    case pageEnd = 0xE3
    case printEnd = 0xF3
}

/// Command ids sent by the printer.
public enum ResponseCommand: UInt8, Sendable {
    case notSupported = 0x00
    case printStart = 0x02
    case pageStart = 0x04
    case setPageSize = 0x14
    case printQuantity = 0x16
    case rfidInfo = 0x1B
    case printClear = 0x30
    case setDensity = 0x31
    case setLabelType = 0x33
    case setAutoShutdownTime = 0x37
    case soundSettings = 0x68
    case paperInfo = 0x69
    case printStatus = 0xB3
    case printerStatusData = 0xB5
    case printerCapabilities = 0xBF
    case connect = 0xC2
    case cancelPrint = 0xD0
    case printerCheckLine = 0xD3
    case labelPositioningCalibration = 0x8F
    case heartbeatAdvanced2 = 0xD9
    case printError = 0xDB
    case heartbeatAdvanced1 = 0xDD
    case heartbeatBasic = 0xDE
    case heartbeatPrinterInfo = 0xDF
    case pageIndex = 0xE0
    case pageEnd = 0xE4
    case printEnd = 0xF4
}

extension RequestCommand {
    /// Responses that complete a request; empty for one-way packets (bitmap rows).
    var responseIds: Set<UInt8> {
        let r: [ResponseCommand]
        switch self {
        case .printBitmapRow, .printBitmapRowIndexed, .printEmptyRow: return []
        case .printerInfo:
            // PrinterInfo responses are 0x40 + info type.
            return Set((0x41...0x4F).map { UInt8($0) })
        case .heartbeat: r = [.heartbeatBasic, .heartbeatPrinterInfo, .heartbeatAdvanced1, .heartbeatAdvanced2]
        case .printStart: r = [.printStart]
        case .pageStart: r = [.pageStart]
        case .setPageSize: r = [.setPageSize]
        case .printQuantity: r = [.printQuantity]
        case .rfidInfo: r = [.rfidInfo]
        case .printClear: r = [.printClear]
        case .setDensity: r = [.setDensity]
        case .setLabelType: r = [.setLabelType]
        case .setAutoShutdownTime: r = [.setAutoShutdownTime]
        case .soundSettings: r = [.soundSettings]
        case .getPaperInfo: r = [.paperInfo]
        case .printerCheckLine: r = [.printerCheckLine]
        case .labelPositioningCalibration: r = [.labelPositioningCalibration]
        case .printStatus: r = [.printStatus]
        case .printerStatusData: r = [.printerStatusData]
        case .getPrinterCapabilities: r = [.printerCapabilities]
        case .connect: r = [.connect]
        case .cancelPrint: r = [.cancelPrint]
        case .pageEnd: r = [.pageEnd]
        case .printEnd: r = [.printEnd]
        }
        return Set(r.map(\.rawValue))
    }
}

/// Printer sounds that can be switched on and off.
public enum PrinterSound: UInt8, Sendable, CaseIterable {
    case bluetoothConnection = 1
    case power = 2
}

public enum PrinterInfoType: UInt8, Sendable {
    case density = 1, speed = 2, labelType = 3, language = 6, autoShutdownTime = 7
    case modelId = 8, softwareVersion = 9, batteryChargeLevel = 10, serialNumber = 11
    case hardwareVersion = 12, bluetoothAddress = 13, printMode = 14, area = 15
}

public enum HeartbeatType: UInt8, Sendable {
    case advanced1 = 1, basic = 2, printerInfo = 3, advanced2 = 4
}

public enum ConnectResult: UInt8, Sendable {
    case disconnect = 0, connected = 1, connectedNew = 2, connectedV3 = 3, firmwareErrors = 90
}

public enum LabelType: UInt8, CaseIterable, Identifiable, Sendable {
    case invalid = 0
    case withGaps = 1
    case black = 2
    case continuous = 3
    case perforated = 4
    case transparent = 5
    case pvcTag = 6
    case blackMarkGap = 10
    case heatShrinkTube = 11

    public var id: UInt8 { rawValue }

    public var displayName: String {
        switch self {
        case .invalid: "Unknown"
        case .withGaps: "Paper labels"
        case .black: "Black-mark tape"
        case .continuous: "Continuous tape"
        case .perforated: "Perforated labels"
        case .transparent: "Clear labels"
        case .pvcTag: "PVC tags"
        case .blackMarkGap: "Black-mark labels"
        case .heatShrinkTube: "Heat-shrink tube"
        }
    }
}

public enum PrinterErrorCode: UInt8, Sendable {
    case coverOpen = 0x01, lackPaper = 0x02, lowBattery = 0x03, batteryException = 0x04
    case userCancel = 0x05, dataError = 0x06, overheat = 0x07, paperOutException = 0x08
    case printerBusy = 0x09, noPrinterHead = 0x0A, temperatureLow = 0x0B
    case printerHeadLoose = 0x0C, noRibbon = 0x0D, wrongRibbon = 0x0E
    case usedRibbon = 0x0F, wrongPaper = 0x10, setPaperFail = 0x11
    case setPrintModeFail = 0x12, setPrintDensityFail = 0x13, writeRfidFail = 0x14
    case setMarginFail = 0x15, communicationException = 0x16, disconnect = 0x17
    case canvasParameterError = 0x18, rotationParameterException = 0x19
    case jsonParameterException = 0x1A, b3sAbnormalPaperOutput = 0x1B
    case eCheckPaper = 0x1C, rfidTagNotWritten = 0x1D, setPrintDensityNoSupport = 0x1E
    case setPrintModeNoSupport = 0x1F, setPrintLabelMaterialError = 0x20
    case setPrintLabelMaterialNoSupport = 0x21, notSupportWrittenRfid = 0x22
    case illegalPage = 0x32, illegalRibbonPage = 0x33, receiveDataTimeout = 0x34
    case nonDedicatedRibbon = 0x35
}

public enum NiimbotError: LocalizedError, Equatable {
    case malformedPacket(String)
    case timeout(String)
    case notConnected
    case notSupported
    case printError(UInt8)
    case unexpectedResponse(String)
    case unsupportedModel(String)
    case bluetooth(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .malformedPacket(let m): "Malformed packet: \(m)"
        case .timeout(let m): "Printer did not respond (\(m))"
        case .notConnected: "Printer is not connected"
        case .notSupported: "The printer does not support this command"
        case .printError(let code):
            "Printer error \(code)" + (PrinterErrorCode(rawValue: code).map { ": \($0)" } ?? "")
        case .unexpectedResponse(let m): "Unexpected response: \(m)"
        case .unsupportedModel(let m): "Unsupported printer: \(m)"
        case .bluetooth(let m): "Bluetooth: \(m)"
        case .cancelled: "Cancelled"
        }
    }
}

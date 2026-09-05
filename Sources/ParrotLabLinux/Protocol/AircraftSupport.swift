// Snapshot of mac/ParrotLab/Sources/ParrotLab/AircraftSupport.swift; see PORTING.md.
import Foundation

enum ParrotVideoCodec: Equatable {
    case h264
    case mjpeg
}

enum ParrotCommandFamily: Equatable {
    case arDrone3
    case jumpingSumo
    case unknown
}

enum ParrotProductModel: String, Equatable, Codable {
    case unknown
    case bebopDrone
    case bebop2
    case jumpingSumo

    init(productID: UInt16) {
        switch productID {
        case 0x0901: self = .bebopDrone
        case 0x0902: self = .jumpingSumo
        case 0x090c: self = .bebop2
        default: self = .unknown
        }
    }

    var productID: UInt16? {
        switch self {
        case .unknown: return nil
        case .bebopDrone: return 0x0901
        case .jumpingSumo: return 0x0902
        case .bebop2: return 0x090c
        }
    }

    var displayName: String {
        switch self {
        case .unknown: return "Parrot product — detecting model"
        case .bebopDrone: return "Bebop Drone"
        case .bebop2: return "Bebop 2"
        case .jumpingSumo: return "Jumping Sumo"
        }
    }

    var shortLabel: String {
        switch self {
        case .unknown: return "PARROT"
        case .bebopDrone: return "BB1"
        case .bebop2: return "BB2"
        case .jumpingSumo: return "SUMO"
        }
    }

    var mediaFilenameToken: String { shortLabel }
    var isGroundProduct: Bool { self == .jumpingSumo }

    var capabilities: ParrotProductCapabilities {
        ParrotProductCapabilities(model: self)
    }
}

struct ParrotProductCapabilities: Equatable {
    let model: ParrotProductModel

    var commandFamily: ParrotCommandFamily {
        switch model {
        case .bebopDrone, .bebop2: return .arDrone3
        case .jumpingSumo: return .jumpingSumo
        case .unknown: return .unknown
        }
    }

    var videoCodec: ParrotVideoCodec { model == .jumpingSumo ? .mjpeg : .h264 }
    var supportsSharedARDrone3Commands: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsJumpingSumoCommands: Bool { model == .jumpingSumo }
    var supportsStockCompatibilityVideo: Bool { model != .unknown }
    var usesARStream1Video: Bool { model == .bebopDrone || model == .jumpingSumo }
    var supportsStockFisheyePhoto: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsBebopCalibration: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsFlightNavigation: Bool { model == .bebopDrone || model == .bebop2 }
    var supportsGroundDriving: Bool { model == .jumpingSumo }
    var supportsBB2DragonLab: Bool { model == .bebop2 }
    var supportsBB2CameraCalibration: Bool { model == .bebop2 }
    var supportsBB2PersistentTelnetInstall: Bool { model == .bebop2 }
    var supportsValidatedRFMod: Bool { model == .bebop2 }
}

enum ParrotVideoSource: Equatable {
    case directARStream1(ParrotVideoCodec)
    case directARStream2H264
    case skyControllerRestream
}

enum ParrotSessionRouting {
    static func routeAfterDetection(
        current: ARSDKConnectionRoute,
        product _: ParrotProductModel
    ) -> ARSDKConnectionRoute {
        current
    }

    static func videoSource(
        route: ARSDKConnectionRoute,
        product: ParrotProductModel
    ) -> ParrotVideoSource {
        if route == .skyController { return .skyControllerRestream }
        if product.capabilities.usesARStream1Video {
            return .directARStream1(product.capabilities.videoCodec)
        }
        return .directARStream2H264
    }
}

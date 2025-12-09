//
//  StreamTimeLimit.swift
//  RayBanPriceScanner
//
//  Created by Ali Khan on 12/6/25.
//

import Foundation

/// Time limits used by StreamSessionViewModel to optionally stop streaming after a duration.
enum StreamTimeLimit: CaseIterable, Identifiable {
    case noLimit
    case seconds30
    case minute1
    case minutes5

    var id: String { label }

    /// Human-readable label (if you ever want a picker in UI).
    var label: String {
        switch self {
        case .noLimit:   return "No limit"
        case .seconds30: return "30 sec"
        case .minute1:   return "1 min"
        case .minutes5:  return "5 min"
        }
    }

    /// Duration in seconds (nil = unlimited).
    var durationInSeconds: TimeInterval? {
        switch self {
        case .noLimit:   return nil
        case .seconds30: return 30
        case .minute1:   return 60
        case .minutes5:  return 5 * 60
        }
    }

    /// Convenience flag used in StreamSessionViewModel.
    var isTimeLimited: Bool {
        durationInSeconds != nil
    }
}

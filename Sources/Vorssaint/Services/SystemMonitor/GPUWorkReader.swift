// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import IOKit

/// Reads per-client accumulated GPU time from the graphics accelerator.
/// The headline percentage and the per-app list both diff these counters, so
/// a screen redraw counts for the time the GPU actually ran it.
enum GPUWorkReader {
    /// Longer than the 10s closed-panel GPU stride, including timer tolerance.
    /// A gap past this is a pause: the average over the pause is not current.
    static let maximumSampleGap: TimeInterval = 15

    /// `nil` when the accelerator registry cannot be opened. An empty dictionary
    /// is a real reading of a machine with no GPU clients.
    static func snapshot() -> [UInt64: GPUClientWork]? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var clients: [UInt64: GPUClientWork] = [:]
        // The advance lives in the `while` condition so `defer` only releases.
        // Advancing inside `defer` and then returning leaked the next entry.
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            var children = io_iterator_t()
            guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == kIOReturnSuccess
            else { continue }
            defer { IOObjectRelease(children) }

            while case let client = IOIteratorNext(children), client != 0 {
                defer { IOObjectRelease(client) }
                record(client, into: &clients)
            }
        }
        return clients
    }

    private static func record(_ client: io_registry_entry_t, into clients: inout [UInt64: GPUClientWork]) {
        guard let creatorRef = IORegistryEntryCreateCFProperty(
                  client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0),
              let creator = creatorRef.takeRetainedValue() as? String,
              let pid = pid(fromCreator: creator)
        else { return }

        guard let usageRef = IORegistryEntryCreateCFProperty(
                  client, "AppUsage" as CFString, kCFAllocatorDefault, 0),
              let usage = usageRef.takeRetainedValue() as? [[String: Any]]
        else { return }

        var nanoseconds = 0.0
        for entry in usage {
            guard let time = gpuNanoseconds(entry["accumulatedGPUTime"]) else { continue }
            nanoseconds += time
        }
        guard nanoseconds > 0 else { return }

        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(client, &entryID) == kIOReturnSuccess else { return }
        let existing = clients[entryID]?.nanoseconds ?? 0
        clients[entryID] = GPUClientWork(pid: pid, nanoseconds: existing + nanoseconds)
    }

    /// "pid 437, WindowServer" → 437
    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        return pid_t(digits)
    }

    private static func gpuNanoseconds(_ value: Any?) -> Double? {
        let time: Double?
        switch value {
        case let number as Double:
            time = number
        case let number as Int:
            time = Double(number)
        case let number as Int64:
            time = Double(number)
        case let number as UInt64:
            time = Double(number)
        case let number as NSNumber:
            time = number.doubleValue
        default:
            time = nil
        }
        guard let time, time.isFinite, time >= 0 else { return nil }
        return time
    }
}

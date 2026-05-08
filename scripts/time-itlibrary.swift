#!/usr/bin/env swift
//
// time-itlibrary.swift — micro-benchmark for the new ITLibrary playlist read.
//
// Usage:
//   scripts/time-itlibrary.swift
//
// Prints how long ITLibrary takes to enumerate user playlists, three times in a row
// (first run pays page-cache cost; second/third runs show steady-state).

import Foundation
import iTunesLibrary

func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
}

func timeOnce(_ label: String) {
    let start = nowMs()
    do {
        let library = try ITLibrary(apiVersion: "1.0")
        let userPlaylists = library.allPlaylists.filter { p in
            !p.isPrimary && p.distinguishedKind == .kindNone && p.kind != .folder
        }
        let summaries = userPlaylists.map { p in
            "\(p.items.count)\t\(p.name)"
        }
        let elapsed = nowMs() - start
        print(String(format: "  %-30s %6.1f ms — %d playlist(s)", label, elapsed, summaries.count))
        if label == "cold" {
            for s in summaries.prefix(5) { print("    \(s)") }
            if summaries.count > 5 { print("    ... (+\(summaries.count - 5) more)") }
        }
    } catch {
        print("  \(label): ERROR — \(error.localizedDescription)")
    }
}

print("=== ITLibrary playlist enumeration ===")
timeOnce("cold")
timeOnce("hot 1")
timeOnce("hot 2")

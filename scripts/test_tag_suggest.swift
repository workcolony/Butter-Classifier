#!/usr/bin/env swift
import Foundation

// Minimal smoke test mirroring TagSuggester token + vocabulary logic.
let jsonURL = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: jsonURL)
struct TokenRules: Decodable {
    var tokens: [String: [String]]
}
let rules = try JSONDecoder().decode(TokenRules.self, from: data)

var vocabulary: [String: String] = [:]
func register(_ tag: String) {
    let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    vocabulary[t.lowercased()] = t
}
for (tag, aliases) in rules.tokens {
    register(tag)
    if let canon = vocabulary[tag.lowercased()] {
        for alias in aliases { vocabulary[alias.lowercased()] = canon }
    }
}

func tokenize(_ text: String) -> [String] {
    text.lowercased()
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split { !$0.isLetter && !$0.isNumber }
        .map(String.init)
        .filter { !$0.isEmpty }
}

func match(_ token: String) -> String? {
    vocabulary[token.lowercased()]
}

let names = ["kick_01.wav", "SnareDrum.wav", "808_bass.wav", "hihat_open.wav"]
for name in names {
    let stem = (name as NSString).deletingPathExtension
    let hits = tokenize(stem).compactMap { t -> String? in
        guard let tag = match(t) else { return nil }
        return "\(t)->\(tag)"
    }
    print("\(name): \(hits.isEmpty ? "NONE" : hits.joined(separator: ", "))")
}

#!/usr/bin/env swift
import Foundation
import NaturalLanguage

struct InputRow: Decodable {
    let id: String
    let source: String
    let text: String
    let label: Int
    let split: String
}

struct OutputRow: Encodable {
    let id: String
    let source: String
    let label: Int
    let split: String
    let vector: [Double]
}

func option(_ name: String, default defaultValue: String) -> String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return defaultValue }
    return args[index + 1]
}

func compact(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

let inputURL = URL(fileURLWithPath: option("--input", default: ""))
let outputURL = URL(fileURLWithPath: option("--output", default: ""))
let maxCharacters = Int(option("--max-characters", default: "4000")) ?? 4000
guard !inputURL.path.isEmpty, !outputURL.path.isEmpty else {
    fatalError("Usage: export_nlembedding_features.swift --input rows.jsonl --output features.jsonl [--max-characters 4000]")
}
guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
    fatalError("English sentence embedding is unavailable on this Mac")
}

let input = try String(contentsOf: inputURL, encoding: .utf8)
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
FileManager.default.createFile(atPath: outputURL.path, contents: nil)
let handle = try FileHandle(forWritingTo: outputURL)
defer { try? handle.close() }

let decoder = JSONDecoder()
let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
var exported = 0
for rawLine in input.split(separator: "\n") {
    guard let data = String(rawLine).data(using: .utf8) else { continue }
    let row = try decoder.decode(InputRow.self, from: data)
    let text = String("source=\(row.source)\n\(compact(row.text))".prefix(maxCharacters))
    guard let vector = embedding.vector(for: text) else { continue }
    let output = OutputRow(id: row.id, source: row.source, label: row.label, split: row.split, vector: vector)
    let encoded = try encoder.encode(output)
    handle.write(encoded)
    handle.write(Data([0x0A]))
    exported += 1
    if exported % 500 == 0 {
        FileHandle.standardError.write(Data("exported \(exported)\n".utf8))
    }
}
FileHandle.standardError.write(Data("exported \(exported)\n".utf8))

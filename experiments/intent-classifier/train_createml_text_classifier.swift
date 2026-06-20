#!/usr/bin/env swift
import CreateML
import Darwin
import Foundation
import NaturalLanguage

struct CorpusRow {
    let id: String
    let source: String
    let text: String
}

struct LabeledRow {
    let id: String
    let source: String
    let text: String
    let label: Bool
}

struct MetricRow {
    let threshold: Double
    let precision: Double
    let recall: Double
    let wakeRate: Double
    let tp: Int
    let fp: Int
    let fn: Int
    let tn: Int
}

func option(_ name: String, default defaultValue: String) -> String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return defaultValue }
    return args[index + 1]
}

func hasFlag(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

func compact(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
}

func exampleText(_ row: CorpusRow) -> String {
    "source=\(row.source)\n\(compact(row.text))"
}

func readJSONLines(_ url: URL) throws -> [[String: Any]] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }
    var rows: [[String: Any]] = []
    for rawLine in String(decoding: handle.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            rows.append(object)
        }
    }
    return rows
}

func loadCorpus(_ url: URL) throws -> [String: CorpusRow] {
    var corpus: [String: CorpusRow] = [:]
    for row in try readJSONLines(url) {
        guard let id = row["id"] as? String else { continue }
        corpus[id] = CorpusRow(
            id: id,
            source: row["source"] as? String ?? "unknown",
            text: row["text"] as? String ?? ""
        )
    }
    return corpus
}

func matchesAny(_ filename: String, patterns: [String]) -> Bool {
    patterns.contains { pattern in
        fnmatch(pattern, filename, 0) == 0
    }
}

func loadVotes(labelDir: URL, holdoutPatterns: [String]) throws -> (train: [String: [Bool]], holdout: [String: [Bool]]) {
    var train: [String: [Bool]] = [:]
    var holdout: [String: [Bool]] = [:]
    let files = try FileManager.default.contentsOfDirectory(
        at: labelDir,
        includingPropertiesForKeys: nil
    )
        .filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    for file in files {
        let isHoldout = matchesAny(file.lastPathComponent, patterns: holdoutPatterns)
        for row in try readJSONLines(file) {
            guard let id = row["record_id"] as? String else { continue }
            let shouldWake = row["should_wake"] as? Bool ?? false
            if isHoldout {
                holdout[id, default: []].append(shouldWake)
            } else {
                train[id, default: []].append(shouldWake)
            }
        }
    }
    return (train, holdout)
}

func resolve(_ votes: [String: [Bool]]) -> [String: Bool] {
    votes.mapValues { values in
        values.filter { $0 }.count >= values.filter { !$0 }.count
    }
}

func rows(corpus: [String: CorpusRow], labels: [String: Bool]) -> [LabeledRow] {
    labels.compactMap { id, label in
        guard let row = corpus[id] else { return nil }
        return LabeledRow(id: id, source: row.source, text: exampleText(row), label: label)
    }
    .sorted { $0.id < $1.id }
}

func metric(yTrue: [Bool], scores: [Double], threshold: Double) -> MetricRow {
    var tp = 0
    var fp = 0
    var fn = 0
    var tn = 0
    for (label, score) in zip(yTrue, scores) {
        let pred = score >= threshold
        if pred && label { tp += 1 }
        else if pred && !label { fp += 1 }
        else if !pred && label { fn += 1 }
        else { tn += 1 }
    }
    let precision = tp + fp == 0 ? 0.0 : Double(tp) / Double(tp + fp)
    let recall = tp + fn == 0 ? 0.0 : Double(tp) / Double(tp + fn)
    let wakeRate = yTrue.isEmpty ? 0.0 : Double(tp + fp) / Double(yTrue.count)
    return MetricRow(threshold: threshold, precision: precision, recall: recall, wakeRate: wakeRate, tp: tp, fp: fp, fn: fn, tn: tn)
}

func thresholds() -> [Double] {
    stride(from: 0.05, through: 0.95, by: 0.005).map { (value: Double) in
        (value * 1000).rounded() / 1000
    }
}

func bestMetric(yTrue: [Bool], scores: [Double], precisionFloor: Double) -> MetricRow {
    let rows = thresholds().map { metric(yTrue: yTrue, scores: scores, threshold: $0) }
    let viable = rows.filter { $0.precision >= precisionFloor && $0.tp > 0 }
    if viable.isEmpty {
        return rows.max {
            ($0.precision, $0.recall, -$0.wakeRate) < ($1.precision, $1.recall, -$1.wakeRate)
        }!
    }
    return viable.max {
        ($0.recall, $0.precision, -$0.wakeRate) < ($1.recall, $1.precision, -$1.wakeRate)
    }!
}

func algorithm(named name: String) -> MLTextClassifier.ModelAlgorithmType {
    switch name {
    case "bert":
        return .transferLearning(.bertEmbedding, revision: nil)
    case "elmo":
        return .transferLearning(.elmoEmbedding, revision: nil)
    case "static":
        return .transferLearning(.staticEmbedding, revision: nil)
    default:
        return .maxEnt(revision: 1)
    }
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let corpusURL = URL(fileURLWithPath: option("--corpus", default: repo.appendingPathComponent("feedback/intent-classifier/chat-corpus.jsonl").path))
let labelDir = URL(fileURLWithPath: option("--label-dir", default: repo.appendingPathComponent("feedback/intent-classifier/subagent-labels").path))
let holdoutPattern = option("--holdout-pattern", default: "*round7*.jsonl")
let algorithmName = option("--algorithm", default: "bert")
let outputURL = URL(fileURLWithPath: option("--output", default: repo.appendingPathComponent("feedback/intent-classifier/createml-text-round7.mlmodel").path))
let reportURL = URL(fileURLWithPath: option("--report", default: repo.appendingPathComponent("feedback/intent-classifier/createml-text-round7-report.md").path))
let precisionFloor = Double(option("--precision-floor", default: "0.95")) ?? 0.95

let corpus = try loadCorpus(corpusURL)
let voteSets = try loadVotes(labelDir: labelDir, holdoutPatterns: [holdoutPattern])
let trainRows = rows(corpus: corpus, labels: resolve(voteSets.train))
let holdoutRows = rows(corpus: corpus, labels: resolve(voteSets.holdout))
guard trainRows.contains(where: { $0.label }) && trainRows.contains(where: { !$0.label }) else {
    fatalError("Need both train classes")
}
guard !holdoutRows.isEmpty else {
    fatalError("Holdout pattern produced no rows")
}

let trainingData = Dictionary(grouping: trainRows, by: { $0.label ? "wake" : "no_wake" })
    .mapValues { rows in rows.map(\.text) }
var parameters = MLTextClassifier.ModelParameters(
    validation: .none,
    algorithm: algorithm(named: algorithmName),
    language: .english
)
parameters.maxIterations = Int(option("--max-iterations", default: "25"))

let classifier = try MLTextClassifier(trainingData: trainingData, parameters: parameters)
let holdoutTexts = holdoutRows.map(\.text)
let confidences = try classifier.predictionsWithConfidence(from: holdoutTexts)
let scores = confidences.map { $0["wake"] ?? 0.0 }
let yTrue = holdoutRows.map(\.label)
let best = bestMetric(yTrue: yTrue, scores: scores, precisionFloor: precisionFloor)
let ranked = thresholds()
    .map { metric(yTrue: yTrue, scores: scores, threshold: $0) }
    .sorted {
        ($0.precision, $0.recall, -$0.wakeRate) > ($1.precision, $1.recall, -$1.wakeRate)
    }
    .prefix(15)

try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try classifier.write(to: outputURL)

let trainWake = trainRows.filter(\.label).count
let holdoutWake = holdoutRows.filter(\.label).count
var lines: [String] = []
lines.append("# Create ML Text Classifier Round-7 Report")
lines.append("")
lines.append("Algorithm: `\(algorithmName)`")
lines.append("Output: `\(outputURL.path)`")
lines.append("Holdout pattern: `\(holdoutPattern)`")
lines.append("Precision floor: \(String(format: "%.3f", precisionFloor))")
lines.append("")
lines.append("| split | rows | wake | no wake |")
lines.append("| --- | ---: | ---: | ---: |")
lines.append("| train | \(trainRows.count) | \(trainWake) | \(trainRows.count - trainWake) |")
lines.append("| round-7 holdout | \(holdoutRows.count) | \(holdoutWake) | \(holdoutRows.count - holdoutWake) |")
lines.append("")
lines.append("## Selected Holdout Metric")
lines.append("")
lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
lines.append(String(format: "| %.3f | %.4f | %.4f | %.4f | %d | %d | %d | %d |", best.threshold, best.precision, best.recall, best.wakeRate, best.tp, best.fp, best.fn, best.tn))
lines.append("")
lines.append("## Top Thresholds")
lines.append("")
lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for row in ranked {
    lines.append(String(format: "| %.3f | %.4f | %.4f | %.4f | %d | %d | %d | %d |", row.threshold, row.precision, row.recall, row.wakeRate, row.tp, row.fp, row.fn, row.tn))
}
try lines.joined(separator: "\n").appending("\n").write(to: reportURL, atomically: true, encoding: .utf8)
print(reportURL.path)

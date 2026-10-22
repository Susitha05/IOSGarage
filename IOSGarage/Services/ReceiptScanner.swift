import UIKit
import Vision

struct ScannedReceipt { var vendor: String; var total: Double?; var date: Date?; var text: String }

enum ReceiptScanner {
    enum ScanError: Error { case badImage }

    static func scan(_ image: UIImage) async throws -> ScannedReceipt {
        guard let cg = image.cgImage else { throw ScanError.badImage }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try await Task.detached { try VNImageRequestHandler(cgImage: cg).perform([req]) }.value
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return parse(lines)
    }

    static func parse(_ lines: [String]) -> ScannedReceipt {
        let vendor = lines.first { $0.trimmingCharacters(in: .whitespaces).count > 2 } ?? "Unknown"
        let numRegex = try! NSRegularExpression(pattern: #"[0-9]{1,3}(?:,[0-9]{3})*(?:\.[0-9]{1,2})?|[0-9]+(?:\.[0-9]{1,2})?"#)
        func numbers(in s: String) -> [Double] {
            numRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
                Double(String(s[Range($0.range, in: s)!]).replacingOccurrences(of: ",", with: ""))
            }
        }
        var total: Double?
        for l in lines where l.lowercased().contains("total") && !l.lowercased().contains("sub") {
            if let n = numbers(in: l).max() { total = n }
        }
        if total == nil { total = lines.flatMap(numbers).max() }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        let joined = lines.joined(separator: "\n")
        let date = detector?.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined))?.date
        return ScannedReceipt(vendor: vendor, total: total, date: date, text: joined)
    }
}

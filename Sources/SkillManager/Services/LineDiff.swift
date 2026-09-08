import Foundation

/// One rendered row of a unified diff.
struct DiffLine: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        case context
        case insertion
        case deletion
        /// Stands in for a run of unchanged lines that was collapsed away.
        case gap
    }

    /// Position in the diff — stable for as long as the diff exists, which is
    /// all `ForEach` needs and cheaper than handing out UUIDs per line.
    let id: Int
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

/// Line-based unified diff, the minimum that makes a review panel readable.
enum LineDiff {
    /// Unchanged lines kept around each change.
    static let contextLines = 3

    /// Ceiling for the O(n·m) table. Above it the file is reported as a wholesale
    /// replacement instead — still correct, just less precise, and it keeps a
    /// stray multi-megabyte text file from allocating gigabytes.
    static let maxAlignedLines = 2000

    /// Diffs two documents and returns the rows to render, long unchanged runs
    /// collapsed into `.gap`.
    static func unified(old: String, new: String) -> [DiffLine] {
        let oldLines = lines(of: old)
        let newLines = lines(of: new)
        guard oldLines != newLines else { return [] }
        return collapse(operations(old: oldLines, new: newLines))
    }

    /// Splits into lines without inventing a trailing empty one for the final
    /// newline, so "a\n" and "a" both come out as a single line.
    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private enum Operation {
        case keep(String)
        case insert(String)
        case delete(String)
    }

    /// Common head and tail are matched off cheaply first — for an edit inside a
    /// long file that leaves only a handful of lines for the quadratic part.
    private static func operations(old: [String], new: [String]) -> [Operation] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }

        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        let middle: [Operation]
        if oldMiddle.count > maxAlignedLines && newMiddle.count > maxAlignedLines {
            middle = oldMiddle.map { .delete($0) } + newMiddle.map { .insert($0) }
        } else {
            middle = align(oldMiddle, newMiddle)
        }

        return old[0..<prefix].map { .keep($0) }
            + middle
            + old[(old.count - suffix)...].map { .keep($0) }
    }

    /// Longest common subsequence, walked forward into an edit script.
    private static func align(_ old: [String], _ new: [String]) -> [Operation] {
        if old.isEmpty { return new.map { .insert($0) } }
        if new.isEmpty { return old.map { .delete($0) } }

        let rows = old.count + 1
        let columns = new.count + 1
        // table[i * columns + j] = LCS length of old[i...] and new[j...].
        var table = [Int32](repeating: 0, count: rows * columns)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i * columns + j] = old[i] == new[j]
                    ? table[(i + 1) * columns + j + 1] + 1
                    : max(table[(i + 1) * columns + j], table[i * columns + j + 1])
            }
        }

        var operations: [Operation] = []
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                operations.append(.keep(old[i]))
                i += 1
                j += 1
            } else if table[(i + 1) * columns + j] >= table[i * columns + j + 1] {
                operations.append(.delete(old[i]))
                i += 1
            } else {
                operations.append(.insert(new[j]))
                j += 1
            }
        }
        operations += old[i...].map { .delete($0) }
        operations += new[j...].map { .insert($0) }
        return operations
    }

    /// Numbers the rows and drops unchanged stretches that are further than
    /// `contextLines` from any edit.
    private static func collapse(_ operations: [Operation]) -> [DiffLine] {
        // Distance to the nearest change, so a run between two edits that is
        // short enough stays visible in full.
        var keepVisible = [Bool](repeating: false, count: operations.count)
        var lastChange = -1
        for (index, operation) in operations.enumerated() {
            if case .keep = operation {} else { lastChange = index }
            if lastChange >= 0, index - lastChange <= contextLines { keepVisible[index] = true }
        }
        lastChange = -1
        for index in stride(from: operations.count - 1, through: 0, by: -1) {
            if case .keep = operations[index] {} else { lastChange = index }
            if lastChange >= 0, lastChange - index <= contextLines { keepVisible[index] = true }
        }

        var rows: [DiffLine] = []
        var oldNumber = 1
        var newNumber = 1
        var hiddenRun = 0
        for (index, operation) in operations.enumerated() {
            if !keepVisible[index] {
                hiddenRun += 1
                oldNumber += 1
                newNumber += 1
                continue
            }
            if hiddenRun > 0 {
                rows.append(DiffLine(
                    id: rows.count,
                    kind: .gap,
                    text: "\(hiddenRun) unchanged line\(hiddenRun == 1 ? "" : "s")",
                    oldNumber: nil,
                    newNumber: nil
                ))
                hiddenRun = 0
            }
            switch operation {
            case .keep(let text):
                rows.append(DiffLine(
                    id: rows.count, kind: .context, text: text,
                    oldNumber: oldNumber, newNumber: newNumber
                ))
                oldNumber += 1
                newNumber += 1
            case .delete(let text):
                rows.append(DiffLine(
                    id: rows.count, kind: .deletion, text: text,
                    oldNumber: oldNumber, newNumber: nil
                ))
                oldNumber += 1
            case .insert(let text):
                rows.append(DiffLine(
                    id: rows.count, kind: .insertion, text: text,
                    oldNumber: nil, newNumber: newNumber
                ))
                newNumber += 1
            }
        }
        if hiddenRun > 0 {
            rows.append(DiffLine(
                id: rows.count,
                kind: .gap,
                text: "\(hiddenRun) unchanged line\(hiddenRun == 1 ? "" : "s")",
                oldNumber: nil,
                newNumber: nil
            ))
        }
        return rows
    }
}

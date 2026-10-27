/// Python difflib's matching-block algorithm, including popular-element filtering.
struct SequenceMatcher<Element: Hashable> {
    struct Match: Equatable { var a: Int; var b: Int; var size: Int }
    struct Opcode: Equatable { let tag: String; let i1: Int; let i2: Int; let j1: Int; let j2: Int }
    let a: [Element]
    let b: [Element]
    private let b2j: [Element: [Int]]

    init(_ a: [Element], _ b: [Element], autojunk: Bool = true) {
        self.a = a
        self.b = b
        var index: [Element: [Int]] = [:]
        for (i, element) in b.enumerated() { index[element, default: []].append(i) }
        if autojunk && b.count >= 200 {
            let limit = b.count / 100 + 1
            index = index.filter { $0.value.count <= limit }
        }
        b2j = index
    }

    private func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> Match {
        var best = Match(a: alo, b: blo, size: 0)
        var previous: [Int: Int] = [:]
        for i in alo..<ahi {
            var lengths: [Int: Int] = [:]
            for j in b2j[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let size = (previous[j - 1] ?? 0) + 1
                lengths[j] = size
                if size > best.size { best = Match(a: i - size + 1, b: j - size + 1, size: size) }
            }
            previous = lengths
        }
        // No isjunk predicate is used by cleanup. Popular elements can extend a match.
        while best.a > alo && best.b > blo && a[best.a - 1] == b[best.b - 1] {
            best.a -= 1; best.b -= 1; best.size += 1
        }
        while best.a + best.size < ahi && best.b + best.size < bhi && a[best.a + best.size] == b[best.b + best.size] {
            best.size += 1
        }
        return best
    }

    func matchingBlocks() -> [Match] {
        var queue = [(0, a.count, 0, b.count)]
        var matches: [Match] = []
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let match = longest(alo, ahi, blo, bhi)
            if match.size == 0 { continue }
            matches.append(match)
            if alo < match.a && blo < match.b { queue.append((alo, match.a, blo, match.b)) }
            if match.a + match.size < ahi && match.b + match.size < bhi {
                queue.append((match.a + match.size, ahi, match.b + match.size, bhi))
            }
        }
        matches.sort { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }
        var collapsed: [Match] = []
        for match in matches {
            if let last = collapsed.last, last.a + last.size == match.a && last.b + last.size == match.b {
                collapsed[collapsed.count - 1].size += match.size
            } else { collapsed.append(match) }
        }
        collapsed.append(Match(a: a.count, b: b.count, size: 0))
        return collapsed
    }

    func opcodes() -> [Opcode] {
        var i = 0, j = 0
        var result: [Opcode] = []
        for match in matchingBlocks() {
            let tag = i < match.a ? (j < match.b ? "replace" : "delete") : (j < match.b ? "insert" : "")
            if !tag.isEmpty { result.append(Opcode(tag: tag, i1: i, i2: match.a, j1: j, j2: match.b)) }
            if match.size > 0 {
                result.append(Opcode(tag: "equal", i1: match.a, i2: match.a + match.size, j1: match.b, j2: match.b + match.size))
            }
            i = match.a + match.size; j = match.b + match.size
        }
        return result
    }

    func ratio() -> Double {
        let length = a.count + b.count
        return length == 0 ? 1 : 2 * Double(matchingBlocks().reduce(0) { $0 + $1.size }) / Double(length)
    }
}

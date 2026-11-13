// Swipe path -> ranked words. Only words that start near where the finger went down and end
// near where it lifted are considered; each candidate's ideal path is compared with the swipe
// (a quick pass, then dynamic time warping for the best few hundred), and the result is
// weighed with how common the word is and your own history with it. Same as core.js.

import Foundation

public struct DecoderParams {
    public var samples = 50
    public var band = 12
    public var endRadius = 1.4
    public var maxEndKeys = 4
    public var wLoc = 4.0
    public var wEnd = 1.0
    public var wFreq = 0.35
    public var wUser = 0.35
    public var prefilter = 300
    public var cheapSamples = 12
    public var minLengthRatio = 0.7
    public var maxLengthRatio = 2.2

    public init() {}
}

public struct SwipeResult: Equatable {
    public let word: String
    public let cost: Double
    public let lang: String?
}

let SRC_SHIFT = 0x1000000

public final class SwipeDecoder {
    public let params: DecoderParams
    public private(set) var cx = [Double](repeating: 0, count: 26)
    public private(set) var cy = [Double](repeating: 0, count: 26)
    public private(set) var keyWidth = 1.0
    public private(set) var hasGeometry = false
    private var gx: [Double]
    private var gy: [Double]
    private var tx: [Double]
    private var ty: [Double]
    private var dtwPrev: [Double]
    private var dtwCur: [Double]
    private var hx: [Double]
    private var hy: [Double]
    private var ux: [Double]
    private var uy: [Double]
    private var tpl = [Int32](repeating: 0, count: 64)
    private var tplX = [Double](repeating: 0, count: 64)
    private var tplY = [Double](repeating: 0, count: 64)
    private var dS = [Double](repeating: 0, count: 26)
    private var dE = [Double](repeating: 0, count: 26)
    private var candId = [Int32]()
    private var candCheap = [Double]()
    private var candFixed = [Double]()
    /// Where your finger goes for each key: the key centers moved by your swipe profile.
    private var ex = [Double](repeating: 0, count: 26)
    private var ey = [Double](repeating: 0, count: 26)
    /// Your swipe profile, or nil.
    public private(set) var profile: ProfileParams?
    private var gsx = 0.0
    private var gsy = 0.0
    private var gex = 0.0
    private var gey = 0.0

    public init(params: DecoderParams = DecoderParams()) {
        self.params = params
        let n = params.samples
        let c = params.cheapSamples
        gx = [Double](repeating: 0, count: n)
        gy = [Double](repeating: 0, count: n)
        tx = [Double](repeating: 0, count: n)
        ty = [Double](repeating: 0, count: n)
        dtwPrev = [Double](repeating: 0, count: n)
        dtwCur = [Double](repeating: 0, count: n)
        hx = [Double](repeating: 0, count: c)
        hy = [Double](repeating: 0, count: c)
        ux = [Double](repeating: 0, count: c)
        uy = [Double](repeating: 0, count: c)
        candId.reserveCapacity(4096)
        candCheap.reserveCapacity(4096)
        candFixed.reserveCapacity(4096)
    }

    /// Key centers for a..z and the width of one letter key, in the swipe's pixel space.
    public func setKeyCenters(_ xPx: [Double], _ yPx: [Double], _ keyWidthPx: Double) {
        keyWidth = keyWidthPx
        for i in 0..<26 {
            cx[i] = xPx[i] / keyWidthPx
            cy[i] = yPx[i] / keyWidthPx
        }
        hasGeometry = true
        placeKeys()
    }

    /// Uses a swipe profile (nil for none).
    public func setProfile(_ p: ProfileParams?) {
        profile = p
        placeKeys()
    }

    private func placeKeys() {
        for i in 0..<26 {
            if let P = profile {
                ex[i] = cx[i] + P.dx[i]
                ey[i] = cy[i] + P.dy[i]
            } else {
                ex[i] = cx[i]
                ey[i] = cy[i]
            }
        }
    }

    public var ready: Bool { hasGeometry }

    /// The path your finger is expected to take for the template in tpl[0..<t).
    private func placeNodes(_ t: Int) {
        guard let P = profile else {
            for i in 0..<t {
                tplX[i] = cx[Int(tpl[i])]
                tplY[i] = cy[Int(tpl[i])]
            }
            return
        }
        for i in 0..<t {
            tplX[i] = ex[Int(tpl[i])]
            tplY[i] = ey[Int(tpl[i])]
        }
        if t < 2 { return }
        var dir = (0.0, 0.0)
        tpl.withUnsafeBufferPointer { tp in
            for i in 0..<t {
                // Everyone's path rounds corners and the comparison already allows for that, so
                // only the first and last letters move.
                if i > 0 && i < t - 1 && !P.useCorner { continue }
                let role = nodeRole(cx, cy, tp.baseAddress!, t, i, &dir)
                if role < 0 { continue }
                let b = P.bias[role]
                tplX[i] += b.0 * dir.0 - b.1 * dir.1
                tplY[i] += b.0 * dir.1 + b.1 * dir.0
            }
        }
    }

    /// The word's key letters with repeats merged ("hello" -> h e l o). Returns the count.
    private func buildTemplate<C: Collection>(_ key: C) -> Int where C.Element == UInt8 {
        var t = 0
        var last: Int32 = -1
        for ch in key {
            if t >= 64 { break }
            let k = Int32(ch) - 97
            if k < 0 || k >= 26 { continue }
            if k != last {
                tpl[t] = k
                t += 1
                last = k
            }
        }
        return t
    }

    /// Pixel points -> key widths, dropping repeats. Returns the count kept.
    private func normalise(_ xs: [Double], _ ys: [Double], _ count: Int, _ px: inout [Double], _ py: inout [Double]) -> Int {
        var m = 0
        for i in 0..<count {
            let x = xs[i] / keyWidth
            let y = ys[i] / keyWidth
            if m > 0 && abs(x - px[m - 1]) + abs(y - py[m - 1]) < 1e-4 { continue }
            px[m] = x
            py[m] = y
            m += 1
        }
        return m
    }

    /// Lines up a swipe with the word it was meant to be, or nil.
    public func align(_ word: String, _ xs: [Double], _ ys: [Double], _ count: Int) -> Alignment? {
        if !hasGeometry { return nil }
        let key = keyOf(word)
        let t = buildTemplate(Array(key.utf8))
        if t < 2 || count < 2 { return nil }
        var px = [Double](repeating: 0, count: count)
        var py = [Double](repeating: 0, count: count)
        let m = normalise(xs, ys, count, &px, &py)
        if m < 2 { return nil }
        let nodes = Array(tpl[0..<t])
        let at = alignNodes(px, py, m, nodes, cx, cy)
        return Alignment(nodes: nodes, x: at.x, y: at.y, cx: cx, cy: cy)
    }

    /// Best first.
    public func decode(_ xs: [Double], _ ys: [Double], _ count: Int, _ sources: [Source], max: Int) -> [SwipeResult] {
        var out = [SwipeResult]()
        if !hasGeometry || count < 2 || sources.isEmpty { return out }
        let p = params
        var px = [Double](repeating: 0, count: count)
        var py = [Double](repeating: 0, count: count)
        let m = normalise(xs, ys, count, &px, &py)
        if m < 2 { return out }
        let gLen = px.withUnsafeBufferPointer { a in py.withUnsafeBufferPointer { b in pathLength(a.baseAddress!, b.baseAddress!, m) } }
        if gLen < 0.5 { return out }

        let n = p.samples
        resample(px, py, m, &gx, &gy, n)
        resample(px, py, m, &hx, &hy, p.cheapSamples)

        let sx = px[0]
        let sy = py[0]
        let exx = px[m - 1]
        let eyy = py[m - 1]
        gsx = sx
        gsy = sy
        gex = exx
        gey = eyy
        for k in 0..<26 {
            dS[k] = dist(sx, sy, ex[k], ey[k])
            dE[k] = dist(exx, eyy, ex[k], ey[k])
        }
        // With a profile, where you start and stop can sit further from the key (by your habit).
        let startOk: [Bool]
        let endOk: [Bool]
        if let prof = profile {
            startOk = nearestKeys(dS, p.endRadius + prof.reach[ROLE_START], p.maxEndKeys + 1)
            endOk = nearestKeys(dE, p.endRadius + prof.reach[ROLE_END], p.maxEndKeys + 1)
        } else {
            startOk = nearestKeys(dS, p.endRadius, p.maxEndKeys)
            endOk = nearestKeys(dE, p.endRadius, p.maxEndKeys)
        }

        // Pass 1: quick score for every word with a plausible first and last letter.
        let P = primaryOf(sources)
        candId.removeAll(keepingCapacity: true)
        candCheap.removeAll(keepingCapacity: true)
        candFixed.removeAll(keepingCapacity: true)
        for si in 0..<sources.count {
            let S = sources[si]
            let W = S.words
            let bias = S.bias
            let index = SourceIndex(S, P)
            let shared: SharedMap? = isForeign(S, P) ? sharedWith(W, P!.words) : nil
            for f in 0..<26 where startOk[f] {
                for l in 0..<26 where endOk[l] {
                    for id32 in W.withFirstLast(f, l) {
                        let id = Int(id32)
                        if let sh = shared, sh[id] { continue }
                        var prior = p.wFreq * (Double(W.score(id)) / 100 + bias)
                        prior += p.wUser * index.bonus(id)
                        consider(Int32(si * SRC_SHIFT + id), W.keyBytes(id), prior, gLen)
                    }
                }
            }
        }
        // Words you taught it, per language.
        var added = [(word: String, key: [UInt8], si: Int)]()
        for si in 0..<sources.count {
            let S = sources[si]
            let foreign = isForeign(S, P)
            for e in S.user.activeAdded() {
                let key = Array(keyOf(e.word).utf8)
                if key.isEmpty || S.words.find(e.word) >= 0 { continue }
                if foreign && P!.words.find(e.word) >= 0 { continue }
                if !startOk[Int(key[0]) - 97] || !endOk[Int(key[key.count - 1]) - 97] { continue }
                added.append((e.word, key, si))
                let prior = p.wFreq * (ADDED_WORD_ZIPF + S.bias) + p.wUser * bonusIn(S, P, e.word)
                consider(Int32(-added.count), key, prior, gLen)
            }
        }
        let c = candId.count
        if c == 0 { return out }

        // Pass 2: careful score for the best few hundred.
        let cheap = candCheap
        let order = (0..<c).sorted { a, b in cheap[a] < cheap[b] || (cheap[a] == cheap[b] && a < b) }
        let keep = min(c, p.prefilter)
        var finalCost = [Double](repeating: 0, count: keep)
        var finalWord = [String](repeating: "", count: keep)
        var finalSrc = [Int](repeating: 0, count: keep)
        for r in 0..<keep {
            let slot = order[r]
            let cid = Int(candId[slot])
            let t: Int
            if cid >= 0 {
                let S = sources[cid / SRC_SHIFT]
                let id = cid % SRC_SHIFT
                t = buildTemplate(S.words.keyBytes(id))
                finalWord[r] = S.words.display(id)
                finalSrc[r] = cid / SRC_SHIFT
            } else {
                let a = added[-cid - 1]
                t = buildTemplate(a.key)
                finalWord[r] = a.word
                finalSrc[r] = a.si
            }
            placeNodes(t)
            resampleTemplate(t, &tx, &ty, n)
            let d = dtw(n, p.band)
            finalCost[r] = p.wLoc * d + candFixed[slot]
        }
        let rank = (0..<keep).sorted { a, b in
            finalCost[a] < finalCost[b] || (finalCost[a] == finalCost[b] && a < b)
        }
        var seen = Set<String>()
        var i = 0
        while i < keep && out.count < max {
            let w = finalWord[rank[i]]
            let S = sources[finalSrc[rank[i]]]
            i += 1
            let lower = w.lowercased()
            if seen.contains(lower) { continue }
            if blockedIn(S, P, w) { continue }
            seen.insert(lower)
            out.append(SwipeResult(word: w, cost: finalCost[rank[i - 1]], lang: S.lang))
        }
        return out
    }

    private func consider<C: Collection>(_ id: Int32, _ key: C, _ prior: Double, _ gLen: Double) where C.Element == UInt8 {
        let p = params
        let t = buildTemplate(key)
        if t < 2 { return }
        placeNodes(t)
        var len = 0.0
        for i in 1..<t { len += dist(tplX[i - 1], tplY[i - 1], tplX[i], tplY[i]) }
        if len < p.minLengthRatio * gLen - 1 || len > p.maxLengthRatio * gLen + 1 { return }
        let fixed: Double
        if profile != nil {
            // Distance from where you started and stopped to where you'd start and stop for this word.
            let ds = dist(gsx, gsy, tplX[0], tplY[0])
            let de = dist(gex, gey, tplX[t - 1], tplY[t - 1])
            fixed = p.wEnd * (ds * ds + de * de) - prior
        } else {
            let f = Int(tpl[0])
            let l = Int(tpl[t - 1])
            fixed = p.wEnd * (dS[f] * dS[f] + dE[l] * dE[l]) - prior
        }
        resampleTemplate(t, &ux, &uy, p.cheapSamples)
        var sum = 0.0
        for i in 0..<p.cheapSamples { sum += dist(hx[i], hy[i], ux[i], uy[i]) }
        let cheapCost = p.wLoc * (sum / Double(p.cheapSamples)) + fixed
        candId.append(id)
        candCheap.append(cheapCost)
        candFixed.append(fixed)
    }

    /// Resamples the path placed by placeNodes(t).
    private func resampleTemplate(_ t: Int, _ ox: inout [Double], _ oy: inout [Double], _ n: Int) {
        resample(tplX, tplY, t, &ox, &oy, n)
    }

    private func nearestKeys(_ d: [Double], _ r: Double, _ most: Int) -> [Bool] {
        let idx = (0..<26).sorted { a, b in d[a] < d[b] || (d[a] == d[b] && a < b) }
        var ok = [Bool](repeating: false, count: 26)
        for i in 0..<min(most, 26) where i < 2 || d[idx[i]] <= r { ok[idx[i]] = true }
        return ok
    }

    /// Average distance between the swipe and the template after the best in-order alignment.
    private func dtw(_ n: Int, _ band: Int) -> Double {
        let inf = 1e30
        var prev = dtwPrev
        var cur = dtwCur
        for j in 0..<n { prev[j] = inf }
        for i in 0..<n {
            for j in 0..<n { cur[j] = inf }
            let lo = Swift.max(0, i - band)
            let hi = Swift.min(n - 1, i + band)
            var j = lo
            while j <= hi {
                let dx = gx[i] - tx[j]
                let dy = gy[i] - ty[j]
                let d = (dx * dx + dy * dy).squareRoot()
                var best: Double
                if i == 0 && j == 0 {
                    best = 0
                } else {
                    best = inf
                    if i > 0 {
                        if prev[j] < best { best = prev[j] }
                        if j > 0 && prev[j - 1] < best { best = prev[j - 1] }
                    }
                    if j > 0 && cur[j - 1] < best { best = cur[j - 1] }
                }
                cur[j] = d + best
                j += 1
            }
            swap(&prev, &cur)
        }
        dtwPrev = prev
        dtwCur = cur
        return prev[n - 1] / Double(n)
    }
}

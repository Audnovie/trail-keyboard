// How you swipe, learned from test swipes where the word is known (the Training rounds).
// Keeps running totals only, never the swipes themselves. Same maths as core.js.

import Foundation

@inline(__always)
func dist(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
    let dx = ax - bx
    let dy = ay - by
    return (dx * dx + dy * dy).squareRoot()
}

func pathLength(_ x: UnsafePointer<Double>, _ y: UnsafePointer<Double>, _ n: Int) -> Double {
    var len = 0.0
    var i = 1
    while i < n {
        len += dist(x[i - 1], y[i - 1], x[i], y[i])
        i += 1
    }
    return len
}

/// Resamples a polyline to n points spaced evenly along its length.
func resample(_ x: UnsafePointer<Double>, _ y: UnsafePointer<Double>, _ count: Int,
              _ ox: UnsafeMutablePointer<Double>, _ oy: UnsafeMutablePointer<Double>, _ n: Int) {
    let total = pathLength(x, y, count)
    if total <= 0 || count < 2 {
        for i in 0..<n {
            ox[i] = x[0]
            oy[i] = y[0]
        }
        return
    }
    let step = total / Double(n - 1)
    ox[0] = x[0]
    oy[0] = y[0]
    var outI = 1
    var carried = 0.0
    var prevX = x[0]
    var prevY = y[0]
    var i = 1
    while i < count && outI < n - 1 {
        let seg = dist(prevX, prevY, x[i], y[i])
        if carried + seg >= step && seg > 0 {
            let r = (step - carried) / seg
            let nx = prevX + r * (x[i] - prevX)
            let ny = prevY + r * (y[i] - prevY)
            ox[outI] = nx
            oy[outI] = ny
            outI += 1
            prevX = nx
            prevY = ny
            carried = 0
        } else {
            carried += seg
            prevX = x[i]
            prevY = y[i]
            i += 1
        }
    }
    while outI < n {
        ox[outI] = x[count - 1]
        oy[outI] = y[count - 1]
        outI += 1
    }
}

/// Array-friendly wrapper.
func resample(_ x: [Double], _ y: [Double], _ count: Int, _ ox: inout [Double], _ oy: inout [Double], _ n: Int) {
    x.withUnsafeBufferPointer { xb in
        y.withUnsafeBufferPointer { yb in
            ox.withUnsafeMutableBufferPointer { oxb in
                oy.withUnsafeMutableBufferPointer { oyb in
                    resample(xb.baseAddress!, yb.baseAddress!, count, oxb.baseAddress!, oyb.baseAddress!, n)
                }
            }
        }
    }
}

let ROLE_START = 0
let ROLE_CORNER = 1
let ROLE_END = 2
/// A letter where the path turns more than about 40 degrees counts as a corner.
let CORNER_MIN = 0.7
/// Points a swipe is resampled to before it's lined up with its letters.
let ALIGN_POINTS = 64
/// Each new test swipe makes the older ones count this much less, so the profile follows changes.
let PROFILE_DECAY = 0.997
/// Test swipes before the profile starts adjusting anything.
public let PROFILE_MIN_SWIPES = 20
/// About where more test swipes stop helping.
public let PROFILE_FULL_SWIPES = 150
/// A key's own offset counts fully only after about this many swipes over it.
let KEY_SHRINK = 8.0
let GLOBAL_SHRINK = 3.0
let ROLE_SHRINK = 5.0
/// A letter counts as missed when the swipe passes outside its key, made this much bigger.
let MISS_SLACK = 1.2

/// What a letter is in a word's path: the first one, a corner, the last one, or -1 for a letter
/// the path goes straight through. dir gets the direction its habit is measured along.
func nodeRole(_ cx: [Double], _ cy: [Double], _ tpl: UnsafePointer<Int32>, _ t: Int, _ i: Int, _ dir: inout (Double, Double)) -> Int {
    if t < 2 { return -1 }
    if i == 0 || i == t - 1 {
        let a = Int(i == 0 ? tpl[0] : tpl[t - 2])
        let b = Int(i == 0 ? tpl[1] : tpl[t - 1])
        let dx = cx[b] - cx[a]
        let dy = cy[b] - cy[a]
        let len = (dx * dx + dy * dy).squareRoot()
        if len < 1e-9 { return -1 }
        dir = (dx / len, dy / len)
        return i == 0 ? ROLE_START : ROLE_END
    }
    let p = Int(tpl[i - 1]), q = Int(tpl[i]), r = Int(tpl[i + 1])
    let ax = cx[q] - cx[p]
    let ay = cy[q] - cy[p]
    let bx = cx[r] - cx[q]
    let by = cy[r] - cy[q]
    let la = (ax * ax + ay * ay).squareRoot()
    let lb = (bx * bx + by * by).squareRoot()
    if la < 1e-9 || lb < 1e-9 { return -1 }
    let wx = bx / lb - ax / la
    let wy = by / lb - ay / la
    let lw = (wx * wx + wy * wy).squareRoot()
    if lw < CORNER_MIN { return -1 }
    dir = (wx / lw, wy / lw)
    return ROLE_CORNER
}

func nodeRole(_ cx: [Double], _ cy: [Double], _ nodes: [Int32], _ i: Int, _ dir: inout (Double, Double)) -> Int {
    nodes.withUnsafeBufferPointer { nodeRole(cx, cy, $0.baseAddress!, nodes.count, i, &dir) }
}

/// For each letter of a word (repeats merged), the point of the swipe that goes with it: the
/// first point for the first letter, the last point for the last, and for the ones between
/// the closest point, in order.
func alignNodes(_ px: [Double], _ py: [Double], _ m: Int, _ nodes: [Int32], _ cx: [Double], _ cy: [Double]) -> (x: [Double], y: [Double]) {
    let R = ALIGN_POINTS
    var ax = [Double](repeating: 0, count: R)
    var ay = [Double](repeating: 0, count: R)
    resample(px, py, m, &ax, &ay, R)
    let t = nodes.count
    var outX = [Double](repeating: 0, count: t)
    var outY = [Double](repeating: 0, count: t)
    outX[0] = px[0]
    outY[0] = py[0]
    outX[t - 1] = px[m - 1]
    outY[t - 1] = py[m - 1]
    if t > 2 {
        let INF = 1e30
        var best = [Double](repeating: INF, count: R)
        best[0] = 0
        var back = [[Int]](repeating: [], count: t)
        for j in 1...(t - 2) {
            let k = Int(nodes[j])
            var cur = [Double](repeating: 0, count: R)
            var bk = [Int](repeating: 0, count: R)
            var pm = INF
            var pi = 0
            for i in 0..<R {
                if best[i] < pm {
                    pm = best[i]
                    pi = i
                }
                let dx = ax[i] - cx[k]
                let dy = ay[i] - cy[k]
                cur[i] = pm + dx * dx + dy * dy
                bk[i] = pi
            }
            back[j] = bk
            best = cur
        }
        var i = 0
        for q in 1..<R where best[q] < best[i] { i = q }
        var j = t - 2
        while j >= 1 {
            outX[j] = ax[i]
            outY[j] = ay[i]
            i = back[j][i]
            j -= 1
        }
    }
    return (outX, outY)
}

/// A swipe lined up with the word it was meant to be (SwipeDecoder.align), in key widths.
public struct Alignment {
    /// Each letter's key (0-25), repeats merged.
    public let nodes: [Int32]
    /// The point of the swipe that goes with each letter.
    public let x: [Double]
    public let y: [Double]
    /// Key centers.
    public let cx: [Double]
    public let cy: [Double]
}

/// What stood out about one test swipe.
public struct SwipeNotes {
    /// Letters it missed, by index in Alignment.nodes.
    public let missed: [Int]
    /// How far past (+) or short of (-) the last letter it stopped, along the path.
    public let endAlong: Double
    /// How far past (+) or before (-) the first letter it started.
    public let startAlong: Double
}

/// The fitted profile the swipe reader uses: each key's offset, and the start, corner and end
/// habits as [along, across] the path.
public struct ProfileParams {
    public let dx: [Double]
    public let dy: [Double]
    public let overall: (Double, Double)
    public let bias: [(Double, Double)]
    public let reach: [Double]
    /// Experiments only: also move corner letters.
    public var useCorner = false
}

public struct ProfileSummary {
    public struct MissedKey {
        public let key: String
        public let seen: Double
        public let missRate: Double
    }

    public let total: Int
    public let ready: Bool
    public let progress: Double
    public let keysSeen: Int
    public let start: (Double, Double)?
    public let corner: (Double, Double)?
    public let end: (Double, Double)?
    public let overall: (Double, Double)?
    public let missedKeys: [MissedKey]
    public let ab: SwipeProfile.AB
}

public final class SwipeProfile {
    public struct AB: Codable, Equatable {
        /// Test swipes since it switched on.
        public var n: Double = 0
        /// Right first time with it.
        public var on: Double = 0
        /// Would have been right first time without it.
        public var off: Double = 0
    }

    /// Test swipes learned from.
    public private(set) var total = 0
    /// The same, with older ones counting a little less.
    private(set) var n = 0.0
    /// Letters seen.
    private(set) var N = 0.0
    var sy = [Double](repeating: 0, count: 2)
    var nk = [Double](repeating: 0, count: 26)
    var syk = [Double](repeating: 0, count: 52)
    var missk = [Double](repeating: 0, count: 26)
    var nr = [Double](repeating: 0, count: 3)
    var su = [Double](repeating: 0, count: 6)
    var sry = [Double](repeating: 0, count: 6)
    var m2 = [Double](repeating: 0, count: 6)
    var nkr = [Double](repeating: 0, count: 78)
    var suk = [Double](repeating: 0, count: 156)
    public var ab = AB()
    private var fitted: ProfileParams?

    public init() {}

    public func reset() {
        total = 0
        n = 0
        N = 0
        sy = [Double](repeating: 0, count: 2)
        nk = [Double](repeating: 0, count: 26)
        syk = [Double](repeating: 0, count: 52)
        missk = [Double](repeating: 0, count: 26)
        nr = [Double](repeating: 0, count: 3)
        su = [Double](repeating: 0, count: 6)
        sry = [Double](repeating: 0, count: 6)
        m2 = [Double](repeating: 0, count: 6)
        nkr = [Double](repeating: 0, count: 78)
        suk = [Double](repeating: 0, count: 156)
        ab = AB()
        fitted = nil
    }

    /// Learns from a swipe lined up with its word. Returns what stood out about it.
    @discardableResult
    public func learn(_ al: Alignment) -> SwipeNotes {
        let notes = check(al)
        func decay(_ a: inout [Double]) { for i in 0..<a.count { a[i] *= PROFILE_DECAY } }
        decay(&sy); decay(&nk); decay(&syk); decay(&missk); decay(&nr)
        decay(&su); decay(&sry); decay(&m2); decay(&nkr); decay(&suk)
        n = n * PROFILE_DECAY + 1
        N *= PROFILE_DECAY
        total += 1
        let cx = al.cx
        let cy = al.cy
        let t = al.nodes.count
        var dir = (0.0, 0.0)
        for i in 0..<t {
            let k = Int(al.nodes[i])
            let yx = al.x[i] - cx[k]
            let yy = al.y[i] - cy[k]
            N += 1
            sy[0] += yx
            sy[1] += yy
            nk[k] += 1
            syk[2 * k] += yx
            syk[2 * k + 1] += yy
            if notes.missed.contains(i) { missk[k] += 1 }
            let role = nodeRole(cx, cy, al.nodes, i, &dir)
            if role < 0 { continue }
            let ux = dir.0
            let uy = dir.1
            let along = ux * yx + uy * yy
            let cross = -uy * yx + ux * yy
            nr[role] += 1
            su[2 * role] += ux
            su[2 * role + 1] += uy
            sry[2 * role] += along
            sry[2 * role + 1] += cross
            m2[2 * role] += along * along
            m2[2 * role + 1] += cross * cross
            nkr[k * 3 + role] += 1
            suk[(k * 3 + role) * 2] += ux
            suk[(k * 3 + role) * 2 + 1] += uy
        }
        fitted = nil
        return notes
    }

    /// What stood out about one swipe: letters it missed, and how far past or short of the last
    /// letter it stopped, and off the first it started.
    public func check(_ al: Alignment) -> SwipeNotes {
        let cx = al.cx
        let cy = al.cy
        let t = al.nodes.count
        let halfW = 0.5 * MISS_SLACK
        let halfH = ((cy[0] - cy[16]) / 2) * MISS_SLACK // a (row 2) minus q (row 1): one row
        var missed = [Int]()
        for i in 0..<t {
            let k = Int(al.nodes[i])
            if abs(al.x[i] - cx[k]) > halfW || abs(al.y[i] - cy[k]) > halfH { missed.append(i) }
        }
        var endAlong = 0.0
        var startAlong = 0.0
        var dir = (0.0, 0.0)
        if nodeRole(cx, cy, al.nodes, t - 1, &dir) == ROLE_END {
            let k = Int(al.nodes[t - 1])
            endAlong = dir.0 * (al.x[t - 1] - cx[k]) + dir.1 * (al.y[t - 1] - cy[k])
        }
        if nodeRole(cx, cy, al.nodes, 0, &dir) == ROLE_START {
            let k = Int(al.nodes[0])
            startAlong = dir.0 * (al.x[0] - cx[k]) + dir.1 * (al.y[0] - cy[k])
        }
        return SwipeNotes(missed: missed, endAlong: endAlong, startAlong: startAlong)
    }

    /// True once it has enough to go on.
    public var ready: Bool { total >= PROFILE_MIN_SWIPES }

    /// The fitted profile for SwipeDecoder.setProfile, or nil before it's ready.
    public func params() -> ProfileParams? {
        if !ready { return nil }
        if let f = fitted { return f }
        var gx = 0.0
        var gy = 0.0
        var d = [Double](repeating: 0, count: 52)
        var b: [(Double, Double)] = [(0, 0), (0, 0), (0, 0)]
        // Each part in turn, holding the others: per-key offsets, the overall offset, the habits.
        for _ in 0..<12 {
            for k in 0..<26 {
                var rx = syk[2 * k] - nk[k] * gx
                var ry = syk[2 * k + 1] - nk[k] * gy
                for r in 0..<3 {
                    let sx = suk[(k * 3 + r) * 2]
                    let sy2 = suk[(k * 3 + r) * 2 + 1]
                    rx -= b[r].0 * sx - b[r].1 * sy2
                    ry -= b[r].0 * sy2 + b[r].1 * sx
                }
                d[2 * k] = rx / (nk[k] + KEY_SHRINK)
                d[2 * k + 1] = ry / (nk[k] + KEY_SHRINK)
            }
            var ox = sy[0]
            var oy = sy[1]
            for k in 0..<26 {
                ox -= nk[k] * d[2 * k]
                oy -= nk[k] * d[2 * k + 1]
            }
            for r in 0..<3 {
                ox -= b[r].0 * su[2 * r] - b[r].1 * su[2 * r + 1]
                oy -= b[r].0 * su[2 * r + 1] + b[r].1 * su[2 * r]
            }
            gx = ox / (N + GLOBAL_SHRINK)
            gy = oy / (N + GLOBAL_SHRINK)
            for r in 0..<3 {
                var a = sry[2 * r] - (gx * su[2 * r] + gy * su[2 * r + 1])
                var c = sry[2 * r + 1] - (-gx * su[2 * r + 1] + gy * su[2 * r])
                for k in 0..<26 {
                    let sx = suk[(k * 3 + r) * 2]
                    let sy2 = suk[(k * 3 + r) * 2 + 1]
                    a -= d[2 * k] * sx + d[2 * k + 1] * sy2
                    c -= -d[2 * k] * sy2 + d[2 * k + 1] * sx
                }
                b[r].0 = a / (nr[r] + ROLE_SHRINK)
                b[r].1 = c / (nr[r] + ROLE_SHRINK)
            }
        }
        var dx = [Double](repeating: 0, count: 26)
        var dy = [Double](repeating: 0, count: 26)
        for k in 0..<26 {
            dx[k] = gx + d[2 * k]
            dy[k] = gy + d[2 * k + 1]
        }
        let reach = b.map { ($0.0 * $0.0 + $0.1 * $0.1).squareRoot() }
        let f = ProfileParams(dx: dx, dy: dy, overall: (gx, gy), bias: b, reach: reach)
        fitted = f
        return f
    }

    /// Plain numbers about your habits, for showing.
    public func summary() -> ProfileSummary {
        let P = params()
        var keys = [ProfileSummary.MissedKey]()
        for k in 0..<26 where nk[k] >= 4 {
            keys.append(.init(key: String(UnicodeScalar(UInt8(97 + k))), seen: nk[k], missRate: missk[k] / nk[k]))
        }
        // Stable sort by miss rate, most missed first.
        let order = keys.indices.sorted { a, b in
            keys[a].missRate > keys[b].missRate || (keys[a].missRate == keys[b].missRate && a < b)
        }
        keys = order.map { keys[$0] }
        var keysSeen = 0
        for k in 0..<26 where nk[k] >= KEY_SHRINK { keysSeen += 1 }
        return ProfileSummary(
            total: total,
            ready: P != nil,
            progress: min(1, Double(total) / Double(PROFILE_FULL_SWIPES)),
            keysSeen: keysSeen,
            start: P?.bias[ROLE_START],
            corner: P?.bias[ROLE_CORNER],
            end: P?.bias[ROLE_END],
            overall: P?.overall,
            missedKeys: Array(keys.filter { $0.missRate >= 0.25 }.prefix(3)),
            ab: ab)
    }

    /// How many times each key has been seen first, anywhere, and last (for picking test words).
    public func seen(_ k: Int) -> (all: Double, first: Double, last: Double) {
        (nk[k], nkr[k * 3 + ROLE_START], nkr[k * 3 + ROLE_END])
    }

    // ---- saving ----

    public struct Saved: Codable, Equatable {
        public var v: Int
        public var total: Double
        public var n: Double
        public var N: Double
        public var sy: [Double]
        public var nk: [Double]
        public var syk: [Double]
        public var missk: [Double]
        public var nr: [Double]
        public var su: [Double]
        public var sry: [Double]
        public var m2: [Double]
        public var nkr: [Double]
        public var suk: [Double]
        public var ab: AB
    }

    public func saved() -> Saved {
        func r(_ a: [Double]) -> [Double] { a.map { jsRound($0 * 10000) / 10000 } }
        return Saved(v: 1, total: Double(total), n: r([n])[0], N: r([N])[0], sy: r(sy), nk: r(nk), syk: r(syk),
                     missk: r(missk), nr: r(nr), su: r(su), sry: r(sry), m2: r(m2), nkr: r(nkr), suk: r(suk), ab: ab)
    }

    /// Replaces everything with a saved copy (anything malformed starts it over).
    public func load(_ data: Saved?) {
        reset()
        guard let d = data, d.v == 1 else { return }
        let parts: [([Double], Int)] = [(d.sy, 2), (d.nk, 26), (d.syk, 52), (d.missk, 26), (d.nr, 3), (d.su, 6),
                                        (d.sry, 6), (d.m2, 6), (d.nkr, 78), (d.suk, 156)]
        for (a, size) in parts where a.count != size || !a.allSatisfy({ $0.isFinite }) {
            reset()
            return
        }
        sy = d.sy; nk = d.nk; syk = d.syk; missk = d.missk; nr = d.nr
        su = d.su; sry = d.sry; m2 = d.m2; nkr = d.nkr; suk = d.suk
        total = d.total.isFinite ? Int(d.total) : 0
        n = d.n.isFinite ? d.n : 0
        N = d.N.isFinite ? d.N : 0
        ab = d.ab
    }

    /// A copy (the Training rounds keep one to undo a swipe).
    public func copy() -> SwipeProfile {
        let c = SwipeProfile()
        c.load(saved())
        return c
    }
}

import Foundation
import simd

struct SilkVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var tangent: SIMD3<Float>
    var uv: SIMD2<Float>
}

struct SilkPose {
    var head: SIMD3<Float>
    var axis: SIMD2<Float>

    var side: SIMD2<Float> {
        return SIMD2(self.axis.y, -self.axis.x)
    }
}

struct SilkDrape {
    var strength: Float
    var side: Float
    var theta0: Float
    var kappa: Float
}

struct SilkForces {
    var gravity: SIMD3<Float>
    var damping: Float
    var wind: Float
    var time: Float
    var hang: Float
    var ripple: Float
    var drape: SilkDrape?
}

private func smooth(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)
}

final class SilkCloth {
    static let rows = 30
    static let columns = 7
    static let width: Float = 22.0
    static let length: Float = 86.0

    private static let notch: Float = 12.0
    private static let stepDuration: Float = 1.0 / 120.0
    private static let iterations = 10
    private static let pinnedRows = 3

    private struct Link {
        let a: Int
        let b: Int
        let rest: Float
        let stiffness: Float
    }

    private var positions: [SIMD3<Float>]
    private var previous: [SIMD3<Float>]
    private let rest: [SIMD2<Float>]
    private let links: [Link]
    private var accumulator: Float = 0.0

    private(set) var motion: Float = 1.0

    static var vertexCount: Int {
        return rows * columns
    }

    init() {
        let rows = SilkCloth.rows
        let columns = SilkCloth.columns
        var rest: [SIMD2<Float>] = []
        rest.reserveCapacity(rows * columns)
        for row in 0 ..< rows {
            let v = Float(row) / Float(rows - 1)
            for column in 0 ..< columns {
                let u = Float(column) / Float(columns - 1)
                let centerness = 1.0 - abs(u - 0.5) * 2.0
                let y = SilkCloth.length * v - SilkCloth.notch * centerness * v * v
                rest.append(SIMD2((u - 0.5) * SilkCloth.width, y))
            }
        }
        self.rest = rest
        self.positions = Array(repeating: .zero, count: rest.count)
        self.previous = self.positions

        var links: [Link] = []
        func add(_ a: Int, _ b: Int, _ stiffness: Float) {
            links.append(Link(a: a, b: b, rest: simd_distance(rest[a], rest[b]), stiffness: stiffness))
        }
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let i = row * columns + column
                if column + 1 < columns {
                    add(i, i + 1, 1.0)
                }
                if row + 1 < rows {
                    add(i, i + columns, 1.0)
                    if column + 1 < columns {
                        add(i, i + columns + 1, 0.6)
                        add(i + 1, i + columns, 0.6)
                    }
                }
                if column + 2 < columns {
                    add(i, i + 2, 0.7)
                }
                if row + 2 < rows {
                    add(i, i + columns * 2, 0.1)
                }
            }
        }
        self.links = links
    }

    static func indices() -> [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity((rows - 1) * (columns - 1) * 6)
        for row in 0 ..< rows - 1 {
            for column in 0 ..< columns - 1 {
                let i = UInt16(row * columns + column)
                let next = UInt16(columns)
                result.append(contentsOf: [i, i + next, i + 1, i + 1, i + next, i + next + 1])
            }
        }
        return result
    }

    func reset(pose: SilkPose) {
        let side = pose.side
        for i in 0 ..< self.positions.count {
            let xy = SIMD2(pose.head.x, pose.head.y) + side * self.rest[i].x + pose.axis * self.rest[i].y
            self.positions[i] = SIMD3(xy.x, xy.y, pose.head.z)
        }
        self.previous = self.positions
        self.accumulator = 0.0
        self.motion = 1.0
    }

    func translate(by delta: SIMD2<Float>) {
        let offset = SIMD3(delta.x, delta.y, 0.0)
        for i in 0 ..< self.positions.count {
            self.positions[i] += offset
            self.previous[i] += offset
        }
    }

    func advance(dt: Float, pose: SilkPose, forces: SilkForces) {
        self.accumulator += dt
        var steps = 0
        var motion: Float = 0.0
        while self.accumulator >= SilkCloth.stepDuration && steps < 6 {
            self.pin(pose)
            motion = self.step(pose: pose, forces: forces)
            self.accumulator -= SilkCloth.stepDuration
            steps += 1
        }
        if steps == 6 {
            self.accumulator = 0.0
        }
        if steps != 0 {
            self.motion = motion
        }
    }

    private func pin(_ pose: SilkPose) {
        let side = pose.side
        for i in 0 ..< SilkCloth.pinnedRows * SilkCloth.columns {
            let xy = SIMD2(pose.head.x, pose.head.y) + side * self.rest[i].x + pose.axis * self.rest[i].y
            let target = SIMD3(xy.x, xy.y, pose.head.z)
            self.positions[i] = target
            self.previous[i] = target
        }
    }

    private func drapeTarget(index i: Int, pose: SilkPose, drape: SilkDrape) -> SIMD3<Float> {
        let rest = self.rest[i]
        let v = rest.y / SilkCloth.length
        let theta = drape.theta0 + drape.kappa * rest.y
        let along = SIMD2(drape.side * (cos(drape.theta0) - cos(theta)) / drape.kappa, (sin(theta) - sin(drape.theta0)) / drape.kappa)
        let across = SIMD2(cos(theta), -drape.side * sin(theta))
        let xy = SIMD2(pose.head.x, pose.head.y) + along + across * rest.x
        let ripple = sin(v * Float.pi * 3.2 + 0.8)
        let lift = smooth(0.7, 1.0, v)
        let z = 1.4 + 1.1 * ripple * ripple + 8.0 * lift * lift
        return SIMD3(xy.x, xy.y, z)
    }

    private func step(pose: SilkPose, forces: SilkForces) -> Float {
        let h = SilkCloth.stepDuration
        let columns = SilkCloth.columns
        let rows = Float(SilkCloth.rows - 1)
        var maxMotion: Float = 0.0
        for i in SilkCloth.pinnedRows * columns ..< self.positions.count {
            let v = Float(i / columns) / rows
            let p = self.positions[i]
            let velocity = (p - self.previous[i]) * forces.damping
            var acceleration = forces.gravity
            if forces.wind > 0.0 {
                acceleration.x += forces.wind * 1500.0 * sin(forces.time * 8.4 + v * 1.6) * v
                acceleration.z += forces.wind * 900.0 * sin(forces.time * 13.0 - v * 6.0) * v
            }
            acceleration.z += forces.ripple * sin(v * 10.0)
            if forces.hang > 0.0 {
                let rest = self.rest[i]
                let side = pose.side
                let xy = SIMD2(pose.head.x, pose.head.y) + pose.axis * rest.y + side * rest.x
                acceleration += (SIMD3(xy.x, xy.y, pose.head.z) - p) * (forces.hang * (1.0 - 0.55 * v))
            }
            if let drape = forces.drape {
                acceleration += (self.drapeTarget(index: i, pose: pose, drape: drape) - p) * (320.0 * drape.strength)
            }
            self.previous[i] = p
            self.positions[i] = p + velocity + acceleration * (h * h)
            maxMotion = max(maxMotion, simd_length_squared(velocity))
        }

        let pinnedCount = SilkCloth.pinnedRows * columns
        for _ in 0 ..< SilkCloth.iterations {
            for link in self.links {
                let delta = self.positions[link.b] - self.positions[link.a]
                let distance = simd_length(delta)
                if distance < 0.0001 {
                    continue
                }
                let correction = delta * ((distance - link.rest) / distance * link.stiffness)
                let aPinned = link.a < pinnedCount
                let bPinned = link.b < pinnedCount
                if aPinned && bPinned {
                    continue
                } else if aPinned {
                    self.positions[link.b] -= correction
                } else if bPinned {
                    self.positions[link.a] += correction
                } else {
                    self.positions[link.a] += correction * 0.5
                    self.positions[link.b] -= correction * 0.5
                }
            }
            if let drape = forces.drape, drape.strength > 0.0 {
                for i in pinnedCount ..< self.positions.count where self.positions[i].z < 0.6 {
                    self.positions[i].z = 0.6
                }
            }
        }
        return sqrt(maxMotion)
    }

    func bounds() -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in self.positions {
            let xy = SIMD2(p.x, p.y)
            low = simd_min(low, xy)
            high = simd_max(high, xy)
        }
        return (low, high)
    }

    func distance(to point: SIMD2<Float>) -> Float {
        let columns = SilkCloth.columns
        let center = columns / 2
        var best = Float.greatestFiniteMagnitude
        for row in 0 ..< SilkCloth.rows - 1 {
            let a3 = self.positions[row * columns + center]
            let b3 = self.positions[(row + 1) * columns + center]
            let a = SIMD2(a3.x, a3.y)
            let b = SIMD2(b3.x, b3.y)
            let ab = b - a
            let denominator = simd_length_squared(ab)
            let t = denominator > 0.0 ? min(max(simd_dot(point - a, ab) / denominator, 0.0), 1.0) : 0.0
            best = min(best, simd_distance(point, a + ab * t))
        }
        return best
    }

    func fill(_ vertices: UnsafeMutablePointer<SilkVertex>) {
        let rows = SilkCloth.rows
        let columns = SilkCloth.columns
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let i = row * columns + column
                let left = self.positions[row * columns + max(column - 1, 0)]
                let right = self.positions[row * columns + min(column + 1, columns - 1)]
                let up = self.positions[max(row - 1, 0) * columns + column]
                let down = self.positions[min(row + 1, rows - 1) * columns + column]
                let across = right - left
                let along = down - up
                var normal = simd_cross(across, along)
                let normalLength = simd_length(normal)
                normal = normalLength > 0.0001 ? normal / normalLength : SIMD3(0.0, 0.0, 1.0)
                let alongLength = simd_length(along)
                let tangent = alongLength > 0.0001 ? along / alongLength : SIMD3(0.0, 1.0, 0.0)
                vertices[i] = SilkVertex(
                    position: self.positions[i],
                    normal: normal,
                    tangent: tangent,
                    uv: SIMD2(Float(column) / Float(columns - 1), self.rest[i].y / SilkCloth.length)
                )
            }
        }
    }
}

import SwiftUI

/// SVG `pathData` → SwiftUI `Path`
///
/// Android 的图标是 VectorDrawable，本质就是 SVG path。iOS 没有这个格式，
/// 但 `pathData` 原样贴进来就能画——前提是把它用到的命令全都实现，
/// 尤其是 `A`（椭圆弧）：花洒图标的出水弧线就是它，少了那几条线图标会残缺。
///
/// 这里只做「解析 + 填充」，不做描边（原图都是 `fillColor` 单色填充）。
enum SVGPathParser {

    static func path(from d: String) -> Path {
        var p = Parser(d)
        return p.run()
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// 上一条 C/S 的第二控制点（`S`/`s` 要按它做反射）
        var lastCubicControl: CGPoint?
        /// 上一条 Q/T 的控制点（`T`/`t` 要按它做反射）
        var lastQuadControl: CGPoint?
        /// `M` 之后继续出现数字时，按 `L` 处理（SVG 规范）
        var multipleMoveTo = false

        init(_ s: String) { chars = Array(s) }

        var n: Int { chars.count }

        mutating func skipSeparators() {
            while i < n {
                let c = chars[i]
                if c == " " || c == "," || c == "\n" || c == "\r" || c == "\t" { i += 1 } else { break }
            }
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            guard i < n else { return nil }
            var s = ""
            if chars[i] == "-" || chars[i] == "+" { s.append(chars[i]); i += 1 }
            var seenDot = false
            while i < n {
                let c = chars[i]
                if c.isNumber {
                    s.append(c); i += 1
                } else if c == "." && !seenDot {
                    seenDot = true; s.append(c); i += 1
                } else {
                    break
                }
            }
            return s.isEmpty || s == "-" || s == "+" ? nil : CGFloat(Double(s) ?? 0)
        }

        mutating func run() -> Path {
            var cmd: Character = " "
            while true {
                skipSeparators()
                guard i < n else { break }

                let c = chars[i]
                if c.isLetter {
                    cmd = c
                    i += 1
                    multipleMoveTo = false
                } else if cmd == " " {
                    i += 1
                    continue
                }

                if cmd == "Z" || cmd == "z" {
                    path.closeSubpath()
                    current = subpathStart
                    lastCubicControl = nil
                    lastQuadControl = nil
                    continue
                }

                // `M` 的第二组以后参数按 `L` 处理
                if multipleMoveTo, cmd == "M" || cmd == "m" {
                    guard let x = number(), let y = number() else { break }
                    let p = cmd == "m" ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                    path.addLine(to: p)
                    current = p
                    lastCubicControl = nil
                    lastQuadControl = nil
                    continue
                }

                guard apply(cmd: cmd) else { break }

                if cmd == "M" || cmd == "m" { multipleMoveTo = true }
                if cmd == "Z" || cmd == "z" { multipleMoveTo = false }
            }
            return path
        }

        /// 读一组参数并落到 path 上。返回 false 表示数据不够（结束解析）。
        mutating func apply(cmd: Character) -> Bool {
            let relative = cmd.isLowercase

            switch cmd.uppercased() {
            case "M":
                guard let x = number(), let y = number() else { return false }
                let p = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: p)
                current = p
                subpathStart = p
                lastCubicControl = nil
                lastQuadControl = nil

            case "L":
                guard let x = number(), let y = number() else { return false }
                let p = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case "H":
                guard let x = number() else { return false }
                let p = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case "V":
                guard let y = number() else { return false }
                let p = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case "C":
                guard let x1 = number(), let y1 = number(),
                      let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return false }
                let base = relative ? current : .zero
                let c1 = CGPoint(x: base.x + x1, y: base.y + y1)
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                let p = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
                lastQuadControl = nil

            case "S":
                guard let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return false }
                let base = relative ? current : .zero
                let c1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let c2 = CGPoint(x: base.x + x2, y: base.y + y2)
                let p = CGPoint(x: base.x + x, y: base.y + y)
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
                lastCubicControl = c2
                lastQuadControl = nil

            case "Q":
                guard let x1 = number(), let y1 = number(),
                      let x = number(), let y = number() else { return false }
                let base = relative ? current : .zero
                let c = CGPoint(x: base.x + x1, y: base.y + y1)
                let p = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuadControl = c
                lastCubicControl = nil

            case "T":
                guard let x = number(), let y = number() else { return false }
                let base = relative ? current : .zero
                let c = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let p = CGPoint(x: base.x + x, y: base.y + y)
                path.addQuadCurve(to: p, control: c)
                current = p
                lastQuadControl = c
                lastCubicControl = nil

            case "A":
                guard let rx = number(), let ry = number(), let rot = number(),
                      let large = number(), let sweep = number(),
                      let x = number(), let y = number() else { return false }
                let p = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                addArc(rx: rx, ry: ry, rotation: rot, largeArc: large != 0, sweep: sweep != 0, to: p)
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                // 不认识就停，免得把后面的坐标读成别的命令
                return false
            }
            return true
        }

        /// 椭圆弧 → 若干段三次贝塞尔（SVG 规范的 endpoint 转 center 参数化）
        mutating func addArc(
            rx rxIn: CGFloat,
            ry ryIn: CGFloat,
            rotation: CGFloat,
            largeArc: Bool,
            sweep: Bool,
            to end: CGPoint
        ) {
            let start = current
            if abs(start.x - end.x) < 0.0001 && abs(start.y - end.y) < 0.0001 { return }

            var rx = abs(rxIn), ry = abs(ryIn)
            guard rx > 0, ry > 0 else {
                path.addLine(to: end)
                current = end
                return
            }

            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy

            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                let s = sqrt(lambda)
                rx *= s
                ry *= s
            }

            let sign: CGFloat = (largeArc != sweep) ? 1 : -1
            let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coef = sign * sqrt(max(0, num / max(den, 1e-12)))
            let cx1 = coef * rx * y1 / ry
            let cy1 = -coef * ry * x1 / rx
            let cx = cosPhi * cx1 - sinPhi * cy1 + (start.x + end.x) / 2
            let cy = sinPhi * cx1 + cosPhi * cy1 + (start.y + end.y) / 2

            let ux = (x1 - cx1) / rx, uy = (y1 - cy1) / ry
            let vx = (-x1 - cx1) / rx, vy = (-y1 - cy1) / ry

            let theta = atan2(uy, ux)
            var dTheta = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
            if sweep && dTheta < 0 { dTheta += 2 * .pi }

            let segments = max(1, Int(ceil(abs(dTheta) / (.pi / 2))))
            let delta = dTheta / CGFloat(segments)
            let alpha = 4.0 / 3.0 * tan(delta / 4)

            var t = theta
            var p0 = start
            for _ in 0 ..< segments {
                let t2 = t + delta
                let p3 = point(cx: cx, cy: cy, rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, angle: t2)
                let d1 = derivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, angle: t)
                let d2 = derivative(rx: rx, ry: ry, cosPhi: cosPhi, sinPhi: sinPhi, angle: t2)
                let c1 = CGPoint(x: p0.x + alpha * d1.x, y: p0.y + alpha * d1.y)
                let c2 = CGPoint(x: p3.x - alpha * d2.x, y: p3.y - alpha * d2.y)
                path.addCurve(to: p3, control1: c1, control2: c2)
                p0 = p3
                t = t2
            }
            current = end
        }

        private func point(
            cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
            cosPhi: CGFloat, sinPhi: CGFloat, angle: CGFloat
        ) -> CGPoint {
            CGPoint(
                x: cx + cosPhi * rx * cos(angle) - sinPhi * ry * sin(angle),
                y: cy + sinPhi * rx * cos(angle) + cosPhi * ry * sin(angle)
            )
        }

        private func derivative(
            rx: CGFloat, ry: CGFloat, cosPhi: CGFloat, sinPhi: CGFloat, angle: CGFloat
        ) -> CGPoint {
            CGPoint(
                x: -cosPhi * rx * sin(angle) - sinPhi * ry * cos(angle),
                y: -sinPhi * rx * sin(angle) + cosPhi * ry * cos(angle)
            )
        }
    }
}

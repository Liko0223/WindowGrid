import Foundation

enum L10n {
    static var usesChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static func text(_ english: String, _ chinese: String) -> String {
        usesChinese ? chinese : english
    }

    static func current(_ value: String) -> String {
        text("Current: \(value)", "当前：\(value)")
    }

    static func notInstalled(_ name: String) -> String {
        text("\(name) (not installed)", "\(name)（未安装）")
    }

    static func layoutName(_ name: String) -> String {
        if !usesChinese { return name }

        if name.hasPrefix("Custom ") {
            return name.replacingOccurrences(of: "Custom", with: "自定义")
        }
        if name.hasPrefix("Adaptive ") {
            return adaptiveLayoutName(name)
        }

        return layoutNameMap[name] ?? name
    }

    private static func adaptiveLayoutName(_ name: String) -> String {
        let replacements: [(String, String)] = [
            ("Adaptive", "自适应"),
            ("Left Half", "左半屏"),
            ("Right Half", "右半屏"),
            ("Full", "全屏"),
            ("2-Column", "两列"),
            ("3-Column", "三列"),
            ("Left + 2 Right", "左大右两小"),
            ("2 Left + Right", "左两小右大"),
            ("Large + Stack + Large", "两侧大窗 + 中间堆叠"),
            ("Large + 4 Stack + Large", "两侧大窗 + 中间四格"),
            ("Large + 6 Stack + Large", "两侧大窗 + 中间六格"),
            ("Large + 8 Stack", "左侧大窗 + 右侧八格"),
            ("1+6 Left", "左侧大窗 + 右侧六格"),
            ("6+1 Right", "左侧六格 + 右侧大窗"),
        ]

        var result = name
        for (english, chinese) in replacements {
            result = result.replacingOccurrences(of: english, with: chinese)
        }
        return result
    }

    private static let layoutNameMap: [String: String] = [
        "6-Grid (3×2)": "六格 (3×2)",
        "4-Grid (2×2)": "四格 (2×2)",
        "3-Column": "三列",
        "2-Column": "两列",
        "9-Grid (3×3)": "九格 (3×3)",
        "1+4 (Tall Left)": "左侧大窗 + 四格",
        "4+1 (Tall Right)": "四格 + 右侧大窗",
        "1+2 (Wide Top)": "上方宽屏 + 下方两格",
        "2+1 (Wide Bottom)": "上方两格 + 下方宽屏",
    ]
}

import Foundation

struct UninstallManifestBuilder: Sendable {
    func makeText(
        application: InstalledApplication,
        selectedResidues: [AppResidueCandidate],
        associations: [AppAssociatedItem],
        generatedAt: Date = Date()
    ) -> String {
        var lines = [
            String(localized: "Sin Clean 卸载清单"),
            String(localized: "生成时间：\(generatedAt.formatted(date: .numeric, time: .standard))"),
            String(localized: "状态：仅导出计划，尚未执行卸载"),
            "",
            String(localized: "应用本体"),
            String(localized: "名称：\(application.name)"),
            String(localized: "Bundle Identifier：\(application.bundleIdentifier ?? String(localized: "无法读取"))"),
            String(localized: "版本：\(application.version ?? String(localized: "无法读取"))"),
            String(localized: "路径：\(application.path)"),
            String(localized: "预计占用：\(SystemFormatters.bytes.string(fromByteCount: application.allocatedBytes))"),
            String(localized: "签名状态：\(application.signatureState.localizedDisplayName)"),
            "",
            String(localized: "已勾选残留（\(selectedResidues.count.formatted()) 项）")
        ]

        if selectedResidues.isEmpty {
            lines.append(String(localized: "无"))
        } else {
            for residue in selectedResidues {
                lines.append("- \(residue.kind.localizedDisplayName) | \(SystemFormatters.bytes.string(fromByteCount: residue.allocatedBytes)) | \(residue.path)")
            }
        }

        lines.append(contentsOf: [
            "",
            String(localized: "只读关联分析（\(associations.count.formatted()) 项，不会单独自动移除）")
        ])
        if associations.isEmpty {
            lines.append(String(localized: "无"))
        } else {
            for item in associations {
                let identifier = item.identifier.map { String(localized: " | 标识符：\($0)") } ?? ""
                lines.append("- \(item.kind.localizedDisplayName) | \(item.relationship.localizedDisplayName)\(identifier) | \(item.path)")
            }
        }

        lines.append(contentsOf: [
            "",
            String(localized: "安全说明"),
            String(localized: "- 执行时应用本体优先移动到废纸篓。"),
            String(localized: "- 应用本体失败时，所有关联残留都会保留。"),
            String(localized: "- 扫描后发生变化、越界或包含符号链接的目标会被拒绝。"),
            String(localized: "- 只读关联分析中的外部后台项目和安装收据不会被自动处理。")
        ])
        return lines.joined(separator: "\n") + "\n"
    }

    func suggestedFilename(for application: InstalledApplication) -> String {
        let disallowed = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let safeName = application.name.components(separatedBy: disallowed).joined(separator: "-")
        return String(localized: "\(safeName.isEmpty ? String(localized: "应用") : safeName)-卸载清单.txt")
    }
}

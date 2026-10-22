import Foundation
import Combine

/// 打印机列表的本地存储（UserDefaults + JSON）。
@MainActor
final class PrinterStore: ObservableObject {

    @Published private(set) var printers: [PrinterConfig] = []

    private let storageKey = "lanprint.printers.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - 增删改

    func add(_ printer: PrinterConfig) {
        var p = printer
        p.normalizeFormat()
        printers.append(p)
        sortAndSave()
    }

    func update(_ printer: PrinterConfig) {
        guard let idx = printers.firstIndex(where: { $0.id == printer.id }) else { return }
        var p = printer
        p.normalizeFormat()
        printers[idx] = p
        sortAndSave()
    }

    func delete(id: UUID) {
        printers.removeAll { $0.id == id }
        save()
    }

    func printer(id: UUID) -> PrinterConfig? {
        printers.first { $0.id == id }
    }

    // MARK: - 状态标记

    func markTest(id: UUID, ok: Bool, detail: String) {
        guard let idx = printers.firstIndex(where: { $0.id == id }) else { return }
        printers[idx].lastTestAt = Date()
        printers[idx].lastTestOK = ok
        printers[idx].lastTestDetail = detail
        save()
    }

    func markPrint(id: UUID) {
        guard let idx = printers.firstIndex(where: { $0.id == id }) else { return }
        printers[idx].lastPrintAt = Date()
        save()
    }

    // MARK: - 持久化

    private func sortAndSave() {
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            let list = try JSONDecoder().decode([PrinterConfig].self, from: data)
            printers = list.map { stored in
                var printer = stored
                printer.normalizeFormat()
                return printer
            }
        } catch {
            printers = []
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(printers)
            defaults.set(data, forKey: storageKey)
        } catch {
            // 存储失败不阻塞界面；下次写入会再试。
        }
    }
}

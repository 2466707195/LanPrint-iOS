import SwiftUI

@main
struct LanPrintApp: App {

    @StateObject private var store = PrinterStore()

    var body: some Scene {
        WindowGroup {
            HomeScreen()
                .environmentObject(store)
                .preferredColorScheme(.light)
                .tint(Aurora.brand)
        }
    }
}

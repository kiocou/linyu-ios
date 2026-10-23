import Foundation

// Runs the production AppDataStore and BillService with a deterministic HTTP boundary.
@main
struct DataStoreRegression {
    @MainActor static func main() async throws {
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures.append(name) }
        }

        ApiClient.failBills = true
        let retryStore = AppDataStore()
        await retryStore.loadIfNeeded()
        check(!retryStore.loaded, "failed requests are not cached as an empty success")
        ApiClient.failBills = false
        await retryStore.loadIfNeeded()
        check(retryStore.loaded && retryStore.bills.count == 3, "initial failure can retry on next visit")
        ApiClient.failBills = true
        await retryStore.reload()
        check(retryStore.bills.count == 3, "refresh failure preserves previously loaded bills")

        ApiClient.failBills = false
        ApiClient.delay = 30_000_000
        let switchingStore = AppDataStore()
        let page = Task { await switchingStore.loadIfNeeded() }
        while ApiClient.activeRequests == 0 { await Task.yield() }
        page.cancel()
        await page.value
        check(switchingStore.loaded && switchingStore.bills.count == 3,
              "leaving a tab does not cancel shared bill loading")

        ApiClient.delay = 0
        ApiClient.emptyBills = true
        let emptyStore = AppDataStore()
        await emptyStore.loadIfNeeded()
        check(emptyStore.loaded && emptyStore.bills.isEmpty, "successful empty response remains a valid empty state")
        ApiClient.emptyBills = false
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        ApiClient.failingMonth = formatter.string(from: Calendar(identifier: .gregorian).date(byAdding: .month, value: -1, to: Date())!)
        let partial = await BillService.loadHistory()
        check(partial.count == 2, "settlement fallback preserves successful months on partial failure")
        let partialStore = AppDataStore()
        await partialStore.loadIfNeeded()
        check(!partialStore.loaded, "partial bill responses do not become a complete cache")
        ApiClient.failingMonth = nil

        SettlementRegression.run(check: check)

        if !failures.isEmpty { fatalError("Regression failures: \(failures.joined(separator: ", "))") }
    }
}

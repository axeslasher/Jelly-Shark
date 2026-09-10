@testable import Features
import Testing

@Suite("Home refresh eligibility")
@MainActor
struct HomeRefreshEligibilityTests {
    @Test func eligibleOnHomeAtRootWithNoSwitchInFlight() {
        #expect(RootView.homeRefreshEligible(
            selectedTab: .home, homePathIsEmpty: true, hasPendingSwitch: false,
        ))
    }

    @Test func notEligibleWithADetailPushed() {
        #expect(!RootView.homeRefreshEligible(
            selectedTab: .home, homePathIsEmpty: false, hasPendingSwitch: false,
        ))
    }

    @Test func notEligibleOnAnotherTab() {
        #expect(!RootView.homeRefreshEligible(
            selectedTab: .search, homePathIsEmpty: true, hasPendingSwitch: false,
        ))
    }

    @Test func notEligibleWhileATabSwitchIsSettling() {
        // The trap: `tabSelection` empties the outgoing path
        // *synchronously* and commits `selectedTab` 350ms later, so
        // leaving Home with a detail pushed makes "Home at root"
        // transiently true. Refreshing there refetches the page the
        // viewer is leaving (#236 § 4).
        #expect(!RootView.homeRefreshEligible(
            selectedTab: .home, homePathIsEmpty: true, hasPendingSwitch: true,
        ))
    }
}

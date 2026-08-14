//
//  ContentView.swift
//  IntemptDemo
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//
//  Every accessibility identifier here is what the UI test drives. Renaming one
//  breaks a test, which is the intent — the identifiers are the contract
//  between this screen and IntemptDemoUITests.
//
import Intempt
import SwiftUI
import UserNotifications

struct ContentView: View {
    @StateObject private var log = DemoLog.shared

    var body: some View {
        // NavigationView, not NavigationStack: the SDK's floor is iOS 15 and
        // NavigationStack is iOS 16+. A demo that will not build at the SDK's
        // own minimum deployment target is not demonstrating the SDK.
        NavigationView {
            List {
                trackingSection
                commerceSection
                personalizationSection
                privacySection
                deliverySection
                autocaptureSection
                logSection
            }
            .navigationTitle("Intempt SDK")
        }
        .navigationViewStyle(.stack)
    }

    private var intempt: IntemptInstance? { Intempt.shared }

    // MARK: - Tracking

    private var trackingSection: some View {
        Section("Tracking") {
            Button("Track event") {
                let ok = intempt?.track(
                    eventTitle: "Demo Button Tapped",
                    data: ["screen": "ContentView", "at": Date()]) ?? false
                DemoLog.append("track → \(ok)")
            }
            .accessibilityIdentifier("track-button")

            Button("Identify user") {
                let ok = intempt?.identify(
                    userId: "demo@intempt.com",
                    userAttributes: ["plan": "pro", "seats": 3]) ?? false
                DemoLog.append("identify → \(ok)")
            }
            .accessibilityIdentifier("identify-button")

            Button("Set account") {
                let ok = intempt?.group(
                    accountId: "demo-account",
                    accountAttributes: ["tier": "enterprise"]) ?? false
                DemoLog.append("group → \(ok)")
            }
            .accessibilityIdentifier("group-button")

            Button("Record (user + account)") {
                let ok = intempt?.record(
                    eventTitle: "Demo Signup",
                    userId: "demo@intempt.com",
                    accountId: "demo-account",
                    data: ["source": "demo-app"]) ?? false
                DemoLog.append("record → \(ok)")
            }
            .accessibilityIdentifier("record-button")

            Button("Alias") {
                let ok = intempt?.alias(
                    userId: "demo@intempt.com", anotherUserId: "demo-alias") ?? false
                DemoLog.append("alias → \(ok)")
            }
            .accessibilityIdentifier("alias-button")

            // Proves the SDK refuses a value that cannot survive JSON rather
            // than shipping the string "nan", which is what upstream does.
            Button("Track invalid (NaN)") {
                let ok = intempt?.track(
                    eventTitle: "Demo Invalid", data: ["bad": Double.nan]) ?? false
                DemoLog.append("track NaN → \(ok) (false is correct)")
            }
            .accessibilityIdentifier("invalid-button")
        }
    }

    // MARK: - Commerce

    private var commerceSection: some View {
        Section("Commerce") {
            Button("Product viewed") {
                DemoLog.append("productView → \(intempt?.productView(productId: "sku_1") ?? false)")
            }
            .accessibilityIdentifier("product-view-button")

            Button("Added to cart") {
                DemoLog.append(
                    "productAdd → \(intempt?.productAdd(productId: "sku_1", quantity: 2) ?? false)")
            }
            .accessibilityIdentifier("product-add-button")

            Button("Product ordered") {
                let ok =
                    intempt?.productOrdered(products: [
                        (productId: "sku_1", quantity: 2),
                        (productId: "sku_2", quantity: 1),
                    ]) ?? false
                DemoLog.append("productOrdered → \(ok)")
            }
            .accessibilityIdentifier("product-ordered-button")
        }
    }

    // MARK: - Personalization

    private var personalizationSection: some View {
        Section("Personalization") {
            Button("Fetch experiments") {
                intempt?.experiments { result in
                    switch result {
                    case .success(let choices):
                        DemoLog.append("experiments → \(choices.count) choice(s)")
                        for choice in choices {
                            DemoLog.append("  \(choice.experience) → variant \(choice.variant)")
                        }
                    case .failure(let error):
                        DemoLog.append("experiments failed → \(error)")
                    }
                }
            }
            .accessibilityIdentifier("experiments-button")

            Button("Fetch recommendations") {
                // `fields` defaults to a compact set on purpose: an unfielded
                // request returns raw ML embedding vectors, 443x the bytes.
                intempt?.products(feedId: "5258", count: 3) { result in
                    switch result {
                    case .success(let products):
                        DemoLog.append("products → \(products.count)")
                        for product in products {
                            DemoLog.append("  \(product.title ?? "?") \(product["price"] ?? "")")
                        }
                    case .failure(let error):
                        DemoLog.append("products failed → \(error)")
                    }
                }
            }
            .accessibilityIdentifier("products-button")
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Privacy") {
            Button("Accept consent") {
                let ok = intempt?.consent(action: .accept, validUntil: 31_536_000) ?? false
                DemoLog.append("consent accept → \(ok)")
            }
            .accessibilityIdentifier("consent-accept-button")

            // Not just a flag: this purges the queue and stops collection,
            // while preserving the withdrawal record itself.
            Button("Reject consent") {
                let ok = intempt?.consent(action: .reject, validUntil: 0) ?? false
                DemoLog.append("consent reject → \(ok); optedOut=\(intempt?.hasOptedOut() ?? false)")
            }
            .accessibilityIdentifier("consent-reject-button")

            Button("Opt out") {
                intempt?.optOut()
                DemoLog.append("optOut → queue purged, collection stopped")
            }
            .accessibilityIdentifier("opt-out-button")

            Button("Opt in") {
                intempt?.optIn()
                DemoLog.append("optIn → collection resumed")
            }
            .accessibilityIdentifier("opt-in-button")

            Button("Log out (rotate identity)") {
                let before = intempt?.getProfileId() ?? "?"
                intempt?.logOut()
                DemoLog.append("logOut → \(before) became \(intempt?.getProfileId() ?? "?")")
            }
            .accessibilityIdentifier("logout-button")
        }
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section("Delivery") {
            Button("Flush now") {
                intempt?.flush { sent in
                    DemoLog.append("flush → \(sent) event(s) delivered")
                }
            }
            .accessibilityIdentifier("flush-button")

            Button("Queue 120 events") {
                for i in 0..<120 {
                    _ = intempt?.track(eventTitle: "Demo Bulk", data: ["index": i])
                }
                DemoLog.append("queued 120 — flush drains them in 3 batches of 50")
            }
            .accessibilityIdentifier("bulk-button")

            Button("Register for push") {
                UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                        DemoLog.append("push authorization granted=\(granted)")
                        guard granted else { return }
                        DispatchQueue.main.async {
                            UIApplication.shared.registerForRemoteNotifications()
                        }
                    }
            }
            .accessibilityIdentifier("push-button")
        }
    }

    // MARK: - Autocapture

    private var autocaptureSection: some View {
        Section("Autocapture") {
            // A control the tap hook should see, with no explicit tracking
            // call attached to it.
            Toggle("Autocaptured switch", isOn: .constant(true))
                .accessibilityIdentifier("autocapture-toggle")

            // The opt-out. Nothing about this control may be recorded, and the
            // prefix match walks up the view tree.
            Toggle("Excluded switch", isOn: .constant(false))
                .accessibilityIdentifier("intempt-ignore-toggle")

            NavigationLink("Push a screen") {
                SecondScreen()
            }
            .accessibilityIdentifier("second-screen-link")
        }
    }

    // MARK: - Log

    private var logSection: some View {
        Section("Log") {
            Button("Clear log") { DemoLog.clear() }
                .accessibilityIdentifier("clear-log-button")

            ForEach(Array(log.lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
            }
            .accessibilityIdentifier("log-lines")
        }
    }
}

/// A second view controller so screen autocapture has something to report.
struct SecondScreen: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("This screen's appearance is autocaptured as \"View screen\".")
                .multilineTextAlignment(.center)
                .padding()

            // Its contents must never be captured — only that it changed.
            TextField("Type here (contents never captured)", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("demo-text-field")
                .padding(.horizontal)

            SecureField("Password (skipped entirely)", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("demo-secure-field")
                .padding(.horizontal)
        }
        .navigationTitle("Second Screen")
        .accessibilityIdentifier("second-screen")
    }
}

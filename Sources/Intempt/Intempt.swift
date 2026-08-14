//
//  Intempt.swift
//  Intempt
//
//  Copyright © 2026 Intempt Technologies, Inc.
//  Licensed under the Apache License, Version 2.0.
//

import Foundation

/// Namespace for SDK-wide constants and the instance manager.
///
/// `Intempt.initialize(...)` is declared on `IntemptInstance`; this enum holds
/// the values a caller may need before any instance exists.
public enum Intempt {
    /// SDK version, surfaced on every outbound request as the User-Agent.
    public static let sdkVersion = "0.0.1"

    /// Catalog columns requested from a recommendation feed by default.
    ///
    /// Deliberately compact. Verified against production: the same 10 products
    /// are 503 bytes with these fields and 222,919 bytes without any — the
    /// unfielded response includes raw ML embedding vectors
    /// (`intempt_image_vector`). 443x, over cellular, for a product strip.
    /// Widen this per call when a feed carries columns a screen actually needs.
    public static let defaultFeedFields = [
        "productId", "title", "price", "imageUrl", "url",
    ]
}

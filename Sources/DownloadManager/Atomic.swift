//
//  Atomic.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 23/2/21.
//  Copyright © 2021 Lachlan Charlick. All rights reserved.
//

import Foundation

/// Automatically locks a value for thread-safe reading and writing.
@propertyWrapper struct Atomic<Value> {
    private let lock = DispatchSemaphore(value: 1)
    private var value: Value

    init(wrappedValue: Value) {
        self.value = wrappedValue
    }

    var wrappedValue: Value {
        get {
            lock.wait()
            defer { lock.signal() }
            return value
        }
        set {
            lock.wait()
            value = newValue
            lock.signal()
        }
    }
}

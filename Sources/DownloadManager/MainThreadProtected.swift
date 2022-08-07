//
//  MainThreadProtected.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 4/7/21.
//

import Foundation

/// Raise an assertion if the wrapped value is accessed from a non-main thread.
/// Used for debug purposes only.
@propertyWrapper struct MainThreadProtected<Value> {
    private var value: Value

    init(wrappedValue: Value) {
        value = wrappedValue
    }

    var wrappedValue: Value {
        get {
            assert(Thread.current.isMainThread)
            return value
        }
        set {
            assert(Thread.current.isMainThread)
            value = newValue
        }
    }
}

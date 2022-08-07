//
//  DownloadProgress.swift
//  DownloadManager
//
//  Created by Lachlan Charlick on 3/3/21.
//

import Combine
import Foundation

public class DownloadProgress: Identifiable, ObservableObject {
    public let id = UUID()

    @Published
    public private(set) var fractionCompleted: Double = 0
    private let fraction = PassthroughSubject<Double, Never>()

    public var throttleInterval: DispatchQueue.SchedulerTimeType.Stride? {
        didSet {
            observeChanges()
        }
    }

    private var _expected: Int = 0
    private var _received: Int = 0

    public var expected: Int {
        get {
            _expected
        }
        set {
            if _expected != newValue {
                _expected = newValue
                updateFraction()
            }
        }
    }

    public internal(set) var received: Int {
        get {
            _received
        }
        set {
            if _received != newValue {
                _received = newValue
                updateFraction()
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var updateFractionCancellable: AnyCancellable?

    private let lock = NSLock()

    private var children: Set<DownloadProgress> = [] {
        didSet {
            updateBindings()
        }
    }

    public init(expected: Int = 0, received: Int = 0) {
        self.expected = expected
        self.received = received
        observeChanges()
        updateFraction()
    }

    init(children: Set<DownloadProgress>) {
        self.children = children
        observeChanges()
        updateBindings()
    }

    convenience init(children: [DownloadProgress]) {
        self.init(children: Set(children))
    }

    private func updateFraction() {
        guard expected > 0 else {
            fraction.send(0)
            return
        }
        fraction.send(Double(received) / Double(expected))
    }

    private func observeChanges() {
        if let interval = throttleInterval {
            updateFractionCancellable = fraction
                .throttle(for: interval, scheduler: DispatchQueue.main, latest: true).sink { [weak self] fraction in
                    self?.fractionCompleted = fraction
                }
        } else {
            // Send values synchronously.
            updateFractionCancellable = fraction.sink { [weak self] fraction in
                self?.fractionCompleted = fraction
            }
        }
    }

    private func updateBindings() {
        cancellables = []

        guard children.count > 0 else {
            updateValuesFromChildren()
            return
        }

        Publishers.MergeMany(children.map { child in
            child.$fractionCompleted.map { _ in }
        }).sink { [weak self] in
            self?.updateValuesFromChildren()
        }
        .store(in: &cancellables)
    }

    private func updateValuesFromChildren() {
        let (expected, received) = children.reduce(into: (0, 0)) {
            $0.0 += $1.expected
            $0.1 += $1.received
        }
        _expected = expected
        _received = received
        updateFraction()
    }

    func addChild(_ child: DownloadProgress) {
        lock.lock()
        children.insert(child)
        lock.unlock()
    }

    func addChildren(_ children: [DownloadProgress]) {
        lock.lock()
        self.children.formUnion(Set(children))
        lock.unlock()
    }

    func removeChild(_ child: DownloadProgress) {
        lock.lock()
        children.remove(child)
        lock.unlock()
    }

    func removeChildren(_ children: [DownloadProgress]) {
        lock.lock()
        self.children.subtract(children)
        lock.unlock()
    }
}

extension DownloadProgress: Hashable {
    public static func == (lhs: DownloadProgress, rhs: DownloadProgress) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

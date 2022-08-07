//
//  DownloadProgressTests.swift
//
//
//  Created by Lachlan Charlick on 3/3/21.
//

import Combine
@testable import DownloadManager
import XCTest

final class DownloadProgressTests: XCTestCase {
    func testFractionCompleted() {
        XCTAssertEqual(DownloadProgress(expected: 0, received: 0).fractionCompleted, 0)
        XCTAssertEqual(DownloadProgress(expected: 1, received: 1).fractionCompleted, 1)
        XCTAssertEqual(DownloadProgress(expected: 2, received: 1).fractionCompleted, 0.5)

        let progress = DownloadProgress(expected: 1, received: 0)
        progress.received = 1
        XCTAssertEqual(progress.fractionCompleted, 1)
    }

    func testInitWithChild() {
        let child = DownloadProgress(expected: 2, received: 1)
        let parent = DownloadProgress(children: [child])
        XCTAssertEqual(parent.expected, 2)
        XCTAssertEqual(parent.received, 1)
    }

    func testInitWithChildren() {
        let child1 = DownloadProgress(expected: 2, received: 1)
        let child2 = DownloadProgress(expected: 2, received: 1)
        let parent = DownloadProgress(children: [child1, child2])
        XCTAssertEqual(parent.expected, 4)
        XCTAssertEqual(parent.received, 2)
    }

    func testAddChild() {
        let child1 = DownloadProgress(expected: 2, received: 1)
        let child2 = DownloadProgress(expected: 2, received: 1)
        let parent = DownloadProgress(expected: 100, received: 10)
        parent.addChild(child1)
        parent.addChild(child2)
        XCTAssertEqual(parent.expected, 4)
        XCTAssertEqual(parent.received, 2)
    }

    func testAddDuplicateChildHasNoEffect() {
        let child = DownloadProgress(expected: 2, received: 1)
        let parent = DownloadProgress(children: [child])
        parent.addChild(child)
        XCTAssertEqual(parent.expected, 2)
        XCTAssertEqual(parent.received, 1)
    }

    func testNestedChild() {
        let grandchild = DownloadProgress(expected: 2, received: 1)
        let child = DownloadProgress(children: [grandchild])
        let parent = DownloadProgress(children: [child])

        XCTAssertEqual(parent.expected, 2)
        XCTAssertEqual(parent.received, 1)
    }

    func testChildUpdatesParent() {
        let child = DownloadProgress(expected: 2, received: 1)
        let parent = DownloadProgress(children: [child])

        child.received = 2

        XCTAssertEqual(parent.expected, 2)
        XCTAssertEqual(parent.received, 2)
    }

    func testRemoveChild() {
        let child1 = DownloadProgress(expected: 2, received: 1)
        let child2 = DownloadProgress(expected: 2, received: 1)
        let parent = DownloadProgress(children: [child1, child2])

        parent.removeChild(child1)

        XCTAssertEqual(parent.expected, 2)
        XCTAssertEqual(parent.received, 1)

        parent.removeChild(child2)

        XCTAssertEqual(parent.expected, 0)
        XCTAssertEqual(parent.received, 0)
    }

    /*
     private var cancellable: AnyCancellable?

     func testThrottle() {
         let progress = DownloadProgress(expected: 2)
         progress.throttleInterval = .milliseconds(100)

         let start = Date()
         var received: Date?

         let expectation = self.expectation(description: "it should publish a new fraction after 100ms")

         cancellable = progress.$fractionCompleted.sink { fraction in
             guard fraction == 1 else { return }
             received = Date()
             expectation.fulfill()
         }

         progress.received = 0
         progress.received = 1
         progress.received = 2

         waitForExpectations(timeout: 0.15)

         let interval = received.map { $0.timeIntervalSince(start) } ?? 0
         XCTAssertGreaterThanOrEqual(interval, 0.1)
     }
     */

    func testPerformance() {
        let children = (0 ..< 1000).map { _ -> DownloadProgress in
            DownloadProgress(expected: .random(in: 0 ... 100), received: .random(in: 0 ... 100))
        }

        let parent = DownloadProgress(children: children)

        measure {
            for child in children {
                child.received = child.expected
            }
        }
        XCTAssertEqual(parent.fractionCompleted, 1)
    }
}

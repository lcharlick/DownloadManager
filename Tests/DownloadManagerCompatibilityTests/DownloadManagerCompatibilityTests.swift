//
//  DownloadManagerCompatibilityTests.swift
//  DownloadManagerTests
//
//  Created by Lachlan Charlick on 26/8/2026.
//

import DownloadManager
import XCTest

final class DownloadManagerCompatibilityTests: XCTestCase {
    func testModuleExportsDownloadManagerType() {
        let type: Any.Type = DownloadManager.self
        XCTAssertEqual(String(describing: type), "DownloadManager")
    }
}

import XCTest

#if !canImport(ObjectiveC)
public func allTests() -> [XCTestCaseEntry] {
    [
        testCase(DownloadManagerTests.allTests)
    ]
}
#endif

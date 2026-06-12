import Foundation

// Zero-dependency test runner (Command Line Tools have no XCTest/swift-testing).
// Each function below registers-and-runs its tests via the Harness. Run with:
//   swift run LumenTests
print("Running Lumen tests…\n")

sortOrderTests()
filterStateTests()
photoTests()
photoMetaTests()
colorLabelTests()
albumTests()
renamePatternTests()
duplicateFinderTests()
exporterTests()
metadataStoreTests()
offlineRootTests()
photoAssetTests()
imageEditorTests()
incrementalScannerTests()
thumbnailCacheTests()
libraryCacheTests()
albumScaleTests()

exit(Harness.finish())

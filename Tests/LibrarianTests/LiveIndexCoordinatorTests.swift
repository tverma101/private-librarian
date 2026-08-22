import XCTest
@testable import LibrarianCore
final class LiveIndexCoordinatorTests: XCTestCase {
    private func makeCatalog() throws -> Catalog { try TestSupport.makeCatalog() }
    func testCoalescingDedupesByPath(){let q=LiveCoalescingQueue(debounceInterval:0.8); q.ingest([LiveRawEvent(path:"/a/file.txt",flags:LiveRawEvent.itemModified,eventId:1)]); q.ingest([LiveRawEvent(path:"/a/file.txt",flags:LiveRawEvent.itemModified,eventId:2)]); q.ingest([LiveRawEvent(path:"/a/file.txt",flags:LiveRawEvent.itemModified,eventId:3)]); XCTAssertEqual(q.drain()?.paths,["/a/file.txt"])}
    func testCoalescingPreservesDistinctPaths(){let q=LiveCoalescingQueue(debounceInterval:0.8); q.ingest([LiveRawEvent(path:"/a/one.txt",flags:0,eventId:1),LiveRawEvent(path:"/a/two.txt",flags:0,eventId:2),LiveRawEvent(path:"/a/three.txt",flags:0,eventId:3)]); XCTAssertEqual(q.drain()?.paths.sorted(),["/a/one.txt","/a/three.txt","/a/two.txt"])}
    func testCoalescingStormCollapses(){let q=LiveCoalescingQueue(debounceInterval:0.8); var evs:[LiveRawEvent]=[]; for i in 0..<500{evs.append(LiveRawEvent(path:"/a/file\(i%10).txt",flags:LiveRawEvent.itemModified,eventId:UInt64(i)))}; q.ingest(evs); XCTAssertEqual(q.drain()?.paths.count,10)}
    func testDroppedEventSetsMustScanFlag(){let q=LiveCoalescingQueue(debounceInterval:0.8); q.ingest([LiveRawEvent(path:"/",flags:LiveRawEvent.mustScanSubDirs,eventId:99)]); XCTAssertTrue(q.hasPendingFullRescan); XCTAssertTrue(q.drain()?.needsFullRescan==true); XCTAssertFalse(q.hasPendingFullRescan)}
    func testUserAndKernelDroppedAlsoTriggerRescan(){for flag in [LiveRawEvent.userDropped,LiveRawEvent.kernelDropped,LiveRawEvent.historyDone,LiveRawEvent.rootChanged]{let q=LiveCoalescingQueue(debounceInterval:0.8); q.ingest([LiveRawEvent(path:"/a/b",flags:flag,eventId:1)]); XCTAssertTrue(q.hasPendingFullRescan,"flag \(flag) must trigger rescan")}}
    func testCreateModifyDeleteOneFileProducesExpectedDelta() throws {
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-delta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let catalog=try makeCatalog(); let indexer=Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler())
        let c=LiveIndexCoordinator(catalog:catalog,indexer:indexer,broker:SourceBroker(),scheduler:Scheduler(),roots:[tmp])
        c.start(); defer{c.stop()}
        var idx:[String]=[]; var mis:[String]=[]
        c.testIndexOneHandler={idx.append($0); return true}; c.testMarkMissingHandler={mis.append($0)}
        let f=tmp.appendingPathComponent("note.txt")
        try "hello".write(to:f,atomically:true,encoding:.utf8)
        c.simulateFileChange(at:f.path,flags:LiveRawEvent.itemCreated); _ = c.flushForTesting()
        XCTAssertEqual(idx,[f.path]); idx.removeAll()
        try "hello world".write(to:f,atomically:true,encoding:.utf8)
        c.simulateFileChange(at:f.path,flags:LiveRawEvent.itemModified); _ = c.flushForTesting()
        XCTAssertEqual(idx,[f.path]); idx.removeAll()
        try FileManager.default.removeItem(at:f)
        c.simulateFileChange(at:f.path,flags:LiveRawEvent.itemRemoved); _ = c.flushForTesting()
        XCTAssertTrue(mis.contains(f.path)); XCTAssertTrue(idx.isEmpty)
    }
    func testDeletionMarksMissingNeverRecreates() throws {
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-del-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let catalog=try makeCatalog()
        let c=LiveIndexCoordinator(catalog:catalog,indexer:Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler()),broker:SourceBroker(),scheduler:Scheduler(),roots:[tmp])
        var mis:[String]=[]; var idx:[String]=[]
        c.testMarkMissingHandler={mis.append($0)}; c.testIndexOneHandler={idx.append($0); return true}
        let g=tmp.appendingPathComponent("ghost.txt").path
        c.ingest(events:[LiveRawEvent(path:g,flags:LiveRawEvent.itemRemoved,eventId:1)])
        _ = c.flushForTesting()
        XCTAssertTrue(mis.contains(g)); XCTAssertTrue(idx.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath:g))
    }
    func testStormCollapsesWithoutFullRescanWhenUnderLimit() throws {
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-storm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let catalog=try makeCatalog(); var opts=LiveIndexCoordinator.Options(); opts.maxCoalescedPaths=2_000
        let c=LiveIndexCoordinator(catalog:catalog,indexer:Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler()),broker:SourceBroker(),scheduler:Scheduler(),roots:[tmp],options:opts)
        var idx:Set<String>=[]; var did=false
        c.testIndexOneHandler={p in if !FileManager.default.fileExists(atPath:p){FileManager.default.createFile(atPath:p,contents:Data("x".utf8))}; idx.insert(p); return true}
        c.testFullRescanHandler={did=true}
        var evs:[LiveRawEvent]=[]; for i in 0..<500{evs.append(LiveRawEvent(path:tmp.appendingPathComponent("file\(i%20).txt").path,flags:LiveRawEvent.itemModified,eventId:UInt64(i+1)))}
        for j in 0..<20{let p=tmp.appendingPathComponent("file\(j).txt").path; if !FileManager.default.fileExists(atPath:p){FileManager.default.createFile(atPath:p,contents:Data("x".utf8))}}
        c.ingest(events:evs); _ = c.flushForTesting(); XCTAssertFalse(did); XCTAssertEqual(idx.count,20)
    }
    func testExcludesAppCatalogAndModelsDirectories() throws {
        let catalog=try makeCatalog(); let pre=LiveExclusions.prefixes(catalogPath:catalog.path)
        let dir=(catalog.path as NSString).deletingLastPathComponent
        XCTAssertTrue(LiveExclusions.isExcluded(path:dir+"/catalog.db-wal",prefixes:pre))
        XCTAssertTrue(LiveExclusions.isExcluded(path:dir+"/catalog.db",prefixes:pre))
        XCTAssertTrue(LiveExclusions.isExcluded(path:NSTemporaryDirectory()+"something",prefixes:pre))
        XCTAssertFalse(LiveExclusions.isExcluded(path:"/tmp/my-library/note.txt",prefixes:pre))
    }
    func testCoordinatorExcludesCatalogPathsFromQueue() throws {
        let catalog=try makeCatalog()
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-excl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let c=LiveIndexCoordinator(catalog:catalog,indexer:Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler()),broker:SourceBroker(),scheduler:Scheduler(),roots:[tmp])
        var idx:[String]=[]; c.testIndexOneHandler={idx.append($0); return true}
        let dir=(catalog.path as NSString).deletingLastPathComponent
        let bad=LiveRawEvent(path:dir+"/catalog.db-wal",flags:LiveRawEvent.itemModified,eventId:1)
        let good=tmp.appendingPathComponent("ok.txt").path; FileManager.default.createFile(atPath:good,contents:Data("x".utf8))
        c.ingest(events:[bad,LiveRawEvent(path:good,flags:LiveRawEvent.itemModified,eventId:2)])
        _ = c.flushForTesting(); XCTAssertFalse(idx.contains(bad.path)); XCTAssertTrue(idx.contains(good))
    }
    func testDoubleFlushIsEmpty() throws {
        let catalog=try makeCatalog()
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-fence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let c=LiveIndexCoordinator(catalog:catalog,indexer:Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler()),broker:SourceBroker(),scheduler:Scheduler(),roots:[tmp])
        c.testIndexOneHandler={_ in true}; let p=tmp.appendingPathComponent("a.txt").path
        FileManager.default.createFile(atPath:p,contents:Data("x".utf8))
        c.ingest(events:[LiveRawEvent(path:p,flags:LiveRawEvent.itemModified,eventId:1)])
        XCTAssertNotNil(c.flushForTesting()); XCTAssertNil(c.flushForTesting())
    }
    func testNoWriteEntitlement(){
        let src=(try? String(contentsOfFile:(#filePath as NSString).deletingLastPathComponent.replacingOccurrences(of:"Tests/LibrarianTests",with:"Sources/LibrarianCore")+"/LiveIndexCoordinator.swift",encoding:.utf8)) ?? ""
        XCTAssertFalse(src.contains("O_WRONLY")); XCTAssertFalse(src.contains("O_RDWR"))
        let low=src.lowercased()
        XCTAssertFalse(low.contains("com.apple.security.files.user-selected.read-write"))
        XCTAssertFalse(low.contains("com.apple.security.files.bookmarks.document-scope"))
    }
    func testDroppedEventRecoveryTriggersSafeReconciliation() throws {
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let catalog=try makeCatalog()
        let c=LiveIndexCoordinator(catalog:catalog,indexer:Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler()),broker:SourceBroker(),scheduler:Scheduler(),roots:[tmp])
        var did=false; c.testFullRescanHandler={did=true}
        c.ingest(events:[LiveRawEvent(path:tmp.path,flags:LiveRawEvent.mustScanSubDirs,eventId:1)])
        _ = c.flushForTesting(); XCTAssertTrue(did)
    }
    func testRootRemovalAndReauthorization() throws {
        let a=URL(fileURLWithPath:"/tmp/live-root-a-\(UUID().uuidString)"); let b=URL(fileURLWithPath:"/tmp/live-root-b-\(UUID().uuidString)")
        let catalog=try makeCatalog()
        let c=LiveIndexCoordinator(catalog:catalog,indexer:Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler()),broker:SourceBroker(),scheduler:Scheduler(),roots:[a])
        XCTAssertEqual(c.currentRoots.map(\.path),[a.path])
        c.addRoot(b); XCTAssertEqual(Set(c.currentRoots.map(\.path)),Set([a.path,b.path]))
        c.removeRoot(a); XCTAssertEqual(c.currentRoots.map(\.path),[b.path])
        c.addRoot(a); XCTAssertEqual(Set(c.currentRoots.map(\.path)),Set([a.path,b.path]))
        c.addRoot(a); XCTAssertEqual(c.currentRoots.count,2)
    }
    func testAppSleepWakeTriggersReconciliationWhenRunning() throws {
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-wake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:tmp,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let catalog=try makeCatalog()
        let c=LiveIndexCoordinator(catalog:catalog,indexer:Indexer(broker:SourceBroker(),catalog:catalog,scheduler:Scheduler()),broker:SourceBroker(),scheduler:Scheduler(),roots:[tmp])
        var did=false; c.testFullRescanHandler={did=true}
        c.start(); defer{c.stop()}
        XCTAssertTrue(c.running); c.handleDidWake(); Thread.sleep(forTimeInterval:0.3)
        if !did{_ = c.flushForTesting()}; XCTAssertTrue(did)
    }
    func testDirectoryDeletionMarksAllChildrenMissing() throws {
        let tmp=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("live-dir-del-\(UUID().uuidString)")
        let sub=tmp.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at:sub,withIntermediateDirectories:true); defer{try? FileManager.default.removeItem(at:tmp)}
        let catalog=try makeCatalog(); let broker=SourceBroker()
        let f1=sub.appendingPathComponent("one.txt").path; let f2=sub.appendingPathComponent("two.txt").path
        FileManager.default.createFile(atPath:f1,contents:Data("a".utf8)); FileManager.default.createFile(atPath:f2,contents:Data("b".utf8))
        let indexer=Indexer(broker:broker,catalog:catalog,scheduler:Scheduler()); _ = try indexer.indexRoot(tmp)
        XCTAssertTrue(try catalog.allFiles().contains{$0.path==f1})
        let c=LiveIndexCoordinator(catalog:catalog,indexer:indexer,broker:broker,scheduler:Scheduler(),roots:[tmp])
        try FileManager.default.removeItem(at:sub)
        c.ingest(events:[LiveRawEvent(path:sub.path,flags:LiveRawEvent.itemRemoved|LiveRawEvent.itemIsDir,eventId:1)])
        _ = c.flushForTesting()
        let after=try catalog.allFiles()
        XCTAssertEqual(after.first(where:{$0.path==f1})?.status,"missing")
        XCTAssertEqual(after.first(where:{$0.path==f2})?.status,"missing")
    }
}

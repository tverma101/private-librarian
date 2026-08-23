import Foundation
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(AppKit)
import AppKit
#endif
public struct LiveRawEvent: Sendable, Equatable {
    public let path:String; public let flags:UInt32; public let eventId:UInt64
    public init(path:String,flags:UInt32=0,eventId:UInt64=0){self.path=path;self.flags=flags;self.eventId=eventId}
    public static let mustScanSubDirs:UInt32=0x00000001; public static let userDropped:UInt32=0x00000002
    public static let kernelDropped:UInt32=0x00000004; public static let historyDone:UInt32=0x00000010
    public static let rootChanged:UInt32=0x00000020; public static let mount:UInt32=0x00000040
    public static let unmount:UInt32=0x00000080; public static let itemCreated:UInt32=0x00000100
    public static let itemRemoved:UInt32=0x00000200; public static let itemRenamed:UInt32=0x00000800
    public static let itemModified:UInt32=0x00001000; public static let itemIsDir:UInt32=0x00002000
}
public final class LiveCoalescingQueue: @unchecked Sendable {
    private let lock=NSLock(); private var pending:[String:LiveRawEvent]=[:]; private var needsFullRescan=false
    public let debounceInterval:TimeInterval
    public struct CoalescedBatch:Sendable{public let paths:[String]; public let needsFullRescan:Bool; public let rawEvents:[LiveRawEvent]}
    public init(debounceInterval:TimeInterval=0.8){self.debounceInterval=debounceInterval}
    public func ingest(_ evs:[LiveRawEvent]){guard !evs.isEmpty else{return}; lock.lock(); for ev in evs{if LiveCoalescingQueue.isDroppedEvent(flags:ev.flags){needsFullRescan=true}; pending[LiveCoalescingQueue.normalizedPath(ev.path)]=ev}; lock.unlock()}
    public static func isDroppedEvent(flags:UInt32)->Bool{let m=LiveRawEvent.mustScanSubDirs|LiveRawEvent.userDropped|LiveRawEvent.kernelDropped|LiveRawEvent.historyDone|LiveRawEvent.rootChanged; return (flags & m) != 0}
    public static func normalizedPath(_ p:String)->String{if p.count>1 && p.hasSuffix("/"){return String(p.dropLast())}; return p}
    public func drain()->CoalescedBatch?{lock.lock(); defer{lock.unlock()}; guard !pending.isEmpty || needsFullRescan else{return nil}; let b=CoalescedBatch(paths:Array(pending.keys).sorted(),needsFullRescan:needsFullRescan,rawEvents:Array(pending.values)); pending.removeAll(); needsFullRescan=false; return b}
    public var pendingCount:Int{lock.lock(); defer{lock.unlock()}; return pending.count+(needsFullRescan ? 1:0)}
    public var hasPendingFullRescan:Bool{lock.lock(); defer{lock.unlock()}; return needsFullRescan}
}
public enum LiveExclusions{
    public static func prefixes(catalogPath:String)->[String]{
        var out:[String]=[]; let fm=FileManager.default; let d=(catalogPath as NSString).deletingLastPathComponent
        func add(_ p:String){let t=(p.count>1 && p.hasSuffix("/")) ? String(p.dropLast()):p; guard !t.isEmpty,!out.contains(t) else{return}; out.append(t)}
        add(d); for r in LocalModelBridge.modelsRoots(){add(r.path)}; add((d as NSString).appendingPathComponent("Models"))
        if let c=fm.urls(for:.cachesDirectory,in:.userDomainMask).first?.path{add(c)}; add(NSTemporaryDirectory()); return out
    }
    public static func isExcluded(path:String,prefixes:[String])->Bool{let n=LiveCoalescingQueue.normalizedPath(path); for p in prefixes{if n==p || n.hasPrefix(p+"/"){return true}}; return false}
}
public final class LiveIndexCoordinator: @unchecked Sendable{
    public struct Options:Sendable{public var debounceInterval:TimeInterval=0.8; public var maxCoalescedPaths:Int=2_000; public init(){}}
    private let catalog:Catalog; private let indexer:Indexer; private let broker:SourceBroker; private let scheduler:Scheduler
    private let options:Options; private let queue:LiveCoalescingQueue
    private let workQueue=DispatchQueue(label:"librarian.live.work",qos:.utility); private let lock=NSLock()
    private var roots:[URL]; private var exclusionPrefixes:[String]; private var isRunning=false
    private var debounceWorkItem:DispatchWorkItem?; private var lastEventId:UInt64=0
    public var testIndexOneHandler:((String)throws->Bool)?; public var testMarkMissingHandler:((String)throws->Void)?; public var testFullRescanHandler:(()throws->Void)?
#if canImport(CoreServices)
    private var streams:[FSEventStreamRef]=[]
#endif
    private var wakeObserver:NSObjectProtocol?
    public init(catalog:Catalog,indexer:Indexer,broker:SourceBroker,scheduler:Scheduler,roots:[URL],options:Options=Options()){
        self.catalog=catalog; self.indexer=indexer; self.broker=broker; self.scheduler=scheduler; self.roots=roots; self.options=options
        self.queue=LiveCoalescingQueue(debounceInterval:options.debounceInterval); self.exclusionPrefixes=LiveExclusions.prefixes(catalogPath:catalog.path)
    }
    deinit{stop()}
    public func start(){
        lock.lock(); guard !isRunning else{lock.unlock();return}; isRunning=true; let snap=roots; lock.unlock()
        exclusionPrefixes=LiveExclusions.prefixes(catalogPath:catalog.path)
#if canImport(CoreServices)
        startStreams(for:snap)
#endif
        observeWake()
    }
    public func stop(){
        lock.lock(); guard isRunning else{lock.unlock();return}; isRunning=false; lock.unlock()
        debounceWorkItem?.cancel(); debounceWorkItem=nil
#if canImport(CoreServices)
        for s in streams{FSEventStreamStop(s);FSEventStreamInvalidate(s);FSEventStreamRelease(s)}; streams.removeAll()
#endif
        if let o=wakeObserver{
#if canImport(AppKit)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
#else
            NotificationCenter.default.removeObserver(o)
#endif
            wakeObserver=nil
        }
    }
    public func addRoot(_ u:URL){lock.lock(); let a=roots.contains(where:{$0.path==u.path}); if !a{roots.append(u)}; let r=isRunning; lock.unlock(); guard !a else{return}
#if canImport(CoreServices)
        if r{startStreams(for:[u])}
#endif
    }
    public func removeRoot(_ u:URL){lock.lock(); roots.removeAll{$0.path==u.path}; lock.unlock()
#if canImport(CoreServices)
        if isRunning{for s in streams{FSEventStreamStop(s);FSEventStreamInvalidate(s);FSEventStreamRelease(s)}; streams.removeAll(); lock.lock(); let snap=roots; lock.unlock(); if !snap.isEmpty{startStreams(for:snap)}}
#endif
    }
    public var currentRoots:[URL]{lock.lock(); defer{lock.unlock()}; return roots}
    public var running:Bool{lock.lock(); defer{lock.unlock()}; return isRunning}
    private func isUnderWatchedRoot(_ path:String)->Bool{
        let n=LiveCoalescingQueue.normalizedPath(path); lock.lock(); let snap=roots; lock.unlock()
        for r in snap{let rp=LiveCoalescingQueue.normalizedPath(r.path); if n==rp || n.hasPrefix(rp+"/"){return true}}
        return false
    }
    public func ingest(events:[LiveRawEvent]){
        guard !events.isEmpty else{return}
        if let m=events.map(\.eventId).max(),m>lastEventId{lastEventId=m}
        let filt=events.filter{isUnderWatchedRoot($0.path) && !LiveExclusions.isExcluded(path:$0.path,prefixes:exclusionPrefixes)}
        let hasDrop=events.contains{LiveCoalescingQueue.isDroppedEvent(flags:$0.flags)}
        if filt.isEmpty && !hasDrop{return}
        var toIngest=filt
        if hasDrop && filt.isEmpty{toIngest=[LiveRawEvent(path:"/",flags:LiveRawEvent.mustScanSubDirs,eventId:lastEventId)]}
        if hasDrop && !toIngest.contains(where:{LiveCoalescingQueue.isDroppedEvent(flags:$0.flags)}){toIngest.append(LiveRawEvent(path:"/",flags:LiveRawEvent.mustScanSubDirs,eventId:lastEventId))}
        queue.ingest(toIngest); scheduleDebounce()
    }
    public func simulateFileChange(at p:String,flags:UInt32=LiveRawEvent.itemModified){ingest(events:[LiveRawEvent(path:p,flags:flags,eventId:lastEventId &+ 1)])}
    public func handleDidWake(){lock.lock(); let r=isRunning; lock.unlock(); guard r else{return}; queue.ingest([LiveRawEvent(path:"/",flags:LiveRawEvent.mustScanSubDirs,eventId:lastEventId &+ 1)]); scheduleDebounce(immediate:true)}
    private func scheduleDebounce(immediate:Bool=false){
        workQueue.async{[weak self] in guard let self else{return}; self.lock.lock(); guard self.isRunning else{self.lock.unlock();return}; self.lock.unlock()
            self.debounceWorkItem?.cancel(); let d=immediate ? 0.05:self.options.debounceInterval
            let it=DispatchWorkItem{[weak self] in self?.drainAndProcess()}; self.debounceWorkItem=it
            self.workQueue.asyncAfter(deadline:.now()+d,execute:it)}
    }
    @discardableResult public func flushForTesting()->LiveCoalescingQueue.CoalescedBatch?{debounceWorkItem?.cancel(); debounceWorkItem=nil; return drainAndProcessSync()}
    @discardableResult private func drainAndProcess()->LiveCoalescingQueue.CoalescedBatch?{drainAndProcessSync()}
    @discardableResult private func drainAndProcessSync()->LiveCoalescingQueue.CoalescedBatch?{guard let b=queue.drain() else{return nil}; process(batch:b); return b}
    private func process(batch:LiveCoalescingQueue.CoalescedBatch){
        if batch.needsFullRescan || batch.paths.count>options.maxCoalescedPaths{doFullRescan(reason:batch.needsFullRescan ? "dropped-events":"storm-overflow"); return}
        let ps=batch.paths.filter{isUnderWatchedRoot($0) && !LiveExclusions.isExcluded(path:$0,prefixes:exclusionPrefixes)}; guard !ps.isEmpty else{return}
        for p in ps{do{try processSinglePath(p)}catch{try? catalog.recordError(opaqueRef:FileID.workerError(0),stage:"live-index",message:String(describing:error).prefix(200).description)}}
    }
    private func processSinglePath(_ p:String)throws{if (try? broker.identity(at:p))==nil{try markMissing(atOrUnder:p); return}; if let h=testIndexOneHandler{_=try h(p)}else{_=try? indexer.indexOne(path:p)}}
    private func markMissing(atOrUnder path:String)throws{
        if let h=testMarkMissingHandler{try h(path); return}
        try? catalog.markMissing(path:path)
        let pre=path.hasSuffix("/") ? String(path.dropLast()):path; let needle=pre+"/"
        for r in (try? catalog.allFiles()) ?? [] where r.status != "missing"{if r.path==path || r.path.hasPrefix(needle){try? catalog.markMissing(path:r.path)}}
    }
    private func doFullRescan(reason:String){
        if let h=testFullRescanHandler{try? h(); return}
        try? catalog.recordError(opaqueRef:"live-rescan",stage:"live-reconcile",message:"full rescan: \(reason)")
        lock.lock(); let snap=roots; lock.unlock(); for root in snap where FileManager.default.fileExists(atPath:root.path){_ = try? indexer.indexRoot(root)}
    }
    private func observeWake(){
#if canImport(AppKit)
        wakeObserver=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main){[weak self] _ in self?.handleDidWake()}
#else
        wakeObserver=NotificationCenter.default.addObserver(forName:Notification.Name("LiveIndexCoordinatorDidWake"),object:nil,queue:.main){[weak self] _ in self?.handleDidWake()}
#endif
    }
#if canImport(CoreServices)
    private func startStreams(for urls:[URL]){
        for url in urls{
            let p=url.path as NSString
            var ctx=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(self).toOpaque(),retain:nil,release:nil,copyDescription:nil)
            let fl:FSEventStreamCreateFlags=UInt32(kFSEventStreamCreateFlagFileEvents|kFSEventStreamCreateFlagNoDefer|kFSEventStreamCreateFlagWatchRoot|kFSEventStreamCreateFlagUseCFTypes)
            let lat:CFTimeInterval=options.debounceInterval
            let cb:FSEventStreamCallback={_,info,numEvents,eventPaths,eventFlags,eventIds in
                guard let info else{return}
                let c=Unmanaged<LiveIndexCoordinator>.fromOpaque(info).takeUnretainedValue()
                let paths=Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let count=min(numEvents,CFArrayGetCount(paths))
                var evs:[LiveRawEvent]=[]; evs.reserveCapacity(numEvents)
                for i in 0..<count{
                    guard let value=CFArrayGetValueAtIndex(paths,i) else{continue}
                    let object=Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
                    guard let path=object as? String else{continue}
                    evs.append(LiveRawEvent(path:path,flags:eventFlags[i],eventId:eventIds[i]))
                }
                c.ingest(events:evs)
            }
            let w=[p] as CFArray
            guard let s=FSEventStreamCreate(kCFAllocatorDefault,cb,&ctx,w,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),lat,fl) else{continue}
            FSEventStreamScheduleWithRunLoop(s,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
            FSEventStreamStart(s); streams.append(s)
        }
    }
#endif
}

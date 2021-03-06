// The MIT License (MIT)
//
// Copyright (c) 2015 Alexander Grebenyuk (github.com/kean).

import UIKit

public let ImageManagerErrorDomain = "Nuke.ImageManagerErrorDomain"
public let ImageManagerErrorCancelled = -1
public let ImageManagerErrorUnknown = -2

// MARK: - ImageManagerConfiguration

public struct ImageManagerConfiguration {
    public var loader: ImageLoading
    public var cache: ImageMemoryCaching?
    public var maxConcurrentPreheatingTaskCount = 2
    
    public init(loader: ImageLoading, cache: ImageMemoryCaching? = ImageMemoryCache()) {
        self.loader = loader
        self.cache = cache
    }
    
    public init(dataLoader: ImageDataLoading, decoder: ImageDecoding = ImageDecoder(), cache: ImageMemoryCaching? = ImageMemoryCache()) {
        let loader = ImageLoader(configuration: ImageLoaderConfiguration(dataLoader: dataLoader, decoder: decoder))
        self.init(loader: loader, cache: cache)
    }
}

// MARK: - ImageManager

public class ImageManager {
    public let configuration: ImageManagerConfiguration
    
    private var cache: ImageMemoryCaching? {
        return self.configuration.cache
    }
    private var loader: ImageLoading {
        return self.configuration.loader
    }
    private var executingTasks = Set<ImageTaskInternal>()
    private var preheatingTasks = [ImageRequestKey: ImageTaskInternal]()
    private let lock = NSRecursiveLock()
    private var invalidated = false
    private var needsToExecutePreheatingTasks = false
    private var taskIdentifier: Int32 = 0
    private var nextTaskIdentifier: Int {
        return Int(OSAtomicIncrement32(&taskIdentifier))
    }
    
    public init(configuration: ImageManagerConfiguration) {
        self.configuration = configuration
        self.loader.delegate = self
    }
    
    public func taskWithRequest(request: ImageRequest) -> ImageTask {
        return ImageTaskInternal(manager: self, request: request, identifier: self.nextTaskIdentifier)
    }
    
    public func invalidateAndCancel() {
        self.perform {
            self.loader.delegate = nil
            self.cancelTasks(self.executingTasks)
            self.preheatingTasks.removeAll()
            self.loader.invalidate()
            self.invalidated = true
        }
    }
    
    public func removeAllCachedImages() {
        self.configuration.cache?.removeAllCachedImages()
        self.loader.removeAllCachedImages()
    }
    
    // MARK: FSM (ImageTaskState)
    
    private func setState(state: ImageTaskState, forTask task: ImageTaskInternal)  {
        if task.isValidNextState(state) {
            self.transitionStateAction(task.state, toState: state, task: task)
            task.state = state
            self.enterStateAction(state, task: task)
        }
    }
    
    private func transitionStateAction(fromState: ImageTaskState, toState: ImageTaskState, task: ImageTaskInternal) {
        if fromState == .Running && toState == .Cancelled {
            self.loader.stopLoadingForTask(task)
        }
    }
    
    private func enterStateAction(state: ImageTaskState, task: ImageTaskInternal) {
        switch state {
        case .Running:
            if let response = self.cachedResponseForRequest(task.request) {
                task.response = ImageResponse.Success(response.image, ImageResponseInfo(fastResponse: true, userInfo: response.userInfo))
                self.setState(.Completed, forTask: task)
            } else {
                self.executingTasks.insert(task)
                self.loader.startLoadingForTask(task)
            }
        case .Cancelled:
            task.response = ImageResponse.Failure(NSError(domain: ImageManagerErrorDomain, code: ImageManagerErrorCancelled, userInfo: nil))
            fallthrough
        case .Completed:
            self.executingTasks.remove(task)
            self.setNeedsExecutePreheatingTasks()
            
            let completions = task.completions
            self.dispatchBlock {
                assert(task.response != nil)
                completions.forEach { $0(task.response!) }
            }
        default: break
        }
    }

    // MARK: Preheating
    
    public func startPreheatingImages(requests: [ImageRequest]) {
        self.perform {
            for request in requests {
                let key = ImageRequestKey(request, owner: self)
                if self.preheatingTasks[key] == nil {
                    self.preheatingTasks[key] = ImageTaskInternal(manager: self, request: request, identifier: self.nextTaskIdentifier).completion { [weak self] _ in
                        self?.preheatingTasks[key] = nil
                    }
                }
            }
            self.setNeedsExecutePreheatingTasks()
        }
    }
    
    public func stopPreheatingImages(requests: [ImageRequest]) {
        self.perform {
            self.cancelTasks(requests.flatMap {
                return self.preheatingTasks[ImageRequestKey($0, owner: self)]
            })
        }
    }
    
    public func stopPreheatingImages() {
        self.perform { self.cancelTasks(self.preheatingTasks.values) }
    }
    
    private func setNeedsExecutePreheatingTasks() {
        if !self.needsToExecutePreheatingTasks && !self.invalidated {
            self.needsToExecutePreheatingTasks = true
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64((0.15 * Double(NSEC_PER_SEC)))), dispatch_get_main_queue()) {
                [weak self] in self?.perform {
                    self?.executePreheatingTasksIfNeeded()
                }
            }
        }
    }
    
    private func executePreheatingTasksIfNeeded() {
        self.needsToExecutePreheatingTasks = false
        var executingTaskCount = self.executingTasks.count
        for task in (self.preheatingTasks.values.sort { $0.identifier < $1.identifier }) {
            if executingTaskCount > self.configuration.maxConcurrentPreheatingTaskCount {
                break
            }
            if task.state == .Suspended {
                self.setState(.Running, forTask: task)
                executingTaskCount++
            }
        }
    }
    
    // MARK: Memory Caching
    
    public func cachedResponseForRequest(request: ImageRequest) -> ImageCachedResponse? {
        return self.configuration.cache?.cachedResponseForKey(ImageRequestKey(request, owner: self))
    }
    
    public func storeResponse(response: ImageCachedResponse, forRequest request: ImageRequest) {
        self.configuration.cache?.storeResponse(response, forKey: ImageRequestKey(request, owner: self))
    }
    
    // MARK: Misc
    
    private func perform(@noescape block: Void -> Void) {
        self.lock.lock()
        if !self.invalidated { block() }
        self.lock.unlock()
    }

    private func dispatchBlock(block: (Void) -> Void) {
        NSThread.isMainThread() ? block() : dispatch_async(dispatch_get_main_queue(), block)
    }

    private func cancelTasks<T: SequenceType where T.Generator.Element == ImageTaskInternal>(tasks: T) {
        tasks.forEach { self.setState(.Cancelled, forTask: $0) }
    }
}

// MARK: ImageManager: ImageLoadingDelegate

extension ImageManager: ImageLoadingDelegate {
    public func imageLoader(imageLoader: ImageLoading, imageTask: ImageTask, didUpdateProgressWithCompletedUnitCount completedUnitCount: Int64, totalUnitCount: Int64) {
        dispatch_async(dispatch_get_main_queue()) {
            imageTask.progress.totalUnitCount = totalUnitCount
            imageTask.progress.completedUnitCount = completedUnitCount
        }
    }

    public func imageLoader(imageLoader: ImageLoading, imageTask: ImageTask, didCompleteWithImage image: UIImage?, error: ErrorType?, userInfo: Any?) {
        let imageTask = imageTask as! ImageTaskInternal
        if let image = image {
            self.storeResponse(ImageCachedResponse(image: image, userInfo: userInfo), forRequest: imageTask.request)
            imageTask.response = ImageResponse.Success(image, ImageResponseInfo(fastResponse: false, userInfo: userInfo))
        } else {
            imageTask.response = ImageResponse.Failure(error ?? NSError(domain: ImageManagerErrorDomain, code: ImageManagerErrorUnknown, userInfo: nil))
        }
        self.perform { self.setState(.Completed, forTask: imageTask) }
    }
}

// MARK: ImageManager: ImageTaskManaging

extension ImageManager: ImageTaskManaging {
    private func resumeManagedTask(task: ImageTaskInternal) {
        self.perform { self.setState(.Running, forTask: task) }
    }

    private func cancelManagedTask(task: ImageTaskInternal) {
        self.perform { self.setState(.Cancelled, forTask: task) }
    }

    private func addCompletion(completion: ImageTaskCompletion, forTask task: ImageTaskInternal) {
        self.perform {
            if task.state == .Completed || task.state == .Cancelled {
                self.dispatchBlock {
                    assert(task.response != nil)
                    completion(task.response!)
                }
            } else {
                task.completions.append(completion)
            }
        }
    }
}

// MARK: - ImageLoader: ImageRequestKeyOwner

extension ImageManager: ImageRequestKeyOwner {
    public func isImageRequestKey(lhs: ImageRequestKey, equalToKey rhs: ImageRequestKey) -> Bool {
        return self.loader.isRequestCacheEquivalent(lhs.request, toRequest: rhs.request)
    }
}

// MARK: - ImageManager (Convenience)

public extension ImageManager {
    func taskWithURL(URL: NSURL, completion: ImageTaskCompletion? = nil) -> ImageTask {
        return self.taskWithRequest(ImageRequest(URL: URL), completion: completion)
    }
    
    func taskWithRequest(request: ImageRequest, completion: ImageTaskCompletion? = nil) -> ImageTask {
        let task = self.taskWithRequest(request)
        if completion != nil { task.completion(completion!) }
        return task
    }
}

// MARK: - ImageManager (Shared)

public extension ImageManager {
    private static var sharedManagerIvar: ImageManager = ImageManager(configuration: ImageManagerConfiguration(dataLoader: ImageDataLoader()))
    private static var lock = OS_SPINLOCK_INIT
    private static var token: dispatch_once_t = 0
    
    public class var shared: ImageManager {
        set {
            OSSpinLockLock(&lock)
            sharedManagerIvar = newValue
            OSSpinLockUnlock(&lock)
        }
        get {
            var manager: ImageManager
            OSSpinLockLock(&lock)
            manager = sharedManagerIvar
            OSSpinLockUnlock(&lock)
            return manager
        }
    }
}

// MARK: - ImageTaskInternal

private protocol ImageTaskManaging {
    func resumeManagedTask(task: ImageTaskInternal)
    func cancelManagedTask(task: ImageTaskInternal)
    func addCompletion(completion: ImageTaskCompletion, forTask task: ImageTaskInternal)
}

private class ImageTaskInternal: ImageTask {
    let manager: ImageTaskManaging
    var completions = [ImageTaskCompletion]()
    
    init(manager: ImageTaskManaging, request: ImageRequest, identifier: Int) {
        self.manager = manager
        super.init(request: request, identifier: identifier)
    }
    
    override func resume() -> Self {
        self.manager.resumeManagedTask(self)
        return self
    }
    
    override func cancel() -> Self {
        self.manager.cancelManagedTask(self)
        return self
    }
    
    override func completion(completion: ImageTaskCompletion) -> Self {
        self.manager.addCompletion(completion, forTask: self)
        return self
    }
    
    func isValidNextState(state: ImageTaskState) -> Bool {
        switch (self.state) {
        case .Suspended: return (state == .Running || state == .Cancelled)
        case .Running: return (state == .Completed || state == .Cancelled)
        default: return false
        }
    }
}

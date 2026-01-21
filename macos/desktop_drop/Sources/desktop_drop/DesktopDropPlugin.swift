import Cocoa
import FlutterMacOS

private func findFlutterViewController(_ viewController: NSViewController?) -> FlutterViewController? {
  guard let vc = viewController else {
    return nil
  }
  if let fvc = vc as? FlutterViewController {
    return fvc
  }
  for child in vc.children {
    let fvc = findFlutterViewController(child)
    if fvc != nil {
      return fvc
    }
  }
  return nil
}

public class DesktopDropPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    guard let flutterView = registrar.view else { return }
    guard let flutterWindow = flutterView.window else { return }
    guard let vc = findFlutterViewController(flutterWindow.contentViewController) else { return }

    let channel = FlutterMethodChannel(name: "desktop_drop", binaryMessenger: registrar.messenger)

    let instance = DesktopDropPlugin()
      
      channel.setMethodCallHandler(instance.handle(_:result:))
      
    let d = DropTarget(frame: vc.view.bounds, channel: channel)
    d.autoresizingMask = [.width, .height]

    // Register for all relevant types (promises, URLs, and legacy filename arrays)
    var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    types.append(.fileURL) // public.file-url
    types.append(NSPasteboard.PasteboardType("NSFilenamesPboardType")) // legacy multi-file array
    d.registerForDraggedTypes(types)

    vc.view.addSubview(d)

    registrar.addMethodCallDelegate(instance, channel: channel)
  }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult){
 
      if call.method ==  "startAccessingSecurityScopedResource"{
            let map = call.arguments as! NSDictionary 
            var isStale: Bool = false

          let bookmarkByte = map["apple-bookmark"] as! FlutterStandardTypedData
          let bookmark = bookmarkByte.data
            
            let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            let suc = url?.startAccessingSecurityScopedResource()
            result(suc) 
            return
      }

      if call.method ==  "stopAccessingSecurityScopedResource"{
            let map = call.arguments as! NSDictionary 
            var isStale: Bool = false 
          let bookmarkByte = map["apple-bookmark"] as! FlutterStandardTypedData
          let bookmark = bookmarkByte.data
            let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            url?.stopAccessingSecurityScopedResource()
            result(true)
            return
      }

      Swift.print("method not found: \(call.method)")
      result(FlutterMethodNotImplemented)
      return
  }

   
}

class DropTarget: NSView {
  private let channel: FlutterMethodChannel
  private let itemsLock = NSLock()

  init(frame frameRect: NSRect, channel: FlutterMethodChannel) {
    self.channel = channel
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("entered", arguments: convertPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("updated", arguments: convertPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("exited", arguments: nil)
  }

  /// Create a per-drop destination for promised files (avoids name collisions).
  private func uniqueDropDestination() -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Drops", isDirectory: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS'Z'"
    let stamp = formatter.string(from: Date())
    let dest = base.appendingPathComponent(stamp, isDirectory: true)
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: nil)
    return dest
  }

  /// Queue used for reading and writing file promises.
  private lazy var workQueue: OperationQueue = {
    let providerQueue = OperationQueue()
    providerQueue.qualityOfService = .userInitiated
    return providerQueue
  }()

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pb = sender.draggingPasteboard
    let dest = uniqueDropDestination()
    let dropLocation = convertPoint(sender.draggingLocation)

    // IMPORTANT: Read from pasteboard on main thread (required by macOS).
    // This is fast even for thousands of files.
    let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    let legacyList = (pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]) ?? []
    let promiseReceivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]

    // Calculate total item count for immediate feedback
    let itemCount: Int
    if !urls.isEmpty || !legacyList.isEmpty {
      itemCount = urls.count + legacyList.count
    } else {
      itemCount = promiseReceivers?.count ?? 0
    }

    // IMMEDIATELY notify Dart that a drop was received (before processing starts).
    // This allows the app to show instant feedback like "Preparing import..."
    channel.invokeMethod("dropReceived", arguments: [itemCount, dropLocation])

    // Move all heavy processing (file stats, bookmark creation) to background thread
    // to avoid blocking the UI when dropping thousands of files.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else { return }

      var items: [[String: Any]] = []
      var seen = Set<String>()
      let group = DispatchGroup()

      // Pre-compute container paths once (not per-file)
      let bundleID = Bundle.main.bundleIdentifier ?? ""
      let containerRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/\(bundleID)", isDirectory: true)
        .path
      let tmpPath = FileManager.default.temporaryDirectory.path

      // Thread-safe helper to process a single URL
      func processURL(_ url: URL, fromPromise: Bool) -> [String: Any]? {
        let path = url.path

        // Check for duplicates under lock
        self.itemsLock.lock()
        let isNew = seen.insert(path).inserted
        self.itemsLock.unlock()
        if !isNew { return nil }

        // These operations are expensive but now run in parallel on background threads
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        let isDirectory: Bool = values?.isDirectory ?? false

        let isInsideContainer = path.hasPrefix(containerRoot) || path.hasPrefix(tmpPath)

        let bmData: Any
        if isInsideContainer {
          bmData = NSNull()
        } else {
          let bm = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
          bmData = bm ?? NSNull()
        }

        return [
          "path": path,
          "apple-bookmark": bmData,
          "isDirectory": isDirectory,
          "fromPromise": fromPromise,
        ]
      }

      // Prefer real file URLs if they exist; only fall back to promises
      if !urls.isEmpty || !legacyList.isEmpty {
        // Combine all URLs for parallel processing
        let allURLs = urls + legacyList.map { URL(fileURLWithPath: $0) }

        // Process files in parallel for maximum performance
        // Pre-allocate array with placeholders
        var results = [[String: Any]?](repeating: nil, count: allURLs.count)

        DispatchQueue.concurrentPerform(iterations: allURLs.count) { index in
          results[index] = processURL(allURLs[index], fromPromise: false)
        }

        // Collect non-nil results (filtering out duplicates that returned nil)
        items = results.compactMap { $0 }
      } else {
        // Handle file promises (e.g., VS Code, browsers, Mail)
        // Promises are inherently async, so we use the existing callback mechanism
        if let receivers = promiseReceivers, !receivers.isEmpty {
          for r in receivers {
            group.enter()
            r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: self.workQueue) { url, error in
              defer { group.leave() }
              if let error = error {
                debugPrint("NSFilePromiseReceiver error: \(error)")
                return
              }
              if let item = processURL(url, fromPromise: true) {
                self.itemsLock.lock()
                items.append(item)
                self.itemsLock.unlock()
              }
            }
          }
        }
      }

      // Wait for any file promises to complete
      group.wait()

      // Dispatch back to main thread to invoke Flutter callback
      DispatchQueue.main.async {
        self.channel.invokeMethod("performOperation_macos", arguments: items)
      }
    }
    return true
  }

  func convertPoint(_ location: NSPoint) -> [CGFloat] {
    return [location.x, bounds.height - location.y]
  }
}

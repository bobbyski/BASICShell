import Foundation

// BASICRT system objects — the interpreter's built-in classes that are
// implemented by the host rather than by BASIC code: `File` here; the
// TUI, graphics, timer, and HTTP objects follow with their hosts.
//
// A system object is a reference: copying the value that holds it shares
// the object, as the interpreter's `.systemObject(name, id)` shares an id.
// Calls go through one boxed entry point — arguments and results are
// VARIANT boxes — so the compiler needs no per-method ABI; it only types
// the result statically from its member table.

/// The runtime's system object.
package final class RTSystemObject {
    package let typeName: String
    package let payload: AnyObject

    package init(typeName: String, payload: AnyObject) {
        self.typeName = typeName
        self.payload = payload
    }
}

/// The host's VTG dispatcher (BASICRTHost) — or the stub that says no.
@_silgen_name("basic_rt_host_vtg_call") func rtHostVTGCall(_ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer

/// A `VectorTerminal()` object: no state of its own — every instance
/// shares the host canvas, as the interpreter's do.
package final class RTVectorTerminal {}

/// The `HttpClient` object's state.
package final class RTHTTPClient {
    package let baseURL: String
    package var headers: [String: String] = [:]
    init(baseURL: String) { self.baseURL = baseURL }
}

/// The `File` object's state — the interpreter's `BASICOpenFile`.
package final class RTFileObject {
    package var path: String?
    package var access: RTFileAccess?
    package var contentType: RTFileContentType?
    package var isOpen = false
    package var content: RTText = .empty
    package var position = 0
    package var lastError: String?
}

enum RTSystem {
    /// `File()` / `File(path, access, type, requireNew)`.
    static func newFile(_ arguments: [RTValue]) -> RTValue {
        let file = RTFileObject()
        let object = RTSystemObject(typeName: "File", payload: file)
        guard arguments.isEmpty || arguments.count == 4 else { basic_rt_fail("File expects 0 or 4 arguments") }
        if arguments.count == 4 {
            _ = callFile(file, method: "OPEN", arguments: arguments)
        }
        return .system(object)
    }

    /// A timer property's number, the interpreter's coercion.
    static func timerNumber(_ value: RTValue, _ what: String) -> Double {
        guard let number = value.number else { basic_rt_fail("\(what) expects a number") }
        return number
    }

    /// A timer property's flag.
    static func timerBoolean(_ value: RTValue, _ what: String) -> Bool {
        if case .boolean(let flag) = value { return flag }
        guard let number = value.number else { basic_rt_fail("\(what) expects a boolean") }
        return number != 0
    }

    /// `timer.start()` / `timer.stop()`.
    static func callTimer(_ timer: RTTimer, method: String, arguments: [RTValue]) -> RTValue {
        switch method.uppercased() {
        case "START":
            guard arguments.isEmpty else { basic_rt_fail("SecondsTimer.start expects 0 arguments") }
            guard timer.intervalSeconds > 0 else { basic_rt_fail("SecondsTimer interval must be greater than zero") }
            timer.isRunning = true
            timer.nextFire = RTEvents.now() + timer.intervalSeconds
        case "STOP", "CANCEL":
            guard arguments.isEmpty else { basic_rt_fail("SecondsTimer.stop expects 0 arguments") }
            timer.isRunning = false
        default:
            basic_rt_fail("SecondsTimer has no method \(method)")
        }
        return .empty
    }

    /// A writable property of a system object — only the timer has any.
    static func set(_ object: RTSystemObject, property: String, to value: RTValue) {
        guard let timer = object.payload as? RTTimer else {
            basic_rt_fail("\(object.typeName) has no writable property \(property)")
        }
        switch property.uppercased() {
        case "INTERVAL", "INTERVALSECONDS": timer.intervalSeconds = timerNumber(value, "SecondsTimer interval")
        case "REPEATING": timer.repeating = timerBoolean(value, "SecondsTimer repeating")
        case "RUNNING", "ISRUNNING": timer.isRunning = timerBoolean(value, "SecondsTimer running")
        case "HANDLER": basic_rt_fail("Timer handler assignment is not implemented; use ON timer GOSUB handler")
        default: basic_rt_fail("SecondsTimer has no property \(property)")
        }
    }

    static func call(_ object: RTSystemObject, method: String, arguments: [RTValue]) -> RTValue {
        switch object.payload {
        case let file as RTFileObject:
            return callFile(file, method: method, arguments: arguments)
        case let client as RTHTTPClient:
            return callHTTP(client, method: method, arguments: arguments)
        case let timer as RTTimer:
            return callTimer(timer, method: method, arguments: arguments)
        case is RTVectorTerminal:
            var boxes = arguments.map { Optional(rtOwned($0)) }
            defer { boxes.forEach { basic_rt_value_release($0) } }
            let result = boxes.withUnsafeBufferPointer { buffer in
                rtHostVTGCall(method, buffer.count, buffer.baseAddress!)
            }
            defer { basic_rt_value_release(result) }
            return rtValue(result)
        default:
            basic_rt_fail("\(object.typeName) has no method \(method)")
        }
    }

    /// `HttpClient(baseURL)`.
    static func newHTTPClient(_ arguments: [RTValue]) -> RTValue {
        guard arguments.count == 1 else { basic_rt_fail("HttpClient expects 1 argument") }
        guard let base = arguments[0].string else { basic_rt_fail("Expected a string") }
        let baseURL = base.description
        guard let url = URL(string: baseURL), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            basic_rt_fail("HttpClient requires an http or https base URL")
        }
        return .system(RTSystemObject(typeName: "HttpClient", payload: RTHTTPClient(baseURL: baseURL)))
    }

    /// The interpreter's HttpClient: `header(name, value)` and `get(path[, substitutions])`.
    /// `get` runs the request to completion — the compiled runtime has no
    /// task scheduler, so the `AWAIT` the program writes is a pass-through.
    static func callHTTP(_ client: RTHTTPClient, method: String, arguments: [RTValue]) -> RTValue {
        switch method.uppercased() {
        case "HEADER":
            guard arguments.count == 2, let name = arguments[0].string, let value = arguments[1].string else {
                basic_rt_fail("HttpClient.header expects 2 string arguments")
            }
            client.headers[name.description] = value.description
            return .empty
        case "GET":
            guard arguments.count == 1 || arguments.count == 2 else {
                basic_rt_fail("HttpClient.get expects a path and optional substitutions dictionary")
            }
            guard let pathText = arguments[0].string else { basic_rt_fail("Expected a string") }
            var path = pathText.description
            if arguments.count == 2 {
                guard case .dictionary(let dictionary) = arguments[1] else {
                    basic_rt_fail("HttpClient.get substitutions must be a dictionary")
                }
                path = substituteURLTemplate(path, values: dictionary.values)
            } else if path.contains("{") || path.contains("}") {
                basic_rt_fail("HttpClient.get URL template requires a substitutions dictionary")
            }
            let requestURL: URL
            if let absolute = URL(string: path), let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                requestURL = absolute
            } else if let base = URL(string: client.baseURL), let resolved = URL(string: path, relativeTo: base)?.absoluteURL {
                requestURL = resolved
            } else {
                basic_rt_fail("HTTP request requires an http or https URL")
            }
            var request = URLRequest(url: requestURL)
            request.httpMethod = "GET"
            client.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var outcome: (Data?, URLResponse?, Error?) = (nil, nil, nil)
            URLSession.shared.dataTask(with: request) { data, response, error in
                outcome = (data, response, error)
                semaphore.signal()
            }.resume()
            semaphore.wait()
            if let error = outcome.2 { basic_rt_fail(error.localizedDescription) }
            guard let http = outcome.1 as? HTTPURLResponse else { basic_rt_fail("HTTP request did not receive an HTTP response") }
            let headers = RTDictionary()
            for (key, value) in http.allHeaderFields {
                headers.values[String(describing: key)] = .string(RTText(String(describing: value)))
            }
            let result = RTDictionary()
            result.values["BODY"] = .string(RTText(String(decoding: outcome.0 ?? Data(), as: UTF8.self)))
            result.values["HEADERS"] = .dictionary(headers)
            result.values["OK"] = .boolean((200..<300).contains(http.statusCode))
            result.values["STATUS"] = .number(Double(http.statusCode))
            result.values["URL"] = .string(RTText(http.url?.absoluteString ?? requestURL.absoluteString))
            return .dictionary(result)
        default:
            basic_rt_fail("HttpClient has no method \(method)")
        }
    }

    private static func substituteURLTemplate(_ template: String, values: [String: RTValue]) -> String {
        var result = template
        for (key, value) in values {
            let text: String
            switch value {
            case .string(let string): text = string.description
            case .number(let number):
                if number.rounded() == number, number >= Double(Int64.min), number <= Double(Int64.max) { text = String(Int64(number)) } else { text = String(number) }
            case .boolean(let boolean): text = boolean ? "true" : "false"
            default: basic_rt_fail("URL substitution {\(key)} must be a scalar value")
            }
            let encoded = text.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? text
            result = result.replacingOccurrences(of: "{\(key)}", with: encoded)
        }
        if result.contains("{") || result.contains("}") { basic_rt_fail("URL template has an unresolved substitution") }
        return result
    }

    private static func filePath(_ value: RTValue) -> String {
        guard let string = value.string else { basic_rt_fail("Expected a string") }
        return RTFiles.validated(string.description)
    }

    private static func fileInteger(_ value: RTValue) -> Int {
        guard let number = value.number, number.rounded() == number else { basic_rt_fail("Expected an integer") }
        return Int(number)
    }

    private static func fileBoolean(_ value: RTValue) -> Bool {
        switch value {
        case .boolean(let flag): return flag
        case .number(let number) where number == 0: return false
        case .number(let number) where number == 1: return true
        default: basic_rt_fail("Expected a boolean")
        }
    }

    private static func fileAccess(_ value: RTValue) -> RTFileAccess {
        guard let string = value.string else { basic_rt_fail("Expected file access") }
        guard let access = RTFileAccess(rawValue: string.description.uppercased()) else { basic_rt_fail("Expected READ, WRITE, or BOTH") }
        return access
    }

    private static func fileContentType(_ value: RTValue) -> RTFileContentType {
        guard let string = value.string else { basic_rt_fail("Expected file type") }
        guard let type = RTFileContentType(rawValue: string.description.uppercased()) else { basic_rt_fail("Expected RAW, TEXT, or JSON") }
        return type
    }

    /// The interpreter's `callFileMethod` and `systemObjectProperty` for a File.
    static func callFile(_ file: RTFileObject, method: String, arguments: [RTValue]) -> RTValue {
        let normalized = method.uppercased()
        func requireOpen() { guard file.isOpen else { basic_rt_fail("File is not open") } }
        func requireAccess(_ allowed: Set<RTFileAccess>) {
            guard let access = file.access, allowed.contains(access) else { basic_rt_fail("Bad file mode") }
        }
        func openPath() -> String {
            guard let path = file.path else { basic_rt_fail("File is not open") }
            return path
        }
        switch normalized {
        case "OPEN":
            guard arguments.count == 4 else { basic_rt_fail("open expects 4 arguments") }
            guard !file.isOpen else { basic_rt_fail("File Already Open") }
            let path = filePath(arguments[0])
            let access = fileAccess(arguments[1])
            let contentType = fileContentType(arguments[2])
            let requireNew = fileBoolean(arguments[3])
            let exists = FileManager.default.fileExists(atPath: RTFiles.expanded(path))
            if requireNew && exists { basic_rt_fail("File Already Exists") }
            if access == .read && !exists { basic_rt_fail("File Not Found") }
            var initial: RTText = .empty
            if exists, access != .write {
                initial = contentType == .raw ? RTText(data: RTFiles.loadData(path)) : RTText(RTFiles.loadText(path))
            } else if access == .write || access == .both {
                if contentType == .raw { RTFiles.saveData(Data(), to: path) } else { RTFiles.saveText("", to: path) }
            }
            file.path = path
            file.access = access
            file.contentType = contentType
            file.isOpen = true
            file.content = initial
            file.position = 0
            return .empty
        case "READ":
            requireOpen()
            requireAccess([.read, .both])
            guard file.contentType != .json else { basic_rt_fail("Bad file mode") }
            guard arguments.count <= 1 else { basic_rt_fail("read expects 0 or 1 arguments") }
            if file.contentType == .raw {
                let data = file.content.rawData
                let start = min(file.position, data.count)
                let maxCount = arguments.isEmpty ? data.count - start : max(0, fileInteger(arguments[0]))
                let end = min(data.count, start + maxCount)
                file.position = end
                return .string(RTText(data: data.subdata(in: start..<end)))
            }
            let raw = file.content.rawString
            let start = raw.index(raw.startIndex, offsetBy: min(file.position, raw.count))
            let remaining = raw[start...]
            let result: String
            if arguments.isEmpty {
                result = String(remaining)
                file.position = raw.count
            } else {
                result = String(remaining.prefix(max(0, fileInteger(arguments[0]))))
                file.position += result.count
            }
            return .string(RTText(result))
        case "JSON":
            requireOpen()
            requireAccess([.read, .both])
            guard file.contentType == .json else { basic_rt_fail("Bad file mode") }
            guard arguments.isEmpty else { basic_rt_fail("json expects 0 arguments") }
            do throws(RTFailure) {
                return try RTJSON.decode(file.content.rawString, permissive: true)
            } catch { error.raise() }
        case "WRITE":
            requireOpen()
            requireAccess([.write, .both])
            guard file.contentType != .json else { basic_rt_fail("Bad file mode") }
            guard arguments.count == 1, let text = arguments[0].string else { basic_rt_fail("write expects a string") }
            let path = openPath()
            if file.contentType == .raw {
                var data = file.content.rawData
                let start = min(file.position, data.count)
                let end = min(data.count, start + text.rawData.count)
                data.replaceSubrange(start..<end, with: text.rawData)
                file.content = RTText(data: data)
                file.position = start + text.rawData.count
                RTFiles.saveData(data, to: path)
            } else {
                var raw = file.content.rawString
                let start = raw.index(raw.startIndex, offsetBy: min(file.position, raw.count))
                let end = raw.index(start, offsetBy: min(text.characterCount, raw.distance(from: start, to: raw.endIndex)))
                raw.replaceSubrange(start..<end, with: text.rawString)
                file.content = RTText(raw)
                file.position = min(file.position, raw.count) + text.characterCount
                RTFiles.saveText(raw, to: path)
            }
            return .empty
        case "WRITEJSON":
            requireOpen()
            requireAccess([.write, .both])
            guard file.contentType == .json else { basic_rt_fail("Bad file mode") }
            guard arguments.count == 2 else { basic_rt_fail("writeJson expects 2 arguments") }
            let pretty = fileBoolean(arguments[1])
            let text: String
            do throws(RTFailure) {
                text = try RTJSON.encode(arguments[0], pretty: pretty)
            } catch { error.raise() }
            RTFiles.saveText(text, to: openPath())
            file.content = RTText(text)
            file.position = text.count
            return .empty
        case "SIZE":
            requireOpen()
            guard arguments.isEmpty else { basic_rt_fail("size expects 0 arguments") }
            return .number(Double(file.content.byteCount))
        case "PATH", "PATH$":
            guard arguments.isEmpty else { basic_rt_fail("path$ expects 0 arguments") }
            return .string(RTText(file.path ?? ""))
        case "ACCESS", "ACCESS$":
            guard arguments.isEmpty else { basic_rt_fail("access$ expects 0 arguments") }
            return .string(RTText(file.access?.rawValue ?? ""))
        case "TYPE", "TYPE$":
            guard arguments.isEmpty else { basic_rt_fail("type$ expects 0 arguments") }
            return .string(RTText(file.contentType?.rawValue ?? ""))
        case "CLOSE":
            guard arguments.isEmpty else { basic_rt_fail("close expects 0 arguments") }
            file.isOpen = false
            return .empty
        case "ISOPEN":
            return .boolean(file.isOpen)
        case "POSITION":
            return .number(Double(file.position))
        case "EOF":
            let size = file.contentType == .raw ? file.content.byteCount : file.content.characterCount
            return .boolean(file.position >= size)
        case "ERROR", "ERROR$":
            return .string(RTText(file.lastError ?? ""))
        default:
            basic_rt_fail("File has no method \(method)")
        }
    }
}

/// `TypeName(args…)` / `NEW TypeName(args…)` for a system class; owned box.
@_cdecl("basic_rt_system_new")
public func basic_rt_system_new(_ typeName: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    let values = (0..<count).map { rtValue(arguments[$0]) }
    switch String(cString: typeName).uppercased() {
    case "FILE": return rtOwned(RTSystem.newFile(values))
    case "HTTPCLIENT": return rtOwned(RTSystem.newHTTPClient(values))
    case "VECTORTERMINAL", "VTG":
        guard values.isEmpty else { basic_rt_fail("VectorTerminal expects 0 arguments") }
        return rtOwned(RTValue.system(RTSystemObject(typeName: "VectorTerminal", payload: RTVectorTerminal())))
    case "SECONDSTIMER":
        guard values.count == 1 else { basic_rt_fail("SecondsTimer expects 1 argument") }
        return basic_rt_timer_new(RTSystem.timerNumber(values[0], "SecondsTimer interval"))
    default: basic_rt_fail("Unknown CLASS \(String(cString: typeName))")
    }
}

/// `object.Method(args…)` on a system object; the result, owned.
@_cdecl("basic_rt_system_call")
public func basic_rt_system_call(_ pointer: UnsafeMutableRawPointer?, _ method: UnsafePointer<CChar>, _ count: Int, _ arguments: UnsafePointer<UnsafeMutableRawPointer?>) -> UnsafeMutableRawPointer {
    guard case .system(let object) = rtValue(pointer) else { basic_rt_fail("Bad file object") }
    let values = (0..<count).map { rtValue(arguments[$0]) }
    return rtOwned(RTSystem.call(object, method: String(cString: method), arguments: values))
}


/// `object.property = value` on a system object.
@_cdecl("basic_rt_system_set")
public func basic_rt_system_set(_ pointer: UnsafeMutableRawPointer?, _ property: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?) {
    guard case .system(let object) = rtValue(pointer) else { basic_rt_fail("Not a system object") }
    RTSystem.set(object, property: String(cString: property), to: rtValue(value))
}

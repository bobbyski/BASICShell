import Foundation

// BASICRT `File.*` — the shared file service the interpreter exposes as
// static methods on `File`: File.Cwd$, File.ChDir, File.Mkdir, File.Rm,
// File.Rename, File.Exists, File.IsDir, File.ReadText$, File.WriteText.
// Messages follow the shell host's. The JSON, bytes, and Files$ members
// arrive with dynamic values (Phase 4.9).

private func expanded(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

private func ensureParentDirectory(for path: String) {
    let parent = (expanded(path) as NSString).deletingLastPathComponent
    guard !parent.isEmpty else { return }
    try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
}

@_cdecl("basic_rt_file_cwd")
public func basic_rt_file_cwd() -> UnsafeMutableRawPointer {
    rtOwned(FileManager.default.currentDirectoryPath)
}

@_cdecl("basic_rt_file_chdir")
public func basic_rt_file_chdir(_ pathPointer: UnsafeMutableRawPointer?) {
    let path = RTFiles.validated(rtText(pathPointer))
    var isDirectory: ObjCBool = false
    let resolved = expanded(path)
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue,
          FileManager.default.changeCurrentDirectoryPath(resolved) else {
        basic_rt_fail("Could not change directory to \(path)")
    }
}

@_cdecl("basic_rt_file_mkdir")
public func basic_rt_file_mkdir(_ pathPointer: UnsafeMutableRawPointer?) {
    let path = RTFiles.validated(rtText(pathPointer))
    do {
        try FileManager.default.createDirectory(atPath: expanded(path), withIntermediateDirectories: true)
    } catch {
        basic_rt_fail("Could not create directory \(path)")
    }
}

@_cdecl("basic_rt_file_rm")
public func basic_rt_file_rm(_ pathPointer: UnsafeMutableRawPointer?) {
    let path = RTFiles.validated(rtText(pathPointer))
    let resolved = expanded(path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) else {
        basic_rt_fail("File Not Found")
    }
    if isDirectory.boolValue {
        guard ((try? FileManager.default.contentsOfDirectory(atPath: resolved)) ?? []).isEmpty else {
            basic_rt_fail("Directory not empty")
        }
    }
    do {
        try FileManager.default.removeItem(atPath: resolved)
    } catch {
        basic_rt_fail("Could not remove \(path)")
    }
}

@_cdecl("basic_rt_file_rename")
public func basic_rt_file_rename(_ fromPointer: UnsafeMutableRawPointer?, _ toPointer: UnsafeMutableRawPointer?) {
    let source = RTFiles.validated(rtText(fromPointer))
    let destination = RTFiles.validated(rtText(toPointer))
    ensureParentDirectory(for: destination)
    do {
        try FileManager.default.moveItem(atPath: expanded(source), toPath: expanded(destination))
    } catch {
        basic_rt_fail("Could not rename \(source)")
    }
}

@_cdecl("basic_rt_file_exists")
public func basic_rt_file_exists(_ pathPointer: UnsafeMutableRawPointer?) -> Bool {
    FileManager.default.fileExists(atPath: expanded(RTFiles.validated(rtText(pathPointer))))
}

@_cdecl("basic_rt_file_isdir")
public func basic_rt_file_isdir(_ pathPointer: UnsafeMutableRawPointer?) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: expanded(RTFiles.validated(rtText(pathPointer))), isDirectory: &isDirectory) && isDirectory.boolValue
}

@_cdecl("basic_rt_file_read_text")
public func basic_rt_file_read_text(_ pathPointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let path = RTFiles.validated(rtText(pathPointer))
    guard let text = try? String(contentsOfFile: expanded(path), encoding: .utf8) else {
        basic_rt_fail("File Not Found")
    }
    return rtOwned(text)
}

@_cdecl("basic_rt_file_write_text")
public func basic_rt_file_write_text(_ pathPointer: UnsafeMutableRawPointer?, _ textPointer: UnsafeMutableRawPointer?) {
    let path = RTFiles.validated(rtText(pathPointer))
    ensureParentDirectory(for: path)
    do {
        try rtText(textPointer).write(toFile: expanded(path), atomically: true, encoding: .utf8)
    } catch {
        basic_rt_fail("Could not write \(path)")
    }
}

// MARK: - Bytes, JSON, and listings

/// `File.ReadBytes$(path)`: the file's bytes as a data-backed string; owned.
@_cdecl("basic_rt_file_read_bytes")
public func basic_rt_file_read_bytes(_ pathPointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let path = RTFiles.validated(rtText(pathPointer))
    return rtOwned(RTText(data: RTFiles.loadData(path)))
}

/// `File.WriteBytes path, bytes$`.
@_cdecl("basic_rt_file_write_bytes")
public func basic_rt_file_write_bytes(_ pathPointer: UnsafeMutableRawPointer?, _ bytesPointer: UnsafeMutableRawPointer?) {
    let path = RTFiles.validated(rtText(pathPointer))
    ensureParentDirectory(for: path)
    RTFiles.saveData(rtString(bytesPointer).rawData, to: path)
}

/// `File.AppendBytes path, bytes$`: reads, appends, rewrites.
@_cdecl("basic_rt_file_append_bytes")
public func basic_rt_file_append_bytes(_ pathPointer: UnsafeMutableRawPointer?, _ bytesPointer: UnsafeMutableRawPointer?) {
    let path = RTFiles.validated(rtText(pathPointer))
    var data = FileManager.default.fileExists(atPath: expanded(path)) ? RTFiles.loadData(path) : Data()
    data.append(rtString(bytesPointer).rawData)
    ensureParentDirectory(for: path)
    RTFiles.saveData(data, to: path)
}

/// `File.ReadJson(path[, permissive])`; owned box.
@_cdecl("basic_rt_file_read_json")
public func basic_rt_file_read_json(_ pathPointer: UnsafeMutableRawPointer?, _ permissive: Bool) -> UnsafeMutableRawPointer {
    let path = RTFiles.validated(rtText(pathPointer))
    do throws(RTFailure) {
        return rtOwned(try RTJSON.decode(RTFiles.loadText(path), permissive: permissive))
    } catch { error.raise() }
}

/// `File.WriteJson path, value[, pretty]`.
@_cdecl("basic_rt_file_write_json")
public func basic_rt_file_write_json(_ pathPointer: UnsafeMutableRawPointer?, _ value: UnsafeMutableRawPointer?, _ pretty: Bool) {
    let path = RTFiles.validated(rtText(pathPointer))
    let text: String
    do throws(RTFailure) {
        text = try RTJSON.encode(rtValue(value), pretty: pretty)
    } catch { error.raise() }
    ensureParentDirectory(for: path)
    RTFiles.saveText(text, to: path)
}

/// `File.Files$([dir])`: the names in a directory as a dynamic string
/// array (no dot-files, natural order), boxed and owned.
@_cdecl("basic_rt_file_files")
public func basic_rt_file_files(_ pathPointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    let path = pathPointer.map { RTFiles.validated(rtText($0)) } ?? FileManager.default.currentDirectoryPath
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: expanded(path)) else {
        basic_rt_fail("File Not Found")
    }
    let names = entries.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let array = RTArray(upperBounds: [names.isEmpty ? -1 : names.count - 1], isDynamic: true, element: .string, values: names.map { .string(RTText($0)) })
    return rtOwned(RTValue.array(array))
}

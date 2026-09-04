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

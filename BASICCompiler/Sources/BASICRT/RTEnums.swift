import Foundation

// ENUM values whose members carry fields (E3). A value is an RTComposite of
// the enum's synthesized record type: the case at slot 0, then each field
// name once. The compiler hands these functions a descriptor built from the
// declaration, so the runtime keeps no enum registry of its own.

/// `S.Damage`: the field at `slot`, owned and boxed — or, when the current
/// case has no such field, the interpreter's error naming the case.
///
/// The descriptor is five lines: the variable, the enum, the field, the
/// member names in order, and the tags of the members that carry the field.
@_cdecl("basic_rt_enum_field")
public func basic_rt_enum_field(_ pointer: UnsafeMutableRawPointer?, _ slot: Double, _ descriptor: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { basic_rt_fail("an ENUM value is missing") }
    let composite = rtComposite(pointer)
    let parts = rtString(descriptor).rawString.components(separatedBy: "\n")
    guard parts.count == 5 else { basic_rt_fail("a malformed ENUM field descriptor") }
    let tag = Int(composite.fields[0].number ?? 0)
    let allowed = Set(parts[4].split(separator: ",").compactMap { Int($0) })
    guard allowed.contains(tag) else {
        let members = parts[3].components(separatedBy: ",")
        let member = members.indices.contains(tag) ? members[tag] : "?"
        basic_rt_fail("\(parts[0]) is \(parts[1]).\(member), which has no field \(parts[2])")
    }
    return rtOwned(composite.fields[Int(slot)].copied())
}

/// `PRINT` of such a value, as it would be written: `Critical(30, "headshot")`,
/// or just `Missed`. The descriptor has one line per member: its name, then
/// the slot of each of its fields.
@_cdecl("basic_rt_enum_payload_text")
public func basic_rt_enum_payload_text(_ pointer: UnsafeMutableRawPointer?, _ descriptor: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    guard let pointer else { return rtOwned("") }
    let composite = rtComposite(pointer)
    let members = rtString(descriptor).rawString.components(separatedBy: "\n")
    let tag = Int(composite.fields[0].number ?? 0)
    guard members.indices.contains(tag) else { return rtOwned("") }
    let parts = members[tag].components(separatedBy: ",")
    guard parts.count > 1 else { return rtOwned(parts[0]) }
    let shown = parts.dropFirst().compactMap { Int($0) }.map { slot -> String in
        let value = composite.fields[slot]
        if case .string = value { return "\"" + value.description + "\"" }
        return value.description
    }
    return rtOwned(parts[0] + "(" + shown.joined(separator: ", ") + ")")
}

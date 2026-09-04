#!/usr/bin/env BASICShell

print "MODERN FILE TEST SUITE"

File.Mkdir "file-suite-work"

let textFile = File("file-suite-work/notes.txt", WRITE, TEXT, false)
textFile.write("alpha" + chr$(10) + "beta" + chr$(10))
print "TEXT BYTES = "; textFile.size()
textFile.close

let textInput = File("file-suite-work/notes.txt", READ, TEXT, false)
print textInput.read(5)
print textInput.read()
textInput.close

let rawFile = File("file-suite-work/bytes.bin", WRITE, RAW, false)
rawFile.write(chr$(65) + chr$(0) + chr$(255))
print "RAW BYTES = "; rawFile.size()
rawFile.close

let rawInput = File("file-suite-work/bytes.bin", READ, RAW, false)
bytes$ = rawInput.read()
rawInput.close
print "RAW READ = "; len(bytes$)

let payload as variant = FromJsonString('{"ready":true,"count":3}', true)
File.WriteJson("file-suite-work/state.json", payload, true)
let restored as variant = File.ReadJson("file-suite-work/state.json")
print "JSON READY = "; restored("ready")
print "JSON COUNT = "; restored("count")

let names as variant = File.Files$("file-suite-work")
print "FILES = "; len(names)
print names(0)
print names(1)
print names(2)

File.Rename "file-suite-work/notes.txt", "file-suite-work/renamed.txt"
print "RENAMED = "; File.Exists("file-suite-work/renamed.txt")

File.WriteText "file-suite-work/shared.txt", "shared text"
print "SHARED TEXT = "; File.ReadText$("file-suite-work/shared.txt")
File.WriteBytes "file-suite-work/shared.bin", chr$(65) + chr$(0)
File.AppendBytes "file-suite-work/shared.bin", chr$(255)
sharedBytes$ = File.ReadBytes$("file-suite-work/shared.bin")
print "SHARED BYTES = "; len(sharedBytes$)

File.Rm "file-suite-work/renamed.txt"
File.Rm "file-suite-work/bytes.bin"
File.Rm "file-suite-work/state.json"
File.Rm "file-suite-work/shared.txt"
File.Rm "file-suite-work/shared.bin"
File.Rm "file-suite-work"

print "MODERN FILE TEST SUITE COMPLETE"

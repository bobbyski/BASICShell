' Versioning and migration (D7).
'
' The database remembers which version of a class wrote it, in `_basic_schema`.
' A class ahead of the database runs the registered migrations to catch up; a
' step nobody registered, and a database ahead of the program, are refusals
' rather than guesses.

CLASS Customer
  PUBLIC Id AS INTEGER DATABASE KEY META { version: 2 }
  PUBLIC Name AS STRING DATABASE
  PUBLIC Tier AS STRING DATABASE
END CLASS

10 ON ERROR GOTO 900
20 RAN$ = ""
30 DB = SqlDatabase(":memory:")
40 STORE = DataStore(DB)
50 PRINT "the database has never heard of it: "; STORE.SchemaVersion("Customer")

' Registered, not discovered: the function is named as an argument, so the
' compiler resolves it at build time from a known set.
60 STORE.Migration("Customer", 0, 1, "MigrateCustomer0to1")
70 STORE.Migration("Customer", 1, 2, "MigrateCustomer1to2")

80 STORE.EnsureSchema("Customer")
90 PRINT "a new database starts at the class's version: "; STORE.SchemaVersion("Customer")
100 PRINT "so nothing ran: ["; RAN$; "]"

110 PRINT ""
120 PRINT "-- a database that is behind --"
130 DB.Execute("update _basic_schema set version = 0 where class_name = ?", "Customer")
140 PRINT "pretending it is at: "; STORE.SchemaVersion("Customer")
150 STORE.EnsureSchema("Customer")
160 PRINT "migrations that ran: ["; RAN$; "]"
170 PRINT "and it is now at:    "; STORE.SchemaVersion("Customer")

180 PRINT ""
190 PRINT "-- a database ahead of the program is refused --"
200 DB.Execute("update _basic_schema set version = 9 where class_name = ?", "Customer")
210 TRAPPED = 0
220 STORE.EnsureSchema("Customer")
230 PRINT "refused: "; TRAPPED; "  still at: "; STORE.SchemaVersion("Customer")

240 PRINT ""
250 PRINT "-- a missing step is named, not guessed --"
260 DB.Execute("delete from _basic_schema")
270 DB.Execute("insert into _basic_schema (class_name, version, applied_at, shape) values (?, ?, ?, ?)", "Customer", 0, "2026-01-01T00:00:00Z", "stale")
280 FRESH = DataStore(DB)
290 FRESH.Migration("Customer", 1, 2, "MigrateCustomer1to2")
300 TRAPPED = 0
310 RAN$ = ""
320 FRESH.EnsureSchema("Customer")
330 PRINT "refused: "; TRAPPED; "  migrations that ran: ["; RAN$; "]"
340 PRINT "and it is still at:   "; FRESH.SchemaVersion("Customer")

350 ON ERROR GOTO 0
360 DB.Close()
370 END

' The message is the data layer's; what a program can see is that it was
' trapped at all -- and, more to the point, that nothing moved.
900 TRAPPED = ERR
910 RESUME NEXT

FUNCTION MigrateCustomer0to1() AS VOID
  RAN$ = RAN$ + "0->1 "
END FUNCTION

FUNCTION MigrateCustomer1to2() AS VOID
  RAN$ = RAN$ + "1->2 "
END FUNCTION

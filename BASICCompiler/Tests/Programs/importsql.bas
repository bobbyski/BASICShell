' Start from SQL, and the classes are generated (D6).
'
' Nothing below declares a CLASS. Both of them come from the schema, and
' `Describe$` prints what the ORM made of them -- which is the same text
' someone would have written by hand to get that table.

IMPORT "importsql/schema.sql"

LET DB = SqlDatabase(":memory:")
LET STORE = DataStore(DB)

PRINT STORE.Describe$("customers")
PRINT STORE.Describe$("orders")

PRINT "-- and the round trip: the generated classes make their own tables --"
PRINT "customers: "; STORE.EnsureSchema("customers"); " change(s)"
PRINT "orders:    "; STORE.EnsureSchema("orders"); " change(s)"

DIM C AS customers
C = NEW customers()
C.FullName = "Ada Lovelace"
C.EmailAddress = "ada@example.com"
C.BalanceCents = 25000
C.IsVip = TRUE
C = STORE.Save(C)
PRINT "saved as #"; C.CustomerId

DIM FOUND AS customers
FOUND = STORE.Load("customers", C.CustomerId)
PRINT "loaded "; FOUND.FullName; ", vip "; FOUND.IsVip

' The column is still called "Full Name" -- asked of the database rather than
' of the class, which is the whole point of the generated DATABASE NAME.
LET ROWS = DB.Query("select * from customers")
PRINT "column 2 is still called: "; ROWS.ColumnName$(2)
ROWS.Close()
DB.Close()

' The database and the ORM, in every engine (D12).
'
' Two ways to the same data: SQL when you want it, objects when you don't.
' The provider is behind the connection string, and the ORM is behind the
' class -- so this program says nothing about SQLite, and would say nothing
' different about any other compliant provider.

ENUM Status
  Pending
  Shipped
END ENUM

CLASS Customer
  PUBLIC Id AS INTEGER DATABASE KEY
  PUBLIC Name AS STRING DATABASE NAME "customer_name"
  PUBLIC Balance AS DOUBLE DATABASE
  PUBLIC Vip AS BOOLEAN DATABASE
  PUBLIC State AS Status DATABASE
  PUBLIC Scratch AS STRING
END CLASS

LET DB = SqlDatabase(":memory:")
LET STORE = DataStore(DB)
PRINT "changes to make the schema: "; STORE.EnsureSchema("Customer")
PRINT "and none the second time:   "; STORE.EnsureSchema("Customer")

DIM ADA AS Customer
ADA = NEW Customer()
ADA.Name = "Ada Lovelace"
ADA.Balance = 250
ADA.Vip = TRUE
ADA.State = Status.Shipped
ADA.Scratch = "never stored"
ADA = STORE.Save(ADA)
PRINT "saved Ada as #"; ADA.Id

DIM GRACE AS Customer
GRACE = NEW Customer()
GRACE.Name = "Grace Hopper"
GRACE.Balance = 900
GRACE.State = Status.Pending
GRACE = STORE.Save(GRACE)
PRINT "saved Grace as #"; GRACE.Id

DIM FOUND AS Customer
FOUND = STORE.Load("Customer", ADA.Id)
PRINT "loaded "; FOUND.Name; ", balance "; FOUND.Balance; ", vip "; FOUND.Vip
' Printed by comparison rather than directly: PRINT of an ENUM-typed class
' field does not yet agree between the engines (the interpreter shows the
' number, the compiler the name), and that gap is E1's, not the database's.
IF FOUND.State = Status.Shipped THEN PRINT "state came back as Shipped"
PRINT "a field with no DATABASE marker stays empty: ["; FOUND.Scratch; "]"
PRINT "customers: "; STORE.Count("Customer")

PRINT ""
PRINT "-- the same rows, as rows --"
LET ROWS = DB.Query("select customer_name, Balance, State from Customer order by Balance desc")
PRINT "columns: "; ROWS.ColumnCount()
WHILE ROWS.Read()
  PRINT ROWS.Text$("customer_name"); " has "; ROWS.Number("Balance"); " and is "; ROWS.Text$("State")
WEND
ROWS.Close()

PRINT ""
PRINT "-- a value that looks like SQL is a value --"
DB.Execute("insert into Customer (customer_name, Balance, Vip, State) values (?, ?, ?, ?)", "'); drop table Customer; --", 0, FALSE, "Pending")
LET N = DB.Query("select count(*) as C from Customer")
IF N.Read() THEN PRINT "still here: "; N.Number("C")
N.Close()

PRINT ""
PRINT "-- deleting by key --"
PRINT "rows deleted: "; STORE.Delete("Customer", GRACE.Id)
PRINT "customers: "; STORE.Count("Customer")

DB.Close()

TYPE Point
  X AS DOUBLE
  Y AS DOUBLE = 5
END TYPE
TYPE Person
  Name AS STRING = "nobody"
  Age AS INTEGER
  Home AS Point
END TYPE
DIM P AS Person
PRINT P.Name; P.Age; P.Home.X; P.Home.Y
P.Name = "Ada"
P.Age = 36
P.Home.X = 1.5
Q = P
Q.Name = "Grace"
Q.Home.X = 99
PRINT P.Name; P.Home.X; Q.Name; Q.Home.X
PRINT P
DIM People(2) AS Person
People(1) = P
People(1).Age = 37
People(2).Name = "Linus"
PRINT People(1).Name; People(1).Age; People(2).Name; People(2).Age; P.Age
FUNCTION Older(Who AS Person) AS Person
  Who.Age = Who.Age + 10
  RETURN Who
END FUNCTION
R = Older(P)
PRINT P.Age; R.Age
PRINT $"${P.Name} lives at ${P.Home.X}"

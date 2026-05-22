record StoreInfo
    Name as string json name "name"
    Address as string json name "address"
    Phone as string json name "phone"
    StateTaxRate as double json name "stateTaxRate"
    LocalTaxRate as double json name "localTaxRate"
end record

class StoreFormatter
    function CenterColumn(text as string) as integer
        let width = SCREENWIDTH
        let column = int((width - len(text)) / 2) + 1
        if column < 1 then column = 1
        return column
    end function

    function TaxPercent(rate as double) as double
        return rate * 100
    end function

    function TaxPercentText(rate as double) as string
        return using$("##.###", rate * 100)
    end function

    function TotalTaxRate(store as StoreInfo) as double
        return store.StateTaxRate + store.LocalTaxRate
    end function
end class

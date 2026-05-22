class FirstRun
    function Run(dataPath as string) as StoreInfo
        cls
        print "AIBASIC POS SETUP"
        print
        print "No store profile was found at "; dataPath
        print
        print "Working directory:"
        print CURRENTDIR$
        print
        print "Files:"
        files
        print

        let store as StoreInfo
        print "Store name: ";
        line input store.Name
        print "Street address: ";
        line input store.Address
        print "Phone number: ";
        line input store.Phone
        input "State sales tax rate, as decimal (example .065): ", store.StateTaxRate
        input "Local sales tax rate, as decimal (example .015): ", store.LocalTaxRate

        system "mkdir -p posdata"
        let output = File()
        output.open(dataPath, WRITE, JSON, false)
        output.writeJson(store, true)
        output.close

        return store
    end function
end class

#!/usr/bin/env BASICShell
' AIBasic POS starter.
' This is intentionally written as a small app skeleton rather than a tiny demo:
' records own persisted data, classes hold formatting behavior, and the main
' program is organized into labeled sections.

import "poslib/"
option local-let

let dataPath$ = "posdata/storeinfo.json"

let formatter as StoreFormatter
formatter = new StoreFormatter()

let store as StoreInfo

if fileexists(dataPath$) then LoadStore
let setup as FirstRun
setup = new FirstRun()
store = setup.Run(dataPath$)
goto ShowApp

LoadStore:
    let storeFile = File(dataPath$, READ, JSON, false)
    store = storeFile.json()
    storeFile.close

ShowApp:
    print chr$(27) + "[0;32;40m";
    cls
    gosub ShowStoreHeader

    let menu as MainMenu
    menu = new MainMenu()
    let selected = menu.Show()

    if selected = 1 then PointOfSale
    if selected = 2 then Parts
    goto Done

ShowStoreHeader:
    let title$ = store.Name
    let address$ = store.Address
    let phone$ = store.Phone
    let taxLabel$ = "Tax Rate " + formatter.TaxPercentText(formatter.TotalTaxRate(store)) + "%"

    locate 1, formatter.CenterColumn(title$)
    print title$
    locate 2, formatter.CenterColumn(address$)
    print address$
    locate 3, formatter.CenterColumn(phone$)
    print phone$
    locate 4, formatter.CenterColumn(taxLabel$)
    print taxLabel$
    locate 6, 1
    return

PointOfSale:
    print chr$(27) + "[0;32;40m";
    cls
    gosub ShowStoreHeader
    print "Point of Sale is next on the build list."
    goto Done

Parts:
    print chr$(27) + "[0;32;40m";
    cls
    gosub ShowStoreHeader
    let part as Part
    part.Sku = "COFFEE-001"
    part.Description = "House coffee"
    part.UnitPrice = 2.5
    part.Taxable = true

    let editor as ViewEditor
    editor = new ViewEditor()
    part = editor.Edit(part)

    cls
    gosub ShowStoreHeader
    print "Part:"
    print "SKU         "; part.Sku
    print "Description "; part.Description
    print "Unit Price  "; using$("###.##", part.UnitPrice)
    print "Taxable     "; part.Taxable
    goto Done

Done:
    print
    print "POS ready."
    end

record Part
    Sku as string json name "sku" meta { label: "SKU", width: 18, required: true }
    Description as string json name "description" meta { label: "Description", width: 40 }
    UnitPrice as double json name "unitPrice" meta { label: "Unit Price", width: 12, decimals: 2 }
    Taxable as boolean json name "taxable" meta { label: "Taxable", width: 5 }
end record

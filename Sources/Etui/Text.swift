import Foundation

func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

func lowercase(_ text: String) -> String {
    guard text.unicodeScalars.contains("Σ") else { return text.lowercased() }
    let scalars = Array(text.unicodeScalars)
    var result = ""
    var precededByCased = false
    for index in scalars.indices {
        let scalar = scalars[index]
        if scalar == "Σ" {
            let followedByCased = scalars[(index + 1)...].first { !$0.properties.isCaseIgnorable }?.properties.isCased == true
            result += precededByCased && !followedByCased ? "ς" : "σ"
        } else {
            result += String(scalar).lowercased()
        }
        if !scalar.properties.isCaseIgnorable {
            precededByCased = scalar.properties.isCased
        }
    }
    return result
}

func trim(_ text: String) -> String {
    var scalars = text.unicodeScalars[...]
    while scalars.first?.properties.isWhitespace == true {
        scalars.removeFirst()
    }
    while scalars.last?.properties.isWhitespace == true {
        scalars.removeLast()
    }
    return String(scalars)
}

func plainInteger(_ value: Any?) -> NSNumber? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number) else { return nil }
    return number
}

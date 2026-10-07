@testable import AdaUI
import Testing

struct UIInspectionTypeNameTests {
    @Test func simpleViewNamesRemainReadable() {
        #expect(UIInspectionTypeName.name(of: Text.self) == "AdaUI.Text")
        #expect(UIInspectionTypeName.name(of: TextField.self) == "AdaUI.TextField")
    }

    @Test func privateAndGenericTypesHaveBoundedNominalNames() {
        #expect(UIInspectionTypeName.name(of: PrivateInspectionType.self).hasSuffix("PrivateInspectionType"))
        let name = UIInspectionTypeName.name(of: GenericPair<Text, TextField>.self)
        #expect(name.contains("GenericPair"))
        #expect(name.hasSuffix("<…>"))
        #expect(name.count < 100)
    }

    @Test func repeatedGenericArgumentsDoNotExpandExponentially() {
        // The full spelling contains millions of repeated generic argument names.
        // Inspection must name only the nominal type, not print that entire tree.
        for _ in 0..<100 {
            let name = UIInspectionTypeName.name(of: Level20.self)
            #expect(name.contains("GenericPair"))
            #expect(name.count < 100)
        }
    }
}

private struct PrivateInspectionType {}
private enum GenericPair<First, Second> {}
private typealias Level1 = GenericPair<Text, Text>
private typealias Level2 = GenericPair<Level1, Level1>
private typealias Level3 = GenericPair<Level2, Level2>
private typealias Level4 = GenericPair<Level3, Level3>
private typealias Level5 = GenericPair<Level4, Level4>
private typealias Level6 = GenericPair<Level5, Level5>
private typealias Level7 = GenericPair<Level6, Level6>
private typealias Level8 = GenericPair<Level7, Level7>
private typealias Level9 = GenericPair<Level8, Level8>
private typealias Level10 = GenericPair<Level9, Level9>
private typealias Level11 = GenericPair<Level10, Level10>
private typealias Level12 = GenericPair<Level11, Level11>
private typealias Level13 = GenericPair<Level12, Level12>
private typealias Level14 = GenericPair<Level13, Level13>
private typealias Level15 = GenericPair<Level14, Level14>
private typealias Level16 = GenericPair<Level15, Level15>
private typealias Level17 = GenericPair<Level16, Level16>
private typealias Level18 = GenericPair<Level17, Level17>
private typealias Level19 = GenericPair<Level18, Level18>
private typealias Level20 = GenericPair<Level19, Level19>

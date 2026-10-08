import Testing
@testable import AdaRender

@Suite
struct BufferDataTests {
    @Test
    func inoutElementMutationKeepsReservedStorage() {
        var data = BufferData<Int>(elements: [])
        data.elements.reserveCapacity(1_024)
        let initialAddress = data.elements.withUnsafeBufferPointer { $0.baseAddress }

        append(42, to: &data.elements)

        let finalAddress = data.elements.withUnsafeBufferPointer { $0.baseAddress }
        #expect(initialAddress == finalAddress)
        #expect(data.elements == [42])
        #expect(data.isChanged)
    }

    private func append(_ value: Int, to elements: inout [Int]) {
        elements.append(value)
    }
}

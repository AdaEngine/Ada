//
//  TextFieldViewNode+TextNavigation.swift
//  AdaEngine
//
//  Created by Codex on 19.02.2026.
//

import AdaUtils
import Foundation
import Math

extension TextFieldViewNode {
    func isTap(at position: Point, start: Point?) -> Bool {
        guard let start else {
            return false
        }

        let dx = position.x - start.x
        let dy = position.y - start.y
        return dx * dx + dy * dy <= Constants.tapMovementToleranceSquared
    }

    func handleTapCompletion(at position: Point, time: AdaUtils.TimeInterval, caretOffset: Int) {
        if self.isDoubleTap(at: position, time: time) {
            self.selectWord(at: caretOffset)
            self.clearTapCandidate()

            #if canImport(UIKit)
                self.showEditMenu(at: position)
            #endif
        } else {
            self.storeTapCandidate(at: position, time: time)

            #if canImport(UIKit)
                if self.hasSelection {
                    self.showEditMenu(at: position)
                } else {
                    self.hideEditMenu()
                }
            #endif
        }
    }

    func isDoubleTap(at position: Point, time: AdaUtils.TimeInterval) -> Bool {
        guard let lastTapTime, let lastTapPosition else {
            return false
        }

        let deltaTime = time - lastTapTime
        guard deltaTime >= 0, deltaTime <= Constants.doubleTapMaxInterval else {
            return false
        }

        let dx = position.x - lastTapPosition.x
        let dy = position.y - lastTapPosition.y
        return dx * dx + dy * dy <= Constants.doubleTapMovementToleranceSquared
    }

    func storeTapCandidate(at position: Point, time: AdaUtils.TimeInterval) {
        self.lastTapPosition = position
        self.lastTapTime = time
    }

    func clearTapCandidate() {
        self.lastTapPosition = nil
        self.lastTapTime = nil
    }

    func selectWord(at offset: Int) {
        let range = self.wordRange(at: offset)
        if range.isEmpty {
            self.setSelection(to: offset)
        } else {
            self.selectionAnchor = range.lowerBound
            self.selectionHead = range.upperBound
        }
        self.ensureCaretVisibleIfNeeded()
        self.requestDisplay()
    }

    func wordRange(at offset: Int) -> Range<Int> {
        let characters = Array(self.text)
        let count = characters.count
        guard count > 0 else {
            let clamped = max(0, min(offset, count))
            return clamped..<clamped
        }

        let clamped = max(0, min(offset, count))
        var index = clamped
        if index == count {
            index = count - 1
        }

        if !Self.isWordCharacter(characters[index]) {
            if index > 0, Self.isWordCharacter(characters[index - 1]) {
                index -= 1
            } else {
                return clamped..<clamped
            }
        }

        var start = index
        var end = index + 1
        while start > 0, Self.isWordCharacter(characters[start - 1]) {
            start -= 1
        }

        while end < count, Self.isWordCharacter(characters[end]) {
            end += 1
        }

        return start..<end
    }

    func wordBoundaryBefore(offset: Int) -> Int {
        let characters = Array(self.text)
        var index = max(0, min(offset, characters.count))
        guard index > 0 else {
            return 0
        }

        while index > 0, !Self.isWordCharacter(characters[index - 1]) {
            index -= 1
        }

        while index > 0, Self.isWordCharacter(characters[index - 1]) {
            index -= 1
        }

        return index
    }

    func wordBoundaryAfter(offset: Int) -> Int {
        let characters = Array(self.text)
        let count = characters.count
        var index = max(0, min(offset, count))
        guard index < count else {
            return count
        }

        while index < count, !Self.isWordCharacter(characters[index]) {
            index += 1
        }

        while index < count, Self.isWordCharacter(characters[index]) {
            index += 1
        }

        return index
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        var hasScalars = false
        for scalar in character.unicodeScalars {
            hasScalars = true
            if scalar == "_" {
                continue
            }

            if !CharacterSet.alphanumerics.contains(scalar) {
                return false
            }
        }

        return hasScalars
    }
}

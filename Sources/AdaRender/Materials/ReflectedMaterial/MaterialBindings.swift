//
//  MaterialBindings.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/2/23.
//

import AdaUtils

// TODO: Should we use struct here?

/// Property wrapper that specify uniform for using in ``ReflectedMaterial``.
///
/// When you want to update value in shader define `Uniform` property wrapper.
/// That property wrapper will capture your property name and will try to change the same uniform shader value in your material.
///
/// For example, if your shader uniform has property named `color` and you specify the same name in your ``ReflectedMaterial``,
/// than Uniform will connected to it by default.
@propertyWrapper
public final class Uniform<T>: _ShaderBindProperty, _ShaderUniformProperty {
    private var _value: T?

    public var wrappedValue: T {
        get {
            guard let value = _value else {
                fatalError("Property being accessed without initialization")
            }
            return value
        }
        set {
            self._value = newValue
            self.delegate?.updateValue(newValue, for: self.propertyName)
        }
    }

    weak var delegate: MaterialValueDelegate?

    var valueLayout: Int {
        MemoryLayout<T>.stride
    }

    internal var propertyName: String = ""

    /// Create a new Uniform property wrapper.
    /// - Parameter binding: The index of uniform bind group.
    /// - Parameter propertyName: Custom shader uniform property name, by default it's empty and will capture real property name.
    public init(wrappedValue: T, propertyName: String = "") {
        self._value = wrappedValue
        self.propertyName = propertyName
    }

    /// Create a new Uniform property wrapper.
    /// - Parameter binding: The index of uniform bind group.
    /// - Parameter propertyName: Custom shader uniform property name, by default it's empty and will capture real property name.
    public init(binding _: Int, propertyName: String = "") {
        self._value = nil
        self.propertyName = propertyName
    }

    func update() {
        self.delegate?.updateValue(self.wrappedValue, for: self.propertyName)
    }
}

/// Property wrapper that pass fragment texture to the ``ReflectedMaterial``.
///
/// You can specify texture for your custom material.
@propertyWrapper
public final class FragmentTexture<T: Texture>: _ShaderBindProperty {
    private var _value: T?

    public var wrappedValue: T {
        get {
            guard let value = _value else {
                fatalError("Property being accessed without initialization")
            }
            return value
        }
        set {
            self._value = newValue
            update()
        }
    }

    internal var propertyName: String = ""
    var samplerName: String

    weak var delegate: MaterialValueDelegate?

    /// Create a new texture property wrapper.
    /// - Parameter binding: The index of texture bind group.
    /// - Parameter propertyName: Custom shader texture property name, by default it's empty and will capture real property name.
    public init(wrappedValue: T, propertyName: String = "", samplerName: String) {
        self._value = wrappedValue
        self.propertyName = propertyName
        self.samplerName = samplerName
    }

    /// Create a new texture property wrapper.
    /// - Parameter binding: The index of texture bind group.
    /// - Parameter propertyName: Custom shader texture property name, by default it's empty and will capture real property name.
    public init(propertyName: String = "", samplerName: String) {
        self._value = nil
        self.propertyName = propertyName
        self.samplerName = samplerName
    }

    func update() {
        self.delegate?
            .updateTexture(
                MaterialTexture(
                    texture: self.wrappedValue,
                    samplerName: samplerName
                ),
                for: self.propertyName
            )
    }
}

/// Internal shader bind property that will used for reflection.
protocol _ShaderBindProperty: AnyObject {
    /// Contains shader property name.
    var propertyName: String { get set }

    /// Contains delegate which will recieve updates of current property wrapper.
    var delegate: MaterialValueDelegate? { get set }

    /// Update property wrapper. Should be called once when delegate connected to pass stored value to delegate.
    func update()
}

protocol _ShaderUniformProperty {
    var valueLayout: Int { get }
}

//
//  QueryPredicate.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 22.05.2025.
//

/// An object that defines the criteria for an entity query.
public struct QueryPredicate: Sendable {
    /// The function that evaluates the predicate.
    /// - Parameter archetype: The archetype to evaluate the predicate for.
    /// - Returns: True if the predicate is satisfied for the archetype, otherwise false.
    let evaluate: @Sendable (Archetype) -> Bool
}

/// Negate a predicate.
/// - Parameter operand: The predicate to negate.
/// - Returns: A new predicate that is the negation of the operand.
prefix public func ! (operand: QueryPredicate) -> QueryPredicate {
    QueryPredicate { archetype in
        !operand.evaluate(archetype)
    }
}

extension QueryPredicate {
    /// Matches every archetype.
    public static var all: QueryPredicate {
        QueryPredicate { _ in true }
    }

    /// Set the rule that entity should contains given type.
    /// - Parameter type: The type of the component to check.
    /// - Returns: A new predicate that checks if the entity contains the given component.
    public static func has<T: Component>(_ type: T.Type) -> QueryPredicate {
        QueryPredicate { archetype in
            return archetype.componentLayout.maskSet.contains(type.identifier)
        }
    }

    /// Matches archetypes containing a component resolved at runtime.
    public static func has(_ component: ComponentId) -> QueryPredicate {
        QueryPredicate { archetype in
            archetype.componentLayout.maskSet.contains(component)
        }
    }

    /// Set the rule that entity doesn't contains given type.
    /// - Parameter type: The type of the component to check.
    /// - Returns: A new predicate that checks if the entity does not contain the given component.
    public static func without<T: Component>(_ type: T.Type) -> QueryPredicate {
        QueryPredicate { archetype in
            return !archetype.componentLayout.maskSet.contains(type.identifier)
        }
    }

    /// Matches archetypes without a component resolved at runtime.
    public static func without(_ component: ComponentId) -> QueryPredicate {
        QueryPredicate { archetype in
            !archetype.componentLayout.maskSet.contains(component)
        }
    }

    /// Set AND condition for predicate.
    /// - Parameter lhs: The left predicate.
    /// - Parameter rhs: The right predicate.
    /// - Returns: A new predicate that is the conjunction of the two predicates.
    public static func && (lhs: QueryPredicate, rhs: QueryPredicate) -> QueryPredicate {
        QueryPredicate { value in
            lhs.evaluate(value) && rhs.evaluate(value)
        }
    }

    /// Set OR condition for predicate.
    /// - Parameter lhs: The left predicate.
    /// - Parameter rhs: The right predicate.
    /// - Returns: A new predicate that is the disjunction of the two predicates.
    public static func || (lhs: QueryPredicate, rhs: QueryPredicate) -> QueryPredicate {
        QueryPredicate { value in
            lhs.evaluate(value) || rhs.evaluate(value)
        }
    }
}

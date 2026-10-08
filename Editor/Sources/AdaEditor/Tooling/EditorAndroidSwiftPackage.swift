#if os(macOS)
  import Foundation
  import SwiftParser
  import SwiftSyntax

  /// Edits only the unpublished copy. SwiftPM remains responsible for compiling
  /// the project; the user's source files and manifest are never rewritten.
  enum EditorAndroidSwiftPackage {
    static func prepare(
      at stage: URL, originalRoot: URL, engineRoot: URL, model: SwiftPackageModel, product: String,
      compilerRoot: URL? = nil
    ) throws {
      guard let targetName = model.executableTargetName(forProductNamed: product),
        let target = model.targets.first(where: { $0.name == targetName })
      else {
        throw EditorPreviewBuildFailure(
          message: "Select an executable AdaEngine App product for Android export.")
      }
      let originalRoot = originalRoot.resolvingSymlinksInPath()
      let targetPath = target.path ?? "Sources/\(targetName)"
      let originalTarget =
        (targetPath.hasPrefix("/")
        ? URL(fileURLWithPath: targetPath) : originalRoot.appendingPathComponent(targetPath))
        .resolvingSymlinksInPath().standardizedFileURL
      guard originalTarget.path.hasPrefix(originalRoot.path + "/") else {
        throw EditorPreviewBuildFailure(
          message: "Android export requires project sources inside the project directory.")
      }
      let relative = String(originalTarget.path.dropFirst(originalRoot.path.count + 1))
      let sourceRoot = stage.appendingPathComponent(relative)
      let files = target.sources.filter { $0.hasSuffix(".swift") }.map {
        sourceRoot.appendingPathComponent($0)
      }
      let sources = try files.map { try String(contentsOf: $0, encoding: .utf8) }
      let bootstrapped = try EditorAndroidAppBootstrap.prepare(sources)
      for (file, source) in zip(files, bootstrapped) {
        let rewrite = AndroidSourceRewriter(bundle: model.name + "_" + targetName)
        let rewritten = rewrite.rewrite(Parser.parse(source: source)).description
        try rewritten.write(to: file, atomically: true, encoding: .utf8)
      }
      let manifestURL = stage.appendingPathComponent("Package.swift")
      let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
      let rewriter = AndroidManifestRewriter(
        product: product, target: targetName, originalRoot: originalRoot, engineRoot: engineRoot,
        compilerRoot: compilerRoot)
      let transformed = rewriter.rewrite(Parser.parse(source: manifest)).description
      guard rewriter.convertedTarget, rewriter.convertedProduct else {
        throw EditorPreviewBuildFailure(
          message:
            "Android export needs literal .executable and .executableTarget declarations for \(product). Use an Android dynamic library product for computed manifests."
        )
      }
      guard !Parser.parse(source: transformed).hasError else {
        throw EditorPreviewBuildFailure(message: "Could not prepare the Android package manifest.")
      }
      try transformed.write(to: manifestURL, atomically: true, encoding: .utf8)
    }
  }

  private final class AndroidSourceRewriter: SyntaxRewriter {
    let bundle: String
    init(bundle: String) {
      self.bundle = bundle
      super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
      var result = super.visit(node)
      result.leadingTrivia = node.leadingTrivia
      return result
    }
    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
      var result = super.visit(node)
      result.leadingTrivia = node.leadingTrivia
      return result
    }
    override func visit(_ node: MemberAccessExprSyntax) -> ExprSyntax {
      guard node.declName.baseName.text == "module",
        node.base?.trimmedDescription == "Bundle"
          || node.base?.trimmedDescription == "Foundation.Bundle" || node.base == nil
      else {
        return super.visit(node)
      }
      // Bare .module is a bundle only in resource-loading argument positions.
      if node.base == nil {
        guard let argument = node.parent?.as(LabeledExprSyntax.self),
          ["assetBundle", "from", "bundle"].contains(argument.label?.text ?? "")
        else { return super.visit(node) }
      }
      return expression("AndroidResourceBundle.bundle(named: \(swiftString(bundle)))")
    }
  }

  private final class AndroidManifestRewriter: SyntaxRewriter {
    let product: String
    let target: String
    let originalRoot: URL
    let engineRoot: URL
    let compilerRoot: URL?
    var convertedProduct = false
    var convertedTarget = false
    init(product: String, target: String, originalRoot: URL, engineRoot: URL, compilerRoot: URL?) {
      self.product = product
      self.target = target
      self.originalRoot = originalRoot
      self.engineRoot = engineRoot
      self.compilerRoot = compilerRoot
      super.init(viewMode: .sourceAccurate)
    }
    override func visit(_ node: FunctionCallExprSyntax) -> ExprSyntax {
      guard let member = node.calledExpression.as(MemberAccessExprSyntax.self) else {
        return super.visit(node)
      }
      func literal(_ label: String) -> String? {
        node.arguments.first(where: { $0.label?.text == label })?.expression.as(
          StringLiteralExprSyntax.self)?.segments.first?.as(StringSegmentSyntax.self)?.content.text
      }
      let kind = member.declName.baseName.text
      if kind == "executable", literal("name") == product {
        convertedProduct = true
        return expression(
          ".library(name: \(swiftString(product)), type: .dynamic, targets: [\(swiftString(target))])"
        )
      }
      if kind == "executableTarget", literal("name") == target {
        convertedTarget = true
        var changed = node
        var callee = member
        callee.declName.baseName = .identifier("target")
        changed.calledExpression = ExprSyntax(callee)
        return super.visit(changed)
      }
      if kind == "package" {
        if literal("name")?.lowercased() == "adaengine"
          || literal("url")?.lowercased().contains("adaengine/adaengine") == true
        {
          return expression(".package(name: \"AdaEngine\", path: \(swiftString(engineRoot.path)))")
        }
        if let compilerRoot,
          literal("name") == "gravity-lang"
            || literal("url")?.lowercased().contains("adaengine/gravity-lang") == true
        {
          return expression(
            ".package(name: \"gravity-lang\", path: \(swiftString(compilerRoot.path)))")
        }
        if let path = literal("path"), !path.hasPrefix("/") {
          var changed = node
          changed.arguments = LabeledExprListSyntax(
            node.arguments.map { argument in
              guard argument.label?.text == "path" else { return argument }
              var edited = argument
              edited.expression = expression(
                swiftString(originalRoot.appendingPathComponent(path).standardizedFileURL.path))
              return edited
            })
          return ExprSyntax(changed)
        }
      }
      return super.visit(node)
    }
  }

  private func expression(_ text: String) -> ExprSyntax {
    let tree = Parser.parse(source: "let value = " + text)
    // These are compiler-generated expressions with a fixed grammar.
    guard
      let expression = tree.statements.first?.item.as(VariableDeclSyntax.self)?.bindings.first?
        .initializer?.value
    else {
      preconditionFailure("Invalid generated Android expression")
    }
    return expression
  }

  private func swiftString(_ value: String) -> String { String(reflecting: value) }
#endif

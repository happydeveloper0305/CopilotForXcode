import ASTParser
import Foundation
import Preferences
import SuggestionModel
import SwiftTreeSitter

public enum TreeSitterTextPosition {
    case node(ASTNode)
    case range(range: NSRange, pointRange: Range<Point>)
}

public class ObjectiveCFocusedCodeFinder: KnownLanguageFocusedCodeFinder<
    ASTTree,
    ASTNode,
    TreeSitterTextPosition
> {
    override public init(
        maxFocusedCodeLineCount: Int = UserDefaults.shared.value(for: \.maxFocusedCodeLineCount)
    ) {
        super.init(maxFocusedCodeLineCount: maxFocusedCodeLineCount)
    }
    
    public func parseSyntaxTree(from document: Document) -> ASTTree? {
        let parser = ASTParser(language: .objectiveC)
        return parser.parse(document.content)
    }

    public func collectContextNodes(
        in document: Document,
        tree: ASTTree,
        containingRange range: CursorRange,
        textProvider: @escaping TextProvider,
        rangeConverter: @escaping RangeConverter
    ) -> ContextInfo {
        let visitor = ObjectiveCScopeHierarchySyntaxVisitor(
            tree: tree,
            code: document.content,
            textProvider: { node in
                textProvider(.node(node))
            },
            range: range
        )
        
        let nodes = visitor.findScopeHierarchy()
        
        return .init(nodes: nodes, includes: visitor.includes, imports: visitor.imports)
    }

    public func createTextProviderAndRangeConverter(
        for document: Document,
        tree: ASTTree
    ) -> (TextProvider, RangeConverter) {
        (
            { position in
                switch position {
                case let .node(node):
                    return document.content.cursorTextProvider(node.range, node.pointRange) ?? ""
                case let .range(range, pointRange):
                    return document.content.cursorTextProvider(range, pointRange) ?? ""
                }
            },
            { node in
                CursorRange(pointRange: node.pointRange)
            }
        )
    }

    public func contextContainingNode(
        _ node: Node,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        switch ObjectiveCNodeType(rawValue: node.nodeType ?? "") {
        case .classInterface, .categoryInterface:
            return parseClassInterfaceNode(node, textProvider: textProvider)
        case .classImplementation, .categoryImplementation:
            return parseClassImplementationNode(node, textProvider: textProvider)
        case .protocolDeclaration:
            return parseProtocolNode(node, textProvider: textProvider)
        case .methodDefinition:
            return parseMethodDefinitionNode(node, textProvider: textProvider)
        case .functionDefinition:
            return parseFunctionDefinitionNode(node, textProvider: textProvider)
        case .structSpecifier, .enumSpecifier, .nsEnumSpecifier:
            return parseTypeSpecifierNode(node, textProvider: textProvider)
        case .typeDefinition:
            return parseTypedefNode(node, textProvider: textProvider)
        default:
            return (nil, false)
        }
    }

    func parseClassInterfaceNode(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        var name = ""
        var superClass = ""
        var category = ""
        var protocols = [String]()
        let children = node.children
        for child in children {
            if let nameNode = child.child(byFieldName: "name") {
                name = textProvider(.node(nameNode))
            }
            if let superClassNode = child.child(byFieldName: "superclass") {
                superClass = textProvider(.node(superClassNode))
            }
            if let categoryNode = child.child(byFieldName: "category") {
                category = textProvider(.node(categoryNode))
            }
            if let protocolsNode = child.child(byFieldName: "protocols") {
                for protocolNode in protocolsNode.children {
                    let protocolName = textProvider(.node(protocolNode))
                    if !protocolName.isEmpty {
                        protocols.append(protocolName)
                    }
                }
            }
        }

        var signature = "@interface \(name)"
        if !category.isEmpty {
            signature += "(\(category))"
        }
        if !protocols.isEmpty {
            signature += "<\(protocols.joined(separator: ","))>"
        }
        if !superClass.isEmpty {
            signature += ": \(superClass)"
        }

        return (
            .init(
                node: node,
                signature: signature,
                name: name,
                canBeUsedAsCodeRange: true
            ),
            false
        )
    }

    func parseClassImplementationNode(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        var name = ""
        var superClass = ""
        var category = ""
        var protocols = [String]()
        let children = node.children
        for child in children {
            if let nameNode = child.child(byFieldName: "name") {
                name = textProvider(.node(nameNode))
            }
            if let superClassNode = child.child(byFieldName: "superclass") {
                superClass = textProvider(.node(superClassNode))
            }
            if let categoryNode = child.child(byFieldName: "category") {
                category = textProvider(.node(categoryNode))
            }
            if let protocolsNode = child.child(byFieldName: "protocols") {
                for protocolNode in protocolsNode.children {
                    let protocolName = textProvider(.node(protocolNode))
                    if !protocolName.isEmpty {
                        protocols.append(protocolName)
                    }
                }
            }
        }

        var signature = "@implement \(name)"
        if !category.isEmpty {
            signature += "(\(category))"
        }
        if !protocols.isEmpty {
            signature += "<\(protocols.joined(separator: ","))>"
        }
        if !superClass.isEmpty {
            signature += ": \(superClass)"
        }
        return (
            .init(
                node: node,
                signature: signature,
                name: name,
                canBeUsedAsCodeRange: true
            ),
            false
        )
    }

    func parseProtocolNode(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        var name = ""
        var protocols = [String]()
        let children = node.children
        for child in children {
            if let nameNode = child.child(byFieldName: "name") {
                name = textProvider(.node(nameNode))
            }
            if let protocolsNode = child.child(byFieldName: "protocols") {
                for protocolNode in protocolsNode.children {
                    let protocolName = textProvider(.node(protocolNode))
                    if !protocolName.isEmpty {
                        protocols.append(protocolName)
                    }
                }
            }
        }

        var signature = "@protocol \(name)"
        if !protocols.isEmpty {
            signature += "<\(protocols.joined(separator: ","))>"
        }
        return (
            .init(
                node: node,
                signature: signature,
                name: name,
                canBeUsedAsCodeRange: true
            ),
            false
        )
    }

    func parseMethodDefinitionNode(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        parseSignatureBeforeBody(node, textProvider: textProvider)
    }

    func parseFunctionDefinitionNode(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        parseSignatureBeforeBody(node, textProvider: textProvider)
    }

    func parseTypeSpecifierNode(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        parseSignatureBeforeBody(node, textProvider: textProvider)
    }

    func parseTypedefNode(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        guard let typeNode = node.child(byFieldName: "type") else { return (nil, false) }
        return parseSignatureBeforeBody(typeNode, textProvider: textProvider)
    }
}

// MARK: - Shared Parser

extension ObjectiveCFocusedCodeFinder {
    func parseSignatureBeforeBody(
        _ node: ASTNode,
        textProvider: @escaping TextProvider
    ) -> (nodeInfo: NodeInfo?, more: Bool) {
        let definitionRange = CursorRange(pointRange: node.pointRange)
        let name = node.contentOfChild(withFieldName: "name", textProvider: textProvider)
        let (
            _,
            signatureRange,
            signaturePointRange
        ) = node.extractInformationBeforeNode(withFieldName: "body")
        let signature = textProvider(.range(range: signatureRange, pointRange: signaturePointRange))
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if signature.isEmpty { return (nil, false) }
        return (
            .init(
                node: node,
                signature: signature,
                name: name ?? "N/A",
                canBeUsedAsCodeRange: false
            ),
            false
        )
    }
}

extension ASTNode {
    func contentOfChild(
        withFieldName name: String,
        textProvider: (TreeSitterTextPosition) -> String
    ) -> String? {
        guard let child = child(byFieldName: name) else { return nil }
        return textProvider(.node(child))
    }

    func extractInformationBeforeNode(withFieldName name: String) -> (
        postfixNode: ASTNode?,
        range: NSRange,
        pointRange: Range<Point>
    ) {
        guard let postfixNode = child(byFieldName: name) else {
            return (nil, range, pointRange)
        }

        let range = self.range.excluding(postfixNode.range)
        let pointRange = self.pointRange.excluding(postfixNode.pointRange)
        return (postfixNode, range, pointRange)
    }
}

extension NSRange {
    func excluding(_ range: NSRange) -> NSRange {
        let start = max(location, range.location)
        let end = min(location + length, range.location + range.length)
        return NSRange(location: start, length: end - start)
    }
}

extension Range where Bound == Point {
    func excluding(_ range: Range<Bound>) -> Range<Bound> {
        let start = Point(
            row: Swift.max(lowerBound.row, range.lowerBound.row),
            column: Swift.max(lowerBound.column, range.lowerBound.column)
        )
        let end = Point(
            row: Swift.min(upperBound.row, range.upperBound.row),
            column: Swift.min(upperBound.column, range.upperBound.column)
        )
        return Range(uncheckedBounds: (start, end))
    }
}


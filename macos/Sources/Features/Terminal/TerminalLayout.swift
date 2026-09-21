import AppKit

/// Codable layout data. Decoding never creates a view, window or terminal session.
/// Its wire format matches the existing version 1 SplitTree archives.
struct TerminalLayout<Leaf: Codable>: Codable {
    indirect enum Node: Codable {
        case view(Leaf)
        case split(Split)

        struct Split: Codable {
            let direction: Direction
            let ratio: Double
            let left: Node
            let right: Node
        }
        enum Direction: Codable { case horizontal, vertical }
        enum CodingKeys: CodingKey { case view, split }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if values.contains(.view) {
                self = .view(try values.decode(Leaf.self, forKey: .view))
            } else {
                self = .split(try values.decode(Split.self, forKey: .split))
            }
        }

        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .view(let value): try values.encode(value, forKey: .view)
            case .split(let split): try values.encode(split, forKey: .split)
            }
        }

        var leaves: [Leaf] {
            switch self {
            case .view(let value): [value]
            case .split(let split): split.left.leaves + split.right.leaves
            }
        }
    }

    struct Path: Codable {
        enum Component: Codable { case left, right }
        let path: [Component]
    }

    let root: Node?
    let zoomed: Path?
    var isEmpty: Bool { root == nil }
    var leaves: [Leaf] { root?.leaves ?? [] }

    private enum CodingKeys: CodingKey { case version, root, zoomed }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values,
                                                  debugDescription: "Unsupported terminal layout version: \(version)")
        }
        root = try values.decodeIfPresent(Node.self, forKey: .root)
        zoomed = try values.decodeIfPresent(Path.self, forKey: .zoomed)
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .version)
        try values.encodeIfPresent(root, forKey: .root)
        try values.encodeIfPresent(zoomed, forKey: .zoomed)
    }

    init<View>(_ tree: SplitTree<View>, snapshot: (View) -> Leaf) {
        func capture(_ node: SplitTree<View>.Node) -> Node {
            switch node {
            case .leaf(let view): .view(snapshot(view))
            case .split(let split): .split(.init(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio, left: capture(split.left), right: capture(split.right)))
            }
        }
        root = tree.root.map(capture)
        zoomed = tree.zoomed.flatMap { tree.root?.path(to: $0) }.map {
            Path(path: $0.path.map { $0 == .left ? .left : .right })
        }
    }

    /// Explicit materialization uses the caller's app and base configuration.
    func restore<View>(makeView: (Leaf) -> View) -> SplitTree<View> {
        func create(_ node: Node) -> SplitTree<View>.Node {
            switch node {
            case .view(let value): .leaf(view: makeView(value))
            case .split(let split): .split(.init(
                direction: split.direction == .horizontal ? .horizontal : .vertical,
                ratio: split.ratio, left: create(split.left), right: create(split.right)))
            }
        }
        let root = root.map(create)
        let zoomed = zoomed.flatMap { saved in
            root?.node(at: .init(path: saved.path.map { $0 == .left ? .left : .right }))
        }
        return .init(root: root, zoomed: zoomed)
    }
}

/// A saved terminal contains values only; it never owns a live shell or C handle.
struct SurfaceSnapshot: Codable, Identifiable {
    let id: UUID
    let pwd: String?
    let title: String?
    let isUserSetTitle: Bool

    private enum CodingKeys: String, CodingKey {
        case id = "uuid"
        case pwd, title, isUserSetTitle
    }

    init(_ view: Ghostty.SurfaceView) {
        id = view.id
        pwd = view.pwd
        title = view.title
        isUserSetTitle = view.titleFromTerminal != nil
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        pwd = try values.decodeIfPresent(String.self, forKey: .pwd)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        isUserSetTitle = try values.decodeIfPresent(Bool.self, forKey: .isUserSetTitle) ?? false
    }

    func makeView(in app: Ghostty.App, baseConfig: Ghostty.SurfaceConfiguration? = nil) -> Ghostty.SurfaceView {
        var config = baseConfig ?? Ghostty.SurfaceConfiguration()
        config.workingDirectory = pwd
        let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: id)
        view.restoreTitle(title, isUserSet: isUserSetTitle)
        return view
    }
}

// SplitTreeTests.swift
// Weir — pure-data tests for the SplitTree pane layout primitive.

import Foundation
import Testing
@testable import Weir

@Suite("SplitTree")
struct SplitTreeTests {

    // MARK: - Single-leaf basics

    @Test("a tree built from one leaf reports that leaf as focused")
    func singleLeafTree_hasOneLeafAndItIsFocused() {
        let leaf = UUID()
        let tree = SplitTree(leafID: leaf)
        #expect(tree.allLeafIDs() == [leaf])
        #expect(tree.focusedLeafID == leaf)
    }

    @Test("the bottom edge holds both sides of a side-by-side split and the lower half of a stacked one")
    func bottomEdgeLeafIDs_followTheShape() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // a | (b / c)
        let tree = SplitTree(root: .split(PaneSplit(
            direction: .horizontal,
            ratio: 0.3,
            first: .leaf(id: a),
            second: .split(PaneSplit(direction: .vertical, ratio: 0.5, first: .leaf(id: b), second: .leaf(id: c)))
        )))
        #expect(tree.bottomEdgeLeafIDs() == [a, c])
        #expect(SplitTree(leafID: a).bottomEdgeLeafIDs() == [a])
        #expect(SplitTree().bottomEdgeLeafIDs().isEmpty)
    }

    // MARK: - Insertion

    @Test(
        "inserting a leaf preserves child order and focuses the new leaf",
        arguments: [SplitDirection.horizontal, SplitDirection.vertical]
    )
    func insert_anyDirection_splitsAndFocusesNewLeaf(direction: SplitDirection) {
        let a = UUID()
        let b = UUID()
        let result = SplitTree(leafID: a).insert(at: a, direction: direction, newID: b)
        #expect(result.tree == SplitTree(
            root: .split(PaneSplit(direction: direction, ratio: 0.5, first: .leaf(id: a), second: .leaf(id: b))),
            focusedLeafID: b
        ))
        #expect(result.newLeafID == b)
    }

    @Test("inserting into an empty tree plants and focuses the first leaf")
    func insert_intoEmptyTree_plantsTheFirstLeaf() {
        let new = UUID()
        let result = SplitTree().insert(at: UUID(), direction: .horizontal, newID: new)
        #expect(result.tree == SplitTree(leafID: new))
        #expect(result.newLeafID == new)
    }

    @Test("insert at an unknown leaf is a no-op")
    func insert_atUnknownLeaf_returnsTreeUnchanged() {
        let a = UUID()
        let bogus = UUID()
        let new = UUID()
        let original = SplitTree(leafID: a)
        let result = original.insert(at: bogus, direction: .horizontal, newID: new)
        #expect(result.tree == original)
        #expect(result.newLeafID == new)
    }

    // MARK: - Removal

    @Test("removing one of two leaves collapses to the survivor and hops focus")
    func remove_oneOfTwoLeaves_collapsesAndHopsFocus() {
        let a = UUID()
        let b = UUID()
        let split = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let removed = split.remove(b)
        #expect(removed.tree == SplitTree(leafID: a))
        #expect(removed.focusTarget == a)
    }

    @Test(
        "removing a pane preserves valid focus or restores focus to the surviving sibling",
        arguments: [RemovalFocus.explicit, .unset, .stale]
    )
    func remove_unfocusedLeaf_resolvesRemainingFocus(focus: RemovalFocus) {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let tree = SplitTree(
            root: .split(PaneSplit(
                direction: .horizontal,
                ratio: 0.3,
                first: .leaf(id: a),
                second: .split(PaneSplit(direction: .vertical, ratio: 0.6, first: .leaf(id: b), second: .leaf(id: c)))
            )),
            focusedLeafID: focus == .explicit ? a : focus == .unset ? nil : UUID()
        )

        let removed = tree.remove(c)

        let expectedFocus = focus == .stale ? b : a
        #expect(removed.tree == SplitTree(
            root: .split(PaneSplit(direction: .horizontal, ratio: 0.3, first: .leaf(id: a), second: .leaf(id: b))),
            focusedLeafID: expectedFocus
        ))
        #expect(removed.tree.effectiveFocusedLeafID == expectedFocus)
        #expect(removed.focusTarget == (focus == .stale ? b : nil))
    }

    enum RemovalFocus { case explicit, unset, stale }

    @Test("removing the focused leaf moves the focus to its sibling")
    func remove_focusedLeaf_movesToSibling() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // a | (b | c), with b focused: c takes b's place and the focus.
        var tree = SplitTree(leafID: a)
            .insert(at: a, direction: .horizontal, newID: b).tree
            .insert(at: b, direction: .horizontal, newID: c).tree
        tree.focusedLeafID = b

        let removed = tree.remove(b)

        #expect(removed.tree.allLeafIDs() == [a, c])
        #expect(removed.tree.focusedLeafID == c)
        #expect(removed.focusTarget == c)
    }

    @Test("removing the last leaf produces an empty tree")
    func remove_lastLeaf_producesEmptyTree() {
        let only = UUID()
        let removed = SplitTree(leafID: only).remove(only)
        #expect(removed.tree == SplitTree())
        #expect(removed.focusTarget == nil)
    }

    // MARK: - Resize ratio clamping

    @Test("divider thickness is excluded from both pane minimums")
    func resolvedRatio_directSplit_preservesVisiblePaneFloor() {
        let ratio = PaneSplit.resolvedRatio(
            0,
            extent: 400,
            firstMinimum: 80,
            secondMinimum: 80
        )
        let firstVisibleExtent = 400 * ratio - Double(PaneSplit.dividerThickness / 2)
        #expect(abs(firstVisibleExtent - 80) < 0.001)

        let far = PaneSplit.resolvedRatio(
            1,
            extent: 400,
            firstMinimum: 80,
            secondMinimum: 80
        )
        let secondVisibleExtent = 400 * (1 - far) - Double(PaneSplit.dividerThickness / 2)
        #expect(abs(secondVisibleExtent - 80) < 0.001)
    }

    @Test("minimum extent adds same-axis descendants and takes the maximum across the other axis")
    func minimumExtent_nestedSplits_countsEveryLeafOnTheAxis() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let horizontal = SplitTree(leafID: a)
            .insert(at: a, direction: .horizontal, newID: b).tree
            .insert(at: b, direction: .horizontal, newID: c).tree
        let mixed = SplitTree(leafID: a)
            .insert(at: a, direction: .horizontal, newID: b).tree
            .insert(at: b, direction: .vertical, newID: c).tree

        #expect(horizontal.root?.minimumExtent(along: .horizontal, leafMinimum: 80) == 242)
        #expect(mixed.root?.minimumExtent(along: .horizontal, leafMinimum: 80) == 161)
        #expect(mixed.root?.minimumExtent(along: .vertical, leafMinimum: 80) == 161)
    }

    @Test("an oversized drag keeps every leaf, and the parent divider reserves its nested subtree's minimum width")
    func resize_nestedSameAxisSplit_preservesEveryLeafFloor() throws {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let tree = SplitTree(leafID: a)
            .insert(at: a, direction: .horizontal, newID: b).tree
            .insert(at: b, direction: .horizontal, newID: c).tree

        let resized = tree.resize(
            splitAt: [],
            by: 10000,
            bounds: CGSize(width: 400, height: 300),
            minSize: 80
        )
        let root = try #require(resized.root)
        guard case let .split(split) = root else {
            Issue.record("Expected a split root")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.first == .leaf(id: a))
        #expect(split.second == .split(PaneSplit(direction: .horizontal, ratio: 0.5, first: .leaf(id: b), second: .leaf(id: c))))
        #expect(resized.focusedLeafID == c)
        let secondVisibleExtent = 400 * (1 - split.ratio) - 0.5
        #expect(abs(secondVisibleExtent - 161) < 0.001)
    }

    @Test("a nested same-axis divider is resized by its unique structural path")
    func resize_leftNestedSameAxisSplit_changesOnlyTheInnerDivider() throws {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let tree = SplitTree(leafID: a)
            .insert(at: a, direction: .horizontal, newID: b).tree
            .insert(at: a, direction: .horizontal, newID: c).tree

        let resized = tree.resize(
            splitAt: [.first],
            by: 100,
            bounds: CGSize(width: 400, height: 300),
            minSize: 80
        )
        let root = try #require(resized.root)
        guard case let .split(outer) = root,
              case let .split(inner) = outer.first
        else {
            Issue.record("Expected a left-nested split tree")
            return
        }
        #expect(outer.ratio == 0.5)
        #expect(inner.ratio == 0.75)
    }

    @Test(
        "an undersized container divides the visible extent in proportion to each minimum",
        arguments: [(80.0, 80.0, 49.5), (80.0, 120.0, 39.6), (120.0, 80.0, 59.4)]
    )
    func resolvedRatio_insufficientExtent_scalesBothSubtreeMinimums(
        firstMinimum: CGFloat, secondMinimum: CGFloat, firstVisible: CGFloat
    ) {
        let ratio = PaneSplit.resolvedRatio(0.9, extent: 100, firstMinimum: firstMinimum, secondMinimum: secondMinimum)
        #expect(abs(100 * ratio - 0.5 - firstVisible) < 0.001)
        #expect(abs(100 * (1 - ratio) - 0.5 - (99 - firstVisible)) < 0.001)
    }

    // MARK: - Equalize

    @Test("equalize resets every split ratio to 0.5 while preserving leaves and focus")
    func equalize_nestedSplits_resetsAllRatiosToHalf() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // Build a→b horizontal split, then b→c vertical split, then drag
        // both dividers off-center so equalize has something to reset.
        let one = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let two = one.insert(at: b, direction: .vertical, newID: c).tree
        let bounds = CGSize(width: 800, height: 600)
        let dragged = two
            .resize(splitAt: [], by: 200, bounds: bounds, minSize: 80)
            .resize(splitAt: [.second], by: 150, bounds: bounds, minSize: 80)

        /// Walk the tree and collect every split's ratio.
        func collectRatios(_ node: PaneNode) -> [Double] {
            switch node {
            case .leaf: []
            case let .split(data):
                [data.ratio] + collectRatios(data.first) + collectRatios(data.second)
            }
        }
        // A drag that moved nothing would leave equalize nothing to reset.
        let off = dragged.root.map(collectRatios) ?? []
        #expect(off.count == 2)
        #expect(off.allSatisfy { $0 != 0.5 })

        let leveled = dragged.equalize()

        let ratios = leveled.root.map(collectRatios) ?? []
        #expect(ratios.count == 2)
        #expect(ratios.allSatisfy { $0 == 0.5 })
        #expect(Set(leveled.allLeafIDs()) == [a, b, c])
        #expect(leveled.focusedLeafID == dragged.focusedLeafID)
    }

    @Test("equalize on an empty tree is a no-op")
    func equalize_emptyTree_remainsEmpty() {
        let empty = SplitTree()
        #expect(empty.equalize().root == nil)
    }

    @Test("equalize(splitAt:) only rebalances the addressed subtree")
    func equalize_atInnerDivider_leavesOuterUntouched() {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        func tree(innerRatio: Double) -> SplitTree {
            SplitTree(
                root: .split(PaneSplit(
                    direction: .horizontal,
                    ratio: 0.7,
                    first: .leaf(id: a),
                    second: .split(PaneSplit(
                        direction: .vertical, ratio: innerRatio, first: .leaf(id: b), second: .leaf(id: c)
                    ))
                )),
                focusedLeafID: c
            )
        }

        #expect(tree(innerRatio: 0.8).equalize(splitAt: [.second]) == tree(innerRatio: 0.5))
    }

    @Test("equalize on a right-leaning same-axis tree weights every leaf equally")
    func equalize_rightLeaningSameAxis_distributesByLeafCount() throws {
        let a = UUID()
        let b = UUID()
        let c = UUID()
        // Two consecutive Split-Right from the focused pane builds H(a, H(b, c)).
        // Naive 50/50 per node would land a=1/2, b=1/4, c=1/4. The weight-based
        // pass should give the outer split 1/3 (one leaf vs two) so each of
        // a, b, c renders at a third of the width.
        let one = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let two = one.insert(at: b, direction: .horizontal, newID: c).tree

        let leveled = two.equalize()

        func collectRatios(_ node: PaneNode) -> [Double] {
            switch node {
            case .leaf: []
            case let .split(data):
                [data.ratio] + collectRatios(data.first) + collectRatios(data.second)
            }
        }
        let ratios = leveled.root.map(collectRatios) ?? []
        try #require(ratios.count == 2)
        #expect(abs(ratios[0] - 1.0 / 3.0) < 0.001)
        #expect(abs(ratios[1] - 0.5) < 0.001)
    }

    // MARK: - Directional neighbor lookup

    @Test(
        "neighborLeaf reaches the sibling in either split direction and has no orthogonal neighbor",
        arguments: [
            NeighborAxis(split: .horizontal, forward: .right, backward: .left, orthogonal: [.up, .down]),
            NeighborAxis(split: .vertical, forward: .down, backward: .up, orthogonal: [.left, .right])
        ]
    )
    func neighborLeaf_singleSplit_usesItsAxis(axis: NeighborAxis) {
        let a = UUID()
        let b = UUID()
        let tree = SplitTree(leafID: a).insert(at: a, direction: axis.split, newID: b).tree
        #expect(tree.neighborLeaf(of: a, direction: axis.forward) == b)
        #expect(tree.neighborLeaf(of: b, direction: axis.backward) == a)
        for direction in axis.orthogonal {
            #expect(tree.neighborLeaf(of: a, direction: direction) == nil)
            #expect(tree.neighborLeaf(of: b, direction: direction) == nil)
        }
    }

    struct NeighborAxis {
        let split: SplitDirection
        let forward: SpatialDirection
        let backward: SpatialDirection
        let orthogonal: [SpatialDirection]
    }

    @Test("neighborLeaf finds the orthogonal neighbor of each corner in a 2x2 grid")
    func neighborLeaf_grid2x2_findsOrthogonalNeighbors() {
        // Build a 2x2 layout:
        //  +----+----+
        //  | a  | b  |
        //  +----+----+
        //  | c  | d  |
        //  +----+----+
        // Top horizontal split, then each top leaf split vertically.
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let d = UUID()
        let r1 = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let r2 = r1.insert(at: a, direction: .vertical, newID: c).tree
        let tree = r2.insert(at: b, direction: .vertical, newID: d).tree

        #expect(tree.neighborLeaf(of: a, direction: .right) == b)
        #expect(tree.neighborLeaf(of: a, direction: .down) == c)
        #expect(tree.neighborLeaf(of: b, direction: .left) == a)
        #expect(tree.neighborLeaf(of: b, direction: .down) == d)
        #expect(tree.neighborLeaf(of: c, direction: .right) == d)
        #expect(tree.neighborLeaf(of: c, direction: .up) == a)
        #expect(tree.neighborLeaf(of: d, direction: .left) == c)
        #expect(tree.neighborLeaf(of: d, direction: .up) == b)
    }

    @Test("neighborLeaf picks the immediately adjacent column in a 3-column row")
    func neighborLeaf_threeColumn_picksImmediateNeighbor() {
        // a | b | c, all full-height. Left from c must land on b, never a.
        let a = UUID()
        let b = UUID()
        let c = UUID()
        let one = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let tree = one.insert(at: b, direction: .horizontal, newID: c).tree

        #expect(tree.neighborLeaf(of: c, direction: .left) == b)
        #expect(tree.neighborLeaf(of: b, direction: .left) == a)
        #expect(tree.neighborLeaf(of: a, direction: .right) == b)
        #expect(tree.neighborLeaf(of: b, direction: .right) == c)
    }

    @Test("neighborLeaf returns nil at the edge of a single-leaf tree")
    func neighborLeaf_singleLeaf_returnsNilInAllDirections() {
        let only = UUID()
        let tree = SplitTree(leafID: only)
        for d in [SpatialDirection.left, .right, .up, .down] {
            #expect(tree.neighborLeaf(of: only, direction: d) == nil)
        }
    }

    @Test("rendered rectangles override stored ratios for directional adjacency")
    func neighborLeaf_renderedRects_usesVisibleGeometry() {
        let upperLeft = UUID()
        let lowerLeft = UUID()
        let upperRight = UUID()
        let lowerRight = UUID()
        let tree = SplitTree(root: .split(PaneSplit(
            direction: .horizontal,
            ratio: 0.5,
            first: .split(PaneSplit(direction: .vertical, ratio: 0.05, first: .leaf(id: upperLeft), second: .leaf(id: lowerLeft))),
            second: .split(PaneSplit(direction: .vertical, ratio: 0.75, first: .leaf(id: upperRight), second: .leaf(id: lowerRight)))
        )))
        // The 80pt pane floor moves both dividers within the columns. Both neighbors
        // still overlap the origin and have the same gap along the move.
        let rects: [(id: UUID, rect: CGRect)] = [
            (upperLeft, CGRect(x: 0, y: 0, width: 100, height: 80)),
            (lowerLeft, CGRect(x: 0, y: 81, width: 100, height: 219)),
            (upperRight, CGRect(x: 101, y: 0, width: 100, height: 219)),
            (lowerRight, CGRect(x: 101, y: 220, width: 100, height: 80))
        ]

        #expect(tree.neighborLeaf(of: lowerLeft, direction: .right) == upperRight)
        #expect(tree.neighborLeaf(of: lowerLeft, direction: .right, rects: rects) == lowerRight)
    }

    @Test("rendered rectangles preserve visual up and down directions")
    func neighborLeaf_renderedRects_distinguishesVerticalDirections() {
        let top = UUID()
        let middle = UUID()
        let bottom = UUID()
        let tree = SplitTree(leafID: top)
            .insert(at: top, direction: .vertical, newID: middle).tree
            .insert(at: middle, direction: .vertical, newID: bottom).tree
        let rects: [(id: UUID, rect: CGRect)] = [
            (top, CGRect(x: 0, y: 0, width: 100, height: 80)),
            (middle, CGRect(x: 0, y: 86, width: 100, height: 80)),
            (bottom, CGRect(x: 0, y: 172, width: 100, height: 80))
        ]

        #expect(tree.neighborLeaf(of: middle, direction: .up, rects: rects) == top)
        #expect(tree.neighborLeaf(of: middle, direction: .down, rects: rects) == bottom)
    }

    // MARK: - Codable wire format

    // The `Codable` form doubles as the on-disk session layout, so these
    // guard the persisted JSON keys — a future rename that breaks backward
    // compat with an existing `state.json` should fail here.

    @Test("a split tree round-trips through Codable unchanged")
    func codable_splitTree_roundTrips() throws {
        let a = UUID()
        let b = UUID()
        let tree = SplitTree(leafID: a).insert(at: a, direction: .horizontal, newID: b).tree
        let data = try JSONEncoder().encode(tree)
        let restored = try JSONDecoder().decode(SplitTree.self, from: data)
        #expect(restored == tree)
    }

    @Test("the persisted split layout decodes from and encodes to the state.json shape")
    func codable_persistedKeys_areStable() throws {
        let fixture = Data("""
        {
          "root": {"split": {"_0": {
            "direction": "horizontal",
            "ratio": 0.25,
            "first": {"leaf": {"id": "00000000-0000-0000-0000-000000000001"}},
            "second": {"split": {"_0": {
              "direction": "vertical",
              "ratio": 0.75,
              "first": {"leaf": {"id": "00000000-0000-0000-0000-000000000002"}},
              "second": {"leaf": {"id": "00000000-0000-0000-0000-000000000003"}}
            }}}
          }}},
          "focusedLeafID": "00000000-0000-0000-0000-000000000003"
        }
        """.utf8)
        let a = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let b = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let c = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let expected = SplitTree(
            root: .split(PaneSplit(
                direction: .horizontal,
                ratio: 0.25,
                first: .leaf(id: a),
                second: .split(PaneSplit(direction: .vertical, ratio: 0.75, first: .leaf(id: b), second: .leaf(id: c)))
            )),
            focusedLeafID: c
        )
        #expect(try JSONDecoder().decode(SplitTree.self, from: fixture) == expected)

        let persisted = try #require(JSONSerialization.jsonObject(with: fixture) as? NSDictionary)
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as? NSDictionary)
        #expect(encoded == persisted)
    }
}

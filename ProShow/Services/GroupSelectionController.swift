import Foundation

/// Groups, ungroups, and derives compound bounds for canvas selections.
enum GroupSelectionController {
    static func compoundBounds(of objects: [CanvasObject]) -> CanvasBounds? {
        CanvasBounds.union(objects.map(\.bounds))
    }

    static func members(of groupID: UUID, in objects: [CanvasObject]) -> [CanvasObject] {
        objects.filter { $0.groupID == groupID }
    }

    static func sharedGroupID(for ids: Set<UUID>, in objects: [CanvasObject]) -> UUID? {
        let selected = objects.filter { ids.contains($0.id) }
        guard let first = selected.first?.groupID else { return nil }
        guard selected.allSatisfy({ $0.groupID == first }) else { return nil }
        return first
    }

    static func groupIDs(in ids: Set<UUID>, objects: [CanvasObject]) -> Set<UUID> {
        Set(objects.filter { ids.contains($0.id) }.compactMap(\.groupID))
    }

    @discardableResult
    static func groupSelectedElements(
        selectedIds: [UUID],
        objects: inout [CanvasObject],
        groups: inout [CanvasGroupNode]
    ) -> CanvasGroupNode? {
        var seen = Set<UUID>()
        let unique = selectedIds.filter { seen.insert($0).inserted }
        guard unique.count > 1 else { return nil }
        let targets = objects.filter { unique.contains($0.id) }
        guard targets.count > 1, let bounds = compoundBounds(of: targets) else { return nil }

        let node = CanvasGroupNode(
            name: "Group \(groups.count + 1)",
            childElementIds: unique,
            bounds: bounds
        )
        for index in objects.indices where unique.contains(objects[index].id) {
            objects[index].groupID = node.id
        }
        groups.removeAll { group in
            group.childElementIds.allSatisfy { unique.contains($0) }
        }
        groups.append(node)
        pruneEmptyGroups(objects: objects, groups: &groups)
        return node
    }

    static func ungroupNode(
        groupId: UUID,
        objects: inout [CanvasObject],
        groups: inout [CanvasGroupNode]
    ) {
        for index in objects.indices where objects[index].groupID == groupId {
            objects[index].groupID = nil
        }
        groups.removeAll { $0.id == groupId }
    }

    static func refreshBounds(
        groupId: UUID,
        objects: [CanvasObject],
        groups: inout [CanvasGroupNode]
    ) {
        guard let index = groups.firstIndex(where: { $0.id == groupId }) else { return }
        let members = members(of: groupId, in: objects)
        groups[index].childElementIds = members.map(\.id)
        if let bounds = compoundBounds(of: members) {
            groups[index].bounds = bounds
        }
    }

    static func pruneEmptyGroups(objects: [CanvasObject], groups: inout [CanvasGroupNode]) {
        let live = Set(objects.compactMap(\.groupID))
        groups.removeAll { !live.contains($0.id) || members(of: $0.id, in: objects).count < 2 }
    }

    static func inferredGroups(from objects: [CanvasObject], stored: [CanvasGroupNode] = []) -> [CanvasGroupNode] {
        let ids = Set(objects.compactMap(\.groupID))
        return ids.compactMap { id in
            let children = members(of: id, in: objects)
            guard children.count > 1, let bounds = compoundBounds(of: children) else { return nil }
            if let existing = stored.first(where: { $0.id == id }) {
                var node = existing
                node.childElementIds = children.map(\.id)
                node.bounds = bounds
                return node
            }
            return CanvasGroupNode(id: id, name: "Group", childElementIds: children.map(\.id), bounds: bounds)
        }
    }

    /// Front-to-back outline: group folders wrap their children; collapsed folders hide children.
    static func treeRows(
        objects: [CanvasObject],
        groups: [CanvasGroupNode],
        collapsedGroupIDs: Set<UUID>
    ) -> [ObjectTreeItem] {
        let sorted = objects.sorted { $0.zIndex > $1.zIndex }
        var emitted = Set<UUID>()
        var rows: [ObjectTreeItem] = []
        for object in sorted {
            if let groupID = object.groupID {
                guard !emitted.contains(groupID) else { continue }
                emitted.insert(groupID)
                let children = sorted.filter { $0.groupID == groupID }
                let name = groups.first(where: { $0.id == groupID })?.name ?? "Group"
                let expanded = !collapsedGroupIDs.contains(groupID)
                rows.append(.group(id: groupID, name: name, childIDs: children.map(\.id), isExpanded: expanded))
                if expanded {
                    rows.append(contentsOf: children.map { ObjectTreeItem.object($0, depth: 1) })
                }
            } else {
                rows.append(.object(object, depth: 0))
            }
        }
        return rows
    }

    static func objectIDs(in rows: [ObjectTreeItem], from startID: UUID, to endID: UUID) -> Set<UUID> {
        guard let start = rows.firstIndex(where: { $0.id == startID }),
              let end = rows.firstIndex(where: { $0.id == endID })
        else { return [] }
        let lower = min(start, end)
        let upper = max(start, end)
        return Set(rows[lower...upper].flatMap(\.representedObjectIDs))
    }
}

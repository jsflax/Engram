import SwiftUI

/// The project/relation controls used by both Engram graph hosts.
public struct EngramGraphFilterList: View {
    let projects: [String]
    let hiddenProjects: Set<String>
    let hiddenRelations: Set<String>
    let allRelationCounts: [(key: String, value: Int)]
    let colorMap: [String: Color]
    let toggleProject: (String) -> Void
    let toggleRelation: (String) -> Void
    let driveToProject: ((String) -> Void)?
    public init(projects: [String], hiddenProjects: Set<String>, hiddenRelations: Set<String>,
                relationCounts: [String: Int], colorMap: [String: Color],
                toggleProject: @escaping (String) -> Void, toggleRelation: @escaping (String) -> Void,
                driveToProject: ((String) -> Void)? = nil) {
        self.projects = projects; self.hiddenProjects = hiddenProjects; self.hiddenRelations = hiddenRelations
        self.allRelationCounts = relationCounts.sorted { $0.key < $1.key }; self.colorMap = colorMap
        self.toggleProject = toggleProject; self.toggleRelation = toggleRelation; self.driveToProject = driveToProject
    }
    public static let relationColors: [String: Color] = [
        "part_of": .cyan, "contradicts": .red, "supersedes": .orange,
        "derived_from": .yellow, "relates_to": .blue, "summarized_by": .purple
    ]
    public var body: some View {
        #if os(iOS)
        mobileRows
        #else
        desktopPanel
        #endif
    }

    #if os(iOS)
    private var mobileRows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("Projects").font(.caption).foregroundStyle(.secondary)
                ForEach(projects, id: \.self) { project in
                    HStack(spacing: 8) {
                        Button { toggleProject(project) } label: {
                            mobileRowLabel(project, color: colorMap[project] ?? .gray,
                                           hidden: hiddenProjects.contains(project))
                        }
                        .accessibilityLabel(project)
                        .accessibilityValue(hiddenProjects.contains(project) ? "Hidden" : "Visible")
                        if let driveToProject {
                            Button { driveToProject(project) } label: {
                                Image(systemName: "scope").engramGraphTouchTarget()
                            }
                            .accessibilityLabel("Fly to \(project)")
                        }
                    }
                }
                if !allRelationCounts.isEmpty {
                    Divider()
                    Text("Connections").font(.caption).foregroundStyle(.secondary)
                    ForEach(allRelationCounts, id: \.key) { relation, count in
                        let label = "\(relation.replacingOccurrences(of: "_", with: " ")) (\(count))"
                        Button { toggleRelation(relation) } label: {
                            mobileRowLabel(label, color: Self.relationColors[relation] ?? .white,
                                           hidden: hiddenRelations.contains(relation))
                        }
                        .accessibilityLabel(label)
                        .accessibilityValue(hiddenRelations.contains(relation) ? "Hidden" : "Visible")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.callout)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func mobileRowLabel(_ text: String, color: Color, hidden: Bool) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 8, height: 8)
                .opacity(hidden ? 0.3 : 1)
            Text(text).strikethrough(hidden).multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: hidden ? "eye.slash" : "checkmark")
                .foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .engramGraphTouchTarget(alignment: .leading)
    }
    #endif

    private var desktopPanel: some View {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .trailing, spacing: 6) {
                    // Project filters
                    ForEach(projects, id: \.self) { project in
                        HStack(spacing: 4) {
                            if let driveToProject {
                                Button {
                                    driveToProject(project)
                                } label: {
                                    Image(systemName: "scope")
                                        .font(.system(size: 10))
                                        .engramGraphTouchTarget()
                                }
                                .buttonStyle(.plain)
                                .opacity(hiddenProjects.contains(project) ? 0.3 : 0.6)
                                .help("Fly to \(project)")
                                .accessibilityLabel("Fly to \(project)")
                            }
                            Button {
                                toggleProject(project)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(colorMap[project] ?? .gray)
                                        .frame(width: 8, height: 8)
                                        .opacity(hiddenProjects.contains(project) ? 0.3 : 1.0)
                                    Text(project)
                                        .font(.system(size: 11, design: .monospaced))
                                        .strikethrough(hiddenProjects.contains(project))
                                }
                                .engramGraphTouchTarget(alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Edge type filters (use unfiltered counts so hidden types remain visible)
                    if !allRelationCounts.isEmpty {
                        Divider().frame(width: 100).overlay(Color.white.opacity(0.2))

                        ForEach(allRelationCounts, id: \.key) { relation, count in
                            Button {
                                toggleRelation(relation)
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(EngramGraphFilterList.relationColors[relation] ?? .white)
                                        .frame(width: 8, height: 8)
                                        .opacity(hiddenRelations.contains(relation) ? 0.3 : 1.0)
                                    Text("\(relation.replacingOccurrences(of: "_", with: " ")) (\(count))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .strikethrough(hiddenRelations.contains(relation))
                                }
                                .engramGraphTouchTarget(alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
    }
}

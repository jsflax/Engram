import SwiftUI

// MARK: - Groups + Invites sections (Account tab, between Account and Projects)

extension SidebarView {
    @ViewBuilder
    var groupsSection: some View {
        section("Groups") {
            VStack(alignment: .leading, spacing: 4) {
                if let error = groupService.lastRefreshError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow.opacity(0.7))
                        Text(groupService.groups.isEmpty ? error : "Showing cached groups — \(error)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(2)
                        Spacer()
                        Button("Retry") {
                            Task { await groupService.refresh() }
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .buttonStyle(.plain)
                        .foregroundStyle(.cyan.opacity(0.8))
                    }
                    .padding(.vertical, 4)
                }

                // Billing banners come from the DAEMON's per-spoke state, not
                // from a client-side guess: it is the daemon that knows a
                // group's sync is actually paused. Distinct from the red
                // error style — a lapse is a prompt, not a failure.
                ForEach((syncManager.daemonHealth?.groups ?? []).filter(\.needsBilling)) { spoke in
                    billingBanner(spoke)
                }

                let ordered = groupService.orderedGroups()
                if ordered.isEmpty && groupService.lastRefreshError == nil {
                    Text(groupService.hasLoadedOnce ? "No groups yet" : "Loading…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                ForEach(ordered, id: \.group.id) { entry in
                    groupRow(entry.group, depth: entry.depth)
                }

                Button {
                    groupService.createGroupParentId = nil
                    groupService.showCreateGroup = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("New Group")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(.cyan.opacity(0.8))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let error = groupService.errorMessage {
                    Text(error)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.8))
                        .lineLimit(2)
                }
            }
        }
        .task {
            await groupService.refresh()
        }
    }

    /// Billing state for one group's spoke. Amber, not red: sync is paused
    /// pending payment, and an owner gets a direct route to fix it.
    func billingBanner(_ spoke: SyncManager.GroupSpokeHealth) -> some View {
        let group = groupService.groups.first { $0.id.uuidString == spoke.id }
        let isOwner = group?.myRole == "owner"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange.opacity(0.8))
                Text(spoke.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer()
            }
            Text(spoke.detail ?? (spoke.state == "past_due"
                 ? "Subscription past due — sync continues during the grace period"
                 : "Team sync paused — the organization's subscription is inactive"))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            if isOwner, let group {
                Button {
                    Task {
                        // Owners get the checkout/portal link directly; the
                        // server decides which is appropriate.
                        let live = spoke.state == "past_due"
                        if let url = live
                            ? await groupService.portalURLString(groupId: group.id)
                            : await groupService.checkoutURLString(groupId: group.id),
                           let target = URL(string: url) {
                            NSWorkspace.shared.open(target)
                        }
                    }
                } label: {
                    Text(spoke.state == "past_due" ? "Manage billing" : "Reactivate…")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(.orange.opacity(0.85)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(.orange.opacity(0.08))
        )
    }

    func groupRow(_ group: GroupService.GroupSummary, depth: Int) -> some View {
        Button {
            groupService.selectedGroupId = group.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.root ? "person.3" : "person.2")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16)

                Text(group.name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                if let role = group.myRole, role != "member" {
                    Text(role)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.cyan.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(.cyan.opacity(0.12))
                        )
                }

                Spacer()

                Text("\(group.memberCount)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.25))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(depth) * 14)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var invitesSection: some View {
        if !groupService.incomingInvites.isEmpty {
            section("Invitations") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groupService.incomingInvites) { invite in
                        incomingInviteRow(invite)
                    }
                }
            }
        }
    }

    func incomingInviteRow(_ invite: GroupService.IncomingInvite) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.groupName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Text("invited by \(invite.inviterName) · \(invite.role)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await groupService.acceptInvite(invite) }
                } label: {
                    Text("Accept")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.cyan.opacity(0.85)))
                }
                .buttonStyle(.plain)

                Button {
                    Task { await groupService.declineInvite(invite) }
                } label: {
                    Text("Decline")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(.cyan.opacity(0.05))
        )
    }

    // MARK: - Per-project group exposure (decision 5: writes-only gate)

    /// Inline expansion under a project row: the user's groups with
    /// checkmarks. Toggling exposes/un-exposes the project to that group
    /// (SyncConfig.exposedGroups — the daemon's per-group hub filters react)
    /// and, on expose, registers the local name in the group's project
    /// registry (create-or-match, decision 13's default mapping).
    @ViewBuilder
    func exposureExpansion(for project: String, exposed: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Share with groups — un-sharing stops future sharing; already-shared memories remain (retract one via is_private)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 2)
            ForEach(groupService.groups.sorted(by: { $0.name < $1.name })) { group in
                let isOn = exposed.contains(group.id.uuidString)
                Button {
                    syncManager.setGroupExposure(project: project, groupId: group.id, exposed: !isOn)
                    if !isOn {
                        Task { await groupService.createGroupProject(groupId: group.id, name: project) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11))
                            .foregroundStyle(isOn ? .cyan.opacity(0.8) : .white.opacity(0.3))
                        Text(group.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.white.opacity(isOn ? 0.8 : 0.5))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 24)
        .padding(.vertical, 4)
    }

}

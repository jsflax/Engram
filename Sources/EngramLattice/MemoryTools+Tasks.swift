import Lattice
import MCP
import Foundation

// MARK: - Task Continuity

extension MemoryTools {

    // MARK: - checkpoint

    func handleCheckpoint(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(CheckpointArgs.self)

        // Validate status if provided
        if let status = a.status {
            guard validStatuses.contains(status) else {
                throw MCPError.invalidParams("Invalid status '\(status)'. Must be one of: active, paused, completed")
            }
        }

        // Update existing task
        if let taskId = a.taskId?.value {
            let id64 = Int64(taskId)
            let matches = localLattice.objects(Checkpoint.self).where { $0.primaryKey == id64 }
            guard let task = matches.first else {
                return CallTool.Result(content: [.text("Task with id \(taskId) not found.")], isError: true)
            }

            var changes: [String] = []
            if let title = a.title, !title.isEmpty {
                task.title = title
                changes.append("title")
            }
            let oldStatus = task.status
            if let status = a.status {
                task.status = status
                changes.append("status: \(oldStatus) → \(status)")
            }
            if let project = a.project {
                task.project = project
                changes.append("project")
            }
            if let plan = a.plan {
                task.plan = plan
                changes.append("plan")
            }
            if let progress = a.progress {
                task.progress = progress
                changes.append("progress")
            }
            if let context = a.context {
                task.context = context
                changes.append("context")
            }
            guard !changes.isEmpty else {
                throw MCPError.invalidParams("No fields to update. Provide at least one of: title, status, project, plan, progress, context")
            }

            task.checkpointedAt = Date()

            let reopened = oldStatus == "completed" && task.status != "completed"
            let reopenNote = reopened ? " (re-opened)" : ""
            log("Updated task [task:\(taskId)]: \(changes.joined(separator: ", "))")
            return CallTool.Result(
                content: [.text("Updated task (task:\(taskId), \(task.title))\(reopenNote). Changed: \(changes.joined(separator: ", "))")],
                isError: false
            )
        }

        // Create new task — title is required
        guard let title = a.title, !title.isEmpty else {
            throw MCPError.invalidParams("'title' is required when creating a new task (no task_id provided)")
        }

        let task = Checkpoint(
            title: title,
            status: a.status ?? "active",
            project: a.project ?? "global",
            plan: a.plan ?? "",
            progress: a.progress ?? "",
            context: a.context ?? ""
        )
        try localLattice.add(task)

        guard let taskId = task.primaryKey else {
            throw MCPError.internalError("Failed to persist task — primaryKey is nil after add()")
        }
        log("Created task [task:\(taskId)] \(title)")
        return CallTool.Result(
            content: [.text("Created task (task:\(taskId), status: \(task.status), project: \(task.project)): \(title)")],
            isError: false
        )
    }

    // MARK: - resume

    func handleResume(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(ResumeArgs.self)
        let id64 = Int64(a.taskId.value)
        let matches = localLattice.objects(Checkpoint.self).where { $0.primaryKey == id64 }
        guard let task = matches.first else {
            return CallTool.Result(content: [.text("Task with id \(a.taskId.value) not found.")], isError: true)
        }

        let oldStatus = task.status
        task.status = "active"
        task.checkpointedAt = Date()

        var output = "## Resuming: \(task.title)\n"
        output += "**Status**: \(oldStatus) → active | **Project**: \(task.project) | **Created**: \(Self.dateFormatter.string(from: task.createdAt))"

        if !task.plan.isEmpty {
            output += "\n\n### Plan\n\(task.plan)"
        }
        if !task.progress.isEmpty {
            output += "\n\n### Progress\n\(task.progress)"
        }
        if !task.context.isEmpty {
            output += "\n\n### Context\n\(task.context)"
        }

        log("Resumed task [task:\(a.taskId.value)] \(task.title)")
        return CallTool.Result(content: [.text(output)], isError: false)
    }

    // MARK: - list_tasks

    func handleListTasks(_ args: [String: Value]?) throws -> CallTool.Result {
        let a = try args.decode(ListTasksArgs.self)
        let limit = a.limit?.value ?? 20

        // Validate status if provided
        if let status = a.status {
            guard validStatuses.contains(status) else {
                throw MCPError.invalidParams("Invalid status '\(status)'. Must be one of: active, paused, completed")
            }
        }

        var results = localLattice.objects(Checkpoint.self)

        if let project = a.project {
            results = results.where { $0.project == project }
        }
        if let statusFilter = a.status {
            results = results.where { $0.status == statusFilter }
        } else {
            // Default: active + paused (not completed)
            results = results.where { $0.status != "completed" }
        }

        let sorted = results.sortedBy(.init(\.checkpointedAt, order: .reverse))
        let limited = sorted.snapshot(limit: Int64(limit))

        if limited.isEmpty {
            return CallTool.Result(content: [.text("No tasks found.")], isError: false)
        }

        let lines = limited.compactMap { task -> String? in
            guard let taskId = task.primaryKey else { return nil }
            let date = Self.dateFormatter.string(from: task.checkpointedAt)
            let progressPreview = task.progress.isEmpty ? "" : " — \(task.progress.prefix(80))"
            return "[task:\(taskId)] [\(task.status)] \(task.title) (\(task.project), checkpointed: \(date))\(progressPreview)"
        }

        return CallTool.Result(content: [.text(lines.joined(separator: "\n"))], isError: false)
    }
}

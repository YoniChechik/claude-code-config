import { groupBlocksByAgent, BlockGroup } from "../lib/agent-grouping";
import type { ContentBlock } from "../lib/types";

describe("groupBlocksByAgent", () => {
  describe("basic grouping", () => {
    it("should return standalone blocks for non-Task tools", () => {
      const blocks: ContentBlock[] = [
        { type: "tool_use", id: "bash_1", name: "Bash", input: { command: "ls" } },
        { type: "tool_result", tool_use_id: "bash_1", content: "file1 file2" },
      ];

      const groups = groupBlocksByAgent(blocks);

      expect(groups).toHaveLength(2);
      expect(groups[0].type).toBe("standalone");
      expect(groups[1].type).toBe("standalone");
    });

    it("should group Task tool_use with its children and tool_result", () => {
      const blocks: ContentBlock[] = [
        {
          type: "tool_use",
          id: "task_1",
          name: "Task",
          input: { subagent_type: "Debugger", description: "Fix the bug" },
        },
        { type: "tool_use", id: "bash_1", name: "Bash", input: { command: "git status" } },
        { type: "tool_result", tool_use_id: "bash_1", content: "On branch main" },
        { type: "tool_result", tool_use_id: "task_1", content: "Task completed" },
      ];

      const groups = groupBlocksByAgent(blocks);

      expect(groups).toHaveLength(1);
      expect(groups[0].type).toBe("agent_task");

      const agentTask = groups[0] as Extract<BlockGroup, { type: "agent_task" }>;
      expect(agentTask.agentType).toBe("Debugger");
      expect(agentTask.description).toBe("Fix the bug");
      // Child blocks should contain the Bash tool_use and tool_result
      expect(agentTask.blocks.length).toBeGreaterThanOrEqual(2);
    });
  });

  describe("causality preservation", () => {
    it("should maintain child tool order before Task completion", () => {
      // This test verifies the fix for the causality bug where
      // child tool outputs appeared after the agent completion
      const blocks: ContentBlock[] = [
        {
          type: "tool_use",
          id: "task_1",
          name: "Task",
          input: { subagent_type: "Analyzer", description: "Analyze code" },
        },
        { type: "tool_use", id: "read_1", name: "Read", input: { file_path: "/test.ts" } },
        { type: "tool_result", tool_use_id: "read_1", content: "const x = 1;" },
        { type: "tool_use", id: "bash_1", name: "Bash", input: { command: "git log" } },
        { type: "tool_result", tool_use_id: "bash_1", content: "commit abc123" },
        { type: "tool_result", tool_use_id: "task_1", content: "Analysis complete" },
      ];

      const groups = groupBlocksByAgent(blocks);

      expect(groups).toHaveLength(1);
      expect(groups[0].type).toBe("agent_task");

      const agentTask = groups[0] as Extract<BlockGroup, { type: "agent_task" }>;

      // The child blocks should contain Read and Bash tools in order
      // Flattening the child groups to check ordering
      const childBlocks = agentTask.blocks.flatMap((item) => {
        if ("type" in item && item.type === "standalone") {
          return [item.block];
        }
        return [];
      });

      // Should have 4 child blocks: read_use, read_result, bash_use, bash_result
      expect(childBlocks).toHaveLength(4);

      // Verify ordering: Read tool_use should come before Bash tool_use
      const readUseIdx = childBlocks.findIndex(
        (b) => b.type === "tool_use" && b.name === "Read"
      );
      const bashUseIdx = childBlocks.findIndex(
        (b) => b.type === "tool_use" && b.name === "Bash"
      );
      expect(readUseIdx).toBeLessThan(bashUseIdx);
    });

    it("should not move Task tool_result before child blocks", () => {
      // This specifically tests the bug fix where _sortToolBlocks
      // was incorrectly pairing Task tool_use with tool_result immediately
      const blocks: ContentBlock[] = [
        {
          type: "tool_use",
          id: "task_1",
          name: "Task",
          input: { subagent_type: "Writer", description: "Write docs" },
        },
        { type: "tool_use", id: "write_1", name: "Write", input: { file_path: "/README.md", content: "# Docs" } },
        { type: "tool_result", tool_use_id: "write_1", content: "File written" },
        { type: "tool_result", tool_use_id: "task_1", content: "Documentation written" },
      ];

      const groups = groupBlocksByAgent(blocks);

      // Should have exactly 1 agent_task group
      expect(groups).toHaveLength(1);
      expect(groups[0].type).toBe("agent_task");

      const agentTask = groups[0] as Extract<BlockGroup, { type: "agent_task" }>;

      // Child blocks should exist and include the Write tool
      expect(agentTask.blocks.length).toBeGreaterThan(0);

      // Find the Write tool in children
      const hasWriteTool = agentTask.blocks.some((item) => {
        if ("type" in item && item.type === "standalone") {
          const block = item.block;
          return block.type === "tool_use" && block.name === "Write";
        }
        return false;
      });
      expect(hasWriteTool).toBe(true);
    });
  });

  describe("nested agents", () => {
    it("should handle nested Task tools recursively", () => {
      const blocks: ContentBlock[] = [
        {
          type: "tool_use",
          id: "task_outer",
          name: "Task",
          input: { subagent_type: "Orchestrator", description: "Coordinate work" },
        },
        {
          type: "tool_use",
          id: "task_inner",
          name: "Task",
          input: { subagent_type: "Worker", description: "Do subtask" },
        },
        { type: "tool_use", id: "bash_1", name: "Bash", input: { command: "echo test" } },
        { type: "tool_result", tool_use_id: "bash_1", content: "test" },
        { type: "tool_result", tool_use_id: "task_inner", content: "Subtask done" },
        { type: "tool_result", tool_use_id: "task_outer", content: "All done" },
      ];

      const groups = groupBlocksByAgent(blocks);

      expect(groups).toHaveLength(1);
      expect(groups[0].type).toBe("agent_task");

      const outerTask = groups[0] as Extract<BlockGroup, { type: "agent_task" }>;
      expect(outerTask.agentType).toBe("Orchestrator");

      // Find nested agent task in children
      const nestedAgent = outerTask.blocks.find(
        (item) => "type" in item && item.type === "agent_task"
      ) as Extract<BlockGroup, { type: "agent_task" }> | undefined;

      expect(nestedAgent).toBeDefined();
      expect(nestedAgent!.agentType).toBe("Worker");

      // The bash tool should be a child of the inner task
      expect(nestedAgent!.blocks.length).toBeGreaterThan(0);
    });
  });

  describe("mixed content", () => {
    it("should handle text blocks mixed with tool blocks", () => {
      const blocks: ContentBlock[] = [
        { type: "text", text: "Starting analysis..." },
        {
          type: "tool_use",
          id: "task_1",
          name: "Task",
          input: { subagent_type: "Analyzer", description: "Analyze" },
        },
        { type: "tool_use", id: "bash_1", name: "Bash", input: { command: "ls" } },
        { type: "tool_result", tool_use_id: "bash_1", content: "files" },
        { type: "tool_result", tool_use_id: "task_1", content: "Done" },
        { type: "text", text: "Analysis complete!" },
      ];

      const groups = groupBlocksByAgent(blocks);

      expect(groups).toHaveLength(3);
      expect(groups[0].type).toBe("standalone");
      expect(groups[1].type).toBe("agent_task");
      expect(groups[2].type).toBe("standalone");

      // First text block
      const firstText = groups[0] as Extract<BlockGroup, { type: "standalone" }>;
      expect(firstText.block.type).toBe("text");

      // Agent task should contain Bash as child
      const agentTask = groups[1] as Extract<BlockGroup, { type: "agent_task" }>;
      expect(agentTask.blocks.length).toBeGreaterThan(0);

      // Last text block
      const lastText = groups[2] as Extract<BlockGroup, { type: "standalone" }>;
      expect(lastText.block.type).toBe("text");
    });
  });
});

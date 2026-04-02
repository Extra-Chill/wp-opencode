// dm-context-filter.ts — OpenCode plugin for WordPress agent VPSes with Data Machine.
//
// Strips Kimaki built-in features from the agent context when Data Machine
// manages memory, scheduling, and other concerns.
//
// What it removes from the system prompt:
// 1. Scheduling — ~500 tokens of --send-at, cron, task management instructions.
// 2. Tunnel / dev server — ~500 tokens about kimaki tunnel and tmux. Not needed
//    on production WordPress VPS where the site is already live.
// 3. Critique — ~900 tokens of diff-sharing instructions. We use GitHub PRs.
// 4. Worktree creation — ~150 tokens. We use feature branches in workspace repos.
// 5. Cross-project commands — ~200 tokens. Single-project fleet servers.
// 6. Waiting for sessions — ~150 tokens. Rarely used, discoverable via --help.
//
// What it removes from chat message injection:
// 7. MEMORY.md injection — Kimaki reads MEMORY.md from the project directory and
//    injects a condensed TOC. Conflicts with Data Machine's own memory files.
// 8. "Update MEMORY.md" time-gap reminder — Redundant with external memory system.
//
// Total savings: ~2,400+ tokens per session.
//
// How to use:
//   Add to opencode.json:  "plugin": ["/opt/kimaki-config/plugins/dm-context-filter.ts"]
//   Or place in .opencode/plugins/ in the project root.

import type { Plugin } from "@opencode-ai/plugin";

const fleetContextFilter: Plugin = async () => {
  return {
    // Strip sections from the system prompt.
    "experimental.chat.system.transform": async (_input, output) => {
      output.system = output.system.map((block) => {
        let result = block;
        result = stripSection(result, "## scheduled sends and task management");
        result = stripSection(result, "## running dev servers with tunnel access");
        result = stripSection(result, "## creating worktrees");
        result = stripSection(result, "## cross-project commands");
        result = stripSection(result, "## waiting for a session to finish");
        result = stripSection(result, "## showing diffs");
        result = stripSection(result, "## about critique");
        result = stripSection(result, "### always show diff at end of session");
        result = stripSection(result, "### fetching user comments from critique diffs");
        result = stripSection(result, "### reviewing diffs with AI");
        // Clean up leftover double/triple blank lines.
        result = result.replace(/\n{3,}/g, "\n\n");
        return result;
      });
    },

    // Filter out Kimaki's MEMORY.md injection and time-gap MEMORY.md reminders.
    "chat.message": async (_input, output) => {
      // Walk backwards so splice indices stay valid.
      for (let i = output.parts.length - 1; i >= 0; i--) {
        const part = output.parts[i];
        if (part.type !== "text" || !(part as any).synthetic) {
          continue;
        }
        const text = (part as any).text as string;
        if (!text) continue;

        // Remove MEMORY.md TOC injection.
        if (text.includes("Project memory from MEMORY.md")) {
          output.parts.splice(i, 1);
          continue;
        }

        // Remove "update MEMORY.md" time-gap reminder.
        if (text.includes("update MEMORY.md before starting the new task")) {
          output.parts.splice(i, 1);
          continue;
        }
      }
    },
  };
};

/**
 * Remove a markdown section from a system prompt block. Matches from the
 * heading to just before the next heading at the same or higher level, or
 * to the end of the block.
 *
 * Supports both ## and ### headings. For ##, stops at the next ## or #.
 * For ###, stops at the next ###, ##, or #.
 */
function stripSection(block: string, heading: string): string {
  const escaped = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const level = (heading.match(/^#+/) || ["##"])[0].length;

  // Build a pattern that stops at the next heading of the same or higher level.
  // For ## (level 2): stop at \n## or \n#[space] (i.e., any heading ≤ level 2)
  // For ### (level 3): stop at \n### or \n## or \n#[space]
  const stopPattern = `\\n#{1,${level}} `;
  const pattern = new RegExp(
    `${escaped}[\\s\\S]*?(?=${stopPattern}|$)`
  );
  return block.replace(pattern, "");
}

export default fleetContextFilter;

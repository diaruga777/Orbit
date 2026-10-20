# Agent integrations

Orbit's MCP runs on the Mac doing the builds. A cloud agent needs a supported connection back to that Mac; a cloud runner cannot deploy to a private phone just by installing the plugin. Orbit does not run a hosted MCP service or expose its local control socket publicly.

## Codex

The most dependable local configuration is an absolute-path stdio server:

```sh
codex mcp add orbit -- /absolute/path/Orbit/bin/orbit mcp
```

The repository also includes `plugins/orbit`, a portable Agent Plugin with `plugin.json`, `mcp.json`, and setup/deploy skills, plus a `.codex-plugin/plugin.json` compatibility manifest. The portable package uses `${PLUGIN_ROOT}`; the compatibility MCP uses the supported `${CLAUDE_PLUGIN_ROOT}` alias. The plugin launcher reads the checkout location recorded by bootstrap, so a plugin-cache update cannot erase schedules or app configuration.

For a Codex desktop version supporting local plugin sources, add `plugins/orbit` through its local plugin/marketplace import flow and run **orbit-setup**. If that surface does not offer local imports, use the MCP command above and install the skills as normal local skills under `~/.codex/skills`. No OpenAI API key is required for Orbit's MCP. [Official packaging and local testing guidance](https://developers.openai.com/plugins/build/plugins)

Public plugin-directory distribution is a separate publisher submission/review step. The GitHub package is prepared for that workflow; it is **not** represented as already accepted or listed. A local stdio server belongs in a Mac-based agent environment; a remote-only ChatGPT connector cannot directly spawn it on the user's computer.

## Cursor

Cursor supports portable Agent Plugins and its own `.cursor-plugin/plugin.json` package. Orbit includes the latter with `cursor.mcp.json`, using `${CURSOR_PLUGIN_ROOT}` as required by Cursor.

For local testing, copy the **contents** of `plugins/orbit` to a directory under `~/.cursor/plugins/local/orbit`, then reload Cursor and inspect Customize. Do not symlink to an external checkout: current Cursor docs say those symlinks are skipped. Run Orbit bootstrap in the durable source checkout first. If your organization disables local imports, configure the MCP through the supported settings flow instead. [Cursor plugins](https://cursor.com/docs/plugins), [manifest reference](https://cursor.com/docs/reference/plugins)

For public distribution, submit the GitHub repository/plugin package to [Cursor Marketplace publishing](https://cursor.com/marketplace/publish). It requires review. The root `.cursor-plugin/marketplace.json` describes this repository's plugin for supported repository/team import flows. No marketplace submission is performed by bootstrap.

## Claude Code

The package includes a `.claude-plugin` manifest and root marketplace entry. For local development:

```sh
claude --plugin-dir /absolute/path/Orbit/plugins/orbit
```

Or register only the MCP with the host's stdio MCP command. The shared setup/deploy skills use portable SKILL.md files; no model-provider API is called by Orbit. Review the host's current [plugin documentation](https://code.claude.com/docs/en/plugins) for marketplace installation and policy restrictions.

## VS Code / GitHub Copilot and other MCP hosts

Use the MCP settings UI to add a **local stdio** server running `/absolute/path/Orbit/bin/orbit mcp`. Some hosts use a top-level `servers` key instead of `mcpServers`; follow that host's schema. Python 3.9+ is sufficient. Absolute paths avoid GUI PATH differences. Do not expose `~/.orbit/control.sock` through a generic unauthenticated tunnel.

## Suggested iOS development skills

Orbit handles registration, signing coordination, build/install jobs and refreshes. Pair it with development tools that help the agent design, write and debug an app:

- [OpenAI Build iOS Apps plugin](https://github.com/openai/plugins/tree/main/plugins/build-ios-apps): SwiftUI patterns, refactors, App Intents, performance and Simulator debugging.
- [MobileBuildMCP (formerly XcodeBuildMCP)](https://github.com/getsentry/MobileBuildMCP): project/scheme discovery, compilation and Simulator workflows. Orbit's no-WebDriverAgent-on-physical-phones rule still applies when combining tools.
- [SwiftUI Agent Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill): SwiftUI implementation and review guidance. Check its instructions and supported Swift versions before installing.

These are optional recommendations, not dependencies or copied skill bundles. Use the equivalent UIKit, Swift concurrency, accessibility and testing skills already installed in your harness. A human can perform every Orbit setup and deployment step without an agent.

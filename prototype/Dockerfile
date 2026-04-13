# CF Agent Prototype — opencode serve as a CF app container
#
# Key findings from source research:
#   - opencode defaults to 127.0.0.1 — CF requires 0.0.0.0
#   - opencode ignores $PORT — must be passed as --port $PORT
#   - No SIGTERM handler in opencode — wrapper script handles it
#   - Sessions persist to ~/.local/share/opencode/opencode.db
#     (ephemeral in CF; override with XDG_DATA_HOME for persistence)
#   - Agent uses CF V3 API directly (HTTP + Bearer token) — no CF CLI needed

FROM oven/bun:1-debian

# Install dependencies
RUN apt-get update && apt-get install -y curl ca-certificates jq && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install opencode
RUN npm install -g opencode-ai

# Set working directory (project root for opencode)
WORKDIR /app

# Wrapper script that:
# 1. Passes $PORT to opencode (CF injects this)
# 2. Handles SIGTERM gracefully (opencode has no SIGTERM handler)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]

# CF Agent System — Architecture

**Status**: Pre-implementation design  
**Date**: 2026-04-13  
**Authors**: Ramon / OpenCode

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [CF Platform Background](#2-cf-platform-background)
3. [Agent Resource Model](#3-agent-resource-model)
4. [opencode Runtime](#4-opencode-runtime)
5. [Component Architecture](#5-component-architecture)
6. [CF CLI Commands](#6-cf-cli-commands)
7. [CAPI Changes](#7-capi-changes)
8. [Agent Container Spec](#8-agent-container-spec)
9. [Sub-Agent Spawning Protocol](#9-sub-agent-spawning-protocol)
10. [Space Scoping & Permissions](#10-space-scoping--permissions)
11. [Authentication & Security](#11-authentication--security)
12. [Networking & Routing](#12-networking--routing)
13. [Lifecycle](#13-lifecycle)
14. [Diego Integration](#14-diego-integration)
15. [BOSH Packaging](#15-bosh-packaging)
16. [Implementation Phases](#16-implementation-phases)

---

## 1. Executive Summary

Cloud Foundry today manages two primary first-class resources:

- **Apps** — stateless workloads scheduled by Diego onto Garden containers
- **Services** — backing resources provisioned via the Open Service Broker API

This document proposes a **third first-class resource**: the **Agent**. An agent is a
long-running, autonomous AI process that:

1. Is created with `cf create-agent opencode` (and eventually other agent types)
2. Runs `opencode serve` inside a CF Diego container
3. Is scoped to a CF space (same isolation model as apps)
4. Holds a UAA client credential delegated by the platform
5. Can spawn **sub-agents** — new opencode sessions — via the opencode Session API
6. Can push, update, and manage CF apps within its assigned space(s)
7. Exposes the full **opencode HTTP/SSE API** on a registered CF route

The key insight: **opencode is already a server**. `opencode serve` exposes a full
OpenAPI 3.1 HTTP server with sessions, messages, sub-agent spawning, file access, tools,
and SSE event streaming. The CF Agent system's job is to:

- Package that server as a first-class CF resource
- Provision it with delegated CF API credentials
- Register its route through GoRouter
- Manage its lifecycle (create/start/stop/delete)
- Wire its parent→child session model to CF's space/org model

---

## 2. CF Platform Background

### 2.1 Core Components

```
                           ┌─────────────┐
  cf CLI / API clients ───▶│   GoRouter   │──▶ routes to backend instances
                           └──────┬──────┘
                                  │ HTTPS
                           ┌──────▼──────┐
                           │  Cloud      │  (CAPI — cloudfoundry/cloud_controller_ng)
                           │  Controller │  REST API: /v3/apps, /v3/service_instances,
                           │  (CC/CAPI)  │  /v3/spaces, /v3/organizations
                           └──┬──────┬───┘
                              │      │
               ┌──────────────┘      └──────────────────────┐
               │ MySQL (CC DB)              ┌────────────────▼────────┐
               │ Blobstore (droplets)       │ Diego BBS               │
               │                            │ (DesiredLRP/ActualLRP)  │
               │                            └───────────┬─────────────┘
               │                                        │ HTTP+protobuf
               │                            ┌───────────▼─────────────┐
               │                            │  Diego Auctioneer        │
               │                            └───────────┬─────────────┘
               │                                        │
               │            ┌───────────────────────────▼──────────────────┐
               │            │              Diego Cell (VM)                   │
               │            │  ┌──────────────────────────────────────────┐ │
               │            │  │  Garden Container (app or agent instance) │ │
               │            │  │  - Process (buildpack / docker)           │ │
               │            │  │  - Envoy sidecar (c2c networking)         │ │
               │            │  └──────────────────────────────────────────┘ │
               │            │  Rep (cell agent — reports to BBS)            │
               │            └───────────────────────────────────────────────┘
               │
        ┌──────▼──────┐
        │    UAA      │  OAuth2/OIDC — issues tokens for users, apps, services
        └─────────────┘
```

### 2.2 What Agents Are Not

It might be tempting to model agents as service instances via the Open Service Broker API.
This is insufficient:

| Dimension | Service (OSB) | Agent (proposed) |
|-----------|--------------|-----------------|
| Runs inside CF? | No (External) | Yes (Diego container) |
| Has CF API access? | No | Yes (UAA delegated client) |
| Logs in Loggregator? | No | Yes |
| Can push CF apps? | No | Yes |
| Can spawn children? | No | Yes (opencode sessions + CF sub-agents) |
| Has structured task API? | No | Yes (opencode `/session/:id/message`) |
| Health managed by CF? | No | Yes (Diego restarts on failure) |
| SSE event stream? | No | Yes (opencode `/event`) |

Agents are CF workloads with a rich API. OSB models external adapters. These are
fundamentally different resource types.

---

## 3. Agent Resource Model

### 3.1 New CC Database Tables

```sql
-- Core agent entity
CREATE TABLE agents (
  guid              UUID PRIMARY KEY,
  name              VARCHAR(255) NOT NULL,
  state             ENUM('CREATING','STARTING','RUNNING','STOPPING','STOPPED','ERROR'),
  agent_type        VARCHAR(255) NOT NULL DEFAULT 'opencode',
  space_guid        UUID NOT NULL REFERENCES spaces(guid),
  uaa_client_id     VARCHAR(255) NOT NULL,
  process_guid      VARCHAR(255),            -- Diego LRP process guid
  route_guid        UUID REFERENCES routes(guid),
  parent_guid       UUID REFERENCES agents(guid),  -- NULL for root agents
  opencode_session_id VARCHAR(255),          -- active root session ID
  working_dir       VARCHAR(1024),
  created_at        TIMESTAMP NOT NULL,
  updated_at        TIMESTAMP NOT NULL,
  metadata          JSONB
);

-- Which spaces can this agent operate in?
CREATE TABLE agent_space_grants (
  agent_guid  UUID REFERENCES agents(guid),
  space_guid  UUID REFERENCES spaces(guid),
  role        ENUM('readonly', 'deployer', 'full'),
  PRIMARY KEY (agent_guid, space_guid)
);
```

Secrets (`CF_CLIENT_SECRET`, `OPENCODE_SERVER_PASSWORD`) are stored in CredHub at:
- `/cf/agents/<agent-guid>/client_secret`
- `/cf/agents/<agent-guid>/server_password`

### 3.2 CF V3 API Endpoints

```
POST   /v3/agents                              Create an agent (async -> 202 + job)
GET    /v3/agents                              List agents (filter: space, state, type)
GET    /v3/agents/:guid                        Get agent details
PATCH  /v3/agents/:guid                        Update agent config/metadata
DELETE /v3/agents/:guid                        Delete (async -> 202 + job)

POST   /v3/agents/:guid/actions/start          Start a stopped agent
POST   /v3/agents/:guid/actions/stop           Stop a running agent
POST   /v3/agents/:guid/actions/restart        Restart agent process

GET    /v3/agents/:guid/sub_agents             List child agents (Level 2)
GET    /v3/agents/:guid/sessions               Proxy -> opencode GET /session
POST   /v3/agents/:guid/sessions               Proxy -> opencode POST /session
POST   /v3/agents/:guid/message                Proxy -> opencode POST /session/:id/prompt_async
GET    /v3/agents/:guid/events                 Proxy -> opencode SSE /event

POST   /v3/agents/:guid/space_grants           Grant access to additional space
DELETE /v3/agents/:guid/space_grants/:space    Revoke space access

GET    /v3/agent_types                         Catalog of available agent types
```

### 3.3 Agent Create Request

```json
POST /v3/agents

{
  "name": "my-opencode",
  "type": "opencode",
  "relationships": {
    "space": { "data": { "guid": "<space-guid>" } }
  },
  "environment_variables": {
    "ANTHROPIC_API_KEY": "sk-ant-...",
    "OPENCODE_MODEL": "claude-sonnet-4-5"
  },
  "metadata": {
    "labels": { "team": "platform" },
    "annotations": { "purpose": "dev-assistant" }
  }
}
```

### 3.4 Agent Response Body

```json
{
  "guid": "a1b2c3d4-...",
  "name": "my-opencode",
  "state": "RUNNING",
  "type": "opencode",
  "created_at": "2026-04-13T10:00:00Z",
  "updated_at": "2026-04-13T10:00:05Z",
  "relationships": {
    "space":        { "data": { "guid": "<space-guid>" } },
    "parent_agent": { "data": null }
  },
  "links": {
    "self":     { "href": "https://api.example.com/v3/agents/a1b2c3d4-..." },
    "space":    { "href": "https://api.example.com/v3/spaces/<space-guid>" },
    "process":  { "href": "https://api.example.com/v3/processes/<process-guid>" },
    "route":    { "href": "https://my-opencode-a1b2c3.apps.example.com" },
    "opencode": { "href": "https://my-opencode-a1b2c3.apps.example.com/doc" }
  },
  "metadata": { "labels": {}, "annotations": {} }
}
```

---

## 4. opencode Runtime

All findings in this section are source-verified from the `sst/opencode` repository
(`packages/opencode/src/`).

### 4.1 Start Command

```bash
# CF start command (mandatory flags):
opencode serve --port $PORT --hostname 0.0.0.0
```

| Flag | CF Usage | Notes |
|------|----------|-------|
| `--port` | `$PORT` (CF-injected) | Default is `0` (OS-random); CF must override |
| `--hostname` | `0.0.0.0` | Default is `127.0.0.1`; CF requires all-interfaces bind |
| `--cors` | optional | Add agent management UI origin if needed |
| `--mdns` | disabled | CF routing handles discovery; not needed |

**`$PORT` is NOT read automatically** — it must be passed explicitly as `--port $PORT`.

### 4.2 Health Check

`GET /global/health` returns `{ "healthy": true, "version": "..." }` (HTTP 200).
Available immediately on process start (no warm-up delay).

```yaml
# CF manifest health check config:
health-check-type: http
health-check-http-endpoint: /global/health
```

### 4.3 SIGTERM Handling

**The opencode process has no SIGTERM handler.** The `server.stop()` call in `serve.ts`
is unreachable dead code — the process blocks forever on `await new Promise(() => {})`.
When Diego sends SIGTERM (on scale-down, redeploy, or delete), the Bun runtime exits
immediately, killing in-flight AI sessions.

**Required workaround** — use a wrapper `entrypoint.sh` in the Docker image:

```sh
#!/bin/sh
# entrypoint.sh — SIGTERM-aware wrapper for opencode serve
trap 'kill -TERM $PID; wait $PID' TERM INT
opencode serve --hostname 0.0.0.0 --port "$PORT" &
PID=$!
wait $PID
```

This gives the process up to Diego's `graceful_shutdown_interval` (default 10s) to finish.

### 4.4 Session Persistence

Sessions are stored in SQLite at:
```
$XDG_DATA_HOME/opencode/opencode.db
# default on Linux: ~/.local/share/opencode/opencode.db
```

In a CF container this path is the ephemeral layer — **session history is lost on restart**.

Override options:
- `XDG_DATA_HOME=/mnt/data` — redirect entire data dir (requires CF volume service mount)
- `OPENCODE_DB=/mnt/data/opencode.db` — direct DB path override

**Phase 1**: Accept session loss on restart (stateless container model). Known limitation.
**Phase 2**: Persist sessions via CF volume services mounted at `XDG_DATA_HOME`.

### 4.5 Docker Image

No runtime Docker image exists for opencode. The repo publishes only CI build-helper
images. A custom image must be built for CF deployment:

```dockerfile
FROM oven/bun:1

# Install opencode
RUN npm install -g opencode-ai

WORKDIR /app

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

See `prototype/` directory for the full working image with `entrypoint.sh`.

### 4.6 opencode HTTP API Reference

Full OpenAPI 3.1 spec at `GET /doc` on the running server.

#### Global

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/global/health` | `{ healthy: true, version: "..." }` |
| `GET` | `/global/event` | Global SSE event stream |

#### Sessions

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/session` | Create session. `parentID` creates a child session |
| `GET` | `/session` | List sessions. `?roots=true` filters to root sessions only |
| `GET` | `/session/status` | Status map: `{ [sessionID]: SessionStatus }` |
| `GET` | `/session/:id` | Get session details |
| `DELETE` | `/session/:id` | Delete session + all its data |
| `PATCH` | `/session/:id` | Update session (title, archived, etc.) |
| `GET` | `/session/:id/children` | List child sessions (sub-agent tree) |
| `POST` | `/session/:id/fork` | Fork session from a message point |
| `POST` | `/session/:id/abort` | Cancel a running prompt |

#### Messages

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/session/:id/message` | Send prompt, streaming JSON response (sync) |
| `POST` | `/session/:id/prompt_async` | Send prompt, return 204 immediately (async) |
| `GET` | `/session/:id/message` | List messages in session |
| `POST` | `/session/:id/command` | Execute slash command |
| `POST` | `/session/:id/shell` | Run shell command in container |
| `POST` | `/session/:id/revert` | Undo message effects |

**Preferred for CF agent manager**: `prompt_async` (non-blocking, pairs with SSE monitoring).

#### Events (SSE)

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/event` | SSE bus events. First event: `server.connected`. Heartbeat every 10s |

#### Other

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/config` | Get config |
| `PATCH` | `/config` | Update config |
| `GET` | `/config/providers` | List AI providers + default models |
| `GET` | `/agent` | List available agent types/personas |
| `GET` | `/file` | Get file contents |
| `GET` | `/find/file` | Fuzzy file search |
| `GET` | `/experimental/tool/ids` | List tool IDs |
| `PUT` | `/auth/:id` | Set provider auth credentials |
| `GET` | `/doc` | OpenAPI 3.1 spec |

### 4.7 Session Status States

`GET /session/status` returns `Record<sessionID, SessionStatus>`:

```typescript
SessionStatus =
  | { type: "idle" }
  | { type: "busy" }
  | { type: "retry", attempt: number, message: string, next: number }
```

- Sessions absent from the map are implicitly `idle`
- `busy` — LLM call in flight
- `retry` — rate-limited or errored; will auto-retry
- `idle` — done; entry removed from status map

**CF agent manager polling**: Poll `GET /session/status` every 5s. When root session
returns to `idle`, the task is complete.

### 4.8 SSE Event Stream

**Endpoint**: `GET /event`

**Connection handshake**:
```
data: {"type":"server.connected","properties":{}}
data: {"type":"server.heartbeat","properties":{}}   <- every 10 seconds
```

**Events relevant to CF agent monitoring**:

| Event Type | Properties | Meaning |
|------------|-----------|---------|
| `session.created` | `{ sessionID, info }` | New session started (may be Level-1 sub-agent) |
| `session.updated` | `{ sessionID, info }` | Title, status changed |
| `session.deleted` | `{ sessionID, info }` | Session removed |
| `session.status` | `{ sessionID, status }` | Status transition (idle/busy/retry) |
| `session.error` | `{ sessionID?, error }` | Fatal error in prompt |
| `message.part.updated` | `{ sessionID, part }` | LLM streaming delta |
| `server.connected` | `{}` | SSE handshake |
| `server.heartbeat` | `{}` | Keep-alive (every 10s) |
| `server.disposed` | `{}` | Server shutting down — client should reconnect |

**Connection notes**:
- Heartbeat at 10s is safe — CF GoRouter has 90s idle timeout
- `X-Accel-Buffering: no` header is set to prevent nginx buffering
- On `server.disposed`: reconnect with exponential backoff

### 4.9 Server Authentication

opencode supports HTTP Basic Auth via environment variables:

```bash
OPENCODE_SERVER_PASSWORD=<password>     # enables auth (required to lock down the server)
OPENCODE_SERVER_USERNAME=opencode       # default username
```

The CF platform generates `OPENCODE_SERVER_PASSWORD` at agent creation, stores it in
CredHub, and injects it into the container. The end user never sees it — CF CLI proxy
endpoints retrieve it transparently.

---

## 5. Component Architecture

### 5.1 Overview

```
                               +-----------------------------------------+
                               |  cf CLI                                  |
                               |  cf create-agent opencode                |
                               |  cf agent-command my-agent "..."         |
                               +------------------+----------------------+
                                                  | HTTPS
                               +------------------v---------------------+
                               |     GoRouter                            |
                               +--+------------------------------------+-+
                                  | /v3/agents (API)  | *.apps.example.com
                                  v                   v
                    +------------------------+  +----------------------------------+
                    |  CAPI                  |  |  Agent Container (Diego Cell)    |
                    |  /v3/agents API        |  |                                  |
                    |  AgentCreateJob:       |  |  opencode serve                  |
                    |  - Create UAA client   |  |  --port $PORT                    |
                    |  - Submit LRP          |  |  --hostname 0.0.0.0              |
                    |  - Register route      |  |                                  |
                    +--+----------+----------+  |  GET  /global/health <- Diego HC |
                       |          |             |  POST /session       <- tasks    |
                       v          v             |  GET  /session/:id/children      |
                    +------+  +----------+      |  GET  /event         <- SSE      |
                    | UAA  |  | Diego BBS|      |  POST /session/:id/shell         |
                    |client|  |DesiredLRP|      |                                  |
                    |create|  |  submit  |      |  Env: CF_API_URL                 |
                    +------+  +----------+      |       CF_CLIENT_ID               |
                                                |       CF_CLIENT_SECRET           |
                                                |       OPENCODE_SERVER_PASSWORD   |
                                                |       ANTHROPIC_API_KEY          |
                                                +----------------------------------+
```

### 5.2 What Is New (Minimal)

| Component | Change |
|-----------|--------|
| `cloud_controller_ng` | New `agents` + `agent_space_grants` tables, `/v3/agents` controller, `AgentCreateJob` |
| `cf-cli` | New commands: `create-agent`, `agents`, `agent-command`, `agent-logs`, `delete-agent` |
| `uaa` | No changes — CAPI already creates UAA clients dynamically (SSO service broker pattern) |
| `diego` | No changes — agent is a standard DesiredLRP |
| `gorouter` | No changes — agent route is a standard CF route |
| `loggregator` | No changes — agent stdout/stderr flows through normally |

---

## 6. CF CLI Commands

### 6.1 Command Reference

```bash
# --- Create ----------------------------------------------------------------
cf create-agent opencode [NAME] [OPTIONS]
  --space, -s          Space (default: current target)
  --env, -e KEY=VALUE  Set env variable (repeatable)
  --memory, -m MB      Memory limit (default: 512)
  --disk, -d MB        Disk limit (default: 1024)
  --no-start           Create without starting

cf create-agent opencode my-dev-agent \
  --env ANTHROPIC_API_KEY=sk-ant-... \
  --env OPENCODE_MODEL=claude-sonnet-4-5

# --- Inspect ---------------------------------------------------------------
cf agents                            # list all agents in current space
cf agents --space other-space
cf agent my-dev-agent                # details: state, route, sessions

# --- Lifecycle -------------------------------------------------------------
cf stop-agent my-dev-agent
cf start-agent my-dev-agent
cf restart-agent my-dev-agent
cf delete-agent my-dev-agent [-f]

# --- Interact --------------------------------------------------------------
cf agent-command my-dev-agent "build me a Go REST API for health checks"
cf agent-command my-dev-agent "build me a Go REST API" --async  # fire-and-forget

# Stream SSE events from the agent (proxies GET /event)
cf agent-logs my-dev-agent --stream

# Recent logs (Loggregator tail -- stdout/stderr)
cf agent-logs my-dev-agent --recent

# SSH into agent container for debugging
cf agent-ssh my-dev-agent

# Retrieve HTTP Basic Auth credentials
cf agent-credentials my-dev-agent

# --- Sessions --------------------------------------------------------------
cf agent-sessions my-dev-agent       # list opencode sessions
cf sub-agents my-dev-agent           # list child agents

# --- Permissions -----------------------------------------------------------
cf grant-agent-space my-dev-agent staging-space
cf revoke-agent-space my-dev-agent staging-space
```

### 6.2 Example Output

```
Creating agent my-dev-agent in org my-org / space dev as user@example.com...

Provisioning UAA client... OK
Submitting to Diego...      OK
Registering route...        OK

Agent my-dev-agent is starting. Use 'cf agent my-dev-agent' to see its state.

Route:    https://my-dev-agent-a1b2c3.apps.example.com
API spec: https://my-dev-agent-a1b2c3.apps.example.com/doc
```

```
Getting agents in org my-org / space dev as user@example.com...

name             state     type      route                                        since
my-dev-agent     running   opencode  my-dev-agent-a1b2c3.apps.example.com        10 minutes ago
test-agent       stopped   opencode  test-agent-d4e5f6.apps.example.com           2 days ago
```

### 6.3 CLI Implementation Pattern

All agent commands follow the established command chain used throughout the CF CLI
codebase (source-verified from `cloudfoundry/cli`, module `code.cloudfoundry.org/cli/v9`):

```
command/v7/create_agent_command.go       <- flag parsing, output, calls actor
  -> actor/v7action/agent.go            <- business logic, calls CC client
    -> api/cloudcontroller/ccv3/agent.go <- HTTP: POST /v3/agents -> (JobURL, Warnings, error)
      -> resources/agent_resource.go    <- resource struct with JSON tags
```

Command registration in `command/common/command_list_v7.go`:

```go
CreateAgent  v7.CreateAgentCommand  `command:"create-agent"  description:"Create an AI agent"`
Agents       v7.AgentsCommand       `command:"agents"        description:"List agents in the target space"`
Agent        v7.AgentCommand        `command:"agent"         description:"Show agent info"`
DeleteAgent  v7.DeleteAgentCommand  `command:"delete-agent"  description:"Delete an agent"`
AgentCommand v7.AgentCommandCommand `command:"agent-command" description:"Send a task to an agent"`
AgentLogs    v7.AgentLogsCommand    `command:"agent-logs"    description:"Show or stream agent logs"`
```

Async job polling uses the existing `actor.PollJobToEventStream(jobURL)` channel pattern.

---

## 7. CAPI Changes

### 7.1 New Files in cloud_controller_ng

Following the existing Rails V3 MVC pattern:

```
app/
  controllers/v3/
    agents_controller.rb             # CRUD + actions + proxy endpoints
    agent_space_grants_controller.rb
  models/runtime/
    agent.rb                         # ActiveRecord model
    agent_space_grant.rb
  messages/
    agent_create_message.rb          # validates POST body
    agent_update_message.rb
    agents_list_message.rb
  fetchers/
    agent_fetcher.rb                 # scoped DB queries (space-filtered)
  actions/v3/
    agent_create.rb                  # orchestrates: DB -> UAA client -> LRP -> route
    agent_delete.rb                  # stops LRP, revokes UAA client, removes route
    agent_start.rb
    agent_stop.rb
  presenters/v3/
    agent_presenter.rb               # serializes to JSON response
  jobs/v3/
    agent_create_job.rb              # background: UAA + Diego + route provisioning
    agent_delete_job.rb

db/migrations/
  TIMESTAMP_create_agents.rb
  TIMESTAMP_create_agent_space_grants.rb
```

### 7.2 Agent Create Job — Detailed Flow

```
POST /v3/agents
  | Validate AgentCreateMessage
  | Authorize: user must have SpaceDeveloper in target space
  | Create Agent record (state: CREATING)
  | Enqueue AgentCreateJob via Jobs::Enqueuer.new.enqueue_pollable(job)
  +-> 202 Accepted, Location: /v3/jobs/<job-guid>

AgentCreateJob#perform (Delayed::Job background worker):

  Step 1 -- Provision UAA client
    UaaClientManager#modify_transaction([{
      client_id:    "agent-<agent-guid>",
      client_secret: SecureRandom.hex(32),
      authorized_grant_types: ["client_credentials"],
      authorities:  ["cloud_controller.read", "cloud_controller.write",
                     "routing.routes.write", "agents.spawn"],
      scope:        []
    }])
    -> Store client_secret in CredHub: /cf/agents/<agent-guid>/client_secret

  Step 2 -- Generate opencode server password
    opencode_password = SecureRandom.hex(24)
    -> Store in CredHub: /cf/agents/<agent-guid>/server_password

  Step 3 -- Submit Diego DesiredLRP
    BbsAppsClient -> Diego::Client -> HTTP POST to BBS with protobuf body
    (see Section 14 for full LRP spec)

  Step 4 -- Register CF route
    POST /v3/routes  { host: "<agent-name>-<short-guid>", domain_guid: <apps-domain> }
    POST /v3/routes/<route-guid>/destinations { destinations: [{ process_guid: "agent-..." }] }

  Step 5 -- Update Agent record
    state: STARTING

  Step 6 -- Poll Diego health check
    When ActualLRP state = RUNNING and GET /global/health -> 200:
    state: RUNNING -> job completes
```

**Job framework**: Delayed::Job (not Sidekiq). Use `Jobs::Enqueuer.new(queue: Jobs::Queues.generic).enqueue_pollable(job_instance)`.

**UAA client management**: Reuse `UaaClientManager#modify_transaction` — same pattern used
by SSO service brokers today (source-verified from `lib/services/sso/uaa/uaa_client_manager.rb`).

### 7.3 CAPI Proxy Endpoints

Proxy endpoints add a CF authorization layer on top of the opencode API:

```ruby
# agents_controller.rb
def send_message
  agent = find_agent(params[:guid])
  authorize! :write, agent
  session_id = agent.opencode_session_id || create_default_session(agent)
  proxy_to_opencode(agent, :post, "/session/#{session_id}/prompt_async", request.body)
end

def events
  agent = find_agent(params[:guid])
  authorize! :read, agent
  proxy_sse_to_opencode(agent, '/event')
end

private

def proxy_to_opencode(agent, method, path, body = nil)
  uri = "#{agent.internal_url}#{path}"
  response = HTTPClient.new.send(method, uri,
    headers: { 'Authorization' => opencode_basic_auth(agent) },
    body: body
  )
  render json: response.body, status: response.status
end

def opencode_basic_auth(agent)
  secret = CredHub.get("/cf/agents/#{agent.guid}/server_password")
  ActionController::HttpAuthentication::Basic.encode_credentials('opencode', secret)
end
```

---

## 8. Agent Container Spec

### 8.1 Start Command

```bash
web: /entrypoint.sh
# entrypoint.sh runs: opencode serve --port $PORT --hostname 0.0.0.0
```

### 8.2 Environment Variables

```bash
# -- CF Standard ------------------------------------------------------------
PORT=8080
VCAP_APPLICATION='{"application_name":"my-dev-agent","space_name":"dev",...}'
MEMORY_LIMIT=512m
CF_INSTANCE_GUID=...
CF_INSTANCE_IP=...

# -- CF Agent Identity -------------------------------------------------------
AGENT_GUID=a1b2c3d4-...
AGENT_TYPE=opencode
AGENT_NAME=my-dev-agent
AGENT_SPACE_GUID=<space-guid>
PARENT_AGENT_GUID=                   # empty for root agents; set for sub-agents

# -- Delegated CF Credentials ------------------------------------------------
CF_API_URL=https://api.sys.example.com
CF_UAA_URL=https://uaa.sys.example.com
CF_CLIENT_ID=agent-a1b2c3d4-...
CF_CLIENT_SECRET=<generated-secret>

# -- opencode Server Auth ----------------------------------------------------
OPENCODE_SERVER_PASSWORD=<generated>
OPENCODE_SERVER_USERNAME=opencode

# -- AI Provider (user-supplied at create time) ------------------------------
ANTHROPIC_API_KEY=sk-ant-...
OPENCODE_MODEL=claude-sonnet-4-5
```

### 8.3 CF API Access from Inside the Container

The agent calls the CF V3 API directly using its delegated UAA client credentials.
**No CF CLI is installed in the container** — the CLI is an end-user tool. The agent
interacts with CF programmatically via HTTP.

```bash
# 1. Acquire UAA token (client_credentials grant)
TOKEN=$(curl -s -X POST "$CF_UAA_URL/oauth/token" \
  -u "$CF_CLIENT_ID:$CF_CLIENT_SECRET" \
  -d "grant_type=client_credentials" \
  | jq -r .access_token)

# 2. List apps in the agent's space
curl -H "Authorization: Bearer $TOKEN" \
  "$CF_API_URL/v3/apps?space_guids=$AGENT_SPACE_GUID"

# 3. Create an app
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
  "$CF_API_URL/v3/apps" \
  -d '{"name":"my-new-app","relationships":{"space":{"data":{"guid":"'$AGENT_SPACE_GUID'"}}}}'

# 4. Push source (create package, upload bits, create build, create deployment)
curl -X POST -H "Authorization: Bearer $TOKEN" \
  "$CF_API_URL/v3/packages" \
  -d '{"type":"bits","relationships":{"app":{"data":{"guid":"<app-guid>"}}}}'

# 5. Bind a service
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
  "$CF_API_URL/v3/service_credential_bindings" \
  -d '{"type":"app","relationships":{"app":{"data":{"guid":"<app-guid>"}},"service_instance":{"data":{"guid":"<si-guid>"}}}}'

# 6. Spawn a Level 2 sub-agent
curl -X POST -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
  "$CF_API_URL/v3/agents" \
  -d '{"name":"sub-agent","type":"opencode","relationships":{"space":{"data":{"guid":"'$AGENT_SPACE_GUID'"}},"parent_agent":{"data":{"guid":"'$AGENT_GUID'"}}}}'
```

The token must be refreshed before expiry (default UAA token TTL: 600s). The agent
is responsible for token lifecycle — obtain, cache, refresh.

### 8.4 Contract: What the Agent Process Must Do

opencode satisfies all of these out of the box:

```
[OK] Listen on $PORT (opencode: --port $PORT)
[OK] Bind to 0.0.0.0 (opencode: --hostname 0.0.0.0)
[OK] Respond GET /global/health -> 200 {"healthy": true} immediately on start
[OK] Write logs to stdout/stderr (Loggregator picks these up)
[!]  Handle SIGTERM gracefully -- requires entrypoint.sh wrapper (see Section 4.3)
```

---

## 9. Sub-Agent Spawning Protocol

### 9.1 Phase Availability

| Level | Mechanism | Available in |
|-------|-----------|-------------|
| **Level 1** | opencode `task` tool — child sessions inside one container | **Phase 1** — zero CF changes |
| **Level 2** | CF sub-agents — separate Diego containers per sub-agent | **Phase 2** — requires CAPI `parent_agent` support |

### 9.2 Level 1 — opencode Task Tool (Phase 1)

opencode has a built-in `task` tool (source: `packages/opencode/src/tool/task.ts`).
When the LLM calls this tool, opencode **automatically**:

1. Creates a child session (`sessions.create({ parentID: ctx.sessionID, ... })`)
2. Runs a new prompt in that child session using a named sub-agent type
3. Returns the result to the parent session

The sub-agent type (`subagent_type`) refers to a named agent defined in `opencode.json`.
Sub-agents with `mode: "subagent"` are only available to the task tool (not shown in the
UI agent picker). Sub-agents with `mode: "primary"` are excluded from task tool dispatch.

**opencode.json configuration** (baked into the container image or mounted via CF env):

```json
{
  "agents": {
    "go-specialist": {
      "mode": "subagent",
      "description": "Writes idiomatic Go code, tests, and interfaces",
      "prompt": "You are a Go specialist. Write idiomatic, well-tested Go code.",
      "model": "anthropic/claude-sonnet-4-5"
    },
    "test-writer": {
      "mode": "subagent",
      "description": "Writes unit and integration tests for existing code",
      "prompt": "You are a test specialist. Write thorough, focused tests.",
      "model": "anthropic/claude-sonnet-4-5"
    },
    "cf-operator": {
      "mode": "subagent",
      "description": "Manages CF apps via V3 REST API calls",
      "prompt": "You manage CF apps. Use shell tool to call the CF V3 API with the injected credentials.",
      "model": "anthropic/claude-sonnet-4-5"
    }
  }
}
```

**Task tool parameters** (what the LLM sends when calling the tool):

```json
{
  "description": "Write the HTTP handler",
  "prompt": "Write a Go HTTP handler for POST /health that returns 200 OK",
  "subagent_type": "go-specialist",
  "task_id": "<optional: resume a previous child session>"
}
```

**Session tree inside the container:**

```
opencode server (container A)
+-- session: abc123  (root — "build a REST API for CF health checks")
    +-- session: def456  (@go-specialist — "write the HTTP handler")
    +-- session: ghi789  (@test-writer   — "write the tests")
    +-- session: jkl012  (@cf-operator   — "push the app to CF")
```

Detection via HTTP API:
```
GET /session?roots=true              → lists only root sessions
GET /session/abc123/children         → lists def456, ghi789, jkl012
GET /session/status                  → {"abc123": "busy", "def456": "idle", ...}
```

**Permission scoping** — the task tool enforces permissions at spawn time:
- A sub-agent definition can restrict which tools it can use (`permission` field)
- The task tool can deny `task` permission on child sessions (preventing grandchild spawning)
- This is enforced in `TaskTool` source before `sessions.create()` is called

**Resuming** — `task_id` in the tool call continues an existing child session rather
than creating a new one. The LLM uses this to pick up a partially completed sub-task.

### 9.3 Level 2 — CF Sub-Agents (Phase 2)

For workloads that need their own container — isolated disk, separate codebase,
independent lifecycle — the agent calls the CF V3 API to spawn a new agent:

**Step 1: spawn**
```bash
RESPONSE=$(curl -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  "$CF_API_URL/v3/agents" \
  -d '{
    "name": "sub-agent-go-spec",
    "type": "opencode",
    "relationships": {
      "space":        { "data": { "guid": "'$AGENT_SPACE_GUID'" } },
      "parent_agent": { "data": { "guid": "'$AGENT_GUID'" } }
    }
  }')

JOB_URL=$(echo $RESPONSE | jq -r '.links.job.href')
```

**Step 2: poll job to completion**
```bash
# Poll until state == "complete"
while true; do
  STATE=$(curl -s -H "Authorization: Bearer $TOKEN" "$CF_API_URL$JOB_URL" | jq -r '.state')
  [ "$STATE" = "COMPLETE" ] && break
  sleep 2
done
```

**Step 3: get the sub-agent's route**
```bash
SUB_AGENT_GUID=$(curl -s -H "Authorization: Bearer $TOKEN" "$CF_API_URL$JOB_URL" \
  | jq -r '.links.resource.href' | xargs -I{} curl -s -H "Authorization: Bearer $TOKEN" "$CF_API_URL{}" \
  | jq -r '.guid')

SUB_AGENT_ROUTE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "$CF_API_URL/v3/agents/$SUB_AGENT_GUID" | jq -r '.links.route.href')
```

**Step 4: communicate with the sub-agent**
```bash
# Via GoRouter (external HTTP)
curl -X POST "https://$SUB_AGENT_ROUTE/session" \
  -H "Authorization: Basic $(echo -n "$SUB_AGENT_ID:$SUB_AGENT_PASSWORD" | base64)"
  -d '{"title": "build the payment service"}'

# Via C2C networking (internal, lower latency — same CF space)
curl -X POST "http://sub-agent-x1y2z3.apps.internal:8080/session" ...
```

The new container has its own opencode server, its own sessions, its own working
directory, its own UAA client (scoped to <= parent's permissions).

### 9.4 When to Use Each Level

| Use Level 1 (opencode task tool) | Use Level 2 (CF sub-agents) |
|----------------------------------|-----------------------------|
| Parallel sub-tasks within one job | Long-running separate workstreams |
| Specialist personas within same codebase | Agents that outlive the parent's session |
| Fast, lightweight parallel work | Isolated disk / working directory per agent |
| Shared CF credentials / same container | Different codebases or CF spaces |
| **Available: Phase 1** | **Available: Phase 2** |

### 9.5 Sub-Agent Constraints (Level 2)

- Sub-agent's UAA scope <= parent's UAA scope (no privilege escalation)
- Sub-agent inherits same space grants as parent by default
- Platform enforces: max depth = 3 (parent → child → grandchild)
- Platform enforces: max 10 Level 2 sub-agents per agent

### 9.6 Sub-Agent Communication — Level 2

Via GoRouter (external, crosses network boundary):
```
POST https://sub-agent-x1y2z3.apps.example.com/session/:id/prompt_async
Authorization: Basic <base64(clientID:serverPassword)>
```

Via C2C networking (internal, same CF space, lower latency):
```
POST http://sub-agent-x1y2z3.apps.internal:8080/session/:id/prompt_async
```

C2C network policies between parent and child agents are auto-provisioned by
`AgentCreateJob` when `parent_agent` relationship is present.

---

## 10. Space Scoping & Permissions

### 10.1 Default: Agent Scoped to Creation Space

When created in space `dev`, the agent's UAA client is authorized only for `dev`.
The agent can see, push, and manage apps only within `dev`.

### 10.2 Multi-Space Grants

```bash
cf grant-agent-space my-dev-agent staging   # requires SpaceDeveloper in staging
```

```http
POST /v3/agents/<guid>/space_grants
{ "space_guid": "<staging-guid>", "role": "deployer" }
```

### 10.3 Role Mapping

| Agent Role | CF Space Role Equivalent | Capabilities |
|------------|--------------------------|-------------|
| `readonly` | SpaceAuditor | Read apps, logs, services |
| `deployer` | SpaceDeveloper | Push apps, create routes, bind services |
| `full` | SpaceManager | Manage space membership too |

### 10.4 What Agents Cannot Do

- Create orgs or spaces
- Access other orgs
- Spawn sub-agents with higher permissions than themselves
- Bypass App Security Groups (same network rules as regular apps)
- Access CredHub secrets not explicitly granted to their UAA client

---

## 11. Authentication & Security

### 11.1 UAA Client Lifecycle

```
cf create-agent opencode
  |
  +-> AgentCreateJob: POST /oauth/clients/tx/modify (UAA)
  |   {
  |     client_id:    "agent-<guid>",
  |     client_secret: "<32-char-random>",
  |     grant_types:  ["client_credentials"],
  |     authorities:  ["cloud_controller.write", "cloud_controller.read",
  |                    "routing.routes.write", "agents.spawn"]
  |   }
  |
  +-> CredHub: store client_secret at /cf/agents/<guid>/client_secret
  +-> CredHub: store server_password at /cf/agents/<guid>/server_password
  +-> Diego LRP submitted with secrets injected as env vars

cf delete-agent
  |
  +-> Diego: remove LRP (stops container)
  +-> UAA: DELETE /oauth/clients/agent-<guid>
  +-> CredHub: DELETE /cf/agents/<guid>/client_secret
  +-> CredHub: DELETE /cf/agents/<guid>/server_password
  +-> CAPI: remove route, remove DB records
```

### 11.2 Token Flow: Agent -> CF API

```
Inside agent container:
  1. opencode / cf CLI reads CF_CLIENT_ID, CF_CLIENT_SECRET
  2. POST $CF_UAA_URL/oauth/token
       grant_type=client_credentials
       client_id=agent-<guid>
       client_secret=<secret>
  3. UAA issues JWT (expires ~600s)
  4. Agent calls: GET $CF_API_URL/v3/apps?space_guids=<space>
       Authorization: Bearer <jwt>
  5. CAPI validates:
       - JWT signature (UAA public key)
       - scope includes cloud_controller.read
       - space in request is in agent_space_grants for this agent
```

### 11.3 opencode API Security Layer

The opencode HTTP server is protected by HTTP Basic Auth using the platform-generated
`OPENCODE_SERVER_PASSWORD`.

Access paths:
```
External users:  -> GoRouter -> Agent (require OPENCODE_SERVER_PASSWORD)
CF CLI:          -> CAPI proxy -> Agent (CAPI injects auth; user needs CF role)
Parent agent:    -> C2C or GoRouter -> Child agent (password shared via env)
Other CF apps:   -> C2C (if network policy added) -> Agent
```

External access credentials are retrievable via:
```bash
cf agent-credentials my-dev-agent   # prints Basic Auth password
```

---

## 12. Networking & Routing

### 12.1 Agent HTTP Route

Each agent gets an auto-registered CF route at creation:

```
<agent-name>-<short-guid>.<apps-domain>

Example: my-dev-agent-a1b2c3.apps.example.com
  GET  /global/health       -> Diego health check
  GET  /doc                 -> OpenAPI 3.1 spec
  GET  /event               -> SSE event stream
  POST /session             -> create session
  POST /session/:id/message -> send task
  ...
```

### 12.2 Internal Route (Container-to-Container)

For sub-agent communication without GoRouter overhead:

```
my-dev-agent-a1b2c3.apps.internal:8080
```

C2C network policy is auto-provisioned between parent and child agent containers by
`AgentCreateJob`:

```bash
# Equivalent of:
cf add-network-policy <parent-agent-process> <child-agent-process> --protocol tcp --port 8080
```

---

## 13. Lifecycle

### 13.1 State Machine

```
        cf create-agent
               |
               v
          [CREATING]     <- CAPI creates DB record, enqueues job
               |
               v
          [STARTING]     <- UAA client + LRP submitted; waiting for health check
               |
               v
          [RUNNING]      <- GET /global/health -> 200; route live; accepting tasks
               |
       +-------+---------+
       |                 |
   [STOPPING]         [ERROR]    <- repeated health check failures / crash loop
       |
       v
   [STOPPED]
       |
       v (cf delete-agent)
   [DELETED]             <- LRP removed, UAA client revoked, route deregistered
```

### 13.2 Startup Sequence (Inside Container)

```
Container starts
     |
     +-- entrypoint.sh sets up SIGTERM trap
     +-- opencode reads env vars (CF_API_URL, CF_CLIENT_ID, etc.)
     +-- opencode starts HTTP server on $PORT, binding 0.0.0.0
     +-- GET /global/health -> 200 (Diego health check passes)
     |
     v
State: RUNNING
     |
      +-- Receive tasks via POST /session/:id/prompt_async (from cf CLI or API)
      +-- Each task can:
      |     - Call CF V3 API directly: GET/POST $CF_API_URL/v3/apps, /v3/packages, etc.
      |     - Spawn opencode child sessions (Level 1 sub-agents)
      |     - POST $CF_API_URL/v3/agents to spawn Level 2 sub-agents
      |     - Read/write files in working directory via /session/:id/shell
     |
     v
SIGTERM received (cf stop-agent / cf delete-agent / Diego restart)
     +-- entrypoint.sh catches SIGTERM
     +-- Forwards to opencode process (SIGTERM)
     +-- Waits up to graceful_shutdown_interval (default 10s)
     +-- Exit 0
```

---

## 14. Diego Integration

### 14.1 Agents as Standard DesiredLRPs

Agents run as Diego DesiredLRPs — identical to CF app processes. **Zero Diego changes.**

```ruby
# AgentCreateJob submits to BBS via BbsAppsClient -> Diego::Client -> HTTP+protobuf:
bbs_client.desire_lrp(
  process_guid:               "agent-#{agent.guid}-web",
  root_fs:                    "docker:///registry.example.com/cf-opencode:latest",
  instances:                  1,
  memory_mb:                  512,
  disk_mb:                    1024,
  ports:                      [8080],
  routes: {
    "cf-router" => [{
      hostnames: ["#{agent.name}-#{short_guid}.apps.#{system_domain}"],
      port: 8080
    }]
  },
  health_check_type:          "http",
  health_check_http_endpoint: "/global/health",
  health_check_timeout_ms:    60_000,
  start_command:              "/entrypoint.sh",
  env_vars:                   agent_env_vars(agent),
  log_guid:                   "agent-#{agent.guid}",
  metric_tags: {
    "agent_guid" => agent.guid,
    "agent_type" => agent.type,
    "space_guid" => agent.space_guid
  }
)
```

Diego communication path (source-verified from `cloud_controller_ng`):
```
AgentCreateJob
  -> BbsAppsClient#desire_app
    -> Diego::Client
      -> HTTP POST to BBS with protobuf-encoded body
```

### 14.2 Scaling

Phase 1: agents run as 1 instance. Scaling to multiple instances requires session affinity
(sticky routes) since opencode session state is per-process.

```bash
# Future (Phase 3+):
cf scale-agent my-dev-agent -i 2
# Requires: shared session store between instances
```

---

## 15. BOSH Packaging

### 15.1 Phase 1: Embed in Existing CAPI Job

Embed agent management directly in the existing `cloud_controller_ng` job:

- New DB tables in the existing CC migration chain
- New Rails controllers in the existing CC app
- No new BOSH jobs
- Feature flag to enable/disable the agent system

```yaml
# operations/enable-agent-system.yml (ops file for cf-deployment)
- type: replace
  path: /instance_groups/name=api/jobs/name=cloud_controller_ng/properties/cc/agents
  value:
    enabled: true
    max_agents_per_space: 50
    max_sub_agent_depth: 3
    max_sub_agents_per_agent: 10
    agent_types:
      - name: opencode
        image: "docker:///registry.example.com/cf-opencode:latest"
        min_memory_mb: 512
        min_disk_mb: 1024
        capabilities: ["spawn_sub_agents", "push_apps", "bind_services"]
        required_env: ["ANTHROPIC_API_KEY"]
```

### 15.2 Future: Separate BOSH Job

If the agent system grows (catalog service, separate worker pool, WebSocket broker),
it can be extracted into a dedicated `cf-agent-controller` BOSH job. Out of scope for Phase 1.

---

## 16. Implementation Phases

### Phase 1 — CAPI MVP (6-8 weeks)

- [ ] `agents` + `agent_space_grants` DB migrations in CC
- [ ] `/v3/agents` CRUD controller + `AgentCreateMessage` + `AgentPresenter`
- [ ] `AgentCreateJob`: UAA client + CredHub + Diego LRP + CF route
- [ ] `AgentDeleteJob`: stop LRP + revoke UAA client + clean CredHub
- [ ] `cf create-agent opencode` CLI command with async job polling
- [ ] `cf agents` + `cf agent` + `cf delete-agent` CLI commands
- [ ] Diego health check wired to `GET /global/health`
- [ ] `cf agent-command` (CAPI proxy to `/session/:id/prompt_async`)
- [ ] Custom opencode Docker image (bun base + SIGTERM entrypoint.sh)
- [ ] BOSH ops file for cf-deployment

### Phase 2 — Interaction & Sub-Agents (4-6 weeks)

- [ ] `cf agent-logs --stream` (proxy SSE `/event` endpoint)
- [ ] `cf agent-sessions` (proxy `/session`)
- [ ] `cf sub-agents` (proxy `/session/:id/children`)
- [ ] Level 2 CF sub-agents (`parent_agent_guid` + child LRP spawning)
- [ ] C2C network policy auto-provisioning for parent-child agents
- [ ] `cf grant-agent-space` / `cf revoke-agent-space`
- [ ] Sub-agent scope inheritance enforcement (no privilege escalation)

### Phase 3 — Hardening & Production (4-6 weeks)

- [ ] Full CredHub integration for all agent secrets
- [ ] Agent audit events in CC event log
- [ ] Rate limiting on agent-spawned CF API calls
- [ ] `cf agent-credentials` command
- [ ] Agent metrics tagged in Loggregator / Log Cache
- [ ] Session persistence via CF volume services (`XDG_DATA_HOME` override)
- [ ] Agent scaling (session affinity / external session store)

### Phase 4 — Agent Type Catalog

- [ ] `agent_types` catalog in CC DB
- [ ] `GET /v3/agent_types` endpoint
- [ ] Agent type versioning and pinning
- [ ] Buildpack-based agent packaging (alternative to Docker)
- [ ] Custom agent types (not just opencode)

---

## Appendix A: opencode API Quick Reference

```
opencode serve --port $PORT --hostname 0.0.0.0
  |
  +-- GET  /global/health          -> {"healthy":true}          <- Diego health check
  +-- GET  /event                  -> SSE (heartbeat every 10s) <- CF monitor
  |
  +-- POST /session                -> create session {parentID?}
  +-- GET  /session                -> list sessions (?roots=true)
  +-- GET  /session/status         -> {sessionID: idle|busy|retry}
  +-- GET  /session/:id/children   -> Level-1 sub-agent tree
  |
  +-- POST /session/:id/message    -> sync streaming JSON response
  +-- POST /session/:id/prompt_async -> 204 (async, monitor via SSE)
  +-- POST /session/:id/abort      -> cancel running prompt
  +-- POST /session/:id/shell      -> run shell command in container
  |
  +-- GET  /config/providers       -> list AI providers
  +-- GET  /experimental/tool/ids  -> list tool IDs
  |
  +-- GET  /doc                    -> OpenAPI 3.1 spec
```

---

## Appendix B: Key Repository References

| Repository | Purpose | Key Paths |
|-----------|---------|-----------|
| `cloud_controller_ng` | CAPI — add `/v3/agents` | `app/controllers/v3/`, `app/jobs/v3/` |
| `cli` | Add `cf create-agent` commands | `command/v7/`, `actor/v7action/`, `api/cloudcontroller/ccv3/` |
| `uaa` | UAA client management | No changes required |
| `bbs` | Diego LRP API | No changes required |
| `cf-deployment` | BOSH ops file | `operations/` |
| `opencode` | Agent runtime | `packages/opencode/src/` |

**Verified source paths in `sst/opencode`**:
- `packages/opencode/src/cli/cmd/serve.ts` — ServeCommand, SIGTERM issue
- `packages/opencode/src/cli/network.ts` — `--port`, `--hostname` flags
- `packages/opencode/src/server/instance/global.ts` — `GET /global/health`
- `packages/opencode/src/server/instance/session.ts` — all session HTTP routes
- `packages/opencode/src/server/instance/event.ts` — SSE `/event` endpoint
- `packages/opencode/src/session/index.ts` — `Session.Info` schema
- `packages/opencode/src/session/status.ts` — `SessionStatus` (idle/busy/retry)

**Verified source paths in `cloudfoundry/cloud_controller_ng`**:
- `lib/services/sso/uaa/uaa_client_manager.rb` — UAA client creation pattern
- `app/controllers/v3/service_instances_controller.rb` — V3 controller + job enqueue template
- `app/jobs/v3/create_service_instance_job.rb` — `ReoccurringJob` pattern
- `lib/cloud_controller/diego/bbs_apps_client.rb` — `desire_app` -> BBS

**Verified source paths in `cloudfoundry/cli`** (module `code.cloudfoundry.org/cli/v9`):
- `command/common/command_list_v7.go` — command registration (internal Go package is `v7`, CLI binary is v8)
- `command/v7/create_service_command.go` — template for `create-agent`
- `actor/v7action/service_instance.go` — `PollJobToEventStream` pattern
- `api/cloudcontroller/ccv3/service_instance.go` — V3 HTTP client pattern

---

*CF Agent System Architecture v2 — 2026-04-13*

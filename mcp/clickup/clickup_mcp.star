#!/usr/bin/env kite
# clickup_mcp.star — Minimal ClickUp MCP Server built with Starkite.
#
# Exposes 2 essential ClickUp tools over Model Context Protocol (MCP):
#   1. get_authorized_user()           -> User identity and primary workspace team ID
#   2. get_tasks(team_id, assignee_id) -> Query open tasks for a workspace
#
# Run in stdio mode:
#   kite run --allow-local --sandbox-net ./clickup_mcp.star --api-key pk_your_token
#
# Run in HTTP mode:
#   kite run --allow-local --sandbox-net ./clickup_mcp.star --api-key pk_your_token --port 8080

BASE_URL = "https://api.clickup.com/api/v2"

args.string("api-key", shorthand = "k", default = "", help = "ClickUp Personal API Token (pk_...)")
args.int("port", shorthand = "p", default = 0, help = "HTTP port to listen on (0 for stdio transport)")

def get_authorized_user():
    """Get authenticated user identity and primary workspace team ID."""
    user = json.decode(http.get(BASE_URL + "/user").body).get("user", {})
    teams = json.decode(http.get(BASE_URL + "/team").body).get("teams", [])
    team = teams[0] if teams else {}

    return {
        "user_id": "%d" % user.get("id"),
        "username": user.get("username", ""),
        "email": user.get("email", ""),
        "team_id": team.get("id", ""),
        "team_name": team.get("name", ""),
    }

def get_tasks(team_id, assignee_id="", status=""):
    """List open tasks for a team workspace.

    Args:
        team_id: ClickUp workspace/team ID.
        assignee_id: Optional user ID to filter assigned tasks.
        status: Optional status name to filter by (e.g. 'in progress').
    """
    query = "?subtasks=false&include_closed=false"
    if assignee_id:
        query += "&assignees[]=" + assignee_id
    if status:
        query += "&statuses[]=" + status

    resp = http.get(BASE_URL + "/team/" + team_id + "/task" + query)
    if resp.status_code != 200:
        fail("ClickUp error: " + resp.get_text())

    raw_tasks = json.decode(resp.body).get("tasks", [])
    tasks = []
    for t in raw_tasks:
        priority = (t.get("priority") or {}).get("priority", "none")
        tasks.append({
            "id": t.get("id"),
            "name": t.get("name"),
            "status": (t.get("status") or {}).get("status", ""),
            "priority": priority,
            "url": t.get("url", ""),
        })
    return {"count": len(tasks), "tasks": tasks}

def main():
    opts = args.parse()
    if not opts.api_key:
        fail("ClickUp API token required: pass --api-key <token>")

    http.config(headers={"Authorization": opts.api_key})

    if opts.port > 0:
        mcp.serve(
            name="clickup-mini",
            version="0.1.0",
            tools=[get_authorized_user, get_tasks],
            port=opts.port,
        )
    else:
        mcp.serve(
            name="clickup-mini",
            version="0.1.0",
            tools=[get_authorized_user, get_tasks],
        )

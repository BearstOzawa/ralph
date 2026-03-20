#!/usr/bin/env python3
"""
🐺 Ralph Feishu Bridge — WebSocket long-connection mode

No public URL needed, no server required, works behind firewalls.
Connects outbound to Feishu servers, receives messages, creates GitHub Issues via API.

Usage:
  1. pip install lark-oapi requests
  2. Set environment variables (see below)
  3. python feishu/bridge.py

Environment variables:
  FEISHU_APP_ID       - Feishu app App ID
  FEISHU_APP_SECRET   - Feishu app App Secret
  GITHUB_TOKEN        - GitHub PAT (needs repo scope)
  GITHUB_REPO         - Target repo, e.g. your-org/your-repo

Feishu app setup:
  1. Feishu Open Platform → Create app → Enable "Bot" capability
  2. Event subscription → Add im.message.receive_v1
  3. Important: Connection mode must be "WebSocket" (not Webhook)
  4. Permissions → Add im:message:receive_v1, im:message
"""

import os
import sys
import json
import logging
import requests

try:
    import lark_oapi as lark
    from lark_oapi.adapter.flask import *
except ImportError:
    print("❌ Install dependencies first: pip install lark-oapi requests")
    sys.exit(1)

# Configuration
APP_ID = os.environ.get("FEISHU_APP_ID", "")
APP_SECRET = os.environ.get("FEISHU_APP_SECRET", "")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "")

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("ralph-feishu")


def create_github_issue(title: str, body: str) -> dict | None:
    """Create a GitHub issue with ai/ready label."""
    if not GITHUB_REPO:
        logger.error("Missing GITHUB_REPO environment variable")
        return None

    url = f"https://api.github.com/repos/{GITHUB_REPO}/issues"
    resp = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {GITHUB_TOKEN}",
            "Accept": "application/vnd.github.v3+json",
        },
        json={
            "title": title,
            "body": body,
            "labels": ["ai/ready"],
        },
        timeout=30,
    )
    if resp.status_code == 201:
        return resp.json()
    logger.error(f"GitHub API error {resp.status_code}: {resp.text}")
    return None


def reply_message(client: lark.Client, message_id: str, text: str):
    """Reply to a Feishu message."""
    try:
        req = lark.api.im.v1.CreateMessageRequest.builder() \
            .receive_id_type("message_id") \
            .request_body(
                lark.api.im.v1.CreateMessageRequestBody.builder()
                .receive_id(message_id)
                .msg_type("text")
                .content(json.dumps({"text": text}))
                .build()
            ).build()
        # Use reply API
        import lark_oapi.api.im.v1 as im_v1
        reply_req = im_v1.ReplyMessageRequest.builder() \
            .message_id(message_id) \
            .request_body(
                im_v1.ReplyMessageRequestBody.builder()
                .msg_type("text")
                .content(json.dumps({"text": text}))
                .build()
            ).build()
        client.im.v1.message.reply(reply_req)
    except Exception as e:
        logger.error(f"Reply failed: {e}")


def handle_message(client: lark.Client, event: dict):
    """Process incoming Feishu message."""
    msg = event.get("message", {})
    msg_type = msg.get("message_type", "")
    message_id = msg.get("message_id", "")

    if msg_type != "text":
        return

    content = json.loads(msg.get("content", "{}"))
    text = content.get("text", "").strip()

    # Match /ralph command
    if not text.startswith("/ralph "):
        return

    raw = text[len("/ralph "):].strip()
    if not raw:
        reply_message(client, message_id, "Usage: /ralph <task description>")
        return

    # Parse: first line = title, rest = body
    lines = raw.split("\n")
    title = lines[0].strip()
    body = "\n".join(lines[1:]).strip()

    sender = event.get("sender", {}).get("sender_id", {}).get("open_id", "unknown")
    full_body = f"{body}\n\n---\n> Via Feishu (sender: {sender})" if body else f"---\n> Via Feishu (sender: {sender})"

    logger.info(f"Creating issue: {title}")
    issue = create_github_issue(title, full_body)

    if issue:
        reply_message(
            client,
            message_id,
            f"🐺 Ralph is on it!\n\nIssue #{issue['number']}: {issue['title']}\n{issue['html_url']}",
        )
        logger.info(f"Issue #{issue['number']} created")
    else:
        reply_message(client, message_id, "❌ Failed to create Issue. Check GITHUB_REPO / GITHUB_TOKEN and logs.")


def main():
    if not APP_ID or not APP_SECRET:
        print("❌ Set FEISHU_APP_ID and FEISHU_APP_SECRET")
        sys.exit(1)
    if not GITHUB_TOKEN:
        print("❌ Set GITHUB_TOKEN")
        sys.exit(1)

    logger.info(f"🐺 Ralph Feishu Bridge starting...")
    logger.info(f"Repo: {GITHUB_REPO}")
    logger.info(f"Mode: WebSocket long-connection")

    # Build event handler
    event_handler = lark.EventDispatcherHandler.builder("", "") \
        .register_p2_im_message_receive_v1(lambda ctx, event: handle_message(ctx.get_client(), event.event)) \
        .build()

    # Create client with WebSocket mode
    cli = lark.ws.Client(
        APP_ID,
        APP_SECRET,
        event_handler=event_handler,
        log_level=lark.LogLevel.INFO,
    )

    logger.info("✅ Connected to Feishu via WebSocket")
    logger.info("In Feishu group, @bot and send: /ralph <task description>")
    logger.info("Press Ctrl+C to stop")

    cli.start()


if __name__ == "__main__":
    main()

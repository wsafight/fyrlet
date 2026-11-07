"""Interactive inbox against a running Fyrlet server.

    FYRLET_ENDPOINT=http://127.0.0.1:4000 FYRLET_PROJECT_ID=... FYRLET_SERVICE_KEY=rtk_... python examples/inbox.py "First note"

In a real application the SessionService runs on your backend and only the token reaches the client.
"""

import os
import sys
import time

from fyrlet import Client, SessionService

endpoint = os.environ["FYRLET_ENDPOINT"]
service = SessionService(endpoint, os.environ["FYRLET_SERVICE_KEY"])
session = service.issue_session("example-user", issuer="example", ttl_seconds=600)

with Client(endpoint, os.environ["FYRLET_PROJECT_ID"], lambda force_refresh: service.issue_session("example-user").token
            if force_refresh else session.token) as client:
    recent = client.subscribe("inbox.recent", {"limit": 20})
    recent.on_change(lambda state: print(state.status, [item["text"] for item in state.data or []]))
    for text in sys.argv[1:] or ["Hello from Python"]:
        client.call("inbox.add", {"text": text})
    time.sleep(1)  # let the delta arrive before leaving the context manager

"""Map session events to specific diff hunks (file + line range).

Replays edits sequentially to attribute final-state line ownership.
"""
from __future__ import annotations

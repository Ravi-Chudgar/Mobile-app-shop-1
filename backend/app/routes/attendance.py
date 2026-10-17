"""Staff attendance: clock in / clock out (one immutable record per day).

Deliberately append-only: this blueprint only READS today's record and
CREATES a clock-in / clock-out stamp. There is no PUT/PATCH/DELETE that
could alter a recorded clock-in — and the repository backs that with
conditional writes, so even racing double-taps cannot change a stamp.
"""
from flask import Blueprint, jsonify, g

from ..auth import any_required
from ..repositories import attendance as attendance_repo

bp = Blueprint("attendance", __name__)


@bp.get("/attendance/me")
@any_required
def me():
    """Today's shift for the signed-in member, or null if not clocked in."""
    return jsonify({"record": attendance_repo.get_today(g.user.get("sub"))})


@bp.post("/attendance/clock-in")
@any_required
def clock_in():
    """Start today's shift. 409 when one exists — never overwrites it."""
    return jsonify(
        {"record": attendance_repo.clock_in(g.user.get("sub"))}), 201


@bp.post("/attendance/clock-out")
@any_required
def clock_out():
    """End today's shift. 400 without a clock-in, 409 if already clocked out."""
    return jsonify({"record": attendance_repo.clock_out(g.user.get("sub"))})

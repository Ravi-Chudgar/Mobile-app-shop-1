"""Table listing (staff) + table management (owner)."""
from flask import Blueprint, request, jsonify, g

from ..auth import staff_required, owner_required
from ..repositories import tables as tables_repo
from ..util import ApiError

bp = Blueprint("tables", __name__)


@bp.get("/tables")
@staff_required
def list_tables():
    return jsonify(tables_repo.list_all())


@bp.post("/tables/<number>/free")
@staff_required
def free_table(number):
    # Table locking: only the staff member serving the table (or the owner)
    # may free an occupied table.
    table = tables_repo.get(str(number))
    if table and table.get("status") == "occupied":
        server = table.get("taken_by")
        if server and g.user.get("role") != "owner" and g.user.get("sub") != server:
            raise ApiError(f"Table {number} is locked by {server}", 403)
    tables_repo.free(number)
    return jsonify(tables_repo.get(str(number)) or
                   {"number": str(number), "status": "empty"})


@bp.post("/admin/tables")
@owner_required
def add_table():
    data = request.get_json(silent=True) or {}
    if data.get("number") is not None:
        return jsonify(tables_repo.add(data["number"], layout=data)), 201
    return jsonify(tables_repo.add_next()), 201


@bp.put("/admin/tables/<number>/layout")
@owner_required
def update_table_layout(number):
    """Owner-only floor-map layout: zone + position/size (x, y, w, h) + shape."""
    data = request.get_json(silent=True) or {}
    return jsonify(tables_repo.update_layout(number, data))


@bp.delete("/admin/tables/<number>")
@owner_required
def remove_table(number):
    return jsonify(tables_repo.remove(number))

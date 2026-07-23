"""Serializes plain Python dict/list/str/num/bool into Lua table source."""
from __future__ import annotations


def _key(k) -> str:
    if isinstance(k, str) and k.isidentifier():
        return k
    return f"[{_value(k)}]"


def _value(v, indent: int = 0) -> str:
    pad = "  " * indent
    pad_in = "  " * (indent + 1)
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        escaped = v.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    if isinstance(v, dict):
        if not v:
            return "{}"
        items = ",\n".join(f"{pad_in}{_key(k)} = {_value(val, indent + 1)}" for k, val in v.items())
        return "{\n" + items + f"\n{pad}}}"
    if isinstance(v, (list, tuple)):
        if not v:
            return "{}"
        items = ",\n".join(f"{pad_in}{_value(item, indent + 1)}" for item in v)
        return "{\n" + items + f"\n{pad}}}"
    raise TypeError(f"Cannot serialize {type(v)} to Lua")


def to_lua(value) -> str:
    return "return " + _value(value) + "\n"

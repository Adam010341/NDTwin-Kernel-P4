"""
Minimal declarative schema validator for NDTwin API responses.

Deliberately dependency-free (no jsonschema / pydantic) so the contract test can run
anywhere python3 exists, including a bare demo VM.

The point of this module is *precise failure messages*. A test that says
"get_graph_data failed" is barely better than eyeballing the GUI; a test that says
    nodes[3].is_up: expected bool, got str ('true')
tells you what to fix.

[Co-developed with claude code -- Adam]
"""

from __future__ import annotations


class SchemaError(Exception):
    """Raised with a JSON-path-ish location so the caller knows exactly what broke."""


def _fail(path: str, msg: str) -> None:
    raise SchemaError(f"{path or '<root>'}: {msg}")


def _typename(v) -> str:
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    if isinstance(v, str):
        return "str"
    if isinstance(v, list):
        return "list"
    if isinstance(v, dict):
        return "object"
    if v is None:
        return "null"
    return type(v).__name__


def _preview(v, limit: int = 40) -> str:
    s = repr(v)
    return s if len(s) <= limit else s[:limit] + "..."


class Type:
    """Base class. Subclasses implement check(value, path)."""

    def check(self, value, path: str = "") -> None:
        raise NotImplementedError

    def describe(self) -> str:
        return self.__class__.__name__.lower()


class Int(Type):
    """An integer. bool is rejected: in JSON `true` is not a valid dpid."""

    def __init__(self, min=None, max=None):
        self.min, self.max = min, max

    def check(self, value, path="") -> None:
        if isinstance(value, bool) or not isinstance(value, int):
            _fail(path, f"expected int, got {_typename(value)} ({_preview(value)})")
        if self.min is not None and value < self.min:
            _fail(path, f"expected int >= {self.min}, got {value}")
        if self.max is not None and value > self.max:
            _fail(path, f"expected int <= {self.max}, got {value}")


class Num(Type):
    """Integer or float. Use for rates/percentages where the kernel may emit either."""

    def __init__(self, min=None, max=None):
        self.min, self.max = min, max

    def check(self, value, path="") -> None:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            _fail(path, f"expected number, got {_typename(value)} ({_preview(value)})")
        if self.min is not None and value < self.min:
            _fail(path, f"expected >= {self.min}, got {value}")
        if self.max is not None and value > self.max:
            _fail(path, f"expected <= {self.max}, got {value}")


class Str(Type):
    def __init__(self, allowed=None, nonempty=False):
        self.allowed = set(allowed) if allowed else None
        self.nonempty = nonempty

    def check(self, value, path="") -> None:
        if not isinstance(value, str):
            _fail(path, f"expected str, got {_typename(value)} ({_preview(value)})")
        if self.nonempty and not value:
            _fail(path, "expected a non-empty string")
        if self.allowed is not None and value not in self.allowed:
            _fail(path, f"expected one of {sorted(self.allowed)}, got {value!r}")


class Bool(Type):
    def check(self, value, path="") -> None:
        if not isinstance(value, bool):
            _fail(path, f"expected bool, got {_typename(value)} ({_preview(value)})")


class Any_(Type):
    """Accepts anything, including null. Use where the kernel's shape is genuinely open."""

    def check(self, value, path="") -> None:
        return


class List(Type):
    def __init__(self, of: Type, min_len=None):
        self.of, self.min_len = of, min_len

    def check(self, value, path="") -> None:
        if not isinstance(value, list):
            _fail(path, f"expected list, got {_typename(value)} ({_preview(value)})")
        if self.min_len is not None and len(value) < self.min_len:
            _fail(path, f"expected at least {self.min_len} element(s), got {len(value)}")
        for i, item in enumerate(value):
            self.of.check(item, f"{path}[{i}]")


class Obj(Type):
    """
    An object with required and optional fields.

    strict=True rejects unexpected keys. Defaults to False: a kernel that *adds* a
    field is not breaking its consumers, so treating that as failure would produce
    noise every time someone extends the API.
    """

    def __init__(self, fields: dict, optional: dict | None = None, strict: bool = False):
        self.fields = fields
        self.optional = optional or {}
        self.strict = strict

    def check(self, value, path="") -> None:
        if not isinstance(value, dict):
            _fail(path, f"expected object, got {_typename(value)} ({_preview(value)})")

        missing = [k for k in self.fields if k not in value]
        if missing:
            _fail(path, f"missing required field(s): {', '.join(sorted(missing))}")

        for key, typ in self.fields.items():
            typ.check(value[key], f"{path}.{key}" if path else key)

        for key, typ in self.optional.items():
            if key in value:
                typ.check(value[key], f"{path}.{key}" if path else key)

        if self.strict:
            extra = set(value) - set(self.fields) - set(self.optional)
            if extra:
                _fail(path, f"unexpected field(s): {', '.join(sorted(extra))}")


class MapOf(Type):
    """
    An object used as a dictionary, e.g. get_cpu_utilization's {"10.0.0.1": 12}.

    Keys are always JSON strings; key_check lets us assert they look like IPs/dpids.
    """

    def __init__(self, value_type: Type, key_check=None, key_desc: str = "key"):
        self.value_type = value_type
        self.key_check = key_check
        self.key_desc = key_desc

    def check(self, value, path="") -> None:
        if not isinstance(value, dict):
            _fail(path, f"expected object (map), got {_typename(value)} ({_preview(value)})")
        for key, val in value.items():
            if self.key_check and not self.key_check(key):
                _fail(f"{path}.{key}", f"key is not a valid {self.key_desc}")
            self.value_type.check(val, f"{path}.{key}" if path else key)


class OneOf(Type):
    """Union. Reports every branch's failure, since which one was intended is ambiguous."""

    def __init__(self, *types: Type):
        self.types = types

    def check(self, value, path="") -> None:
        errors = []
        for typ in self.types:
            try:
                typ.check(value, path)
                return
            except SchemaError as exc:
                errors.append(str(exc))
        _fail(path, "matched none of the allowed shapes:\n      - " + "\n      - ".join(errors))


# --- helpers used by the endpoint specs -------------------------------------------

def is_ipv4_string(s: str) -> bool:
    parts = s.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p.isdigit() or not 0 <= int(p) <= 255:
            return False
    return True


def is_decimal_string(s: str) -> bool:
    return s.isdigit()


def validate(schema: Type, data) -> list[str]:
    """Returns a list of failure messages (empty means the data conforms)."""
    try:
        schema.check(data, "")
    except SchemaError as exc:
        return [str(exc)]
    return []

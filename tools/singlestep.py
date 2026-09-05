"""Small, dependency-free readers for SingleStepTests 80286 data.

The reader normalizes the published JSON representation and the MOO 1.1
chunked representation into the same lightweight ``SingleStepCase`` object.
It intentionally stops at data loading and selection in Phase 0; instruction
execution and comparison against RTL belong to a later CPU milestone.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import struct
from typing import Any, Iterable, Iterator, Mapping


REGISTER_NAMES = (
    "ax",
    "bx",
    "cx",
    "dx",
    "cs",
    "ss",
    "ds",
    "es",
    "sp",
    "bp",
    "si",
    "di",
    "ip",
    "flags",
)

BUS_STATUS_NAMES_286 = {
    0: "INTA",
    1: "PASV",
    2: "PASV",
    3: "PASV",
    4: "HALT",
    5: "MEMR",
    6: "MEMW",
    9: "IOR",
    10: "IOW",
    13: "CODE",
}


class SingleStepFormatError(ValueError):
    """Raised when a JSON or MOO input is malformed."""


@dataclass(frozen=True)
class SingleStepCase:
    """Normalized representation of one SingleStep test case."""

    index: int
    name: str
    instruction_bytes: tuple[int, ...]
    initial: Mapping[str, Any]
    final: Mapping[str, Any]
    exception: Mapping[str, Any] | None
    test_hash: str | None
    cycles: tuple[Any, ...]
    raw: Mapping[str, Any]

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any], fallback_index: int = 0) -> "SingleStepCase":
        try:
            index = int(value.get("idx", value.get("index", fallback_index)))
            name = str(value.get("name", f"case-{index}"))
            raw_bytes = value.get("bytes", value.get("instruction_bytes", []))
            instruction_bytes = tuple(_checked_byte(item, "instruction byte") for item in raw_bytes)
            initial = value.get("initial", {})
            final = value.get("final", {})
        except (TypeError, ValueError, KeyError) as error:
            raise SingleStepFormatError(f"invalid test case: {error}") from error

        if not isinstance(initial, Mapping) or not isinstance(final, Mapping):
            raise SingleStepFormatError(f"case {index}: initial/final state must be objects")

        exception = value.get("exception")
        if exception is not None and not isinstance(exception, Mapping):
            raise SingleStepFormatError(f"case {index}: exception must be an object")

        cycles_value = value.get("cycles", [])
        if not isinstance(cycles_value, list):
            raise SingleStepFormatError(f"case {index}: cycles must be an array")
        cycles = tuple(cycles_value)
        test_hash = value.get("hash")
        if test_hash is not None:
            test_hash = str(test_hash).lower()

        return cls(
            index=index,
            name=name,
            instruction_bytes=instruction_bytes,
            initial=initial,
            final=final,
            exception=exception,
            test_hash=test_hash,
            cycles=cycles,
            raw=value,
        )


@dataclass(frozen=True)
class MooFile:
    """Parsed MOO file metadata and tests."""

    header: Mapping[str, Any]
    metadata: Mapping[str, Any]
    tests: tuple[SingleStepCase, ...]


def _checked_byte(value: Any, label: str) -> int:
    number = int(value)
    if not 0 <= number <= 0xFF:
        raise SingleStepFormatError(f"{label} outside byte range: {number}")
    return number


def _chunks(data: bytes, start: int = 0, end: int | None = None) -> Iterator[tuple[bytes, bytes]]:
    end = len(data) if end is None else end
    offset = start
    while offset < end:
        if end - offset < 8:
            raise SingleStepFormatError(f"truncated chunk header at offset {offset}")
        chunk_type = data[offset : offset + 4]
        length = struct.unpack_from("<I", data, offset + 4)[0]
        payload_start = offset + 8
        payload_end = payload_start + length
        if payload_end > end:
            raise SingleStepFormatError(
                f"chunk {chunk_type!r} exceeds container at offset {offset}"
            )
        yield chunk_type, data[payload_start:payload_end]
        offset = payload_end


def _ascii_id(value: bytes) -> str:
    try:
        return value.decode("ascii")
    except UnicodeDecodeError as error:
        raise SingleStepFormatError(f"non-ASCII chunk identifier: {value!r}") from error


def _length_prefixed_bytes(payload: bytes, label: str) -> bytes:
    if len(payload) < 4:
        raise SingleStepFormatError(f"short {label} payload")
    length = struct.unpack_from("<I", payload, 0)[0]
    if 4 + length > len(payload):
        raise SingleStepFormatError(f"short {label} data")
    return payload[4 : 4 + length]


def _parse_register_payload(payload: bytes, masks: bool = False) -> dict[str, int]:
    if len(payload) < 2:
        raise SingleStepFormatError("short REGS/RMSK payload")
    bitmask = struct.unpack_from("<H", payload, 0)[0]
    offset = 2
    result: dict[str, int] = {}
    for bit, name in enumerate(REGISTER_NAMES):
        if bitmask & (1 << bit):
            if offset + 2 > len(payload):
                raise SingleStepFormatError("short REGS/RMSK register list")
            result[name] = struct.unpack_from("<H", payload, offset)[0]
            offset += 2
    if offset != len(payload):
        raise SingleStepFormatError("unexpected trailing bytes in REGS/RMSK payload")
    return result


def _parse_ram_payload(payload: bytes) -> list[list[int]]:
    if len(payload) < 4:
        raise SingleStepFormatError("short RAM payload")
    count = struct.unpack_from("<I", payload, 0)[0]
    expected_length = 4 + count * 5
    if len(payload) != expected_length:
        raise SingleStepFormatError("RAM entry count does not match payload length")
    result = []
    offset = 4
    for _ in range(count):
        address = struct.unpack_from("<I", payload, offset)[0]
        value = payload[offset + 4]
        result.append([address, value])
        offset += 5
    return result


def _parse_state(payload: bytes) -> dict[str, Any]:
    state: dict[str, Any] = {"regs": {}, "ram": [], "queue": []}
    for chunk_type, chunk_payload in _chunks(payload):
        kind = _ascii_id(chunk_type)
        if kind == "REGS":
            state["regs"] = _parse_register_payload(chunk_payload)
        elif kind == "RMSK":
            state["reg_masks"] = _parse_register_payload(chunk_payload, masks=True)
        elif kind == "RAM ":
            state["ram"] = _parse_ram_payload(chunk_payload)
        elif kind == "QUEU":
            state["queue"] = list(_length_prefixed_bytes(chunk_payload, "queue"))
        elif kind in {"RG32", "RM32", "EA32"}:
            state[kind.strip()] = chunk_payload.hex()
        else:
            # Unknown chunks are explicitly skippable in MOO 1.1.
            continue
    return state


def _parse_cycles(payload: bytes) -> list[dict[str, Any]]:
    if len(payload) < 4:
        raise SingleStepFormatError("short CYCL payload")
    count = struct.unpack_from("<I", payload, 0)[0]
    cycle_size = 15
    if len(payload) != 4 + count * cycle_size:
        raise SingleStepFormatError("cycle count does not match payload length")
    cycles = []
    offset = 4
    for _ in range(count):
        pin0 = payload[offset]
        address, = struct.unpack_from("<I", payload, offset + 1)
        segment_status = payload[offset + 5]
        memory_status = payload[offset + 6]
        io_status = payload[offset + 7]
        pin1 = payload[offset + 8]
        data_bus, = struct.unpack_from("<H", payload, offset + 9)
        bus_status = payload[offset + 11]
        t_state = payload[offset + 12]
        queue_operation = payload[offset + 13]
        queue_byte = payload[offset + 14]
        cycles.append(
            {
                "pin_bitfield0": pin0,
                "address": address,
                "segment_status": segment_status,
                "memory_status": memory_status,
                "io_status": io_status,
                "pin_bitfield1": pin1,
                "data_bus": data_bus,
                "bus_status": bus_status,
                "bus_status_name": BUS_STATUS_NAMES_286.get(bus_status, "PASV"),
                "t_state": t_state,
                "queue_operation": queue_operation,
                "queue_byte": queue_byte,
            }
        )
        offset += cycle_size
    return cycles


def _parse_moo_test(payload: bytes, top_level_masks: Mapping[str, int] | None) -> SingleStepCase:
    if len(payload) < 4:
        raise SingleStepFormatError("short TEST payload")
    index, = struct.unpack_from("<I", payload, 0)
    mapping: dict[str, Any] = {
        "idx": index,
        "name": f"case-{index}",
        "bytes": [],
        "initial": {},
        "final": {},
        "cycles": [],
    }
    final_masks = top_level_masks
    for chunk_type, chunk_payload in _chunks(payload, 4):
        kind = _ascii_id(chunk_type)
        if kind == "NAME":
            mapping["name"] = _length_prefixed_bytes(chunk_payload, "name").decode("ascii")
        elif kind == "BYTS":
            mapping["bytes"] = list(_length_prefixed_bytes(chunk_payload, "bytes"))
        elif kind == "INIT":
            mapping["initial"] = _parse_state(chunk_payload)
        elif kind == "FINA":
            mapping["final"] = _parse_state(chunk_payload)
        elif kind == "CYCL":
            mapping["cycles"] = _parse_cycles(chunk_payload)
        elif kind == "EXCP":
            if len(chunk_payload) != 5:
                raise SingleStepFormatError("EXCP payload must contain number and flag address")
            mapping["exception"] = {
                "number": chunk_payload[0],
                "flag_address": struct.unpack_from("<I", chunk_payload, 1)[0],
            }
        elif kind == "HASH":
            if len(chunk_payload) != 20:
                raise SingleStepFormatError("HASH payload must contain 20 bytes")
            mapping["hash"] = chunk_payload.hex()
        elif kind in {"RMSK", "RM32"}:
            final_masks = _parse_register_payload(chunk_payload)
        else:
            continue
    if final_masks:
        mapping.setdefault("final", {})["reg_masks"] = dict(final_masks)
    return SingleStepCase.from_mapping(mapping, fallback_index=index)


def load_moo(path: str | Path) -> MooFile:
    """Load a MOO 1.0/1.1 file and return normalized cases."""

    data = Path(path).read_bytes()
    header: dict[str, Any] = {}
    metadata: dict[str, Any] = {}
    tests: list[SingleStepCase] = []
    top_level_masks: dict[str, int] | None = None

    for chunk_type, payload in _chunks(data):
        kind = _ascii_id(chunk_type)
        if kind == "MOO ":
            if len(payload) < 12:
                raise SingleStepFormatError("MOO header is too short")
            header = {
                "major_version": payload[0],
                "minor_version": payload[1],
                "test_count": struct.unpack_from("<I", payload, 4)[0],
                "cpu_id": payload[8:12].decode("ascii").rstrip(" "),
            }
        elif kind == "META":
            if len(payload) >= 28:
                metadata = {
                    "major_version": payload[0],
                    "minor_version": payload[1],
                    "cpu_type": payload[2],
                    "opcode": struct.unpack_from("<I", payload, 4)[0],
                    "mnemonic": payload[8:16].decode("ascii").rstrip(" "),
                    "test_count": struct.unpack_from("<I", payload, 16)[0],
                    "file_seed": struct.unpack_from("<Q", payload, 20)[0],
                    "cpu_mode": payload[28] if len(payload) > 28 else None,
                }
        elif kind in {"RMSK", "RM32"}:
            if kind == "RMSK":
                top_level_masks = _parse_register_payload(payload)
        elif kind == "TEST":
            tests.append(_parse_moo_test(payload, top_level_masks))

    if not header:
        raise SingleStepFormatError("MOO header chunk is missing")
    return MooFile(header=header, metadata=metadata, tests=tuple(tests))


def load_json(path: str | Path) -> tuple[SingleStepCase, ...]:
    """Load a JSON array, a ``{\"tests\": [...]}`` object, or one case."""

    source = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(source, list):
        values = source
    elif isinstance(source, Mapping) and isinstance(source.get("tests"), list):
        values = source["tests"]
    elif isinstance(source, Mapping):
        values = [source]
    else:
        raise SingleStepFormatError("JSON root must be an object or array")
    cases = []
    for fallback_index, value in enumerate(values):
        if not isinstance(value, Mapping):
            raise SingleStepFormatError(f"JSON case {fallback_index} is not an object")
        cases.append(SingleStepCase.from_mapping(value, fallback_index))
    return tuple(cases)


def load_source(path: str | Path) -> tuple[SingleStepCase, ...]:
    """Load ``.json`` or ``.moo`` and return normalized cases."""

    source_path = Path(path)
    suffix = source_path.suffix.lower()
    if suffix == ".moo":
        return load_moo(source_path).tests
    if suffix in {".json", ".jsonl"}:
        if suffix == ".jsonl":
            cases = []
            for line_number, line in enumerate(source_path.read_text(encoding="utf-8").splitlines(), 1):
                if not line.strip():
                    continue
                value = json.loads(line)
                if not isinstance(value, Mapping):
                    raise SingleStepFormatError(f"JSONL line {line_number} is not an object")
                cases.append(SingleStepCase.from_mapping(value, len(cases)))
            return tuple(cases)
        return load_json(source_path)
    raise SingleStepFormatError(f"unsupported test-data extension: {source_path.suffix}")


def load_revocation_list(path: str | Path) -> frozenset[str]:
    """Load hashes from a SingleStep ``revocation_list.txt``."""

    values = set()
    for line in Path(path).read_text(encoding="ascii").splitlines():
        value = line.split("#", 1)[0].strip().lower()
        if value:
            values.add(value)
    return frozenset(values)


def is_revoked(case: SingleStepCase, revoked_hashes: Iterable[str]) -> bool:
    return case.test_hash is not None and case.test_hash.lower() in {item.lower() for item in revoked_hashes}

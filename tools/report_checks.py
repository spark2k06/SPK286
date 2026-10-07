"""Fail-closed helpers shared by the SingleStep report tools."""


def require(value, message):
    if not value:
        raise ValueError(message)


def unique_object(pairs):
    """JSON object hook that rejects duplicate field names."""
    result = {}
    for name, value in pairs:
        require(name not in result, f'duplicate JSON field {name}')
        result[name] = value
    return result

#!/usr/bin/env python3
"""Static regression checks for fail-closed root Keychain query construction."""

from collections import Counter
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]


def section(source: str, start: str, end: str) -> str:
    before, separator, remainder = source.partition(start)
    assert separator, f"missing section start: {start}"
    body, separator, _ = remainder.partition(end)
    assert separator, f"missing section end: {end}"
    return body


def security_calls(source: str) -> Counter[tuple[str, str]]:
    return Counter(
        re.findall(r"SecItem(CopyMatching|Update|Add|Delete)\((\w+)", source)
    )


app_attest_source = (ROOT / "Sources/LatchwayAppAttest/LatchwayAppAttestProvider.swift").read_text()
app_attest_store = section(
    app_attest_source,
    "private actor AppAttestKeychainStateStore",
    "enum AppAttestKeychainQuery",
)
app_attest_query = app_attest_source.partition("enum AppAttestKeychainQuery")[2]

assert security_calls(app_attest_store) == Counter(
    {
        ("CopyMatching", "query"): 2,
        ("Update", "identity"): 1,
        ("Add", "insertion"): 1,
        ("Delete", "query"): 1,
    }
), "every App Attest Security operation must remain covered by the grouped-query invariant"
assert app_attest_store.count("AppAttestKeychainQuery.identity(") == 4
assert "var insertion = identity" in app_attest_store
assert "kSecAttrAccessGroup: accessGroup" in app_attest_query

core_source = (ROOT / "Sources/Latchway/Persistence/KeychainStore.swift").read_text()
core_store = section(core_source, "actor LatchwayKeychainStore", "enum LatchwayKeychainQuery")
core_query = core_source.partition("enum LatchwayKeychainQuery")[2]

assert security_calls(core_store) == Counter(
    {
        ("CopyMatching", "query"): 1,
        ("Update", "identity"): 1,
        ("Add", "insertion"): 1,
        ("Delete", "query"): 1,
    }
), "every root key/session Security operation must remain covered by the grouped-query invariant"
assert core_store.count("LatchwayKeychainQuery.identity(") == 3
assert "var insertion = identity" in core_store
assert "kSecAttrAccessGroup: accessGroup" in core_query

print("root Keychain source invariants: ok")

"""SQLite TEST DOUBLE, not a blockchain, distributed ledger, or identity system.

ACL strings are synthetic configuration, not credentials. The local owner can
rewrite the database. Writer/reader use distinct connections, not independent
operators. No daemon, existing instance, socket or network is used.
"""
import json
import sqlite3
from pathlib import Path

from vape.contracts import canonical
from vape.ledger.service import validate_record


class SQLiteTestWriter:
    def __init__(self, path, chain_id, authority, allowed_namespaces):
        self.path = Path(path)
        self.chain_id = chain_id
        self.authority = authority
        self.allowed_namespaces = frozenset(allowed_namespaces)
        with sqlite3.connect(str(self.path)) as db:
            db.execute("CREATE TABLE IF NOT EXISTS anchors (chain_id TEXT, authority TEXT, namespace TEXT, sequence INTEGER, record TEXT NOT NULL, PRIMARY KEY(chain_id,authority,namespace,sequence))")

    def commit(self, record):
        record = validate_record(record)
        scope = (record["chainId"], record["authority"], record["namespace"])
        if scope[:2] != (self.chain_id, self.authority) or scope[2] not in self.allowed_namespaces:
            raise PermissionError("Test writer is not authorized for this chain/authority/namespace")
        with sqlite3.connect(str(self.path)) as db:
            db.execute("BEGIN IMMEDIATE")
            last = db.execute("SELECT MAX(sequence) FROM anchors WHERE chain_id=? AND authority=? AND namespace=?", scope).fetchone()[0] or 0
            if record["sequence"] != last + 1:
                raise ValueError("Duplicate, stale or skipped sequence")
            db.execute("INSERT INTO anchors VALUES (?,?,?,?,?)", scope + (record["sequence"], canonical(record).decode("utf-8")))


class SQLiteTestReader:
    def __init__(self, path, chain_id, authority, allowed_namespaces):
        self.path = Path(path)
        self.chain_id = chain_id
        self.authority = authority
        self.allowed_namespaces = frozenset(allowed_namespaces)

    def read(self, chain_id, authority, namespace, sequence):
        if (chain_id, authority) != (self.chain_id, self.authority) or namespace not in self.allowed_namespaces:
            raise PermissionError("Test reader is not authorized for this scope")
        # mode=ro guarantees a missing database cannot be silently initialized.
        with sqlite3.connect(self.path.resolve().as_uri() + "?mode=ro", uri=True) as db:
            row = db.execute("SELECT record FROM anchors WHERE chain_id=? AND authority=? AND namespace=? AND sequence=?",
                             (chain_id, authority, namespace, sequence)).fetchone()
        return None if row is None else {"record": json.loads(row[0]), "finalized": True}

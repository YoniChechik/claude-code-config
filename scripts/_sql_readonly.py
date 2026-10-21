import re
import sys

WHITESPACE = " \t\n\r\f\v"
DOLLAR_TAG = re.compile(
    r"\$([A-Za-z_\u0080-\U0010ffff][A-Za-z0-9_\u0080-\U0010ffff]*)?\$"
)
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_$]*")
NUMBER = re.compile(r"[0-9.][0-9A-Za-z_.]*")
OPS = set("()[],.:+-*/<>=~!@#%^&|`?")

BODY_STARTERS = {"select", "with", "table", "values", "show", "explain"}
QUERY_WORDS = {"select", "with", "table", "values"}

DENY_WORDS = {
    "insert",
    "update",
    "delete",
    "merge",
    "truncate",
    "create",
    "alter",
    "drop",
    "grant",
    "revoke",
    "vacuum",
    "analyze",
    "analyse",
    "refresh",
    "lock",
    "notify",
    "listen",
    "unlisten",
    "copy",
    "call",
    "do",
    "prepare",
    "execute",
    "deallocate",
    "declare",
    "set",
    "reset",
    "begin",
    "commit",
    "rollback",
    "abort",
    "savepoint",
    "release",
    "discard",
    "checkpoint",
    "cluster",
    "reindex",
    "load",
    "import",
    "security",
    "authorization",
    "session",
    "transaction",
    "characteristics",
    "write",
    "into",
    "share",
    "returning",
    "program",
    "default_transaction_read_only",
    "transaction_read_only",
}

DENY_FUNCS = {
    "nextval",
    "setval",
    "set_config",
    "pg_notify",
    "query_to_xml",
    "query_to_xmlschema",
    "query_to_xml_and_xmlschema",
    "cursor_to_xml",
    "cursor_to_xmlschema",
    "ts_stat",
    "pg_promote",
    "pg_stat_file",
    "pg_start_backup",
    "pg_stop_backup",
    "pg_current_logfile",
}

DENY_PREFIXES = (
    "pg_advisory",
    "pg_try_advisory",
    "lo_",
    "dblink",
    "pg_background",
    "http",
    "pg_read_",
    "pg_ls_",
    "pg_file_",
    "pg_terminate_",
    "pg_cancel_",
    "pg_signal_",
    "pg_reload_",
    "pg_rotate_",
    "pg_switch_",
    "pg_create_",
    "pg_drop_",
    "pg_copy_",
    "pg_replication_",
    "pg_logical_",
    "pg_stat_reset",
    "pg_stat_statements_reset",
    "pg_wal_",
    "pg_xlog_",
    "pg_backup_",
    "pg_import_",
    "pg_log_",
    "pg_sync_",
    "pg_clear_",
    "pg_restore_",
    "pg_set_",
    "pg_buffercache_evict",
    "pg_truncate_",
    "pg_prewarm",
    "pg_export_snapshot",
    "postgres_fdw_",
    "pg_stat_force_next_flush",
    "pg_stat_clear_snapshot",
)

BEGIN_MODE_WORDS = {
    "read",
    "only",
    "isolation",
    "level",
    "serializable",
    "repeatable",
    "committed",
    "uncommitted",
    "deferrable",
    "not",
}


SIDE_EFFECT_CALL = re.compile(
    r"(^|_)(reset|evict|flush|terminate|cancel|signal|kill|notify|lock|unlock|advisory|exec|execute"
    r"|launch|send|schedule|unschedule|purge|rotate|reload|promote|replay|enqueue|dequeue|publish"
    r"|request|write|http)(_|$)"
)


class Reject(Exception):
    pass


def skip_string(s, i):
    n = len(s)
    while i < n:
        if s[i] == "'":
            if i + 1 < n and s[i + 1] == "'":
                i += 2
                continue
            return i + 1
        i += 1
    raise Reject("unterminated string literal")


def tokenize(s):
    toks = []
    i = 0
    n = len(s)
    while i < n:
        c = s[i]
        if c in WHITESPACE:
            i += 1
        elif s.startswith("--", i):
            while i < n and s[i] not in "\r\n":
                i += 1
        elif s.startswith("/*", i):
            depth = 0
            while True:
                if i >= n:
                    raise Reject("unterminated /* comment")
                if s.startswith("/*", i):
                    depth += 1
                    i += 2
                elif s.startswith("*/", i):
                    depth -= 1
                    i += 2
                    if depth == 0:
                        break
                else:
                    i += 1
        elif c == "'":
            i = skip_string(s, i + 1)
            toks.append(("str", ""))
        elif c == '"':
            j = i + 1
            buf = []
            while True:
                if j >= n:
                    raise Reject("unterminated quoted identifier")
                if s[j] == '"':
                    if j + 1 < n and s[j + 1] == '"':
                        buf.append('"')
                        j += 2
                        continue
                    break
                buf.append(s[j])
                j += 1
            if not buf:
                raise Reject("empty quoted identifier")
            toks.append(("ident", "".join(buf).lower()))
            i = j + 1
        elif c == "$":
            m = DOLLAR_TAG.match(s, i)
            if not m:
                raise Reject(
                    "`$` outside a dollar-quoted string (parameters and variables are not allowed)"
                )
            delim = m.group(0)
            end = s.find(delim, m.end())
            if end < 0:
                raise Reject("unterminated dollar-quoted string")
            toks.append(("str", ""))
            i = end + len(delim)
        elif WORD.match(s, i):
            m = WORD.match(s, i)
            w = m.group(0).lower()
            i = m.end()
            if i < n and s[i] == "'" and w in ("e", "b", "x", "n"):
                i = skip_string(s, i + 1)
                toks.append(("str", ""))
            elif i < n and s[i] == "&" and w == "u":
                raise Reject("U& unicode-escape literals are not allowed")
            else:
                toks.append(("word", w))
        elif (
            c.isascii()
            and c.isdigit()
            or c == "."
            and i + 1 < n
            and s[i + 1].isascii()
            and s[i + 1].isdigit()
        ):
            m = NUMBER.match(s, i)
            toks.append(("num", m.group(0)))
            i = m.end()
        elif c == ";":
            toks.append(("semi", ";"))
            i += 1
        elif c in OPS:
            toks.append(("op", c))
            i += 1
        else:
            raise Reject(
                "character %r is not allowed outside string literals and quoted identifiers"
                % c
            )
    return toks


def split_statements(toks):
    stmts = [[]]
    for t in toks:
        if t[0] == "semi":
            stmts.append([])
        else:
            stmts[-1].append(t)
    if not stmts[-1]:
        stmts.pop()
    for st in stmts:
        if not st:
            raise Reject("empty statement")
    return stmts


def words(st):
    if any(t[0] not in ("word", "op") for t in st):
        return None
    return [t[1] for t in st]


def is_pre(st):
    w = words(st)
    if w is None:
        return False
    if w in (
        ["set", "session", "characteristics", "as", "transaction", "read", "only"],
    ):
        return True
    if w and w[0] == "set":
        rest = w[1:]
        if rest and rest[0] == "session":
            rest = rest[1:]
        return (
            len(rest) == 3
            and rest[0] == "default_transaction_read_only"
            and rest[1] in ("=", "to")
            and rest[2] in ("on", "true")
        )
    return False


def is_begin(st):
    w = words(st)
    if not w:
        return False
    if w[0] == "begin":
        modes = w[1:]
        if modes and modes[0] in ("transaction", "work"):
            modes = modes[1:]
    elif w[:2] == ["start", "transaction"]:
        modes = w[2:]
    else:
        return False
    if any(m not in BEGIN_MODE_WORDS and m != "," for m in modes):
        return False
    return any(
        modes[k] == "read" and modes[k + 1] == "only" for k in range(len(modes) - 1)
    )


def is_end(st):
    w = words(st)
    if not w or w[0] not in ("commit", "rollback"):
        return False
    return w[1:] in ([], ["work"], ["transaction"])


def check_name(name, where):
    if name in DENY_WORDS:
        return "`%s` is not allowed (%s)" % (name, where)
    if name in DENY_FUNCS or name.startswith(DENY_PREFIXES):
        return "`%s` has side effects outside the read-only transaction (%s)" % (
            name,
            where,
        )
    return None


def check_body(st, idx):
    first = st[0]
    if first[0] != "word" or first[1] not in BODY_STARTERS:
        return (
            "statement %d must start with SELECT, WITH, TABLE, VALUES, SHOW or EXPLAIN"
            % idx
        )
    explain = first[1] == "explain"
    seen_query = False
    for pos, t in enumerate(st[1:], start=1):
        if t[0] not in ("word", "ident"):
            continue
        name = t[1]
        if (
            pos + 1 < len(st)
            and st[pos + 1] == ("op", "(")
            and SIDE_EFFECT_CALL.search(name)
        ):
            return "`%s(` looks like a function with side effects (statement %d)" % (
                name,
                idx,
            )
        if t[0] == "word" and name in QUERY_WORDS:
            seen_query = True
        if (
            explain
            and not seen_query
            and t[0] == "word"
            and name in ("analyze", "analyse")
        ):
            continue
        err = check_name(name, "statement %d" % idx)
        if err:
            return err
    return None


def validate(sql):
    if "\x00" in sql:
        raise Reject("NUL byte in SQL")
    if "\\" in sql:
        raise Reject(
            "backslashes are not allowed (psql meta-commands and escape strings)"
        )
    stmts = split_statements(tokenize(sql))
    i = 0
    while i < len(stmts) and is_pre(stmts[i]):
        i += 1
    if i >= len(stmts) or not is_begin(stmts[i]):
        raise Reject(
            "the first statement (after optional SET default_transaction_read_only = on) must be BEGIN READ ONLY / START TRANSACTION READ ONLY"
        )
    body = stmts[i + 1 : -1]
    if len(stmts) < i + 3:
        raise Reject(
            "expected BEGIN READ ONLY, at least one query, then COMMIT or ROLLBACK"
        )
    if not is_end(stmts[-1]):
        raise Reject(
            "the last statement must be COMMIT or ROLLBACK, and nothing may follow it"
        )
    for k, st in enumerate(body, start=i + 2):
        err = check_body(st, k)
        if err:
            raise Reject(err)


def main():
    raw = sys.stdin.buffer.read()
    try:
        sql = raw.decode("utf-8")
    except UnicodeDecodeError:
        print("SQL is not valid UTF-8")
        return 1
    try:
        validate(sql)
    except Reject as e:
        print(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

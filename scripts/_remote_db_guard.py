import json
import re
import shlex
import sys
from urllib.parse import parse_qsl, unquote

DYN = "\ufffd"
PG_TOOLS = {"psql", "pgcli", "pg_dump", "pg_dumpall", "pg_restore"}
LOCAL_HOSTS = {"", "localhost", "127.0.0.1", "::1", "[::1]"}
LOCAL_HOSTADDRS = {"", "127.0.0.1", "::1"}

SPECS = {
    "psql": {
        "short": "cdfhLopPRTUvF",
        "long": {
            "command": "c",
            "dbname": "d",
            "file": "f",
            "host": "h",
            "log-file": "L",
            "output": "o",
            "port": "p",
            "pset": "P",
            "record-separator": "R",
            "table-attr": "T",
            "username": "U",
            "set": "v",
            "variable": "v",
            "field-separator": "F",
        },
        "flags": [
            "echo-all",
            "no-align",
            "csv",
            "echo-errors",
            "echo-queries",
            "echo-hidden",
            "html",
            "list",
            "no-readline",
            "single-step",
            "single-line",
            "tuples-only",
            "expanded",
            "no-psqlrc",
            "single-transaction",
            "help",
            "version",
            "quiet",
            "no-password",
            "password",
            "record-separator-zero",
            "field-separator-zero",
        ],
        "conn": "d",
        "positional_conn": True,
    },
    "pg_dump": {
        "short": "dhpUfFjnNtTZESe",
        "long": {
            "dbname": "d",
            "host": "h",
            "port": "p",
            "username": "U",
            "file": "f",
            "format": "F",
            "jobs": "j",
            "schema": "n",
            "exclude-schema": "N",
            "table": "t",
            "exclude-table": "T",
            "compress": "Z",
            "encoding": "E",
            "superuser": "S",
            "extension": "e",
            "role": "",
            "lock-wait-timeout": "",
            "exclude-table-data": "",
            "extra-float-digits": "",
            "section": "",
            "snapshot": "",
            "filter": "",
            "exclude-extension": "",
            "include-foreign-data": "",
            "rows-per-insert": "",
            "table-and-children": "",
            "exclude-table-and-children": "",
            "exclude-table-data-and-children": "",
        },
        "flags": [],
        "conn": "d",
        "positional_conn": True,
    },
    "pg_dumpall": {
        "short": "dhpUflS",
        "long": {
            "dbname": "d",
            "host": "h",
            "port": "p",
            "username": "U",
            "file": "f",
            "database": "l",
            "superuser": "S",
            "role": "",
            "lock-wait-timeout": "",
            "exclude-database": "",
            "extra-float-digits": "",
            "filter": "",
            "rows-per-insert": "",
        },
        "flags": [],
        "conn": "dl",
        "positional_conn": True,
    },
    "pg_restore": {
        "short": "dhpUfFjnNtTIPLSe",
        "long": {
            "dbname": "d",
            "host": "h",
            "port": "p",
            "username": "U",
            "file": "f",
            "format": "F",
            "jobs": "j",
            "schema": "n",
            "exclude-schema": "N",
            "table": "t",
            "trigger": "T",
            "index": "I",
            "function": "P",
            "use-list": "L",
            "superuser": "S",
            "role": "",
            "section": "",
            "filter": "",
        },
        "flags": [],
        "conn": "d",
        "positional_conn": False,
    },
    "pgcli": {
        "short": "hpUudDR",
        "long": {
            "host": "h",
            "port": "p",
            "username": "U",
            "user": "U",
            "dbname": "d",
            "dsn": "D",
            "row-limit": "R",
            "prompt": "",
            "prompt-dsn": "",
            "application-name": "",
            "log-file": "",
            "pgclirc": "",
            "ssh-tunnel": "!",
            "init-command": "",
        },
        "flags": [],
        "conn": "d",
        "positional_conn": True,
        "exact_long": True,
        "deny_short": "D",
    },
}

PSQL_META_DENY = [
    re.compile(r"\\(?:setenv|!)"),
    re.compile(r"\\(?:o|out|g|gx|w|write)\s*\|"),
    re.compile(r"\\copy\b[^\n]*\bprogram\b", re.IGNORECASE),
]
PSQL_CONNECT = re.compile(r"\\(?:c|connect)(?![A-Za-z_])([^\n\\]*)")
STRICT = True
PG_EMBEDDED = re.compile(
    r"(?:^|[\s/=!\"'(;&|`])(psql|pgcli|pg_dump|pg_dumpall|pg_restore)(?=[\s\"';)&|`]|$)",
    re.IGNORECASE,
)
SHELL_OPS = {";", "&", "|", "&&", "||", "(", ")", ";;", "|&"}


class Deny(Exception):
    pass


def is_dynamic(word):
    return DYN in word or "$" in word or "`" in word


def check_hosts(value, what, allowed):
    if is_dynamic(value):
        if not STRICT:
            return
        raise Deny(f"the {what} is built from a variable or command substitution")
    for part in value.split(","):
        host = part.strip().lower()
        if host in allowed or (allowed is LOCAL_HOSTS and host.startswith("/")):
            continue
        raise Deny(
            f"the {what} {part.strip()!r} is not 127.0.0.1, localhost, ::1 or a unix socket"
        )


def parse_conninfo(text):
    pairs = []
    i, n = 0, len(text)
    while True:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            return pairs
        start = i
        while i < n and text[i] != "=" and not text[i].isspace():
            i += 1
        key = text[start:i]
        while i < n and text[i].isspace():
            i += 1
        if i >= n or text[i] != "=" or not key:
            return None
        i += 1
        while i < n and text[i].isspace():
            i += 1
        value = []
        if i < n and text[i] == "'":
            i += 1
            while True:
                if i >= n:
                    return None
                ch = text[i]
                if ch == "\\" and i + 1 < n:
                    value.append(text[i + 1])
                    i += 2
                    continue
                if ch == "'":
                    i += 1
                    break
                value.append(ch)
                i += 1
        else:
            while i < n and not text[i].isspace():
                ch = text[i]
                if ch == "\\" and i + 1 < n:
                    value.append(text[i + 1])
                    i += 2
                    continue
                value.append(ch)
                i += 1
        pairs.append((key, "".join(value)))


def check_conn_pairs(pairs):
    for key, value in pairs:
        k = key.lower()
        if k == "service":
            raise Deny(
                "a connection service (service=) points at a pg_service.conf entry the guard cannot read"
            )
        if k == "host":
            check_hosts(value, "host", LOCAL_HOSTS)
        elif k == "hostaddr":
            check_hosts(value, "hostaddr", LOCAL_HOSTADDRS)
        elif k == "dbname" and ("=" in value or "://" in value):
            check_conn(value)


def check_uri(word):
    rest = word.split("://", 1)[1]
    query = ""
    if "?" in rest:
        rest, query = rest.split("?", 1)
    authority = rest.split("/", 1)[0]
    hostspec = authority.rsplit("@", 1)[1] if "@" in authority else authority
    for part in re.split(r",", hostspec):
        host = unquote(part)
        if host.startswith("["):
            host = host.split("]", 1)[0] + "]"
        else:
            host = host.rsplit(":", 1)[0] if ":" in host else host
        check_hosts(host, "URI host", LOCAL_HOSTS)
    for key, value in parse_qsl(query, keep_blank_values=True):
        check_conn_pairs([(key, value)])


def check_conn(word):
    low = word.strip().lower()
    if is_dynamic(word):
        if not STRICT:
            return
        raise Deny(
            "a connection string is built from a variable or command substitution"
        )
    if re.match(r"^postgres(?:ql)?://", low):
        check_uri(word.strip())
        return
    if "postgres://" in low or "postgresql://" in low:
        raise Deny("a connection string embeds a postgres:// URI")
    if "=" not in word:
        return
    pairs = parse_conninfo(word)
    if pairs is None:
        if re.search(r"(host|hostaddr|service)\s*=", low):
            raise Deny(
                "a connection string the guard cannot parse names a host or service"
            )
        return
    check_conn_pairs(pairs)


def check_meta(text):
    for rx in PSQL_META_DENY:
        if rx.search(text):
            raise Deny(
                "psql meta-commands that run a shell or set its environment (\\!, \\setenv, \\o |, \\g |, \\w |, \\copy ... program) are blocked"
            )
    if "`" in text and re.search(r"\\[A-Za-z]", text):
        raise Deny("a psql meta-command with a backtick runs a shell command")
    for m in PSQL_CONNECT.finditer(text):
        args = [
            a for a in split_embedded(m.group(1)) if not a.startswith("-reuse-previous")
        ]
        for a in args:
            if a.startswith(":"):
                raise Deny("a psql \\connect target is built from a psql variable")
        if args:
            check_conn(args[0])
        if len(args) >= 3 and args[2] != "-":
            check_hosts(args[2], "\\connect host", LOCAL_HOSTS)


def resolve_long(spec, name):
    longs = spec["long"]
    if name in longs:
        return name
    if spec.get("exact_long"):
        return None
    if name in spec["flags"]:
        return name
    cands = [k for k in list(longs) + spec["flags"] if k.startswith(name)]
    if len(cands) == 1:
        return cands[0]
    return None


NO_CONNECT = {"--help", "--version", "-?"}


def check_pg_argv(tool, args, dyn, env, strict):
    spec = SPECS[tool]
    no_connect = NO_CONNECT if tool == "pgcli" else NO_CONNECT | {"-V"}
    if any(a in no_connect for a in args):
        return
    if "PGHOST" in env:
        check_hosts(env["PGHOST"], "$PGHOST", LOCAL_HOSTS)
    if "PGHOSTADDR" in env:
        check_hosts(env["PGHOSTADDR"], "$PGHOSTADDR", LOCAL_HOSTADDRS)
    if env.get("PGSERVICE", ""):
        raise Deny("$PGSERVICE selects a pg_service.conf entry the guard cannot read")
    for key in ("PGDATABASE", "DATABASE_URL"):
        if key in env:
            check_conn(env[key])
    if strict:
        for word, d in zip(args, dyn):
            if d or DYN in word:
                raise Deny(
                    "an argument is built from a variable, glob or command substitution, so the target cannot be proven local"
                )
    opts = []
    positionals = []
    i, n = 0, len(args)
    while i < n:
        word = args[i]
        if word == "--":
            positionals.extend(args[i + 1 :])
            break
        if word.startswith("--") and len(word) > 2:
            name, eq, value = word[2:].partition("=")
            full = resolve_long(spec, name)
            letter = spec["long"].get(full) if full else None
            if full and full in spec["long"]:
                if not eq:
                    i += 1
                    value = args[i] if i < n else ""
                opts.append((letter if letter else full, value))
            i += 1
            continue
        if word.startswith("-") and len(word) > 1:
            body = word[1:]
            for j, ch in enumerate(body):
                if ch in spec.get("deny_short", ""):
                    opts.append((ch, ""))
                if ch in spec["short"]:
                    value = body[j + 1 :]
                    if not value:
                        i += 1
                        value = args[i] if i < n else ""
                    opts.append((ch, value))
                    break
            i += 1
            continue
        positionals.append(word)
        i += 1
    for opt, value in opts:
        if opt == "!" or opt == "ssh-tunnel":
            raise Deny(
                f"{tool} --ssh-tunnel reaches a remote database through a tunnel"
            )
        if opt in spec.get("deny_short", ""):
            raise Deny(
                f"{tool} -D/--dsn reads a connection alias from a config file the guard cannot read"
            )
        if opt == "h":
            check_hosts(value, "host", LOCAL_HOSTS)
        elif opt in spec["conn"]:
            check_conn(value)
        elif tool == "psql" and opt == "c":
            check_meta(value)
    if spec["positional_conn"]:
        for word in positionals:
            check_conn(word)


MGMT_HOST = re.compile(
    r"(?<![a-z0-9.-])api\.supabase\.(?:com|io)\.?(?=(?::[0-9]*)?(?:[/?#]|$))"
)
PG_ENV_NAMES = ("PGHOST", "PGHOSTADDR", "PGSERVICE", "PGDATABASE")
PG_ENV_ASSIGN = re.compile(
    r"(?<![A-Za-z0-9_$])(PGHOST|PGHOSTADDR|PGSERVICE|PGDATABASE)=(\"[^\"]*\"|'[^']*'|[^\s;&|)]*)"
)
PG_ENV_OTHER = re.compile(
    r"(?<![A-Za-z0-9_${])(PGHOST|PGHOSTADDR|PGSERVICE|PGDATABASE)(?![A-Za-z0-9_=])"
)


def check_env_assignments(text):
    for m in PG_ENV_ASSIGN.finditer(text):
        name, value = m.group(1), m.group(2)
        if value[:1] in "\"'" and value[-1:] == value[:1] and len(value) >= 2:
            quote = value[0]
            value = value[1:-1]
            if quote == '"' and ("$" in value or "`" in value):
                raise Deny(f"{name} is set from a variable or command substitution")
        elif "$" in value or "`" in value:
            raise Deny(f"{name} is set from a variable or command substitution")
        check_pg_argv("psql", [], [], {name: value}, True)
    if PG_ENV_OTHER.search(text):
        raise Deny(
            "the command changes PGHOST, PGHOSTADDR, PGSERVICE or PGDATABASE in a way the guard cannot read"
        )


def normalize_url(word):
    text = word
    for _ in range(3):
        decoded = unquote(text)
        if decoded == text:
            break
        text = decoded
    text = text.lower().replace("\\", "/")
    text = re.sub(r"[{}\[\]]", "", text)
    text = re.sub(r"/+", "/", text)
    return text


def check_http_word(word, http_tool):
    text = normalize_url(word)
    m = MGMT_HOST.search(text)
    if m:
        tail = text[m.end() :]
        raw_tail = word[word.lower().find("supabase") :] if "supabase" in word.lower() else word
        if http_tool and re.search(r"[{}\[\]]", raw_tail):
            raise Deny(
                "it calls the Supabase Management API with a curl URL glob the guard does not expand"
            )
        if re.search(r"database|pg-meta|query|sql", tail):
            raise Deny(
                "it calls the Supabase Management API's database or SQL endpoints"
            )
        if http_tool and (DYN in tail or "$" in tail or "`" in tail):
            raise Deny(
                "it calls the Supabase Management API with a path built from a variable"
            )
    if re.search(r"/v1/projects/.*database", text) or "/platform/pg-meta/" in text:
        raise Deny("it calls the Supabase Management API's database or SQL endpoints")


def split_embedded(rest):
    try:
        lex = shlex.shlex(rest, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:
        tokens = rest.split()
    out = []
    for tok in tokens:
        if tok in SHELL_OPS or "\n" in tok:
            break
        out.append(tok)
    return out


def check_text(text):
    check_http_word(text, False)
    for m in PG_EMBEDDED.finditer(text):
        tool = m.group(1).lower()
        args = split_embedded(text[m.end() :])
        check_pg_argv(tool, args, [is_dynamic(a) for a in args], {}, True)


def main():
    global STRICT
    req = json.loads(sys.argv[1])
    words = sys.argv[2:]
    mode = req["mode"]
    STRICT = req.get("strict", True)
    try:
        if mode == "pg":
            check_pg_argv(
                req["tool"], words, req["dyn"], req["env"], req["strict"]
            )
        elif mode == "http":
            for word in words:
                check_http_word(word, req["http_tool"])
        elif mode == "text":
            for word in words:
                check_text(word)
        elif mode == "raw":
            for word in words:
                check_text(word)
            check_text(" ".join(words))
        elif mode == "env":
            check_env_assignments(words[0])
        elif mode == "meta":
            check_meta(words[0])
        else:
            print(f"unknown mode {mode}")
            return 2
    except Deny as e:
        print(str(e))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

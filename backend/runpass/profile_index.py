"""Search index for runners: prefix tokens of username and display name.

DynamoDB only answers prefix queries inside one partition, so each token lands in the
partition `PIDX#<first two letters>`. The owner keeps a SEARCHIDX row listing every shared
row it owns (`sharedKeys`), which lets account erasure remove them in the same commit.
"""

import re
import unicodedata

MIN_TOKEN = 2


def fold(text):
    """Lowercase ASCII without accents, so 'João' is found by 'joao'."""
    plain = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode()
    return plain.lower()


def tokens(text):
    return re.findall(r"[a-z0-9_]+", fold(text))


def profile_tokens(username, display_name):
    found = {username.lower(), *tokens(display_name), *tokens(username)}
    return {t for t in found if len(t) >= MIN_TOKEN}


def index_keys(subject, username, display_name):
    return {
        ("identity", "PIDX#" + token[:MIN_TOKEN], f"{token}#{subject}")
        for token in profile_tokens(username, display_name)
    }


def shared_keys(keys):
    return [list(key) for key in sorted(keys)]

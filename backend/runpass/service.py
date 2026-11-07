"""Identity/admission rules. Every decision is guarded by the same commit as its effects."""

import hashlib
import hmac
import json
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from uuid import uuid4
from zoneinfo import ZoneInfo

from .profile_index import index_keys, shared_keys
from .store import Conflict


class Problem(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


def utc_now():
    return datetime.now(timezone.utc)


def stamp(value):
    return value.isoformat().replace("+00:00", "Z")


class IdentityService:
    def __init__(
        self,
        store,
        erasure_key,
        clock=utc_now,
        environment="local",
        identity_namespace="local-runner",
    ):
        if len(erasure_key) < 32:
            raise ValueError("Erasure HMAC key requires at least 32 bytes")
        self.store, self.clock, self.erasure_key = store, clock, erasure_key
        self.environment = environment
        self.identity_namespace = identity_namespace

    def erasure(self, subject):
        digest = hmac.new(
            self.erasure_key,
            f"{self.environment}:{self.identity_namespace}:{subject}".encode(),
            hashlib.sha256,
        ).hexdigest()
        return ("erasure", "ERASURE#v1#" + digest, "CONTROL")

    def transact(self, principal, operation, key, body, work, admitted=False):
        if principal.audience != "runner":
            raise Problem(403, "RUNNER_REQUIRED")
        fingerprint = hashlib.sha256(
            json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        ).hexdigest()
        pk = "USER#" + principal.subject
        cmd = (
            ("operations", pk, "CMD#" + operation + "#" + hashlib.sha256(key.encode()).hexdigest())
            if key is not None
            else None
        )
        for _ in range(20):
            expected, writes = {}, {}

            def read(k):
                if k not in expected:
                    expected[k] = self.store.get(k)
                return deepcopy(expected[k])

            def write(k, value):
                read(k)
                writes[k] = value

            now = self.clock()
            account_key = ("identity", pk, "ACCOUNT")
            account = read(account_key)
            erased = read(self.erasure(principal.subject))
            if (erased and erased["expiresAt"] > int(now.timestamp())) or (
                account and account.get("state") != "active"
            ):
                raise Problem(403, "ACCOUNT_UNAVAILABLE")
            if admitted and (not account or not account.get("admitted")):
                raise Problem(403, "BETA_ADMISSION_REQUIRED")
            previous = read(cmd) if cmd else None
            replay = previous and previous["expiresAt"] > int(now.timestamp())
            if replay and previous["fingerprint"] != fingerprint:
                raise Problem(409, "IDEMPOTENCY_CONFLICT")
            result, receipt = work(
                read, write, account, now, previous["receipt"] if replay else None
            )
            if cmd and not replay:
                write(
                    cmd,
                    {
                        "fingerprint": fingerprint,
                        "receipt": receipt,
                        "expiresAt": int((now + timedelta(days=7)).timestamp()),
                    },
                )
            try:
                self.store.commit(expected, writes)
                return result
            except Conflict:
                continue
        raise Problem(503, "CONCURRENT_RETRY_REQUIRED")

    def profile(self, principal):
        def work(read, write, account, now, replay):
            result = read(("identity", "USER#" + principal.subject, "PROFILE"))
            if not result:
                raise Problem(404, "PROFILE_NOT_FOUND")
            # Profiles created before search existed are indexed the next time their owner opens.
            self._sync_index(read, write, principal.subject, result)
            body = self.public_profile(result)
            # Data de nascimento: so no GET /me do proprio titular (decisao 06/11/2026);
            # public_profile() e as demais rotas nunca recebem esse campo.
            private = read(("identity", "USER#" + principal.subject, "PRIVATE"))
            if private and private.get("birthDate"):
                body["birthDate"] = private["birthDate"]
            return body, {}

        return self.transact(principal, "getOwnProfile", None, {}, work)

    @staticmethod
    def public_profile(profile):
        return {
            k: profile[k]
            for k in (
                "id",
                "displayName",
                "username",
                "version",
                "city",
                "bio",
                "photoReference",
                "bannerReference",
                "isPrivate",
            )
            if k in profile
        }

    @staticmethod
    def _sync_index(read, write, subject, profile):
        """Keep the search rows and the owner's SEARCHIDX pointer equal to the profile."""
        pointer = ("identity", "USER#" + subject, "SEARCHIDX")
        old = {tuple(k) for k in (read(pointer) or {}).get("sharedKeys", [])}
        new = index_keys(subject, profile["username"], profile["displayName"])
        if old == new:
            return
        for key in old - new:
            write(key, None)
        for key in new - old:
            write(key, {"owner": subject})
        write(pointer, {"sharedKeys": shared_keys(new)})

    def authorize(self, principal, admitted=False):
        # A read-only optimistic transaction makes account/erasure checks one atomic boundary.
        def check(read, write, account, now, replay):
            return None, {}

        self.transact(principal, "authorize", None, {}, check, admitted)

    def create_profile(self, principal, key, payload):
        if not principal.verified_email:
            raise Problem(403, "EMAIL_NOT_VERIFIED")
        pk = "USER#" + principal.subject

        def work(read, write, account, now, replay):
            profile_key = ("identity", pk, "PROFILE")
            profile = read(profile_key)
            if replay is not None:
                if not profile:
                    raise Problem(404, "PROFILE_NOT_FOUND")
                return self.public_profile(profile), {}
            if profile or account:
                raise Problem(409, "PROFILE_EXISTS")
            username = payload["username"].lower()
            claim = ("identity", "USERNAME#" + username, "CLAIM")
            if read(claim):
                raise Problem(409, "USERNAME_TAKEN")
            profile = {
                "id": principal.subject,
                "displayName": payload["displayName"],
                "username": username,
                "version": 1,
            }
            write(claim, {"owner": principal.subject})
            write(("identity", pk, "ACCOUNT"), {"state": "active", "admitted": False})
            write(profile_key, profile)
            self._sync_index(read, write, principal.subject, profile)
            return self.public_profile(profile), {}

        return self.transact(principal, "createOwnProfile", key, payload, work)

    @staticmethod
    def _swap_profile_photo(read, write, subject, profile, payload, field="photoReference"):
        """The image must be valid and uploaded by this runner; reference counts follow."""
        reference = payload[field]
        if reference == profile.get(field):
            return
        if reference is not None:
            new_key = ("operations", "USER#" + subject, "IMAGE#" + reference)
            new = read(new_key)
            if not new or new.get("state") != "valid" or new.get("owner") != subject:
                raise Problem(422, "IMAGE_NOT_VALID")
            write(new_key, {**new, "refs": new.get("refs", 0) + 1})
        previous = profile.get(field)
        if previous:
            old_key = ("operations", "USER#" + subject, "IMAGE#" + previous)
            old = read(old_key)
            if old:
                write(old_key, {**old, "refs": max(0, old.get("refs", 0) - 1)})

    def patch_profile(self, principal, key, payload):
        pk = "USER#" + principal.subject

        def work(read, write, account, now, replay):
            pkey = ("identity", pk, "PROFILE")
            profile = read(pkey)
            if not profile:
                raise Problem(404, "PROFILE_NOT_FOUND")
            if replay is not None:
                return self.public_profile(profile), {}
            if profile["version"] != payload["expectedVersion"]:
                raise Problem(409, "VERSION_CONFLICT")
            for field in ("photoReference", "bannerReference"):
                if field in payload:
                    self._swap_profile_photo(
                        read, write, principal.subject, profile, payload, field
                    )
            new_username = payload.get("username", profile["username"]).lower()
            if new_username != profile["username"]:
                new = ("identity", "USERNAME#" + new_username, "CLAIM")
                old = ("identity", "USERNAME#" + profile["username"], "CLAIM")
                if read(new):
                    raise Problem(409, "USERNAME_TAKEN")
                if not read(old) or read(old)["owner"] != principal.subject:
                    raise Problem(503, "USERNAME_INTEGRITY_FAILURE")
                write(new, {"owner": principal.subject})
                write(old, None)
            for name, value in payload.items():
                if name == "expectedVersion":
                    continue
                if value is None:
                    profile.pop(name, None)
                else:
                    profile[name] = value.strip() if name == "displayName" else value
            profile["username"] = new_username
            profile["version"] += 1
            write(pkey, profile)
            self._sync_index(read, write, principal.subject, profile)
            return self.public_profile(profile), {}

        return self.transact(principal, "patchOwnProfile", key, payload, work, admitted=True)

    def status(self, principal):
        def work(read, write, account, now, replay):
            control = read(("identity", "BETA#v1", "CONTROL")) or {"count": 0}
            profile = read(("identity", "USER#" + principal.subject, "PROFILE"))
            if profile and account and account.get("state") == "active":
                # Runs at every sign-in, so profiles created before search existed become findable.
                self._sync_index(read, write, principal.subject, profile)
            waiting = read(("identity", "USER#" + principal.subject, "WAITLIST"))
            closed = bool(
                control.get("endsAt") and now >= datetime.fromisoformat(control["endsAt"])
            )
            state = (
                "admitted"
                if (account or {}).get("admitted")
                else ("waiting" if waiting else "closed" if closed else "not_admitted")
            )
            result = {"myStatus": state, "admissionsOpen": not closed and control["count"] < 1000}
            if control.get("endsAt"):
                result["betaEndsAt"] = control["endsAt"]
            return result, {}

        return self.transact(principal, "getMyBetaStatus", None, {}, work)

    @staticmethod
    def eligible(payload, now):
        birth = datetime.strptime(payload["birthDate"], "%Y-%m-%d").date()
        today = now.astimezone(ZoneInfo("America/Sao_Paulo")).date()
        age = today.year - birth.year - ((today.month, today.day) < (birth.month, birth.day))
        if birth > today or age < 18 or payload["declaresAdult"] is not True:
            raise Problem(422, "NOT_ELIGIBLE")

    def admit(self, principal, key, payload, waitlist=False):
        if not principal.verified_email:
            raise Problem(403, "EMAIL_NOT_VERIFIED")
        pk = "USER#" + principal.subject

        def work(read, write, account, now, replay):
            if not account:
                raise Problem(409, "PROFILE_REQUIRED")
            self.eligible(payload, now)
            ckey = ("identity", "BETA#v1", "CONTROL")
            control = read(ckey) or {"count": 0}
            akey, wkey = ("identity", pk, "ADMISSION"), ("identity", pk, "WAITLIST")
            admission, waiting = read(akey), read(wkey)
            closed = control.get("endsAt") and now >= datetime.fromisoformat(control["endsAt"])
            if waitlist:
                if admission:
                    raise Problem(409, "ALREADY_ADMITTED")
                if replay is not None and not waiting:
                    return {**replay, "state": "removed"}, replay
                if waiting:
                    return self.waitlist_view(waiting), self.waitlist_view(waiting)
                if closed:
                    raise Problem(409, "BETA_CLOSED")
                if control["count"] < 1000:
                    raise Problem(409, "CAPACITY_AVAILABLE")
                waiting = {"id": str(uuid4()), "state": "waiting", "createdAt": stamp(now)}
                write(wkey, waiting)
                return waiting, self.waitlist_view(waiting)
            if admission:
                result = {"admitted": True, "admittedAt": admission["admittedAt"]}
                if control.get("endsAt"):
                    result["betaEndsAt"] = control["endsAt"]
                return result, {}
            if replay is not None:
                raise Problem(409, "ADMISSION_INTEGRITY_FAILURE")
            if closed:
                raise Problem(409, "BETA_CLOSED")
            if control["count"] >= 1000:
                raise Problem(409, "BETA_FULL")
            control["count"] += 1
            if control["count"] == 50:
                control["startedAt"], control["endsAt"] = (
                    stamp(now),
                    stamp(now + timedelta(days=60)),
                )
            write(ckey, control)
            write(akey, {"admittedAt": stamp(now)})
            account["admitted"] = True
            write(("identity", pk, "ACCOUNT"), account)
            write(("identity", pk, "PRIVATE"), {"birthDate": payload["birthDate"]})
            if waiting:
                write(wkey, None)
            result = {"admitted": True, "admittedAt": stamp(now)}
            if control.get("endsAt"):
                result["betaEndsAt"] = control["endsAt"]
            return result, {}

        operation = "joinBetaWaitlist" if waitlist else "admitToBeta"
        return self.transact(principal, operation, key, payload, work)

    @staticmethod
    def waitlist_view(item):
        return {k: item[k] for k in ("id", "state", "createdAt")}

    def waitlist(self, principal):
        def work(read, write, account, now, replay):
            result = read(("identity", "USER#" + principal.subject, "WAITLIST"))
            if not result:
                raise Problem(404, "WAITLIST_NOT_FOUND")
            return self.waitlist_view(result), {}

        return self.transact(principal, "getMyWaitlistEntry", None, {}, work)

    def remove_waitlist(self, principal, key):
        def work(read, write, account, now, replay):
            if replay is not None:
                return None, {}
            k = ("identity", "USER#" + principal.subject, "WAITLIST")
            write(k, None)
            return None, {}

        return self.transact(principal, "removeMyWaitlistEntry", key, {}, work)

    def delete_account(self, principal, key):
        def work(read, write, account, now, replay):
            operation = str(uuid4())
            pk = "USER#" + principal.subject
            profile = read(("identity", pk, "PROFILE"))
            work_pk = "WORK#erase_account#pending#" + str(int(operation[:2], 16) % 16)
            work_sk = stamp(now) + "#" + operation
            write(("identity", pk, "ACCOUNT"), {**(account or {}), "state": "deleting"})
            write(
                self.erasure(principal.subject),
                {
                    "acceptedAt": stamp(now),
                    "expiresAt": int((now + timedelta(days=15)).timestamp()),
                    "expiryPK": "EXPIRY#" + (now + timedelta(days=15)).date().isoformat(),
                    "expirySK": stamp(now + timedelta(days=15)),
                },
            )
            write(
                ("operations", pk, "JOB#" + operation),
                {
                    "state": "pending",
                    "type": "erase_account",
                    "acceptedAt": stamp(now),
                    "dueAt": stamp(now + timedelta(days=7)),
                    "workPK": work_pk,
                    "workSK": work_sk,
                    "stage": "compensate",
                    "username": profile.get("username") if profile else None,
                },
            )
            write(
                ("operations", work_pk, work_sk),
                {
                    "owner": principal.subject,
                    "operationId": operation,
                    "state": "pending",
                },
            )
            return {
                "operationId": operation,
                "state": "accepted",
                "accessBlocked": True,
                "publiclyHidden": True,
            }, {}

        return self.transact(principal, "deleteOwnAccount", key, {}, work)

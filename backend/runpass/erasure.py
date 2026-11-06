"""Retriable local account erasure executor; real scheduling and restore proof belong to S09."""

from copy import deepcopy

from .service import Problem, stamp
from .store import Conflict, iter_partition

MAX_ROWS = 90


class ErasureProcessor:
    """`external` holds destinations with delete_owner(owner), such as the identity directory."""

    def __init__(self, identity, blobs=None, external=(), audit=None):
        self.identity, self.store, self.blobs = identity, identity.store, blobs
        self.external, self.audit = external, audit

    def run_pending(self, max_steps=200, limit=50):
        """Advance accepted jobs; unfinished ones stay durable and resume on the next run."""
        completed, pending = 0, 0
        for shard in range(16):
            for _, marker in iter_partition(
                self.store, "operations", f"WORK#erase_account#pending#{shard}"
            ):
                state = "pending"
                while state != "completed" and max_steps > 0:
                    max_steps -= 1
                    state = self.step(marker["owner"], marker["operationId"], limit)["state"]
                completed += state == "completed"
                pending += state != "completed"
        return {"completed": completed, "pending": pending}

    def step(self, owner, operation_id, limit=50):
        pk = "USER#" + owner
        job_key = ("operations", pk, "JOB#" + operation_id)
        job = self.store.get(job_key)
        if not job or job.get("type") != "erase_account":
            raise Problem(404, "ERASURE_JOB_NOT_FOUND")
        if job["state"] == "completed":
            return {"state": "completed"}
        if job.get("stage") == "compensate":
            rows, _ = self.store.query("projections", pk, prefix="CONTRIBUTION#", limit=limit)
            if rows:
                for sk, contribution in rows:
                    self._remove_contribution(pk, sk, contribution)
                return {"state": "pending", "stage": "compensate"}
            self._update_job(job_key, job, "erase")
            return {"state": "pending", "stage": "erase"}
        return self._erase(owner, job_key, job, limit)

    def _remove_contribution(self, pk, sk, contribution):
        contribution_key = ("projections", pk, sk)
        score_key = (
            "projections",
            "EDITION#" + contribution["editionId"],
            "SCORE#current",
        )
        for _ in range(20):
            current = self.store.get(contribution_key)
            if not current:
                return
            score = self.store.get(score_key)
            updated = deepcopy(score) if score else {"ratingSum": 0, "reviewCount": 0}
            updated["ratingSum"] -= current["ratingSum"]
            updated["reviewCount"] -= 1
            try:
                self.store.commit(
                    {contribution_key: current, score_key: score},
                    {contribution_key: None, score_key: updated},
                )
                return
            except Conflict:
                continue
        raise Problem(503, "CONCURRENT_RETRY_REQUIRED")

    def _delete_audit_object(self, key, item):
        # EVENT rows also count: an object may exist if the worker died before writing its locator.
        if key[2].startswith("LAKE#") and item.get("objectKey"):
            self.audit.delete(item["objectKey"])
        elif key[2].startswith("EVENT#") and item.get("occurredAt"):
            self.audit.delete(self.audit.key_for(item["id"], item["occurredAt"]))

    def _update_job(self, key, job, stage):
        updated = {**job, "stage": stage, "updatedAt": stamp(self.identity.clock())}
        try:
            self.store.commit({key: job}, {key: updated})
        except Conflict as error:
            raise Problem(503, "CONCURRENT_RETRY_REQUIRED") from error

    def _erase(self, owner, job_key, job, limit):
        pk = "USER#" + owner
        candidates = []
        for table in ("identity", "history", "operations", "projections"):
            rows, _ = self.store.query(table, pk, limit=limit)
            for sk, item in rows:
                key = (table, pk, sk)
                if key == job_key:
                    continue
                candidates.append((key, item))
                if len(candidates) >= limit:
                    break
            if len(candidates) >= limit:
                break
        if len(candidates) < limit:
            for shard in range(16):
                partition = f"WORK#event#pending#{shard:02d}"
                # Markers are shared by all owners, so an unpaged read could miss this owner's.
                for sk, item in iter_partition(self.store, "operations", partition):
                    if item.get("owner") == owner:
                        candidates.append((("operations", partition, sk), item))
                        if len(candidates) >= limit:
                            break
                if len(candidates) >= limit:
                    break
        if candidates:
            if self.audit is not None:
                for key, item in candidates:
                    self._delete_audit_object(key, item)
            expected, writes = {}, {}
            for key, item in candidates:
                # One commit holds at most 100 rows; leftovers are picked up by the next step.
                if expected and len(expected) + 1 + len(item.get("sharedKeys", [])) > MAX_ROWS:
                    break
                expected[key] = item
                writes[key] = None
                if key[0] == "history" and key[2].endswith("#PART") and item.get("id"):
                    reverse = ("history", "PARTICIPATION#" + item["id"], "OWNER")
                    expected[reverse] = self.store.get(reverse)
                    writes[reverse] = None
                # Rows owned by this account but stored elsewhere (search index, the other side
                # of a follow, comments): removed in the same commit as the pointer row.
                for shared in map(tuple, item.get("sharedKeys", [])):
                    if shared not in expected:
                        expected[shared] = self.store.get(shared)
                        writes[shared] = None
            try:
                self.store.commit(expected, writes)
            except Conflict as error:
                raise Problem(503, "CONCURRENT_RETRY_REQUIRED") from error
            return {"state": "pending", "stage": "erase"}

        if self.blobs is not None:
            self.blobs.delete_owner(owner)
        for destination in self.external:
            destination.delete_owner(owner)

        work_key = ("operations", job["workPK"], job["workSK"])
        username_key = (
            ("identity", "USERNAME#" + job["username"], "CLAIM") if job.get("username") else None
        )
        keys = [job_key, work_key]
        if username_key:
            keys.append(username_key)
        expected = {key: self.store.get(key) for key in keys}
        writes = {key: None for key in keys}
        try:
            self.store.commit(expected, writes)
        except Conflict as error:
            raise Problem(503, "CONCURRENT_RETRY_REQUIRED") from error
        return {"state": "completed"}

"""Guards #8000 (Part 4): identity storage is Postgres-only. When no store
resolves, the user manager must fail loudly instead of silently degrading to
a second credential store with divergent semantics (the old sqlite fallback).

Also guards the way a server could reach a request while its identity is
wrong: a signing secret that cannot be kept, or a system principal that was
never provisioned (the one scheduled jobs and webhooks run as).
"""

import os;
import unittest.mock;
import from pathlib { Path }
import from tempfile { TemporaryDirectory }
import from jaclang.server.identity.user_manager { SYSTEM_USER, UserManager, UserRole }


"""Apply `values` over the environment, returning what was there before."""
def _set_env(values: dict[str, str | None]) -> dict[str, str | None] {
    previous: dict[str, str | None] = {};
    for (key, value) in values.items() {
        previous[key] = os.environ.get(key);
        if value is None {
            os.environ.pop(key, None);
        } else {
            os.environ[key] = value;
        }
    }
    return previous;
}


test "user manager refuses to start without a reachable database" {
    with unittest.mock.patch(
        "jaclang.server.shared_store.shared_store", return_value=None
    ) {
        with testraises(RuntimeError) as exc {
            UserManager(base_path=".");
        }
        assert "Postgres" in str(exc.value);
        assert "credential store" in str(exc.value);
    }
}


test "sqlite identity fallback is gone" {
    import jaclang.server.identity.identity_storage as storage_mod;
    assert not hasattr(storage_mod, "SqliteIdentityStorage");
}


test "a signing secret that cannot be kept fails the boot, not a request" {
    import from jaclang.server.server { JacAPIServer }
    with TemporaryDirectory() as tmpdir {
        # A regular file where the .jac data directory has to go.
        wall = os.path.join(tmpdir, "wall");
        Path(wall).write_text("", encoding="utf-8");
        previous = _set_env(
            {
                "JAC_DATA_PATH": wall,
                "KUBERNETES_SERVICE_HOST": None,
                "JAC_SERVE_AUTH_SECRET": None
            }
        );
        try {
            with testraises(RuntimeError) as exc {
                JacAPIServer(module_name="app", port=0, base_path=tmpdir);
            }
            message = str(exc.value);
            assert "[serve.auth] secret" in message;
            assert "keep to" in message;
        } finally {
            _set_env(previous);
        }
    }
}


"""Remove every trace of the system principal from the identity tables."""
def _wipe_system_user(srv: any) {
    store = srv.user_manager._identity_storage.store;
    store.rows(
        "DELETE FROM identity_users WHERE user_id IN "
        "(SELECT user_id FROM identity_lookups WHERE value_normalized = :v)",
        {"v": SYSTEM_USER}
    );
    store.rows(
        "DELETE FROM identity_lookups WHERE value_normalized = :v", {"v": SYSTEM_USER}
    );
}


"""A lookup row for the system identity whose user document is gone, as a
partially migrated identity table leaves it: the identity reads as absent, yet
creating it collides."""
def _orphan_system_lookup(srv: any) {
    srv.user_manager._identity_storage.store.rows(
        "INSERT INTO identity_lookups (value_normalized, user_id) VALUES (:v, :u)",
        {"v": SYSTEM_USER, "u": "orphaned-system-user"}
    );
}


def _role_cannot_be_stored(self: any, user_id: str, role: str) -> dict[str, str] {
    return {"error": "role store unavailable"};
}


"""The system user as a concurrent boot leaves it between creating the user and
giving it its role."""
def _system_user_without_role(srv: any) {
    srv.user_manager.create_internal_user(SYSTEM_USER, "__no_login__");
}


"""A lookup of the system identity that misses once, as it does for the process
that reads before the other boot has created the user, then reads for real."""
def _first_system_lookup_misses -> any {
    missed: list[bool] = [False];
    real = UserManager.find_user_by_identity;
    def _find(self: any, value: str) -> any {
        if value == SYSTEM_USER and not missed[0] {
            missed[0] = True;
            return None;
        }
        return real(self, value);
    }
    return _find;
}


test "a boot refuses to continue without a verified system principal" {
    import from jaclang.server.server { JacAPIServer }
    with TemporaryDirectory() as tmpdir {
        try {
            srv = JacAPIServer(module_name="app", port=0, base_path=tmpdir);
            _wipe_system_user(srv);
        } except Exception as e {
            print(f"[skip] embedded postgres unavailable: {e}");
            return;
        }
        # (label, wipe first, prepare, role setter, first lookup misses, boot must fail)
        cases = [
            ("first boot provisions it", True, None, None, False, False),
            ("a restart finds it already provisioned", False, None, None, False, False),
            (
                "an identity that is taken but unreadable",
                True,
                _orphan_system_lookup,
                None,
                False,
                True
            ),
            (
                "a role that cannot be applied",
                True,
                None,
                _role_cannot_be_stored,
                False,
                True
            ),
            (
                "a concurrent boot that created the user but not yet its role",
                True,
                _system_user_without_role,
                None,
                True,
                False
            )
        ];
        try {
            for (label, wipe, prepare, role_setter, misses_first, must_fail) in cases {
                if wipe {
                    _wipe_system_user(srv);
                }
                if prepare is not None {
                    prepare(srv);
                }
                finder = (
                    _first_system_lookup_misses()
                        if misses_first
                        else UserManager.find_user_by_identity
                );
                with unittest.mock.patch.object(
                    UserManager, "find_user_by_identity", new=finder
                ), unittest.mock.patch.object(
                    UserManager,
                    "set_user_role",
                    new=role_setter or UserManager.set_user_role
                ) {
                    if must_fail {
                        with testraises(RuntimeError) as exc {
                            srv._ensure_internal_users();
                        }
                        assert SYSTEM_USER in str(exc.value) , label;
                    } else {
                        srv._ensure_internal_users();
                        found = srv.user_manager.find_user_by_identity(SYSTEM_USER);
                        assert found is not None , label;
                        assert (
                            srv.user_manager.get_user_role(str(found["user_id"]))
                            == UserRole.SYSTEM.value
                        ) , label;
                    }
                }
            }
        } finally {
            _wipe_system_user(srv);
            srv._ensure_internal_users();
        }
    }
}

"""Unit tests for the shared static-asset resolver.

Every run mode (monolith, gateway, embedded, dev) consumes `asset_root_table` /
`resolve_asset` / `asset_cache_policy` from
`jaclang/server/serving/static_assets.jac`. Because there is exactly one
resolver, every resolution invariant is asserted here, once; host wiring and
cross-mode parity live in the gateway, embedded gateway and real-boot tests.
No mocks: real temp trees, real Path resolution.

(`root` is a Jac built-in, the graph root node, so the project dir is `proj`.)
"""

import os;
import tempfile;
import from pathlib { Path }
import from tempfile { TemporaryDirectory }
import from jaclang.server.serving.static_assets {
    AssetRoot,
    asset_root_table,
    resolve_asset,
    asset_cache_policy
}


# A fresh dir under the test's temp dir. Callers create the dirs/files they need.
def _project(tmp: str) -> Path {
    return Path(tempfile.mkdtemp(dir=tmp));
}


# Create proj/rel with `data`, making parent dirs. Returns the file path.
def _write(proj: Path, rel: str, data: bytes) -> Path {
    target = proj / rel;
    target.parent.mkdir(parents=True, exist_ok=True);
    target.write_bytes(data);
    return target;
}


# The standard table for a project whose client build is at .jac/client/dist.
def _table(proj: Path) -> list[AssetRoot] {
    return asset_root_table(proj, proj / ".jac" / "client" / "dist");
}


# ---- public/ at the web root ---------------------------------------------

test "public/ files resolve at the web root with no extension allowlist" {
    with TemporaryDirectory() as tmp {
        proj = _project(tmp);
        _write(proj, "public/brand/logo.png", b"PNG_DATA");
        _write(proj, "public/manifest.webmanifest", b"{}");
        _write(proj, "public/app.wasm", b"\x00asm");
        tbl = _table(proj);
        for (url, expected) in [
            ("/brand/logo.png", b"PNG_DATA"),
            ("/manifest.webmanifest", b"{}"),
            ("/app.wasm", b"\x00asm")
        ] {
            result = resolve_asset(tbl, url);
            assert result is not None , f"public/ file must be reachable at {url}";
            (path, _) = result;
            assert path.read_bytes() == expected;
        }
    }
}


# ---- containment: jail, no source leak, honest miss ----------------------

test "nothing outside the declared asset roots resolves" {
    with TemporaryDirectory() as tmp {
        proj = _project(tmp);
        # positive control, so the table below cannot pass vacuously
        _write(proj, "public/logo.png", b"OK");
        _write(proj, "package.json", b"{\"secrets\":true}");
        _write(proj, "src/app.js", b"console.log(1)");
        _write(proj, "secret.txt", b"classified");
        # `dist` is in the --scale bundle's _EXCLUDE_DIRS, so a project-root dist/
        # is absent in k8s; it must be a miss in every mode, not just k8s.
        _write(proj, "dist/legacy.png", b"LEGACY");
        os.symlink(str(proj / "secret.txt"), str(proj / "public" / "link.txt"));
        tbl = _table(proj);
        assert resolve_asset(tbl, "/logo.png") is not None;
        # Path.resolve() raises ValueError (not OSError) on an embedded NUL, so
        # /%00 must be a miss rather than a 500 in every host.
        for url in [
            "/package.json",
            "/src/app.js",
            "/../secret.txt",
            "/link.txt",
            "/\x00",
            "/legacy.png",
            "/dist/legacy.png",
            "/missing.png"
        ] {
            assert resolve_asset(tbl, url) is None , f"{url} must not resolve";
        }
    }
}


# ---- determinism: no basename flattening / no aliasing -------------------

test "exact path only: no basename flattening, one URL maps to one file" {
    with TemporaryDirectory() as tmp {
        proj = _project(tmp);
        _write(proj, "assets/img/icon.svg", b"SVG");
        _write(proj, "assets/logo.png", b"LOGO");
        tbl = _table(proj);
        # project assets/ are served under /static/assets/ at their real
        # relative path
        assert resolve_asset(tbl, "/static/assets/img/icon.svg") is not None;
        for url in [
            "/static/assets/icon.svg",
            "/static/assets/x/deep/logo.png",
            "/sub/logo.png",
            "/static/sub/logo.png"
        ] {
            assert resolve_asset(tbl, url) is None , f"{url} must not alias a shallower file";
        }
    }
}


# ---- table ordering (first hit wins) -------------------------------------

test "table order: built dist beats public/, which still serves what dist lacks" {
    with TemporaryDirectory() as tmp {
        proj = _project(tmp);
        _write(proj, ".jac/client/dist/index.html", b"DIST");
        _write(proj, "public/index.html", b"PUBLIC");
        _write(proj, "public/data.json", b"FROM_PUBLIC");
        tbl = _table(proj);
        for (url, expected) in [
            ("/index.html", b"DIST"),
            ("/data.json", b"FROM_PUBLIC")
        ] {
            result = resolve_asset(tbl, url);
            assert result is not None , f"{url} must resolve";
            (path, _) = result;
            assert path.read_bytes() == expected , f"{url} resolved to the wrong root";
        }
    }
}


# NOTE — one-law / reserved-segment protection ("public/user/data.json" must not
# serve at /user/data.json) is a HOST-DISPATCH invariant, not a resolver one: in
# every host, reserved paths classify before static, so the resolver is never
# asked for them. Asserting it here would force a backwards layering dependency
# (server core -> scale/routing.jac). It is asserted against the real
# gateway/monolith dispatch instead. The core resolver stays dependency-free.

# ---- asset_cache_policy: cache-control decision ----------------------------
# Response construction (status, ETag, 304, Range) is shared with the rest of
# the server through files.jac's file_response; asset_cache_policy only owns
# the one decision specific to these roots -- whether a hit is cacheable.

test "asset_cache_policy revalidates html shells and static files, never caches for a year" {
    with TemporaryDirectory() as tmp {
        proj = _project(tmp);
        png = _write(proj, "public/logo.png", b"PNG_DATA");
        html = _write(proj, "public/index.html", b"<html></html>");
        assert asset_cache_policy(html) == "no-cache";
        policy = asset_cache_policy(png);
        assert "max-age=3600" in policy;
        assert "must-revalidate" in policy;
        # The monolith's old blanket `max-age=31536000` on every file is the bug
        # being removed; a hashed/immutable long-cache split is separate work.
        assert "31536000" not in policy , "an unhashed, mutable asset must not be cached immutable for a year";
    }
}

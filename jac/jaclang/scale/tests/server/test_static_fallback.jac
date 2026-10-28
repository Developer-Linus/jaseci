import os;
import tempfile;


"""A root stub that answers every request with a fixed marker body, so a test
can prove a request never reached it (rather than merely that its own file
didn't win) by asserting the marker is absent from the response."""
def _spawn_root_stub(marker: bytes) -> tuple[any, int] {
    app = ServingApp(title="root-stub");
    async def handler(request: Request, call_next: object) -> Response {
        return Response(content=marker, media_type="application/octet-stream");
    }
    app.add_middleware(handler);
    server = ServingServer(app=app, host="127.0.0.1", port=0);
    stop = server.serve_background();
    assert server.bound_port , "root stub did not bind a port";
    return (stop, server.bound_port);
}


def _get_request -> Request {
    return Request(method="GET", url=URL(path="/static/assets/logo.svg"));
}


def _make_gateway(
    project_root: str, shadow_mount: str, dist: str
) -> MicroserviceGateway {
    gw = MicroserviceGateway(registry=ServiceRegistry());
    gw.base_path = project_root;
    gw.client_dist_dir = dist;
    if shadow_mount {
        gw.static_mounts = [{"url_prefix": "static", "local_path": shadow_mount}];
    }
    return gw;
}


test "project /static asset resolves even when a static mount claims the prefix" {
    project_root = tempfile.mkdtemp();
    os.makedirs(os.path.join(project_root, "assets"), exist_ok=True);
    with open(os.path.join(project_root, "assets", "logo.svg"), "w") as f {
        f.write("<svg></svg>");
    }

    shadow_mount = tempfile.mkdtemp();
    empty_dist = tempfile.mkdtemp();

    gw = _make_gateway(project_root, shadow_mount, empty_dist);
    # project assets/ is served under /static/assets/: assets/logo.svg resolves
    # at /static/assets/logo.svg. A static mount claiming the 'static' prefix
    # must not shadow that real project asset -- the static/assets->assets root
    # still serves it past the mount miss.
    resp = gw.handle_static(_get_request(), "/static/assets/logo.svg");

    assert resp is not None , "a /static/* project asset must still resolve when a static mount "
    "claims the 'static' prefix but lacks the file (#7020)";
    assert resp.status_code == 200;
}


test "a mount-owned miss 404s through full gateway dispatch (no leak, no SPA, no root fallthrough)" {
    import shutil;
    import from jaclang.testing.testkit { ServingTestClient as TestClient }
    project_root = tempfile.mkdtemp();
    dist = tempfile.mkdtemp();
    mount_dir = tempfile.mkdtemp();
    # A real root member, like `jac start --fleet` always has: dispatch must
    # never reach it for a mount-owned miss. It knows nothing about the
    # gateway's static_mounts and would serve its own public/media hit.
    (root_stop, root_port) = _spawn_root_stub(b"FROM_ROOT_SERVICE");
    try {
        # a project public/ file at the exact path the mount claims: must NOT leak
        media = os.path.join(project_root, "public", "media");
        os.makedirs(media, exist_ok=True);
        with open(os.path.join(media, "logo.png"), "wb") as f {
            f.write(b"FROM_PUBLIC");
        }
        # an index.html so the SPA fallback is available -- to prove it is NOT used
        with open(os.path.join(dist, "index.html"), "w") as f {
            f.write("<html>SPA</html>");
        }

        def _gateway(reg: ServiceRegistry, mounts: list[dict[str, str]]) -> any {
            gw = MicroserviceGateway(
                registry=reg, client_dist_dir=dist, static_mounts=mounts
            );
            gw.base_path = project_root;
            gw.setup();
            return TestClient(gw.app);
        }

        fleet = ServiceRegistry();
        fleet.register(
            ServiceEntry(
                name="app",
                file="main.jac",
                prefix="/",
                port=root_port,
                url=f"http://127.0.0.1:{root_port}",
                status=ServiceStatus.HEALTHY,
                is_root=True,
                serves_client=True
            )
        );
        with_root = _gateway(fleet, [{"url_prefix": "media", "local_path": mount_dir}]);
        # No root member owns "/", so /docs takes the client-page branch, which
        # must check mount ownership before answering with the SPA shell.
        client_pages = _gateway(
            ServiceRegistry(), [{"url_prefix": "docs", "local_path": mount_dir}]
        );
        # Positive control: with no mount, /docs is the client app's own page.
        plain = _gateway(ServiceRegistry(), []);

        png = {"accept": "image/png"};
        html = {"accept": "text/html"};
        # (client, method, path, headers, expected status)
        cases = [
            (plain, "GET", "/docs", html, 200),
            (with_root, "GET", "/media/logo.png", png, 404),
            # HEAD must not skip mount_claims and fall through to forward_to_root
            (with_root, "HEAD", "/media/logo.png", png, 404),
            (client_pages, "GET", "/docs", html, 404),
            (client_pages, "GET", "/docs/", html, 404)
        ];
        for (client, method, path, headers, expected) in cases {
            resp = client.get(path, headers=headers)
                if method == "GET"
                else client.head(path, headers=headers);
            assert resp.status_code == expected , (
                f"{method} {path}: expected {expected}, got {resp.status_code}"
            );
            if expected == 200 {
                assert b"SPA" in resp.content , f"{path} must be the SPA page";
                continue;
            }
            for leaked in (b"FROM_PUBLIC", b"SPA", b"FROM_ROOT_SERVICE") {
                assert leaked not in resp.content , (
                    f"{method} {path} is mount-owned; it must 404 in the gateway, "
                    f"not serve {leaked}"
                );
            }
        }
    } finally {
        root_stop();
        shutil.rmtree(project_root, ignore_errors=True);
        shutil.rmtree(dist, ignore_errors=True);
        shutil.rmtree(mount_dir, ignore_errors=True);
    }
}


test "a genuinely missing /static asset still 404s (no false-positive serving)" {
    project_root = tempfile.mkdtemp();
    os.makedirs(os.path.join(project_root, "assets"), exist_ok=True);
    shadow_mount = tempfile.mkdtemp();
    empty_dist = tempfile.mkdtemp();

    gw = _make_gateway(project_root, shadow_mount, empty_dist);
    resp = gw.handle_static(_get_request(), "/static/assets/does-not-exist.svg");

    assert resp is None , "a missing asset must not be served by the fallback path";
}


test "public/ asset is served at the web root like vite and next serve it" {
    import shutil;
    project_root = tempfile.mkdtemp();
    empty_dist = tempfile.mkdtemp();
    try {
        brand_dir = os.path.join(project_root, "public", "brand");
        os.makedirs(brand_dir, exist_ok=True);
        with open(os.path.join(brand_dir, "logo.png"), "wb") as f {
            f.write(b"PNG_DATA");
        }

        gw = _make_gateway(project_root, "", empty_dist);
        import from jaclang.server.serving.datatypes { URL }
        req = Request(method="GET", url=URL(path="/brand/logo.png"));
        resp = gw.handle_static(req, "/brand/logo.png");

        assert resp is not None , "public/brand/logo.png must be reachable at /brand/logo.png";
        assert resp.status_code == 200;
        assert resp.body_bytes() == b"PNG_DATA";
    } finally {
        shutil.rmtree(project_root, ignore_errors=True);
        shutil.rmtree(empty_dist, ignore_errors=True);
    }
}

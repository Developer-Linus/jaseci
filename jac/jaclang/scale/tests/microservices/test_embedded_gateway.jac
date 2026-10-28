import os;
import tempfile;


def _make_gateway(
    dist: str = "/nonexistent-dist", base_path: str = "."
) -> EmbeddedGateway {
    reg = ServiceRegistry();
    reg.register(ServiceEntry(name="orders", file="orders.jac", prefix="/orders"));
    reg.register(
        ServiceEntry(name="products", file="products.jac", prefix="/products")
    );

    transport = InProcessTransport();
    transport.register_function(
        "orders",
        "create",
        lambda (payload: dict[str, any]) { {"order_id": payload.get("n", 0) * 10}; }
    );
    transport.register_walker(
        "products",
        "List",
        lambda (payload: dict[str, any]) { {
            "result": {"limit": 2},
            "reports": [{"items": ["a", "b"]}]
        }; }
    );

    gw = EmbeddedGateway(
        registry=reg, transport=transport, client_dist_dir=dist, base_path=base_path
    );
    gw.setup();
    return gw;
}


test "a function member subpath is served by an in-process transport call" {
    gw = _make_gateway();
    client = TestClient(getattr(gw, "app"));
    resp = client.post("/orders/function/create", json={"n": 4});
    assert resp.status_code == 200;
    body = resp.json();
    assert body["ok"] == True;
    assert body["data"]["result"] == {"order_id": 40};
}


test "a walker member subpath is served by an in-process transport call" {
    gw = _make_gateway();
    client = TestClient(getattr(gw, "app"));
    resp = client.post("/products/walker/List", json={});
    assert resp.status_code == 200;
    assert resp.json()["data"]
        == {"result": {"limit": 2}, "reports": [{"items": ["a", "b"]}]};
}


test "an unregistered member surfaces a 404 envelope" {
    gw = _make_gateway();
    client = TestClient(getattr(gw, "app"));
    resp = client.post("/orders/function/missing", json={});
    assert resp.status_code == 404;
    assert resp.json()["error"]["code"] == "NOT_FOUND";
}


test "a bare service prefix falls through to static, never the transport" {
    gw = _make_gateway();
    client = TestClient(getattr(gw, "app"));
    resp = client.get("/orders");
    assert resp.status_code == 404;

    assert "Not found" in resp.json()["error"]["message"];
}


test "the shared middleware chain runs in front of the dispatcher" {
    gw = _make_gateway();
    hits: list[str] = [];

    obj _Audit(Middleware) {
        async def handle(request: any, call_next: any) -> any {
            hits.append("seen");
            return await call_next(request);
        }
    }

    gw.middleware.register(_Audit(name="audit", priority=10));

    gw.setup();
    client = TestClient(getattr(gw, "app"));
    client.post("/orders/function/create", json={"n": 1});
    assert "seen" in hits;
}


test "embedded gateway resolves dist and public/ files, and the SPA shell only for html navigations" {
    import shutil;
    project_root = tempfile.mkdtemp();
    dist = tempfile.mkdtemp();
    try {
        brand = os.path.join(project_root, "public", "brand");
        os.makedirs(brand, exist_ok=True);
        with open(os.path.join(brand, "logo.png"), "wb") as f {
            f.write(b"PNG_DATA");
        }
        with open(os.path.join(dist, "app.js"), "wb") as f {
            f.write(b"CONSOLE_LOG");
        }
        with open(os.path.join(dist, "index.html"), "w") as f {
            f.write("<!doctype html><title>spa-shell</title>");
        }

        gw = _make_gateway(dist=dist, base_path=project_root);
        client = TestClient(getattr(gw, "app"));
        # (path, accept, expected status, expected body fragment)
        cases = [
            # the resolver serves the physical files, not the SPA shell
            ("/app.js", "*/*", 200, b"CONSOLE_LOG"),
            ("/brand/logo.png", "image/png", 200, b"PNG_DATA"),
            # an extensionless html navigation with no matching file gets index.html
            ("/dashboard", "text/html", 200, b"spa-shell"),
            # a non-html asset miss is an honest 404, never the SPA shell
            ("/missing.png", "image/png", 404, b"NOT_FOUND")
        ];
        for (path, accept, status, fragment) in cases {
            resp = client.get(path, headers={"accept": accept});
            assert resp.status_code == status , (
                f"{path}: expected {status}, got {resp.status_code}"
            );
            assert fragment in resp.content , f"{path}: expected {fragment!r} in the body";
        }
    } finally {
        shutil.rmtree(project_root, ignore_errors=True);
        shutil.rmtree(dist, ignore_errors=True);
    }
}

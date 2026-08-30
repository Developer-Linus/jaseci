import from jaclang.scale.runtime.context.util {
    k8s_safe_service_name,
    k8s_service_dns_host,
    in_cluster_namespace
}

glob KEDA_INTERCEPTOR_SERVICE_ADDRESS: str = "keda-add-ons-http-interceptor-proxy.keda:8080";


obj ServiceRoute {
    has url: str,
        host_header: (str | None) = None;
}


def resolve_http_activation_config(
    top_level_http_activation: dict[str, any],
    app_scale_cfg: dict[str, any]
) -> dict[str, any] | None {
    """Merge [apps.<svc_name>.scale.http_activation] over
    [scale.kubernetes.http_activation], the same precedence
    ManifestBuilder._get_http_activation_config uses. Returns None when the
    merged config isn't enabled.""";
    per_service: dict[str, any] = dict(app_scale_cfg.get("http_activation", {}));
    merged: dict[str, any] = dict(top_level_http_activation);
    merged.update(per_service);
    if not merged.get("enabled", False) {
        return None;
    }
    return merged;
}


def resolve_service_route(
    svc_name: str,
    namespace: str,
    port: int,
    kubernetes_cfg: dict[str, any],
    app_scale_cfg: dict[str, any]
) -> ServiceRoute {
    """The one decision point: interceptor-routed vs. direct ClusterIP.""";
    safe_name = k8s_safe_service_name(svc_name);
    real_host = k8s_service_dns_host(f"{safe_name}-service", namespace);
    http_cfg = resolve_http_activation_config(
        dict(kubernetes_cfg.get("http_activation", {})), app_scale_cfg
    );
    if http_cfg is not None {
        return ServiceRoute(
            url=f"http://{KEDA_INTERCEPTOR_SERVICE_ADDRESS}", host_header=real_host
        );
    }
    return ServiceRoute(url=f"http://{real_host}:{port}", host_header=None);
}


def build_k8s_service_routes(
    routes: dict[str, str],
    port: int,
    kubernetes_cfg: dict[str, any],
    app_scale_configs: dict[str, dict[str, any]] | None = None
) -> dict[str, ServiceRoute] {
    namespace: str = in_cluster_namespace();
    configs: dict[str, dict[str, any]] = app_scale_configs or {};
    result: dict[str, ServiceRoute] = {};
    for svc_name in routes.keys() {
        result[svc_name] = resolve_service_route(
            svc_name, namespace, port, kubernetes_cfg, configs.get(svc_name, {})
        );
    }
    return result;
}

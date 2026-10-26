"""`[scale.monitoring].enabled` must decide whether the metrics stack deploys.
The observability path force-set `monitoring_enabled = True` on the config it
handed the deployer, so a configured `false` was overridden and a configured
`true` alone never reached the deployer at all. Real config objects, no mocks:
`gateway_config` is injected as a plain dict, which is the same seam
`_gateway_cfg` reads in production."""

def _target(
    monitoring: bool,
    logs: bool = False,
    tracing: bool = False,
    k8s_metrics: bool = True
) -> KubernetesTarget {
    return KubernetesTarget(
        config=KubernetesConfig(
            app_name="t",
            namespace="t-ns",
            monitoring_enabled=monitoring,
            k8s_metrics_enabled=k8s_metrics
        ),
        gateway_config={"logs": {"enabled": logs}, "tracing": {"enabled": tracing}}
    );
}


def _needs_privileged(target: KubernetesTarget) -> bool {
    return MonitoringDeployer(
        target._build_observability_config(), None
    ).needs_privileged_namespace();
}


test "a disabled monitoring switch is not overridden on the way to the deployer" {
    target = _target(monitoring=False, logs=True);
    obs = target._build_observability_config();
    assert obs.monitoring_enabled == False;
    assert obs.loki_enabled == True;
}


test "an enabled monitoring switch reaches the deployer" {
    target = _target(monitoring=True);
    obs = target._build_observability_config();
    assert obs.monitoring_enabled == True;
}


test "the monitoring switch alone requests the observability stack" {
    assert _target(monitoring=True)._observability_requested() == True;
    assert _needs_privileged(_target(monitoring=True)) == True , "node-exporter";
    no_node_metrics = _target(monitoring=True, k8s_metrics=False);
    assert _needs_privileged(no_node_metrics) == False , "no hostPath component";
}


test "logs or tracing still request the stack without the monitoring switch" {
    assert _target(monitoring=False, logs=True)._observability_requested() == True;
    assert _target(monitoring=False, tracing=True)._observability_requested() == True;
    assert _needs_privileged(_target(monitoring=False, logs=True)) == True;
    assert _needs_privileged(_target(monitoring=False, tracing=True)) == False , (
        "tracing alone runs Alloy without host paths, so the sandbox stays"
    );
}


test "nothing enabled requests nothing" {
    assert _target(monitoring=False)._observability_requested() == False;
}


test "Alloy mounts host paths only for logs, and a redeploy replaces it" {
    import unittest.mock;
    import from kubernetes.client.exceptions { ApiException }
    import from jaclang.scale.deploy.target.kubernetes { monitoring as monitoring_mod }

    def _render(logs: bool, exists: bool) -> tuple[str, dict[str, any]] {
        sent: list[tuple[str, dict[str, any]]] = [];
        def _read(**kwargs: any) {
            if not exists {
                raise ApiException(status=404);
            }
        }
        def _create(**kwargs: any) {
            sent.append(("create", kwargs["body"]));
        }
        def _replace(**kwargs: any) {
            sent.append(("replace", kwargs["body"]));
        }
        apps_v1 = unittest.mock.MagicMock();
        apps_v1.read_namespaced_daemon_set.side_effect = _read;
        apps_v1.create_namespaced_daemon_set.side_effect = _create;
        apps_v1.replace_namespaced_daemon_set.side_effect = _replace;
        obs = _target(
            monitoring=False, logs=logs, tracing=True
        )._build_observability_config();
        with unittest.mock.patch.object(
            monitoring_mod, "client", unittest.mock.MagicMock()
        ) {
            MonitoringDeployer(obs, None)._deploy_alloy(
                "t", "t-ns", apps_v1, unittest.mock.MagicMock()
            );
        }
        assert len(sent) == 1 , sent;
        return sent[0];
    }

    for (logs, exists, verb) in [
        (False, False, "create"),
        (True, False, "create"),
        (False, True, "replace"),
        (True, True, "replace"),

    ] {
        (sent_verb, body) = _render(logs, exists);
        assert sent_verb == verb , (logs, exists, sent_verb);
        pod = body["spec"]["template"]["spec"];
        host_paths = [
            v["hostPath"]["path"]
            for v in pod["volumes"]
            if "hostPath" in v
        ];
        mounted = [m["mountPath"] for m in pod["containers"][0]["volumeMounts"]];
        if logs {
            assert host_paths == ["/var/log/pods", "/var/lib/docker/containers"];
            assert "/var/log/pods" in mounted;
        } else {
            assert host_paths == [] , "tracing alone must not mount the node";
            assert mounted == ["/etc/alloy"];
        }
    }
}

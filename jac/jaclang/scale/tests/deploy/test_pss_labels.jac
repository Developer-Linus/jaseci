"""jac-scale must be able to upgrade a namespace it labeled itself.

The deploy stamps enforce=baseline on any namespace lacking an enforce label,
then the observability step refused to touch a namespace that already carried
one, so the privileged upgrade the hostPath DaemonSets need could never fire on
a namespace jac-scale created. An operator's own label must still be respected.
"""

test "the default labels record that jac-scale set the enforce level" {
    labels = default_pss_labels();
    assert labels[PSS_ENFORCE_LABEL] == "baseline";
    assert labels[PSS_WARN_LABEL] == "restricted";
    assert labels[PSS_SOURCE_LABEL] == "baseline";
}


test "an unlabeled namespace is upgraded to privileged" {
    patch = privileged_pss_labels({});
    assert patch == {PSS_ENFORCE_LABEL: "privileged", PSS_SOURCE_LABEL: "privileged"};
}


test "the baseline jac-scale set on this namespace is upgraded, not refused" {
    patch = privileged_pss_labels(default_pss_labels());
    assert patch is not None , "jac-scale must be able to overwrite its own default";
    assert patch[PSS_ENFORCE_LABEL] == "privileged";
    assert patch[PSS_SOURCE_LABEL] == "privileged" , "the marker follows the value";
}


test "an operator's own enforce label is left alone" {
    assert privileged_pss_labels({PSS_ENFORCE_LABEL: "baseline"}) is None;
    assert privileged_pss_labels({PSS_ENFORCE_LABEL: "restricted"}) is None;
}


test "a namespace whose baseline came from somewhere else is left alone" {
    existing = {PSS_ENFORCE_LABEL: "restricted", PSS_SOURCE_LABEL: "baseline"};
    assert privileged_pss_labels(existing) is None;
}


test "a namespace already privileged needs no patch and no warning" {
    assert privileged_pss_labels({PSS_ENFORCE_LABEL: "privileged"}) == {};
}


test "a second deploy of the same namespace is a no-op" {
    first = privileged_pss_labels(default_pss_labels());
    settled = {** default_pss_labels(), ** first};
    assert privileged_pss_labels(settled) == {} , "upgrading twice must not re-patch";
}


test "only a privileged level jac-scale set is released, and default goes back to unlabeled" {
    jac_privileged = {PSS_ENFORCE_LABEL: "privileged", PSS_SOURCE_LABEL: "privileged"};
    cases: list[tuple[str, dict[str, str], dict[str, any]]] = [
        (
            "app-ns",
            jac_privileged,
            {PSS_ENFORCE_LABEL: "baseline", PSS_SOURCE_LABEL: "baseline"}
        ),
        ("default", jac_privileged, {PSS_ENFORCE_LABEL: None, PSS_SOURCE_LABEL: None}),
        ("app-ns", {PSS_ENFORCE_LABEL: "privileged"}, {}),
        ("app-ns", default_pss_labels(), {}),
        ("app-ns", {}, {}),

    ];
    for (namespace, existing, expected) in cases {
        assert released_pss_labels(namespace, existing) == expected , (
            namespace,
            existing
        );
    }
}


test "a pod spec escapes baseline exactly when it asks the node for something" {
    import from kubernetes.client {
        V1Capabilities,
        V1Container,
        V1ContainerPort,
        V1HostPathVolumeSource,
        V1PodSpec,
        V1SecurityContext,
        V1Volume
    }
    plain = V1Container(name="app", image="app");
    cases: list[tuple[str, any, bool]] = [
        ("plain", V1PodSpec(containers=[plain]), False),
        ("no spec", None, False),
        (
            "hostPath volume",
            V1PodSpec(
                containers=[plain],
                volumes=[
                    V1Volume(
                        name="logs",
                        host_path=V1HostPathVolumeSource(path="/var/log/pods")
                    )
                ]
            ),
            True
        ),
        ("host network", V1PodSpec(containers=[plain], host_network=True), True),
        (
            "privileged container",
            V1PodSpec(
                containers=[
                    V1Container(
                        name="x", security_context=V1SecurityContext(privileged=True)
                    )
                ]
            ),
            True
        ),
        (
            "added capability",
            V1PodSpec(
                containers=[
                    V1Container(
                        name="x",
                        security_context=V1SecurityContext(
                            capabilities=V1Capabilities(add=["NET_ADMIN"])
                        )
                    )
                ]
            ),
            True
        ),
        (
            "dropped capabilities only",
            V1PodSpec(
                containers=[
                    V1Container(
                        name="x",
                        security_context=V1SecurityContext(
                            capabilities=V1Capabilities(drop=["ALL"])
                        )
                    )
                ]
            ),
            False
        ),
        (
            "host port",
            V1PodSpec(
                containers=[
                    V1Container(
                        name="x",
                        ports=[V1ContainerPort(container_port=80, host_port=80)]
                    )
                ]
            ),
            True
        ),

    ];
    for (label, spec, expected) in cases {
        assert pod_spec_escapes_baseline(spec) == expected , label;
    }
}

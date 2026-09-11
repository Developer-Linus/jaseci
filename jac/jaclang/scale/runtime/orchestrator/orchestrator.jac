import time;
import atexit;
import logging;
import from jaclang.cli.console { console }
import from jaclang.scale.runtime.fleet { FleetSpec, ROOT_PREFIX }
import from jaclang.scale.runtime.gateway.service_registry {
    ServiceRegistry,
    ServiceEntry,
    ServiceStatus
}
import from jaclang.scale.runtime.orchestrator.process_manager { ServiceProcessManager }
import from jaclang.scale.runtime.orchestrator.local_deployer { LocalDeployer }
import from jaclang.scale.runtime.gateway.process_gateway { ProcessGateway }
import from jaclang.scale.runtime.context.util {
    DEFAULT_GATEWAY_PORT,
    DEFAULT_GATEWAY_HOST,
    DEFAULT_CLIENT_DIST_DIR
}

glob logger = logging.getLogger(__name__),
     _BOOT_RECHECK_INTERVAL: float = 2.0;


def _log_gateway_only_ready(host: str, bound: int) {
    logger.info(
        f"Starting gateway-only mode on {host}:{bound} "
        f"(K8s pod context; no process spawning)"
    );
}


obj FleetOrchestrator {
    has fleet: FleetSpec,
        gateway_config: dict[str, any] = {};

    def _gateway_port -> int {
        return int(self.gateway_config.get("gateway_port", DEFAULT_GATEWAY_PORT));
    }

    def _gateway_host -> str {
        return str(self.gateway_config.get("gateway_host", DEFAULT_GATEWAY_HOST));
    }

    def _port_pinned -> bool {
        return bool(self.gateway_config.get("gateway_port_pinned", False));
    }

    def start_local -> None {
        if self.fleet.is_empty() {
            logger.warning(
                "No apps to run as a fleet: declare [apps.<name>] kind = \"service\" "
                "entries in jac.toml."
            );
            return;
        }

        client_dist: str = self._client_dist_dir();
        self._build_client_bundle_if_needed(client_dist);

        registry = self._build_registry();
        logger.info(f"Registry: {len(registry.entries)} apps");

        deployer = LocalDeployer(registry=registry, dev_mode=self._dev_mode());
        pm = deployer._ensure_pm();
        pm.app_boot_timeout = float(
            self.gateway_config.get("app_boot_timeout", pm.app_boot_timeout)
        );
        pm._boot_health_timeout = float(
            self.gateway_config.get("boot_health_timeout", pm._boot_health_timeout)
        );
        pm._health_monitor_interval = float(
            self.gateway_config.get(
                "health_monitor_interval", pm._health_monitor_interval
            )
        );
        deployer.deploy_all();
        max_wait: int = int(
            max(
                float(self.gateway_config.get("boot_max_wait", 90)),
                pm._boot_health_timeout
            )
        );

        atexit.register(deployer.destroy_all);

        self._wait_for_health(pm, registry, max_wait);

        pm.start_health_monitor(interval=_BOOT_RECHECK_INTERVAL);

        static_mounts: list[dict[str, str]] = self._parse_static_mounts();
        gateway = ProcessGateway(
            registry=registry,
            port=self._gateway_port(),
            host=self._gateway_host(),
            client_dist_dir=client_dist,
            static_mounts=static_mounts,
            port_pinned=self._port_pinned()
        );

        import from functools { partial }
        gateway.serve(
            on_ready=partial(
                self._print_startup_banner,
                registry,
                self._gateway_host(),
                static_mounts=static_mounts
            )
        );

        deployer.destroy_all();
    }

    def start_gateway_only -> None {
        if self.fleet.is_empty() {
            logger.error("No fleet to front: JAC_SV_FLEET is empty");
            return;
        }

        registry = self._build_registry();
        for (_name, _entry) in registry.entries.items() {
            _entry.status = ServiceStatus.STARTING;
        }
        _populate_k8s_urls(registry);

        health_monitor = ServiceProcessManager(registry=registry);
        health_monitor.start_health_monitor(interval=_BOOT_RECHECK_INTERVAL);

        gateway = ProcessGateway(
            registry=registry,
            port=self._gateway_port(),
            host=self._gateway_host(),
            client_dist_dir=self._client_dist_dir(),
            static_mounts=self._parse_static_mounts(),
            port_pinned=self._port_pinned()
        );
        import from functools { partial }
        gateway.serve(on_ready=partial(_log_gateway_only_ready, self._gateway_host()));
    }

    def _dev_mode -> bool {
        return bool(self.gateway_config.get("dev", False));
    }

    def _app_serves_client -> bool {
        return bool(self.gateway_config.get("app_serves_client", False));
    }

    def _build_registry -> ServiceRegistry {
        registry = ServiceRegistry();
        serves_client: bool = self._app_serves_client();
        for (name, member) in self.fleet.members.items() {
            svc_entry = ServiceEntry(
                name=name,
                file=member.file,
                prefix=ROOT_PREFIX if member.is_root else member.route,
                port=0,
                env={"JAC_SV_NAME": name},
                is_root=member.is_root,
                serves_client=member.is_root and member.client and serves_client
            );
            registry.register(svc_entry);
            role: str = " (host)" if member.is_root else "";
            logger.info(f"Registered app: {name} -> {svc_entry.prefix}{role}");
        }
        return registry;
    }

    def _client_dist_dir -> str {
        return str(self.gateway_config.get("client_dist_dir", DEFAULT_CLIENT_DIST_DIR));
    }

    def _parse_static_mounts -> list[dict[str, str]] {
        out: list[dict[str, str]] = [];
        raw = self.gateway_config.get("static_mounts", []);
        if not isinstance(raw, list) {
            return out;
        }
        for `entry in raw {
            ed = dict(`entry) if isinstance(`entry, dict) else {};
            url_prefix = str(ed.get("url_prefix", "")).strip();
            local_path = str(ed.get("local_path", "")).strip();
            if url_prefix and local_path {
                out.append({"url_prefix": url_prefix, "local_path": local_path});
            } else {
                logger.warning(
                    f"static mount missing url_prefix/local_path, dropped: {`entry}"
                );
            }
        }
        return out;
    }

    def _client_sources_newer_than(built_at: float) -> bool {
        import os;
        src_suffixes = (".jac", ".css", ".toml", ".ts", ".tsx", ".jsx");
        for (dirpath, dirnames, filenames) in os.walk(".") {
            dirnames[:] = [
                d
                for d in dirnames
                if not d.startswith(".") and d != "node_modules" and d != "__pycache__"
            ];
            for fname in filenames {
                if fname.endswith(src_suffixes) {
                    try {
                        if os.path.getmtime(os.path.join(dirpath, fname)) > built_at {
                            return True;
                        }
                    } except OSError {
                        continue;
                    }
                }
            }
        }
        return False;
    }

    def _build_client_bundle_if_needed(client_dist: str) -> None {
        root_member = self.fleet.root_member();
        client_entry: str = (
            root_member.file if root_member is not None and root_member.client else ""
        );
        if not client_entry {
            return;
        }
        import subprocess;
        import from pathlib { Path }
        dist_path = Path(client_dist);
        index_file = dist_path / "index.html";

        if index_file.exists() {
            if not self._client_sources_newer_than(index_file.stat().st_mtime) {
                logger.info("Client already built and up to date, skipping build");
                return;
            }
            console.print("  Client sources changed - rebuilding bundle...");
        }

        console.print(f"  Building client from {client_entry}...");
        try {
            build_result = subprocess.run(
                ["jac", "build", "--as", "client", client_entry], timeout=600
            );
            if build_result.returncode == 0 {
                console.print("  Client build complete");
            } else {
                logger.warning(
                    "Client build failed - gateway will start without client UI"
                );
            }
        } except subprocess.TimeoutExpired {
            logger.warning(
                "Client build exceeded 600s and was terminated - "
                "the gateway will serve the previous bundle if one exists"
            );
        } except FileNotFoundError {
            logger.warning("jac build command not found");
        }
    }

    def _wait_for_health(
        pm: ServiceProcessManager, registry: ServiceRegistry, max_wait: int
    ) -> bool {
        logger.info("Waiting for apps to start...");
        start_time: float = time.time();
        all_healthy = False;

        while time.time() - start_time < max_wait {
            results = pm.check_all_health();
            healthy_count: int = 0;
            dead_count: int = 0;
            for (name, `entry) in registry.entries.items() {
                if results.get(name) {
                    healthy_count += 1;
                } elif `entry.status == ServiceStatus.STOPPED {
                    dead_count += 1;
                }
            }
            if healthy_count == len(results) {
                all_healthy = True;
                logger.info(f"All {len(results)} apps healthy!");
                break;
            }
            if healthy_count + dead_count == len(results) {
                logger.warning(
                    f"{dead_count} app(s) exited during boot and cannot "
                    "become healthy; not waiting further"
                );
                break;
            }
            logger.info(f"  {healthy_count}/{len(results)} apps healthy, waiting...");
            time.sleep(2);
        }

        if not all_healthy {
            starting: list[str] = [
                name
                for (name, `entry) in registry.entries.items()
                if `entry.status not in (ServiceStatus.HEALTHY, ServiceStatus.STOPPED)
            ];
            if starting {
                logger.warning(
                    f"still starting after {max_wait}s: {', '.join(starting)}. "
                    "The gateway keeps polling them and picks up their routes "
                    "as soon as they answer; until then their paths reach the "
                    "root app."
                );
            }
        }
        return all_healthy;
    }

    def _print_startup_banner(
        registry: ServiceRegistry,
        gateway_host: str,
        gateway_port: int,
        static_mounts: list[dict[str, str]] = []
    ) {
        console.print();
        console.print("  Jac Fleet Mode", style="bold cyan");
        console.print(f"  Gateway: http://{gateway_host}:{gateway_port}", style="bold");
        console.print();
        console.print("  Apps", style="bold");
        console.print(f"  {'-' * 48}", style="muted");
        for (name, `entry) in registry.entries.items() {
            if `entry.status == ServiceStatus.HEALTHY {
                icon = "●";
                row_style = "success";
            } else {
                icon = "○";
                row_style = "warning";
            }
            label = f"{`entry.prefix} (host)" if `entry.is_root else `entry.prefix;
            console.print(
                f"  {icon} {name:18s} {label:20s} -> {`entry.url}", style=row_style
            );
        }
        if static_mounts {
            console.print();
            console.print("  Static mounts", style="bold");
            console.print(f"  {'-' * 48}", style="muted");
            for mount in static_mounts {
                console.print(
                    f"  -> {mount['url_prefix']:20s} -> {mount['local_path']}",
                    style="cyan"
                );
            }
        }
        console.print();
    }
}


def build_registry(fleet: FleetSpec) -> ServiceRegistry {
    return FleetOrchestrator(fleet=fleet)._build_registry();
}

def start_fleet_mode(fleet: FleetSpec, gateway_config: dict[str, any]) {
    FleetOrchestrator(fleet=fleet, gateway_config=gateway_config).start_local();
}

def start_gateway_only(fleet: FleetSpec, gateway_config: dict[str, any]) {
    FleetOrchestrator(fleet=fleet, gateway_config=gateway_config).start_gateway_only();
}


def _populate_k8s_urls(registry: ServiceRegistry) {
    try {
        import jaclang;
        dns_map: dict[str, str] = jaclang.JacRuntime.get_sv_registry();
    } except Exception as e {
        logger.warning(f"K8s URL population failed: {e}");
        return;
    }
    for (svc_name, _entry) in registry.entries.items() {
        url = dns_map.get(svc_name, "");
        if url {
            _entry.url = url;
        }
    }
    logger.info(
        f"K8s URLs populated: {sum(
            1
            for e in registry.entries.values()
            if e.url
        )}"
        f"/{len(registry.entries)} apps"
    );
}

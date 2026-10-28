impl _resolve_root(local_dir: str) -> Path {
    p = Path(local_dir);
    try {
        return p.resolve();
    } except (OSError, ValueError) {
        _logger.warning(
            f"could not resolve asset root {local_dir!r}, using unresolved path"
        );
        return p;
    }
}

impl _assets_dir(project_root: Path) -> Path {
    cfg = get_config_for_dir(str(project_root));
    return client_assets_dir(cfg, project_root);
}

impl _public_dirs(project_root: Path) -> list[Path] {
    cfg = get_config_for_dir(str(project_root));
    app_root = Path(client_app_root(cfg, project_root));
    dirs = [app_root / "public"] if app_root != project_root else [];
    dirs.append(project_root / "public");
    return dirs;
}

impl asset_root_table(project_root: Path, client_dist: Path) -> list[AssetRoot] {
    table: list[AssetRoot] = [];
    dist = str(client_dist);
    assets = str(_assets_dir(project_root));
    assets_resolved = _resolve_root(assets);

    table.append(
        AssetRoot(
            url_prefix="static/assets",
            local_dir=assets,
            source="assets",
            resolved_dir=assets_resolved,
        )
    );

    if dist and dist != "." {
        dist_resolved = _resolve_root(dist);
        table.append(
            AssetRoot(
                url_prefix="static",
                local_dir=dist,
                source="dist",
                resolved_dir=dist_resolved
            )
        );
        table.append(
            AssetRoot(
                url_prefix="", local_dir=dist, source="dist", resolved_dir=dist_resolved
            )
        );
    }
    for public_dir in _public_dirs(project_root) {
        public = str(public_dir);
        table.append(
            AssetRoot(
                url_prefix="",
                local_dir=public,
                source="public",
                resolved_dir=_resolve_root(public)
            )
        );
    }
    table.append(
        AssetRoot(
            url_prefix="",
            local_dir=assets,
            source="assets",
            resolved_dir=assets_resolved
        )
    );

    return table;
}

impl _remainder(url_path: str, prefix: str) -> (str | None) {
    p = prefix.strip("/");
    if p == "" {
        rel = url_path.lstrip("/");
        if rel.startswith("static/") {
            return None;
        }
        return rel;
    }
    marker = "/" + p;
    if url_path == marker {
        return "";
    }
    if url_path.startswith(marker + "/") {
        return url_path[len(marker) + 1:];
    }
    return None;
}

impl resolve_asset(
    table: list[AssetRoot], url_path: str
) -> (tuple[Path, AssetRoot] | None) {
    for r in table {
        rel = _remainder(url_path, r.url_prefix);
        if rel is None or rel == "" {
            continue;
        }
        base = r.resolved_dir;
        target = base / rel;
        try {
            resolved = target.resolve();
            if not resolved.is_relative_to(base) {
                continue;
            }
        } except (OSError, ValueError) {
            continue;
        }
        if resolved.is_file() {
            return (resolved, r);
        }
    }
    return None;
}

impl asset_cache_policy(target: Path) -> str {
    cacheable = target.suffix.lower() not in (".html", ".htm", "");
    return "public, max-age=3600, must-revalidate" if cacheable else "no-cache";
}

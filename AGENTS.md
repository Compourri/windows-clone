# AGENTS — Windows Clone

## Marketplace updates

- Plugin is listed in `omacom/omarchy-plugin-marketplace` as `com.compourri.windows-clone`.
- **DO NOT use the new-submission form** for updates. Open a **Verify** ticket via `.github/ISSUE_TEMPLATE/verify-plugin.yml`:
  - Title: `[Verify]: com.compourri.windows-clone — publish <version>`
  - Fields:
    - `Verification action: Verify and publish a newer upstream commit`
    - `Plugin ID: com.compourri.windows-clone`
    - `Repository URL: https://github.com/Compourri/windows-clone`
    - `Target commit: <full 40-char SHA of new HEAD/tag>`
    - Check `Verification acknowledgment`
  - Example: `gh issue create --repo omacom/omarchy-plugin-marketplace --title "[Verify]: com.compourri.windows-clone — publish 1.0.3" --body "Verification action: ...\nTarget commit: <sha>"`
- Bump `manifest.json` `version`, commit, tag `v<version>`, push `main` + tag, then create the Verify issue. See `issue #5692` for 1.0.3 example.

## Local install after code changes

- `clone-windows.sh` / `windows-clone-helper` are root-owned in `/usr/lib/windows-clone/` via `pkexec`/`sudo`. After editing, reinstall:
  ```bash
  pkexec bash /tmp/install-fix.sh  # or: sudo cp clone-windows.sh windows-clone-helper /usr/lib/windows-clone/ && sudo chown root:root /usr/lib/windows-clone/* && sudo chmod 755 /usr/lib/windows-clone/*
  ```
- QML plugin lives in `~/.config/omarchy/plugins/com.compourri.windows-clone/`; copy `Clone.qml`/`BarWidget.qml`/`manifest.json` there and `quickshell` restart is needed (validate with `omarchy plugin validate`).

## Security

- Helper allowlist is strict (`--randomize-guids|--preserve-guids|--yes` etc.), `exec "${ARGS[@]}"` with no shell, validates block devices and Omarchy disk. `--yes` only bypasses interactive `YES`, never `Omarchy` protection. Run `bash test-security.sh` before push.

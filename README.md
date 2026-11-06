# Windows UI Bridge

Local Windows desktop testing helper, usable from a CLI or any MCP stdio client. It is independent of Codex and Claude Code subscriptions. Each developer runs their own copy on their own logged-in Windows desktop; this is not a remote desktop service.

Created by John Lee, [Recherche Solutions LLC](https://recherchesolutions.com). Free for anyone to use under the [MIT License](LICENSE).

## Requirements

Setup checks every item below and prints `[ OK ]` or `[MISS]` for each one. Where something can be fixed without administrator rights, setup offers to fix it:
- **Python missing:** it offers to install Python 3.13 for your user only. It uses `winget` when available. Otherwise it downloads the python.org installer and runs it only if the installer carries a valid Python Software Foundation signature.
- **Execution policy blocks scripts:** it offers to set your *user* policy to `RemoteSigned`. If Group Policy controls the setting, it tells you to contact IT and changes nothing.

Setup asks before every change. Pass `-Yes` to accept all offers without prompts. When input is redirected, it declines them and stops with instructions.

| Requirement | Version | Notes |
|---|---|---|
| Windows (desktop session) | Windows 10/11 or Windows Server 2016+ | You must be signed in to an interactive desktop. Locked, disconnected or UAC secure desktops cannot be driven. |
| Python | **64-bit, 3.10 or newer** | From [python.org](https://www.python.org/downloads/windows/) or `winget install Python.Python.3.12`. `python` must be on `PATH`, or pass `-PythonCommand`. Python 3.14 is tested. |
| Windows PowerShell | 5.1 (built into Windows) | PowerShell 7 is not needed. |
| PowerShell execution policy | `RemoteSigned`, `Unrestricted` or `Bypass` | At runtime the bridge runs `worker.ps1`. The Windows client default (`Restricted`) blocks this. Where your organisation allows it: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`. Setup detects this and offers the change. |
| .NET Framework 4.x | Built into Windows | Uses UIAutomationClient, UIAutomationTypes, System.Windows.Forms and System.Drawing. |

These are bundled, and setup handles them:

| Dependency | How it is installed |
|---|---|
| `comtypes` 1.4.17 | Installed **offline** from `wheels/` into a private `.venv`, with its hash checked against `requirements.lock`. Needs no internet access or `pip` index. |
| `.venv` | Created by setup for the folder it runs in. It is never shipped. If the folder moves, run setup again. |

Optional, only if you use the matching registration flag: the `claude` CLI (Claude Code) or the `codex` CLI on `PATH`.

The helper never needs administrator rights. It changes no global Python packages, opens no network listener, and needs no cloud account or API key. Your user account determines which apps it can reach.

## Quick install (no source code needed)

1. Download `windows-ui-bridge-v<version>.zip` from the [`release/`](release/) folder or the GitHub Releases page.
2. Extract it to a folder you can write to, e.g. `C:\Tools\windows-ui-bridge`.
3. Double-click **`Setup.cmd`**.
4. Optional: register with your assistant by running one of these in that folder:

   ```bat
   Setup.cmd -RegisterClaude
   Setup.cmd -RegisterCodex
   ```

Setup checks the prerequisites and offers to install anything missing (see [Requirements](#requirements)). `Setup.cmd` runs `Setup.ps1` with a policy bypass for the setup process only; Group Policy still applies. Setup removes the "downloaded from the internet" mark from the extracted files so `RemoteSigned` accepts them. It rebuilds `.venv` if one is missing or broken, then prints `"ready": true`.

## Install from source

```powershell
powershell -NoProfile -File .\Setup.ps1
```

The optional flags register the helper with a client:

```powershell
powershell -NoProfile -File .\Setup.ps1 -RegisterCodex
powershell -NoProfile -File .\Setup.ps1 -RegisterClaude
```

Both flags may be supplied together. They add only the named `windows-ui-bridge` server. Open/reconnect the relevant client session to discover newly registered tools; the CLI works immediately. The helper has no dependency on either client executable unless its registration flag is used.

Equivalent registrations, with paths adjusted to your extracted folder:

```powershell
codex mcp add windows-ui-bridge -- C:\Tools\windows-ui-bridge\.venv\Scripts\python.exe C:\Tools\windows-ui-bridge\bridge.py serve
claude mcp add --transport stdio --scope user windows-ui-bridge -- C:\Tools\windows-ui-bridge\.venv\Scripts\python.exe C:\Tools\windows-ui-bridge\bridge.py serve
```

A generic MCP client can use this entry (replace paths):

```json
{"mcpServers":{"windows-ui-bridge":{"command":"C:\\Tools\\windows-ui-bridge\\.venv\\Scripts\\python.exe","args":["C:\\Tools\\windows-ui-bridge\\bridge.py","serve"]}}}
```

## Verify on each computer

```powershell
.\.venv\Scripts\python.exe .\smoke_test.py
```

This opens an explicitly disposable synthetic WinForms test app, operates only its own process/windows, and closes them afterward. Reports/screenshots go under `.state/self-test` by default. It tests native controls, text entry, password refusal, stale-window refusal, pointer input, modal dismissal, keyboard Escape and scoped secondary-window close. It does not verify every application, browser host or secure desktop.

## Tools and workflow

- `desktop_list_windows`: visible native windows, process, owner, physical bounds and identity keys. Offscreen browser host windows can be listed too; their existence does not prove they are dialogs.
- `desktop_inspect`: bounded UIA3 control tree, labels, bounds, supported patterns and state. It does not dump text-field values; password controls are masked.
- `desktop_screenshot`: one exact window via PrintWindow, to a fresh absolute PNG path. Unsupported renderers can return blank/black; verify the image.
- `desktop_capture_screen`: a display or virtual desktop screenshot, physical-pixel origin/bounds and cursor position. Prefer a window capture when possible.
- `desktop_act`: invoke, toggle, select, expand/collapse, set a non-password value, focus, close, limited navigation keys, cursor hover and mouse click. `click_point`/`hover_point` coordinates are relative to the selected window bounds, not the image of an unrelated screen.
- `desktop_action_status`: completion of an asynchronous UIA invoke.

For visual operation: list the target window; screenshot and analyze it; map the desired point to that window; act using its fresh `hwnd` and `window_key`; inspect or screenshot again to verify the resulting state. Pointer actions check the foreground and hit-tested top-level window. A changed identity, covered window or stale element is refused.

Prefer real mouse clicks for controls that **open modal dialogs**. Some providers hold a UIA Invoke RPC until their dialog closes and can block further provider inspection. Invokes use bounded background jobs and return a `job_id` when pending: inspect the expected UI and query its status rather than submitting it again. If provider inspection is blocked, use a verified window screenshot and scoped pointer/keyboard input. A timeout never proves the action did not run.

CLI requests are JSON on stdin or in a UTF-8 file:

```powershell
'{"command":"list_windows","process":"notepad"}' | .\.venv\Scripts\python.exe .\bridge.py call
.\.venv\Scripts\python.exe .\bridge.py call --request-file .\request.json
```

Inspect example (use real keys returned by the list call):

```json
{"command":"inspect","hwnd":"12345","window_key":"returned-key","max_nodes":350,"max_depth":12}
```

Button action example (use a real key returned by inspect):

```json
{"command":"act","hwnd":"12345","window_key":"returned-key","action":"click","element_key":"returned-element-key"}
```

## Operating boundaries

The helper performs requested actions; it never automatically approves every popup, closes unrelated windows, changes credentials, answers CAPTCHAs or elevates privileges. Existing authorization and confirmation rules apply equally in Codex, Claude Code and other clients. Password input is deliberately refused. UAC/secure desktops, locked or disconnected desktop sessions, higher-integrity apps and controls without suitable accessibility/pixel exposure are not guaranteed. Use the same interactive session and compatible integrity level as the app; no protection bypass is included.

Input text, screenshots and UI names are omitted from the action journal. Read results and screenshots can still contain private UI: keep `.state`, virtual environments, logs and local configuration out of shared packages. The bundled source and wheel contain no credentials, application data or machine-specific MCP profiles. Screen interpretation is performed by the calling assistant/model; the bridge itself supplies pixels and control metadata without sending them to a cloud service.

## Building a release

```powershell
powershell -NoProfile -File .\Build-Release.ps1 -Version 0.1.0
```

This writes `release\windows-ui-bridge-v0.1.0.zip` and a `.sha256` file. The zip contains only the distributable source, `Setup.cmd` and the pinned wheel, never `.venv`, `.state` or local configuration.

## Sources

- [Microsoft UI Automation patterns](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-controlpatternsoverview)
- [comtypes client API](https://comtypes.readthedocs.io/en/stable/client.html)
- [Codex MCP configuration](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)
- [Claude Code local stdio MCP](https://code.claude.com/docs/en/mcp#option-3-add-a-local-stdio-server)

Client-specific configuration is documented and packaged. Protocol and local Windows behavior must be tested separately from claims about every client or other computer.

## License

[MIT](LICENSE): free to use, copy, modify and distribute, including commercially. Keep the copyright notice. Provided as is, without warranty.

# AzQuotaRequester as an MCP server

Exposes the quota tooling to MCP clients, so you can ask for quota in chat
instead of running the wizard:

> *"Do I have room for eight more D4ads_v7 in Italy North?"*
> *"Raise the Dadsv7 quota there to 64."*

The server runs **on your machine** and uses the Azure session you are already
signed in with, so everything happens under your own RBAC. No hosting, no app
registration, no on-behalf-of exchange.

---

## Requirements

| Item | Requirement |
|---|---|
| PowerShell | 7 (`pwsh`) — the server relies on `[Console]::In.ReadLine()` over piped stdio |
| Module | `Az.Accounts` |
| Azure | `Connect-AzAccount` **once, in a normal shell** — the server never prompts |
| Client | An MCP client that can launch a **local (stdio)** server |

The server deliberately never calls `Connect-AzAccount`: it has no terminal, so
a sign-in prompt would hang the client forever. If you are not signed in, the
tools return a clear error telling you to sign in first.

---

## Setup

### GitHub Copilot CLI

```powershell
copilot mcp add azquota -- pwsh -NoProfile -File C:\path\to\AzQuotaRequester\mcp\Start-AqrMcpServer.ps1
```

Or edit `%USERPROFILE%\.copilot\mcp-config.json` directly:

```json
{
  "mcpServers": {
    "azquota": {
      "tools": ["*"],
      "type": "local",
      "command": "pwsh",
      "args": [
        "-NoProfile",
        "-File",
        "C:\\path\\to\\AzQuotaRequester\\mcp\\Start-AqrMcpServer.ps1"
      ]
    }
  }
}
```

### VS Code

`.vscode/mcp.json`:

```json
{
  "servers": {
    "azquota": {
      "type": "stdio",
      "command": "pwsh",
      "args": [
        "-NoProfile",
        "-File",
        "C:\\path\\to\\AzQuotaRequester\\mcp\\Start-AqrMcpServer.ps1"
      ]
    }
  }
}
```

---

## Tools

| Tool | Does | Changes anything? |
|---|---|---|
| `azqr_assess_sku` | **Start here.** Quota + restrictions + zones + successors, with a verdict and ranked alternatives | No |
| `azqr_get_context` | Subscription, tenant and account the tools act as | No |
| `azqr_check_quota` | Limit, used and available for the SKU family **and** the regional total | No |
| `azqr_check_sku` | Availability state, zones, restrictions | No |
| `azqr_suggest_skus` | The same size in newer generations the region actually offers | No |
| `azqr_request_quota` | Requests an increase through `Microsoft.Quota` and waits | **Yes** |

All of them accept a region as `westeurope` or `West Europe`, and a SKU as
`Standard_D4ads_v7`, `d4ads_v7`, `dadsv7`, or the family display name. An
ambiguous query returns the candidates instead of guessing — picking one
silently could raise quota on the wrong family.

---

## Recommendations

Quota, restrictions and successors are only useful **together**. A healthy limit
on a restricted SKU reads like *"you're fine"* when in fact nothing can be
deployed — so every result carries the same assessment: the numbers, what is
blocking, and what to do about it.

| Verdict | Meaning |
|---|---|
| `Proceed` | Usable across every AZ. Newer generations are still named, if any exist. |
| `ProceedWithZonePinning` | Usable, but not in every AZ. Raise quota and pin the deployment to a usable zone. |
| `ProceedOrSwitch` | Usable in some AZs, but a successor covers all of them. |
| `RequestQuota` | Offered and unrestricted, but the limit is 0. |
| `SwitchSku` | Not usable here. A successor is, and it is named. |
| `SupportCase` | Not usable, and no successor in this region is either. |

Alternatives are ranked by **usability first** — an unusable option is never a
recommendation, however new it is — then by zone coverage, then generation, then
existing headroom. Each one says *why* it is being offered.

`azqr_request_quota` uses the same assessment twice: it refuses before sending
anything if the SKU is restricted, and if Azure refuses the request it attaches
the alternatives, because that is exactly when another generation matters.

```jsonc
// azqr_assess_sku: Standard_D4ads_v5 in germanywestcentral
"status": "RestrictedForSubscription",
"quota":  { "family": { "limit": 20, "used": 0, "available": 20 } },  // looks fine, is not
"blockers": [
  "Not enabled for this subscription, or blocked in every zone. A quota request cannot lift this.",
  "AZ 1,2,3 restricted for this subscription."
],
"recommendation": {
  "verdict":  "SwitchSku",
  "bestPick": "Standard_D4ads_v7",
  "summary":  "Standard_D4ads_v5 cannot be used in germanywestcentral (RestrictedForSubscription). Switch to Standard_D4ads_v7 - newer generation; usable while the requested one is not."
}
```

### Safety

- **`targetVCores` is the absolute new limit, not an increment.** The Quota API
  accepts and applies a *lower* value, so a delta would silently shrink quota.
- **A restricted SKU is refused before anything is sent.** A quota increase
  cannot lift a subscription restriction, so the tool says so instead of
  submitting a request that cannot succeed.
- **Results are verified by re-reading the live limit.** If the request reports
  success but the limit did not move, the outcome is `Unverified`, not
  `Succeeded`.
- **A preview never reads as an outcome.** With `whatIf: true` the summary says
  what *would* be requested and never claims a target was reached.
- **No support cases.** The server will not file one. When Azure refuses, the
  result says so and points at `Start-AzQuotaRequest.ps1`, which files a case
  from your template. Filing a real support case is not something an agent
  should do unattended.

---

## Why this cannot work with Microsoft 365 Copilot

Cloud-hosted Copilot surfaces cannot reach a server on your workstation:

| Surface | Local stdio? | Acts as your Azure identity? |
|---|---|---|
| GitHub Copilot CLI / VS Code | Yes | Yes — your `Connect-AzAccount` session |
| Microsoft 365 Copilot | **No** | Only via a hosted service doing OBO |
| Copilot Studio | **No** | Only via a hosted service doing OBO |
| Copilot in Azure (portal) | **No** | No extensibility model at all |

The blocker is structural, not a setting: the M365 Copilot plugin manifest types
its MCP runtime as `RemoteMCPServer` with a **required absolute URL**. There is
no stdio option, and the only local runtime it allows is Office add-ins.

To use this from M365 Copilot or Copilot Studio you would host the logic behind
HTTPS, register two Entra apps, and exchange the user token on-behalf-of for an
ARM token. That is a different deployment with different security properties —
and execution would no longer happen on your machine.

---

## Troubleshooting

Nothing but JSON-RPC ever reaches stdout, so the only way to watch the server is
a log file:

```powershell
pwsh -NoProfile -File .\mcp\Start-AqrMcpServer.ps1 -LogPath $env:TEMP\azquota-mcp.log
```

You can also drive it by hand — it is just line-delimited JSON:

```powershell
@(
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
) -join "`n" | pwsh -NoProfile -File .\mcp\Start-AqrMcpServer.ps1
```

**If the client reports a protocol error**, something wrote to stdout. The
modules narrate with `Write-Host`, which lands there, so the server captures the
real stdout once at startup and blackholes the console for the rest of the
process. Any new code that prints is therefore harmless — but if you replace
that guard, the stream breaks. The test suite pins this behaviour.

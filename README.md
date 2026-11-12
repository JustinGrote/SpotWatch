# Azure Monitor VM starter

An HTTP-triggered Azure PowerShell Function that accepts the Azure Monitor common alert schema, starts its single targeted virtual machine, and returns success only after Azure reports `PowerState/running`.

## Deploy and configure

Deploy this folder as an Azure Functions app using the PowerShell 7.4 runtime. The Function endpoint requires a Function key; use its full URL, including `?code=...`, as the Azure Monitor action group's webhook URL and enable the common alert schema.

By default, the function uses the Function App's managed identity. Set `AZURE_CLIENT_ID` to use a user-assigned managed identity. To use a service principal instead, set all three of `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_CLIENT_SECRET`; if any are missing, the function uses managed identity.

| Setting | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | If specified alone, this is the optional user-assigned managed identity client ID. If specified with the other two settings, it is the service principal ID |
| `AZURE_TENANT_ID` | Required with the other two settings for a service principal |
| `AZURE_CLIENT_SECRET` | Required with the other two settings for a service principal; store as an app setting backed by Key Vault where possible |

For system-assigned managed identity, enable it on the Function App and omit all three settings. For a user-assigned identity, set `AZURE_CLIENT_ID` and leave `AZURE_TENANT_ID` and `AZURE_CLIENT_SECRET` unset. Assign the selected identity or service principal the **Virtual Machine Contributor** role on the VM (or a suitable parent scope). Store the client secret only in protected Function App configuration.

Only alerts whose `alertContext.properties.title` is `Low priority machine preempted`, with `monitorCondition` set to `Fired`, the virtual-machine target type, and exactly one valid VM resource ID are acted on. Other alert titles are ignored. The function polls Azure for up to 120 seconds. It returns HTTP 200 when running, 504 if the VM does not become running in time, 400 for an unsupported or malformed payload, and 500 for an Azure operation or authentication error.

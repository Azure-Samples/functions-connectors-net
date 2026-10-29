# OneDrive for Business connector triggers (.NET)

Choose one standalone sample:

| Sample | Delivery to Functions | Local development |
| --- | --- | --- |
| [Polling](polling/README.md) | The host receives and acknowledges events from the Connector Namespace using identity | No public callback or tunnel |
| [Webhook](webhook/README.md) | The Connector Namespace posts events to the Functions webhook | Requires a public, authenticated callback for live connector events |

Both samples support all four file events:

| Function | Connector operation | Event |
| --- | --- | --- |
| `OnNewFileContent` | `OnNewFileV2` | File created, including content |
| `OnUpdatedFileContent` | `OnUpdatedFileV2` | File modified, including content |
| `OnNewFile` | `OnNewFilesV2` | File created (properties only) |
| `OnUpdatedFile` | `OnUpdatedFilesV2` | File modified (properties only) |

Content operations bind raw JSON as `string`; properties-only operations retain
their typed SDK payloads. Functions only log that
the trigger was received; there is no Blob output binding and file payloads are
not serialized or logged. Azure Storage remains for Functions host state and
deployment artifacts.

Poll versus Webhook describes delivery **from the namespace to the Functions
host**, not how the OneDrive connector detects changes. Each sample has its own
project, dependencies, infrastructure, deployment hook, and local-settings
template. Copy an entire sample folder to use it independently. Use different
`azd` environment names for polling and webhook deployments.
